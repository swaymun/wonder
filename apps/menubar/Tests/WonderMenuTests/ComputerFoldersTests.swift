import Foundation
import XCTest
@testable import WonderMenu

final class ComputerFoldersTests: XCTestCase {
    @MainActor
    func testSelectionsPersistDeduplicateAndRemoveWithoutDeletingFolder() throws {
        let suite = "ComputerFoldersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let model = ComputerFolders(defaults: defaults, excludedRoots: [])
        try model.remember(folder)
        try model.remember(folder)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?["available"] as? Bool, true)
        let restored = ComputerFolders(defaults: defaults, excludedRoots: [])
        XCTAssertEqual(restored.rows.first?["path"] as? String, folder.path)
        restored.remove(folder.path)
        XCTAssertTrue(ComputerFolders(defaults: defaults, excludedRoots: []).rows.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }
    @MainActor
    func testImportsKnownDirectoriesOnceAndHonorsRemoval() throws {
        let suite = "ComputerFoldersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("file.txt")
        try Data().write(to: file)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let model = ComputerFolders(defaults: defaults, excludedRoots: [])
        model.importExisting([folder.path, folder.path, file.path])
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?["imported"] as? Bool, true)
        model.remove(folder.path)
        let restored = ComputerFolders(defaults: defaults, excludedRoots: [])
        restored.importExisting([folder.path])
        XCTAssertTrue(restored.rows.isEmpty)
    }

    @MainActor
    func testInternalFolderFilterUsesPathBoundaries() {
        XCTAssertFalse(ComputerFolders.isVisible("/tmp/example"))
        XCTAssertFalse(ComputerFolders.isVisible("/private/tmp/example"))
        XCTAssertFalse(ComputerFolders.isVisible(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wonder/bots/example").path))
        XCTAssertTrue(ComputerFolders.isVisible("/tmp-project"))
        XCTAssertTrue(ComputerFolders.isVisible("/Users/example/Projects"))
    }

}
