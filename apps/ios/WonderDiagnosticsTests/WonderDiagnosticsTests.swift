import XCTest
import CryptoKit
import UIKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import Vision
import PDFKit
import WonderPairing
@testable import Wonder

final class WonderDiagnosticsTests: XCTestCase {
    @MainActor func testWorkspaceRevisionCoalescesRapidSequencesDuringSlowRead() async throws {
        actor Counter {
            private var value = 0
            func next() -> Int { value += 1; return value }
            func count() -> Int { value }
        }
        actor ReadGate {
            private var opened = false
            private var waiter: CheckedContinuation<Void, Never>?
            func wait() async {
                if opened { return }
                await withCheckedContinuation { waiter = $0 }
            }
            func open() {
                opened = true
                waiter?.resume()
                waiter = nil
            }
        }
        let original = Data("old".utf8)
        let updated = Data("new".utf8)
        let revision = WorkspaceRevisionState(data: original, sha256: ConversationFile.digest(original))
        revision.observedPoint = WorkspaceObservationPoint(hostEpoch: "epoch-1", sequence: 1)
        let reads = Counter()
        let notices = Counter()
        let gate = ReadGate()
        let firstStarted = expectation(description: "First revision read started")
        let newestStarted = expectation(description: "Newest revision read started")
        let refresh: () async throws -> Data = {
            if await reads.next() == 1 {
                firstStarted.fulfill()
                await gate.wait()
                try Task.checkCancellation()
                return original
            }
            newestStarted.fulfill()
            return updated
        }
        let onRevision: (String) async -> Void = { _ in _ = await notices.next() }
        await revision.observe(point: WorkspaceObservationPoint(hostEpoch: "epoch-1", sequence: 2),
                               refresh: refresh, onRevision: onRevision, failureMessage: "Read failed")
        await fulfillment(of: [firstStarted], timeout: 2)
        XCTAssertTrue(revision.refreshing)
        for sequence in 3...40 {
            await revision.observe(point: WorkspaceObservationPoint(hostEpoch: "epoch-1", sequence: UInt64(sequence)), refresh: refresh,
                                   onRevision: onRevision, failureMessage: "Read failed")
        }
        let readsDuringStream = await reads.count()
        XCTAssertEqual(readsDuringStream, 1, "Streaming updates should not restart an in-flight download")
        await gate.open()
        await fulfillment(of: [newestStarted], timeout: 3)
        for _ in 0..<100 where revision.observedPoint?.sequence != 40 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(revision.observedPoint, WorkspaceObservationPoint(hostEpoch: "epoch-1", sequence: 40))
        let finalReads = await reads.count()
        XCTAssertEqual(finalReads, 2, "Only the latest pending sequence needs another read")
        XCTAssertEqual(revision.offeredData, updated)
        XCTAssertEqual(revision.offeredSha256, ConversationFile.digest(updated))
        let firstNotices = await notices.count()
        XCTAssertEqual(firstNotices, 2)

        await revision.observe(point: WorkspaceObservationPoint(hostEpoch: "epoch-1", sequence: 41),
                               refresh: { updated }, onRevision: onRevision,
                               failureMessage: "Read failed")
        for _ in 0..<100 where revision.observedPoint?.sequence != 41 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let finalNotices = await notices.count()
        XCTAssertEqual(finalNotices, 3, "A new draft note needs stale reconciliation even for the same offered bytes")

        await revision.observe(point: WorkspaceObservationPoint(hostEpoch: "epoch-2", sequence: 0),
                               refresh: { updated }, onRevision: onRevision, failureMessage: "Read failed")
        for _ in 0..<100 where revision.observedPoint?.hostEpoch != "epoch-2" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(revision.observedPoint, WorkspaceObservationPoint(hostEpoch: "epoch-2", sequence: 0),
                       "A restarted host with a lower sequence must still check the selected file")

        let sustainedReads = Counter()
        for sequence in 1...12 {
            await revision.observe(point: WorkspaceObservationPoint(hostEpoch: "epoch-2", sequence: UInt64(sequence)),
                                   refresh: { _ = await sustainedReads.next(); return updated },
                                   onRevision: onRevision, failureMessage: "Read failed")
            try await Task.sleep(for: .milliseconds(100))
        }
        for _ in 0..<200 where revision.observedPoint?.sequence != 12 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(revision.observedPoint, WorkspaceObservationPoint(hostEpoch: "epoch-2", sequence: 12))
        let sampledReads = await sustainedReads.count()
        XCTAssertLessThanOrEqual(sampledReads, 3, "Sustained chat updates should bound full-file reads")

        let revertedNotice = expectation(description: "Reverted source reconciles draft notes")
        await revision.observe(point: WorkspaceObservationPoint(hostEpoch: "epoch-2", sequence: 13),
                               refresh: { original }, onRevision: { sha256 in
                                   if sha256 == ConversationFile.digest(original) { revertedNotice.fulfill() }
                               }, failureMessage: "Read failed")
        await fulfillment(of: [revertedNotice], timeout: 2)
        XCTAssertNil(revision.offeredData, "A byte-for-byte revert should clear the pending revision offer")
        revision.close()

        let cancelledEpochGate = ReadGate()
        let guardedEpoch = WorkspaceRevisionState(data: original, sha256: ConversationFile.digest(original))
        guardedEpoch.observedPoint = WorkspaceObservationPoint(hostEpoch: "epoch-1", sequence: 10)
        let lateOldEpoch = Task {
            await cancelledEpochGate.wait()
            await guardedEpoch.observe(point: WorkspaceObservationPoint(hostEpoch: "epoch-1", sequence: 11),
                                       refresh: { original }, onRevision: nil, failureMessage: "Read failed")
        }
        lateOldEpoch.cancel()
        await guardedEpoch.observe(point: WorkspaceObservationPoint(hostEpoch: "epoch-2", sequence: 0),
                                   refresh: { updated }, onRevision: nil, failureMessage: "Read failed")
        await cancelledEpochGate.open()
        await lateOldEpoch.value
        for _ in 0..<100 where guardedEpoch.observedPoint?.hostEpoch != "epoch-2" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(guardedEpoch.observedPoint, WorkspaceObservationPoint(hostEpoch: "epoch-2", sequence: 0),
                       "A cancelled observation from the old epoch must not replace the restart check")
        guardedEpoch.close()

        let openedBeforeSnapshot = WorkspaceRevisionState(data: original, sha256: ConversationFile.digest(original))
        openedBeforeSnapshot.observedPoint = WorkspaceObservationPoint(hostEpoch: "", sequence: 0)
        let firstSnapshotRead = expectation(description: "First snapshot after file open is checked")
        await openedBeforeSnapshot.observe(point: WorkspaceObservationPoint(hostEpoch: "epoch-3", sequence: 1),
                                           refresh: { firstSnapshotRead.fulfill(); return updated },
                                           onRevision: nil, failureMessage: "Read failed")
        await fulfillment(of: [firstSnapshotRead], timeout: 2)
        openedBeforeSnapshot.close()

        let largeSource = Data(repeating: 65, count: 512 * 1024)
        let largeRevision = WorkspaceRevisionState(data: largeSource, sha256: ConversationFile.digest(largeSource))
        largeRevision.observedPoint = WorkspaceObservationPoint(hostEpoch: "large-file", sequence: 1)
        let largeReads = Counter()
        let largeRefresh: () async throws -> Data = { _ = await largeReads.next(); return largeSource }
        await largeRevision.observe(point: WorkspaceObservationPoint(hostEpoch: "large-file", sequence: 2),
                                    refresh: largeRefresh, onRevision: nil, failureMessage: "Read failed")
        for _ in 0..<100 where largeRevision.observedPoint?.sequence != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstLargeReadCount = await largeReads.count()
        XCTAssertEqual(firstLargeReadCount, 1)
        await largeRevision.observe(point: WorkspaceObservationPoint(hostEpoch: "large-file", sequence: 3),
                                    refresh: largeRefresh, onRevision: nil, failureMessage: "Read failed")
        try await Task.sleep(for: .milliseconds(1_250))
        let automaticLargeReadCount = await largeReads.count()
        XCTAssertEqual(automaticLargeReadCount, 1,
                       "A large unchanged file must not download once per second during a stream")
        let manualLargeRead = await largeRevision.checkManuallyForRevision(refresh: largeRefresh, onRevision: nil,
                                                                         failureMessage: "Read failed")
        XCTAssertTrue(manualLargeRead,
                      "Manual refresh remains available between passive checks")
        let finalLargeReadCount = await largeReads.count()
        XCTAssertEqual(finalLargeReadCount, 2)
        try await Task.sleep(for: .milliseconds(1_000))
        let coalescedLargeReadCount = await largeReads.count()
        XCTAssertEqual(coalescedLargeReadCount, 2,
                       "Manual refresh should satisfy the queued automatic check")
        largeRevision.close()

        let failedManualRevision = WorkspaceRevisionState(data: largeSource, sha256: ConversationFile.digest(largeSource))
        failedManualRevision.observedPoint = WorkspaceObservationPoint(hostEpoch: "failed-manual", sequence: 1)
        await failedManualRevision.observe(point: WorkspaceObservationPoint(hostEpoch: "failed-manual", sequence: 2),
                                           refresh: { largeSource }, onRevision: nil, failureMessage: "Read failed")
        for _ in 0..<100 where failedManualRevision.observedPoint?.sequence != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let automaticAfterFailure = expectation(description: "Automatic check retries after failed manual read")
        await failedManualRevision.observe(point: WorkspaceObservationPoint(hostEpoch: "failed-manual", sequence: 3),
                                           refresh: { automaticAfterFailure.fulfill(); return largeSource },
                                           onRevision: nil, failureMessage: "Read failed")
        try await Task.sleep(for: .milliseconds(900))
        let handledFailure = await failedManualRevision.checkManuallyForRevision(
            refresh: { throw URLError(.timedOut) }, onRevision: nil, failureMessage: "Read failed")
        XCTAssertTrue(handledFailure)
        XCTAssertEqual(failedManualRevision.observedPoint?.sequence, 2,
                       "A failed manual read must not consume the queued event")
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(failedManualRevision.observedPoint?.sequence, 2,
                       "A manual failure must delay the queued automatic retry")
        await fulfillment(of: [automaticAfterFailure], timeout: 4)
        for _ in 0..<100 where failedManualRevision.observedPoint?.sequence != 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(failedManualRevision.observedPoint?.sequence, 3)
        failedManualRevision.close()

        let failedAutomaticRevision = WorkspaceRevisionState(data: original, sha256: ConversationFile.digest(original))
        failedAutomaticRevision.observedPoint = WorkspaceObservationPoint(hostEpoch: "failed-automatic", sequence: 1)
        let automaticReads = Counter()
        let slowFailure = expectation(description: "Slow automatic read times out")
        let automaticRetry = expectation(description: "Failed automatic check retries without a new chat event")
        await failedAutomaticRevision.observe(
            point: WorkspaceObservationPoint(hostEpoch: "failed-automatic", sequence: 2),
            refresh: {
                if await automaticReads.next() == 1 {
                    try await Task.sleep(for: .milliseconds(2_100))
                    slowFailure.fulfill()
                    throw URLError(.timedOut)
                }
                automaticRetry.fulfill()
                return updated
            }, onRevision: nil, failureMessage: "Read failed")
        await fulfillment(of: [slowFailure], timeout: 4)
        for _ in 0..<100 where failedAutomaticRevision.refreshFailure == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(failedAutomaticRevision.observedPoint?.sequence, 1,
                       "A failed automatic read must not consume the pending update")
        let failedAutomaticReads = await automaticReads.count()
        XCTAssertEqual(failedAutomaticReads, 1)
        try await Task.sleep(for: .milliseconds(250))
        let readsBeforeRetry = await automaticReads.count()
        XCTAssertEqual(readsBeforeRetry, 1,
                       "Backoff must start after a slow timeout, not when the read began")
        await fulfillment(of: [automaticRetry], timeout: 4)
        for _ in 0..<100 where failedAutomaticRevision.observedPoint?.sequence != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(failedAutomaticRevision.observedPoint?.sequence, 2)
        XCTAssertEqual(failedAutomaticRevision.offeredData, updated)
        XCTAssertNil(failedAutomaticRevision.refreshFailure)
        failedAutomaticRevision.close()
    }

    @MainActor func testPDFPreviewRetainsPageReadingPointAndZoomAcrossRevision() throws {
        func document(_ label: String) -> Data {
            UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 3000)).pdfData { context in
                for page in 1...2 {
                    context.beginPage()
                    ("\(label) page \(page)" as NSString).draw(at: CGPoint(x: 24, y: 24),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
                }
            }
        }
        func pdfView(in view: UIView) -> PDFView? {
            if let view = view as? PDFView { return view }
            return view.subviews.lazy.compactMap { pdfView(in: $0) }.first
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let session = PDFPreviewSession()
        let host = UIHostingController(rootView: AnyView(PDFPreview(
            data: document("Old"), revision: "old", session: session)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        host.view.layoutIfNeeded()
        let viewer = try XCTUnwrap(pdfView(in: host.view))
        let original = try XCTUnwrap(viewer.document)
        let second = try XCTUnwrap(original.page(at: 1))
        viewer.go(to: second)
        viewer.scaleFactor = min(viewer.maxScaleFactor, max(viewer.minScaleFactor, viewer.scaleFactor * 1.4))
        viewer.go(to: PDFDestination(page: second, at: CGPoint(x: 80, y: 1800)))
        let before = try XCTUnwrap(viewer.currentDestination)
        let scale = viewer.scaleFactor
        XCTAssertEqual(original.index(for: try XCTUnwrap(before.page)), 1)

        let revised = document("Revised")
        host.rootView = AnyView(PDFPreview(data: revised, revision: "revised", session: session))
        host.view.layoutIfNeeded()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            viewer.document !== original && viewer.currentPage.flatMap { viewer.document?.index(for: $0) } == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        let after = try XCTUnwrap(viewer.currentDestination)
        XCTAssertEqual(viewer.document?.index(for: try XCTUnwrap(after.page)), 1)
        XCTAssertEqual(after.point.y, before.point.y, accuracy: 5)
        XCTAssertEqual(viewer.scaleFactor, scale, accuracy: 0.05)

        host.rootView = AnyView(Color.clear)
        host.view.layoutIfNeeded()
        let unmounted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            pdfView(in: host.view) == nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [unmounted], timeout: 5), .completed)
        host.rootView = AnyView(PDFPreview(data: revised, revision: "revised", session: session))
        host.view.layoutIfNeeded()
        let remounted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let next = pdfView(in: host.view) else { return false }
            return next !== viewer && next.currentPage.flatMap { next.document?.index(for: $0) } == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [remounted], timeout: 5), .completed)
        let nextViewer = try XCTUnwrap(pdfView(in: host.view))
        let restored = try XCTUnwrap(nextViewer.currentDestination)
        XCTAssertEqual(nextViewer.document?.index(for: try XCTUnwrap(restored.page)), 1)
        XCTAssertEqual(restored.point.y, after.point.y, accuracy: 5)
        XCTAssertEqual(nextViewer.scaleFactor, scale, accuracy: 0.05)
    }
    // Observe rendered opening frames inside the app process: an external
    // XCTest query waits for idleness and misses the brief wrong-position flash.
    // The existing fixture owns both saved-anchor and unsaved-bottom content.
    @MainActor func testChatOpeningFramesStartAtTheIntendedReadingPosition() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        for savedReply in [6, 12] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let chat = DiagnosticSubagentFixture.parentChat()
            MessageRecoveryURLProtocol.reset()
            let model = recoveryModel(root: root)
            model.chats = [chat]
            model.macConnected = false
            model.snapshots[chat.id] = try JSONDecoder().decode(ConversationSnapshot.self,
                from: JSONSerialization.data(withJSONObject: DiagnosticSubagentFixture.chatLayoutSnapshot()))
            if savedReply == 6 {
                let anchor = try XCTUnwrap(ChatFeedEntry.grouping(model.feedRows(for: chat)).first {
                    $0.rows.contains { $0.text.hasPrefix("Reply 6.") }
                }?.id)
                model.savePosition(anchor, chat: chat.id)
            }
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView:
                NavigationStack { ConversationView(model: model, chat: chat) }
                    .environment(\.dynamicTypeSize, .large))
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previousWindow?.makeKey()
                try? FileManager.default.removeItem(at: root)
            }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
            var frames: [UIImage] = []
            let deadline = Date().addingTimeInterval(1.5)
            repeat {
                frames.append(renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) })
                try await Task.sleep(for: .milliseconds(16))
            } while Date() < deadline
            struct Line: Sendable { let text: String; let bounds: CGRect }
            let images = try frames.map { try XCTUnwrap($0.pngData()) }
            let recognized = try await Task.detached {
                // Recognize identical pixels once; still check every captured
                // frame, including the very first one and any changed position.
                var cache: [Data: [Line]] = [:]
                return try images.map { data in
                    if let lines = cache[data] { return lines }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    try VNImageRequestHandler(data: data).perform([request])
                    let lines = (request.results ?? []).map { Line(text: $0.topCandidates(1).first?.string ?? "", bounds: $0.boundingBox) }
                    cache[data] = lines
                    return lines
                }
            }.value
            var firstY: CGFloat?
            var visibleFrames = 0
            for (index, lines) in recognized.enumerated() {
                let transcript = lines.filter { $0.text.hasPrefix("Reply ") || $0.text.hasPrefix("Question ") }
                guard !transcript.isEmpty else { continue }
                let expected = transcript.first { $0.text.hasPrefix("Reply \(savedReply).") }
                let shifted = expected.map { line in firstY.map { abs(line.bounds.minY - $0) * window.bounds.height > 2 } ?? false } ?? false
                if expected == nil || shifted {
                    let attachment = XCTAttachment(image: frames[index])
                    attachment.name = "Opening frame \(index), intended reply \(savedReply)"
                    attachment.lifetime = .keepAlways; add(attachment)
                }
                XCTAssertNotNil(expected, "Every readable opening frame must contain the intended reply; frame \(index)")
                if let expected {
                    let y = expected.bounds.minY
                    if let firstY { XCTAssertEqual(y * window.bounds.height, firstY * window.bounds.height, accuracy: 2, "The first visible reply must not jump after opening") }
                    else { firstY = y }
                    visibleFrames += 1
                }
            }
            XCTAssertGreaterThan(visibleFrames, 2, "The chat must finish opening, not stay hidden")
            let evidence = XCTAttachment(string: "Intended reply: \(savedReply); captured frames: \(frames.count); readable correct frames: \(visibleFrames)")
            evidence.lifetime = .keepAlways; add(evidence)
        }
    }

    // Asset packaging owns this contract: known connectors must render a real
    // bundled image in both appearances, even with no network or runtime logo URL.
    @MainActor func testConnectedAppAssetsAreAvailableOffline() throws {
        for name in ["Gmail", "Google Calendar", "Google Drive", "Claude Docs", "GitHub", "OpenAI Platform", "Sites", "Linear", "Flashloop", "Adobe Acrobat", "claude.ai Gmail", "Claude.ai: Google Drive"] {
            let data = try JSONSerialization.data(withJSONObject: ["id": name, "name": name, "status": "available"])
            let app = try JSONDecoder().decode(ConnectedApp.self, from: data)
            let asset = try XCTUnwrap(app.bundledIcon)
            for style in [UIUserInterfaceStyle.light, .dark] {
                let image = try XCTUnwrap(UIImage(named: asset, in: .main, compatibleWith: UITraitCollection(userInterfaceStyle: style)))
                XCTAssertGreaterThan(image.size.width, 0)
                XCTAssertGreaterThan(image.size.height, 0)
            }
        }
    }

    func testPushPreviewAuthenticatesContentAndRouting() throws {
        let key = try XCTUnwrap(Data(pushBase64URL: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"))
        var payload: [String: String] = ["eventId": "00000000-0000-4000-8000-000000000003", "preview": "AAECAwQFBgcICQoLPCCicrGJpzm3Y8Xk0I1YGfG_9xQyzH8tTQKW8XQGbpAtMsyTy7gwolbzF4Tr7whcjyBA-jWkyKkAt9qGj3AaVn8eu2CVVyfnz0FMKbT7GBkXrL4", "registrationId": "00000000-0000-4000-8000-000000000001", "routeId": "00000000-0000-4000-8000-000000000002"]
        let decoded = try PushPreview.decrypt(payload, key: key)
        XCTAssertEqual(decoded.title, "Road trip · Question")
        XCTAssertEqual(decoded.body, "Which day works? 🗓️")
        for field in ["registrationId", "routeId", "eventId"] {
            var wrong = payload; wrong[field] = UUID().uuidString.lowercased()
            XCTAssertThrowsError(try PushPreview.decrypt(wrong, key: key))
        }
        XCTAssertThrowsError(try PushPreview.decrypt(payload, key: Data(repeating: 0, count: 32)))
        payload["preview"] = String(repeating: "a", count: 3241)
        XCTAssertThrowsError(try PushPreview.decrypt(payload, key: key))
    }


    @MainActor func testPushSetupStatusAndOwnershipSurvivePersistence() throws {
        let saved = Self.cameraSavedConnection()
        var record = PushRegistration(host: saved.credential.hostInstallationId, device: saved.credential.deviceId, endpoint: "https://push.example.test", key: Data(repeating: 1, count: 32))
        XCTAssertFalse(record.macRegistered)
        XCTAssertTrue(record.belongs(to: saved.credential))
        record.macRegistered = true
        XCTAssertTrue(record.macRegistered)
        record.enabled = false
        let restored = try JSONDecoder().decode(PushRegistration.self, from: JSONEncoder().encode(record))
        XCTAssertFalse(restored.enabled)
        let differentDevice = PushRegistration(host: saved.credential.hostInstallationId, device: "repaired-device", endpoint: record.endpoint, key: record.key)
        XCTAssertFalse(differentDevice.belongs(to: saved.credential))
    }

    @MainActor func testPushPreferenceIsImmediateAndSurvivesOfflineMacAndRestart() async throws {
        MessageRecoveryURLProtocol.reset()
        MessageRecoveryURLProtocol.fail(path: "/api/v1/push/config", error: .notConnectedToInternet)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root), host = Self.cameraSavedConnection().credential.hostInstallationId
        let library = ConnectionLibrary(diagnosticModel: model)
        var values: [String: Data] = [:]
        var attempts = 0
        let push = PushNotifications(read: { values[$0] }, write: { values[$1] = $0 }, authorize: {
            attempts += 1
            return true
        }, registerForPush: { XCTFail("Offline setup must not reach APNs enrollment") })
        push.attach(library)
        push.enable(model)
        XCTAssertTrue(push.isEnabled(host), "The preference changes before any asynchronous work")
        XCTAssertNotNil(values["push-requested-devices-v1"])
        for _ in 0..<100 { if !MessageRecoveryURLProtocol.bodies(path: "/api/v1/push/config", includingEmpty: true).isEmpty { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: "/api/v1/push/config", includingEmpty: true).count, 1)
        XCTAssertTrue(push.isEnabled(host))
        XCTAssertNil(push.settingsAlert, "An offline Mac must not interrupt the user")
        for _ in 0..<100 {
            if case .some(.needsRetry) = push.setupState(host) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .some(.needsRetry) = push.setupState(host) else {
            return XCTFail("An offline setup should offer retry in Settings")
        }
        let restored = PushNotifications(read: { values[$0] }, write: { values[$1] = $0 }, registerForPush: {})
        restored.attach(library)
        XCTAssertTrue(restored.isEnabled(host), "Pending intent survives relaunch without a registration")
        restored.disable(model)
        let off = PushNotifications(read: { values[$0] }, write: { values[$1] = $0 }, registerForPush: {})
        off.attach(library)
        XCTAssertFalse(off.isEnabled(host))
        push.disable(model)
    }

    @MainActor func testPushDeniedPermissionTurnsOffAndOffersSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root), host = Self.cameraSavedConnection().credential.hostInstallationId
        let library = ConnectionLibrary(diagnosticModel: model)
        var values: [String: Data] = [:]
        let push = PushNotifications(read: { values[$0] }, write: { values[$1] = $0 }, authorize: { false }, registerForPush: { XCTFail("Denied permission must not enroll") })
        push.attach(library); push.enable(model)
        XCTAssertTrue(push.isEnabled(host))
        for _ in 0..<100 { if push.settingsAlert != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(push.isEnabled(host))
        XCTAssertEqual(push.settingsAlert?.host, host)
        XCTAssertEqual(push.settingsAlert?.opensSettings, true)
        let saved = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(values["push-requested-devices-v1"]))
        XCTAssertNil(saved[host])
    }

    @MainActor func testPushAPNsFailureIsVisibleAndRetryableWithoutLosingPreference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root), host = Self.cameraSavedConnection().credential.hostInstallationId
        let library = ConnectionLibrary(diagnosticModel: model)
        var values: [String: Data] = [:]
        var registrations = 0
        let push = PushNotifications(read: { values[$0] }, write: { values[$1] = $0 },
                                     authorize: { true }, registerForPush: { registrations += 1 })
        push.attach(library)
        push.enable(model)
        XCTAssertEqual(push.setupState(host), .settingUp)

        push.registrationFailed()
        guard case .some(.needsRetry(let message)) = push.setupState(host) else {
            return XCTFail("APNs failure should offer a retry")
        }
        XCTAssertTrue(message.contains("Apple"))
        XCTAssertTrue(push.isEnabled(host), "An APNs failure must preserve the requested setting")

        let beforeRetry = registrations
        push.retry(host)
        XCTAssertEqual(push.setupState(host), .settingUp)
        XCTAssertEqual(registrations, beforeRetry + 1)
        push.disable(model)
        XCTAssertNil(push.setupState(host))
    }

    @MainActor func testPushChallengeTimeoutIgnoresStaleProof() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root), saved = Self.cameraSavedConnection(), host = saved.credential.hostInstallationId
        let library = ConnectionLibrary(diagnosticModel: model)
        var record = PushRegistration(host: host, device: saved.credential.deviceId,
                                      endpoint: "https://push.example.test", key: Data(repeating: 1, count: 32))
        record.nonce = "current"
        var values = ["push-registrations-v1": try JSONEncoder().encode([host: record])]
        let push = PushNotifications(read: { values[$0] }, write: { values[$1] = $0 },
                                     authorize: { true }, registerForPush: {})
        push.attach(library)
        push.enable(model)
        push.challengeTimedOut(host, nonce: "stale")
        XCTAssertEqual(push.setupState(host), .settingUp)
        push.challengeTimedOut(host, nonce: "current")
        guard case .some(.needsRetry(let message)) = push.setupState(host) else {
            return XCTFail("An unanswered current challenge should offer retry")
        }
        XCTAssertTrue(message.contains("Apple"))
        let pending = try JSONDecoder().decode([String: PushRegistration].self,
                                               from: XCTUnwrap(values["push-registrations-v1"]))
        XCTAssertEqual(pending[host]?.nonce, "current", "A late APNs proof must remain eligible after the warning")
        push.disable(model)
    }

    @MainActor func testPushRestoredRegistrationClearsSetupWhenAPNsTokenArrives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root), saved = Self.cameraSavedConnection(), host = saved.credential.hostInstallationId
        let library = ConnectionLibrary(diagnosticModel: model)
        var record = PushRegistration(host: host, device: saved.credential.deviceId,
                                      endpoint: "https://push.example.test", key: Data(repeating: 1, count: 32))
        record.id = UUID().uuidString
        record.token = "0102"
        record.macRegistered = true
        record.previewVersion = 1
        record.registeredAt = Date()
        var values = ["push-registrations-v1": try JSONEncoder().encode([host: record])]
        let push = PushNotifications(read: { values[$0] }, write: { values[$1] = $0 },
                                     authorize: { true }, registerForPush: {})
        push.attach(library)
        push.enable(model)
        XCTAssertEqual(push.setupState(host), .settingUp)
        push.receivedToken(Data([0x01, 0x02]))
        XCTAssertNil(push.setupState(host), "A confirmed registration must not look stuck after relaunch")
    }

    @MainActor func testPushOffCancelsDelayedPermissionWithoutReenabling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root), host = Self.cameraSavedConnection().credential.hostInstallationId
        let library = ConnectionLibrary(diagnosticModel: model)
        var values: [String: Data] = [:]
        var permission: CheckedContinuation<Bool, Error>?
        let push = PushNotifications(read: { values[$0] }, write: { values[$1] = $0 }, authorize: {
            try await withCheckedThrowingContinuation { permission = $0 }
        }, registerForPush: { XCTFail("A cancelled preference must never enroll") })
        push.attach(library); push.enable(model)
        for _ in 0..<100 { if permission != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        let pending = try XCTUnwrap(permission)
        push.disable(model)
        pending.resume(returning: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(push.isEnabled(host))
        XCTAssertNil(push.settingsAlert)
        XCTAssertNil(values["push-registrations-v1"])
    }

    @MainActor func testPushPreferenceWriteFailureDoesNotPretendItSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root), host = Self.cameraSavedConnection().credential.hostInstallationId
        let library = ConnectionLibrary(diagnosticModel: model)
        let push = PushNotifications(read: { _ in nil }, write: { _, _ in throw CocoaError(.fileWriteNoPermission) }, authorize: { XCTFail("An unsaved preference must not enroll"); return true }, registerForPush: {})
        push.attach(library); push.enable(model)
        XCTAssertFalse(push.isEnabled(host))
        XCTAssertEqual(push.settingsAlert?.title, "Couldn't change notifications")
    }

    @MainActor func testPushPreferenceMigrationPreservesOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root), saved = Self.cameraSavedConnection()
        let library = ConnectionLibrary(diagnosticModel: model)
        let record = PushRegistration(host: saved.credential.hostInstallationId, device: saved.credential.deviceId, endpoint: "https://push.example.test", key: Data(repeating: 1, count: 32))
        let data = try JSONEncoder().encode([record.host: record])
        let migrated = PushNotifications(read: { $0 == "push-registrations-v1" ? data : nil }, write: { _, _ in }, registerForPush: {})
        migrated.attach(library)
        XCTAssertTrue(migrated.isEnabled(record.host))
        let wrongDevice = try JSONEncoder().encode([record.host: "old-device"])
        let repaired = PushNotifications(read: { $0 == "push-requested-devices-v1" ? wrongDevice : nil }, write: { _, _ in }, registerForPush: {})
        repaired.attach(library)
        XCTAssertFalse(repaired.isEnabled(record.host))
    }

    func testPushRetryBacksOffAndStaysBounded() {
        var retry = PushRetry()
        let now = Date(timeIntervalSince1970: 1000)
        for delay: TimeInterval in [15, 30, 60, 120, 240, 300, 300, 300] {
            retry.postpone(now: now)
            XCTAssertEqual(retry.nextAttempt.timeIntervalSince(now), delay)
        }
        XCTAssertEqual(retry.failures, 6)
        XCTAssertLessThan(PushRetry().nextAttempt, now)
    }

    /// Launch must show saved chats from the on-device cache without waiting
    /// for the Mac, and an unreachable Mac must not blank or revoke them.
    @MainActor func testSavedChatsLoadWithoutTheMacAndStayMarkedUnverified() async throws {
        MessageRecoveryURLProtocol.reset()
        let saved = Self.cameraSavedConnection()
        let store = ReadStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wonder/Hosts"),
                              host: saved.credential.hostInstallationId, device: saved.storageDeviceId)
        defer { try? store.remove() }
        var previous = ProjectionState()
        previous.install(try JSONDecoder().decode(ConversationSnapshot.self, from: Data(#"{"conversationId":"saved-chat","hostEpoch":"epoch","lastSequence":7,"messages":[{"messageId":"m","body":"Saved question","state":"completed","createdAt":"1700000000000","attachmentIds":[]}],"assistantMessages":[],"thread":{"hydrated":true}}"#.utf8)))
        previous.summaries = [try Self.cameraChat(id: "saved-chat")]
        try store.save(previous)
        MessageRecoveryURLProtocol.fail(path: "/api/v1/pairing/session/refresh-challenge", error: .notConnectedToInternet)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MessageRecoveryURLProtocol.self]
        let model = ConnectionModel(saved: saved, persistConnection: { _ in }, api: PairingAPI(configuration: configuration))
        XCTAssertTrue(model.chats.isEmpty)
        await model.check(renew: true)
        XCTAssertEqual(model.chats.map(\.id), ["saved-chat"])
        XCTAssertEqual(model.snapshots["saved-chat"]?.messages.first?.body, "Saved question")
        XCTAssertEqual(model.macConnected, false)
        XCTAssertFalse(model.accessEnded, "An unreachable Mac is not revoked access")
        XCTAssertTrue(model.cachedConversationIds.contains("saved-chat"), "Saved content stays marked unverified")
        XCTAssertTrue(model.loadingConversationIDs.isEmpty)
        XCTAssertNil(model.conversationLoadFailures["saved-chat"])
    }

    private func managedBot(_ id: String, avatar: String, archived: Bool = false) throws -> ManagedBot {
        let json = """
        {"id":"\(id)","name":"\(id)","role":"Test","systemPrompt":"","workspacePath":"/Bots/\(id)","permissionProfile":"bot-\(id)","permissionMode":"workspace","approvalMode":"ask-for-approval","model":"model","reasoningEffort":"medium","serviceTier":"default","isArchived":\(archived),"conversationId":"chat-\(id)","avatarColor":"#ffb51c","avatarShape":"sun","avatarPalette":"\(avatar)","workingDirectory":"/Workspace"}
        """
        return try JSONDecoder().decode(ManagedBot.self, from: Data(json.utf8))
    }

    func testManagedBotMutationAppliesAuthoritativeBotImmediately() throws {
        let old = try managedBot("ada", avatar: "amber")
        let saved = try managedBot("ada", avatar: "ocean")
        var state = ManagedBotListMutationState()

        let result = state.confirm(saved, current: [old])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.avatarPalette, "ocean")
    }

    func testManagedBotMutationProtectsConfirmedBotFromPreMutationRefresh() throws {
        let old = try managedBot("ada", avatar: "amber")
        let saved = try managedBot("ada", avatar: "ocean")
        var state = ManagedBotListMutationState()
        let snapshot = state.revision
        _ = state.confirm(saved, current: [old])

        let result = state.reconcile([old], startedAt: snapshot)

        XCTAssertEqual(result.first?.avatarPalette, "ocean")
    }

    func testManagedBotMutationAllowsPostMutationRefreshToReconcile() throws {
        let saved = try managedBot("ada", avatar: "ocean")
        let server = try managedBot("ada", avatar: "violet")
        var state = ManagedBotListMutationState()
        _ = state.confirm(saved, current: [])
        let snapshot = state.revision

        let result = state.reconcile([server], startedAt: snapshot)

        XCTAssertEqual(result.first?.avatarPalette, "violet")
        XCTAssertEqual(state.reconcile([saved], startedAt: snapshot).first?.avatarPalette, "ocean")
    }

    func testManagedBotMutationLeavesUnrelatedBotsFromRefreshUntouched() throws {
        let oldAda = try managedBot("ada", avatar: "amber")
        let savedAda = try managedBot("ada", avatar: "ocean")
        let refreshedLin = try managedBot("lin", avatar: "rose")
        var state = ManagedBotListMutationState()
        let snapshot = state.revision
        _ = state.confirm(savedAda, current: [oldAda])

        let result = state.reconcile([oldAda, refreshedLin], startedAt: snapshot)

        XCTAssertEqual(result.map(\.id), ["ada", "lin"])
        XCTAssertEqual(result.first?.avatarPalette, "ocean")
        XCTAssertEqual(result.last?.avatarPalette, "rose")
    }

    func testUsageGatePreservesModelScopeResetUnknownAndOverage() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        func entry(_ json: String, age: TimeInterval = 0) throws -> CodexUsageCacheEntry {
            CodexUsageCacheEntry(response: try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8)), fetchedAt: now.addingTimeInterval(-age))
        }
        let json = #"{"agentFamily":"claude","checkedAtMs":2000000,"windows":[{"id":"seven_day_opus","label":"Weekly","usedPercent":100,"remainingPercent":0,"resetsAt":3000}]}"#
        let cached = try entry(json)
        XCTAssertNotNil(cached.exhaustedWindow(model: "claude:claude-opus-5-5", now: now))
        XCTAssertNil(cached.exhaustedWindow(model: "claude:claude-sonnet-5-5", now: now))
        XCTAssertNil(cached.exhaustedWindow(model: "claude:haiku", now: now))
        XCTAssertNil(cached.exhaustedWindow(model: "claude:opus", now: Date(timeIntervalSince1970: 3000)))
        XCTAssertNil(try entry(json, age: 300).exhaustedWindow(model: "claude:opus", now: now))
        XCTAssertNil(try entry(json.replacingOccurrences(of: #""usedPercent":100,"remainingPercent":0"#, with: #""usedPercent":99.9,"remainingPercent":0.1"#)).exhaustedWindow(model: "claude:opus", now: now))
        XCTAssertNil(try entry(json.replacingOccurrences(of: #""checkedAtMs":2000000"#, with: #""checkedAtMs":2000000,"additionalUsageAvailable":true"#)).exhaustedWindow(model: "claude:opus", now: now))
        XCTAssertNil(try entry(#"{"checkedAtMs":2000000,"windows":[]}"#).exhaustedWindow(model: "", now: now))
    }

    @MainActor func testExhaustedUsagePreflightPreservesDraftAndNeverSends() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat) = try recoveryGroup(root: root)
        model.editDraft("Keep this message", chat: chat.id)
        let family = AgentFamily(model: model.usageModel(chat))
        let usage = try JSONSerialization.data(withJSONObject: ["agentFamily": family.rawValue, "checkedAtMs": 1,
            "windows": [["id": "primary", "label": "5 hours", "usedPercent": 100, "remainingPercent": 0]], "additionalUsageAvailable": false])
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/account/usage", body: usage)
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/bot-options", body: try recoveryOptions())
        XCTAssertTrue(model.canSend(chat), "Missing usage is unknown, not exhausted")
        await model.send(chat)
        XCTAssertFalse(model.canSend(chat))
        XCTAssertNotNil(model.usageLimitMessage(chat))
        XCTAssertEqual(model.composers[chat.id]?.draft, "Keep this message")
        XCTAssertNil(model.composers[chat.id]?.pending)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/group-chats/group/messages").isEmpty)
        let other = CodexUsageCacheEntry(response: try JSONDecoder().decode(CodexUsageResponse.self, from: usage), fetchedAt: Date())
        model.codexUsageCache = [:]; model.claudeUsageCache = [:]
        if family == .codex { model.claudeUsageCache[model.assignmentScope] = other }
        else { model.codexUsageCache[model.assignmentScope] = other }
        XCTAssertTrue(model.canSend(chat), "Another provider's limit must not block this model")
    }

    func testCodexUsageResponseDecodesTheHostContract() throws {
        let data = Data(#"{"checkedAtMs":1700000000000,"windows":[{"id":"five-hours","label":"5 hours","usedPercent":27,"remainingPercent":73,"windowDurationMins":300,"resetsAt":1700018000000},{"id":"weekly","label":"Weekly","usedPercent":41,"remainingPercent":59,"windowDurationMins":10080,"resetsAt":1700604800000}]}"#.utf8)
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        XCTAssertEqual(response.windows.map(\.label), ["5 hours", "Weekly"])
        XCTAssertEqual(response.windows.map(\.roundedRemainingPercent), [73, 59])
        XCTAssertEqual(response.windows[0].windowDurationMins, 300)
    }

    func testVisibleChatProjectionExcludesArchivedBotDirectChatsAndRestoresThem() throws {
        func summary(_ id: String, botID: String?) throws -> ChatSummary {
            let botValue = botID.map { "\"\($0)\"" } ?? "null"
            let json = """
            {"conversationId":"\(id)","botId":\(botValue),"title":"\(id)","lastMessagePreview":null,"lastMessageAt":null,"messageCount":0,"deliveryState":null,"hasUnread":false,"isArchived":false,"isPinned":false}
            """
            return try JSONDecoder().decode(ChatSummary.self, from: Data(json.utf8))
        }

        let remote = try [
            summary("archived-direct", botID: "archived-bot"),
            summary("active-direct", botID: "active-bot"),
            summary("botless-summary", botID: nil),
            summary("shared-group", botID: nil)
        ]
        let group = try JSONDecoder().decode(
            GroupRead.self,
            from: Data(#"{"id":"group-1","conversationId":"shared-group","name":"Shared","isArchived":false,"messages":[]}"#.utf8))

        let active = projectVisibleChatSummaries(remote: remote, groups: [group], activeBotIDs: ["active-bot"])
        XCTAssertEqual(active.map(\.id), ["active-direct", "botless-summary", "shared-group"])
        XCTAssertFalse(active.contains { $0.id == "archived-direct" })

        let restored = projectVisibleChatSummaries(
            remote: remote,
            groups: [group],
            activeBotIDs: ["active-bot", "archived-bot"])
        XCTAssertEqual(restored.map(\.id), ["archived-direct", "active-direct", "botless-summary", "shared-group"])
    }

    @MainActor func testScienceAvatarRenderedCatalog() throws {
        for scheme in [ColorScheme.light, .dark] {
            let gallery = HStack(alignment: .top, spacing: 16) {
                ForEach(ScienceAvatarCatalog.shapes) { shape in
                    VStack(spacing: 12) {
                        ScienceAvatar(shape: shape.rawValue, palette: "violet", size: 160)
                        Text(shape.title).font(.headline)
                        HStack(spacing: 12) {
                            ScienceAvatar(shape: shape.rawValue, palette: "violet", size: 32)
                            ScienceAvatar(shape: shape.rawValue, palette: "violet", size: 48)
                        }
                        ScienceAvatarGroup(shape: shape, palette: .resolve("violet"), size: 28)
                    }
                }
            }
            .padding(24)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: gallery)
            renderer.scale = 2
            let rendered = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThan(rendered.size.width, 1000)
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "Native SVG geometry - \(scheme) - Violet 160 32 48 and agents 28"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor func testScienceAvatarGeometryFitsSmallAndLargeSizesInLightAndDark() {
        for colorScheme in [ColorScheme.light, .dark] {
            for shape in ScienceAvatarCatalog.shapes {
                for size in [CGFloat(32), 48, 96] {
                    let view = ScienceAvatar(shape: shape.rawValue, palette: ScienceAvatarCatalog.defaultPalette, size: size)
                        .environment(\.colorScheme, colorScheme)
                    let host = UIHostingController(rootView: view)
                    host.loadViewIfNeeded()
                    let measured = host.sizeThatFits(in: CGSize(width: size, height: size))
                    XCTAssertLessThanOrEqual(measured.width, size + 0.5, "\(shape.title) exceeds \(size)pt in \(colorScheme)")
                    XCTAssertLessThanOrEqual(measured.height, size + 0.5, "\(shape.title) exceeds \(size)pt in \(colorScheme)")
                }
            }
        }
    }

    @MainActor func testScienceAvatarFallbacksAndMotionSemanticsAreDeterministic() {
        XCTAssertEqual(ScienceAvatarPresentation.shape(rawValue: nil, identity: "fixture-bot"), ScienceAvatarCatalog.stableShape(for: "fixture-bot"))
        XCTAssertEqual(ScienceAvatarPresentation.palette(rawValue: nil, legacyColor: "#3864A0").id, "ocean")
        XCTAssertEqual(ScienceAvatarPresentation.palette(rawValue: "not-a-palette", legacyColor: nil).id, ScienceAvatarCatalog.defaultPalette)
        XCTAssertEqual(ScienceAvatar.motionMode(for: .done, animate: true, reduceMotion: false), .finite)
        XCTAssertEqual(ScienceAvatar.motionMode(for: .working, animate: true, reduceMotion: false), .looping)
        XCTAssertEqual(ScienceAvatar.motionMode(for: .working, animate: true, reduceMotion: true), .static)
        XCTAssertEqual(ScienceAvatar.doneMotionDuration, 0.8, accuracy: 0.001)
        for state in ScienceAvatarMotionState.allCases {
            XCTAssertEqual(ScienceAvatar.motionTransform(for: state, active: true, reduceMotion: true, phase: true), .zero)
        }
        XCTAssertNotEqual(ScienceAvatar.motionTransform(for: .working, active: true, reduceMotion: false, phase: true), .zero)
    }

    func testScienceAvatarHeaderMotionReducerRequiresAnObservedActiveTurn() {
        var reducer = ScienceAvatarHeaderMotionReducer()
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.state, .idle)
        XCTAssertEqual(reducer.output.doneTrigger, 0)

        reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.state, .working)
        XCTAssertTrue(reducer.output.animate)
        XCTAssertEqual(reducer.output.doneTrigger, 0)

        reducer.reduce(
            activeTurnID: "turn-active",
            trackedTurnStatus: .inProgress,
            isPresented: true,
            reduceMotion: false,
            activeState: .thinking
        )
        XCTAssertEqual(reducer.output.state, .thinking)
    }

    func testScienceAvatarHeaderMotionReducerBouncesOnceForSuccessfulCompletion() {
        var reducer = ScienceAvatarHeaderMotionReducer()
        reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: true, reduceMotion: false)
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.state, .idle)
        XCTAssertEqual(reducer.output.doneTrigger, 1)

        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.doneTrigger, 1, "A replayed terminal snapshot must not replay the bounce")
    }

    func testScienceAvatarHeaderMotionReducerDoesNotBounceForFailedOrStoppedWork() {
        for status in [ScienceAvatarObservedTurnStatus.failed, .interrupted] {
            var reducer = ScienceAvatarHeaderMotionReducer()
            reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: true, reduceMotion: false)
            reducer.reduce(activeTurnID: nil, trackedTurnStatus: status, isPresented: true, reduceMotion: false)
            XCTAssertEqual(reducer.output.state, .idle)
            XCTAssertEqual(reducer.output.doneTrigger, 0)
        }
    }

    func testScienceAvatarHeaderMotionReducerDeduplicatesAReplayedTurnID() {
        var reducer = ScienceAvatarHeaderMotionReducer()
        reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: true, reduceMotion: false)
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.doneTrigger, 1)

        reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: true, reduceMotion: false)
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.doneTrigger, 1)
    }

    func testScienceAvatarHeaderMotionReducerDoesNotInferCompletionAcrossReconnect() {
        var reducer = ScienceAvatarHeaderMotionReducer()
        reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: true, reduceMotion: false)
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .unknown, isPresented: true, reduceMotion: false)
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.doneTrigger, 0)
    }

    func testScienceAvatarHeaderMotionReducerSuppressesMotionForReduceMotion() {
        var reducer = ScienceAvatarHeaderMotionReducer()
        reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: true, reduceMotion: true)
        XCTAssertEqual(reducer.output.state, .working)
        XCTAssertFalse(reducer.output.animate)
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: true)
        XCTAssertEqual(reducer.output.doneTrigger, 0)
    }

    func testScienceAvatarHeaderMotionReducerDefersDoneBounceWhileInactive() {
        var reducer = ScienceAvatarHeaderMotionReducer()
        reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: false, reduceMotion: false)
        XCTAssertFalse(reducer.output.animate)
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: false, reduceMotion: false)
        XCTAssertEqual(reducer.output.doneTrigger, 0)

        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.doneTrigger, 1)
    }

    func testScienceAvatarHeaderMotionReducerDefersDoneBounceWhileCovered() {
        var reducer = ScienceAvatarHeaderMotionReducer()
        reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: false, reduceMotion: false)
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: false, reduceMotion: false)
        XCTAssertEqual(reducer.output.doneTrigger, 0)
        XCTAssertFalse(reducer.output.animate)

        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.doneTrigger, 1)
    }

    @MainActor func testImageCanvasKeepsItsHeightWhileLoadingAndOnFailure() {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for size in [CGSize(width: 600, height: 200), CGSize(width: 200, height: 600)] {
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in }
            for width in [280.0, 360.0] {
                for canvas in [ToolImageCanvas(image: nil, failed: false), ToolImageCanvas(image: image, failed: false), ToolImageCanvas(image: nil, failed: true)] {
                    let host = UIHostingController(rootView: canvas)
                    let measured = host.sizeThatFits(in: CGSize(width: width, height: 1000))
                    XCTAssertEqual(measured.height, 220, accuracy: 0.1)
                    XCTAssertEqual(measured.width, width, accuracy: 0.1)
                }
            }
        }
    }

    @MainActor func testThumbnailsDeduplicateCacheAndInvalidateRevisions() async throws {
        let data = Self.imageData()
        let probe = ImageLoadProbe(data: data)
        let cache = ToolImagePreviews()
        let scope = UUID()
        let original = try Self.imageRequest(scope: scope, data: data)
        async let first = cache.image(for: original) { try await probe.load() }
        async let second = cache.image(for: original) { try await probe.load() }
        let (a, b) = try await (first, second)
        XCTAssertTrue(a === b)
        _ = try await cache.image(for: original) { try await probe.load() }
        let initialCalls = await probe.calls; XCTAssertEqual(initialCalls, 1)

        for request in [try Self.imageRequest(scope: scope, data: data, revision: "changed"),
                        try Self.imageRequest(scope: UUID(), data: data)] {
            _ = try await cache.image(for: request) { try await probe.load() }
        }
        let removed = try Self.imageRequest(scope: scope, data: data, state: "removed")
        do {
            _ = try await cache.image(for: removed) {
                _ = try await probe.load()
                throw FileFailure.integrity
            }
            XCTFail("A removed file reused its old thumbnail")
        } catch FileFailure.integrity { }
        let revisedCalls = await probe.calls; XCTAssertEqual(revisedCalls, 4)
        cache.invalidate(); XCTAssertEqual(cache.cachedBytes, 0)
        _ = try await cache.image(for: original) { try await probe.load() }
        let reloadedCalls = await probe.calls; XCTAssertEqual(reloadedCalls, 5)
    }

    @MainActor func testThumbnailWorkIsBoundedAndCancelledConsumersDoNotReload() async throws {
        let data = Self.imageData()
        let probe = ImageLoadProbe(data: data, delay: .milliseconds(200))
        let cache = ToolImagePreviews(maximumBytes: 250_000)
        let scope = UUID()
        let requests = try (0..<8).map { try Self.imageRequest(scope: scope, data: data, revision: String($0)) }
        var tasks = requests.prefix(2).map { key in Task { try await cache.image(for: key) { try await probe.load() } } }
        while await probe.calls < 2 { await Task.yield() }
        tasks += requests.dropFirst(2).map { key in Task { try await cache.image(for: key) { try await probe.load() } } }
        // This request is queued behind the two active workers.
        tasks[7].cancel()
        for (index, task) in tasks.enumerated() {
            do { _ = try await task.value; XCTAssertNotEqual(index, 7) }
            catch is CancellationError { XCTAssertEqual(index, 7) }
        }
        let maximum = await probe.maximumActive; XCTAssertEqual(maximum, 2)
        let calls = await probe.calls; XCTAssertEqual(calls, 7)
        XCTAssertLessThanOrEqual(cache.cachedBytes, 250_000)
        // An evicted image must be loaded again, without retaining all history.
        _ = try await cache.image(for: requests[0]) { try await probe.load() }
        let afterEviction = await probe.calls; XCTAssertEqual(afterEviction, 8)

        let pending = Task { try await cache.image(for: requests[7]) { try await probe.load() } }
        while await probe.calls < 9 { await Task.yield() }
        cache.invalidate()
        do { _ = try await pending.value; XCTFail("Invalidated work returned a stale image") }
        catch is CancellationError { }
        XCTAssertEqual(cache.cachedBytes, 0)
        _ = try await cache.image(for: requests[7]) { try await probe.load() }
        let afterCancellation = await probe.calls; XCTAssertEqual(afterCancellation, 10)
        XCTAssertLessThanOrEqual(cache.cachedBytes, 250_000)
    }

    @MainActor private static func imageData() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240), format: format).pngData { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
        }
    }
    private static func imageRequest(scope: UUID, data: Data, revision: String = "original", state: String = "available") throws -> ToolImageRequest {
        let value: [String: Any] = ["id": "image", "name": "image.png", "mimeType": "image/png", "byteSize": data.count, "sha256": ConversationFile.digest(data), "state": state, "updatedAt": revision]
        let file = try JSONDecoder().decode(ConversationFile.self, from: JSONSerialization.data(withJSONObject: value))
        return ToolImageRequest(scope: scope, chatID: "chat", file: file)
    }
    @MainActor func testPresentedRowsInvalidateWhenLiveSourceChanges() throws {
        func group(_ text: String) throws -> GroupRead {
            let value:[String:Any] = ["id":"group","conversationId":"chat","name":"Test","isArchived":false,"members":[],"messages":[["messageId":"1","body":text,"createdAt":"1700000000000","authorKind":"user","presentationKind":"message"]]]
            return try JSONDecoder().decode(GroupRead.self,from:JSONSerialization.data(withJSONObject:value))
        }
        let model=ConnectionModel(); let original=try group("Before")
        model.groups=["chat":original]
        XCTAssertEqual(model.rows(for:original.summary).first?.text,"Before")
        XCTAssertEqual(model.rows(for:original.summary).first?.text,"Before")
        model.groups["chat"]=try group("After")
        XCTAssertEqual(model.rows(for:original.summary).first?.text,"After")
        var versioned = try group("First host")
        versioned.hostEpoch = "first"; versioned.lastSequence = 4
        model.groups["chat"] = versioned
        XCTAssertEqual(model.rows(for: original.summary).first?.text, "First host")
        versioned = try group("Replacement host")
        versioned.hostEpoch = "replacement"; versioned.lastSequence = 4
        model.groups["chat"] = versioned
        XCTAssertEqual(model.rows(for: original.summary).first?.text, "Replacement host")
        model.groups=[:]
        XCTAssertTrue(model.rows(for:original.summary).isEmpty)
        for epoch in ["first", "replacement"] {
            let data = Data("""
            {"conversationId":"chat","hostEpoch":"\(epoch)","lastSequence":4,"messages":[],
             "assistantMessages":[{"messageId":"reply","text":"\(epoch)","state":"completed","createdAt":"1","updatedAt":"1"}],
             "thread":{"hydrated":true}}
            """.utf8)
            model.snapshots["chat"] = try JSONDecoder().decode(ConversationSnapshot.self, from: data)
            XCTAssertEqual(model.rows(for: original.summary).first?.text, epoch)
        }
        model.snapshots = [:]
        XCTAssertTrue(model.rows(for: original.summary).isEmpty)
    }
    @MainActor func testTurnLifecycleKeepsPreTurnQueueStateSeparateFromCanonicalControls() throws {
        func snapshot(turns: [[String: Any]], messages: [[String: Any]]) throws -> ConversationSnapshot {
            let value: [String: Any] = [
                "conversationId": "chat", "hostEpoch": "epoch", "lastSequence": 1,
                "messages": messages, "assistantMessages": [],
                "thread": ["hydrated": true, "turns": turns]
            ]
            return try JSONDecoder().decode(ConversationSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let model = ConnectionModel(saved: nil, persistConnection: { _ in })
        let preTurn = try snapshot(turns: [], messages: [
            ["messageId": "accepted", "body": "accepted", "state": "accepted_by_wonder", "createdAt": "1000", "attachmentIds": []],
            ["messageId": "dispatching", "body": "dispatching", "state": "dispatching_to_codex", "createdAt": "1001", "attachmentIds": []]
        ])
        model.snapshots = ["chat": preTurn]
        XCTAssertTrue(model.botWorking("chat"))
        XCTAssertNil(model.activeTurn("chat"), "Pre-turn acceptance cannot be targeted by Guide or Stop")

        let turns: [[String: Any]] = [
            ["id": "old", "status": "inProgress", "createdAt": "2000", "updatedAt": "2000", "items": []],
            ["id": "canonical", "status": "inProgress", "createdAt": "3000", "updatedAt": "3000", "items": []]
        ]
        let active = try snapshot(turns: turns, messages: [
            ["messageId": "late", "body": "late", "state": "streaming", "codexTurnId": "old", "createdAt": "2000", "attachmentIds": []],
            ["messageId": "canonical-receipt", "body": "canonical", "state": "completed", "codexTurnId": "canonical", "createdAt": "3000", "attachmentIds": []]
        ])
        model.snapshots = ["chat": active]
        XCTAssertTrue(model.botWorking("chat"))
        XCTAssertEqual(model.activeTurn("chat"), "canonical")
    }

    @MainActor func testVisibleChildRefreshAndBackNavigationKeepTheRootSelected() async throws {
        DiagnosticSubagentFixture.resetTransport()
        let model = DiagnosticSubagentFixture.model()
        await model.loadChats(force: true)
        let parent = try XCTUnwrap(model.chats.first)
        await model.open(parent)
        let child = try XCTUnwrap(model.subagents[parent.id]?.first).chatSummary(botId: parent.botId)
        await model.open(child, root: parent)
        XCTAssertEqual(model.selectedChat?.id, parent.id)
        XCTAssertEqual(model.visibleChat?.id, child.id)
        let cameraContext = model.cameraContextID
        model.dismissConversation(parent)
        XCTAssertEqual(model.visibleChat?.id, child.id, "A late parent disappearance must not clear its child")

        // A post-creation list refresh must not wait on any old conversation
        // detail endpoint, even while a child is visible over the parent.
        DiagnosticSubagentFixture.resetTransport()
        await model.refreshChatList()
        let listPaths = DiagnosticSubagentFixture.recordedPaths()
        XCTAssertTrue(listPaths.contains("/api/v1/conversations"))
        XCTAssertTrue(listPaths.contains("/api/v1/group-chats"))
        XCTAssertTrue(listPaths.contains("/api/v1/bots"))
        XCTAssertFalse(listPaths.contains { $0.hasPrefix("/api/v1/conversations/\(child.id)") })
        XCTAssertFalse(listPaths.contains { $0.hasPrefix("/api/v1/conversations/\(parent.id)") })
        XCTAssertEqual(model.selectedChat?.id, parent.id)
        XCTAssertEqual(model.visibleChat?.id, child.id)

        DiagnosticSubagentFixture.resetTransport()
        DiagnosticSubagentFixture.updateChild(status: "inProgress")
        await model.loadChats(force: true)
        XCTAssertEqual(model.activeTurn(child.id), "fixture-child-turn")
        for suffix in ["", "/questions", "/queue"] {
            XCTAssertTrue(DiagnosticSubagentFixture.recordedPaths().contains("/api/v1/conversations/\(child.id)\(suffix)"))
        }
        DiagnosticSubagentFixture.updateChild(status: "completed")
        await model.loadChats(force: true)
        XCTAssertNil(model.activeTurn(child.id))
        XCTAssertEqual(model.selectedChat?.id, parent.id)

        model.presentConversation(parent)
        model.dismissConversation(child)
        XCTAssertEqual(model.visibleChat?.id, parent.id)
        XCTAssertNotEqual(model.cameraContextID, cameraContext)
        DiagnosticSubagentFixture.resetTransport()
        await model.loadChats(force: true)
        XCTAssertFalse(DiagnosticSubagentFixture.recordedPaths().contains("/api/v1/conversations/\(child.id)"))
        model.dismissConversation(parent)
        XCTAssertNil(model.visibleChat)
    }

    @MainActor func testCameraAttachesOnlyToTheVisibleVerifiedChild() async throws {
        DiagnosticSubagentFixture.resetTransport()
        let model = DiagnosticSubagentFixture.model()
        await model.loadChats(force: true)
        let parent = try XCTUnwrap(model.chats.first)
        await model.open(parent)
        let child = try XCTUnwrap(model.subagents[parent.id]?.first).chatSummary(botId: parent.botId)
        await model.open(child, root: parent)
        XCTAssertFalse(model.chats.contains { $0.id == child.id })
        let attached = await model.stageCameraPhoto(Self.cameraImageData(), chat: child, scope: model.assignmentScope)
        guard case .cancelled = attached else { return XCTFail("A read-only agent accepted a capture") }
        XCTAssertEqual(model.composers[child.id]?.attachmentCount, 0)
        XCTAssertEqual(model.composers[parent.id]?.attachmentCount, 0)
        model.presentConversation(parent)
        let cancelled = await model.stageCameraPhoto(Self.cameraImageData(), chat: child, scope: model.assignmentScope)
        guard case .cancelled = cancelled else { return XCTFail("An outgoing child accepted a capture") }
        XCTAssertEqual(model.composers[child.id]?.attachmentCount, 0)
    }

    @MainActor func testGroupPreparationFailureKeepsAttachmentOnlyDraftRetryable() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat) = try recoveryGroup(root: root)
        var intent = ComposerIntent(); intent.draftAttachmentIds = ["uploaded-file"]
        model.composers[chat.id] = intent
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/bot-options", status: 503)
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/bot-options", body: try recoveryOptions())

        await model.send(chat)
        XCTAssertNil(model.composerErrors[chat.id])
        XCTAssertNotNil(model.controlErrors[chat.id])
        XCTAssertTrue(model.canSend(chat))
        XCTAssertNil(model.composers[chat.id]?.pending)
        XCTAssertEqual(model.composers[chat.id]?.draftAttachmentIds, ["uploaded-file"])
        await model.send(chat)
        XCTAssertNil(model.controlErrors[chat.id])
        let request = try JSONDecoder().decode(SendRequest.self, from: XCTUnwrap(MessageRecoveryURLProtocol.bodies(path: "/api/v1/group-chats/group/messages").first))
        XCTAssertEqual(request.attachmentIds, ["uploaded-file"])
        XCTAssertEqual(request.body, "")
        XCTAssertNotNil(model.composers[chat.id]?.pending?.receipt)
    }

    @MainActor func testGroupPreparationRejectsOverlappingSendsAndPreservesClickedDraft() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat) = try recoveryGroup(root: root)
        model.editDraft("Original message", chat: chat.id)
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/bot-options", body: try recoveryOptions())
        MessageRecoveryURLProtocol.hold(path: "/api/v1/bot-options")
        let first = Task { @MainActor in await model.send(chat) }
        defer { MessageRecoveryURLProtocol.releaseHeld() }
        for _ in 0..<100 {
            if !MessageRecoveryURLProtocol.bodies(path: "/api/v1/bot-options", includingEmpty: true).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.preparingSends.contains(chat.id))
        XCTAssertFalse(model.canSend(chat))
        model.editDraft("Later edit", chat: chat.id)
        await model.send(chat)
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: "/api/v1/bot-options", includingEmpty: true).count, 1)
        MessageRecoveryURLProtocol.releaseHeld()
        await first.value
        let bodies = MessageRecoveryURLProtocol.bodies(path: "/api/v1/group-chats/group/messages")
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(SendRequest.self, from: XCTUnwrap(bodies.first)).body, "Original message")
        XCTAssertFalse(model.preparingSends.contains(chat.id))
    }

    @MainActor func testUnavailableGroupDefaultDoesNotBecomeADraftStorageError() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat) = try recoveryGroup(root: root)
        model.editDraft("Still here", chat: chat.id)
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/bot-options", body: Data(#"{"models":[],"approvalModes":[],"allowedApprovalPolicies":[]}"#.utf8))
        await model.send(chat)
        XCTAssertTrue(model.canSend(chat))
        XCTAssertNil(model.composerErrors[chat.id])
        XCTAssertNil(model.composers[chat.id]?.pending)
        XCTAssertEqual(model.composers[chat.id]?.draft, "Still here")
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/bot-options", body: try recoveryOptions())
        await model.send(chat)
        XCTAssertNotNil(model.composers[chat.id]?.pending?.receipt)
    }

    @MainActor func testAsyncReplyRejectsOversizedTextBeforePersistingOrSending() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root)
        let chat = try Self.cameraChat(id: "recovery-chat")
        let question = try recoveryQuestion()
        await model.replyAsync(question, chat: chat, answers: [String(repeating: "é", count: 4097)], skip: false)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/conversations/recovery-chat/questions/q").isEmpty)
        XCTAssertNil(try ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device").loadIntent(conversation: "async-reply-q"))
        XCTAssertNotNil(model.attentionErrors[question.id])
        XCTAssertFalse(model.retryableAsyncReplies.contains(question.id))
    }

    @MainActor func testDefinitivelyRejectedAsyncReplyCanBeCorrectedOrSkipped() async throws {
        for status in [400, 413] {
            for skip in [false, true] {
                MessageRecoveryURLProtocol.reset()
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let model = recoveryModel(root: root)
                let chat = try Self.cameraChat(id: "recovery-chat")
                let question = try recoveryQuestion()
                let store = ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
                let old = AsyncAnswerIntent(answers: [String(repeating: "a", count: 8193)], skip: false)
                try store.saveIntent(JSONEncoder().encode(old), conversation: "async-reply-q")
                model.saveAnswerDraft(["0": "Editable answer"], id: question.id)
                let path = "/api/v1/conversations/recovery-chat/questions/q"
                MessageRecoveryURLProtocol.enqueue(path: path, status: status)
                await model.replyAsync(question, chat: chat, answers: ["Ignored during exact retry"], skip: false)
                XCTAssertNil(try store.loadIntent(conversation: "async-reply-q"))
                XCTAssertFalse(model.retryableAsyncReplies.contains(question.id))
                XCTAssertEqual(model.answerDraft(question.id), ["0": "Editable answer"])
                MessageRecoveryURLProtocol.enqueue(path: path, status: 204)
                await model.replyAsync(question, chat: chat, answers: skip ? [] : ["Corrected answer"], skip: skip)
                let bodies = MessageRecoveryURLProtocol.bodies(path: path)
                XCTAssertEqual(bodies.count, 2)
                let retried = try JSONDecoder().decode(AsyncAnswerIntent.self, from: XCTUnwrap(bodies.last))
                XCTAssertEqual(retried.skip, skip)
                XCTAssertEqual(retried.answers, skip ? [] : ["Corrected answer"])
                XCTAssertNil(model.attentionErrors[question.id])
            }
        }
    }

    @MainActor func testAmbiguousAsyncReplyRetainsExactSavedPayloadAcrossRestart() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try Self.cameraChat(id: "recovery-chat")
        let question = try recoveryQuestion()
        let path = "/api/v1/conversations/recovery-chat/questions/q"
        MessageRecoveryURLProtocol.fail(path: path, error: .timedOut)
        await recoveryModel(root: root).replyAsync(question, chat: chat, answers: ["Original answer"], skip: false)
        MessageRecoveryURLProtocol.enqueue(path: path, status: 204)
        await recoveryModel(root: root).replyAsync(question, chat: chat, answers: [], skip: true)
        let bodies = MessageRecoveryURLProtocol.bodies(path: path)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.first, bodies.last, "An ambiguous reply must not silently become Skip")
    }

    @MainActor func testSharedConnectionMaintenanceSurvivesAnotherWindowClosing() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ConnectionLibrary(diagnosticModel: recoveryModel(root: root))
        let first = UUID(), second = UUID()
        library.setScene(first, active: true)
        library.setScene(second, active: true)
        XCTAssertEqual(library.foregroundOwner, first)
        library.setScene(second, active: false)
        XCTAssertEqual(library.foregroundOwner, first)
        library.setScene(second, active: true)
        library.setScene(first, active: false)
        XCTAssertEqual(library.foregroundOwner, second)
        library.setScene(second, active: false)
        XCTAssertNil(library.foregroundOwner)
    }

    // Creation handoff owns one first-message identity across restart. A lost
    // creation response must not replace another saved composer or send twice.
    @MainActor func testCreationMessageTransfersToDurableOutboxOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try Self.cameraChat(id: "creation-outbox")
        let requestID = UUID().uuidString
        let model = recoveryModel(root: root)
        try model.prepareCreationMessage(chat, body: "Help with testing", requestID: requestID)
        let restarted = recoveryModel(root: root)
        try restarted.prepareCreationMessage(chat, body: "Help with testing", requestID: requestID)
        XCTAssertEqual(restarted.composers[chat.id]?.pending?.request.clientMessageId, requestID)
        XCTAssertEqual(restarted.composers[chat.id]?.pending?.request.body, "Help with testing")
        XCTAssertThrowsError(try restarted.prepareCreationMessage(chat, body: "Different message", requestID: UUID().uuidString))
        XCTAssertEqual(restarted.composers[chat.id]?.pending?.request.body, "Help with testing")

        // Delivery can reconcile before the New Chat draft is retired. Replay
        // must leave the accepted composer empty and must not upload the note.
        MessageRecoveryURLProtocol.reset()
        let snapshot = try JSONDecoder().decode(ConversationSnapshot.self,
            from: JSONSerialization.data(withJSONObject: ["conversationId": chat.id,
                "hostEpoch": "epoch", "lastSequence": 1,
                "messages": [["messageId": "accepted", "clientMessageId": requestID,
                    "body": "Help with testing", "state": "completed", "createdAt": "1700000000000",
                    "attachmentIds": ["annotation-file"]]], "assistantMessages": [],
                "thread": ["hydrated": true]]))
        var reconciled = try XCTUnwrap(restarted.composers[chat.id])
        reconciled.reconcile(snapshot)
        try ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
            .saveComposer(reconciled, conversation: chat.id)
        let recovered = recoveryModel(root: root)
        recovered.snapshots[chat.id] = snapshot
        let note = try ArtifactAnnotation(projectId: "project", conversationId: chat.id,
            rootId: "workspace", path: "README.md", source: Data("Source".utf8),
            startLine: 1, endLine: 1, note: "Check this").stagedFile()
        try await recovered.prepareCreation(chat, body: "Help with testing", requestID: requestID, files: [note])
        XCTAssertEqual(recovered.composers[chat.id]?.draft, "")
        XCTAssertEqual(recovered.composers[chat.id]?.attachmentCount, 0)
        XCTAssertNil(recovered.composers[chat.id]?.pending)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/conversations/\(chat.id)/files", includingEmpty: true).isEmpty)
        recovered.editDraft("Next question", chat: chat.id)
        try await recovered.prepareCreation(chat, body: "Help with testing", requestID: requestID, files: [note])
        XCTAssertEqual(recovered.composers[chat.id]?.draft, "Next question", "Replay must preserve a newer draft")
    }

    @MainActor func testAnnotationFolderRejectionRestoresEditableMessage() async throws {
        for detail in ["Project folders changed. Reopen the annotation preview before sending.",
                       "An annotated Project folder changed. Reopen the preview before sending."] {
            MessageRecoveryURLProtocol.reset()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let chat = try Self.cameraChat(id: "annotation-folder-recovery")
            var intent = ComposerIntent()
            intent.draft = "Review my note"
            intent.draftAttachmentIds = ["annotation-file"]
            try ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
                .saveComposer(intent, conversation: chat.id)
            let model = recoveryModel(root: root)
            try model.prepareCreationMessage(chat, body: intent.draft, requestID: UUID().uuidString)
            let path = "/api/v1/conversations/\(chat.id)/messages"
            MessageRecoveryURLProtocol.enqueue(path: path, status: 409, body: Data(detail.utf8), contentType: "text/plain")
            await model.deliver(chat)
            XCTAssertNil(model.composers[chat.id]?.pending)
            XCTAssertEqual(model.composers[chat.id]?.draft, intent.draft)
            XCTAssertEqual(model.composers[chat.id]?.draftAttachmentIds, ["annotation-file"])
            XCTAssertTrue(model.controlErrors[chat.id]?.contains(detail) == true)
            let restored = try ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
                .loadComposer(conversation: chat.id)
            XCTAssertNil(restored.pending)
            XCTAssertEqual(restored.draft, intent.draft)
            await model.deliver(chat)
            XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path).count, 1,
                           "A rejected note must remain editable instead of retrying immutable bytes")
        }
    }

    // Choosing another destination retains both drafts and any uncertain
    // request. Connection removal clears only the selected Mac's drafts.
    @MainActor func testNewChatDraftsRestorePerDestinationAndStayConnectionScoped() throws {
        let host = "draft-test-" + UUID().uuidString
        let otherHost = "other-" + host
        defer { NewChatDraftStore.remove(host: host); NewChatDraftStore.remove(host: otherHost) }
        var bot = NewChatDraft(destination: .newBot, text: "Bot purpose")
        let file = try StagedFile(name: "draft.txt", mimeType: "text/plain", data: Data("Owned bytes".utf8))
        let descriptor = try NewChatDraftStore.stage(file)
        let storedFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NewChatAttachments").appendingPathComponent(file.id)
        defer { try? FileManager.default.removeItem(at: storedFile) }
        bot.attachments = [descriptor]
        let projectDraft = NewChatDraftStore.selecting(.project(id: "draft-project"), from: bot, host: host)
        XCTAssertEqual(projectDraft.text, bot.text, "Choosing an empty project keeps the owner's words")
        XCTAssertEqual(projectDraft.attachments, bot.attachments)
        XCTAssertEqual(NewChatDraftStore.load(host: host, destination: .newBot), bot,
                       "Carrying to a project must keep the outgoing draft recoverable")
        var otherProject = projectDraft
        otherProject.text = "Independent project draft"
        let secondProject = NewChatDraftStore.selecting(.project(id: "second-project"), from: otherProject, host: host)
        XCTAssertEqual(secondProject.text, otherProject.text)
        var editedSecond = secondProject
        editedSecond.text = "Second project words"
        let returnedProject = NewChatDraftStore.selecting(.project(id: "draft-project"), from: editedSecond, host: host)
        XCTAssertEqual(returnedProject.text, otherProject.text)
        XCTAssertEqual(NewChatDraftStore.load(host: host, destination: .project(id: "second-project"))?.text, editedSecond.text)
        let group = NewChatDraftStore.selecting(.newGroup, from: bot, host: host)
        XCTAssertTrue(group.text.isEmpty)
        var edited = group; edited.text = "Group purpose"
        let recovered = NewChatDraftStore.selecting(.newBot, from: edited, host: host)
        XCTAssertEqual(recovered.text, "Bot purpose")
        let staged = try NewChatDraftStore.files(try XCTUnwrap(recovered.attachments))
        XCTAssertEqual(staged.first?.data, file.data)
        XCTAssertNil(staged.first?.uploaded, "A new destination must upload local bytes through its own authenticated route")
        let moved = NewChatDraft.switching(from: recovered, toSaved: nil)
        XCTAssertNil(moved.destination)
        XCTAssertEqual(moved.attachments, recovered.attachments)
        try Data("Changed bytes".utf8).write(to: storedFile)
        XCTAssertThrowsError(try NewChatDraftStore.files(try XCTUnwrap(moved.attachments)))
        XCTAssertEqual(NewChatDraftStore.load(host: host, destination: .newGroup)?.text, "Group purpose")
        bot.freeze()
        XCTAssertEqual(NewChatDraftStore.selecting(.newGroup, from: bot, host: host), bot)
        NewChatDraftStore.save(edited, host: otherHost)
        // Selection now saves the displayed draft immediately. Explicitly
        // navigate away before delivering a late result to the Bot draft.
        let active = NewChatDraftStore.selecting(.newGroup, from: recovered, host: host)
        XCTAssertEqual(active.text, "Group purpose")
        XCTAssertEqual(NewChatDraftStore.load(host: host)?.requestID, active.requestID)
        XCTAssertNotEqual(active.requestID, recovered.requestID)
        // A late dictation result belongs to the original destination, is
        // idempotent, and must not overwrite the currently selected draft.
        try NewChatDraftStore.insertDictation("spoken words", requestID: "recording", draftID: recovered.requestID, host: host)
        try NewChatDraftStore.insertDictation("spoken words", requestID: "recording", draftID: recovered.requestID, host: host)
        XCTAssertEqual(NewChatDraftStore.load(host: host, destination: .newBot)?.text, "Bot purpose spoken words")
        XCTAssertEqual(NewChatDraftStore.load(host: host)?.text, "Group purpose")
        XCTAssertThrowsError(try NewChatDraftStore.insertDictation("wrong host", requestID: "other", draftID: recovered.requestID, host: otherHost))
        var submitted = try XCTUnwrap(NewChatDraftStore.load(host: host, destination: .newBot))
        submitted.freeze()
        NewChatDraftStore.save(submitted, host: host)
        XCTAssertThrowsError(try NewChatDraftStore.insertDictation("too late", requestID: "late", draftID: submitted.requestID, host: host))
        NewChatDraftStore.remove(host: host)
        XCTAssertNil(NewChatDraftStore.load(host: host, destination: .newBot))
        XCTAssertEqual(NewChatDraftStore.load(host: otherHost)?.text, "Group purpose")
    }

    // Contract: leaving an unconfirmed creation unlocks a separate draft while
    // preserving the original retry identity, attachment bytes and pairing.
    // Reviewing, confirming or rejecting it cannot erase newer project words.
    @MainActor func testUnconfirmedNewChatKeepsOriginalAndIndependentDraft() throws {
        let host = "pending-draft-test-" + UUID().uuidString
        let otherHost = "other-" + host
        defer { NewChatDraftStore.remove(host: host); NewChatDraftStore.remove(host: otherHost) }
        let file = try StagedFile(name: "original.txt", mimeType: "text/plain", data: Data("Original bytes".utf8))
        let descriptor = try NewChatDraftStore.stage(file)
        let storedFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NewChatAttachments").appendingPathComponent(file.id)
        defer { try? FileManager.default.removeItem(at: storedFile) }
        var original = NewChatDraft(destination: .project(id: "project"), text: "Original message", family: .codex, model: "model")
        original.attachments = [descriptor]
        original.submittedDeviceID = "original-device"
        XCTAssertTrue(NewChatDraftStore.save(original, host: host))
        original.freeze()
        XCTAssertTrue(NewChatDraftStore.save(original, host: host))
        var fresh = try XCTUnwrap(NewChatDraftStore.startNew(from: original, host: host))
        XCTAssertFalse(fresh.isSubmitted)
        XCTAssertNotEqual(fresh.requestID, original.requestID)
        XCTAssertTrue(fresh.text.isEmpty)
        XCTAssertNil(fresh.attachments)
        fresh.text = "Independent words"
        XCTAssertTrue(NewChatDraftStore.save(fresh, host: host))
        let restored = try XCTUnwrap(NewChatDraftStore.savedMessages(host: host).first)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(try NewChatDraftStore.files(try XCTUnwrap(restored.attachments)).first?.data, file.data)
        XCTAssertTrue(NewChatDraftStore.save(restored, host: host))
        XCTAssertEqual(NewChatDraftStore.load(host: host), original)
        XCTAssertEqual(NewChatDraftStore.load(host: host, destination: .project(id: "project")), fresh)
        XCTAssertEqual(NewChatDraftStore.startNew(from: restored, host: host), fresh)
        let completed = try XCTUnwrap(NewChatDraftStore.complete(restored, host: host))
        XCTAssertEqual(completed, fresh)
        XCTAssertTrue(NewChatDraftStore.savedMessages(host: host).isEmpty)
        XCTAssertTrue(NewChatDraftStore.save(original, host: host))
        let rejected = try XCTUnwrap(NewChatDraftStore.reject(original, host: host))
        XCTAssertFalse(rejected.isSubmitted)
        XCTAssertEqual(rejected.text, original.text)
        XCTAssertEqual(rejected.attachments, original.attachments)
        XCTAssertNotEqual(rejected.requestID, original.requestID)
        XCTAssertEqual(NewChatDraftStore.load(host: host, destination: .project(id: "project")), fresh)
        XCTAssertEqual(NewChatDraftStore.savedMessages(host: host), [rejected])
        XCTAssertTrue(NewChatDraftStore.save(original, host: otherHost))
        NewChatDraftStore.remove(host: host)
        XCTAssertTrue(NewChatDraftStore.savedMessages(host: host).isEmpty)
        XCTAssertEqual(NewChatDraftStore.load(host: otherHost), original)
    }

    // Contract: saving a project pin updates the thread, global Pinned list and
    // offline detail together. Regression: a details-sheet save left the old
    // cache behind, and its overlapping GET put the unpinned detail back.
    @MainActor func testProjectPinSaveSurvivesStaleDetailAndRelaunch() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = recoveryModel(root: root)
        model.projects.forgetCache()
        defer { MessageRecoveryURLProtocol.releaseHeld(); model.projects.forgetCache(); try? FileManager.default.removeItem(at: root) }
        try await prepareProject(model)
        let path = "/api/v1/project-conversations/project-chat"
        MessageRecoveryURLProtocol.enqueue(path: path, method: "GET", body: projectDetail(pinned: false))
        MessageRecoveryURLProtocol.hold(path: path, method: "GET")
        let stale = Task { try await model.projects.loadDetail("project-chat") }
        for _ in 0..<100 {
            if MessageRecoveryURLProtocol.bodies(path: path, includingEmpty: true).count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path, includingEmpty: true).count, 2)
        MessageRecoveryURLProtocol.enqueue(path: path, method: "PATCH", body: projectDetail(pinned: true))
        try await model.projects.updateConversation("project-chat", fields: ["isPinned": true])
        XCTAssertEqual(model.projects.pinned.map(\.thread.conversationId), ["project-chat"])
        MessageRecoveryURLProtocol.releaseHeld()
        let refreshed = try await stale.value
        XCTAssertTrue(refreshed.isPinned)
        XCTAssertTrue(try XCTUnwrap(model.projects.threads["project"]?.threads.first).isPinned)
        let restarted = recoveryModel(root: root)
        XCTAssertEqual(restarted.projects.details["project-chat"]?.isPinned, true)
        XCTAssertEqual(restarted.projects.pinned.map(\.thread.conversationId), ["project-chat"])
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/conversations/project-chat/messages").isEmpty)
    }

    // Contract: a pin save joining an older catalog read still obtains a new
    // catalog; late thread pages cannot undo its pin. The transport controls
    // the actual production request boundary rather than mocking the library.
    @MainActor func testProjectPinRefreshAndThreadPageKeepNewerSave() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = recoveryModel(root: root)
        model.projects.forgetCache()
        defer { MessageRecoveryURLProtocol.releaseHeld(); model.projects.forgetCache(); try? FileManager.default.removeItem(at: root) }
        try await prepareProject(model)
        let pagePath = "/api/v1/projects/project/threads"
        MessageRecoveryURLProtocol.enqueue(path: pagePath, body: projectPage(pinned: false))
        MessageRecoveryURLProtocol.hold(path: pagePath)
        model.projects.loadThreads("project")
        for _ in 0..<100 {
            if MessageRecoveryURLProtocol.bodies(path: pagePath, includingEmpty: true).count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/project-conversations/project-chat", body: projectDetail(pinned: true))
        try await model.projects.updateConversation("project-chat", fields: ["isPinned": true])
        MessageRecoveryURLProtocol.releaseHeld()
        for _ in 0..<100 {
            if model.projects.threads["project"]?.isLoading == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(try XCTUnwrap(model.projects.threads["project"]?.threads.first).isPinned)

        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/projects", body: projectCatalog(pinned: true))
        MessageRecoveryURLProtocol.hold(path: "/api/v1/projects")
        let stale = Task { await model.projects.refresh() }
        for _ in 0..<100 {
            if MessageRecoveryURLProtocol.bodies(path: "/api/v1/projects", includingEmpty: true).count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/project-conversations/project-chat", body: projectDetail(pinned: false))
        try await model.projects.updateConversation("project-chat", fields: ["isPinned": false])
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/projects", body: projectCatalog(pinned: false))
        MessageRecoveryURLProtocol.enqueue(path: pagePath, body: projectPage(pinned: false))
        MessageRecoveryURLProtocol.enqueue(path: pagePath, body: projectPage(pinned: false))
        let afterSave = Task { await model.projects.refresh() }
        await Task.yield()
        MessageRecoveryURLProtocol.releaseHeld()
        await stale.value; await afterSave.value
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: "/api/v1/projects", includingEmpty: true).count, 3)
        XCTAssertTrue(model.projects.pinned.isEmpty)
        XCTAssertEqual(model.projects.details["project-chat"]?.isPinned, false)
    }

    // Contract: confirmed archives survive stale catalog responses without
    // discarding drafts; a desktop restore makes the native thread visible again.
    @MainActor func testProjectArchiveFencesStalePageAndPreservesDraftOnRestore() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = recoveryModel(root: root)
        model.projects.forgetCache()
        defer { MessageRecoveryURLProtocol.releaseHeld(); model.projects.forgetCache(); try? FileManager.default.removeItem(at: root) }
        // Reuse the Project fixtures with the native Codex family.
        func codex(_ data: Data) -> Data {
            Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "claude", with: "codex").utf8)
        }
        let path = "/api/v1/project-conversations/project-chat"
        let pagePath = "/api/v1/projects/project/threads"
        let page = codex(projectPage(pinned: true))
        let detail = codex(projectDetail(pinned: true))
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/projects", body: codex(projectCatalog(pinned: true)))
        await model.projects.refresh()
        MessageRecoveryURLProtocol.enqueue(path: pagePath, body: page)
        model.projects.loadThreads("project")
        for _ in 0..<100 {
            if model.projects.threads["project"]?.hasLoaded == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        MessageRecoveryURLProtocol.enqueue(path: path, body: detail)
        try await model.projects.loadDetail("project-chat")
        model.editDraft("Keep my unsent words", chat: "project-chat")
        MessageRecoveryURLProtocol.enqueue(path: pagePath, body: page)
        MessageRecoveryURLProtocol.hold(path: pagePath)
        model.projects.loadThreads("project")
        for _ in 0..<100 {
            if MessageRecoveryURLProtocol.bodies(path: pagePath, includingEmpty: true).count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        var archived = try XCTUnwrap(JSONSerialization.jsonObject(with: detail) as? [String: Any])
        archived["isArchived"] = true
        MessageRecoveryURLProtocol.enqueue(path: path, method: "PATCH", body: try JSONSerialization.data(withJSONObject: archived))
        try await model.projects.updateConversation("project-chat", fields: ["isArchived": true])
        MessageRecoveryURLProtocol.releaseHeld()
        for _ in 0..<100 {
            if model.projects.threads["project"]?.isLoading == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.projects.pinned.isEmpty)
        XCTAssertTrue(try XCTUnwrap(model.projects.threads["project"]).threads.isEmpty)
        XCTAssertEqual(model.projects.details["project-chat"]?.isArchived, true)
        XCTAssertEqual(model.composers["project-chat"]?.draft, "Keep my unsent words")

        // A new catalog is authoritative after a restore in Codex Desktop.
        MessageRecoveryURLProtocol.enqueue(path: pagePath, body: page)
        model.projects.loadThreads("project")
        for _ in 0..<100 {
            if model.projects.threads["project"]?.isLoading == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        archived["isArchived"] = false
        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONSerialization.data(withJSONObject: archived))
        try await model.projects.loadDetail("project-chat")
        XCTAssertEqual(model.projects.threads["project"]?.threads.first?.reference, "codex:fixture")
        XCTAssertEqual(model.projects.details["project-chat"]?.isArchived, false)
        XCTAssertEqual(model.composers["project-chat"]?.draft, "Keep my unsent words")
    }

    // Contract: old hosts expose no plan controls or mode writes; a response
    // for an ended pairing cannot claim a successful mode save.
    @MainActor func testProjectPlanSaveRequiresCapabilityAndCurrentPairing() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = recoveryModel(root: root)
        model.projects.forgetCache()
        defer { MessageRecoveryURLProtocol.releaseHeld(); model.projects.forgetCache(); try? FileManager.default.removeItem(at: root) }
        let chat = try Self.cameraChat(id: "project-chat")
        let oldResult = await setPlanMode(true, model: model, library: model.projects, chat: chat)
        XCTAssertFalse(oldResult)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/project-conversations/project-chat").isEmpty)
        try await prepareProject(model)
        let path = "/api/v1/project-conversations/project-chat"
        MessageRecoveryURLProtocol.enqueue(path: path, body: projectDetail(pinned: false, plan: true))
        let enabled = await setPlanMode(true, model: model, library: model.projects, chat: chat)
        XCTAssertTrue(enabled)
        MessageRecoveryURLProtocol.enqueue(path: path, body: projectDetail(pinned: false, plan: false))
        MessageRecoveryURLProtocol.hold(path: path, method: "PATCH")
        let save = Task { await setPlanMode(false, model: model, library: model.projects, chat: chat) }
        for _ in 0..<100 {
            if MessageRecoveryURLProtocol.bodies(path: path).count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.accessEnded = true
        MessageRecoveryURLProtocol.releaseHeld()
        let staleResult = await save.value
        XCTAssertFalse(staleResult)
        XCTAssertEqual(model.projects.details["project-chat"]?.planMode, true)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/conversations/project-chat/messages").isEmpty)
    }

    // Contract: a confirmed read clears the thread's unread dot everywhere it
    // shows and after relaunch. Regression: Project chats are absent from the
    // Bot inbox, so its unread check prevented the actual acknowledgement path.
    @MainActor func testProjectReadClearsUnreadAcrossSidebarAndRelaunch() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = recoveryModel(root: root)
        model.projects.forgetCache()
        defer { model.projects.forgetCache(); try? FileManager.default.removeItem(at: root) }
        model.setForeground(true)
        await model.loadChats()
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/projects", body: projectCatalog(pinned: false))
        await model.projects.refresh()
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/projects/project/threads", body: projectPage(pinned: false, unread: true))
        model.projects.loadThreads("project")
        for _ in 0..<100 {
            if model.projects.threads["project"]?.hasLoaded == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/project-conversations/project-chat", body: projectDetail(pinned: false, unread: true))
        let detail = try await model.projects.loadDetail("project-chat")
        let chat = model.projectChat(detail)
        XCTAssertFalse(model.chats.contains { $0.id == chat.id })
        XCTAssertTrue(model.hasUnread(chat.id))
        let path = "/api/v1/conversations/project-chat"
        MessageRecoveryURLProtocol.enqueue(path: path, method: "GET", body: Data(#"{"conversationId":"project-chat","hostEpoch":"epoch","lastSequence":1,"messages":[],"assistantMessages":[],"thread":{"hydrated":true}}"#.utf8))
        await model.open(chat, readOnly: true)
        let visible = try XCTUnwrap(model.readReceipt(for: chat.id))
        MessageRecoveryURLProtocol.enqueue(path: path, method: "PATCH", status: 503)
        await model.acknowledgeVisibleRead(visible)
        XCTAssertTrue(model.hasUnread(chat.id), "A failed read must keep its dot until a retry succeeds")
        MessageRecoveryURLProtocol.enqueue(path: path, method: "PATCH", status: 204, body: Data())
        await model.acknowledgeVisibleRead(visible)
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path).count, 2)
        XCTAssertFalse(model.projects.hasUnread("project-chat"))
        XCTAssertEqual(model.projects.threads["project"]?.threads.first?.hasUnread, false)
        XCTAssertEqual(model.projects.details["project-chat"]?.hasUnread, false)
        let restarted = recoveryModel(root: root)
        XCTAssertFalse(restarted.projects.hasUnread("project-chat"))

        // Explicit sidebar actions persist without opening a conversation.
        XCTAssertNil(restarted.visibleChat)
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/project-conversations/project-chat", method: "PATCH", body: projectDetail(pinned: false, unread: true))
        try await restarted.projects.updateConversation(chat.id, fields: ["hasUnread": true])
        XCTAssertTrue(restarted.hasUnread(chat.id))
        XCTAssertEqual(restarted.projects.threads["project"]?.threads.first?.hasUnread, true)
        XCTAssertTrue(recoveryModel(root: root).projects.hasUnread(chat.id))
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/project-conversations/project-chat", method: "PATCH", body: projectDetail(pinned: false, unread: false))
        try await restarted.projects.updateConversation(chat.id, fields: ["hasUnread": false])
        XCTAssertFalse(recoveryModel(root: root).projects.hasUnread(chat.id))
        XCTAssertNil(restarted.visibleChat)

        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/project-conversations/project-chat", method: "PATCH", body: projectDetail(pinned: false, unread: true))
        try await model.projects.updateConversation(chat.id, fields: ["hasUnread": true])
        await model.acknowledgeVisibleRead(visible)
        XCTAssertTrue(model.hasUnread(chat.id), "An explicit unread action on the visible thread must survive automatic reading")
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path).count, 2)
        model.projects.noteOpened(chat.id)
        MessageRecoveryURLProtocol.enqueue(path: path, method: "PATCH", status: 204, body: Data())
        await model.acknowledgeVisibleRead(visible)
        XCTAssertFalse(model.hasUnread(chat.id), "Opening the thread again resumes automatic reading")
        model.setForeground(false)
    }

    // Contract: a catalog request started before a read change cannot put back
    // the old dot. The real request/cache boundary owns this refresh race.
    @MainActor func testProjectReadSurvivesOlderSidebarRefresh() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = recoveryModel(root: root)
        model.projects.forgetCache()
        defer { MessageRecoveryURLProtocol.releaseHeld(); model.projects.forgetCache(); try? FileManager.default.removeItem(at: root) }
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/projects", body: projectCatalog(pinned: false))
        await model.projects.refresh()
        let path = "/api/v1/projects/project/threads"
        MessageRecoveryURLProtocol.enqueue(path: path, body: projectPage(pinned: false, unread: true))
        model.projects.loadThreads("project")
        for _ in 0..<100 {
            if model.projects.threads["project"]?.hasLoaded == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/project-conversations/project-chat", body: projectDetail(pinned: false, unread: true))
        try await model.projects.loadDetail("project-chat")
        MessageRecoveryURLProtocol.enqueue(path: path, body: projectPage(pinned: false, unread: true))
        MessageRecoveryURLProtocol.hold(path: path)
        model.projects.loadThreads("project")
        try await waitForRecoveryRequests(path: path, count: 2)
        model.projects.markRead("project-chat")
        MessageRecoveryURLProtocol.releaseHeld()
        for _ in 0..<100 {
            if model.projects.threads["project"]?.isLoading == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.hasUnread("project-chat"))
        XCTAssertEqual(model.projects.threads["project"]?.threads.first?.hasUnread, false)
        XCTAssertFalse(recoveryModel(root: root).projects.hasUnread("project-chat"))
    }

    // Contract: a project request stops appearing in Queue when the Mac starts
    // it, while genuinely waiting requests remain editable. Regression: project
    // chats have no botId, so foreground/replay refreshes never reloaded Queue.
    @MainActor func testProjectQueueRefreshRetiresStartedMessagesAndKeepsWaitingMessages() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = recoveryModel(root: root)
        model.projects.forgetCache()
        defer { model.projects.forgetCache(); try? FileManager.default.removeItem(at: root) }
        let detail = try JSONDecoder().decode(ProjectConversationDetail.self, from: projectDetail(pinned: false))
        model.registerProjectConversation(detail)
        let chat = model.projectChat(detail)
        XCTAssertNil(chat.botId)
        let path = "/api/v1/conversations/" + chat.id
        let queue: [[String: Any]] = ["first", "waiting"].map { id in
            ["id": id, "clientMessageId": id + "-client", "body": id + " request", "revision": 1, "attachmentIds": []]
        }
        func snapshot(started: Bool, finished: Bool = false) throws -> Data {
            let messages: [[String: Any]] = ["first", "waiting"].enumerated().map { index, id in
                var message: [String: Any] = ["messageId": id, "clientMessageId": id + "-client", "body": id + " request",
                    "state": finished ? "completed" : started && index == 0 ? "streaming" : "accepted_by_wonder",
                    "createdAt": "\(1000 + index)", "attachmentIds": []]
                if finished || started && index == 0 { message["codexTurnId"] = id + "-turn" }
                return message
            }
            let turns: [[String: Any]] = (finished ? ["first", "waiting"] : started ? ["first"] : []).map { id in
                ["id": id + "-turn", "status": finished ? "completed" : "inProgress", "items": [
                    ["id": id + "-item", "type": "userMessage", "state": "completed", "text": id + " request",
                     "payload": ["clientId": id + "-client"], "createdAt": id == "first" ? "1000" : "1001"]
                ]]
            }
            return try JSONSerialization.data(withJSONObject: ["conversationId": chat.id, "hostEpoch": "epoch", "lastSequence": 1,
                "messages": messages, "assistantMessages": [], "thread": ["hydrated": true, "turns": turns]])
        }
        MessageRecoveryURLProtocol.enqueue(path: path, body: try snapshot(started: false))
        MessageRecoveryURLProtocol.enqueue(path: path + "/queue", body: try JSONSerialization.data(withJSONObject: queue))
        await model.open(chat)
        XCTAssertEqual(model.queues[chat.id]?.map(\.id), ["first", "waiting"])
        XCTAssertTrue(model.feedRows(for: chat).isEmpty)

        MessageRecoveryURLProtocol.enqueue(path: path, body: try snapshot(started: true))
        MessageRecoveryURLProtocol.enqueue(path: path + "/queue", body: try JSONSerialization.data(withJSONObject: [queue[1]]))
        await model.loadChats(force: true)
        XCTAssertEqual(model.activeTurn(chat.id), "first-turn")
        XCTAssertEqual(model.queues[chat.id]?.map(\.id), ["waiting"])
        XCTAssertEqual(model.feedRows(for: chat).map(\.id), ["user-first-client"])

        MessageRecoveryURLProtocol.enqueue(path: path, body: try snapshot(started: true, finished: true))
        MessageRecoveryURLProtocol.enqueue(path: path + "/queue", body: Data("[]".utf8))
        await model.loadChats(force: true)
        XCTAssertNil(model.activeTurn(chat.id))
        XCTAssertTrue(model.queues[chat.id]?.isEmpty == true)
        XCTAssertEqual(model.feedRows(for: chat).map(\.id), ["user-first-client", "user-waiting-client"])
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path + "/queue", includingEmpty: true).count, 3)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: path + "/messages").isEmpty)
    }

    // Opening an already attached Codex thread must reach the host association
    // check instead of treating its cached conversation ID as sufficient.
    @MainActor func testCodexProjectOpenReattachesExistingNativeThread() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = recoveryModel(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let thread = ProjectThreadSummary(reference: "codex:fixture", conversationId: "project-chat", title: "Thread", family: .codex,
            updatedAt: 1, isPinned: false, hasUnread: false, isWorking: false)
        let path = "/api/v1/projects/project/threads/attach"
        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(thread))
        let id = try await model.projects.attach("project", thread: thread)
        XCTAssertEqual(id, "project-chat")
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path).count, 1)
        let request = try XCTUnwrap(MessageRecoveryURLProtocol.bodies(path: path).first)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: String])
        XCTAssertEqual(payload, ["reference": "codex:fixture"])
        let draft = ProjectThreadSummary(reference: "wonder:draft", conversationId: "draft-chat", title: "Draft", family: .codex,
            updatedAt: 1, isPinned: false, hasUnread: false, isWorking: false)
        let draftID = try await model.projects.attach("project", thread: draft)
        XCTAssertEqual(draftID, "draft-chat")
        let claude = ProjectThreadSummary(reference: "claude:fixture", conversationId: "claude-chat", title: "Claude", family: .claude,
            updatedAt: 1, isPinned: false, hasUnread: false, isWorking: false)
        let claudeID = try await model.projects.attach("project", thread: claude)
        XCTAssertEqual(claudeID, "claude-chat")
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path).count, 1, "Drafts and attached Claude sessions need no native Codex repair")
    }

    // A Project conversation without a provider session still has a durable
    // conversation ID and must be reachable from the Widget's recent chats.
    @MainActor func testWidgetIncludesUnstartedProjectConversation() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = recoveryModel(root: root)
        model.projects.forgetCache()
        defer { model.projects.forgetCache(); try? FileManager.default.removeItem(at: root) }
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/projects", body: projectCatalog(pinned: false))
        await model.projects.refresh()
        let page = Data(#"{"threads":[{"reference":"wonder:draft-chat","conversationId":"draft-chat","title":"Planning draft","family":"codex","updatedAt":2,"isPinned":false,"hasUnread":false,"isWorking":false},{"reference":"codex:fixture","conversationId":"started-chat","title":"Started","family":"codex","updatedAt":1,"isPinned":false,"hasUnread":false,"isWorking":false}],"nextCursor":null,"partial":[]}"#.utf8)
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/projects/project/threads", body: page)
        MessageRecoveryURLProtocol.hold(path: "/api/v1/projects/project/threads", method: "GET")
        defer { MessageRecoveryURLProtocol.releaseHeld() }
        model.projects.loadThreads("project")
        for _ in 0..<100 {
            if !MessageRecoveryURLProtocol.bodies(path: "/api/v1/projects/project/threads", includingEmpty: true).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: "/api/v1/projects/project/threads", includingEmpty: true).count, 1)
        let response = Data(#"{"conversation":{"reference":"wonder:draft-chat","conversationId":"draft-chat","title":"Planning draft","family":"codex","updatedAt":2,"isPinned":false,"hasUnread":false,"isWorking":false},"receipt":null}"#.utf8)
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/projects/project/threads", method: "POST", body: response)
        var widgetChanges = 0
        model.projects.widgetSnapshotChanged = { widgetChanges += 1 }
        let draft = NewChatDraft(destination: .project(id: "project"), text: "Plan the next step", family: .codex, model: "fixture-model")
        let created = try await model.projects.createThread(projectID: "project", draft: draft,
                                                            body: "Plan the next step", deviceID: Self.cameraSavedConnection().credential.deviceId)
        XCTAssertEqual(created.conversation.conversationId, "draft-chat")
        XCTAssertEqual(widgetChanges, 1, "A successful prepare-only POST must request a Widget refresh before any detail GET")
        let secondResponse = Data(#"{"conversation":{"reference":"wonder:second-chat","conversationId":"second-chat","title":"Second draft","family":"codex","updatedAt":3,"isPinned":false,"hasUnread":false,"isWorking":false},"receipt":null}"#.utf8)
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/projects/project/threads", method: "POST", body: secondResponse)
        let secondDraft = NewChatDraft(destination: .project(id: "project"), text: "Another plan", family: .codex, model: "fixture-model")
        let second = try await model.projects.createThread(projectID: "project", draft: secondDraft,
                                                           body: "Another plan", deviceID: Self.cameraSavedConnection().credential.deviceId)
        XCTAssertEqual(second.conversation.conversationId, "second-chat")
        var renamed = try XCTUnwrap(JSONSerialization.jsonObject(with: projectDetail(pinned: false)) as? [String: Any])
        renamed["conversationId"] = "draft-chat"
        renamed["title"] = "Revised draft"
        renamed["family"] = "codex"
        renamed["hasNativeSession"] = false
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/project-conversations/draft-chat", method: "PATCH",
                                           body: try JSONSerialization.data(withJSONObject: renamed))
        try await model.projects.updateConversation("draft-chat", fields: ["title": "Revised draft"])
        let changesBeforeOldPage = widgetChanges
        MessageRecoveryURLProtocol.releaseHeld()
        for _ in 0..<100 {
            if model.projects.threads["project"]?.isLoading == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.projects.threads["project"]?.isLoading, false)
        XCTAssertEqual(widgetChanges, changesBeforeOldPage + 1, "The older thread page must request another Widget refresh")
        XCTAssertEqual(model.projects.threads["project"]?.threads.compactMap(\.conversationId),
                       ["second-chat", "draft-chat", "started-chat"], "Locally created rows must keep their sidebar order")
        let library = ConnectionLibrary(diagnosticModel: model)
        let project = try XCTUnwrap(ProjectWidgetSnapshotPublisher.projectRows(from: library).first)
        XCTAssertEqual(project.id, "project")
        XCTAssertEqual(project.recentChats.map(\.id), ["second-chat", "draft-chat", "started-chat"])
        XCTAssertEqual(project.recentChats.dropFirst().first?.title, "Revised draft")
    }

    @MainActor private func prepareProject(_ model: ConnectionModel) async throws {
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/projects", body: projectCatalog(pinned: false))
        await model.projects.refresh()
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/projects/project/threads", body: projectPage(pinned: false))
        model.projects.loadThreads("project")
        for _ in 0..<100 {
            if model.projects.threads["project"]?.hasLoaded == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.projects.threads["project"]?.hasLoaded, true)
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/project-conversations/project-chat", body: projectDetail(pinned: false))
        try await model.projects.loadDetail("project-chat")
    }

    // Contract: the composer warning reflects the newest checked source even
    // when an older annotation download finishes afterward. The host still
    // validates the source hash at send; this covers the client-visible state.
    @MainActor func testAnnotationStaleWarningIgnoresOlderRevisionDownload() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = recoveryModel(root: root)
        defer {
            MessageRecoveryURLProtocol.releaseHeld()
            model.projects.forgetCache()
            try? FileManager.default.removeItem(at: root)
        }
        try await prepareProject(model)
        let chat = model.projectChat(try XCTUnwrap(model.projects.details["project-chat"]))
        let original = Data("Old source".utf8)
        let annotation = try ArtifactAnnotation(projectId: "project", conversationId: chat.id,
            rootId: "workspace", path: "README.md", source: original, mimeType: "text/plain",
            startByte: 0, endByte: 3, note: "Check this")
        let bytes = try annotation.stagedFile().data
        let fileID = UUID().uuidString
        let metadata: [String: Any] = ["id": fileID, "name": "README.md.annotation.json",
            "mimeType": ArtifactAnnotation.mimeType, "byteSize": bytes.count,
            "sha256": ConversationFile.digest(bytes), "state": "available", "updatedAt": "fixture"]
        let file = try JSONDecoder().decode(ConversationFile.self,
            from: JSONSerialization.data(withJSONObject: metadata))
        model.files[chat.id] = [file]
        var composer = ComposerIntent()
        composer.draftAttachmentIds = [file.id]
        model.composers[chat.id] = composer
        let path = "/api/v1/conversations/\(chat.id)/files/\(file.id)"
        MessageRecoveryURLProtocol.enqueue(path: path, body: bytes, contentType: ArtifactAnnotation.mimeType)
        MessageRecoveryURLProtocol.enqueue(path: path, body: bytes, contentType: ArtifactAnnotation.mimeType)
        MessageRecoveryURLProtocol.hold(path: path)

        let older = Task { await model.noteWorkspaceRevision(chat, rootID: "workspace", path: "README.md",
                                                             currentSha256: ConversationFile.digest(original)) }
        for _ in 0..<100 where MessageRecoveryURLProtocol.bodies(path: path, includingEmpty: true).count < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path, includingEmpty: true).count, 1)
        let newer = Task { await model.noteWorkspaceRevision(chat, rootID: "workspace", path: "README.md",
                                                             currentSha256: ConversationFile.digest(Data("New source".utf8))) }
        for _ in 0..<100 where MessageRecoveryURLProtocol.bodies(path: path, includingEmpty: true).count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path, includingEmpty: true).count, 2)
        MessageRecoveryURLProtocol.releaseNewestHeld()
        await newer.value
        XCTAssertTrue(model.isAnnotationStale(file.id, chat: chat.id))
        MessageRecoveryURLProtocol.releaseHeld()
        await older.value
        XCTAssertTrue(model.isAnnotationStale(file.id, chat: chat.id),
                      "An older matching source must not clear the newer stale warning")
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/conversations/\(chat.id)/messages").isEmpty)
    }
    private func projectDetail(pinned: Bool, plan: Bool = false, unread: Bool = false) -> Data {
        Data(#"{"conversationId":"project-chat","projectId":"project","projectName":"Project","title":"Thread","family":"claude","model":"claude:sonnet","effort":"high","accessMode":"workspace","workingFolder":"/fixture","workingFolderName":"fixture","isPinned":\#(pinned),"hasUnread":\#(unread),"hasNativeSession":true,"folderInProject":true,"claudeApproval":"ask","planMode":\#(plan)}"#.utf8)
    }
    private func projectPage(pinned: Bool, unread: Bool = false) -> Data {
        Data(#"{"threads":[{"reference":"claude:fixture","conversationId":"project-chat","title":"Thread","family":"claude","updatedAt":1,"isPinned":\#(pinned),"hasUnread":\#(unread),"isWorking":false}],"nextCursor":null,"partial":[]}"#.utf8)
    }
    private func projectCatalog(pinned: Bool) -> Data {
        let pins = pinned ? #"[{"projectId":"project","thread":{"reference":"claude:fixture","conversationId":"project-chat","title":"Thread","family":"claude","updatedAt":1,"isPinned":true,"hasUnread":false,"isWorking":false}}]"# : "[]"
        return Data(#"{"projects":[{"id":"project","name":"Project","isIncluded":true,"isPinned":false,"rootsRevision":1,"folders":[],"createdAt":"fixture"}],"families":[{"family":"claude","available":true}],"modesVersion":1,"pinned":\#(pins)}"#.utf8)
    }

    @MainActor private func recoveryModel(root: URL) -> ConnectionModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MessageRecoveryURLProtocol.self]
        return ConnectionModel(cameraFixtureStoreRoot: root, saved: Self.cameraSavedConnection(),
            api: PairingAPI(configuration: configuration), replayEnabled: false)
    }

    @MainActor private func recoveryGroup(root: URL) throws -> (ConnectionModel, ChatSummary) {
        let group = try JSONDecoder().decode(GroupRead.self, from: Data(#"{"id":"group","conversationId":"recovery-chat","name":"Group","isArchived":false,"messages":[],"attachmentsSupported":true,"collaboration":{"configuration":{"instructions":"","routing":{"model":"","reasoningEffort":""},"workspace":"/fixture","needsPurpose":false},"runs":[]}}"#.utf8))
        let model = recoveryModel(root: root)
        model.groups[group.conversationId] = group
        model.chats = [group.summary]
        return (model, group.summary)
    }

    private func recoveryOptions() throws -> Data {
        let defaults = ModelDefaultPurpose.groupParticipation.load()
        return try JSONSerialization.data(withJSONObject: [
            "models": [["id": defaults.model.isEmpty ? "fixture-model" : defaults.model, "displayName": "Fixture", "hidden": false,
                "reasoningEfforts": [["id": defaults.reasoningEffort, "label": "Fixture"]],
                "serviceTiers": [["id": defaults.serviceTier ?? "default", "label": "Fixture"]]]],
            "approvalModes": [["id": defaults.approvalMode.rawValue, "allowed": true]],
            "allowedApprovalPolicies": []
        ])
    }

    private func recoveryQuestion() throws -> AsyncQuestion {
        try JSONDecoder().decode(AsyncQuestion.self, from: Data(#"{"id":"q","conversationId":"recovery-chat","turnId":"turn","itemId":"item","questions":[{"title":"Question?"}],"state":"pending","expiresAtMs":9999999999999}"#.utf8))
    }

    @MainActor func testSubagentSheetReadsExactChildAndRejectsDirectSend() async throws {
        DiagnosticSubagentFixture.resetTransport()
        let model = DiagnosticSubagentFixture.model()
        await model.loadChats(force: true)
        let parent = try XCTUnwrap(model.chats.first(where: { $0.id == DiagnosticSubagentFixture.parentID }))
        await model.open(parent)
        let child = try XCTUnwrap(model.subagents[parent.id]?.first)
        XCTAssertEqual(child.threadId, DiagnosticSubagentFixture.childThreadID)
        XCTAssertFalse(model.subagents[parent.id, default: []].contains { $0.threadId == DiagnosticSubagentFixture.ordinaryTaskThreadID })
        let unavailable = try XCTUnwrap(model.subagents[parent.id]?.first { $0.id == DiagnosticSubagentFixture.unavailableChildID })
        XCTAssertEqual(unavailable.canAcceptDirectInput, false)
        XCTAssertTrue(unavailable.isArchived)

        let childChat = child.chatSummary(botId: parent.botId)
        await model.open(childChat, root: parent)
        var intent = ComposerIntent()
        intent.draft = "Direct child message"
        model.composers[childChat.id] = intent
        await model.send(childChat)

        let paths = DiagnosticSubagentFixture.recordedPaths()
        XCTAssertTrue(paths.contains("/api/v1/conversations/\(DiagnosticSubagentFixture.childID)"))
        XCTAssertFalse(paths.contains("/api/v1/conversations/\(DiagnosticSubagentFixture.childID)/messages"))
        XCTAssertEqual(model.composers[childChat.id]?.draft, "Direct child message")
        XCTAssertFalse(model.canSend(childChat))
        XCTAssertFalse(model.canGuide(childChat))
        XCTAssertFalse(paths.contains("/api/v1/conversations/\(DiagnosticSubagentFixture.parentID)/messages"))
    }

    @MainActor func testSavedChildPendingIntentNeverResumesAfterOpeningOrRefresh() async throws {
        DiagnosticSubagentFixture.resetTransport()
        let model = DiagnosticSubagentFixture.model()
        await model.loadChats(force: true)
        let parent = try XCTUnwrap(model.chats.first(where: { $0.id == DiagnosticSubagentFixture.parentID }))
        await model.open(parent)
        let child = try XCTUnwrap(model.subagents[parent.id]?.first).chatSummary(botId: parent.botId)
        await model.open(child, root: parent, readOnly: true)
        model.editDraft("Saved child intent", chat: child.id)
        var intent = try XCTUnwrap(model.composers[child.id])
        try intent.begin(device: try XCTUnwrap(model.connection?.credential.deviceId))
        model.composers[child.id] = intent
        await model.open(parent)
        await model.open(child, root: parent, readOnly: true)
        await model.loadChats(force: true)
        await model.deliver(child)
        await model.stop(child)
        XCTAssertEqual(model.composers[child.id]?.pending?.request.body, "Saved child intent")
        XCTAssertTrue(DiagnosticSubagentFixture.recordedMessagePaths().isEmpty)
        XCTAssertFalse(DiagnosticSubagentFixture.recordedPaths().contains { $0.hasSuffix("/interrupt") })
        XCTAssertEqual(model.selectedChat?.id, parent.id)
    }

    @MainActor func testLargeImagePreviewIsDownsampledAndMalformedDataIsRejected() async throws {
        let data=try autoreleasepool {
            let format=UIGraphicsImageRendererFormat(); format.scale=1
            return try XCTUnwrap(UIGraphicsImageRenderer(size:CGSize(width:4000,height:3000),format:format).image { context in
                UIColor.systemBlue.setFill(); context.fill(CGRect(x:0,y:0,width:4000,height:3000))
            }.jpegData(compressionQuality: 0.5))
        }
        let decoded=await Task.detached { ToolPreviewImage.decode(data) }.value
        let image=try XCTUnwrap(decoded)
        XCTAssertEqual(image.size.width,1080); XCTAssertEqual(image.size.height,810)
        XCTAssertNil(ToolPreviewImage.decode(Data("invalid".utf8)))
    }

    @MainActor func testPhotoViewerRoutingDecodeBoundsOrientationAndDocumentSeparation() async throws {
        let data = try autoreleasepool {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format).image { context in
                UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
            }
            let output = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
            guard let cgImage = image.cgImage else { throw FileFailure.unsupported }
            CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyOrientation: 6] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return output as Data
        }

        let decodedImage = await Task.detached { PhotoViewerImage.decode(data) }.value
        let decoded = try XCTUnwrap(decodedImage)
        XCTAssertEqual(decoded.size.width, 3000, accuracy: 1)
        XCTAssertEqual(decoded.size.height, 4000, accuracy: 1)
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 4096)
        XCTAssertNil(PhotoViewerImage.decode(Data("malformed".utf8)))

        let imageFile = try Self.makeFile(id: "photo", name: "photo.png", mime: "image/png", data: Self.imageData())
        let documentFile = try Self.makeFile(id: "document", name: "notes.txt", mime: "text/plain", data: Data("notes".utf8))
        XCTAssertTrue(PhotoViewerRouting.isImage(imageFile))
        XCTAssertFalse(PhotoViewerRouting.isImage(documentFile))
        XCTAssertFalse(PhotoViewerRouting.isImage(mimeType: "application/pdf"))
    }

    @MainActor func testConversationAttachmentGalleryPreservesMessageOrderAndExcludesDocuments() throws {
        let first = try Self.makeFile(id: "first", name: "first.png", mime: "image/png", data: Self.imageData())
        let document = try Self.makeFile(id: "notes", name: "notes.txt", mime: "text/plain", data: Data("notes".utf8))
        let second = try Self.makeFile(id: "second", name: "second.png", mime: "image/png", data: Self.imageData())

        let gallery = ConversationAttachmentGallery.imageFiles(
            [first, document, second],
            attachmentIDs: ["second", "notes", "first"]
        )

        XCTAssertEqual(gallery.map(\.id), ["second", "first"])
        XCTAssertTrue(gallery.allSatisfy(PhotoViewerRouting.isImage))
        XCTAssertEqual(ConversationAttachmentGallery.imageFiles([first, document]).map(\.id), ["first"])
    }

    @MainActor func testWorkspaceBrowserFixturesKeepRootsViewsAndPreviewRoutesTyped() throws {
        let response = WorkspaceRootsResponse(
            available: true,
            detail: nil,
            roots: [WorkspaceRoot(id: "workspace", label: "Workspace", path: "/preview", isDirectory: true, kind: "workingDirectory", readOnly: true)],
            attachments: [try Self.makeFile(id: "photo", name: "photo.png", mime: "image/png", data: Self.imageData())]
        )
        let encoded = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(WorkspaceRootsResponse.self, from: encoded)
        XCTAssertEqual(decoded.roots.first?.kind, "workingDirectory")
        XCTAssertTrue(decoded.roots.first?.readOnly == true)

        let page = WorkspaceDirectoryPage(
            rootId: "workspace", path: "", parentPath: nil,
            entries: [WorkspaceEntry(name: "notes.txt", path: "notes.txt", isDirectory: false, byteSize: 5, mimeType: "text/plain")],
            nextOffset: 200
        )
        XCTAssertEqual(page.entries.first?.id, "notes.txt")
        XCTAssertEqual(page.nextOffset, 200)
        let change = WorkspaceGitChange(path: "notes.txt", originalPath: nil, state: "unstaged", indexStatus: " ", worktreeStatus: "M")
        XCTAssertEqual(change.id, "notes.txt:unstaged")
        XCTAssertTrue(PhotoViewerRouting.isImage(decoded.attachments[0]))
    }

    @MainActor func testWorkspaceEndpointEncodesConversationSegmentExactlyOnce() {
        let conversationID = "550e8400-e29b-41d4-a716-446655440000/child"
        let endpoint = ConnectionModel.workspaceEndpoint(conversationID: conversationID, operation: "git/diff")
        XCTAssertEqual(
            endpoint,
            "/api/v1/conversations/550e8400%2De29b%2D41d4%2Da716%2D446655440000%2Fchild/workspace/git/diff"
        )
        XCTAssertFalse(endpoint?.contains("%252D") == true)
        XCTAssertFalse(endpoint?.contains("%252F") == true)
    }

    private static func makeFile(id: String, name: String, mime: String, data: Data) throws -> ConversationFile {
        let value: [String: Any] = [
            "id": id, "name": name, "mimeType": mime, "byteSize": data.count,
            "sha256": ConversationFile.digest(data), "state": "available", "updatedAt": "test"
        ]
        return try JSONDecoder().decode(ConversationFile.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @MainActor func testCameraIgnoresDelayedSessionNotificationsAfterStop() {
        let camera = CameraCaptureController(fixture: .ready(data: Data(), preview: UIImage()))
        camera.start { _ in XCTFail("A stopped camera must not deliver a photo") }
        XCTAssertEqual(camera.state, .ready)
        camera.stop()
        camera.runtimeError()
        camera.retry()
        XCTAssertEqual(camera.state, .checking)
    }

    @MainActor func testCameraStageNormalizesOrientationAndSurvivesModelRestart() async throws {
        let input = try Self.orientedCameraImageData()
        let prepared = try await CameraPhotoPreparation.prepare(input)
        XCTAssertEqual(prepared.mimeType, "image/jpeg")
        guard let source = CGImageSourceCreateWithData(prepared.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return XCTFail("Prepared camera data was not readable")
        }
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 960)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 720)
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 1)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wonder-camera-restart-\(UUID().uuidString)", isDirectory: true)
        let saved = Self.cameraSavedConnection()
        let chat = try Self.cameraChat(id: "camera-restart")
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: saved, chat: chat)
        let scope = model.assignmentScope
        let result = await model.stageCameraPhoto(input, chat: chat, scope: scope)
        guard case .attached = result else { return XCTFail("Camera photo was not staged") }
        XCTAssertEqual(model.composers[chat.id]?.attachmentIDs.count, 1)
        XCTAssertNil(model.composers[chat.id]?.pending)

        let restarted = ConnectionModel(cameraFixtureStoreRoot: root, saved: saved, chat: chat)
        XCTAssertEqual(restarted.selectedChat?.id, chat.id)
        XCTAssertEqual(restarted.composers[chat.id]?.attachmentIDs, model.composers[chat.id]?.attachmentIDs)
        XCTAssertNil(restarted.composers[chat.id]?.pending)
    }

    @MainActor func testCameraStageIgnoresDifferentSelectedChatAndScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wonder-camera-context-\(UUID().uuidString)", isDirectory: true)
        let saved = Self.cameraSavedConnection()
        let chat = try Self.cameraChat(id: "camera-origin")
        let other = try Self.cameraChat(id: "camera-other")
        var initial = ComposerIntent()
        let existing = try StagedFile(id: "existing-camera", name: "Existing.jpg", mimeType: "image/jpeg", data: Self.cameraImageData())
        initial.stagedFiles = [existing]
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: saved, chat: chat, initialIntent: initial)
        let input = Self.cameraImageData()
        let scope = model.assignmentScope

        model.selectedChat = other
        let differentChat = await model.stageCameraPhoto(input, chat: chat, scope: scope)
        guard case .cancelled = differentChat else { return XCTFail("A changed selected chat accepted a stale capture") }
        XCTAssertEqual(model.composers[chat.id]?.attachmentIDs, ["existing-camera"])

        model.selectedChat = chat
        let differentScope = await model.stageCameraPhoto(input, chat: chat, scope: "other-host:other-device")
        guard case .cancelled = differentScope else { return XCTFail("A changed assignment scope accepted a stale capture") }
        XCTAssertEqual(model.composers[chat.id]?.attachmentIDs, ["existing-camera"])
        XCTAssertNil(model.composers[chat.id]?.pending)
    }

    @MainActor func testCameraStageRejectsFourthAttachmentWithoutChangingDurableDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wonder-camera-limit-\(UUID().uuidString)", isDirectory: true)
        let saved = Self.cameraSavedConnection()
        let chat = try Self.cameraChat(id: "camera-limit")
        var initial = ComposerIntent()
        initial.stagedFiles = try (0..<4).map { index in
            try StagedFile(id: "existing-camera-\(index)", name: "Existing \(index).jpg", mimeType: "image/jpeg", data: Self.cameraImageData())
        }
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: saved, chat: chat, initialIntent: initial)
        let result = await model.stageCameraPhoto(Self.cameraImageData(), chat: chat, scope: model.assignmentScope)
        guard case .cancelled = result else { return XCTFail("Camera accepted a fifth attachment") }
        XCTAssertEqual(model.composers[chat.id]?.attachmentCount, 4)
        XCTAssertEqual(model.composers[chat.id]?.attachmentIDs, initial.attachmentIDs)
        XCTAssertNil(model.composers[chat.id]?.pending)

        let restarted = ConnectionModel(cameraFixtureStoreRoot: root, saved: saved, chat: chat)
        XCTAssertEqual(restarted.composers[chat.id]?.attachmentIDs, initial.attachmentIDs)
        XCTAssertNil(restarted.composers[chat.id]?.pending)
    }

    @MainActor func testImagePastePreservesPNGTextAndExistingAttachmentsAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try Self.cameraChat(id: "paste")
        var initial = ComposerIntent(); initial.draft = "Keep this draft."
        initial.stagedFiles = [try StagedFile(name: "notes.txt", mimeType: "text/plain", data: Data("Notes".utf8))]
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: Self.cameraSavedConnection(), chat: chat, initialIntent: initial)
        let png = try XCTUnwrap(UIImage(data: Self.cameraImageData())?.pngData())
        let providers = [NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier),
                         NSItemProvider(item: Self.cameraImageData() as NSData, typeIdentifier: UTType.jpeg.identifier)]
        await model.stagePastedImages(providers, chat: chat, scope: model.assignmentScope)
        XCTAssertNil(model.controlErrors[chat.id])
        let restarted = ConnectionModel(cameraFixtureStoreRoot: root, saved: Self.cameraSavedConnection(), chat: chat)
        let intent = try XCTUnwrap(restarted.composers[chat.id])
        XCTAssertEqual(intent.draft, initial.draft)
        XCTAssertEqual(intent.stagedFiles?.map(\.mimeType), ["text/plain", "image/png", "image/jpeg"])
        XCTAssertEqual(intent.stagedFiles?[1].data, png)
        XCTAssertNil(intent.pending)
        XCTAssertTrue(intent.stagedFiles?.allSatisfy { $0.uploaded == nil } == true)
        restarted.removeStaged(intent.stagedFiles![1].id, chat: chat.id)
        XCTAssertEqual(restarted.composers[chat.id]?.attachmentCount, 2)
        XCTAssertEqual(restarted.composers[chat.id]?.draft, initial.draft)
    }

    @MainActor func testImagePasteRejectsInvalidOversizedAndExcessImagesAtomically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try Self.cameraChat(id: "paste-limits")
        var initial = ComposerIntent(); initial.draft = "Preserved"
        initial.stagedFiles = [try StagedFile(name: "notes.txt", mimeType: "text/plain", data: Data("Notes".utf8))]
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: Self.cameraSavedConnection(), chat: chat, initialIntent: initial)
        let valid = NSItemProvider(item: Self.cameraImageData() as NSData, typeIdentifier: UTType.jpeg.identifier)
        for providers in [
            [valid, NSItemProvider(item: Data("not an image".utf8) as NSData, typeIdentifier: UTType.png.identifier)],
            [NSItemProvider(item: Data(count: 8 * 1024 * 1024 + 1) as NSData, typeIdentifier: UTType.png.identifier)],
            [valid, valid, valid, valid]
        ] {
            await model.stagePastedImages(providers, chat: chat, scope: model.assignmentScope)
            XCTAssertEqual(model.composers[chat.id]?.attachmentIDs, initial.attachmentIDs)
            XCTAssertEqual(model.composers[chat.id]?.draft, initial.draft)
            XCTAssertNotNil(model.controlErrors[chat.id])
            XCTAssertFalse(model.loadingPhotos.contains(chat.id))
        }
    }

    @MainActor func testImagePasteIgnoresNavigationAndCancellationDuringProviderLoad() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try Self.cameraChat(id: "paste-delayed")
        let other = try Self.cameraChat(id: "other")
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: Self.cameraSavedConnection(), chat: chat)
        let data = Self.cameraImageData()
        for cancel in [false, true] {
            model.selectedChat = chat
            let started = expectation(description: "Provider began")
            let delivery = DelayedPasteDelivery()
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
                delivery.set(completion)
                started.fulfill()
                return nil
            }
            let task = Task { await model.stagePastedImages([provider], chat: chat, scope: model.assignmentScope) }
            await fulfillment(of: [started], timeout: 5)
            if cancel { task.cancel() } else { model.selectedChat = other }
            delivery.complete(data)
            await task.value
            XCTAssertEqual(model.composers[chat.id]?.attachmentCount, 0)
            XCTAssertNil(model.controlErrors[chat.id])
            XCTAssertFalse(model.loadingPhotos.contains(chat.id))
        }
    }

    @MainActor func testImagePasteUsesSystemActionAndLeavesSelectionAndTextUnchanged() async throws {
        let original = UIPasteboard.general.items
        defer { UIPasteboard.general.items = original }
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.text = "Keep selected text"; view.selectedRange = NSRange(location: 5, length: 8)
        view.canPasteImages = true
        var received = 0
        view.pasteImages = { received += $0.count }
        UIPasteboard.general.items = [[UTType.png.identifier: try XCTUnwrap(UIImage(data: Self.cameraImageData())?.pngData())]]
        XCTAssertTrue(view.canPerformAction(#selector(view.paste(_:)), withSender: nil))
        view.paste(nil)
        XCTAssertEqual(received, 1)
        XCTAssertEqual(view.text, "Keep selected text")
        XCTAssertEqual(view.selectedRange, NSRange(location: 5, length: 8))
        view.canPasteImages = false
        XCTAssertFalse(view.canPerformAction(#selector(view.paste(_:)), withSender: nil))
        view.paste(nil)
        XCTAssertEqual(received, 1)
        UIPasteboard.general.string = "ordinary"
        view.paste(nil)
        let textPasted = expectation(for: NSPredicate { _, _ in view.text == "Keep ordinary text" }, evaluatedWith: nil)
        await fulfillment(of: [textPasted], timeout: 3)

        // The iOS 27 keyboard paste suggestion delivers item providers instead of paste(_:).
        view.canPasteImages = true
        let image = NSItemProvider(item: try XCTUnwrap(UIImage(data: Self.cameraImageData())?.pngData()) as NSData,
                                   typeIdentifier: UTType.png.identifier)
        let supporting: UIPasteConfigurationSupporting = view
        XCTAssertEqual(supporting.canPaste?([image]), true)
        supporting.paste?(itemProviders: [image])
        let providerPasted = expectation(for: NSPredicate { _, _ in received == 2 }, evaluatedWith: nil)
        await fulfillment(of: [providerPasted], timeout: 3)
        XCTAssertEqual(view.text, "Keep ordinary text")
        view.canPasteImages = false
        XCTAssertEqual(supporting.canPaste?([image]), false)
    }

    @MainActor private static func cameraImageData() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 720, height: 960), format: format).jpegData(withCompressionQuality: 0.82) { context in
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 720, height: 960))
            UIColor.white.setFill(); context.fill(CGRect(x: 120, y: 170, width: 480, height: 620))
        }
    }

    @MainActor private static func orientedCameraImageData() throws -> Data {
        let image = try XCTUnwrap(UIImage(data: cameraImageData())?.cgImage)
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func cameraSavedConnection() -> SavedConnection {
        let value: [String: Any] = ["origin": "https://camera-unit.invalid", "credential": [
            "sessionToken": "camera-unit-session", "deviceId": "camera-unit-device", "csrfToken": "camera-unit-csrf",
            "hostInstallationId": "camera-unit-host"
        ]]
        return try! JSONDecoder().decode(SavedConnection.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private static func cameraChat(id: String) throws -> ChatSummary {
        let value: [String: Any] = ["conversationId": id, "botId": "camera-unit-bot", "title": id,
                                     "messageCount": 0, "hasUnread": false, "isArchived": false, "isPinned": false]
        return try JSONDecoder().decode(ChatSummary.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @MainActor func testBackgroundSuspendsDetailedCapture() {
        let recorder=Diagnostics.shared; let previous=recorder.recording
        recorder.recording=true; recorder.setActive(true); recorder.startCapture()
        XCTAssertTrue(recorder.capturing)
        recorder.setActive(false)
        XCTAssertFalse(recorder.capturing)
        recorder.startCapture()
        XCTAssertFalse(recorder.capturing)
        recorder.setActive(true); recorder.recording=previous
    }
    func testReportsStayAssignedToTheirSelectedMac() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal=DiagnosticJournal(root:root); let first=UUID().uuidString; let second=UUID().uuidString
        journal.selectHost(first); journal.record(DiagnosticEvent(operation:"capture",phase:"start"))
        journal.selectHost(second); journal.record(DiagnosticEvent(operation:"system.hang",durationMs:10))
        let a=await journal.pending(host:first); let b=await journal.pending(host:second)
        XCTAssertEqual(a.count,1); XCTAssertEqual(b.count,1)
        XCTAssertTrue(String(decoding:a[0].1,as:UTF8.self).contains("capture"))
        XCTAssertFalse(String(decoding:a[0].1,as:UTF8.self).contains("system.hang"))
    }
    func testJournalRetriesUntilAcknowledgedAndExportsSentBatches() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal=DiagnosticJournal(root:root); let host=UUID().uuidString
        journal.selectHost(host)
        journal.record(DiagnosticEvent(operation:"activity.expand",durationMs:10))
        let first=await journal.pending(host:host)
        XCTAssertEqual(first.count,1)
        let retry=await journal.pending(host:host)
        XCTAssertEqual(first.first?.1,retry.first?.1)
        journal.acknowledge(first[0].0)
        let pending=await journal.pending(host:host); XCTAssertTrue(pending.isEmpty)
        let exported=try await journal.export()
        let values=try JSONSerialization.jsonObject(with:Data(contentsOf:exported)) as? [[String:Any]]
        XCTAssertEqual(values?.count,1)
        XCTAssertFalse(String(data:try Data(contentsOf:exported),encoding:.utf8)!.contains(host))
    }
    func testRetentionAndStorageBudget() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host=UUID().uuidString
        let journal=DiagnosticJournal(root:root,maximumBytes:1024,retention:10)
        journal.selectHost(host)
        journal.record(DiagnosticEvent(operation:"history.load",durationMs:1))
        let initial=await journal.pending(host:host)
        XCTAssertFalse(initial.isEmpty)
        try FileManager.default.setAttributes([.modificationDate:Date.distantPast],ofItemAtPath:initial[0].0.path)
        let expired=await journal.pending(host:host)
        XCTAssertTrue(expired.isEmpty)
        for _ in 0..<3 {
            journal.record(DiagnosticEvent(operation:"activity.expand",durationMs:1))
            _=await journal.pending(host:host)
        }
        let retained=await journal.pending(host:host)
        XCTAssertLessThanOrEqual(retained.reduce(0) { $0+$1.1.count },1024)
    }

    @MainActor func testComputerControlGeometryUsesAspectFitAndZoomWithoutLeakingOutOfBounds() {
        let session = ComputerSession(
            id: "session", clientRequestId: "request", ownerDeviceId: "phone", hostInstallationId: "mac",
            conversationId: "chat", generation: 2, state: .live,
            source: ComputerSource(id: "display:1", name: "Main display", kind: "display", width: 1920, height: 1080, scale: 2),
            geometryRevision: 3, failureReason: nil, createdAt: "now", updatedAt: "now", lastStateAt: "now",
            endedAt: nil, capability: ComputerCapability(available: true, action: "none", reason: "Live"),
            control: ComputerControlCapability(available: true, action: "none", reason: "Active")
        )

        XCTAssertEqual(ComputerSessionModel.sourceAspectRatio(session), 16.0 / 9.0, accuracy: 0.001)
        let center = ComputerSessionModel.normalizedPoint(
            location: CGPoint(x: 200, y: 100), in: CGSize(width: 400, height: 200), session: session, zoomScale: 1
        )
        XCTAssertEqual(center?.x ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(center?.y ?? -1, 0.5, accuracy: 0.001)

        let letterbox = ComputerSessionModel.normalizedPoint(
            location: CGPoint(x: 0, y: 100), in: CGSize(width: 400, height: 200), session: session, zoomScale: 1
        )
        XCTAssertNil(letterbox)

        let zoomed = ComputerSessionModel.normalizedPoint(
            location: CGPoint(x: 200, y: 100), in: CGSize(width: 400, height: 200), session: session, zoomScale: 2
        )
        XCTAssertEqual(zoomed?.x ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(zoomed?.y ?? -1, 0.5, accuracy: 0.001)
        let clamped = ComputerSessionModel.normalizedPoint(
            location: CGPoint(x: -20, y: 100),
            in: CGSize(width: 400, height: 200),
            session: session,
            zoomScale: 1,
            clampToContent: true
        )
        XCTAssertEqual(clamped?.x ?? -1, 0, accuracy: 0.001)
        XCTAssertTrue([ComputerControlState.viewOnly, .starting, .active].map(\.title).contains("Starting control…"))
    }

    func testComputerAppSwitcherHoldsCommandUntilSelectionOrCancellation() {
        var switcher = ComputerAppSwitcher()
        let open: [ComputerInputAction] = [.key(key: "command", phase: "down", modifiers: 8),
                                           .key(key: "tab", phase: "press", modifiers: 8)]
        let release: [ComputerInputAction] = [.key(key: "command", phase: "up", modifiers: 0)]
        XCTAssertEqual(switcher.toggle(), open)
        XCTAssertTrue(switcher.isPresented)
        XCTAssertEqual(switcher.key("tab"), [.key(key: "tab", phase: "press", modifiers: 8)])
        XCTAssertTrue(switcher.isPresented)
        XCTAssertEqual(switcher.key("left"), [.key(key: "left", phase: "press", modifiers: 8)])
        XCTAssertEqual(switcher.toggle(), release)
        XCTAssertFalse(switcher.isPresented)
        XCTAssertTrue(switcher.finish().isEmpty)
        XCTAssertEqual(switcher.toggle(), open)
        XCTAssertEqual(switcher.key("escape"), [.key(key: "escape", phase: "press", modifiers: 8)] + release)
        XCTAssertFalse(switcher.isPresented)
        XCTAssertEqual(switcher.toggle(), open)
        XCTAssertEqual(switcher.key("delete"), [.key(key: "escape", phase: "press", modifiers: 8)] + release
                       + [.key(key: "delete", phase: "press", modifiers: 0)])
        XCTAssertFalse(switcher.isPresented)
        XCTAssertEqual(switcher.toggle(), open)
        XCTAssertEqual(switcher.key("return"), release)
        XCTAssertFalse(switcher.isPresented)
    }

    @MainActor func testComputerKeyboardCommitsCompositionWithoutDuplicatingMarkedText() {
        var input = ComputerKeyboardComposition()
        XCTAssertEqual(input.update("ni", hasMarkedText: true), [])
        XCTAssertEqual(input.update("你", hasMarkedText: true), [])
        XCTAssertEqual(input.update("你", hasMarkedText: false), [.text("你")])
        XCTAssertEqual(input.update("你", hasMarkedText: false), [])
        XCTAssertEqual(input.update("你好", hasMarkedText: false), [.text("好")])
        XCTAssertEqual(input.update("你", hasMarkedText: false), [.key(key: "delete", phase: "press", modifiers: 0)])
        input.reset()
        XCTAssertEqual(input.update("👨‍👩‍👧‍👦", hasMarkedText: false), [.text("👨‍👩‍👧‍👦")])
        XCTAssertEqual(input.update("", hasMarkedText: false), [.key(key: "delete", phase: "press", modifiers: 0)])
    }

    @MainActor func testComputerKeyboardReturnAndTabAreKeysAndContextIsBounded() {
        var input = ComputerKeyboardComposition()
        XCTAssertEqual(input.update("hello\n\t", hasMarkedText: false), [
            .text("hello"), .key(key: "return", phase: "press", modifiers: 0),
            .key(key: "tab", phase: "press", modifiers: 0)
        ])
        input.reset()
        XCTAssertEqual(input.update(String(repeating: "a", count: 200), hasMarkedText: false), [.text(String(repeating: "a", count: 200))])
        XCTAssertEqual(input.committed.count, 128)
        XCTAssertEqual(input.update(input.committed + "b", hasMarkedText: false), [.text("b")])
        let combining = String(repeating: "e\u{301}", count: 2_100)
        input.reset()
        let chunks = input.update(combining, hasMarkedText: false)
        XCTAssertTrue(chunks.allSatisfy { if case .text(let value) = $0 { return value.unicodeScalars.count <= 4_096 }; return false })
        XCTAssertEqual(chunks.compactMap { if case .text(let value) = $0 { return value }; return nil }.joined(), combining)
    }

    @MainActor func testComputerInputBufferCoalescesMotionWithoutCrossingClicksOrDragBoundaries() {
        var buffer = ComputerInputBuffer()
        XCTAssertTrue(buffer.append([.pointer(x: 0.1, y: 0.2, phase: "move", button: nil)]))
        XCTAssertTrue(buffer.append([.pointer(x: 0.2, y: 0.3, phase: "move", button: nil)]))
        XCTAssertTrue(buffer.append([.pointer(x: 0.2, y: 0.3, phase: "down", button: "left")]))
        XCTAssertTrue(buffer.append([.pointer(x: 0.3, y: 0.4, phase: "move", button: "left")]))
        XCTAssertTrue(buffer.append([.pointer(x: 0.4, y: 0.5, phase: "move", button: "left")]))
        XCTAssertTrue(buffer.append([.pointer(x: 0.4, y: 0.5, phase: "up", button: "left")]))
        XCTAssertEqual(buffer.popFirst(), [.pointer(x: 0.2, y: 0.3, phase: "move", button: nil)])
        XCTAssertEqual(buffer.popFirst(), [.pointer(x: 0.2, y: 0.3, phase: "down", button: "left")])
        XCTAssertEqual(buffer.popFirst(), [.pointer(x: 0.4, y: 0.5, phase: "move", button: "left")])
        XCTAssertEqual(buffer.popFirst(), [.pointer(x: 0.4, y: 0.5, phase: "up", button: "left")])
        XCTAssertNil(buffer.popFirst())
        XCTAssertTrue(buffer.append([.text("hello")]))
        XCTAssertTrue(buffer.append([.text(" world")]))
        XCTAssertTrue(buffer.append([.key(key: "return", phase: "press", modifiers: 0)]))
        XCTAssertTrue(buffer.append([.text("next line")]))
        XCTAssertEqual(buffer.popFirst(), [.text("hello world")])
        XCTAssertEqual(buffer.popFirst(), [.key(key: "return", phase: "press", modifiers: 0)])
        XCTAssertEqual(buffer.popFirst(), [.text("next line")])
    }

    @MainActor func testComputerInputBufferRefusesOverflowAndClearsAllPendingWork() {
        var buffer = ComputerInputBuffer()
        for _ in 0..<64 { XCTAssertTrue(buffer.append([.key(key: "delete", phase: "press", modifiers: 0)])) }
        XCTAssertFalse(buffer.append([.text("must not disappear silently")]))
        XCTAssertEqual(buffer.batches.count, 64)
        buffer.removeAll()
        XCTAssertNil(buffer.popFirst())
        XCTAssertTrue(buffer.append([.text("new lease")]))
        XCTAssertEqual(buffer.popFirst(), [.text("new lease")])
    }

    @MainActor func testComputerViewportHitTestsLetterboxWithinTheWholeAvailableArea() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        let connection = ConnectionModel(saved: nil, persistConnection: { _ in })
        let model = ComputerSessionModel(model: connection, chat: DiagnosticSubagentFixture.parentChat())
        let host = UIHostingController(rootView: ComputerViewport(model: model).frame(width: 1, height: 1))
        window.rootViewController = host
        window.makeKeyAndVisible()
        let width = min(400, window.bounds.width)
        let wideWidth = min(600, window.bounds.width)
        let sizes = [CGSize(width: width, height: min(600, window.bounds.height)),
                     CGSize(width: wideWidth, height: wideWidth / 2.4),
                     CGSize(width: width, height: min(240, window.bounds.height))]
        var hitEvidence: [String] = []
        func inputView(in view: UIView) -> ComputerGestureSurface.InputView? {
            if let input = view as? ComputerGestureSurface.InputView { return input }
            return view.subviews.lazy.compactMap { inputView(in: $0) }.first
        }
        for size in sizes {
            host.rootView = ComputerViewport(model: model).frame(width: size.width, height: size.height)
            host.view.layoutIfNeeded()
            for _ in 0..<50 {
                if let input = inputView(in: host.view), input.bounds.size == size { break }
                try await Task.sleep(for: .milliseconds(10))
                host.view.layoutIfNeeded()
            }
            let input = try XCTUnwrap(inputView(in: host.view))
            XCTAssertEqual(input.bounds.width, size.width, accuracy: 1)
            XCTAssertEqual(input.bounds.height, size.height, accuracy: 1)
            let transform = model.viewportTransform(in: size)
            let points = transform.content.minY > 0
                ? [CGPoint(x: size.width / 2, y: transform.content.minY / 2),
                   CGPoint(x: size.width / 2, y: (transform.content.maxY + size.height) / 2)]
                : [CGPoint(x: transform.content.minX / 2, y: size.height / 2),
                   CGPoint(x: (transform.content.maxX + size.width) / 2, y: size.height / 2)]
            for point in points {
                XCTAssertNil(transform.point(point), "Direct touch must keep rejecting the letterbox.")
                let hostedPoint = input.convert(point, to: host.view)
                let hit = host.view.hitTest(hostedPoint, with: nil)
                hitEvidence.append("Viewport: \(size), point: \(hostedPoint), host: \(host.view.bounds), hit: \(String(describing: hit.map { type(of: $0) }))")
                XCTAssertTrue(host.view.bounds.contains(hostedPoint), "The hosted fixture point must be on screen.")
                XCTAssertTrue(hit === input,
                              "The black letterbox must deliver gestures to the trackpad surface. \(hitEvidence.last ?? "")")
            }
            let moved = transform.moving(CGPoint(x: 0.5, y: 0.5), by: CGSize(width: 40, height: -20))
            XCTAssertEqual(moved.x, 0.5 + 40 / transform.content.width, accuracy: 0.001)
            XCTAssertEqual(moved.y, 0.5 - 20 / transform.content.height, accuracy: 0.001)
        }
        let evidence = XCTAttachment(string: hitEvidence.joined(separator: "\n"))
        evidence.name = "Computer letterbox hit-test geometry"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor func testComputerViewportPanAndKeyboardResizeUseOneTransform() {
        let large = ComputerViewportTransform(size: CGSize(width: 400, height: 225), aspect: 16 / 9, zoom: 2,
                                             center: CGPoint(x: 0.65, y: 0.4))
        XCTAssertEqual(large.point(CGPoint(x: 200, y: 112.5))?.x ?? -1, 0.65, accuracy: 0.001)
        XCTAssertEqual(large.point(CGPoint(x: 200, y: 112.5))?.y ?? -1, 0.4, accuracy: 0.001)
        let small = ComputerViewportTransform(size: CGSize(width: 200, height: 112.5), aspect: 16 / 9, zoom: 2,
                                             center: large.center)
        XCTAssertEqual(small.point(CGPoint(x: 100, y: 56.25))?.x ?? -1, 0.65, accuracy: 0.001)
        let moved = small.moving(CGPoint(x: 0.5, y: 0.5), by: CGSize(width: 40, height: -22.5))
        XCTAssertEqual(moved.x, 0.6, accuracy: 0.001)
        XCTAssertEqual(moved.y, 0.4, accuracy: 0.001)
        XCTAssertEqual(small.moving(moved, by: CGSize(width: 10_000, height: -10_000)), CGPoint(x: 1, y: 0))
        let panned = ComputerViewportTransform(size: small.size, aspect: 16 / 9, zoom: 2,
                                              center: small.panning(by: CGSize(width: 10_000, height: -10_000)))
        XCTAssertEqual(panned.center, CGPoint(x: 0.25, y: 0.75))
    }

    @MainActor func testComputerEncodedPaddingAndPhonePointerShareSourceGeometry() {
        // The host centers a 16:10 source inside its fixed 16:9 encoded frame.
        let fit = ComputerViewportTransform(size: CGSize(width: 420, height: 262.5), aspect: 1.6, zoom: 1)
        let video = fit.videoFrame(encodedAspect: 16.0 / 9.0)
        XCTAssertEqual(video.width, 466.6667, accuracy: 0.001)
        XCTAssertEqual(video.minX, -23.3333, accuracy: 0.001)
        XCTAssertEqual(video.height, 262.5, accuracy: 0.001)
        XCTAssertEqual(fit.content.width, 420, accuracy: 0.001)
        for transform in [fit,
            ComputerViewportTransform(size: CGSize(width: 420, height: 262.5), aspect: 1.6, zoom: 2, center: CGPoint(x: 0.65, y: 0.4)),
            ComputerViewportTransform(size: CGSize(width: 320, height: 200), aspect: 1.6, zoom: 2, center: CGPoint(x: 0.65, y: 0.4))] {
            let point = CGPoint(x: 0.6, y: 0.45)
            let location = transform.location(for: point)
            XCTAssertEqual(transform.point(location)?.x ?? -1, point.x, accuracy: 0.001)
            XCTAssertEqual(transform.point(location)?.y ?? -1, point.y, accuracy: 0.001)
            let frame = transform.videoFrame(encodedAspect: 16.0 / 9.0)
            XCTAssertEqual(frame.midX, transform.content.midX, accuracy: 0.001)
            XCTAssertEqual(frame.midY, transform.content.midY, accuracy: 0.001)
            XCTAssertEqual(frame.height, transform.content.height, accuracy: 0.001)
        }
        let wide = ComputerViewportTransform(size: CGSize(width: 420, height: 180), aspect: 21.0 / 9.0, zoom: 1)
        XCTAssertEqual(wide.videoFrame(encodedAspect: 16.0 / 9.0).width, 420, accuracy: 0.001)
        XCTAssertEqual(wide.videoFrame(encodedAspect: 16.0 / 9.0).height, 236.25, accuracy: 0.001)
    }

    @MainActor func testComputerPointerModeDefaultsToTrackpadAndRemembersSelection() throws {
        let suite = "computer-mode-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let chat = try JSONDecoder().decode(ChatSummary.self, from: Data(#"{"conversationId":"fixture-chat","botId":"fixture-bot","title":"Computer fixture","messageCount":0,"hasUnread":false,"isArchived":false,"isPinned":false}"#.utf8))
        let connection = ConnectionModel(saved: nil, persistConnection: { _ in })
        let first = ComputerSessionModel(model: connection, chat: chat, inputPreferences: preferences)
        XCTAssertEqual(first.inputMode, .trackpad)
        XCTAssertFalse(first.isControlActive)
        first.toggleKeyboard()
        XCTAssertFalse(first.keyboardPresented)
        first.recenterPointer()
        XCTAssertNil(first.controlLease)
        first.inputMode = .directTouch
        let size = CGSize(width: 400, height: 600)
        first.dragBegan(at: CGPoint(x: 200, y: 10), in: size)
        first.dragMoved(to: CGPoint(x: 300, y: 300), in: size)
        first.dragEnded(at: CGPoint(x: 300, y: 590), in: size)
        XCTAssertEqual(first.pointerState.position, CGPoint(x: 0.5, y: 0.5),
                       "A rejected direct-touch drag must not move the pointer when it ends.")
        let second = ComputerSessionModel(model: connection, chat: chat, inputPreferences: preferences)
        XCTAssertEqual(second.inputMode, .directTouch)
    }

    @MainActor func testClosedComputerSessionCannotRestartOrPresentInput() async throws {
        let chat = try JSONDecoder().decode(ChatSummary.self, from: Data(#"{"conversationId":"closed-fixture","botId":"fixture-bot","title":"Closed fixture","messageCount":0,"hasUnread":false,"isArchived":false,"isPinned":false}"#.utf8))
        let connection = ConnectionModel(saved: nil, persistConnection: { _ in })
        let computer = ComputerSessionModel(model: connection, chat: chat)
        await computer.close()
        await computer.start()
        await computer.retry()
        computer.toggleKeyboard()
        XCTAssertTrue(computer.isClosed)
        XCTAssertEqual(computer.receiverState, .closed)
        XCTAssertFalse(computer.isLoading)
        XCTAssertNil(computer.session)
        XCTAssertFalse(computer.keyboardPresented)
        XCTAssertFalse(computer.controlAvailable)
    }

    @MainActor func testComputerControlLeaseReconciliationNeverRollsSequenceBackward() {
        func lease(id: String = "lease", sequence: UInt64) -> ComputerControlLease {
            ComputerControlLease(
                id: id, sessionId: "session", ownerDeviceId: "phone", hostInstallationId: "mac",
                conversationId: "chat", generation: 1, sourceId: "display:1", geometryRevision: 1,
                status: "active", lastSequence: sequence, acquiredAt: "a", updatedAt: "u",
                expiresAt: "e", releasedAt: nil
            )
        }

        let reconciled = ComputerSessionModel.reconciledLease(
            current: lease(sequence: 7),
            refreshed: lease(sequence: 6)
        )
        XCTAssertEqual(reconciled?.lastSequence, 7)
        XCTAssertNil(ComputerSessionModel.reconciledLease(
            current: lease(sequence: 7),
            refreshed: lease(id: "other", sequence: 8)
        ))
    }
}

/// NSItemProvider calls its loader on an arbitrary queue. Synchronize the
/// test-controlled delivery instead of sharing a mutable closure across actors.
private final class DelayedPasteDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Data?, Error?) -> Void)?
    func set(_ value: @escaping (Data?, Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        completion = value
    }
    func complete(_ data: Data) {
        lock.lock()
        let value = completion; completion = nil
        lock.unlock()
        value?(data, nil)
    }
}

private actor ImageLoadProbe {
    let data: Data
    let delay: Duration
    private(set) var calls = 0
    private(set) var maximumActive = 0
    private var active = 0
    init(data: Data, delay: Duration = .milliseconds(20)) { self.data = data; self.delay = delay }
    func load() async throws -> Data {
        calls += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        return data
    }
}

extension WonderDiagnosticsTests {
    @MainActor func testApprovalSelectionIsImmediateAndSurvivesNavigationUntilConfirmed() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); MessageRecoveryURLProtocol.releaseHeld() }
        let (model, chat, target) = try approvalFixture(root: root)
        let path = "/api/v1/bots/\(target.botID)"
        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(approvalBot(.fullAccess)))
        MessageRecoveryURLProtocol.hold(path: path)
        XCTAssertTrue(model.canSend(chat))
        XCTAssertTrue(model.canGuide(chat))

        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        let saving = try XCTUnwrap(model.composerApprovalTasks[target])
        XCTAssertEqual(model.approvalChange(target)?.desired, .fullAccess)
        XCTAssertEqual(model.approvalChange(target)?.saving, true)
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.askForApproval.rawValue)
        XCTAssertFalse(model.canSend(chat))
        XCTAssertFalse(model.canGuide(chat))
        await model.send(chat)
        await model.guide(chat)
        XCTAssertNil(model.composers[chat.id]?.pending, "Execution must wait for the server-confirmed permission")
        XCTAssertTrue(model.savingComposerSettings.isEmpty, "Permission saving must not trigger the model settings spinner")
        try await waitForRecoveryRequests(path: path)

        model.dismissConversation(chat)
        model.presentConversation(try Self.cameraChat(id: "other-chat"))
        model.presentConversation(chat)
        XCTAssertEqual(model.approvalChange(target)?.desired, .fullAccess)
        // A stale source refresh must leave the pending presentation intact.
        model.managedBots = [try approvalBot(.askForApproval)]
        XCTAssertEqual(model.approvalChange(target)?.desired, .fullAccess)
        XCTAssertFalse(model.canSend(chat))

        MessageRecoveryURLProtocol.releaseHeld()
        await saving.value
        XCTAssertNil(model.approvalChange(target))
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.fullAccess.rawValue)
        XCTAssertTrue(model.canSend(chat))
        XCTAssertTrue(model.canGuide(chat))
    }

    @MainActor func testApprovalRapidSelectionsSerializeAndCoalesceToLatestChoice() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); MessageRecoveryURLProtocol.releaseHeld() }
        let (model, chat, target) = try approvalFixture(root: root)
        let path = "/api/v1/bots/\(target.botID)"
        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(approvalBot(.fullAccess)))
        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(approvalBot(.approveForMe)))
        MessageRecoveryURLProtocol.hold(path: path)
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        let saving = try XCTUnwrap(model.composerApprovalTasks[target])
        try await waitForRecoveryRequests(path: path)

        model.setApprovalMode(.askForApproval, target: target, chat: chat)
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        model.setApprovalMode(.approveForMe, target: target, chat: chat)
        XCTAssertEqual(model.approvalChange(target)?.desired, .approveForMe)
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path).count, 1)
        MessageRecoveryURLProtocol.releaseHeld()
        await saving.value

        let writes = try MessageRecoveryURLProtocol.bodies(path: path).map {
            try JSONDecoder().decode([String: String].self, from: $0)
        }
        XCTAssertEqual(writes.map { $0["approvalMode"] }, ["full-access", "approve-for-me"])
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.approveForMe.rawValue)
        XCTAssertNil(model.approvalChange(target))
        XCTAssertTrue(model.canSend(chat))
    }

    @MainActor func testApprovalFailureReadsBackConfirmedStateAndKeepsRetryIntent() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat, target) = try approvalFixture(root: root)
        let path = "/api/v1/bots/\(target.botID)"
        MessageRecoveryURLProtocol.enqueue(path: path, status: 503)
        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(approvalBot(.askForApproval)))
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value

        let failure = try XCTUnwrap(model.approvalChange(target))
        XCTAssertFalse(failure.saving)
        XCTAssertTrue(failure.reconciled)
        XCTAssertNotNil(failure.failure)
        XCTAssertEqual(failure.desired, .fullAccess)
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.askForApproval.rawValue)
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path, includingEmpty: true).count, 2)
        XCTAssertTrue(model.canSend(chat), "Successful readback restores a known execution policy")

        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(approvalBot(.fullAccess)))
        model.setApprovalMode(failure.desired, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.fullAccess.rawValue)
        XCTAssertNil(model.approvalChange(target))
    }

    @MainActor func testApprovalTimeoutWithConfirmedDesiredReadbackCompletesWithoutError() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat, target) = try approvalFixture(root: root)
        let path = "/api/v1/bots/\(target.botID)"
        MessageRecoveryURLProtocol.fail(path: path, error: .timedOut)
        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(approvalBot(.fullAccess)))

        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value

        XCTAssertNil(model.approvalChange(target), "A lost write response is successful when the server confirms the intended mode")
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.fullAccess.rawValue)
        XCTAssertTrue(model.canSend(chat))
        XCTAssertTrue(model.canGuide(chat))
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path).count, 1, "Authoritative readback must avoid a redundant write retry")
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path, includingEmpty: true).count, 2)
    }

    @MainActor func testApprovalAmbiguousFailureBlocksSendAndGuideUntilRetryConfirmsState() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat, target) = try approvalFixture(root: root)
        let path = "/api/v1/bots/\(target.botID)"
        MessageRecoveryURLProtocol.fail(path: path, error: .timedOut)
        MessageRecoveryURLProtocol.fail(path: path, error: .notConnectedToInternet)
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value

        let failure = try XCTUnwrap(model.approvalChange(target))
        XCTAssertFalse(failure.saving)
        XCTAssertFalse(failure.reconciled)
        XCTAssertNotNil(failure.failure)
        XCTAssertFalse(model.canSend(chat))
        XCTAssertFalse(model.canGuide(chat))
        await model.send(chat)
        await model.guide(chat)
        XCTAssertNil(model.composers[chat.id]?.pending)
        XCTAssertEqual(model.composers[chat.id]?.draft, "Keep this draft")

        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(approvalBot(.fullAccess)))
        model.setApprovalMode(failure.desired, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value
        XCTAssertNil(model.approvalChange(target))
        XCTAssertTrue(model.canSend(chat))
        XCTAssertTrue(model.canGuide(chat))
    }

    @MainActor func testApprovalChangeDuringDelayedUploadPreventsSendFromBeginning() async throws {
        try await assertApprovalChangeDuringDelayedUploadPreventsExecution(guide: false)
    }

    @MainActor func testApprovalChangeDuringDelayedUploadPreventsGuideFromBeginning() async throws {
        try await assertApprovalChangeDuringDelayedUploadPreventsExecution(guide: true)
    }

    @MainActor private func assertApprovalChangeDuringDelayedUploadPreventsExecution(guide: Bool) async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); MessageRecoveryURLProtocol.releaseHeld() }
        let (model, chat, target) = try approvalFixture(root: root)
        let file = try StagedFile(id: "approval-file", name: "Notes.txt", mimeType: "text/plain", data: Data("Retain this attachment".utf8))
        var draft = try XCTUnwrap(model.composers[chat.id])
        draft.stagedFiles = [file]
        model.composers[chat.id] = draft
        let uploadPath = "/api/v1/conversations/\(chat.id)/files"
        let uploaded: [String: Any] = ["id": "uploaded-approval-file", "name": file.name, "mimeType": file.mimeType,
            "byteSize": file.data.count, "sha256": ConversationFile.digest(file.data), "state": "available", "updatedAt": "2026-09-20T00:00:00Z"]
        MessageRecoveryURLProtocol.enqueue(path: uploadPath, body: try JSONSerialization.data(withJSONObject: uploaded))
        MessageRecoveryURLProtocol.hold(path: uploadPath)
        XCTAssertTrue(guide ? model.canGuide(chat) : model.canSend(chat))
        let execution = Task { @MainActor in
            if guide { await model.guide(chat) } else { await model.send(chat) }
        }
        try await waitForRecoveryRequests(path: uploadPath)
        XCTAssertTrue(model.uploading.contains(chat.id))

        // The selection happens after Send/Guide passed its initial guard,
        // while attachment upload is suspended. An unknown save result must
        // remain a fence when that earlier action resumes.
        let settingsPath = "/api/v1/bots/\(target.botID)"
        MessageRecoveryURLProtocol.fail(path: settingsPath, error: .timedOut)
        MessageRecoveryURLProtocol.fail(path: settingsPath, error: .notConnectedToInternet)
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value
        XCTAssertEqual(model.approvalChange(target)?.reconciled, false)
        XCTAssertTrue(model.approvalSettingsBlockSending(chat.id))
        MessageRecoveryURLProtocol.releaseHeld()
        await execution.value

        XCTAssertNil(model.composers[chat.id]?.pending)
        XCTAssertEqual(model.composers[chat.id]?.draft, "Keep this draft")
        XCTAssertEqual(model.composers[chat.id]?.stagedFiles?.first?.uploaded?.id, "uploaded-approval-file")
        XCTAssertEqual(model.composers[chat.id]?.stagedFiles?.first?.data, file.data)
        XCTAssertFalse(model.uploading.contains(chat.id))
        XCTAssertFalse(model.preparingSends.contains(chat.id))
        XCTAssertNil(model.controlErrors[chat.id])
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/conversations/\(chat.id)/messages").isEmpty)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/conversations/\(chat.id)/turns/active-turn/steer").isEmpty)
    }

    @MainActor func testApprovalHostChangeCancelsPendingSaveAndIgnoresOldResponse() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); MessageRecoveryURLProtocol.releaseHeld() }
        let (model, chat, target) = try approvalFixture(root: root)
        let path = "/api/v1/bots/\(target.botID)"
        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(approvalBot(.fullAccess)))
        MessageRecoveryURLProtocol.hold(path: path)
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        let saving = try XCTUnwrap(model.composerApprovalTasks[target])
        try await waitForRecoveryRequests(path: path)

        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.cameraSavedConnection())) as? [String: Any])
        var credential = try XCTUnwrap(fields["credential"] as? [String: Any])
        credential["hostInstallationId"] = "another-unit-host"
        fields["credential"] = credential
        model.connection = try JSONDecoder().decode(SavedConnection.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertTrue(model.composerApprovalChanges.isEmpty)
        XCTAssertTrue(model.composerApprovalTasks.isEmpty)
        MessageRecoveryURLProtocol.releaseHeld()
        await saving.value
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.askForApproval.rawValue)
        XCTAssertTrue(model.composerApprovalChanges.isEmpty)
    }

    @MainActor func testQueuedApprovalConflictReloadsRevisionAndRetryUsesLatestRevision() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat, directTarget) = try approvalFixture(root: root)
        let target = ComposerApprovalTarget(conversationID: chat.id, botID: directTarget.botID, queuedMessageID: "queued")
        let queuePath = "/api/v1/conversations/\(chat.id)/queue", writePath = queuePath + "/queued"
        model.queues[chat.id] = [try approvalQueuedMessage(revision: 1, mode: .askForApproval)]
        MessageRecoveryURLProtocol.enqueue(path: writePath, status: 409)
        MessageRecoveryURLProtocol.enqueue(path: queuePath, body: try JSONEncoder().encode([approvalQueuedMessage(revision: 2, mode: .approveForMe)]))
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value
        XCTAssertEqual(model.queues[chat.id]?.first?.revision, 2)
        XCTAssertEqual(model.queues[chat.id]?.first?.executionSettings?.approvalMode, BotApprovalMode.approveForMe.rawValue)
        XCTAssertEqual(model.approvalChange(target)?.reconciled, true)
        XCTAssertNotNil(model.approvalChange(target)?.failure)

        MessageRecoveryURLProtocol.enqueue(path: writePath)
        MessageRecoveryURLProtocol.enqueue(path: queuePath, body: try JSONEncoder().encode([approvalQueuedMessage(revision: 3, mode: .fullAccess)]))
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value
        let writes = try MessageRecoveryURLProtocol.bodies(path: writePath).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        XCTAssertEqual(writes.compactMap { $0["expectedRevision"] as? Int }, [1, 2])
        XCTAssertEqual(writes.compactMap { ($0["settings"] as? [String: String])?["approvalMode"] }, ["full-access", "full-access"])
        XCTAssertEqual(model.queues[chat.id]?.first?.revision, 3)
        XCTAssertEqual(model.queues[chat.id]?.first?.executionSettings?.approvalMode, BotApprovalMode.fullAccess.rawValue)
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.askForApproval.rawValue, "Queued settings must not change the Bot defaults")
        XCTAssertNil(model.approvalChange(target))
    }

    @MainActor func testQueuedApprovalAmbiguousFailureClearsFenceWhenMessageDisappears() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat, directTarget) = try approvalFixture(root: root)
        let target = ComposerApprovalTarget(conversationID: chat.id, botID: directTarget.botID, queuedMessageID: "queued")
        let queuePath = "/api/v1/conversations/\(chat.id)/queue"
        model.queues[chat.id] = [try approvalQueuedMessage(revision: 1, mode: .askForApproval)]
        MessageRecoveryURLProtocol.fail(path: queuePath + "/queued", error: .timedOut)
        MessageRecoveryURLProtocol.fail(path: queuePath, error: .notConnectedToInternet)
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value
        XCTAssertEqual(model.approvalChange(target)?.reconciled, false)
        XCTAssertNotNil(model.approvalChange(target)?.failure)
        XCTAssertFalse(model.canSend(chat))
        XCTAssertFalse(model.canGuide(chat))

        // A later authoritative queue refresh reports that this message was
        // started or cancelled, so there is no longer a settings target to retry.
        MessageRecoveryURLProtocol.enqueue(path: queuePath, body: Data("[]".utf8))
        try await model.loadQueue(chat)

        XCTAssertTrue(model.queues[chat.id]?.isEmpty == true)
        XCTAssertNil(model.approvalChange(target))
        XCTAssertNil(model.composerApprovalTasks[target])
        XCTAssertNil(model.composerApprovalTokens[target])
        XCTAssertFalse(model.approvalSettingsBlockSending(chat.id))
        XCTAssertTrue(model.canSend(chat))
        XCTAssertTrue(model.canGuide(chat))
        XCTAssertEqual(model.composers[chat.id]?.draft, "Keep this draft")
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.askForApproval.rawValue)
    }

    @MainActor func testQueuedApprovalOlderRefreshCannotReplaceConfirmedRevision() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); MessageRecoveryURLProtocol.releaseHeld() }
        let (model, chat, _) = try approvalFixture(root: root)
        let path = "/api/v1/conversations/\(chat.id)/queue"
        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode([approvalQueuedMessage(revision: 1, mode: .askForApproval)]))
        MessageRecoveryURLProtocol.hold(path: path)
        let refresh = Task { @MainActor in try await model.loadQueue(chat) }
        try await waitForRecoveryRequests(path: path)
        model.queues[chat.id] = [try approvalQueuedMessage(revision: 3, mode: .fullAccess)]
        MessageRecoveryURLProtocol.releaseHeld()
        try await refresh.value
        XCTAssertEqual(model.queues[chat.id]?.first?.revision, 3)
        XCTAssertEqual(model.queues[chat.id]?.first?.executionSettings?.approvalMode, BotApprovalMode.fullAccess.rawValue)
    }

    @MainActor private func approvalFixture(root: URL) throws -> (ConnectionModel, ChatSummary, ComposerApprovalTarget) {
        let model = recoveryModel(root: root)
        let chat = try Self.cameraChat(id: "approval-chat")
        model.managedBots = [try approvalBot(.askForApproval)]
        model.chats = [chat]
        model.presentConversation(chat)
        model.snapshots[chat.id] = try JSONDecoder().decode(ConversationSnapshot.self, from: Data(#"{"conversationId":"approval-chat","hostEpoch":"epoch","lastSequence":1,"messages":[],"assistantMessages":[],"thread":{"hydrated":true,"turns":[{"id":"active-turn","status":"inProgress","items":[]}]}}"#.utf8))
        model.editDraft("Keep this draft", chat: chat.id)
        return (model, chat, ComposerApprovalTarget(conversationID: chat.id, botID: "camera-unit-bot", queuedMessageID: nil))
    }

    private func approvalBot(_ mode: BotApprovalMode) throws -> ManagedBot {
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(managedBot("camera-unit-bot", avatar: "ocean"))) as? [String: Any])
        fields["approvalMode"] = mode.rawValue
        fields["conversationId"] = "approval-chat"
        return try JSONDecoder().decode(ManagedBot.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func approvalQueuedMessage(revision: Int, mode: BotApprovalMode) throws -> QueuedMessage {
        let fields: [String: Any] = ["id": "queued", "clientMessageId": "queued-client", "body": "Queued draft", "revision": revision,
            "attachmentIds": [], "executionSettings": ["approvalMode": mode.rawValue, "model": "model"]]
        return try JSONDecoder().decode(QueuedMessage.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @MainActor private func waitForRecoveryRequests(path: String, count: Int = 1) async throws {
        for _ in 0..<100 {
            if MessageRecoveryURLProtocol.bodies(path: path, includingEmpty: true).count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The expected synthetic request did not arrive: \(path)")
    }

    @MainActor func testConnectionRenewalRecoversFromNetworkFailureWithoutPairingAgain() async throws {
        let path = "/api/v1/pairing/session/refresh-challenge"
        for (failure, message) in [(URLError.Code.notConnectedToInternet, "Your iPhone is offline"),
                                   (.timedOut, "Tailscale"), (.cannotFindHost, "Tailscale")] {
            MessageRecoveryURLProtocol.reset()
            var saved: [SavedConnection] = []
            let model = renewalModel { if let value = $0 { saved.append(value) } }
            MessageRecoveryURLProtocol.fail(path: path, error: failure)
            await model.check(renew: true, userInitiated: true)
            XCTAssertEqual(model.macConnected, false)
            XCTAssertTrue(model.status.contains(message))
            XCTAssertFalse(model.accessEnded)
            XCTAssertEqual(model.connection?.requiresPairing, false)
            XCTAssertFalse(model.busy)
            XCTAssertFalse(model.checkingConnection)
            XCTAssertTrue(saved.isEmpty)

            try enqueueRenewal()
            await model.check(renew: true, userInitiated: true)
            XCTAssertEqual(model.macConnected, true)
            XCTAssertEqual(model.status, "Connected to your computer.")
            XCTAssertFalse(model.accessEnded)
            XCTAssertNil(model.error)
            XCTAssertEqual(saved.count, 1)
            XCTAssertEqual(saved.first?.credential.deviceId, Self.cameraSavedConnection().credential.deviceId)
            XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path).count, 2)
        }
    }

    @MainActor func testConnectionRenewalDiscardsBackgroundResponseAndRetriesOnResume() async throws {
        MessageRecoveryURLProtocol.reset()
        let path = "/api/v1/pairing/session/refresh-challenge"
        var saves = 0
        let model = renewalModel { _ in saves += 1 }
        try enqueueRenewal()
        MessageRecoveryURLProtocol.hold(path: path)
        defer { MessageRecoveryURLProtocol.releaseHeld() }
        let check = Task { await model.check(renew: true) }
        try await waitForRecoveryRequests(path: path)
        model.setForeground(false)
        MessageRecoveryURLProtocol.releaseHeld()
        await check.value
        XCTAssertNil(model.macConnected)
        XCTAssertEqual(saves, 0, "A backgrounded renewal must not publish or save a stale response")
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/pairing/session").isEmpty)
        try enqueueRenewal()
        await model.check(renew: true)
        XCTAssertEqual(model.macConnected, true)
        XCTAssertEqual(saves, 1)
    }

    @MainActor func testConnectionRenewalRejectsWrongHostWithoutReplacingCredentials() async throws {
        MessageRecoveryURLProtocol.reset()
        let model = renewalModel { _ in XCTFail("A different host must not replace the saved connection") }
        try enqueueRenewal(host: "different-host")
        await model.check(renew: true)
        XCTAssertEqual(model.macConnected, false)
        XCTAssertEqual(model.connection?.credential.hostInstallationId, Self.cameraSavedConnection().credential.hostInstallationId)
        XCTAssertFalse(model.accessEnded)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/pairing/session").isEmpty)
    }

    @MainActor func testCancelledConnectionCheckDoesNotRenewAfterCachePreparation() async throws {
        MessageRecoveryURLProtocol.reset()
        let model = renewalModel { _ in XCTFail("A cancelled check must not replace credentials") }
        let check = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.check(renew: true)
        }
        await check.value
        XCTAssertFalse(model.checkingConnection)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/pairing/session/refresh-challenge", includingEmpty: true).isEmpty)
    }

    // A saved Project can open before the foreground connection check starts.
    // Its history refresh must join renewal instead of leaving Send blocked by a stale failure.
    @MainActor func testColdProjectHistoryWaitsForRenewalBeforeRefreshing() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { MessageRecoveryURLProtocol.releaseHeld(); try? FileManager.default.removeItem(at: root) }
        let model = renewalModel(root: root) { _ in }
        model.projects.forgetCache()
        defer { model.projects.forgetCache() }
        let detail = try JSONDecoder().decode(ProjectConversationDetail.self, from: projectDetail(pinned: false))
        model.registerProjectConversation(detail)
        let chat = model.projectChat(detail)
        model.macConnected = nil
        try enqueueRenewal()
        let challengePath = "/api/v1/pairing/session/refresh-challenge"
        let historyPath = "/api/v1/conversations/\(chat.id)/history/refresh"
        MessageRecoveryURLProtocol.hold(path: challengePath)
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/project-conversations/\(chat.id)", body: projectDetail(pinned: false))
        MessageRecoveryURLProtocol.enqueue(path: historyPath, method: "POST", status: 202,
                                           body: Data(#"{"state":"refreshing"}"#.utf8))
        MessageRecoveryURLProtocol.enqueue(path: historyPath, method: "GET", body: Data(#"{"state":"completed"}"#.utf8))
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/conversations/\(chat.id)",
                                           body: Data(#"{"conversationId":"project-chat","hostEpoch":"epoch","lastSequence":1,"messages":[],"assistantMessages":[],"thread":{"hydrated":true}}"#.utf8))
        let refresh = Task { await model.reloadNativeHistory(chat) }
        try await waitForRecoveryRequests(path: challengePath)
        XCTAssertTrue(model.nativeHistoryRefreshing.contains(chat.id))
        XCTAssertFalse(model.nativeHistoryFailures.contains(chat.id))
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: historyPath).isEmpty)
        MessageRecoveryURLProtocol.releaseHeld()
        await refresh.value
        XCTAssertEqual(model.macConnected, true)
        XCTAssertFalse(model.nativeHistoryFailures.contains(chat.id))
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: historyPath).count, 1)
        XCTAssertEqual(model.snapshots[chat.id]?.conversationId, chat.id)
    }

    @MainActor private func renewalModel(root: URL? = nil, persist: @escaping (SavedConnection?) throws -> Void) -> ConnectionModel {
        let key = P256.Signing.PrivateKey()
        let signing = SigningIdentity(read: { key.rawRepresentation }, save: { _ in XCTFail("Renewal must not replace the identity") },
            restore: { _ in EnrollmentSigningIdentity(publicKey: key.publicKey, representation: key.rawRepresentation,
                                                      sign: { try key.signature(for: $0) }) },
            create: { throw SigningIdentityFailure.missing })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MessageRecoveryURLProtocol.self]
        if let root {
            return ConnectionModel(cameraFixtureStoreRoot: root, saved: Self.cameraSavedConnection(),
                                   api: PairingAPI(configuration: configuration), replayEnabled: false, signingIdentity: signing)
        }
        return ConnectionModel(saved: Self.cameraSavedConnection(), persistConnection: persist,
                               api: PairingAPI(configuration: configuration), signingIdentity: signing)
    }

    private func enqueueRenewal(host: String = "camera-unit-host") throws {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let challenge: [String: Any] = ["challengeId": "renewal", "deviceId": "camera-unit-device", "nonce": "synthetic",
            "origin": "https://camera-unit.invalid", "hostInstallationId": host, "offerId": "",
            "issuedAtMs": now, "expiresAtMs": now + 60_000]
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/pairing/session/refresh-challenge",
                                           body: try JSONSerialization.data(withJSONObject: challenge))
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/pairing/session",
                                           body: try JSONEncoder().encode(Self.cameraSavedConnection().credential))
    }

    @MainActor func testCancelledPairingDoesNotReadIdentityOrConsumeOffer() async throws {
        let signing = SigningIdentity(read: {
            XCTFail("Cancelled enrollment must not read an identity")
            throw SigningIdentityFailure.missing
        }, save: { _ in XCTFail("Cancelled enrollment must not save a key") }, restore: { _ in
            XCTFail("Cancelled enrollment must not restore a key")
            throw SigningIdentityFailure.missing
        }, create: {
            XCTFail("Cancelled enrollment must not create a key")
            throw SigningIdentityFailure.missing
        })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingDelayedResponse.self]
        let model = ConnectionModel(persistConnection: { _ in XCTFail("Cancelled enrollment must not save credentials") },
                                    api: PairingAPI(configuration: configuration), signingIdentity: signing)
        model.pair(link: "https://pairing-recovery-unit.invalid/pair#offerId=11111111-1111-1111-1111-111111111111&secret=synthetic&hostInstallationId=test-host", address: "", code: "")
        model.cancel()
        for _ in 0..<100 {
            if !model.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.connection)
        XCTAssertFalse(PairingDelayedResponse.delivery.isWaiting)
        XCTAssertTrue(model.status.contains("Pairing stopped"))
    }

    @MainActor func testReplacedPairingRejectsLateSendReceiptAndPreservesFreshDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = SavedConnection(origin: "https://pairing-recovery-unit.invalid", credential: Self.cameraSavedConnection().credential)
        let chat = try Self.cameraChat(id: "pairing-recovery-chat")
        var initial = ComposerIntent(); initial.draft = "Possibly sent before reconnect"
        try initial.begin(device: old.credential.deviceId)
        let request = try XCTUnwrap(initial.pending?.request)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingDelayedResponse.self]
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: old, chat: chat, initialIntent: initial,
                                    api: PairingAPI(configuration: configuration), replayEnabled: false)
        let delivery = Task { await model.deliver(chat) }
        for _ in 0..<200 {
            if PairingDelayedResponse.delivery.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(PairingDelayedResponse.delivery.isWaiting)
        model.retireAfterPairingReplacement()
        let store = ReadStore(root: root, host: old.credential.hostInstallationId, device: old.storageDeviceId)
        var fresh = ComposerIntent(); fresh.draft = "Typed after new pairing"
        try store.saveComposer(fresh, conversation: chat.id)
        let receipt: [String: Any] = ["clientMessageId": request.clientMessageId, "wonderMessageId": "accepted-old-message",
            "bodySha256": ConversationFile.digest(Data(request.body.utf8)), "conversationId": chat.id, "deliveryState": "accepted_by_wonder"]
        PairingDelayedResponse.delivery.complete(try JSONSerialization.data(withJSONObject: receipt))
        await delivery.value
        XCTAssertEqual(try store.loadComposer(conversation: chat.id).draft, fresh.draft)
        XCTAssertNil(try store.loadComposer(conversation: chat.id).pending)
        model.editDraft("Stale view edit", chat: chat.id)
        XCTAssertEqual(try store.loadComposer(conversation: chat.id).draft, fresh.draft)
        XCTAssertTrue(model.accessEnded)
    }

    // A same-host replacement leaves the old model's host and assignment scope
    // intact. A late folder/model rejection must not reset that draft's retry ID.
    @MainActor func testReplacedPairingIgnoresLateNewChatRejections() async throws {
        let saved = SavedConnection(origin: "https://pairing-recovery-unit.invalid", credential: Self.cameraSavedConnection().credential)
        let host = saved.credential.hostInstallationId
        defer { NewChatDraftStore.remove(host: host); PairingDelayedResponse.delivery.complete(Data(), status: 500) }
        for status in [412, 422] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PairingDelayedResponse.self]
            let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: saved,
                                        api: PairingAPI(configuration: configuration), replayEnabled: false)
            var draft = NewChatDraft(destination: .project(id: "project"), text: "Keep this request", family: .codex, model: "model")
            draft.submittedDeviceID = saved.credential.deviceId
            draft.freeze()
            XCTAssertTrue(NewChatDraftStore.save(draft, host: host))
            let attempt = NewChatSendAttempt(scope: model.assignmentScope, hostID: host, requestID: draft.requestID)
            XCTAssertTrue(attempt.applies(to: model, hostID: host, draft: draft))
            let response = Task {
                try await model.projects.createThread(projectID: "project", draft: draft,
                                                      body: "Keep this request", deviceID: saved.credential.deviceId)
            }
            for _ in 0..<200 {
                if PairingDelayedResponse.delivery.isWaiting { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard PairingDelayedResponse.delivery.isWaiting else {
                response.cancel()
                XCTFail("The new-chat request did not reach the delayed response")
                continue
            }
            model.retireAfterPairingReplacement()
            XCTAssertEqual(model.assignmentScope, attempt.scope)
            XCTAssertTrue(model.accessEnded)
            PairingDelayedResponse.delivery.complete(Data(), status: status)
            do {
                _ = try await response.value
                XCTFail("Expected HTTP \(status)")
            } catch PairingFailure.response(let code) {
                XCTAssertEqual(code, status)
            } catch {
                XCTFail("Expected HTTP \(status), got \(error)")
            }
            // This is the same response fence the New Chat catch paths use.
            if attempt.applies(to: model, hostID: host, draft: draft) {
                _ = NewChatDraftStore.reject(draft, host: host)
            }
            XCTAssertEqual(NewChatDraftStore.load(host: host)?.requestID, draft.requestID)
            XCTAssertEqual(NewChatDraftStore.savedMessages(host: host).first?.requestID, draft.requestID)
            NewChatDraftStore.remove(host: host)
        }
    }

    // The first request is still waiting at the Mac when the same host is
    // paired again. Its control must unlock before that HTTP request returns.
    @MainActor func testNewChatSendTaskReleasesControlOnPairingReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); PairingDelayedResponse.delivery.complete(Data(), status: 500) }
        let saved = SavedConnection(origin: "https://pairing-recovery-unit.invalid", credential: Self.cameraSavedConnection().credential)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingDelayedResponse.self]
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: saved,
                                    api: PairingAPI(configuration: configuration), replayEnabled: false)
        let draft = NewChatDraft(destination: .project(id: "project"), text: "Keep this request", family: .codex, model: "model")
        var send = NewChatSendTask()
        let oldGeneration = send.generation
        let oldRequest = Task {
            _ = try? await model.projects.createThread(projectID: "project", draft: draft,
                                                       body: draft.text, deviceID: saved.credential.deviceId)
        }
        send.start(oldRequest)
        for _ in 0..<200 {
            if PairingDelayedResponse.delivery.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard PairingDelayedResponse.delivery.isWaiting else {
            send.cancel()
            XCTFail("The new-chat request did not reach the delayed response")
            return
        }
        model.retireAfterPairingReplacement()
        send.cancel()
        XCTAssertFalse(send.isActive, "The new pairing must release Send without waiting for the old Mac")
        XCTAssertNotEqual(send.generation, oldGeneration)
        let newGeneration = send.generation
        let newRequest = Task { }
        send.start(newRequest)
        XCTAssertTrue(send.isActive)
        PairingDelayedResponse.delivery.complete(Data(), status: 422)
        await oldRequest.value
        XCTAssertFalse(send.finish(oldGeneration), "The old completion must not release the new send")
        XCTAssertTrue(send.isActive)
        await newRequest.value
        XCTAssertTrue(send.finish(newGeneration))
        XCTAssertFalse(send.isActive)
    }

    // Leaving New Chat while creation waits on the Mac must keep the retry
    // identity and make the late response inapplicable to its departed draft.
    @MainActor func testLeavingNewChatCancelsHeldCreationAndKeepsRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let saved = SavedConnection(origin: "https://pairing-recovery-unit.invalid", credential: Self.cameraSavedConnection().credential)
        let host = saved.credential.hostInstallationId
        defer {
            PairingDelayedResponse.delivery.complete(Data(), status: 500)
            NewChatDraftStore.remove(host: host)
            try? FileManager.default.removeItem(at: root)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingDelayedResponse.self]
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: saved,
                                    api: PairingAPI(configuration: configuration), replayEnabled: false)
        var draft = NewChatDraft(destination: .project(id: "project"), text: "Keep this request", family: .codex, model: "model")
        draft.submittedDeviceID = saved.credential.deviceId
        draft.freeze()
        XCTAssertTrue(NewChatDraftStore.save(draft, host: host))
        let attempt = NewChatSendAttempt(scope: model.assignmentScope, hostID: host, requestID: draft.requestID)
        var send = NewChatSendTask()
        let request = Task {
            _ = try? await model.projects.createThread(projectID: "project", draft: draft,
                                                       body: draft.text, deviceID: saved.credential.deviceId)
            XCTAssertFalse(attempt.applies(to: model, hostID: host, draft: draft),
                           "A response after navigation must not mutate the departed draft")
        }
        send.start(request)
        for _ in 0..<200 {
            if PairingDelayedResponse.delivery.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard PairingDelayedResponse.delivery.isWaiting else {
            send.cancel()
            XCTFail("The creation request did not reach the delayed response")
            return
        }
        XCTAssertTrue(send.cancelAfterSaving(draft, hostID: host))
        XCTAssertFalse(send.isActive)
        PairingDelayedResponse.delivery.complete(Data(), status: 500)
        await request.value
        XCTAssertEqual(NewChatDraftStore.savedMessages(host: host).first?.requestID, draft.requestID)
    }

    // An exact Project link on the same Mac replaces the visible draft while
    // the original creation request is held. Save its retry identity first,
    // then cancel its task so the linked Project can send immediately.
    @MainActor func testExactProjectLinkSavesHeldSendBeforeSwitchingDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let saved = SavedConnection(origin: "https://pairing-recovery-unit.invalid", credential: Self.cameraSavedConnection().credential)
        let host = saved.credential.hostInstallationId
        defer {
            PairingDelayedResponse.delivery.complete(Data(), status: 500)
            NewChatDraftStore.remove(host: host)
            try? FileManager.default.removeItem(at: root)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingDelayedResponse.self]
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: saved,
                                    api: PairingAPI(configuration: configuration), replayEnabled: false)
        let linked = NewChatDraft(destination: .project(id: "linked-project"), text: "Linked draft words", family: .codex, model: "model")
        XCTAssertTrue(NewChatDraftStore.save(linked, host: host))
        var pending = NewChatDraft(destination: .project(id: "old-project"), text: "Pending original words", family: .codex, model: "model")
        pending.submittedDeviceID = saved.credential.deviceId
        pending.freeze()
        XCTAssertTrue(NewChatDraftStore.save(pending, host: host))
        var send = NewChatSendTask()
        let oldGeneration = send.generation
        let oldRequest = Task {
            _ = try? await model.projects.createThread(projectID: "old-project", draft: pending,
                                                       body: pending.text, deviceID: saved.credential.deviceId)
        }
        send.start(oldRequest)
        for _ in 0..<200 {
            if PairingDelayedResponse.delivery.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard PairingDelayedResponse.delivery.isWaiting else {
            send.cancel()
            XCTFail("The old Project request did not reach the delayed response")
            return
        }
        XCTAssertTrue(send.cancelAfterSaving(pending, hostID: host))
        XCTAssertFalse(send.isActive)
        XCTAssertNotEqual(send.generation, oldGeneration)
        XCTAssertEqual(NewChatDraftStore.savedMessages(host: host).first?.requestID, pending.requestID)
        XCTAssertEqual(NewChatDraftStore.load(host: host, destination: .project(id: "linked-project")), linked)
        let newGeneration = send.generation
        let newRequest = Task { }
        send.start(newRequest)
        PairingDelayedResponse.delivery.complete(Data(), status: 422)
        await oldRequest.value
        XCTAssertFalse(send.finish(oldGeneration))
        XCTAssertTrue(send.isActive)
        await newRequest.value
        XCTAssertTrue(send.finish(newGeneration))
    }
}

private final class PairingDelayedDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var response: PairingDelayedResponse?
    var isWaiting: Bool { lock.withLock { response != nil } }
    func hold(_ value: PairingDelayedResponse) { lock.withLock { response = value } }
    func complete(_ data: Data, status: Int = 200) {
        let value = lock.withLock { let value = response; response = nil; return value }
        value?.complete(data, status: status)
    }
}

private final class PairingDelayedResponse: URLProtocol, @unchecked Sendable {
    static let delivery = PairingDelayedDelivery()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pairing-recovery-unit.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.delivery.hold(self) }
    override func stopLoading() { }
    func complete(_ data: Data, status: Int = 200) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// Identical regression checks run before and after the Release 2 product patch.
extension WonderDiagnosticsTests {

    @MainActor func testRelease2RegressionVisibleChildRefreshKeepsRootSelection() async throws {
        DiagnosticSubagentFixture.resetTransport()
        let model = DiagnosticSubagentFixture.model()
        await model.loadChats(force: true)
        let parent = try XCTUnwrap(model.chats.first(where: { $0.id == DiagnosticSubagentFixture.parentID }))
        await model.open(parent)
        let child = try XCTUnwrap(model.subagents[parent.id]?.first).chatSummary(botId: parent.botId)
        await model.open(child, root: parent)
        XCTAssertEqual(model.selectedChat?.id, parent.id)

        // Clear requests only; the active route must survive a background refresh.
        DiagnosticSubagentFixture.resetTransport()
        await model.loadChats(force: true)
        for suffix in ["", "/questions", "/queue"] {
            XCTAssertTrue(DiagnosticSubagentFixture.recordedPaths().contains("/api/v1/conversations/\(child.id)\(suffix)"),
                "Background refresh did not refresh the visible child route: \(suffix)")
        }
        XCTAssertEqual(model.selectedChat?.id, parent.id)
    }

    @MainActor func testReadOnlyChildRejectsCameraWithoutChangingParent() async throws {
        DiagnosticSubagentFixture.resetTransport()
        let model = DiagnosticSubagentFixture.model()
        await model.loadChats(force: true)
        let parent = try XCTUnwrap(model.chats.first(where: { $0.id == DiagnosticSubagentFixture.parentID }))
        await model.open(parent)
        let child = try XCTUnwrap(model.subagents[parent.id]?.first).chatSummary(botId: parent.botId)
        await model.open(child, root: parent)
        XCTAssertFalse(model.chats.contains { $0.id == child.id })
        let attached = await model.stageCameraPhoto(Self.cameraImageData(), chat: child, scope: model.assignmentScope)
        guard case .cancelled = attached else { return XCTFail("A read-only agent accepted a capture") }
        XCTAssertEqual(model.composers[child.id]?.attachmentCount, 0)
        XCTAssertEqual(model.composers[parent.id]?.attachmentCount, 0)
        await model.open(parent)
        let cancelled = await model.stageCameraPhoto(Self.cameraImageData(), chat: child, scope: model.assignmentScope)
        guard case .cancelled = cancelled else { return XCTFail("An outgoing child accepted a capture") }
        XCTAssertEqual(model.composers[child.id]?.attachmentCount, 0)
    }

    @MainActor func testRelease2RegressionGroupPreparationFailureKeepsDraftRetryable() async throws {
        Release2RegressionURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat) = try release2RegressionGroup(root: root)
        var intent = ComposerIntent(); intent.draftAttachmentIds = ["uploaded-file"]
        model.composers[chat.id] = intent
        Release2RegressionURLProtocol.enqueue(path: "/api/v1/bot-options", status: 503)
        Release2RegressionURLProtocol.enqueue(path: "/api/v1/bot-options", body: try release2RegressionOptions())

        await model.send(chat)
        XCTAssertNil(model.composerErrors[chat.id])
        XCTAssertNotNil(model.controlErrors[chat.id])
        XCTAssertTrue(model.canSend(chat))
        XCTAssertNil(model.composers[chat.id]?.pending)
        XCTAssertEqual(model.composers[chat.id]?.draftAttachmentIds, ["uploaded-file"])
        await model.send(chat)
        XCTAssertNil(model.controlErrors[chat.id])
        let request = try JSONDecoder().decode(SendRequest.self, from: XCTUnwrap(Release2RegressionURLProtocol.bodies(path: "/api/v1/group-chats/group/messages").first))
        XCTAssertEqual(request.attachmentIds, ["uploaded-file"])
        XCTAssertEqual(request.body, "")
        XCTAssertNotNil(model.composers[chat.id]?.pending?.receipt)
    }

    @MainActor func testRelease2RegressionRejectedAsyncReplyCanBeCorrectedOrSkipped() async throws {
        for status in [400, 413] {
            for skip in [false, true] {
                Release2RegressionURLProtocol.reset()
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let model = release2RegressionModel(root: root)
                let chat = try Self.cameraChat(id: "recovery-chat")
                let question = try release2RegressionQuestion()
                let store = ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
                let old = AsyncAnswerIntent(answers: [String(repeating: "a", count: 8193)], skip: false)
                try store.saveIntent(JSONEncoder().encode(old), conversation: "async-reply-q")
                model.saveAnswerDraft(["0": "Editable answer"], id: question.id)
                let path = "/api/v1/conversations/recovery-chat/questions/q"
                Release2RegressionURLProtocol.enqueue(path: path, status: status)
                await model.replyAsync(question, chat: chat, answers: ["Ignored during exact retry"], skip: false)
                XCTAssertNil(try store.loadIntent(conversation: "async-reply-q"))
                XCTAssertEqual(model.answerDraft(question.id), ["0": "Editable answer"])
                Release2RegressionURLProtocol.enqueue(path: path, status: 204)
                await model.replyAsync(question, chat: chat, answers: skip ? [] : ["Corrected answer"], skip: skip)
                let bodies = Release2RegressionURLProtocol.bodies(path: path)
                XCTAssertEqual(bodies.count, 2)
                let retried = try JSONDecoder().decode(AsyncAnswerIntent.self, from: XCTUnwrap(bodies.last))
                XCTAssertEqual(retried.skip, skip)
                XCTAssertEqual(retried.answers, skip ? [] : ["Corrected answer"])
                XCTAssertNil(model.attentionErrors[question.id])
            }
        }
    }

    @MainActor private func release2RegressionModel(root: URL) -> ConnectionModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Release2RegressionURLProtocol.self]
        return ConnectionModel(cameraFixtureStoreRoot: root, saved: Self.cameraSavedConnection(),
            api: PairingAPI(configuration: configuration), replayEnabled: false)
    }

    @MainActor private func release2RegressionGroup(root: URL) throws -> (ConnectionModel, ChatSummary) {
        let group = try JSONDecoder().decode(GroupRead.self, from: Data(#"{"id":"group","conversationId":"recovery-chat","name":"Group","isArchived":false,"messages":[],"attachmentsSupported":true,"collaboration":{"configuration":{"instructions":"","routing":{"model":"","reasoningEffort":""},"workspace":"/fixture","needsPurpose":false},"runs":[]}}"#.utf8))
        let model = release2RegressionModel(root: root)
        model.groups[group.conversationId] = group
        model.chats = [group.summary]
        return (model, group.summary)
    }

    private func release2RegressionOptions() throws -> Data {
        let defaults = ModelDefaultPurpose.groupParticipation.load()
        return try JSONSerialization.data(withJSONObject: [
            "models": [["id": defaults.model.isEmpty ? "fixture-model" : defaults.model, "displayName": "Fixture", "hidden": false,
                "reasoningEfforts": [["id": defaults.reasoningEffort, "label": "Fixture"]],
                "serviceTiers": [["id": defaults.serviceTier ?? "default", "label": "Fixture"]]]],
            "approvalModes": [["id": defaults.approvalMode.rawValue, "allowed": true]],
            "allowedApprovalPolicies": []
        ])
    }

    private func release2RegressionQuestion() throws -> AsyncQuestion {
        try JSONDecoder().decode(AsyncQuestion.self, from: Data(#"{"id":"q","conversationId":"recovery-chat","turnId":"turn","itemId":"item","questions":[{"title":"Question?"}],"state":"pending","expiresAtMs":9999999999999}"#.utf8))
    }

}

/// Synthetic, scoped transport. Held requests are released explicitly by tests;
/// no real host, credentials or model execution is involved.
private final class Release2RegressionURLProtocol: URLProtocol, @unchecked Sendable {
    private enum Reply { case response(Int, Data), failure(URLError.Code) }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var replies: [String: [Reply]] = [:]
        var requests: [(String, Data?)] = []
        var heldPath: String?
        var held: [() -> Void] = []
    }
    private static let state = State()
    static func reset() {
        releaseHeld()
        state.lock.withLock { state.replies = [:]; state.requests = []; state.heldPath = nil }
    }
    static func enqueue(path: String, status: Int = 200, body: Data = Data("{}".utf8)) {
        state.lock.withLock { state.replies[path, default: []].append(.response(status, body)) }
    }
    static func fail(path: String, error: URLError.Code) {
        state.lock.withLock { state.replies[path, default: []].append(.failure(error)) }
    }
    static func bodies(path: String, includingEmpty: Bool = false) -> [Data] {
        state.lock.withLock { state.requests.filter { $0.0 == path }.compactMap { $0.1 ?? (includingEmpty ? Data() : nil) } }
    }
    static func hold(path: String) { state.lock.withLock { state.heldPath = path } }
    static func releaseHeld() {
        let work = state.lock.withLock { let work = state.held; state.held = []; state.heldPath = nil; return work }
        work.forEach { $0() }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "camera-unit.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: Data?
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { body = nil }
        let held = Self.state.lock.withLock {
            Self.state.requests.append((path, body))
            guard Self.state.heldPath == path else { return false }
            Self.state.held.append { [weak self] in self?.respond(path: path, body: body) }
            return true
        }
        if !held { respond(path: path, body: body) }
    }
    override func stopLoading() {}
    private func respond(path: String, body: Data?) {
        let reply: Reply? = Self.state.lock.withLock {
            guard Self.state.replies[path]?.isEmpty == false else { return nil }
            return Self.state.replies[path]?.removeFirst()
        }
        if case .failure(let code) = reply { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        if case .response(let status, let data) = reply { finish(status: status, body: data); return }
        if path == "/api/v1/group-chats/group/messages", let body,
           let sent = try? JSONDecoder().decode(SendRequest.self, from: body) {
            let value = ["clientMessageId": sent.clientMessageId, "wonderMessageId": "accepted",
                "bodySha256": ConversationFile.digest(Data(sent.body.utf8)), "conversationId": "recovery-chat", "deliveryState": "accepted_by_wonder"]
            finish(status: 202, body: try! JSONEncoder().encode(value)); return
        }
        if path == "/api/v1/devices" {
            finish(status: 200, body: Data(#"[{"id":"camera-unit-device","revokedAt":null}]"#.utf8)); return
        }
        if path == "/api/v1/host/status" {
            finish(status: 200, body: Data(#"{"hostInstallationId":"camera-unit-host"}"#.utf8)); return
        }
        finish(status: 200, body: Data("[]".utf8))
    }
    private func finish(status: Int, body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Synthetic, scoped transport. Held requests are released explicitly by tests;
/// no real host, credentials or model execution is involved.
private final class MessageRecoveryURLProtocol: URLProtocol, @unchecked Sendable {
    private enum Reply { case response(Int, Data, String), failure(URLError.Code) }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var replies: [String: [Reply]] = [:]
        var requests: [(String, Data?)] = []
        var heldPath: String?
        var heldMethod: String?
        var held: [() -> Void] = []
    }
    private static let state = State()
    static func reset() {
        releaseHeld()
        state.lock.withLock { state.replies = [:]; state.requests = []; state.heldPath = nil; state.heldMethod = nil }
    }
    static func enqueue(path: String, method: String? = nil, status: Int = 200, body: Data = Data("{}".utf8),
                        contentType: String = "application/json") {
        state.lock.withLock { state.replies[method.map { $0 + " " + path } ?? path, default: []].append(.response(status, body, contentType)) }
    }
    static func fail(path: String, error: URLError.Code) {
        state.lock.withLock { state.replies[path, default: []].append(.failure(error)) }
    }
    static func bodies(path: String, includingEmpty: Bool = false) -> [Data] {
        state.lock.withLock { state.requests.filter { $0.0 == path }.compactMap { $0.1 ?? (includingEmpty ? Data() : nil) } }
    }
    static func hold(path: String, method: String? = nil) { state.lock.withLock { state.heldPath = path; state.heldMethod = method } }
    static func releaseHeld() {
        let work = state.lock.withLock { let work = state.held; state.held = []; state.heldPath = nil; state.heldMethod = nil; return work }
        work.forEach { $0() }
    }
    static func releaseNewestHeld() {
        let work = state.lock.withLock { state.held.popLast() }
        work?()
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "camera-unit.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: Data?
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { body = nil }
        let held = Self.state.lock.withLock {
            Self.state.requests.append((path, body))
            guard Self.state.heldPath == path, Self.state.heldMethod == nil || Self.state.heldMethod == request.httpMethod else { return false }
            Self.state.held.append { [weak self] in self?.respond(path: path, body: body) }
            return true
        }
        if !held { respond(path: path, body: body) }
    }
    override func stopLoading() {}
    private func respond(path: String, body: Data?) {
        let reply: Reply? = Self.state.lock.withLock {
            let methodKey = (request.httpMethod ?? "GET") + " " + path
            let key = Self.state.replies[methodKey]?.isEmpty == false ? methodKey : path
            guard Self.state.replies[key]?.isEmpty == false else { return nil }
            return Self.state.replies[key]?.removeFirst()
        }
        if case .failure(let code) = reply { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        if case .response(let status, let data, let contentType) = reply {
            finish(status: status, body: data, contentType: contentType); return
        }
        if path == "/api/v1/group-chats/group/messages", let body,
           let sent = try? JSONDecoder().decode(SendRequest.self, from: body) {
            let value = ["clientMessageId": sent.clientMessageId, "wonderMessageId": "accepted",
                "bodySha256": ConversationFile.digest(Data(sent.body.utf8)), "conversationId": "recovery-chat", "deliveryState": "accepted_by_wonder"]
            finish(status: 202, body: try! JSONEncoder().encode(value)); return
        }
        if path == "/api/v1/devices" {
            finish(status: 200, body: Data(#"[{"id":"camera-unit-device","revokedAt":null}]"#.utf8)); return
        }
        if path == "/api/v1/host/status" {
            finish(status: 200, body: Data(#"{"hostInstallationId":"camera-unit-host"}"#.utf8)); return
        }
        finish(status: 200, body: Data("[]".utf8))
    }
    private func finish(status: Int, body: Data, contentType: String = "application/json") {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

extension WonderDiagnosticsTests {
    @MainActor func testAsyncReplyRestoresPendingSubmissionAndRetriesExactBytes() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let question = try recoveryQuestion()
        let chat = try Self.cameraChat(id: "recovery-chat")
        let store = ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
        let bytes = Data(#"{ "skip" : false, "answers" : ["Original answer"] }"#.utf8)
        try store.saveIntent(bytes, conversation: "async-reply-q")
        let model = recoveryModel(root: root)
        let listPath = "/api/v1/conversations/recovery-chat/questions"
        let replyPath = listPath + "/q"
        MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([question]))
        await model.loadAsyncQuestions(chat)
        XCTAssertEqual(model.savedAsyncReplies[question.id]?.answers, ["Original answer"])
        XCTAssertTrue(model.retryableAsyncReplies.contains(question.id))
        XCTAssertNotNil(model.attentionErrors[question.id])
        MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([question]))
        MessageRecoveryURLProtocol.enqueue(path: replyPath, status: 204)
        await model.replyAsync(question, chat: chat, answers: [], skip: true, retry: true)
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: replyPath), [bytes])
        XCTAssertNil(try store.loadIntent(conversation: "async-reply-q"))
        XCTAssertNil(model.savedAsyncReplies[question.id])
    }

    @MainActor func testAsyncReplyRestoresExpiredSubmissionForCopyWithoutResubmitting() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try Self.cameraChat(id: "recovery-chat")
        let expired = try recoveryQuestionWithState("expired", response: nil)
        let store = ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
        let bytes = try JSONEncoder().encode(AsyncAnswerIntent(answers: ["Keep this reply"], skip: false))
        try store.saveIntent(bytes, conversation: "async-reply-q")
        let model = recoveryModel(root: root)
        let listPath = "/api/v1/conversations/recovery-chat/questions"
        MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([expired]))
        await model.loadAsyncQuestions(chat)
        XCTAssertEqual(model.savedAsyncReplies[expired.id]?.answers, ["Keep this reply"])
        XCTAssertNotNil(model.attentionErrors[expired.id], "The expired row must remain reachable in QuestionDock")
        XCTAssertFalse(model.retryableAsyncReplies.contains(expired.id))
        MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([expired]))
        await model.replyAsync(expired, chat: chat, answers: [], skip: true, retry: true)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: listPath + "/q").isEmpty)
        XCTAssertEqual(try store.loadIntent(conversation: "async-reply-q"), bytes)
    }

    @MainActor func testAsyncReplyReconcilesConfirmedTerminalResponseWithoutResubmitting() async throws {
        for state in ["answered", "dismissed"] {
            MessageRecoveryURLProtocol.reset()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let chat = try Self.cameraChat(id: "recovery-chat")
            let answer = AsyncAnswerIntent(answers: state == "answered" ? ["Confirmed reply"] : [], skip: state == "dismissed")
            let terminal = try recoveryQuestionWithState(state, response: answer)
            let store = ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
            try store.saveIntent(JSONEncoder().encode(answer), conversation: "async-reply-q")
            let model = recoveryModel(root: root)
            let listPath = "/api/v1/conversations/recovery-chat/questions"
            MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([terminal]))
            await model.loadAsyncQuestions(chat)
            XCTAssertNil(try store.loadIntent(conversation: "async-reply-q"))
            XCTAssertNil(model.savedAsyncReplies[terminal.id])
            XCTAssertNil(model.attentionErrors[terminal.id])
            XCTAssertFalse(model.retryableAsyncReplies.contains(terminal.id))
            MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([terminal]))
            await model.replyAsync(terminal, chat: chat, answers: [], skip: true, retry: true)
            XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: listPath + "/q").isEmpty)
        }
    }

    @MainActor func testAsyncReplyPreservesDifferentTerminalResponseWithoutResubmitting() async throws {
        for state in ["answered", "dismissed"] {
            MessageRecoveryURLProtocol.reset()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let chat = try Self.cameraChat(id: "recovery-chat")
            let stalePending = try recoveryQuestion()
            let response = AsyncAnswerIntent(answers: state == "answered" ? ["Answered elsewhere"] : [], skip: state == "dismissed")
            let terminal = try recoveryQuestionWithState(state, response: response)
            let store = ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
            let bytes = try JSONEncoder().encode(AsyncAnswerIntent(answers: ["My original reply"], skip: false))
            try store.saveIntent(bytes, conversation: "async-reply-q")
            let model = recoveryModel(root: root)
            let listPath = "/api/v1/conversations/recovery-chat/questions"
            MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([terminal]))
            await model.loadAsyncQuestions(chat)
            XCTAssertEqual(model.savedAsyncReplies[terminal.id]?.answers, ["My original reply"])
            XCTAssertNotNil(model.attentionErrors[terminal.id])
            XCTAssertFalse(model.retryableAsyncReplies.contains(terminal.id))
            // Even a stale pending row may not submit after authoritative terminal state.
            await model.replyAsync(stalePending, chat: chat, answers: ["Changed"], skip: false)
            MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([terminal]))
            await model.replyAsync(stalePending, chat: chat, answers: [], skip: true, retry: true)
            XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: listPath + "/q").isEmpty)
            XCTAssertEqual(try store.loadIntent(conversation: "async-reply-q"), bytes)
        }
    }

    @MainActor func testAsyncReplyStatusFailureAndMissingQuestionNeverResubmit() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try Self.cameraChat(id: "recovery-chat")
        let question = try recoveryQuestion()
        let store = ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
        let bytes = try JSONEncoder().encode(AsyncAnswerIntent(answers: ["My reply"], skip: false))
        try store.saveIntent(bytes, conversation: "async-reply-q")
        let model = recoveryModel(root: root)
        let listPath = "/api/v1/conversations/recovery-chat/questions"
        MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([question]))
        await model.loadAsyncQuestions(chat)
        MessageRecoveryURLProtocol.enqueue(path: listPath, status: 503)
        await model.replyAsync(question, chat: chat, answers: [], skip: true, retry: true)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: listPath + "/q").isEmpty)
        XCTAssertNotNil(model.savedAsyncReplies[question.id])
        MessageRecoveryURLProtocol.enqueue(path: listPath, body: Data("[]".utf8))
        await model.replyAsync(question, chat: chat, answers: [], skip: true, retry: true)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: listPath + "/q").isEmpty)
        XCTAssertEqual(model.asyncQuestions[chat.id]?.map(\.id), [question.id])
        XCTAssertNotNil(model.attentionErrors[question.id])
        XCTAssertFalse(model.retryableAsyncReplies.contains(question.id))
        XCTAssertEqual(try store.loadIntent(conversation: "async-reply-q"), bytes)
    }

    @MainActor func testAsyncReplyRestoresCachedExpiredSubmissionWhileOffline() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try Self.cameraChat(id: "recovery-chat")
        let expired = try recoveryQuestionWithState("expired", response: nil)
        let store = ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
        try store.saveIntent(JSONEncoder().encode([expired]), conversation: "async-list-" + chat.id)
        try store.saveIntent(JSONEncoder().encode(AsyncAnswerIntent(answers: ["Offline saved reply"], skip: false)), conversation: "async-reply-q")
        let model = recoveryModel(root: root)
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/conversations/recovery-chat/questions", status: 503)
        await model.open(chat)
        XCTAssertEqual(model.savedAsyncReplies[expired.id]?.answers, ["Offline saved reply"])
        XCTAssertNotNil(model.attentionErrors[expired.id])
        XCTAssertEqual(model.asyncQuestions[chat.id]?.map(\.id), [expired.id])
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/conversations/recovery-chat/questions/q").isEmpty)
    }

    private func recoveryQuestionWithState(_ state: String, response: AsyncAnswerIntent?) throws -> AsyncQuestion {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(recoveryQuestion())) as? [String: Any])
        value["state"] = state
        if state == "expired" { value["expiresAtMs"] = 1 }
        if let response { value["response"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) }
        else { value.removeValue(forKey: "response") }
        return try JSONDecoder().decode(AsyncQuestion.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
