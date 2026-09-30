import XCTest
@testable import WonderPairing

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
        let page = try JSONDecoder().decode(ProjectThreadsPage.self, from: Data(#"{"threads":[{"reference":"claude:a0b0","conversationId":"f861","title":"Wonder-p0","family":"claude","updatedAt":1790735086,"isPinned":false,"hasUnread":true,"isWorking":false}],"nextCursor":null,"partial":[]}"#.utf8))
        XCTAssertEqual(page.threads.first?.family, .claude)
        let detail = try JSONDecoder().decode(ProjectConversationDetail.self, from: Data(#"{"conversationId":"c","projectId":"p","projectName":"Codex P0","title":"t","family":"codex","model":"gpt-5.6-luna","effort":"low","accessMode":"read_only","workingFolder":"/w","workingFolderName":"w","isPinned":false,"hasUnread":false,"hasNativeSession":true,"folderInProject":true,"notice":null}"#.utf8))
        XCTAssertEqual(detail.accessMode, .readOnly)
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
    // without reordering, pins lead, and collapsed projects load nothing.
    func testSidebarRowsAreStableAcrossPaging() {
        var state = ProjectThreadsState()
        state.apply(ProjectThreadsPage(threads: [thread("codex:1", conversation: "c1"), thread("claude:2", pinned: true, family: .claude)], nextCursor: "next", partial: []), replacing: true)
        let host = SidebarHostProjects(hostID: "mac", name: "MacBook Pro", isOnline: true, supportsProjects: true,
                                       projects: [project("b"), project("a", pinned: true), project("hidden", included: false)], threads: ["a": state])
        let key = SidebarProjection.expansionKey(host: "mac", project: "a")
        let first = SidebarProjection.projectRows(hosts: [host], expanded: [key], selectedConversation: "c1", selectedProject: nil)
        XCTAssertEqual(first.map(\.id), ["project:mac:a", "thread:mac:a:claude:2", "thread:mac:a:codex:1", "more:mac:a", "project:mac:b"])
        if case .thread(_, _, _, let selected) = first[2] { XCTAssertTrue(selected) } else { XCTFail() }
        state.apply(ProjectThreadsPage(threads: [thread("codex:1", conversation: "c1"), thread("codex:3")], nextCursor: nil, partial: []), replacing: false)
        let paged = SidebarProjection.projectRows(hosts: [SidebarHostProjects(hostID: "mac", name: "MacBook Pro", isOnline: true, supportsProjects: true, projects: host.projects, threads: ["a": state])], expanded: [key], selectedConversation: nil, selectedProject: nil)
        XCTAssertEqual(Array(paged.map(\.id).prefix(4)), ["project:mac:a", "thread:mac:a:claude:2", "thread:mac:a:codex:1", "thread:mac:a:codex:3"])
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
