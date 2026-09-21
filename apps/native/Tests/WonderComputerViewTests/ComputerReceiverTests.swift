import XCTest
@preconcurrency import WebRTC
@testable import WonderComputerView
import WonderPairing

final class ComputerReceiverTests: XCTestCase {
    func testOfferAnswerOrderAndCandidateBuffering() async throws {
        let transport = FakeTransport(responses: [
            .success(response(peerRevision: "peer-1", nextCursor: 1, candidates: [candidate(1)], offer: nil)),
            .success(response(peerRevision: "peer-1", nextCursor: 2, candidates: [candidate(2)], offer: offer)),
        ])
        let peer = FakePeer()
        let receiver = ComputerReceiver(peerFactory: FakePeerFactory(peer: peer))
        receiver.start(session: session, transport: transport)

        peer.emitLocalCandidate()
        try await waitUntil { await transport.answerRequests.count == 1 && peer.addedSequences == [1, 2] }

        let polls = await transport.pollRequests
        XCTAssertGreaterThanOrEqual(polls.count, 2)
        XCTAssertEqual(polls[0].cursor, 0)
        XCTAssertEqual(polls[1].cursor, 1)
        let answers = await transport.answerRequests
        let localCandidates = await transport.candidateRequests
        XCTAssertEqual(answers.first?.peerRevision, "peer-1")
        XCTAssertEqual(localCandidates.map(\.sequence), [1])
        XCTAssertTrue(peer.remoteOfferAccepted)

        receiver.close()
        XCTAssertEqual(receiver.currentState, .closed)
    }

    func testOutOfRangeRemoteCandidateIsIgnoredAndFollowingValidCandidatesAreDeliveredInOrder() async throws {
        let transport = FakeTransport(responses: [
            .success(response(
                peerRevision: "peer-1",
                nextCursor: 3,
                candidates: [
                    candidate(1, sdpMLineIndex: UInt64(Int32.max) + 1),
                    candidate(2),
                    candidate(3),
                ],
                offer: offer
            )),
        ])
        let peer = FakePeer()
        let receiver = ComputerReceiver(peerFactory: FakePeerFactory(peer: peer))
        receiver.start(session: session, transport: transport)

        try await waitUntil { peer.remoteOfferAccepted && peer.addedSequences == [2, 3] }

        XCTAssertEqual(peer.addedSequences, [2, 3])
        receiver.close()
    }

    func testStaleSessionGenerationAndPeerRevisionAreIgnored() async throws {
        let transport = FakeTransport(responses: [
            .success(response(sessionID: "other-session", generation: 99, peerRevision: "stale", nextCursor: 20, candidates: [candidate(20)], offer: offer)),
            .success(response(peerRevision: "peer-current", nextCursor: 1)),
            .success(response(peerRevision: "peer-old", nextCursor: 2, offer: offer)),
        ])
        let peer = FakePeer()
        let receiver = ComputerReceiver(peerFactory: FakePeerFactory(peer: peer))
        receiver.start(session: session, transport: transport)

        try await waitUntil { (await transport.pollRequests).count >= 3 }
        XCTAssertEqual(peer.acceptedOfferCount, 0)
        let answers = await transport.answerRequests
        let candidates = await transport.candidateRequests
        XCTAssertEqual(answers.count, 0)
        XCTAssertEqual(candidates.count, 0)
        receiver.close()
    }

    func testRetryAndTeardownCancelPollingAndCloseSignaling() async throws {
        let transport = FakeTransport(responses: [
            .failure,
            .success(response(peerRevision: "peer-1", nextCursor: 0)),
        ])
        let peer = FakePeer()
        let receiver = ComputerReceiver(peerFactory: FakePeerFactory(peer: peer))
        receiver.start(session: session, transport: transport)

        try await waitUntil(timeout: 2) { receiver.currentState == .retrying("The Mac could not be reached. Retrying…") }
        try await waitUntil(timeout: 2) { await transport.pollRequests.count >= 2 }
        receiver.close(reason: "dismissed")

        XCTAssertEqual(receiver.currentState, .closed)
        XCTAssertTrue(peer.closed)
        try await waitUntil { await transport.closeRequests.count == 1 }
        let closes = await transport.closeRequests
        XCTAssertEqual(closes.first?.reason, "dismissed")

        let count = await transport.pollRequests.count
        try await Task.sleep(for: .milliseconds(350))
        let pollsAfterClose = await transport.pollRequests.count
        XCTAssertEqual(pollsAfterClose, count)
    }

    func testRendererStateClearsOnDisconnect() async throws {
        let live = response(peerRevision: "peer-1", state: "live")
        let transport = FakeTransport(responses: [.success(live)], fallback: live)
        let peer = FakePeer()
        let receiver = ComputerReceiver(peerFactory: FakePeerFactory(peer: peer))
        receiver.start(session: session, transport: transport)

        peer.emitVideoTrack()
        peer.emit(.connected)
        try await waitUntil { receiver.currentState == .live }
        peer.emit(.disconnected)
        try await waitUntil { receiver.currentState == .retrying("The connection to your Mac was interrupted. Retrying…") }
        XCTAssertEqual(peer.clearRendererCount, 1)
        peer.emit(.failed)
        try await waitUntil { if case .failed = receiver.currentState { return true }; return false }
        receiver.close()
    }

    func testLiveRequiresHostCaptureConnectedPeerAndVideoTrack() async throws {
        let transport = FakeTransport(responses: [
            .success(response(peerRevision: "peer-1", offer: offer, state: "offerReady")),
            .success(response(peerRevision: "peer-1", state: "live")),
        ], fallback: response(peerRevision: "peer-1", state: "live"))
        let peer = FakePeer()
        let receiver = ComputerReceiver(peerFactory: FakePeerFactory(peer: peer))
        receiver.start(session: session, transport: transport)

        try await waitUntil { await transport.answerRequests.count == 1 }
        peer.emit(.connected)
        XCTAssertNotEqual(receiver.currentState, .live)
        peer.emitVideoTrack()
        try await waitUntil { receiver.currentState == .live }
        receiver.close()
    }

    func testAwaitingSourceIsTruthfulAndPeerConnectionDoesNotMakeItLive() async throws {
        let awaiting = response(peerRevision: "peer-1", state: "awaitingSource")
        let transport = FakeTransport(responses: [.success(awaiting)], fallback: awaiting)
        let peer = FakePeer()
        let receiver = ComputerReceiver(peerFactory: FakePeerFactory(peer: peer))
        receiver.start(session: session, transport: transport)

        try await waitUntil { receiver.currentState == .awaitingSource }
        peer.emit(.connected)
        peer.emitVideoTrack()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(receiver.currentState, .awaitingSource)
        receiver.close()
    }

    func testTerminalFailureIsNotOverwrittenByLatePeerClose() async throws {
        let transport = FakeTransport(responses: [])
        let peer = FakePeer()
        let receiver = ComputerReceiver(peerFactory: FakePeerFactory(peer: peer))
        receiver.start(session: session, transport: transport)

        peer.emit(.failed)
        try await waitUntil {
            if case .failed = receiver.currentState { return true }
            return false
        }
        peer.emit(.closed)
        try await Task.sleep(for: .milliseconds(50))
        guard case .failed = receiver.currentState else {
            return XCTFail("A late peer callback replaced the terminal failure state")
        }
        receiver.close()
    }

    private var session: ComputerSession {
        ComputerSession(
            id: "session",
            clientRequestId: "request",
            ownerDeviceId: "device",
            hostInstallationId: "host",
            conversationId: "conversation",
            generation: 1,
            state: .preparing,
            source: ComputerSource(width: 1280, height: 720),
            geometryRevision: 0,
            failureReason: nil,
            createdAt: "now",
            updatedAt: "now",
            lastStateAt: "now",
            endedAt: nil,
            capability: ComputerCapability(available: true, action: "stream", reason: "available")
        )
    }

    private var offer: ComputerSignalingDescription {
        decode("{\"type\":\"offer\",\"sdp\":\"v=0\\r\\nm=video 9 UDP/TLS/RTP/SAVPF 96\\r\\na=sendonly\"}")
    }

    private func candidate(_ sequence: UInt64, sdpMLineIndex: UInt64 = 0) -> ComputerSignalingCandidate {
        decode("{\"sequence\":\(sequence),\"candidate\":\"candidate:\(sequence)\",\"sdpMid\":\"0\",\"sdpMLineIndex\":\(sdpMLineIndex),\"usernameFragment\":null}")
    }

    private func response(sessionID: String = "session", generation: UInt64 = 1,
                          peerRevision: String? = nil, nextCursor: UInt64 = 0,
                          candidates: [ComputerSignalingCandidate] = [],
                          offer: ComputerSignalingDescription? = nil,
                          state: String = "connecting") -> ComputerSignalingResponse {
        var object: [String: Any] = [
            "sessionId": sessionID,
            "generation": generation,
            "state": state,
            "captureState": "ready",
            "peerState": "new",
            "candidates": candidates.map { [
                "sequence": $0.sequence,
                "candidate": $0.candidate,
                "sdpMid": $0.sdpMid as Any,
                "sdpMLineIndex": $0.sdpMLineIndex,
                "usernameFragment": $0.usernameFragment as Any,
            ] },
            "cursor": 0,
            "nextCursor": nextCursor,
            "failureReason": NSNull(),
            "iceServers": [],
        ]
        object["peerRevision"] = peerRevision ?? NSNull()
        object["offer"] = offer.map { ["type": $0.type, "sdp": $0.sdp] } ?? NSNull()
        return try! JSONDecoder().decode(
            ComputerSignalingResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func decode<T: Decodable>(_ value: String) -> T {
        try! JSONDecoder().decode(T.self, from: Data(value.utf8))
    }

    private func waitUntil(timeout: TimeInterval = 1, _ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for deterministic receiver condition")
    }
}

private enum FakeTransportError: Error, Sendable { case unavailable }

private actor FakeTransport: ComputerSignalingTransport {
    enum Result: Sendable { case success(ComputerSignalingResponse); case failure }

    private var results: [Result]
    private let fallback: ComputerSignalingResponse
    private(set) var pollRequests: [ComputerSignalingPollRequest] = []
    private(set) var answerRequests: [ComputerSignalingAnswerRequest] = []
    private(set) var candidateRequests: [ComputerSignalingCandidateRequest] = []
    private(set) var closeRequests: [ComputerSignalingCloseRequest] = []

    init(responses: [Result], fallback: ComputerSignalingResponse? = nil) {
        self.results = responses
        self.fallback = fallback ?? (try! JSONDecoder().decode(
            ComputerSignalingResponse.self,
            from: Data("{\"sessionId\":\"session\",\"generation\":1,\"peerRevision\":\"peer-1\",\"state\":\"connecting\",\"captureState\":\"ready\",\"peerState\":\"new\",\"offer\":null,\"candidates\":[],\"cursor\":0,\"nextCursor\":0,\"failureReason\":null,\"iceServers\":[]}".utf8)
        ))
    }

    func poll(sessionID: String, request: ComputerSignalingPollRequest) async throws -> ComputerSignalingResponse {
        pollRequests.append(request)
        let result = results.isEmpty ? .success(fallback) : results.removeFirst()
        switch result {
        case .success(let response): return response
        case .failure: throw FakeTransportError.unavailable
        }
    }

    func submitAnswer(sessionID: String, request: ComputerSignalingAnswerRequest) async throws -> ComputerSignalingMutationResponse {
        answerRequests.append(request)
        return mutation()
    }

    func sendCandidate(sessionID: String, request: ComputerSignalingCandidateRequest) async throws -> ComputerSignalingMutationResponse {
        candidateRequests.append(request)
        return mutation()
    }

    func close(sessionID: String, request: ComputerSignalingCloseRequest) async throws -> ComputerSignalingMutationResponse {
        closeRequests.append(request)
        return mutation()
    }

    private func mutation() -> ComputerSignalingMutationResponse {
        try! JSONDecoder().decode(ComputerSignalingMutationResponse.self, from: Data("{\"accepted\":true}".utf8))
    }
}

private final class FakePeerFactory: ComputerPeerFactory, @unchecked Sendable {
    let peer: FakePeer

    init(peer: FakePeer) { self.peer = peer }
    func makePeer() -> ComputerPeer? { peer }
}

private final class FakePeer: ComputerPeer, @unchecked Sendable {
    var onLocalCandidate: ((ComputerLocalCandidate) -> Void)?
    var onStateChange: ((ComputerPeerState) -> Void)?
    var onVideoTrack: (() -> Void)?
    private(set) var acceptedOfferCount = 0
    private(set) var remoteOfferAccepted = false
    private(set) var addedSequences: [UInt64] = []
    private(set) var clearRendererCount = 0
    private(set) var closed = false

    func acceptOffer(_ sdp: String) async throws -> String {
        acceptedOfferCount += 1
        remoteOfferAccepted = true
        return #"v=0\r\na=answer"#
    }

    func addRemoteCandidate(_ candidate: ComputerSignalingCandidate) {
        addedSequences.append(candidate.sequence)
    }

    func attach(renderer: RTCVideoRenderer) {}
    func detach(renderer: RTCVideoRenderer) {}
    func clearRenderer() { clearRendererCount += 1 }
    func close() { closed = true }

    func emit(_ state: ComputerPeerState) { onStateChange?(state) }
    func emitVideoTrack() { onVideoTrack?() }
    func emitLocalCandidate() {
        onLocalCandidate?(ComputerLocalCandidate(sdp: "candidate:local", sdpMid: "0", sdpMLineIndex: 0))
    }
}
