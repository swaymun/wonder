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
}
