import Foundation
import WonderRelayFFI

public enum RelayError: Error, Equatable, Sendable {
    case invalidArgument
    case invalidKey
    case invalidState
    case bufferTooSmall
    case authenticationFailed
    case messageTooLarge
    case invalidFrame
    case invalidHandshakeMessage
    case invalidContext
    case invalidRequest
    case invalidOutput
    case internalError(Int32)

    init(status: Int32) {
        switch status {
        case Int32(WONDER_RELAY_INVALID_ARGUMENT): self = .invalidArgument
        case Int32(WONDER_RELAY_INVALID_KEY): self = .invalidKey
        case Int32(WONDER_RELAY_INVALID_STATE): self = .invalidState
        case Int32(WONDER_RELAY_BUFFER_TOO_SMALL): self = .bufferTooSmall
        case Int32(WONDER_RELAY_AUTHENTICATION_FAILED): self = .authenticationFailed
        case Int32(WONDER_RELAY_MESSAGE_TOO_LARGE): self = .messageTooLarge
        case Int32(WONDER_RELAY_INVALID_FRAME): self = .invalidFrame
        default: self = .internalError(status)
        }
    }
}

@inline(__always)
func check(_ status: Int32) throws {
    guard status == Int32(WONDER_RELAY_OK) else { throw RelayError(status: status) }
}
