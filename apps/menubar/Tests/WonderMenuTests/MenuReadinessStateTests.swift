import XCTest
@testable import WonderMenu

final class MenuReadinessStateTests: XCTestCase {
    func testHostExecutionDetailDecodesWhenPresentAndMissing() throws {
        let blocked = try JSONDecoder().decode(HostStatus.self, from: Data(#"{"state":"degraded","execution":{"ready":false,"detail":"Chat storage is unavailable."}}"#.utf8))
        XCTAssertFalse(blocked.execution.ready)
        XCTAssertEqual(blocked.execution.detail, "Chat storage is unavailable.")
        let older = try JSONDecoder().decode(HostStatus.self, from: Data(#"{"state":"ready","execution":{"ready":true}}"#.utf8))
        XCTAssertNil(older.execution.detail)
    }
    func testReadyHostStatesUseReadyPresentation() {
        XCTAssertEqual(MenuReadinessState.fromHostState("ready"), .ready)
        XCTAssertEqual(MenuReadinessState.fromHostState("RUNNING"), .ready)
        XCTAssertEqual(
            MenuReadinessState.ready.presentation,
            MenuStatusPresentation(
                title: "Connected",
                detail: "Your Mac is ready."
            )
        )
    }

    func testStartingHostStateUsesStartingPresentation() {
        XCTAssertEqual(MenuReadinessState.fromHostState("degraded"), .starting)
        XCTAssertEqual(
            MenuReadinessState.starting.presentation,
            MenuStatusPresentation(
                title: "Connecting…",
                detail: "Your Mac is opening your saved chats."
            )
        )
    }

    func testOfflineUsesOfflinePresentation() {
        XCTAssertEqual(
            MenuReadinessState.offline.presentation,
            MenuStatusPresentation(
                title: "Offline",
                detail: "Wonder is not responding. Restart it below; your saved chats are kept."
            )
        )
    }

}
