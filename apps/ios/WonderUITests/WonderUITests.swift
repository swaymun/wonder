import XCTest
import UIKit

@MainActor final class WonderUITests: XCTestCase {
    func testNativeMarketingConversationCapture() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-marketing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let chat = app.buttons["chat-row:fixture-parent-conversation"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10)); chat.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "A little structure, plenty of room.")).firstMatch.waitForExistence(timeout: 10))
        let pill = app.buttons["subagent-status-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        retainMenuScreenshot(app, name: "Native sample conversation")
        pill.tap()
        XCTAssertTrue(app.buttons["subagent-roster:fixture-child-conversation"].waitForExistence(timeout: 5))
        retainMenuScreenshot(app, name: "Native sample helper roster")
        app.terminate()
        app.launchArguments.append("-diagnostics-marketing-approval")
        app.launch()
        XCTAssertTrue(chat.waitForExistence(timeout: 10)); chat.tap()
        XCTAssertTrue(app.staticTexts["Save your Saturday plan."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Allow once"].isEnabled)
        retainMenuScreenshot(app, name: "Native sample approval request")
        app.terminate()
    }

    func testChatInitialLayoutWithoutSavedPosition() throws {
        for _ in 0..<5 { try checkInitialChatLayout(extra: ["-diagnostics-chat-layout-unsaved"]) }
    }

    func testChatInitialLayoutKeepsMarginsBeforeFirstDrag() throws {
        for _ in 0..<10 { try checkInitialChatLayout(extra: []) }
    }

    func testChatInitialLayoutAtAccessibilitySize() throws {
        for extra in [[String](), ["-diagnostics-chat-layout-unsaved"]] {
            try checkInitialChatLayout(extra: extra, contentSize: "UICTContentSizeCategoryAccessibilityXXL")
        }
    }

    private func checkInitialChatLayout(extra: [String], contentSize: String = "UICTContentSizeCategoryL") throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-chat-layout", "-UIPreferredContentSizeCategoryName", contentSize] + extra
        app.launch()
        let row = app.buttons["chat-row:diagnostic-host:fixture-parent-conversation"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let draft = app.textViews["message-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reply 12.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        let work = app.buttons["activity-group:layout-turn-12/layout-work-12"]
        let header = app.navigationBars.containing(.other, identifier: "conversation-avatar-header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let before = reply.frame
        let workBefore = work.exists ? work.frame : nil
        retainMenuScreenshot(app, name: "Initial chat before any drag")
        let scroll = app.scrollViews["conversation-scroll"]
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)), withVelocity: .slow, thenHoldForDuration: 0)
        let after = reply.frame
        let workAfter = work.exists ? work.frame : nil
        retainMenuScreenshot(app, name: "Chat after first short drag")
        let evidence = XCTAttachment(string: "Before: \(before)\nAfter: \(after)\nWork before: \(String(describing: workBefore))\nWork after: \(String(describing: workAfter))\nHeader: \(header.frame)\nComposer: \(draft.frame)\nHelper: \(app.buttons["subagent-status-pill"].frame)\nViewport bottom: \(conversationLayoutBottom(app, draft: draft))\nScroll: \(scroll.frame)")
        evidence.lifetime = .keepAlways; add(evidence)
        XCTAssertEqual(before.minX, after.minX, accuracy: 1, "A vertical drag must not repair a horizontal offset")
        // Combined text accessibility bounds can extend outside the visible
        // bubble. The identified activity control shares its padded column.
        if let workBefore {
            let workAfter = try XCTUnwrap(workAfter, "A short drag must preserve the visible activity row")
            XCTAssertEqual(workBefore.minX, workAfter.minX, accuracy: 1)
            XCTAssertGreaterThanOrEqual(workBefore.minX, max(scroll.frame.minX, header.frame.minX) + 16)
        }
        XCTAssertLessThanOrEqual(after.maxY, before.maxY + 1, "Dragging up must not snap overscrolled content down")
        let viewportTop = max(scroll.frame.minY, header.frame.maxY)
        let viewportBottom = conversationLayoutBottom(app, draft: draft)
        let viewportHeight = viewportBottom - viewportTop
        XCTAssertGreaterThan(viewportHeight, 0)
        XCTAssertGreaterThan(min(before.maxY, viewportBottom) - max(before.minY, viewportTop), 0, "The restored reply must be visible between the detail header and composer")
        if before.height <= viewportHeight {
            XCTAssertLessThanOrEqual(before.maxY, viewportBottom + 1)
            XCTAssertLessThan(viewportBottom - before.maxY, 100, "The latest reply must not leave an initial blank area above the composer")
        } else {
            if !extra.contains("-diagnostics-chat-layout-unsaved") {
                XCTAssertGreaterThanOrEqual(before.minY, viewportTop - 1, "A saved top anchor must keep the start of a tall reply readable")
            }
            if reply.frame.maxY > conversationLayoutBottom(app, draft: draft) + 1 {
                let bottom = app.buttons["scroll-to-bottom"]
                XCTAssertTrue(bottom.waitForExistence(timeout: 5))
                bottom.tap()
                retainConversationLayoutEvidence(app, name: "Tall reply after bottom action", reply: reply, header: header, draft: draft)
                expectation(for: NSPredicate { _, _ in reply.frame.maxY <= self.conversationLayoutBottom(app, draft: draft) + 1 }, evaluatedWith: nil)
                waitForExpectations(timeout: 5)
            }
            retainConversationLayoutEvidence(app, name: "Tall reply end above the helper dock", reply: reply, header: header, draft: draft)
            XCTAssertGreaterThan(reply.frame.maxY, viewportTop)
            XCTAssertLessThanOrEqual(reply.frame.maxY, conversationLayoutBottom(app, draft: draft) + 1)
            XCTAssertLessThan(conversationLayoutBottom(app, draft: draft) - reply.frame.maxY, 100)
        }
        if workBefore == nil {
            // Opening at the end of a tall reply need not realize the preceding
            // lazy activity row. Check initial readability before revealing it.
            XCTAssertTrue(extra.contains("-diagnostics-chat-layout-unsaved"))
            XCTAssertGreaterThan(before.height, viewportHeight)
            for _ in 0..<8 {
                if work.exists, work.frame.minY >= viewportTop,
                   work.frame.maxY <= conversationLayoutBottom(app, draft: draft) { break }
                let reveal = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.24))
                reveal.press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.64)), withVelocity: .slow, thenHoldForDuration: 0)
            }
            retainConversationLayoutEvidence(app, name: "Activity row revealed above tall unsaved reply", reply: reply, header: header, draft: draft)
            let workEvidence = XCTAttachment(string: "Work: \(work.exists ? String(describing: work.frame) : "not realized")\nViewport top: \(viewportTop)\nViewport bottom: \(conversationLayoutBottom(app, draft: draft))")
            workEvidence.lifetime = .keepAlways; add(workEvidence)
            XCTAssertTrue(work.exists, "Bounded scrolling must reveal the preceding activity row")
            XCTAssertGreaterThanOrEqual(work.frame.minY, viewportTop)
            XCTAssertLessThanOrEqual(work.frame.maxY, conversationLayoutBottom(app, draft: draft))
            XCTAssertGreaterThanOrEqual(work.frame.minX, max(scroll.frame.minX, header.frame.minX) + 16)
        }
        app.terminate()
    }

    func testChatRestoresOlderReadingPositionAndReturnsToBottom() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-chat-layout", "-diagnostics-chat-layout-older", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let row = app.buttons["chat-row:diagnostic-host:fixture-parent-conversation"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let draft = app.textViews["message-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reply 6.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        let scroll = app.scrollViews["conversation-scroll"]
        let header = app.navigationBars.containing(.other, identifier: "conversation-avatar-header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let olderWork = app.buttons["activity-group:layout-turn-6/layout-work-6"]
        XCTAssertTrue(olderWork.waitForExistence(timeout: 5))
        retainConversationLayoutEvidence(app, name: "Older saved reply restored without a drag", reply: reply, header: header, draft: draft)
        XCTAssertGreaterThanOrEqual(olderWork.frame.minX, max(scroll.frame.minX, header.frame.minX) + 16)
        XCTAssertGreaterThan(reply.frame.maxY, header.frame.maxY)
        XCTAssertLessThan(reply.frame.minY, conversationLayoutBottom(app, draft: draft))
        if !row.isHittable {
            header.buttons.firstMatch.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            XCTAssertTrue(reply.waitForExistence(timeout: 5))
            retainConversationLayoutEvidence(app, name: "Older reply restored after returning to chat", reply: reply, header: header, draft: draft)
            XCTAssertGreaterThan(reply.frame.maxY, header.frame.maxY)
            XCTAssertLessThan(reply.frame.minY, conversationLayoutBottom(app, draft: draft))
        }
        let bottom = app.buttons["scroll-to-bottom"]
        XCTAssertTrue(bottom.waitForExistence(timeout: 5))
        bottom.tap()
        let latest = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reply 12.")).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        retainConversationLayoutEvidence(app, name: "Bottom action after restoring an older reply", reply: latest, header: header, draft: draft)
        XCTAssertLessThanOrEqual(latest.frame.maxY, conversationLayoutBottom(app, draft: draft))
        XCTAssertLessThan(conversationLayoutBottom(app, draft: draft) - latest.frame.maxY, 100)
        let work = app.buttons["activity-group:layout-turn-12/layout-work-12"]
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(work.frame.minX, max(scroll.frame.minX, header.frame.minX) + 16)
        XCTAssertEqual(work.value as? String, "Collapsed")
        work.tap()
        XCTAssertEqual(work.value as? String, "Expanded")
        work.tap()
        XCTAssertEqual(work.value as? String, "Collapsed")
        retainConversationLayoutEvidence(app, name: "Activity expands and collapses above the helper dock", reply: latest, header: header, draft: draft)
        XCTAssertGreaterThanOrEqual(work.frame.minX, max(scroll.frame.minX, header.frame.minX) + 16)
        XCTAssertLessThanOrEqual(latest.frame.maxY, conversationLayoutBottom(app, draft: draft))
        XCTAssertLessThan(conversationLayoutBottom(app, draft: draft) - latest.frame.maxY, 100)
        app.terminate()
    }

    private func conversationLayoutBottom(_ app: XCUIApplication, draft: XCUIElement) -> CGFloat {
        let pill = app.buttons["subagent-status-pill"]
        return pill.exists && pill.isHittable ? min(pill.frame.minY, draft.frame.minY) : draft.frame.minY
    }

    private func retainConversationLayoutEvidence(_ app: XCUIApplication, name: String, reply: XCUIElement, header: XCUIElement, draft: XCUIElement) {
        retainMenuScreenshot(app, name: name)
        let pill = app.buttons["subagent-status-pill"]
        let evidence = XCTAttachment(string: "Reply: \(reply.frame)\nHeader: \(header.frame)\nComposer: \(draft.frame)\nHelper: \(pill.exists ? String(describing: pill.frame) : "absent")\nViewport bottom: \(conversationLayoutBottom(app, draft: draft))\nScroll: \(app.scrollViews["conversation-scroll"].frame)")
        evidence.name = name + " geometry"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testChatStatusesAndVisibleReadRetryClearUnreadWithoutScrolling() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-read-status"]
        app.launch()
        let unread = app.buttons["chat-row:fixture-parent-conversation"]
        let working = app.buttons["chat-row:fixture-working"]
        let read = app.buttons["chat-row:fixture-read"]
        XCTAssertTrue(unread.waitForExistence(timeout: 10))
        XCTAssertEqual(unread.value as? String, "Unread")
        XCTAssertEqual(working.value as? String, "Working")
        XCTAssertEqual(read.value as? String, "Read")
        retainMenuScreenshot(app, name: "Chat status: unread dot, working spinner, read blank")
        unread.tap()
        XCTAssertTrue(app.textViews["message-draft"].waitForExistence(timeout: 10))
        // The first PATCH receives 503. Stay still while the same visible
        // snapshot retries, then return to the list and check the host reply.
        let settled = NSPredicate { _, _ in (unread.value as? String) == "Read" }
        // On iPhone the sidebar is offscreen, so use the return to Chats after
        // the bounded retry window rather than reading a hidden row.
        if !unread.isHittable {
            let expectation = XCTestExpectation(description: "Allow the read retry")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { expectation.fulfill() }
            wait(for: [expectation], timeout: 4)
            app.navigationBars.buttons.firstMatch.tap()
        }
        expectation(for: settled, evaluatedWith: nil)
        waitForExpectations(timeout: 8)
        XCTAssertEqual(unread.value as? String, "Read")
        XCTAssertEqual(working.value as? String, "Working")
        retainMenuScreenshot(app, name: "Unread cleared after visible read acknowledgement")
    }

    func testWorkingImagesFollowActivityExpansion() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        for extra in [[], ["-activity-running-preview"], ["-activity-final-image-preview"]] {
            app.launchArguments = ["-read-preview", "-send-preview", "-activity-preview", "-activity-mixed-preview"] + extra
            app.launch()
            let group = app.buttons["activity-group:turn/z-commentary"]
            let workingImage = app.buttons["tool-image:tool-preview"]
            let finalImage = app.buttons["tool-image:final-preview"]
            let isRunning = extra.contains("-activity-running-preview")
            XCTAssertTrue(group.waitForExistence(timeout: 10))
            XCTAssertEqual(group.value as? String, isRunning ? "Expanded" : "Collapsed")
            XCTAssertEqual(workingImage.waitForExistence(timeout: isRunning ? 5 : 0.5), isRunning)
            if extra.contains("-activity-final-image-preview") {
                XCTAssertTrue(finalImage.waitForExistence(timeout: 5))
            }
            retainMenuScreenshot(app, name: (isRunning ? "Expanded work " : "Collapsed work ") + (extra.first ?? "completed"))

            if isRunning {
                group.tap()
                XCTAssertEqual(group.value as? String, "Collapsed")
                XCTAssertFalse(workingImage.exists)
                group.tap()
            } else {
                group.tap()
            }
            XCTAssertEqual(group.value as? String, "Expanded")
            let scroll = app.scrollViews.firstMatch
            for _ in 0..<4 {
                if workingImage.exists && workingImage.isHittable { break }
                scroll.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(workingImage.waitForExistence(timeout: 5))
            XCTAssertTrue(workingImage.isHittable)
            XCTAssertEqual(workingImage.value as? String, "Loaded")
            retainMenuScreenshot(app, name: "Image inside expanded work")
            if extra.isEmpty {
                workingImage.tap()
                let viewerImage = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo-viewer-image:")).firstMatch
                XCTAssertTrue(viewerImage.waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["photo-viewer-close"].waitForExistence(timeout: 5))
                viewerImage.doubleTap()
                let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "200%"), object: viewerImage)
                XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed)
                app.buttons["photo-viewer-close"].tap()
                XCTAssertTrue(workingImage.waitForExistence(timeout: 5))
            }
            for _ in 0..<4 {
                if group.isHittable && group.frame.minY > app.frame.minY + 120 { break }
                scroll.swipeDown(velocity: .slow)
            }
            group.tap()
            XCTAssertEqual(group.value as? String, "Collapsed")
            XCTAssertFalse(workingImage.exists)
            if extra.contains("-activity-final-image-preview") { XCTAssertTrue(finalImage.exists) }
            app.terminate()
        }
    }

    func testComputerApprovalShowsExactActionAndPhoneControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            app.launchArguments = ["-read-preview", "-send-preview", "-computer-approval-preview", "-UIPreferredContentSizeCategoryName", size]
            app.launch()
            let allow = app.buttons["approval-accept-fixture-computer"]
            XCTAssertTrue(allow.waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["approval-decline-fixture-computer"].exists)
            XCTAssertTrue(app.staticTexts["Capture your Mac’s screen."].exists)
            XCTAssertFalse(app.staticTexts["This request needs Wonder on your Mac. It cannot be approved here yet."].exists)
            // Synthetic preview intentionally cannot submit an owner decision.
            XCTAssertFalse(allow.isEnabled)
            retainMenuScreenshot(app, name: "Computer approval " + size)
            app.terminate()
        }
    }

    func testEveryApprovalFamilyHasPhoneControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        let cases = [
            ("command", "acceptForSession", "convert original.png output.png"),
            ("network", "accept", "example.com"),
            ("file", "accept", "/Users/example/Movies"),
            ("permissions", "allowTurn", "/Users/example/Movies"),
            ("form", "accept", "Choose export settings."),
            ("url", "accept", "Connect the export service."),
            ("unknown", "decline", "This action cannot be run safely.")
        ]
        for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            for (kind, choice, detail) in cases {
                app.launchArguments = ["-read-preview", "-send-preview", "-phone-approval-preview", kind, "-UIPreferredContentSizeCategoryName", size]
                app.launch()
                let action = app.buttons["approval-\(choice)-fixture-\(kind)"]
                XCTAssertTrue(action.waitForExistence(timeout: 10), "Missing phone action for " + kind)
                XCTAssertTrue(app.buttons["approval-decline-fixture-\(kind)"].exists)
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", detail)).firstMatch.exists)
                XCTAssertFalse(app.staticTexts["This request needs Wonder on your Mac. It cannot be approved here yet."].exists)
                XCTAssertFalse(action.isEnabled, "Offline previews cannot send approvals")
                if kind == "url" { XCTAssertTrue(app.links["approval-service-link"].exists || app.buttons["approval-service-link"].exists) }
                retainMenuScreenshot(app, name: "Phone approval " + kind + " " + size)
                app.terminate()
            }
        }
    }

    func testChatContextMenuPreview() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        // Synthetic, offline Bot and Group rows exercise the real menu. Network
        // mutations stay disabled, while Copy ID remains available.
        for arguments in [["-read-preview", "-send-preview", "-chats-preview"], ["-read-preview", "-chats-preview"], ["-connections-preview"]] {
            app.launchArguments = arguments
            app.launch()
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-row:")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.press(forDuration: 1)
            XCTAssertTrue(app.buttons["Advanced"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["Archive"].exists)
            XCTAssertFalse(app.buttons["Archive"].isEnabled)
            XCTAssertFalse(app.buttons["Copy ID"].exists)
            XCTAssertFalse(app.buttons["Delete"].exists)
            retainMenuScreenshot(app, name: arguments.contains("-send-preview") ? "Bot menu" : "Group menu")
            app.buttons["Advanced"].tap()
            XCTAssertTrue(app.buttons["Copy ID"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["Copy ID"].isEnabled)
            XCTAssertTrue(app.buttons["Delete"].exists)
            XCTAssertFalse(app.buttons["Delete"].isEnabled)
            retainMenuScreenshot(app, name: "Advanced menu")
            app.buttons["Copy ID"].tap()
            XCTAssertFalse(app.buttons["Advanced"].exists)
            XCTAssertTrue(row.isHittable)
            app.terminate()
        }
    }

    func testComposerApprovalChangesWithoutSavingIndicatorAndPersists() throws {
        try checkOptimisticApprovals(minimumDuration: 0, minimumChanges: 12)
    }

    func testBotPolishPhysicalSession() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("This three-minute interaction session requires a physical iPhone.")
        #else
        try checkOptimisticApprovals(minimumDuration: 180, minimumChanges: 30)
        #endif
    }

    private func checkOptimisticApprovals(minimumDuration: TimeInterval, minimumChanges: Int) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        let arguments = ["-diagnostics-subagent-fixture", "-diagnostics-optimistic-approval", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launchArguments = arguments + ["-diagnostics-approval-reset"]
        app.launch()
        let chat = app.buttons["chat-row:fixture-parent-conversation"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10)); chat.tap()
        let approval = app.buttons["composer-permissions"]
        XCTAssertTrue(approval.waitForExistence(timeout: 10))
        XCTAssertTrue(approval.isEnabled)
        let started = Date()
        let modes = [("full-access", "Full access"), ("approve-for-me", "Approve for me"), ("ask-for-approval", "Ask for approval")]
        var changes = 0, helperCycles = 0
        repeat {
            let mode = modes[changes % modes.count]
            approval.tap()
            let option = app.buttons["approval-choice-" + mode.0]
            XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
            XCTAssertTrue(NSPredicate(format: "value == %@", mode.1).evaluate(with: approval))
            XCTAssertFalse(app.staticTexts["Saving…"].exists)
            XCTAssertFalse(app.otherElements["composer-approval-error"].exists)
            XCTAssertTrue(approval.isEnabled)
            if changes % 3 == 0 {
            let pill = app.buttons["subagent-status-pill"]
            XCTAssertTrue(pill.exists); pill.tap()
            let child = app.buttons["subagent-roster:fixture-child-conversation"]
            XCTAssertTrue(child.waitForExistence(timeout: 5)); child.tap()
            let done = app.buttons["subagent-sheet-done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
            XCTAssertTrue(child.waitForExistence(timeout: 5)); pill.tap()
            XCTAssertEqual(pill.value as? String, "Collapsed")
            helperCycles += 1
            }
            changes += 1
        } while changes < minimumChanges || Date().timeIntervalSince(started) < minimumDuration
        retainMenuScreenshot(app, name: "Approval and helper interactions - \(changes) cycles")
        let finalTitle = modes[(changes - 1) % modes.count].1
        app.terminate()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(chat.waitForExistence(timeout: 10)); chat.tap()
        XCTAssertTrue(approval.waitForExistence(timeout: 10))
        XCTAssertEqual(approval.value as? String, finalTitle)
        let evidence = XCTAttachment(string: "Completed \(changes) permission changes and \(helperCycles) helper open/close cycles in \(Date().timeIntervalSince(started)) seconds. Synthetic host; no messages or model work.")
        evidence.name = "Bot polish interaction session"; evidence.lifetime = .keepAlways; add(evidence)
    }

    func testDiagnosticsSubagentPillSheetPreservesParentDraftAndActivityState() throws {
        try checkSubagentSheet(contentSize: "UICTContentSizeCategoryL")
    }

    func testDiagnosticsSubagentSheetAtAccessibilitySize() throws {
        try checkSubagentSheet(contentSize: "UICTContentSizeCategoryAccessibilityXXL")
    }

    private func checkSubagentSheet(contentSize: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-subagent-fixture", "-UIPreferredContentSizeCategoryName", contentSize]
        app.launch()
        let parent = app.buttons["chat-row:fixture-parent-conversation"]
        XCTAssertTrue(parent.waitForExistence(timeout: 10)); parent.tap()
        let parentDraft = app.textViews["message-draft"]
        XCTAssertTrue(parentDraft.waitForExistence(timeout: 10))
        parentDraft.tap(); parentDraft.typeText("parent draft")
        if app.keyboards.firstMatch.exists {
            let scroll = app.scrollViews["conversation-scroll"]
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.19))
            start.press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86)),
                        withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        let groups = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity-group:"))
        for _ in 0..<5 where !groups.firstMatch.exists {
            let scroll = app.scrollViews["conversation-scroll"]
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.19))
            start.press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32)))
        }
        XCTAssertTrue(groups.firstMatch.waitForExistence(timeout: 5)); groups.firstMatch.tap()
        let pill = app.buttons["subagent-status-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(pill.frame.height, 44)
        XCTAssertGreaterThan(pill.frame.midX, parentDraft.frame.midX)
        XCTAssertLessThanOrEqual(pill.frame.maxX, parentDraft.frame.maxX + 24)
        XCTAssertGreaterThanOrEqual(parentDraft.frame.minY - pill.frame.maxY, 0)
        XCTAssertLessThan(parentDraft.frame.minY - pill.frame.maxY, 22)
        pill.tap()
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Completed"].exists)
        retainMenuScreenshot(app, name: "Agent roster above composer")
        let child = app.buttons["subagent-roster:fixture-child-conversation"]
        XCTAssertTrue(child.exists); child.tap()
        let done = app.buttons["subagent-sheet-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Scout: I am the verified Scout child."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["message-draft"].isHittable)
        XCTAssertFalse(app.buttons["send-message"].isHittable)
        retainMenuScreenshot(app, name: "Read only agent sheet")
        done.tap()
        XCTAssertTrue(child.waitForExistence(timeout: 5))
        XCTAssertEqual(pill.value as? String, "Expanded")
        retainMenuScreenshot(app, name: "Agent roster restored after sheet")
        pill.tap()
        XCTAssertEqual(pill.value as? String, "Collapsed")
        XCTAssertTrue(parentDraft.waitForExistence(timeout: 5))
        XCTAssertEqual(parentDraft.value as? String, "parent draft")
        XCTAssertEqual(groups.firstMatch.value as? String, "Expanded")
        let activity = app.buttons["subagent-row:fixture-child-conversation"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5)); activity.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        XCTAssertEqual(pill.value as? String, "Collapsed")
        XCTAssertEqual(parentDraft.value as? String, "parent draft")
        retainMenuScreenshot(app, name: "Parent restored after agent sheet")
    }

    func testDiagnosticsComputerSessionUnavailableFixture() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-computer-session-fixture"]
        app.launch()

        let computerContainer = app.descendants(matching: .any)
            .matching(identifier: "computer-session-container").firstMatch
        XCTAssertTrue(computerContainer.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Unavailable"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Live computer viewing is unavailable on this Mac."].exists)
        XCTAssertTrue(app.staticTexts["Live computer viewing is unavailable on this Mac. Update Wonder on the Mac, then try again."].exists)
        let preview = app.descendants(matching: .any)
            .matching(identifier: "computer-session-preview").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertEqual(preview.label, "Computer screen preview")
        XCTAssertNotNil(preview.value as? String)
        XCTAssertTrue(app.buttons["computer-session-close"].exists)
        app.buttons["computer-session-more"].tap()
        XCTAssertTrue(app.buttons["computer-session-fit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["computer-session-zoom-out"].exists)
        XCTAssertTrue(app.buttons["computer-session-zoom-in"].exists)
        app.buttons["computer-session-fit"].tap()
        XCTAssertTrue(app.buttons["computer-session-refresh"].exists)
        XCTAssertFalse(app.buttons["computer-session-take-control"].exists)
        XCTAssertTrue(app.staticTexts["View only"].exists)
        let zoomValue = app.buttons["computer-session-more"]
        XCTAssertTrue(zoomValue.exists)
        XCTAssertEqual(zoomValue.value as? String, "100 percent")
        XCTAssertFalse(app.staticTexts["Waiting for a verified computer stream."].exists)
        retainMenuScreenshot(app, name: "Computer session unavailable")

        selectComputerMoreAction(app, identifier: "computer-session-zoom-in")
        XCTAssertEqual(zoomValue.value as? String, "125 percent")
        selectComputerMoreAction(app, identifier: "computer-session-fit")
        XCTAssertEqual(zoomValue.value as? String, "100 percent")
        app.buttons["computer-session-close"].tap()
        XCTAssertFalse(computerContainer.waitForExistence(timeout: 2))
    }

    func testDiagnosticsComputerSessionAvailableFixtureTakesControlAndReleasesIt() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-computer-session-fixture", "-diagnostics-computer-session-available-fixture"]
        app.launch()

        let computerContainer = app.descendants(matching: .any)
            .matching(identifier: "computer-session-container").firstMatch
        XCTAssertTrue(computerContainer.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Live"].waitForExistence(timeout: 5))
        let takeControl = app.buttons["computer-session-take-control"]
        XCTAssertTrue(takeControl.waitForExistence(timeout: 5))
        takeControl.tap()

        let waiting = app.descendants(matching: .any)
            .matching(identifier: "computer-session-waiting").firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 2))
        let active = app.descendants(matching: .any)
            .matching(identifier: "computer-session-control-active").firstMatch
        XCTAssertTrue(active.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["computer-session-keyboard"].exists)
        XCTAssertTrue(app.buttons["computer-session-done"].exists)

        assertComputerControlRow(app)
        let preview = app.descendants(matching: .any).matching(identifier: "computer-session-preview").firstMatch
        XCTAssertEqual(preview.frame.width, app.frame.width, accuracy: 1, "Portrait preview must use the phone width.")
        app.buttons["computer-session-keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertComputerControlRow(app)
        app.typeText("Native keyboard fixture\n")
        app.buttons["computer-session-clipboard"].tap()
        let copy = app.buttons["computer-session-copy-from-mac"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(app.staticTexts["Copied from Mac"].waitForExistence(timeout: 5))
        retainMenuScreenshot(app, name: "Computer session control active")

        app.buttons["computer-session-done"].tap()
        XCTAssertTrue(takeControl.waitForExistence(timeout: 5))
        XCTAssertFalse(active.exists)
        app.buttons["computer-session-close"].tap()
        XCTAssertFalse(computerContainer.waitForExistence(timeout: 2))
    }

    func testDiagnosticsComputerControlsStayOnOneRowAtAccessibilitySize() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-computer-session-fixture", "-diagnostics-computer-session-available-fixture",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let takeControl = app.buttons["computer-session-take-control"]
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        takeControl.tap()
        XCTAssertTrue(app.buttons["computer-session-keyboard"].waitForExistence(timeout: 5))
        assertComputerControlRow(app)
        app.buttons["computer-session-keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertComputerControlRow(app)
        retainMenuScreenshot(app, name: "Single control row at largest accessibility text size")
        app.buttons["computer-session-done"].tap()
        XCTAssertTrue(takeControl.waitForExistence(timeout: 5))
        app.buttons["computer-session-close"].tap()
    }

    func testDiagnosticsComputerPointerModeMenuDoesNotOpenKeyboard() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-computer-session-fixture", "-diagnostics-computer-session-available-fixture",
                               "-diagnostics-computer-live-updates"]
        app.launch()
        let takeControl = app.buttons["computer-session-take-control"]
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        takeControl.tap()
        let keyboard = app.buttons["computer-session-keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let preview = app.descendants(matching: .any).matching(identifier: "computer-session-preview").firstMatch
        retainComputerGeometry(app, name: "Fixture before Direct touch menu")
        app.buttons["computer-session-more"].tap()
        let direct = app.buttons["Direct touch"]
        XCTAssertTrue(direct.waitForExistence(timeout: 5))
        retainComputerGeometry(app, name: "Fixture Direct touch menu open")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertTrue(direct.exists, "Heartbeat lease publications must preserve the open menu.")
        XCTAssertEqual(keyboard.label, "Show keyboard")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        direct.tap()
        XCTAssertTrue(waitUntilGone(direct, timeout: 5))
        retainComputerGeometry(app, name: "Fixture immediately after Direct touch selection")
        XCTAssertEqual(keyboard.label, "Show keyboard")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        retainComputerGeometry(app, name: "Fixture after preview center tap")
        XCTAssertEqual(keyboard.label, "Show keyboard")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["computer-session-more"].tap()
        retainComputerGeometry(app, name: "Fixture reopened More after preview tap")
        let trackpad = app.buttons["Trackpad"]
        XCTAssertTrue(trackpad.waitForExistence(timeout: 5))
        trackpad.tap()
        XCTAssertTrue(waitUntilGone(trackpad, timeout: 5))
        XCTAssertEqual(keyboard.label, "Show keyboard")
        app.buttons["computer-session-done"].tap()
        app.buttons["computer-session-close"].tap()
    }

    private func selectComputerMoreAction(_ app: XCUIApplication, identifier: String) {
        app.buttons["computer-session-more"].tap()
        // iOS 27's native section-backed menu items expose their spoken label
        // but may omit the SwiftUI accessibility identifier.
        let labels = ["computer-session-fit": "Fit", "computer-session-zoom-in": "Zoom in",
                      "computer-session-zoom-out": "Zoom out", "computer-session-recenter": "Recenter pointer"]
        let action = app.buttons[labels[identifier] ?? identifier]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
        XCTAssertTrue(waitUntilGone(action, timeout: 5))
    }

    private func assertComputerControlRow(_ app: XCUIApplication) {
        let identifiers = ["computer-session-key-escape", "computer-session-key-tab",
                           "computer-session-clipboard", "computer-session-keyboard", "computer-session-done"]
        let frames = identifiers.map { identifier -> CGRect in
            let button = app.buttons[identifier]
            XCTAssertTrue(button.isHittable, "Essential control must be directly reachable: \(identifier)")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            return button.frame
        }
        for frame in frames {
            XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 1, "Essential controls must share one row.")
        }
        if app.keyboards.firstMatch.exists {
            XCTAssertLessThanOrEqual(frames[0].maxY, app.keyboards.firstMatch.frame.minY + 2)
        }
    }

    private func retainComputerGeometry(_ app: XCUIApplication, name: String) {
        let tree = app.debugDescription
        let focused = tree.split(separator: "\n").filter {
            $0.contains("computer-session") || $0.contains("Direct touch")
                || $0.contains("Trackpad") || $0.contains("Keyboard,")
        }.joined(separator: "\n")
        print("COMPUTER_GEOMETRY \(name) @ \(Date().timeIntervalSince1970)\n\(focused)")
        XCTContext.runActivity(named: name) { activity in
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = name + ".png"
            image.lifetime = .keepAlways
            activity.add(image)
            let hierarchy = XCTAttachment(string: tree)
            hierarchy.name = name + " accessibility.txt"
            hierarchy.lifetime = .keepAlways
            activity.add(hierarchy)
        }
    }

    private func assertComputerMoreMenuExcludesTeaching(_ app: XCUIApplication) {
        app.buttons["computer-session-more"].tap()
        let fit = app.buttons["Fit"]
        XCTAssertTrue(fit.waitForExistence(timeout: 5), "Inspect the open Computer menu before checking its actions.")
        XCTAssertFalse(app.buttons["Teach a task"].exists, "Teaching is not available in the beta Computer view.")
        fit.tap()
        XCTAssertTrue(waitUntilGone(fit, timeout: 5), "Computer menu did not dismiss after Fit.")
    }

    func testDiagnosticsComputerMenuExcludesTeachingAndKeepsKeyboardAvailable() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-computer-session-fixture", "-diagnostics-computer-session-available-fixture"]
        app.launch()
        let takeControl = app.buttons["computer-session-take-control"]
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        assertComputerMoreMenuExcludesTeaching(app)
        takeControl.tap()
        let active = app.descendants(matching: .any).matching(identifier: "computer-session-control-active").firstMatch
        XCTAssertTrue(active.waitForExistence(timeout: 5))
        assertComputerMoreMenuExcludesTeaching(app)
        let keyboard = app.buttons["computer-session-keyboard"]
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertComputerControlRow(app)
        app.typeText("Computer control keyboard fixture\n")
        XCTAssertTrue(active.exists)
        let preview = app.descendants(matching: .any).matching(identifier: "computer-session-preview").firstMatch
        XCTAssertEqual(preview.value as? String, "Live")
        retainMenuScreenshot(app, name: "Computer controls and keyboard without teaching")
        app.buttons["computer-session-done"].tap()
        XCTAssertTrue(takeControl.waitForExistence(timeout: 5))
        XCTAssertFalse(active.exists)
        XCTAssertTrue(waitUntilGone(app.keyboards.firstMatch, timeout: 5))
        app.buttons["computer-session-close"].tap()
        XCTAssertTrue(app.staticTexts["Computer viewer closed"].waitForExistence(timeout: 5))
    }

    func testDiagnosticsComputerCloseWhileControllingDismissesKeyboard() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-computer-session-fixture", "-diagnostics-computer-session-available-fixture"]
        app.launch()
        let takeControl = app.buttons["computer-session-take-control"]
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        takeControl.tap()
        let keyboard = app.buttons["computer-session-keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertComputerControlRow(app)
        app.typeText("Close active control fixture\n")
        app.buttons["computer-session-close"].tap()
        XCTAssertTrue(app.staticTexts["Computer viewer closed"].waitForExistence(timeout: 5))
        let computerView = app.descendants(matching: .any).matching(identifier: "computer-session-container").firstMatch
        XCTAssertFalse(computerView.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "computer-session-control-active").firstMatch.exists)
        XCTAssertTrue(waitUntilGone(app.keyboards.firstMatch, timeout: 5))
        retainMenuScreenshot(app, name: "Close dismisses active computer controls and keyboard")
    }

    func testDiagnosticsComputerBackgroundEndsControlAndDismissesViewer() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-computer-session-fixture", "-diagnostics-computer-session-available-fixture"]
        app.launch()
        let takeControl = app.buttons["computer-session-take-control"]
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        takeControl.tap()
        let keyboard = app.buttons["computer-session-keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertComputerControlRow(app)
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.activate()

        XCTAssertTrue(app.staticTexts["Computer viewer closed"].waitForExistence(timeout: 10))
        let computerView = app.descendants(matching: .any).matching(identifier: "computer-session-container").firstMatch
        XCTAssertFalse(computerView.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "computer-session-control-active").firstMatch.exists)
        XCTAssertFalse(keyboard.exists)
        XCTAssertFalse(takeControl.exists)
        XCTAssertTrue(waitUntilGone(app.keyboards.firstMatch, timeout: 5))
        retainMenuScreenshot(app, name: "Background ends computer controls and dismisses viewer")
    }

    func testPhysicalComputerViewStartsAuthenticatedMacStreamAndCloses() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        let localNetworkMonitor = installWonderLocalNetworkPermissionMonitor()
        defer { removeUIInterruptionMonitor(localNetworkMonitor) }
        app.launch()

        // A Local Network alert is owned by SpringBoard and can appear just
        // after launch. Perform one harmless, deterministic XCTest action when
        // it is present so the interruption monitor gets a chance to handle it
        // before any conversation controls are tapped.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemAlert = springboard.alerts.firstMatch
        if systemAlert.waitForExistence(timeout: 5) {
            let isLocalNetworkAlert = systemAlert.label.localizedCaseInsensitiveContains("local network")
                || systemAlert.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS[c] %@", "local network")
                ).firstMatch.exists
            XCTAssertTrue(isLocalNetworkAlert,
                          "Only the expected Local Network permission alert may be handled here.")
            app.tap()
            XCTAssertFalse(systemAlert.waitForExistence(timeout: 2),
                           "The expected Local Network permission alert was not dismissed.")
        }

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-row:")).firstMatch
        guard row.waitForExistence(timeout: 20) else {
            throw XCTSkip("Requires an unlocked physical device paired with the updated Wonder host.")
        }
        row.tap()
        let details = app.buttons["Conversation details"]
        XCTAssertTrue(details.waitForExistence(timeout: 15))
        details.tap()
        let viewComputer = app.buttons["View computer"]
        XCTAssertTrue(viewComputer.waitForExistence(timeout: 15))
        viewComputer.tap()
        let openedAt = Date()

        let computerView = app.descendants(matching: .any)
            .matching(identifier: "computer-session-container").firstMatch
        XCTAssertTrue(computerView.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Live computer viewing is unavailable on this Mac."].exists)

        // The helper lifecycle is asynchronous. Refresh the authenticated
        // session until the daemon projects either its short-lived source
        // selection state or an already-live stream. With a usable main
        // display this must not require a Mac-side sharing picker.
        let awaitingSource = app.staticTexts["Choose a source on your Mac"]
        let preview = app.descendants(matching: .any)
            .matching(identifier: "computer-session-preview").firstMatch
        let refresh = app.buttons["computer-session-refresh"]
        let deadline = Date().addingTimeInterval(20)
        var reachedLive = preview.value as? String == "Live"
        var reachedAwaitingSource = !reachedLive && awaitingSource.exists
        while !reachedLive && !reachedAwaitingSource && Date() < deadline {
            XCTAssertTrue(refresh.waitForExistence(timeout: 3))
            reachedLive = preview.value as? String == "Live"
            reachedAwaitingSource = !reachedLive && awaitingSource.exists
            if reachedLive || reachedAwaitingSource { break }
            refresh.tap()
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.75)))
            reachedLive = preview.value as? String == "Live"
            reachedAwaitingSource = !reachedLive && awaitingSource.exists
        }
        XCTAssertTrue(reachedLive || reachedAwaitingSource,
                      "The signed Mac helper reached neither source selection nor a live stream.")
        if reachedAwaitingSource {
            retainMenuScreenshot(app, name: "Physical supervised Computer View awaiting Mac source")
        }

        // If awaiting source won the race, the coordinator selects a Mac source
        // while this wait is active. An already-live stream completes it at once.
        let live = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Live"),
            object: preview
        )
        XCTAssertEqual(XCTWaiter.wait(for: [live], timeout: 90), .completed,
                       "The authenticated local WebRTC stream never became live.")
        let liveLatency = Date().timeIntervalSince(openedAt)
        XCTAssertLessThan(liveLatency, 90)
        XCTContext.runActivity(named: String(format: "Computer view live latency %.3fs", liveLatency)) { activity in
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = String(format: "Physical live Mac stream %.3fs", liveLatency)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        let zoom = app.buttons["computer-session-more"]
        selectComputerMoreAction(app, identifier: "computer-session-zoom-in")
        XCTAssertEqual(zoom.value as? String, "125 percent")
        selectComputerMoreAction(app, identifier: "computer-session-fit")
        XCTAssertEqual(zoom.value as? String, "100 percent")

        // Backgrounding must close the session and never reveal a stale frame
        // when Wonder returns to the foreground.
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.activate()
        XCTAssertFalse(computerView.waitForExistence(timeout: 10))
    }

    func testPhysicalComputerControlAcceptsInputAndReleases() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        let localNetworkMonitor = installWonderLocalNetworkPermissionMonitor()
        defer { removeUIInterruptionMonitor(localNetworkMonitor) }
        app.launch()

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-row:")).firstMatch
        guard row.waitForExistence(timeout: 20) else {
            throw XCTSkip("Requires an unlocked physical device paired with the updated Wonder host.")
        }
        row.tap()
        let details = app.buttons["Conversation details"]
        XCTAssertTrue(details.waitForExistence(timeout: 15))
        details.tap()
        let viewComputer = app.buttons["View computer"]
        XCTAssertTrue(viewComputer.waitForExistence(timeout: 15))
        viewComputer.tap()

        let computerView = app.descendants(matching: .any)
            .matching(identifier: "computer-session-container").firstMatch
        XCTAssertTrue(computerView.waitForExistence(timeout: 15))
        let preview = app.descendants(matching: .any)
            .matching(identifier: "computer-session-preview").firstMatch
        let live = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Live"),
            object: preview
        )
        XCTAssertEqual(XCTWaiter.wait(for: [live], timeout: 90), .completed,
                       "The authenticated local WebRTC stream never became live.")

        let takeControl = app.buttons["computer-session-take-control"]
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        let requestedAt = Date()
        takeControl.tap()
        let waiting = app.descendants(matching: .any)
            .matching(identifier: "computer-session-waiting").firstMatch
        let active = app.descendants(matching: .any)
            .matching(identifier: "computer-session-control-active").firstMatch

        // Persistent paired-device authorization can make control active before
        // the transient starting state is sampled. Accept either state first,
        // then require the active state within the same overall timeout.
        let controlStartTimeout: TimeInterval = 125
        let controlStartDeadline = Date().addingTimeInterval(controlStartTimeout)
        let enteredStartingOrActive = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in waiting.exists || active.exists },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [enteredStartingOrActive], timeout: controlStartTimeout),
            .completed,
            "Control never reached a starting or active state."
        )
        let activeTimeout = max(0, controlStartDeadline.timeIntervalSinceNow)
        XCTAssertTrue(active.waitForExistence(timeout: activeTimeout),
                      "Control did not start on the Mac.")
        let consentLatency = Date().timeIntervalSince(requestedAt)
        XCTContext.runActivity(named: String(format: "Control consent latency %.3fs", consentLatency)) { activity in
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = String(format: "Physical control active %.3fs", consentLatency)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        app.buttons["computer-session-more"].tap()
        if !app.buttons["Trackpad"].exists { app.buttons["Pointer mode"].tap() }
        app.buttons["Trackpad"].tap()
        app.buttons["computer-session-more"].tap()
        app.buttons["computer-session-recenter"].tap()

        // The coordinator provides an ordinary local-only input fixture window.
        // Trackpad movement preserves the Mac cursor across finger lifts.
        let start = preview.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.5))
        let end = preview.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        end.press(forDuration: 0.05, thenDragTo: start)
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let keyboard = app.buttons["computer-session-keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("Wonder physical control 2026")
        retainMenuScreenshot(app, name: "Physical computer control input accepted")

        app.buttons["computer-session-done"].tap()
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        XCTAssertFalse(active.exists)
        app.buttons["computer-session-close"].tap()
        XCTAssertFalse(computerView.waitForExistence(timeout: 10))
    }

    func testPhysicalComputerTrackpadAndKeyboardThreeMinuteSession() throws {
        continueAfterFailure = false
        guard let qaRowID = ProcessInfo.processInfo.environment["WONDER_PAIRING_QA_CONVERSATION_ID"],
              qaRowID.hasPrefix("chat-row:"), qaRowID.count > "chat-row:".count else {
            throw XCTSkip("Supply WONDER_PAIRING_QA_CONVERSATION_ID with the exact dedicated QA chat-row accessibility identifier.")
        }
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        let localNetworkMonitor = installWonderLocalNetworkPermissionMonitor()
        defer { removeUIInterruptionMonitor(localNetworkMonitor) }
        app.launch()

        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        app.buttons["diagnostics-settings"].tap()
        let capture = app.buttons["diagnostics-capture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        if !capture.isEnabled { app.switches["Record performance"].tap() }
        XCTAssertTrue(capture.isEnabled)
        if capture.label == "Record two minutes" { capture.tap() }
        XCTAssertEqual(capture.label, "Stop capture")
        let captureEvidence = XCTAttachment(string: "Diagnostics capture started before computer setup at \(Date()). Detailed resource/display capture is independently bounded to two minutes; the interaction observation below lasts at least three minutes.")
        captureEvidence.name = "Bounded diagnostics capture window"
        captureEvidence.lifetime = .keepAlways
        add(captureEvidence)
        app.tabBars.buttons["Chats"].tap()

        let row = app.buttons.matching(identifier: qaRowID).firstMatch
        guard row.waitForExistence(timeout: 20) else {
            throw XCTSkip("Requires the explicitly selected QA chat and a paired, unlocked physical device.")
        }
        row.tap()
        let details = app.buttons["Conversation details"]
        XCTAssertTrue(details.waitForExistence(timeout: 15))
        details.tap()
        let viewComputer = app.buttons["View computer"]
        XCTAssertTrue(viewComputer.waitForExistence(timeout: 15))
        viewComputer.tap()

        let computerView = app.descendants(matching: .any)
            .matching(identifier: "computer-session-container").firstMatch
        XCTAssertTrue(computerView.waitForExistence(timeout: 15))
        let preview = app.descendants(matching: .any)
            .matching(identifier: "computer-session-preview").firstMatch
        let live = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Live"),
            object: preview
        )
        XCTAssertEqual(XCTWaiter.wait(for: [live], timeout: 90), .completed,
                       "The authenticated local WebRTC stream never became live.")

        func retainControlPhase(_ phase: String) {
            let evidence = XCTAttachment(string: "Phase: \(phase)\nUnix seconds: \(Date().timeIntervalSince1970)\nCompare the independent Mac fixture receipts at these phase boundaries; an XCTest command completing is not input acceptance.")
            evidence.name = phase
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        func attemptViewOnlyInput(_ phase: String) {
            XCTAssertFalse(app.buttons["computer-session-keyboard"].exists)
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            retainControlPhase("\(phase) begin")
            preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            preview.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.5))
                .press(forDuration: 0.05,
                       thenDragTo: preview.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0)
            retainControlPhase("\(phase) end; host input counts must be unchanged")
            XCTAssertFalse(app.keyboards.firstMatch.exists)
        }

        let takeControl = app.buttons["computer-session-take-control"]
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        attemptViewOnlyInput("View-only before Take control")
        let requestedAt = Date()
        takeControl.tap()
        let waiting = app.descendants(matching: .any)
            .matching(identifier: "computer-session-waiting").firstMatch
        let active = app.descendants(matching: .any)
            .matching(identifier: "computer-session-control-active").firstMatch

        // Persistent paired-device authorization can make control active before
        // the transient starting state is sampled. Accept either state first,
        // then require the active state within the same overall timeout.
        let controlStartTimeout: TimeInterval = 125
        let controlStartDeadline = Date().addingTimeInterval(controlStartTimeout)
        let enteredStartingOrActive = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in waiting.exists || active.exists },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [enteredStartingOrActive], timeout: controlStartTimeout),
            .completed,
            "Control never reached a starting or active state."
        )
        let activeTimeout = max(0, controlStartDeadline.timeIntervalSinceNow)
        XCTAssertTrue(active.waitForExistence(timeout: activeTimeout),
                      "Control did not start on the Mac.")
        let consentLatency = Date().timeIntervalSince(requestedAt)
        XCTContext.runActivity(named: String(format: "Control consent latency %.3fs", consentLatency)) { activity in
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = String(format: "Physical control active %.3fs", consentLatency)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        let preflightStarted = Date()
        selectComputerMoreAction(app, identifier: "computer-session-fit")
        retainComputerGeometry(app, name: "Physical before Direct touch menu")
        app.buttons["computer-session-more"].tap()
        let direct = app.buttons["Direct touch"]
        if !direct.waitForExistence(timeout: 2) {
            let picker = app.buttons["Pointer mode"]
            XCTAssertTrue(picker.waitForExistence(timeout: 2))
            picker.tap()
        }
        XCTAssertTrue(direct.waitForExistence(timeout: 5))
        retainComputerGeometry(app, name: "Physical Direct touch menu before selection")
        direct.tap()
        XCTAssertTrue(waitUntilGone(direct, timeout: 5))
        retainComputerGeometry(app, name: "Physical immediately after Direct touch selection")
        XCTAssertEqual(app.buttons["computer-session-keyboard"].label, "Show keyboard",
                       "Choosing pointer mode must not activate the phone keyboard.")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        retainControlPhase("Direct-touch center click begin")
        retainComputerGeometry(app, name: "Physical before direct preview center tap")
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        retainControlPhase("Direct-touch center click end; expect one Mac click and up")
        retainComputerGeometry(app, name: "Physical after direct preview center tap")
        XCTAssertEqual(app.buttons["computer-session-keyboard"].label, "Show keyboard")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["computer-session-more"].tap()
        retainComputerGeometry(app, name: "Physical reopened More after direct preview tap")
        let trackpad = app.buttons["Trackpad"]
        if !trackpad.waitForExistence(timeout: 2) {
            let picker = app.buttons["Pointer mode"]
            XCTAssertTrue(picker.waitForExistence(timeout: 2))
            picker.tap()
        }
        XCTAssertTrue(trackpad.waitForExistence(timeout: 5))
        trackpad.tap()
        XCTAssertTrue(waitUntilGone(trackpad, timeout: 5))
        selectComputerMoreAction(app, identifier: "computer-session-recenter")
        assertComputerMoreMenuExcludesTeaching(app)
        let observationStart = Date()
        let preflightSeconds = observationStart.timeIntervalSince(preflightStarted)
        var commandDurations: [Double] = []

        var completedCycles = 0
        while (completedCycles < 30 || Date().timeIntervalSince(observationStart) < 180)
                && Date().timeIntervalSince(observationStart) < 300 {
            let iteration = completedCycles
            let cycleStarted = Date()
            XCTAssertTrue(active.exists)
            XCTAssertEqual(preview.value as? String, "Live")
            let fromX: CGFloat = iteration.isMultiple(of: 2) ? 0.47 : 0.53
            let toX: CGFloat = iteration.isMultiple(of: 2) ? 0.53 : 0.47
            let from = preview.coordinate(withNormalizedOffset: CGVector(dx: fromX, dy: 0.5))
            let to = preview.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0)
            preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            commandDurations.append(Date().timeIntervalSince(cycleStarted))

            if iteration < 30 && iteration.isMultiple(of: 10) {
                // The fixture records right-clicks without opening a menu or
                // changing the focused text target.
                preview.tap(withNumberOfTaps: 1, numberOfTouches: 2)
                let dragStart = preview.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.52))
                dragStart.tap()
                dragStart.press(forDuration: 0.25,
                                thenDragTo: preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52)),
                                withVelocity: .slow, thenHoldForDuration: 0)
                preview.pinch(withScale: 1.25, velocity: 1)
                selectComputerMoreAction(app, identifier: "computer-session-fit")
                selectComputerMoreAction(app, identifier: "computer-session-recenter")
                preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let keyboard = app.buttons["computer-session-keyboard"]
                keyboard.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                if iteration == 0 { retainComputerGeometry(app, name: "Physical native keyboard before committed typing") }
                app.typeText("CONTROL-\(iteration)\nCafe\u{301} 🙂Z")
                app.typeText(XCUIKeyboardKey.delete.rawValue)
                app.typeText("\n")
                keyboard.tap()
                XCTAssertTrue(waitUntilGone(app.keyboards.firstMatch, timeout: 5))
            }
            if iteration == 0 || iteration == 15 || iteration == 29 {
                retainMenuScreenshot(app, name: "Physical computer control cycle \(iteration)")
            }
            completedCycles += 1
            // Continue relevant pointer input for three minutes. The three
            // keyboard/gesture groups run once each; later cycles stay light.
        }
        let elapsed = Date().timeIntervalSince(observationStart)
        XCTAssertGreaterThanOrEqual(completedCycles, 30,
                                    "The bounded observation ended before 30 relevant input cycles completed.")
        XCTAssertGreaterThanOrEqual(elapsed, 180)
        XCTAssertTrue(active.exists)
        XCTAssertEqual(preview.value as? String, "Live")
        retainControlPhase("Pointer and keyboard cycles complete; independently verify accepted Mac input receipts")
        let ordered = commandDurations.sorted()
        let evidence = XCTAttachment(string: "Preflight seconds (excluded from observation): \(preflightSeconds)\nActive observation seconds: \(elapsed)\nRepetitions: \(completedCycles)\nXCTest command duration only; not touch/render latency.\nSamples: \(ordered.count), p50: \(ordered[ordered.count / 2]), p95: \(ordered[Int(Double(ordered.count - 1) * 0.95)]), max: \(ordered.last ?? 0)\nHost fixture receipts must independently verify pointer, drag, click, text, emoji and deletion outcomes.")
        evidence.name = "Physical computer input observation"
        evidence.lifetime = .keepAlways
        add(evidence)

        // Preserve the prior clipboard in memory without logging its contents.
        // Restore it only if nobody changed the synthetic clipboard in the meantime.
        let clipboardText = "CLIPBOARD-BEGIN\nTab\tCafe\u{301} 🙂\nCLIPBOARD-END\n"
        let previousClipboardItems = UIPasteboard.general.items
        UIPasteboard.general.string = clipboardText
        let clipboardChange = UIPasteboard.general.changeCount
        defer {
            if UIPasteboard.general.changeCount == clipboardChange {
                UIPasteboard.general.items = previousClipboardItems
            }
        }
        func acceptExpectedPastePermission(_ alert: XCUIElement) -> Bool {
            let allow = alert.buttons["Allow Paste"]
            let mentionsPaste = alert.label.localizedCaseInsensitiveContains("paste")
                || alert.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "paste")).firstMatch.exists
            guard mentionsPaste, allow.exists else { return false }
            allow.tap()
            return true
        }
        let pasteMonitor = addUIInterruptionMonitor(withDescription: "Wonder reads the synthetic test clipboard") { alert in
            acceptExpectedPastePermission(alert)
        }
        defer { removeUIInterruptionMonitor(pasteMonitor) }
        selectComputerMoreAction(app, identifier: "computer-session-recenter")
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let keyboard = app.buttons["computer-session-keyboard"]
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertComputerControlRow(app)
        app.buttons["computer-session-clipboard"].tap()
        let paste = app.buttons["computer-session-paste-from-phone"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        retainControlPhase("Clipboard multiline tab combining-accent emoji paste begin")
        paste.tap()
        let appPasteAlert = app.alerts.firstMatch
        let systemPasteAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if appPasteAlert.buttons["Allow Paste"].waitForExistence(timeout: 2) {
            XCTAssertTrue(acceptExpectedPastePermission(appPasteAlert))
        } else if systemPasteAlert.buttons["Allow Paste"].waitForExistence(timeout: 2) {
            XCTAssertTrue(acceptExpectedPastePermission(systemPasteAlert))
        }
        retainControlPhase("Clipboard paste end; expect exact CLIPBOARD-BEGIN through CLIPBOARD-END payload on Mac")
        retainComputerGeometry(app, name: "Physical native keyboard after multiline clipboard paste")
        XCTAssertTrue(active.exists)
        XCTAssertFalse(app.staticTexts["There is no text on this phone to paste."].exists)
        XCTAssertFalse(app.staticTexts["Phone clipboard text is too large or contains unsupported characters."].exists)
        keyboard.tap()
        XCTAssertTrue(waitUntilGone(app.keyboards.firstMatch, timeout: 5))
        retainMenuScreenshot(app, name: "Physical computer control after input and clipboard checks")
        app.buttons["computer-session-done"].tap()
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        XCTAssertFalse(active.exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        attemptViewOnlyInput("View-only after Done")
        XCTAssertTrue(takeControl.exists)
        retainControlPhase("Input acceptance complete; all held Mac buttons and keys must be released")
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(observationStart), 300,
                                 "Active input observation and release exceeded the five-minute budget.")
        app.buttons["computer-session-close"].tap()
        XCTAssertTrue(waitUntilGone(computerView, timeout: 10))
    }

    func testPhysicalComputerRecenterActionDismissesMenuThreeTimes() throws {
        continueAfterFailure = false
        guard let qaRowID = ProcessInfo.processInfo.environment["WONDER_PAIRING_QA_CONVERSATION_ID"],
              qaRowID.hasPrefix("chat-row:"), qaRowID.count > "chat-row:".count else {
            throw XCTSkip("Supply WONDER_PAIRING_QA_CONVERSATION_ID with the exact dedicated QA chat-row accessibility identifier.")
        }
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        let localNetworkMonitor = installWonderLocalNetworkPermissionMonitor()
        defer { removeUIInterruptionMonitor(localNetworkMonitor) }
        app.launch()

        let row = app.buttons.matching(identifier: qaRowID).firstMatch
        guard row.waitForExistence(timeout: 20) else {
            throw XCTSkip("Requires the explicitly selected QA chat and a paired, unlocked physical device.")
        }
        row.tap()
        let details = app.buttons["Conversation details"]
        XCTAssertTrue(details.waitForExistence(timeout: 15))
        details.tap()
        let viewComputer = app.buttons["View computer"]
        XCTAssertTrue(viewComputer.waitForExistence(timeout: 15))
        viewComputer.tap()

        let computerView = app.descendants(matching: .any).matching(identifier: "computer-session-container").firstMatch
        XCTAssertTrue(computerView.waitForExistence(timeout: 15))
        defer {
            // A first Close tap can dismiss an open native menu. A second
            // closes the viewer and releases control if it is still present.
            let close = app.buttons["computer-session-close"]
            if close.exists { close.tap() }
            if computerView.exists && close.exists { close.tap() }
        }
        let preview = app.descendants(matching: .any).matching(identifier: "computer-session-preview").firstMatch
        let live = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Live"), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [live], timeout: 90), .completed)
        let takeControl = app.buttons["computer-session-take-control"]
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        takeControl.tap()
        let active = app.descendants(matching: .any).matching(identifier: "computer-session-control-active").firstMatch
        XCTAssertTrue(active.waitForExistence(timeout: 125), "Control did not start on the Mac.")

        for iteration in 1...3 {
            let more = app.buttons["computer-session-more"]
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            more.tap()
            let byIdentifier = app.buttons["computer-session-recenter"]
            // Native menu sections may retain the spoken label but omit ID.
            let byLabel = app.buttons.matching(NSPredicate(format: "label == %@", "Recenter pointer")).firstMatch
            let actionVisible = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in byIdentifier.exists || byLabel.exists }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [actionVisible], timeout: 5), .completed)
            let action = byIdentifier.exists ? byIdentifier : byLabel
            let match = "Recenter \(iteration), Unix seconds \(Date().timeIntervalSince1970), identifier match \(byIdentifier.exists), label match \(byLabel.exists), frame \(action.frame)\n\(action.debugDescription)"
            print("COMPUTER_RECENTER_MATCH \(match)")
            let attachment = XCTAttachment(string: match)
            attachment.name = "Physical Recenter \(iteration) matched button"
            attachment.lifetime = .keepAlways
            add(attachment)
            retainComputerGeometry(app, name: "Physical Recenter \(iteration) before tap")
            XCTAssertTrue(action.isHittable)
            action.tap()
            retainComputerGeometry(app, name: "Physical Recenter \(iteration) after tap")
            XCTAssertTrue(waitUntilGone(byLabel, timeout: 5), "Recenter \(iteration) did not dismiss its native menu.")
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            XCTAssertTrue(active.exists)
        }
        // Menu dismissal is UI evidence; compare the temporary action/input
        // trace and host lease sequence to verify all three actions executed.
        app.buttons["computer-session-done"].tap()
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        XCTAssertFalse(active.exists)
        app.buttons["computer-session-close"].tap()
        XCTAssertTrue(waitUntilGone(computerView, timeout: 10))
    }

    func testPhysicalComputerControlExternalRevocationLeavesViewOnly() throws {
        continueAfterFailure = false
        guard let qaRowID = ProcessInfo.processInfo.environment["WONDER_PAIRING_QA_CONVERSATION_ID"],
              qaRowID.hasPrefix("chat-row:"), qaRowID.count > "chat-row:".count else {
            throw XCTSkip("Supply WONDER_PAIRING_QA_CONVERSATION_ID with the exact dedicated QA chat-row accessibility identifier.")
        }
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        let localNetworkMonitor = installWonderLocalNetworkPermissionMonitor()
        defer { removeUIInterruptionMonitor(localNetworkMonitor) }
        app.launch()

        let row = app.buttons.matching(identifier: qaRowID).firstMatch
        guard row.waitForExistence(timeout: 20) else {
            throw XCTSkip("Requires the explicitly selected QA chat and a paired, unlocked physical device.")
        }
        row.tap()
        let details = app.buttons["Conversation details"]
        XCTAssertTrue(details.waitForExistence(timeout: 15))
        details.tap()
        let viewComputer = app.buttons["View computer"]
        XCTAssertTrue(viewComputer.waitForExistence(timeout: 15))
        viewComputer.tap()

        let computerView = app.descendants(matching: .any)
            .matching(identifier: "computer-session-container").firstMatch
        XCTAssertTrue(computerView.waitForExistence(timeout: 15))
        defer {
            let done = app.buttons["computer-session-done"]
            if done.exists {
                done.tap()
                _ = app.buttons["computer-session-take-control"].waitForExistence(timeout: 10)
            }
            let close = app.buttons["computer-session-close"]
            if close.exists {
                close.tap()
                _ = computerView.waitForExistence(timeout: 10)
            }
        }

        let preview = app.descendants(matching: .any)
            .matching(identifier: "computer-session-preview").firstMatch
        let live = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Live"),
            object: preview
        )
        XCTAssertEqual(XCTWaiter.wait(for: [live], timeout: 90), .completed,
                       "The authenticated local WebRTC stream never became live.")

        let takeControl = app.buttons["computer-session-take-control"]
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        takeControl.tap()
        let waiting = app.descendants(matching: .any)
            .matching(identifier: "computer-session-waiting").firstMatch
        let active = app.descendants(matching: .any)
            .matching(identifier: "computer-session-control-active").firstMatch

        // Persistent paired-device authorization can make control active before
        // the transient starting state is sampled. Accept either state first,
        // then require the active state within the same overall timeout.
        let controlStartTimeout: TimeInterval = 125
        let controlStartDeadline = Date().addingTimeInterval(controlStartTimeout)
        let enteredStartingOrActive = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in waiting.exists || active.exists },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [enteredStartingOrActive], timeout: controlStartTimeout),
            .completed,
            "Control never reached a starting or active state."
        )
        XCTAssertTrue(
            active.waitForExistence(timeout: max(0, controlStartDeadline.timeIntervalSinceNow)),
            "Control did not start on the Mac."
        )

        // This wait is the manual gesture handoff. The coordinator then presses
        // Stop control on the Mac; the phone must return to view-only. The test
        // injects no pointer or keyboard input during the handoff.
        let viewOnly = app.descendants(matching: .any)
            .matching(identifier: "computer-session-view-only").firstMatch
        let externallyRevoked = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                takeControl.exists && viewOnly.exists && !active.exists
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [externallyRevoked], timeout: 180),
            .completed,
            "The phone did not leave active control after the external Mac revocation."
        )
        XCTAssertTrue(takeControl.exists)
        XCTAssertTrue(viewOnly.exists)
        XCTAssertFalse(active.exists)
    }

    private func installWonderLocalNetworkPermissionMonitor() -> NSObjectProtocol {
        addUIInterruptionMonitor(withDescription: "Wonder Local Network permission") { alert in
            let mentionsLocalNetwork = alert.label.localizedCaseInsensitiveContains("local network")
                || alert.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS[c] %@", "local network")
                ).firstMatch.exists
            guard mentionsLocalNetwork else { return false }

            // Do not accept arbitrary system prompts. The only supported
            // permission transition in this test is the explicit Allow action
            // on Wonder's Local Network prompt.
            let allow = alert.buttons["Allow"]
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
    }

    func testDiagnosticsTeachingUnavailableFixture() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-teaching-fixture"]
        app.launch()

        XCTAssertTrue(app.collectionViews["teaching-view"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Teach Orbit"].exists)
        XCTAssertTrue(app.staticTexts["Teaching capture unavailable"].exists)
        XCTAssertTrue(app.staticTexts["Teaching requires a newer Wonder host. Update Wonder on your Mac, then try again."].exists)
        let outcome = app.textFields["teaching-outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 5))
        XCTAssertFalse((outcome.value as? String ?? "").contains("Create a preview file"))
        XCTAssertFalse(app.buttons["teaching-done"].exists)
        let start = app.buttons["teaching-start"]
        XCTAssertTrue(start.exists)
        XCTAssertFalse(start.isEnabled)
        XCTAssertTrue(app.staticTexts["Saved · Version 1 · Replay not verified"].exists)
        retainMenuScreenshot(app, name: "Teaching capture unavailable")

        app.buttons["teaching-skill-fixture-private-skill"].tap()
        XCTAssertTrue(app.staticTexts["Visibility, This Bot only"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Version 1, Replay not verified"].exists)
        XCTAssertTrue(app.textFields["teaching-fixture-title"].exists)
        XCTAssertTrue(app.textFields["teaching-fixture-date"].exists)
        app.buttons["teaching-fixture-run"].tap()
        let fixtureSuccess = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture tested · Version 1 ·")).firstMatch
        XCTAssertTrue(fixtureSuccess.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Preview artifact verified (256 bytes). Real supervised replay remains unverified."].exists)
        XCTAssertTrue(app.staticTexts["Version 1, Fixture tested"].exists)
        retainMenuScreenshot(app, name: "Fixture tested")
    }

    func testDiagnosticsTeachingAvailableFixtureRecordsReviewsAndSaves() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-teaching-fixture", "-diagnostics-teaching-flow-fixture"]
        app.launch()

        XCTAssertTrue(app.collectionViews["teaching-view"].waitForExistence(timeout: 10))
        let start = app.buttons["teaching-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        XCTAssertFalse(app.buttons["teaching-done"].exists)
        XCTAssertEqual(app.textFields["teaching-outcome"].value as? String, "Create a preview file")
        XCTAssertFalse(app.staticTexts["Take control is required"].exists)
        retainMenuScreenshot(app, name: "Teaching ready after control lease")

        start.tap()
        XCTAssertTrue(app.buttons["teaching-stop"].waitForExistence(timeout: 5))
        let recording = app.descendants(matching: .any).matching(identifier: "teaching-recording-status").firstMatch
        XCTAssertTrue(recording.waitForExistence(timeout: 5))
        XCTAssertTrue(recording.label.contains("Recording"))
        let privacyCopy = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "No screenshots or clipboard text")).firstMatch
        XCTAssertTrue(privacyCopy.exists)
        retainMenuScreenshot(app, name: "Teaching recording")

        app.buttons["teaching-stop"].tap()
        let teachingForm = app.collectionViews["teaching-view"]
        let reviewStatus = app.descendants(matching: .any).matching(identifier: "teaching-session-status").firstMatch
        for _ in 0..<6 {
            if reviewStatus.exists {
                break
            }
            teachingForm.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(reviewStatus.waitForExistence(timeout: 5))
        let readyToReview = expectation(
            for: NSPredicate(format: "value == %@", "Ready to review"),
            evaluatedWith: reviewStatus
        )
        wait(for: [readyToReview], timeout: 5)
        XCTAssertEqual(reviewStatus.value as? String, "Ready to review")
        retainMenuScreenshot(app, name: "Teaching after stop")
        let capturedActions = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Captured actions ·"))
            .firstMatch
        var capturedActionsVisible = false
        for _ in 0..<12 {
            if capturedActions.exists {
                let frame = capturedActions.frame
                if capturedActions.isHittable && frame.minY >= app.frame.minY && frame.maxY <= app.frame.maxY - 8 {
                    capturedActionsVisible = true
                    break
                }
                if frame.minY < app.frame.minY {
                    teachingForm.swipeDown(velocity: .slow)
                } else {
                    teachingForm.swipeUp(velocity: .slow)
                }
            } else {
                teachingForm.swipeUp(velocity: .slow)
            }
        }
        XCTAssertTrue(capturedActionsVisible, "Captured actions did not become fully visible within the bounded reveal loop")
        XCTAssertTrue(capturedActions.waitForExistence(timeout: 5))
        assertFullyVisible(capturedActions, in: app)
        XCTAssertEqual(capturedActions.value as? String, "Collapsed")
        capturedActions.tap()
        let expanded = expectation(
            for: NSPredicate(format: "value == %@", "Expanded"),
            evaluatedWith: capturedActions
        )
        wait(for: [expanded], timeout: 5)
        XCTAssertEqual(capturedActions.value as? String, "Expanded")
        let capturedEvent = app.descendants(matching: .any).matching(identifier: "teaching-event-1-0").firstMatch
        XCTAssertTrue(capturedEvent.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Text input redacted"].exists)
        XCTAssertTrue(app.staticTexts["Showing first 3 of 4 actions"].exists)
        retainMenuScreenshot(app, name: "Teaching captured event review")
        for _ in 0..<6 where !app.textFields["teaching-draft-inputs"].exists {
            teachingForm.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(app.textFields["teaching-draft-inputs"].waitForExistence(timeout: 5))

        for _ in 0..<6 {
            let review = app.buttons["teaching-review"]
            if review.isHittable && review.frame.minY >= app.frame.minY && review.frame.maxY <= app.frame.maxY - 8 {
                break
            }
            teachingForm.swipeUp(velocity: .slow)
        }
        let review = app.buttons["teaching-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        assertFullyVisible(review, in: app)
        review.tap()
        for _ in 0..<6 where !app.buttons["teaching-save"].exists {
            teachingForm.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(app.buttons["teaching-save"].waitForExistence(timeout: 5))
        app.buttons["teaching-save"].tap()
        for _ in 0..<6 where !app.staticTexts["Saved privately"].exists || !app.staticTexts["Saved is distinct from Replay verified. This demonstration has not been replay-verified."].exists {
            teachingForm.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(app.staticTexts["Saved privately"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved is distinct from Replay verified. This demonstration has not been replay-verified."].exists)
        retainMenuScreenshot(app, name: "Teaching saved private skill")
    }

    func testDiagnosticsTeachingCancelLeavesNoDemonstration() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-teaching-fixture", "-diagnostics-teaching-flow-fixture"]
        app.launch()

        XCTAssertTrue(app.buttons["teaching-start"].waitForExistence(timeout: 10))
        app.buttons["teaching-start"].tap()
        XCTAssertTrue(app.buttons["teaching-cancel"].waitForExistence(timeout: 5))
        app.buttons["teaching-cancel"].tap()
        let cancelled = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Cancelled")).firstMatch
        XCTAssertTrue(cancelled.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["teaching-save"].exists)
        XCTAssertFalse(app.staticTexts["Saved privately"].exists)
    }

    func testLiveChatContextMenuCancellation() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launch()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-row:"))
        guard rows.firstMatch.waitForExistence(timeout: 15) else { throw XCTSkip("Requires a paired device with a chat in the list.") }
        let row = app.buttons[rows.firstMatch.identifier]
        // Read-only interaction: open Delete, then Cancel. Never confirm a
        // deletion or archive an owner's conversation during this live check.
        for iteration in 0..<12 {
            row.press(forDuration: 0.8)
            XCTAssertTrue(app.buttons["Advanced"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["Archive"].isEnabled)
            if iteration == 0 { retainMenuScreenshot(app, name: "Live chat menu") }
            app.buttons["Advanced"].tap()
            XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["Copy ID"].isEnabled)
            if iteration == 0 { retainMenuScreenshot(app, name: "Live advanced menu") }
            app.buttons["Delete"].tap()
            XCTAssertTrue(app.buttons["Delete forever"].waitForExistence(timeout: 3))
            if iteration == 0 { retainMenuScreenshot(app, name: "Delete confirmation") }
            if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
            else {
                // Newer iOS can present confirmation as a popover, where
                // cancellation is tapping its native outside-dismiss region.
                let dismiss = app.otherElements["PopoverDismissRegion"]
                XCTAssertTrue(dismiss.exists)
                dismiss.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.2)).tap()
            }
            XCTAssertFalse(app.buttons["Delete forever"].exists)
            XCTAssertTrue(row.isHittable)
        }
    }

    private func retainMenuScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openWorkingImage(_ app: XCUIApplication, scroll: XCUIElement) throws -> (XCUIElement, XCUIElement) {
        let groups = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity-group:"))
        let images = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tool-image:"))
        let screen = app.frame
        let target = ProcessInfo.processInfo.environment["WONDER_WORKING_IMAGE_GROUP"]
        var checked: Set<String> = []
        for _ in 0..<16 {
            guard let candidate = groups.allElementsBoundByIndex.last(where: {
                (target == nil || $0.identifier == target) && !checked.contains($0.identifier)
                    && $0.isHittable && $0.frame.minY > screen.minY + 150 && $0.frame.maxY < screen.maxY - 250
            }) else { scroll.swipeDown(velocity: .slow); continue }
            let group = app.buttons[candidate.identifier]
            checked.insert(group.identifier)
            let before = Set(images.allElementsBoundByIndex.map(\.identifier))
            XCTAssertEqual(group.value as? String, "Collapsed")
            group.tap()
            XCTAssertEqual(group.value as? String, "Expanded")
            for _ in 0..<6 {
                if let image = images.allElementsBoundByIndex.first(where: {
                    !before.contains($0.identifier) && $0.isHittable && $0.frame.minY > screen.minY + 150 && $0.frame.maxY < screen.maxY - 250
                }) { return (group, app.buttons[image.identifier]) }
                scroll.swipeUp(velocity: .slow)
            }
            revealWorkingGroup(group, app: app, scroll: scroll)
            group.tap()
            XCTAssertEqual(group.value as? String, "Collapsed")
        }
        XCTFail("No working image was found in the reachable live history.")
        throw NSError(domain: "WonderUITests", code: 1)
    }

    private func revealWorkingGroup(_ group: XCUIElement, app: XCUIApplication, scroll: XCUIElement) {
        let screen = app.frame
        for _ in 0..<12 {
            if group.isHittable && group.frame.minY > screen.minY + 150 && group.frame.maxY < screen.maxY - 250 { return }
            scroll.swipeDown(velocity: .slow)
        }
        XCTFail("Could not return to the image's Working disclosure.")
    }

    func testLiveWorkingImageDisclosure() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launch()
        let chat = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Wonder iOS")).firstMatch
        guard chat.waitForExistence(timeout: 15) else { throw XCTSkip("Requires the paired Wonder iOS conversation.") }
        chat.tap()
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let screen = app.frame
        if app.buttons["scroll-to-bottom"].exists { app.buttons["scroll-to-bottom"].tap() }
        let (group, image) = try openWorkingImage(app, scroll: scroll)
        for iteration in 0..<10 {
            XCTAssertEqual(group.value as? String, "Expanded")
            let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Loaded"), object: image)
            XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 15), .completed)
            if iteration == 0 {
                retainMenuScreenshot(app, name: "Live image inside Working")
                image.tap()
                let viewerImage = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo-viewer-image:")).firstMatch
                XCTAssertTrue(viewerImage.waitForExistence(timeout: 10))
                XCTAssertTrue(app.buttons["photo-viewer-close"].waitForExistence(timeout: 5))
                viewerImage.doubleTap()
                let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "200%"), object: viewerImage)
                XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed)
                viewerImage.press(forDuration: 1.0)
                XCTAssertTrue(app.buttons["Copy image"].waitForExistence(timeout: 5))
                app.buttons["Copy image"].tap()
                XCTAssertTrue(app.staticTexts["Image copied"].waitForExistence(timeout: 5))
                retainMenuScreenshot(app, name: "Live fullscreen image after zoom and copy")
                app.buttons["photo-viewer-close"].tap()
                XCTAssertTrue(image.waitForExistence(timeout: 10))
            }
            revealWorkingGroup(group, app: app, scroll: scroll)
            group.tap()
            XCTAssertEqual(group.value as? String, "Collapsed")
            XCTAssertFalse(image.exists)
            if iteration == 0 { retainMenuScreenshot(app, name: "Live Working collapsed") }
            if iteration < 9 {
                group.tap()
                for _ in 0..<6 {
                    if image.exists && image.isHittable && image.frame.minY > screen.minY + 150 && image.frame.maxY < screen.maxY - 250 { break }
                    scroll.swipeUp(velocity: .slow)
                }
                XCTAssertTrue(image.isHittable)
            }
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testLiveInlineImageScrolling() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launch()
        let chat = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Wonder iOS")).firstMatch
        guard chat.waitForExistence(timeout: 15) else { throw XCTSkip("Requires the paired Wonder iOS conversation with a generated image.") }
        chat.tap()
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let bottom = app.buttons["scroll-to-bottom"]
        if bottom.exists { bottom.tap() }
        let (group, selectedImage) = try openWorkingImage(app, scroll: scroll)
        defer { revealWorkingGroup(group, app: app, scroll: scroll); group.tap() }
        let images = app.buttons.matching(identifier: selectedImage.identifier)
        func visibleImage() -> XCUIElement? {
            images.allElementsBoundByIndex.first { image in
                image.isHittable && image.frame.minY > app.frame.minY + 150 && image.frame.maxY < app.frame.maxY - 180
            }
        }
        for _ in 0..<20 {
            if visibleImage() != nil { break }
            scroll.swipeDown(velocity: .slow)
        }
        guard let image = visibleImage() else { XCTFail("Could not bring the generated image into view"); return }
        // Also works against the baseline build, which has no Loaded value.
        let stableImage = image.identifier.isEmpty ? image : app.buttons[image.identifier]
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            stableImage.frame.height > 200
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 20), .completed)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Inline image before scrolling"; screenshot.lifetime = .keepAlways; add(screenshot)
        let options = XCTMeasureOptions()
        options.iterationCount = ProcessInfo.processInfo.environment["WONDER_IMAGE_SCROLL_SMOKE"] == "1" ? 1 : 10
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric(), XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            for _ in 0..<3 { scroll.swipeDown(); scroll.swipeUp() }
        }
        XCTAssertTrue(images.allElementsBoundByIndex.contains { $0.isHittable && $0.frame.height > 200 })
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = "Inline image after scrolling"; after.lifetime = .keepAlways; add(after)
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testLiveImagePreview() throws {
        continueAfterFailure=false
        let app=XCUIApplication(bundleIdentifier:"com.swaymun.wonder")
        app.launch()
        let chat=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@", "Diagnostics image preview")).firstMatch
        guard chat.waitForExistence(timeout:15) else { throw XCTSkip("Prepare the dedicated image test Bot with Preview fixture 4000x3000.png first.") }
        chat.tap()
        app.buttons["Conversation details"].tap()
        app.buttons["Files"].tap()
        let file=app.buttons["Preview fixture 4000x3000.png"]
        XCTAssertTrue(file.waitForExistence(timeout:10))
        let options=XCTMeasureOptions(); options.iterationCount=3
        measure(metrics:[XCTClockMetric(),XCTMemoryMetric()],options:options) {
            file.tap()
            let photo = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo-viewer-image:")).firstMatch
            XCTAssertTrue(photo.waitForExistence(timeout:10))
            XCTAssertTrue(app.buttons["photo-viewer-close"].waitForExistence(timeout:10))
            XCTAssertTrue((photo.value as? String)?.contains("100%") == true)
            photo.doubleTap()
            let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "200%"), object: photo)
            XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed)
            photo.doubleTap()
            let reset = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "100%"), object: photo)
            XCTAssertEqual(XCTWaiter.wait(for: [reset], timeout: 5), .completed)
            photo.press(forDuration: 1.0)
            let copy = app.buttons["Copy image"]
            XCTAssertTrue(copy.waitForExistence(timeout:5))
            copy.tap()
            XCTAssertTrue(app.staticTexts["Image copied"].waitForExistence(timeout:5))
            app.buttons["photo-viewer-close"].tap()
            XCTAssertTrue(file.waitForExistence(timeout:5))
        }
    }

    func testLiveWorkspaceBrowserIsReadOnlyAndNavigable() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launch()
        let chat = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Wonder iOS")).firstMatch
        guard chat.waitForExistence(timeout: 15) else { throw XCTSkip("Requires the paired Wonder iOS conversation.") }
        chat.tap()
        XCTAssertTrue(app.buttons["Conversation details"].waitForExistence(timeout: 10))
        app.buttons["Conversation details"].tap()
        XCTAssertTrue(app.buttons["Files"].waitForExistence(timeout: 5))
        app.buttons["Files"].tap()

        let picker = app.descendants(matching: .any).matching(identifier: "workspace-view-picker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "The updated paired host must expose workspace browsing.")
        let hidden = app.buttons["workspace-hidden-toggle"]
        XCTAssertTrue(hidden.waitForExistence(timeout: 15))
        XCTAssertEqual(hidden.value as? String, "Off")
        hidden.tap()
        XCTAssertEqual(hidden.value as? String, "On")

        let directory = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace-directory-entry:")).firstMatch
        XCTAssertTrue(directory.waitForExistence(timeout: 15))
        let directoryID = directory.identifier
        directory.tap()
        XCTAssertTrue(app.buttons["workspace-back"].waitForExistence(timeout: 15))
        retainMenuScreenshot(app, name: "Live workspace directory")
        app.buttons["workspace-back"].tap()
        XCTAssertTrue(app.buttons[directoryID].waitForExistence(timeout: 10))

        app.buttons["Modified"].tap()
        let changed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace-modified-entry:")).firstMatch
        let noChanges = app.staticTexts["No modified files"]
        let unavailable = app.descendants(matching: .any).matching(identifier: "workspace-git-unavailable").firstMatch
        let modifiedReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            changed.exists || noChanges.exists || unavailable.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [modifiedReady], timeout: 20), .completed)
        XCTAssertFalse(unavailable.exists, "The updated paired host should provide bounded Git inspection for this workspace.")
        if changed.exists {
            changed.tap()
            if app.buttons["Staged changes"].waitForExistence(timeout: 2) {
                app.buttons["Staged changes"].tap()
            }
            XCTAssertTrue(app.buttons["workspace-diff-close"].waitForExistence(timeout: 15))
            retainMenuScreenshot(app, name: "Live read-only workspace diff")
            app.buttons["workspace-diff-close"].tap()
            XCTAssertTrue(changed.waitForExistence(timeout: 10))
        } else {
            XCTAssertTrue(noChanges.exists)
            retainMenuScreenshot(app, name: "Live workspace has no modified files")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testDiagnosticsPhotoViewerRoutesImagesDocumentsAndFailures() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview", "-preview-malformed-image"]
        app.launch()

        XCTAssertTrue(app.buttons["Conversation details"].waitForExistence(timeout: 10))
        app.buttons["Conversation details"].tap()
        XCTAssertTrue(app.buttons["View computer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Teach a task"].exists,
                       "Teaching is not available in the beta conversation menu.")
        app.buttons["View computer"].tap()
        let computerMenu = app.buttons["computer-session-more"]
        XCTAssertTrue(computerMenu.waitForExistence(timeout: 5))
        computerMenu.tap()
        let fit = app.buttons["Fit"]
        XCTAssertTrue(fit.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Teach a task"].exists, "Teaching is not available in the beta Computer menu.")
        let computerPreview = app.descendants(matching: .any)
            .matching(identifier: "computer-session-preview").firstMatch
        XCTAssertTrue(computerPreview.waitForExistence(timeout: 5))
        computerPreview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitUntilGone(fit, timeout: 5), "Computer menu did not dismiss")
        let computerClose = app.buttons["computer-session-close"]
        XCTAssertTrue(computerClose.waitForExistence(timeout: 5))
        computerClose.tap()
        XCTAssertTrue(waitUntilGone(computerClose, timeout: 10), "Computer view did not close")
        XCTAssertTrue(app.buttons["Conversation details"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Files"].waitForExistence(timeout: 5))
        app.buttons["Files"].tap()

        let imageFile = app.buttons["Saturday.png"]
        let documentFile = app.buttons["notes.txt"]
        let malformedFile = app.buttons["broken.png"]
        XCTAssertTrue(app.buttons["workspace-close"].waitForExistence(timeout: 10))
        let filesList = app.collectionViews.allElementsBoundByIndex.max {
            $0.frame.minY < $1.frame.minY
        } ?? app.collectionViews.firstMatch
        for _ in 0..<8 where !(imageFile.exists && documentFile.exists && malformedFile.exists) {
            filesList.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(imageFile.waitForExistence(timeout: 10))
        XCTAssertTrue(documentFile.waitForExistence(timeout: 10))
        XCTAssertTrue(malformedFile.waitForExistence(timeout: 10))
        let originalImageFrame = imageFile.frame

        for _ in 0..<3 {
            imageFile.tap()
            let viewerImage = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo-viewer-image:")).firstMatch
            XCTAssertTrue(viewerImage.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["photo-viewer-close"].waitForExistence(timeout: 5))
            retainMenuScreenshot(app, name: "Photo viewer image")
            XCTAssertTrue((viewerImage.value as? String)?.contains("100%") == true)
            viewerImage.doubleTap()
            let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "200%"), object: viewerImage)
            XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed)
            viewerImage.press(forDuration: 1.0)
            let copy = app.buttons["Copy image"]
            XCTAssertTrue(copy.waitForExistence(timeout: 5))
            copy.tap()
            XCTAssertTrue(app.staticTexts["Image copied"].waitForExistence(timeout: 5))
            app.buttons["photo-viewer-close"].tap()
            XCTAssertTrue(imageFile.waitForExistence(timeout: 5))
        }
        XCTAssertEqual(imageFile.frame, originalImageFrame)

        documentFile.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save a copy"].exists)
        XCTAssertFalse(app.buttons["Details"].exists)
        retainMenuScreenshot(app, name: "Workspace document preview")
        app.buttons["workspace-document-close"].tap()
        XCTAssertTrue(documentFile.waitForExistence(timeout: 5))

        malformedFile.tap()
        XCTAssertTrue(anyElement(app, identifier: "photo-viewer-error").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save a copy"].exists)
        XCTAssertTrue(app.buttons["photo-viewer-close"].isHittable)
        retainMenuScreenshot(app, name: "Photo viewer failure")
        app.buttons["photo-viewer-close"].tap()
        XCTAssertTrue(malformedFile.waitForExistence(timeout: 5))
    }

    func testDiagnosticsWorkspaceBrowserViewsNavigationAndGitDiff() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview"]
        app.launch()

        XCTAssertTrue(app.buttons["Conversation details"].waitForExistence(timeout: 10))
        app.buttons["Conversation details"].tap()
        app.buttons["Files"].tap()
        let picker = app.descendants(matching: .any).matching(identifier: "workspace-view-picker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "Workspace browser preview is unavailable in this build.")
        guard picker.exists else { return }
        XCTAssertTrue(app.buttons["workspace-directory-entry:Projects"].waitForExistence(timeout: 5))
        let initial = XCTAttachment(screenshot: app.screenshot()); initial.name = "Workspace all files"; initial.lifetime = .keepAlways; add(initial)

        app.buttons["workspace-directory-entry:Projects"].tap()
        XCTAssertTrue(app.buttons["workspace-file-entry:Projects/Plan.md"].waitForExistence(timeout: 5))
        app.buttons["workspace-back"].tap()
        let hiddenToggle = app.buttons["workspace-hidden-toggle"]
        XCTAssertTrue(hiddenToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(hiddenToggle.isHittable)
        hiddenToggle.tap()
        XCTAssertEqual(hiddenToggle.value as? String, "On")
        let hiddenFile = app.buttons["workspace-file-entry:.gitignore"]
        for _ in 0..<3 {
            if hiddenFile.exists { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(hiddenFile.waitForExistence(timeout: 5))

        app.buttons["Modified"].tap()
        XCTAssertTrue(app.buttons["workspace-modified-entry:README.md"].waitForExistence(timeout: 5))
        app.buttons["workspace-modified-entry:README.md"].tap()
        XCTAssertTrue(app.buttons["workspace-diff-close"].waitForExistence(timeout: 5))
        let diff = XCTAttachment(screenshot: app.screenshot()); diff.name = "Workspace modified diff"; diff.lifetime = .keepAlways; add(diff)
        app.buttons["workspace-diff-close"].tap()
        XCTAssertTrue(app.buttons["workspace-modified-entry:README.md"].waitForExistence(timeout: 5))
    }

    func testLargeActivityDetails() throws {
        let app=XCUIApplication(bundleIdentifier:"com.swaymun.wonder")
        app.launchArguments=["-diagnostics-fixtures"]; app.launch()
        for title in ["Command","Diff"] {
            selectDiagnosticFixture(title, in: app)
            let detail=app.descendants(matching:.any).matching(identifier:"activity-detail").firstMatch
            XCTAssertTrue(detail.waitForExistence(timeout:5))
            let toggle = title == "Diff" ? app.buttons["file-change-toggle:fixture/row"]
                : app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "swift test")).firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
            let output=anyElement(app, identifier:"tool-output")
            XCTAssertTrue(output.waitForExistence(timeout:5)); output.swipeUp(); output.swipeDown()
            XCTAssertEqual(output.label, title == "Command" ? "Command output" : "Diff output")
            XCTAssertEqual(output.value as? String, "Full text is available in the scrollable viewer.")
            XCTAssertGreaterThan(output.frame.height, 0)
            XCTAssertLessThanOrEqual(output.frame.height, 261)
            XCTAssertTrue(toggle.isHittable); toggle.tap()
        }
        selectDiagnosticFixture("Commentary", in: app); app.scrollViews.firstMatch.swipeUp()
        XCTAssertEqual(app.state,.runningForeground)
    }

    func testDiagnosticsLongFilenameKeepsChangeCountsOnTheSameLine() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-fixtures", "-read-preview", "-diagnostics-file-long", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        selectDiagnosticFixture("Diff", in: app)
        let link = app.buttons["file-change-open:Tests/FileChangeSummaryTests.swift"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        XCTAssertEqual(link.label, "FileChangeSummaryTests.swift")
        let added = anyElement(app, identifier: "file-change-additions")
        let removed = anyElement(app, identifier: "file-change-deletions")
        XCTAssertTrue(added.exists); XCTAssertTrue(removed.exists)
        XCTAssertEqual(link.frame.midY, added.frame.midY, accuracy: 2)
        XCTAssertEqual(added.frame.midY, removed.frame.midY, accuracy: 2)
        XCTAssertLessThanOrEqual(removed.frame.maxX, app.frame.maxX)
        retainMenuScreenshot(app, name: "Single line filename link and change counts")
    }

    func testDiagnosticsCancelledQueueKeepsGuideAndWorkingState() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-fixtures", "-diagnostics-cancelled-queue", "-read-preview", "-send-preview"]
        app.launch()
        let working = app.buttons["activity-group:runtime/command-0"]
        XCTAssertTrue(working.waitForExistence(timeout: 10))
        XCTAssertEqual(working.label, "Working…")
        XCTAssertTrue(app.buttons["Stop response"].exists)
        XCTAssertEqual(app.buttons["send-message"].label, "Queue message")
        XCTAssertFalse(anyElement(app, identifier: "last-request-issue").exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Add filename links")).count, 1)
        app.buttons["fixture-add-activity"].tap()
        let activityDetails = app.descendants(matching: .any).matching(identifier: "activity-detail")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: activityDetails)], timeout: 5), .completed)
        XCTAssertEqual(working.label, "Working…")
        XCTAssertFalse(anyElement(app, identifier: "last-request-issue").exists)
        retainMenuScreenshot(app, name: "Cancelled queue preserves live work")
        let draft = app.textViews["message-draft"]
        draft.tap(); draft.typeText("Adjust this response")
        app.buttons["send-message"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["Guide"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Guide"].isEnabled)
        // Inspect only: no message or Guide is sent by this fixture.
    }

    func testDiagnosticsFileChangeSummaryShowsFilenameCountsAndRetainsDiff() throws {
        continueAfterFailure = false
        for large in [false, true] {
            let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
            app.launchArguments = ["-diagnostics-fixtures", "-read-preview"]
            if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
            app.launch()
            selectDiagnosticFixture("Diff", in: app)
            let detail = anyElement(app, identifier: "activity-detail")
            XCTAssertTrue(detail.waitForExistence(timeout: 5))
            XCTAssertEqual(detail.label, "Edited Authentication.swift, 1500 added lines, 1500 removed lines")
            XCTAssertLessThanOrEqual(detail.frame.maxX, app.frame.maxX)
            XCTAssertFalse(app.staticTexts["File changes"].exists)
            XCTAssertFalse(app.staticTexts["Sources/Authentication.swift"].exists)
            retainMenuScreenshot(app, name: large ? "File changes at maximum text" : "Filename and colored change counts")
            let link = app.buttons["file-change-open:Sources/Authentication.swift"]
            XCTAssertTrue(link.waitForExistence(timeout: 5))
            XCTAssertEqual(link.label, "Authentication.swift")
            XCTAssertGreaterThanOrEqual(link.frame.height, 44 - 0.01)
            link.tap()
            XCTAssertTrue(app.navigationBars["Authentication.swift"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Fixture workspace file: Authentication.swift\n"].exists)
            retainMenuScreenshot(app, name: large ? "Linked file at maximum text" : "Filename opens file preview")
            app.buttons["workspace-document-close"].tap()
            XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 5))
            app.buttons["workspace-close"].tap()
            XCTAssertTrue(detail.waitForExistence(timeout: 5))
            XCTAssertEqual(detail.value as? String, "Collapsed")
            let toggle = app.buttons["file-change-toggle:fixture/row"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            for iteration in 0..<3 {
                toggle.tap()
                let output = anyElement(app, identifier: "tool-output")
                XCTAssertTrue(output.waitForExistence(timeout: 5))
                XCTAssertEqual(output.label, "Diff output")
                XCTAssertLessThanOrEqual(output.frame.height, 261)
                if !large && iteration == 0 { retainMenuScreenshot(app, name: "Expanded file diff") }
                toggle.tap()
                XCTAssertFalse(output.exists)
            }
            app.terminate()
        }
    }

    func testDiagnosticsCommandSummaryKeepsDurationOnlyWhenTheFullCommandFits() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-fixtures", "-diagnostics-command-narrow", "-diagnostics-command-short"]
        app.launch()
        selectDiagnosticFixture("Command", in: app)

        let detail = anyElement(app, identifier: "activity-detail")
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let duration = anyElement(app, identifier: "command-duration:fixture/row")
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        // DisclosureGroup combines its visual label's accessibility children.
        XCTAssertTrue(duration.label.hasSuffix("for 5s"))
        XCTAssertTrue(detail.label.contains("Ran `swift test` for 5s"))
        XCTAssertLessThanOrEqual(detail.frame.maxX, app.frame.maxX)
        retainMenuScreenshot(app, name: "Full command retains duration at 220pt")

        let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "swift test")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        let output = anyElement(app, identifier: "tool-output")
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        XCTAssertEqual(output.label, "Command output")
        XCTAssertEqual(output.value as? String, "Full text is available in the scrollable viewer.")
        XCTAssertLessThanOrEqual(output.frame.height, 261)
        XCTAssertEqual(detail.value as? String, "Expanded")
        retainMenuScreenshot(app, name: "Expanded command preserves raw wrapper and bounded output")
        toggle.tap()
        XCTAssertFalse(output.exists)
        XCTAssertEqual(detail.value as? String, "Collapsed")
        toggle.tap()
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        XCTAssertEqual(output.label, "Command output")
    }

    func testDiagnosticsCommandSummaryOmitsDurationWhenTheCommandTruncatesOrAtMaximumText() throws {
        continueAfterFailure = false
        let constrained = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        constrained.launchArguments = ["-diagnostics-fixtures", "-diagnostics-command-narrow"]
        constrained.launch()
        selectDiagnosticFixture("Command", in: constrained)
        let constrainedDetail = anyElement(constrained, identifier: "activity-detail")
        XCTAssertTrue(constrainedDetail.waitForExistence(timeout: 5))
        XCTAssertFalse(anyElement(constrained, identifier: "command-duration:fixture/row").exists)
        XCTAssertTrue(constrainedDetail.label.contains("for 5s"), "Accessibility retains the complete prepared summary")
        retainMenuScreenshot(constrained, name: "Truncated command at 220pt omits visual duration")
        constrained.terminate()

        let largeText = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        largeText.launchArguments = ["-diagnostics-fixtures", "-diagnostics-command-narrow",
                                     "-diagnostics-command-short",
                                     "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        largeText.launch()
        selectDiagnosticFixture("Command", in: largeText)
        let largeDetail = anyElement(largeText, identifier: "activity-detail")
        XCTAssertTrue(largeDetail.waitForExistence(timeout: 5))
        XCTAssertFalse(anyElement(largeText, identifier: "command-duration:fixture/row").exists)
        XCTAssertTrue(largeDetail.label.contains("for 5s"), "Accessibility remains untruncated at maximum text")
        XCTAssertLessThanOrEqual(largeDetail.frame.maxX, largeText.frame.maxX)
        retainMenuScreenshot(largeText, name: "Command maximum Dynamic Type")
    }

    func testDiagnosticsWorkspaceRequestLeavesChatAfterApproval() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-fixtures", "-diagnostics-working-folder"]
        app.launch()

        let status = app.staticTexts["folder-request-status-diagnostic-working-folder"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Approve this folder as the Workspace for the next turn.")
        let path = app.staticTexts["folder-request-path-diagnostic-working-folder"]
        XCTAssertTrue(path.exists)
        XCTAssertLessThanOrEqual(path.frame.maxX, app.frame.maxX)
        retainMenuScreenshot(app, name: "Pending Workspace request")

        app.buttons["folder-request-approve-diagnostic-working-folder"].tap()
        XCTAssertTrue(waitUntilGone(status, timeout: 5))
    }

    func testDiagnosticsWorkspaceRequestFitsAtMaximumTextSize() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = [
            "-diagnostics-fixtures", "-diagnostics-working-folder",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()

        let status = app.staticTexts["folder-request-status-diagnostic-working-folder"]
        let path = app.staticTexts["folder-request-path-diagnostic-working-folder"]
        let approve = app.buttons["folder-request-approve-diagnostic-working-folder"]
        let decline = app.buttons["folder-request-decline-diagnostic-working-folder"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(path.exists)
        XCTAssertTrue(approve.exists)
        XCTAssertTrue(decline.exists)
        for element in [status, path, approve, decline] {
            XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
        }
        XCTAssertGreaterThanOrEqual(decline.frame.minY, approve.frame.minY)
        retainMenuScreenshot(app, name: "Workspace maximum Dynamic Type")
    }

    func testDiagnosticsTurnLifecycleFixtureUsesAuthoritativeStatus() throws {
        continueAfterFailure = false
        // This fixture is intentionally launched with the optimized
        // Diagnostics product identity, not the legacy DEBUG preview target.
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-fixtures"]
        app.launch()

        selectDiagnosticFixture("Turn lifecycle", in: app)

        let completedFirst = app.buttons["activity-group:turn-completed/command"]
        let completedLast = app.buttons["activity-group:turn-completed/search"]
        let activeFirst = app.buttons["activity-group:turn-active/active-command"]
        let activeLast = app.buttons["activity-group:turn-active/active-search"]
        let stopped = app.buttons["activity-group:turn-stopped/stopped-command"]
        let completedCompaction = anyElement(app, identifier: "context-compaction:turn-completed/compact-completed")
        let secondCompletedCompaction = anyElement(app, identifier: "context-compaction:turn-completed/compact-completed-2")
        let runningCompaction = anyElement(app, identifier: "context-compaction:turn-active/compact-running")
        let stoppedCompaction = anyElement(app, identifier: "context-compaction:turn-stopped/compact-stopped")
        XCTAssertTrue(completedFirst.waitForExistence(timeout: 10))
        XCTAssertTrue(completedLast.exists)
        XCTAssertTrue(activeFirst.exists)
        XCTAssertTrue(activeLast.exists)
        XCTAssertTrue(stopped.exists)
        XCTAssertTrue(completedCompaction.exists)
        XCTAssertTrue(secondCompletedCompaction.exists)
        XCTAssertTrue(runningCompaction.exists)
        XCTAssertTrue(stoppedCompaction.exists)
        XCTAssertEqual(completedCompaction.label, "Context compacted")
        XCTAssertEqual(secondCompletedCompaction.label, "Context compacted")
        XCTAssertEqual(runningCompaction.label, "Compacting context…")
        XCTAssertEqual(stoppedCompaction.label, "Context compaction stopped")
        let details = app.descendants(matching: .any).matching(identifier: "activity-detail")
        XCTAssertGreaterThanOrEqual(details.count, 2, "Every visible segment of the active authoritative turn starts expanded")

        XCTAssertEqual(completedFirst.label, "Ran 1 command")
        XCTAssertEqual(completedLast.label, "Worked for 21m 52s")
        XCTAssertEqual(activeFirst.label, "Ran 1 command")
        XCTAssertEqual(activeLast.label, "Working…")
        XCTAssertEqual(stopped.label, "Stopped")
        XCTAssertEqual(activeFirst.value as? String, "Expanded")
        XCTAssertEqual(activeLast.value as? String, "Expanded")
        XCTAssertGreaterThanOrEqual(details.count, 2)

        completedFirst.tap()
        XCTAssertEqual(completedFirst.value as? String, "Expanded")
        XCTAssertTrue(details.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(details.firstMatch.isHittable)
        XCTAssertGreaterThanOrEqual(details.count, 3)
        completedFirst.tap()
        XCTAssertEqual(completedFirst.value as? String, "Collapsed")
        XCTAssertEqual(details.count, 2, "The active turn remains automatically expanded while the completed segment is collapsed")

        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "activity-progress:turn-completed/command").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "activity-progress:turn-active/active-command").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "activity-progress:turn-active/active-search").firstMatch.waitForExistence(timeout: 5))

        // An authoritative terminal transition collapses every segment of
        // that turn; the regular disclosure action can reopen one afterward.
        app.buttons["fixture-complete-active-turn"].tap()
        XCTAssertEqual(activeFirst.value as? String, "Collapsed")
        XCTAssertEqual(activeLast.value as? String, "Collapsed")
        XCTAssertFalse(details.firstMatch.exists)
        activeFirst.tap()
        XCTAssertEqual(activeFirst.value as? String, "Expanded")
        XCTAssertTrue(details.firstMatch.waitForExistence(timeout: 5))
        retainMenuScreenshot(app, name: "Authoritative turn lifecycle fixture")
    }

    func testDiagnosticsCompletedRefreshDoesNotShowStaleStopResponse() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-fixtures", "-diagnostics-stale-active"]
        app.launch()

        let send = app.buttons["send-message"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertEqual(send.label, "Send message")
        XCTAssertFalse(app.buttons["Stop response"].exists)

        let historicalActivity = app.buttons["activity-group:turn-old/old-command"]
        XCTAssertTrue(historicalActivity.waitForExistence(timeout: 5))
        XCTAssertEqual(historicalActivity.value as? String, "Collapsed")
        historicalActivity.tap()
        let expandedHistoricalActivity = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Expanded"),
            object: historicalActivity
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expandedHistoricalActivity], timeout: 3), .completed)
        XCTAssertTrue(anyElement(app, identifier: "activity-detail").waitForExistence(timeout: 5))

        app.buttons["Message actions"].tap()
        XCTAssertFalse(app.buttons["Stop response"].exists)
        retainMenuScreenshot(app, name: "Completed canonical refresh has no stale Stop")
    }

    func testDiagnosticsCompactionMarkersRemainVisibleAroundCollapsedActivity() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-fixtures"]
        app.launch()
        selectDiagnosticFixture("Turn lifecycle", in: app)
        let activeFirst = app.buttons["activity-group:turn-active/active-command"]
        let activeLast = app.buttons["activity-group:turn-active/active-search"]
        XCTAssertTrue(activeFirst.waitForExistence(timeout: 5))
        activeFirst.tap()
        activeLast.tap()
        XCTAssertEqual(activeFirst.value as? String, "Collapsed")
        XCTAssertEqual(activeLast.value as? String, "Collapsed")
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let states = [
            ("turn-completed/compact-completed", "Context compacted"),
            ("turn-completed/compact-completed-2", "Context compacted"),
            ("turn-active/compact-running", "Compacting context…"),
            ("turn-stopped/compact-stopped", "Context compaction stopped"),
            ("turn-failed/compact-failed", "Context compaction failed"),
            ("turn-unknown/compact-unknown", "Context compaction status unavailable")
        ]
        for (id, label) in states {
            let marker = anyElement(app, identifier: "context-compaction:" + id)
            XCTAssertTrue(marker.waitForExistence(timeout: 5))
            let visibleBounds = scroll.frame.insetBy(dx: 0, dy: 5)
            var fullyVisible = false
            for _ in 0..<12 {
                let frame = marker.frame
                if frame.minY >= visibleBounds.minY && frame.maxY <= visibleBounds.maxY {
                    fullyVisible = true
                    break
                }
                if frame.minY < visibleBounds.minY {
                    scroll.swipeDown(velocity: .slow)
                } else if frame.maxY > visibleBounds.maxY {
                    scroll.swipeUp(velocity: .slow)
                } else {
                    break
                }
            }
            fullyVisible = fullyVisible || (marker.frame.minY >= visibleBounds.minY && marker.frame.maxY <= visibleBounds.maxY)
            XCTAssertTrue(fullyVisible, "Compaction marker did not become fully visible within the bounded reveal loop")
            XCTAssertEqual(marker.label, label)
            XCTAssertGreaterThanOrEqual(marker.frame.minY, visibleBounds.minY)
            XCTAssertLessThanOrEqual(marker.frame.maxY, visibleBounds.maxY)
            retainMenuScreenshot(app, name: "Compaction marker " + id)
        }
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "PRIVATE")).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "activity-detail").firstMatch.exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testComposerImagePasteFromLongPressMenuPreservesDraftAndReloads() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-fixtures", "-diagnostics-composer-paste"]
        app.launch()
        let editor = app.textViews["message-draft"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        for index in 0..<10 {
            app.buttons["fixture-copy-image"].tap()
            editor.press(forDuration: 1.2)
            let paste = app.menuItems["Paste"].firstMatch
            XCTAssertTrue(paste.waitForExistence(timeout: 3))
            paste.tap()
            let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "composer-attachment-remove:")).firstMatch
            XCTAssertTrue(remove.waitForExistence(timeout: 5))
            XCTAssertEqual(editor.value as? String, "Keep this draft.")
            XCTAssertEqual(app.staticTexts["camera-draft-count"].label, "Draft attachments: 1")
            if index == 0 {
                retainMenuScreenshot(app, name: "Pasted PNG in composer attachment strip")
                app.buttons["camera-reload-draft"].tap()
                XCTAssertTrue(remove.exists)
                XCTAssertEqual(editor.value as? String, "Keep this draft.")
            }
            remove.tap()
            XCTAssertEqual(app.staticTexts["camera-draft-count"].label, "Draft attachments: 0")
        }
        app.buttons["fixture-copy-text"].tap()
        editor.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        paste.tap()
        XCTAssertTrue((editor.value as? String)?.contains("Pasted text.") == true)
        XCTAssertEqual(app.staticTexts["camera-draft-count"].label, "Draft attachments: 0")
        XCTAssertEqual(app.staticTexts["camera-pending-send"].label, "No pending send")
        XCTAssertEqual(app.staticTexts["camera-draft-transfers"].label, "Local draft only")
    }

    func testComposerAttachmentPreviewLoadsAndRemovesOnlyTheSelectedImage() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-read-preview", "-send-preview", "-composer-attachments-preview"]
        app.launch()

        let photo = anyElement(app, identifier: "composer-attachment:composer-photo")
        let file = anyElement(app, identifier: "composer-attachment:composer-file")
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["message-draft"].waitForExistence(timeout: 5))

        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Loaded"), object: photo)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        assertFullyVisible(photo, in: app)
        // The remove control overlaps the thumbnail's top-right corner while
        // the open-photo button remains a stable 72pt target.
        let openPhoto = app.buttons["composer-attachment-open:composer-photo"]
        let removePhoto = app.buttons["composer-attachment-remove:composer-photo"]
        XCTAssertTrue(openPhoto.waitForExistence(timeout: 5))
        XCTAssertTrue(removePhoto.waitForExistence(timeout: 5))
        XCTAssertEqual(openPhoto.frame.width, 72, accuracy: 8)
        XCTAssertEqual(openPhoto.frame.height, 72, accuracy: 8)
        XCTAssertGreaterThanOrEqual(removePhoto.frame.width, 44)
        XCTAssertGreaterThanOrEqual(removePhoto.frame.height, 44)
        XCTAssertGreaterThanOrEqual(photo.frame.height, 80)
        XCTAssertGreaterThan(removePhoto.frame.midX, openPhoto.frame.midX)
        XCTAssertLessThan(removePhoto.frame.midY, openPhoto.frame.midY)
        XCTAssertTrue(file.frame.height >= 44)
        XCTAssertEqual(app.textViews["message-draft"].value as? String, "Keep the evening free too.")
        retainMenuScreenshot(app, name: "Composer attachments loaded (iPhone/iPad)")

        openPhoto.tap()
        retainMenuScreenshot(app, name: "Composer photo viewer after open")
        XCTAssertTrue(anyElement(app, identifier: "photo-viewer-image:composer-photo").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["photo-viewer-close"].isHittable)
        app.buttons["photo-viewer-close"].tap()
        XCTAssertTrue(photo.exists)

        XCTAssertTrue(removePhoto.waitForExistence(timeout: 5))
        assertFullyVisible(removePhoto, in: app)
        XCTAssertTrue(removePhoto.isEnabled)
        removePhoto.tap()

        XCTAssertTrue(waitUntilGone(photo, timeout: 5))
        XCTAssertTrue(file.exists)
        XCTAssertTrue(app.textViews["message-draft"].exists)
        XCTAssertEqual(app.textViews["message-draft"].value as? String, "Keep the evening free too.")
        retainMenuScreenshot(app, name: "Composer file retained after photo removal")
    }

    func testSentMessageAttachmentsShowAboveTextAndSwipeConversationImages() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-read-preview", "-send-preview", "-message-attachments-preview"]
        app.launch()

        let first = app.buttons["message-attachment-open:message-image-1"]
        let second = app.buttons["message-attachment-open:message-image-2"]
        let document = app.buttons["message-attachment-file:message-notes"]
        let message = app.staticTexts["Here are the reference images and notes."]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        XCTAssertTrue(document.waitForExistence(timeout: 10))
        XCTAssertTrue(message.waitForExistence(timeout: 10))

        let firstLoaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Loaded"), object: first)
        let secondLoaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Loaded"), object: second)
        XCTAssertEqual(XCTWaiter.wait(for: [firstLoaded, secondLoaded], timeout: 10), .completed)
        XCTAssertLessThan(first.frame.maxY, message.frame.minY)
        XCTAssertLessThan(second.frame.maxY, message.frame.minY)
        XCTAssertGreaterThanOrEqual(first.frame.width, 64)
        XCTAssertGreaterThanOrEqual(first.frame.height, 64)
        retainMenuScreenshot(app, name: "Sent message attachment thumbnails above text")

        first.tap()
        let imageOne = app.descendants(matching: .any).matching(identifier: "photo-viewer-image:message-image-1").firstMatch
        XCTAssertTrue(imageOne.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1 of 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["photo-viewer-close"].isHittable)
        retainMenuScreenshot(app, name: "Conversation photo viewer image one")

        imageOne.swipeLeft(velocity: .slow)
        let imageTwo = app.descendants(matching: .any).matching(identifier: "photo-viewer-image:message-image-2").firstMatch
        XCTAssertTrue(imageTwo.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2 of 2"].waitForExistence(timeout: 5))
        retainMenuScreenshot(app, name: "Conversation photo viewer image two")
        app.buttons["photo-viewer-close"].tap()

        document.tap()
        let documentRow = app.buttons["workspace-attachment:message-notes"]
        XCTAssertTrue(documentRow.waitForExistence(timeout: 10))
        documentRow.tap()
        XCTAssertTrue(app.buttons["workspace-document-close"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["reference-notes.txt"].exists)
        retainMenuScreenshot(app, name: "Conversation document routed separately")
        app.buttons["workspace-document-close"].tap()
        XCTAssertTrue(documentRow.waitForExistence(timeout: 5))
    }

    func testRestoredComposerAttachmentsShowLoadedAndMissingStatesAndCanBeRemoved() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-read-preview", "-send-preview", "-composer-restored-attachments-preview"]
        app.launch()

        let restored = anyElement(app, identifier: "composer-attachment:restored-photo")
        let missing = anyElement(app, identifier: "composer-attachment:missing-restored-file")
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertTrue(missing.waitForExistence(timeout: 5))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Loaded"), object: restored)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        assertFullyVisible(restored, in: app)
        let restoredOpen = app.buttons["composer-attachment-open:restored-photo"]
        XCTAssertTrue(restoredOpen.waitForExistence(timeout: 5))
        XCTAssertEqual(restoredOpen.frame.width, 72, accuracy: 8)
        XCTAssertEqual(restoredOpen.frame.height, 72, accuracy: 8)
        XCTAssertGreaterThanOrEqual(restored.frame.height, 80)
        let restoredRemove = app.buttons["composer-attachment-remove:restored-photo"]
        XCTAssertTrue(restoredRemove.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(restoredRemove.frame.midX, restoredOpen.frame.midX)
        XCTAssertLessThan(restoredRemove.frame.midY, restoredOpen.frame.midY)
        XCTAssertTrue(missing.frame.height >= 44)
        retainMenuScreenshot(app, name: "Restored attachment with missing fallback")

        let removeMissing = app.buttons["composer-attachment-remove:missing-restored-file"]
        XCTAssertTrue(removeMissing.waitForExistence(timeout: 5))
        assertFullyVisible(removeMissing, in: app)
        removeMissing.tap()
        XCTAssertTrue(waitUntilGone(missing, timeout: 5))
        XCTAssertTrue(restored.exists)

        let removeRestored = app.buttons["composer-attachment-remove:restored-photo"]
        XCTAssertTrue(removeRestored.waitForExistence(timeout: 5))
        assertFullyVisible(removeRestored, in: app)
        removeRestored.tap()
        XCTAssertTrue(waitUntilGone(restored, timeout: 5))
        XCTAssertFalse(anyElement(app, identifier: "composer-attachments").exists)
        XCTAssertEqual(app.textViews["message-draft"].value as? String, "Keep the evening free too.")
        retainMenuScreenshot(app, name: "Restored attachments removed with draft retained")
    }

    func testDiagnosticsAttachmentFixtureUsesStripAndKeepsFileAfterPhotoRemoval() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-fixtures"]
        app.launch()
        selectDiagnosticFixture("Attachments", in: app)

        let photo = anyElement(app, identifier: "composer-attachment:diagnostics-composer-photo")
        let file = anyElement(app, identifier: "composer-attachment:diagnostics-composer-file")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Loaded"), object: photo)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        assertFullyVisible(photo, in: app)
        let openPhoto = app.buttons["composer-attachment-open:diagnostics-composer-photo"]
        XCTAssertTrue(openPhoto.waitForExistence(timeout: 5))
        XCTAssertEqual(openPhoto.frame.width, 72, accuracy: 8)
        XCTAssertEqual(openPhoto.frame.height, 72, accuracy: 8)
        XCTAssertGreaterThanOrEqual(photo.frame.height, 80)
        let diagnosticRemove = app.buttons["composer-attachment-remove:diagnostics-composer-photo"]
        XCTAssertTrue(diagnosticRemove.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(diagnosticRemove.frame.midX, openPhoto.frame.midX)
        XCTAssertLessThan(diagnosticRemove.frame.midY, openPhoto.frame.midY)
        retainMenuScreenshot(app, name: "Diagnostics local attachment fixture")

        let remove = app.buttons["composer-attachment-remove:diagnostics-composer-photo"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        assertFullyVisible(remove, in: app)
        remove.tap()
        XCTAssertTrue(waitUntilGone(photo, timeout: 5))
        XCTAssertTrue(file.exists)
        retainMenuScreenshot(app, name: "Diagnostics file retained after photo removal")
    }

    func testComposerRunningAndQueuedFixturesExposeSafeControls() throws {
        continueAfterFailure = false
        let cases: [[String]] = [
            ["-read-preview", "-send-preview", "-composer-running-preview"],
            ["-read-preview", "-send-preview", "-composer-queued-preview"]
        ]
        for arguments in cases {
            let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
            app.launchArguments = arguments
            app.launch()
            if arguments.contains("-composer-running-preview") {
                let stop = app.buttons["Stop response"]
                XCTAssertTrue(stop.waitForExistence(timeout: 10))
                XCTAssertFalse(stop.isEnabled, "Preview mode must not issue a stop request")
                XCTAssertTrue(app.buttons["Message actions"].exists)
                retainMenuScreenshot(app, name: "Running composer controls")
            } else {
                let queued = app.descendants(matching: .any).matching(
                    NSPredicate(format: "label CONTAINS %@", "Queued message: Find a walking route")
                ).firstMatch
                let queuedWithAttachments = app.descendants(matching: .any).matching(
                    NSPredicate(format: "label CONTAINS %@", "Queued message: Summarize the plan")
                ).firstMatch
                XCTAssertTrue(queued.waitForExistence(timeout: 10))
                XCTAssertTrue(queuedWithAttachments.waitForExistence(timeout: 10))
                XCTAssertTrue(app.staticTexts["Queued"].exists)
                let composer = app.textViews["message-draft"]
                XCTAssertTrue(composer.waitForExistence(timeout: 5))
                XCTAssertLessThanOrEqual(queued.frame.maxY, composer.frame.minY,
                                         "The queued message belongs to the timeline above the floating composer.")

                let scroll = app.scrollViews.firstMatch
                for _ in 0..<8 {
                    let bounds = scroll.frame.insetBy(dx: 0, dy: 5)
                    if queuedWithAttachments.frame.minY >= bounds.minY && queuedWithAttachments.frame.maxY <= bounds.maxY { break }
                    if queuedWithAttachments.frame.minY < bounds.minY {
                        scroll.swipeDown(velocity: .slow)
                    } else {
                        scroll.swipeUp(velocity: .slow)
                    }
                }
                assertFullyVisible(queuedWithAttachments, in: app)
                let queuedText = app.staticTexts["Summarize the plan in the attached notes."]
                let queuedImage = app.buttons["message-attachment-open:Saturday.png"]
                let queuedDocument = app.buttons["message-attachment-file:notes.txt"]
                XCTAssertTrue(queuedText.waitForExistence(timeout: 5))
                XCTAssertTrue(queuedImage.waitForExistence(timeout: 5))
                XCTAssertTrue(queuedDocument.waitForExistence(timeout: 5))
                XCTAssertFalse(app.staticTexts["2 attachments"].exists,
                               "Queued attachments render their actual previews instead of a paperclip count.")
                let queuedImageLoaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Loaded"), object: queuedImage)
                XCTAssertEqual(XCTWaiter.wait(for: [queuedImageLoaded], timeout: 10), .completed)
                XCTAssertLessThan(queuedImage.frame.maxY, queuedText.frame.minY,
                                  "Queued attachment previews belong above the queued message text.")
                XCTAssertGreaterThanOrEqual(queuedImage.frame.width, 64)
                XCTAssertGreaterThanOrEqual(queuedImage.frame.height, 64)
                retainMenuScreenshot(app, name: "Queued timeline row above floating composer")

                queuedImage.tap()
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "photo-viewer-image:Saturday.png").firstMatch.waitForExistence(timeout: 10))
                XCTAssertTrue(app.buttons["photo-viewer-close"].waitForExistence(timeout: 5))
                retainMenuScreenshot(app, name: "Queued image attachment viewer")
                app.buttons["photo-viewer-close"].tap()
                queuedDocument.tap()
                let queuedDocumentRow = app.buttons["workspace-attachment:notes.txt"]
                XCTAssertTrue(queuedDocumentRow.waitForExistence(timeout: 10))
                queuedDocumentRow.tap()
                XCTAssertTrue(app.buttons["workspace-document-close"].waitForExistence(timeout: 10))
                XCTAssertTrue(app.staticTexts["notes.txt"].exists)
                retainMenuScreenshot(app, name: "Queued document attachment route")
                app.buttons["workspace-document-close"].tap()
                let workspaceAttachment = app.buttons["workspace-attachment:notes.txt"]
                XCTAssertTrue(workspaceAttachment.waitForExistence(timeout: 5),
                              "Closing the document preview returns to the Files attachment row.")
                let workspaceClose = app.buttons["workspace-close"]
                XCTAssertTrue(workspaceClose.waitForExistence(timeout: 5),
                              "The Files sheet remains explicitly dismissible after closing a document preview.")
                workspaceClose.tap()
                XCTAssertTrue(queuedWithAttachments.waitForExistence(timeout: 5),
                              "Dismissing Files returns to the queued conversation row.")

                let conversationViewport = scroll.frame.insetBy(dx: 0, dy: 8)
                let rowsLeftViewport = { (row: XCUIElement) in
                    // LazyVStack removes a row from the accessibility tree after it
                    // leaves the viewport; that is itself an unambiguous off-screen state.
                    guard row.exists else { return true }
                    let frame = row.frame
                    return frame.isEmpty || frame.maxY <= conversationViewport.minY || frame.minY >= conversationViewport.maxY
                }
                var bothRowsLeftViewport = false
                for _ in 0..<3 {
                    if rowsLeftViewport(queued) && rowsLeftViewport(queuedWithAttachments) {
                        bothRowsLeftViewport = true
                        break
                    }
                    let dragStart = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                    let dragEnd = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                    dragStart.press(forDuration: 0.1, thenDragTo: dragEnd,
                                    withVelocity: .slow, thenHoldForDuration: 0.1)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
                bothRowsLeftViewport = bothRowsLeftViewport ||
                    (rowsLeftViewport(queued) && rowsLeftViewport(queuedWithAttachments))
                XCTAssertTrue(bothRowsLeftViewport,
                              "Both queued rows should scroll outside the visible conversation viewport.")
                let bottom = app.buttons["scroll-to-bottom"]
                XCTAssertTrue(bottom.waitForExistence(timeout: 5))
                bottom.tap()
                XCTAssertTrue(queued.waitForExistence(timeout: 5))
                assertFullyVisible(queuedWithAttachments, in: app)
                retainMenuScreenshot(app, name: "Queued timeline row restored at bottom")
            }
            app.terminate()
        }
    }

    func testNewBotWaitsForPurposeQuestionBeforeShowingComposer() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        for waiting in [true, false] {
            app.launchArguments = ["-read-preview", "-onboarding-preview"] + (waiting ? ["-onboarding-loading-preview"] : [])
            app.launch()
            let chat = app.staticTexts["Luna"].firstMatch
            XCTAssertTrue(chat.waitForExistence(timeout: 10))
            chat.tap()
            let header = app.otherElements["conversation-avatar-header"]
            XCTAssertTrue(header.waitForExistence(timeout: 10))
            XCTAssertTrue(header.label.contains("Luna character, Ocean palette"))
            if waiting {
                let progress = app.activityIndicators["bot-initialization-progress"]
                XCTAssertTrue(progress.waitForExistence(timeout: 5))
                let conversationBar = app.navigationBars.containing(.other, identifier: "conversation-avatar-header").firstMatch
                XCTAssertTrue(conversationBar.exists)
                let navigation = conversationBar.frame
                // iPad's detail navigation bar spans behind the floating sidebar.
                let sidebar = app.collectionViews["Sidebar"]
                let leading = sidebar.exists && sidebar.frame.intersects(app.frame) && sidebar.frame.maxX < header.frame.midX
                    ? sidebar.frame.maxX : navigation.minX
                let area = CGRect(x: leading, y: navigation.maxY, width: navigation.maxX - leading,
                                  height: app.frame.maxY - navigation.maxY)
                XCTAssertEqual(progress.frame.midX, area.midX, accuracy: 3)
                XCTAssertEqual(progress.frame.midY, area.midY, accuracy: 30)
                XCTAssertFalse(app.textViews["Message Luna"].exists)
                XCTAssertFalse(app.buttons["Send message"].exists)
            } else {
                XCTAssertTrue(app.staticTexts["What should I help with?"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.textViews["Message Luna"].exists)
                XCTAssertTrue(app.buttons["Skip"].exists)
                XCTAssertFalse(app.activityIndicators["bot-initialization-progress"].exists)
            }
            retainMenuScreenshot(app, name: waiting ? "Bot preparing" : "Bot first question ready")
            app.terminate()
        }
    }

    func testBotSettingsUsesCompactAvatarSection() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-read-status"]
        app.launch()
        let chat = app.buttons["chat-row:fixture-parent-conversation"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.tap()
        let details = app.buttons["Conversation details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        details.tap()
        let settings = app.buttons["Bot settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.textFields["bot-name"].waitForExistence(timeout: 10))
        let characters = app.scrollViews["science-avatar-character-row"]
        let colors = app.scrollViews["science-avatar-color-row"]
        XCTAssertTrue(characters.waitForExistence(timeout: 10))
        XCTAssertTrue(colors.exists)
        XCTAssertFalse(app.images["science-avatar-preview"].exists)
        XCTAssertFalse(app.staticTexts["Character"].exists)
        XCTAssertFalse(app.staticTexts["Palette"].exists)
        XCTAssertLessThan(characters.frame.height + colors.frame.height, 210)
        XCTAssertEqual(app.buttons["science-avatar-shape-luna"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["science-avatar-palette-ocean"].value as? String, "Selected")
        retainMenuScreenshot(app, name: "Bot settings compact Avatar section")
    }

    func testBotAvatarSettingsMatchSavedIdentityAndSaveAcrossRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        let arguments = ["-diagnostics-subagent-fixture", "-diagnostics-avatar-settings"]
        app.launchArguments = arguments + ["-diagnostics-avatar-settings-reset"]

        func openChat() {
            let chat = app.buttons["chat-row:fixture-parent-conversation"]
            XCTAssertTrue(chat.waitForExistence(timeout: 10))
            chat.tap()
            XCTAssertTrue(app.buttons["Conversation details"].waitForExistence(timeout: 10))
        }
        func checkHeader(_ identity: String) {
            let header = app.descendants(matching: .any)["conversation-avatar-header"].firstMatch
            let matches = NSPredicate(format: "label CONTAINS %@", identity)
            XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: header)], timeout: 10) == .completed)
        }
        func openSettings(shape: String, palette: String) {
            app.buttons["Conversation details"].tap()
            let settings = app.buttons["Bot settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            settings.tap()
            XCTAssertTrue(app.textFields["bot-name"].waitForExistence(timeout: 10))
            for id in ["science-avatar-shape-" + shape, "science-avatar-palette-" + palette] {
                let selected = app.buttons[id]
                XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected"), object: selected)], timeout: 5) == .completed)
            }
        }
        func select(_ id: String, rowID: String) {
            let target = app.buttons[id]
            let row = app.scrollViews[rowID]
            for _ in 0..<12 {
                if target.isHittable && target.frame.minX >= row.frame.minX && target.frame.maxX <= row.frame.maxX { break }
                if target.frame.midX < row.frame.midX { row.swipeRight(velocity: .slow) }
                else { row.swipeLeft(velocity: .slow) }
            }
            XCTAssertTrue(target.isHittable)
            target.tap()
            XCTAssertEqual(target.value as? String, "Selected")
        }
        func save() {
            let button = app.buttons["save-bot"]
            XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)], timeout: 10) == .completed)
            button.tap()
        }

        app.launch()
        openChat()
        checkHeader("Luna character, Ocean palette")
        // The seeded unrelated draft has stale Sun/Amber values but no avatar edits.
        openSettings(shape: "luna", palette: "ocean")
        select("science-avatar-shape-atom", rowID: "science-avatar-character-row")
        save() // A host conflict must be visible without scrolling the settings form.
        let saveFailure = app.alerts["Couldn’t save Bot"]
        XCTAssertTrue(saveFailure.waitForExistence(timeout: 5))
        XCTAssertTrue(saveFailure.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This change is blocked")).firstMatch.exists)
        retainMenuScreenshot(app, name: "Avatar save conflict is immediately visible")
        saveFailure.buttons["OK"].tap()
        XCTAssertEqual(app.buttons["science-avatar-shape-atom"].value as? String, "Selected")
        app.terminate()

        app.launchArguments = arguments
        app.launch()
        openChat()
        checkHeader("Luna character, Ocean palette")
        openSettings(shape: "atom", palette: "ocean")
        save()
        XCTAssertTrue(waitUntilGone(app.textFields["bot-name"], timeout: 10))
        checkHeader("Atom character, Ocean palette")
        openSettings(shape: "atom", palette: "ocean")
        select("science-avatar-palette-rose", rowID: "science-avatar-color-row")
        save()
        XCTAssertTrue(waitUntilGone(app.textFields["bot-name"], timeout: 10))
        checkHeader("Atom character, Rose palette")
        app.terminate()

        app.launch()
        openChat()
        checkHeader("Atom character, Rose palette")
        openSettings(shape: "atom", palette: "rose")
        retainMenuScreenshot(app, name: "Saved Bot avatar matches settings after relaunch")
        app.terminate()
    }

    func testDiagnosticsScienceAvatarsSelectPersistAndExposeMotionStates() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-avatar-fixture", "-diagnostics-avatar-reset"]
        app.launch()

        let preview = app.images["science-avatar-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let shapes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "science-avatar-shape-"))
        let palettes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "science-avatar-palette-"))
        XCTAssertEqual(shapes.count, 7)
        XCTAssertEqual(palettes.count, 12)
        let characterRow = app.scrollViews["science-avatar-character-row"]
        let colorRow = app.scrollViews["science-avatar-color-row"]
        XCTAssertTrue(characterRow.exists)
        XCTAssertTrue(colorRow.exists)
        XCTAssertFalse(app.staticTexts["Character"].exists)
        XCTAssertFalse(app.staticTexts["Palette"].exists)
        XCTAssertLessThanOrEqual(colorRow.frame.height, 48)
        retainMenuScreenshot(app, name: "Compact avatar rows")

        func reveal(_ target: XCUIElement, in row: XCUIElement) {
            for _ in 0..<12 {
                if target.isHittable && target.frame.minX >= row.frame.minX && target.frame.maxX <= row.frame.maxX { return }
                row.swipeLeft(velocity: .slow)
            }
            XCTFail("Could not reveal \(target.identifier) in its horizontal row")
        }
        let luna = app.buttons["science-avatar-shape-luna"]
        let ocean = app.buttons["science-avatar-palette-ocean"]
        reveal(luna, in: characterRow)
        XCTAssertTrue(luna.label.contains("Luna character"))
        XCTAssertTrue(luna.label.contains("Amber palette"))
        XCTAssertEqual(luna.value as? String, "Not selected")
        luna.tap()
        reveal(ocean, in: colorRow)
        XCTAssertEqual(ocean.frame.width, 44, accuracy: 0.5)
        XCTAssertEqual(ocean.frame.height, 44, accuracy: 0.5)
        XCTAssertEqual(ocean.label, "Ocean color")
        ocean.tap()
        XCTAssertEqual(luna.value as? String, "Selected")
        XCTAssertTrue(luna.label.contains("Ocean palette"))
        XCTAssertEqual(ocean.value as? String, "Selected")
        retainMenuScreenshot(app, name: "Selected Luna and Ocean in compact rows")

        let motionPicker = app.buttons["science-avatar-motion-picker"]
        XCTAssertTrue(motionPicker.waitForExistence(timeout: 5))
        let fixtureScroll = app.scrollViews["science-avatar-fixture-scroll"]
        for _ in 0..<6 {
            if motionPicker.isHittable { break }
            fixtureScroll.swipeUp(velocity: .slow)
        }
        motionPicker.tap()
        let working = app.buttons["Working"]
        XCTAssertTrue(working.waitForExistence(timeout: 5))
        working.tap()
        retainMenuScreenshot(app, name: "Science avatars Luna Ocean Working")

        let saveAvatar = app.buttons["science-avatar-save"]
        for _ in 0..<6 {
            if saveAvatar.isHittable { break }
            fixtureScroll.swipeUp(velocity: .slow)
        }
        saveAvatar.tap()
        let payload = app.staticTexts["science-avatar-saved-payload"]
        XCTAssertTrue(payload.label.contains("avatarShape"))
        XCTAssertTrue(payload.label.contains("luna"))
        XCTAssertTrue(payload.label.contains("avatarPalette"))
        XCTAssertTrue(payload.label.contains("ocean"))
        XCTAssertFalse(payload.label.contains("avatarColor"))
        app.terminate()

        let relaunched = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        relaunched.launchArguments = ["-diagnostics-avatar-fixture"]
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["science-avatar-shape-luna"].waitForExistence(timeout: 10))
        XCTAssertEqual(relaunched.buttons["science-avatar-shape-luna"].value as? String, "Selected")
        XCTAssertEqual(relaunched.buttons["science-avatar-palette-ocean"].value as? String, "Selected")
        XCTAssertTrue(relaunched.staticTexts["science-avatar-saved-payload"].label.contains("luna"))
        relaunched.terminate()
    }

    func testDiagnosticsApprovalPickerUsesThreeChoicesPersistsAndShowsOldHostState() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-fixtures", "-diagnostics-permission-fixture", "-diagnostics-permission-reset"]
        app.launch()
        let picker = app.buttons["diagnostic-approval-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        XCTAssertTrue(app.buttons["approval-choice-ask-for-approval"].exists)
        let automatic = app.buttons["approval-choice-approve-for-me"]
        XCTAssertTrue(automatic.exists)
        XCTAssertFalse(automatic.isEnabled)
        XCTAssertTrue(app.buttons["approval-choice-full-access"].exists)
        retainMenuScreenshot(app, name: "Approval choices with unavailable automatic review")
        app.buttons["approval-choice-full-access"].tap()
        XCTAssertEqual(picker.value as? String, "Full access")
        app.buttons["diagnostic-approval-save"].tap()
        XCTAssertEqual(app.staticTexts["diagnostic-approval-saved"].label, "Full access")
        app.terminate()

        let relaunched = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        relaunched.launchArguments = ["-diagnostics-fixtures", "-diagnostics-permission-fixture"]
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["diagnostic-approval-picker"].waitForExistence(timeout: 10))
        XCTAssertEqual(relaunched.buttons["diagnostic-approval-picker"].value as? String, "Full access")
        relaunched.terminate()

        let oldHost = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        oldHost.launchArguments = ["-diagnostics-fixtures", "-diagnostics-permission-fixture", "-diagnostics-permission-old-host", "-diagnostics-permission-reset"]
        oldHost.launch()
        XCTAssertTrue(oldHost.staticTexts["Update Wonder on your Mac to change approval settings."].waitForExistence(timeout: 10))
        XCTAssertFalse(oldHost.buttons["diagnostic-approval-picker"].isEnabled)
        oldHost.terminate()
    }

    func testDiagnosticsAllApprovalChoicesSaveAndReload() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-fixtures", "-diagnostics-permission-fixture", "-diagnostics-permission-auto-available", "-diagnostics-permission-reset"]
        app.launch()
        let picker = app.buttons["diagnostic-approval-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        for (id, title) in [("full-access", "Full access"), ("ask-for-approval", "Ask for approval"), ("approve-for-me", "Approve for me")] {
            picker.tap()
            let choice = app.buttons["approval-choice-" + id]
            XCTAssertTrue(choice.isEnabled)
            retainMenuScreenshot(app, name: "Approval menu before " + title)
            choice.tap()
            XCTAssertEqual(picker.value as? String, title)
            XCTAssertEqual(app.staticTexts["diagnostic-approval-saved"].label, title)
            app.buttons["diagnostic-approval-reload"].tap()
            XCTAssertEqual(picker.value as? String, title)
        }
        app.terminate()
        app.launchArguments.removeAll { $0 == "-diagnostics-permission-reset" }
        app.launch()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertEqual(picker.value as? String, "Approve for me")
        retainMenuScreenshot(app, name: "Automatic approval persisted after relaunch")
        app.terminate()
    }

    private func anyElement(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func liveChatRowIdentifiers(_ app: XCUIApplication) -> Set<String> {
        Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-row:")).allElementsBoundByIndex.map(\.identifier))
    }

    private func assertFullyVisible(_ element: XCUIElement, in app: XCUIApplication, bottomInset: CGFloat = 8) {
        let screen = app.frame
        XCTAssertTrue(element.isHittable)
        XCTAssertGreaterThanOrEqual(element.frame.minY, screen.minY)
        XCTAssertLessThanOrEqual(element.frame.maxY, screen.maxY - bottomInset)
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !element.exists }, object: nil)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    /// New Bot creation opens its direct chat before the hidden initialization
    /// turn is necessarily archivable. Retry only the exact created row after
    /// the server's busy/409 response; never fall back to another row.
    private func archiveExactNewBotRow(_ row: XCUIElement, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !row.exists { return true }
            row.press(forDuration: 0.8)
            let archive = app.buttons["Archive"]
            guard archive.waitForExistence(timeout: 5) else { continue }
            guard archive.isEnabled else {
                RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(1)))
                continue
            }
            archive.tap()

            let actionDeadline = min(deadline, Date().addingTimeInterval(12))
            while Date() < actionDeadline {
                if !row.exists { return true }
                let alert = app.alerts.firstMatch
                if alert.exists {
                    let text = ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label))
                        .joined(separator: " ").lowercased()
                    let busyInitialization = text.contains("couldn’t update chat") ||
                        text.contains("couldn't update chat") || text.contains("finish or stop") ||
                        text.contains("initial") || text.contains("queue") || text.contains("working")
                    guard busyInitialization else { return false }
                    let ok = alert.buttons["OK"]
                    if ok.exists { ok.tap() } else if alert.buttons.firstMatch.exists { alert.buttons.firstMatch.tap() }
                    RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(1)))
                    break
                }
                RunLoop.current.run(until: min(actionDeadline, Date().addingTimeInterval(0.25)))
            }
        }
        return !row.exists
    }

    func testPairForLiveRun() throws {
        continueAfterFailure = false
        guard let link = ProcessInfo.processInfo.environment["WONDER_PAIRING_LINK"] else { throw XCTSkip("No explicit pairing offer supplied.") }
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-show-connections"]
        app.launch()
        app.buttons["Add computer"].tap()
        let field = app.textFields["Or paste pairing link"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(link)
        app.buttons["Connect to computer"].tap()
        let verification = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Verification text ")).firstMatch
        XCTAssertTrue(verification.waitForExistence(timeout: 15), "The phone must expose the verification text before Mac confirmation.")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.buttons["Stop pairing"].exists && !field.exists
        }, object: nil)], timeout: 60), .completed)
        XCTAssertTrue(app.buttons["Add computer"].isHittable)
        retainMenuScreenshot(app, name: "Physical pairing completed")
    }

    func testPhysicalPairingRelaunchRenewsAndReadsExistingChats() throws {
        continueAfterFailure = false
        guard let host = ProcessInfo.processInfo.environment["WONDER_PAIRING_HOST_NAME"] else { throw XCTSkip("An explicit paired host is required.") }
        guard let qaRowID = ProcessInfo.processInfo.environment["WONDER_PAIRING_QA_CONVERSATION_ID"],
              qaRowID.hasPrefix("chat-row:"), qaRowID.count > "chat-row:".count else {
            throw XCTSkip("Supply WONDER_PAIRING_QA_CONVERSATION_ID with the exact dedicated QA chat-row accessibility identifier.")
        }
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-show-connections"]
        for pass in 0..<2 {
            app.launch()
            let computer = app.buttons[host]
            XCTAssertTrue(computer.waitForExistence(timeout: 15))
            computer.tap()
            let check = app.buttons["Check connection"]
            XCTAssertTrue(check.waitForExistence(timeout: 10))
            check.tap()
            let connected = app.staticTexts["Connected to your computer."]
            XCTAssertTrue(connected.waitForExistence(timeout: 20))
            XCTAssertFalse(app.buttons["Pair again"].exists)
            app.tabBars.buttons["Chats"].tap()
            let chat = app.buttons.matching(identifier: qaRowID).firstMatch
            XCTAssertTrue(chat.waitForExistence(timeout: 20))
            chat.tap()
            XCTAssertTrue(app.buttons["Conversation details"].waitForExistence(timeout: 15))
            // Only the explicitly selected QA conversation is read; no message is submitted.
            retainMenuScreenshot(app, name: "Physical paired conversation after launch \(pass + 1)")
            app.terminate()
        }
    }

    func testDiagnosticsCodexUsageIsInlineInConnectionSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-connections-preview", "-diagnostics-usage-fixture", "-show-connections"]
        app.launch()

        let studio = app.buttons["Studio"]
        XCTAssertTrue(studio.waitForExistence(timeout: 10))
        studio.tap()

        let heading = app.staticTexts["Codex usage"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        let fiveHours = app.descendants(matching: .any).matching(identifier: "codex-usage-window:five-hours").firstMatch
        let weekly = app.descendants(matching: .any).matching(identifier: "codex-usage-window:weekly").firstMatch
        XCTAssertTrue(fiveHours.waitForExistence(timeout: 10))
        XCTAssertTrue(weekly.waitForExistence(timeout: 10))
        XCTAssertEqual(fiveHours.label, "5 hours")
        XCTAssertEqual(fiveHours.value as? String, "73% left")
        XCTAssertEqual(weekly.label, "Weekly")
        XCTAssertEqual(weekly.value as? String, "59% left")
        XCTAssertFalse(app.navigationBars["Codex usage"].exists, "Codex usage must remain inline, not a navigation destination")
        XCTAssertTrue(app.switches["connection-notifications"].exists)
        XCTAssertTrue(app.switches["connection-notifications"].isEnabled)
        retainMenuScreenshot(app, name: "Codex usage inline settings")
    }

    func testPhysicalNewBotCreationOpensAndArchivesExactChat() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = []
        app.launch()
        var createdRowID: String?
        var cleanupCompleted = false
        var creationStarted: Date?
        var creationElapsed: TimeInterval?
        var creationOutcome = "Not started"
        defer {
            if let creationStarted {
                let elapsed = creationElapsed ?? Date().timeIntervalSince(creationStarted)
                let attachment = XCTAttachment(string: "Outcome: \(creationOutcome)\nNew chat tap-to-outcome: \(String(format: "%.3f", elapsed)) seconds")
                attachment.name = "New Bot creation outcome"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            if let createdRowID, !cleanupCompleted {
                if !app.buttons[createdRowID].exists {
                    let back = app.navigationBars.buttons.firstMatch
                    if back.exists { back.tap() }
                }
                let row = app.buttons[createdRowID]
                if row.waitForExistence(timeout: 5) {
                    cleanupCompleted = archiveExactNewBotRow(row, app: app, timeout: 90)
                }
            }
            app.terminate()
        }

        let newChatMenu = app.buttons.matching(NSPredicate(format: "label == %@", "New chat and requests")).firstMatch
        guard newChatMenu.waitForExistence(timeout: 20) else {
            if app.buttons["Add computer"].waitForExistence(timeout: 3) || app.staticTexts["Add a computer in Settings"].exists {
                throw XCTSkip("Requires an existing paired Mac connection.")
            }
            XCTFail("The paired Diagnostics Chats UI did not appear.")
            return
        }

        let existingRowIDs = liveChatRowIdentifiers(app)
        let connectedHostLabels = Set(app.buttons.allElementsBoundByIndex.compactMap { button -> String? in
            guard button.isEnabled, (button.value as? String) == "Connected", !button.label.isEmpty else { return nil }
            return button.label
        })
        retainMenuScreenshot(app, name: "Physical New Bot before create")
        guard newChatMenu.isEnabled else {
            XCTFail("The Chats New Bot menu is unavailable because the paired Mac is not connected.")
            return
        }

        let started = Date()
        creationStarted = started
        newChatMenu.tap()
        let newBot = app.buttons["New Bot"]
        if !newBot.waitForExistence(timeout: 1) {
            retainMenuScreenshot(app, name: "Physical New Bot host picker")
            let hostButtons = app.buttons.allElementsBoundByIndex.filter { button in
                button.isEnabled && button.isHittable && connectedHostLabels.contains(button.label)
                    && ((button.value as? String) ?? "").isEmpty
            }
            guard hostButtons.count == 1 else {
                creationOutcome = "Failed to select the connected host submenu"
                creationElapsed = Date().timeIntervalSince(started)
                XCTFail("Expected one enabled connected-host submenu, found \(hostButtons.count).")
                return
            }
            hostButtons[0].tap()
            guard newBot.waitForExistence(timeout: 5), newBot.isEnabled, newBot.isHittable else {
                creationOutcome = "Connected host submenu did not expose New Bot"
                creationElapsed = Date().timeIntervalSince(started)
                XCTFail("The connected host submenu did not expose a hittable New Bot action.")
                return
            }
        }
        XCTAssertTrue(newBot.isEnabled, "The resolved New Bot action is disabled.")
        XCTAssertTrue(newBot.isHittable, "The resolved New Bot action is not hittable.")
        newBot.tap()

        let header = anyElement(app, identifier: "conversation-avatar-header")
        let composer = app.textViews["message-draft"]
        let deadline = Date().addingTimeInterval(60)
        let progress = app.descendants(matching: .any).matching(identifier: "new-bot-progress").firstMatch
        var sawProgress = false
        var opened = false
        while Date() < deadline {
            if header.exists && composer.exists {
                opened = true
                creationOutcome = "Conversation opened"
                creationElapsed = Date().timeIntervalSince(started)
                break
            }
            if progress.exists || app.staticTexts["Creating Bot…"].exists {
                sawProgress = true
                creationOutcome = "Creation progress visible"
            }
            if app.alerts.firstMatch.exists {
                creationOutcome = "Creation alert appeared"
                creationElapsed = Date().timeIntervalSince(started)
                break
            }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.25)))
        }

        XCTAssertTrue(sawProgress || opened, "New Bot creation did not expose progress before the conversation opened.")
        guard opened else {
            let alert = app.alerts.firstMatch
            if alert.exists {
                retainMenuScreenshot(app, name: "Physical New Bot creation failure")
                let message = alert.staticTexts.allElementsBoundByIndex
                    .map(\.label)
                    .filter { !$0.isEmpty && $0 != "Couldn’t create Bot" }
                    .joined(separator: " ")
                let failure = message.isEmpty ? alert.label : message
                creationOutcome = "Failed: \(failure)"
                XCTFail("New Bot creation failed: \(failure)")
            } else {
                retainMenuScreenshot(app, name: "Physical New Bot creation timeout")
                creationOutcome = "Timed out before chat or error"
                creationElapsed = Date().timeIntervalSince(started)
                XCTFail("New Bot did not open a conversation with both its header and composer within 60 seconds.")
            }
            return
        }

        XCTAssertTrue(header.exists)
        XCTAssertTrue(composer.exists)
        retainMenuScreenshot(app, name: "Physical New Bot after open")

        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "The opened Bot conversation did not expose a navigation back control.")
        back.tap()

        var newRowIDs = Set<String>()
        let rowDeadline = Date().addingTimeInterval(30)
        while Date() < rowDeadline {
            newRowIDs = liveChatRowIdentifiers(app).subtracting(existingRowIDs)
            if !newRowIDs.isEmpty { break }
            RunLoop.current.run(until: min(rowDeadline, Date().addingTimeInterval(0.25)))
        }
        XCTAssertEqual(newRowIDs.count, 1, "Expected exactly one new chat row by identifier difference, found \(newRowIDs.count): \(newRowIDs.sorted())")
        guard let newRowID = newRowIDs.first, newRowIDs.count == 1 else { return }
        createdRowID = newRowID

        let newRow = app.buttons[newRowID]
        XCTAssertTrue(newRow.waitForExistence(timeout: 10))
        cleanupCompleted = archiveExactNewBotRow(newRow, app: app, timeout: 90)
        XCTAssertTrue(cleanupCompleted, "The exact newly created Bot row did not disappear after archival.")
        retainMenuScreenshot(app, name: "Physical New Bot after cleanup")
    }

    func testPhysicalTenMinuteLiveScenarioCompletes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-diagnostics-scenario", "-diagnostics-soak"]
        // Some physical Diagnostics installs do not retain launch arguments
        // when XCTest starts the already-paired app. The app recognizes this
        // explicit Diagnostics-only route fallback while Release ignores it.
        app.launchEnvironment["WONDER_DIAGNOSTICS_SCENARIO"] = "1"
        app.launchEnvironment["WONDER_DIAGNOSTICS_SOAK"] = "1"
        app.launch()
        let root = anyElement(app, identifier: "diagnostics-scenario-root")
        let status = app.staticTexts["scenario-status"]
        guard root.waitForExistence(timeout: 20) else {
            retainMenuScreenshot(app, name: "Physical ten-minute live scenario missing diagnostics root")
            let state = XCTAttachment(string: """
            appState=\(app.state.rawValue)
            rootExists=\(root.exists)
            rootLabel=\(root.label)
            statusExists=\(status.exists)
            statusLabel=\(status.label)
            launchArguments=\(app.launchArguments.joined(separator: " | "))
            launchEnvironment=WONDER_DIAGNOSTICS_SCENARIO:\(app.launchEnvironment["WONDER_DIAGNOSTICS_SCENARIO"] ?? "<missing>")
            launchEnvironment=WONDER_DIAGNOSTICS_SOAK:\(app.launchEnvironment["WONDER_DIAGNOSTICS_SOAK"] ?? "<missing>")
            """)
            state.name = "Physical diagnostics launch state"
            state.lifetime = .keepAlways
            add(state)
            XCTFail("Diagnostics scenario root did not appear; retained a screenshot and launch state for diagnosis.")
            return
        }
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "Completed "),
            object: status)
        XCTAssertEqual(
            XCTWaiter.wait(for: [completed], timeout: 720),
            .completed,
            "The ten-minute foreground scenario must finish its asserted activity cycles and read-only Bot lifecycle.")
        XCTAssertTrue(status.label.contains("live cycles"))
        XCTAssertEqual(app.state, .runningForeground)
        retainMenuScreenshot(app, name: "Physical ten-minute live scenario completed")
    }
    func testLiveActivityAndScrolling() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-fixtures"]
        app.launch()

        // Keep this performance check independent of whatever live chat happens
        // to be selected on the simulator. The fixture uses the production
        // ConversationView/activity renderers with deterministic turn status,
        // compaction markers, and stable row identities.
        selectDiagnosticFixture("Turn lifecycle", in: app)

        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let activityIDs = [
            "activity-group:turn-completed/command",
            "activity-group:turn-completed/search",
            "activity-group:turn-stopped/stopped-command",
            "activity-group:turn-active/active-command",
            "activity-group:turn-active/active-search"
        ]
        for id in activityIDs {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 10), "Missing deterministic activity row \(id)")
        }
        let groups = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity-group:"))

        func visibleActivity() -> XCUIElement? {
            // iOS can report a lazy row behind the navigation/composer overlays
            // as hittable. Select a fully visible row and keep its stable identity.
            guard let row = groups.allElementsBoundByIndex.first(where: {
                $0.isHittable && $0.frame.minY > app.frame.minY + 150 && $0.frame.maxY < app.frame.maxY - 250
            }) else { return nil }
            return app.buttons[row.identifier]
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric(), XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            for _ in 0..<12 {
                if visibleActivity() != nil { break }
                scroll.swipeDown()
            }
            guard let activity = visibleActivity() else {
                XCTFail("No fully visible deterministic activity row was available")
                return
            }
            let before = activity.value as? String
            XCTAssertEqual(before, "Collapsed")
            activity.tap()
            let expanded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Expanded"), object: activity)
            XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 3), .completed)
            if activity.isHittable {
                activity.tap()
                let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Collapsed"), object: activity)
                XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 3), .completed)
            } else {
                XCTFail("Expansion moved its control offscreen")
                return
            }

            scroll.swipeDown()
            scroll.swipeUp()
        }
        let bottom = app.buttons["scroll-to-bottom"]
        if bottom.exists { bottom.tap() }
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testDiagnosticsCameraCaptureAttachesToDraftAndDismisses() throws {
        let app = launchCameraFixture("capture")
        let shutter = app.buttons["camera-shutter"]
        assertCameraHalfSheet(app)
        shutter.tap()
        XCTAssertTrue(waitUntilGone(anyElement(app, identifier: "camera-sheet"), timeout: 5))
        let ids = assertCameraDraft(app, count: 1)
        app.buttons["camera-reload-draft"].tap()
        XCTAssertEqual(assertCameraDraft(app, count: 1), ids)
        XCTAssertFalse(shutter.exists, "Reloading a durable draft must not reopen Camera")
    }

    func testDiagnosticsCameraCancelLeavesDraftUntouched() throws {
        let app = launchCameraFixture("cancel")
        let dismiss = app.buttons["camera-dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10))
        dismiss.tap()
        XCTAssertTrue(waitUntilGone(anyElement(app, identifier: "camera-sheet"), timeout: 5))
        app.buttons["camera-reload-draft"].tap()
        _ = assertCameraDraft(app, count: 0)
    }

    func testDiagnosticsCameraLimitLeavesDurableDraftUnchanged() throws {
        let app = launchCameraFixture("limit")
        let shutter = app.buttons["camera-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        shutter.tap()
        XCTAssertTrue(waitUntilGone(shutter, timeout: 10))
        app.buttons["camera-reload-draft"].tap()
        let expected = Set((0..<4).map { "composer-attachment:camera-existing-\($0)" })
        XCTAssertEqual(assertCameraDraft(app, count: 4), expected)
    }

    func testDiagnosticsCameraPermissionAndHardwareFailureAreDismissible() throws {
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        for argument in ["-diagnostics-camera-denied", "-diagnostics-camera-unavailable"] {
            app.launchArguments = ["-diagnostics-fixtures", argument]
            app.launch()
            let state = app.staticTexts["camera-permission-state"]
            XCTAssertTrue(state.waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["camera-error-dismiss"].waitForExistence(timeout: 5))
            app.buttons["camera-error-dismiss"].tap()
            XCTAssertFalse(state.exists)
            app.terminate()
        }
    }

    func testDiagnosticsCameraOptionsExposeNativeControls() throws {
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        app.launchArguments = ["-diagnostics-fixtures", "-diagnostics-camera-options"]
        app.launch()
        let options = app.buttons["camera-options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.tap()
        XCTAssertTrue(app.buttons["Switch camera"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Turn flash on"].exists)
        app.buttons["Turn flash on"].tap()
        options.tap()
        XCTAssertTrue(app.buttons["Turn flash off"].waitForExistence(timeout: 5))
        app.buttons["Turn flash off"].tap()
        options.tap()
        app.buttons["Switch camera"].tap()
        let facing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Front camera"), object: anyElement(app, identifier: "camera-preview"))
        XCTAssertEqual(XCTWaiter.wait(for: [facing], timeout: 5), .completed)
        options.tap()
        XCTAssertTrue(app.buttons["Turn flash on"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Turn flash on"].isEnabled)
    }

    func testPhysicalCameraHalfSheetCapturesOnlyToDurableDraft() throws {
        let app = launchCameraFixture("physical")
        assertCameraHalfSheet(app)
        retainMenuScreenshot(app, name: "Physical Camera medium sheet before capture")
        app.buttons["camera-shutter"].tap()
        // Real AVCapture + image preparation may take a moment; no review/Done
        // action is allowed between shutter and the saved composer thumbnail.
        XCTAssertTrue(waitUntilGone(anyElement(app, identifier: "camera-sheet"), timeout: 5))
        let ids = assertCameraDraft(app, count: 1)
        XCTAssertEqual(app.staticTexts["camera-input-source"].label, "Real camera · isolated draft")
        app.buttons["camera-reload-draft"].tap()
        XCTAssertEqual(assertCameraDraft(app, count: 1), ids)
        retainMenuScreenshot(app, name: "Physical Camera saved local draft after automatic dismissal")
        app.buttons["open-camera"].tap()
        waitForCameraReady(app)
        assertCameraHalfSheet(app)
        app.buttons["camera-dismiss"].tap()
        XCTAssertTrue(waitUntilGone(anyElement(app, identifier: "camera-sheet"), timeout: 5))
        XCTAssertEqual(assertCameraDraft(app, count: 1), ids)
    }

    func testPhysicalCameraThreeMinuteSheetLifecycle() throws {
        let app = launchCameraFixture("physical")
        let started = Date()
        var savedIDs = Set<String>()
        // Ten presentations over approximately three minutes exercise session
        // ownership, two real captures, camera switching and foreground resume.
        // This is separate from the final combined ten-minute integration run.
        for iteration in 0..<10 {
            if iteration > 0 { app.buttons["open-camera"].tap() }
            waitForCameraReady(app)
            assertCameraHalfSheet(app)
            if iteration == 2 || iteration == 7 {
                app.buttons["camera-options"].tap()
                app.buttons["Switch camera"].tap()
                waitForCameraReady(app)
                let facing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Front camera"), object: anyElement(app, identifier: "camera-preview"))
                XCTAssertEqual(XCTWaiter.wait(for: [facing], timeout: 10), .completed)
                retainMenuScreenshot(app, name: "Physical Camera switched lens \(iteration)")
            }
            if iteration == 3 || iteration == 8 {
                XCUIDevice.shared.press(.home)
                XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
                app.activate()
                waitForCameraReady(app)
                assertCameraHalfSheet(app)
                retainMenuScreenshot(app, name: "Physical Camera resumed from background \(iteration)")
            }
            let remaining = max(0, 180 - Date().timeIntervalSince(started))
            let observation = min(30, remaining / Double(10 - iteration))
            let shutter = app.buttons["camera-shutter"]
            let unavailable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.state != .runningForeground || !shutter.exists || !shutter.isEnabled
            }, object: nil)
            unavailable.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [unavailable], timeout: observation), .completed)

            let captured = iteration == 2 || iteration == 7
            if captured { shutter.tap() } else { app.buttons["camera-dismiss"].tap() }
            XCTAssertTrue(waitUntilGone(anyElement(app, identifier: "camera-sheet"), timeout: 5))
            let ids = assertCameraDraft(app, count: savedIDs.count + (captured ? 1 : 0))
            XCTAssertTrue(ids.isSuperset(of: savedIDs))
            if !captured { XCTAssertEqual(ids, savedIDs) }
            savedIDs = ids
            app.buttons["camera-reload-draft"].tap()
            XCTAssertEqual(assertCameraDraft(app, count: savedIDs.count), savedIDs)
        }
        XCTAssertEqual(savedIDs.count, 2)
        XCTAssertEqual(app.staticTexts["camera-input-source"].label, "Real camera · isolated draft")
        retainMenuScreenshot(app, name: "Physical Camera lifecycle finished with two local photos")
    }

    private func selectDiagnosticFixture(_ title: String, in app: XCUIApplication) {
        let picker = app.buttons["diagnostic-fixture-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5))
        app.buttons[title].tap()
    }

    private func launchCameraFixture(_ mode: String) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.swaymun.wonder")
        if mode == "physical" {
            // The interruption monitor handles a prompt that arrives during an
            // XCTest action; Springboard handles the first-launch system alert.
            _ = addUIInterruptionMonitor(withDescription: "Wonder camera permission") { alert in
                guard alert.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "camera")).firstMatch.exists else { return false }
                for label in ["Allow", "OK"] where alert.buttons[label].exists {
                    alert.buttons[label].tap(); return true
                }
                return false
            }
        }
        app.launchArguments = ["-diagnostics-fixtures", "-diagnostics-camera-" + mode]
        app.launch()
        if mode == "physical" {
            let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
            if alert.waitForExistence(timeout: 3),
               alert.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "camera")).firstMatch.exists {
                for label in ["Allow", "OK"] where alert.buttons[label].exists {
                    alert.buttons[label].tap(); break
                }
            }
        }
        waitForCameraReady(app) // Denial/unavailable is a failure, never a skip.
        return app
    }

    private func waitForCameraReady(_ app: XCUIApplication) {
        let shutter = app.buttons["camera-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 15), "A working camera and granted video permission are required")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    private func assertCameraHalfSheet(_ app: XCUIApplication) {
        let sheet = anyElement(app, identifier: "camera-sheet")
        let preview = anyElement(app, identifier: "camera-preview")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let screen = app.frame
        XCTAssertGreaterThan(screen.height, screen.width, "Half-sheet bounds are measured in portrait")
        retainMenuScreenshot(app, name: "Camera sheet bounds")
        if screen.width < 600 {
            XCTAssertGreaterThanOrEqual(sheet.frame.minY, screen.minY + screen.height * 0.4)
            XCTAssertGreaterThanOrEqual(preview.frame.minY, screen.minY + screen.height * 0.4)
        } else {
            // iPad uses the native floating medium sheet, not an edge-to-edge
            // iPhone panel. Preserve compact height and visible surrounding UI.
            XCTAssertGreaterThanOrEqual(sheet.frame.minY, screen.minY + screen.height * 0.20)
            XCTAssertLessThan(sheet.frame.width, screen.width * 0.9)
            XCTAssertGreaterThanOrEqual(preview.frame.minY, sheet.frame.minY)
        }
        XCTAssertLessThan(sheet.frame.height, screen.height * 0.65)
        XCTAssertGreaterThan(preview.frame.height, 80)
        XCTAssertGreaterThan(preview.frame.width, 150)
        for control in [app.buttons["camera-dismiss"], app.buttons["camera-shutter"], app.buttons["camera-options"]] {
            assertFullyVisible(control, in: app)
            XCTAssertGreaterThanOrEqual(control.frame.minY, sheet.frame.minY)
            XCTAssertLessThanOrEqual(control.frame.maxY, sheet.frame.maxY + 1)
        }
    }

    @discardableResult private func assertCameraDraft(_ app: XCUIApplication, count: Int) -> Set<String> {
        let label = app.staticTexts["camera-draft-count"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        XCTAssertEqual(label.label, "Draft attachments: \(count)")
        XCTAssertEqual(app.staticTexts["camera-pending-send"].label, "No pending send")
        XCTAssertEqual(app.staticTexts["camera-draft-transfers"].label, "Local draft only")
        let attachments = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "composer-attachment:"))
        let ids = Set(attachments.allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(ids.count, count)
        for id in ids {
            let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Loaded"), object: anyElement(app, identifier: id))
            XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        }
        return ids
    }
}
