import XCTest
@testable import WonderPairing

final class FileAccessManagementTests: XCTestCase {
    func testCreationSendsNativeArraysAndSelectedDirectory() throws {
        var files = BotFileSelection()
        files.select(path: "/Users/owner/Reference.pdf", isDirectory: false, writable: false)
        files.select(path: "/Users/owner/Project", isDirectory: true, writable: true)
        files.workingDirectory = "/Users/owner/Project"
        let fields = ["name": "Ada", "clientRequestId": "request", "_submitted": "true"]
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: files.creationBody(fields: fields)) as? [String: Any])
        XCTAssertEqual(body["readRoots"] as? [String], ["/Users/owner/Reference.pdf"])
        XCTAssertEqual(body["writeRoots"] as? [String], ["/Users/owner/Project"])
        XCTAssertEqual(body["workingDirectory"] as? String, "/Users/owner/Project")
        XCTAssertEqual(body["clientRequestId"] as? String, "request")
        XCTAssertNil(body["_submitted"])
    }
    func testPrivateWorkspaceDefaultAddsNoExternalAccess() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: BotFileSelection().creationBody(fields: ["name": "Ada"])) as? [String: Any])
        XCTAssertEqual(body["readRoots"] as? [String], [])
        XCTAssertEqual(body["writeRoots"] as? [String], [])
        XCTAssertNil(body["workingDirectory"])
    }
    func testPermissionLevelMovesWithoutDuplicateGrantAndRemovalResetsDirectory() {
        var files = BotFileSelection()
        files.select(path: "/Project", isDirectory: true, writable: true)
        files.workingDirectory = "/Project/Sources"
        files.select(path: "/Project", isDirectory: true, writable: false)
        XCTAssertEqual(files.readRoots, ["/Project"])
        XCTAssertTrue(files.writeRoots.isEmpty)
        XCTAssertEqual(files.directoryRoots, ["/Project"])
        files.remove(path: "/Project")
        XCTAssertNil(files.workingDirectory)
        XCTAssertTrue(files.readRoots.isEmpty)
    }
    func testSavedCreationDraftKeepsExactGrantPayloadAndRequestIdentity() throws {
        var draft = ManagementDraft(); var files = BotFileSelection()
        files.select(path: "/Project with spaces/文.txt", isDirectory: false, writable: false)
        draft.values = ["name": "Ada", "_submitted": "true", "_fileAccess": files.encodedDraft]
        let saved = try JSONDecoder().decode(ManagementDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(saved.requestId, draft.requestId)
        let restored = BotFileSelection.draft(saved.values["_fileAccess"])
        XCTAssertEqual(restored, files)
        XCTAssertEqual(try restored.creationBody(fields: saved.values), try files.creationBody(fields: draft.values))
    }
    func testDirectoryPageDecodesNamesKindsAndPagination() throws {
        let page = try JSONDecoder().decode(MacLocationPage.self, from: Data(#"{"path":"/Users/owner","parentPath":"/Users","entries":[{"name":"Project","path":"/Users/owner/Project","isDirectory":true},{"name":"Notes.md","path":"/Users/owner/Notes.md","isDirectory":false}],"nextOffset":200}"#.utf8))
        XCTAssertEqual(page.entries.map(\.isDirectory), [true, false])
        XCTAssertEqual(page.parentPath, "/Users")
        XCTAssertEqual(page.nextOffset, 200)
    }
    func testSavedRootsComparisonIgnoresOrderButNotPermissionLevel() throws {
        let state = try JSONDecoder().decode(BotFileAccessState.self, from: Data(#"{"revision":2,"appliedRevision":2,"readRoots":["/B","/A"],"writeRoots":["/C"]}"#.utf8))
        var files = BotFileSelection(); files.readRoots = ["/A", "/B"]; files.writeRoots = ["/C"]
        XCTAssertTrue(files.matches(state))
        files.select(path: "/A", isDirectory: true, writable: true)
        XCTAssertFalse(files.matches(state))
    }
    func testAliasRowsKeepDistinctIdentityWhenCanonicalPathsMatch() throws {
        let page = try JSONDecoder().decode(MacLocationPage.self, from: Data(#"{"path":"/Users/owner","parentPath":"/Users","entries":[{"name":"Project","path":"/Shared/project","isDirectory":true},{"name":"Project alias","path":"/Shared/project","isDirectory":true}],"nextOffset":null}"#.utf8))
        XCTAssertEqual(page.entries[0].path, page.entries[1].path)
        XCTAssertNotEqual(page.entries[0].id, page.entries[1].id)
    }

}
