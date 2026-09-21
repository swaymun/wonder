import XCTest
@testable import WonderPairing

final class CommandSummaryTests: XCTestCase {
    func testRecognizedPOSIXWrappersStripOnlyAnUnambiguousLaunchPrefix() throws {
        XCTAssertEqual(try summary("/bin/zsh -lc 'swift test'").displayCommand, "swift test")
        XCTAssertEqual(try summary("bash -c \"echo ☃\"").displayCommand, "echo ☃")
        XCTAssertEqual(try summary("env FOO=bar /bin/bash -lc 'swift test'").displayCommand, "swift test")

        // These are ordinary commands, not shell launch wrappers.
        XCTAssertEqual(try summary("command -v jq").displayCommand, "command -v jq")
        XCTAssertEqual(try summary("set -e").displayCommand, "set -e")
    }

    func testAmbiguousWrappersKeepTheFullRawCommand() throws {
        let cases = [
            "/bin/sh -c 'echo one'; echo two",
            "/bin/sh -c 'echo $1' name arg",
            "/bin/sh -c 'echo one'foo",
            "/bin/sh -C 'echo one'",
            "/bin/sh -c echo;pwd",
            "/bin/sh -c $(echo one)",
            "/bin/sh -c echo\\ hi",
            "env FOO=bar; /bin/sh -c echo",
            "pwsh -Command 'echo one'"
        ]
        for command in cases {
            let value = try summary(command)
            XCTAssertEqual(value.displayCommand, command)
            XCTAssertEqual(value.rawCommand, command)
        }
    }

    func testLongUnicodeAndMultilineCommandsStayCompleteInPreparedAccessibility() throws {
        let command = "/bin/zsh -lc 'printf \"☃\"\necho a-very-long-command-with-many-arguments --one --two --three'"
        let value = try summary(command, duration: .number(5_000))
        XCTAssertEqual(value.displayCommand, "printf \"☃\" echo a-very-long-command-with-many-arguments --one --two --three")
        XCTAssertEqual(value.accessibilityLabel,
                       "Ran `printf \"☃\" echo a-very-long-command-with-many-arguments --one --two --three` for 5s")
        XCTAssertFalse(value.accessibilityLabel.contains("…"))
    }

    func testMissingInvalidAndZeroDurationsAreHandledWithoutReceiptGuessing() throws {
        XCTAssertFalse(try summary("echo ok").accessibilityLabel.contains(" for "))
        XCTAssertFalse(try summary("echo ok", duration: .string("not a duration")).accessibilityLabel.contains(" for "))
        XCTAssertFalse(try summary("echo ok", duration: .number(-1)).accessibilityLabel.contains(" for "))
        XCTAssertFalse(try summary("echo ok", duration: .number(.nan)).accessibilityLabel.contains(" for "))
        XCTAssertFalse(try summary("echo ok", duration: .number(1.5)).accessibilityLabel.contains(" for "))
        XCTAssertEqual(try summary("echo ok", duration: .number(0)).accessibilityLabel, "Ran `echo ok` for 0ms")
    }

    func testCommandStatusesStayAccurateIncludingInterruptedExit130() throws {
        XCTAssertEqual(try summary("swift test", state: "started").accessibilityLabel, "Running `swift test`")
        XCTAssertEqual(try summary("swift test", state: "completed", duration: .number(5_000)).accessibilityLabel, "Ran `swift test` for 5s")
        XCTAssertEqual(try summary("swift test", state: "failed", exitCode: 1).accessibilityLabel, "Failed `swift test`")

        let stopped = try row("swift test", state: "interrupted", exitCode: 130,
                              payload: ["error": .string("Interrupted")])
        XCTAssertEqual(stopped.activity?.status, "Stopped")
        XCTAssertFalse(stopped.activity?.failed == true)
        XCTAssertEqual(stopped.commandSummary?.accessibilityLabel, "Stopped `swift test`")

        let exit130WithoutInterruption = try row("swift test", state: "completed", exitCode: 130)
        XCTAssertEqual(exit130WithoutInterruption.activity?.status, "Failed")
    }

    func testRunningCommandDoesNotUseStaleTerminalHints() throws {
        for state in ["started", "streaming", "waiting"] {
            let running = try row("swift test", state: state, exitCode: 1,
                                  payload: ["error": .string("Previous attempt"), "success": .bool(false)])
            XCTAssertEqual(running.commandSummary?.prefix, "Running")
            XCTAssertFalse(running.activity?.failed == true)
            XCTAssertEqual(running.activity?.state, state)
        }
    }

    func testExpandedDetailsRetainRawCommandAndFullOutput() throws {
        let command = "/bin/sh -c 'printf one'; printf two"
        let output = "first output line\nsecond output line"
        let row = try row(command, output: output)
        XCTAssertTrue(row.activitySummary?.details.isEmpty == true)
        let details = try XCTUnwrap(row.activity?.details)
        XCTAssertEqual(details.first(where: { $0.title == "Command" })?.text, command)
        XCTAssertEqual(details.first(where: { $0.title == "Output" })?.text, output)
        XCTAssertTrue(row.commandSummary?.accessibilityLabel.contains(command) == true)
    }

    private func summary(_ command: String, state: String = "completed", duration: ThreadValue? = nil,
                         exitCode: Int64? = nil) throws -> CommandSummary {
        try XCTUnwrap(row(command, state: state, duration: duration, exitCode: exitCode).commandSummary)
    }

    private func row(_ command: String, state: String = "completed", duration: ThreadValue? = nil,
                     exitCode: Int64? = nil, output: String? = nil,
                     payload: [String: ThreadValue] = [:]) throws -> ReadRow {
        var values = payload
        values["command"] = .string(command)
        if let duration { values["durationMs"] = duration }
        if let exitCode { values["exitCode"] = .number(Double(exitCode)) }
        if let output { values["output"] = .string(output) }
        return ReadRow(id: "command", author: "Bot", text: "", isUser: false, timestamp: "1000",
                       turnId: "turn", item: ReadItem(id: "command", type: "commandExecution", state: state,
                                                        text: nil, createdAt: "1000", payload: values))
    }
}
