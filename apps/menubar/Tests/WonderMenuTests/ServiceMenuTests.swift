import XCTest
@testable import WonderMenu

final class ServiceMenuTests: XCTestCase {
    @MainActor
    func testDevelopmentUpdaterIsUnavailableWithoutAFeedAndKey() {
        XCTAssertFalse(AppUpdates().available)
    }


}
