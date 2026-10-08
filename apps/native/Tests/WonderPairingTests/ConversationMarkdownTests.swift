import XCTest
@testable import WonderPairing

final class ConversationMarkdownTests: XCTestCase {
    func testSpeakersMessagesAndActivityBecomeReadableMarkdown() {
        let rows = [
            user("u1", "Fix the **build**"),
            tool("c1", "commandExecution", ["command": .string("/bin/zsh -lc 'swift test'"), "output": .string("SECRET OUTPUT"), "durationMs": .number(5_000)]),
            tool("f1", "fileChange", ["paths": .array([.string("src/App.swift")]), "diffs": .array([.object(["path": .string("src/App.swift"), "kind": .string("update"), "diff": .string("+secret diff")])])]),
            tool("t1", "reasoning", [:]),
            agent("a1", "Done. All tests pass."),
            user("u2", "Thanks")
        ]
        let output = ConversationMarkdown.render(title: "Fix build", agentName: "Codex", rows: rows, isPartial: false)
        XCTAssertEqual(output.markdown, """
        # Fix build

        ## You

        Fix the **build**

        ## Wonder Agent

        - Ran `swift test` for 5s
        - Edited App.swift

        Done. All tests pass.

        ## You

        Thanks

        """)
        XCTAssertEqual(output.messageCount, 3)
        XCTAssertEqual(output.confirmation, "Copied 3 messages")
        XCTAssertFalse(output.markdown.contains("SECRET"))
        XCTAssertFalse(output.markdown.contains("secret diff"))
    }

    func testPartialHistoryIsSaidInTheTextAndTheConfirmation() {
        let output = ConversationMarkdown.render(title: "", agentName: "Codex", rows: [user("u1", "Hi")], isPartial: true)
        XCTAssertTrue(output.markdown.hasPrefix("# Conversation\n\n_Earlier messages are not included._"))
        XCTAssertEqual(output.confirmation, "Copied 1 message. Earlier messages are not loaded yet.")
    }

    func testAnEmptyConversationCopiesNoMessages() {
        let output = ConversationMarkdown.render(title: "Empty", agentName: "Codex", rows: [], isPartial: false)
        XCTAssertEqual(output.messageCount, 0)
        XCTAssertEqual(output.markdown, "# Empty\n")
    }

    private func user(_ id: String, _ text: String) -> ReadRow {
        ReadRow(id: id, author: "You", text: text, isUser: true, timestamp: "1000")
    }
    private func agent(_ id: String, _ text: String) -> ReadRow {
        ReadRow(id: id, author: "Wonder Agent", text: text, isUser: false, timestamp: "1000",
                item: ReadItem(id: id, type: "agentMessage", state: "completed", text: text, createdAt: "1000"))
    }
    private func tool(_ id: String, _ type: String, _ payload: [String: ThreadValue]) -> ReadRow {
        ReadRow(id: id, author: "Wonder Agent", text: "raw tool text", isUser: false, timestamp: "1000", turnId: "t",
                item: ReadItem(id: id, type: type, state: "completed", text: nil, createdAt: "1000", payload: payload))
    }
}
