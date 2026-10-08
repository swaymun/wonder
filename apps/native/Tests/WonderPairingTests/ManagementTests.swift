import XCTest
@testable import WonderPairing

final class ManagementTests: XCTestCase {
    // Group routing must use the selected provider's approval choices,
    // including an SDK model with no reasoning control and additive metadata.
    func testGroupRoutingUsesTheSelectedProvidersApprovalChoicesAndAcceptsAdditiveModelMetadata() throws {
        let options = try JSONDecoder().decode(BotOptions.self, from: Data(#"{"models":[{"id":"claude:haiku","agentFamily":"claude","displayName":"Haiku 4.5","hidden":false,"reasoningEfforts":[],"capabilities":{"guide":false,"goals":false,"imageGeneration":false,"futureCapability":true},"futureSDKField":{}}],"allowedApprovalPolicies":[],"approvalModes":[{"id":"approve-for-me","allowed":true}],"permissionsByFamily":{"claude":{"permissionModes":[{"id":"workspace","allowed":true}],"approvalModes":[{"id":"ask-for-approval","allowed":true},{"id":"full-access","allowed":true}]}}}"#.utf8))
        XCTAssertEqual(options.models.first?.family, .claude)
        XCTAssertEqual(options.models.first?.capabilities?.guide, false)
        XCTAssertEqual(try NewBotDefaults(model: "claude:haiku").creationValues(options: options), ["model":"claude:haiku", "approvalMode":"ask-for-approval"])
        XCTAssertThrowsError(try NewBotDefaults(model: "claude:haiku", approvalMode: .approveForMe).creationValues(options: options))
        XCTAssertThrowsError(try NewBotDefaults(model: "claude:haiku", reasoningEffort: "high").creationValues(options: options))
    }
    // The family is whatever the host sent. A model id that looks like another
    // provider's, or one the host did not list, never changes it.
    func testFamilyComesFromTheHostNotTheModelId() throws {
        let options = try JSONDecoder().decode(BotOptions.self, from: Data(#"{"models":[{"id":"claude:lookalike","agentFamily":"codex","displayName":"Lookalike","hidden":false,"reasoningEfforts":[]},{"id":"plain","displayName":"Old host","hidden":false,"reasoningEfforts":[]}],"allowedApprovalPolicies":[],"approvalModes":[{"id":"ask-for-approval","allowed":true}],"permissionsByFamily":{"claude":{"permissionModes":[],"approvalModes":[{"id":"full-access","allowed":true}]}}}"#.utf8))
        XCTAssertEqual(options.models[0].family, .codex)
        XCTAssertEqual(options.models[1].family, .codex)
        XCTAssertEqual(options.approvalChoices(model: "claude:lookalike")?.map(\.id), ["ask-for-approval"])
        XCTAssertNil(options.approvalChoices(model: "claude:unlisted"))
    }
    func testGlobalDefaultsSurviveDraftRemovalAndAreValidatedAgainstHostChoices() throws {
        let suite = "WonderDefaultsTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let json = #"{"models":[{"id":"model","displayName":"Model","hidden":false,"reasoningEfforts":[{"id":"low","label":"Low"},{"id":"high","label":"High"}],"defaultReasoningEffort":"low"}],"timezone":"UTC","allowedApprovalPolicies":[],"approvalModes":[{"id":"ask-for-approval","allowed":true},{"id":"approve-for-me","allowed":true},{"id":"full-access","allowed":true}]}"#
        let options = try JSONDecoder().decode(BotOptions.self, from: Data(json.utf8))
        try NewBotDefaults(model: "model", reasoningEffort: "high").save(to: preferences)
        var draft = ManagementDraft(); draft.values = ["name": "Ada"]
        let first = ManagementDraftStore(host: "first", defaults: preferences)
        let second = ManagementDraftStore(host: "second", defaults: preferences)
        try first.save(draft, key: "create")
        try second.save(draft, key: "create")
        first.removeAll()
        XCTAssertEqual(NewBotDefaults.load(from: preferences).reasoningEffort, "high")
        XCTAssertEqual(second.load("create")?.values["name"], "Ada")
        XCTAssertEqual(try NewBotDefaults.load(from: preferences).creationValues(options: options)["reasoningEffort"], "high")
        XCTAssertEqual(try NewBotDefaults().creationValues(options: options)["reasoningEffort"], "low")
        XCTAssertThrowsError(try NewBotDefaults(model: "missing").creationValues(options: options))
        XCTAssertThrowsError(try NewBotDefaults(model: "model", reasoningEffort: "light").creationValues(options: options))
    }
    func testGroupParticipationDefaultsFreezeSpeedWithPendingSend() throws {
        let suite = "group-defaults-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ModelDefaultPurpose.groupParticipation.initial.reasoningEffort, "xhigh")
        // An explicit prior choice must win over the faster unsaved default.
        let selection = NewBotDefaults(model: "luna", reasoningEffort: "xhigh", serviceTier: "priority")
        try selection.save(to: preferences, key: ModelDefaultPurpose.groupParticipation.key)
        XCTAssertEqual(NewBotDefaults.load(from: preferences, key: ModelDefaultPurpose.groupParticipation.key), selection)
        let options = try JSONDecoder().decode(BotOptions.self, from: Data(#"{"models":[{"id":"luna","displayName":"Luna","hidden":false,"reasoningEfforts":[{"id":"xhigh","label":"Extra high"}],"serviceTiers":[{"id":"priority","label":"Fast"}]}],"timezone":"UTC","allowedApprovalPolicies":[],"approvalModes":[{"id":"ask-for-approval","allowed":true},{"id":"approve-for-me","allowed":true},{"id":"full-access","allowed":true}]}"#.utf8))
        XCTAssertEqual(try selection.creationValues(options: options)["serviceTier"], "priority")
        XCTAssertThrowsError(try NewBotDefaults(model: "luna", reasoningEffort: "xhigh", serviceTier: "unknown").creationValues(options: options))
        var composer = ComposerIntent(); composer.draft = "Review this together"
        try composer.begin(device: "phone", groupRouting: selection)
        let restored = try JSONDecoder().decode(ComposerIntent.self, from: JSONEncoder().encode(composer))
        XCTAssertEqual(restored.pending?.request.groupRouting, selection)
    }
    func testCollaborativeFeedHidesInitializationAndShowsProfileAsStatus() throws {
        let json = #"{"id":"g","conversationId":"chat","name":"Team","isArchived":false,"messages":[{"messageId":"init","body":"Internal instructions","createdAt":"0","authorKind":"user","presentationKind":"status"},{"messageId":"name","body":"Updated Design Team","createdAt":"1","authorKind":"member","authorBotName":"Ada","presentationKind":"status","outcome":"completed"},{"messageId":"reply","body":"A useful answer","createdAt":"2","authorKind":"member","authorBotName":"Ada","presentationKind":"message","outcome":"completed"}]}"#
        let group = try JSONDecoder().decode(GroupRead.self, from: Data(json.utf8))
        XCTAssertEqual(group.rows.count, 2)
        XCTAssertEqual(group.rows.first?.profileStatus, "Updated Design Team")
        XCTAssertNil(group.rows.last?.profileStatus)
    }
    private func row(_ id: String, bot: String = "ada", user: Bool = false, commentary: Bool = false) -> ReadRow {
        ReadRow(id: id, author: bot == "ada" ? "Ada" : "Lin", text: "Hello", isUser: user, timestamp: "0", authorId: user ? nil : bot, item: commentary ? ReadItem(id: id, type: "agentMessage", state: "completed", text: "Hello", createdAt: "0", payload: ["phase": .string("commentary")]) : nil)
    }
    func testDirectRepliesNeverRepeatIdentityIncludingCommentary() {
        XCTAssertFalse(SpeakerPresentation.showsIdentity(row: row("1"), previous: nil, isGroup: false))
        XCTAssertFalse(SpeakerPresentation.showsIdentity(row: row("2", commentary: true), previous: row("1", user: true), isGroup: false))
    }
    func testGroupIdentityOnlyOnSpeakerChanges() {
        XCTAssertTrue(SpeakerPresentation.showsIdentity(row: row("1"), previous: nil, isGroup: true))
        XCTAssertFalse(SpeakerPresentation.showsIdentity(row: row("2"), previous: row("1"), isGroup: true))
        XCTAssertTrue(SpeakerPresentation.showsIdentity(row: row("3", bot: "lin"), previous: row("2"), isGroup: true))
        XCTAssertTrue(SpeakerPresentation.showsIdentity(row: row("4"), previous: row("3", user: true), isGroup: true))
        XCTAssertFalse(SpeakerPresentation.showsIdentity(row: row("5", user: true), previous: row("4"), isGroup: true))
    }
    func testDraftRoundTripPartitionsHostsAndPreservesRequestIdentity() throws {
        let suite = "WonderManagementTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ManagementDraftStore(host: "first", defaults: defaults)
        let second = ManagementDraftStore(host: "second", defaults: defaults)
        var draft = ManagementDraft(); draft.values = ["name": "Ada", "prompt": "Check tomorrow’s weather"]
        try first.save(draft, key: "new")
        XCTAssertEqual(first.load("new"), draft)
        XCTAssertNil(second.load("new"))
        try second.save(draft, key: "new")
        first.removeAll()
        XCTAssertNil(first.load("new"))
        XCTAssertEqual(second.load("new")?.requestId, draft.requestId)
    }
    func testBotAndOptionsDecodeDaemonContract() throws {
        let bot = try JSONDecoder().decode(ManagedBot.self, from: Data(##"{"id":"ada","name":"Ada","role":"Research","systemPrompt":"Read carefully","workspacePath":"/Bots/ada","permissionProfile":"bot-ada","model":null,"reasoningEffort":null,"serviceTier":null,"isArchived":false,"conversationId":"chat","avatarColor":"#ffb51c","avatarShape":"orbit","avatarPalette":"coral","workingDirectory":"/Projects/report"}"##.utf8))
        XCTAssertEqual(bot.avatarColor, "#ffb51c")
        XCTAssertEqual(bot.avatarShape, "orbit")
        XCTAssertEqual(bot.avatarPalette, "coral")
        XCTAssertEqual(bot.workingDirectory, "/Projects/report")
        XCTAssertEqual(bot.conversationId, "chat")
        let options = try JSONDecoder().decode(BotOptions.self, from: Data(##"{"models":[{"id":"model","displayName":"Model","description":null,"modelSpecialty":null,"hidden":false,"reasoningEfforts":[{"id":"high","label":"High","description":null}],"defaultReasoningEffort":"high","serviceTiers":[{"id":"default","label":"Standard","description":"Standard speed, standard usage"},{"id":"priority","label":"Fast","description":"2x speed, increased usage"}],"defaultServiceTier":null}],"timezone":"America/New_York","allowedApprovalPolicies":["never"]}"##.utf8))
        XCTAssertEqual(options.models.first?.displayName, "Model")
        XCTAssertEqual(options.models.first?.reasoningEfforts.first?.id, "high")
        XCTAssertEqual(options.models.first?.serviceTiers?.last?.id, "priority")
        XCTAssertEqual(options.models.first?.serviceTiers?.last?.description, "2x speed, increased usage")
        XCTAssertEqual(options.timezone, "America/New_York")
    }

    func testScienceAvatarCatalogAndLegacyClientRoundTrips() throws {
        XCTAssertEqual(ScienceAvatarCatalog.sourceVersion, "science-avatar-v1")
        XCTAssertEqual(ScienceAvatarCatalog.sourceHash.count, 64)
        XCTAssertEqual(ScienceAvatarCatalog.sourceHash, "9324e397b3c5d27dd693bac25f5a776d451fb7ad941f7567f21446e79fc63c3a")
        XCTAssertEqual(ScienceAvatarCatalog.shapes.count, 7)
        XCTAssertEqual(ScienceAvatarCatalog.palettes.count, 12)
        XCTAssertEqual(ScienceAvatarCatalog.defaultShape, .sun)
        XCTAssertEqual(ScienceAvatarCatalog.defaultPalette, "amber")
        XCTAssertEqual(ScienceAvatarCatalog.stableShape(for: "bot-id"), .luna)
        XCTAssertEqual(ScienceAvatarCatalog.stableShape(for: "bot-id"), ScienceAvatarCatalog.stableShape(for: "bot-id"))

        let old = try JSONDecoder().decode(ManagedBot.self, from: Data(#"{"id":"old","name":"Old","role":"Helper","systemPrompt":"Help","workspacePath":"/Bots/old","permissionProfile":"bot-old","isArchived":false}"#.utf8))
        XCTAssertNil(old.avatarShape)
        XCTAssertNil(old.avatarPalette)

        let future = try JSONDecoder().decode(ManagedBot.self, from: Data(##"{"id":"future","name":"Future","role":"Helper","systemPrompt":"Help","workspacePath":"/Bots/future","permissionProfile":"bot-future","isArchived":false,"avatarShape":"future-character","avatarPalette":"future-palette","avatarColor":"#123456"}"##.utf8))
        XCTAssertEqual(future.avatarShape, "future-character")
        XCTAssertEqual(future.avatarPalette, "future-palette")
        let encoded = try JSONEncoder().encode(future)
        let roundTrip = try JSONDecoder().decode(ManagedBot.self, from: encoded)
        XCTAssertEqual(roundTrip.avatarShape, future.avatarShape)
        XCTAssertEqual(roundTrip.avatarPalette, future.avatarPalette)
        XCTAssertEqual(roundTrip.avatarColor, future.avatarColor)
    }

    func testScienceAvatarLegacyColorsUseCompleteMappingsAndNearestFallback() {
        XCTAssertEqual(ScienceAvatarPalette.legacyID(for: "#9A7253"), "amber")
        XCTAssertEqual(ScienceAvatarPalette.legacyID(for: "#168C8C"), "teal")
        XCTAssertEqual(ScienceAvatarPalette.legacyID(for: "#123456"), "teal")
        XCTAssertNil(ScienceAvatarPalette.legacyID(for: "not-a-color"))
        XCTAssertEqual(ScienceAvatarPalette.resolve(nil, legacyColor: "#123456").id, "teal")
        XCTAssertEqual(ScienceAvatarPalette.resolve("future-palette", legacyColor: "#123456").id, "amber")
    }

    func testBotPermissionModesDecodeWithoutUpgradingLegacyBots() throws {
        let base: [String: Any] = ["id": "ada", "name": "Ada", "role": "Research", "systemPrompt": "Read carefully", "workspacePath": "/Bots/ada", "permissionProfile": "bot-ada", "isArchived": false]
        let legacy = try JSONDecoder().decode(ManagedBot.self, from: JSONSerialization.data(withJSONObject: base))
        XCTAssertNil(legacy.permissionMode)
        for mode in BotPermissionMode.allCases {
            var object = base; object["permissionMode"] = mode.rawValue
            let bot = try JSONDecoder().decode(ManagedBot.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(bot.permissionMode, mode.rawValue)
        }
        let options = try JSONDecoder().decode(BotOptions.self, from: Data(#"{"models":[],"timezone":"UTC","allowedApprovalPolicies":[],"permissionModes":[{"id":"read-only","allowed":true},{"id":"workspace","allowed":false},{"id":"full-access","allowed":true}]}"#.utf8))
        XCTAssertEqual(options.permissionModes?.map(\.allowed), [true, false, true])
    }

    func testApprovalModesUseExactWireIDsAndOldComposerOptionsRemainActionable() throws {
        XCTAssertEqual(BotApprovalMode.allCases.map(\.rawValue), ["ask-for-approval", "approve-for-me", "full-access"])
        XCTAssertEqual(BotApprovalMode.allCases.map(\.title), ["Ask for approval", "Approve for me", "Full access"])

        // This is the old composer-options response shape: no timezone and no
        // approvalModes field. It must decode so the UI can show its update state.
        let oldJSON = #"{"models":[{"id":"model","displayName":"Model","hidden":false,"reasoningEfforts":[]}],"allowedApprovalPolicies":["on-request"],"permissionModes":[{"id":"read-only","allowed":true},{"id":"workspace","allowed":true},{"id":"full-access","allowed":true}]}"#
        let oldOptions = try JSONDecoder().decode(BotOptions.self, from: Data(oldJSON.utf8))
        XCTAssertNil(oldOptions.timezone)
        XCTAssertNil(oldOptions.approvalModes)
        XCTAssertThrowsError(try NewBotDefaults().creationValues(options: oldOptions)) { error in
            XCTAssertEqual((error as? NewBotDefaults.SelectionError), .unavailableApprovalMode)
        }

        let newJSON = #"{"models":[{"id":"model","displayName":"Model","hidden":false,"reasoningEfforts":[]}],"timezone":"UTC","allowedApprovalPolicies":["on-request"],"approvalModes":[{"id":"ask-for-approval","allowed":true},{"id":"approve-for-me","allowed":false},{"id":"full-access","allowed":true}]}"#
        let newOptions = try JSONDecoder().decode(BotOptions.self, from: Data(newJSON.utf8))
        XCTAssertEqual(try NewBotDefaults(approvalMode: .askForApproval).creationValues(options: newOptions)["approvalMode"], "ask-for-approval")
        XCTAssertThrowsError(try NewBotDefaults(approvalMode: .approveForMe).creationValues(options: newOptions))
        XCTAssertEqual(try NewBotDefaults(approvalMode: .fullAccess).creationValues(options: newOptions)["approvalMode"], "full-access")

        let legacyDefaults = try JSONDecoder().decode(NewBotDefaults.self, from: Data(#"{"model":"model","reasoningEffort":""}"#.utf8))
        XCTAssertEqual(legacyDefaults.approvalMode, .askForApproval)
        let queued = try JSONDecoder().decode(QueuedMessage.self, from: Data(#"{"id":"q","clientMessageId":"c","body":"Work","revision":1,"attachmentIds":[],"executionSettings":{"model":"model","reasoningEffort":null,"serviceTier":null,"permissionMode":"read-only","approvalMode":"approve-for-me","workingDirectory":"/Projects/report"}}"#.utf8))
        XCTAssertEqual(queued.executionSettings?.approvalMode, "approve-for-me")
        XCTAssertEqual(queued.executionSettings?.workingDirectory, "/Projects/report")
    }

    func testDeletedConversationIntentRemovalDoesNotRemoveAnotherChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadStore(root: root, host: "host", device: "phone")
        try store.saveIntent(Data("deleted draft".utf8), conversation: "deleted")
        try store.saveIntent(Data("retained draft".utf8), conversation: "retained")
        try store.removeIntent(conversation: "deleted")
        try store.removeIntent(conversation: "deleted")
        XCTAssertNil(try store.loadIntent(conversation: "deleted"))
        XCTAssertEqual(try store.loadIntent(conversation: "retained"), Data("retained draft".utf8))
    }

}
