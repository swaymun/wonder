import XCTest

@MainActor final class WorkspacePreviewUITests: XCTestCase {
    private var appBundleIdentifier: String {
        #if WONDER_TESTING
        "com.swaymun.wonder.testing"
        #else
        "com.swaymun.wonder"
        #endif
    }

    private func launchProjectFiles(revision: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview",
                               "-project-files-conversation-preview", "-workspace-document-preview"]
        if revision { app.launchArguments.append("-artifact-revision-preview") }
        app.launch()
        XCTAssertTrue(app.buttons["conversation-files-pill"].waitForExistence(timeout: 10))
        return app
    }

    private func open(_ name: String, in app: XCUIApplication) {
        app.buttons["conversation-files-pill"].tap()
        let list = app.descendants(matching: .any)["workspace-file-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "Files should replace the conversation")
        let file = app.buttons["workspace-file-entry:\(name)"]
        let composerTop = app.buttons["computer-status-pill"].frame.minY
        let visibleTop = list.frame.minY + 8
        let visibleBottom = min(list.frame.maxY, composerTop) - 8
        func nudge(_ up: Bool) {
            let start = list.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: list.frame.width / 2,
                                     dy: (up ? visibleBottom - 24 : visibleTop + 24) - list.frame.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: up ? -110 : 110))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        for _ in 0..<15 {
            if file.exists { break }
            nudge(true)
        }
        XCTAssertTrue(file.waitForExistence(timeout: 5), "Missing \(name) in Files")
        for _ in 0..<10 {
            if file.isHittable && file.frame.minY >= visibleTop && file.frame.maxY <= visibleBottom { break }
            nudge(file.frame.maxY > visibleBottom)
        }
        XCTAssertTrue(file.isHittable, "\(name) must be reachable on this device")
        XCTAssertGreaterThanOrEqual(file.frame.minY, visibleTop)
        XCTAssertLessThanOrEqual(file.frame.maxY, visibleBottom,
                                 "\(name) must be visible above the composer before tapping")
        file.tap()
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    func testEPUBNavigationTextSizeAndRetainedChapter() {
        continueAfterFailure = false
        let app = launchProjectFiles()
        open("workspace-reader.epub", in: app)
        let content = app.descendants(matching: .any)["workspace-epub-content"]
        XCTAssertTrue(content.waitForExistence(timeout: 15), "The authenticated EPUB should render")
        XCTAssertTrue(app.buttons["workspace-epub-chapters"].waitForExistence(timeout: 5))
        app.buttons["workspace-epub-chapters"].tap()
        let chapter = app.buttons["Chapter 2"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        chapter.tap()
        let secondPage = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "second page remains here")).firstMatch
        XCTAssertTrue(secondPage.waitForExistence(timeout: 10), "Chapter navigation should reveal the second page")
        let textSize = app.buttons["workspace-epub-text-size"]
        if textSize.label == "Normal Text" { textSize.tap() }
        XCTAssertEqual(textSize.label, "Large Text")
        textSize.tap()
        XCTAssertTrue(app.buttons["Normal Text"].waitForExistence(timeout: 5))
        capture(app, name: "EPUB chapter and large text")
        app.buttons["workspace-preview-expand"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-collapse"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "workspace-epub-content").count, 1,
                       "Full screen must not mount a second EPUB navigator")
        XCTAssertEqual(app.buttons["workspace-epub-text-size"].label, "Normal Text",
                       "Full screen should retain the selected text size")
        app.buttons["workspace-preview-collapse"].tap()
        XCTAssertTrue(secondPage.waitForExistence(timeout: 10), "Collapse should restore Chapter 2")
        XCTAssertEqual(app.buttons["workspace-epub-text-size"].label, "Normal Text")
        app.buttons["workspace-preview-back"].tap()
        XCTAssertTrue(app.buttons["workspace-file-entry:workspace-reader.epub"].waitForExistence(timeout: 5))
        app.terminate()

        let reopened = launchProjectFiles()
        open("workspace-reader.epub", in: reopened)
        XCTAssertTrue(reopened.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "second page remains here"))
            .firstMatch.waitForExistence(timeout: 10), "The same revision should reopen at Chapter 2")
        XCTAssertEqual(reopened.buttons["workspace-epub-text-size"].label, "Normal Text")
        capture(reopened, name: "EPUB retained chapter")
        reopened.buttons["workspace-epub-text-size"].tap()
        reopened.buttons["workspace-preview-back"].tap()
    }

    func testSingleFileModelsAndUnsupportedInputs() {
        continueAfterFailure = false
        let app = launchProjectFiles()
        for name in ["triangle.usdz", "triangle.obj", "triangle.ply", "triangle-binary.stl"] {
            open(name, in: app)
            let scene = app.descendants(matching: .any)["workspace-model-scene"]
            XCTAssertTrue(scene.waitForExistence(timeout: 12), "\(name) should show 3D geometry")
            XCTAssertTrue(scene.isHittable)
            capture(app, name: "Model initial \(name)")
            scene.swipeLeft()
            capture(app, name: "Model \(name)")
            app.buttons["workspace-preview-back"].tap()
            XCTAssertTrue(app.buttons["workspace-file-entry:\(name)"].waitForExistence(timeout: 5))
            app.buttons["workspace-close"].tap()
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                    object: app.buttons["workspace-close"])
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
            XCTAssertTrue(app.buttons["conversation-files-pill"].waitForExistence(timeout: 5))
        }
        for name in ["triangle-ascii.stl", "sidecar.obj"] {
            open(name, in: app)
            XCTAssertTrue(app.descendants(matching: .any)["workspace-model-error"]
                .waitForExistence(timeout: 10), "\(name) should explain its unsupported input")
            capture(app, name: "Unsupported model \(name)")
            app.buttons["workspace-preview-back"].tap()
            app.buttons["workspace-close"].tap()
        }
    }

    func testTetraModelRotationAndZoomControls() {
        continueAfterFailure = false
        let app = launchProjectFiles()
        open("tetra.obj", in: app)
        let scene = app.descendants(matching: .any)["workspace-model-scene"]
        XCTAssertTrue(scene.waitForExistence(timeout: 12))
        XCTAssertTrue(scene.isHittable)
        capture(app, name: "Tetra before rotation")
        for identifier in ["workspace-model-rotate-left", "workspace-model-rotate-right",
                           "workspace-model-zoom-in", "workspace-model-zoom-out"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.exists, "Missing \(identifier)")
            XCTAssertTrue(control.isHittable, "\(identifier) must be reachable")
        }
        app.buttons["workspace-model-rotate-left"].tap()
        capture(app, name: "Tetra rotated left")
        app.buttons["workspace-model-zoom-in"].tap()
        capture(app, name: "Tetra zoomed in")
        app.buttons["workspace-model-rotate-right"].tap()
        app.buttons["workspace-model-zoom-out"].tap()
        capture(app, name: "Tetra controls restored")
        XCTAssertTrue(scene.isHittable)
        app.buttons["workspace-preview-expand"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-collapse"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "workspace-model-scene").count, 1,
                       "Full screen must not mount a second 3D scene")
        app.buttons["workspace-preview-collapse"].tap()
        XCTAssertTrue(scene.waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["workspace-model-zoom-in"].isHittable)
    }

    func testEPUBRevisionOpensAcceptedBook() {
        continueAfterFailure = false
        let app = launchProjectFiles(revision: true)
        open("workspace-reader.epub", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["workspace-epub-content"]
            .waitForExistence(timeout: 15))
        app.buttons["workspace-binary-refresh"].tap()
        let show = app.buttons["workspace-binary-show-revision"]
        XCTAssertTrue(show.waitForExistence(timeout: 10))
        app.buttons["workspace-preview-expand"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-collapse"].waitForExistence(timeout: 5))
        XCTAssertTrue(show.exists, "The offered EPUB should survive full screen")
        app.buttons["workspace-preview-collapse"].tap()
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        show.tap()
        XCTAssertTrue(app.descendants(matching: .any)["workspace-epub-content"]
            .waitForExistence(timeout: 15), "Accepted EPUB bytes should reopen")
        app.buttons["workspace-epub-chapters"].tap()
        let chapter = app.buttons["Chapter 2"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        chapter.tap()
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Revised chapter is here"))
            .firstMatch.waitForExistence(timeout: 10), "The reader must show the accepted bytes")
        capture(app, name: "Accepted EPUB revision")
    }

    func testModelRevisionReopensFromUnsupportedSource() {
        continueAfterFailure = false
        let app = launchProjectFiles(revision: true)
        open("sidecar.obj", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["workspace-model-error"]
            .waitForExistence(timeout: 10))
        app.buttons["workspace-binary-refresh"].tap()
        let show = app.buttons["workspace-binary-show-revision"]
        XCTAssertTrue(show.waitForExistence(timeout: 10))
        show.tap()
        let scene = app.descendants(matching: .any)["workspace-model-scene"]
        XCTAssertTrue(scene.waitForExistence(timeout: 12), "Accepted OBJ should replace the unsupported source")
        XCTAssertTrue(scene.isHittable)
        capture(app, name: "Accepted OBJ revision")
    }
}
