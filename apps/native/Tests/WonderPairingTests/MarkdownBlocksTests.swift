import XCTest
@testable import WonderPairing

final class MarkdownBlocksTests: XCTestCase {
    func testBlocksAgentRepliesUse() {
        let text = """
        ## Summary
        The **build** passed.

        - First
          continued
        - [x] Done
        1. One
        2) Two

        > Quoted
        > lines

        ---
        | File | Lines |
        |------|------:|
        | A.swift | 3 |
        | B.swift |
        ```swift
        let a = 1

        let b = 2
        ```
        """
        XCTAssertEqual(MarkdownBlock.parse(text), [
            .heading(level: 2, text: "Summary"),
            .paragraph("The **build** passed."),
            .listItem(marker: "•", depth: 0, text: "First\ncontinued"),
            .listItem(marker: "☑", depth: 0, text: "Done"),
            .listItem(marker: "1.", depth: 0, text: "One"),
            .listItem(marker: "2.", depth: 0, text: "Two"),
            .quote("Quoted\nlines"),
            .rule,
            .table(header: ["File", "Lines"], rows: [["A.swift", "3"], ["B.swift", ""]]),
            .code(language: "swift", text: "let a = 1\n\nlet b = 2"),
        ])
    }

    func testPlainTextAndLookalikesStayParagraphs() {
        XCTAssertEqual(MarkdownBlock.parse("#hashtag and 3.5 apples\n-not a list"),
                       [.paragraph("#hashtag and 3.5 apples\n-not a list")])
        XCTAssertEqual(MarkdownBlock.parse("```\nunclosed"), [.code(language: nil, text: "unclosed")])
        XCTAssertEqual(MarkdownBlock.parse("a | b without separator"), [.paragraph("a | b without separator")])
    }

    func testPlainTextReadsWithoutSyntax() {
        XCTAssertEqual(MarkdownBlock.parse("x").count, 1)
        XCTAssertEqual(MarkdownBlock.plainText("## Done\nThe **build** `passed`.\n- One\n2. Two\n---\n| A | B |\n|---|---|\n| 1 | 2 |"),
                       "Done\nThe build passed.\nOne\n2. Two\nA, B\n1, 2")
    }
}
