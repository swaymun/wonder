import Foundation
import XCTest
@testable import WonderMenu

final class PrivacySettingsTests: XCTestCase {
    @MainActor
    func testFindsRunningApplicationRegardlessOfInstallDirectory() {
        for root in ["/Applications/Wonder.app", "/Users/test/Applications/Wonder Beta.app"] {
            let executable = URL(fileURLWithPath: root + "/Contents/MacOS/WonderMacBridge")
            XCTAssertEqual(PrivacySettings.applicationBundle(containing: executable)?.path, root)
        }
        XCTAssertNil(PrivacySettings.applicationBundle(containing: URL(fileURLWithPath: "/tmp/WonderMacBridge")))
    }
    @MainActor
    func testDragWindowOnlyAppearsForUnconfiguredSetupPermissions() {
        XCTAssertFalse(PrivacySettings.shouldPresent(setup: false, alreadyAllowed: false))
        XCTAssertFalse(PrivacySettings.shouldPresent(setup: false, alreadyAllowed: true))
        XCTAssertFalse(PrivacySettings.shouldPresent(setup: true, alreadyAllowed: true))
        XCTAssertTrue(PrivacySettings.shouldPresent(setup: true, alreadyAllowed: false))
    }

}
