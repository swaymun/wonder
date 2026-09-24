import XCTest
@testable import WonderMenu

final class NativeBridgeTests: XCTestCase {
    @MainActor private func bridge() -> NativeBridge {
        NativeBridge(defaults: UserDefaults(suiteName: "WonderBridgeTests-" + UUID().uuidString)!)
    }
    @MainActor private func bridge(serviceDirectory: URL, defaults: UserDefaults) -> NativeBridge {
        NativeBridge(defaults: defaults, serviceDirectory: serviceDirectory)
    }
    @MainActor func testSetupCannotAdvanceBeforeExecutionReadyOrFinishEarly() async {
        let bridge = bridge()
        await bridge.perform(BridgeCommand(id: "step", action: "setup-step", step: 1))
        XCTAssertEqual(bridge.setup.step, .welcome)
        await bridge.perform(BridgeCommand(id: "done", action: "setup-finish"))
        XCTAssertFalse(bridge.setup.completed)
        bridge.model.executionReady = true
        await bridge.perform(BridgeCommand(id: "step2", action: "setup-step", step: 4))
        XCTAssertEqual(bridge.setup.step, .connection)
        await bridge.perform(BridgeCommand(id: "unsigned", action: "setup-step", step: 1))
        XCTAssertEqual(bridge.setup.step, .permissions)
    }
    @MainActor func testScreenChoiceDefaultsToMainRejectsStaleDisplayAndPersistsSelection() async {
        let suite = "WonderBridgeDisplayTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = NativeBridge(defaults: defaults)
        XCTAssertEqual(first.snapshot()["preferredDisplayID"] as? String, "")

        await first.perform(BridgeCommand(id: "stale", action: "shared-display", key: "999:999:999"))
        XCTAssertEqual(first.snapshot()["preferredDisplayID"] as? String, "")
        XCTAssertFalse((first.snapshot()["error"] as? String ?? "").isEmpty)

        if let display = (first.snapshot()["sharedDisplays"] as? [[String: Any]])?.first,
           let identifier = display["id"] as? String {
            await first.perform(BridgeCommand(id: "select", action: "shared-display", key: identifier))
            XCTAssertEqual(first.snapshot()["preferredDisplayID"] as? String, identifier)
            XCTAssertEqual(NativeBridge(defaults: defaults).snapshot()["preferredDisplayID"] as? String, identifier)
        }

        await first.perform(BridgeCommand(id: "main", action: "shared-display", key: ""))
        XCTAssertEqual(first.snapshot()["preferredDisplayID"] as? String, "")
    }
    @MainActor func testChangedPairingCodeCannotApproveARequest() async {
        let bridge = bridge()
        bridge.pairing.pending = [PhoneEnrollment(deviceId: "device", label: "Phone", challenge: EnrollmentChallenge(
            deviceId: "device", challengeId: "new", nonce: "nonce", origin: "https://test.invalid", hostInstallationId: "host", issuedAtMs: 1, expiresAtMs: 9999999999999))]
        await bridge.perform(BridgeCommand(id: "approve", action: "approve", key: "device", verification: "old"))
        XCTAssertEqual(bridge.pairing.pending.count, 1)
        XCTAssertFalse(bridge.snapshot()["error"] as? String == "")
        XCTAssertEqual(bridge.snapshot()["acknowledged"] as? String, "approve")
    }
    @MainActor func testSnapshotContainsDisplayCodeWithoutChallengeSecrets() throws {
        let bridge = bridge()
        bridge.pairing.pending = [PhoneEnrollment(deviceId: "device", label: "Phone", challenge: EnrollmentChallenge(
            deviceId: "device", challengeId: "challenge-secret", nonce: "nonce-secret", origin: "https://test.invalid", hostInstallationId: "host", issuedAtMs: 1, expiresAtMs: 9999999999999))]
        let data = try JSONSerialization.data(withJSONObject: bridge.snapshot())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("nonce-secret"))
        XCTAssertFalse(text.contains("challenge-secret"))
        XCTAssertTrue(text.contains(bridge.pairing.pending[0].challenge.verification))
    }
    @MainActor func testPairingSnapshotCarriesARealPNGAndMatchingLinkAlternative() throws {
        let bridge = bridge()
        bridge.pairing.offer = PhoneOffer(offerId: "offer", url: "https://test.invalid/pair#private-token", humanCode: "ab1234", expiresAtMs: 9999999999999)
        let offer = try XCTUnwrap(bridge.snapshot()["offer"] as? [String: Any])
        let png = try XCTUnwrap(offer["qr"] as? [UInt8])
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(offer["origin"] as? String, "https://test.invalid")
        XCTAssertEqual(offer["code"] as? String, "AB1234")
        XCTAssertEqual(offer["url"] as? String, bridge.pairing.offer?.url)
    }
    @MainActor func testSnapshotSeparatesLocalServiceFromBotReadinessAndHidesGlobalFileEditor() throws {
        let bridge = bridge()
        bridge.model.serviceRunning = true
        bridge.model.executionReady = false
        let snapshot = bridge.snapshot()
        XCTAssertEqual(snapshot["serviceRunning"] as? Bool, true)
        XCTAssertEqual(snapshot["ready"] as? Bool, false)
        for key in ["bots", "fileAccess", "selectedBot"] { XCTAssertNil(snapshot[key]) }
    }
    @MainActor func testPairedDeviceControlDefaultsOffPersistsAcrossRelaunchAndDisables() async throws {
        let serviceDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wonder-bridge-control-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: serviceDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        defer { try? FileManager.default.removeItem(at: serviceDirectory) }
        let defaults = UserDefaults(suiteName: "WonderBridgeTests-" + UUID().uuidString)!
        let first = bridge(serviceDirectory: serviceDirectory, defaults: defaults)
        XCTAssertEqual(first.snapshot()["allowControlFromPairedDevices"] as? Bool, false)

        await first.perform(BridgeCommand(id: "enable", action: "allow-control-from-paired-devices", enabled: true))
        XCTAssertEqual(first.snapshot()["allowControlFromPairedDevices"] as? Bool, true)

        let relaunched = bridge(serviceDirectory: serviceDirectory, defaults: defaults)
        XCTAssertEqual(relaunched.snapshot()["allowControlFromPairedDevices"] as? Bool, true)
        await relaunched.perform(BridgeCommand(id: "disable", action: "allow-control-from-paired-devices", enabled: false))
        XCTAssertEqual(relaunched.snapshot()["allowControlFromPairedDevices"] as? Bool, false)
    }
    @MainActor func testUnknownActionIsAcknowledgedAsAnError() async {
        let bridge = bridge()
        await bridge.perform(BridgeCommand(id: "unknown", action: "shell"))
        XCTAssertEqual(bridge.snapshot()["acknowledged"] as? String, "unknown")
        XCTAssertFalse(bridge.snapshot()["error"] as? String == "")
    }
}
