import XCTest
@testable import WonderPairing

// Contract: Settings offers only what the Mac's catalog lists for a harness,
// shows a stored choice the catalog dropped as Wonder's default, and sends
// explicit nulls so a cleared effort or speed is cleared on the Mac.
final class DefaultModelsTests: XCTestCase {
    private func options() throws -> [BotOptions.Model] {
        let json = #"{"models":[{"id":"gpt-a","agentFamily":"codex","displayName":"GPT A","hidden":false,"reasoningEfforts":[{"id":"low","label":"Low"},{"id":"high","label":"High"}],"serviceTiers":[{"id":"default","label":"Standard"},{"id":"priority","label":"Fast"}]},{"id":"gpt-b","agentFamily":"codex","displayName":"GPT B","hidden":false,"reasoningEfforts":[{"id":"low","label":"Low"}]},{"id":"gpt-hidden","agentFamily":"codex","displayName":"Hidden","hidden":true,"reasoningEfforts":[]},{"id":"claude:sonnet","agentFamily":"claude","displayName":"Sonnet","hidden":false,"reasoningEfforts":[{"id":"high","label":"High"}]}],"allowedApprovalPolicies":[],"approvalModes":[]}"#
        return try JSONDecoder().decode(BotOptions.self, from: Data(json.utf8)).models
    }

    func testChoicesAreLimitedToTheHarnessAndHideHiddenModels() throws {
        let choices = DefaultModelChoices(family: .codex, options: try options(), stored: .init(family: .codex))
        XCTAssertEqual(choices.models.map(\.id), ["gpt-a", "gpt-b"])
        XCTAssertEqual(choices.summary, "Wonder’s default")
        XCTAssertTrue(choices.efforts.isEmpty)
    }

    func testAStoredChoiceTheCatalogDroppedFallsBackToWondersDefault() throws {
        let gone = DefaultModelChoices(family: .codex, options: try options(), stored: .init(family: .codex, model: "retired", effort: "high"))
        XCTAssertNil(gone.selected.model)
        XCTAssertNil(gone.selected.effort)
        // The model stays, but an effort it no longer offers is dropped.
        let stale = DefaultModelChoices(family: .codex, options: try options(), stored: .init(family: .codex, model: "gpt-b", effort: "high", serviceTier: "priority"))
        XCTAssertEqual(stale.selected, .init(family: .codex, model: "gpt-b"))
        let kept = DefaultModelChoices(family: .codex, options: try options(), stored: .init(family: .codex, model: "gpt-a", effort: "high", serviceTier: "priority"))
        XCTAssertEqual(kept.summary, "GPT A · High")
        XCTAssertEqual(kept.speeds.map(\.id), ["default", "priority"])
    }

    func testChangingTheModelDropsWhatItDoesNotOfferAndTheBodySendsNulls() throws {
        let kept = DefaultModelChoices(family: .codex, options: try options(), stored: .init(family: .codex, model: "gpt-a", effort: "high", serviceTier: "priority"))
        let switched = kept.choosing(model: "gpt-b")
        XCTAssertEqual(switched, .init(family: .codex, model: "gpt-b"))
        XCTAssertEqual(kept.choosing(model: nil), .init(family: .codex))
        let body = try JSONSerialization.jsonObject(with: DefaultModelChoices.body(switched)) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "gpt-b")
        XCTAssertTrue(body?["effort"] is NSNull)
        XCTAssertTrue(body?["serviceTier"] is NSNull)
        XCTAssertEqual(DefaultModelChoices.path(.claude), "/api/v1/settings/default-models/claude")
    }

    func testPreferencesDecodeFromTheHost() throws {
        let json = #"{"families":[{"family":"codex","model":null,"effort":null,"serviceTier":null},{"family":"claude","model":"claude:sonnet","effort":"high","serviceTier":null}]}"#
        let preferences = try JSONDecoder().decode(DefaultModelPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(preferences.entry(.claude).model, "claude:sonnet")
        XCTAssertNil(preferences.entry(.codex).model)
    }
}
