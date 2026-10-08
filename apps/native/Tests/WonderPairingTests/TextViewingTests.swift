import XCTest
@testable import WonderPairing

final class TextViewingTests: XCTestCase {
    func testKindIsDetectedFromNameThenMime() {
        XCTAssertEqual(TextViewerKind.detect(name: "README.md", mimeType: "text/plain"), .markdown)
        XCTAssertEqual(TextViewerKind.detect(name: "notes.MARKDOWN", mimeType: nil), .markdown)
        XCTAssertEqual(TextViewerKind.detect(name: "data.json", mimeType: "text/plain"), .json)
        XCTAssertEqual(TextViewerKind.detect(name: "log.jsonl", mimeType: nil), .jsonl)
        XCTAssertEqual(TextViewerKind.detect(name: "log.ndjson", mimeType: nil), .jsonl)
        XCTAssertEqual(TextViewerKind.detect(name: "payload", mimeType: "application/json; charset=utf-8"), .json)
        XCTAssertEqual(TextViewerKind.detect(name: "doc", mimeType: "text/markdown"), .markdown)
        XCTAssertNil(TextViewerKind.detect(name: "main.swift", mimeType: "text/plain"))
        XCTAssertNil(TextViewerKind.detect(name: "page.html", mimeType: "text/html"))
    }

    func testPreferenceDefaultsToRenderedAndIsRememberedPerKind() throws {
        let suite = "TextViewingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TextViewerPreference.mode(for: .markdown, defaults: defaults), .rendered)
        TextViewerPreference.remember(.source, for: .markdown, defaults: defaults)
        XCTAssertEqual(TextViewerPreference.mode(for: .markdown, defaults: defaults), .source)
        XCTAssertEqual(TextViewerPreference.mode(for: .json, defaults: defaults), .rendered)
        TextViewerPreference.remember(.source, for: .json, defaults: defaults)
        XCTAssertEqual(TextViewerPreference.mode(for: .jsonl, defaults: defaults), .source)
        TextViewerPreference.remember(.rendered, for: .markdown, defaults: defaults)
        XCTAssertEqual(TextViewerPreference.mode(for: .markdown, defaults: defaults), .rendered)
        defaults.set("garbage", forKey: TextViewerPreference.storageKey(for: .markdown))
        XCTAssertEqual(TextViewerPreference.mode(for: .markdown, defaults: defaults), .rendered)
    }

    func testChunksSplitAtBlankLinesAndNeverInsideFences() {
        let fenced = "```swift\nlet a = 1\n\nlet b = 2\n```"
        let text = "# Title\n\nParagraph one.\n\n" + fenced + "\n\nTail."
        let chunks = MarkdownChunker.chunks(text, targetBytes: 5)
        XCTAssertEqual(chunks.joined(separator: "\n"), text)
        XCTAssertTrue(chunks.contains { $0.contains("let a = 1\n\nlet b = 2") })
        XCTAssertGreaterThan(chunks.count, 3)
        XCTAssertEqual(MarkdownChunker.chunks("", targetBytes: 5), [])
        XCTAssertEqual(MarkdownChunker.chunks("one\n\ntwo").count, 1)
        XCTAssertGreaterThan(MarkdownChunker.chunks("a\r\n\r\nb\r\n\r\nc", targetBytes: 2).count, 1)
    }

    func testVisibleCountBoundsRenderingButKeepsAtLeastOneChunk() {
        let chunks = ["aaaa", "bbbb", "cccc"]
        XCTAssertEqual(MarkdownChunker.visibleCount(of: chunks, limitBytes: 5), 2)
        XCTAssertEqual(MarkdownChunker.visibleCount(of: chunks, limitBytes: 1), 1)
        XCTAssertEqual(MarkdownChunker.visibleCount(of: chunks, limitBytes: 100), 3)
    }

    func testMarkdownHeadingRunsUseUTF16OffsetsAcrossEmojiAndCRLF() throws {
        let text = "🙂 intro\r\n# Title\n\nplain"
        let runs = SyntaxRuns.runs(text, language: "md")
        let heading = try XCTUnwrap(runs.first { $0.role == .keyword })
        XCTAssertEqual((text as NSString).substring(with: heading.range), "# Title")
        XCTAssertTrue(SyntaxRuns.runs(text, language: "nope").isEmpty)
        XCTAssertTrue(SyntaxRuns.runs(text, language: "md", maxBytes: 3).isEmpty)
    }
}
