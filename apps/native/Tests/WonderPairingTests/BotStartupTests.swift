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

    func testStartupWaitsUntilItsQuestionIsOnTheDeviceAndDoesNotRequireAnAnswer() throws {
        let question = try JSONDecoder().decode(AsyncQuestion.self, from: Data(#"{"id":"purpose","conversationId":"bot","turnId":"init","itemId":"wonder-purpose","questions":[{"title":"What should I help with?","options":["Build","Research"]}],"state":"pending","expiresAtMs":9999999999999}"#.utf8))
        XCTAssertTrue(BotInitialization().isWaiting(questions: []))
        XCTAssertTrue(BotInitialization(questionId: "purpose").isWaiting(questions: []))
        XCTAssertTrue(BotInitialization(questionId: "other").isWaiting(questions: [question]))
        XCTAssertFalse(BotInitialization(questionId: "purpose").isWaiting(questions: [question]))

        var snapshot = ConversationSnapshot(conversationId: "bot", hostEpoch: "epoch", lastSequence: 1, messages: [], assistantMessages: [], thread: ThreadProjection(nextCursor: nil, hydrated: false), initialization: BotInitialization())
        let cached = try JSONDecoder().decode(ConversationSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertTrue(try XCTUnwrap(cached.initialization).isWaiting(questions: []))
        snapshot.initialization = nil
        XCTAssertNil(try snapshot.mergingOlder(cached).initialization, "Fresh readiness must win over a cached loading state")
    }

    func testNewBotDefaultsVaryAndRemainStable() {
        let identities = (0..<100).map { "bot-\($0)" }
        XCTAssertEqual(Set(identities.map(ScienceAvatarCatalog.stableShape)).count, 7)
        XCTAssertEqual(Set(identities.map(ScienceAvatarCatalog.stablePalette)).count, 12)
        XCTAssertEqual(ScienceAvatarCatalog.stableShape(for: "bot-id"), .luna)
        XCTAssertEqual(ScienceAvatarCatalog.stablePalette(for: "bot-id"), "violet")
    }
}
