import Foundation
import WonderRelayFFI

public struct RelayContext: Sendable, Equatable {
    public let hostIdentity: String
    public let deviceIdentity: String
    public let routingIdentity: String

    public init(hostIdentity: String, deviceIdentity: String, routingIdentity: String) throws {
        guard !hostIdentity.isEmpty, !deviceIdentity.isEmpty, !routingIdentity.isEmpty,
              hostIdentity.utf8.count <= 4096, deviceIdentity.utf8.count <= 4096,
              routingIdentity.utf8.count <= 4096 else { throw RelayError.invalidContext }
        self.hostIdentity = hostIdentity
        self.deviceIdentity = deviceIdentity
        self.routingIdentity = routingIdentity
    }
}

public final class RelayInitiator: @unchecked Sendable {
    private var raw: UnsafeMutableRawPointer?
    private let lock = NSLock()

    private init(raw: UnsafeMutableRawPointer) { self.raw = raw }

    public static func start(localPrivateKey: Data, peerPublicKey: Data, context: RelayContext) throws -> (initiator: RelayInitiator, message: Data) {
        try validateKeys(localPrivateKey, peerPublicKey)
        var initiator: UnsafeMutableRawPointer?
        var message = Data(repeating: 0, count: 1024)
        var messageLength = 0
        let status = try withInputs(localPrivateKey, peerPublicKey, context) { local, peer, host, device, route in
            message.withUnsafeMutableBytes { destination in
                wonder_relay_initiator_start(
                    local, 32, peer, 32,
                    host, context.hostIdentity.utf8.count,
                    device, context.deviceIdentity.utf8.count,
                    route, context.routingIdentity.utf8.count,
                    &initiator, destination.bindMemory(to: UInt8.self).baseAddress, destination.count, &messageLength
                )
            }
        }
        if status != Int32(WONDER_RELAY_OK) {
            if let initiator { wonder_relay_initiator_free(initiator) }
            try check(status)
        }
        guard let initiator else { throw RelayError.internalError(-1) }
        guard (1...message.count).contains(messageLength) else {
            wonder_relay_initiator_free(initiator)
            throw RelayError.invalidOutput
        }
        message.removeSubrange(messageLength..<message.count)
        return (RelayInitiator(raw: initiator), message)
    }

    public func finish(_ message: Data) throws -> RelaySession {
        guard message.count <= 1024, !message.isEmpty else { throw RelayError.invalidHandshakeMessage }
        return try withLock { raw in
            var session: UnsafeMutableRawPointer?
            let status = message.withUnsafeBytes { bytes in
                wonder_relay_initiator_finish(raw, bytes.bindMemory(to: UInt8.self).baseAddress, message.count, &session)
            }
            // `finish` mirrors Rust's consuming Initiator::finish API. The
            // FFI consumes this pointer on both success and failure.
            self.raw = nil
            if status != Int32(WONDER_RELAY_OK), let session { wonder_relay_session_free(session) }
            try check(status)
            guard let session else { throw RelayError.internalError(-1) }
            return RelaySession(raw: session)
        }
    }

    deinit { if let raw { wonder_relay_initiator_free(raw) } }

    private func withLock<T>(_ body: (UnsafeMutableRawPointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let raw else { throw RelayError.invalidState }
        return try body(raw)
    }
}

public enum RelayResponder {
    public static func accept(localPrivateKey: Data, peerPublicKey: Data, context: RelayContext, message: Data) throws -> (response: Data, session: RelaySession) {
        try validateKeys(localPrivateKey, peerPublicKey)
        guard message.count <= 1024, !message.isEmpty else { throw RelayError.invalidHandshakeMessage }
        var session: UnsafeMutableRawPointer?
        var response = Data(repeating: 0, count: 1024)
        var responseLength = 0
        let status = try withInputs(localPrivateKey, peerPublicKey, context) { local, peer, host, device, route in
            message.withUnsafeBytes { incoming in
                response.withUnsafeMutableBytes { outgoing in
                    wonder_relay_responder_accept(
                        local, 32, peer, 32,
                        host, context.hostIdentity.utf8.count,
                        device, context.deviceIdentity.utf8.count,
                        route, context.routingIdentity.utf8.count,
                        incoming.bindMemory(to: UInt8.self).baseAddress, message.count,
                        outgoing.bindMemory(to: UInt8.self).baseAddress, outgoing.count, &responseLength,
                        &session
                    )
                }
            }
        }
        if status != Int32(WONDER_RELAY_OK) {
            if let session { wonder_relay_session_free(session) }
            try check(status)
        }
        guard let session else { throw RelayError.internalError(-1) }
        guard (1...response.count).contains(responseLength) else {
            wonder_relay_session_free(session)
            throw RelayError.invalidOutput
        }
        response.removeSubrange(responseLength..<response.count)
        return (response, RelaySession(raw: session))
    }
}

public final class RelaySession: @unchecked Sendable {
    private var raw: UnsafeMutableRawPointer?
    private var poisoned = false
    private let lock = NSLock()

    fileprivate init(raw: UnsafeMutableRawPointer) { self.raw = raw }
    deinit { if let raw { wonder_relay_session_free(raw) } }

    public func sealFrame(_ payload: Data) throws -> Data {
        guard payload.count <= 65535 - 4 - 16 else { throw RelayError.messageTooLarge }
        return try withLock { raw in
            var frame = Data(repeating: 0, count: 65535)
            let capacity = frame.count
            var frameLength = 0
            try frame.withUnsafeMutableBytes { destination in
                try payload.withUnsafeBytes { source in
                    try check(wonder_relay_seal_frame(raw, source.bindMemory(to: UInt8.self).baseAddress, payload.count, destination.bindMemory(to: UInt8.self).baseAddress, capacity, &frameLength))
                }
            }
            guard (1...frame.count).contains(frameLength) else { throw RelayError.invalidOutput }
            frame.removeSubrange(frameLength..<frame.count)
            return frame
        }
    }

    public func openFrame(_ frame: Data) throws -> Data {
        guard frame.count <= 65535 else {
            lock.lock(); poisoned = true; lock.unlock()
            throw RelayError.messageTooLarge
        }
        return try withLock { raw in
            var payload = Data(repeating: 0, count: 65535)
            let capacity = payload.count
            var payloadLength = 0
            try payload.withUnsafeMutableBytes { destination in
                try frame.withUnsafeBytes { source in
                    do {
                        try check(wonder_relay_open_frame(raw, source.bindMemory(to: UInt8.self).baseAddress, frame.count, destination.bindMemory(to: UInt8.self).baseAddress, capacity, &payloadLength))
                    } catch {
                        poisoned = true
                        throw error
                    }
                }
            }
            guard (0...payload.count).contains(payloadLength) else {
                poisoned = true
                throw RelayError.invalidOutput
            }
            payload.removeSubrange(payloadLength..<payload.count)
            return payload
        }
    }

    private func withLock<T>(_ body: (UnsafeMutableRawPointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !poisoned else { throw RelayError.invalidState }
        guard let raw else { throw RelayError.invalidState }
        return try body(raw)
    }
}

private func validateKeys(_ local: Data, _ peer: Data) throws {
    guard local.count == 32, peer.count == 32 else { throw RelayError.invalidKey }
}

private func withInputs<T>(_ local: Data, _ peer: Data, _ context: RelayContext, _ body: (UnsafePointer<UInt8>, UnsafePointer<UInt8>, UnsafePointer<UInt8>, UnsafePointer<UInt8>, UnsafePointer<UInt8>) throws -> T) throws -> T {
    let host = Data(context.hostIdentity.utf8)
    let device = Data(context.deviceIdentity.utf8)
    let route = Data(context.routingIdentity.utf8)
    return try local.withUnsafeBytes { localBytes in
        try peer.withUnsafeBytes { peerBytes in
            try host.withUnsafeBytes { hostBytes in
                try device.withUnsafeBytes { deviceBytes in
                    try route.withUnsafeBytes { routeBytes in
                        try body(localBytes.bindMemory(to: UInt8.self).baseAddress!, peerBytes.bindMemory(to: UInt8.self).baseAddress!, hostBytes.bindMemory(to: UInt8.self).baseAddress!, deviceBytes.bindMemory(to: UInt8.self).baseAddress!, routeBytes.bindMemory(to: UInt8.self).baseAddress!)
                    }
                }
            }
        }
    }
}
