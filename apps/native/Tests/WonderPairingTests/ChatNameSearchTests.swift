import XCTest
@testable import WonderPairing

final class ChatNameSearchTests: XCTestCase {
    private func chat(_ id: String, title: String, bot: String? = nil) -> ChatSummary {
        ChatSummary(conversationId: id, botId: bot, title: title, lastMessagePreview: "Do not match message content", lastMessageAt: nil,
            messageCount: 3, deliveryState: nil, hasUnread: true, isArchived: false, isPinned: true)
    }
    func testFindsBotAndGroupNamesIgnoringCaseDiacriticsAndQueryWhitespace() {
        let bot = chat("direct", title: "José", bot: "jose")
        let group = chat("group", title: "Café Development")
        XCTAssertTrue(bot.matchesName("  JOSE\n"))
        XCTAssertTrue(group.matchesName("cafe"))
        XCTAssertTrue(group.matchesName("DEVELOP"))
        XCTAssertFalse(group.matchesName("message content"))
        XCTAssertFalse(group.matchesName("group"))
        XCTAssertTrue(bot.matchesName(" \n"))
    }
    func testCachedNamesPreserveOrderIdentityAndUnreadWithoutNetwork() throws {
        let source = [chat("group", title: "Wonder Development"), chat("other", title: "Weekend"), chat("direct", title: "Wonder Builder", bot: "builder")]
        let cached = try JSONDecoder().decode([ChatSummary].self, from: JSONEncoder().encode(source))
        let result = cached.filter { $0.matchesName("wonder") }
        XCTAssertEqual(result, [source[0], source[2]])
        XCTAssertTrue(result.allSatisfy(\.hasUnread))
        XCTAssertTrue(result.allSatisfy(\.isPinned))
        XCTAssertEqual(cached.filter { $0.matchesName("") }, source)
    }
    func testRenameAndRemovalUseCurrentSummariesWithoutStaleMatches() {
        var summaries = [chat("group", title: "Launch team")]
        XCTAssertEqual(summaries.filter { $0.matchesName("launch") }.count, 1)
        summaries[0] = chat("group", title: "Design team")
        XCTAssertTrue(summaries.filter { $0.matchesName("launch") }.isEmpty)
        XCTAssertEqual(summaries.filter { $0.matchesName("design") }.map(\.id), ["group"])
        summaries.removeAll()
        XCTAssertTrue(summaries.filter { $0.matchesName("design") }.isEmpty)
    }
}
