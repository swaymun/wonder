import XCTest

@MainActor final class AutomationUITests: XCTestCase {
    private var appBundleIdentifier: String {
        #if WONDER_TESTING
        "com.swaymun.wonder.testing"
        #else
        "com.swaymun.wonder"
        #endif
    }

    func testExistingBotAndGroupSchedulesPauseAndResume() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-automations-fixture", "-diagnostics-automations-patch-fails"]
        app.launch()

        let bot = app.descendants(matching: .any)["automation-row:fixture-bot-schedule"]
        let group = app.descendants(matching: .any)["automation-row:fixture-group-schedule"]
        XCTAssertTrue(bot.waitForExistence(timeout: 15))
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        XCTAssertTrue(bot.staticTexts["Bot · Research Bot"].exists)
        XCTAssertTrue(group.staticTexts["Group Chat · Launch Team"].exists)
        XCTAssertTrue(bot.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Next: ")).firstMatch.exists)
        XCTAssertTrue(bot.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Last: ")).firstMatch.exists)
        XCTAssertTrue(app.buttons["project-automation-new"].exists)

        let toggle = app.buttons["automation-toggle:fixture-bot-schedule"]
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(toggle.label, "Pause")
        toggle.tap()
        XCTAssertTrue(app.staticTexts["automation-change-failure:fixture-bot-schedule"].waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.label, "Pause", "A failed owner API mutation must not change the visible status")
        toggle.tap()
        let resume = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Resume"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [resume], timeout: 10), .completed)
        XCTAssertFalse(app.staticTexts["automation-change-failure:fixture-bot-schedule"].exists)
        app.buttons["automations-refresh"].tap()
        XCTAssertEqual(toggle.label, "Resume", "A fresh host list must retain the server-confirmed pause")
        toggle.tap()
        let pause = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pause"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [pause], timeout: 10), .completed)
    }

    func testAutomationListFailureCanRetry() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-automations-fixture", "-diagnostics-automations-list-fails"]
        app.launch()
        XCTAssertTrue(app.staticTexts["automations-failure"].waitForExistence(timeout: 15))
        let retry = app.buttons["automations-retry"]
        XCTAssertTrue(retry.isHittable)
        retry.tap()
        XCTAssertTrue(app.descendants(matching: .any)["automation-row:fixture-bot-schedule"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["automations-failure"].exists)
    }

    func testProjectScheduleCreatesAndEditsAttachedThread() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-automations-fixture"]
        app.launch()

        let create = app.buttons["project-automation-new"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        XCTAssertTrue(create.isHittable)
        create.tap()
        let thread = app.buttons["project-automation-thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 15))
        let name = app.descendants(matching: .any)["project-automation-name"]
        let prompt = app.descendants(matching: .any)["project-automation-prompt"]
        XCTAssertTrue(name.isHittable)
        name.tap(); name.typeText("Daily launch review")
        prompt.tap(); prompt.typeText("Review the launch plan.")
        let save = app.buttons["project-automation-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let row = app.descendants(matching: .any)["automation-row:fixture-project-schedule"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.staticTexts["Daily launch review"].exists)
        XCTAssertTrue(row.staticTexts["Roadmap · Plan launch"].exists)

        let edit = app.buttons["automation-edit:fixture-project-schedule"]
        XCTAssertTrue(edit.isHittable)
        edit.tap()
        let task = app.descendants(matching: .any)["project-automation-prompt"]
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.tap()
        task.typeText(" Check the risks.")
        save.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["automation-change-failure:fixture-project-schedule"].exists)
        app.buttons["automations-refresh"].tap()
        XCTAssertTrue(row.staticTexts["Daily launch review"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["automations-failure"].exists)
        edit.tap()
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        XCTAssertTrue((task.value as? String)?.contains("Check the risks.") == true)
    }

    func testSwitchingProjectsDuringThreadLoadShowsLatestThreads() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-automations-fixture", "-diagnostics-automations-switch-project"]
        app.launch()
        let create = app.buttons["project-automation-new"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        create.tap()
        let project = app.buttons["project-automation-project"]
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        let zephyr = app.buttons["Zephyr"]
        XCTAssertTrue(zephyr.waitForExistence(timeout: 5))
        zephyr.tap()
        XCTAssertTrue(project.label.contains("Zephyr"),
                      "Project picker did not select Zephyr: \(project.label)")
        let thread = app.buttons["project-automation-thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            thread.label.contains("Check Zephyr")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed,
                       "Thread picker stayed at \(thread.label)\n\(app.debugDescription)")
        let delayedResponse = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in false }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [delayedResponse], timeout: 4), .timedOut)
        XCTAssertFalse(app.staticTexts["Loading threads…"].exists)
        XCTAssertTrue(thread.label.contains("Check Zephyr"),
                      "The old Project response must not replace the selected Project's threads")
    }

    func testProjectTargetStaysFixedWhileCreateIsSaving() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-automations-fixture", "-diagnostics-automations-slow-create"]
        app.launch()
        XCTAssertTrue(app.buttons["project-automation-new"].waitForExistence(timeout: 15))
        app.buttons["project-automation-new"].tap()
        let project = app.buttons["project-automation-project"]
        let thread = app.buttons["project-automation-thread"]
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        XCTAssertTrue(project.label.contains("Roadmap"))
        let name = app.descendants(matching: .any)["project-automation-name"]
        let prompt = app.descendants(matching: .any)["project-automation-prompt"]
        name.tap(); name.typeText("Daily launch review")
        prompt.tap(); prompt.typeText("Review the launch plan.")
        app.buttons["project-automation-save"].tap()
        XCTAssertFalse(project.isEnabled, "The Project target must stay fixed until the request settles")
        XCTAssertFalse(thread.isEnabled)
        XCTAssertFalse(prompt.isEnabled)
        let row = app.descendants(matching: .any)["automation-row:fixture-project-schedule"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.staticTexts["Roadmap · Plan launch"].exists)
        XCTAssertTrue(row.staticTexts["Daily launch review"].exists)
    }

    func testUncertainCreateWithEditedDraftRequiresNewRequest() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-automations-fixture", "-diagnostics-automations-create-lost-response"]
        app.launch()
        let create = app.buttons["project-automation-new"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        create.tap()
        XCTAssertTrue(app.buttons["project-automation-thread"].waitForExistence(timeout: 15))
        let name = app.descendants(matching: .any)["project-automation-name"]
        let prompt = app.descendants(matching: .any)["project-automation-prompt"]
        name.tap(); name.typeText("Daily review")
        prompt.tap(); prompt.typeText("Review the plan.")
        let save = app.buttons["project-automation-save"]
        save.tap()
        let failure = app.staticTexts["project-automation-save-failure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        prompt.tap(); prompt.typeText(" Include risks.")
        save.tap()
        XCTAssertTrue(app.buttons["project-automation-new-request"].waitForExistence(timeout: 10))
        XCTAssertTrue((prompt.value as? String)?.contains("Include risks.") == true)
        app.buttons["project-automation-new-request"].tap()
        XCTAssertFalse(failure.exists)
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue((prompt.value as? String)?.contains("Include risks.") == true)
    }

    func testProjectEditFailureKeepsFormForRetry() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-automations-fixture", "-diagnostics-automations-existing-project",
                               "-diagnostics-automations-project-save-fails"]
        app.launch()
        let row = app.descendants(matching: .any)["automation-row:fixture-project-schedule"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(row.staticTexts["Roadmap · Plan launch"].exists)
        app.buttons["automation-edit:fixture-project-schedule"].tap()
        let prompt = app.descendants(matching: .any)["project-automation-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["automation-change-failure:fixture-project-schedule"].exists)
        prompt.tap(); prompt.typeText(" Check the blockers.")
        let save = app.buttons["project-automation-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let failure = app.staticTexts["project-automation-save-failure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertTrue(save.isHittable)
        save.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["automation-change-failure:fixture-project-schedule"].exists)
        XCTAssertFalse(app.staticTexts["project-automation-save-failure"].exists)
        app.buttons["automations-refresh"].tap()
        XCTAssertTrue(row.staticTexts["Project check-in"].waitForExistence(timeout: 10))
        app.buttons["automation-edit:fixture-project-schedule"].tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        XCTAssertTrue((prompt.value as? String)?.contains("Check the blockers.") == true)
    }

    func testRevisionConflictKeepsAutomationEditsVisible() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-diagnostics-automations-fixture", "-diagnostics-automations-existing-project",
                               "-diagnostics-automations-revision-conflict"]
        app.launch()

        let bot = app.buttons["automation-toggle:fixture-bot-schedule"]
        XCTAssertTrue(bot.waitForExistence(timeout: 15))
        XCTAssertEqual(bot.label, "Pause")
        bot.tap()
        let toggleFailure = app.staticTexts["automation-change-failure:fixture-bot-schedule"]
        XCTAssertTrue(toggleFailure.waitForExistence(timeout: 10))
        XCTAssertTrue(toggleFailure.label.contains("Refresh and try again"))
        XCTAssertEqual(bot.label, "Pause", "A stale toggle must retain the server-confirmed status")

        let edit = app.buttons["automation-edit:fixture-project-schedule"]
        XCTAssertTrue(edit.isHittable)
        edit.tap()
        let prompt = app.descendants(matching: .any)["project-automation-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.tap(); prompt.typeText(" Check the current plan.")
        app.buttons["project-automation-save"].tap()
        let editFailure = app.staticTexts["project-automation-save-failure"]
        XCTAssertTrue(editFailure.waitForExistence(timeout: 10))
        XCTAssertTrue(editFailure.label.contains("Reload the latest version"))
        XCTAssertTrue((prompt.value as? String)?.contains("Check the current plan.") == true,
                      "A stale edit must remain visible so the user can recover it")
        let reload = app.buttons["project-automation-reload"]
        XCTAssertTrue(reload.isHittable)
        reload.tap()
        XCTAssertFalse(editFailure.waitForExistence(timeout: 3))
        let row = app.descendants(matching: .any)["automation-row:fixture-project-schedule"]
        XCTAssertTrue(row.staticTexts["Project updated on Mac"].waitForExistence(timeout: 10))
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        XCTAssertEqual(prompt.value as? String, "Updated on Mac.",
                       "Reload should show the latest server version before another edit")
    }
}
