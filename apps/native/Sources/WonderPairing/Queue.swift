import Foundation
public struct QueuedMessage: Codable, Identifiable, Sendable {
    public let id: String
    public let clientMessageId: String
    public let body: String
    public let revision: Int
    public let attachmentIds: [String]
    public var executionSettings: QueuedExecutionSettings? = nil
}

public struct QueuedExecutionSettings: Codable, Sendable {
    public let model: String?
    public let reasoningEffort: String?
    public let serviceTier: String?
    public let permissionMode: String?
    public let approvalMode: String?
    public let workingDirectory: String?
}
