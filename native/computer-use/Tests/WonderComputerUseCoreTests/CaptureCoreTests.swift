import XCTest
@testable import WonderComputerUseCore

final class CaptureCoreTests: XCTestCase {
    func testSelectionPlanOffersThePickerBeforeTheMainDisplay() {
        let plan = CaptureSourceSelectionPlanner.plan(
            requestedSourceID: nil,
            displayIDs: [1, 2],
            sourceIDs: ["display:1", "display:2", "window:9"],
            mainDisplayID: 2,
            pickerAvailable: true
        )

        XCTAssertEqual(plan, .presentSharingPicker)
    }

    func testSelectionPlanDoesNotChooseAnUnrelatedWindowWhenTheMainDisplayIsMissing() {
        let plan = CaptureSourceSelectionPlanner.plan(
            requestedSourceID: nil,
            displayIDs: [1],
            sourceIDs: ["display:1", "window:9"],
            mainDisplayID: 2,
            pickerAvailable: true
        )

        XCTAssertEqual(plan, .presentSharingPicker)
    }

    func testSelectionPlanUsesTheMainDisplayWhenThePickerIsUnavailable() {
        let plan = CaptureSourceSelectionPlanner.plan(
            requestedSourceID: nil,
            displayIDs: [1, 2],
            sourceIDs: ["display:1", "display:2", "window:9"],
            mainDisplayID: 2,
            pickerAvailable: false
        )

        XCTAssertEqual(plan, .select(sourceID: "display:2"))
    }

    func testSelectionPlanHonorsAnExplicitWindow() {
        let plan = CaptureSourceSelectionPlanner.plan(
            requestedSourceID: "window:9",
            displayIDs: [1],
            sourceIDs: ["display:1", "window:9"],
            mainDisplayID: 1,
            pickerAvailable: true
        )

        XCTAssertEqual(plan, .select(sourceID: "window:9"))
    }

    func testSelectionPlanRejectsAnExplicitSourceThatWasNotEnumerated() {
        let plan = CaptureSourceSelectionPlanner.plan(
            requestedSourceID: "window:9",
            displayIDs: [1],
            sourceIDs: ["display:1"],
            mainDisplayID: 1,
            pickerAvailable: true
        )

        XCTAssertEqual(plan, .unavailable(reason: "source_not_found"))
    }

    func testLifecycleRequiresPermissionAndThenUsesExplicitPickerPendingState() {
        var machine = CaptureStateMachine(helperInstanceID: "helper", pickerAvailable: true)

        let denied = machine.prepare(sessionID: "session", generation: 1, viewerCount: 1, screenRecordingAuthorized: false)
        XCTAssertEqual(denied.state, .permissionDenied)
        XCTAssertEqual(denied.message, "Allow Screen Recording for Wonder on your Mac")
        XCTAssertEqual(denied.reason, "screen_recording_permission_required")

        XCTAssertEqual(machine.beginPickerSelection().state, .permissionDenied)
        let authorized = machine.updateScreenRecordingAuthorization(true)
        XCTAssertTrue(authorized.screenRecordingAuthorized)
        let pending = machine.beginPickerSelection()
        XCTAssertEqual(pending.state, .awaitingSource)
        XCTAssertEqual(pending.message, "Choose what to share on your Mac")

        let source = CaptureSourceDescriptor(
            id: "display:1",
            kind: .display,
            title: "Display 1",
            width: 3_840,
            height: 2_160,
            scale: 2,
            contentRect: CaptureRect(x: 0, y: 0, width: 1_920, height: 1_080)
        )
        XCTAssertEqual(machine.selectSource(source).state, .ready)
        XCTAssertEqual(machine.requestStart().state, .starting)
        XCTAssertEqual(machine.captureStarted().state, .capturing)
        XCTAssertEqual(machine.pause().state, .paused)
        XCTAssertEqual(machine.resume().state, .starting)
        XCTAssertEqual(machine.captureStarted().state, .capturing)
        XCTAssertEqual(machine.suspended().state, .suspended)
        XCTAssertEqual(machine.resumedFromSuspension().state, .capturing)
        XCTAssertEqual(machine.setViewerCount(0).state, .stopped)
        XCTAssertEqual(machine.status.reason, "no_authorized_viewers")
    }

    func testNoAuthorizedViewerStopsAReadySessionBeforeCaptureStarts() {
        var machine = CaptureStateMachine()
        _ = machine.prepare(sessionID: "session", generation: 1, viewerCount: 1, screenRecordingAuthorized: true)
        XCTAssertEqual(machine.setViewerCount(0).state, .stopped)
        XCTAssertEqual(machine.status.reason, "no_authorized_viewers")
    }

    func testPermissionRevocationStopsTruthfullyAndCannotSelectASource() {
        var machine = CaptureStateMachine(pickerAvailable: true)
        _ = machine.prepare(sessionID: "session", generation: 1, viewerCount: 1, screenRecordingAuthorized: true)
        let revoked = machine.updateScreenRecordingAuthorization(false)
        XCTAssertEqual(revoked.state, .permissionDenied)
        XCTAssertFalse(revoked.screenRecordingAuthorized)
        XCTAssertEqual(revoked.message, "Allow Screen Recording for Wonder on your Mac")

        let source = CaptureSourceDescriptor(
            id: "display:1",
            kind: .display,
            title: "Display 1",
            width: 1_280,
            height: 720,
            scale: 2,
            contentRect: .zero
        )
        XCTAssertEqual(machine.selectSource(source).state, .permissionDenied)
        XCTAssertEqual(machine.beginPickerSelection().state, .permissionDenied)
    }

    func testStaleSelectionCannotMutateANewerPreparedSession() {
        var machine = CaptureStateMachine()
        _ = machine.prepare(sessionID: "old", generation: 1, viewerCount: 1, screenRecordingAuthorized: true)
        _ = machine.prepare(sessionID: "new", generation: 2, viewerCount: 1, screenRecordingAuthorized: true)
        let source = CaptureSourceDescriptor(
            id: "display:1",
            kind: .display,
            title: "Display 1",
            width: 1_280,
            height: 720,
            scale: 1,
            contentRect: .zero
        )

        let unchanged = machine.selectSource(source, sessionID: "old", generation: 1)

        XCTAssertEqual(unchanged.state, .awaitingSource)
        XCTAssertEqual(unchanged.sessionID, "new")
        XCTAssertNil(unchanged.sourceID)
    }

    func testRestartInvalidatesIdentityAndStopIsIdempotent() {
        var machine = CaptureStateMachine(helperInstanceID: "helper")
        _ = machine.prepare(sessionID: "session", generation: 5, viewerCount: 1, screenRecordingAuthorized: true)
        let restarted = machine.helperRestarted()
        XCTAssertEqual(restarted.state, .helperRestarted)
        XCTAssertNil(restarted.sessionID)
        XCTAssertEqual(restarted.generation, 6)

        let stopped = machine.stop()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertEqual(stopped.queuedFrameCount, 0)
        XCTAssertEqual(machine.stop(), stopped)
    }

    func testLatestFrameQueueDropsSupersededFramesAndNeverExceedsBound() {
        let queue = LatestFrameQueue<Int>(capacity: 2)
        XCTAssertFalse(queue.offer(1))
        XCTAssertFalse(queue.offer(2))
        XCTAssertTrue(queue.offer(3))
        XCTAssertEqual(queue.statistics(), .init(count: 2, droppedCount: 1))
        XCTAssertEqual(queue.takeLatest(), 3)
        XCTAssertNil(queue.takeLatest())
        XCTAssertEqual(queue.statistics().droppedCount, 1)
        queue.reset()
        XCTAssertEqual(queue.statistics(), .init(count: 0, droppedCount: 0))
    }

    func testFrameMetadataIsBoundedAndCarriesGeometryAndIdentity() {
        let source = CaptureSourceDescriptor(
            id: "window:7",
            kind: .window,
            title: "Fixture",
            width: 1_920,
            height: 1_080,
            scale: 2,
            contentRect: CaptureRect(x: 10, y: 20, width: 960, height: 540)
        )
        let metadata = CaptureFrameMetadata.make(
            timestamp: .infinity,
            sourceWidth: 1_280,
            sourceHeight: 720,
            source: source,
            geometryRevision: 4,
            frameSequence: 9,
            sessionID: "session",
            generation: 3
        )
        XCTAssertTrue(metadata.captureTimestamp.isFinite)
        XCTAssertEqual(metadata.geometryRevision, 4)
        XCTAssertEqual(metadata.sourceWidth, 1_280)
        XCTAssertEqual(metadata.cropRect.width, 1_280)
        XCTAssertEqual(metadata.cropRect.height, 720)
        XCTAssertEqual(metadata.frameSequence, 9)
        XCTAssertEqual(metadata.sessionID, "session")
        XCTAssertEqual(metadata.generation, 3)
    }

    func testDefaultConfigurationIs720p15WithoutAudioAndClampedQueue() {
        let configuration = CaptureConfiguration(width: 4_000, height: 3_000, framesPerSecond: 120, audioEnabled: true, queueDepth: 100)
        XCTAssertEqual(configuration.width, 1_280)
        XCTAssertEqual(configuration.height, 720)
        XCTAssertEqual(configuration.framesPerSecond, 15)
        XCTAssertFalse(configuration.audioEnabled)
        XCTAssertEqual(configuration.queueDepth, 2)
    }

    func testCaptureConfigurationCentersSourceWithoutChangingEncodedDimensions() {
        let cases: [(Double, Double, CaptureRect)] = [
            (1_920, 1_080, CaptureRect(x: 0, y: 0, width: 1_280, height: 720)),
            (1_440, 900, CaptureRect(x: 64, y: 0, width: 1_152, height: 720)),
            (1_024, 768, CaptureRect(x: 160, y: 0, width: 960, height: 720)),
            (900, 1_600, CaptureRect(x: 437.5, y: 0, width: 405, height: 720)),
            (3_840, 1_080, CaptureRect(x: 0, y: 180, width: 1_280, height: 360)),
        ]
        for (width, height, expected) in cases {
            let source = CaptureSourceDescriptor(
                id: "display:1", kind: .display, title: "Fixture",
                width: Int(width * 2), height: Int(height * 2), scale: 2,
                contentRect: CaptureRect(x: -1_920, y: 100, width: width, height: height)
            )
            // Inspect the actual ScreenCaptureKit configuration, not only the
            // geometry helper. No screen recording or permission is required.
            let configuration = ScreenCaptureSession.makeStreamConfiguration(CaptureConfiguration(), source: source)
            XCTAssertEqual(configuration.width, 1_280)
            XCTAssertEqual(configuration.height, 720)
            XCTAssertEqual(configuration.destinationRect.origin.x, expected.x, accuracy: 0.001)
            XCTAssertEqual(configuration.destinationRect.origin.y, expected.y, accuracy: 0.001)
            XCTAssertEqual(configuration.destinationRect.width, expected.width, accuracy: 0.001)
            XCTAssertEqual(configuration.destinationRect.height, expected.height, accuracy: 0.001)
            XCTAssertTrue(configuration.scalesToFit)
            if #available(macOS 14.0, *) {
                XCTAssertTrue(configuration.preservesAspectRatio)
            }
        }
    }

    func testCaptureDestinationUsesLogicalBoundsAndFallsBackForMissingGeometry() {
        let logicalSource = CaptureSourceDescriptor(
            id: "display:1", kind: .display, title: "Fixture",
            width: 1_280, height: 720, scale: 2,
            contentRect: CaptureRect(x: 40, y: -200, width: 1_440, height: 900)
        )
        let configuration = CaptureConfiguration(width: 640, height: 360)
        XCTAssertEqual(configuration.centeredDestinationRect(for: logicalSource),
                       CaptureRect(x: 32, y: 0, width: 576, height: 360))

        let fallbackSource = CaptureSourceDescriptor(
            id: "window:7", kind: .window, title: "Fixture",
            width: 1_024, height: 768, scale: 1, contentRect: .zero
        )
        XCTAssertEqual(configuration.centeredDestinationRect(for: fallbackSource),
                       CaptureRect(x: 80, y: 0, width: 480, height: 360))

        let invalidSource = CaptureSourceDescriptor(
            id: "picker-selection", kind: .picker, title: "Fixture",
            width: 0, height: 0, scale: 1,
            contentRect: CaptureRect(x: 0, y: 0, width: .infinity, height: .nan)
        )
        XCTAssertEqual(configuration.centeredDestinationRect(for: invalidSource),
                       CaptureRect(x: 0, y: 0, width: 640, height: 360))
    }
}
