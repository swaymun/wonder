import Foundation
@preconcurrency import WebRTC
import WonderPairing

public enum ComputerReceiverState: Equatable, Sendable {
    case preparing
    case awaitingSource
    case connecting
    case live
    case retrying(String)
    case failed(String)
    case closed

    public var title: String {
        switch self {
        case .preparing: "Preparing"
        case .awaitingSource: "Choose a source on your Mac"
        case .connecting: "Connecting"
        case .live: "Live"
        case .retrying: "Retrying"
        case .failed: "Couldn’t connect"
        case .closed: "Closed"
        }
    }

    public var message: String {
        switch self {
        case .preparing: "Preparing a live computer view…"
        case .awaitingSource: "Choose what to share in Wonder on your Mac."
        case .connecting: "Connecting to your Mac…"
        case .live: "Live computer view"
        case .retrying(let reason): reason
        case .failed(let reason): reason
        case .closed: "Computer view closed"
        }
    }
}

public protocol ComputerSignalingTransport: Sendable {
    func poll(sessionID: String, request: ComputerSignalingPollRequest) async throws -> ComputerSignalingResponse
    func submitAnswer(sessionID: String, request: ComputerSignalingAnswerRequest) async throws -> ComputerSignalingMutationResponse
    func sendCandidate(sessionID: String, request: ComputerSignalingCandidateRequest) async throws -> ComputerSignalingMutationResponse
    func close(sessionID: String, request: ComputerSignalingCloseRequest) async throws -> ComputerSignalingMutationResponse
}

struct ComputerLocalCandidate: Sendable {
    let sdp: String
    let sdpMid: String?
    let sdpMLineIndex: UInt32
}

enum ComputerPeerState: Sendable {
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

protocol ComputerPeer: AnyObject {
    var onLocalCandidate: ((ComputerLocalCandidate) -> Void)? { get set }
    var onStateChange: ((ComputerPeerState) -> Void)? { get set }
    var onVideoTrack: (() -> Void)? { get set }

    func acceptOffer(_ sdp: String) async throws -> String
    func addRemoteCandidate(_ candidate: ComputerSignalingCandidate)
    func attach(renderer: RTCVideoRenderer)
    func detach(renderer: RTCVideoRenderer)
    func clearRenderer()
    func close()
}

protocol ComputerPeerFactory: Sendable {
    func makePeer() -> ComputerPeer?
}

private struct WebRTCPeerFactory: ComputerPeerFactory, Sendable {
    func makePeer() -> ComputerPeer? { WebRTCPeer.make() }
}

private enum ComputerPeerError: LocalizedError {
    case invalidOffer
    case unavailable
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidOffer: "The Mac sent an unsupported computer stream offer."
        case .unavailable: "The computer stream is unavailable."
        case .operationFailed(let reason): reason
        }
    }
}

/// The iOS answerer for the authenticated, LAN-only Mac publisher.
///
/// This type owns no input or data channel and keeps network/WebRTC work off
/// the caller's actor. A generation token makes every callback from an old
/// peer harmless after a replacement or dismissal.
public final class ComputerReceiver: @unchecked Sendable {
    public var onStateChange: ((ComputerReceiverState, UInt64) -> Void)?

    private struct Identity: Equatable, Sendable {
        let token: UUID
        let sessionID: String
        let generation: UInt64
        let conversationID: String
        let hostInstallationID: String
        var peerRevision: String?
    }

    private let lock = NSLock()
    private let peerFactory: any ComputerPeerFactory
    private var identity: Identity?
    private var peer: (any ComputerPeer)?
    private var transport: (any ComputerSignalingTransport)?
    private var pollTask: Task<Void, Never>?
    private var state: ComputerReceiverState = .closed
    private var stateRevision: UInt64 = 0
    private var remoteDescriptionSet = false
    private var hostState = "preparing"
    private var peerConnected = false
    private var videoTrackAvailable = false
    private var pendingRemoteCandidates: [UInt64: ComputerSignalingCandidate] = [:]
    private var seenRemoteCandidates: [UInt64: ComputerSignalingCandidate] = [:]
    private var localCandidates: [UInt64: ComputerLocalCandidate] = [:]
    private var sentLocalCandidateSequences: Set<UInt64> = []
    private var nextLocalCandidateSequence: UInt64 = 0
    private var renderer: RTCVideoRenderer?

    public init() {
        peerFactory = WebRTCPeerFactory()
    }

    internal init(peerFactory: any ComputerPeerFactory) {
        self.peerFactory = peerFactory
    }

    public var currentState: ComputerReceiverState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func start(session: ComputerSession, transport: any ComputerSignalingTransport) {
        reset(reason: "replaced", publishClosed: false)
        guard session.capability.available else {
            publish(.failed(session.capability.reason))
            return
        }

        let token = UUID()
        guard let peer = peerFactory.makePeer() else {
            publish(.failed("The computer stream could not start on this device."))
            return
        }
        let identity = Identity(
            token: token,
            sessionID: session.id,
            generation: session.generation,
            conversationID: session.conversationId,
            hostInstallationID: session.hostInstallationId,
            peerRevision: nil
        )
        peer.onLocalCandidate = { [weak self] candidate in
            self?.recordLocalCandidate(candidate, token: token)
        }
        peer.onStateChange = { [weak self] state in
            self?.peerStateChanged(state, token: token)
        }
        peer.onVideoTrack = { [weak self] in
            self?.videoTrackReceived(token: token)
        }

        lock.lock()
        self.identity = identity
        self.peer = peer
        self.transport = transport
        self.remoteDescriptionSet = false
        self.hostState = "preparing"
        self.peerConnected = false
        self.videoTrackAvailable = false
        self.pendingRemoteCandidates.removeAll(keepingCapacity: true)
        self.seenRemoteCandidates.removeAll(keepingCapacity: true)
        self.localCandidates.removeAll(keepingCapacity: true)
        self.sentLocalCandidateSequences.removeAll(keepingCapacity: true)
        self.nextLocalCandidateSequence = 0
        lock.unlock()

        publish(.preparing)
        pollTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.pollLoop(session: session, token: token, peer: peer, transport: transport)
        }
    }

    public func close(reason: String = "closed_by_viewer") {
        reset(reason: reason, publishClosed: true)
    }

    private func reset(reason: String, publishClosed: Bool) {
        lock.lock()
        let oldIdentity = identity
        let oldTransport = transport
        let oldPeer = peer
        let oldRenderer = renderer
        pollTask?.cancel()
        pollTask = nil
        identity = nil
        peer = nil
        transport = nil
        renderer = nil
        remoteDescriptionSet = false
        hostState = "preparing"
        peerConnected = false
        videoTrackAvailable = false
        pendingRemoteCandidates.removeAll(keepingCapacity: true)
        seenRemoteCandidates.removeAll(keepingCapacity: true)
        localCandidates.removeAll(keepingCapacity: true)
        sentLocalCandidateSequences.removeAll(keepingCapacity: true)
        nextLocalCandidateSequence = 0
        lock.unlock()

        oldRenderer?.renderFrame(nil)
        oldPeer?.clearRenderer()
        if let oldPeer { oldPeer.close() }
        if publishClosed { publish(.closed) }

        guard let oldIdentity, let oldTransport, let peerRevision = oldIdentity.peerRevision,
              let request = ComputerSignalingCloseRequest(
                binding: ComputerSignalingBinding(
                    generation: oldIdentity.generation,
                    conversationId: oldIdentity.conversationID,
                    hostInstallationId: oldIdentity.hostInstallationID,
                    peerRevision: peerRevision
                ), reason: reason
              ) else { return }
        Task.detached(priority: .utility) {
            _ = try? await oldTransport.close(sessionID: oldIdentity.sessionID, request: request)
        }
    }

    internal func attach(renderer: RTCVideoRenderer) {
        lock.lock()
        if self.renderer === renderer {
            lock.unlock()
            return
        }
        let oldRenderer = self.renderer
        self.renderer = renderer
        let peer = self.peer
        lock.unlock()
        oldRenderer?.renderFrame(nil)
        if let peer { peer.attach(renderer: renderer) }
    }

    internal func detach(renderer: RTCVideoRenderer) {
        lock.lock()
        guard self.renderer === renderer else {
            lock.unlock()
            return
        }
        self.renderer = nil
        let peer = self.peer
        lock.unlock()
        peer?.detach(renderer: renderer)
        renderer.renderFrame(nil)
    }

    private func pollLoop(session: ComputerSession, token: UUID, peer: any ComputerPeer,
                          transport: any ComputerSignalingTransport) async {
        var cursor: UInt64 = 0
        var retries = 0
        var pendingAnswer: String?
        var remoteOfferSDP: String?
        var staleResponseCount = 0

        while !Task.isCancelled, isCurrent(token: token) {
            if case .failed = currentState { return }
            if case .closed = currentState { return }
            do {
                let binding = currentBinding(session: session, token: token)
                let response = try await transport.poll(
                    sessionID: session.id,
                    request: ComputerSignalingPollRequest(binding: binding, cursor: cursor)
                )
                guard isCurrent(token: token), response.sessionId == session.id,
                      response.generation == session.generation else {
                    staleResponseCount += 1
                    if staleResponseCount > 6 {
                        fail("The computer view changed on your Mac. Close this screen and try again.", token: token, peer: peer)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                staleResponseCount = 0
                retries = 0

                if let revision = response.peerRevision {
                    guard adoptPeerRevision(revision, token: token) else {
                        // A response from an old/replaced publisher must not
                        // alter this peer or move its stateless cursor.
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                }
                if !response.iceServers.isEmpty {
                    fail("This computer view requires a direct local connection.", token: token, peer: peer)
                    return
                }
                if response.state == "failed" {
                    fail(response.failureReason ?? "The Mac computer stream failed.", token: token, peer: peer)
                    return
                }
                if response.state == "closed" {
                    finishClosed(token: token, peer: peer)
                    return
                }
                updateHostState(response.state, token: token)

                if let offer = response.offer {
                    guard offer.type == "offer" else {
                        fail("The Mac sent an invalid computer stream offer.", token: token, peer: peer)
                        return
                    }
                    guard currentBinding(session: session, token: token).peerRevision != nil else {
                        fail("The Mac sent an incomplete computer stream offer.", token: token, peer: peer)
                        return
                    }
                    if let remoteOfferSDP, remoteOfferSDP != offer.sdp {
                        fail("The computer stream changed while connecting. Try again.", token: token, peer: peer)
                        return
                    }
                    if remoteOfferSDP == nil {
                        do {
                            pendingAnswer = try await peer.acceptOffer(offer.sdp)
                            remoteOfferSDP = offer.sdp
                            markRemoteDescriptionSet(token: token, peer: peer)
                        } catch {
                            fail(error.localizedDescription, token: token, peer: peer)
                            return
                        }
                    }
                }

                for candidate in response.candidates {
                    receiveRemoteCandidate(candidate, token: token, peer: peer)
                }

                if let answer = pendingAnswer {
                    guard let request = ComputerSignalingAnswerRequest(
                        binding: currentBinding(session: session, token: token), sdp: answer
                    ) else { return }
                    do {
                        let result = try await transport.submitAnswer(sessionID: session.id, request: request)
                        guard result.accepted else { throw ComputerPeerError.operationFailed("The Mac did not accept the stream answer.") }
                        pendingAnswer = nil
                    } catch {
                        publish(.retrying("Connecting to your Mac…"), token: token)
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                }

                try await sendPendingLocalCandidates(session: session, token: token, transport: transport)
                cursor = max(cursor, response.nextCursor)
                let delay: Duration = currentState == .live ? .milliseconds(500) : .milliseconds(150)
                try await Task.sleep(for: delay)
            } catch is CancellationError {
                return
            } catch {
                retries += 1
                if retries > 6 {
                    fail("The Mac could not be reached. Check that Wonder is running on the same local network, then try again.", token: token, peer: peer)
                    return
                }
                let seconds = min(4.0, 0.25 * pow(2.0, Double(retries - 1)))
                publish(.retrying("The Mac could not be reached. Retrying…"), token: token)
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    private func currentBinding(session: ComputerSession, token: UUID) -> ComputerSignalingBinding {
        lock.lock()
        let revision = identity?.token == token ? identity?.peerRevision : nil
        lock.unlock()
        return ComputerSignalingBinding(
            generation: session.generation,
            conversationId: session.conversationId,
            hostInstallationId: session.hostInstallationId,
            peerRevision: revision
        )
    }

    private func adoptPeerRevision(_ revision: String, token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard identity?.token == token else { return false }
        guard revision.utf8.count <= 128, !revision.isEmpty else { return false }
        if let current = identity?.peerRevision { return current == revision }
        identity?.peerRevision = revision
        return true
    }

    private func recordLocalCandidate(_ candidate: ComputerLocalCandidate, token: UUID) {
        guard candidate.sdp.hasPrefix("candidate:"), candidate.sdp.utf8.count <= 4 * 1024 else { return }
        lock.lock()
        guard identity?.token == token, nextLocalCandidateSequence < 128 else {
            lock.unlock()
            return
        }
        nextLocalCandidateSequence += 1
        localCandidates[nextLocalCandidateSequence] = candidate
        lock.unlock()
    }

    private func sendPendingLocalCandidates(session: ComputerSession, token: UUID,
                                            transport: any ComputerSignalingTransport) async throws {
        let pending: [(UInt64, ComputerLocalCandidate, ComputerSignalingCandidateRequest)] = {
            lock.lock()
            defer { lock.unlock() }
            guard identity?.token == token, let peerRevision = identity?.peerRevision else { return [] }
            return localCandidates.keys.sorted().compactMap { sequence in
                guard !sentLocalCandidateSequences.contains(sequence), let candidate = localCandidates[sequence],
                      let request = ComputerSignalingCandidateRequest(
                        binding: ComputerSignalingBinding(
                            generation: session.generation,
                            conversationId: session.conversationId,
                            hostInstallationId: session.hostInstallationId,
                            peerRevision: peerRevision
                        ), sequence: sequence, candidate: candidate.sdp,
                        sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex
                      ) else { return nil }
                return (sequence, candidate, request)
            }
        }()
        for (sequence, _, request) in pending {
            let result = try await transport.sendCandidate(sessionID: session.id, request: request)
            guard result.accepted else { throw ComputerPeerError.operationFailed("The Mac did not accept an ICE candidate.") }
            markLocalCandidateSent(sequence, token: token)
        }
    }

    private func markLocalCandidateSent(_ sequence: UInt64, token: UUID) {
        lock.lock()
        if identity?.token == token { sentLocalCandidateSequences.insert(sequence) }
        lock.unlock()
    }

    private func receiveRemoteCandidate(_ candidate: ComputerSignalingCandidate, token: UUID, peer: any ComputerPeer) {
        guard candidate.sequence > 0, candidate.sequence <= 128,
              candidate.candidate.hasPrefix("candidate:"), candidate.candidate.utf8.count <= 4 * 1024,
              candidate.sdpMLineIndex <= UInt32(Int32.max) else { return }
        lock.lock()
        guard identity?.token == token else {
            lock.unlock()
            return
        }
        if let existing = seenRemoteCandidates[candidate.sequence] {
            lock.unlock()
            if existing != candidate {
                fail("The Mac sent conflicting computer connection data.", token: token, peer: peer)
            }
            return
        }
        seenRemoteCandidates[candidate.sequence] = candidate
        if remoteDescriptionSet {
            lock.unlock()
            peer.addRemoteCandidate(candidate)
        } else {
            pendingRemoteCandidates[candidate.sequence] = candidate
            lock.unlock()
        }
    }

    private func markRemoteDescriptionSet(token: UUID, peer: any ComputerPeer) {
        lock.lock()
        guard identity?.token == token else {
            lock.unlock()
            return
        }
        remoteDescriptionSet = true
        let pending = pendingRemoteCandidates.values.sorted { $0.sequence < $1.sequence }
        pendingRemoteCandidates.removeAll(keepingCapacity: true)
        lock.unlock()
        for candidate in pending { peer.addRemoteCandidate(candidate) }
    }

    private func peerStateChanged(_ state: ComputerPeerState, token: UUID) {
        guard isCurrent(token: token) else { return }
        switch currentState {
        case .failed, .closed: return
        default: break
        }
        switch state {
        case .connecting:
            setPeerConnected(false, token: token)
            recomputePresentationState(token: token)
        case .connected:
            setPeerConnected(true, token: token)
            recomputePresentationState(token: token)
        case .disconnected:
            setPeerConnected(false, token: token)
            clearRenderer(token: token)
            publish(.retrying("The connection to your Mac was interrupted. Retrying…"), token: token)
        case .failed:
            clearRenderer(token: token)
            publish(.failed("The connection to your Mac failed. Check the local network and try again."), token: token)
        case .closed:
            clearRenderer(token: token)
            publish(.closed, token: token)
        }
    }

    private func videoTrackReceived(token: UUID) {
        guard isCurrent(token: token) else { return }
        switch currentState {
        case .failed, .closed: return
        default: break
        }
        lock.lock()
        if identity?.token == token { videoTrackAvailable = true }
        lock.unlock()
        recomputePresentationState(token: token)
    }

    private func updateHostState(_ next: String, token: UUID) {
        lock.lock()
        guard identity?.token == token else {
            lock.unlock()
            return
        }
        hostState = next
        lock.unlock()
        recomputePresentationState(token: token)
    }

    private func setPeerConnected(_ connected: Bool, token: UUID) {
        lock.lock()
        if identity?.token == token { peerConnected = connected }
        lock.unlock()
    }

    private func recomputePresentationState(token: UUID) {
        lock.lock()
        guard identity?.token == token else {
            lock.unlock()
            return
        }
        let hostState = self.hostState
        let canShowLive = peerConnected && videoTrackAvailable
        lock.unlock()
        switch hostState {
        case "awaitingSource": publish(.awaitingSource, token: token)
        case "preparing": publish(.preparing, token: token)
        case "live" where canShowLive: publish(.live, token: token)
        default: publish(.connecting, token: token)
        }
    }

    private func clearRenderer(token: UUID) {
        lock.lock()
        guard identity?.token == token, let peer else {
            lock.unlock()
            return
        }
        lock.unlock()
        peer.clearRenderer()
    }

    private func fail(_ message: String, token: UUID, peer: any ComputerPeer) {
        guard isCurrent(token: token) else { return }
        publish(.failed(message), token: token)
        peer.clearRenderer()
        peer.close()
    }

    private func finishClosed(token: UUID, peer: any ComputerPeer) {
        guard isCurrent(token: token) else { return }
        publish(.closed, token: token)
        peer.clearRenderer()
        peer.close()
    }

    private func isCurrent(token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return identity?.token == token
    }

    private func publish(_ next: ComputerReceiverState, token: UUID? = nil) {
        lock.lock()
        if let token, identity?.token != token {
            lock.unlock()
            return
        }
        guard state != next else {
            lock.unlock()
            return
        }
        state = next
        stateRevision += 1
        let revision = stateRevision
        let callback = onStateChange
        lock.unlock()
        callback?(next, revision)
    }
}

private final class WebRTCPeer: NSObject, ComputerPeer, RTCPeerConnectionDelegate, @unchecked Sendable {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private let lock = NSLock()
    private let peerConnection: RTCPeerConnection
    private var videoTrack: RTCVideoTrack?
    private var renderer: RTCVideoRenderer?

    var onLocalCandidate: ((ComputerLocalCandidate) -> Void)?
    var onStateChange: ((ComputerPeerState) -> Void)?
    var onVideoTrack: (() -> Void)?

    static func make() -> WebRTCPeer? {
        let configuration = RTCConfiguration()
        configuration.iceServers = []
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue]
        )
        return WebRTCPeer(configuration: configuration, constraints: constraints)
    }

    private init?(configuration: RTCConfiguration, constraints: RTCMediaConstraints) {
        guard let peer = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else { return nil }
        peerConnection = peer
        super.init()
        peer.delegate = self
    }

    func acceptOffer(_ sdp: String) async throws -> String {
        guard sdp.utf8.count <= 64 * 1024, sdp.hasPrefix("v=0"), sdp.contains("m=video"),
              !sdp.contains("m=audio"), !sdp.contains("m=application") else {
            throw ComputerPeerError.invalidOffer
        }
        try await setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp))
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue],
            optionalConstraints: nil
        )
        let answer = try await createAnswer(constraints: constraints)
        try await setLocalDescription(answer)
        return answer.sdp
    }

    func addRemoteCandidate(_ candidate: ComputerSignalingCandidate) {
        let ice = RTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: Int32(candidate.sdpMLineIndex),
            sdpMid: candidate.sdpMid
        )
        peerConnection.add(ice) { _ in }
    }

    func attach(renderer: RTCVideoRenderer) {
        lock.lock()
        if self.renderer === renderer {
            lock.unlock()
            return
        }
        let old = self.renderer
        self.renderer = renderer
        let track = videoTrack
        lock.unlock()
        old.map { track?.remove($0) }
        if let track { track.add(renderer) }
    }

    func detach(renderer: RTCVideoRenderer) {
        lock.lock()
        guard self.renderer === renderer else {
            lock.unlock()
            return
        }
        self.renderer = nil
        let track = videoTrack
        lock.unlock()
        track?.remove(renderer)
    }

    func clearRenderer() {
        lock.lock()
        let current = renderer
        lock.unlock()
        current?.renderFrame(nil)
    }

    func close() {
        lock.lock()
        let currentRenderer = renderer
        let currentTrack = videoTrack
        renderer = nil
        videoTrack = nil
        lock.unlock()
        if let currentRenderer { currentTrack?.remove(currentRenderer) }
        currentRenderer?.renderFrame(nil)
        peerConnection.close()
    }

    private func setRemoteDescription(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private func createAnswer(constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.answer(for: constraints) { answer, error in
                if let error { continuation.resume(throwing: error) }
                else if let answer { continuation.resume(returning: answer) }
                else { continuation.resume(throwing: ComputerPeerError.unavailable) }
            }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let state: ComputerPeerState
        switch newState {
        case .new, .checking: state = .connecting
        case .connected, .completed: state = .connected
        case .disconnected: state = .disconnected
        case .failed: state = .failed
        case .closed: state = .closed
        case .count: return
        @unknown default: return
        }
        onStateChange?(state)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard candidate.sdp.hasPrefix("candidate:"), candidate.sdp.utf8.count <= 4 * 1024,
              candidate.sdpMLineIndex >= 0 else { return }
        onLocalCandidate?(ComputerLocalCandidate(
            sdp: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: UInt32(candidate.sdpMLineIndex)
        ))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.close()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                        streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        lock.lock()
        videoTrack = track
        let currentRenderer = renderer
        lock.unlock()
        if let currentRenderer { track.add(currentRenderer) }
        onVideoTrack?()
    }
}
