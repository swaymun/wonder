import XCTest
@testable import WonderPairing

private final class ProjectSubagentResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "project-agents.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let roster = #"{"available":true,"detail":null,"subagents":[{"parentConversationId":"project parent","threadId":"child/thread","title":"Scout","agentNickname":"Scout","agentRole":"research","status":"active","isArchived":false,"canAcceptDirectInput":false}]}"#
        let transcript = #"{"subagent":{"parentConversationId":"project parent","threadId":"child/thread","title":"Scout","agentNickname":"Scout","agentRole":"research","status":"completed","isArchived":false,"canAcceptDirectInput":false},"snapshot":{"conversationId":"project-agent:project parent:child/thread","hostEpoch":"epoch","lastSequence":0,"messages":[],"assistantMessages":[],"thread":{"threadId":"child/thread","turns":[{"id":"turn","status":"completed","startedAt":null,"completedAt":null,"items":[{"id":"answer","type":"agentMessage","state":"completed","text":"Found the issue","createdAt":"2026-10-02T00:00:00Z","payload":{}}]}],"nextCursor":null,"hydrated":false},"events":[]}}"#
        let value: String?
        switch request.url?.absoluteString {
        case "https://project-agents.invalid/api/v1/project-conversations/project%20parent/subagents":
            value = roster
        case "https://project-agents.invalid/api/v1/project-conversations/project%20parent/subagents/child%2Fthread/transcript?cursor=older%2Bpage":
            value = transcript
        default:
            value = nil
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: value == nil ? 404 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let value { client?.urlProtocol(self, didLoad: Data(value.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ProjectsTests: XCTestCase {
    private func project(_ id: String, pinned: Bool = false, included: Bool = true, family: AgentFamily? = nil) -> ProjectSummary {
        ProjectSummary(id: id, name: id.capitalized, isIncluded: included, isPinned: pinned,
                       folders: [ProjectFolder(id: id + "-root", path: "/work/" + id, name: id, isPrimary: true, isAvailable: true)],
                       lastFamily: family)
    }
    private func thread(_ reference: String, conversation: String? = nil, pinned: Bool = false, title: String? = nil, family: AgentFamily = .codex) -> ProjectThreadSummary {
        ProjectThreadSummary(reference: reference, conversationId: conversation, title: title ?? reference, family: family,
                             updatedAt: 1, isPinned: pinned)
    }

    // Contract: responses captured from a real host decode without loss, so
    // the phone and Mac agree on the published HTTP schema.
    func testHostResponsesDecode() throws {
        let projects = try JSONDecoder().decode(ProjectsResponse.self, from: Data(#"{"projects":[{"id":"p","name":"Codex P0","isIncluded":true,"isPinned":false,"rootsRevision":1,"folders":[{"id":"f","path":"/Users/owner/app","name":"app","isPrimary":true,"isAvailable":true}],"lastFamily":null,"lastUsedAt":null,"createdAt":"2026-09-30T02:18:38.447Z"}],"families":[{"family":"codex","available":true},{"family":"claude","available":true}]}"#.utf8))
        XCTAssertEqual(projects.projects.first?.primaryFolder?.path, "/Users/owner/app")
        XCTAssertNil(projects.archiveVersion, "Older hosts do not offer Archive")
        let page = try JSONDecoder().decode(ProjectThreadsPage.self, from: Data(#"{"threads":[{"reference":"claude:a0b0","conversationId":"f861","title":"Wonder-p0","family":"claude","updatedAt":1790735086,"isPinned":false,"hasUnread":true,"isWorking":false}],"nextCursor":null,"partial":[]}"#.utf8))
        XCTAssertEqual(page.threads.first?.family, .claude)
        let detail = try JSONDecoder().decode(ProjectConversationDetail.self, from: Data(#"{"conversationId":"c","projectId":"p","projectName":"Codex P0","title":"t","family":"codex","model":"gpt-5.6-luna","effort":"low","serviceTier":"fast","accessMode":"read_only","workingFolder":"/w","workingFolderName":"w","isPinned":false,"hasUnread":false,"hasNativeSession":true,"folderInProject":true,"notice":null}"#.utf8))
        XCTAssertEqual(detail.accessMode, .readOnly)
        XCTAssertEqual(detail.serviceTier, "fast")
        XCTAssertNil(detail.isArchived)
        let encoded = try JSONEncoder().encode(detail)
        var archived = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        archived["isArchived"] = true
        XCTAssertEqual(try JSONDecoder().decode(ProjectConversationDetail.self,
            from: JSONSerialization.data(withJSONObject: archived)).isArchived, true)
    }

    // Contract: a Project helper stays bound to its parent and exact provider
    // thread; the read-only transcript route cannot be confused with Bot chat.
    func testProjectSubagentWireAndRequestPaths() async throws {
        let roster = try JSONDecoder().decode(ProjectSubagentList.self, from: Data(#"{"available":true,"detail":null,"subagents":[{"parentConversationId":"project parent","threadId":"child/thread","title":"Scout","agentNickname":"Scout","agentRole":"research","status":"active","isArchived":false,"canAcceptDirectInput":false}]}"#.utf8))
        let child = try XCTUnwrap(roster.subagents.first)
        XCTAssertEqual(child.statusLabel, "Running")
        XCTAssertEqual(child.statusLabel(available: false), "Last known: Running")
        XCTAssertFalse(child.canAcceptDirectInput)
        // The host cannot infer live desktop-owned work from a separate App
        // Server's notLoaded status; archiving also cannot imply completion.
        for (status, archived, expected) in [
            ("notLoaded", false, "Status unknown"),
            ("unknown", false, "Status unknown"),
            ("interrupted", true, "Archived · Stopped"),
            ("failed", true, "Archived · Failed"),
            ("completed", true, "Archived · Completed"),
            ("notLoaded", true, "Archived · Status unknown"),
        ] {
            let data = try JSONSerialization.data(withJSONObject: [
                "parentConversationId": "project parent", "threadId": "child/thread",
                "title": "Scout", "agentNickname": "Scout", "agentRole": "research",
                "status": status, "isArchived": archived, "canAcceptDirectInput": false,
            ])
            XCTAssertEqual(try JSONDecoder().decode(ProjectSubagentSummary.self, from: data).statusLabel,
                           expected, "\(status), archived=\(archived)")
        }
        XCTAssertEqual(try ProjectSubagentPaths.roster(parentConversationId: child.parentConversationId),
                       "/api/v1/project-conversations/project%20parent/subagents")
        XCTAssertEqual(try ProjectSubagentPaths.transcript(parentConversationId: child.parentConversationId,
            threadId: child.threadId, cursor: "older+page"),
            "/api/v1/project-conversations/project%20parent/subagents/child%2Fthread/transcript?cursor=older%2Bpage")
        XCTAssertThrowsError(try ProjectSubagentPaths.transcript(parentConversationId: "", threadId: child.threadId))

        let read = try JSONDecoder().decode(ProjectSubagentTranscript.self, from: Data(#"{"subagent":{"parentConversationId":"project parent","threadId":"child/thread","title":"Scout","agentNickname":"Scout","agentRole":"research","status":"completed","isArchived":false,"canAcceptDirectInput":false},"snapshot":{"conversationId":"project-agent:project parent:child/thread","hostEpoch":"epoch","lastSequence":0,"messages":[],"assistantMessages":[],"thread":{"threadId":"child/thread","turns":[{"id":"turn","status":"completed","startedAt":null,"completedAt":null,"items":[{"id":"answer","type":"agentMessage","state":"completed","text":"Found the issue","createdAt":"2026-10-02T00:00:00Z","payload":{}}]}],"nextCursor":null,"hydrated":false},"events":[]}}"#.utf8))
        XCTAssertEqual(read.subagent.parentConversationId, child.parentConversationId)
        XCTAssertEqual(read.snapshot.rows(author: read.subagent.title).first?.text, "Found the issue")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProjectSubagentResponseProtocol.self]
        let api = PairingAPI(configuration: configuration)
        let fetchedRoster: ProjectSubagentList = try await api.request(
            ProjectSubagentPaths.roster(parentConversationId: child.parentConversationId),
            origin: "https://project-agents.invalid")
        XCTAssertEqual(fetchedRoster.subagents.first?.threadId, child.threadId)
        let fetchedRead: ProjectSubagentTranscript = try await api.request(
            ProjectSubagentPaths.transcript(parentConversationId: child.parentConversationId,
                                            threadId: child.threadId, cursor: "older+page"),
            origin: "https://project-agents.invalid")
        XCTAssertEqual(fetchedRead.snapshot.rows(author: child.title).first?.text, "Found the issue")
    }

    // Contract: changing Macs never keeps a destination, provider or settings
    // that belong to the previous Mac, and never overwrites a saved draft.
    func testSwitchingConnectionsCarriesTextOnly() {
        var outgoing = NewChatDraft(text: "Refactor the parser")
        outgoing.choose(.project(id: "mac-a-project"), project: project("mac-a-project", family: .claude))
        let fresh = NewChatDraft.switching(from: outgoing, toSaved: nil)
        XCTAssertEqual(fresh.text, "Refactor the parser")
        XCTAssertNil(fresh.destination)
        XCTAssertNil(fresh.family)
        var saved = NewChatDraft(text: "Existing words")
        saved.choose(.newBot)
        XCTAssertEqual(NewChatDraft.switching(from: outgoing, toSaved: saved), saved)
    }

    // Contract: a submitted creation keeps its exact request identity and body
    // until confirmed, so a retry cannot create a second thread.
    func testSubmittedDraftIsFrozenUntilConfirmed() {
        var draft = NewChatDraft(text: "First message")
        draft.choose(.project(id: "p"), project: project("p", family: .claude))
        XCTAssertEqual(draft.family, .claude)
        let request = draft.requestID
        draft.freeze()
        draft.chooseFamily(.codex)
        draft.choose(.newBot)
        XCTAssertEqual(draft.family, .claude)
        XCTAssertEqual(draft.destination, .project(id: "p"))
        XCTAssertEqual(draft.requestID, request)
        XCTAssertNil(NewChatDraft.switching(from: draft, toSaved: nil).submittedBody)
        draft.completeSubmission()
        XCTAssertNotEqual(draft.requestID, request)
        XCTAssertEqual(draft.text, "")
        draft.text = "Rejected request"
        draft.freeze()
        let rejectedID = draft.requestID
        draft.rejectSubmission()
        XCTAssertFalse(draft.isSubmitted)
        XCTAssertNotEqual(draft.requestID, rejectedID)
        XCTAssertEqual(draft.text, "Rejected request")
    }

    // Contract: the tree is one flat list with stable IDs; paging appends
    // without reordering, pinned threads leave the project list, and
    // collapsed projects load nothing.
    func testSidebarRowsAreStableAcrossPaging() {
        var state = ProjectThreadsState()
        state.apply(ProjectThreadsPage(threads: [thread("codex:1", conversation: "c1"), thread("claude:2", pinned: true, family: .claude)], nextCursor: "next", partial: []), replacing: true)
        let host = SidebarHostProjects(hostID: "mac", name: "MacBook Pro", isOnline: true, supportsProjects: true,
                                       projects: [project("b"), project("a", pinned: true), project("hidden", included: false)], threads: ["a": state])
        let key = SidebarProjection.expansionKey(host: "mac", project: "a")
        let first = SidebarProjection.projectRows(hosts: [host], expanded: [key], selectedConversation: "c1", selectedProject: nil)
        XCTAssertEqual(first.map(\.id), ["host:mac", "project:mac:a", "thread:mac:a:codex:1", "more:mac:a", "project:mac:b", "new-project:mac"])
        if case .thread(_, _, _, let selected) = first[2] { XCTAssertTrue(selected) } else { XCTFail() }
        state.apply(ProjectThreadsPage(threads: [thread("codex:1", conversation: "c1"), thread("codex:3")], nextCursor: nil, partial: []), replacing: false)
        let paged = SidebarProjection.projectRows(hosts: [SidebarHostProjects(hostID: "mac", name: "MacBook Pro", isOnline: true, supportsProjects: true, projects: host.projects, threads: ["a": state])], expanded: [key], selectedConversation: nil, selectedProject: nil)
        XCTAssertEqual(Array(paged.map(\.id).prefix(4)), ["host:mac", "project:mac:a", "thread:mac:a:codex:1", "thread:mac:a:codex:3"])
        XCTAssertFalse(paged.map(\.id).contains("more:mac:a"))
        state.apply(ProjectThreadsPage(threads: [], nextCursor: nil, partial: [ProjectPartialFailure(family: .codex, detail: "Try again")]), replacing: true)
        XCTAssertEqual(state.threads.map(\.reference), ["codex:1", "codex:3"], "A provider timeout must retain its cached conversations")
    }

    // Contract: search expands matching projects temporarily, one provider's
    // failure stays beside the other's rows, and an old Mac asks for an update.
    func testSearchPartialFailureAndOldHost() {
        var state = ProjectThreadsState()
        state.apply(ProjectThreadsPage(threads: [thread("codex:1", title: "Fix reconnect"), thread("codex:2", title: "Polish")],
                                       nextCursor: nil, partial: [ProjectPartialFailure(family: .claude, detail: "Claude Code threads could not be loaded.")]), replacing: true)
        let hosts = [
            SidebarHostProjects(hostID: "mac", name: "Studio", isOnline: true, supportsProjects: true, projects: [project("a"), project("b")], threads: ["a": state]),
            SidebarHostProjects(hostID: "old", name: "Old Mac", isOnline: true, supportsProjects: false, projects: [], threads: [:]),
        ]
        let rows = SidebarProjection.projectRows(hosts: hosts, expanded: [], selectedConversation: nil, selectedProject: nil, search: "reconnect")
        XCTAssertEqual(rows.map(\.id), ["host:mac", "project:mac:a", "thread:mac:a:codex:1", "notice:mac:a", "host:old", "update:old"])
        let plain = SidebarProjection.projectRows(hosts: hosts, expanded: [SidebarProjection.expansionKey(host: "mac", project: "a")], selectedConversation: nil, selectedProject: nil)
        XCTAssertTrue(plain.contains { if case .threadsNotice(_, _, let message, _) = $0 { return message.contains("Claude") }; return false })
        XCTAssertTrue(plain.contains { $0.id == "thread:mac:a:codex:2" })
        let named = SidebarProjection.projectRows(hosts: hosts, expanded: [SidebarProjection.expansionKey(host: "mac", project: "a")], selectedConversation: nil, selectedProject: nil, search: "A")
        XCTAssertTrue(named.contains { $0.id == "thread:mac:a:codex:1" })
        XCTAssertTrue(named.contains { $0.id == "thread:mac:a:codex:2" })
        let collapsed = SidebarProjection.projectRows(hosts: hosts, expanded: [], selectedConversation: nil, selectedProject: nil, search: "A")
        XCTAssertFalse(collapsed.contains { $0.id.hasPrefix("thread:") })
    }

    // Contract: Pinned merges what a Mac reported with pins already loaded,
    // hides pins of hidden projects, names the Mac only when several are
    // paired, selects only its own Mac's conversation, and never repeats a
    // pinned thread under its project. A collapsed Mac keeps header and notice.
    func testPinnedSectionAndCollapsedHost() {
        var loaded = ProjectThreadsState()
        loaded.apply(ProjectThreadsPage(threads: [thread("codex:1", conversation: "c1"), thread("claude:2", conversation: "c2", pinned: true, family: .claude)], nextCursor: nil, partial: []), replacing: true)
        func reported(_ reference: String, project: String, updatedAt: Int) -> PinnedProjectThread {
            PinnedProjectThread(projectId: project, thread: ProjectThreadSummary(reference: reference, conversationId: "c-" + reference, title: "Reported " + reference, family: .codex, updatedAt: updatedAt, isPinned: true))
        }
        let mac = SidebarHostProjects(hostID: "mac", name: "Studio", isOnline: false, supportsProjects: true,
                                      projects: [project("a"), project("b"), project("hidden", included: false)], threads: ["a": loaded],
                                      pinned: [reported("codex:9", project: "b", updatedAt: 500), reported("codex:8", project: "hidden", updatedAt: 900)],
                                      notice: .offline)
        let laptop = SidebarHostProjects(hostID: "laptop", name: "Laptop", isOnline: true, supportsProjects: true, projects: [project("c")], threads: [:])
        let key = SidebarProjection.expansionKey(host: "mac", project: "a")
        let rows = SidebarProjection.rows(hosts: [mac, laptop], expanded: [key], collapsedHosts: ["laptop"], selectedHost: "mac", selectedConversation: "c2")
        XCTAssertEqual(rows.map(\.id), ["pinned-header", "pinned:mac:codex:9", "pinned:mac:claude:2",
                                        "host:mac", "host-notice:mac", "project:mac:a", "thread:mac:a:codex:1", "project:mac:b", "new-project:mac",
                                        "host:laptop"])
        if case .pinned(_, let project, let projectName, let hostName, _, let selected) = rows[2] {
            XCTAssertEqual([project, projectName, hostName], ["a", "A", "Studio"])
            XCTAssertTrue(selected)
        } else { XCTFail() }
        if case .host(_, _, _, let collapsed) = rows[9] { XCTAssertTrue(collapsed) } else { XCTFail() }
        let elsewhere = SidebarProjection.pinnedRows(hosts: [mac, laptop], selectedHost: "laptop", selectedConversation: "c2")
        XCTAssertFalse(elsewhere.contains { if case .pinned(_, _, _, _, _, let selected) = $0 { return selected }; return false })
        if case .pinned(_, _, _, let hostName, _, _) = SidebarProjection.pinnedRows(hosts: [mac], selectedConversation: nil)[1] { XCTAssertNil(hostName) } else { XCTFail() }
        let searched = SidebarProjection.rows(hosts: [mac, laptop], expanded: [], collapsedHosts: ["laptop"], selectedConversation: nil, search: "reported")
        XCTAssertEqual(searched.map(\.id), ["pinned-header", "pinned:mac:codex:9", "host:mac", "host-notice:mac", "host:laptop"])
        XCTAssertTrue(SidebarProjection.pinnedRows(hosts: [laptop], selectedConversation: nil).isEmpty)
    }

    // Contract: only the 30 most recently opened project conversations keep
    // their saved history; reopening moves one to the front instead of duplicating it.
    func testRecentlyOpenedConversationsAreBounded() {
        var recent = RecentlyOpenedConversations()
        for index in 1...31 { recent.note("c\(index)") }
        XCTAssertEqual(recent.ids.count, RecentlyOpenedConversations.limit)
        XCTAssertEqual(recent.ids.first, "c31")
        XCTAssertFalse(recent.ids.contains("c1"))
        recent.note("c2")
        XCTAssertEqual(Array(recent.ids.prefix(2)), ["c2", "c31"])
        XCTAssertEqual(recent.ids.count, RecentlyOpenedConversations.limit)
        let restored = try? JSONDecoder().decode(RecentlyOpenedConversations.self, from: JSONEncoder().encode(recent))
        XCTAssertEqual(restored, recent)
    }

    // Contract: pinned chats stay visible; five recent unpinned chats show
    // first, ordered by message time with stable ties.
    func testRecentConversationOrdering() throws {
        func chat(_ id: String, at: String?, pinned: Bool = false) -> ChatSummary {
            ChatSummary(conversationId: id, botId: "b", title: id, lastMessagePreview: nil, lastMessageAt: at, messageCount: 0,
                        deliveryState: nil, hasUnread: false, isArchived: false, isPinned: pinned)
        }
        let chats = (1...7).map { chat("c\($0)", at: "2026-09-0\($0)") } + [chat("pinned", at: nil, pinned: true), chat("c0", at: "2026-09-07")]
        let visible = RecentConversations.visible(chats, showAll: false)
        XCTAssertEqual(visible.rows.map(\.id), ["pinned", "c0", "c7", "c6", "c5", "c4"])
        XCTAssertTrue(visible.hasMore)
        XCTAssertEqual(RecentConversations.visible(chats, showAll: true).rows.count, 9)
    }
}

// Composer contracts for project threads: access choices, reasoning defaults
// and where a draft belongs once Bots are not a destination.
final class ProjectComposerContractTests: XCTestCase {
    private func models(_ json: String) throws -> [BotOptions.Model] {
        try JSONDecoder().decode(BotOptions.self, from: Data(#"{"models":\#(json),"timezone":"UTC","allowedApprovalPolicies":[]}"#.utf8)).models
    }
    private func catalog() throws -> [BotOptions.Model] {
        try models(#"""
        [{"id":"claude:haiku","displayName":"Haiku","hidden":false,"reasoningEfforts":[],"agentFamily":"claude"},
         {"id":"claude:sonnet","displayName":"Sonnet","hidden":false,"reasoningEfforts":[{"id":"low","label":"Low"},{"id":"medium","label":"Medium"},{"id":"high","label":"High"}],"defaultReasoningEffort":"xhigh","agentFamily":"claude"},
         {"id":"gpt-hidden","displayName":"Hidden","hidden":true,"reasoningEfforts":[],"agentFamily":"codex"},
         {"id":"gpt-a","displayName":"GPT A","hidden":false,"reasoningEfforts":[{"id":"low","label":"Low"},{"id":"medium","label":"Medium"},{"id":"xhigh","label":"xhigh"}],"defaultReasoningEffort":"medium","agentFamily":"codex"},
         {"id":"gpt-b","displayName":"GPT B","hidden":false,"reasoningEfforts":[{"id":"low","label":"Low"},{"id":"high","label":"High"}],"agentFamily":"codex"},
         {"id":"gpt-c","displayName":"GPT C","hidden":false,"reasoningEfforts":[{"id":"minimal","label":"Minimal"},{"id":"low","label":"Low"}],"agentFamily":"codex"}]
        """#)
    }
    private func visible(_ family: AgentFamily, _ all: [BotOptions.Model]) -> [BotOptions.Model] {
        all.filter { !$0.hidden && $0.family == family }
    }

    // Contract: choosing a model always yields an effort the model supports:
    // its own default, else high, else medium, else its first. Regression:
    // the effort was cleared and the button showed no reasoning at all.
    func testEffortIsNeverBlankWhenTheModelOffersEfforts() throws {
        let all = try catalog()
        func effort(_ id: String) -> String? { ModelDefaults.effort(for: all.first { $0.id == id }!) }
        XCTAssertEqual(effort("gpt-a"), "medium")
        XCTAssertEqual(effort("claude:sonnet"), "high", "An unoffered default falls back to high")
        XCTAssertEqual(effort("gpt-b"), "high")
        XCTAssertEqual(effort("gpt-c"), "minimal")
        XCTAssertNil(effort("claude:haiku"))
        let codex = visible(.codex, all)
        var draft = NewChatDraft()
        draft.chooseModel(codex[0])
        XCTAssertEqual(draft.effort, "medium")
        draft.effort = "xhigh"
        draft.chooseModel(codex[1])
        XCTAssertEqual(draft.effort, "high", "Switching models resets to the new model's default")
        XCTAssertEqual(ModelDefaults.summary(model: codex[0], effort: "xhigh"), "GPT A · Extra high")
        XCTAssertEqual(ModelDefaults.summary(model: try XCTUnwrap(all.first { $0.id == "claude:haiku" }), effort: nil), "Haiku")
    }

    // Contract: a draft or attached thread without a stored model shows the
    // host's default for its provider and stays on a supported effort.
    func testEnsureModelUsesRememberedThenHostDefault() throws {
        let all = try catalog()
        XCTAssertEqual(ModelDefaults.defaultModel(in: visible(.claude, all))?.id, "claude:sonnet", "The host avoids Haiku when it can")
        XCTAssertEqual(ModelDefaults.defaultModel(in: visible(.codex, all))?.id, "gpt-a")
        XCTAssertEqual(ModelDefaults.defaultModel(in: all.filter { $0.id == "claude:haiku" })?.id, "claude:haiku")
        var fresh = NewChatDraft(family: .codex)
        fresh.ensureModel(among: visible(.codex, all))
        XCTAssertEqual([fresh.model, fresh.effort], ["gpt-a", "medium"])
        var remembered = NewChatDraft(family: .codex)
        remembered.ensureModel(among: visible(.codex, all), remembered: RememberedModel(model: "gpt-b", effort: "low"))
        XCTAssertEqual([remembered.model, remembered.effort], ["gpt-b", "low"])
        var stale = NewChatDraft(family: .codex)
        stale.ensureModel(among: visible(.codex, all), remembered: RememberedModel(model: "removed", effort: "low"))
        XCTAssertEqual(stale.model, "gpt-a")
        var repaired = NewChatDraft(family: .codex, model: "gpt-a", effort: "high")
        repaired.ensureModel(among: visible(.codex, all))
        XCTAssertEqual([repaired.model, repaired.effort], ["gpt-a", "medium"])
        var kept = NewChatDraft(family: .codex, model: "gpt-a", effort: "xhigh")
        kept.ensureModel(among: visible(.codex, all), remembered: RememberedModel(model: "gpt-b", effort: "low"))
        XCTAssertEqual([kept.model, kept.effort], ["gpt-a", "xhigh"])
        var frozen = NewChatDraft(text: "Go", family: .codex, submittedBody: "Go")
        frozen.ensureModel(among: visible(.codex, all))
        XCTAssertNil(frozen.model, "A committed request never changes")
        var empty = NewChatDraft(family: .codex)
        empty.ensureModel(among: [])
        XCTAssertNil(empty.model)
        var switched = NewChatDraft(family: .codex, model: "gpt-a", effort: "medium")
        switched.chooseFamily(.claude)
        switched.ensureModel(among: visible(.claude, all))
        XCTAssertEqual([switched.model, switched.effort], ["claude:sonnet", "high"])
    }

    // A saved draft keeps an advertised speed, clears it when the selected
    // model loses that tier, and never rewrites a submitted creation.
    func testProjectDraftSpeedFollowsRuntimeModelChoices() throws {
        let options = try models(#"""
        [{"id":"gpt-a","displayName":"A","hidden":false,"reasoningEfforts":[],"agentFamily":"codex",
          "serviceTiers":[{"id":"default","label":"Standard"},{"id":"fast","label":"Fast"}]},
         {"id":"gpt-b","displayName":"B","hidden":false,"reasoningEfforts":[],"agentFamily":"codex",
          "serviceTiers":[{"id":"default","label":"Standard"}]}]
        """#)
        var draft = NewChatDraft(family: .codex, model: "gpt-a")
        draft.serviceTier = "fast"
        draft.ensureModel(among: options)
        XCTAssertEqual(draft.serviceTier, "fast")
        draft.chooseModel(options[1])
        XCTAssertNil(draft.serviceTier)
        draft.model = "gpt-a"; draft.serviceTier = "fast"
        draft.ensureModel(among: [options[1]])
        XCTAssertNil(draft.serviceTier)
        draft.serviceTier = "default"; draft.freeze()
        draft.ensureModel(among: options)
        XCTAssertEqual(draft.serviceTier, "default")
    }

    // Contract: each provider offers its own access rows, older hosts keep the
    // original three, and every choice changes only fields the host accepts.
    func testAccessMenusPerProviderAndHost() {
        func titles(_ family: AgentFamily, modes: Bool, current: ProjectAccess = ProjectAccess()) -> [String] {
            ProjectAccessChoice.choices(family: family, supportsModes: modes, current: current).map { $0.title(for: family, supportsModes: modes) }
        }
        XCTAssertEqual(titles(.codex, modes: true), ["Read only", "Auto", "Full access"])
        XCTAssertEqual(titles(.claude, modes: true), ["Manual", "Accept edits", "Auto", "Plan", "Bypass permissions"])
        XCTAssertEqual(titles(.claude, modes: true, current: ProjectAccess(accessMode: .readOnly)),
                       ["Read only", "Manual", "Accept edits", "Auto", "Plan", "Bypass permissions"])
        XCTAssertEqual(titles(.codex, modes: false), ["Read only", "Edit project", "Full access"])
        XCTAssertEqual(titles(.claude, modes: false), ["Read only", "Ask for approval", "Full access"])
        XCTAssertTrue(ProjectAccessChoice.fullAccess.isElevated)
        XCTAssertFalse(ProjectAccessChoice.auto.isElevated)

        func selected(_ family: AgentFamily, _ access: ProjectAccess, modes: Bool = true) -> ProjectAccessChoice {
            ProjectAccessChoice.selected(for: access, family: family, supportsModes: modes)
        }
        XCTAssertEqual(selected(.claude, ProjectAccess()), .manual)
        XCTAssertEqual(selected(.claude, ProjectAccess(claudeApproval: .acceptEdits)), .acceptEdits)
        XCTAssertEqual(selected(.claude, ProjectAccess(claudeApproval: .auto)), .auto)
        XCTAssertEqual(selected(.claude, ProjectAccess(accessMode: .fullAccess, planMode: true)), .plan, "Plan mode wins over the other Claude rows")
        XCTAssertEqual(selected(.codex, ProjectAccess(planMode: true)), .workspace, "Codex plan mode is separate from its access level")
        XCTAssertEqual(selected(.claude, ProjectAccess(accessMode: .fullAccess), modes: false), .fullAccess)
    }

    func testAccessChoicesChangeOnlyWhatTheHostAccepts() {
        func patch(_ choice: ProjectAccessChoice, from access: ProjectAccess, _ family: AgentFamily, modes: Bool = true) -> [String: String] {
            let next = choice.result(from: access, family: family, supportsModes: modes)
            return access.changes(to: next, family: family, supportsModes: modes).mapValues { "\($0)" }
        }
        XCTAssertEqual(patch(.acceptEdits, from: ProjectAccess(), .claude), ["claudeApproval": "accept_edits"])
        XCTAssertEqual(patch(.plan, from: ProjectAccess(), .claude), ["planMode": "true"])
        XCTAssertEqual(patch(.manual, from: ProjectAccess(planMode: true), .claude), ["planMode": "false"])
        XCTAssertEqual(patch(.fullAccess, from: ProjectAccess(planMode: true), .claude), ["accessMode": "full_access", "planMode": "false"])
        XCTAssertEqual(patch(.auto, from: ProjectAccess(accessMode: .fullAccess), .claude),
                       ["accessMode": "workspace", "claudeApproval": "auto"])
        XCTAssertEqual(patch(.fullAccess, from: ProjectAccess(planMode: true), .codex), ["accessMode": "full_access"], "A Codex access level leaves plan mode alone")
        XCTAssertEqual(patch(.manual, from: ProjectAccess(claudeApproval: .auto), .codex), [:], "Codex threads reject claudeApproval")
        XCTAssertEqual(patch(.fullAccess, from: ProjectAccess(), .claude, modes: false), ["accessMode": "full_access"])
        XCTAssertEqual(patch(.plan, from: ProjectAccess(), .claude, modes: false), [:], "Older hosts reject planMode")
        XCTAssertEqual(patch(.manual, from: ProjectAccess(), .claude), [:], "Choosing the current row saves nothing")
    }

    // Contract: the draft, the created thread and the menu read the same fields.
    func testDraftAccessAndDetailShareOneShape() throws {
        var draft = NewChatDraft(family: .claude)
        draft.access = ProjectAccessChoice.acceptEdits.result(from: draft.access, family: .claude, supportsModes: true)
        XCTAssertEqual([draft.accessMode.rawValue, draft.claudeApproval?.rawValue], ["workspace", "accept_edits"])
        XCTAssertNil(draft.planMode)
        draft.access = ProjectAccessChoice.plan.result(from: draft.access, family: .claude, supportsModes: true)
        XCTAssertEqual(draft.planMode, true)
        draft.chooseFamily(.codex)
        XCTAssertNil(draft.claudeApproval, "A Codex draft never carries a Claude approval")
        let detail = try JSONDecoder().decode(ProjectConversationDetail.self, from: Data(#"{"conversationId":"c","projectId":"p","projectName":"P","title":"t","family":"claude","model":null,"effort":null,"accessMode":"workspace","workingFolder":"/w","workingFolderName":"w","isPinned":false,"hasUnread":false,"hasNativeSession":true,"folderInProject":true,"notice":null,"claudeApproval":"auto","planMode":true}"#.utf8))
        XCTAssertEqual(detail.access, ProjectAccess(accessMode: .workspace, claudeApproval: .auto, planMode: true))
        let older = try JSONDecoder().decode(ProjectConversationDetail.self, from: Data(#"{"conversationId":"c","projectId":"p","projectName":"P","title":"t","family":"codex","model":null,"effort":null,"accessMode":"read_only","workingFolder":"/w","workingFolderName":"w","isPinned":false,"hasUnread":false,"hasNativeSession":true,"folderInProject":true,"notice":null}"#.utf8))
        XCTAssertEqual(older.access, ProjectAccess(accessMode: .readOnly))
    }

    // Contract: Bots and Group Chats are not destinations. A restored draft
    // with one moves to the default project and keeps its words; a committed
    // project request never moves.
    func testRetiredDestinationsSettleIntoTheDefaultProject() {
        func project(_ id: String, family: AgentFamily? = nil) -> ProjectSummary {
            ProjectSummary(id: id, name: id, folders: [ProjectFolder(id: id + "f", path: "/" + id, name: id, isPrimary: true, isAvailable: true)], lastFamily: family)
        }
        let projects = [project("first", family: .claude), project("second")]
        for retired in [nil, ChatDestination.newBot, .newGroup, .conversation(id: "bot"), .project(id: "deleted")] {
            var draft = NewChatDraft(destination: retired, text: "Fix the parser")
            XCTAssertTrue(draft.settle(in: projects))
            XCTAssertEqual(draft.destination, .project(id: "first"))
            XCTAssertEqual(draft.family, .claude)
            XCTAssertEqual(draft.text, "Fix the parser")
        }
        var current = NewChatDraft(destination: .project(id: "second"), text: "Keep")
        XCTAssertFalse(current.settle(in: projects))
        XCTAssertEqual(current.destination, .project(id: "second"))
        var frozenProject = NewChatDraft(destination: .project(id: "deleted"), text: "Sent", submittedBody: "Sent")
        let request = frozenProject.requestID
        XCTAssertFalse(frozenProject.settle(in: projects))
        XCTAssertEqual(frozenProject.requestID, request)
        var frozenBot = NewChatDraft(destination: .newBot, text: "Hello", submittedBody: "Hello")
        XCTAssertTrue(frozenBot.settle(in: projects))
        XCTAssertFalse(frozenBot.isSubmitted)
        XCTAssertEqual(frozenBot.text, "Hello")
        var none = NewChatDraft(text: "Nowhere to go")
        XCTAssertFalse(none.settle(in: []))
        XCTAssertNil(none.destination)
    }
}
