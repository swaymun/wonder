import XCTest

@MainActor final class DeepLinkUITests: XCTestCase {
    private var bundleID: String {
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
        let tree = XCTAttachment(string: XCUIApplication(bundleIdentifier: bundleID).debugDescription)
        tree.name = "Failure hierarchy"; tree.lifetime = .keepAlways
        issue.add(tree)
        super.record(issue)
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }

    private var scheme: String {
        #if WONDER_TESTING
        "wonder-testing"
        #else
        "wonder"
        #endif
    }

    private func launch(_ path: String, extras: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = ["-connections-preview", "-diagnostics-deep-link", "\(scheme)://v1\(path)"] + extras
        app.launch()
        return app
    }

    func testExactProjectLinkOpensDraftOnItsMac() {
        continueAfterFailure = false
        let app = launch("/hosts/macbook/projects/preview-project/new", extras: ["-project-files-preview"])
        let picker = app.buttons["connection-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        XCTAssertEqual(picker.value as? String, "Laptop, Connected")
        let project = app.buttons["destination-picker"]
        XCTAssertTrue(project.exists)
        XCTAssertEqual(project.value as? String, "Preview project")
        keep(app, "Project link opens New Chat on its Mac")
        XCTAssertTrue(app.textViews["new-chat-draft"].exists)
    }

    func testExactConversationLinkOpensProjectThread() {
        continueAfterFailure = false
        let app = launch("/hosts/studio/chats/preview", extras: ["-project-files-preview", "-project-files-conversation-preview"])
        XCTAssertTrue(app.buttons["conversation-title-menu"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.textViews["message-draft"].exists)
        XCTAssertFalse(app.buttons["destination-picker"].exists)
    }

    func testSystemURLLaunchOpensExactConversation() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = ["-connections-preview", "-project-files-preview", "-project-files-conversation-preview"]
        app.open(URL(string: "\(scheme)://v1/hosts/studio/chats/preview")!)
        XCTAssertTrue(app.buttons["conversation-title-menu"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.textViews["message-draft"].exists)
    }

    func testMissingProjectDoesNotSelectAnotherProject() {
        continueAfterFailure = false
        let app = launch("/hosts/studio/projects/removed/new", extras: ["-project-files-preview"])
        XCTAssertTrue(app.staticTexts["Project unavailable"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["destination-picker"].exists)
        XCTAssertTrue(app.buttons["Choose a project"].exists)
    }

    func testUnpairedAndMalformedLinksGiveRecovery() {
        continueAfterFailure = false
        let unpaired = launch("/hosts/unpaired/projects/preview-project/new")
        XCTAssertTrue(unpaired.alerts["Couldn’t open link"].waitForExistence(timeout: 10))
        XCTAssertTrue(unpaired.staticTexts["The linked computer is not paired on this device. Pair that computer to open it."].exists)
        unpaired.terminate()

        let malformed = launch("/hosts/studio/chats/%2Fsecret")
        XCTAssertTrue(malformed.alerts["Couldn’t open link"].waitForExistence(timeout: 10))
        XCTAssertTrue(malformed.staticTexts["This link is invalid or belongs to another Wonder app. Ask for a new link."].exists)
    }

    func testOfflineConversationShowsRetryInsteadOfSpinner() {
        continueAfterFailure = false
        let app = launch("/hosts/studio/chats/unknown", extras: ["-diagnostics-deep-link-offline"])
        XCTAssertTrue(app.staticTexts["Computer offline"].waitForExistence(timeout: 15))
        keep(app, "Offline link offers retry")
        XCTAssertTrue(app.buttons["Try again"].exists)
        XCTAssertFalse(app.progressIndicators["conversation-loading"].exists)
    }

    /// A widget tap while the Mac is still reconnecting opens the draft at once.
    func testOfflineCachedProjectLinkOpensDraftWithoutRecoveryScreen() {
        continueAfterFailure = false
        let app = launch("/hosts/studio/projects/preview-project/new",
                         extras: ["-project-files-preview", "-diagnostics-deep-link-offline"])
        let project = app.buttons["destination-picker"]
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        XCTAssertEqual(project.value as? String, "Preview project")
        XCTAssertTrue(app.textViews["new-chat-draft"].exists)
        XCTAssertFalse(app.staticTexts["Computer offline"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["linked-project-recovery"].exists)
        keep(app, "Project link opens New Chat while the Mac reconnects")
    }
}
