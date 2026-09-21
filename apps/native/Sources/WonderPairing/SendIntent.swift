import Foundation
import CryptoKit

public struct SendRequest: Codable, Sendable {
    public let deviceId: String
    public let clientMessageId: String
    public let body: String
    public let attachmentIds: [String]
    public var groupRouting: NewBotDefaults? = nil
    public var expectedTurnId: String?
}

public struct SendReceipt: Codable, Sendable {
    public let clientMessageId: String
    public let wonderMessageId: String
    public let bodySha256: String
    public let conversationId: String
    public let deliveryState: String
}

public enum SendFailure: Error { case empty, tooLarge, pending, receiptMismatch }

public struct PendingSend: Codable, Sendable {
    public let request: SendRequest
    public let createdAt: String
    public var receipt: SendReceipt?
    public var rejected: Bool?
}

/// Reconcile an IME commit with text appended while the marked candidate was
/// still being edited. Never restore already-sent base text after a draft clear.
public enum ComposerComposition {
    /// Keep the original input until the model confirms it accepted a write.
    /// Each retry merges against the latest draft, including a Send/reset clear.
    public struct PendingCommit {
        private let base: String
        private let committed: String
        public init(base: String, committed: String) { self.base = base; self.committed = committed }
        public func replacingCommittedText(_ text: String) -> Self { Self(base: base, committed: text) }
        public func apply(to currentDraft: String, save: (String) -> String) -> String? {
            let merged = ComposerComposition.merge(base: base, committed: committed, currentDraft: currentDraft)
            return save(merged) == merged ? merged : nil
        }
    }
    public static func merge(base: String, committed: String, currentDraft: String) -> String {
        if currentDraft == base { return committed }
        if committed == base { return currentDraft }
        if currentDraft.hasPrefix(base) {
            return join(committed, String(currentDraft.dropFirst(base.count)))
        }
        // A send/restore replaced the base while composition was active. Retain
        // the current draft and only the user's changed span, not the stale base.
        let before = Array(base), after = Array(committed)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
            before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        return join(currentDraft, String(after[prefix..<(after.count - suffix)]))
    }
    private static func join(_ first: String, _ second: String) -> String {
        let separated = first.isEmpty || second.isEmpty || first.last?.isWhitespace == true || second.first?.isWhitespace == true
        return first + (separated ? "" : " ") + second
    }
}

/// Saved atomically before networking. A retry always uses the original bytes and ID.
public struct ComposerIntent: Codable, Sendable {
    public var stagedFiles: [StagedFile]?
    public var draftAttachmentIds: [String]?
    public var draft = ""
    public private(set) var lastDictationRequestID: String?
    public private(set) var pending: PendingSend?
    /// Requests made by a previous pairing remain immutable and readable, but
    /// cannot block a new draft or be retried under the replacement identity.
    public private(set) var recoveredPending: [PendingSend]?
    public init() {}
    @discardableResult public mutating func preservePreviousIdentityPending(currentDevice: String) -> Bool {
        guard let pending, pending.request.deviceId != currentDevice else { return false }
        var recovered = recoveredPending ?? []
        if !recovered.contains(where: { $0.request.clientMessageId == pending.request.clientMessageId }) { recovered.append(pending) }
        recoveredPending = recovered
        self.pending = nil
        return true
    }
    /// The durable draft can contain both local files waiting for upload and
    /// server files restored after a rejected or interrupted send. Keep their
    /// count and identity in one place so attachment limits and removal agree.
    public var attachmentIDs: [String] {
        var result: [String] = []
        for id in (stagedFiles ?? []).map(\.id) + (draftAttachmentIds ?? []) where !result.contains(id) {
            result.append(id)
        }
        return result
    }
    public var attachmentCount: Int { attachmentIDs.count }

    public mutating func removeAttachment(id: String) {
        stagedFiles?.removeAll { $0.id == id }
        draftAttachmentIds?.removeAll { $0 == id }
    }
    @discardableResult public mutating func appendDictation(_ text: String, requestID: String) throws -> Bool {
        guard lastDictationRequestID != requestID else { return false }
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw SendFailure.empty }
        let result = draft + (draft.isEmpty || draft.last?.isWhitespace == true ? "" : " ") + transcript
        guard result.utf8.count <= 65536 else { throw SendFailure.tooLarge }
        draft = result; lastDictationRequestID = requestID
        return true
    }
    public mutating func begin(device: String, expectedTurnId: String? = nil, groupRouting: NewBotDefaults? = nil) throws {
        guard pending == nil else { throw SendFailure.pending }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(stagedFiles ?? []).isEmpty || !(draftAttachmentIds ?? []).isEmpty else { throw SendFailure.empty }
        guard draft.utf8.count <= 65536 else { throw SendFailure.tooLarge }
        guard attachmentCount <= 4 else { throw FileFailure.tooLarge }
        guard (stagedFiles ?? []).allSatisfy({ $0.uploaded != nil }) else { throw FileFailure.notUploaded }
        pending = PendingSend(request: SendRequest(deviceId: device, clientMessageId: UUID().uuidString,
            body: draft, attachmentIds: (stagedFiles ?? []).compactMap { $0.uploaded?.id } + (draftAttachmentIds ?? []), groupRouting: groupRouting, expectedTurnId: expectedTurnId), createdAt: ISO8601DateFormatter().string(from: Date()))
        draft = ""
        stagedFiles = nil
        draftAttachmentIds = nil
    }
    public mutating func markRejected() { pending?.rejected = true }
    public mutating func restoreRejected() throws {
        guard let pending, pending.rejected == true, pending.receipt == nil,
              draft.isEmpty, (stagedFiles ?? []).isEmpty else { throw SendFailure.pending }
        draft = pending.request.body
        draftAttachmentIds = pending.request.attachmentIds
        self.pending = nil
    }
    public mutating func accept(_ receipt: SendReceipt, conversation: String) throws {
        guard let pending, receipt.clientMessageId == pending.request.clientMessageId,
              receipt.conversationId == conversation, !receipt.wonderMessageId.isEmpty,
              receipt.bodySha256 == SHA256.hash(data: Data(pending.request.body.utf8)).map({ String(format: "%02x", $0) }).joined()
        else { throw SendFailure.receiptMismatch }
        self.pending?.receipt = receipt
    }
    public mutating func reconcile(_ group: GroupRead) {
        let matches: (PendingSend) -> Bool = { pending in
            if let receipt = pending.receipt, receipt.conversationId != group.conversationId { return false }
            return group.messages.contains {
                $0.authorKind == "user" && $0.clientMessageId == pending.request.clientMessageId && $0.body == pending.request.body
            }
        }
        if let pending, matches(pending) { self.pending = nil }
        recoveredPending?.removeAll(where: matches)
    }
    public mutating func reconcile(_ snapshot: ConversationSnapshot) {
        // Remove the local echo only after the authoritative projection includes it.
        let matches: (PendingSend) -> Bool = { pending in
            if let receipt = pending.receipt, receipt.conversationId != snapshot.conversationId { return false }
            return snapshot.messages.contains {
                ($0.messageId == pending.receipt?.wonderMessageId || $0.clientMessageId == pending.request.clientMessageId)
                    && ($0.body == pending.request.body || $0.originalBodySha256 == ConversationFile.digest(Data(pending.request.body.utf8)))
            }
        }
        if let pending, matches(pending) { self.pending = nil }
        recoveredPending?.removeAll(where: matches)
    }
}

public extension ReadStore {
    func loadComposer(conversation: String) throws -> ComposerIntent {
        guard let data = try loadIntent(conversation: conversation) else { return ComposerIntent() }
        return try JSONDecoder().decode(ComposerIntent.self, from: data)
    }
    func saveComposer(_ intent: ComposerIntent, conversation: String) throws {
        try saveIntent(JSONEncoder().encode(intent), conversation: conversation)
    }
}
