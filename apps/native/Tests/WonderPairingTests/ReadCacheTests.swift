import XCTest
@testable import WonderPairing

final class ReadCacheTests: XCTestCase {
    func testSubagentStatusUsesProductFacingLifecycleCopy() throws {
        let fixture = #"{"conversationId":"child","threadId":"thread","parentConversationId":"parent","parentThreadId":"parent-thread","title":"Scout","agentNickname":"Scout","agentRole":"research","agentPath":"worker","status":"idle","canAcceptDirectInput":true,"isArchived":false}"#
        let waiting = try JSONDecoder().decode(SubagentSummary.self, from: Data(fixture.utf8))
        XCTAssertEqual(waiting.statusLabel, "Waiting")
        XCTAssertEqual(try JSONDecoder().decode(SubagentSummary.self, from: Data(fixture.replacingOccurrences(of: "idle", with: "active").utf8)).statusLabel, "Running")
        XCTAssertEqual(try JSONDecoder().decode(SubagentSummary.self, from: Data(fixture.replacingOccurrences(of: "idle", with: "completed").utf8)).statusLabel, "Completed")
        XCTAssertEqual(try JSONDecoder().decode(SubagentSummary.self, from: Data(fixture.replacingOccurrences(of: "idle", with: "notFound").utf8)).statusLabel, "Unavailable")
    }

    func testReadingPositionPersistsWithoutRewritingHistoryOrIntent() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=ReadStore(root:root,host:"mac",device:"phone")
        try store.save(ProjectionState())
        try store.saveIntent(Data("unsent draft".utf8),conversation:"chat")
        let cache=store.directory.appendingPathComponent("read-cache-v2.json")
        let bytes=try Data(contentsOf:cache)
        let date=try cache.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
        try store.savePosition("activity:row",conversation:"chat")
        let restarted=ReadStore(root:root,host:"mac",device:"phone")
        XCTAssertEqual(try restarted.loadPosition(conversation:"chat"),"activity:row")
        XCTAssertNil(try restarted.loadPosition(conversation:"other"))
        XCTAssertEqual(try Data(contentsOf:cache),bytes)
        XCTAssertEqual(try cache.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,date)
        XCTAssertEqual(try restarted.loadIntent(conversation:"chat"),Data("unsent draft".utf8))
    }
    func snapshot(_ chat: String = "a", epoch: String = "epoch", sequence: UInt64 = 10, start: Int = 0, count: Int = 1, cursor: String? = nil) -> ConversationSnapshot {
        ConversationSnapshot(conversationId: chat, hostEpoch: epoch, lastSequence: sequence,
            messages: (start..<(start+count)).map { ConversationMessage(messageId: String($0), body: "Message \($0)", state: "completed", createdAt: String(1700000000000 + $0), attachmentIds: []) },
            assistantMessages: [], thread: ThreadProjection(nextCursor: cursor, hydrated: true))
    }
    func event(_ sequence: UInt64, epoch: String = "epoch", type: String = "activity") -> ReplayEvent {
        ReplayEvent(eventId: String(sequence), hostEpoch: epoch, sequence: sequence, occurredAt: "now", conversationId: nil, event: EventBody(type: type))
    }
    func testHistoryMergePreservesConcurrentRefresh() throws {
        let older = snapshot(sequence: 10, start: 0, count: 3, cursor: "earlier")
        let latest = ConversationSnapshot(conversationId: "a", hostEpoch: "epoch", lastSequence: 12,
            messages: [ConversationMessage(messageId: "2", body: "Newer text", state: "completed", createdAt: "1700000000002", attachmentIds: [])],
            assistantMessages: [], thread: ThreadProjection(nextCursor: "current", hydrated: true))
        let merged = try latest.mergingOlder(older)
        XCTAssertEqual(merged.lastSequence, 12)
        XCTAssertEqual(merged.messages.map(\.messageId), ["0", "1", "2"])
        XCTAssertEqual(merged.messages.last?.body, "Newer text")
        XCTAssertEqual(merged.thread.nextCursor, "earlier")
    }

    func testHistoryPrependKeepsEachCompactionIdentityExactlyOnce() throws {
        let compacted = ReadItem(id: "compact-1", type: "contextCompaction", state: "completed",
            text: "private summary", createdAt: "1700000000001", payload: nil)
        let older = ConversationSnapshot(conversationId: "a", hostEpoch: "epoch", lastSequence: 10,
            messages: [], assistantMessages: [], thread: ThreadProjection(nextCursor: "earlier", hydrated: true,
                turns: [ReadTurn(id: "turn", items: [compacted], status: "completed")]))
        let following = ReadItem(id: "reply-1", type: "agentMessage", state: "completed",
            text: "Following work", createdAt: "1700000000002", payload: nil)
        let newer = ConversationSnapshot(conversationId: "a", hostEpoch: "epoch", lastSequence: 12,
            messages: [], assistantMessages: [], thread: ThreadProjection(nextCursor: "current", hydrated: true,
                turns: [ReadTurn(id: "turn", items: [following], status: "completed")]))

        let merged = try newer.mergingOlder(older)
        XCTAssertEqual(merged.thread.turns?.first?.items.map(\.id), ["compact-1", "reply-1"])
        XCTAssertEqual(merged.rows(author: "Bot").filter(\.isContextCompaction).map(\.id), ["turn/compact-1"])
    }

    func testSnapshotNeverSkipsOtherConversations() throws {
        var state = ProjectionState()
        state.install(snapshot())
        state.install(snapshot("b", sequence: 90))
        XCTAssertEqual(state.lastSequence, 10)
        try state.consume(event(11))
        XCTAssertEqual(state.dirty, ["a", "b"])
        state.install(snapshot(sequence: 12))
        XCTAssertEqual(state.dirty, ["b"])
        XCTAssertEqual(state.lastSequence, 11)
    }
    func testResyncEpochGapDuplicateAndUnknownEvent() throws {
        var state = ProjectionState()
        state.install(snapshot())
        XCTAssertThrowsError(try state.consume(event(12)))
        XCTAssertThrowsError(try state.consume(event(11, epoch: "new")))
        XCTAssertThrowsError(try state.consume(event(10, type: "resync_required")))
        try state.consume(event(10))
        XCTAssertEqual(state.lastSequence, 10)
        try state.consume(event(11, type: "future_kind"))
        XCTAssertTrue(state.dirty.contains("a"))
        XCTAssertTrue(state.listDirty)
    }
    func testCrashBeforeAndAfterAtomicCommitPreservesIntent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadStore(root: root, host: "Mac", device: "phone")
        var state = ProjectionState()
        state.install(snapshot())
        try store.save(state)
        try store.saveIntent(Data("unsent draft and uncertain receipt".utf8), conversation: "a")
        let intent = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("intent-") }!
        try state.consume(event(11))
        // Simulated death before persistence: a new reader still sees the old cursor.
        XCTAssertEqual(try store.load().lastSequence, 10)
        try store.save(state)
        let recovered = try store.load()
        XCTAssertEqual(recovered.lastSequence, 11)
        XCTAssertTrue(recovered.dirty.contains("a"))
        XCTAssertEqual(try Data(contentsOf: intent), Data("unsent draft and uncertain receipt".utf8))
        try store.save(ProjectionState())
        XCTAssertEqual(try Data(contentsOf: intent), Data("unsent draft and uncertain receipt".utf8))
    }
    func testHostPartitionRemovalAndWriteFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = ReadStore(root: root, host: "../a", device: "phone")
        let b = ReadStore(root: root, host: "b", device: "phone")
        var state = ProjectionState(); state.install(snapshot())
        try a.save(state); try a.saveIntent(Data("draft".utf8), conversation: "a")
        XCTAssertTrue(try b.load().snapshots.isEmpty)
        try b.save(state); try a.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.directory.path))
        XCTAssertFalse(try b.load().snapshots.isEmpty)
        let bad = root.appendingPathComponent("not-a-directory")
        try Data().write(to: bad)
        XCTAssertThrowsError(try ReadStore(root: bad, host: "host", device: "device").save(state))
    }
    func testThousandItemsPaginateWithoutDuplicatesAndSortChronologically() throws {
        var combined = snapshot(start: 900, count: 100, cursor: "900")
        for start in stride(from: 800, through: 0, by: -100) {
            combined = try combined.mergingOlder(snapshot(start: start, count: 100, cursor: start == 0 ? nil : String(start)))
        }
        let rows = combined.rows(author: "Ada")
        XCTAssertEqual(rows.count, 1000)
        XCTAssertEqual(rows.first?.text, "Message 0")
        XCTAssertEqual(rows.last?.text, "Message 999")
        XCTAssertNil(combined.thread.nextCursor)
        let duplicate = try combined.mergingOlder(snapshot(start: 0, count: 100))
        XCTAssertEqual(duplicate.messages.count, 1000)
        XCTAssertThrowsError(try combined.mergingOlder(snapshot("other")))
        XCTAssertThrowsError(try combined.mergingOlder(snapshot(epoch: "new")))
    }
    func testActualRustFixtureDecodesAndKeepsAuthor() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let value = try JSONDecoder().decode(ConversationSnapshot.self, from: Data(contentsOf: root.appendingPathComponent("tests/contracts/native/conversation-snapshot.json")))
        XCTAssertFalse(value.messages.isEmpty)
        XCTAssertTrue(value.rows(author: "Ada").contains { $0.author == "Ada" })
        XCTAssertEqual(value.rows(author: "Ada").filter { $0.author == "Ada" }.count, 1)
    }

    func testGroupSpeakersAndStatusFiltering() throws {
        let group = GroupRead(id: "group", conversationId: "chat", name: "Team", isArchived: false, messages: [
            GroupMessage(messageId: "1", body: "Question", createdAt: "1000", authorKind: "user", authorBotName: nil, presentationKind: "message", outcome: nil),
            GroupMessage(messageId: "2", body: "routing internals", createdAt: "2000", authorKind: "coordinator", authorBotName: "Ada", presentationKind: "status", outcome: nil),
            GroupMessage(messageId: "3", body: "Answer", createdAt: "3000", authorKind: "member", authorBotName: "Ben", presentationKind: "message", outcome: "completed")
        ])
        XCTAssertEqual(group.rows.map(\.author), ["You", "Ben"])
        XCTAssertEqual(group.summary.title, "Team")
        var state = ProjectionState(); state.install(snapshot())
        state.groups["chat"] = group
        try state.consume(event(11))
        XCTAssertTrue(state.dirty.contains("chat"))
    }

    func testSnapshotRacingReplayStaysDirty() throws {
        var state = ProjectionState(); state.install(snapshot())
        try state.consume(event(11))
        state.install(snapshot(sequence: 10))
        XCTAssertTrue(state.dirty.contains("a"))
        XCTAssertEqual(state.lastSequence, 11)
    }
}
