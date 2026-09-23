import XCTest
@testable import WonderMenu

final class ServiceMenuTests: XCTestCase {
    @MainActor
    func testDevelopmentUpdaterIsUnavailableWithoutAFeedAndKey() {
        XCTAssertFalse(AppUpdates().available)
    }

    @MainActor
    func testUpdaterRequiresHTTPSValidKeyAndVerificationBeforeExtraction() {
        let valid: [String: Any] = [
            "SUFeedURL": "https://updates.example.test/appcast.xml",
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "SUVerifyUpdateBeforeExtraction": true,
            "SURequireSignedFeed": true
        ]
        XCTAssertTrue(AppUpdates.configured(valid))
        for url in ["http://updates.example.test/feed", "https://user:secret@example.test/feed", "https://example.test/feed?token=secret", "https://example.test/feed#fragment"] {
            var changed = valid; changed["SUFeedURL"] = url
            XCTAssertFalse(AppUpdates.configured(changed))
        }
        var changed = valid; changed["SUPublicEDKey"] = "placeholder"
        XCTAssertFalse(AppUpdates.configured(changed))
        changed = valid; changed["SUVerifyUpdateBeforeExtraction"] = false
        XCTAssertFalse(AppUpdates.configured(changed))
        changed = valid; changed["SURequireSignedFeed"] = false
        XCTAssertFalse(AppUpdates.configured(changed))
    }

    @MainActor
    func testBusyHostDefersInstallationAndSameAttemptRenewsAdmission() async {
        var ready = false
        var ids: [String] = []
        let updates = AppUpdates(prepare: { id in ids.append(id); return ready }, cancel: { _ in })
        let initiallyReady = await updates.prepareTermination()
        XCTAssertFalse(initiallyReady)
        XCTAssertFalse(updates.admissionGranted)
        ready = true
        let subsequentlyReady = await updates.prepareTermination()
        XCTAssertTrue(subsequentlyReady)
        XCTAssertTrue(updates.admissionGranted)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, ids.last)
    }

    @MainActor
    func testHostFailureNeverAllowsTermination() async {
        let updates = AppUpdates(prepare: { _ in throw URLError(.timedOut) }, cancel: { _ in })
        let ready = await updates.prepareTermination()
        XCTAssertFalse(ready)
        XCTAssertFalse(updates.admissionGranted)
        XCTAssertTrue(updates.message?.contains("could not confirm") == true)
    }

    @MainActor
    func testPendingInstallationRunsOnlyAfterAdmission() async {
        let admitted = expectation(description: "admitted")
        var calls = 0
        let updates = AppUpdates(prepare: { _ in true }, cancel: { _ in })
        updates.postponeInstallation { calls += 1; admitted.fulfill() }
        await fulfillment(of: [admitted], timeout: 2)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(updates.admissionGranted)
        XCTAssertTrue(updates.preparingInstall)
    }

    @MainActor
    func testAbortedPreparationCannotInstallAndCancelsItsOriginalLease() async {
        let started = expectation(description: "prepare started")
        var continuation: CheckedContinuation<Bool, Never>?
        var preparedID: String?
        var cancelledIDs: [String] = []
        var installations = 0
        let updates = AppUpdates(prepare: { id in
            preparedID = id
            return await withCheckedContinuation { pending in
                continuation = pending
                started.fulfill()
            }
        }, cancel: { cancelledIDs.append($0) })
        updates.postponeInstallation { installations += 1 }
        await fulfillment(of: [started], timeout: 2)
        updates.installationFailed("Cancelled")
        continuation?.resume(returning: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(installations, 0)
        XCTAssertFalse(updates.admissionGranted)
        XCTAssertFalse(updates.preparingInstall)
        XCTAssertFalse(cancelledIDs.isEmpty)
        XCTAssertTrue(cancelledIDs.allSatisfy { $0 == preparedID })
    }

}
