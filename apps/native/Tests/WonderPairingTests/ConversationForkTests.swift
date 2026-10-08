import XCTest
@testable import WonderPairing

final class ConversationForkTests: XCTestCase {
    func testRequestNamesTheTurnOnlyWhenForkingFromAReply() throws {
        let from = try ForkConversationRequest(lastTurnId: "turn-2").body()
        XCTAssertEqual(try JSONSerialization.jsonObject(with: from) as? [String: String], ["lastTurnId": "turn-2"])
        let latest = try ForkConversationRequest(lastTurnId: nil).body()
        XCTAssertEqual(String(decoding: latest, as: UTF8.self), "{}")
    }

    func testOnlyAFinishedAgentReplyOffersFork() {
        let reply = row(isUser: false, type: "agentMessage", state: "completed")
        XCTAssertEqual(ConversationFork.turnID(of: reply, turnFinished: true), "turn-1")
        XCTAssertNil(ConversationFork.turnID(of: reply, turnFinished: false), "the turn is still running")
        XCTAssertNil(ConversationFork.turnID(of: row(isUser: false, type: "agentMessage", state: "streaming"), turnFinished: true))
        XCTAssertNil(ConversationFork.turnID(of: row(isUser: true, type: "userMessage", state: "completed"), turnFinished: true))
        XCTAssertNil(ConversationFork.turnID(of: row(isUser: false, type: "agentMessage", state: "completed", phase: "commentary"), turnFinished: true))
        XCTAssertNil(ConversationFork.turnID(of: row(isUser: false, type: "commandExecution", state: "completed"), turnFinished: true))
    }

    func testHeaderForkNeedsAStartedIdleUnarchivedThread() {
        XCTAssertTrue(ConversationFork.canForkLatest(hasNativeSession: true, hasActiveTurn: false, isArchived: false))
        XCTAssertFalse(ConversationFork.canForkLatest(hasNativeSession: false, hasActiveTurn: false, isArchived: false))
        XCTAssertFalse(ConversationFork.canForkLatest(hasNativeSession: true, hasActiveTurn: true, isArchived: false))
        XCTAssertFalse(ConversationFork.canForkLatest(hasNativeSession: true, hasActiveTurn: false, isArchived: true))
    }

    func testFailuresAreExplainedInPlainLanguage() {
        XCTAssertTrue(ConversationFork.failureMessage(status: 409, computer: "Mac").contains("busy"))
        XCTAssertTrue(ConversationFork.failureMessage(status: 404, computer: "Studio").contains("Studio"))
        XCTAssertTrue(ConversationFork.failureMessage(status: nil, computer: "Mac").contains("try again"))
    }

    private func row(isUser: Bool, type: String, state: String, phase: String? = nil) -> ReadRow {
        var payload: [String: ThreadValue] = [:]
        if let phase { payload["phase"] = .string(phase) }
        return ReadRow(id: "row", author: "Agent", text: "Done", isUser: isUser, timestamp: "1000", turnId: "turn-1",
                       item: ReadItem(id: "row", type: type, state: state, text: "Done", createdAt: "1000", payload: payload))
    }
}
