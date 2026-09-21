import Foundation

public enum ComputerSessionState: String, Codable, Sendable, CaseIterable, Equatable {
    case preparing
    case awaitingSource
    case live
    case paused
    case stale
    case ended
    case failed
    case unavailable

    public var title: String {
        switch self {
        case .preparing: "Preparing"
        case .awaitingSource: "Choose a source on your Mac"
        case .live: "Live"
        case .paused: "Paused"
        case .stale: "Stale"
        case .ended: "Ended"
        case .failed: "Couldn’t connect"
        case .unavailable: "Unavailable"
        }
    }
}

public struct ComputerCapability: Codable, Equatable, Sendable {
    public let available: Bool
    public let action: String
    public let reason: String

    public init(available: Bool, action: String, reason: String) {
        self.available = available
        self.action = action
        self.reason = reason
    }

    public static let oldHost = Self(
        available: false,
        action: "update-host",
        reason: "Computer viewing needs a newer Wonder host. Update Wonder on your Mac, then try again."
    )
}

public struct ComputerControlCapability: Codable, Equatable, Sendable {
    public let available: Bool
    public let action: String
    public let reason: String
    public let heartbeatIntervalSeconds: UInt64
    public let leaseExpirySeconds: UInt64

    public init(available: Bool, action: String, reason: String,
                heartbeatIntervalSeconds: UInt64 = 3, leaseExpirySeconds: UInt64 = 10) {
        self.available = available
        self.action = action
        self.reason = reason
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.leaseExpirySeconds = leaseExpirySeconds
    }

    public static let unavailable = Self(
        available: false,
        action: "update-host",
        reason: "Take control is unavailable until a verified computer provider is configured on this Mac."
    )
}

public struct ComputerSource: Codable, Equatable, Sendable {
    public let id: String?
    public let name: String?
    public let kind: String?
    public let width: UInt32?
    public let height: UInt32?
    public let scale: Double?
    public let crop: ComputerCrop?

    public init(id: String? = nil, name: String? = nil, kind: String? = nil, width: UInt32? = nil,
                height: UInt32? = nil, scale: Double? = nil, crop: ComputerCrop? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.width = width
        self.height = height; self.scale = scale; self.crop = crop
    }

    public static let unknown = Self()
}

public struct ComputerCrop: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ComputerSession: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let clientRequestId: String
    public let ownerDeviceId: String
    public let hostInstallationId: String
    public let conversationId: String
    public let generation: UInt64
    public let state: ComputerSessionState
    public let source: ComputerSource
    public let geometryRevision: UInt64
    public let failureReason: String?
    public let createdAt: String
    public let updatedAt: String
    public let lastStateAt: String
    public let endedAt: String?
    public let capability: ComputerCapability
    public let control: ComputerControlCapability?

    public init(id: String, clientRequestId: String, ownerDeviceId: String, hostInstallationId: String,
                conversationId: String, generation: UInt64, state: ComputerSessionState,
                source: ComputerSource, geometryRevision: UInt64, failureReason: String?,
                createdAt: String, updatedAt: String, lastStateAt: String, endedAt: String?,
                capability: ComputerCapability, control: ComputerControlCapability? = .unavailable) {
        self.id = id; self.clientRequestId = clientRequestId; self.ownerDeviceId = ownerDeviceId
        self.hostInstallationId = hostInstallationId; self.conversationId = conversationId
        self.generation = generation; self.state = state; self.source = source
        self.geometryRevision = geometryRevision; self.failureReason = failureReason
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.lastStateAt = lastStateAt
        self.endedAt = endedAt; self.capability = capability; self.control = control
    }
}

public struct StartComputerSessionRequest: Encodable, Sendable {
    public let clientRequestId: String
    public let conversationId: String
    public let hostInstallationId: String
    public let generation: UInt64
    public let source: ComputerSource?

    public init(clientRequestId: String, conversationId: String, hostInstallationId: String,
                generation: UInt64 = 1, source: ComputerSource? = nil) {
        self.clientRequestId = clientRequestId; self.conversationId = conversationId
        self.hostInstallationId = hostInstallationId; self.generation = generation; self.source = source
    }
}

public struct ComputerSignalingBinding: Encodable, Sendable {
    public let generation: UInt64
    public let conversationId: String
    public let hostInstallationId: String
    public let peerRevision: String?

    public init(generation: UInt64, conversationId: String, hostInstallationId: String,
                peerRevision: String? = nil) {
        self.generation = generation
        self.conversationId = conversationId
        self.hostInstallationId = hostInstallationId
        self.peerRevision = peerRevision
    }
}

public struct ComputerSignalingPollRequest: Encodable, Sendable {
    public let generation: UInt64
    public let conversationId: String
    public let hostInstallationId: String
    public let peerRevision: String?
    public let cursor: UInt64

    public init(binding: ComputerSignalingBinding, cursor: UInt64 = 0) {
        generation = binding.generation
        conversationId = binding.conversationId
        hostInstallationId = binding.hostInstallationId
        peerRevision = binding.peerRevision
        self.cursor = cursor
    }
}

public struct ComputerSignalingAnswerRequest: Encodable, Sendable {
    public let generation: UInt64
    public let conversationId: String
    public let hostInstallationId: String
    public let peerRevision: String
    public let type: String
    public let sdp: String

    public init?(binding: ComputerSignalingBinding, sdp: String) {
        guard let peerRevision = binding.peerRevision else { return nil }
        generation = binding.generation
        conversationId = binding.conversationId
        hostInstallationId = binding.hostInstallationId
        self.peerRevision = peerRevision
        type = "answer"
        self.sdp = sdp
    }
}

public struct ComputerSignalingCandidateRequest: Encodable, Sendable {
    public let generation: UInt64
    public let conversationId: String
    public let hostInstallationId: String
    public let peerRevision: String
    public let sequence: UInt64
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: UInt32
    public let usernameFragment: String?

    public init?(binding: ComputerSignalingBinding, sequence: UInt64, candidate: String,
                 sdpMid: String?, sdpMLineIndex: UInt32, usernameFragment: String? = nil) {
        guard let peerRevision = binding.peerRevision else { return nil }
        generation = binding.generation
        conversationId = binding.conversationId
        hostInstallationId = binding.hostInstallationId
        self.peerRevision = peerRevision
        self.sequence = sequence
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.usernameFragment = usernameFragment
    }
}

public struct ComputerSignalingCloseRequest: Encodable, Sendable {
    public let generation: UInt64
    public let conversationId: String
    public let hostInstallationId: String
    public let peerRevision: String
    public let reason: String?

    public init?(binding: ComputerSignalingBinding, reason: String? = nil) {
        guard let peerRevision = binding.peerRevision else { return nil }
        generation = binding.generation
        conversationId = binding.conversationId
        hostInstallationId = binding.hostInstallationId
        self.peerRevision = peerRevision
        self.reason = reason
    }
}

public struct ComputerIceServer: Decodable, Equatable, Sendable {
    public let urls: [String]
    public let username: String?
    public let credential: String?
}

public struct ComputerSignalingDescription: Decodable, Equatable, Sendable {
    public let type: String
    public let sdp: String
}

public struct ComputerSignalingCandidate: Decodable, Equatable, Sendable {
    public let sequence: UInt64
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: UInt32
    public let usernameFragment: String?
}

public struct ComputerSignalingResponse: Decodable, Equatable, Sendable {
    public let sessionId: String
    public let generation: UInt64
    public let peerRevision: String?
    public let state: String
    public let captureState: String
    public let peerState: String
    public let offer: ComputerSignalingDescription?
    public let candidates: [ComputerSignalingCandidate]
    public let cursor: UInt64
    public let nextCursor: UInt64
    public let failureReason: String?
    public let iceServers: [ComputerIceServer]
}

public struct ComputerSignalingMutationResponse: Decodable, Equatable, Sendable {
    public let accepted: Bool
    public let duplicate: Bool?
    public let closed: Bool?
    public let sessionId: String?
    public let generation: UInt64?
}

public struct ComputerAdmissionRequest: Encodable, Sendable {
    public let generation: UInt64
    public let role: String
    public init(generation: UInt64, role: String) { self.generation = generation; self.role = role }
}

public struct ComputerAdmissionResponse: Decodable, Sendable {
    public let session: ComputerSession
    public let role: String
    public let granted: Bool
    public let admission: [String: String]?
    public let capability: ComputerCapability
}

public struct AcquireComputerControlRequest: Encodable, Sendable {
    public let clientRequestId: String
    public let generation: UInt64
    public let geometryRevision: UInt64
    public let sourceId: String?

    public init(clientRequestId: String, generation: UInt64, geometryRevision: UInt64, sourceId: String?) {
        self.clientRequestId = clientRequestId
        self.generation = generation
        self.geometryRevision = geometryRevision
        self.sourceId = sourceId
    }
}

public struct ComputerControlBindingRequest: Codable, Sendable {
    public let leaseId: String
    public let generation: UInt64
    public let geometryRevision: UInt64
    public let sourceId: String?

    public init(leaseId: String, generation: UInt64, geometryRevision: UInt64, sourceId: String?) {
        self.leaseId = leaseId
        self.generation = generation
        self.geometryRevision = geometryRevision
        self.sourceId = sourceId
    }
}

public struct ComputerControlLease: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let ownerDeviceId: String
    public let hostInstallationId: String
    public let conversationId: String
    public let generation: UInt64
    public let sourceId: String?
    public let geometryRevision: UInt64
    public let status: String
    public let lastSequence: UInt64
    public let acquiredAt: String
    public let updatedAt: String
    public let expiresAt: String
    public let releasedAt: String?

    public init(id: String, sessionId: String, ownerDeviceId: String, hostInstallationId: String,
                conversationId: String, generation: UInt64, sourceId: String?, geometryRevision: UInt64,
                status: String, lastSequence: UInt64, acquiredAt: String, updatedAt: String,
                expiresAt: String, releasedAt: String?) {
        self.id = id
        self.sessionId = sessionId
        self.ownerDeviceId = ownerDeviceId
        self.hostInstallationId = hostInstallationId
        self.conversationId = conversationId
        self.generation = generation
        self.sourceId = sourceId
        self.geometryRevision = geometryRevision
        self.status = status
        self.lastSequence = lastSequence
        self.acquiredAt = acquiredAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.releasedAt = releasedAt
    }
}

public enum ComputerInputAction: Codable, Equatable, Sendable {
    case pointer(x: Double, y: Double, phase: String, button: String?)
    case scroll(deltaX: Double, deltaY: Double)
    case key(key: String, phase: String, modifiers: UInt32)
    case text(String)
    case clipboard(operation: String, text: String?)
    case releaseAll

    private enum CodingKeys: String, CodingKey {
        case type, x, y, phase, button, deltaX, deltaY, key, modifiers, text, operation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "pointer":
            self = .pointer(
                x: try container.decode(Double.self, forKey: .x),
                y: try container.decode(Double.self, forKey: .y),
                phase: try container.decode(String.self, forKey: .phase),
                button: try container.decodeIfPresent(String.self, forKey: .button)
            )
        case "scroll":
            self = .scroll(
                deltaX: try container.decode(Double.self, forKey: .deltaX),
                deltaY: try container.decode(Double.self, forKey: .deltaY)
            )
        case "key":
            self = .key(
                key: try container.decode(String.self, forKey: .key),
                phase: try container.decode(String.self, forKey: .phase),
                modifiers: try container.decode(UInt32.self, forKey: .modifiers)
            )
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "clipboard":
            self = .clipboard(
                operation: try container.decode(String.self, forKey: .operation),
                text: try container.decodeIfPresent(String.self, forKey: .text)
            )
        case "releaseAll":
            self = .releaseAll
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unsupported computer input action"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pointer(x, y, phase, button):
            try container.encode("pointer", forKey: .type)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
            try container.encode(phase, forKey: .phase)
            try container.encodeIfPresent(button, forKey: .button)
        case let .scroll(deltaX, deltaY):
            try container.encode("scroll", forKey: .type)
            try container.encode(deltaX, forKey: .deltaX)
            try container.encode(deltaY, forKey: .deltaY)
        case let .key(key, phase, modifiers):
            try container.encode("key", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(phase, forKey: .phase)
            try container.encode(modifiers, forKey: .modifiers)
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .clipboard(operation, text):
            try container.encode("clipboard", forKey: .type)
            try container.encode(operation, forKey: .operation)
            try container.encodeIfPresent(text, forKey: .text)
        case .releaseAll:
            try container.encode("releaseAll", forKey: .type)
        }
    }
}

public struct ComputerInputBatchRequest: Encodable, Sendable {
    public let leaseId: String
    public let generation: UInt64
    public let geometryRevision: UInt64
    public let sourceId: String?
    public let sequence: UInt64
    public let actions: [ComputerInputAction]

    public init(leaseId: String, generation: UInt64, geometryRevision: UInt64, sourceId: String?,
                sequence: UInt64, actions: [ComputerInputAction]) {
        self.leaseId = leaseId
        self.generation = generation
        self.geometryRevision = geometryRevision
        self.sourceId = sourceId
        self.sequence = sequence
        self.actions = actions
    }
}

public struct ComputerControlActionResponse: Decodable, Sendable {
    public let granted: Bool
    public let acknowledged: Bool
    public let status: String
    public let reason: String
    public let lease: ComputerControlLease?
    public let control: ComputerControlCapability
    public let clipboardText: String?
}
