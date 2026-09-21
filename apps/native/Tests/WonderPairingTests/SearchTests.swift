import XCTest
@testable import WonderPairing

final class SearchTests: XCTestCase {
    private func result(_ id: String = "message", kind: String = "message", snippet: String = "A <mark>match</mark> <script>literal</script>") throws -> PersistedSearchResult {
        let json: [String: Any] = ["id":id,"kind":kind,"title":"Ada","snippet":snippet,"conversationId":"chat","updatedAt":"1000"]
        return try JSONDecoder().decode(PersistedSearchResult.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func testLivePagesDeduplicateKindAndIDAndKeepLiteralSnippetText() throws {
        var page = PersistedSearchPage(results: [try result()], nextCursor: "one")
        page.append(PersistedSearchPage(results: [try result(snippet:"Edited"), try result(kind:"assistant_message")], nextCursor:nil))
        XCTAssertEqual(page.results.count, 2)
        XCTAssertEqual(page.results[0].plainSnippet, "Edited")
        XCTAssertEqual(try result().plainSnippet, "A match <script>literal</script>")
        XCTAssertNil(page.nextCursor)
        let decoded = try JSONDecoder().decode(PersistedSearchPage.self, from: JSONEncoder().encode(page))
        XCTAssertEqual(decoded.results.map(\.identity), ["message:message","assistant_message:message"])
    }
    func testSearchCacheBoundsQueriesAndPreservesContinuationAtItsSavedBoundary() throws {
        var cache = PersistedSearchCache()
        for n in 0...10 { cache.remember(PersistedSearchPage(results:[try result("\(n)")], nextCursor:"next-\(n)"), query:"q\(n)") }
        XCTAssertNil(cache.pages["q0"])
        XCTAssertEqual(cache.pages.count, 10)
        cache.remember(PersistedSearchPage(results:try (0...300).map { try result("\($0)") }, nextCursor:"too-far"), query:"q10")
        XCTAssertEqual(cache.pages["q10"]?.nextCursor, "next-10")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ReadStore(root:root, host:"mac", device:"phone")
        try first.saveIntent(JSONEncoder().encode(cache), conversation:"search-cache-v1")
        XCTAssertNil(try ReadStore(root:root, host:"other", device:"phone").loadIntent(conversation:"search-cache-v1"))
        XCTAssertNil(try ReadStore(root:root, host:"mac", device:"other").loadIntent(conversation:"search-cache-v1"))
        let restored = try JSONDecoder().decode(PersistedSearchCache.self, from:XCTUnwrap(first.loadIntent(conversation:"search-cache-v1")))
        XCTAssertEqual(restored.pages["q10"]?.results.first?.id, "10")
    }
    func testCanonicalUserAndAssistantIDsResolveAfterHistoryMerge() throws {
        let empty = #"{"conversationId":"chat","hostEpoch":"epoch","lastSequence":5,"messages":[],"assistantMessages":[],"thread":{"hydrated":true}}"#
        let older = #"{"conversationId":"chat","hostEpoch":"epoch","lastSequence":4,"messages":[{"messageId":"message","clientMessageId":"client","body":"User text","state":"completed","createdAt":"1000","attachmentIds":[]}],"assistantMessages":[{"messageId":"answer","codexTurnId":"turn","itemId":"item","text":"Answer text","state":"completed","createdAt":"1000","updatedAt":"1000"}],"thread":{"hydrated":true}}"#
        let current = try JSONDecoder().decode(ConversationSnapshot.self, from:Data(empty.utf8))
        XCTAssertNil(try result().rowID(snapshot:current, group:nil))
        let merged = try current.mergingOlder(JSONDecoder().decode(ConversationSnapshot.self, from:Data(older.utf8)))
        XCTAssertEqual(try result().rowID(snapshot:merged, group:nil), "user-client")
        XCTAssertEqual(try result("answer", kind:"assistant_message").rowID(snapshot:merged, group:nil), "turn/item")
        XCTAssertNil(try result("deleted").rowID(snapshot:merged, group:nil))
        let canonical = try XCTUnwrap(result().rowID(snapshot:merged, group:nil))
        let displayed = ChatFeedEntry.grouping(ChatFeedEntry.visibleRows(merged.rows(author:"Ada"), queuedClientIDs:["client"]), focusedRowID:canonical)
        XCTAssertFalse(displayed.contains { $0.rows.contains { $0.id == canonical } })
        XCTAssertTrue(displayed.contains { $0.rows.contains { $0.id == "turn/item" } })
        let unqueued = ChatFeedEntry.grouping(ChatFeedEntry.visibleRows(merged.rows(author:"Ada"), queuedClientIDs:[]), focusedRowID:canonical)
        XCTAssertTrue(unqueued.contains { $0.id == canonical })
    }
    func testGroupPublicMessageUsesCanonicalIDAndRejectsRawAssistant() throws {
        let json = #"{"id":"group","conversationId":"chat","name":"Developers","isArchived":false,"messages":[{"messageId":"message","body":"Public answer","createdAt":"1000","authorKind":"bot","authorBotName":"Builder","presentationKind":"message"}]}"#
        let group = try JSONDecoder().decode(GroupRead.self, from:Data(json.utf8))
        XCTAssertEqual(try result().rowID(snapshot:nil, group:group), "message")
        XCTAssertNil(try result(kind:"assistant_message").rowID(snapshot:nil, group:group))
    }
}
