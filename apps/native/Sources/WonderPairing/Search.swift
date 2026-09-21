import Foundation

public struct PersistedSearchResult: Codable, Identifiable, Sendable {
    public let kind: String
    public let id: String
    public let title: String
    public let snippet: String?
    public let conversationId: String?
    public let botId: String?
    public let updatedAt: String
    public var identity: String { kind + ":" + id }
    public var plainSnippet: String { (snippet ?? "").replacingOccurrences(of: "<mark>", with: "").replacingOccurrences(of: "</mark>", with: "") }
    public func rowID(snapshot: ConversationSnapshot?, group: GroupRead?) -> String? {
        if let group, group.conversationId == conversationId, kind == "message",
            let message = group.messages.first(where: { $0.messageId == id }) {
            let row = message.authorKind == "user" ? "user-" + (message.clientMessageId ?? message.messageId) : message.messageId
            return group.rows.contains(where: { $0.id == row }) ? row : nil
        }
        guard let snapshot, snapshot.conversationId == conversationId else { return nil }
        let row: String?
        if kind == "message", let message = snapshot.messages.first(where: { $0.messageId == id }) { row = "user-" + (message.clientMessageId ?? message.messageId) }
        else if kind == "assistant_message" { row = snapshot.assistantMessages.first(where: { $0.messageId == id })?.rowId }
        else { row = nil }
        return row.flatMap { target in snapshot.rows(author: title).contains(where: { $0.id == target }) ? target : nil }
    }
}
public struct PersistedSearchPage: Codable, Sendable {
    public var results: [PersistedSearchResult]
    public var nextCursor: String?
    public init(results: [PersistedSearchResult] = [], nextCursor: String? = nil) { self.results = results; self.nextCursor = nextCursor }
    public mutating func append(_ page: Self) {
        // A live page may repeat an edited result; retain one stable row identity.
        for result in page.results {
            if let index = results.firstIndex(where: { $0.identity == result.identity }) { results[index] = result }
            else { results.append(result) }
        }
        nextCursor = page.nextCursor
    }
}
public struct PersistedSearchCache: Codable, Sendable {
    public private(set) var pages: [String: PersistedSearchPage] = [:]
    private var recent: [String] = []
    public init() {}
    public mutating func remember(_ page: PersistedSearchPage, query: String) {
        // Keep at most ten queries and ten pages per query in the host/device store.
        guard page.results.count <= 300 else { return }
        recent.removeAll { $0 == query }; recent.append(query); pages[query] = page
        while recent.count > 10 { pages.removeValue(forKey: recent.removeFirst()) }
    }
}
public struct SearchMessageFocus: Identifiable, Sendable {
    public let id = UUID()
    public let conversationID: String
    public let rowID: String
    public let scrollID: String
    public init(conversationID: String, rowID: String, scrollID: String) { self.conversationID = conversationID; self.rowID = rowID; self.scrollID = scrollID }
}
