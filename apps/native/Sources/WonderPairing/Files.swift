import Foundation
import CryptoKit

public enum FileFailure: Error { case tooLarge, integrity, unsupported, notUploaded }
public struct ConversationFile: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let mimeType: String?
    public let byteSize: Int?
    public let sha256: String?
    public let state: String
    public let updatedAt: String
    public func verify(_ data: Data, mime: String?) throws {
        guard data.count <= 8 * 1024 * 1024 else { throw FileFailure.tooLarge }
        guard state == "available", byteSize == data.count,
              sha256 == Self.digest(data), mimeType?.lowercased() == mime?.lowercased() else { throw FileFailure.integrity }
        try Self.validateContent(data, mime: mimeType ?? "")
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func validateContent(_ data: Data, mime: String) throws {
        if mime == "application/pdf", !data.starts(with: Data("%PDF-".utf8)) { throw FileFailure.integrity }
        if mime == "image/png", !data.starts(with: [137,80,78,71,13,10,26,10]) { throw FileFailure.integrity }
        if mime == "image/jpeg", !data.starts(with: [255,216,255]) { throw FileFailure.integrity }
        if mime.hasPrefix("text/"), String(data: data, encoding: .utf8) == nil { throw FileFailure.integrity }
    }
}

public struct WorkspaceRoot: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let path: String
    public let isDirectory: Bool
    public let kind: String
    public let readOnly: Bool
    public let byteSize: UInt64?
    public let mimeType: String?
    public init(id: String, label: String, path: String, isDirectory: Bool, kind: String, readOnly: Bool, byteSize: UInt64? = nil, mimeType: String? = nil) {
        self.id = id; self.label = label; self.path = path; self.isDirectory = isDirectory; self.kind = kind; self.readOnly = readOnly; self.byteSize = byteSize; self.mimeType = mimeType
    }
}

public struct WorkspaceRootsResponse: Codable, Sendable {
    public let available: Bool
    public let detail: String?
    public let roots: [WorkspaceRoot]
    public let attachments: [ConversationFile]
    public init(available: Bool, detail: String?, roots: [WorkspaceRoot], attachments: [ConversationFile]) {
        self.available = available; self.detail = detail; self.roots = roots; self.attachments = attachments
    }
}

public struct WorkspaceEntry: Codable, Identifiable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let byteSize: UInt64?
    public let mimeType: String?
    public var id: String { path }
    public init(name: String, path: String, isDirectory: Bool, byteSize: UInt64?, mimeType: String?) {
        self.name = name; self.path = path; self.isDirectory = isDirectory; self.byteSize = byteSize; self.mimeType = mimeType
    }
}

public struct WorkspaceDirectoryPage: Codable, Sendable {
    public let rootId: String
    public let path: String
    public let parentPath: String?
    public let entries: [WorkspaceEntry]
    public let nextOffset: Int?
    public init(rootId: String, path: String, parentPath: String?, entries: [WorkspaceEntry], nextOffset: Int?) {
        self.rootId = rootId; self.path = path; self.parentPath = parentPath; self.entries = entries; self.nextOffset = nextOffset
    }
}

public struct WorkspaceGitChange: Codable, Identifiable, Hashable, Sendable {
    public let path: String
    public let originalPath: String?
    public let state: String
    public let indexStatus: String
    public let worktreeStatus: String
    public var id: String { path + ":" + state }
    public init(path: String, originalPath: String?, state: String, indexStatus: String, worktreeStatus: String) {
        self.path = path; self.originalPath = originalPath; self.state = state; self.indexStatus = indexStatus; self.worktreeStatus = worktreeStatus
    }
}

public struct WorkspaceGitStatusResponse: Codable, Sendable {
    public let available: Bool
    public let detail: String?
    public let repositoryPath: String?
    public let changes: [WorkspaceGitChange]
    public init(available: Bool, detail: String?, repositoryPath: String?, changes: [WorkspaceGitChange]) {
        self.available = available; self.detail = detail; self.repositoryPath = repositoryPath; self.changes = changes
    }
}

public struct WorkspaceDiffResponse: Codable, Sendable {
    public let path: String
    public let staged: Bool
    public let diff: String
    public init(path: String, staged: Bool, diff: String) {
        self.path = path; self.staged = staged; self.diff = diff
    }
}

public struct StagedFile: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let mimeType: String
    public let data: Data
    public var uploaded: ConversationFile?
    public init(name: String, mimeType: String, data: Data) throws {
        try self.init(id: UUID().uuidString, name: name, mimeType: mimeType, data: data)
    }
    public init(id: String, name: String, mimeType: String, data: Data, uploaded: ConversationFile? = nil) throws {
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw FileFailure.tooLarge }
        try ConversationFile.validateContent(data, mime: mimeType)
        guard !id.isEmpty, !name.isEmpty, !mimeType.isEmpty else { throw FileFailure.integrity }
        self.id = id; self.name = name; self.mimeType = mimeType; self.data = data; self.uploaded = uploaded
    }
    public func uploadBody() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["clientUploadId": id, "name": name, "mimeType": mimeType, "contentBase64": data.base64EncodedString()])
    }
}
