import XCTest
import UIKit

@MainActor final class WonderUITests: XCTestCase {
    // A landscape check must not leave the next test rotated.
    override func setUp() async throws {
        XCUIDevice.shared.orientation = .portrait
    }
    private var appBundleIdentifier: String {
        #if WONDER_TESTING
        "com.swaymun.wonder.testing"
        #else
        "com.swaymun.wonder"
        #endif
    }

    // Keep the visible state with every failure; a failed assertion alone
    // rarely shows which control was covered or missing.
    override func record(_ issue: XCTIssue) {
        var issue = issue
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "Failure screen"; screen.lifetime = .keepAlways
        issue.add(screen)
        let tree = XCTAttachment(string: XCUIApplication(bundleIdentifier: appBundleIdentifier).debugDescription)
        tree.name = "Failure hierarchy"; tree.lifetime = .keepAlways
        issue.add(tree)
        super.record(issue)
    }
    private var appDisplayName: String { appBundleIdentifier.hasSuffix(".testing") ? "Wonder Testing" : "Wonder" }

    // Manual QA uses a team-signed Testing app/Widget and a disposable App
    // Group snapshot. Ordinary UI suites do not alter the Home Screen.
    private func requireRecentWidgetQA() throws {
        let environment = ProcessInfo.processInfo.environment
        guard appBundleIdentifier.hasSuffix(".testing"),
              environment["WONDER_WIDGET_RECENT_QA"] == "1",
              let ownedDevice = environment["WONDER_WIDGET_QA_DEVICE_NAME"],
              !ownedDevice.isEmpty, ownedDevice == environment["SIMULATOR_DEVICE_NAME"] else {
            throw XCTSkip("A signed Testing Widget, synthetic App Group snapshot, and explicit QA simulator name are required")
        }
    }

    private func mediumProjectWidget(on springboard: XCUIApplication) -> XCUIElement? {
        let widgets = springboard.icons.matching(NSPredicate(format: "identifier == %@ AND value CONTAINS %@",
                                                             appDisplayName, "Widget"))
        return widgets.allElementsBoundByIndex.first {
            let frame = $0.frame
            return frame.width > 240 && frame.height > 0 &&
                (1.5...3.4).contains(frame.width / frame.height) && $0.isHittable
        }
    }

    func testPlaceMediumProjectWidgetForRecentChatQA() throws {
        try requireRecentWidgetQA()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-connections-preview", "-project-files-preview", "-project-files-conversation-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["connection-picker"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10))
        if mediumProjectWidget(on: springboard) == nil {
            let edit = springboard.buttons["Edit"]
            if !edit.exists { springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68)).press(forDuration: 1.5) }
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            edit.tap()
            let addWidgetButton = springboard.buttons["Add Widget"]
            XCTAssertTrue(addWidgetButton.waitForExistence(timeout: 5))
            addWidgetButton.tap()
            let search = springboard.searchFields["Search Widgets"]
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            search.tap()
            search.typeText("Wonder")
            let wonder = springboard.cells[appDisplayName]
            XCTAssertTrue(wonder.waitForExistence(timeout: 10))
            wonder.tap()
            let card = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(appDisplayName), Recent Projects")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10), springboard.debugDescription)
            card.swipeLeft()
            XCTAssertTrue((card.value as? String)?.contains("Medium") == true, "Choose the medium layout")
            let addSelected = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Add Widget")).firstMatch
            XCTAssertTrue(addSelected.waitForExistence(timeout: 5))
            addSelected.tap()
            let done = springboard.buttons["Done"]
            if done.exists { done.tap() }
        }
        XCTAssertNotNil(mediumProjectWidget(on: springboard), "A visible medium Wonder Testing Widget was placed")
        XCUIDevice.shared.press(.home)
        let capture = XCTAttachment(screenshot: springboard.screenshot())
        capture.name = "Medium Recent Projects Widget"
        capture.lifetime = .keepAlways
        add(capture)
    }

    // The Widget needs no configuration: its tiles start a new chat in that
    // Project on the last-used Mac, and Live View opens that Mac's screen.
    func testConfiguredMediumProjectWidgetOpensRecentChat() throws {
        try requireRecentWidgetQA()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-connections-preview", "-project-files-preview", "-project-files-conversation-preview"]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for target in ["project", "computer"] {
            app.launch()
            XCTAssertTrue(app.buttons["connection-picker"].waitForExistence(timeout: 15))
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10))
            if mediumProjectWidget(on: springboard) == nil { springboard.swipeLeft() }
            guard let widget = mediumProjectWidget(on: springboard) else {
                XCTFail("A medium Wonder Testing Widget must be visible")
                return
            }
            // Two rows of tiles: the most recent Project first, Live View last.
            let point = target == "project" ? CGVector(dx: 0.25, dy: 0.39) : CGVector(dx: 0.75, dy: 0.72)
            widget.coordinate(withNormalizedOffset: point).tap()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "The Widget tap must foreground Wonder")
            if target == "project" {
                let draft = app.textViews["new-chat-draft"]
                XCTAssertTrue(draft.waitForExistence(timeout: 15))
                let destination = anyElement(app, identifier: "destination-picker")
                XCTAssertTrue(destination.waitForExistence(timeout: 5))
                XCTAssertEqual(destination.value as? String, "Preview project")
            } else {
                XCTAssertTrue(app.descendants(matching: .any)["computer-session-refresh"].waitForExistence(timeout: 15) ||
                              app.navigationBars.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            }
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = target == "project" ? "Widget project tile destination" : "Widget Live View destination"
            capture.lifetime = .keepAlways
            add(capture)
            app.terminate()
        }
    }

    func testRemoveMediumProjectWidgetAfterRecentChatQA() throws {
        try requireRecentWidgetQA()
        continueAfterFailure = false
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10))
        if mediumProjectWidget(on: springboard) == nil { springboard.swipeLeft() }
        guard let widget = mediumProjectWidget(on: springboard) else {
            XCTFail("The exact medium QA Widget must exist before cleanup")
            return
        }
        widget.press(forDuration: 1.2)
        let remove = springboard.buttons["Remove Widget"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tap()
        let confirm = springboard.buttons["Remove"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        XCTAssertNil(mediumProjectWidget(on: springboard),
                     "Cleanup must remove the medium QA Widget from this simulator")
    }
    private func selectTextForPreviewComment(_ app: XCUIApplication) {
        let selectable = app.textViews["annotation-selectable-text"]
        XCTAssertTrue(selectable.waitForExistence(timeout: 10))
        selectable.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.06)).doubleTap()
        tapEditMenuComment(app, "Selecting preview text must offer Comment in its menu")
        XCTAssertTrue(app.descendants(matching: .any)["annotation-note"].waitForExistence(timeout: 5))
    }
    private func tapEditMenuComment(_ app: XCUIApplication, _ message: String) {
        let menuItem = app.menuItems["Comment"]
        if menuItem.waitForExistence(timeout: 5) { menuItem.tap(); return }
        let button = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Comment", "annotation-comment")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 3), message + "\n" + app.debugDescription)
        button.tap()
    }
    /// Long-presses a word in the visible PDF page, which selects it and shows the edit menu.
    private func selectPDFWord(_ app: XCUIApplication) {
        let pdf = app.descendants(matching: .any)["workspace-pdf-preview"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 10))
        // The fixture page (300×420 pt) fits the viewer's width; its heading sits
        // about 8% down the page.
        let width = pdf.frame.width
        let heading = pdf.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: width * 0.22, dy: 6 + width * 1.4 * 0.08))
        heading.press(forDuration: 1.2)
    }
    private func workspacePreviewClose(_ app: XCUIApplication, legacyID: String) -> XCUIElement {
        let backToFiles = app.buttons["workspace-preview-back"]
        return backToFiles.exists ? backToFiles : app.buttons[legacyID]
    }
    private func openConversationDetails(_ app: XCUIApplication) {
        let title = app.buttons["conversation-title-menu"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        let details = app.buttons["Conversation details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
    }
    // This optional private replay uses the production conversation controls.
    // Supply the projected snapshot in the app's Documents directory; never
    // check real session contents into source or initiate model work here.
    func testExistingClaudeSessionReplay() throws {
        guard ProcessInfo.processInfo.environment["WONDER_HISTORY_REPLAY"] == "1" else {
            throw XCTSkip("Explicit private offline history fixture required")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-chat-layout", "-diagnostics-chat-layout-unsaved", "-diagnostics-history-replay"]
        app.launch()
        XCTAssertTrue(app.textViews["message-draft"].waitForExistence(timeout: 10))
        let scroll = anyElement(app, identifier: "conversation-scroll")
        XCTAssertTrue(scroll.exists)
        let groups = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity-group:"))
        let header = app.buttons["conversation-title-menu"]
        let draft = app.textViews["message-draft"]
        var selected: XCUIElement?
        for _ in 0..<20 {
            selected = groups.allElementsBoundByIndex.first { $0.frame.minY >= header.frame.maxY && $0.frame.maxY <= draft.frame.minY && $0.isHittable }
            if selected != nil { break }
            scroll.swipeDown()
        }
        let work = try XCTUnwrap(selected, "The existing transcript must expose a fully visible activity control")
        let id = work.identifier
        XCTAssertEqual(work.value as? String, "Collapsed")
        for _ in 0..<12 {
            let control = app.buttons[id]
            control.tap(); XCTAssertEqual(control.value as? String, "Expanded")
            control.tap(); XCTAssertEqual(control.value as? String, "Collapsed")
        }
        retainMenuScreenshot(app, name: "Private Claude session replay")
        for _ in 0..<5 { scroll.swipeDown(); scroll.swipeUp() }
        XCTAssertTrue(draft.exists)
        XCTAssertFalse(app.buttons["subagent-status-pill"].exists, "An offline transcript must not inherit unrelated synthetic helpers")
        app.terminate()
    }

    func testNativeMarketingConversationCapture() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-marketing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-chat-layout", "-UIPreferredContentSizeCategoryName", contentSize] + extra
        app.launch()
        let draft = app.textViews["message-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reply 12.")).firstMatch
        let replyExists = reply.waitForExistence(timeout: 10)
        if !replyExists { retainMenuScreenshot(app, name: "Initial chat missing latest reply") }
        XCTAssertTrue(replyExists)
        let work = app.buttons["activity-group:layout-turn-12/layout-work-12"]
        let header = app.buttons["conversation-title-menu"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let before = reply.frame
        let workBefore = work.exists ? work.staticTexts.firstMatch.frame : nil
        retainMenuScreenshot(app, name: "Initial chat before any drag")
        let scroll = anyElement(app, identifier: "conversation-scroll")
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)), withVelocity: .slow, thenHoldForDuration: 0)
        let after = reply.frame
        let workAfter = work.exists ? work.staticTexts.firstMatch.frame : nil
        retainMenuScreenshot(app, name: "Chat after first short drag")
        let evidence = XCTAttachment(string: "Before: \(before)\nAfter: \(after)\nWork before: \(String(describing: workBefore))\nWork after: \(String(describing: workAfter))\nHeader: \(header.frame)\nComposer: \(draft.frame)\nHelper: \(app.buttons["subagent-status-pill"].frame)\nViewport bottom: \(conversationLayoutBottom(app, draft: draft))\nScroll: \(scroll.frame)")
        evidence.lifetime = .keepAlways; add(evidence)
        XCTAssertEqual(before.minX, after.minX, accuracy: 1, "A vertical drag must not repair a horizontal offset")
        // Native list controls expose a full-row accessibility tap target.
        // Measure the label to check the visible column's actual padding.
        if let workBefore {
            let workAfter = try XCTUnwrap(workAfter, "A short drag must preserve the visible activity row")
            XCTAssertEqual(workBefore.minX, workAfter.minX, accuracy: 1)
            XCTAssertGreaterThanOrEqual(workBefore.minX, scroll.frame.minX + 16)
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
        if extra.contains("-diagnostics-chat-layout-unsaved"), before.height > viewportHeight {
            // Exercise a real drag to the preceding row even if the native
            // list has already prepared its offscreen accessibility element.
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
            XCTAssertGreaterThanOrEqual(work.staticTexts.firstMatch.frame.minX, scroll.frame.minX + 16)
        }
        app.terminate()
    }

    func testChatRestoresOlderReadingPositionAndReturnsToBottom() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-chat-layout", "-diagnostics-chat-layout-older", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let draft = app.textViews["message-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reply 6.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        let scroll = anyElement(app, identifier: "conversation-scroll")
        let header = app.buttons["conversation-title-menu"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let olderWork = app.buttons["activity-group:layout-turn-6/layout-work-6"]
        XCTAssertTrue(olderWork.waitForExistence(timeout: 5))
        retainConversationLayoutEvidence(app, name: "Older saved reply restored without a drag", reply: reply, header: header, draft: draft)
        XCTAssertGreaterThanOrEqual(olderWork.staticTexts.firstMatch.frame.minX, scroll.frame.minX + 16)
        XCTAssertGreaterThan(reply.frame.maxY, header.frame.maxY)
        XCTAssertLessThan(reply.frame.minY, conversationLayoutBottom(app, draft: draft))
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
        XCTAssertGreaterThanOrEqual(work.staticTexts.firstMatch.frame.minX, scroll.frame.minX + 16)
        XCTAssertEqual(work.value as? String, "Collapsed")
        work.tap()
        XCTAssertEqual(work.value as? String, "Expanded")
        work.tap()
        XCTAssertEqual(work.value as? String, "Collapsed")
        retainConversationLayoutEvidence(app, name: "Activity expands and collapses above the helper dock", reply: latest, header: header, draft: draft)
        XCTAssertGreaterThanOrEqual(work.staticTexts.firstMatch.frame.minX, scroll.frame.minX + 16)
        XCTAssertLessThanOrEqual(latest.frame.maxY, conversationLayoutBottom(app, draft: draft))
        XCTAssertLessThan(conversationLayoutBottom(app, draft: draft) - latest.frame.maxY, 100)
        app.terminate()
    }

    // Contract: long-press read actions update the sidebar without opening the
    // chat, and seeing the latest Project reply clears the same unread dot.
    // Uses the existing synthetic transport and real product controls.
    // Contract: failed native archives leave the pinned chat visible; a confirmed
    // retry removes it from the real sidebar and leaves the open conversation.
    func testProjectArchiveFailureAndConfirmedRemoval() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-chat-layout",
            "-diagnostics-chat-layout-unsaved", "-diagnostics-project-archive"]
        app.launch()
        openSidebarIfNeeded(app)
        let row = app.buttons["pinned-thread:codex:read-fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.buttons["conversation-title-menu"].waitForExistence(timeout: 15))
        openSidebarIfNeeded(app)
        row.press(forDuration: 1)
        let archive = app.buttons["archive-project-thread"]
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        retainMenuScreenshot(app, name: "Codex archive menu")
        archive.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(row.exists, "A failed archive keeps the chat visible")
        row.press(forDuration: 1)
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        archive.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !row.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["conversation-title-menu"].exists, "Archiving closes the selected chat")
        retainMenuScreenshot(app, name: "Archived Codex chat removed")
    }

    // Uses a synthetic Codex catalog and Project detail. Selecting speed
    // must persist in the existing thread and be offered in a new draft
    // without sending model work.
    func testProjectSpeedControlsOnThreadAndNewDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-chat-layout",
            "-diagnostics-chat-layout-unsaved", "-diagnostics-project-speed"]
        app.launch()
        openSidebarIfNeeded(app)
        let row = app.buttons["pinned-thread:codex:read-fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let model = app.buttons["project-composer-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 15))
        model.tap()
        let fast = app.buttons["project-speed:fast"]
        XCTAssertTrue(fast.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["project-speed:default"].exists)
        retainMenuScreenshot(app, name: "Project model and speed choices")
        fast.tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (model.value as? String)?.contains("Fast") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        app.buttons["Done"].tap()
        model.tap()
        XCTAssertTrue(fast.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["new-chat"].tap()
        let picker = app.buttons["project-agent-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        let newFast = app.buttons["new-chat-speed:fast"]
        XCTAssertTrue(newFast.waitForExistence(timeout: 10))
        newFast.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue((picker.value as? String)?.contains("Fast") == true)
    }

    func testProjectThreadReadMenuAndVisibleAcknowledgement() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-chat-layout",
            "-diagnostics-chat-layout-unsaved", "-diagnostics-project-read",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        app.launch()
        openSidebarIfNeeded(app)
        let row = app.buttons["pinned-thread:claude:read-fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue((row.value as? String)?.contains("Unread") == true)
        for cycle in 0..<12 {
            for unread in [false, true] {
                row.press(forDuration: 1)
                let action = app.buttons[unread ? "Mark as Unread" : "Mark as Read"]
                XCTAssertTrue(action.waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons[unread ? "Mark as Read" : "Mark as Unread"].exists)
                if cycle == 0 { retainMenuScreenshot(app, name: unread ? "Read thread menu" : "Unread thread menu") }
                action.tap()
                let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    row.exists && ((row.value as? String)?.contains("Unread") == true) == unread
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 8), .completed)
                XCTAssertFalse(app.buttons["conversation-title-menu"].exists, "Marking status must not navigate into the chat")
            }
        }
        row.tap()
        XCTAssertTrue(app.textViews["message-draft"].waitForExistence(timeout: 15))
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reply 12.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        if app.buttons["scroll-to-bottom"].exists { app.buttons["scroll-to-bottom"].tap() }
        retainMenuScreenshot(app, name: "Latest Project reply before read acknowledgement")
        XCTAssertLessThanOrEqual(reply.frame.maxY, conversationLayoutBottom(app, draft: app.textViews["message-draft"]) + 1,
                                 "Only a fully seen latest reply counts as read")
        // Let the stationary viewport's acknowledgement run before covering it.
        let pause = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in false }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pause], timeout: 2), .timedOut)
        openSidebarIfNeeded(app)
        let read = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            row.exists && (row.value as? String)?.contains("Unread") != true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [read], timeout: 10), .completed,
                       "A Project chat must acknowledge its visible reply despite being absent from the Bot inbox")
        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Mark as Unread"].waitForExistence(timeout: 5))
        retainMenuScreenshot(app, name: "Read menu after viewing Project reply")
        app.buttons["Mark as Unread"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in false }, object: nil)], timeout: 2), .timedOut)
        XCTAssertTrue((row.value as? String)?.contains("Unread") == true,
                      "Mark as Unread stays set even if the iPad conversation is still visible")
        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Mark as Read"].waitForExistence(timeout: 5))
        retainMenuScreenshot(app, name: "Manually unread open thread")
        app.buttons["Mark as Read"].tap()
        app.terminate()
    }

    // Claude Code background commands and agents use the same agent-task list.
    func testClaudeBackgroundTasksAppearInAgentTasks() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-chat-layout",
                               "-diagnostics-chat-layout-unsaved", "-diagnostics-project-subagents", "-diagnostics-project-claude-tasks"]
        app.launch()
        openSidebarIfNeeded(app)
        let parent = app.buttons["pinned-thread:codex:read-fixture"]
        XCTAssertTrue(parent.waitForExistence(timeout: 15))
        parent.tap()
        let pill = app.buttons["project-subagent-status-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 15))
        pill.tap()
        let command = app.buttons["project-subagent-roster:fixture-child-thread"]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        XCTAssertTrue(command.label.hasPrefix("Run focused UI tests"), command.label)
        XCTAssertTrue(command.label.hasSuffix("Running"), command.label)
        let agent = app.buttons["project-subagent-roster:fixture-second-child-thread"]
        XCTAssertTrue(agent.exists)
        XCTAssertTrue(agent.label.hasSuffix("Completed"), agent.label)
        Thread.sleep(forTimeInterval: 0.5)
        retainMenuScreenshot(app, name: "Claude background tasks in agent tasks")
    }

    func testProjectAgentTaskOpensReadOnlyTranscript() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-chat-layout",
                               "-diagnostics-chat-layout-unsaved", "-diagnostics-project-subagents"]
        app.launch()
        openSidebarIfNeeded(app)
        let parent = app.buttons["pinned-thread:codex:read-fixture"]
        XCTAssertTrue(parent.waitForExistence(timeout: 15))
        parent.tap()
        let pill = app.buttons["project-subagent-status-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 15))
        pill.tap()
        Thread.sleep(forTimeInterval: 0.5); retainMenuScreenshot(app, name: "Project agent tasks")
        let scout = app.buttons["project-subagent-roster:fixture-child-thread"]
        XCTAssertTrue(scout.waitForExistence(timeout: 5))
        XCTAssertEqual(scout.label, "Scout, Status unknown",
                       "A desktop-owned child that is not loaded by this server must not look unavailable or falsely live")
        scout.tap()
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Scout found the parser issue.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), app.debugDescription)
        let transcript = app.scrollViews["project-subagent-transcript"]
        XCTAssertTrue(transcript.exists)
        XCTAssertEqual(transcript.textViews.count, 0, "Agent history has no direct-send composer")
        retainMenuScreenshot(app, name: "Agent task read-only conversation")
        app.buttons["project-subagent-sheet-done"].tap()
        XCTAssertTrue(app.textViews["message-draft"].waitForExistence(timeout: 5))
        let group = app.buttons["activity-group:layout-turn-12/layout-work-12"]
        for _ in 0..<6 where !group.exists {
            anyElement(app, identifier: "conversation-scroll").swipeDown(velocity: .slow)
        }
        XCTAssertTrue(group.waitForExistence(timeout: 5), app.debugDescription)
        if group.value as? String == "Collapsed" { group.tap() }
        let activity = app.buttons["project-subagent-row:fixture-child-thread"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5),
                      "The inline Project activity should resolve the verified child")
        activity.tap()
        XCTAssertTrue(reply.waitForExistence(timeout: 15),
                      "The inline activity should open the Project transcript")
        XCTAssertTrue(app.scrollViews["project-subagent-transcript"].exists)
        app.buttons["project-subagent-sheet-done"].tap()
        XCTAssertTrue(app.textViews["message-draft"].waitForExistence(timeout: 5))
        let secondActivity = app.buttons["project-subagent-row:fixture-second-child-thread"]
        XCTAssertTrue(secondActivity.waitForExistence(timeout: 5),
                      "A collaboration activity should expose each verified receiver")
        secondActivity.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Builder completed the file review.")).firstMatch.waitForExistence(timeout: 15))
        app.buttons["project-subagent-sheet-done"].tap()
        XCTAssertTrue(app.textViews["message-draft"].waitForExistence(timeout: 5))
    }

    func testProjectAgentRosterMarksCachedRunningStatusLastKnownAfterRefreshFailure() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-chat-layout",
                               "-diagnostics-chat-layout-unsaved", "-diagnostics-project-subagents",
                               "-diagnostics-project-subagents-stale"]
        app.launch()
        openSidebarIfNeeded(app)
        let parent = app.buttons["pinned-thread:codex:read-fixture"]
        XCTAssertTrue(parent.waitForExistence(timeout: 15))
        parent.tap()
        let pill = app.buttons["project-subagent-status-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        pill.tap()
        let scout = app.buttons["project-subagent-roster:fixture-child-thread"]
        XCTAssertTrue(scout.waitForExistence(timeout: 5))
        XCTAssertEqual(scout.label, "Scout, Running")
        scout.tap()
        XCTAssertTrue(app.buttons["project-subagent-sheet-done"].waitForExistence(timeout: 10))
        app.buttons["project-subagent-sheet-done"].tap()
        app.buttons["new-chat"].tap()
        openSidebarIfNeeded(app)
        parent.tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        pill.tap()
        XCTAssertTrue(scout.waitForExistence(timeout: 5))
        XCTAssertEqual(scout.label, "Scout, Last known: Running")
        XCTAssertTrue(app.staticTexts["project-subagent-roster-detail"].exists)
    }

    func testProjectAgentRosterLoadsOlderVerifiedChild() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-chat-layout",
                               "-diagnostics-chat-layout-unsaved", "-diagnostics-project-subagents",
                               "-diagnostics-project-subagents-paged"]
        app.launch()
        openSidebarIfNeeded(app)
        let parent = app.buttons["pinned-thread:codex:read-fixture"]
        XCTAssertTrue(parent.waitForExistence(timeout: 15))
        parent.tap()
        let pill = app.buttons["project-subagent-status-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 15))
        pill.tap()
        XCTAssertTrue(app.buttons["project-subagent-roster:fixture-child-thread"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["project-subagent-roster:fixture-second-child-thread"].exists)
        let loadOlder = app.buttons["project-subagent-roster-load-older"]
        XCTAssertTrue(loadOlder.waitForExistence(timeout: 5))
        loadOlder.tap()
        let builder = app.buttons["project-subagent-roster:fixture-second-child-thread"]
        XCTAssertTrue(builder.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(loadOlder.exists, "The final provider page clears the load-more control")
        builder.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "Builder completed the file review.")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.scrollViews["project-subagent-transcript"].textViews.count, 0)
        app.buttons["project-subagent-sheet-done"].tap()
        XCTAssertTrue(app.textViews["message-draft"].waitForExistence(timeout: 5))
        app.buttons["new-chat"].tap()
        openSidebarIfNeeded(app)
        parent.tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        pill.tap()
        XCTAssertTrue(builder.waitForExistence(timeout: 5))
        XCTAssertEqual(builder.label, "Builder, Last known: Completed")
        builder.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "Builder completed the file review.")).firstMatch.waitForExistence(timeout: 15))
    }

    func testProjectAgentRosterStopsRepeatedProviderCursor() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-chat-layout",
                               "-diagnostics-chat-layout-unsaved", "-diagnostics-project-subagents",
                               "-diagnostics-project-subagents-paged", "-diagnostics-project-subagents-cycle"]
        app.launch()
        openSidebarIfNeeded(app)
        let parent = app.buttons["pinned-thread:codex:read-fixture"]
        XCTAssertTrue(parent.waitForExistence(timeout: 15))
        parent.tap()
        let pill = app.buttons["project-subagent-status-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 15))
        pill.tap()
        let loadOlder = app.buttons["project-subagent-roster-load-older"]
        XCTAssertTrue(loadOlder.waitForExistence(timeout: 5))
        loadOlder.tap()
        let builder = app.buttons["project-subagent-roster:fixture-second-child-thread"]
        XCTAssertTrue(builder.waitForExistence(timeout: 10))
        XCTAssertEqual(builder.label, "Builder, Completed")
        pill.tap()
        app.buttons["new-chat"].tap()
        openSidebarIfNeeded(app)
        parent.tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        pill.tap()
        XCTAssertTrue(builder.waitForExistence(timeout: 5))
        XCTAssertEqual(builder.label, "Builder, Last known: Completed")
        XCTAssertTrue(loadOlder.waitForExistence(timeout: 5))
        loadOlder.tap()
        let detail = app.staticTexts["project-subagent-roster-detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        XCTAssertTrue(detail.label.contains("could not be loaded"), detail.label)
        XCTAssertEqual(builder.label, "Builder, Running",
                       "The next verified page refreshes the retained older row")
        XCTAssertFalse(loadOlder.exists, "A repeated provider cursor must end paging")
    }

    func testActivityDisclosureKeepsVisibleReadingAnchorAtLargeText() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-chat-layout", "-diagnostics-chat-layout-older",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        app.launch()
        let work = app.buttons["activity-group:layout-turn-6/layout-work-6"]
        let scroll = anyElement(app, identifier: "conversation-scroll")
        let draft = app.textViews["message-draft"]
        let header = app.buttons["conversation-title-menu"]
        XCTAssertTrue(work.waitForExistence(timeout: 10))
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        for _ in 0..<8 {
            let top = max(scroll.frame.minY, header.frame.maxY)
            let bottom = conversationLayoutBottom(app, draft: draft)
            if work.isHittable && work.frame.minY >= top && work.frame.maxY <= bottom { break }
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: work.frame.minY < top ? 0.65 : 0.45))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        }
        let top = max(scroll.frame.minY, header.frame.maxY)
        let bottom = conversationLayoutBottom(app, draft: draft)
        XCTAssertTrue(work.isHittable)
        XCTAssertGreaterThanOrEqual(work.frame.minY, top)
        XCTAssertLessThanOrEqual(work.frame.maxY, bottom)
        let before = work.frame
        work.tap()
        XCTAssertEqual(work.value as? String, "Expanded")
        let after = work.frame
        XCTAssertGreaterThanOrEqual(after.minY, top)
        XCTAssertLessThanOrEqual(after.minY, bottom)
        XCTAssertEqual(after.minY, before.minY, accuracy: 64,
                       "Expanding a visible row should not jump the conversation to another position")
    }

    private func conversationLayoutBottom(_ app: XCUIApplication, draft: XCUIElement) -> CGFloat {
        let pill = app.buttons["subagent-status-pill"]
        return pill.exists && pill.isHittable ? min(pill.frame.minY, draft.frame.minY) : draft.frame.minY
    }

    private func retainConversationLayoutEvidence(_ app: XCUIApplication, name: String, reply: XCUIElement, header: XCUIElement, draft: XCUIElement) {
        retainMenuScreenshot(app, name: name)
        let pill = app.buttons["subagent-status-pill"]
        let evidence = XCTAttachment(string: "Reply: \(reply.frame)\nHeader: \(header.frame)\nComposer: \(draft.frame)\nHelper: \(pill.exists ? String(describing: pill.frame) : "absent")\nViewport bottom: \(conversationLayoutBottom(app, draft: draft))\nScroll: \(anyElement(app, identifier: "conversation-scroll").frame)")
        evidence.name = name + " geometry"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testWorkingImagesFollowActivityExpansion() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
            let scroll = anyElement(app, identifier: "conversation-scroll")
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
                XCTAssertTrue(workspacePreviewClose(app, legacyID: "photo-viewer-close").waitForExistence(timeout: 5))
                viewerImage.doubleTap()
                let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "200%"), object: viewerImage)
                XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed)
                workspacePreviewClose(app, legacyID: "photo-viewer-close").tap()
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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

    func testReviewRequestReturnsFromFilesToThePendingApproval() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview", "-computer-approval-preview"]
        app.launch()
        let review = app.buttons["review-approval-request"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        files.tap()
        XCTAssertTrue(app.collectionViews["workspace-file-list"].waitForExistence(timeout: 10))
        review.tap()
        XCTAssertFalse(app.collectionViews["workspace-file-list"].exists)
        let approval = app.buttons["approval-accept-fixture-computer"]
        XCTAssertTrue(approval.waitForExistence(timeout: 5))
        XCTAssertTrue(approval.isHittable, "Review request should reveal the pending approval")
    }

    func testEveryApprovalFamilyHasPhoneControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        let cases = [
            ("command", "acceptForSession", "convert original.png output.png"),
            ("network", "accept", "example.com"),
            ("file", "accept", "/Users/example/Movies"),
            ("permissions", "allowTurn", "/Users/example/Movies"),
            ("form", "accept", "Choose export settings."),
            ("native", "accept", "App: Calculator"),
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
                if kind == "native" {
                    XCTAssertEqual(action.label, "Allow once")
                    XCTAssertTrue(app.staticTexts["Risk level: Low"].exists)
                    XCTAssertFalse(app.staticTexts["Allow for this session"].exists)
                }
                retainMenuScreenshot(app, name: "Phone approval " + kind + " " + size)
                app.terminate()
            }
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        let arguments = ["-diagnostics-subagent-fixture", "-diagnostics-optimistic-approval", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launchArguments = arguments + ["-diagnostics-approval-reset"]
        app.launch()
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

    func testDiagnosticsGoalPillAndSheet() throws {
        try checkGoalSheet(contentSize: "UICTContentSizeCategoryL")
    }

    func testDiagnosticsGoalPillAndSheetAtAccessibilitySize() throws {
        try checkGoalSheet(contentSize: "UICTContentSizeCategoryAccessibilityXXL")
    }

    func testDiagnosticsGoalPillStatusIconsKeepDetailsAccessible() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        for (status, label, detail) in [
            ("paused", "paused", "Paused"), ("complete", "complete", "Complete"),
            ("blocked", "needs attention", "Needs attention"),
            ("usageLimited", "usage limited", "Usage limit reached"),
            ("budgetLimited", "budget reached", "Budget reached")
        ] {
            app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-goal-fixture",
                                   "-diagnostics-goal-status", status]
            app.launch()
            let goal = app.buttons["goal-status-pill"]
            let agents = app.buttons["subagent-status-pill"]
            XCTAssertTrue(goal.waitForExistence(timeout: 10))
            XCTAssertTrue(agents.waitForExistence(timeout: 5))
            XCTAssertEqual(goal.label, "Goal " + label)
            XCTAssertEqual(goal.staticTexts.count, 0)
            XCTAssertEqual(goal.frame.height, agents.frame.height, accuracy: 1)
            XCTAssertEqual(goal.frame.midY, agents.frame.midY, accuracy: 1)
            XCTAssertGreaterThanOrEqual(goal.frame.width, 44)
            XCTAssertGreaterThanOrEqual(goal.frame.width, 64, "The goal retains its icon beside the status symbol")
            XCTAssertLessThan(goal.frame.width, 90, "The goal stays a compact pair of icons")
            retainMenuScreenshot(app, name: "Goal status " + status)
            goal.tap()
            XCTAssertTrue(app.staticTexts["goal-objective"].waitForExistence(timeout: 5))
            let statusDetail = app.descendants(matching: .any).matching(identifier: "goal-metadata-status").firstMatch
            XCTAssertEqual(statusDetail.label, "Status, " + detail)
            if status == "complete" { XCTAssertFalse(app.buttons["goal-resume"].exists) }
            else { XCTAssertTrue(app.buttons["goal-resume"].exists) }
            app.buttons["goal-done"].tap()
            XCTAssertEqual(goal.value as? String, "Collapsed")
            app.terminate()
        }
    }

    private func checkGoalSheet(contentSize: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-goal-fixture",
                               "-UIPreferredContentSizeCategoryName", contentSize]
        app.launch()
        let draft = app.textViews["message-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap(); draft.typeText("parent draft")

        let goalPill = app.buttons["goal-status-pill"]
        let agentPill = app.buttons["subagent-status-pill"]
        XCTAssertTrue(goalPill.waitForExistence(timeout: 10))
        XCTAssertTrue(agentPill.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(goalPill.frame.height, 44)
        XCTAssertGreaterThanOrEqual(goalPill.frame.width, 44)
        XCTAssertEqual(goalPill.frame.height, agentPill.frame.height, accuracy: 1)
        XCTAssertEqual(goalPill.frame.midY, agentPill.frame.midY, accuracy: 1)
        XCTAssertEqual(goalPill.label, "Goal active")
        XCTAssertEqual(goalPill.staticTexts.count, 0, "The single goal uses its goal and status icons without redundant text")
        XCTAssertEqual(agentPill.staticTexts.firstMatch.label, "2", "The roster control displays only its count beside the avatars")
        XCTAssertLessThan(goalPill.frame.maxX, agentPill.frame.minX)
        XCTAssertLessThanOrEqual(agentPill.frame.minX - goalPill.frame.maxX, 8)
        XCTAssertLessThanOrEqual(agentPill.frame.maxX, draft.frame.maxX + 24)
        XCTAssertGreaterThanOrEqual(draft.frame.minY - goalPill.frame.maxY, 0)
        XCTAssertLessThan(draft.frame.minY - goalPill.frame.maxY, 22)
        retainMenuScreenshot(app, name: "Goal and agent pills above composer")
        goalPill.tap()
        let objective = app.staticTexts["goal-objective"]
        XCTAssertTrue(objective.waitForExistence(timeout: 5))
        XCTAssertTrue((objective.label).contains("reliable beta launch"))
        let metadata = app.descendants(matching: .any)
        XCTAssertEqual(metadata.matching(identifier: "goal-metadata-tokens").firstMatch.label,
                       "Tokens used, 50. Token budget, 1,000")
        XCTAssertEqual(metadata.matching(identifier: "goal-metadata-time").firstMatch.label,
                       "Active time, 0 min. Time limit, 10 min")
        let edit = app.buttons["goal-edit"]
        let pause = app.buttons["goal-pause"]
        let remove = app.buttons["goal-remove"]
        for control in [edit, pause, remove] {
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertEqual(control.frame.midY, edit.frame.midY, accuracy: 1)
        }
        XCTAssertEqual(edit.label, "Edit goal")
        XCTAssertEqual(pause.label, "Pause goal")
        XCTAssertEqual(remove.label, "Remove goal")
        retainMenuScreenshot(app, name: "Goal details half sheet")

        tapGoalControl("goal-pause", in: app)
        XCTAssertTrue(app.buttons["goal-resume"].waitForExistence(timeout: 5))
        app.buttons["goal-done"].tap()
        XCTAssertEqual(goalPill.label, "Goal paused")
        XCTAssertEqual(goalPill.frame.height, agentPill.frame.height, accuracy: 1)
        retainMenuScreenshot(app, name: "Paused goal and agent pills")
        goalPill.tap()
        tapGoalControl("goal-resume", in: app)
        XCTAssertTrue(app.buttons["goal-pause"].waitForExistence(timeout: 5))
        tapGoalControl("goal-edit", in: app)
        let editor = app.textViews["goal-objective-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let timeLimit = app.textFields["goal-time-budget-editor"]
        XCTAssertTrue(timeLimit.exists)
        XCTAssertEqual(timeLimit.value as? String, "10")
        editor.tap(); editor.typeText(" Ready.")
        tapGoalControl("goal-save", in: app)
        XCTAssertTrue(objective.waitForExistence(timeout: 5))
        XCTAssertTrue(objective.label.contains("Ready."))

        tapGoalControl("goal-remove", in: app)
        let removeButtons = app.buttons.matching(NSPredicate(format: "label == %@", "Remove goal"))
        let removeConfirmation = try XCTUnwrap(removeButtons.allElementsBoundByIndex.first { $0.isHittable })
        removeConfirmation.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: goalPill)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(agentPill.exists)
        XCTAssertEqual(draft.value as? String, "parent draft")
        app.terminate()
    }

    private func tapGoalControl(_ identifier: String, in app: XCUIApplication) {
        let control = app.buttons[identifier]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        let scroll = app.scrollViews["goal-details-scroll"]
        // XCTest may report an offscreen SwiftUI button as hittable even
        // when its frame sits beneath the software keyboard. Reveal the full
        // control within the actual unobscured scroll viewport before tapping.
        func visibleBounds() -> CGRect {
            var bounds = identifier == "goal-save" ? app.frame : scroll.frame.intersection(app.frame)
            if app.keyboards.firstMatch.exists {
                bounds.size.height = max(0, min(bounds.maxY, app.keyboards.firstMatch.frame.minY) - bounds.minY)
            }
            return bounds.insetBy(dx: 0, dy: 8)
        }
        for _ in 0..<5 {
            let bounds = visibleBounds()
            if control.isHittable && bounds.contains(control.frame) { break }
            let down = control.frame.minY < bounds.minY
            let top = bounds.minY + 24
            let bottom = bounds.maxY - 24
            // Start inside the padded content; the outer gutter is not hit-testable.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: bounds.midX, dy: down ? top : bottom))
            let end = origin.withOffset(CGVector(dx: bounds.midX, dy: down ? bottom : top))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(control.isHittable)
        XCTAssertTrue(visibleBounds().contains(control.frame), "Goal control must be fully visible before tapping")
        control.tap()
    }

    private func checkSubagentSheet(contentSize: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-subagent-fixture", "-UIPreferredContentSizeCategoryName", contentSize]
        app.launch()
        let parentDraft = app.textViews["message-draft"]
        XCTAssertTrue(parentDraft.waitForExistence(timeout: 10), app.debugDescription)
        parentDraft.tap(); parentDraft.typeText("parent draft")
        if app.keyboards.firstMatch.exists {
            let scroll = anyElement(app, identifier: "conversation-scroll")
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.19))
            start.press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86)),
                        withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        let groups = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity-group:"))
        for _ in 0..<5 where !groups.firstMatch.exists {
            let scroll = anyElement(app, identifier: "conversation-scroll")
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
        let conversationScroll = anyElement(app, identifier: "conversation-scroll")
        for _ in 0..<6 where !activity.exists { conversationScroll.swipeDown(velocity: .slow) }
        for _ in 0..<6 where !activity.exists { conversationScroll.swipeUp(velocity: .slow) }
        XCTAssertTrue(activity.waitForExistence(timeout: 5), app.debugDescription); activity.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        XCTAssertEqual(pill.value as? String, "Collapsed")
        XCTAssertEqual(parentDraft.value as? String, "parent draft")
        retainMenuScreenshot(app, name: "Parent restored after agent sheet")
    }

    func testDiagnosticsComputerSessionUnavailableFixture() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-computer-session-fixture"]
        app.launch()

        let computerContainer = app.descendants(matching: .any)
            .matching(identifier: "computer-session-container").firstMatch
        XCTAssertTrue(computerContainer.waitForExistence(timeout: 10))
        let picker = app.buttons["computer-session-connection-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "Connecting, screen unavailable")
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
        let refresh = app.buttons["computer-session-refresh"]
        let more = app.buttons["computer-session-more"]
        XCTAssertTrue(refresh.exists)
        XCTAssertTrue(more.exists)
        XCTAssertGreaterThan(more.frame.minX - refresh.frame.maxX, 4,
                             "Refresh and More should be separate toolbar buttons.")
        XCTAssertFalse(app.buttons["computer-session-take-control"].exists)
        XCTAssertFalse(app.staticTexts["View only"].exists)
        let zoomValue = app.buttons["computer-session-more"]
        XCTAssertTrue(zoomValue.exists)
        XCTAssertEqual(zoomValue.label, "More, zoom 100 percent")
        XCTAssertFalse(app.staticTexts["Waiting for a verified computer stream."].exists)
        retainMenuScreenshot(app, name: "Computer session unavailable", fullScreen: true)

        selectComputerMoreAction(app, identifier: "computer-session-zoom-in")
        XCTAssertEqual(zoomValue.label, "More, zoom 125 percent")
        selectComputerMoreAction(app, identifier: "computer-session-fit")
        XCTAssertEqual(zoomValue.label, "More, zoom 100 percent")
        app.buttons["computer-session-close"].tap()
        XCTAssertFalse(computerContainer.waitForExistence(timeout: 2))
    }

    func testDiagnosticsComputerSessionAvailableFixtureTakesControlAndReleasesIt() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-computer-session-fixture", "-diagnostics-computer-session-available-fixture"]
        app.launch()

        let computerContainer = app.descendants(matching: .any)
            .matching(identifier: "computer-session-container").firstMatch
        XCTAssertTrue(computerContainer.waitForExistence(timeout: 10))
        let picker = app.buttons["computer-session-connection-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "Connecting, screen live")
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
        let header = app.descendants(matching: .any).matching(identifier: "computer-session-header").firstMatch
        let controls = app.descendants(matching: .any).matching(identifier: "computer-session-controls-row").firstMatch
        XCTAssertLessThanOrEqual(preview.frame.minY - header.frame.maxY, 24,
                                 "The trackpad must include the black area below the computer status.")
        XCTAssertEqual(preview.frame.maxY, controls.frame.minY, accuracy: 1,
                       "The trackpad must reach the controls, including the lower black area.")
        let switcher = app.buttons["computer-session-shortcut-app-switcher"]
        switcher.tap()
        XCTAssertEqual(switcher.value as? String, "Open, Command held")
        app.buttons["computer-session-key-tab"].tap()
        XCTAssertEqual(switcher.value as? String, "Open, Command held")
        app.buttons["computer-session-key-escape"].tap()
        XCTAssertEqual(switcher.value as? String, "Closed")
        switcher.tap()
        switcher.tap()
        XCTAssertEqual(switcher.value as? String, "Closed")
        switcher.tap()
        app.otherElements["computer-session-preview"].tap()
        XCTAssertEqual(switcher.value as? String, "Closed")
        switcher.tap()
        let applications = app.buttons["computer-session-shortcut-applications"]
        applications.tap()
        XCTAssertEqual(switcher.value as? String, "Closed")
        app.buttons["computer-session-keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertComputerControlRow(app)
        app.typeText("Native keyboard fixture\n")
        app.buttons["computer-session-clipboard"].tap()
        let copy = app.buttons["computer-session-copy-from-mac"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(app.staticTexts["Copied from Mac"].waitForExistence(timeout: 5))
        retainMenuScreenshot(app, name: "Computer session control active", fullScreen: true)

        switcher.tap()
        XCTAssertEqual(switcher.value as? String, "Open, Command held")
        app.buttons["computer-session-done"].tap()
        XCTAssertTrue(takeControl.waitForExistence(timeout: 5))
        XCTAssertFalse(active.exists)
        takeControl.tap()
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        XCTAssertEqual(switcher.value as? String, "Closed")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(computerContainer.waitForExistence(timeout: 5), "Rotation must keep View Computer open.")
        retainMenuScreenshot(app, name: "Computer controls in landscape", fullScreen: true)
        assertComputerSideRail(app)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(computerContainer.waitForExistence(timeout: 5), "Returning to portrait must keep the same viewer open.")
        assertComputerControlRow(app)
        app.buttons["computer-session-close"].tap()
        XCTAssertFalse(computerContainer.waitForExistence(timeout: 2))
    }

    func testDiagnosticsComputerControlsStayOnOneRowAtAccessibilitySize() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        retainMenuScreenshot(app, name: "Single control row at largest accessibility text size", fullScreen: true)
        app.buttons["computer-session-done"].tap()
        XCTAssertTrue(takeControl.waitForExistence(timeout: 5))
        app.buttons["computer-session-close"].tap()
    }

    func testComputerViewerFromNewChatSurvivesPhoneRotation() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-connections-preview", "-diagnostics-computer-shell-fixture",
                               "-diagnostics-computer-session-available-fixture"]
        app.launch()
        let viewComputer = app.buttons["view-computer"]
        XCTAssertTrue(viewComputer.waitForExistence(timeout: 10))
        viewComputer.tap()
        let viewer = app.descendants(matching: .any).matching(identifier: "computer-session-container").firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        let picker = app.buttons["computer-session-connection-picker"]
        XCTAssertTrue(picker.exists)
        XCTAssertEqual(picker.value as? String, "Connected, screen live")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(viewer.waitForExistence(timeout: 5), "Rotating must keep the presented viewer, not return to New chat.")
        XCTAssertTrue(picker.isHittable)
        XCTAssertFalse(viewComputer.isHittable)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        app.buttons["computer-session-close"].tap()
        XCTAssertTrue(viewComputer.waitForExistence(timeout: 5))
    }

    func testDiagnosticsComputerLandscapeToolbarStaysAboveSideRail() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-computer-session-fixture", "-diagnostics-computer-session-available-fixture"]
        app.launch()
        let takeControl = app.buttons["computer-session-take-control"]
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        takeControl.tap()
        XCTAssertTrue(app.buttons["computer-session-done"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let viewer = app.descendants(matching: .any).matching(identifier: "computer-session-container").firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        assertComputerSideRail(app)
        retainMenuScreenshot(app, name: "Computer toolbar above landscape rail", fullScreen: true)
        app.buttons["computer-session-more"].tap()
        XCTAssertTrue(app.buttons["1080p"].waitForExistence(timeout: 5))
    }

    func testDiagnosticsComputerVideoQualityKeepsLiveControl() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-computer-session-fixture", "-diagnostics-computer-session-available-fixture"]
        app.launch()
        let takeControl = app.buttons["computer-session-take-control"]
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        takeControl.tap()
        let active = app.descendants(matching: .any).matching(identifier: "computer-session-control-active").firstMatch
        XCTAssertTrue(active.waitForExistence(timeout: 5))
        app.buttons["computer-session-more"].tap()
        let medium = app.buttons["1080p"]
        XCTAssertTrue(medium.waitForExistence(timeout: 5))
        medium.tap()
        XCTAssertTrue(active.waitForExistence(timeout: 5), "Changing quality must preserve the live control session.")
        XCTAssertFalse(takeControl.exists)
        app.buttons["computer-session-close"].tap()
    }

    func testDiagnosticsComputerPickerSwitchesHostsAndReleasesControl() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-computer-session-fixture", "-diagnostics-computer-session-available-fixture", "-connections-preview"]
        app.launch()
        let picker = app.buttons["computer-session-connection-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        let studio = app.buttons["computer-session-connection:studio"]
        XCTAssertTrue(studio.waitForExistence(timeout: 5))
        studio.tap()
        XCTAssertTrue(app.buttons["computer-session-take-control"].waitForExistence(timeout: 5))
        XCTAssertEqual(picker.label, "Computer, Studio")
        XCTAssertEqual(picker.value as? String, "Connected, screen live")
        app.buttons["computer-session-take-control"].tap()
        let switcher = app.buttons["computer-session-shortcut-app-switcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        switcher.tap()
        XCTAssertEqual(switcher.value as? String, "Open, Command held")
        picker.tap()
        let laptop = app.buttons["computer-session-connection:macbook"]
        XCTAssertTrue(laptop.waitForExistence(timeout: 5))
        laptop.tap()
        XCTAssertTrue(app.buttons["computer-session-take-control"].waitForExistence(timeout: 5))
        XCTAssertEqual(picker.label, "Computer, Laptop")
        XCTAssertEqual(picker.value as? String, "Connected, screen live")
        XCTAssertFalse(switcher.exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["computer-session-take-control"].tap()
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        XCTAssertEqual(switcher.value as? String, "Closed")
        picker.tap()
        app.buttons["computer-session-connection:macbook"].tap()
        XCTAssertTrue(switcher.exists, "Reselecting the same computer preserves the session.")
        retainMenuScreenshot(app, name: "Computer picker switched to Laptop", fullScreen: true)
        app.buttons["computer-session-close"].tap()
        XCTAssertTrue(app.staticTexts["Computer viewer closed"].waitForExistence(timeout: 5))
    }

    func testDiagnosticsComputerPointerModeMenuDoesNotOpenKeyboard() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        // A notification banner overlaps the toolbar on physical iPhones.
        // Let it disappear instead of tapping through it into another screen.
        let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .descendants(matching: .any).matching(identifier: "NotificationShortLookView").firstMatch
        if banner.exists { XCTAssertTrue(waitUntilGone(banner, timeout: 15)) }
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
        let shortcuts = ["all-windows", "app-windows", "next-window", "applications", "app-switcher"].map {
            app.buttons["computer-session-shortcut-" + $0]
        }
        for shortcut in shortcuts {
            XCTAssertTrue(shortcut.isHittable)
            XCTAssertGreaterThanOrEqual(shortcut.frame.width, 44)
            XCTAssertGreaterThanOrEqual(shortcut.frame.height, 44)
            XCTAssertEqual(shortcut.frame.midY, shortcuts[0].frame.midY, accuracy: 1)
            XCTAssertLessThanOrEqual(shortcut.frame.maxY, frames[0].minY + 1,
                                     "Shortcuts have their own row above the essential controls.")
        }
        if app.keyboards.firstMatch.exists {
            XCTAssertLessThanOrEqual(frames[0].maxY, app.keyboards.firstMatch.frame.minY + 2)
        }
    }

    private func assertComputerSideRail(_ app: XCUIApplication) {
        let preview = app.otherElements["computer-session-preview"]
        let controls = app.descendants(matching: .any).matching(identifier: "computer-session-controls-row").firstMatch
        let done = app.buttons["computer-session-done"]
        let refresh = app.buttons["computer-session-refresh"]
        let more = app.buttons["computer-session-more"]
        XCTAssertTrue(preview.exists && controls.exists && done.isHittable)
        XCTAssertTrue(refresh.isHittable && more.isHittable)
        XCTAssertLessThanOrEqual(refresh.frame.maxY, done.frame.minY + 2,
                                 "Refresh must stay above the landscape control rail.")
        XCTAssertLessThanOrEqual(more.frame.maxY, done.frame.minY + 2,
                                 "More must stay above the landscape control rail.")
        XCTAssertLessThanOrEqual(preview.frame.maxX, controls.frame.minX + 2)
        XCTAssertLessThanOrEqual(app.windows.firstMatch.frame.maxX - controls.frame.maxX, 12,
                                 "Landscape controls should sit close to the right edge.")
        XCTAssertGreaterThanOrEqual(preview.frame.maxY, controls.frame.maxY - 24,
                                    "The video viewport must reach the bottom safe area beside the rail.")
        XCTAssertLessThan(done.frame.midY, app.buttons["computer-session-shortcut-all-windows"].frame.midY)
        let left = app.buttons["computer-session-shortcut-all-windows"]
        let right = app.buttons["computer-session-shortcut-app-windows"]
        XCTAssertTrue(left.isHittable && right.isHittable)
        XCTAssertEqual(left.frame.midY, right.frame.midY, accuracy: 1)
        XCTAssertLessThan(left.frame.midX, right.frame.midX)
        for identifier in ["computer-session-shortcut-next-window", "computer-session-shortcut-applications",
                           "computer-session-shortcut-app-switcher", "computer-session-key-escape",
                           "computer-session-key-tab", "computer-session-clipboard", "computer-session-keyboard"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.isHittable, "Side control must be reachable: \(identifier)")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        try checkPhysicalComputerView()
    }

    private func checkPhysicalComputerView() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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

        openSidebarIfNeeded(app)
        let row = threadRows(app).firstMatch
        guard row.waitForExistence(timeout: 20) else {
            throw XCTSkip("Requires an unlocked physical device paired with the updated Wonder host.")
        }
        row.tap()
        let viewComputer = app.buttons["computer-status-pill"]
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
        for _ in 0..<10 {
            selectComputerMoreAction(app, identifier: "computer-session-zoom-in")
            let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "More, zoom 125 percent"), object: zoom)
            XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed, zoom.debugDescription)
            selectComputerMoreAction(app, identifier: "computer-session-fit")
            let fitted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "More, zoom 100 percent"), object: zoom)
            XCTAssertEqual(XCTWaiter.wait(for: [fitted], timeout: 5), .completed, zoom.debugDescription)
        }

        // Backgrounding must close the session and never reveal a stale frame
        // when Wonder returns to the foreground.
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.activate()
        XCTAssertFalse(computerView.waitForExistence(timeout: 10))
    }

    func testPhysicalComputerControlAcceptsInputAndReleases() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        let localNetworkMonitor = installWonderLocalNetworkPermissionMonitor()
        defer { removeUIInterruptionMonitor(localNetworkMonitor) }
        app.launch()

        openSidebarIfNeeded(app)
        let row = threadRows(app).firstMatch
        guard row.waitForExistence(timeout: 20) else {
            throw XCTSkip("Requires an unlocked physical device paired with the updated Wonder host.")
        }
        row.tap()
        let viewComputer = app.buttons["computer-status-pill"]
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
              isThreadRowIdentifier(qaRowID) else {
            throw XCTSkip("Supply WONDER_PAIRING_QA_CONVERSATION_ID with the exact dedicated QA thread-row accessibility identifier.")
        }
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        let localNetworkMonitor = installWonderLocalNetworkPermissionMonitor()
        defer { removeUIInterruptionMonitor(localNetworkMonitor) }
        app.launch()

        openSidebarIfNeeded(app)
        let settings = app.buttons["sidebar-settings"]
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
        leaveSettings(app)
        openSidebarIfNeeded(app)

        let row = app.buttons.matching(identifier: qaRowID).firstMatch
        guard row.waitForExistence(timeout: 20) else {
            throw XCTSkip("Requires the explicitly selected QA chat and a paired, unlocked physical device.")
        }
        row.tap()
        let viewComputer = app.buttons["computer-status-pill"]
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
        let trackpadY: CGFloat = 0.12
        let header = app.descendants(matching: .any).matching(identifier: "computer-session-header").firstMatch
        let sourceDescription = header.value as? String ?? ""
        let dimensions = sourceDescription.split(separator: "·").last?.split(separator: "×").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        } ?? []
        // The coordinator supplies the actual source aspect when capture has
        // a crop; otherwise the existing spoken source dimensions own it.
        let sourceAspect = ProcessInfo.processInfo.environment["WONDER_COMPUTER_SOURCE_ASPECT_RATIO"].flatMap(Double.init)
            ?? (dimensions.count == 2 && dimensions[1] > 0 ? dimensions[0] / dimensions[1] : 0)
        guard sourceAspect.isFinite, sourceAspect > 0 else {
            app.buttons["computer-session-done"].tap()
            app.buttons["computer-session-close"].tap()
            throw XCTSkip("Cannot verify the black trackpad area without the live source dimensions or crop aspect.")
        }
        let previewFrame = preview.frame
        let blackTopInset = (previewFrame.height - min(previewFrame.height, previewFrame.width / CGFloat(sourceAspect))) / 2
        guard trackpadY * previewFrame.height < blackTopInset else {
            app.buttons["computer-session-done"].tap()
            app.buttons["computer-session-close"].tap()
            throw XCTSkip("The planned trackpad swipe is outside the top black area for the current viewport/source geometry.")
        }
        let blackAreaEvidence = XCTAttachment(string: "Source: \(sourceDescription)\nSource aspect: \(sourceAspect)\nViewport: \(previewFrame)\nTop black inset: \(blackTopInset)\nSwipe start: \(CGPoint(x: previewFrame.minX + previewFrame.width * 0.47, y: previewFrame.minY + previewFrame.height * trackpadY))\nSwipe end: \(CGPoint(x: previewFrame.minX + previewFrame.width * 0.53, y: previewFrame.minY + previewFrame.height * trackpadY))\nSwipes stay in the black area; remote pointer outcomes require independent Mac fixture receipts.")
        blackAreaEvidence.name = "Physical black trackpad geometry"
        blackAreaEvidence.lifetime = .keepAlways
        add(blackAreaEvidence)
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
            let from = preview.coordinate(withNormalizedOffset: CGVector(dx: fromX, dy: trackpadY))
            let to = preview.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: trackpadY))
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
              isThreadRowIdentifier(qaRowID) else {
            throw XCTSkip("Supply WONDER_PAIRING_QA_CONVERSATION_ID with the exact dedicated QA thread-row accessibility identifier.")
        }
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        let localNetworkMonitor = installWonderLocalNetworkPermissionMonitor()
        defer { removeUIInterruptionMonitor(localNetworkMonitor) }
        app.launch()

        openSidebarIfNeeded(app)
        let row = app.buttons.matching(identifier: qaRowID).firstMatch
        guard row.waitForExistence(timeout: 20) else {
            throw XCTSkip("Requires the explicitly selected QA chat and a paired, unlocked physical device.")
        }
        row.tap()
        let viewComputer = app.buttons["computer-status-pill"]
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
              isThreadRowIdentifier(qaRowID) else {
            throw XCTSkip("Supply WONDER_PAIRING_QA_CONVERSATION_ID with the exact dedicated QA thread-row accessibility identifier.")
        }
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        let localNetworkMonitor = installWonderLocalNetworkPermissionMonitor()
        defer { removeUIInterruptionMonitor(localNetworkMonitor) }
        app.launch()

        openSidebarIfNeeded(app)
        let row = app.buttons.matching(identifier: qaRowID).firstMatch
        guard row.waitForExistence(timeout: 20) else {
            throw XCTSkip("Requires the explicitly selected QA chat and a paired, unlocked physical device.")
        }
        row.tap()
        let viewComputer = app.buttons["computer-status-pill"]
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
        let externallyRevoked = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                takeControl.exists && !active.exists
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [externallyRevoked], timeout: 180),
            .completed,
            "The phone did not leave active control after the external Mac revocation."
        )
        XCTAssertTrue(takeControl.exists)
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

    private func retainMenuScreenshot(_ app: XCUIApplication, name: String, fullScreen: Bool = false) {
        let attachment = XCTAttachment(screenshot: fullScreen ? XCUIScreen.main.screenshot() : app.screenshot())
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launch()
        openSidebarIfNeeded(app)
        let chat = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Wonder iOS")).firstMatch
        guard chat.waitForExistence(timeout: 15) else { throw XCTSkip("Requires the paired Wonder iOS conversation.") }
        chat.tap()
        let scroll = anyElement(app, identifier: "conversation-scroll")
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
                XCTAssertTrue(workspacePreviewClose(app, legacyID: "photo-viewer-close").waitForExistence(timeout: 5))
                viewerImage.doubleTap()
                let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "200%"), object: viewerImage)
                XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed)
                viewerImage.press(forDuration: 1.0)
                XCTAssertTrue(app.buttons["Copy image"].waitForExistence(timeout: 5))
                app.buttons["Copy image"].tap()
                XCTAssertTrue(app.staticTexts["Image copied"].waitForExistence(timeout: 5))
                retainMenuScreenshot(app, name: "Live fullscreen image after zoom and copy")
                workspacePreviewClose(app, legacyID: "photo-viewer-close").tap()
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launch()
        openSidebarIfNeeded(app)
        let chat = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Wonder iOS")).firstMatch
        guard chat.waitForExistence(timeout: 15) else { throw XCTSkip("Requires the paired Wonder iOS conversation with a generated image.") }
        chat.tap()
        let scroll = anyElement(app, identifier: "conversation-scroll")
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

    /// Read-only physical performance pass over explicitly selected, already
    /// read conversations. It opens, scrolls through older history, returns to
    /// the bottom and switches chats. No message, read-state change or model
    /// work is requested beyond what opening an already-read chat does.
    func testLiveConversationOpenScrollAndSwitch() throws {
        continueAfterFailure = false
        let ids = (ProcessInfo.processInfo.environment["WONDER_PERF_CONVERSATION_IDS"] ?? "")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw XCTSkip("Supply WONDER_PERF_CONVERSATION_IDS with already-read conversation IDs.") }
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchEnvironment["WONDER_DIAGNOSTICS_CAPTURE"] = "1"
        let launchStart = Date()
        app.launch()
        openSidebarIfNeeded(app)
        func row(_ id: String) -> XCUIElement {
            threadRows(app).matching(NSPredicate(format: "identifier ENDSWITH %@", ":" + id)).firstMatch
        }
        guard row(ids[0]).waitForExistence(timeout: 30) else {
            retainMenuScreenshot(app, name: "Selected conversation rows missing")
            let rows = threadRows(app).allElementsBoundByIndex.prefix(40).map(\.identifier)
            let evidence = XCTAttachment(string: "state=\(app.state.rawValue)\nrows=\(rows.joined(separator: "\n"))")
            evidence.name = "Visible chat rows"; evidence.lifetime = .keepAlways; add(evidence)
            throw XCTSkip("Requires a paired device listing the selected conversations.")
        }
        var samples = ["listVisibleAfterLaunchMs=\(Int(Date().timeIntervalSince(launchStart) * 1000))"]
        var openDurations: [Double] = []
        let options = XCTMeasureOptions()
        options.iterationCount = Int(ProcessInfo.processInfo.environment["WONDER_PERF_ITERATIONS"] ?? "") ?? 5
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            for id in ids {
                let chat = row(id)
                if !chat.isHittable { openSidebarIfNeeded(app) }
                guard chat.waitForExistence(timeout: 15) else { XCTFail("Missing conversation row \(id)"); return }
                let start = Date()
                chat.tap()
                let scroll = anyElement(app, identifier: "conversation-scroll")
                guard scroll.waitForExistence(timeout: 20), app.textViews["message-draft"].waitForExistence(timeout: 20) else {
                    XCTFail("Conversation \(id) did not open"); return
                }
                openDurations.append(Date().timeIntervalSince(start) * 1000)
                for _ in 0..<4 { scroll.swipeDown(velocity: .fast) }
                let bottom = app.buttons["scroll-to-bottom"]
                if bottom.waitForExistence(timeout: 2) { bottom.tap() } else { for _ in 0..<4 { scroll.swipeUp(velocity: .fast) } }
                for _ in 0..<2 { scroll.swipeDown(); scroll.swipeUp() }
            }
        }
        let sorted = openDurations.sorted()
        func percentile(_ p: Double) -> Int { sorted.isEmpty ? 0 : Int(sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]) }
        samples.append("openToComposerMs n=\(sorted.count) p50=\(percentile(0.5)) p95=\(percentile(0.95)) max=\(Int(sorted.last ?? 0))")
        let evidence = XCTAttachment(string: samples.joined(separator: "\n"))
        evidence.name = "Live open/scroll/switch timings"; evidence.lifetime = .keepAlways; add(evidence)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Share to Wonder from Photos reads the paired Mac's chats with the app's
    /// saved session and stages the photo. It cancels before Send.
    func testLiveShareExtensionStagesPhotoAndListsChatsWithoutSending() throws {
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        addUIInterruptionMonitor(withDescription: "Photos prompts") { alert in
            for label in ["Don’t Allow", "Continue", "Not Now"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
        if photos.buttons["Continue"].waitForExistence(timeout: 3) { photos.buttons["Continue"].tap() }
        let photo = photos.images.matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "PXGGridLayout-Info", "Photo")).firstMatch
        guard photo.waitForExistence(timeout: 15) else {
            let tree = XCTAttachment(string: photos.debugDescription); tree.name = "Photos hierarchy"; tree.lifetime = .keepAlways; add(tree)
            throw XCTSkip("The simulator Photos library has no images.")
        }
        let share = photos.buttons["Share"]
        for _ in 0..<3 where !share.isHittable {
            photo.exists ? photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() : photos.tap()
            _ = share.waitForExistence(timeout: 3)
        }
        retainMenuScreenshot(photos, name: "Photos before sharing")
        XCTAssertTrue(share.isHittable, "Photos did not show its Share button.")
        share.tap()
        let wonder = photos.cells.matching(NSPredicate(format: "label == %@", appDisplayName)).firstMatch
        XCTAssertTrue(wonder.waitForExistence(timeout: 15), "Wonder is not offered in the share sheet.")
        wonder.tap()

        let send = photos.buttons["share-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 20), "The Wonder share sheet did not open.")
        // The extension is a remote view: typed button and text queries reach it.
        let note = photos.textViews["share-note"].exists ? photos.textViews["share-note"] : photos.textFields["share-note"]
        if !photos.buttons["share-attachment-remove"].waitForExistence(timeout: 20) {
            let dump = XCTAttachment(string: photos.buttons.debugDescription + "\n\n" + photos.textViews.debugDescription)
            dump.name = "Share buttons"; dump.lifetime = .keepAlways; add(dump)
            retainMenuScreenshot(photos, name: "Share extension staging")
            XCTFail("The shared photo was not staged.")
        }
        let destination = photos.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "share-destination:")).firstMatch
        guard destination.waitForExistence(timeout: 30) else {
            retainMenuScreenshot(photos, name: "Share extension without chats")
            throw XCTSkip("Requires a simulator paired with a reachable Mac that has at least one chat.")
        }
        XCTAssertFalse(send.isEnabled, "Send must wait for a chosen chat.")
        if note.exists { note.tap(); note.typeText("Share extension check") }
        destination.tap()
        XCTAssertTrue(destination.isSelected)
        XCTAssertTrue(send.isEnabled)
        retainMenuScreenshot(photos, name: "Share to Wonder ready without sending")
        photos.buttons["Cancel"].tap()
        XCTAssertTrue(waitUntilGone(send, timeout: 10), "Cancel did not close the share sheet.")
    }

    func testLiveImagePreview() throws {
        continueAfterFailure=false
        let app=XCUIApplication(bundleIdentifier:appBundleIdentifier)
        app.launch()
        openSidebarIfNeeded(app)
        let chat=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@", "Diagnostics image preview")).firstMatch
        guard chat.waitForExistence(timeout:15) else { throw XCTSkip("Prepare the dedicated image test thread with Preview fixture 4000x3000.png first.") }
        chat.tap()
        openConversationDetails(app)
        app.buttons["conversation-details-files"].tap()
        let file=app.buttons["Preview fixture 4000x3000.png"]
        XCTAssertTrue(file.waitForExistence(timeout:10))
        let options=XCTMeasureOptions(); options.iterationCount=3
        measure(metrics:[XCTClockMetric(),XCTMemoryMetric()],options:options) {
            file.tap()
            let photo = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo-viewer-image:")).firstMatch
            XCTAssertTrue(photo.waitForExistence(timeout:10))
            XCTAssertTrue(workspacePreviewClose(app, legacyID: "photo-viewer-close").waitForExistence(timeout:10))
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
            workspacePreviewClose(app, legacyID: "photo-viewer-close").tap()
            XCTAssertTrue(file.waitForExistence(timeout:5))
        }
    }

    func testLiveWorkspaceBrowserIsReadOnlyAndNavigable() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launch()
        openSidebarIfNeeded(app)
        let chat = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Wonder iOS")).firstMatch
        guard chat.waitForExistence(timeout: 15) else { throw XCTSkip("Requires the paired Wonder iOS conversation.") }
        chat.tap()
        openConversationDetails(app)
        XCTAssertTrue(app.buttons["conversation-details-files"].waitForExistence(timeout: 5))
        app.buttons["conversation-details-files"].tap()

        let picker = app.buttons["workspace-view-toggle"]
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
            XCTAssertTrue(workspacePreviewClose(app, legacyID: "workspace-diff-close").waitForExistence(timeout: 15))
            retainMenuScreenshot(app, name: "Live read-only workspace diff")
            workspacePreviewClose(app, legacyID: "workspace-diff-close").tap()
            XCTAssertTrue(changed.waitForExistence(timeout: 10))
        } else {
            XCTAssertTrue(noChanges.exists)
            retainMenuScreenshot(app, name: "Live workspace has no modified files")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testDiagnosticsPhotoViewerRoutesImagesDocumentsAndFailures() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview", "-preview-malformed-image"]
        app.launch()

        let computerPill = app.buttons["computer-status-pill"]
        XCTAssertTrue(computerPill.waitForExistence(timeout: 10))
        XCTAssertEqual(computerPill.label, "View computer")
        computerPill.tap()
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
        XCTAssertTrue(computerPill.waitForExistence(timeout: 10))
        openConversationDetails(app)
        XCTAssertTrue(app.buttons["conversation-details-files"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@",
                                                        "View computer", "computer-status-pill")).count, 0,
                       "View computer moved to the conversation's status pill.")
        XCTAssertFalse(app.buttons["Teach a task"].exists,
                       "Teaching is not available in the beta conversation menu.")
        app.buttons["conversation-details-files"].tap()

        let imageFile = app.buttons["Saturday.png"]
        let documentFile = app.buttons["notes.txt"]
        let malformedFile = app.buttons["broken.png"]
        XCTAssertTrue(app.collectionViews["workspace-file-list"].waitForExistence(timeout: 10))
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
            XCTAssertTrue(workspacePreviewClose(app, legacyID: "photo-viewer-close").waitForExistence(timeout: 5))
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
            workspacePreviewClose(app, legacyID: "photo-viewer-close").tap()
            XCTAssertTrue(imageFile.waitForExistence(timeout: 5))
        }
        XCTAssertEqual(imageFile.frame, originalImageFrame)

        documentFile.tap()
        XCTAssertTrue(app.buttons["workspace-preview-back"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save a copy"].exists)
        XCTAssertFalse(app.buttons["Details"].exists)
        retainMenuScreenshot(app, name: "Workspace document preview")
        workspacePreviewClose(app, legacyID: "workspace-document-close").tap()
        XCTAssertTrue(documentFile.waitForExistence(timeout: 5))

        malformedFile.tap()
        XCTAssertTrue(anyElement(app, identifier: "photo-viewer-error").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save a copy"].exists)
        XCTAssertTrue(workspacePreviewClose(app, legacyID: "photo-viewer-close").isHittable)
        retainMenuScreenshot(app, name: "Photo viewer failure")
        workspacePreviewClose(app, legacyID: "photo-viewer-close").tap()
        XCTAssertTrue(malformedFile.waitForExistence(timeout: 5))
        // Files opened from Details is a sheet without the composer's Files button.
        let done = app.buttons["workspace-sheet-done"]
        XCTAssertTrue(done.isHittable)
        retainMenuScreenshot(app, name: "Files sheet from Details with Done")
        done.tap()
        XCTAssertTrue(app.collectionViews["workspace-file-list"].waitForNonExistence(timeout: 5))
    }

    func testDiagnosticsWorkspaceBrowserViewsNavigationAndGitDiff() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview"]
        app.launch()

        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        XCTAssertTrue(files.isHittable)
        files.tap()
        let picker = app.buttons["workspace-view-toggle"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "Workspace browser preview is unavailable in this build.")
        guard picker.exists else { return }
        XCTAssertTrue(app.buttons["workspace-directory-entry:Projects"].waitForExistence(timeout: 5))
        let initial = XCTAttachment(screenshot: app.screenshot()); initial.name = "Workspace all files"; initial.lifetime = .keepAlways; add(initial)

        app.buttons["workspace-directory-entry:Projects"].tap()
        XCTAssertTrue(app.buttons["workspace-file-entry:Projects/Plan.md"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workspace-hidden-toggle"].exists, "Hidden files can be shown inside subfolders too")
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
        XCTAssertTrue(workspacePreviewClose(app, legacyID: "workspace-diff-close").waitForExistence(timeout: 5))
        let diff = XCTAttachment(screenshot: app.screenshot()); diff.name = "Workspace modified diff"; diff.lifetime = .keepAlways; add(diff)
        workspacePreviewClose(app, legacyID: "workspace-diff-close").tap()
        XCTAssertTrue(app.buttons["workspace-modified-entry:README.md"].waitForExistence(timeout: 5))
    }

    func testWorkspaceHiddenRefreshCannotReplaceNavigatedProjectFolder() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview", "-workspace-delayed-hidden"]
        app.launch()
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        let projectFolder = app.buttons["workspace-directory-entry:Projects"]
        XCTAssertTrue(projectFolder.waitForExistence(timeout: 10))
        let hiddenToggle = app.buttons["workspace-hidden-toggle"]
        hiddenToggle.tap()
        XCTAssertEqual(hiddenToggle.value as? String, "On")
        // The app process keeps running while XCTest waits; give the delayed
        // fixture request a turn before changing the browser location.
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertFalse(app.descendants(matching: .any)["workspace-refreshing"].exists,
                       "Background refresh must not interrupt browsing with a spinner")
        projectFolder.tap()
        let plan = app.buttons["workspace-file-entry:Projects/Plan.md"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 3.5)
        XCTAssertTrue(plan.exists, "The late root response must not replace the Project folder")
        XCTAssertFalse(app.buttons["workspace-file-entry:.gitignore"].exists,
                       "A hidden file from the previous folder must not appear in Projects")
        XCTAssertFalse(app.descendants(matching: .any)["workspace-unavailable"].exists)
    }

    func testWorkspaceQuietRefreshKeepsLoadedPages() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview", "-workspace-paged-preview"]
        app.launch()
        app.buttons["conversation-files-pill"].tap()
        let more = app.buttons["workspace-next-page"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let lastFile = app.buttons["workspace-file-entry:diagram.png"]
        XCTAssertTrue(lastFile.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["workspace-refresh"].exists)
        Thread.sleep(forTimeInterval: 14)
        XCTAssertTrue(lastFile.exists, "A quiet refresh must keep the pages already loaded")
        XCTAssertFalse(app.descendants(matching: .any)["workspace-refreshing"].exists)
    }

    func testWorkspaceLoadMoreWinsOverBackgroundRefresh() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview",
                               "-workspace-paged-preview", "-workspace-delayed-background-roots"]
        app.launch()
        app.buttons["conversation-files-pill"].tap()
        let more = app.buttons["workspace-next-page"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 13)
        more.tap()
        let lastFile = app.buttons["workspace-file-entry:diagram.png"]
        XCTAssertTrue(lastFile.waitForExistence(timeout: 8),
                      "Explicit pagination must win while background roots are being refreshed")
        Thread.sleep(forTimeInterval: 5.5)
        XCTAssertTrue(lastFile.exists, "A late background response must retain the loaded page")
    }

    func testWorkspaceModifiedLoadsAfterDelayedRoots() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview", "-workspace-delayed-roots"]
        app.launch()
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        let picker = app.buttons["workspace-view-toggle"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Loading files…"].exists)
        app.buttons["Modified"].tap()
        XCTAssertTrue(app.staticTexts["Checking changes…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workspace-modified-entry:README.md"].waitForExistence(timeout: 12),
                      "Modified should load when the delayed workspace root becomes available")
    }

    func testWorkspaceGitAndDiffRepliesStayWithCurrentFilesView() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview", "-workspace-delayed-git"]
        app.launch()
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        XCTAssertTrue(app.buttons["workspace-directory-entry:Projects"].waitForExistence(timeout: 10))
        app.buttons["Modified"].tap()
        XCTAssertTrue(app.staticTexts["Checking changes…"].waitForExistence(timeout: 5))
        app.buttons["workspace-view-toggle"].tap()
        XCTAssertTrue(app.buttons["workspace-directory-entry:Projects"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 3.5)
        XCTAssertTrue(app.buttons["workspace-directory-entry:Projects"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["workspace-unavailable"].exists,
                       "The delayed Git failure belongs to Modified, not All files")

        app.terminate()
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview", "-workspace-delayed-diff"]
        app.launch()
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        app.buttons["Modified"].tap()
        let readme = app.buttons["workspace-modified-entry:README.md"]
        let renamed = app.buttons["workspace-modified-entry:new-name.md"]
        XCTAssertTrue(readme.waitForExistence(timeout: 5))
        readme.tap()
        XCTAssertTrue(app.descendants(matching: .any)["workspace-diff-loading"].waitForExistence(timeout: 5),
                      "A slow diff should show that Files is opening it")
        renamed.tap()
        XCTAssertTrue(workspacePreviewClose(app, legacyID: "workspace-diff-close").waitForExistence(timeout: 5))
        let diffText = anyElement(app, identifier: "workspace-diff-text")
        XCTAssertTrue(diffText.waitForExistence(timeout: 5))
        XCTAssertTrue((diffText.label).contains("new-name.md"))
        Thread.sleep(forTimeInterval: 3.5)
        XCTAssertTrue(diffText.label.contains("new-name.md"),
                      "A late README diff must not replace the currently selected diff")
        XCTAssertFalse(diffText.label.contains("README.md"))
    }

    private func revealControl(_ control: XCUIElement, in scroll: XCUIElement, fullyVisible: Bool = true, minimumVisibleHeight: CGFloat = 0) {
        for _ in 0..<15 {
            if control.exists && control.isHittable && control.frame.intersection(scroll.frame).height > minimumVisibleHeight &&
                (!fullyVisible || scroll.frame.insetBy(dx: -1, dy: -1).contains(control.frame)) { return }
            let above = control.exists && control.frame.height > 0 && control.frame.minY < scroll.frame.minY
            if control.exists && control.frame.intersects(scroll.frame) {
                let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                let end = start.withOffset(CGVector(dx: 0, dy: above ? 60 : -60))
                start.press(forDuration: 0, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: 50), thenHoldForDuration: 0.5)
            } else if above { scroll.swipeDown() }
            else { scroll.swipeUp() }
        }
        XCTAssertTrue(control.exists && control.isHittable, "Control \(control.identifier) frame \(control.frame) in viewport \(scroll.frame)")
        if fullyVisible { XCTAssertTrue(scroll.frame.insetBy(dx: -1, dy: -1).contains(control.frame), "Control \(control.identifier) frame \(control.frame) in viewport \(scroll.frame)") }
    }
    func testProjectConversationFilesPreviewExpandDiffAndKeepComposer() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview", "-project-files-conversation-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["conversation-title-menu"].waitForExistence(timeout: 10))
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        XCTAssertTrue(files.isHittable)
        files.tap()
        let workspace = app.collectionViews["workspace-file-list"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["workspace-close"].exists)
        XCTAssertFalse(app.buttons["workspace-refresh"].exists)
        XCTAssertTrue(app.buttons["workspace-hidden-toggle"].exists)
        retainMenuScreenshot(app, name: "Project Files inside chat")
        let draft = app.textViews["message-draft"]
        XCTAssertTrue(draft.isHittable, "The composer stays available beside Files")
        XCTAssertFalse(anyElement(app, identifier: "conversation-scroll").exists,
                       "Files replaces the chat timeline")
        let file = app.buttons["workspace-file-entry:README.md"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        XCTAssertTrue(app.buttons["workspace-preview-expand"].waitForExistence(timeout: 5))
        retainMenuScreenshot(app, name: "Project file preview inside chat")
        app.buttons["workspace-preview-expand"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-collapse"].waitForExistence(timeout: 5))
        retainMenuScreenshot(app, name: "Project file expanded")
        app.buttons["workspace-preview-collapse"].tap()
        XCTAssertTrue(draft.isHittable)
        XCTAssertTrue(workspacePreviewClose(app, legacyID: "workspace-document-close").waitForExistence(timeout: 5))
        workspacePreviewClose(app, legacyID: "workspace-document-close").tap()
        app.buttons["Modified"].tap()
        let changed = app.buttons["workspace-modified-entry:README.md"]
        XCTAssertTrue(changed.waitForExistence(timeout: 5))
        changed.tap()
        XCTAssertTrue(workspacePreviewClose(app, legacyID: "workspace-diff-close").waitForExistence(timeout: 5))
        app.buttons["workspace-preview-expand"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-collapse"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "workspace-diff-text").count, 1,
                       "Full screen should keep one diff layout")
        app.buttons["workspace-preview-collapse"].tap()
        workspacePreviewClose(app, legacyID: "workspace-diff-close").tap()
        XCTAssertTrue(draft.isHittable)
        draft.tap()
        draft.typeText("Review these files")
        XCTAssertTrue(changed.waitForExistence(timeout: 5),
                      "Editing the composer must keep the Files workspace open")
        closeWorkspace(app)
        XCTAssertTrue(files.waitForExistence(timeout: 5))
    }

    func testProjectFilesStayUsableInResizedIPadWindow() throws {
        continueAfterFailure = false
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad window resizing") }
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-chat-layout", "-diagnostics-chat-layout-unsaved",
                               "-diagnostics-project-files-send", "-diagnostics-usage-fixture"]
        app.launch()
        openSidebarIfNeeded(app)
        let thread = app.buttons["pinned-thread:codex:read-fixture"]
        XCTAssertTrue(thread.waitForExistence(timeout: 15))
        thread.tap()
        XCTAssertTrue(app.buttons["conversation-files-pill"].waitForExistence(timeout: 10))
        let originalWidth = app.windows.firstMatch.frame.width
        XCTAssertGreaterThan(originalWidth, 850, "Use a regular full-screen iPad before resizing")

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: 0.985))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.82))
        start.press(forDuration: 0.1, thenDragTo: end)
        let deadline = Date().addingTimeInterval(6)
        while app.windows.firstMatch.frame.width >= originalWidth - 150 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        let resizedWidth = app.windows.firstMatch.frame.width
        print("Resized iPad window: \(originalWidth) -> \(resizedWidth) points")
        XCTAssertLessThan(resizedWidth, originalWidth - 150,
                          "The app must actually enter a narrower iPad window")
        XCTAssertGreaterThan(resizedWidth, 500, "This test targets a side-by-side iPad width")
        XCTAssertLessThan(resizedWidth, 760, "This test requires a compact iPad window")
        // The system finishes its resize animation after the reported frame changes.
        Thread.sleep(forTimeInterval: 1.5)
        let timeline = app.descendants(matching: .any)["conversation-scroll"]
        let draftInConversation = app.textViews["message-draft"]
        print("Resized timeline frame: \(timeline.frame); draft frame: \(draftInConversation.frame)")
        XCTAssertFalse(app.staticTexts["Agent tasks need a newer Wonder on your computer. Update it, then refresh this Project thread."].exists,
                       "Agent-task availability is not a composer notice")
        XCTAssertTrue(draftInConversation.exists)
        XCTAssertLessThanOrEqual(timeline.frame.maxY, draftInConversation.frame.minY + 2,
                                 "The chat viewport must stop above the composer in a narrow iPad window")
        retainMenuScreenshot(app, name: "Project Files in resized iPad window", fullScreen: true)

        let chats = app.buttons["compact-ipad-chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 5) && chats.isHittable,
                      "Chats must remain reachable below the floating iPad window controls")
        chats.tap()
        XCTAssertTrue(app.textFields["sidebar-search"].waitForExistence(timeout: 5),
                      "The compact Chats control must open the conversation list")
        retainMenuScreenshot(app, name: "Chats in resized iPad window", fullScreen: true)
        app.buttons["sidebar-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5),
                      "Settings must open from compact Chats")
        leaveSettings(app)
        XCTAssertTrue(app.buttons["conversation-files-pill"].waitForExistence(timeout: 5),
                      "Returning from Chats must keep the conversation")
        chats.tap()
        XCTAssertTrue(thread.waitForExistence(timeout: 5))
        thread.tap()

        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.isHittable)
        files.tap()
        XCTAssertTrue(app.collectionViews["workspace-file-list"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["message-draft"].isHittable)
        let readme = app.buttons["workspace-file-entry:README.md"]
        XCTAssertTrue(readme.waitForExistence(timeout: 5))
        readme.tap()
        XCTAssertTrue(app.buttons["workspace-preview-expand"].isHittable)
        XCTAssertTrue(app.textViews["message-draft"].isHittable)
        retainMenuScreenshot(app, name: "Project preview in resized iPad window", fullScreen: true)
        selectTextForPreviewComment(app)
        let note = app.descendants(matching: .any)["annotation-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap(); note.typeText("Check this sentence")
        app.buttons["annotation-add"].tap()
        XCTAssertTrue(app.buttons["composer-annotation-edit"].waitForExistence(timeout: 5),
                      "A note from the narrow preview must stage in the composer")
        retainMenuScreenshot(app, name: "Project note in resized iPad window", fullScreen: true)
    }

    func testProjectFilesKeepsSelectedPreviewDuringOfflineMessageSend() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-chat-layout", "-diagnostics-chat-layout-unsaved",
                               "-diagnostics-project-files-send", "-diagnostics-usage-fixture"]
        app.launch()
        openSidebarIfNeeded(app)
        let thread = app.buttons["pinned-thread:codex:read-fixture"]
        XCTAssertTrue(thread.waitForExistence(timeout: 15))
        thread.tap()
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        let file = app.buttons["workspace-file-entry:README.md"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        let preview = app.textViews["annotation-selectable-text"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue((preview.value as? String)?.contains("Live workspace note.") == true)
        selectTextForPreviewComment(app)
        let note = app.descendants(matching: .any)["annotation-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap(); note.typeText("Keep this unfinished comment")
        let draft = app.textViews["message-draft"]
        XCTAssertTrue(draft.isHittable)
        draft.tap(); draft.typeText("Review this file while Files stays open.")
        app.buttons["send-message"].tap()
        let expand = app.buttons["workspace-preview-expand"]
        let received = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Host received test message"), object: expand)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 15), .completed,
                       "The host must acknowledge the message while Files remains open")
        XCTAssertTrue(expand.exists,
                      "Sending must leave the selected file in the chat workspace")
        let plainPreview = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Live workspace note.")).firstMatch
        XCTAssertTrue(plainPreview.waitForExistence(timeout: 10) || preview.waitForExistence(timeout: 2),
                      "The same file content should remain visible while the send is pending")
        XCTAssertEqual(note.value as? String, "Keep this unfinished comment",
                       "A pending message must not hide or discard a separate comment draft")
        XCTAssertTrue(app.staticTexts["annotation-comment-wait"].exists)
        XCTAssertFalse(app.buttons["annotation-add"].isEnabled)
        XCTAssertFalse(anyElement(app, identifier: "conversation-scroll").exists,
                       "Files should still replace the timeline after the send")
        retainMenuScreenshot(app, name: "Project file stays open after offline send")
        app.buttons["workspace-preview-back"].tap()
        closeWorkspace(app)
        let bottom = app.buttons["scroll-to-bottom"]
        if bottom.exists && bottom.isHittable { bottom.tap() }
        XCTAssertTrue(app.images["Received by your Mac"].waitForExistence(timeout: 10),
                      "The synthetic host must acknowledge the exact message")
    }

    func testProjectFilesRefreshesAfterOfflineMessageWhileOpen() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-chat-layout", "-diagnostics-chat-layout-unsaved",
                               "-diagnostics-project-files-send", "-diagnostics-project-files-refresh",
                               "-diagnostics-usage-fixture"]
        app.launch()
        openSidebarIfNeeded(app)
        let thread = app.buttons["pinned-thread:codex:read-fixture"]
        XCTAssertTrue(thread.waitForExistence(timeout: 15))
        thread.tap()
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        XCTAssertTrue(app.buttons["workspace-file-entry:README.md"].waitForExistence(timeout: 10))
        let update = app.buttons["workspace-file-entry:Project update.md"]
        XCTAssertFalse(update.exists)
        let draft = app.textViews["message-draft"]
        XCTAssertTrue(draft.isHittable)
        draft.tap(); draft.typeText("Review this file while Files stays open.")
        app.buttons["send-message"].tap()
        XCTAssertTrue(update.waitForExistence(timeout: 20),
                      "The acknowledged Project turn must refresh the open Files listing")
        XCTAssertTrue(app.buttons["workspace-file-entry:README.md"].exists)
        XCTAssertFalse(anyElement(app, identifier: "conversation-scroll").exists)
        app.buttons["Modified"].tap()
        XCTAssertTrue(app.buttons["workspace-modified-entry:Project update.md"].waitForExistence(timeout: 10))
        XCTAssertTrue(draft.isHittable)
        retainMenuScreenshot(app, name: "Project Files refreshes after host receipt")
        closeWorkspace(app)
        let bottom = app.buttons["scroll-to-bottom"]
        if bottom.exists && bottom.isHittable { bottom.tap() }
        XCTAssertTrue(app.images["Received by your Mac"].waitForExistence(timeout: 10),
                      "The host must accept the exact synthetic Project message")
    }

    func testProjectFilesRefreshRetriesAfterTransientFailure() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-chat-layout", "-diagnostics-chat-layout-unsaved",
                               "-diagnostics-project-files-send", "-diagnostics-project-files-refresh",
                               "-diagnostics-project-files-refresh-fail-once", "-diagnostics-usage-fixture"]
        app.launch()
        openSidebarIfNeeded(app)
        let thread = app.buttons["pinned-thread:codex:read-fixture"]
        XCTAssertTrue(thread.waitForExistence(timeout: 15))
        thread.tap()
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        XCTAssertTrue(app.buttons["workspace-file-entry:README.md"].waitForExistence(timeout: 10))
        let draft = app.textViews["message-draft"]
        draft.tap(); draft.typeText("Review this file while Files stays open.")
        app.buttons["send-message"].tap()
        XCTAssertFalse(app.buttons["workspace-refresh-retry"].exists,
                       "A failed background read must keep the prior listing without a refresh banner")
        XCTAssertTrue(app.buttons["workspace-file-entry:README.md"].exists)
        XCTAssertTrue(app.buttons["workspace-file-entry:Project update.md"].waitForExistence(timeout: 15),
                      "Files must retry after reconnection without another Project event or manual tap")
        XCTAssertFalse(app.descendants(matching: .any)["workspace-refreshing"].exists)
        XCTAssertTrue(draft.isHittable)
    }

    func testProjectFilesClearRevokedRootsAfterInitialLoad() throws {
        verifyProjectFilesRevocation(argument: "-diagnostics-project-files-revoked-roots", modified: false)
    }

    func testProjectFilesClearRevokedDirectoryAfterInitialLoad() throws {
        verifyProjectFilesRevocation(argument: "-diagnostics-project-files-revoked-directory", modified: false)
    }

    func testProjectFilesClearRevokedGitAfterInitialLoad() throws {
        verifyProjectFilesRevocation(argument: "-diagnostics-project-files-revoked-git", modified: true)
    }

    private func verifyProjectFilesRevocation(argument: String, modified: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-chat-layout", "-diagnostics-chat-layout-unsaved",
                               "-diagnostics-project-files-send", "-diagnostics-project-files-refresh",
                               argument, "-diagnostics-usage-fixture"]
        app.launch()
        openSidebarIfNeeded(app)
        let thread = app.buttons["pinned-thread:codex:read-fixture"]
        XCTAssertTrue(thread.waitForExistence(timeout: 15))
        thread.tap()
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        let oldFile = app.buttons["workspace-file-entry:README.md"]
        XCTAssertTrue(oldFile.waitForExistence(timeout: 10))
        let draft = app.textViews["message-draft"]
        draft.tap(); draft.typeText("Review this file while Files stays open.")
        app.buttons["send-message"].tap()
        if modified {
            XCTAssertTrue(app.buttons["workspace-file-entry:Project update.md"].waitForExistence(timeout: 15),
                          "The message must be accepted before Git access is revoked")
            app.buttons["Modified"].tap()
        }
        let unavailable = anyElement(app, identifier: "workspace-unavailable")
        XCTAssertTrue(unavailable.waitForExistence(timeout: 15),
                      "A denied workspace refresh must hide the previously authorized listing")
        XCTAssertFalse(oldFile.exists)
        XCTAssertFalse(app.staticTexts["No modified files"].exists)
        app.buttons[modified ? "Workspace" : "Modified"].tap()
        XCTAssertTrue(unavailable.exists, "Switching views must not resurrect revoked rows")
        XCTAssertFalse(oldFile.exists)
        closeWorkspace(app)
        XCTAssertTrue(app.images["Received by your Mac"].waitForExistence(timeout: 10),
                      "The fixture must revoke only after accepting the exact message")
        if !modified { retainMenuScreenshot(app, name: "Sent message in view after closing Files") }
    }

    func testProjectFilesClearsRowsWhenRootPathChangesUnderSameID() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-chat-layout", "-diagnostics-chat-layout-unsaved",
                               "-diagnostics-project-files-send", "-diagnostics-project-files-refresh",
                               "-diagnostics-project-files-root-path-changed", "-diagnostics-usage-fixture"]
        app.launch()
        openSidebarIfNeeded(app)
        let thread = app.buttons["pinned-thread:codex:read-fixture"]
        XCTAssertTrue(thread.waitForExistence(timeout: 15))
        thread.tap()
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        let oldFile = app.buttons["workspace-file-entry:README.md"]
        XCTAssertTrue(oldFile.waitForExistence(timeout: 10))
        let draft = app.textViews["message-draft"]
        draft.tap(); draft.typeText("Review this file while Files stays open.")
        app.buttons["send-message"].tap()
        XCTAssertTrue(app.buttons["workspace-file-entry:Project update.md"].waitForExistence(timeout: 10))
        XCTAssertFalse(oldFile.exists,
                       "Old rows must not be tappable under a new path with the same root ID")
        XCTAssertTrue(app.buttons["workspace-file-entry:Project update.md"].waitForExistence(timeout: 10))
        XCTAssertFalse(oldFile.exists)
        XCTAssertTrue(draft.isHittable)
    }

    func testProjectLargeTextPreviewKeepsFilesAndComposerResponsive() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview",
                               "-project-files-conversation-preview", "-artifact-annotation-preview",
                               "-workspace-large-text-preview"]
        app.launch()
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        let largeFile = app.buttons["workspace-file-entry:large.txt"]
        XCTAssertTrue(largeFile.waitForExistence(timeout: 5))
        largeFile.tap()
        // A 40 MB file arrives in steps; its progress takes over Files, and the
        // X in the ring cancels it without an error.
        let loadingRow = anyElement(app, identifier: "workspace-file-loading")
        XCTAssertTrue(loadingRow.waitForExistence(timeout: 3))
        let cancel = app.buttons["workspace-file-load-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3) && cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(loadingRow.waitForNonExistence(timeout: 3))
        XCTAssertTrue(largeFile.waitForExistence(timeout: 3), "Cancelling returns to the file list")
        XCTAssertFalse(app.staticTexts["workspace-document-truncated"].waitForExistence(timeout: 3),
                       "A cancelled download must not open later")
        XCTAssertFalse(anyElement(app, identifier: "workspace-unavailable").exists)
        largeFile.tap()
        XCTAssertTrue(loadingRow.waitForExistence(timeout: 3))
        XCTAssertTrue(loadingRow.label.contains("Opening large.txt"), loadingRow.label)
        XCTAssertTrue(loadingRow.label.contains("MB"), loadingRow.label)
        retainMenuScreenshot(app, name: "Large file loading progress")
        XCTAssertTrue(app.textViews["message-draft"].isHittable, "The composer stays usable while a large file loads")
        XCTAssertTrue(app.staticTexts["workspace-document-truncated"].waitForExistence(timeout: 15),
                      "A 40 MB file should show a bounded text preview without blocking the chat")
        XCTAssertFalse(loadingRow.exists)
        let preview = app.textViews["annotation-selectable-text"]
        XCTAssertTrue(preview.exists)
        XCTAssertLessThanOrEqual((preview.value as? String)?.utf8.count ?? Int.max, 128 * 1024)
        app.buttons["workspace-preview-expand"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-collapse"].waitForExistence(timeout: 5))
        app.buttons["workspace-preview-collapse"].tap()
        // The full-screen cover finishes dismissing before the composer takes touches.
        XCTAssertTrue(app.buttons["workspace-preview-collapse"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.textViews["message-draft"].isHittable)
        app.buttons["workspace-preview-back"].tap()
        XCTAssertTrue(largeFile.waitForExistence(timeout: 5))
    }

    func testProjectImagePreviewExpansionKeepsOneVisiblePage() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview",
                               "-project-files-conversation-preview", "-artifact-annotation-preview"]
        app.launch()
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        let file = app.buttons["workspace-file-entry:diagram.png"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        let page = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "photo-viewer-image:")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        app.buttons["workspace-preview-expand"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-collapse"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "photo-viewer-image:")).count, 1,
                       "The full-screen image should not keep a second decoded page underneath")
        app.buttons["workspace-preview-collapse"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews["message-draft"].isHittable)
    }

    func testProjectConversationScopesStoppedResponse() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-project-terminal-turn-preview"]
        app.launch()

        XCTAssertTrue(app.buttons["conversation-title-menu"].waitForExistence(timeout: 10))
        let activity = app.buttons["activity-group:fixture-turn/stopped-command"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        XCTAssertEqual(activity.label, "Earlier response interrupted")
        let compaction = anyElement(app, identifier: "context-compaction:fixture-turn/compact-stopped")
        XCTAssertTrue(compaction.exists)
        XCTAssertEqual(compaction.label, "Context compaction interrupted")
        XCTAssertTrue(app.textViews["message-draft"].exists)
        retainMenuScreenshot(app, name: "Project response status")
    }

    // A turn running in Claude or Codex on the Mac reads as running, but Wonder
    // offers no Stop or Guide for it; a new message queues on the Mac.
    func testProjectTurnRunningOnMacShowsRunningWithoutStop() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-project-running-elsewhere-preview"]
        app.launch()
        let notice = anyElement(app, identifier: "running-elsewhere")
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.label.contains("on your Mac"), notice.label)
        XCTAssertFalse(app.buttons["Stop response"].exists, "Wonder cannot stop a turn owned by the desktop app")
        let draft = app.textViews["message-draft"]
        draft.tap(); draft.typeText("Next step")
        XCTAssertTrue(notice.label.contains("waits until it finishes"), notice.label)
        XCTAssertEqual(app.buttons["send-message"].label, "Queue message",
                       "A message sent now waits on the Mac until the desktop turn finishes")
        XCTAssertFalse(app.buttons["activity-group:fixture-turn/desktop-command"].exists
            && app.buttons["activity-group:fixture-turn/desktop-command"].label.contains("interrupted"))
        retainMenuScreenshot(app, name: "Project turn running on the Mac")
    }

    // A Claude chat open in Claude Code in a terminal keeps its own copy of
    // the conversation, so a message waits until it is exited there.
    // The access menu owns the opt-in interaction; changing it saves through
    // the existing settings endpoint and never sends a message.
    func testProjectUnsandboxedCommandsRequireFullAccess() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-chat-layout",
            "-diagnostics-chat-layout-unsaved", "-diagnostics-project-read"]
        app.launch()
        openSidebarIfNeeded(app)
        let row = app.buttons["pinned-thread:claude:read-fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
        let access = app.buttons["project-composer-access"]
        XCTAssertTrue(access.waitForExistence(timeout: 15)); access.tap()
        let option = app.buttons["project-unsandboxed-commands"]
        func revealOption() {
            let menu = app.collectionViews.containing(.button, identifier: "access-choice-fullAccess").firstMatch
            for _ in 0..<10 {
                guard menu.exists else { return }
                let visible = menu.frame.intersection(app.frame)
                if option.exists && visible.contains(option.frame) { return }
                let origin = app.coordinate(withNormalizedOffset: .zero)
                origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY))
                    .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: visible.midX, dy: visible.minY + 20)))
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
        revealOption()
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        XCTAssertFalse(option.isEnabled)
        app.buttons["access-choice-fullAccess"].tap()
        let full = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Bypass permissions"), object: access)
        XCTAssertEqual(XCTWaiter.wait(for: [full], timeout: 10), .completed)
        access.tap()
        revealOption()
        XCTAssertTrue(option.waitForExistence(timeout: 5) && option.isEnabled)
        option.tap()
        access.tap()
        revealOption()
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        XCTAssertTrue(option.label.contains("On"), option.label)
        XCTAssertTrue(app.frame.contains(option.frame), "The saved option must be fully on screen")
        retainMenuScreenshot(app, name: "Project commands outside the sandbox enabled")
        option.tap()
        access.tap()
        revealOption()
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        XCTAssertFalse(option.label.contains(": On"), option.label)
    }

    func testMessageWaitsWhileClaudeChatIsOpenOnMac() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-project-files-conversation-preview", "-project-open-on-mac-preview"]
        app.launch()
        let notice = anyElement(app, identifier: "open-elsewhere")
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.label.contains("in a terminal on your Mac"), notice.label)
        retainMenuScreenshot(app, name: "Message waiting while open in a terminal on the Mac")
    }

    func testProjectVideoPreviewStreamsAndReopensWithoutSending() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-project-files-conversation-preview",
                               "-workspace-media-preview"]
        app.launch()
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        let video = app.buttons["workspace-file-entry:black.mp4"]
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        for iteration in 0..<2 {
            video.tap()
            let player = app.descendants(matching: .any)["workspace-media-player"]
            XCTAssertTrue(player.waitForExistence(timeout: 15), "Open \(iteration + 1) must load the authenticated video")
            XCTAssertFalse(app.staticTexts["Playback unavailable"].exists)
            if iteration == 0 { retainMenuScreenshot(app, name: "Project video preview playing") }
            if iteration == 0 {
                app.buttons["workspace-preview-expand"].tap()
                XCTAssertTrue(app.buttons["workspace-preview-collapse"].waitForExistence(timeout: 5))
                XCTAssertTrue(player.waitForExistence(timeout: 10), "Full-screen video must keep its authenticated asset")
                app.buttons["workspace-preview-collapse"].tap()
                XCTAssertTrue(player.waitForExistence(timeout: 10), "Collapsing video must keep the inline player")
                XCTAssertFalse(app.staticTexts["Playback unavailable"].exists)
                XCUIDevice.shared.press(.home)
                app.activate()
                XCTAssertTrue(workspacePreviewClose(app, legacyID: "workspace-media-close").waitForExistence(timeout: 5))
            }
            workspacePreviewClose(app, legacyID: "workspace-media-close").tap()
            XCTAssertTrue(video.waitForExistence(timeout: 5))
        }
        closeWorkspace(app)
        XCTAssertTrue(app.textViews["message-draft"].exists)
    }

    func testProjectVideoPreviewExplainsOfflineMacWithoutSending() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-project-files-conversation-preview",
                               "-workspace-media-preview", "-workspace-media-offline-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["conversation-files-pill"].waitForExistence(timeout: 10))
        app.buttons["conversation-files-pill"].tap()
        let video = app.buttons["workspace-file-entry:black.mp4"]
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        video.tap()
        XCTAssertTrue(app.staticTexts["Playback unavailable"].waitForExistence(timeout: 15))
        XCTAssertTrue(workspacePreviewClose(app, legacyID: "workspace-media-close").isHittable)
        workspacePreviewClose(app, legacyID: "workspace-media-close").tap()
        XCTAssertTrue(video.waitForExistence(timeout: 5))
    }

    func testProjectVideoPreviewExplainsFileChangeAfterProbe() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-project-files-conversation-preview",
                               "-workspace-media-preview", "-workspace-media-stale-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["conversation-files-pill"].waitForExistence(timeout: 10))
        app.buttons["conversation-files-pill"].tap()
        let video = app.buttons["workspace-file-entry:black.mp4"]
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        video.tap()
        XCTAssertTrue(app.staticTexts["File changed. Close and reopen the preview."].waitForExistence(timeout: 15))
        XCTAssertTrue(workspacePreviewClose(app, legacyID: "workspace-media-close").isHittable)
        workspacePreviewClose(app, legacyID: "workspace-media-close").tap()
        XCTAssertTrue(video.waitForExistence(timeout: 5))
    }

    func testProjectTextPreviewAnnotationCanBeAddedEditedAndRemovedWithoutSending() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview",
                               "-project-files-conversation-preview", "-artifact-annotation-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["conversation-files-pill"].waitForExistence(timeout: 10))
        app.buttons["conversation-files-pill"].tap()
        let file = app.buttons["workspace-file-entry:README.md"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        selectTextForPreviewComment(app)
        let note = app.descendants(matching: .any)["annotation-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Add a comment"].exists,
                      "A new comment should show a visible input prompt")
        note.tap()
        note.typeText("Check the preview wording")
        retainMenuScreenshot(app, name: "Highlighted text comment editor")
        let add = app.buttons["annotation-add"]
        XCTAssertTrue(add.isEnabled)
        add.tap()
        XCTAssertTrue(app.buttons["workspace-preview-expand"].exists,
                      "Saving a comment keeps the preview in the chat")
        retainMenuScreenshot(app, name: "Highlighted comment in composer")
        let chip = app.buttons["composer-annotation-edit"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "A comment should appear in the unsent composer")
        XCTAssertTrue(app.textViews["message-draft"].exists)
        chip.tap()
        let edit = app.textViews["annotation-edit-note"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertTrue((edit.value as? String)?.contains("Check the preview wording") == true)
        edit.tap()
        edit.typeText(" again")
        app.buttons["annotation-edit-save"].tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove comment")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertFalse(chip.exists)
        XCTAssertTrue(app.textViews["message-draft"].exists)
    }

    func testProjectTextCommentDraftSurvivesFullScreenAndCancel() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview",
                               "-project-files-conversation-preview", "-artifact-annotation-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["conversation-files-pill"].waitForExistence(timeout: 10))
        app.buttons["conversation-files-pill"].tap()
        let file = app.buttons["workspace-file-entry:README.md"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        selectTextForPreviewComment(app)
        let inlineNote = app.descendants(matching: .any)["annotation-note"]
        XCTAssertTrue(inlineNote.waitForExistence(timeout: 5))
        inlineNote.tap(); inlineNote.typeText("Keep this draft")

        app.buttons["workspace-preview-expand"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-collapse"].waitForExistence(timeout: 5))
        let expandedNote = try XCTUnwrap(app.descendants(matching: .any).matching(identifier: "annotation-note")
            .allElementsBoundByIndex.first(where: { $0.isHittable }))
        XCTAssertTrue((expandedNote.value as? String)?.contains("Keep this draft") == true)
        expandedNote.typeText(" in full screen")
        app.buttons["workspace-preview-collapse"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-expand"].waitForExistence(timeout: 5),
                      "Collapsing must keep the inline file preview")
        let resumedNote = inlineNote.value as? String
        XCTAssertEqual(resumedNote, "Keep this draft in full screen",
                       "An unsaved comment must retain its caret and text through both presentation changes")
        retainMenuScreenshot(app, name: "Comment draft after full-screen collapse")

        app.buttons["annotation-cancel"].tap()
        XCTAssertFalse(app.staticTexts["annotation-selected-text"].exists)
        XCTAssertFalse(app.buttons["annotation-comment"].exists)
        selectTextForPreviewComment(app)
        XCTAssertTrue(app.descendants(matching: .any)["annotation-note"].waitForExistence(timeout: 5))
        XCTAssertFalse((app.descendants(matching: .any)["annotation-note"].value as? String)?
            .contains("Keep this draft") == true, "Cancel must discard the unsaved comment")

        let freshNote = app.descendants(matching: .any)["annotation-note"]
        freshNote.tap(); freshNote.typeText("Review this highlight")
        app.buttons["workspace-preview-expand"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-collapse"].waitForExistence(timeout: 5))
        app.buttons["annotation-add"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-collapse"].exists,
                      "Saving a comment should leave the full-screen preview open")
        XCTAssertTrue(app.descendants(matching: .any)["workspace-annotation-added"].waitForExistence(timeout: 5))
        app.buttons["workspace-preview-collapse"].tap()
        XCTAssertTrue(app.buttons["composer-annotation-edit"].waitForExistence(timeout: 5),
                      "The saved highlight should be attached to the unsent composer")
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove comment")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        app.buttons["workspace-preview-expand"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["workspace-annotation-added"].exists,
                       "The preview must not claim a removed note is still attached")
    }

    func testProjectImageRegionAnnotationUsesDraggedAreaWithoutSending() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview",
                               "-project-files-conversation-preview", "-artifact-annotation-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["conversation-files-pill"].waitForExistence(timeout: 10))
        app.buttons["conversation-files-pill"].tap()
        let image = app.buttons["workspace-file-entry:diagram.png"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        image.tap()
        let annotate = app.buttons["annotation-image-open"]
        XCTAssertTrue(annotate.waitForExistence(timeout: 5))
        app.buttons["workspace-preview-expand"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-collapse"].waitForExistence(timeout: 5))
        annotate.tap()
        let canvas = app.descendants(matching: .any)["annotation-region-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.7))
        start.press(forDuration: 0.1, thenDragTo: end)
        let selectedArea = app.staticTexts["annotation-region-status"].label
        XCTAssertTrue(selectedArea.hasPrefix("Selected area:"), selectedArea)
        XCTAssertFalse(selectedArea.contains("100% wide"), "The drag must select a bounded region")
        retainMenuScreenshot(app, name: "Image region selection")
        let note = app.descendants(matching: .any)["annotation-region-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap(); note.typeText("Inspect the center diagram")
        app.buttons["annotation-region-add"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-collapse"].waitForExistence(timeout: 5),
                      "Closing the region editor must return to the same full-screen image")
        app.buttons["workspace-preview-collapse"].tap()
        XCTAssertTrue(annotate.waitForExistence(timeout: 5),
                      "Collapsing must retain the selected image in Files")
        let chip = app.buttons["composer-annotation-edit"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        XCTAssertTrue(app.staticTexts["Selected image area"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.textViews["message-draft"].exists)
    }

    func testProjectTextRevisionWarnsAndReanchorsUnsentNote() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview",
                               "-project-files-conversation-preview", "-artifact-annotation-preview",
                               "-artifact-revision-preview"]
        app.launch()
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        let file = app.buttons["workspace-file-entry:README.md"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        selectTextForPreviewComment(app)
        let note = app.descendants(matching: .any)["annotation-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap(); note.typeText("Review this introduction")
        app.buttons["annotation-add"].tap()
        let chip = app.buttons["composer-annotation-edit"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))

        app.buttons["workspace-preview-back"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        XCTAssertFalse(app.buttons["workspace-document-refresh"].exists, "Open files update on their own")
        let revised = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Revised workspace file"),
                                                object: app.textViews["annotation-selectable-text"])
        XCTAssertEqual(XCTWaiter.wait(for: [revised], timeout: 10), .completed,
                       "The open file should show the new version without a refresh control")
        retainMenuScreenshot(app, name: "Open file updated automatically")
        workspacePreviewClose(app, legacyID: "workspace-document-close").tap()
        closeWorkspace(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(chip.label.contains("File changed"), chip.label)
        chip.tap()
        XCTAssertTrue(app.staticTexts["annotation-edit-stale"].waitForExistence(timeout: 5))
        let staleNote = app.textViews["annotation-edit-note"]
        staleNote.tap(); staleNote.typeText(" keep this note")
        app.buttons["annotation-edit-save"].tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(chip.label.contains("File changed"),
                      "Editing the note must not clear the old source revision warning")
        chip.tap()
        XCTAssertTrue(app.staticTexts["annotation-edit-stale"].waitForExistence(timeout: 5))
        let unsavedNote = app.textViews["annotation-edit-note"]
        unsavedNote.tap(); unsavedNote.typeText(" unsaved addition")
        app.buttons["annotation-edit-reanchor"].tap()
        // The fixture opens the original; the open file's own check brings in the revision.
        let reopenedRevision = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Revised workspace file"),
                                                         object: app.textViews["annotation-selectable-text"])
        XCTAssertEqual(XCTWaiter.wait(for: [reopenedRevision], timeout: 10), .completed)
        selectTextForPreviewComment(app)
        let carriedNote = app.descendants(matching: .any)["annotation-note"]
        XCTAssertTrue(carriedNote.waitForExistence(timeout: 5))
        XCTAssertTrue((carriedNote.value as? String)?.contains("keep this note") == true)
        XCTAssertTrue((carriedNote.value as? String)?.contains("unsaved addition") == true,
                      "Re-anchoring must carry the current editor text, even before Save")
        app.buttons["annotation-add"].tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "composer-annotation-edit").count, 1)
        XCTAssertFalse(chip.label.contains("File changed"), chip.label)
        XCTAssertTrue(app.textViews["message-draft"].exists)
    }

    func testProjectPDFTextCommentKeepsSelectedPageWithoutSending() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview",
                               "-project-files-conversation-preview", "-artifact-annotation-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["conversation-files-pill"].waitForExistence(timeout: 10))
        app.buttons["conversation-files-pill"].tap()
        let pdf = app.buttons["workspace-file-entry:Weekend.pdf"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 10))
        pdf.tap()
        XCTAssertTrue(app.descendants(matching: .any)["workspace-pdf-preview"].waitForExistence(timeout: 10))
        app.buttons["workspace-preview-expand"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-collapse"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "workspace-pdf-preview").count, 1,
                       "Full screen should keep one PDF viewer")
        XCTAssertFalse(app.buttons["annotation-pdf-open"].exists, "PDF comments start from a text selection")
        selectPDFWord(app)
        retainMenuScreenshot(app, name: "PDF selection menu with Comment")
        tapEditMenuComment(app, "Selecting PDF text must offer Comment in its menu")
        let excerpt = app.staticTexts["annotation-pdf-excerpt"]
        XCTAssertTrue(excerpt.waitForExistence(timeout: 5))
        XCTAssertTrue(excerpt.label.contains("Weekend"), excerpt.label)
        let note = app.descendants(matching: .any)["annotation-pdf-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.typeText("Check this heading")
        retainMenuScreenshot(app, name: "PDF text comment")
        app.buttons["annotation-pdf-add"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-collapse"].waitForExistence(timeout: 5),
                      "Adding the comment must return to the same full-screen PDF")
        app.buttons["workspace-preview-collapse"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["workspace-pdf-preview"].waitForExistence(timeout: 5),
                      "Collapsing must retain the selected PDF in Files")
        let chip = app.buttons["composer-annotation-edit"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        XCTAssertTrue(app.staticTexts["Selected area on page 1"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.textViews["message-draft"].exists)
    }

    func testProjectPDFCommentStaysReachableWithLargeTextAndKeyboard() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview",
                               "-project-files-conversation-preview", "-artifact-annotation-preview",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["conversation-files-pill"].waitForExistence(timeout: 10))
        app.buttons["conversation-files-pill"].tap()
        let fileList = app.collectionViews["workspace-file-list"]
        XCTAssertTrue(fileList.waitForExistence(timeout: 10))
        let pdf = app.buttons["workspace-file-entry:Weekend.pdf"]
        for _ in 0..<15 where !pdf.isHittable {
            // The composer overlays the lower part of this lazy list on iPhone.
            let start = fileList.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45))
            let end = fileList.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.12))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(pdf.isHittable, "The PDF row should remain reachable at large text sizes")
        pdf.tap()
        selectPDFWord(app)
        tapEditMenuComment(app, "Selecting PDF text must offer Comment at large text sizes")
        let note = app.descendants(matching: .any)["annotation-pdf-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.typeText("Review this page")
        let add = app.buttons["annotation-pdf-add"]
        XCTAssertTrue(add.isHittable, "Add must remain reachable above the keyboard at large text sizes")
        retainMenuScreenshot(app, name: "Large text PDF comment with keyboard")
        add.tap()
        XCTAssertTrue(app.buttons["composer-annotation-edit"].waitForExistence(timeout: 5))
    }

    func testProjectImageAndPDFRevisionPreviewsStayInConversation() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview",
                               "-project-files-conversation-preview", "-artifact-annotation-preview",
                               "-artifact-revision-preview"]
        app.launch()
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        let image = app.buttons["workspace-file-entry:diagram.png"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        image.tap()
        let viewedImage = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "photo-viewer-image:")).firstMatch
        XCTAssertTrue(viewedImage.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["workspace-image-refresh"].exists, "Open images update on their own")
        viewedImage.doubleTap()
        let zoomedBefore = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "200%"), object: viewedImage)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomedBefore], timeout: 5), .completed)
        // Small files are checked every few seconds while open.
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(app.buttons["annotation-image-open"].exists)
        XCTAssertTrue((viewedImage.value as? String)?.contains("200%") == true,
                      "The open image should keep its zoom when the new version arrives")
        retainMenuScreenshot(app, name: "Updated image in open viewer")
        workspacePreviewClose(app, legacyID: "photo-viewer-close").tap()

        let pdf = app.buttons["workspace-file-entry:Weekend.pdf"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 5))
        pdf.tap()
        XCTAssertTrue(app.descendants(matching: .any)["workspace-pdf-preview"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(app.descendants(matching: .any)["workspace-pdf-preview"].exists)
        retainMenuScreenshot(app, name: "Updated PDF in open viewer")
        workspacePreviewClose(app, legacyID: "workspace-document-close").tap()
        closeWorkspace(app)
        XCTAssertTrue(app.textViews["message-draft"].exists)
    }

    func testMalformedPDFShowsErrorOnOpenAndRevision() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        let baseArguments = ["-read-preview", "-send-preview", "-files-preview",
                             "-project-files-conversation-preview", "-artifact-annotation-preview"]
        app.launchArguments = baseArguments + ["-malformed-pdf-preview",
                                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        app.buttons["conversation-files-pill"].tap()
        let pdf = app.buttons["workspace-file-entry:Weekend.pdf"]
        let fileList = app.collectionViews["workspace-file-list"]
        XCTAssertTrue(fileList.waitForExistence(timeout: 10))
        // At this text size the list is short; look upward first, then downward.
        for _ in 0..<10 where !pdf.isHittable { fileList.swipeDown(velocity: .slow) }
        for _ in 0..<10 where !pdf.isHittable { fileList.swipeUp(velocity: .slow) }
        XCTAssertTrue(pdf.isHittable)
        pdf.tap()
        let back = app.buttons["workspace-preview-back"]
        let expand = app.buttons["workspace-preview-expand"]
        let title = app.staticTexts["workspace-preview-title"]
        XCTAssertTrue(back.isHittable && expand.isHittable)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Weekend.pdf", "The full filename must remain available at large text sizes")
        XCTAssertLessThanOrEqual(back.frame.maxY, title.frame.minY,
                                 "Preview controls must not crowd or wrap into the filename")
        let remove = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "composer-attachment-remove:")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5) && remove.isHittable,
                      "The attachment remove control must remain visible at large text sizes")
        XCTAssertLessThanOrEqual(remove.frame.maxX, app.frame.maxX - 8)
        XCTAssertGreaterThanOrEqual(app.textViews["message-draft"].frame.height, 80,
                                    "The draft should show more than one line at Accessibility XXXL")
        let error = app.staticTexts["workspace-pdf-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5) && error.isHittable,
                      "An invalid PDF must explain the blank preview")
        retainMenuScreenshot(app, name: "Invalid PDF on first open")
        expand.tap()
        let collapse = app.buttons["workspace-preview-collapse"]
        let expandedTitle = app.staticTexts["workspace-preview-expanded-title"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5) && collapse.isHittable)
        XCTAssertTrue(expandedTitle.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(collapse.frame.maxY, expandedTitle.frame.minY,
                                 "The full-screen filename should have its own row at large text sizes")
        XCTAssertTrue(error.isHittable, "The PDF error must survive full-screen handoff")
        retainMenuScreenshot(app, name: "Invalid PDF full screen at large text")
        collapse.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        workspacePreviewClose(app, legacyID: "workspace-document-close").tap()

        app.terminate()
        app.launchArguments = baseArguments + ["-artifact-revision-preview", "-malformed-pdf-revision-preview"]
        app.launch()
        app.buttons["conversation-files-pill"].tap()
        let revisedPDF = app.buttons["workspace-file-entry:Weekend.pdf"]
        XCTAssertTrue(revisedPDF.waitForExistence(timeout: 10))
        revisedPDF.tap()
        XCTAssertFalse(app.staticTexts["workspace-pdf-error"].exists)
        XCTAssertTrue(app.staticTexts["workspace-pdf-error"].waitForExistence(timeout: 10),
                      "A malformed update must not silently leave the old page visible")
        retainMenuScreenshot(app, name: "Invalid PDF revision in viewer")
        workspacePreviewClose(app, legacyID: "workspace-document-close").tap()
        closeWorkspace(app)
        XCTAssertTrue(app.textViews["message-draft"].exists)
    }

    func testProjectTitleMenuOpensDetailsAppsAndUsage() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-project-files-conversation-preview"]
        app.launch()
        let title = app.buttons["conversation-title-menu"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(title.label.contains("Project notes"))
        XCTAssertTrue(title.label.contains("project, Codex"), "VoiceOver should retain project and provider context")
        title.tap()
        XCTAssertTrue(app.buttons["Conversation details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Connected apps"].exists)
        XCTAssertTrue(app.buttons["Codex usage"].exists)
        retainMenuScreenshot(app, name: "Project title menu")

        app.buttons["Codex usage"].tap()
        XCTAssertTrue(app.navigationBars["Codex usage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Usage is unavailable right now."].exists)
        app.buttons["Done"].tap()

        title.tap()
        app.buttons["Connected apps"].tap()
        XCTAssertTrue(app.navigationBars["Connected apps"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        openConversationDetails(app)
        XCTAssertTrue(app.navigationBars["Thread"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.textViews["message-draft"].isHittable)
    }

    func testProjectGoalPillOpensExactConversationGoalWithoutSending() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-project-files-conversation-preview", "-project-goal-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["conversation-title-menu"].waitForExistence(timeout: 10))
        let pill = app.buttons["goal-status-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        XCTAssertEqual(pill.label, "Goal active")
        pill.tap()
        let objective = app.staticTexts["goal-objective"]
        XCTAssertTrue(objective.waitForExistence(timeout: 5))
        XCTAssertEqual(objective.label, "Review the Project plan")
        retainMenuScreenshot(app, name: "Project goal details")
        app.buttons["goal-done"].tap()
        XCTAssertTrue(app.textViews["message-draft"].isHittable)
    }

    func testNewProjectChatOpensSelectedFolderFilesWithoutSending() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            app.launchArguments = ["-connections-preview", "-project-files-preview", "-files-preview",
                                   "-UIPreferredContentSizeCategoryName", size]
            app.launch()
            let files = app.buttons["new-chat-files"]
            XCTAssertTrue(files.waitForExistence(timeout: 10))
            let computer = app.buttons["connection-picker"]
            let project = app.buttons["destination-picker"]
            let viewComputer = app.buttons["view-computer"]
            let composer = app.otherElements["new-chat-composer"]
            for control in [computer, project, viewComputer, files] {
                XCTAssertTrue(control.isHittable, "Each New Chat destination action must stay visible at \(size)")
            }
            XCTAssertTrue(composer.exists)
            XCTAssertLessThanOrEqual(computer.frame.maxY, project.frame.minY)
            XCTAssertLessThanOrEqual(project.frame.maxY, viewComputer.frame.minY)
            if size == "UICTContentSizeCategoryAccessibilityXXXL" {
                XCTAssertLessThanOrEqual(viewComputer.frame.maxY, files.frame.minY)
            } else {
                XCTAssertLessThanOrEqual(viewComputer.frame.maxX, files.frame.minX)
            }
            XCTAssertLessThanOrEqual(files.frame.maxY, composer.frame.minY)
            retainMenuScreenshot(app, name: "New Project chat destinations at \(size)")
            files.tap()
            let list = app.collectionViews["workspace-file-list"]
            XCTAssertTrue(list.waitForExistence(timeout: 10))
            XCTAssertTrue(composer.isHittable, "New Chat Files must replace the chat area and keep its composer")
            XCTAssertLessThanOrEqual(list.frame.maxY, composer.frame.minY + 2)
            XCTAssertFalse(app.buttons["workspace-close"].exists)
            XCTAssertFalse(app.buttons["workspace-refresh"].exists)
            XCTAssertTrue(app.buttons["workspace-hidden-toggle"].exists)
            XCTAssertTrue(app.buttons["workspace-file-entry:README.md"].waitForExistence(timeout: 10))
            app.buttons["Modified"].tap()
            let changed = app.buttons["workspace-modified-entry:README.md"]
            XCTAssertTrue(changed.waitForExistence(timeout: 5))
            changed.tap()
            XCTAssertTrue(workspacePreviewClose(app, legacyID: "workspace-diff-close").waitForExistence(timeout: 5))
            workspacePreviewClose(app, legacyID: "workspace-diff-close").tap()
            closeWorkspace(app)
            XCTAssertTrue(files.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["new-chat-send"].isEnabled)
            app.terminate()
        }
    }

    func testNewProjectChatPreviewNotePersistsWithoutSending() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-connections-preview", "-project-files-preview", "-files-preview",
                               "-artifact-annotation-preview", "-project-files-multiple-folders-preview",
                               "-reset-new-chat-annotations-preview"]
        app.launch()
        let files = app.buttons["new-chat-files"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        let file = app.buttons["workspace-file-entry:README.md"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        selectTextForPreviewComment(app)
        let note = app.descendants(matching: .any)["annotation-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap(); note.typeText("Check this before creating the chat")
        app.buttons["annotation-add"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-expand"].exists)
        let chip = app.descendants(matching: .any)["composer-attachments"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "The note must enter the New Chat composer")
        app.buttons["project-agent-picker"].tap()
        app.buttons["Second"].tap()
        XCTAssertTrue(app.buttons["Switch and remove comments"].waitForExistence(timeout: 5),
                      "Changing folders must ask before removing saved notes")
        app.buttons["Keep current folder"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(chip.exists)
        let edit = app.buttons["composer-annotation-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let editor = app.textViews["annotation-edit-note"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText(" again")
        app.buttons["annotation-edit-save"].tap()
        retainMenuScreenshot(app, name: "New Project chat comment before send")
        app.terminate()

        app.launchArguments = ["-connections-preview", "-project-files-preview", "-files-preview",
                               "-artifact-annotation-preview", "-project-files-multiple-folders-preview"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["composer-attachments"].waitForExistence(timeout: 10),
                      "The unsent note must survive relaunch")
        app.buttons["composer-annotation-edit"].tap()
        let restoredNote = app.textViews["annotation-edit-note"]
        XCTAssertTrue(restoredNote.waitForExistence(timeout: 5))
        let restoredText = restoredNote.value as? String ?? ""
        XCTAssertTrue(restoredText.contains("Check") && restoredText.contains("again"),
                      "The edited comment must survive relaunch: \(restoredText)")
        app.buttons["Cancel"].tap()
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove comment")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertFalse(app.descendants(matching: .any)["composer-attachments"].exists)
        XCTAssertTrue(app.buttons["new-chat-files"].exists)
    }

    func testNewProjectFilesExplainRevokedAndMissingFolders() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        for (argument, expected) in [
            ("-project-files-root-revoked", "Access to this folder changed"),
            ("-project-files-project-removed", "conversation or Project folder is unavailable")
        ] {
            app.launchArguments = ["-connections-preview", "-project-files-preview", argument]
            app.launch()
            let files = app.buttons["new-chat-files"]
            XCTAssertTrue(files.waitForExistence(timeout: 10))
            files.tap()
            let unavailable = app.descendants(matching: .any).matching(identifier: "workspace-unavailable").firstMatch
            XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
            XCTAssertTrue(unavailable.label.contains(expected))
            XCTAssertTrue(app.buttons["workspace-retry"].exists)
            retainMenuScreenshot(app, name: "Folder unavailable \(expected)")
            closeWorkspace(app)
            XCTAssertTrue(files.waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testNewProjectFilesRecoverAfterSelectedRootChanges() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-connections-preview", "-project-files-preview", "-project-files-root-changed"]
        app.launch()
        let files = app.buttons["new-chat-files"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        let unavailable = app.descendants(matching: .any).matching(identifier: "workspace-unavailable").firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
        app.buttons["workspace-retry"].tap()
        XCTAssertTrue(app.buttons["workspace-file-entry:README.md"].waitForExistence(timeout: 10))
        XCTAssertFalse(unavailable.exists)
        closeWorkspace(app)
        XCTAssertTrue(files.waitForExistence(timeout: 5))
    }

    func testNewProjectFilesRetryReturnsToRootAfterSubfolderMoves() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-connections-preview", "-project-files-preview", "-project-files-directory-moved"]
        app.launch()
        let files = app.buttons["new-chat-files"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        let folder = app.buttons["workspace-directory-entry:Projects"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()
        let unavailable = app.descendants(matching: .any).matching(identifier: "workspace-unavailable").firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
        XCTAssertTrue(unavailable.label.contains("folder moved or was deleted"))
        app.buttons["workspace-retry"].tap()
        XCTAssertTrue(app.buttons["workspace-file-entry:README.md"].waitForExistence(timeout: 10))
        XCTAssertFalse(unavailable.exists)
        closeWorkspace(app)
        XCTAssertTrue(files.waitForExistence(timeout: 5))
    }

    func testLargeActivityDetails() throws {
        let app=XCUIApplication(bundleIdentifier:appBundleIdentifier)
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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

    func testDiagnosticsCompletedResponseDistinguishesFailedFollowupDelivery() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-fixtures", "-diagnostics-cancelled-queue", "-read-preview", "-send-preview"]
        app.launch()
        let working = app.buttons["activity-group:runtime/command-0"]
        XCTAssertTrue(working.waitForExistence(timeout: 10))
        XCTAssertEqual(working.label, "Working…")
        let complete = app.buttons["fixture-complete-failed-followup"]
        XCTAssertTrue(complete.isHittable)
        complete.tap()
        let issue = anyElement(app, identifier: "last-request-issue")
        XCTAssertTrue(issue.waitForExistence(timeout: 5))
        XCTAssertEqual(issue.label, "A message could not be sent. Review the conversation before trying again.")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Turn lifecycle: The requested work is complete.")).firstMatch.exists)
        XCTAssertEqual(working.label, "Worked")
        XCTAssertFalse(app.buttons["Stop response"].exists)
        XCTAssertEqual(app.buttons["send-message"].label, "Send message")
        retainMenuScreenshot(app, name: "Completed work with failed follow-up delivery")
    }

    func testDiagnosticsFileChangeSummaryShowsFilenameCountsAndRetainsDiff() throws {
        continueAfterFailure = false
        for large in [false, true] {
            let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
            // Linked files open in the in-chat Files preview, not a pushed screen.
            let title = app.staticTexts["workspace-preview-title"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.label, "Authentication.swift")
            XCTAssertTrue(app.staticTexts["Fixture workspace file: Authentication.swift\n"].exists)
            retainMenuScreenshot(app, name: large ? "Linked file at maximum text" : "Filename opens file preview")
            workspacePreviewClose(app, legacyID: "workspace-document-close").tap()
            XCTAssertTrue(app.buttons["workspace-view-toggle"].waitForExistence(timeout: 5))
            closeWorkspace(app)
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

    // Replies render Markdown blocks instead of showing their syntax.
    func testAgentReplyRendersMarkdownBlocks() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-activity-preview", "-markdown-reply-preview"]
        app.launch()
        let heading = app.staticTexts["Summary"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        let contains = { (text: String) in
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }
        XCTAssertTrue(contains("Labels read naturally").exists)
        XCTAssertTrue(contains("Review the diff").exists)
        XCTAssertTrue(contains("Remaining work is optional.").exists)
        XCTAssertTrue(contains("ChatView.swift, Labels").exists, "Table rows read as their cells")
        // Neither the drawn text nor what VoiceOver reads keeps Markdown syntax.
        XCTAssertFalse(contains("## Summary").exists, "Heading syntax is not shown or read")
        XCTAssertFalse(contains("|------|").exists, "Table syntax is not shown or read")
        XCTAssertFalse(contains("**chat labels**").exists, "Emphasis syntax is not read")
        retainMenuScreenshot(app, name: "Markdown reply", fullScreen: true)
    }

    func testResponseEditedFilesPillBesideFilesAndDiffKeepComposerInLandscape() throws {
        try checkResponseEditedFiles(landscape: true, large: false)
    }

    func testResponseEditedFilesAtAccessibilitySize() throws {
        try checkResponseEditedFiles(landscape: false, large: true)
    }

    private func checkResponseEditedFiles(landscape: Bool, large: Bool) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-activity-preview", "-response-edits-preview"]
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        if landscape { XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5)); XCTAssertGreaterThan(app.frame.width, app.frame.height) }
        // The latest response's edits sit in the composer row, after Computer and Files.
        let pill = app.buttons["response-edits-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        XCTAssertTrue(pill.isHittable)
        let files = app.buttons["conversation-files-pill"]
        XCTAssertGreaterThanOrEqual(pill.frame.minX, files.frame.maxX - 1)
        XCTAssertLessThanOrEqual(pill.frame.maxX, app.frame.maxX, "The edits pill stays on screen at every text size")
        XCTAssertLessThanOrEqual(pill.frame.maxY, app.textViews["message-draft"].frame.minY + 1)
        XCTAssertEqual(pill.value as? String, "Closed")
        XCTAssertTrue(pill.label.hasPrefix("Edited "), pill.label)
        XCTAssertTrue(pill.label.contains("added lines"), pill.label)
        retainMenuScreenshot(app, name: large ? "Edited files pill at large text" : "Edited files pill in landscape", fullScreen: true)
        pill.tap()
        // The same pill closes the review again; files expand in place.
        XCTAssertTrue(anyElement(app, identifier: "response-edits-review").waitForExistence(timeout: 5))
        XCTAssertEqual(pill.value as? String, "Open")
        XCTAssertFalse(app.buttons["response-edits-back"].exists, "The review has no back arrow")
        let first = app.buttons["response-edited-file:Sources/ChatView.swift"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        XCTAssertEqual(first.value as? String, "Expanded")
        let diff = anyElement(app, identifier: "workspace-diff-text")
        XCTAssertTrue(diff.waitForExistence(timeout: 10))
        XCTAssertTrue(diff.label.contains("+let label = \"Edited files\""), diff.label)
        XCTAssertTrue(app.textViews["message-draft"].isHittable)
        retainMenuScreenshot(app, name: large ? "Saved file diff at large text" : "Saved file diff in landscape", fullScreen: true)
        first.tap()
        XCTAssertEqual(first.value as? String, "Collapsed")
        let document = anyElement(app, identifier: "diff-document")
        let last = app.buttons["response-edited-file:Sources/Long folder name/Accessible layout.swift"]
        for _ in 0..<8 where !last.isHittable { document.swipeUp() }
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        last.tap()
        let lastDiff = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
            "workspace-diff-text", "Accessible layout.swift")).firstMatch
        for _ in 0..<4 where !lastDiff.exists { document.swipeUp() }
        XCTAssertTrue(lastDiff.waitForExistence(timeout: 5))
        let partial = app.staticTexts["Only the first part of this diff was saved. Review the full change on your Mac."]
        for _ in 0..<12 where !partial.exists { document.swipeUp() }
        XCTAssertTrue(partial.waitForExistence(timeout: 5))
        retainMenuScreenshot(app, name: large ? "Partial saved diff notice at large text" : "Partial saved diff notice", fullScreen: true)
        let layout = app.segmentedControls["diff-layout"]
        if layout.exists, layout.isHittable {
            layout.buttons.element(boundBy: 1).tap()
            retainMenuScreenshot(app, name: large ? "Side-by-side diff at large text" : "Side-by-side diff", fullScreen: true)
            layout.buttons.element(boundBy: 0).tap()
        }
        pill.tap()
        XCTAssertTrue(anyElement(app, identifier: "response-edits-review").waitForNonExistence(timeout: 5))
        XCTAssertEqual(pill.value as? String, "Closed")
        // Files replaces the saved-diff review instead of opening behind it.
        pill.tap()
        XCTAssertTrue(anyElement(app, identifier: "response-edits-review").waitForExistence(timeout: 5))
        files.tap()
        XCTAssertTrue(anyElement(app, identifier: "response-edits-review").waitForNonExistence(timeout: 5))
        XCTAssertEqual(files.value as? String, "Open")
        files.tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["message-draft"].isHittable)
    }

    func testDiagnosticsCommandSummaryKeepsDurationOnlyWhenTheFullCommandFits() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        let constrained = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        constrained.launchArguments = ["-diagnostics-fixtures", "-diagnostics-command-narrow"]
        constrained.launch()
        selectDiagnosticFixture("Command", in: constrained)
        let constrainedDetail = anyElement(constrained, identifier: "activity-detail")
        XCTAssertTrue(constrainedDetail.waitForExistence(timeout: 5))
        XCTAssertFalse(anyElement(constrained, identifier: "command-duration:fixture/row").exists)
        XCTAssertTrue(constrainedDetail.label.contains("for 5s"), "Accessibility retains the complete prepared summary")
        retainMenuScreenshot(constrained, name: "Truncated command at 220pt omits visual duration")
        constrained.terminate()

        let largeText = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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

    func testDictationPreparationDoesNotRestartAfterBackground() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-fixtures", "-diagnostics-composer-large-draft",
                               "-diagnostics-progressive-dictation", "-diagnostics-dictation-delayed-preparation"]
        app.launch()
        let editor = app.textViews["message-draft"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let original = try XCTUnwrap(editor.value as? String)
        let mic = app.buttons["dictate-message"]
        mic.tap()
        let preparing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Cancel dictation preparation'"), object: mic)
        XCTAssertEqual(XCTWaiter.wait(for: [preparing], timeout: 2), .completed)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Dictate message' AND enabled == true"), object: mic)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 5), .completed)
        // The delayed preparation response cannot restart recording after return.
        let restarted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Recording'"), object: mic)
        restarted.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [restarted], timeout: 7), .completed)
        XCTAssertEqual(editor.value as? String, original)
        XCTAssertEqual(app.staticTexts["camera-draft-count"].label, "Draft attachments: 1")
        XCTAssertEqual(app.staticTexts["camera-draft-transfers"].label, "Local draft only")
        app.terminate()
    }

    func testDictationMicrophoneDenialPreservesDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.resetAuthorizationStatus(for: .microphone)
        app.launchArguments = ["-diagnostics-fixtures", "-diagnostics-composer-large-draft", "-diagnostics-progressive-dictation"]
        app.launch()
        let editor = app.textViews["message-draft"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let original = try XCTUnwrap(editor.value as? String)
        app.buttons["dictate-message"].tap()
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        alert.buttons["Don’t Allow"].tap()
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, original)
        XCTAssertEqual(app.staticTexts["camera-draft-count"].label, "Draft attachments: 1")
        app.terminate()
    }

    func testDictationNativeAvailabilityPreservesDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.resetAuthorizationStatus(for: .microphone)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launchArguments = ["-diagnostics-fixtures", "-diagnostics-composer-large-draft", "-diagnostics-progressive-dictation"]
        app.launch()
        let editor = app.textViews["message-draft"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let original = try XCTUnwrap(editor.value as? String)
        let mic = app.buttons["dictate-message"]
        for cycle in 0..<2 {
            mic.tap()
            if cycle == 0 {
                let alert = springboard.alerts.firstMatch
                XCTAssertTrue(alert.waitForExistence(timeout: 15))
                alert.buttons["Allow"].tap()
            }
            let available = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                mic.value as? String == "Recording" || app.staticTexts["Dictation unavailable"].exists
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 30), .completed)
            if app.staticTexts["Dictation unavailable"].exists {
                XCTAssertEqual(editor.value as? String, original)
                XCTAssertEqual(app.staticTexts["camera-draft-count"].label, "Draft attachments: 1")
                XCTAssertFalse(app.buttons["Retry"].exists)
                let evidence = XCTAttachment(string: "Native recognition unavailable in this simulator; no Mac fallback.")
                evidence.lifetime = .keepAlways; add(evidence)
                break
            }
            let recording = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Recording'"), object: mic)
            XCTAssertEqual(XCTWaiter.wait(for: [recording], timeout: 15), .completed)
            XCTAssertTrue(editor.isHittable, "The editor remains visible during recording")
            XCTAssertFalse(app.staticTexts["Dictation unavailable"].exists, "A working recording fallback is not an unavailable feature")
            let path = app.staticTexts["dictation-capture-path"].label
            XCTAssertEqual(path, "Native SpeechAnalyzer")
            let evidence = XCTAttachment(string: "Actual simulator capture path: " + path)
            evidence.lifetime = .keepAlways; add(evidence)
            if cycle == 0 { retainMenuScreenshot(app, name: "Actual capture with visible composer") }
            mic.press(forDuration: 1)
            let cancel = app.buttons["cancel-dictation"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            cancel.tap()
            XCTAssertEqual(editor.value as? String, original)
            app.buttons["camera-reload-draft"].tap()
            XCTAssertEqual(editor.value as? String, original)
            XCTAssertEqual(app.staticTexts["camera-draft-count"].label, "Draft attachments: 1")
            XCTAssertEqual(app.staticTexts["camera-draft-transfers"].label, "Local draft only")
        }
        app.terminate()
    }

    func testProgressiveDictationRevisesCancelsAndSavesWithAttachment() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-fixtures", "-diagnostics-composer-large-draft", "-diagnostics-progressive-dictation"]
        app.launch()
        let editor = app.textViews["message-draft"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let original = try XCTUnwrap(editor.value as? String)
        app.buttons["dictation-fixture-partial"].tap()
        XCTAssertTrue((editor.value as? String)?.contains("blue card") == true)
        XCTAssertEqual(app.staticTexts["dictation-saved-draft"].label, original)
        app.buttons["dictation-fixture-revision"].tap()
        XCTAssertTrue((editor.value as? String)?.contains("green card") == true)
        XCTAssertFalse((editor.value as? String)?.contains("blue card") == true)
        retainMenuScreenshot(app, name: "Provisional dictation with attachment")
        let mic = app.buttons["dictate-message"]
        XCTAssertEqual(mic.value as? String, "Recording")
        mic.press(forDuration: 1)
        XCTAssertTrue(app.buttons["cancel-dictation"].waitForExistence(timeout: 5))
        app.buttons["cancel-dictation"].tap()
        XCTAssertEqual(editor.value as? String, original)
        app.buttons["dictation-fixture-partial"].tap()
        app.buttons["dictation-fixture-revision"].tap()
        app.buttons["dictation-fixture-next"].tap()
        XCTAssertTrue((editor.value as? String)?.contains("green card. Next phrase.") == true)
        XCTAssertEqual(app.staticTexts["dictation-saved-draft"].label, original)
        retainMenuScreenshot(app, name: "Blue mic with cumulative provisional phrases")
        XCTAssertTrue(mic.isHittable)
        mic.tap()
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Idle'"), object: mic)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 5), .completed)
        let finished = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(finished.contains("green card"))
        app.buttons["camera-reload-draft"].tap()
        XCTAssertEqual(editor.value as? String, finished)
        XCTAssertEqual(app.staticTexts["camera-draft-count"].label, "Draft attachments: 1")
        XCTAssertEqual(app.staticTexts["camera-pending-send"].label, "No pending send")
        XCTAssertEqual(app.staticTexts["camera-draft-transfers"].label, "Local draft only")
    }

    func testComposerEditWithLargeAttachmentSurvivesDurableReload() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-fixtures", "-diagnostics-composer-large-draft"]
        app.launch()
        let editor = app.textViews["message-draft"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["camera-draft-count"].label, "Draft attachments: 1")
        editor.tap()
        editor.typeText(" More text")
        let changed = try XCTUnwrap(editor.value as? String)
        XCTAssertNotEqual(changed, "Keep this draft.")
        app.buttons["camera-reload-draft"].tap()
        XCTAssertEqual(editor.value as? String, changed)
        XCTAssertEqual(app.staticTexts["camera-draft-count"].label, "Draft attachments: 1")
        XCTAssertEqual(app.staticTexts["camera-pending-send"].label, "No pending send")
        retainMenuScreenshot(app, name: "Large attachment draft after durable reload")
    }

    func testComposerAttachmentPreviewLoadsAndRemovesOnlyTheSelectedImage() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        XCTAssertTrue(workspacePreviewClose(app, legacyID: "photo-viewer-close").isHittable)
        workspacePreviewClose(app, legacyID: "photo-viewer-close").tap()
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        XCTAssertTrue(workspacePreviewClose(app, legacyID: "photo-viewer-close").isHittable)
        retainMenuScreenshot(app, name: "Conversation photo viewer image one")

        imageOne.swipeLeft(velocity: .slow)
        let imageTwo = app.descendants(matching: .any).matching(identifier: "photo-viewer-image:message-image-2").firstMatch
        XCTAssertTrue(imageTwo.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2 of 2"].waitForExistence(timeout: 5))
        retainMenuScreenshot(app, name: "Conversation photo viewer image two")
        workspacePreviewClose(app, legacyID: "photo-viewer-close").tap()

        document.tap()
        let documentRow = app.buttons["workspace-attachment:message-notes"]
        XCTAssertTrue(documentRow.waitForExistence(timeout: 10))
        documentRow.tap()
        XCTAssertTrue(workspacePreviewClose(app, legacyID: "workspace-document-close").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["reference-notes.txt"].exists)
        retainMenuScreenshot(app, name: "Conversation document routed separately")
        workspacePreviewClose(app, legacyID: "workspace-document-close").tap()
        XCTAssertTrue(documentRow.waitForExistence(timeout: 5))
    }

    func testRestoredComposerAttachmentsShowLoadedAndMissingStatesAndCanBeRemoved() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
            let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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

                let scroll = anyElement(app, identifier: "conversation-scroll")
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
                XCTAssertTrue(workspacePreviewClose(app, legacyID: "photo-viewer-close").waitForExistence(timeout: 5))
                retainMenuScreenshot(app, name: "Queued image attachment viewer")
                workspacePreviewClose(app, legacyID: "photo-viewer-close").tap()
                queuedDocument.tap()
                let queuedDocumentRow = app.buttons["workspace-attachment:notes.txt"]
                XCTAssertTrue(queuedDocumentRow.waitForExistence(timeout: 10))
                queuedDocumentRow.tap()
                XCTAssertTrue(workspacePreviewClose(app, legacyID: "workspace-document-close").waitForExistence(timeout: 10))
                XCTAssertTrue(app.staticTexts["notes.txt"].exists)
                retainMenuScreenshot(app, name: "Queued document attachment route")
                workspacePreviewClose(app, legacyID: "workspace-document-close").tap()
                let workspaceAttachment = app.buttons["workspace-attachment:notes.txt"]
                XCTAssertTrue(workspaceAttachment.waitForExistence(timeout: 5),
                              "Closing the document preview returns to the Files attachment row.")
                XCTAssertTrue(app.buttons["conversation-files-pill"].waitForExistence(timeout: 5),
                              "The Files pill remains available after closing a document preview.")
                closeWorkspace(app)
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

    func testDiagnosticsApprovalPickerUsesThreeChoicesPersistsAndShowsOldHostState() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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

        let relaunched = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        relaunched.launchArguments = ["-diagnostics-fixtures", "-diagnostics-permission-fixture"]
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["diagnostic-approval-picker"].waitForExistence(timeout: 10))
        XCTAssertEqual(relaunched.buttons["diagnostic-approval-picker"].value as? String, "Full access")
        relaunched.terminate()

        let oldHost = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        oldHost.launchArguments = ["-diagnostics-fixtures", "-diagnostics-permission-fixture", "-diagnostics-permission-old-host", "-diagnostics-permission-reset"]
        oldHost.launch()
        XCTAssertTrue(oldHost.staticTexts["Update Wonder on your Mac to change approval settings."].waitForExistence(timeout: 10))
        XCTAssertFalse(oldHost.buttons["diagnostic-approval-picker"].isEnabled)
        oldHost.terminate()
    }

    func testDiagnosticsAllApprovalChoicesSaveAndReload() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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

    func testChatsControlRestoresSidebarAtAccessibilitySize() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-chat-layout",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["conversation-title-menu"].waitForExistence(timeout: 10))
        let control = app.buttons["open-sidebar"]
        XCTAssertTrue(control.waitForExistence(timeout: 5), "A conversation needs a visible route to Chats")
        let search = app.textFields["sidebar-search"]
        if search.exists && search.isHittable {
            control.tap()
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !search.isHittable }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        }
        XCTAssertTrue(control.isHittable)
        control.tap()
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in search.exists && search.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed,
                       "The Chats control must restore the sidebar at large text sizes")
        retainMenuScreenshot(app, name: "Chats sidebar restored at accessibility size")
    }

    func testRegularWidthPhoneKeepsChatsBesideProjectConversation() throws {
        continueAfterFailure = false
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone regular-width layout") }
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-chat-layout",
                               "-diagnostics-chat-layout-unsaved", "-diagnostics-project-speed"]
        app.launch()

        let draft = app.textViews["message-draft"]
        XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 10))
        openSidebarIfNeeded(app)
        let parent = app.buttons["pinned-thread:codex:read-fixture"]
        XCTAssertTrue(parent.waitForExistence(timeout: 10))
        parent.tap()
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.tap(); draft.typeText("Keep this draft")
        XCUIDevice.shared.orientation = .landscapeLeft
        guard app.windows.firstMatch.frame.width >= 900 else {
            throw XCTSkip("This iPhone landscape window stays compact")
        }
        let search = app.textFields["sidebar-search"]
        let timeline = app.descendants(matching: .any)["conversation-scroll"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        XCTAssertTrue(search.isHittable, "Chats must stay usable beside the conversation")
        XCTAssertTrue(app.buttons["conversation-title-menu"].isHittable)
        XCTAssertGreaterThanOrEqual(timeline.frame.minX, search.frame.maxX - 10,
                                    "The regular-width sidebar must not cover the conversation")
        XCTAssertFalse(app.buttons["open-sidebar"].exists,
                       "A visible sidebar should not have a redundant drawer control")
        retainMenuScreenshot(app, name: "Chats beside a Project conversation at regular phone width", fullScreen: true)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["conversation-title-menu"].isHittable)
        XCTAssertTrue((draft.value as? String)?.contains("Keep this draft") == true,
                      "Changing the size class must keep the same Project draft")
    }

    private func closeWorkspace(_ app: XCUIApplication) {
        let conversationToggle = app.buttons["conversation-files-pill"]
        let sheetDone = app.buttons["workspace-sheet-done"]
        let toggle = conversationToggle.exists ? conversationToggle : sheetDone.exists ? sheetDone : app.buttons["new-chat-files"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5) && toggle.isHittable,
                      "The bottom Files control must close the workspace")
        toggle.tap()
    }

    private func openSidebarIfNeeded(_ app: XCUIApplication) {
        let search = app.textFields["sidebar-search"]
        if search.exists && search.isHittable && search.frame.minX >= app.frame.minX { return }
        let open = app.buttons["open-sidebar"]
        if open.waitForExistence(timeout: 2) {
            for _ in 0..<2 {
                let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard").descendants(matching: .any)
                    .matching(identifier: "NotificationShortLookView").firstMatch
                if banner.exists { banner.swipeUp() }
                let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: open)
                XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
                open.tap()
                let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    search.exists && search.isHittable && search.frame.minX >= app.frame.minX
                }, object: nil)
                if XCTWaiter.wait(for: [visible], timeout: 5) == .completed { return }
            }
            XCTFail("The sidebar did not become visible")
        }
    }

    private func leaveSettings(_ app: XCUIApplication) {
        if app.navigationBars["Diagnostics"].exists { app.navigationBars.buttons["Settings"].tap() }
        let done = app.buttons["settings-done"]
        if done.exists { done.tap() }
        else {
            let back = app.navigationBars["Settings"].buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), "Pushed Settings must offer a native Back button")
            back.tap()
        }
    }

    private func assertPhoneDrawerClosed(_ app: XCUIApplication, search: XCUIElement) {
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let menu = app.buttons["open-sidebar"]
            return menu.exists && menu.isHittable && (!search.exists ||
                (!search.isHittable && search.frame.maxX <= app.frame.minX + 1))
        }, object: nil)
        let result = XCTWaiter.wait(for: [closed], timeout: 5)
        if result != .completed {
            retainMenuScreenshot(app, name: "Drawer close failure")
            let bounds = XCTAttachment(string: "Search exists=\(search.exists), hittable=\(search.isHittable), frame=\(search.frame).\n" + app.debugDescription)
            bounds.name = "Drawer close hit regions"
            bounds.lifetime = .keepAlways
            add(bounds)
        }
        XCTAssertEqual(result, .completed, "Closing moves the drawer off-screen and makes the main menu usable")
    }

    /// Thread rows of the Projects sidebar, including pinned threads.
    private func threadRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "project-thread:", "pinned-thread:"))
    }

    private func isThreadRowIdentifier(_ identifier: String) -> Bool {
        ["project-thread:", "pinned-thread:"].contains { identifier.hasPrefix($0) && identifier.count > $0.count }
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

    // Navigation is read-only: choosing a project, changing destination and
    // reopening native history must preserve drafts without dispatching a turn.
    func testLiveProjectsSidebarAndDraftsStayReadOnly() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let project = try XCTUnwrap(environment["WONDER_PROJECT_ID"], "Supply an owned test project")
        let name = try XCTUnwrap(environment["WONDER_PROJECT_NAME"])
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launch()
        if app.buttons["settings-done"].waitForExistence(timeout: 2) { app.buttons["settings-done"].tap() }
        openSidebarIfNeeded(app)
        if environment["WONDER_PROJECT_CAPTURE"] == "1" {
            app.buttons["sidebar-settings"].tap()
            app.buttons["diagnostics-settings"].tap()
            let capture = app.buttons["diagnostics-capture"]
            XCTAssertTrue(capture.waitForExistence(timeout: 5))
            if !capture.isEnabled { app.switches["Record performance"].tap() }
            if capture.label == "Record two minutes" { capture.tap() }
            XCTAssertEqual(capture.label, "Stop capture")
            leaveSettings(app)
            openSidebarIfNeeded(app)
        }
        let search = app.textFields["sidebar-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        if app.buttons["Clear search"].exists { app.buttons["Clear search"].tap() }
        search.tap(); search.typeText(name)
        let row = app.buttons["project-row:" + project]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        let draft = app.textViews["new-chat-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["connection-picker"].exists)
        XCTAssertEqual(app.buttons["destination-picker"].value as? String, name)
        let composer = app.otherElements["new-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        for id in ["new-chat-attach", "dictate-message", "new-chat-access", "project-agent-picker", "new-chat-send"] {
            let control = app.buttons[id]
            XCTAssertTrue(control.exists, "Preserve the existing composer control: " + id)
            XCTAssertTrue(composer.frame.insetBy(dx: -1, dy: -1).contains(control.frame), "Keep controls inside the composer: " + id)
        }
        XCTAssertLessThanOrEqual(app.buttons["destination-picker"].frame.maxY, composer.frame.minY)
        app.buttons["project-agent-picker"].tap()
        XCTAssertTrue(app.navigationBars["Model"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["new-chat-attach"].tap()
        XCTAssertTrue(app.buttons["Camera"].exists)
        XCTAssertTrue(app.buttons["Add photo"].exists)
        XCTAssertTrue(app.buttons["Attach file"].exists)
        // On iPhone the native menu covers its anchor. Dismiss outside it;
        // tapping the covered anchor is not a valid composer interaction.
        app.navigationBars["New chat"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.buttons["Camera"].exists)
        retainMenuScreenshot(app, name: "Original composer with connection and project pickers")
        let addition = " Read-only navigation check " + UUID().uuidString
        draft.tap(); draft.typeText(addition)
        let text = try XCTUnwrap(draft.value as? String)
        XCTAssertTrue(text.contains(addition))
        // The header creates a project for this draft's Mac; cancelling keeps the draft.
        app.buttons["new-project"].tap()
        XCTAssertTrue(app.textFields["project-name"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertEqual(draft.value as? String, text)
        if UIDevice.current.userInterfaceIdiom == .phone && app.buttons["open-sidebar"].exists {
            openSidebarIfNeeded(app)
            // The right-hand scrim is outside the drawer's 85% width.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.4)).tap()
            assertPhoneDrawerClosed(app, search: search)
            retainMenuScreenshot(app, name: "Phone drawer closed after scrim tap")
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.35))
            edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.35)))
            XCTAssertTrue(search.waitForExistence(timeout: 5), "A leading-edge swipe opens the drawer")
            XCTAssertTrue(search.isHittable, "The reopened drawer keeps its search field accessible")
            let clearSearch = app.buttons["Clear search"]
            XCTAssertTrue(clearSearch.exists)
            XCTAssertLessThan(clearSearch.frame.width, app.frame.width / 2,
                              "Clear search must retain its own bounds rather than covering the drawer")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.35)).press(forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.35)))
            assertPhoneDrawerClosed(app, search: search)
            XCTAssertTrue(draft.exists, "A drawer swipe must not select the thread under the finger")
            XCTAssertEqual(draft.value as? String, text)
        }
        openSidebarIfNeeded(app)
        app.buttons["sidebar-settings"].tap()
        XCTAssertTrue(app.buttons["settings-add-computer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings-done"].exists, "Sidebar Settings pushes onto the conversation stack")
        leaveSettings(app)
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, text)
        // Projects are the only destinations: the menu offers a new one and keeps this draft.
        app.buttons["destination-picker"].tap()
        XCTAssertTrue(app.buttons["New project"].waitForExistence(timeout: 5))
        app.buttons[name].firstMatch.tap()
        XCTAssertEqual(draft.value as? String, text)
        var threadIdentifier: String?
        for cycle in 0..<(Int(environment["WONDER_PROJECT_CYCLES"] ?? "3") ?? 3) {
            openSidebarIfNeeded(app)
            XCTAssertEqual(search.value as? String, name)
            let disclosure = app.buttons["project-disclosure:" + project]
            XCTAssertTrue(disclosure.waitForExistence(timeout: 10))
            if disclosure.value as? String == "Expanded" { disclosure.tap() }
            XCTAssertEqual(disclosure.value as? String, "Collapsed")
            disclosure.tap()
            XCTAssertEqual(disclosure.value as? String, "Expanded")
            let thread = threadIdentifier.map { app.buttons[$0] } ?? app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-thread:")).firstMatch
            XCTAssertTrue(thread.waitForExistence(timeout: 40))
            threadIdentifier = thread.identifier
            thread.tap()
            let opened = app.buttons["conversation-title-menu"].waitForExistence(timeout: 15)
            if !opened { retainMenuScreenshot(app, name: "Project navigation failure"); print(app.debugDescription) }
            XCTAssertTrue(opened)
            XCTAssertTrue(app.textViews["message-draft"].waitForExistence(timeout: 15))
            XCTAssertNil(app.textViews["message-draft"].label.range(of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, options: .regularExpression), "The composer must use the project title, not its storage identity")
            if cycle == 0 { retainMenuScreenshot(app, name: "Project native conversation") }
            if cycle == 0, environment["WONDER_PROJECT_EDIT_PIN"] == "1" {
                openConversationDetails(app)
                let pin = app.switches["project-thread-pin"]
                XCTAssertTrue(pin.waitForExistence(timeout: 10))
                let previous = try XCTUnwrap(pin.value as? String)
                // SwiftUI exposes the whole Form row as the Switch element;
                // its center is the label. Tap the native switch on the right.
                pin.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                let changed = previous == "1" ? "0" : "1"
                let persisted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ AND enabled == true", changed), object: pin)
                XCTAssertEqual(XCTWaiter.wait(for: [persisted], timeout: 15), .completed)
                app.buttons["Done"].tap()
                openConversationDetails(app)
                XCTAssertTrue(pin.waitForExistence(timeout: 10))
                XCTAssertEqual(pin.value as? String, changed)
                pin.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ AND enabled == true", previous), object: pin)
                XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 15), .completed)
                app.buttons["Done"].tap()
            }
            app.buttons["new-chat"].tap()
            XCTAssertTrue(draft.waitForExistence(timeout: 10))
            XCTAssertEqual(draft.value as? String, text)
        }
        retainMenuScreenshot(app, name: "Project draft after navigation")
        app.terminate(); app.launch()
        XCTAssertTrue(draft.waitForExistence(timeout: 15))
        XCTAssertEqual(draft.value as? String, text)
    }

    func testPairingCodeEntryHasAnAvailableRoute() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-show-connections"]
        app.launch()
        app.buttons["settings-add-computer"].tap()
        XCTAssertTrue(app.textFields["Or paste pairing link"].waitForExistence(timeout: 5))
        app.buttons["pairing-entry-mode"].tap()
        let address = app.textFields["pairing-mac-address"]
        let code = app.textFields["pairing-code"]
        let connect = app.buttons["pairing-connect-code"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertTrue(code.exists)
        XCTAssertFalse(connect.isEnabled)
        address.tap(); address.typeText("https://example.invalid")
        code.tap(); code.typeText("ABCD_123-4")
        XCTAssertEqual(code.value as? String, "ABCD_123-4")
        XCTAssertTrue(connect.isEnabled)
        XCTAssertTrue(connect.isHittable, "The connect action must stay visible above the keyboard on iPad.")
        retainMenuScreenshot(app, name: "Mac address and code pairing route")
        app.buttons["pairing-entry-mode"].tap()
        let link = app.textFields["Or paste pairing link"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        XCTAssertFalse(address.exists)
        link.tap(); link.typeText("https://example.invalid/wonder/pair?offer=fixture&challenge=fixture")
        XCTAssertTrue(app.buttons["pairing-connect-link"].isHittable,
                      "The link action must stay visible above the keyboard on iPad.")
    }

    func testPairForLiveRun() throws {
        continueAfterFailure = false
        guard let link = ProcessInfo.processInfo.environment["WONDER_PAIRING_LINK"] else { throw XCTSkip("No explicit pairing offer supplied.") }
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-show-connections"]
        app.launch()
        app.buttons["settings-add-computer"].tap()
        let field = app.textFields["Or paste pairing link"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(link)
        let connect = app.buttons["pairing-connect-link"]
        XCTAssertTrue(connect.isHittable, "The connect action must stay visible above the keyboard.")
        connect.tap()
        let verification = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Verification text ")).firstMatch
        if !verification.waitForExistence(timeout: 15) {
            let failure = app.buttons["Couldn’t connect"]
            if failure.exists { failure.tap() }
            let detail = app.staticTexts.allElementsBoundByIndex.map(\.label)
                .filter { $0 != "Couldn’t connect" && $0 != "QR code or pairing link" }
                .joined(separator: " | ")
            XCTFail("The phone must expose the verification text before Mac confirmation. \(detail)")
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.buttons["Stop pairing"].exists && !field.exists
        }, object: nil)], timeout: 60), .completed)
        XCTAssertTrue(app.buttons["settings-add-computer"].isHittable)
        retainMenuScreenshot(app, name: "Physical pairing completed")
    }

    func testPairWithCodeForLiveRun() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["WONDER_PAIRING_ADDRESS"],
              let code = environment["WONDER_PAIRING_CODE"] else {
            throw XCTSkip("No explicit Mac pairing address and code supplied.")
        }
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-show-connections"]
        app.launch()
        app.buttons["settings-add-computer"].tap()
        app.buttons["pairing-entry-mode"].tap()
        let addressField = app.textFields["pairing-mac-address"]
        let codeField = app.textFields["pairing-code"]
        XCTAssertTrue(addressField.waitForExistence(timeout: 5))
        addressField.tap(); addressField.typeText(address)
        codeField.tap(); codeField.typeText(code)
        app.buttons["pairing-connect-code"].tap()
        let verification = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Verification text ")).firstMatch
        if !verification.waitForExistence(timeout: 15) {
            let failure = app.buttons["Couldn’t connect"]
            if failure.exists { failure.tap() }
            XCTFail("Pairing code failed: \(app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))")
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.buttons["Stop pairing"].exists && !codeField.exists
        }, object: nil)], timeout: 60), .completed)
        XCTAssertTrue(app.buttons["settings-add-computer"].isHittable)
    }

    // The runner must preflight an owned disposable Project thread on this
    // host and supply its exact IDs separately from the link under test.
    private func liveOwnedProjectURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let link = environment["WONDER_LIVE_PROJECT_LINK"],
              let host = environment["WONDER_LIVE_PROJECT_HOST_ID"], UUID(uuidString: host) != nil,
              let thread = environment["WONDER_LIVE_PROJECT_THREAD_ID"], UUID(uuidString: thread) != nil,
              let url = URL(string: link),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == (appBundleIdentifier == "com.swaymun.wonder.testing" ? "wonder-testing" : "wonder"),
              parts.host == "v1", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath == "/hosts/\(host)/chats/\(thread)" else {
            throw XCTSkip("No exact preflighted owned Project thread supplied.")
        }
        return url
    }

    func testLiveOwnedProjectHeaderFitsAtLargeText() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.open(try liveOwnedProjectURL())
        let menu = app.buttons["conversation-title-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        XCTAssertGreaterThanOrEqual(menu.frame.minX, app.frame.minX + 8)
        XCTAssertLessThanOrEqual(menu.frame.maxX, app.frame.maxX - 8)
        retainMenuScreenshot(app, name: "Project title fits the conversation header")
    }

    // The check never sends a turn; it removes its sole draft attachment.
    func testLiveOwnedProjectFilesAndAnnotationStayUnsent() throws {
        continueAfterFailure = false
        let url = try liveOwnedProjectURL()
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.open(url)
        XCTAssertTrue(app.buttons["conversation-title-menu"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["composer-annotation-edit"].exists,
                       "The disposable thread must start without an older unsent comment")
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        let fileList = app.collectionViews["workspace-file-list"]
        XCTAssertTrue(fileList.waitForExistence(timeout: 10))
        let readme = app.buttons["workspace-file-entry:README.md"]
        for _ in 0..<15 where !readme.isHittable { fileList.swipeUp() }
        XCTAssertTrue(readme.isHittable, "The paired Project root should expose README.md")
        readme.tap()
        selectTextForPreviewComment(app)
        let note = app.descendants(matching: .any)["annotation-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap(); note.typeText("Check this preview line")
        app.buttons["annotation-add"].tap()
        let chip = app.buttons["composer-annotation-edit"]
        let staged = chip.waitForExistence(timeout: 10)
        if staged { retainMenuScreenshot(app, name: "Live Project comment in composer") }
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove comment")).firstMatch
        let removable = remove.waitForExistence(timeout: 5)
        if removable { remove.tap() }
        XCTAssertTrue(staged, "The note must become an unsent composer attachment")
        XCTAssertTrue(removable, "The test note must offer immediate removal")
        XCTAssertFalse(chip.exists, "The test must leave no comment in the composer")

        app.buttons["workspace-preview-back"].tap()
        app.buttons["Modified"].tap()
        let change = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace-modified-entry:")).firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 15), "The paired Mac should return its live Git changes")
        change.tap()
        XCTAssertTrue(workspacePreviewClose(app, legacyID: "workspace-diff-close").waitForExistence(timeout: 10))
        retainMenuScreenshot(app, name: "Live Project diff")
        workspacePreviewClose(app, legacyID: "workspace-diff-close").tap()
        closeWorkspace(app)
        XCTAssertTrue(app.textViews["message-draft"].exists)
    }

    func testLiveOwnedProjectImagePreviewWithoutSending() throws {
        continueAfterFailure = false
        let url = try liveOwnedProjectURL()
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.open(url)
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 20))
        files.tap()
        let fileList = app.collectionViews["workspace-file-list"]
        XCTAssertTrue(fileList.waitForExistence(timeout: 10))
        func openEntry(_ id: String) {
            let entry = app.buttons[id]
            // A List retains its scroll position when navigating back from a
            // child folder. Search both directions for the next known entry.
            for _ in 0..<15 where !entry.isHittable { fileList.swipeDown() }
            for _ in 0..<25 where !entry.isHittable { fileList.swipeUp() }
            XCTAssertTrue(entry.isHittable, "Missing live Project file \(id)")
            entry.tap()
        }
        openEntry("workspace-directory-entry:assets")
        openEntry("workspace-directory-entry:assets/screenshots")
        openEntry("workspace-file-entry:assets/screenshots/pairing.png")
        let loadedImage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo-viewer-image:")).firstMatch
        XCTAssertTrue(loadedImage.waitForExistence(timeout: 10), "The authenticated PNG must decode and render")
        XCTAssertTrue(app.buttons["annotation-image-open"].isHittable)
        retainMenuScreenshot(app, name: "Live Project image preview")
        workspacePreviewClose(app, legacyID: "photo-viewer-close").tap()
        closeWorkspace(app)
        XCTAssertTrue(app.textViews["message-draft"].exists)
    }

    func testLiveOwnedProjectPDFPreviewWithoutSending() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.open(try liveOwnedProjectURL())
        XCTAssertTrue(app.buttons["conversation-title-menu"].waitForExistence(timeout: 20))
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        let fileList = app.collectionViews["workspace-file-list"]
        XCTAssertTrue(fileList.waitForExistence(timeout: 10))
        for path in ["output", "output/pdf"] {
            let entry = app.buttons["workspace-directory-entry:\(path)"]
            // Move less than one viewport each time so a large-text row cannot
            // pass between two accessibility snapshots unnoticed.
            for _ in 0..<40 where !entry.isHittable {
                let start = fileList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
                let end = fileList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.43))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            XCTAssertTrue(entry.isHittable, "Missing live Project directory \(path)")
            entry.tap()
        }
        let pdf = app.buttons["workspace-file-entry:output/pdf/design-qa.pdf"]
        for _ in 0..<15 where !pdf.isHittable { fileList.swipeUp() }
        XCTAssertTrue(pdf.isHittable, "The paired Project PDF should appear")
        pdf.tap()
        XCTAssertTrue(workspacePreviewClose(app, legacyID: "workspace-document-close").waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Preview unavailable"].exists)
        retainMenuScreenshot(app, name: "Live Project iPad PDF preview")
        workspacePreviewClose(app, legacyID: "workspace-document-close").tap()
        closeWorkspace(app)
        XCTAssertTrue(app.textViews["message-draft"].exists)
    }

    // Runs only against the owner's temporary paired QA device and disposable
    // media file. Opening and controlling the preview never sends a turn.
    func testLiveOwnedProjectMediaPreviewWithoutSending() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment["WONDER_LIVE_PROJECT_MEDIA"] == "1",
              let mediaFolder = environment["WONDER_LIVE_PROJECT_MEDIA_FOLDER"],
              !mediaFolder.isEmpty else {
            throw XCTSkip("No disposable live media fixture supplied.")
        }
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.open(try liveOwnedProjectURL())
        let files = app.buttons["conversation-files-pill"]
        XCTAssertTrue(files.waitForExistence(timeout: 20))
        files.tap()
        let fileList = app.collectionViews["workspace-file-list"]
        XCTAssertTrue(fileList.waitForExistence(timeout: 10))
        let folder = app.buttons["workspace-directory-entry:\(mediaFolder)"]
        for _ in 0..<25 where !folder.isHittable { fileList.swipeUp() }
        XCTAssertTrue(folder.isHittable)
        folder.tap()
        XCTAssertTrue(app.buttons["workspace-back"].waitForExistence(timeout: 5),
                      "The selected media folder must open before previewing a file")
        let video = app.buttons["workspace-file-entry:\(mediaFolder)/seekable.mp4"]
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        let opened = Date()
        video.tap()
        let player = app.descendants(matching: .any)["workspace-media-player"]
        XCTAssertTrue(player.waitForExistence(timeout: 20), "The paired Mac must stream the video preview")
        XCTAssertFalse(app.staticTexts["Playback unavailable"].exists)
        print("LIVE_VIDEO_PLAYER_READY_SECONDS=\(Date().timeIntervalSince(opened))")
        retainMenuScreenshot(app, name: "Live authenticated Project video preview")
        player.tap()
        let playPause = app.buttons["Play/Pause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5), "AVKit must expose playback controls")
        // AVKit's volume slider also advertises "Current position" as its
        // accessibility label. Match the timeline's identifier exactly.
        let scrubber = app.sliders.matching(NSPredicate(format: "identifier == %@", "Current position")).firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5), app.debugDescription)
        let initialPosition = scrubber.value as? String
        Thread.sleep(forTimeInterval: 2)
        // AVKit hides its controls while playing. Reveal them before reading
        // or adjusting the timeline, including on iPad's different layout.
        if !scrubber.exists { player.tap() }
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        XCTAssertNotEqual(scrubber.value as? String, initialPosition,
                          "The authenticated video timeline must advance")
        if !playPause.exists { player.tap() }
        playPause.tap()
        if !scrubber.exists { player.tap() }
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        func elapsedSeconds() throws -> Int {
            let value = try XCTUnwrap(scrubber.value as? String)
            let first = String(try XCTUnwrap(value.split(separator: " ").first))
            let pieces = first.split(separator: ":").compactMap { Int($0) }
            if pieces.count == 2 { return pieces[0] * 60 + pieces[1] }
            return try XCTUnwrap(Int(first), "Unknown AVKit timeline value: \(value)")
        }
        scrubber.adjust(toNormalizedSliderPosition: 0)
        XCTAssertLessThanOrEqual(try elapsedSeconds(), 1, "The paused timeline must seek to the start")
        let seekStarted = Date()
        scrubber.adjust(toNormalizedSliderPosition: 0.75)
        let soughtSecond = try elapsedSeconds()
        XCTAssertTrue((5...7).contains(soughtSecond),
                      "The paused eight-second video must seek near six seconds; got \(soughtSecond)")
        print("LIVE_VIDEO_SEEK_SECONDS=\(Date().timeIntervalSince(seekStarted))")
        retainMenuScreenshot(app, name: "Live authenticated Project video controls")
        workspacePreviewClose(app, legacyID: "workspace-media-close").tap()
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        let audio = app.buttons["workspace-file-entry:\(mediaFolder)/tone.m4a"]
        XCTAssertTrue(audio.waitForExistence(timeout: 5))
        audio.tap()
        XCTAssertTrue(player.waitForExistence(timeout: 20), "The paired Mac must stream the audio preview")
        XCTAssertFalse(app.staticTexts["Playback unavailable"].exists)
        player.tap()
        XCTAssertTrue(playPause.waitForExistence(timeout: 5), "AVKit must expose audio playback controls")
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5), app.debugDescription)
        let initialAudioPosition = scrubber.value as? String
        Thread.sleep(forTimeInterval: 2)
        if !scrubber.exists { player.tap() }
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        XCTAssertNotEqual(scrubber.value as? String, initialAudioPosition,
                          "The authenticated audio timeline must advance")
        retainMenuScreenshot(app, name: "Live authenticated Project audio controls")
        workspacePreviewClose(app, legacyID: "workspace-media-close").tap()
        XCTAssertTrue(audio.waitForExistence(timeout: 5))
        closeWorkspace(app)
        XCTAssertTrue(app.textViews["message-draft"].exists)
    }

    // The anchored computer picker must dismiss before changing hosts or opening
    // pairing, while the real new-chat composer restores each Mac's own draft.
    func testConnectionPickerChoosesMacAndOpensPairing() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-connections-preview"]
        app.launch()
        let picker = app.buttons["connection-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        picker.tap()
        let studio = app.buttons["connection-option:studio"]
        XCTAssertTrue(studio.waitForExistence(timeout: 5))
        retainMenuScreenshot(app, name: "Connection status dots before Mac names")
        studio.tap()
        XCTAssertTrue((picker.value as? String)?.hasPrefix("Studio, ") == true, "\(String(describing: picker.value))")
        let draft = app.textViews["new-chat-draft"]
        draft.tap()
        draft.typeText(" Picker check " + UUID().uuidString)
        let text = try XCTUnwrap(draft.value as? String)
        for _ in 0..<10 {
            picker.tap()
            app.buttons["connection-option:macbook"].tap()
            XCTAssertTrue((picker.value as? String)?.hasPrefix("Laptop, ") == true)
            XCTAssertFalse(app.buttons["connection-option:studio"].exists)
            picker.tap()
            XCTAssertEqual(app.buttons["connection-option:macbook"].value as? String, "Connected, Selected")
            studio.tap()
            XCTAssertTrue((picker.value as? String)?.hasPrefix("Studio, ") == true)
            XCTAssertEqual(draft.value as? String, text)
        }
        picker.tap()
        let options = app.scrollViews["connection-options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCTAssertTrue(options.frame.contains(studio.frame), "The selected computer must remain fully visible above the keyboard.")
        retainMenuScreenshot(app, name: "Connection picker with keyboard and restored draft")
        options.swipeUp()
        let addComputer = app.buttons["connection-add-computer"]
        XCTAssertTrue(options.frame.contains(addComputer.frame), "Add computer must scroll fully into view.")
        retainMenuScreenshot(app, name: "Connection picker scrolled to Add computer")
        addComputer.tap()
        XCTAssertTrue(app.navigationBars["Add computer"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, text)
        app.terminate()
    }

    // An offline pending creation must explain its locked fields and offer a
    // durable escape. No messages or model work run in this synthetic fixture.
    func testUnconfirmedNewChatCanStartEditableDraftAndReviewOriginal() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-connections-preview", "-reset-new-chat-pending-preview"]
        app.launch()
        let notice = app.staticTexts["new-chat-pending-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        let draft = app.textViews["new-chat-draft"]
        XCTAssertEqual(draft.value as? String, "Saved unconfirmed message")
        let removals = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "composer-attachment-remove:"))
        XCTAssertTrue(removals.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(removals.firstMatch.isEnabled)
        XCTAssertFalse(app.buttons["connection-picker"].isEnabled)
        XCTAssertFalse(app.buttons["destination-picker"].isEnabled)
        let newDraft = app.buttons["new-chat-start-new-draft"]
        XCTAssertTrue(newDraft.isHittable)
        retainMenuScreenshot(app, name: "Unconfirmed new chat with visible recovery")
        newDraft.tap()
        XCTAssertFalse(notice.exists)
        XCTAssertEqual(removals.count, 0)
        XCTAssertEqual(draft.value as? String, "")
        draft.tap(); draft.typeText("Editable words")
        XCTAssertEqual(draft.value as? String, "Editable words")
        draft.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(draft.value as? String, "Editable word")
        XCTAssertTrue(app.buttons["connection-picker"].isEnabled)
        XCTAssertTrue(app.buttons["destination-picker"].isEnabled)
        app.buttons["connection-picker"].tap()
        XCTAssertTrue(app.buttons["connection-option:macbook"].waitForExistence(timeout: 5))
        app.buttons["connection-option:macbook"].tap()
        XCTAssertEqual(app.buttons["connection-picker"].value as? String, "Laptop, Connected")
        app.buttons["connection-picker"].tap()
        app.buttons["connection-option:studio"].tap()
        XCTAssertEqual(draft.value as? String, "Editable word")
        app.buttons["destination-picker"].tap()
        XCTAssertTrue(app.buttons["New project"].waitForExistence(timeout: 5))
        app.navigationBars["New chat"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        retainMenuScreenshot(app, name: "Editable draft preserves saved pending message")
        app.terminate()
        app.launchArguments = ["-connections-preview"]
        app.launch()
        XCTAssertTrue(draft.waitForExistence(timeout: 15))
        XCTAssertEqual(draft.value as? String, "Editable word")
        let saved = app.buttons["new-chat-pending-messages"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.tap()
        app.buttons["Saved unconfirmed message"].tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "Saved unconfirmed message")
        XCTAssertTrue(removals.firstMatch.waitForExistence(timeout: 5))
        newDraft.tap()
        XCTAssertEqual(draft.value as? String, "Editable word")
        app.terminate()
    }

    // Exercise the real App/WindowGroup boundary. A view-only fixture cannot
    // catch a root builder invoked by SwiftUI's asynchronous renderer.
    func testRootSceneSurvivesRepeatedLaunchAndForeground() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-connections-preview", "-show-connections"]
        for _ in 0..<10 {
            app.launch()
            XCTAssertTrue(app.buttons["settings-add-computer"].waitForExistence(timeout: 15))
            for _ in 0..<2 {
                leaveSettings(app)
                XCUIDevice.shared.press(.home)
                app.activate()
                openSidebarIfNeeded(app)
                XCTAssertTrue(app.buttons["sidebar-settings"].waitForExistence(timeout: 10))
                app.buttons["sidebar-settings"].tap()
                XCTAssertTrue(app.buttons["settings-add-computer"].waitForExistence(timeout: 10))
                XCTAssertEqual(app.state, .runningForeground)
            }
            app.terminate()
        }
    }

    func testPairedConnectionSurvivesRelaunchAndForeground() throws {
        continueAfterFailure = false
        guard let host = ProcessInfo.processInfo.environment["WONDER_PAIRING_HOST_NAME"] else {
            throw XCTSkip("An explicit paired host is required.")
        }
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-show-connections"]
        for pass in 0..<10 {
            app.launch()
            let computer = app.buttons[host]
            XCTAssertTrue(computer.waitForExistence(timeout: 15))
            computer.tap()
            let check = app.buttons["Check connection"]
            XCTAssertTrue(check.waitForExistence(timeout: 10))
            check.tap()
            let connected = app.staticTexts["Connected to your computer."]
            if !connected.waitForExistence(timeout: 25) {
                retainMenuScreenshot(app, name: "Connection failure")
                XCTFail("Connection failed: \(app.staticTexts["connection-status"].label)")
            }
            XCTAssertFalse(app.buttons["Pair again"].exists)
            for _ in 0..<2 {
                XCUIDevice.shared.press(.home)
                app.activate()
                XCTAssertTrue(connected.waitForExistence(timeout: 25))
                XCTAssertTrue(check.isEnabled)
                XCTAssertFalse(app.buttons["Pair again"].exists)
            }
            if pass == 9 { retainMenuScreenshot(app, name: "Paired connection after ten launches and twenty resumes") }
            app.terminate()
        }
    }

    func testPhysicalPairingRelaunchRenewsAndReadsExistingChats() throws {
        continueAfterFailure = false
        guard let host = ProcessInfo.processInfo.environment["WONDER_PAIRING_HOST_NAME"] else { throw XCTSkip("An explicit paired host is required.") }
        guard let qaRowID = ProcessInfo.processInfo.environment["WONDER_PAIRING_QA_CONVERSATION_ID"],
              isThreadRowIdentifier(qaRowID) else {
            throw XCTSkip("Supply WONDER_PAIRING_QA_CONVERSATION_ID with the exact dedicated QA thread-row accessibility identifier.")
        }
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
            leaveSettings(app)
            openSidebarIfNeeded(app)
            let chat = app.buttons.matching(identifier: qaRowID).firstMatch
            XCTAssertTrue(chat.waitForExistence(timeout: 20))
            chat.tap()
            XCTAssertTrue(app.buttons["conversation-title-menu"].waitForExistence(timeout: 15))
            // Only the explicitly selected QA conversation is read; no message is submitted.
            retainMenuScreenshot(app, name: "Physical paired conversation after launch \(pass + 1)")
            app.terminate()
        }
    }

    func testComposerBlocksExhaustedUsageWithoutPhantomFolderError() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-chat-layout",
            "-diagnostics-folder-poll-offline", "-diagnostics-usage-fixture", "-diagnostics-usage-exhausted"]
        app.launch()
        let draft = app.textViews["message-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10)); draft.tap(); draft.typeText("Keep this draft")
        let limit = app.staticTexts["composer-usage-limit"]
        XCTAssertTrue(limit.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(limit.frame.maxY, draft.frame.minY, "The usage notice stays inside the composer above the editor")
        XCTAssertGreaterThanOrEqual(limit.frame.minX, draft.frame.minX)
        XCTAssertFalse(app.buttons["send-message"].isEnabled)
        let pill = app.buttons["computer-status-pill"]
        XCTAssertEqual(pill.label, "View computer")
        XCTAssertFalse(pill.staticTexts["Computer"].exists)
        XCTAssertGreaterThanOrEqual(pill.frame.height, 44)
        let phantomError = app.staticTexts["Folder request unavailable"]
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in phantomError.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 7), .timedOut,
                       "Repeated failed empty polls must not show a folder request error")
        XCTAssertEqual(draft.value as? String, "Keep this draft")
        XCTAssertFalse(app.buttons["send-message"].isEnabled)
        retainMenuScreenshot(app, name: "Icon-only computer and exhausted usage")
    }

    func testConnectedAppsKeepNamesAndIconsAcrossFamilies() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        for (style, size) in [("Light", "UICTContentSizeCategoryL"), ("Dark", "UICTContentSizeCategoryAccessibilityXXL")] {
            app.launchArguments = ["-diagnostics-connected-apps", "-AppleInterfaceStyle", style,
                                   "-UIPreferredContentSizeCategoryName", size]
            if style == "Dark" { app.launchArguments.append("-diagnostics-connected-apps-dark") }
            app.launch()
            let claude = app.segmentedControls.buttons["Claude"]
            let codex = app.segmentedControls.buttons["Codex"]
            let familyPickerReady = claude.waitForExistence(timeout: 15)
            if !familyPickerReady {
                retainMenuScreenshot(app, name: "Missing connection family picker \(style)")
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.lifetime = .keepAlways; add(hierarchy)
            }
            XCTAssertTrue(familyPickerReady)
            XCTAssertTrue(app.staticTexts["Gmail"].waitForExistence(timeout: 10))
            retainMenuScreenshot(app, name: "Codex connection icons \(style)")
            for _ in 0..<8 {
                claude.tap()
                XCTAssertTrue(claude.isSelected, "The provider selection must change before loading its connections")
                XCTAssertTrue(app.staticTexts["Claude Docs"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["Gmail"].exists)
                XCTAssertFalse(app.staticTexts["claude.ai Gmail"].exists)
                codex.tap()
                XCTAssertTrue(codex.isSelected)
                XCTAssertTrue(app.staticTexts["Gmail"].waitForExistence(timeout: 5))
                XCTAssertFalse(app.staticTexts["Claude Docs"].exists)
            }
            claude.tap()
            XCTAssertTrue(app.staticTexts["Claude Docs"].waitForExistence(timeout: 5))
            if style == "Dark" {
                let gmail = app.cells.containing(.staticText, identifier: "Gmail").firstMatch
                XCTAssertGreaterThanOrEqual(gmail.staticTexts["Available"].frame.minY, gmail.staticTexts["Gmail"].frame.maxY,
                                           "Accessibility text should stack the status below the name")
            }
            retainMenuScreenshot(app, name: "Connected apps \(style) \(size)")
            app.terminate()
        }
    }

    func testProjectConnectedAppsUseConversationScopeAndExplainRecovery() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-connected-apps", "-diagnostics-connected-apps-project"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Gmail"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Available"].exists)
        XCTAssertFalse(app.segmentedControls.buttons["Claude"].exists,
                       "Conversation access must stay scoped to its Project provider")
        retainMenuScreenshot(app, name: "Project connected apps", fullScreen: true)
        app.terminate()

        app.launchArguments = ["-diagnostics-connected-apps", "-diagnostics-connected-apps-project",
                               "-diagnostics-connected-apps-stale"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Start this conversation or reopen it, then check its app access again."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["connected-apps-retry"].exists)
        XCTAssertFalse(app.staticTexts["Available"].exists)
        app.terminate()

        app.launchArguments = ["-diagnostics-connected-apps", "-diagnostics-connected-apps-project",
                               "-diagnostics-connected-apps-unloaded"]
        app.launch()
        XCTAssertTrue(app.staticTexts["This conversation’s app access isn’t available right now. Check account-wide apps in Settings."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["connected-apps-retry"].exists)
        XCTAssertFalse(app.staticTexts["Available"].exists)
        retainMenuScreenshot(app, name: "Unloaded Project app access", fullScreen: true)
        app.terminate()

        app.launchArguments = ["-diagnostics-connected-apps", "-diagnostics-connected-apps-project",
                               "-diagnostics-connected-apps-unloaded-after-refresh"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Available"].waitForExistence(timeout: 10))
        app.buttons["Refresh"].tap()
        let unavailable = app.staticTexts["This conversation’s app access isn’t available right now. Check account-wide apps in Settings."]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
        let reopen = app.buttons["connected-apps-reopen-fixture"]
        reopen.tap()
        let remounted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: reopen)
        XCTAssertEqual(XCTWaiter.wait(for: [remounted], timeout: 10), .completed)
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Available"].exists)
        app.terminate()
    }

    // Provider cache mix-ups must be visible here: each fixture has distinct
    // percentages, and both providers stay in the existing connection settings.
    func testDiagnosticsCodexUsageIsInlineInConnectionSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-connections-preview", "-diagnostics-usage-fixture", "-show-connections"]
        app.launch()

        let studio = app.buttons["Studio"]
        XCTAssertTrue(studio.waitForExistence(timeout: 10))
        studio.tap()
        XCTAssertTrue(app.switches["connection-notifications"].exists)
        XCTAssertTrue(app.switches["connection-notifications"].isEnabled)

        let heading = app.staticTexts["Codex usage"]
        for _ in 0..<6 where !heading.exists { app.swipeUp() }
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        let fiveHours = app.descendants(matching: .any).matching(identifier: "codex-usage-window:five-hours").firstMatch
        let weekly = app.descendants(matching: .any).matching(identifier: "codex-usage-window:weekly").firstMatch
        for _ in 0..<6 where !fiveHours.exists { app.swipeUp() }
        XCTAssertTrue(fiveHours.waitForExistence(timeout: 10))
        XCTAssertEqual(fiveHours.label, "5 hours")
        XCTAssertEqual(fiveHours.value as? String, "73% left")
        for _ in 0..<6 where !weekly.exists { app.swipeUp() }
        XCTAssertTrue(weekly.waitForExistence(timeout: 10))
        XCTAssertEqual(weekly.label, "Weekly")
        XCTAssertEqual(weekly.value as? String, "59% left")
        XCTAssertFalse(app.navigationBars["Codex usage"].exists, "Codex usage must remain inline, not a navigation destination")
        retainMenuScreenshot(app, name: "Codex usage inline settings")
        let claudeFive = app.descendants(matching: .any).matching(identifier: "claude-usage-window:five_hour").firstMatch
        for _ in 0..<4 where !claudeFive.isHittable { app.swipeUp() }
        XCTAssertTrue(claudeFive.waitForExistence(timeout: 10))
        XCTAssertEqual(claudeFive.value as? String, "86% left")
        let claudeWeek = app.descendants(matching: .any).matching(identifier: "claude-usage-window:seven_day").firstMatch
        XCTAssertTrue(claudeWeek.exists)
        XCTAssertEqual(claudeWeek.value as? String, "92% left")
        XCTAssertFalse(app.navigationBars["Claude usage"].exists)
        retainMenuScreenshot(app, name: "Claude usage inline settings")
    }

    func testCodexUsageDistinguishesEmptyAndUnavailable() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        for (flag, expected) in [
            ("-diagnostics-usage-empty", "Codex returned no usage windows. Check Codex sign-in on your Mac."),
            ("-diagnostics-usage-unsupported", "This Codex version doesn't provide usage details in Wonder."),
            ("-diagnostics-usage-unavailable", "Codex usage couldn't be verified on this Mac. Check Codex sign-in, then try again.")
        ] {
            app.launchArguments = ["-connections-preview", "-diagnostics-usage-fixture", flag, "-show-connections"]
            app.launch()
            let studio = app.buttons["Studio"]
            XCTAssertTrue(studio.waitForExistence(timeout: 10))
            studio.tap()
            for _ in 0..<6 where !app.staticTexts[expected].exists { app.swipeUp() }
            XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 10))
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "codex-usage-window:five-hours").firstMatch.exists)
            if flag != "-diagnostics-usage-empty" {
                XCTAssertTrue(app.buttons["codex-usage-retry"].exists)
            }
            retainMenuScreenshot(app, name: "Codex usage \(flag)")
            app.terminate()
        }
    }

    func testCodexUsageRefreshFailureMarksPreviousValuesStale() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-connections-preview", "-diagnostics-usage-fixture",
                               "-diagnostics-usage-refresh-fails", "-diagnostics-usage-fast-refresh", "-show-connections"]
        app.launch()
        let studio = app.buttons["Studio"]
        XCTAssertTrue(studio.waitForExistence(timeout: 10))
        studio.tap()
        let fiveHours = app.descendants(matching: .any).matching(identifier: "codex-usage-window:five-hours").firstMatch
        for _ in 0..<6 where !fiveHours.exists { app.swipeUp() }
        XCTAssertTrue(fiveHours.exists)
        XCTAssertFalse(app.buttons["codex-usage-refresh"].exists, "Usage refreshes on its own")
        // The automatic refresh fails; the earlier values stay, marked stale.
        let stale = app.staticTexts["Previous usage values may be out of date."]
        for _ in 0..<5 where !stale.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(stale.exists)
        for _ in 0..<4 where !fiveHours.exists { app.swipeUp() }
        XCTAssertTrue(fiveHours.waitForExistence(timeout: 5))
        XCTAssertEqual(fiveHours.value as? String, "73% left")
        let retry = app.buttons["codex-usage-retry"]
        for _ in 0..<6 where !retry.exists { app.swipeUp() }
        XCTAssertTrue(retry.exists)
        for _ in 0..<6 where !fiveHours.exists { app.swipeDown() }
        XCTAssertEqual(fiveHours.value as? String, "73% left")
        retainMenuScreenshot(app, name: "Codex usage stale refresh")
    }

    func testNativeQuestionHistoryShowsSelectionsWithoutReplyMetadata() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXL"] {
            app.launchArguments = ["-read-preview", "-send-preview", "-native-question-history-preview", "-UIPreferredContentSizeCategoryName", size]
            app.launch()
            let form = anyElement(app, identifier: "native-question-native-history-turn/native-history-question")
            XCTAssertTrue(form.waitForExistence(timeout: 10))
            XCTAssertEqual(form.value as? String, "Collapsed")
            XCTAssertTrue(form.label.contains("Ada"), "The saved question must identify its speaker for VoiceOver")
            for _ in 0..<10 {
                form.tap()
                XCTAssertEqual(form.value as? String, "Expanded")
                XCTAssertTrue(app.staticTexts["Which day works best?"].exists)
                let freeAnswer = app.staticTexts["Your answer: Navigation"]
                XCTAssertTrue(freeAnswer.exists)
                XCTAssertEqual(freeAnswer.label, "Your answer: Navigation")
                let selectedAnswer = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Your answer: Saturday, selected")).firstMatch
                XCTAssertTrue(selectedAnswer.exists)
                XCTAssertEqual(selectedAnswer.label, "Your answer: Saturday, selected")
                XCTAssertFalse(app.buttons["Reply"].exists, "Imported history must not create an actionable reply")
                XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "send_user_message_question_reply")).firstMatch.exists)
                form.tap()
                XCTAssertEqual(form.value as? String, "Collapsed")
            }
            retainMenuScreenshot(app, name: "Native saved question " + size)
            app.terminate()
        }
    }

    func testQuestionMultipleChoicesSurviveQuestionNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXL"] {
            app.launchArguments = ["-read-preview", "-send-preview", "-question-preview", "-UIPreferredContentSizeCategoryName", size]
            app.launch()
            let draft = app.textViews["message-draft"]
            XCTAssertTrue(draft.waitForExistence(timeout: 10))
            let notice = app.buttons["question-dock-open"]
            XCTAssertTrue(notice.waitForExistence(timeout: 10))
            XCTAssertTrue(notice.isHittable, "The question notice must stay above the composer")
            XCTAssertFalse(app.buttons["Next question"].exists, "Questions should open in their sheet")
            notice.tap()
            let next = app.buttons["Next question"]
            XCTAssertTrue(next.waitForExistence(timeout: 10))
            next.tap()
            let first = app.buttons["question-option-fixtures-A, B"]
            let second = app.buttons["question-option-fixtures-C"]
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            first.tap()
            second.tap()
            for _ in 0..<10 {
                XCTAssertTrue(first.isSelected)
                XCTAssertTrue(second.isSelected)
                app.buttons["Previous question"].tap()
                next.tap()
            }
            XCTAssertTrue(first.isSelected)
            XCTAssertTrue(second.isSelected)
            second.tap()
            XCTAssertFalse(second.isSelected)
            XCTAssertTrue(first.isSelected, "A comma in one label must not select another answer")
            let done = app.buttons["Done"]
            XCTAssertTrue(done.exists)
            done.tap()
            XCTAssertTrue(draft.isHittable, "Closing questions must return to the composer")
            XCTAssertTrue(notice.exists)
            retainMenuScreenshot(app, name: "Multiple question choices " + size)
            app.terminate()
        }
    }

    func testQuestionReplyAndSkipClearNoticeWithoutLosingComposerDraft() throws {
        continueAfterFailure = false
        for decision in ["reply", "skip"] {
            let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
            app.launchArguments = ["-diagnostics-subagent-fixture", "-diagnostics-question-resolution"]
            app.launch()
            let draft = app.textViews["message-draft"]
            XCTAssertTrue(draft.waitForExistence(timeout: 15), app.debugDescription)
            draft.tap(); draft.typeText("Keep this unsent draft")
            let notice = app.buttons["question-dock-open"]
            XCTAssertTrue(notice.waitForExistence(timeout: 10))
            notice.tap()
            if decision == "reply" {
                let day = app.buttons["Saturday"]
                XCTAssertTrue(day.waitForExistence(timeout: 5))
                retainMenuScreenshot(app, name: "Question sheet keeps draft")
                day.tap()
                app.buttons["Next question"].tap()
                let fixtures = app.buttons["question-option-fixtures-A, B"]
                XCTAssertTrue(fixtures.waitForExistence(timeout: 5))
                fixtures.tap()
                let reply = app.buttons["Reply"]
                XCTAssertTrue(reply.isEnabled)
                reply.tap()
            } else {
                let skip = app.buttons["Skip"]
                XCTAssertTrue(skip.waitForExistence(timeout: 5))
                skip.tap()
            }
            let resolved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !notice.exists }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [resolved], timeout: 10), .completed,
                           "The Mac fixture must accept the \(decision) payload and clear the pending question")
            let done = app.buttons["Done"]
            if done.isHittable { done.tap() }
            XCTAssertTrue(draft.waitForExistence(timeout: 5))
            XCTAssertTrue((draft.value as? String)?.contains("Keep this unsent draft") == true)
            app.terminate()
        }
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
        // The existing scenario owns recorder overhead on the same warmed
        // device and chat. Keep the physical session alive through both modes.
        let compare = app.buttons["scenario-compare"]
        XCTAssertTrue(compare.waitForExistence(timeout: 5))
        compare.tap()
        let compared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "Recording comparison saved:"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [compared], timeout: 240), .completed)
        XCTAssertEqual(app.state, .runningForeground)
        retainMenuScreenshot(app, name: "Physical recording comparison completed")
    }
    func testLiveActivityAndScrolling() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-fixtures"]
        app.launch()

        // Keep this performance check independent of whatever live chat happens
        // to be selected on the simulator. The fixture uses the production
        // activity renderers with deterministic turn status,
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
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
