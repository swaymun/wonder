import XCTest

@MainActor final class WorkspacePreviewUITests: XCTestCase {
    private var appBundleIdentifier: String {
        #if WONDER_TESTING
        "com.swaymun.wonder.testing"
        #else
        "com.swaymun.wonder"
        #endif
    }

    private func launchProjectFiles() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchArguments = ["-read-preview", "-send-preview", "-files-preview",
                               "-project-files-conversation-preview", "-workspace-document-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["conversation-files-pill"].waitForExistence(timeout: 10))
        return app
    }

    private func open(_ name: String, in app: XCUIApplication) {
        app.buttons["conversation-files-pill"].tap()
        let file = app.buttons["workspace-file-entry:\(name)"]
        for _ in 0..<10 where !file.isHittable { app.swipeUp() }
        XCTAssertTrue(file.waitForExistence(timeout: 5), "Missing \(name) in Files")
        XCTAssertTrue(file.isHittable, "\(name) must be reachable on this device")
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
        app.buttons["workspace-epub-text-size"].tap()
        XCTAssertTrue(app.buttons["Normal Text"].waitForExistence(timeout: 5))
        capture(app, name: "EPUB chapter and large text")
        app.buttons["workspace-preview-expand"].tap()
        XCTAssertTrue(app.buttons["workspace-preview-collapse"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "workspace-epub-content").count, 1,
                       "Full screen must not mount a second EPUB navigator")
        app.buttons["workspace-preview-collapse"].tap()
        XCTAssertTrue(secondPage.waitForExistence(timeout: 10), "Collapse should restore Chapter 2")
        app.buttons["workspace-preview-back"].tap()
        XCTAssertTrue(app.buttons["workspace-file-entry:workspace-reader.epub"].waitForExistence(timeout: 5))
        app.terminate()

        let reopened = launchProjectFiles()
        open("workspace-reader.epub", in: reopened)
        XCTAssertTrue(reopened.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "second page remains here"))
            .firstMatch.waitForExistence(timeout: 10), "The same revision should reopen at Chapter 2")
        capture(reopened, name: "EPUB retained chapter")
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
}
