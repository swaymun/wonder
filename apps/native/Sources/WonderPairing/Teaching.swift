import Foundation

public enum TeachingJSONValue: Codable, Equatable, Sendable {
    case object([String: TeachingJSONValue])
    case array([TeachingJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode([String: TeachingJSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([TeachingJSONValue].self) { self = .array(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else { self = .number(try container.decode(Double.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct TeachingCapability: Codable, Equatable, Sendable {
    public let available: Bool
    public let action: String
    public let reason: String
    public let provider: String
    public let maxDurationSeconds: UInt64
    public let maxEvents: UInt64
    public let maxEvidenceBytes: UInt64

    public init(available: Bool, action: String, reason: String, provider: String,
                maxDurationSeconds: UInt64, maxEvents: UInt64, maxEvidenceBytes: UInt64) {
        self.available = available
        self.action = action
        self.reason = reason
        self.provider = provider
        self.maxDurationSeconds = maxDurationSeconds
        self.maxEvents = maxEvents
        self.maxEvidenceBytes = maxEvidenceBytes
    }

    public static let unavailable = Self(
        available: false,
        action: "update-host",
        reason: "Live Mac teaching capture is unavailable on this host. Update Wonder when a supervised capture provider is available.",
        provider: "none",
        maxDurationSeconds: 600,
        maxEvents: 20_000,
        maxEvidenceBytes: 50 * 1024 * 1024
    )
}

public struct TeachingSession: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let clientRequestId: String
    public let ownerDeviceId: String
    public let hostInstallationId: String
    public let botId: String
    public let conversationId: String
    public let computerSessionId: String?
    public let controlLeaseId: String?
    public let state: String
    public let captureScope: String
    public let captureProvider: String
    public let outcome: String
    public let name: String?
    public let description: String?
    public let goal: String?
    public let inputSchema: [String: TeachingJSONValue]?
    public let prerequisites: String?
    public let steps: String?
    public let resultChecks: String?
    public let failureReason: String?
    public let revision: UInt64
    public let eventCount: UInt64
    public let evidenceBytes: UInt64
    public let contentHash: String?
    public let createdAt: String
    public let updatedAt: String
    public let startedAt: String?
    public let endedAt: String?
    public let expiresAt: String?
    public let events: [TeachingEvent]
    public let capability: TeachingCapability

    private enum CodingKeys: String, CodingKey {
        case id, clientRequestId, ownerDeviceId, hostInstallationId, botId, conversationId
        case computerSessionId, controlLeaseId, state, captureScope, captureProvider, outcome
        case name, description, goal, inputSchema, prerequisites, steps, resultChecks
        case failureReason, revision, eventCount, evidenceBytes, contentHash, createdAt, updatedAt
        case startedAt, endedAt, expiresAt, events, capability
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        clientRequestId = try container.decode(String.self, forKey: .clientRequestId)
        ownerDeviceId = try container.decode(String.self, forKey: .ownerDeviceId)
        hostInstallationId = try container.decode(String.self, forKey: .hostInstallationId)
        botId = try container.decode(String.self, forKey: .botId)
        conversationId = try container.decode(String.self, forKey: .conversationId)
        computerSessionId = try container.decodeIfPresent(String.self, forKey: .computerSessionId)
        controlLeaseId = try container.decodeIfPresent(String.self, forKey: .controlLeaseId)
        state = try container.decode(String.self, forKey: .state)
        captureScope = try container.decode(String.self, forKey: .captureScope)
        captureProvider = try container.decode(String.self, forKey: .captureProvider)
        outcome = try container.decode(String.self, forKey: .outcome)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        goal = try container.decodeIfPresent(String.self, forKey: .goal)
        inputSchema = try container.decodeIfPresent([String: TeachingJSONValue].self, forKey: .inputSchema)
        prerequisites = try container.decodeIfPresent(String.self, forKey: .prerequisites)
        steps = try container.decodeIfPresent(String.self, forKey: .steps)
        resultChecks = try container.decodeIfPresent(String.self, forKey: .resultChecks)
        failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        revision = try container.decode(UInt64.self, forKey: .revision)
        eventCount = try container.decode(UInt64.self, forKey: .eventCount)
        evidenceBytes = try container.decode(UInt64.self, forKey: .evidenceBytes)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(String.self, forKey: .endedAt)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        events = try container.decodeIfPresent([TeachingEvent].self, forKey: .events) ?? []
        capability = try container.decode(TeachingCapability.self, forKey: .capability)
    }
}

public struct TeachingEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(sequence)-\(actionIndex)" }
    public let sequence: UInt64
    public let actionIndex: UInt64
    public let kind: String
    public let payload: [String: TeachingJSONValue]
    public let createdAt: String
}

public struct StartTeachingSessionRequest: Encodable, Sendable {
    public let clientRequestId: String
    public let conversationId: String
    public let computerSessionId: String
    public let controlLeaseId: String
    public let captureScope: String
    public let outcome: String

    public init(clientRequestId: String, conversationId: String, computerSessionId: String,
                controlLeaseId: String, captureScope: String, outcome: String) {
        self.clientRequestId = clientRequestId
        self.conversationId = conversationId
        self.computerSessionId = computerSessionId
        self.controlLeaseId = controlLeaseId
        self.captureScope = captureScope
        self.outcome = outcome
    }
}

public struct TeachingRevisionRequest: Encodable, Sendable {
    public let expectedRevision: UInt64?
    public init(expectedRevision: UInt64?) { self.expectedRevision = expectedRevision }
}

public struct ReviewTeachingSessionRequest: Encodable, Sendable {
    public let expectedRevision: UInt64
    public let name: String
    public let description: String
    public let goal: String
    public let inputSchema: [String: TeachingJSONValue]
    public let prerequisites: String
    public let steps: String
    public let resultChecks: String

    public init(expectedRevision: UInt64, name: String, description: String, goal: String,
                inputSchema: [String: TeachingJSONValue], prerequisites: String, steps: String,
                resultChecks: String) {
        self.expectedRevision = expectedRevision
        self.name = name
        self.description = description
        self.goal = goal
        self.inputSchema = inputSchema
        self.prerequisites = prerequisites
        self.steps = steps
        self.resultChecks = resultChecks
    }
}

public struct SaveBotSkillVersionRequest: Encodable, Sendable {
    public let clientRequestId: String
    public let expectedRevision: UInt64
    public let slug: String?

    public init(clientRequestId: String, expectedRevision: UInt64, slug: String?) {
        self.clientRequestId = clientRequestId
        self.expectedRevision = expectedRevision
        self.slug = slug
    }
}

public struct ActivateBotSkillVersionRequest: Encodable, Sendable {
    public let version: UInt64
    public init(version: UInt64) { self.version = version }
}

public struct BotSkillVersion: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let version: UInt64
    public let sourceSessionId: String
    public let contentHash: String
    public let inputSchema: [String: TeachingJSONValue]
    public let verificationState: String
    public let createdAt: String
}

public struct BotSkill: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let botId: String
    public let slug: String
    public let name: String
    public let description: String
    public let state: String
    public let activeVersion: UInt64?
    public let discoverability: String
    public let versions: [BotSkillVersion]?
}

public struct BotSkillListResponse: Decodable, Sendable {
    public let capability: TeachingCapability
    public let skills: [BotSkill]

    public init(capability: TeachingCapability, skills: [BotSkill]) {
        self.capability = capability
        self.skills = skills
    }
}

public struct SaveBotSkillVersionResponse: Decodable, Sendable {
    public let skill: BotSkill
    public let version: BotSkillVersion
    public let teachingSession: TeachingSession
}

public struct BotSkillFixtureTestRequest: Encodable, Sendable {
    public let clientRequestId: String
    public let contentHash: String
    public let inputSchema: [String: TeachingJSONValue]
    public let inputs: [String: TeachingJSONValue]
    public let workingDirectory: String?

    public init(clientRequestId: String, contentHash: String, inputSchema: [String: TeachingJSONValue], inputs: [String: TeachingJSONValue], workingDirectory: String? = nil) {
        self.clientRequestId = clientRequestId
        self.contentHash = contentHash
        self.inputSchema = inputSchema
        self.inputs = inputs
        self.workingDirectory = workingDirectory
    }
}

public struct BotSkillFixtureTestReceipt: Codable, Identifiable, Sendable {
    public let id: String
    public let clientRequestId: String
    public let ownerDeviceId: String
    public let botId: String
    public let skillId: String
    public let version: UInt64
    public let contentHash: String
    public let inputSchemaHash: String
    public let inputSchema: [String: TeachingJSONValue]
    public let inputs: [String: TeachingJSONValue]
    public let workingDirectory: String
    public let provider: String
    public let executionKind: String
    public let status: String
    public let verificationState: String
    public let artifactPath: String?
    public let artifactHash: String?
    public let artifactBytes: UInt64
    public let evidence: [String: TeachingJSONValue]
    public let failureReason: String?
    public let createdAt: String
    public let completedAt: String
}
