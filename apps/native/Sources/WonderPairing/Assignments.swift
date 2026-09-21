import Foundation

public struct ProjectAssignment: Codable, Identifiable, Sendable {
    public let id: String
    public let groupId: String
    public let botId: String
    public let title: String
    public let projectName: String
    public let instruction: String
    public let state: String
    public let baseRevision: String
    public let resultRevision: String?
    public let summary: String?
    public let dependencyIds: [String]?
    public let createdAt: String
    public let updatedAt: String
    public let diff: String?
    public let validation: String?
    public let integrationHead: String?
    public let repositoryHead: String?
    public let canCancel: Bool?
    public var statusLabel: String {
        switch state {
        case "queued", "ready": "Queued"
        case "working": "Working"
        case "awaiting_input": "Needs your answer"
        case "submitted": "Ready for review"
        case "reviewed": "Reviewed"
        case "integrating": "Integrating"
        case "integrated": "Integrated"
        case "failed": "Couldn’t finish"
        case "cancelled": "Stopped"
        default: "Outcome not confirmed"
        }
    }
}

/// The first submission freezes both request identity and bytes. Reopening the form
/// or retrying an unconfirmed response cannot silently create different work.
public enum AssignmentIntent {
    /// A conflict can occur after integration starts. Only a fresh authoritative
    /// pre-integration state lets the owner replace a definitively rejected intent.
    public static func canReconsiderIntegration(_ draft: ManagementDraft, authoritativeState: String) -> Bool {
        draft.values["_action"] == "integrate" && draft.values["_rejected"] == "true" &&
            ["submitted", "reviewed"].contains(authoritativeState)
    }

    public static func creationBody(_ draft: inout ManagementDraft) throws -> Data {
        if let frozen = draft.values["_body"], let data = Data(base64Encoded: frozen) { return data }
        struct Creation: Encodable {
            let clientRequestId: String
            let title: String
            let instruction: String
            let botId: String
            let baseRevision: String
            let dependencyIds: [String]
        }
        let body = try JSONEncoder().encode(Creation(clientRequestId: draft.requestId,
            title: draft.values["title", default: ""], instruction: draft.values["instruction", default: ""],
            botId: draft.values["botId", default: ""], baseRevision: draft.values["baseRevision", default: ""],
            dependencyIds: draft.values["dependencies", default: ""].split(separator: "\n").map(String.init)))
        draft.values["_body"] = body.base64EncodedString()
        return body
    }
    public static func actionBody(_ draft: inout ManagementDraft, action: String, revision: String?, expectedHead: String?, validation: String?) throws -> Data {
        if let frozen = draft.values["_body"], let data = Data(base64Encoded: frozen) { return data }
        var values: [String: String] = [:]
        values["resultRevision"] = revision
        values["expectedHead"] = expectedHead
        values["validation"] = validation
        let body = try JSONEncoder().encode(values)
        draft.values["_action"] = action
        draft.values["_body"] = body.base64EncodedString()
        return body
    }
}
