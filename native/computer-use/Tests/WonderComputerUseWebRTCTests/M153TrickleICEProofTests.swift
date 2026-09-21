import XCTest
@preconcurrency import WebRTC

final class M153TrickleICEProofTests: XCTestCase {
    func testTwoLocalPeersConnectWithQueuedTrickleICE() throws {
        let factory: RTCPeerConnectionFactory = {
            RTCInitializeSSL()
            return RTCPeerConnectionFactory(
                encoderFactory: RTCDefaultVideoEncoderFactory(),
                decoderFactory: RTCDefaultVideoDecoderFactory()
            )
        }()
        let configuration = RTCConfiguration()
        configuration.iceServers = []
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let connected = expectation(description: "both M153 peers reach encrypted ICE")
        connected.expectedFulfillmentCount = 2

        let left = try XCTUnwrap(factory.peerConnection(with: configuration, constraints: constraints, delegate: nil))
        let right = try XCTUnwrap(factory.peerConnection(with: configuration, constraints: constraints, delegate: nil))
        let leftDelegate = PeerDelegate { state in
            if state == .connected || state == .completed { connected.fulfill() }
        }
        let rightDelegate = PeerDelegate { state in
            if state == .connected || state == .completed { connected.fulfill() }
        }
        left.delegate = leftDelegate
        right.delegate = rightDelegate
        let router = CandidateRouter(left: left, right: right)
        leftDelegate.onCandidate = { router.route($0, fromLeft: true) }
        rightDelegate.onCandidate = { router.route($0, fromLeft: false) }
        let source = factory.videoSource(forScreenCast: true)
        let track = factory.videoTrack(with: source, trackId: "m153-proof-video")
        _ = left.add(track, streamIds: ["m153-proof-stream"])

        let offerExpectation = expectation(description: "offer and answer applied")
        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse],
            optionalConstraints: nil
        )
        left.offer(for: offerConstraints) { offer, error in
            XCTAssertNil(error)
            guard let offer else { return }
            left.setLocalDescription(offer) { error in
                XCTAssertNil(error)
                right.setRemoteDescription(offer) { error in
                    XCTAssertNil(error)
                    router.markRightRemoteDescriptionSet()
                    right.answer(for: offerConstraints) { answer, error in
                        XCTAssertNil(error)
                        guard let answer else { return }
                        right.setLocalDescription(answer) { error in
                            XCTAssertNil(error)
                            left.setRemoteDescription(answer) { error in
                                XCTAssertNil(error)
                                router.markLeftRemoteDescriptionSet()
                                offerExpectation.fulfill()
                            }
                        }
                    }
                }
            }
        }

        wait(for: [offerExpectation, connected], timeout: 8)
        left.close()
        right.close()
    }
}

private final class CandidateRouter: @unchecked Sendable {
    private let lock = NSLock()
    private weak var left: RTCPeerConnection?
    private weak var right: RTCPeerConnection?
    private var leftReady = false
    private var rightReady = false
    private var leftPending: [RTCIceCandidate] = []
    private var rightPending: [RTCIceCandidate] = []

    init(left: RTCPeerConnection, right: RTCPeerConnection) {
        self.left = left
        self.right = right
    }

    func route(_ candidate: RTCIceCandidate, fromLeft: Bool) {
        lock.lock()
        let peer = fromLeft ? right : left
        let ready = fromLeft ? rightReady : leftReady
        if !ready {
            if fromLeft { rightPending.append(candidate) } else { leftPending.append(candidate) }
            lock.unlock()
            return
        }
        lock.unlock()
        peer?.add(candidate) { _ in }
    }

    func markRightRemoteDescriptionSet() {
        lock.lock()
        rightReady = true
        let pending = rightPending
        rightPending.removeAll()
        let peer = right
        lock.unlock()
        pending.forEach { peer?.add($0) { _ in } }
    }

    func markLeftRemoteDescriptionSet() {
        lock.lock()
        leftReady = true
        let pending = leftPending
        leftPending.removeAll()
        let peer = left
        lock.unlock()
        pending.forEach { peer?.add($0) { _ in } }
    }
}

private final class PeerDelegate: NSObject, RTCPeerConnectionDelegate {
    let onState: (RTCIceConnectionState) -> Void
    var onCandidate: ((RTCIceCandidate) -> Void)?

    init(onState: @escaping (RTCIceConnectionState) -> Void) {
        self.onState = onState
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) { onState(newState) }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) { onCandidate?(candidate) }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
