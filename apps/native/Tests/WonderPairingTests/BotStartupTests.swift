import XCTest
@testable import WonderPairing

final class BotStartupTests: XCTestCase {
    func testSavedBotAppearanceRestoresWithChatsAndSupportsOldCaches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadStore(root: root, host: "Mac", device: "phone")
        let bot = try JSONDecoder().decode(ManagedBot.self, from: Data(#"{"id":"bot","name":"Bot","role":"Test","systemPrompt":"","workspacePath":"/Bot","permissionProfile":":workspace","isArchived":false,"avatarShape":"luna","avatarPalette":"ocean"}"#.utf8))
        var state = ProjectionState()
        state.managedBots = [bot]
        try store.save(state)
        let restored = try ReadStore(root: root, host: "Mac", device: "phone").load()
        XCTAssertEqual(restored.managedBots?.first?.avatarShape, "luna")
        XCTAssertEqual(restored.managedBots?.first?.avatarPalette, "ocean")
        XCTAssertNil(try ReadStore(root: root, host: "Other Mac", device: "phone").load().managedBots)

        var oldCache = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        oldCache.removeValue(forKey: "managedBots")
        let migrated = try JSONDecoder().decode(ProjectionState.self, from: JSONSerialization.data(withJSONObject: oldCache))
        XCTAssertNil(migrated.managedBots)
    }

    func testFirstModelRevisionSurvivesOutboxAndReadCache() throws {
        let bot = try JSONDecoder().decode(ManagedBot.self, from: Data(#"{"id":"bot","name":"Luna","role":"Test","systemPrompt":"","workspacePath":"/Bot","permissionProfile":":workspace","isArchived":false,"modelSelectionRevision":3}"#.utf8))
        XCTAssertEqual(bot.modelSelectionRevision, 3)
        var intent = ComposerIntent()
        intent.draft = "First task"
        try intent.begin(device: "phone", modelSelectionRevision: bot.modelSelectionRevision)
        let restored = try JSONDecoder().decode(ComposerIntent.self, from: JSONEncoder().encode(intent))
        XCTAssertEqual(restored.pending?.request.modelSelectionRevision, 3)
        XCTAssertEqual(restored.pending?.request.clientMessageId, intent.pending?.request.clientMessageId)
        XCTAssertEqual(restored.pending?.request.body, "First task")
        var oldRequest = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.pending!.request)) as? [String: Any])
        oldRequest.removeValue(forKey: "modelSelectionRevision")
        XCTAssertNil(try JSONDecoder().decode(SendRequest.self, from: JSONSerialization.data(withJSONObject: oldRequest)).modelSelectionRevision)
        var state = ProjectionState()
        state.managedBots = [bot]
        XCTAssertEqual(try JSONDecoder().decode(ProjectionState.self, from: JSONEncoder().encode(state)).managedBots?.first?.modelSelectionRevision, 3)
    }

    func testNewBotDefaultsVaryAndRemainStable() {
        let identities = (0..<100).map { "bot-\($0)" }
        XCTAssertEqual(Set(identities.map(ScienceAvatarCatalog.stableShape)).count, 7)
        XCTAssertEqual(Set(identities.map(ScienceAvatarCatalog.stablePalette)).count, 12)
        XCTAssertEqual(ScienceAvatarCatalog.stableShape(for: "bot-id"), .luna)
        XCTAssertEqual(ScienceAvatarCatalog.stablePalette(for: "bot-id"), "violet")
    }
}
