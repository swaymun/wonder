import Foundation
import CryptoKit

public struct ChatSummary: Codable, Hashable, Identifiable, Sendable {
    public let conversationId: String
    public let botId: String?
    public let title: String
    public let lastMessagePreview: String?
    public let lastMessageAt: String?
    public let messageCount: Int
    public let deliveryState: String?
    public let hasUnread: Bool
    public let isArchived: Bool
    public let isPinned: Bool
    public var id: String { conversationId }
    public init(conversationId: String, botId: String?, title: String, lastMessagePreview: String?, lastMessageAt: String?,
                messageCount: Int, deliveryState: String?, hasUnread: Bool, isArchived: Bool, isPinned: Bool) {
        self.conversationId = conversationId; self.botId = botId; self.title = title
        self.lastMessagePreview = lastMessagePreview; self.lastMessageAt = lastMessageAt; self.messageCount = messageCount
        self.deliveryState = deliveryState; self.hasUnread = hasUnread; self.isArchived = isArchived; self.isPinned = isPinned
    }
    public func matchesName(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
    }
}

public struct SubagentSummary: Codable, Hashable, Identifiable, Sendable {
    public let conversationId: String
    public let threadId: String
    public let parentConversationId: String
    public let parentThreadId: String
    public let title: String
    public let agentNickname: String?
    public let agentRole: String?
    public let agentPath: String?
    public let status: String
    public let canAcceptDirectInput: Bool?
    public let isArchived: Bool
    public var id: String { conversationId }


    public var isFinished: Bool {
        ["completed", "interrupted", "failed", "errored", "shutdown"].contains(status) || isArchived
    }

    /// Product-facing lifecycle copy. App Server status values are transport
    /// details and must not leak into the conversation UI.
    public var statusLabel: String {
        switch status {
        case "active", "running", "inProgress": return "Running"
        case "idle", "pendingInit", "pending", "waiting": return "Waiting"
        case "waitingOnUserInput", "waiting_on_user_input": return "Waiting for input"
        case "waitingOnApproval", "waiting_on_approval": return "Waiting for approval"
        case "completed": return "Completed"
        case "interrupted", "shutdown": return "Stopped"
        case "failed", "errored": return "Failed"
        default: return "Unavailable"
        }
    }

    public func chatSummary(botId: String?) -> ChatSummary {
        ChatSummary(conversationId: conversationId, botId: botId, title: title,
                    lastMessagePreview: nil, lastMessageAt: nil, messageCount: 0,
                    deliveryState: nil, hasUnread: false, isArchived: isArchived, isPinned: false)
    }
}

public struct SubagentListResponse: Codable, Sendable {
    public let available: Bool
    public let detail: String?
    public let subagents: [SubagentSummary]
}

/// Who wrote a message when another thread, or Wonder reporting finished
/// delegated tasks, did instead of the owner.
public struct MessageSource: Codable, Equatable, Sendable {
    /// `thread`, `delegation` or `wake`.
    public let kind: String
    public let sourceConversationId: String?
    public let sourceTitle: String
    public init(kind: String, sourceConversationId: String? = nil, sourceTitle: String) {
        self.kind = kind; self.sourceConversationId = sourceConversationId; self.sourceTitle = sourceTitle
    }
    /// A short, user-facing label for a message another thread wrote.
    public var fromLabel: String? { kind == "wake" ? nil : "From " + sourceTitle }
    /// Wonder's own report that delegated tasks finished; shown as a system row.
    public var isWake: Bool { kind == "wake" }
}

public struct ConversationMessage: Codable, Identifiable, Sendable {
    public var clientMessageId: String?
    public var codexTurnId: String?
    public var codexThreadId: String?
    public var originalBodySha256: String?
    public let messageId: String
    public let body: String
    public let state: String
    public let createdAt: String
    public let attachmentIds: [String]
    public var source: MessageSource?
    public var id: String { messageId }
    /// Removing queued work cancels the local message before any runtime saw it.
    public var wasCancelledBeforeDispatch: Bool {
        state == "interrupted" && (codexTurnId?.isEmpty ?? true) && (codexThreadId?.isEmpty ?? true)
    }
}

public struct AssistantMessage: Codable, Identifiable, Sendable {
    public var itemId: String?
    public var codexTurnId: String?
    public let messageId: String
    public let text: String
    public let state: String
    public let createdAt: String
    public let updatedAt: String
    public var id: String { messageId }
    public var rowId: String {
        if let codexTurnId, let itemId { return codexTurnId + "/" + itemId }
        return "assistant-" + messageId
    }
}

public struct ConversationSnapshot: Codable, Sendable {
    public init(
        conversationId: String,
        hostEpoch: String,
        lastSequence: UInt64,
        messages: [ConversationMessage],
        assistantMessages: [AssistantMessage],
        thread: ThreadProjection
    ) {
        self.conversationId = conversationId
        self.hostEpoch = hostEpoch
        self.lastSequence = lastSequence
        self.messages = messages
        self.assistantMessages = assistantMessages
        self.thread = thread
    }


    /// Local placeholders retain queued/unsent messages, but cannot supersede
    /// the newest actual runtime turn after Guide, queue cancellation, or replay.
    private var newestRuntimeTurn: ReadTurn? {
        thread.turns?.last(where: { !$0.id.hasPrefix("local:") })
    }
    public var activeTurnIDs: Set<String> {
        activeTurnID.map { [$0] } ?? []
    }
    public var activeTurnID: String? {
        guard let newest = newestRuntimeTurn, newest.isInProgress else { return nil }
        return newest.id
    }
    /// The active turn is running in a desktop or terminal app on the Mac.
    public var activeTurnRunsElsewhere: Bool {
        activeTurnID != nil && newestRuntimeTurn?.runningElsewhere == true
    }
    public var latestRequestIssue: String? {
        guard activeTurnID == nil, !hasUnassignedPreTurnWork,
              let message = messages.last(where: { !$0.wasCancelledBeforeDispatch }) else { return nil }
        if message.codexTurnId == newestRuntimeTurn?.id, newestRuntimeTurn?.status == "completed" { return nil }
        guard ["uncertain", "safe_to_retry", "failed", "interrupted"].contains(message.state) else { return nil }
        if message.state == "uncertain" {
            return "A message’s delivery is unconfirmed. Review the conversation before trying again."
        }
        if message.codexTurnId?.isEmpty != false {
            return "A message could not be sent. Review the conversation before trying again."
        }
        return message.state == "interrupted"
            ? "The last response was stopped. Review the conversation before sending new work."
            : "The last response could not finish. Review the conversation before sending new work."
    }
    /// A message can be accepted before the daemon assigns it to a turn. It
    /// still occupies the composer until dispatch resolves, but it cannot
    /// identify a turn for Guide or Stop.
    public var hasUnassignedPreTurnWork: Bool {
        messages.contains { message in
            (message.codexTurnId == nil || message.codexTurnId?.isEmpty == true)
                && ["accepted_by_wonder", "dispatching_to_codex"].contains(message.state)
        }
    }
    /// Merge an older canonical page, or a cached projection during refresh.
    /// Turn statuses and items remain historical data; actionable state is
    /// derived separately from the newest chronological turn.
    public func mergingOlder(_ older: Self) throws -> Self {
        guard conversationId == older.conversationId, hostEpoch == older.hostEpoch else { throw ReadFailure.resync }
        return Self(conversationId: conversationId, hostEpoch: hostEpoch, lastSequence: lastSequence,
                    messages: Self.unique(older.messages, messages, key: \.messageId),
                    assistantMessages: Self.unique(older.assistantMessages, assistantMessages, key: \.messageId),
                    thread: thread.mergingOlder(older.thread))
    }
    private static func unique<T>(_ older: [T], _ newer: [T], key: KeyPath<T, String>) -> [T] {
        let ids = Set(newer.map { $0[keyPath: key] })
        return older.filter { !ids.contains($0[keyPath: key]) } + newer
    }
    public func rows(author: String) -> [ReadRow] {
        if let turns = thread.turns, !turns.isEmpty {
            let rows: [ReadRow] = turns.flatMap { (turn: ReadTurn) -> [ReadRow] in
                turn.items.compactMap { (item: ReadItem) -> ReadRow? in
                    let user = item.type == "userMessage"
                    let message = user || item.type == "agentMessage"
                    let text: String
                    switch item.type {
                    case "userMessage", "agentMessage": text = item.text ?? "Message content unavailable"
                    case "error": text = item.text ?? "This work could not be completed."
                    case "approval": text = item.state == "completed" ? "Request closed." : "A reply was requested."
                    case "unknown": text = "This item needs a newer version of Wonder."
                    default: text = "Activity · " + (item.state == "completed" ? "Completed" : "Saved")
                    }
                    let durable = user ? canonicalMessage(for: item, in: turn) : nil
                    if durable?.wasCancelledBeforeDispatch == true { return nil }
                    let clientId = durable?.clientMessageId ?? item.payload?["clientId"]?.string
                    let identity = user ? "user-" + (clientId ?? durable?.messageId ?? item.id) : turn.id + "/" + item.id
                    let speaker: String = user ? "You" : (message ? author : "Activity")
                    return ReadRow(id: identity, author: speaker,
                                   text: durable?.body ?? text, isUser: user, timestamp: durable?.createdAt ?? item.createdAt,
                                   turnId: turn.id, item: item, attachmentIds: durable?.attachmentIds ?? [], source: durable?.source)
                }
            }
            // Live projections can precede thread hydration. Merge by identity so
            // accepted sends and in-progress assistant text remain visible.
            let userIDs = Set(rows.filter(\.isUser).map(\.id))
            let missingUsers = messages.filter { !$0.wasCancelledBeforeDispatch && !userIDs.contains("user-" + ($0.clientMessageId ?? $0.messageId)) }.map {
                ReadRow(id: "user-" + ($0.clientMessageId ?? $0.messageId), author: "You", text: $0.body, isUser: true, timestamp: $0.createdAt, attachmentIds: $0.attachmentIds, source: $0.source)
            }
            var merged = rows
            for message in assistantMessages {
                if let item = message.itemId, let index = merged.firstIndex(where: { row in
                    !row.isUser && (message.rowId == row.id
                        || (message.codexTurnId == nil && row.id.hasSuffix("/" + item)))
                }) {
                    let old = merged[index]
                    merged[index] = ReadRow(id: old.id, author: author, text: message.text, isUser: false, timestamp: old.timestamp, turnId: old.turnId, item: old.item)
                } else {
                    merged.append(ReadRow(id: message.rowId, author: author, text: message.text, isUser: false, timestamp: message.createdAt, turnId: message.codexTurnId))
                }
            }
            var seen = Set<String>()
            let visible = (merged + missingUsers).filter { !(!$0.isUser && $0.nativeQuestion == nil && ($0.item == nil || $0.item?.type == "agentMessage") && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && seen.insert($0.id).inserted }.sorted { $0.time < $1.time }
            return ReadRow.reconcilingQuestions(visible)
        }
        return (messages.filter { !$0.wasCancelledBeforeDispatch }.map { ReadRow(id: "user-" + ($0.clientMessageId ?? $0.messageId), author: "You", text: $0.body, isUser: true, timestamp: $0.createdAt, attachmentIds: $0.attachmentIds, source: $0.source) }
         + assistantMessages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { ReadRow(id: $0.rowId, author: author, text: $0.text, isUser: false, timestamp: $0.createdAt) })
        .sorted { $0.time < $1.time }
    }

    private func canonicalMessage(for item: ReadItem, in turn: ReadTurn) -> ConversationMessage? {
        if let clientId = item.payload?["clientId"]?.string,
           let message = messages.first(where: { $0.clientMessageId == clientId }) { return message }
        if let message = messages.first(where: { $0.messageId == item.id }) { return message }
        // Older runtime items may omit clientId. A turn is safe to match only
        // when both sides have exactly one user message; never compare bodies.
        let candidates = messages.filter { $0.codexTurnId == turn.id }
        if candidates.count == 1, turn.items.filter({ $0.type == "userMessage" }).count == 1,
           item.payload?["clientId"]?.string == nil { return candidates[0] }
        return nil
    }

    public let conversationId: String
    public let hostEpoch: String
    public let lastSequence: UInt64
    public let messages: [ConversationMessage]
    public let assistantMessages: [AssistantMessage]
    public let thread: ThreadProjection
}

public struct ThreadProjection: Codable, Sendable {
    public let threadId: String?
    public let nextCursor: String?
    public let hydrated: Bool
    public let turns: [ReadTurn]?
    public init(threadId: String? = nil, nextCursor: String?, hydrated: Bool, turns: [ReadTurn]? = nil) {
        self.threadId = threadId; self.nextCursor = nextCursor; self.hydrated = hydrated; self.turns = turns
    }
    func mergingOlder(_ older: Self) -> Self {
        let order = (older.turns ?? []).map(\.id) + (turns ?? []).map(\.id).filter { id in !(older.turns ?? []).contains { $0.id == id } }
        var merged = Dictionary((older.turns ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for turn in turns ?? [] {
            let newest = Set(turn.items.map(\.id))
            let items = (merged[turn.id]?.items ?? []).filter { !newest.contains($0.id) } + turn.items
            merged[turn.id] = ReadTurn(id: turn.id, items: items,
                                       startedAt: turn.startedAt ?? merged[turn.id]?.startedAt,
                                       completedAt: turn.completedAt ?? merged[turn.id]?.completedAt,
                                       status: turn.status)
        }
        return Self(threadId: threadId ?? older.threadId, nextCursor: older.nextCursor, hydrated: hydrated, turns: merged.isEmpty ? nil : order.compactMap { merged[$0] })
    }
}

public struct ReadTurn: Codable, Sendable {
    public let id: String
    public let items: [ReadItem]
    public var startedAt: String? = nil
    public var completedAt: String? = nil
    /// The App Server turn lifecycle. This is the authority for whether work
    /// is active; item or message delivery states can arrive late during a
    /// steer, stop, reconnect, or replay.
    public let status: String
    /// Running in a desktop or terminal app on the Mac. Wonder shows it but
    /// cannot steer, stop, or add a turn until it finishes.
    public var runningElsewhere = false
    public init(id: String, items: [ReadItem], startedAt: String? = nil, completedAt: String? = nil, status: String = "unknown",
                runningElsewhere: Bool = false) {
        self.id = id
        self.items = items
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
        self.runningElsewhere = runningElsewhere
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        items = try container.decode([ReadItem].self, forKey: .items)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        // Pre-status caches remain readable, but are deliberately treated as
        // unknown instead of being inferred from stale delivery receipts.
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        runningElsewhere = try container.decodeIfPresent(Bool.self, forKey: .runningElsewhere) ?? false
    }
    private enum CodingKeys: String, CodingKey { case id, items, startedAt, completedAt, status, runningElsewhere }
    public var isInProgress: Bool { status == "inProgress" }
    public var terminalLabel: String? {
        switch status {
        case "completed": return workedLabel
        case "interrupted": return "Stopped"
        case "failed": return "Couldn’t finish"
        default: return nil
        }
    }
    public var workedLabel: String {
        guard let startedAt, let completedAt,
              let start = Self.seconds(startedAt), let end = Self.seconds(completedAt),
              end >= start, end - start < Double(Int.max) else { return "Worked" }
        let seconds = Int(end - start)
        return seconds >= 60 ? "Worked for \(seconds / 60)m \(seconds % 60)s" : "Worked for \(seconds)s"
    }
    private static func seconds(_ value: String) -> Double? {
        if let milliseconds = Double(value), milliseconds.isFinite { return milliseconds / 1000 }
        return ReadTimestamp.seconds(value)
    }
}
public struct ReadItem: Codable, Sendable {
    public let id: String; public let type: String; public let state: String
    public let text: String?; public let createdAt: String
    public var payload: [String: ThreadValue]? = nil
}

extension ReadItem {
    private enum CodingKeys: String, CodingKey { case id, type, state, text, createdAt, payload }
    /// Hosts attach each computer-use screenshot inline as a multi-megabyte
    /// base64 data URL. Native clients never render that field, so drop it
    /// before it reaches row projection, the timeline or the on-device cache.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        state = try container.decode(String.self, forKey: .state)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        payload = try container.decodeIfPresent([String: ThreadValue].self, forKey: .payload)
        if type == "imageView", payload?["imageUrl"]?.string?.hasPrefix("data:") == true {
            payload?["imageUrl"] = nil
        }
    }
}

/// Retains the daemon's sanitized structured payload through disk cache/replay.
/// Unknown tool fields survive without making the whole conversation undecodable.
public enum ThreadValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([ThreadValue]), object([String: ThreadValue]), null
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var number: Double? { if case .number(let value) = self { return value }; return nil }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var array: [ThreadValue]? { if case .array(let value) = self { return value }; return nil }
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode([ThreadValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: ThreadValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
}

public struct ReplayEvent: Codable, Sendable {
    public let eventId: String
    public let hostEpoch: String
    public let sequence: UInt64
    public let occurredAt: String
    public let conversationId: String?
    public let event: EventBody
}

public struct EventBody: Codable, Sendable {
    public let type: String
    /// Activity category/state, read only to recognize host-wide runtime
    /// notices. Other payload shapes decode as nil rather than failing replay.
    public let category: String?
    public let state: String?
    public init(type: String, category: String? = nil, state: String? = nil) {
        self.type = type; self.category = category; self.state = state
    }
    private enum CodingKeys: String, CodingKey { case type, data }
    private struct Activity: Codable { let category: String?; let state: String? }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        let activity = (try? container.decodeIfPresent(Activity.self, forKey: .data)) ?? nil
        category = activity?.category; state = activity?.state
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        if category != nil || state != nil { try container.encode(Activity(category: category, state: state), forKey: .data) }
    }
    /// Runtime status the host journals without a conversation (MCP startup,
    /// rate limits, app lists, warnings). It changes no chat, list or Bot data.
    public var isHostRuntimeNotice: Bool { type == "activity" && category == "App Server" && state == "unhandled" }
}

public struct ProjectionState: Codable, Sendable {
    /// Restored with the chats, before their first frame. Optional for old caches.
    public var managedBots: [ManagedBot]?
    public var groups: [String: GroupRead] = [:]
    public var dirty: Set<String> = []
    /// The newest replay sequence that invalidated each dirty conversation. A
    /// conversation without an entry needs a snapshot at the global cursor.
    /// Optional so caches written before scoped invalidation still decode.
    public var invalidatedThrough: [String: UInt64]?
    public var listDirty = true
    public var positions: [String: String] = [:]
    public init() { hostEpoch = ""; lastSequence = 0; summaries = []; snapshots = [:] }
    /// A snapshot read at `sequence` covers this conversation's invalidations
    /// through that sequence. Later events for other conversations do not make
    /// it stale; the host's read fence uses the same per-conversation rule.
    public func covers(_ conversation: String, through sequence: UInt64) -> Bool {
        sequence >= (invalidatedThrough?[conversation] ?? lastSequence)
    }
    public mutating func markClean(_ conversation: String) {
        dirty.remove(conversation)
        invalidatedThrough?[conversation] = nil
    }
    /// Marks every cached conversation stale as of the current cursor, for a
    /// cold load, resnapshot, epoch change or host-wide event.
    public mutating func invalidateAll() {
        var marks = invalidatedThrough ?? [:]
        for conversation in Set(snapshots.keys).union(groups.keys) {
            dirty.insert(conversation)
            marks[conversation] = max(marks[conversation] ?? 0, lastSequence)
        }
        invalidatedThrough = marks
        listDirty = true
    }
    // A snapshot covers one chat, never the rest of the host.
    public mutating func install(_ snapshot: ConversationSnapshot) {
        if let existing = snapshots[snapshot.conversationId], existing.hostEpoch == snapshot.hostEpoch {
            if existing.lastSequence > snapshot.lastSequence { return }
            if existing.lastSequence == snapshot.lastSequence,
               existing.messages.count + existing.assistantMessages.count > snapshot.messages.count + snapshot.assistantMessages.count { return }
        }
        if hostEpoch != snapshot.hostEpoch {
            hostEpoch = snapshot.hostEpoch
            lastSequence = snapshot.lastSequence
            invalidatedThrough = nil
            invalidateAll()
        }
        snapshots[snapshot.conversationId] = snapshot
        if covers(snapshot.conversationId, through: snapshot.lastSequence) { markClean(snapshot.conversationId) }
    }
    public mutating func consume(_ event: ReplayEvent) throws {
        guard event.event.type != "resync_required", event.hostEpoch == hostEpoch else { throw ReadFailure.resync }
        if event.sequence <= lastSequence { return }
        guard lastSequence < UInt64.max, event.sequence == lastSequence + 1 else { throw ReadFailure.resync }
        lastSequence = event.sequence
        let conversation = event.conversationId.flatMap { $0.isEmpty ? nil : $0 }
        if conversation == nil && event.event.isHostRuntimeNotice { return }
        listDirty = true
        if let conversation {
            // Every journaled projection change names its conversation.
            dirty.insert(conversation)
            invalidatedThrough = (invalidatedThrough ?? [:]).merging([conversation: event.sequence]) { _, new in new }
        } else {
            // Host-wide or unknown events conservatively invalidate every scope.
            invalidateAll()
        }
    }

    public var hostEpoch: String
    public var lastSequence: UInt64
    public var summaries: [ChatSummary]
    public var snapshots: [String: ConversationSnapshot]
}


public enum ReadFailure: Error { case resync, wrongConversation }

public struct GroupRead: Codable, Sendable {
    public var description: String?
    public var collaboration: GroupCollaboration?
    public var attachmentsSupported: Bool?
    public var canAttachFiles: Bool { attachmentsSupported == true && !isArchived }
    public var hasUnread: Bool?
    public var hostEpoch: String?
    public var lastSequence: UInt64?
    public let id: String
    public let conversationId: String
    public let name: String
    public var coordinatorBotId: String?
    public var members: [GroupMember]?
    public let isArchived: Bool
    public let messages: [GroupMessage]
    public var summary: ChatSummary {
        ChatSummary(conversationId: conversationId, botId: nil, title: name,
                    lastMessagePreview: messages.last(where: { $0.presentationKind == "message" })?.body,
                    lastMessageAt: messages.last?.createdAt, messageCount: messages.count,
                    deliveryState: nil, hasUnread: hasUnread ?? false, isArchived: isArchived, isPinned: false)
    }
    public var rows: [ReadRow] {
        messages.filter { $0.presentationKind == "message" || ($0.presentationKind == "status" && $0.authorKind != "user" && $0.outcome == "completed") || (collaboration == nil && ($0.outcome == "failed" || $0.outcome == "interrupted" || $0.outcome == "timed_out")) }.map {
            ReadRow(id: $0.authorKind == "user" ? "user-" + ($0.clientMessageId ?? $0.messageId) : $0.messageId, author: $0.authorKind == "user" ? "You" : ($0.authorBotName ?? "Unknown Bot"), text: $0.body,
                    isUser: $0.authorKind == "user", timestamp: $0.createdAt, authorId: $0.authorBotId, attachmentIds: $0.attachmentIds ?? [], groupStatus: ($0.presentationKind == "status" && $0.authorKind != "user" && $0.outcome == "completed") ? $0.body : nil)
        }.sorted { $0.time < $1.time }
    }
}
public struct GroupMember: Codable, Identifiable, Sendable {
    public let botId: String
    public let botName: String
    public let role: String
    public var id: String { botId }
}
public struct GroupMessage: Codable, Sendable {
    public var attachmentIds: [String]?
    public var clientMessageId: String?
    public var authorBotId: String?
    public var state: String?
    public let messageId: String
    public let body: String
    public let createdAt: String
    public let authorKind: String
    public let authorBotName: String?
    public let presentationKind: String
    public let outcome: String?
}

private enum ReadTimestamp {
    // FormatStyle is a Sendable value; Foundation caches its parsing machinery.
    // Do not construct an ISO8601DateFormatter for every row on each view update.
    static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    static func seconds(_ value: String) -> Double? {
        ((try? fractional.parse(value)) ?? (try? whole.parse(value)))?.timeIntervalSince1970
    }
}

public struct ReadRow: Identifiable, Sendable {
    public let groupStatus: String?
    public let attachmentIds: [String]
    /// Set when another thread, or Wonder reporting finished tasks, wrote this.
    public let source: MessageSource?
    /// Prepared while projecting the cached row so command wrapper scanning
    /// never runs from a SwiftUI body update.
    public let commandSummary: CommandSummary?
    public let fileChangeSummary: FileChangeSummary?
    public let id: String
    public let author: String
    public let authorId: String?
    public let text: String
    public let isUser: Bool
    public let timestamp: String
    public let time: Double
    public let turnId: String?
    public let item: ReadItem?
    /// Prepared once per projected row. Timeline grouping reads these for every
    /// row; recomputing them decoded tool JSON on every SwiftUI update.
    public private(set) var profileStatus: String?
    public private(set) var activitySummary: ActivityPresentation?
    public private(set) var toolFiles: [ConversationFile] = []
    public private(set) var nativeQuestion: NativeQuestionPresentation?
    private let nativeQuestionReplies: [NativeQuestionReply]?
    /// Commentary is visible Bot speech, never private reasoning or a tool result.
    public var isCommentary: Bool { !isUser && item?.type == "agentMessage" && item?.payload?["phase"]?.string == "commentary" }
    public init(id: String, author: String, text: String, isUser: Bool, timestamp: String, authorId: String? = nil,
                turnId: String? = nil, item: ReadItem? = nil, attachmentIds: [String] = [], groupStatus: String? = nil,
                source: MessageSource? = nil) {
        self.groupStatus = groupStatus
        self.attachmentIds = attachmentIds
        self.source = source
        self.turnId = turnId; self.item = item
        self.commandSummary = item.flatMap(CommandSummary.prepare)
        self.fileChangeSummary = item.flatMap(FileChangeSummary.prepare)
        nativeQuestion = item.flatMap(NativeQuestionPresentation.prepare)
        nativeQuestionReplies = isUser ? NativeQuestionReply.parse(text) : nil
        self.id = id; self.author = author; self.authorId = authorId
        self.text = nativeQuestionReplies?.map { $0.question + "\n" + $0.answer }.joined(separator: "\n\n") ?? text
        self.isUser = isUser; self.timestamp = timestamp
        time = Double(timestamp).map { $0 / 1000 } ?? ReadTimestamp.seconds(timestamp) ?? 0
        profileStatus = makeProfileStatus()
        activitySummary = presentation(includeDetails: false)
        toolFiles = makeToolFiles()
    }

    static func reconcilingQuestions(_ rows: [Self]) -> [Self] {
        var rows = rows
        let questions = Dictionary(rows.indices.compactMap { index -> (String, Int)? in
            guard rows[index].nativeQuestion != nil, let id = rows[index].item?.id else { return nil }
            return (id, index)
        }, uniquingKeysWith: { first, _ in first })
        var answeredReplyIDs = Set<String>()
        for row in rows {
            guard let replies = row.nativeQuestionReplies else { continue }
            var matched = 0
            for reply in replies {
                guard let target = reply.target, let index = questions[target.itemID],
                      let form = rows[index].nativeQuestion, form.questions.indices.contains(target.index),
                      form.questions[target.index].title == reply.question else { continue }
                rows[index].nativeQuestion?.answers[target.index] = reply.answer
                matched += 1
            }
            // A paged answer stays readable until all its questions are loaded.
            // Attachments remain visible even when the form owns the reply text.
            if matched == replies.count, row.attachmentIds.isEmpty { answeredReplyIDs.insert(row.id) }
        }
        return rows.filter { !answeredReplyIDs.contains($0.id) }
    }
}

// A single atomic replacement contains both invalidations and their replay cursor.
// Intent is stored independently and is never touched by cache replacement.
public struct ReadStore: Sendable {
    public let directory: URL
    public init(root: URL, host: String, device: String) {
        let partition = SHA256.hash(data: Data((host + "\n" + device).utf8)).map { String(format: "%02x", $0) }.joined()
        directory = root.appendingPathComponent(partition, isDirectory: true)
    }
    public func load() throws -> ProjectionState {
        let url = directory.appendingPathComponent("read-cache-v2.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ProjectionState() }
        return try JSONDecoder().decode(ProjectionState.self, from: Data(contentsOf: url))
    }
    /// Returns the encoded size so diagnostics can relate write time to cache size.
    @discardableResult public func save(_ state: ProjectionState) throws -> Int {
        let data = try JSONEncoder().encode(state)
        try write(data, name: "read-cache-v2.json")
        return data.count
    }
    public func savePosition(_ position: String, conversation: String) throws {
        try saveIntent(JSONEncoder().encode(position), conversation: "reading-position-v1:" + conversation)
    }
    public func loadPosition(conversation: String) throws -> String? {
        guard let data = try loadIntent(conversation: "reading-position-v1:" + conversation) else { return nil }
        return try JSONDecoder().decode(String.self, from: data)
    }
    public func remove() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
    public func saveIntent(_ data: Data, conversation: String) throws {
        try write(data, name: intentURL(conversation: conversation).lastPathComponent)
    }
    public func removeIntent(conversation: String) throws {
        let url = intentURL(conversation: conversation)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public func loadIntent(conversation: String) throws -> Data? {
        let url = intentURL(conversation: conversation)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
    /// An atomic intent replacement gets a new file identity. A small draft
    /// overlay can use this token to avoid restoring text from an older intent
    /// after Send or another full composer mutation has committed.
    public func intentRevision(conversation: String) throws -> String {
        let url = intentURL(conversation: conversation)
        guard FileManager.default.fileExists(atPath: url.path) else { return "missing" }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let number = attributes[.systemFileNumber] as? NSNumber,
           let modified = attributes[.modificationDate] as? Date,
           let size = attributes[.size] as? NSNumber {
            return "\(number):\(modified.timeIntervalSince1970.bitPattern):\(size)"
        }
        // File identity is unavailable on some test filesystems. Keep the
        // ordering guarantee there even if checking the token costs more.
        return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    private func intentURL(conversation: String) -> URL {
        let name = SHA256.hash(data: Data(conversation.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("intent-" + name + ".json")
    }
    private func write(_ data: Data, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try data.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        #endif
    }
}

/// Writes the read projection away from the caller's thread. The whole cache
/// can be megabytes, and replay/refresh can replace it several times a second,
/// so writes are coalesced to the newest pending state. Each write is still one
/// atomic replacement of a consistent state, and the serial queue guarantees an
/// older state never lands after a newer one. Removal shares the queue, so a
/// write accepted before `remove()` cannot recreate a forgotten cache.
public final class ProjectionWriter: @unchecked Sendable {
    public let store: ReadStore
    // Replacement models can own the same partition. Serialize their loads,
    // final writes and removals without blocking the UI during ownership changes.
    private static let worker = DispatchQueue(label: "wonder.read-cache.writer", qos: .utility)
    private var queue: DispatchQueue { Self.worker }
    private let lock = NSLock()
    private let delay: DispatchTimeInterval
    private let completion: @Sendable (Result<Int, Error>, TimeInterval) -> Void
    private var pending: ProjectionState?
    private var scheduled = false
    private var retired = false

    /// `completion` runs on the writer queue after each write with the encoded
    /// size (or error) and the elapsed write time.
    public init(store: ReadStore, delay: DispatchTimeInterval = .milliseconds(750),
                completion: @escaping @Sendable (Result<Int, Error>, TimeInterval) -> Void = { _, _ in }) {
        self.store = store
        self.delay = delay
        self.completion = completion
    }

    public func schedule(_ state: ProjectionState) {
        lock.lock(); defer { lock.unlock() }
        guard !retired else { return }
        pending = state
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [self] in drain() }
    }

    /// Persists the newest pending state now, without waiting for the delay.
    public func flush(then done: @escaping @Sendable () -> Void = {}) {
        queue.async { [self] in drain(); done() }
    }

    public func flush() async {
        await withCheckedContinuation { continuation in
            flush(then: { continuation.resume() })
        }
    }

    public static func load(_ store: ReadStore) async throws -> ProjectionState {
        try await withCheckedThrowingContinuation { continuation in
            worker.async { continuation.resume(with: Result { try store.load() }) }
        }
    }

    /// Stops accepting writes, drops pending ones and removes the cache
    /// directory after any write already in progress.
    public func remove() async throws {
        lock.withLock { retired = true; pending = nil }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in continuation.resume(with: Result { try store.remove() }) }
        }
    }

    /// Stops accepting writes and queues the newest accepted state for saving.
    public func retire() {
        lock.withLock { retired = true }
        flush(then: {})
    }

    private func drain() {
        lock.lock()
        scheduled = false
        let state = pending
        pending = nil
        lock.unlock()
        guard let state else { return }
        let start = Date()
        do { completion(.success(try store.save(state)), Date().timeIntervalSince(start)) }
        catch { completion(.failure(error), Date().timeIntervalSince(start)) }
    }
}

public struct GroupCollaboration: Codable, Sendable {
    public var configuration: Configuration
    /// The provider that lists the group's model, as sent by the host.
    public var agentFamily: String? = nil
    public var family: AgentFamily { AgentFamily(host: agentFamily) }
    public var runs: [Run]
    public struct Configuration: Codable, Sendable {
        public var instructions: String
        public var routing: NewBotDefaults
        public var workspace: String
        public var needsPurpose: Bool
    }
    public struct Run: Codable, Identifiable, Sendable {
        public var parentMessageId: String
        public var plan: Plan
        public var id: String { parentMessageId }
    }
    public struct Plan: Codable, Sendable {
        public var assignments: [Assignment]
        public var startedAt: String
        public var finishedAt: String?
        public var error: String?
        public var cancelled: Bool
    }
    public struct Assignment: Codable, Identifiable, Sendable {
        public var botId: String
        public var brief: String
        public var dependsOn: [String]
        public var access: String
        public var state: String
        public var outputId: String?
        public var conversationId: String?
        public var id: String { botId }
    }
}
