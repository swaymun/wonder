import XCTest
@testable import WonderPairing

final class TurnLifecycleTests: XCTestCase {
    func testReadTurnRetainsAuthoritativeDaemonStatusAndReadsOlderCaches() throws {
        let turn = try JSONDecoder().decode(ReadTurn.self, from: Data(#"{"id":"turn","status":"inProgress","items":[]}"#.utf8))
        XCTAssertEqual(turn.status, "inProgress")
        XCTAssertTrue(turn.isInProgress)

        let old = try JSONDecoder().decode(ReadTurn.self, from: Data(#"{"id":"old","items":[]}"#.utf8))
        XCTAssertEqual(old.status, "unknown")
        XCTAssertFalse(old.isInProgress)
    }

    func testStaleReceiptsDoNotReactivateStoppedOrCompletedTurns() {
        let snapshot = snapshot(
            messages: [
                message("completed-receipt", turn: "turn-completed", state: "streaming"),
                message("stopped-receipt", turn: "turn-stopped", state: "accepted_by_codex")
            ],
            turns: [
                turn("turn-completed", status: "completed"),
                turn("turn-stopped", status: "interrupted")
            ])

        XCTAssertTrue(snapshot.activeTurnIDs.isEmpty)
        XCTAssertNil(snapshot.activeTurnID)
    }

    func testUnassignedAcceptanceAndDispatchKeepComposerWorkingWithoutAnActiveTurn() {
        let snapshot = snapshot(
            messages: [
                message("accepted", turn: nil, state: "accepted_by_wonder"),
                message("dispatching", turn: nil, state: "dispatching_to_codex")
            ],
            turns: [])

        XCTAssertTrue(snapshot.hasUnassignedPreTurnWork)
        XCTAssertTrue(snapshot.activeTurnIDs.isEmpty)
        XCTAssertNil(snapshot.activeTurnID)
    }

    func testNewestTerminalTurnSuppressesOlderActiveTurnAfterSteerAndReplay() throws {
        let first = turn("turn-first", status: "completed", items: [row("first-item", type: "commandExecution")])
        let steered = turn("turn-steered", status: "inProgress", items: [row("steered-item", type: "webSearch", state: "streaming")])
        let replayed = turn("turn-late", status: "interrupted", items: [row("late-item", type: "commandExecution")])
        let snapshot = snapshot(
            messages: [
                message("first-receipt", turn: "turn-first", state: "streaming"),
                message("steered-receipt", turn: "turn-steered", state: "completed"),
                message("late-receipt", turn: "turn-late", state: "streaming")
            ],
            turns: [first, steered, replayed])

        XCTAssertNil(snapshot.activeTurnID)
        XCTAssertTrue(snapshot.activeTurnIDs.isEmpty)

        let older = ThreadProjection(nextCursor: nil, hydrated: true, turns: [
            turn("turn-steered", status: "inProgress", items: [row("old-steered", type: "commandExecution")])
        ])
        let newer = ThreadProjection(nextCursor: nil, hydrated: true, turns: [
            turn("turn-steered", status: "completed", items: [row("new-steered", type: "agentMessage")])
        ])
        let merged = newer.mergingOlder(older)
        XCTAssertEqual(merged.turns?.first?.status, "completed")
        XCTAssertEqual(merged.turns?.first?.items.map(\.id), ["old-steered", "new-steered"])

        let unknown = ThreadProjection(nextCursor: nil, hydrated: true, turns: [
            turn("turn-steered", status: "unknown", items: [row("current-unknown", type: "commandExecution")])
        ])
        let unknownMerge = unknown.mergingOlder(older)
        XCTAssertEqual(unknownMerge.turns?.first?.status, "unknown")
        XCTAssertNil(unknownMerge.turns?.first?.terminalLabel)
        XCTAssertTrue(unknownMerge.turns?.first?.isInProgress == false)
    }

    func testOlderInProgressTurnAndNewerCompletedTurnHaveNoActiveTurn() throws {
        let cached = snapshot(messages: [], turns: [
            turn("turn-old", status: "inProgress", items: [row("old-item", type: "commandExecution")]),
            turn("turn-new", status: "completed", items: [row("new-item", type: "agentMessage")])
        ])
        let newest = ConversationSnapshot(
            conversationId: "chat", hostEpoch: "epoch", lastSequence: 2,
            messages: [], assistantMessages: [],
            thread: ThreadProjection(nextCursor: "older", hydrated: true,
                                     turns: [turn("turn-new", status: "completed", items: [row("new-reply", type: "agentMessage")])]))

        let merged = try newest.mergingOlder(cached)

        XCTAssertNil(merged.activeTurnID)
        XCTAssertTrue(merged.activeTurnIDs.isEmpty)
        XCTAssertEqual(merged.thread.turns?.map(\.id), ["turn-old", "turn-new"])
        XCTAssertEqual(merged.thread.turns?.first?.items.map(\.id), ["old-item"])
        XCTAssertEqual(merged.thread.turns?.first?.status, "inProgress")
        XCTAssertEqual(merged.thread.turns?.last?.items.map(\.id), ["new-item", "new-reply"])
        XCTAssertEqual(merged.thread.turns?.last?.status, "completed")
    }

    func testOlderCompletedTurnAndNewestInProgressTurnHaveActiveTurn() throws {
        let cached = snapshot(messages: [], turns: [
            turn("turn-old", status: "completed", items: [row("old-item", type: "commandExecution")])
        ])
        let newest = ConversationSnapshot(
            conversationId: "chat", hostEpoch: "epoch", lastSequence: 2,
            messages: [], assistantMessages: [],
            thread: ThreadProjection(nextCursor: "older", hydrated: true,
                                     turns: [turn("turn-current", status: "inProgress", items: [row("current-item", type: "webSearch", state: "streaming")])]))

        let merged = try newest.mergingOlder(cached)

        XCTAssertEqual(merged.activeTurnID, "turn-current")
        XCTAssertEqual(merged.activeTurnIDs, ["turn-current"])
        XCTAssertEqual(merged.thread.turns?.last?.status, "inProgress")
    }

    func testMergeWithOnlyNonTurnNewestPageKeepsCachedActiveTurnActionable() throws {
        let cached = snapshot(messages: [], turns: [
            turn("turn-current", status: "inProgress", items: [row("current-item", type: "webSearch", state: "streaming")])
        ])
        let newest = ConversationSnapshot(
            conversationId: "chat", hostEpoch: "epoch", lastSequence: 3,
            messages: [message("receipt", turn: "turn-current", state: "streaming")], assistantMessages: [],
            thread: ThreadProjection(nextCursor: "older", hydrated: true, turns: nil))

        let merged = try newest.mergingOlder(cached)

        XCTAssertEqual(merged.activeTurnID, "turn-current")
        XCTAssertEqual(merged.activeTurnIDs, ["turn-current"])
        XCTAssertEqual(merged.thread.turns?.first?.status, "inProgress")
        XCTAssertEqual(merged.thread.turns?.first?.items.map(\.id), ["current-item"])
    }

    func testMergePreservesHistoricalStatusesAndItemsWhileIgnoringStaleActiveTurn() throws {
        let cached = snapshot(messages: [], turns: [
            turn("turn-old", status: "inProgress", items: [row("old-cached", type: "commandExecution")])
        ])
        let newest = ConversationSnapshot(
            conversationId: "chat", hostEpoch: "epoch", lastSequence: 3,
            messages: [], assistantMessages: [],
            thread: ThreadProjection(nextCursor: "older", hydrated: true,
                                     turns: [turn("turn-new", status: "completed", items: [row("new-reply", type: "agentMessage")])]))
        let hydratedOlder = ConversationSnapshot(
            conversationId: "chat", hostEpoch: "epoch", lastSequence: 2,
            messages: [], assistantMessages: [],
            thread: ThreadProjection(nextCursor: nil, hydrated: true,
                                     turns: [turn("turn-old", status: "inProgress", items: [row("old-hydrated", type: "webSearch", state: "waiting")])]))

        let hydrated = try newest.mergingOlder(hydratedOlder)
        let merged = try hydrated.mergingOlder(cached)

        XCTAssertNil(merged.activeTurnID)
        XCTAssertTrue(merged.activeTurnIDs.isEmpty)
        XCTAssertEqual(merged.thread.turns?.map(\.id), ["turn-old", "turn-new"])
        XCTAssertEqual(merged.thread.turns?.first?.items.map(\.id), ["old-cached", "old-hydrated"])
        XCTAssertEqual(merged.thread.turns?.first?.status, "inProgress")
        XCTAssertEqual(merged.thread.turns?.last?.status, "completed")
    }

    func testLatestCanonicalTurnWinsWhenReplayLeavesMultipleTurnsInProgress() {
        let oldActive = turn("turn-old-active", status: "inProgress", items: [row("old-command", type: "commandExecution")])
        let canonical = turn("turn-canonical", status: "inProgress", items: [row("canonical-command", type: "commandExecution")])
        let rows = [
            feedRow("old-command", type: "commandExecution", turn: "turn-old-active", timestamp: "1000"),
            feedRow("canonical-command", type: "commandExecution", turn: "turn-canonical", timestamp: "2000")
        ]
        let snapshot = snapshot(
            messages: [
                message("old-late-receipt", turn: "turn-old-active", state: "streaming"),
                message("canonical-receipt", turn: "turn-canonical", state: "completed")
            ],
            turns: [oldActive, canonical])
        let entries = ChatFeedEntry.grouping(rows, activeTurnIDs: snapshot.activeTurnIDs)

        XCTAssertEqual(snapshot.activeTurnIDs, ["turn-canonical"])
        XCTAssertEqual(snapshot.activeTurnID, "turn-canonical")
        XCTAssertEqual(ChatFeedEntry.latestActivityEntryID(entries, turnID: snapshot.activeTurnID), "canonical-command")
        XCTAssertEqual(ChatFeedEntry.lifecycleLabel(rows: entries[0].rows, turn: oldActive,
                                                    isLatestSegmentForTurn: true, isLatestActiveSegment: false), "Ran 1 command")
        XCTAssertEqual(ChatFeedEntry.lifecycleLabel(rows: entries[1].rows, turn: canonical,
                                                    isLatestSegmentForTurn: true, isLatestActiveSegment: true), "Working…")
    }

    func testActionSummaryUsesBoundedCategoryCountsInsteadOfActivityTitles() {
        let rows = [
            feedRow("command-one", type: "commandExecution", payload: ["command": .string("a very long command")]),
            feedRow("command-two", type: "commandExecution", payload: ["command": .string("another very long command")]),
            feedRow("search", type: "webSearch")
        ]
        XCTAssertEqual(ChatFeedEntry.actionSummary(rows: rows), "Ran 2 commands · Searched the web")

        XCTAssertEqual(ChatFeedEntry.actionSummary(rows: [feedRow("error", type: "error")]), "Encountered 1 error")
        XCTAssertEqual(ChatFeedEntry.actionSummary(rows: [feedRow("image", type: "imageGeneration")]), "1 image action")

        let manyCommands = (0..<200).map { index in
            feedRow("command-\(index)", type: "commandExecution",
                    payload: ["command": .string(String(repeating: "private command output ", count: 100))])
        }
        let summary = ChatFeedEntry.actionSummary(rows: manyCommands)
        XCTAssertEqual(summary, "Ran 200 commands")
        XCTAssertLessThan(summary?.count ?? .max, 64)
        XCTAssertFalse(summary?.contains("private") == true)
    }

    func testOnlyLatestActivitySegmentShowsTurnStateOrDuration() throws {
        let completedTurn = turn("turn-completed", status: "completed", startedAt: "0", completedAt: "1312000")
        let completedRows = [
            feedRow("command", type: "commandExecution", turn: "turn-completed", timestamp: "2000"),
            feedRow("reply-one", type: "agentMessage", turn: "turn-completed", timestamp: "3000"),
            feedRow("search", type: "webSearch", turn: "turn-completed", timestamp: "4000"),
            feedRow("reply-two", type: "agentMessage", turn: "turn-completed", timestamp: "5000")
        ]
        let completedEntries = ChatFeedEntry.grouping(completedRows)
        let latestCompleted = ChatFeedEntry.latestActivityEntryIDs(completedEntries)
        XCTAssertEqual(completedEntries.map(\.id), ["command", "reply-one", "search", "reply-two"])
        XCTAssertEqual(ChatFeedEntry.lifecycleLabel(rows: completedEntries[0].rows, turn: completedTurn,
                                                    isLatestSegmentForTurn: latestCompleted.contains(completedEntries[0].id), isLatestActiveSegment: false), "Ran 1 command")
        XCTAssertEqual(ChatFeedEntry.lifecycleLabel(rows: completedEntries[2].rows, turn: completedTurn,
                                                    isLatestSegmentForTurn: latestCompleted.contains(completedEntries[2].id), isLatestActiveSegment: false), "Worked for 21m 52s")

        let activeTurn = turn("turn-active", status: "inProgress")
        let activeRows = [
            feedRow("active-command", type: "commandExecution", turn: "turn-active", timestamp: "6000"),
            feedRow("active-reply", type: "agentMessage", turn: "turn-active", timestamp: "7000"),
            feedRow("active-search", type: "webSearch", state: "streaming", turn: "turn-active", timestamp: "8000")
        ]
        let activeEntries = ChatFeedEntry.grouping(activeRows, activeTurnIDs: ["turn-active"])
        let latestActive = ChatFeedEntry.latestActivityEntryIDs(activeEntries)
        XCTAssertEqual(ChatFeedEntry.lifecycleLabel(rows: activeEntries[0].rows, turn: activeTurn,
                                                    isLatestSegmentForTurn: latestActive.contains(activeEntries[0].id), isLatestActiveSegment: false), "Ran 1 command")
        XCTAssertEqual(ChatFeedEntry.lifecycleLabel(rows: activeEntries[2].rows, turn: activeTurn,
                                                    isLatestSegmentForTurn: latestActive.contains(activeEntries[2].id), isLatestActiveSegment: true), "Working…")
        XCTAssertEqual(latestActive, ["active-search"])
    }

    func testTerminalLabelsStayTruthfulAndUnknownNeverClaimsCompletedWork() {
        let command = feedRow("command", type: "commandExecution")
        XCTAssertEqual(ChatFeedEntry.lifecycleLabel(rows: [command], turn: turn("failed", status: "failed"),
                                                    isLatestSegmentForTurn: true, isLatestActiveSegment: false), "Couldn’t finish")
        XCTAssertEqual(ChatFeedEntry.lifecycleLabel(rows: [command], turn: turn("stopped", status: "interrupted"),
                                                    isLatestSegmentForTurn: true, isLatestActiveSegment: false), "Stopped")

        let unknown = turn("unknown", status: "unknown", startedAt: "0", completedAt: "1000")
        XCTAssertEqual(ChatFeedEntry.lifecycleLabel(rows: [], turn: unknown,
                                                    isLatestSegmentForTurn: true, isLatestActiveSegment: false), "Work status unavailable")
        XCTAssertNotEqual(ChatFeedEntry.lifecycleLabel(rows: [command], turn: unknown,
                                                       isLatestSegmentForTurn: true, isLatestActiveSegment: false), "Worked")
    }

    func testLocalQueuePlaceholdersCannotReplaceTheActiveRuntimeTurn() throws {
        for state in ["accepted_by_wonder", "dispatching_to_codex", "interrupted", "failed"] {
            let running = snapshot(messages: [message("guide", turn: "runtime", state: "streaming")],
                                   turns: [turn("runtime", status: "inProgress", items: [row("command", type: "commandExecution")])])
            let queuePage = snapshot(messages: [message("queued", turn: nil, state: state)],
                                     turns: [turn("local:queued", status: "unknown")])
            let merged = try queuePage.mergingOlder(running)
            XCTAssertEqual(merged.activeTurnID, "runtime", state)
            XCTAssertEqual(merged.activeTurnIDs, ["runtime"], state)
            XCTAssertNil(merged.latestRequestIssue, state)
            let entries = ChatFeedEntry.grouping(merged.rows(author: "Bot"), activeTurnIDs: merged.activeTurnIDs)
            let latest = try XCTUnwrap(ChatFeedEntry.latestActivityEntryID(entries, turnID: merged.activeTurnID))
            let activity = try XCTUnwrap(entries.first(where: { $0.id == latest }))
            XCTAssertEqual(ChatFeedEntry.lifecycleLabel(rows: activity.rows, turn: merged.thread.turns?.first,
                isLatestSegmentForTurn: true, isLatestActiveSegment: true), "Working…")
        }
        let ended = snapshot(messages: [], turns: [turn("old", status: "inProgress"),
            turn("new", status: "completed"), turn("local:cancelled", status: "unknown")])
        XCTAssertNil(ended.activeTurnID)
    }

    func testCancelledUndispatchedCopiesStayInHistoryButDoNotAppearDelivered() throws {
        let cancelled = message("cancelled", turn: nil, state: "interrupted")
        let item = ReadItem(id: "cancelled", type: "userMessage", state: "interrupted", text: "cancelled", createdAt: "2000",
                            payload: ["clientId": .string("client-cancelled")])
        for turns in [[], [turn("local:cancelled", status: "unknown", items: [item])]] {
            let value = snapshot(messages: [cancelled], turns: turns)
            XCTAssertEqual(value.messages.count, 1)
            XCTAssertTrue(value.rows(author: "Bot").isEmpty)
            XCTAssertNil(value.latestRequestIssue)
        }
        let delivered = snapshot(messages: [message("stopped", turn: "runtime", state: "interrupted")],
                                 turns: [turn("runtime", status: "interrupted")])
        XCTAssertEqual(delivered.rows(author: "Bot").count, 1)
        XCTAssertEqual(delivered.latestRequestIssue, "interrupted")
    }

    func testRealFailuresRemainVisibleAndStaleReceiptsCannotOverrideCompletedWork() {
        for state in ["uncertain", "safe_to_retry", "failed"] {
            XCTAssertEqual(snapshot(messages: [message("failed", turn: nil, state: state)], turns: []).latestRequestIssue, state)
        }
        let finished = snapshot(messages: [message("stale", turn: "runtime", state: "uncertain"),
                                           message("cancelled", turn: nil, state: "interrupted")],
                                turns: [turn("runtime", status: "completed"), turn("local:cancelled", status: "unknown")])
        XCTAssertNil(finished.latestRequestIssue)
        XCTAssertFalse(finished.hasUnassignedPreTurnWork)
    }

    private func snapshot(messages: [ConversationMessage], turns: [ReadTurn]) -> ConversationSnapshot {
        ConversationSnapshot(conversationId: "chat", hostEpoch: "epoch", lastSequence: 1,
                             messages: messages, assistantMessages: [],
                             thread: ThreadProjection(nextCursor: nil, hydrated: true, turns: turns))
    }

    private func message(_ id: String, turn: String?, state: String) -> ConversationMessage {
        ConversationMessage(clientMessageId: "client-" + id, codexTurnId: turn, messageId: id,
                            body: id, state: state, createdAt: "1000", attachmentIds: [])
    }

    private func turn(_ id: String, status: String, items: [ReadItem] = [], startedAt: String? = nil, completedAt: String? = nil) -> ReadTurn {
        ReadTurn(id: id, items: items, startedAt: startedAt, completedAt: completedAt, status: status)
    }

    private func row(_ id: String, type: String, state: String = "completed", turn: String = "turn", timestamp: String = "1000") -> ReadItem {
        ReadItem(id: id, type: type, state: state, text: type == "agentMessage" ? "A reply" : nil,
                 createdAt: timestamp, payload: type == "commandExecution" ? ["command": .string("example")] : nil)
    }

    private func feedRow(_ id: String, type: String, state: String = "completed", turn: String = "turn",
                         timestamp: String = "1000", payload: [String: ThreadValue] = [:]) -> ReadRow {
        ReadRow(id: id, author: "Ada", text: type == "agentMessage" ? "A reply" : "",
                isUser: false, timestamp: timestamp, turnId: turn,
                item: ReadItem(id: id, type: type, state: state, text: type == "agentMessage" ? "A reply" : nil,
                               createdAt: timestamp, payload: payload))
    }
}
