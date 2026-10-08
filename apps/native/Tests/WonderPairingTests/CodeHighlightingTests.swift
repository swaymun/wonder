import XCTest
@testable import WonderPairing

final class CodeHighlightingTests: XCTestCase {
    /// Role of each non-plain span's text on one line.
    private func roles(_ code: String, _ language: String) throws -> [String: SyntaxRole] {
        let lines = try XCTUnwrap(CodeHighlighter.lines(code, language: language), "\(language) unsupported")
        return Dictionary(lines.flatMap { $0 }.compactMap { span in span.role.map { (span.text, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    func testEverySupportedFenceNameFindsALanguageAndUnknownOnesStayPlain() {
        for tag in ["swift", "js", "javascript", "jsx", "ts", "typescript", "tsx", "python", "py", "rust", "rs", "go", "json", "bash",
                    "sh", "shell", "zsh", "html", "css", "yaml", "yml", "markdown", "md", "sql", "Swift", "JSON"] {
            XCTAssertTrue(CodeHighlighter.supports(language: tag), tag)
        }
        for tag in [nil, "", "text", "plaintext", "mermaid", "diff-ish"] as [String?] {
            XCTAssertFalse(CodeHighlighter.supports(language: tag), tag ?? "nil")
            XCTAssertNil(CodeHighlighter.lines("let x = 1", language: tag))
        }
    }

    func testSwiftColoursKeywordsStringsNumbersTypesAndCalls() throws {
        let found = try roles("let name: String = greet(\"hi\", 42) // done", "swift")
        XCTAssertEqual(found["let"], .keyword)
        XCTAssertEqual(found["String"], .type)
        XCTAssertEqual(found["greet"], .function)
        XCTAssertEqual(found["\"hi\""], .string)
        XCTAssertEqual(found["42"], .number)
        XCTAssertEqual(found["// done"], .comment)
        XCTAssertEqual(found[":"], .punctuation)
    }

    func testPunctuationRunsMergeIntoOneSpan() throws {
        let line = try XCTUnwrap(CodeHighlighter.lines("a => {}", language: "js")?.first)
        XCTAssertEqual(line.filter { $0.role == .punctuation }.map(\.text), ["=>", "{}"])
    }

    func testPythonJSONAndShell() throws {
        let python = try roles("def run(x):  # go\n    return 'a' + str(3.5)", "py")
        XCTAssertEqual(python["def"], .keyword); XCTAssertEqual(python["run"], .function)
        XCTAssertEqual(python["# go"], .comment); XCTAssertEqual(python["'a'"], .string); XCTAssertEqual(python["3.5"], .number)

        let json = try roles("{\"name\": \"wonder\", \"n\": 3, \"ok\": true}", "json")
        XCTAssertEqual(json["\"name\""], .type, "keys")
        XCTAssertEqual(json["\"wonder\""], .string)
        XCTAssertEqual(json["3"], .number); XCTAssertEqual(json["true"], .keyword)

        let shell = try roles("export PATH=\"$HOME/bin\" # note\nif [ -f x ]; then echo hi; fi", "bash")
        XCTAssertEqual(shell["export"], .keyword); XCTAssertEqual(shell["# note"], .comment)
        XCTAssertEqual(shell["\"$HOME/bin\""], .string); XCTAssertEqual(shell["then"], .keyword)
    }

    func testYAMLKeysSQLAndMarkdown() throws {
        let yaml = try roles("name: wonder\nitems:\n  - build-step: true", "yml")
        XCTAssertEqual(yaml["name"], .type); XCTAssertEqual(yaml["build-step"], .type); XCTAssertEqual(yaml["true"], .keyword)

        let sql = try roles("SELECT count(*) FROM users WHERE id = 7 -- n", "sql")
        XCTAssertEqual(sql["SELECT"], .keyword); XCTAssertEqual(sql["count"], .function); XCTAssertEqual(sql["7"], .number)
        XCTAssertEqual(sql["-- n"], .comment)

        let markdown = try roles("# Title\nuse `code` here 12\n```swift", "markdown")
        XCTAssertEqual(markdown["# Title"], .keyword); XCTAssertEqual(markdown["`code`"], .string)
        XCTAssertEqual(markdown["```swift"], .comment); XCTAssertNil(markdown["12"], "prose numbers stay plain")
    }

    func testBlockCommentsCarryAcrossLines() throws {
        let lines = try XCTUnwrap(CodeHighlighter.lines("/* a\n b */ let x", language: "ts"))
        XCTAssertEqual(lines[0].first?.role, .comment)
        XCTAssertEqual(lines[1].first, SyntaxSpan(text: " b */", role: .comment))
        XCTAssertTrue(lines[1].contains { $0.text == "let" && $0.role == .keyword })
    }

    func testSpansReassembleTheOriginalText() throws {
        let code = "func f<T>(_ x: T) -> [T] {\n    return [x] // ok\n}\n"
        let lines = try XCTUnwrap(CodeHighlighter.lines(code, language: "swift"))
        XCTAssertEqual(lines.map { $0.map(\.text).joined() }.joined(separator: "\n"), code)
    }

    func testVeryLongBlocksRenderPlain() {
        let long = Array(repeating: "let a = 1", count: CodeHighlighter.maxLines + 1).joined(separator: "\n")
        XCTAssertNil(CodeHighlighter.lines(long, language: "swift"))
        let atLimit = Array(repeating: "let a = 1", count: CodeHighlighter.maxLines).joined(separator: "\n")
        XCTAssertEqual(CodeHighlighter.lines(atLimit, language: "swift")?.count, CodeHighlighter.maxLines)
        XCTAssertNil(CodeHighlighter.lines(String(repeating: "x", count: CodeHighlighter.maxBytes + 1), language: "swift"))
    }

    func testDiffHighlightingIsUnchangedByPunctuationMode() throws {
        var diff = try XCTUnwrap(SyntaxHighlighter(path: "a.swift"))
        XCTAssertFalse(diff.spans("foo(bar) {").contains { $0.role == .punctuation })
    }
}
