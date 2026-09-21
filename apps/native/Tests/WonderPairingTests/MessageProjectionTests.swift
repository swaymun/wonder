import XCTest
@testable import WonderPairing

final class MessageProjectionTests: XCTestCase {
    private func snapshot(_ items: [ReadItem], clients: [String] = ["client"]) -> ConversationSnapshot {
        ConversationSnapshot(conversationId: "chat", hostEpoch: "epoch", lastSequence: 2,
            messages: clients.enumerated().map { index, client in
                ConversationMessage(clientMessageId: client, codexTurnId: "turn", messageId: "stored-\(index)",
                    body: "Same message", state: "completed", createdAt: "1000", attachmentIds: [])
            }, assistantMessages: [], thread: ThreadProjection(nextCursor: nil, hydrated: true,
                turns: [ReadTurn(id: "turn", items: items)]))
    }
    private func echo(_ id: String, client: String?) -> ReadItem {
        ReadItem(id: id, type: "userMessage", state: "completed", text: "Runtime-wrapped input", createdAt: "0",
                 payload: client.map { ["clientId": .string($0)] })
    }
    func testQuestionOnlyEmptyReplyDoesNotRenderBubble() {
        let rows = snapshot([ReadItem(id: "question", type: "agentMessage", state: "completed", text: "  ", createdAt: "1")], clients: []).rows(author: "Ada")
        XCTAssertTrue(rows.isEmpty)
    }
    func testAnsweredQuestionIncludesDurableSelection() throws {
        let json = #"{"id":"q","conversationId":"chat","turnId":"turn","itemId":"question","questions":[{"title":"What next?","options":["Code","Design"]}],"state":"answered","expiresAtMs":100,"response":{"answers":["Code"],"skip":false}}"#
        let question = try JSONDecoder().decode(AsyncQuestion.self, from: Data(json.utf8))
        XCTAssertEqual(question.response?.answers, ["Code"])
        XCTAssertFalse(question.canAnswer(now: 1))
    }
    func testRuntimeEchoUsesCanonicalBodyIdentityAndTimestamp() throws {
        let original = snapshot([echo("runtime", client: "client")])
        let cached = try JSONDecoder().decode(ConversationSnapshot.self, from: JSONEncoder().encode(original))
        for value in [original, cached, try original.mergingOlder(cached)] {
            let rows = value.rows(author: "Ada")
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].id, "user-client")
            XCTAssertEqual(rows[0].text, "Same message")
            XCTAssertEqual(rows[0].timestamp, "1000")
        }
    }
    func testIdenticalIntentionalSendsStaySeparateIncludingGuideInSameTurn() {
        let rows = snapshot([echo("runtime-a", client: "a"), echo("runtime-b", client: "b")], clients: ["a", "b"]).rows(author: "Ada")
        XCTAssertEqual(Set(rows.map(\.id)), ["user-a", "user-b"])
        XCTAssertEqual(rows.count, 2)
    }
    func testRuntimeItemsWithoutClientIdUseOnlyUnambiguousTurnMatch() {
        XCTAssertEqual(snapshot([echo("runtime", client: nil)]).rows(author: "Ada").count, 1)
        let ambiguous = snapshot([echo("runtime", client: nil)], clients: ["a", "b"]).rows(author: "Ada")
        XCTAssertEqual(ambiguous.count, 3) // Never silently drop an unmatched user message.
    }
    func testDuplicateRuntimeEchoesCollapseByClientIdentity() {
        XCTAssertEqual(snapshot([echo("one", client: "client"), echo("two", client: "client")]).rows(author: "Ada").count, 1)
    }
    func testToolPayloadSurvivesCacheAndRowProjection() throws {
        let json = #"{"id":"tool","type":"mcpToolCall","state":"failed","text":null,"createdAt":"2000","payload":{"tool":"search","arguments":{"query":"hello"},"result":[{"text":"result"}],"error":"Unavailable","durationMs":42,"futureField":true}}"#
        let item = try JSONDecoder().decode(ReadItem.self, from: Data(json.utf8))
        let value = snapshot([item], clients: [])
        let cached = try JSONDecoder().decode(ConversationSnapshot.self, from: JSONEncoder().encode(value))
        let row = try XCTUnwrap(cached.rows(author: "Ada").first)
        XCTAssertEqual(row.turnId, "turn")
        XCTAssertEqual(row.item?.type, "mcpToolCall")
        XCTAssertEqual(row.item?.state, "failed")
        XCTAssertEqual(row.item?.payload, item.payload)
        XCTAssertEqual(row.item?.payload?["durationMs"]?.number, 42)
    }
    func testCommentaryAndFinalKeepProtocolOrderAcrossCacheAndHistory() throws {
        // App Server items often share a hydration timestamp; IDs are not chronology.
        let items = [
            ReadItem(id: "z-comment", type: "agentMessage", state: "completed", text: "I’ll check the files.", createdAt: "1000", payload: ["phase": .string("commentary")]),
            ReadItem(id: "m-tool", type: "dynamicToolCall", state: "completed", text: nil, createdAt: "1000"),
            ReadItem(id: "a-final", type: "agentMessage", state: "completed", text: "The check passed.", createdAt: "1000", payload: ["phase": .string("final_answer")])
        ]
        let original = snapshot(items, clients: [])
        let cached = try JSONDecoder().decode(ConversationSnapshot.self, from: JSONEncoder().encode(original))
        for value in [original, cached, try original.mergingOlder(cached)] {
            let rows = value.rows(author: "Ada")
            XCTAssertEqual(rows.map(\.id), ["turn/z-comment", "turn/m-tool", "turn/a-final"])
            XCTAssertEqual(rows.map(\.isCommentary), [true, false, false])
            XCTAssertEqual(rows.first?.text, "I’ll check the files.")
        }
    }

    func testHistoryMergeKeepsTurnOrderWithEqualTimestamps() {
        func turn(_ id: String) -> ReadTurn {
            ReadTurn(id: id, items: [ReadItem(id: id, type: "agentMessage", state: "completed", text: id, createdAt: "1000")])
        }
        let older = ThreadProjection(nextCursor: nil, hydrated: true, turns: [turn("z"), turn("m")])
        let newer = ThreadProjection(nextCursor: nil, hydrated: true, turns: [turn("m"), turn("a")])
        XCTAssertEqual(newer.mergingOlder(older).turns?.map(\.id), ["z", "m", "a"])
    }

    func testStreamingCommentaryReconcilesWithHydrationWithoutBecomingFinal() throws {
        let item = ReadItem(id: "comment", type: "agentMessage", state: "streaming", text: "Checking", createdAt: "1000", payload: ["phase": .string("commentary")])
        let base = snapshot([item], clients: [])
        let live = AssistantMessage(itemId: "comment", codexTurnId: "turn", messageId: "stored", text: "Checking the files…", state: "streaming", createdAt: "1000", updatedAt: "2000")
        let value = ConversationSnapshot(conversationId: base.conversationId, hostEpoch: base.hostEpoch, lastSequence: 3,
            messages: [], assistantMessages: [live], thread: base.thread)
        let cached = try JSONDecoder().decode(ConversationSnapshot.self, from: JSONEncoder().encode(value))
        let rows = cached.rows(author: "Ada")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].text, "Checking the files…")
        XCTAssertTrue(rows[0].isCommentary)
        XCTAssertEqual(rows[0].item?.state, "streaming")
        let unknown = ReadRow(id: "unknown", author: "Ada", text: "Reply", isUser: false, timestamp: "1000")
        XCTAssertFalse(unknown.isCommentary) // Missing phase stays ordinary visible Bot speech.
    }

}
