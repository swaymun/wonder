import XCTest
@testable import WonderPairing

final class ActivityDisclosurePolicyTests: XCTestCase {
    func testTurnLifecycleMappingNeverTreatsUnknownAsTerminal() {
        XCTAssertEqual(ActivityDisclosurePolicy.lifecycle(status: "inProgress"), .active)
        XCTAssertEqual(ActivityDisclosurePolicy.lifecycle(status: "completed"), .completed)
        XCTAssertEqual(ActivityDisclosurePolicy.lifecycle(status: "interrupted"), .interrupted)
        XCTAssertEqual(ActivityDisclosurePolicy.lifecycle(status: "failed"), .failed)
        XCTAssertEqual(ActivityDisclosurePolicy.lifecycle(status: "quiet"), .unknown)
        XCTAssertFalse(ActivityDisclosurePolicy.lifecycle(status: nil).isTerminal)
    }

    func testActiveTurnOpensEveryVisibleSegmentAndKeepsStableIDs() {
        let entries = [
            entry("turn", "segment-1", .active),
            entry("turn", "segment-2", .active),
            entry("old-turn", "old", .completed)
        ]

        XCTAssertEqual(
            ActivityDisclosurePolicy.expandedEntryIDs(entries: entries, state: .init()),
            ["segment-1", "segment-2"]
        )
    }

    func testNewActiveSegmentOpensAfterAStreamUpdateWithoutRewritingExistingIDs() {
        let first = [entry("turn", "first", .active)]
        let state = ActivityDisclosurePolicy.reconciled(.init(), entries: first)
        let revised = first + [entry("turn", "later", .active)]

        XCTAssertEqual(ActivityDisclosurePolicy.expandedEntryIDs(entries: revised, state: state), ["first", "later"])
        XCTAssertEqual(revised.map(\.key.entryID), ["first", "later"])
    }

    func testHistoricalInProgressTurnDoesNotAutoOpenAfterAReplayOrHistoryInsert() {
        let historical = entry("chat", "old-turn", "old-segment", .active, autoOpenWhileActive: false)
        let current = entry("chat", "current-turn", "current-segment", .active)

        XCTAssertEqual(
            ActivityDisclosurePolicy.expandedEntryIDs(entries: [historical, current], state: .init()),
            ["current-segment"]
        )
    }

    func testHistoricalInProgressTurnRemainsManuallyInspectable() {
        let historical = entry("chat", "old-turn", "old-segment", .active, autoOpenWhileActive: false)

        var state = ActivityDisclosurePolicy.State()
        state = ActivityDisclosurePolicy.toggled(state, entry: historical, isExpanded: false)
        XCTAssertEqual(
            ActivityDisclosurePolicy.expandedEntryIDs(entries: [historical], state: state),
            ["old-segment"]
        )

        state = ActivityDisclosurePolicy.toggled(state, entry: historical, isExpanded: true)
        XCTAssertTrue(ActivityDisclosurePolicy.expandedEntryIDs(entries: [historical], state: state).isEmpty)
    }

    func testManualCollapseSuppressesOnlyThatRunningSegment() {
        let first = entry("turn", "first", .active)
        let second = entry("turn", "second", .active)
        let state = ActivityDisclosurePolicy.toggled(.init(), entry: first, isExpanded: true)

        XCTAssertEqual(ActivityDisclosurePolicy.expandedEntryIDs(entries: [first, second], state: state), ["second"])
    }

    func testManualCollapseSurvivesStreamingUpdatesForThatTurn() {
        let first = entry("turn", "first", .active)
        let state = ActivityDisclosurePolicy.toggled(.init(), entry: first, isExpanded: true)
        let revised = entry("turn", "first", .active)

        XCTAssertTrue(ActivityDisclosurePolicy.expandedEntryIDs(entries: [revised], state: state).isEmpty)
    }

    func testCompletionClearsAutomaticExpansionAndRunningOverride() {
        let active = entry("turn", "segment", .active)
        let collapsed = ActivityDisclosurePolicy.toggled(.init(), entry: active, isExpanded: true)
        let completed = entry("turn", "segment", .completed)
        let state = ActivityDisclosurePolicy.reconciled(collapsed, entries: [completed])

        XCTAssertTrue(ActivityDisclosurePolicy.expandedEntryIDs(entries: [completed], state: state).isEmpty)
    }

    func testInterruptionAndFailureCollapseWithoutInspectingItemState() {
        for lifecycle in [ActivityDisclosurePolicy.Lifecycle.interrupted, .failed] {
            let active = entry("turn", "segment", .active)
            let collapsed = ActivityDisclosurePolicy.toggled(.init(), entry: active, isExpanded: true)
            let terminal = entry("turn", "segment", lifecycle)
            let state = ActivityDisclosurePolicy.reconciled(collapsed, entries: [terminal])
            XCTAssertTrue(ActivityDisclosurePolicy.expandedEntryIDs(entries: [terminal], state: state).isEmpty)
        }
    }

    func testUnknownDoesNotAutoOpenButSearchCanRevealIt() {
        let unknown = entry("turn", "segment", .unknown)
        let key = unknown.key

        XCTAssertTrue(ActivityDisclosurePolicy.expandedEntryIDs(entries: [unknown], state: .init()).isEmpty)
        XCTAssertEqual(
            ActivityDisclosurePolicy.expandedEntryIDs(entries: [unknown], state: .init(), searchReveal: [key]),
            ["segment"]
        )
    }

    func testManualReopenAfterCompletionStaysOpenAcrossReplayedTerminalEvent() {
        let completed = entry("turn", "segment", .completed)
        let reopened = ActivityDisclosurePolicy.toggled(.init(), entry: completed, isExpanded: false)
        let replayed = ActivityDisclosurePolicy.reconciled(reopened, entries: [completed])

        XCTAssertEqual(ActivityDisclosurePolicy.expandedEntryIDs(entries: [completed], state: replayed), ["segment"])
    }

    func testActiveTransitionClosesAPreviouslyReopenedUnknownEntry() {
        let unknown = entry("turn", "segment", .unknown)
        let reopened = ActivityDisclosurePolicy.toggled(.init(), entry: unknown, isExpanded: false)
        let active = entry("turn", "segment", .active)
        let state = ActivityDisclosurePolicy.reconciled(reopened, entries: [active])

        XCTAssertEqual(ActivityDisclosurePolicy.expandedEntryIDs(entries: [active], state: state), ["segment"])
    }

    func testPruningKeepsOverridesForRetainedTurnsAndDropsRemovedTurns() {
        let retained = entry("turn-kept", "kept", .active)
        let removed = entry("turn-removed", "removed", .active)
        var state = ActivityDisclosurePolicy.State()
        state = ActivityDisclosurePolicy.toggled(state, entry: retained, isExpanded: true)
        state = ActivityDisclosurePolicy.toggled(state, entry: removed, isExpanded: true)

        let pruned = ActivityDisclosurePolicy.reconciled(
            state,
            entries: [retained],
            retainedConversationID: "chat",
            retainedTurnIDs: ["turn-kept"]
        )
        XCTAssertTrue(ActivityDisclosurePolicy.expandedEntryIDs(entries: [retained], state: pruned).isEmpty)
        XCTAssertEqual(
            ActivityDisclosurePolicy.expandedEntryIDs(entries: [removed], state: pruned),
            ["removed"],
            "A removed turn is no longer owned by the presentation and must not affect a future owner."
        )
    }

    func testConversationScopePreventsASecondConversationFromReusingOverrides() {
        let first = entry("chat-a", "turn", "segment", .active)
        let second = entry("chat-b", "turn", "segment", .active)
        let state = ActivityDisclosurePolicy.toggled(.init(), entry: first, isExpanded: true)
        let pruned = ActivityDisclosurePolicy.reconciled(state, entries: [second], retainedConversationID: "chat-b", retainedTurnIDs: ["turn"])

        XCTAssertEqual(ActivityDisclosurePolicy.expandedEntryIDs(entries: [second], state: pruned), ["segment"])
    }

    func testTwoSimultaneousGroupWorkersOpenIndependently() {
        let entries = [entry("group", "worker-a", .active), entry("group", "worker-b", .active)]
        XCTAssertEqual(ActivityDisclosurePolicy.expandedEntryIDs(entries: entries, state: .init()), ["worker-a", "worker-b"])

        let completedA = entry("group", "worker-a", .completed)
        let state = ActivityDisclosurePolicy.reconciled(.init(), entries: [completedA, entries[1]])
        XCTAssertEqual(ActivityDisclosurePolicy.expandedEntryIDs(entries: [completedA, entries[1]], state: state), ["worker-b"])
    }

    func testChildCompletionDoesNotCollapseAnActiveParentConversation() {
        let parent = entry("parent-chat", "parent-turn", "parent-segment", .active)
        let child = entry("child-chat", "child-turn", "child-segment", .completed)
        let entries = [parent, child]

        XCTAssertEqual(ActivityDisclosurePolicy.expandedEntryIDs(entries: entries, state: .init()), ["parent-segment"])
        XCTAssertTrue(ActivityDisclosurePolicy.expandedEntryIDs(entries: [child], state: .init()).isEmpty)
    }

    func testGroupPlanLifecycleUsesPlanAuthority() throws {
        let active = try plan("""
        {"assignments":[{"botId":"a","brief":"A","dependsOn":[],"access":"read-only","state":"working"}],"startedAt":"2026-09-12T00:00:00Z","finishedAt":null,"error":null,"cancelled":false}
        """)
        let complete = try plan("""
        {"assignments":[{"botId":"a","brief":"A","dependsOn":[],"access":"read-only","state":"completed"}],"startedAt":"2026-09-12T00:00:00Z","finishedAt":"2026-09-12T00:01:00Z","error":null,"cancelled":false}
        """)
        let failed = try plan("""
        {"assignments":[{"botId":"a","brief":"A","dependsOn":[],"access":"read-only","state":"failed"}],"startedAt":"2026-09-12T00:00:00Z","finishedAt":"2026-09-12T00:01:00Z","error":null,"cancelled":false}
        """)

        XCTAssertEqual(ActivityDisclosurePolicy.lifecycle(for: active), .active)
        XCTAssertEqual(ActivityDisclosurePolicy.lifecycle(for: complete), .completed)
        XCTAssertEqual(ActivityDisclosurePolicy.lifecycle(for: failed), .failed)
    }

    func testGroupRunCollapseTerminalTransitionAndReopenUseStableKey() throws {
        let activePlan = try plan("""
        {"assignments":[{"botId":"a","brief":"A","dependsOn":[],"access":"read-only","state":"working"}],"startedAt":"2026-09-12T00:00:00Z","finishedAt":null,"error":null,"cancelled":false}
        """)
        let completedPlan = try plan("""
        {"assignments":[{"botId":"a","brief":"A","dependsOn":[],"access":"read-only","state":"completed"}],"startedAt":"2026-09-12T00:00:00Z","finishedAt":"2026-09-12T00:01:00Z","error":null,"cancelled":false}
        """)
        let active = ActivityDisclosurePolicy.Entry(
            conversationID: "group",
            turnID: "run:message",
            entryID: "group-work:group:message",
            lifecycle: ActivityDisclosurePolicy.lifecycle(for: activePlan)
        )
        let completed = ActivityDisclosurePolicy.Entry(
            conversationID: "group",
            turnID: "run:message",
            entryID: "group-work:group:message",
            lifecycle: ActivityDisclosurePolicy.lifecycle(for: completedPlan)
        )
        let collapsed = ActivityDisclosurePolicy.toggled(.init(), entry: active, isExpanded: true)
        let terminal = ActivityDisclosurePolicy.reconciled(collapsed, entries: [completed], retainedConversationID: "group", retainedTurnIDs: ["run:message"])
        XCTAssertTrue(ActivityDisclosurePolicy.expandedEntryIDs(entries: [completed], state: terminal).isEmpty)

        let reopened = ActivityDisclosurePolicy.toggled(terminal, entry: completed, isExpanded: false)
        XCTAssertEqual(ActivityDisclosurePolicy.expandedEntryIDs(entries: [completed], state: reopened), ["group-work:group:message"])
    }

    private func entry(_ turnID: String, _ entryID: String, _ lifecycle: ActivityDisclosurePolicy.Lifecycle) -> ActivityDisclosurePolicy.Entry {
        entry("chat", turnID, entryID, lifecycle)
    }

    private func entry(
        _ conversationID: String,
        _ turnID: String,
        _ entryID: String,
        _ lifecycle: ActivityDisclosurePolicy.Lifecycle,
        autoOpenWhileActive: Bool = true
    ) -> ActivityDisclosurePolicy.Entry {
        ActivityDisclosurePolicy.Entry(
            conversationID: conversationID,
            turnID: turnID,
            entryID: entryID,
            lifecycle: lifecycle,
            autoOpenWhileActive: autoOpenWhileActive
        )
    }

    private func plan(_ json: String) throws -> GroupCollaboration.Plan {
        try JSONDecoder().decode(GroupCollaboration.Plan.self, from: Data(json.utf8))
    }
}
