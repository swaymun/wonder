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

    // The widget follows one Mac. A stale or corrupted snapshot must never
    // claim live state or manufacture a destination from an invalid ID.
    func testSnapshotBoundsLabelsDestinationsAndStaleness() throws {
        let saved = Date(timeIntervalSince1970: 1_000_000)
        let projects = (0..<12).map { ProjectWidgetSnapshot.Project(id: "project-\($0)", name: "  Launch\nProject  ") }
        let unsafe = ProjectWidgetSnapshot.Project(id: "bad/path", name: "Unsafe")
        let snapshot = try XCTUnwrap(ProjectWidgetSnapshot(savedAt: saved, hostID: "mac",
            hostName: " Studio\n", projects: [unsafe] + projects).validated())
        XCTAssertEqual(snapshot.projects.count, ProjectWidgetSnapshot.maxProjects)
        XCTAssertFalse(snapshot.projects.contains { $0.id == unsafe.id })
        XCTAssertEqual(snapshot.projects[0].name, "LaunchProject")
        XCTAssertEqual(snapshot.hostName, "Studio")
        XCTAssertFalse(snapshot.isStale(at: saved.addingTimeInterval(59 * 60)))
        XCTAssertTrue(snapshot.isStale(at: saved.addingTimeInterval(60 * 60)))
        XCTAssertTrue(snapshot.isStale(at: saved.addingTimeInterval(-6 * 60)))
        let unpaired = try XCTUnwrap(ProjectWidgetSnapshot(hostID: "../mac", hostName: "Studio", projects: projects).validated())
        XCTAssertNil(unpaired.hostID)
        XCTAssertTrue(unpaired.projects.isEmpty)
        let production = try XCTUnwrap(ProjectWidgetIdentity(bundleIdentifier: "com.swaymun.wonder"))
        XCTAssertEqual(ProjectWidgetLink.computer(hostID: "mac_1", identity: production)?.absoluteString,
                       "wonder://v1/hosts/mac_1/computer")
        XCTAssertNil(ProjectWidgetLink.computer(hostID: "mac/1", identity: production))
        XCTAssertEqual(WonderDeepLink.parse(URL(string: "wonder://v1/hosts/mac_1/computer")!, scheme: "wonder"),
                       .computer(host: "mac_1"))
        XCTAssertNil(WonderDeepLink.parse(URL(string: "wonder://v1/hosts/mac_1/computer/x")!, scheme: "wonder"))
    }

    // An atomic valid rewrite recovers a corrupt or oversized snapshot, and
    // names are stored as the widget shows them.
    func testSnapshotStoreRecoversCorruption() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wonder-widget-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("project-widget-snapshot-v2.json")
        let project = ProjectWidgetSnapshot.Project(id: "project", name: "Roadmap")
        let snapshot = ProjectWidgetSnapshot(savedAt: Date(timeIntervalSince1970: 1_000_000), hostID: "mac",
                                             hostName: "Studio", projects: [project])
        XCTAssertTrue(ProjectWidgetSnapshotStore.save(snapshot, in: directory))
        XCTAssertEqual(ProjectWidgetSnapshotStore.load(from: directory)?.projects.first?.name, "Roadmap")
        XCTAssertEqual(ProjectWidgetSnapshotStore.load(from: directory)?.hostName, "Studio")
        try Data("{".utf8).write(to: file, options: .atomic)
        XCTAssertNil(ProjectWidgetSnapshotStore.load(from: directory))
        try Data(repeating: 0, count: ProjectWidgetSnapshot.maxBytes + 1).write(to: file, options: .atomic)
        XCTAssertNil(ProjectWidgetSnapshotStore.load(from: directory))
        XCTAssertTrue(ProjectWidgetSnapshotStore.save(snapshot, in: directory))
        XCTAssertEqual(ProjectWidgetSnapshotStore.load(from: directory)?.projects.first?.name, "Roadmap")
    }
}
