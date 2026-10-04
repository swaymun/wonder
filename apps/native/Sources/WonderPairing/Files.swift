import Foundation
import CryptoKit

public enum FileFailure: Error { case tooLarge, integrity, stale, unsupported, notUploaded }

/// A note about exact preview bytes. The host validates the Project, path,
/// source hash and selected region again before accepting the attachment.
public struct ArtifactAnnotation: Codable, Sendable, Hashable {
    public static let mimeType = "application/vnd.wonder.artifact-annotation+json"
    public enum Anchor: Codable, Sendable, Hashable {
        case textLines(startLine: Int, endLine: Int)
        /// UTF-8 byte offsets into the pinned source, with an exclusive end.
        case textRange(startByte: Int, endByte: Int)
        case imageRegion(x: Double, y: Double, width: Double, height: Double)
        case pdfRegion(page: Int, x: Double, y: Double, width: Double, height: Double)

        private enum CodingKeys: String, CodingKey { case kind, startLine, endLine, startByte, endByte, page, x, y, width, height }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            switch try values.decode(String.self, forKey: .kind) {
            case "textLines":
                self = .textLines(startLine: try values.decode(Int.self, forKey: .startLine),
                                  endLine: try values.decode(Int.self, forKey: .endLine))
            case "textRange":
                self = .textRange(startByte: try values.decode(Int.self, forKey: .startByte),
                                  endByte: try values.decode(Int.self, forKey: .endByte))
            case "imageRegion":
                self = .imageRegion(x: try values.decode(Double.self, forKey: .x),
                                    y: try values.decode(Double.self, forKey: .y),
                                    width: try values.decode(Double.self, forKey: .width),
                                    height: try values.decode(Double.self, forKey: .height))
            case "pdfRegion":
                self = .pdfRegion(page: try values.decode(Int.self, forKey: .page),
                                  x: try values.decode(Double.self, forKey: .x),
                                  y: try values.decode(Double.self, forKey: .y),
                                  width: try values.decode(Double.self, forKey: .width),
                                  height: try values.decode(Double.self, forKey: .height))
            default:
                throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "Unsupported preview anchor")
            }
        }
        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .textLines(let start, let end):
                try values.encode("textLines", forKey: .kind)
                try values.encode(start, forKey: .startLine)
                try values.encode(end, forKey: .endLine)
            case .textRange(let start, let end):
                try values.encode("textRange", forKey: .kind)
                try values.encode(start, forKey: .startByte)
                try values.encode(end, forKey: .endByte)
            case .imageRegion(let x, let y, let width, let height):
                try values.encode("imageRegion", forKey: .kind)
                try values.encode(x, forKey: .x); try values.encode(y, forKey: .y)
                try values.encode(width, forKey: .width); try values.encode(height, forKey: .height)
            case .pdfRegion(let page, let x, let y, let width, let height):
                try values.encode("pdfRegion", forKey: .kind)
                try values.encode(page, forKey: .page)
                try values.encode(x, forKey: .x); try values.encode(y, forKey: .y)
                try values.encode(width, forKey: .width); try values.encode(height, forKey: .height)
            }
        }
    }
    public let version: Int
    public let projectId: String
    public let conversationId: String
    public let rootId: String
    public let path: String
    public let sourceSha256: String
    public let anchor: Anchor
    public var note: String

    public init(projectId: String, conversationId: String, rootId: String, path: String,
                source: Data, startLine: Int, endLine: Int, note: String) throws {
        version = 1
        self.projectId = projectId; self.conversationId = conversationId
        self.rootId = rootId; self.path = path
        sourceSha256 = ConversationFile.digest(source)
        anchor = .textLines(startLine: startLine, endLine: endLine)
        self.note = note
        guard let text = String(data: source, encoding: .utf8) else { throw FileFailure.integrity }
        let lines = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0))
        try validate(sourceLineCount: lines)
    }

    public init(projectId: String, conversationId: String, rootId: String, path: String,
                source: Data, mimeType: String, startByte: Int, endByte: Int, note: String) throws {
        guard Self.isTextFormat(mimeType), startByte >= 0, endByte > startByte,
              endByte <= source.count, String(data: source, encoding: .utf8) != nil,
              String(data: source.subdata(in: startByte..<endByte), encoding: .utf8) != nil
        else { throw FileFailure.integrity }
        version = 1
        self.projectId = projectId; self.conversationId = conversationId
        self.rootId = rootId; self.path = path
        sourceSha256 = ConversationFile.digest(source)
        anchor = .textRange(startByte: startByte, endByte: endByte)
        self.note = note
        try validate()
    }

    private static func isTextFormat(_ mimeType: String) -> Bool {
        (mimeType.hasPrefix("text/") && mimeType != "text/html") ||
        ["application/json", "application/yaml", "application/xml", "application/sql"].contains(mimeType)
    }

    public init(projectId: String, conversationId: String, rootId: String, path: String,
                source: Data, imageX x: Double, y: Double, width: Double, height: Double,
                note: String) throws {
        version = 1; self.projectId = projectId; self.conversationId = conversationId
        self.rootId = rootId; self.path = path
        sourceSha256 = ConversationFile.digest(source)
        anchor = .imageRegion(x: x, y: y, width: width, height: height)
        self.note = note
        guard !source.isEmpty else { throw FileFailure.integrity }
        try validate()
    }

    public init(projectId: String, conversationId: String, rootId: String, path: String,
                source: Data, pdfPage page: Int, x: Double, y: Double, width: Double,
                height: Double, note: String) throws {
        version = 1; self.projectId = projectId; self.conversationId = conversationId
        self.rootId = rootId; self.path = path
        sourceSha256 = ConversationFile.digest(source)
        anchor = .pdfRegion(page: page, x: x, y: y, width: width, height: height)
        self.note = note
        guard source.starts(with: Data("%PDF-".utf8)) else { throw FileFailure.integrity }
        try validate()
    }

    private static func validRegion(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 &&
        width > 0 && height > 0 && x + width <= 1 && y + height <= 1
    }

    public func validate(sourceLineCount: Int? = nil) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard version == 1, !projectId.isEmpty, !conversationId.isEmpty,
              !rootId.isEmpty, rootId.utf8.count <= 128,
              !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              sourceSha256.utf8.count == 64,
              sourceSha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              note.utf8.count <= 4096,
              !note.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" })
        else { throw FileFailure.integrity }
        switch anchor {
        case .textLines(let start, let end):
            guard start > 0, end >= start, sourceLineCount.map({ end <= $0 }) ?? true else { throw FileFailure.integrity }
        case .textRange(let start, let end):
            guard start >= 0, end > start else { throw FileFailure.integrity }
        case .imageRegion(let x, let y, let width, let height):
            guard Self.validRegion(x, y, width, height) else { throw FileFailure.integrity }
        case .pdfRegion(let page, let x, let y, let width, let height):
            guard page > 0, page <= 10_000, Self.validRegion(x, y, width, height) else { throw FileFailure.integrity }
        }
    }

    public static func read(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    public func replacingNote(_ note: String) throws -> Self {
        var copy = self
        copy.note = note
        try copy.validate()
        return copy
    }

    /// A New Chat preview can validate its anchor before a conversation exists.
    /// Bind those same source bytes and note only after prepare-only creation.
    public func bound(to conversationID: String) throws -> Self {
        let copy = Self(version: version, projectId: projectId, conversationId: conversationID,
                        rootId: rootId, path: path, sourceSha256: sourceSha256,
                        anchor: anchor, note: note)
        try copy.validate()
        return copy
    }

    private init(version: Int, projectId: String, conversationId: String, rootId: String,
                 path: String, sourceSha256: String, anchor: Anchor, note: String) {
        self.version = version; self.projectId = projectId; self.conversationId = conversationId
        self.rootId = rootId; self.path = path; self.sourceSha256 = sourceSha256
        self.anchor = anchor; self.note = note
    }

    public func stagedFile() throws -> StagedFile {
        try validate()
        let name = String((path.split(separator: "/").last ?? "File").prefix(48)) + ".annotation.json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try StagedFile(name: name, mimeType: Self.mimeType, data: encoder.encode(self))
    }
}

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
