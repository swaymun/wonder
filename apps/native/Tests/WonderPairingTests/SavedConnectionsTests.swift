import XCTest
@testable import WonderPairing

final class SavedConnectionsTests: XCTestCase {
    private func connection(_ host: String, token: String = "session", device: String = "phone") throws -> SavedConnection {
        let data = try JSONSerialization.data(withJSONObject: ["origin": "https://\(host).invalid", "hostName": host,
            "credential": ["hostInstallationId": host, "deviceId": device, "sessionToken": token, "csrfToken": "csrf"]])
        return try JSONDecoder().decode(SavedConnection.self, from: data)
    }

    func testLegacyMigrationPreservesPairingAndDefaultsToAll() throws {
        let legacy = try connection("studio")
        let saved = SavedConnections(legacy: legacy)
        let restored = try JSONDecoder().decode(SavedConnections.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.connections.count, 1)
        XCTAssertEqual(restored.connections.first?.credential.sessionToken, legacy.credential.sessionToken)
        XCTAssertTrue(restored.selectedHostIDs.isEmpty)
        var filtered = restored
        try filtered.select("studio")
        XCTAssertEqual(filtered.selectedHostIDs, ["studio"])
    }

    func testSingleComputerSelectionReplacesPreviousAndSurvivesReload() throws {
        var saved = SavedConnections(legacy: try connection("studio"))
        saved.save(try connection("laptop", token: "laptop-session"))
        saved.save(try connection("mini"))
        try saved.select("studio")
        try saved.select("laptop")
        saved.save(try connection("studio", token: "renewed"))
        let restored = try JSONDecoder().decode(SavedConnections.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.selectedHostIDs, ["laptop"])
        XCTAssertFalse(restored.includes("studio"))
        XCTAssertFalse(restored.includes("mini"))
        XCTAssertEqual(restored.connections.first?.credential.sessionToken, "renewed")
        XCTAssertEqual(restored.connections[1].credential.sessionToken, "laptop-session")
    }

    func testRepeatedSelectionStaysSelectedAndAllIncludesNewComputers() throws {
        var saved = SavedConnections(legacy: try connection("studio"))
        saved.save(try connection("laptop"))
        XCTAssertTrue(saved.includes("laptop"))
        try saved.select("studio")
        XCTAssertFalse(saved.includes("laptop"))
        try saved.select("studio")
        XCTAssertEqual(saved.selectedHostIDs, ["studio"])
        try saved.select("studio")
        try saved.select("laptop")
        XCTAssertEqual(saved.selectedHostIDs, ["laptop"])
        saved.showAll()
        saved.save(try connection("mini"))
        XCTAssertTrue(saved.includes("mini"))
    }

    func testOldMultipleSelectionRestoresAll() throws {
        var saved = SavedConnections(legacy: try connection("studio"))
        saved.save(try connection("laptop"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        json["selectedHostIDs"] = ["studio", "laptop"]
        let restored = try JSONDecoder().decode(SavedConnections.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(restored.selectedHostIDs.isEmpty)
    }

    func testRepairAndRemovalAffectOnlyMatchingMac() throws {
        var saved = SavedConnections(legacy: try connection("studio"))
        saved.save(try connection("laptop"))
        saved.save(try connection("studio", token: "new", device: "new-device"))
        XCTAssertEqual(saved.connections.count, 2)
        XCTAssertEqual(saved.connections.first?.credential.deviceId, "new-device")
        try saved.select("studio")
        saved.remove("studio")
        XCTAssertEqual(saved.connections.first?.credential.hostInstallationId, "laptop")
        XCTAssertTrue(saved.selectedHostIDs.isEmpty)
        saved.remove("laptop")
        let restored = try JSONDecoder().decode(SavedConnections.self, from: JSONEncoder().encode(saved))
        XCTAssertTrue(restored.connections.isEmpty)
        XCTAssertThrowsError(try saved.select("missing"))
    }
}
