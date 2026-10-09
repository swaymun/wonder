import XCTest
@testable import WonderPairing

/// Prompts as the host projects them from Claude Code transcripts: a command
/// entry joined to its output entry (claude-runtime `nativeTurns`).
final class ClaudeCommandBlockTests: XCTestCase {
    private func row(_ text: String) -> ReadRow { ReadRow(id: "user-1", author: "You", text: text, isUser: true, timestamp: "1000") }

    func testShellCommandKeepsCommandOutputAndErrorsApart() throws {
        let row = row("<bash-input>git status --short && ls nope</bash-input>\n<bash-stdout> M README.md\n?? notes/</bash-stdout><bash-stderr>ls: nope: No such file or directory</bash-stderr>")
        let block = try XCTUnwrap(row.commandBlock)
        XCTAssertEqual(block.kind, .shell)
        XCTAssertEqual(block.command, "git status --short && ls nope")
        XCTAssertEqual(block.output, " M README.md\n?? notes/")
        XCTAssertEqual(block.errorOutput, "ls: nope: No such file or directory")
        // Copy and Markdown export read the row text: no markup.
        XCTAssertEqual(row.text, "$ git status --short && ls nope\n\n M README.md\n?? notes/\n\nls: nope: No such file or directory")
    }

    func testSlashCommandsShowNameArgumentsAndPlainOutput() throws {
        let local = try XCTUnwrap(row("<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args></command-args>\n<local-command-stdout>Set model to \u{1B}[1mOpus\u{1B}[22m</local-command-stdout>").commandBlock)
        XCTAssertEqual([local.command, local.arguments, local.output], ["/model", "", "Set model to Opus"])
        let prompt = try XCTUnwrap(row("<command-message>review is running…</command-message>\n<command-name>/review</command-name>\n<command-args>42</command-args>").commandBlock)
        XCTAssertEqual(prompt.kind, .slash)
        XCTAssertEqual([prompt.command, prompt.arguments], ["/review", "42"])
        XCTAssertTrue(prompt.notes.isEmpty)
        let failed = try XCTUnwrap(row("<command-name>/mcp</command-name>\n<local-command-stderr>No MCP servers configured</local-command-stderr>").commandBlock)
        XCTAssertEqual(failed.errorOutput, "No MCP servers configured")
    }

    func testUnknownTagsAndStrayTextStayReadable() throws {
        let row = row("<bash-input>make</bash-input>\n<bash-exit-code>2</bash-exit-code>\nextra words\n<bash-stdout>built</bash-stdout><command-args>stray</command-args>")
        let block = try XCTUnwrap(row.commandBlock)
        XCTAssertEqual(block.output, "built")
        XCTAssertEqual(block.notes, ["2", "extra words", "stray"])
        XCTAssertTrue(row.text.contains("extra words"))
    }

    func testProseThatMentionsATagIsNotACommand() {
        XCTAssertNil(row("Render `<bash-input>` blocks as cards").commandBlock)
        XCTAssertNil(row("Please run <bash-input>ls</bash-input>").commandBlock)
        XCTAssertNil(row("<task-notification>done</task-notification>").commandBlock)
        XCTAssertNil(ReadRow(id: "a", author: "Claude", text: "<bash-input>ls</bash-input>", isUser: false, timestamp: "1").commandBlock)
    }
}
