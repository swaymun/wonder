import XCTest
@testable import WonderPairing

/// The composer offers both providers' models for a Project thread. A model of
/// the thread's own provider is saved as before; one of the other provider
/// travels with the next message and the host moves the thread on delivery.
final class ProjectProviderSwitchTests: XCTestCase {
    private func models() throws -> [BotOptions.Model] {
        let json = #"""
        {"models":[
         {"id":"gpt-a","displayName":"GPT A","hidden":false,"reasoningEfforts":[],"agentFamily":"codex"},
         {"id":"claude:sonnet","displayName":"Sonnet","hidden":false,"reasoningEfforts":[{"id":"high","label":"High"}],"defaultReasoningEffort":"high","agentFamily":"claude"},
         {"id":"claude:hidden","displayName":"Hidden","hidden":true,"reasoningEfforts":[],"agentFamily":"claude"},
         {"id":"gpt-b","displayName":"GPT B","hidden":false,"reasoningEfforts":[],"agentFamily":"codex"}],
         "timezone":"UTC","allowedApprovalPolicies":[]}
        """#
        return try JSONDecoder().decode(BotOptions.self, from: Data(json.utf8)).models
    }

    func testModelsAreGroupedByProviderWithTheThreadsOwnFirst() throws {
        let all = try models()
        let fromCodex = ProjectModelPicker.groups(models: all, current: .codex)
        XCTAssertEqual(fromCodex.map(\.family), [.codex, .claude])
        XCTAssertEqual(fromCodex[0].models.map(\.id), ["gpt-a", "gpt-b"])
        XCTAssertEqual(fromCodex[1].models.map(\.id), ["claude:sonnet"], "hidden models stay hidden")
        let fromClaude = ProjectModelPicker.groups(models: all, current: .claude)
        XCTAssertEqual(fromClaude.map(\.family), [.claude, .codex])
        // A provider with nothing to offer has no empty group.
        let onlyCodex = all.filter { $0.family == .codex }
        XCTAssertEqual(ProjectModelPicker.groups(models: onlyCodex, current: .claude).map(\.family), [.codex])
    }

    func testOnlyTheOtherProvidersGroupExplainsWhatTheChoiceDoes() throws {
        let groups = ProjectModelPicker.groups(models: try models(), current: .codex)
        XCTAssertTrue(groups[1].note?.contains("fresh Claude session") == true)
        XCTAssertTrue(groups[1].note?.contains("summary-free copy of recent messages") == true)
        XCTAssertTrue(groups[1].note?.contains("Older details stay readable") == true || groups[1].note?.contains("older details stay readable") == true)
    }

    func testAModelOfTheSameProviderIsSavedAndAnotherProvidersTravelsWithTheMessage() throws {
        let all = try models()
        let gpt = all.first { $0.id == "gpt-b" }!
        let sonnet = all.first { $0.id == "claude:sonnet" }!
        XCTAssertEqual(ProjectModelPicker.choice(current: .codex, option: gpt, effort: nil, serviceTier: nil), .saveToThread)
        XCTAssertEqual(
            ProjectModelPicker.choice(current: .codex, option: sonnet, effort: "high", serviceTier: "fast"),
            .sendWithNextMessage(ProjectMessageModel(family: .claude, model: "claude:sonnet", effort: "high", serviceTier: "fast")))
        XCTAssertEqual(ProjectModelPicker.choice(current: .claude, option: sonnet, effort: nil, serviceTier: nil), .saveToThread)
    }

    private func detail(family: String, model: String) throws -> ProjectConversationDetail {
        let json = #"""
        {"conversationId":"c","projectId":"p","projectName":"App","title":"Fix","family":"\#(family)","model":"\#(model)",
         "accessMode":"workspace","workingFolder":"/work","workingFolderName":"work","isPinned":false,"hasUnread":false,
         "hasNativeSession":true,"folderInProject":true}
        """#
        return try JSONDecoder().decode(ProjectConversationDetail.self, from: Data(json.utf8))
    }

    func testACarriedChoiceEndsOnlyOnceTheHostHasMovedTheThread() throws {
        let pending = ProjectMessageModel(family: .claude, model: "claude:sonnet")
        XCTAssertFalse(ProjectModelPicker.isApplied(pending, to: nil))
        XCTAssertFalse(ProjectModelPicker.isApplied(pending, to: try detail(family: "codex", model: "gpt-a")))
        XCTAssertFalse(ProjectModelPicker.isApplied(pending, to: try detail(family: "claude", model: "claude:opus")))
        XCTAssertTrue(ProjectModelPicker.isApplied(pending, to: try detail(family: "claude", model: "claude:sonnet")))
    }

    func testTheMessageRequestCarriesItsModelAndOlderRequestsStillDecode() throws {
        var intent = ComposerIntent()
        intent.draft = "Continue in Claude"
        try intent.begin(device: "phone", projectModel: ProjectMessageModel(family: .claude, model: "claude:sonnet", effort: "high"))
        let request = try XCTUnwrap(intent.pending?.request)
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        let model = try XCTUnwrap(wire?["projectModel"] as? [String: Any])
        XCTAssertEqual(model["family"] as? String, "claude")
        XCTAssertEqual(model["model"] as? String, "claude:sonnet")
        XCTAssertEqual(model["effort"] as? String, "high")
        XCTAssertNil(model["serviceTier"])
        // A send saved before this existed decodes without a model, and an
        // ordinary send does not name one.
        var old = try XCTUnwrap(wire)
        old.removeValue(forKey: "projectModel")
        let decoded = try JSONDecoder().decode(SendRequest.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.projectModel)
        var plain = ComposerIntent()
        plain.draft = "Hello"
        try plain.begin(device: "phone")
        XCTAssertNil(plain.pending?.request.projectModel)
        // The saved send keeps the model across a relaunch, so a retry sends the same one.
        let restored = try JSONDecoder().decode(SendRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(restored.projectModel, request.projectModel)
    }

    func testTheSwitchRowIsATimelineMarkerNotAnActivityGroup() {
        func row(_ id: String, _ type: String, text: String?) -> ReadRow {
            ReadRow(id: id, author: "Ada", text: "", isUser: false, timestamp: "1000", turnId: "provider-switch-1",
                    item: ReadItem(id: id, type: type, state: "completed", text: text, createdAt: "1000", payload: [:]))
        }
        let marker = row("provider-switch-1", "providerSwitch",
                         text: "Switched to Claude Sonnet · Codex history was handed over (14 of 40 messages; the agent can read the rest)")
        XCTAssertTrue(marker.isProviderSwitch)
        XCTAssertFalse(marker.isContextCompaction)
        XCTAssertEqual(marker.providerSwitchText?.hasPrefix("Switched to Claude Sonnet"), true)
        XCTAssertNil(row("blank", "providerSwitch", text: "  ").providerSwitchText)
        let entries = ChatFeedEntry.grouping([row("command", "commandExecution", text: nil), marker, row("later", "commandExecution", text: nil)])
        XCTAssertEqual(entries.count, 3, "commands do not merge across the switch")
        XCTAssertTrue(entries[1].isTimelineMarker)
        XCTAssertFalse(entries[1].isActivity)
        let visible = ChatFeedNode.visible(entries, expanded: [])
        XCTAssertTrue(visible.contains { if case .compaction = $0.content { return true } else { return false } })
    }
}
