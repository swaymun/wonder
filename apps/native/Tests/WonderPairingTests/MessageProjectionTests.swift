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
    // A message another thread wrote keeps its source through decoding and rows,
    // so the bubble can say who wrote it; a wake-up becomes a system row.
    func testMessagesFromOtherThreadsCarryTheirSourceIntoRows() throws {
        let json = #"{"conversationId":"chat","hostEpoch":"epoch","lastSequence":2,"assistantMessages":[],"thread":{"nextCursor":null,"hydrated":true,"turns":[]},"messages":[{"clientMessageId":"c1","messageId":"m1","body":"Please review","state":"completed","createdAt":"1000","attachmentIds":[],"source":{"kind":"thread","sourceConversationId":"planner","sourceTitle":"Planner"}},{"clientMessageId":"c2","messageId":"m2","body":"Automatic message","state":"completed","createdAt":"2000","attachmentIds":[],"source":{"kind":"wake","sourceTitle":"Agent tasks finished: Tests (completed)"}},{"clientMessageId":"c3","messageId":"m3","body":"Mine","state":"completed","createdAt":"3000","attachmentIds":[]}]}"#
        let snapshot = try JSONDecoder().decode(ConversationSnapshot.self, from: Data(json.utf8))
        let rows = snapshot.rows(author: "Ada")
        XCTAssertEqual(rows.map { $0.source?.fromLabel }, ["From Planner", nil, nil])
        XCTAssertEqual(rows[1].source?.isWake, true)
        XCTAssertEqual(rows[1].source?.sourceTitle, "Agent tasks finished: Tests (completed)")
        XCTAssertNil(rows[2].source)
        let cached = try JSONDecoder().decode(ConversationSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(cached.rows(author: "Ada").map { $0.source?.kind }, ["thread", "wake", nil])
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
    func testNativeQuestionAndReplyRenderAsOneSavedFormAfterCacheAndPaging() throws {
        let form = ReadItem(id: "call-question", type: "agentMessage", state: "completed", text: "Which day?", createdAt: "1000",
            payload: ["delivery": .string("async"), "questions": .array([
                .object(["title": .string("Which day?"), "options": .array([.string("Saturday"), .string("Sunday")])]),
                .object(["title": .string("What should we check?"), "options": .null])
            ])])
        let body = #"<send_user_message_question_reply>[{"questionItemId":"[\"request_user_input_async\",\"call-question\",0]","question":"Which day?","answer":"Saturday"},{"questionItemId":"[\"request_user_input_async\",\"call-question\",1]","question":"What should we check?","answer":"Navigation"}]</send_user_message_question_reply>"#
        let reply = ReadItem(id: "reply", type: "userMessage", state: "completed", text: body, createdAt: "2000")
        let original = snapshot([form, reply], clients: [])
        let cached = try JSONDecoder().decode(ConversationSnapshot.self, from: JSONEncoder().encode(original))
        let paged = try snapshot([reply], clients: []).mergingOlder(snapshot([form], clients: []))
        for value in [original, cached, paged] {
            let rows = value.rows(author: "Ada")
            XCTAssertEqual(rows.map(\.id), ["turn/call-question"])
            let question = try XCTUnwrap(rows.first?.nativeQuestion)
            XCTAssertEqual(question.questions.first?.options, ["Saturday", "Sunday"])
            XCTAssertEqual(question.answers, [0: "Saturday", 1: "Navigation"])
            XCTAssertTrue(question.isAnswered)
        }
        let unloaded = try XCTUnwrap(snapshot([reply], clients: []).rows(author: "Ada").first)
        XCTAssertEqual(unloaded.text, "Which day?\nSaturday\n\nWhat should we check?\nNavigation")
        XCTAssertTrue(unloaded.isUser)
    }
    func testNativeQuestionReplyNeverHidesUnmatchedOrMalformedInputOrAttachments() throws {
        let form = ReadItem(id: "call-question", type: "agentMessage", state: "completed", text: "", createdAt: "1000",
            payload: ["delivery": .string("async"), "questions": .array([.object(["title": .string("Which day?")])])])
        let body = #"<send_user_message_question_reply>[{"questionItemId":"[\"request_user_input_async\",\"call-question\",0]","question":"Different question","answer":"Saturday"}]</send_user_message_question_reply>"#
        let reply = ReadItem(id: "reply", type: "userMessage", state: "completed", text: body, createdAt: "2000")
        let rows = snapshot([form, reply], clients: []).rows(author: "Ada")
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(try XCTUnwrap(rows.first?.nativeQuestion).isAnswered)
        XCTAssertEqual(rows.last?.text, "Different question\nSaturday")
        for malformed in ["<send_user_message_question_reply>broken</send_user_message_question_reply>",
                          body + "\nKeep this additional text.",
                          body.replacingOccurrences(of: "request_user_input_async", with: "unknown") ] {
            XCTAssertEqual(ReadRow(id: "user", author: "You", text: malformed, isUser: true, timestamp: "1").text, malformed)
        }
        let attached = ReadRow(id: "attached", author: "You", text: body.replacingOccurrences(of: "Different question", with: "Which day?"),
                               isUser: true, timestamp: "2000", attachmentIds: ["photo"])
        let withAttachment = ReadRow.reconcilingQuestions([try XCTUnwrap(rows.first), attached])
        XCTAssertEqual(withAttachment.count, 2)
        XCTAssertEqual(withAttachment.last?.attachmentIds, ["photo"])
        XCTAssertTrue(try XCTUnwrap(withAttachment.first?.nativeQuestion).isAnswered)
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
