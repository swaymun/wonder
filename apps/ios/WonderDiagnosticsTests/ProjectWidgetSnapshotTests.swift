import XCTest
@testable import Wonder

final class ProjectWidgetSnapshotTests: XCTestCase {
    // Widget links must enter the exact paired host and channel. A scheme or ID
    // mix-up could open the wrong app or turn a shared label into a URL path.
    func testChannelSeparatedExactLinksRejectUnsafeIdentifiers() throws {
        let production = try XCTUnwrap(ProjectWidgetIdentity(bundleIdentifier: "com.swaymun.wonder"))
        let testing = try XCTUnwrap(ProjectWidgetIdentity(bundleIdentifier: "com.swaymun.wonder.testing.Widget"))
        XCTAssertEqual(production.appGroupID, "group.com.swaymun.wonder")
        XCTAssertEqual(testing.appGroupID, "group.com.swaymun.wonder.testing")
        XCTAssertNil(ProjectWidgetIdentity(bundleIdentifier: "com.saimun.wonder.native"))
        XCTAssertEqual(ProjectWidgetLink.newChat(hostID: "mac_1", projectID: "project-2", identity: production)?.absoluteString,
                       "wonder://v1/hosts/mac_1/projects/project-2/new")
        XCTAssertEqual(ProjectWidgetLink.chat(hostID: "mac_1", chatID: "chat_3", identity: testing)?.absoluteString,
                       "wonder-testing://v1/hosts/mac_1/chats/chat_3")
        XCTAssertNil(ProjectWidgetLink.chat(hostID: "mac/other", chatID: "chat_3", identity: testing))
        XCTAssertNil(ProjectWidgetLink.newChat(hostID: "mac_1", projectID: "%2Fsecret", identity: production))
    }

    // A stale or corrupted snapshot must never claim live agent state or
    // manufacture a navigation destination from an invalid ID.
    func testSnapshotBoundsLabelsDestinationsAndStaleness() throws {
        let saved = Date(timeIntervalSince1970: 1_000_000)
        let chats = (0..<5).map { ProjectWidgetSnapshot.Chat(id: "chat-\($0)", title: "  Chat\n\($0)  ") }
        let projects = (0..<12).map {
            ProjectWidgetSnapshot.Project(hostID: "mac", id: "project-\($0)",
                                          name: "  Launch\nProject  ", recentChats: chats)
        }
        let unsafe = ProjectWidgetSnapshot.Project(hostID: "mac", id: "bad/path", name: "Unsafe", recentChats: [])
        let snapshot = try XCTUnwrap(ProjectWidgetSnapshot(savedAt: saved, showNamesOnWidgets: true,
                                                           projects: [unsafe] + projects).validated())
        XCTAssertEqual(snapshot.projects.count, 10)
        XCTAssertFalse(snapshot.projects.contains { $0.id == unsafe.id })
        XCTAssertEqual(snapshot.projects[0].recentChats.count, 3)
        XCTAssertEqual(snapshot.projects[0].name, "LaunchProject")
        XCTAssertEqual(snapshot.projects[0].recentChats[0].title, "Chat0")
        XCTAssertFalse(snapshot.isStale(at: saved.addingTimeInterval(59 * 60)))
        XCTAssertTrue(snapshot.isStale(at: saved.addingTimeInterval(60 * 60)))
        XCTAssertTrue(snapshot.isStale(at: saved.addingTimeInterval(-6 * 60)))
    }

    // Names are absent from persisted bytes until the person opts in. An
    // atomic valid rewrite recovers a corrupt or oversized snapshot.
    func testSnapshotStoreDefaultsToGenericLabelsAndRecoversCorruption() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wonder-widget-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("project-widget-snapshot-v1.json")
        let project = ProjectWidgetSnapshot.Project(hostID: "mac", id: "project",
            name: "Roadmap", recentChats: [.init(id: "chat", title: "Plan launch")])
        let snapshot = ProjectWidgetSnapshot(savedAt: Date(timeIntervalSince1970: 1_000_000), projects: [project])
        XCTAssertTrue(ProjectWidgetSnapshotStore.save(snapshot, in: directory))
        XCTAssertEqual(ProjectWidgetSnapshotStore.load(from: directory)?.projects.first?.name, "Project 1")
        let genericBytes = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(genericBytes.contains("Roadmap"))
        XCTAssertFalse(genericBytes.contains("Plan launch"))
        try Data("{".utf8).write(to: file, options: .atomic)
        XCTAssertNil(ProjectWidgetSnapshotStore.load(from: directory))
        try Data(repeating: 0, count: ProjectWidgetSnapshot.maxBytes + 1).write(to: file, options: .atomic)
        XCTAssertNil(ProjectWidgetSnapshotStore.load(from: directory))
        let optedIn = ProjectWidgetSnapshot(savedAt: snapshot.savedAt, showNamesOnWidgets: true, projects: [project])
        XCTAssertTrue(ProjectWidgetSnapshotStore.save(optedIn, in: directory))
        XCTAssertEqual(ProjectWidgetSnapshotStore.load(from: directory)?.projects.first?.name, "Roadmap")
        XCTAssertEqual(ProjectWidgetSnapshotStore.load(from: directory)?.projects.first?.recentChats.first?.title,
                       "Plan launch")
        XCTAssertTrue(ProjectWidgetSnapshotStore.save(snapshot, in: directory))
        let hiddenBytes = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(hiddenBytes.contains("Roadmap"))
    }
}
