import XCTest
@testable import WonderPairing

final class FileChangeSummaryTests: XCTestCase {
    private func item(_ payload: [String: ThreadValue], state: String = "completed") -> ReadItem {
        ReadItem(id: "edit", type: "fileChange", state: state, text: nil, createdAt: "1000", payload: payload)
    }

    func testFilenameAndCountsSurviveSavedHistoryWithoutShowingDirectories() throws {
        let original = item(["paths": .array([.string("/workspace/Sources/Authentication.swift")]),
                             "additions": .number(3), "deletions": .number(2)])
        let saved = try JSONDecoder().decode(ReadItem.self, from: JSONEncoder().encode(original))
        let summary = try XCTUnwrap(FileChangeSummary.prepare(saved))
        XCTAssertEqual(summary.title, "Edited Authentication.swift")
        XCTAssertEqual(summary.additions, 3)
        XCTAssertEqual(summary.deletions, 2)
        XCTAssertEqual(summary.accessibilityLabel, "Edited Authentication.swift, 3 added lines, 2 removed lines")
    }

    func testCreatedDeletedMultipleAndUnsuccessfulChangesUseHonestVerbs() throws {
        let diff: ThreadValue = .object(["path": .string("Tests/Hello.swift"), "kind": .string("add"), "diff": .string("+hello\n+world")])
        let payload: [String: ThreadValue] = ["diffs": .array([diff])]
        XCTAssertEqual(FileChangeSummary.prepare(item(payload))?.title, "Wrote Hello.swift")
        XCTAssertEqual(FileChangeSummary.prepare(item(payload))?.additions, 2)
        for (state, verb) in [("started", "Editing"), ("failed", "Couldn’t edit"), ("interrupted", "Stopped editing"), ("unknown", "Changes to")] {
            XCTAssertEqual(FileChangeSummary.prepare(item(payload, state: state))?.title, "\(verb) Hello.swift")
        }
        let deleted = item(["diffs": .array([.object(["path": .string("Old.swift"), "kind": .string("delete"), "diff": .string("-old")])])])
        XCTAssertEqual(FileChangeSummary.prepare(deleted)?.title, "Deleted Old.swift")
        let multiple = item(["paths": .array([.string("A/Model.swift"), .string("B/Model.swift")])])
        XCTAssertEqual(FileChangeSummary.prepare(multiple)?.title, "Edited 2 files")
        XCTAssertNil(FileChangeSummary.prepare(multiple)?.additions)
    }

    func testLegacyDiffCountsIgnoreHeadersAndDoNotInventAnOutsideWorkspaceWarning() {
        let legacy = item(["diffs": .array([.object(["path": .string("[path outside workspace]"), "diff": .string("--- a/test.swift\n+++ b/test.swift\n@@ -1 +1 @@\n-old\n+new")])])])
        let summary = FileChangeSummary.prepare(legacy)
        XCTAssertEqual(summary?.title, "Edited a file")
        XCTAssertEqual(summary?.additions, 1)
        XCTAssertEqual(summary?.deletions, 1)
        let unknown = FileChangeSummary.prepare(item([:]))
        XCTAssertNil(unknown?.additions)
        XCTAssertNil(unknown?.deletions)
    }

    func testLinksRetainRelativePathsAndRejectRedactedOrEscapingPaths() {
        for invalid in ["", "/workspace/File.swift", "../File.swift", "A/../File.swift", "A//File.swift", "./File.swift", "[path outside workspace]", "file\0.swift"] {
            XCTAssertNil(FileChangeSummary.relativePath(invalid))
            XCTAssertNil(FileChangeSummary.prepare(item(["paths": .array([.string(invalid)])]))?.path)
        }
        XCTAssertEqual(FileChangeSummary.relativePath("Sources/My File.swift"), "Sources/My File.swift")
        XCTAssertNil(FileChangeSummary.prepare(item(["paths": .array([.string("A.swift"), .string("B.swift")])]))?.path)
    }

    func testExpandedDiffUsesFilenameAndPreservesCode() throws {
        let edit = item(["diffs": .array([.object(["path": .string("Sources/Authentication.swift"), "diff": .string("+let valid = true")])])])
        let row = ReadRow(id: "row", author: "Bot", text: "", isUser: false, timestamp: "1000", item: edit)
        XCTAssertEqual(row.fileChangeSummary?.title, "Edited Authentication.swift")
        XCTAssertEqual(row.activity?.details.first?.title, "Authentication.swift")
        XCTAssertEqual(row.activity?.details.first?.text, "+let valid = true")
        XCTAssertEqual(row.fileChangeSummary?.path, "Sources/Authentication.swift")
        XCTAssertEqual(row.activity?.details.first?.filePath, "Sources/Authentication.swift")
    }

    func testResponseFooterFollowsFinalAnswerAndKeepsSeparateFilesAndRepeatedEdits() throws {
        func edit(_ id: String, _ path: String, _ patch: String, state: String = "completed") -> ReadRow {
            let value = ReadItem(id: id, type: "fileChange", state: state, text: nil, createdAt: "1000",
                payload: ["diffs": .array([.object(["path": .string(path), "diff": .string(patch)])])])
            return ReadRow(id: id, author: "Bot", text: "", isUser: false, timestamp: "1000", turnId: "turn", item: value)
        }
        let reply = ReadRow(id: "reply", author: "Bot", text: "Done", isUser: false, timestamp: "2000", turnId: "turn")
        let progress = ReadRow(id: "progress", author: "Bot", text: "One file is ready", isUser: false, timestamp: "1500", turnId: "turn")
        let rows = [edit("a", "A/File.swift", "-old\n+new"), progress, edit("b", "B/File.swift", "+another"),
                    edit("c", "A/File.swift", "-new\n+final"), edit("failed", "Failed.swift", "+failed", state: "failed"), reply]
        let entries = ChatFeedEntry.grouping(rows)
        let footers = ResponseEditedFiles.footers(entries: entries, activeTurnIDs: [])
        XCTAssertEqual(Set(footers.keys), ["reply"])
        let files = try XCTUnwrap(footers["reply"]).files
        XCTAssertEqual(files.map(\.path), ["A/File.swift", "B/File.swift"])
        XCTAssertEqual(files[0].additions, 2)
        XCTAssertEqual(files[0].deletions, 2)
        XCTAssertEqual(files[0].patches, ["-old\n+new", "-new\n+final"])
        XCTAssertTrue(ResponseEditedFiles.footers(entries: entries, activeTurnIDs: ["turn"]).isEmpty)
    }

    func testResponseFooterDoesNotInventDiffsOrCountsForLegacyHistory() throws {
        let value = item(["paths": .array([.string("Known.swift")])])
        let row = ReadRow(id: "saved", author: "Bot", text: "", isUser: false, timestamp: "1000", turnId: "turn", item: value)
        let files = try XCTUnwrap(ResponseEditedFiles.footers(entries: ChatFeedEntry.grouping([row]), activeTurnIDs: [])["saved"]).files
        XCTAssertEqual(files.map(\.path), ["Known.swift"])
        XCTAssertNil(files[0].additions)
        XCTAssertNil(files[0].deletions)
        XCTAssertTrue(files[0].patches.isEmpty)
    }

    func testResponseFooterReadsMultiplePatchPathsWhenLegacyPathsAreEmpty() throws {
        let value = item(["paths": .array([]), "diffs": .array([
            .object(["path": .string("A.swift"), "diff": .string("--- a/A.swift\n+++ b/A.swift\n-old\n+new")]),
            .object(["path": .string("B.swift"), "diff": .string("+one\n+two")])])])
        let row = ReadRow(id: "saved", author: "Bot", text: "", isUser: false, timestamp: "1000", turnId: "turn", item: value)
        let files = try XCTUnwrap(ResponseEditedFiles.footers(entries: ChatFeedEntry.grouping([row]), activeTurnIDs: [])["saved"]).files
        XCTAssertEqual(files.map(\.path), ["A.swift", "B.swift"])
        XCTAssertEqual(files.map(\.additions), [1, 2])
        XCTAssertEqual(files.map(\.deletions), [1, 0])
    }

    func testResponseFooterMarksPatchCappedByHostAsPartial() throws {
        let value = item(["diffs": .array([
            .object(["path": .string("Large.swift"), "diff": .string("@@ -1,2 +1,2 @@\n-old\n+new"), "additions": .number(900), "deletions": .number(1)]),
            .object(["path": .string("Small.swift"), "diff": .string("@@ -1 +1 @@\n-a\n+b"), "additions": .number(1), "deletions": .number(1)])])])
        let row = ReadRow(id: "saved", author: "Bot", text: "", isUser: false, timestamp: "1000", turnId: "turn", item: value)
        let files = try XCTUnwrap(ResponseEditedFiles.footers(entries: ChatFeedEntry.grouping([row]), activeTurnIDs: [])["saved"]).files
        XCTAssertEqual(files.map(\.partial), [true, false])
        XCTAssertEqual(files[0].additions, 900)
    }
}

extension FileChangeSummaryTests {
    func testTurnDiffReplacesEditRowsIncludingFilesTheRowsMissed() throws {
        let edit = ReadRow(id: "edit", author: "Bot", text: "", isUser: false, timestamp: "1000", turnId: "turn",
            item: item(["diffs": .array([.object(["path": .string("app.js"), "diff": .string("-a\n+b")])])]))
        let reply = ReadRow(id: "reply", author: "Bot", text: "Done", isUser: false, timestamp: "2000", turnId: "turn")
        let entries = ChatFeedEntry.grouping([edit, reply])
        // The shape the Mac sends, saved and reloaded with the thread.
        let json = #"{"id":"turn","items":[],"status":"completed","editedFiles":{"paths":["app.js","comic.html"],"additions":4,"deletions":1,"diffs":[{"path":"app.js","kind":"update","diff":"@@ -1 +1 @@\n-a\n+b","additions":1,"deletions":1},{"path":"comic.html","kind":"add","diff":"@@ -0,0 +1,3 @@\n+<html>\n+<body>\n+</html>","additions":3,"deletions":0}]}}"#
        let decoded = try JSONDecoder().decode(ReadTurn.self, from: Data(json.utf8))
        let turn = try JSONDecoder().decode(ReadTurn.self, from: JSONEncoder().encode(decoded))
        let all = try XCTUnwrap(ResponseEditedFiles.conversation(entries: entries, activeTurnIDs: [], turns: ["turn": turn]))
        XCTAssertEqual(all.files.map(\.path), ["app.js", "comic.html"])
        XCTAssertEqual(all.files.map(\.additions), [1, 3])
        XCTAssertEqual(all.files.map(\.deletions), [1, 0])
        XCTAssertEqual(all.files[1].patches, ["@@ -0,0 +1,3 @@\n+<html>\n+<body>\n+</html>"])
        // A turn whose diff is empty edited nothing, whatever its rows said.
        let empty = ReadTurn(id: "turn", items: [], status: "completed", editedFiles: ["paths": .array([]), "diffs": .array([])])
        XCTAssertNil(ResponseEditedFiles.conversation(entries: entries, activeTurnIDs: [], turns: ["turn": empty]))
        // Pages merged from the cache keep the diff.
        let older = ThreadProjection(nextCursor: nil, hydrated: true, turns: [turn])
        let newer = ThreadProjection(nextCursor: nil, hydrated: true, turns: [ReadTurn(id: "turn", items: [], status: "completed")])
        XCTAssertNotNil(newer.mergingOlder(older).turns?.first?.editedFiles)
    }

    func testConversationEditsAccumulateCompletedResponsesInFirstEditOrder() throws {
        func edit(_ id: String, _ turn: String, _ path: String, _ patch: String) -> ReadRow {
            let value = ReadItem(id: id, type: "fileChange", state: "completed", text: nil, createdAt: "1000",
                payload: ["diffs": .array([.object(["path": .string(path), "diff": .string(patch)])])])
            return ReadRow(id: id, author: "Bot", text: "", isUser: false, timestamp: "1000", turnId: turn, item: value)
        }
        func reply(_ id: String, _ turn: String) -> ReadRow {
            ReadRow(id: id, author: "Bot", text: "Done", isUser: false, timestamp: "2000", turnId: turn)
        }
        let rows = [edit("a", "one", "A.swift", "-old\n+new"), reply("r1", "one"),
                    edit("b", "two", "B.swift", "+added"), edit("c", "two", "A.swift", "+more"), reply("r2", "two"),
                    edit("d", "three", "C.swift", "+running")]
        let entries = ChatFeedEntry.grouping(rows)
        let all = try XCTUnwrap(ResponseEditedFiles.conversation(entries: entries, activeTurnIDs: ["three"]))
        XCTAssertEqual(all.files.map(\.path), ["A.swift", "B.swift"], "A running response's edits are not receipts yet")
        XCTAssertEqual(all.files[0].patches, ["-old\n+new", "+more"])
        XCTAssertEqual(all.files[0].additions, 2)
        XCTAssertEqual(all.files[0].deletions, 1)
        XCTAssertNil(ResponseEditedFiles.conversation(entries: ChatFeedEntry.grouping([reply("r", "x")]), activeTurnIDs: []))
    }
}

final class SyntaxHighlighterTests: XCTestCase {
    private func roles(_ path: String, _ lines: [String]) -> [[String: SyntaxRole]] {
        guard var highlighter = SyntaxHighlighter(path: path) else { return [] }
        return lines.map { line in
            let spans = highlighter.spans(line)
            XCTAssertEqual(spans.map(\.text).joined(), line, "Highlighting never changes the text")
            return Dictionary(spans.compactMap { span in span.role.map { (span.text, $0) } }, uniquingKeysWith: { first, _ in first })
        }
    }

    func testSwiftLineColoursKeywordsStringsTypesAttributesNumbersAndComments() {
        let line = roles("Sources/View.swift", [#"@MainActor let title: String = "Hi // not" + 42 // note"#])[0]
        XCTAssertEqual(line["@MainActor"], .attribute)
        XCTAssertEqual(line["let"], .keyword)
        XCTAssertEqual(line["String"], .type)
        XCTAssertEqual(line[#""Hi // not""#], .string)
        XCTAssertEqual(line["42"], .number)
        XCTAssertEqual(line["// note"], .comment)
    }

    func testBlockCommentsCarryAcrossLinesUntilReset() {
        var highlighter = SyntaxHighlighter(path: "main.ts")!
        _ = highlighter.spans("const a = 1 /* starts")
        XCTAssertEqual(highlighter.spans("still inside */ let b").first, SyntaxSpan(text: "still inside */", role: .comment))
        _ = highlighter.spans("/* open")
        highlighter.reset()
        XCTAssertEqual(highlighter.spans("let c").first?.role, .keyword)
    }

    func testLanguageSpecificQuotesAndComments() {
        XCTAssertEqual(roles("lib.rs", ["fn f<'a>(x: &'a str) -> char { 'z' }"])[0]["'z'"], .string)
        XCTAssertNil(roles("lib.rs", ["fn f<'a>(x: &'a str)"])[0]["'a>(x: &'"], "A lifetime is not a string")
        XCTAssertEqual(roles("run.sh", ["echo $# # count"])[0]["# count"], .comment)
        XCTAssertEqual(roles("query.sql", ["SELECT id FROM users"])[0]["SELECT"], .keyword)
        XCTAssertEqual(roles("Index.html", [#"<div class="x">text</div>"#])[0]["div"], .keyword)
        XCTAssertNil(SyntaxHighlighter(path: "notes.txt"))
    }
}

final class DiffLineTests: XCTestCase {
    func testUnifiedDiffNumbersLinesFromHunkHeaders() {
        let lines = DiffLine.parse("--- a/A.swift\n+++ b/A.swift\n@@ -10,3 +10,3 @@\n keep\n-old\n+new\n tail\n")
        XCTAssertEqual(lines.map(\.kind), [.note, .note, .hunk, .context, .removed, .added, .context])
        XCTAssertEqual(lines[3].oldNumber, 10); XCTAssertEqual(lines[3].newNumber, 10)
        XCTAssertEqual(lines[4].oldNumber, 11); XCTAssertNil(lines[4].newNumber)
        XCTAssertEqual(lines[5].newNumber, 11); XCTAssertEqual(lines[5].text, "new")
        XCTAssertEqual(lines[6].oldNumber, 12); XCTAssertEqual(lines[6].newNumber, 12)
    }

    func testHeadersWithoutNumbersAndRawAdditionsLeaveNumbersUnknown() {
        let lines = DiffLine.parse("@@ @@\n-a\n+b\n+c")
        XCTAssertEqual(lines.map(\.kind), [.hunk, .removed, .added, .added])
        XCTAssertTrue(lines.allSatisfy { $0.oldNumber == nil && $0.newNumber == nil })
    }

    func testSplitRowsPairReplacementsAndKeepContextOnBothSides() {
        let rows = SplitDiffRow.pair(DiffLine.parse("@@ -1,3 +1,2 @@\n same\n-one\n-two\n+uno\n same2"))
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[2].left?.text, "one"); XCTAssertEqual(rows[2].right?.text, "uno")
        XCTAssertEqual(rows[3].left?.text, "two"); XCTAssertNil(rows[3].right)
        XCTAssertEqual(rows[4].left?.text, "same2"); XCTAssertEqual(rows[4].right?.text, "same2")
    }
}
