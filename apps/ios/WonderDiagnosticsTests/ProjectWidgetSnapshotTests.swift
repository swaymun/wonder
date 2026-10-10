import XCTest
@testable import Wonder
import WonderPairing

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
        let file = directory.appendingPathComponent("project-widget-snapshot-v3.json")
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

    // The widget opens the threads most recently worked on, newest first, by
    // their conversation when Wonder has one and otherwise by the provider
    // thread, which the app attaches. Hidden Projects and drafts never leak.
    @MainActor func testRecentThreadsOpenDirectlyNewestFirst() throws {
        func project(_ id: String, included: Bool = true) throws -> ProjectSummary {
            try JSONDecoder().decode(ProjectSummary.self, from: Data(#"{"id":"\#(id)","name":"P \#(id)","isIncluded":\#(included),"isPinned":false,"rootsRevision":1,"folders":[],"createdAt":"x"}"#.utf8))
        }
        var state = ProjectThreadsState()
        state.threads = [
            ProjectThreadSummary(reference: "codex:aa-1", conversationId: "conv-1", title: "Older", family: .codex, updatedAt: 10),
            ProjectThreadSummary(reference: "claude:bb-2", conversationId: nil, title: "Newest", family: .claude, updatedAt: 30),
            ProjectThreadSummary(reference: "wonder:conv-9", conversationId: "conv-9", title: "Draft", family: .codex, updatedAt: 20),
        ]
        var hidden = ProjectThreadsState()
        hidden.threads = [ProjectThreadSummary(reference: "codex:cc-3", conversationId: nil, title: "Hidden", family: .codex, updatedAt: 99)]
        let rows = ProjectWidgetSnapshotPublisher.recentThreads(
            projects: [try project("p1"), try project("p2", included: false)].filter(\.isIncluded),
            threads: ["p1": state, "p2": hidden], pinned: [])
        XCTAssertEqual(rows.map(\.title), ["Newest", "Draft", "Older"])
        let testing = try XCTUnwrap(ProjectWidgetIdentity(bundleIdentifier: "com.swaymun.wonder.testing"))
        let newest = try XCTUnwrap(ProjectWidgetLink.thread(hostID: "mac", thread: rows[0], identity: testing))
        XCTAssertEqual(newest.absoluteString, "wonder-testing://v1/hosts/mac/projects/p1/threads/claude/bb-2")
        XCTAssertEqual(WonderDeepLink.parse(newest, scheme: "wonder-testing"),
                       .projectThread(host: "mac", project: "p1", family: .claude, thread: "bb-2"))
        XCTAssertEqual(ProjectWidgetLink.thread(hostID: "mac", thread: rows[1], identity: testing)?.absoluteString,
                       "wonder-testing://v1/hosts/mac/chats/conv-9")
        XCTAssertNil(WonderDeepLink.parse(URL(string: "wonder-testing://v1/hosts/mac/projects/p1/threads/other/bb-2")!, scheme: "wonder-testing"))
    }
}
