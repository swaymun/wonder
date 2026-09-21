import XCTest
@testable import WonderPairing

final class ActivityPresentationTests: XCTestCase {
    func testProfileSaveIsAStandaloneStatusAndFailuresStayVisible() {
        let result = ThreadValue.array([.object(["type": .string("inputText"), "text": .string(#"{"saved":true,"name":"iOS Scout","statusLine":"Renamed to iOS Scout"}"#)])])
        let saved = row("rename", type: "dynamicToolCall", payload: ["tool": .string("wonder_update_profile"), "success": .bool(true), "contentItems": result])
        XCTAssertEqual(saved.profileStatus, "Renamed to iOS Scout")
        XCTAssertNil(saved.activity)
        let entries = ChatFeedEntry.grouping([row("before", type: "commandExecution"), saved, row("after", type: "webSearch")])
        XCTAssertEqual(entries.count, 3)
        XCTAssertFalse(entries[1].isActivity)
        let failed = row("failure", type: "dynamicToolCall", payload: ["tool": .string("wonder_update_profile"), "success": .bool(false), "contentItems": result])
        XCTAssertNil(failed.profileStatus)
        XCTAssertTrue(failed.activity?.failed == true)
        XCTAssertNil(row("pending", type: "dynamicToolCall", state: "started", payload: ["tool": .string("wonder_update_profile"), "contentItems": result]).profileStatus)
    }

    func testKnownLifecycleActivitiesHaveHumanLabelsAndLazyDetails() throws {
        let fragments: ThreadValue = .array([
            .object(["hookRunId": .string("private-hook-id"), "text": .string("Use the project instructions.")]),
            .object(["hookRunId": .string("another-private-id"), "text": .string("Keep the answer concise.")])
        ])
        let hook = row("hook", type: "hookPrompt", payload: ["fragments": fragments])
        XCTAssertEqual(hook.activitySummary?.title, "Additional instructions")
        XCTAssertEqual(hook.activitySummary?.symbol, "text.badge.plus")
        XCTAssertTrue(try XCTUnwrap(hook.activitySummary).details.isEmpty)
        let hookDetails = try XCTUnwrap(hook.activity).details
        XCTAssertEqual(hookDetails.map(\.title), ["Instructions"])
        XCTAssertEqual(hookDetails.first?.text, "Use the project instructions.\n\nKeep the answer concise.")
        XCTAssertFalse(hookDetails.map(\.text).joined().contains("private-hook-id"))

        let entered = row("review-start", type: "enteredReviewMode", payload: ["review": .string("Check the native layout")])
        XCTAssertEqual(entered.activity?.title, "Start review")
        XCTAssertEqual(entered.activity?.symbol, "checkmark.shield")
        XCTAssertEqual(entered.activity?.details.map(\.text), ["Check the native layout"])

        let exited = row("review-finish", type: "exitedReviewMode", payload: ["review": .string("Layout review complete")])
        XCTAssertEqual(exited.activity?.title, "Finish review")
        XCTAssertEqual(exited.activity?.symbol, "checkmark.shield.fill")
        XCTAssertEqual(exited.activity?.details.map(\.text), ["Layout review complete"])

        let compaction = row("compact", type: "contextCompaction", itemText: nil)
        XCTAssertEqual(compaction.activitySummary?.title, "Context compaction")
        XCTAssertEqual(compaction.activitySummary?.symbol, "text.badge.checkmark")
        XCTAssertTrue(try XCTUnwrap(compaction.activitySummary).details.isEmpty)
        XCTAssertTrue(try XCTUnwrap(compaction.activity).details.isEmpty)
        XCTAssertFalse(compaction.activity?.details.map(\.text).joined().contains("private summary") == true)
    }

    func testContextCompactionStatesStayTruthfulWithoutExposingBodies() {
        let states = [
            ("started", "Compacting context…", true),
            ("streaming", "Compacting context…", true),
            ("waiting", "Compacting context…", true),
            ("completed", "Context compacted", false),
            ("interrupted", "Context compaction stopped", false),
            ("failed", "Context compaction failed", false),
            ("unknown", "Context compaction status unavailable", false)
        ]
        for (state, label, running) in states {
            let value = row("compaction-\(state)", type: "contextCompaction", state: state,
                payload: ["privateSummary": .string("private summary")], itemText: "private instructions")
            XCTAssertEqual(value.contextCompactionPresentation?.label, label)
            XCTAssertEqual(value.contextCompactionPresentation?.isRunning, running)
            XCTAssertTrue(value.activitySummary?.details.isEmpty == true)
            XCTAssertTrue(value.activity?.details.isEmpty == true)
        }
    }

    func testWaitShowsRequestedDurationWithoutConfusingInterruptionWithElapsedTime() throws {
        let examples: [(Double, String)] = [
            (0, "0 milliseconds"),
            (1, "1 millisecond"),
            (1_500, "1.5 seconds"),
            (15_000, "15 seconds"),
            (59_949, "59.9 seconds"),
            (59_950, "1 minute"),
            (60_000, "1 minute"),
            (65_000, "1 minute 5 seconds")
        ]
        for (duration, expected) in examples {
            let wait = row("wait-\(duration)", type: "sleep", payload: ["durationMs": .number(duration)])
            XCTAssertEqual(wait.activity?.title, "Wait")
            XCTAssertEqual(wait.activity?.symbol, "clock")
            XCTAssertEqual(wait.activity?.details.map(\.text), [expected])
            XCTAssertTrue(try XCTUnwrap(wait.activitySummary).details.isEmpty)
        }

        let interrupted = row("wait-interrupted", type: "sleep", state: "interrupted", payload: ["durationMs": .number(20_000)])
        XCTAssertEqual(interrupted.activity?.status, "Stopped")
        XCTAssertEqual(interrupted.activity?.details.map(\.text), ["20 seconds"])
        XCTAssertFalse(interrupted.activity?.details.map(\.text).joined().contains("elapsed") == true)
    }

    func testMalformedWaitDurationsStayHiddenAndNeverCrash() throws {
        let malformed: [ThreadValue] = [
            .string("15000"), .number(-1), .number(1.5), .number(.nan),
            .number(.infinity), .number(9_007_199_254_740_992), .null
        ]
        for (index, duration) in malformed.enumerated() {
            let wait = row("malformed-wait-\(index)", type: "sleep", payload: ["durationMs": duration])
            XCTAssertTrue(try XCTUnwrap(wait.activity).details.isEmpty)
        }
        XCTAssertTrue(try XCTUnwrap(row("missing-wait", type: "sleep").activity).details.isEmpty)
    }

    func testSubagentRowsNameTheAgentAndShowCanonicalState() throws {
        let examples: [(String, String, String, Bool, String)] = [
            ("started", "completed", "/private/agent/path · Started", false, "Another agent was started."),
            ("interacted", "started", "/private/agent/path · Interacted", true, "Another agent received an update."),
            ("interrupted", "interrupted", "/private/agent/path · Interrupted", false, "Another agent was stopped."),
            ("completed", "completed", "/private/agent/path · Completed", false, "Another agent finished its work.")
        ]
        for (kind, state, title, running, detail) in examples {
            let activity = try XCTUnwrap(row("agent-\(kind)", type: "subAgentActivity", state: state, payload: [
                "agentPath": .string("/private/agent/path"),
                "agentThreadId": .string("private-thread-id"),
                "kind": .string(kind)
            ]).activity)
            XCTAssertEqual(activity.title, title)
            XCTAssertEqual(activity.symbol, "person.2")
            XCTAssertEqual(activity.status, state == "started" ? "Running" : state == "interrupted" ? "Stopped" : "Completed")
            XCTAssertEqual(activity.isRunning, running)
            XCTAssertEqual(activity.details.map(\.text), [detail])
            let text = activity.details.map(\.text).joined()
            XCTAssertFalse(text.contains("private/agent"))
            XCTAssertFalse(text.contains("private-thread-id"))
        }
    }

    func testUnknownActivityHasSafeRecoveryCopyWithoutRawPayload() throws {
        let unknown = try XCTUnwrap(row("future", type: "futureActivity", state: "unknown", payload: [
            "privatePayload": .object(["secret": .string("do not show")])
        ]).activity)
        XCTAssertEqual(unknown.title, "New activity")
        XCTAssertEqual(unknown.status, "Status unavailable")
        XCTAssertEqual(unknown.details.map(\.text), ["This activity isn’t supported in this version of Wonder, so its details are unavailable."])
        XCTAssertFalse(unknown.details.map(\.text).joined().contains("do not show"))
    }

    func testEverySupportedActivityTypeHasItsOwnHumanPresentation() throws {
        let supported = [
            "commandExecution", "webSearch", "fileChange", "mcpToolCall", "dynamicToolCall",
            "collabAgentToolCall", "imageView", "imageGeneration", "functionCallOutput", "error",
            "reasoning", "plan", "hookPrompt", "subAgentActivity", "sleep", "enteredReviewMode",
            "exitedReviewMode", "contextCompaction"
        ]
        for type in supported {
            let presentation = try XCTUnwrap(row(type, type: type).activity)
            XCTAssertNotEqual(presentation.title, "New activity", "Supported type \(type) used the future-type fallback")
            XCTAssertNotEqual(presentation.symbol, "ellipsis.circle", "Supported type \(type) used the future-type symbol")
        }
        XCTAssertNil(row("user", type: "userMessage").activity)
        XCTAssertNil(row("reply", type: "agentMessage").activity)
        XCTAssertNil(row("approval", type: "approval").activity)
    }

    func testKnownActivityUnknownStateRemainsUnavailable() throws {
        let activity = try XCTUnwrap(row("unknown-state", type: "subAgentActivity", state: "unknown", payload: [
            "kind": .string("completed")
        ]).activity)
        XCTAssertEqual(activity.title, "Subagent · Completed")
        XCTAssertEqual(activity.status, "Status unavailable")
        XCTAssertFalse(activity.isRunning)
    }

    func testElapsedWorkUsesRecordedLifecycleAndOldCacheFallsBack() throws {
        let turn = ReadTurn(id: "t", items: [], startedAt: "2026-09-08T01:00:00Z", completedAt: "2026-09-08T01:01:05Z")
        XCTAssertEqual(turn.workedLabel, "Worked for 1m 5s")
        XCTAssertEqual(ReadTurn(id: "t", items: [], startedAt: "2000", completedAt: "1000").workedLabel, "Worked")
        let old = try JSONDecoder().decode(ReadTurn.self, from: Data(#"{"id":"t","items":[]}"#.utf8))
        XCTAssertEqual(old.workedLabel, "Worked")
    }
    func testDiffPreservesPatchMarkers() throws {
        let file = try XCTUnwrap(row("f", type: "fileChange", payload: ["diffs": .array([.object(["path": .string("hello.txt"), "diff": .string("@@ -1 +1 @@\n-old\n+new")])])]).activity)
        XCTAssertEqual(file.details.first?.isDiff, true)
        XCTAssertEqual(file.details.first?.text, "@@ -1 +1 @@\n-old\n+new")
    }
    private func row(_ id: String, type: String, state: String = "completed", turn: String = "turn", payload: [String: ThreadValue] = [:], itemText: String? = "Message") -> ReadRow {
        ReadRow(id: id, author: "Ada", text: "Message", isUser: type == "userMessage", timestamp: "1000",
                turnId: turn, item: ReadItem(id: id, type: type, state: state, text: itemText, createdAt: "1000", payload: payload))
    }
    func testVerifiedArtifactsStayOutOfTextAndRetainMetadata() throws {
        let file: ThreadValue = .object(["id":.string("file"), "name":.string("Chart.png"), "mimeType":.string("image/png"), "byteSize":.number(42), "sha256":.string("digest"), "state":.string("available"), "updatedAt":.string("now")])
        let result: ThreadValue = .object(["content":.array([.object(["type":.string("text"),"text":.string("Here is the chart")]), .object(["type":.string("wonderArtifact"),"file":file])])])
        let value = row("tool", type:"mcpToolCall", payload:["result":result])
        XCTAssertEqual(value.toolFiles.map(\.id), ["file"])
        XCTAssertEqual(value.activity?.details.first?.text, "Here is the chart")
        XCTAssertEqual(value.toolFiles.first?.sha256, "digest")
        let localImage = row("local", type: "imageView", payload: ["result":result])
        XCTAssertEqual(localImage.activity?.title, "Image")
        XCTAssertEqual(localImage.toolFiles.map(\.id), ["file"])
        XCTAssertTrue(ChatFeedEntry.grouping([localImage])[0].isActivity)
    }
    func testSearchFocusIsolatesExactCommentaryRowWithoutLosingAdjacentActivity() {
        let rows = [row("before", type:"commandExecution"),
                    row("match", type:"agentMessage", payload:["phase":.string("commentary")]),
                    row("after", type:"webSearch")]
        XCTAssertEqual(ChatFeedEntry.grouping(rows).count, 1)
        let focused = ChatFeedEntry.grouping(rows, focusedRowID:"match")
        XCTAssertEqual(focused.map(\.id), ["before", "match", "after"])
        XCTAssertEqual(focused.flatMap(\.rows).map(\.id), rows.map(\.id))
    }
    func testGeneratedImagePreviewBelongsToExpandedActivity() throws {
        let file: ThreadValue = .object(["id":.string("generated-file"), "name":.string("Tool result.png"), "mimeType":.string("image/png"), "byteSize":.number(42), "sha256":.string("digest"), "state":.string("available"), "updatedAt":.string("now")])
        let result: ThreadValue = .object(["content":.array([.object(["type":.string("wonderArtifact"),"file":file])])])
        let image = row("generated", type: "imageGeneration", payload: ["result":result, "failure":.null])
        XCTAssertEqual(image.activity?.title, "Generate image")
        XCTAssertEqual(image.activity?.symbol, "photo")
        XCTAssertEqual(image.activity?.state, "completed")
        XCTAssertTrue(try XCTUnwrap(image.activity).details.isEmpty)
        XCTAssertEqual(image.toolFiles.map(\.id), ["generated-file"])
        let entries = ChatFeedEntry.grouping([row("before", type:"commandExecution"), image])
        let collapsed = ChatFeedNode.visible(entries, expanded: [])
        let expanded = ChatFeedNode.visible(entries, expanded: [entries[0].id])
        func files(_ nodes: [ChatFeedNode]) -> [String] {
            nodes.compactMap { node in if case .file = node.content { return node.id }; return nil }
        }
        XCTAssertTrue(files(collapsed).isEmpty)
        XCTAssertEqual(files(expanded).count, 1)
        XCTAssertEqual(files(ChatFeedNode.visible(entries, expanded: [entries[0].id])), files(expanded))
    }
    func testGeneratedImageLegacyPayloadAndFailureNeverPrintImageBytes() throws {
        let legacy = row("legacy", type:"imageGeneration", payload:["result":.string("PRIVATE_BASE64"), "savedPath":.string("/private/generated.png")])
        let text = try XCTUnwrap(legacy.activity).details.map(\.text).joined()
        XCTAssertTrue(text.contains("Preview unavailable"))
        XCTAssertFalse(text.contains("PRIVATE_BASE64"))
        XCTAssertFalse(text.contains("/private"))
        let failed = row("failed", type:"imageGeneration", payload:["result":.null, "failure":.string("Generation failed")])
        XCTAssertTrue(try XCTUnwrap(failed.activity).failed)
        XCTAssertEqual(failed.activity?.details.map(\.text), ["Generation failed"])
        XCTAssertTrue(row("pending", type:"imageGeneration", state:"started", payload:["result":.null]).activity?.isRunning == true)
    }
    func testGroupingPreservesReplyQuestionAndTurnBoundaries() {
        let rows = [row("u", type:"userMessage"), row("a", type:"commandExecution"), row("b", type:"webSearch"),
                    row("reply", type:"agentMessage"), row("c", type:"fileChange"), row("q", type:"approval"),
                    row("d", type:"mcpToolCall"), row("e", type:"webSearch", turn:"next")]
        let entries = ChatFeedEntry.grouping(rows)
        XCTAssertEqual(entries.map { $0.rows.count }, [1, 2, 1, 1, 1, 1, 1])
        XCTAssertFalse(entries[0].isActivity)
        XCTAssertFalse(entries[4].isActivity)
        XCTAssertEqual(entries[1].id, "a")
    }
    func testFailuresRemainVisibleEvenWithInconsistentOuterState() throws {
        for value in [row("command", type:"commandExecution", payload:["exitCode":.number(1)]),
                      row("tool", type:"dynamicToolCall", payload:["success":.bool(false)]),
                      row("error", type:"error")] {
            XCTAssertTrue(try XCTUnwrap(value.activity).failed)
        }
    }
    func testCommandAndFileDetailsUseStructuredPayload() throws {
        let command = try XCTUnwrap(row("c", type:"commandExecution", payload:["command":.string("swift test"), "output":.string("passed"), "exitCode":.number(0)]).activity)
        XCTAssertEqual(command.details.map(\.text), ["swift test", "passed", "0"])
        let file = try XCTUnwrap(row("f", type:"fileChange", payload:["paths":.array([.string("a.swift"), .string("b.swift")])]).activity)
        XCTAssertEqual(file.details.first?.text, "a.swift\nb.swift")
    }
    func testRunningInterruptedUnknownAndPrivateReasoning() throws {
        XCTAssertTrue(try XCTUnwrap(row("t", type:"mcpToolCall", state:"streaming").activity).isRunning)
        XCTAssertEqual(row("c", type:"commandExecution", state:"interrupted").activity?.status, "Stopped")
        XCTAssertEqual(row("x", type:"futureType", state:"unknown").activity?.status, "Status unavailable")
        XCTAssertTrue(try XCTUnwrap(row("r", type:"reasoning").activity).details.isEmpty)
    }
    func testNativeWebActionsRetainQueriesAndPageTargets() throws {
        let action: ThreadValue = .object(["type":.string("findInPage"), "url":.string("https://example.com"), "pattern":.string("Swift")])
        let activity = try XCTUnwrap(row("web", type:"webSearch", payload:["action":action]).activity)
        XCTAssertEqual(activity.title, "Find in page")
        XCTAssertEqual(activity.details.map(\.text), ["https://example.com", "Swift"])
    }
    func testToolResultsAreInertStructuredText() throws {
        let activity = try XCTUnwrap(row("t", type:"mcpToolCall", payload:["tool":.string("fetch_document"), "result":.object(["text":.string("<script>ignored</script>")])]).activity)
        XCTAssertEqual(activity.title, "Fetch Document")
        XCTAssertTrue(activity.details.first?.text.contains("<script>ignored</script>") == true)
    }
    func testObservedMixedToolOutputShapesNeverPrintEncodedMedia() throws {
        for types in [["input_text", "input_image", "input_audio"], ["inputText", "inputImage", "inputAudio"], ["text", "image", "audio"]] {
            let blocks: ThreadValue = .array([
                .object(["type": .string(types[0]), "text": .string("Found a chart.")]),
                .object(["type": .string(types[1]), "imageUrl": .string("data:image/png;base64,PRIVATE_IMAGE"), "data": .string("PRIVATE_IMAGE")]),
                .object(["type": .string(types[2]), "audioUrl": .string("data:audio/wav;base64,PRIVATE_AUDIO")])])
            for (kind, key, result) in [("dynamicToolCall", "contentItems", blocks), ("functionCallOutput", "output", blocks), ("mcpToolCall", "result", .object(["content": blocks]))] {
                let activity = try XCTUnwrap(row("output", type: kind, payload: [key: result]).activity)
                let text = activity.details.map(\.text).joined()
                XCTAssertTrue(text.contains("Found a chart."))
                XCTAssertTrue(text.contains("Image result"))
                XCTAssertTrue(text.contains("Audio result"))
                XCTAssertFalse(text.contains("PRIVATE"))
                XCTAssertFalse(text.contains("base64"))
            }
        }
    }

    func testMcpErrorAndStructuredOnlyResults() throws {
        let result: ThreadValue = .object(["content": .array([.object(["type": .string("text"), "text": .string("Service unavailable")])]), "isError": .bool(true)])
        let activity = try XCTUnwrap(row("mcp", type: "mcpToolCall", payload: ["result": result]).activity)
        XCTAssertTrue(activity.failed)
        XCTAssertEqual(activity.details.first?.text, "Service unavailable")
        let structured: ThreadValue = .object(["content": .array([]), "structuredContent": .object(["count": .number(2)])])
        XCTAssertTrue(structured.toolOutputText.contains("count"))
        XCTAssertEqual(ThreadValue.string("plain output").toolOutputText, "plain output")
    }

    func testCommentaryCollapsesWithWork() {
        let commentary = row("comment", type: "agentMessage", payload: ["phase": .string("commentary")])
        XCTAssertTrue(commentary.isCommentary)
        XCTAssertNil(commentary.activity)
        let entries = ChatFeedEntry.grouping([row("a", type: "commandExecution"), commentary, row("b", type: "webSearch")])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].rows.count, 3)
        XCTAssertTrue(entries[0].isActivity)
    }

    func testThinkingOnlyExistsWhileItsTurnAndItemAreActive() {
        let thinking = row("thinking", type: "reasoning", state: "streaming")
        XCTAssertTrue(ChatFeedEntry.grouping([thinking]).isEmpty)
        XCTAssertEqual(ChatFeedEntry.grouping([thinking], activeTurnIDs: ["turn"]).count, 1)
        XCTAssertTrue(ChatFeedEntry.grouping([row("done", type: "reasoning")], activeTurnIDs: ["turn"]).isEmpty)
        let reply = row("reply", type: "agentMessage")
        XCTAssertEqual(ChatFeedEntry.grouping([thinking, reply]).map(\.id), ["reply"])
    }
}
