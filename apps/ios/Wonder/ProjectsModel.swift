import SwiftUI
import WonderPairing

/// Projects on one paired Mac. Requests are fenced by the connection scope so a
/// late response from a replaced pairing or another Mac is never applied.
@MainActor final class ProjectLibrary: ObservableObject {
    private weak var model: ConnectionModel?
    /// nil until the Mac answers; false means it needs a Wonder update.
    @Published private(set) var supportsProjects: Bool?
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var families: [ProjectFamilyAvailability] = []
    @Published private(set) var threads: [String: ProjectThreadsState] = [:]
    @Published private(set) var details: [String: ProjectConversationDetail] = [:]
    @Published private(set) var loadingProjects = false
    /// The host accepts Claude approval modes and plan mode.
    @Published private(set) var supportsModes = false
    @Published private(set) var supportsArchive = false
    /// The Mac archives Claude Code threads in Wonder and lists archived threads.
    @Published private(set) var supportsArchiveList = false
    /// The Mac can create a new project's folder.
    @Published private(set) var supportsNewFolder = false
    /// Pinned threads across this Mac's included projects.
    @Published private(set) var pinned: [PinnedProjectThread] = []
    /// Conversations the Mac reported gone while a saved copy was still open.
    @Published private(set) var unavailable: Set<String> = []
    /// An explicit unread action stays unread until the owner opens the thread
    /// again, even when its conversation is still visible beside an iPad sidebar.
    @Published private(set) var manuallyUnread: Set<String> = []
    @Published var failure: String?
    /// Model catalog for project composer settings, per connection scope.
    @Published var options: BotOptions?
    var widgetSnapshotChanged: (() -> Void)?
    var owner: ConnectionModel? { model }
    private var scope: String?
    private var threadTasks: [String: Task<Void, Never>] = [:]
    /// A first-page read may have started before a prepare-only conversation was created.
    private var createdDuringThreadRead: [String: Set<String>] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private var refreshPinRevision = 0
    /// Newest first; bounded so saved history stays small (see `retainedConversationIDs`).
    private var recentlyOpened = RecentlyOpenedConversations()
    /// Bumped by every local pin change so an older refresh cannot undo it.
    private var pinRevision = 0
    private var pendingPins: [String: Bool] = [:]
    /// A response begun before a successful archive cannot put that row back.
    private var archivedReferences: Set<String> = []
    private var detailRevisions: [String: Int] = [:]
    private var updatingDetails: Set<String> = []
    /// Fences older catalog/detail reads and automatic acknowledgements against
    /// an explicit read-status change, independently of pin changes.
    private var readRevisions: [String: Int] = [:]
    /// In-memory detail cache bound; open, recent, pinned and first-page threads always stay.
    private static let detailLimit = 120
    #if WONDER_DIAGNOSTICS
    private var previewFilesDetail: ProjectConversationDetail?
    func installPreviewFilesConversation(_ detail: ProjectConversationDetail) {
        previewFilesDetail = detail
        details[detail.conversationId] = detail
        model?.registerProjectConversation(detail)
    }
    #endif

    init(model: ConnectionModel) {
        self.model = model
        restoreCache()
        installPreviewFilesProject()
    }

    private func installPreviewFilesProject() {
        #if WONDER_DIAGNOSTICS
        if model?.previewMode == true && (ProcessInfo.processInfo.arguments.contains("-project-files-preview") ||
            ProcessInfo.processInfo.arguments.contains("-project-files-conversation-preview")) {
            // A read-only new-chat destination for the Files UI fixture.
            supportsProjects = true
            var folders = [ProjectFolder(id: "preview-folder", path: "/preview", name: "Preview",
                                         isPrimary: true, isAvailable: true)]
            if ProcessInfo.processInfo.arguments.contains("-project-files-multiple-folders-preview") {
                folders.append(ProjectFolder(id: "second-folder", path: "/second", name: "Second",
                                             isPrimary: false, isAvailable: true))
            }
            projects = [ProjectSummary(id: "preview-project", name: "Preview project", folders: folders)]
        }
        if let previewFilesDetail {
            details[previewFilesDetail.conversationId] = previewFilesDetail
            model?.registerProjectConversation(previewFilesDetail)
        }
        #endif
    }

    var includedProjects: [ProjectSummary] { SidebarProjection.sorted(projects.filter(\.isIncluded)) }

    func isAvailable(_ family: AgentFamily) -> Bool {
        families.first { $0.family == family }?.available ?? false
    }

    private func fenced() -> String? {
        guard let model, !model.accessEnded, model.connection != nil else { return nil }
        let current = model.assignmentScope
        if scope != current {
            // A different pairing or Mac: nothing from the previous scope applies.
            scope = current
            threadTasks.values.forEach { $0.cancel() }
            refreshTask?.cancel(); refreshTask = nil; refreshID = nil
            threadTasks = [:]
            createdDuringThreadRead = [:]
            projects = []; families = []; loadingProjects = false; failure = nil
            threads = [:]; details = [:]; supportsProjects = nil; options = nil
            supportsModes = false; supportsArchive = false; supportsArchiveList = false; supportsNewFolder = false; pinned = []; unavailable = []; manuallyUnread = []; recentlyOpened = RecentlyOpenedConversations()
            archivedReferences = []
            pendingPins = [:]; detailRevisions = [:]; updatingDetails = []; readRevisions = [:]
            restoreCache()
            installPreviewFilesProject()
        }
        return current
    }

    private func isCurrent(_ expected: String) -> Bool {
        scope == expected && model?.assignmentScope == expected && model?.accessEnded == false && !Task.isCancelled
    }

    func refresh() async {
        guard let expected = fenced() else { return }
        if let refreshTask {
            let id = refreshID, revision = refreshPinRevision
            await refreshTask.value
            guard isCurrent(expected) else { return }
            if refreshID == id { self.refreshTask = nil; refreshID = nil }
            // A save that joined an older catalog read needs a fresh read.
            if revision != pinRevision { await refresh() }
            return
        }
        let id = UUID()
        refreshID = id; refreshPinRevision = pinRevision
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        if isCurrent(expected), refreshID == id { refreshTask = nil; refreshID = nil }
    }

    private func performRefresh() async {
        guard let model, let scope = fenced(), !model.previewMode else { return }
        loadingProjects = true
        defer { if scope == self.scope { loadingProjects = false } }
        let pinRevisionAtStart = pinRevision
        let readsAtStart = readRevisions
        do {
            let response: ProjectsResponse = try await model.manage("/api/v1/projects")
            guard isCurrent(scope) else { return }
            supportsProjects = true
            let previous = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.rootsRevision) })
            projects = response.projects
            families = response.families
            supportsModes = (response.modesVersion ?? 0) >= 1
            supportsArchive = (response.archiveVersion ?? 0) >= 1
            supportsArchiveList = (response.archiveVersion ?? 0) >= 2
            supportsNewFolder = (response.createVersion ?? 0) >= 1
            // A pin changed while this request was in flight; the next refresh reports it.
            if pinRevision == pinRevisionAtStart, pendingPins.isEmpty, updatingDetails.isEmpty {
                archivedReferences.subtract((response.pinned ?? []).map(\.thread.reference))
                pinned = (response.pinned ?? []).map {
                    PinnedProjectThread(projectId: $0.projectId, thread: reconcilingRead($0.thread, startedAt: readsAtStart))
                }
            }
            failure = nil
            for project in projects where threads[project.id] != nil {
                if previous[project.id] != project.rootsRevision { threads[project.id]?.nextCursor = nil }
                loadThreads(project.id)
            }
            // A desktop archive can happen in another app-server process.
            // Refresh the open thread as well as catalog rows and pins.
            if let current = model.selectedChat, model.isProject(current) { await refreshDetail(current.id) }
            saveCache()
        } catch PairingFailure.response(404) {
            guard isCurrent(scope) else { return }
            supportsProjects = false
            saveCache()
        } catch is CancellationError {
        } catch {
            guard isCurrent(scope) else { return }
            // Cached projects stay readable; the notice explains the refresh.
            failure = model.macConnected == false ? nil : "Projects could not be refreshed. Pull to try again."
        }
    }

    /// First page on expansion, then explicit Show more. Identical requests
    /// share one task; a replaced connection cancels them.
    func loadThreads(_ projectID: String, more: Bool = false) {
        guard let model, let scope = fenced(), !model.previewMode, supportsProjects != false else { return }
        let key = projectID
        guard threadTasks[key] == nil else { return }
        var state = threads[projectID] ?? ProjectThreadsState()
        if more && state.nextCursor == nil { return }
        state.isLoading = true
        threads[projectID] = state
        let cursor = more ? state.nextCursor : nil
        let pinRevisionAtStart = pinRevision
        let readsAtStart = readRevisions
        threadTasks[key] = Task { [weak self] in
            defer {
                if self?.scope == scope {
                    self?.threadTasks[key] = nil
                    self?.createdDuringThreadRead[projectID] = nil
                }
            }
            var path = "/api/v1/projects/\(ConnectionModel.escape(projectID))/threads?limit=\(more ? 10 : SidebarProjection.initialThreads)"
            if let cursor { path += "&cursor=" + ConnectionModel.escape(cursor) }
            do {
                let page: ProjectThreadsPage = try await model.manage(path)
                guard let self, self.isCurrent(scope), !Task.isCancelled else { return }
                var next = self.threads[projectID] ?? ProjectThreadsState()
                let before = next.threads
                next.apply(self.reconcilingReads(self.reconcilingPins(page, startedAt: pinRevisionAtStart), startedAt: readsAtStart), replacing: !more)
                if !more { self.preserveCreatedDuringRead(in: &next, previous: before, projectID: projectID) }
                next.isLoading = false
                self.threads[projectID] = next
                if !more { self.saveCache() }
            } catch PairingFailure.response(410) {
                // The catalog changed between pages: reload from the top.
                guard let self, self.isCurrent(scope) else { return }
                self.threads[projectID]?.isLoading = false
                self.threads[projectID]?.nextCursor = nil
                // Retry inside this task so its cleanup cannot erase a newer
                // request's handle and allow overlapping pagination.
                do {
                    let revision = self.pinRevision
                    let reads = self.readRevisions
                    let page: ProjectThreadsPage = try await model.manage("/api/v1/projects/\(ConnectionModel.escape(projectID))/threads?limit=\(SidebarProjection.initialThreads)")
                    guard self.isCurrent(scope) else { return }
                    var next = self.threads[projectID] ?? ProjectThreadsState()
                    let before = next.threads
                    next.apply(self.reconcilingReads(self.reconcilingPins(page, startedAt: revision), startedAt: reads), replacing: true); next.isLoading = false
                    self.preserveCreatedDuringRead(in: &next, previous: before, projectID: projectID)
                    self.threads[projectID] = next
                    self.saveCache()
                } catch {
                    guard self.isCurrent(scope) else { return }
                    self.threads[projectID]?.failure = "Threads could not be loaded. Tap to retry."
                }
            } catch {
                guard let self, self.isCurrent(scope), !(error is CancellationError) else { return }
                self.threads[projectID]?.isLoading = false
                self.threads[projectID]?.failure = model.macConnected == false
                        ? "Connect to \(model.macName) to load threads."
                        : "Threads could not be loaded. Tap to retry."
            }
        }
    }

    private func preserveCreatedDuringRead(in state: inout ProjectThreadsState, previous: [ProjectThreadSummary], projectID: String) {
        guard let created = createdDuringThreadRead[projectID] else { return }
        // The page may contain an earlier title, pin or archive state for a row
        // created during this request. The current local row wins; if it was
        // archived, its absence removes a stale server copy too.
        state.threads.removeAll { row in
            guard let id = row.conversationId else { return false }
            return created.contains(id)
        }
        for row in previous.reversed() {
            guard let id = row.conversationId, created.contains(id) else { continue }
            state.threads.insert(row, at: 0)
        }
    }

    func project(_ id: String) -> ProjectSummary? { projects.first { $0.id == id } }

    func upsert(_ project: ProjectSummary) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        else { projects.insert(project, at: 0) }
        saveCache()
    }

    func createProject(requestID: String, name: String, folders: [String], primaryIndex: Int) async throws -> ProjectSummary {
        guard let model, let scope = fenced() else { throw PairingFailure.response(401) }
        let body = try JSONSerialization.data(withJSONObject: ["requestId": requestID, "name": name, "folders": folders, "primaryIndex": primaryIndex])
        let created: ProjectSummary = try await model.manage("/api/v1/projects", method: "POST", body: body)
        guard isCurrent(scope) else { throw CancellationError() }
        upsert(created)
        return created
    }

    /// Creates an empty folder named `name` in `parent` (the Mac's home folder
    /// when nil) and a project for it. A retry with the same request reuses it.
    func createProject(requestID: String, name: String, newFolderParent parent: String?) async throws -> ProjectSummary {
        guard let model, let scope = fenced() else { throw PairingFailure.response(401) }
        let body = try JSONSerialization.data(withJSONObject: ["requestId": requestID, "name": name,
                                                               "newFolder": parent.map { ["parent": $0] } ?? [:]])
        let created: ProjectSummary = try await model.manage("/api/v1/projects", method: "POST", body: body)
        guard isCurrent(scope) else { throw CancellationError() }
        upsert(created)
        return created
    }

    func update(_ projectID: String, fields: [String: Any]) async throws -> ProjectSummary {
        guard let model, let scope = fenced() else { throw PairingFailure.response(401) }
        let updated: ProjectSummary = try await model.manage("/api/v1/projects/\(ConnectionModel.escape(projectID))",
            method: "PATCH", body: JSONSerialization.data(withJSONObject: fields))
        guard isCurrent(scope) else { throw CancellationError() }
        upsert(updated)
        return updated
    }

    func loadOptions() async {
        guard let model, let scope = fenced(), options == nil, !model.previewMode else { return }
        let fetched: BotOptions? = try? await model.manage("/api/v1/bot-options")
        guard isCurrent(scope) else { return }
        options = fetched
    }

    func candidates() async throws -> ProjectCandidatesResponse {
        guard let model, let scope = fenced() else { throw PairingFailure.response(401) }
        let response: ProjectCandidatesResponse = try await model.manage("/api/v1/projects/candidates")
        guard isCurrent(scope) else { throw CancellationError() }
        return response
    }

    /// Opening a catalog thread attaches it; this starts no model work.
    func attach(_ projectID: String, thread: ProjectThreadSummary) async throws -> String {
        // Reattach native Codex threads so a missing desktop project assignment
        // is repaired on open. Drafts have no native metadata to synchronize.
        if let id = thread.conversationId, thread.family != .codex || thread.reference.hasPrefix("wonder:") { return id }
        guard let model, let scope = fenced() else { throw PairingFailure.response(401) }
        let attached: ProjectThreadSummary = try await model.manage(
            "/api/v1/projects/\(ConnectionModel.escape(projectID))/threads/attach", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["reference": thread.reference]))
        guard isCurrent(scope), let id = attached.conversationId else { throw CancellationError() }
        if let existing = thread.conversationId, existing != id { throw ReadFailure.wrongConversation }
        if var state = threads[projectID], let index = state.threads.firstIndex(where: { $0.reference == thread.reference }) {
            state.threads[index] = attached
            threads[projectID] = state
        }
        return id
    }

    @discardableResult func loadDetail(_ conversationID: String) async throws -> ProjectConversationDetail {
        guard let model, let scope = fenced() else { throw PairingFailure.response(401) }
        let revision = detailRevisions[conversationID, default: 0]
        let detail: ProjectConversationDetail = try await model.manage("/api/v1/project-conversations/\(ConnectionModel.escape(conversationID))")
        guard isCurrent(scope) else { throw CancellationError() }
        if revision != detailRevisions[conversationID, default: 0] || updatingDetails.contains(conversationID) {
            guard let current = details[conversationID] else { throw CancellationError() }
            return current
        }
        details[conversationID] = detail
        if detail.isArchived == true { removeArchivedRows(conversationID) }
        if unavailable.contains(conversationID) { unavailable.remove(conversationID) }
        model.registerProjectConversation(detail)
        trimDetails(keeping: conversationID)
        saveCache()
        return detail
    }

    /// Refreshes a conversation that is already on screen from its saved copy.
    /// Only a 404 replaces it; any other failure keeps the saved view.
    func refreshDetail(_ conversationID: String) async {
        guard let scope = fenced() else { return }
        do { try await loadDetail(conversationID) }
        catch PairingFailure.response(404) {
            guard isCurrent(scope) else { return }
            unavailable.insert(conversationID)
            widgetSnapshotChanged?()
        } catch {}
    }

    func updateConversation(_ conversationID: String, fields: [String: Any]) async throws {
        guard let model, let scope = fenced() else { throw PairingFailure.response(401) }
        guard updatingDetails.insert(conversationID).inserted else { throw PairingFailure.response(409) }
        let changesPin = fields["isPinned"] != nil
        let changesRead = fields["hasUnread"] != nil
        let changesArchive = fields["isArchived"] != nil
        detailRevisions[conversationID, default: 0] += 1
        if changesPin || changesArchive { pinRevision += 1 }
        if changesRead { readRevisions[conversationID, default: 0] += 1 }
        defer {
            if self.scope == scope, model.assignmentScope == scope {
                updatingDetails.remove(conversationID)
                detailRevisions[conversationID, default: 0] += 1
                if changesPin || changesArchive { pinRevision += 1 }
                if changesRead { readRevisions[conversationID, default: 0] += 1 }
            }
        }
        let detail: ProjectConversationDetail = try await model.manage(
            "/api/v1/project-conversations/\(ConnectionModel.escape(conversationID))", method: "PATCH",
            body: JSONSerialization.data(withJSONObject: fields))
        guard isCurrent(scope) else { throw CancellationError() }
        if let unread = fields["hasUnread"] as? Bool {
            if unread { manuallyUnread.insert(conversationID) }
            else { manuallyUnread.remove(conversationID) }
        }
        details[conversationID] = detail
        model.registerProjectConversation(detail)
        if detail.isArchived == true {
            removeArchivedRows(conversationID)
            saveCache()
            return
        }
        for (project, var state) in threads {
            guard let index = state.threads.firstIndex(where: { $0.conversationId == conversationID }) else { continue }
            let old = state.threads[index]
            state.threads[index] = ProjectThreadSummary(reference: old.reference, conversationId: old.conversationId, title: detail.title,
                family: old.family, updatedAt: old.updatedAt, isPinned: detail.isPinned, hasUnread: detail.hasUnread, isWorking: old.isWorking)
            threads[project] = state
        }
        if detail.isPinned, !pinned.contains(where: { $0.thread.conversationId == conversationID }),
           let row = threads[detail.projectId]?.threads.first(where: { $0.conversationId == conversationID }) {
            pinned.insert(PinnedProjectThread(projectId: detail.projectId, thread: row), at: 0)
        }
        for index in pinned.indices.reversed() where pinned[index].thread.conversationId == conversationID {
            if detail.isPinned {
                let old = pinned[index].thread
                pinned[index] = PinnedProjectThread(projectId: pinned[index].projectId, thread: ProjectThreadSummary(
                    reference: old.reference, conversationId: old.conversationId, title: detail.title, family: old.family,
                    updatedAt: old.updatedAt, isPinned: true, hasUnread: detail.hasUnread, isWorking: old.isWorking))
            } else { pinned.remove(at: index) }
        }
        saveCache()
    }

    /// Reads started before a local pin save must not put the old pin back.
    /// Reads started during the optimistic sidebar change keep that state too.
    private func reconcilingPins(_ page: ProjectThreadsPage, startedAt revision: Int) -> ProjectThreadsPage {
        guard revision != pinRevision || !pendingPins.isEmpty || !updatingDetails.isEmpty else {
            archivedReferences.subtract(page.threads.map(\.reference))
            return page
        }
        let rows = page.threads.filter { !archivedReferences.contains($0.reference) }.map { row in
            if let value = pendingPins[row.reference] { return row.settingPinned(value) }
            if let id = row.conversationId, let detail = details[id] { return row.settingPinned(detail.isPinned) }
            if let current = threads.values.lazy.flatMap({ $0.threads }).first(where: { $0.reference == row.reference }) {
                return row.settingPinned(current.isPinned)
            }
            return row
        }
        return ProjectThreadsPage(threads: rows, nextCursor: page.nextCursor, partial: page.partial)
    }

    // MARK: Opening, pinning and renaming threads

    /// Remembers that a thread was opened. The most recent ones keep their saved
    /// history and detail on this phone.
    func noteOpened(_ conversationID: String) {
        if manuallyUnread.contains(conversationID) { manuallyUnread.remove(conversationID) }
        guard recentlyOpened.ids.first != conversationID else { return }
        recentlyOpened.note(conversationID)
        if model?.previewMode == false, let recentKey, let data = try? JSONEncoder().encode(recentlyOpened) {
            UserDefaults.standard.set(data, forKey: recentKey)
        }
        widgetSnapshotChanged?()
    }

    /// Conversations whose saved history must survive the conversation list's
    /// pruning: pinned threads and the most recently opened ones.
    var retainedConversationIDs: Set<String> {
        var ids = Set(recentlyOpened.ids)
        ids.formUnion(pinned.compactMap(\.thread.conversationId))
        for state in threads.values { ids.formUnion(state.threads.lazy.filter(\.isPinned).compactMap(\.conversationId)) }
        return ids
    }

    /// Pinning shows in the Pinned list at once; a failure puts everything back.
    func setPinned(_ projectID: String, thread: ProjectThreadSummary, _ value: Bool) async throws {
        guard let scope = fenced() else { throw PairingFailure.response(401) }
        let reference = thread.reference
        guard pendingPins[reference] == nil else { throw PairingFailure.response(409) }
        pendingPins[reference] = value
        defer { if self.scope == scope, model?.assignmentScope == scope { pendingPins.removeValue(forKey: reference) } }
        let previousEntry = pinned.first { $0.thread.reference == reference }
        let previousIndex = pinned.firstIndex { $0.thread.reference == reference }
        let previousThread = threads[projectID]?.threads.first { $0.reference == reference }
        pinRevision += 1
        pinned.removeAll { $0.thread.reference == reference }
        if value { pinned.insert(PinnedProjectThread(projectId: projectID, thread: thread.settingPinned(true)), at: 0) }
        replaceThread(projectID, reference: reference) { $0.settingPinned(value) }
        do {
            // Pinning a provider-only thread first attaches it, without work.
            let conversation = try await attach(projectID, thread: thread)
            try await updateConversation(conversation, fields: ["isPinned": value])
            if value, let index = pinned.firstIndex(where: { $0.thread.reference == reference }),
               let latest = threads[projectID]?.threads.first(where: { $0.reference == reference }) {
                pinned[index] = PinnedProjectThread(projectId: projectID, thread: latest)
            }
        } catch {
            guard self.scope == scope, model?.assignmentScope == scope else { throw error }
            pinRevision += 1
            pinned.removeAll { $0.thread.reference == reference }
            if let previousEntry { pinned.insert(previousEntry, at: min(previousIndex ?? 0, pinned.count)) }
            if let previousThread { replaceThread(projectID, reference: reference) { _ in previousThread } }
            saveCache()
            throw error
        }
        pendingPins.removeValue(forKey: reference)
        saveCache()
        await refresh()
    }

    func rename(_ projectID: String, thread: ProjectThreadSummary, to title: String) async throws {
        let conversation = try await attach(projectID, thread: thread)
        try await updateConversation(conversation, fields: ["title": title])
    }

    /// Whether a thread can be archived: Codex threads in Codex (once they have
    /// a provider thread), Claude Code threads in Wonder only.
    func canArchive(_ thread: ProjectThreadSummary) -> Bool {
        switch thread.family {
        case .codex: supportsArchive && thread.nativeID != nil
        case .claude: supportsArchiveList
        }
    }

    func archive(_ projectID: String, thread: ProjectThreadSummary) async throws {
        guard canArchive(thread) else { throw PairingFailure.response(422) }
        let conversation = try await attach(projectID, thread: thread)
        try await updateConversation(conversation, fields: ["isArchived": true])
        await refresh()
    }

    /// A Project's archived threads, newest first.
    func archivedThreads(_ projectID: String) async throws -> ArchivedProjectThreadsPage {
        guard let model, let scope = fenced() else { throw PairingFailure.response(401) }
        let page: ArchivedProjectThreadsPage = try await model.manage(
            "/api/v1/projects/\(ConnectionModel.escape(projectID))/threads/archived")
        guard isCurrent(scope) else { throw CancellationError() }
        return page
    }

    /// Restores an archived thread: in Codex for a Codex thread, in Wonder for
    /// Claude Code. It returns to the sidebar on the next read.
    func unarchive(_ projectID: String, thread: ProjectThreadSummary) async throws {
        let conversation = try await attach(projectID, thread: thread)
        try await updateConversation(conversation, fields: ["isArchived": false])
        archivedReferences.remove(thread.reference)
        await refresh()
        if threads[projectID] != nil { loadThreads(projectID) }
    }

    private func removeArchivedRows(_ conversationID: String) {
        for (project, var state) in threads {
            for row in state.threads where row.conversationId == conversationID { archivedReferences.insert(row.reference) }
            state.threads.removeAll { $0.conversationId == conversationID }
            threads[project] = state
        }
        for row in pinned where row.thread.conversationId == conversationID { archivedReferences.insert(row.thread.reference) }
        pinned.removeAll { $0.thread.conversationId == conversationID }
    }

    func hasUnread(_ conversationID: String) -> Bool {
        details[conversationID]?.hasUnread == true
            || pinned.contains { $0.thread.conversationId == conversationID && $0.thread.hasUnread }
            || threads.values.contains { $0.threads.contains { $0.conversationId == conversationID && $0.hasUnread } }
    }

    func readRevision(_ conversationID: String) -> Int { readRevisions[conversationID, default: 0] }

    private func reconcilingRead(_ row: ProjectThreadSummary, startedAt revisions: [String: Int]) -> ProjectThreadSummary {
        guard let id = row.conversationId, readRevision(id) != revisions[id, default: 0] else { return row }
        return row.settingUnread(hasUnread(id))
    }

    private func reconcilingReads(_ page: ProjectThreadsPage, startedAt revisions: [String: Int]) -> ProjectThreadsPage {
        ProjectThreadsPage(threads: page.threads.map { reconcilingRead($0, startedAt: revisions) },
                          nextCursor: page.nextCursor, partial: page.partial)
    }

    /// Applies a read acknowledgement the Mac has confirmed.
    func markRead(_ conversationID: String) {
        readRevisions[conversationID, default: 0] += 1
        detailRevisions[conversationID, default: 0] += 1
        for (project, var state) in threads where state.threads.contains(where: { $0.conversationId == conversationID && $0.hasUnread }) {
            state.threads = state.threads.map { $0.conversationId == conversationID ? $0.settingUnread(false) : $0 }
            threads[project] = state
        }
        if pinned.contains(where: { $0.thread.conversationId == conversationID && $0.thread.hasUnread }) {
            pinned = pinned.map { $0.thread.conversationId == conversationID ? PinnedProjectThread(projectId: $0.projectId, thread: $0.thread.settingUnread(false)) : $0 }
        }
        if let detail = details[conversationID], detail.hasUnread,
           var fields = (try? JSONEncoder().encode(detail)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
            fields["hasUnread"] = false
            if let data = try? JSONSerialization.data(withJSONObject: fields),
               let read = try? JSONDecoder().decode(ProjectConversationDetail.self, from: data) { details[conversationID] = read }
        }
        saveCache()
    }

    private func replaceThread(_ projectID: String, reference: String, _ transform: (ProjectThreadSummary) -> ProjectThreadSummary) {
        guard var state = threads[projectID], let index = state.threads.firstIndex(where: { $0.reference == reference }) else { return }
        state.threads[index] = transform(state.threads[index])
        threads[projectID] = state
    }

    /// Drops details nothing can show or reopen quickly once the cache grows.
    private func trimDetails(keeping loaded: String) {
        guard details.count > Self.detailLimit else { return }
        let keep = detailIDsToPersist().union([loaded])
        details = details.filter { keep.contains($0.key) }
    }

    private func detailIDsToPersist() -> Set<String> {
        var ids = retainedConversationIDs
        for state in threads.values {
            ids.formUnion(state.threads.prefix(SidebarProjection.initialThreads + 10).compactMap(\.conversationId))
        }
        return ids
    }

    /// The first message creates the native thread; the request ID makes a
    /// lost response retry the same creation instead of starting another.
    func createThread(projectID: String, draft: NewChatDraft, body: String, deviceID: String) async throws -> CreateProjectThreadResponse {
        guard let model, let scope = fenced(), let family = draft.family, let modelID = draft.model else { throw PairingFailure.response(422) }
        var fields: [String: Any] = ["deviceId": deviceID, "clientMessageId": draft.requestID, "family": family.rawValue,
                                     "model": modelID, "accessMode": draft.accessMode.rawValue, "body": body, "prepareOnly": true]
        if let effort = draft.effort { fields["effort"] = effort }
        if let serviceTier = draft.serviceTier { fields["serviceTier"] = serviceTier }
        if supportsModes {
            if family == .claude { fields["claudeApproval"] = (draft.claudeApproval ?? .standard).rawValue }
            if draft.planMode == true { fields["planMode"] = true }
        }
        if let folder = draft.folderId { fields["folderId"] = folder }
        if let revision = draft.rootsRevision { fields["rootsRevision"] = revision }
        let response: CreateProjectThreadResponse = try await model.manage(
            "/api/v1/projects/\(ConnectionModel.escape(projectID))/threads", method: "POST",
            body: JSONSerialization.data(withJSONObject: fields))
        guard isCurrent(scope) else { throw CancellationError() }
        var state = threads[projectID] ?? ProjectThreadsState()
        if !state.threads.contains(where: { $0.conversationId == response.conversation.conversationId }) {
            state.threads.insert(response.conversation, at: 0)
            state.hasLoaded = true
        }
        threads[projectID] = state
        if threadTasks[projectID] != nil, let id = response.conversation.conversationId {
            createdDuringThreadRead[projectID, default: []].insert(id)
        }
        if let index = projects.firstIndex(where: { $0.id == projectID }) {
            let old = projects[index]
            projects[index] = ProjectSummary(id: old.id, name: old.name, isIncluded: old.isIncluded, isPinned: old.isPinned,
                rootsRevision: old.rootsRevision, folders: old.folders, lastFamily: family, lastUsedAt: old.lastUsedAt, createdAt: old.createdAt)
        }
        saveCache()
        return response
    }

    /// Copies a started thread, through `lastTurnID` when given, into a new
    /// thread in the same project. The Mac never changes the source. Returns
    /// the new conversation's ID.
    func fork(_ conversationID: String, lastTurnID: String?) async throws -> String {
        guard let model, let scope = fenced() else { throw PairingFailure.response(401) }
        let created: ProjectThreadSummary = try await model.manage(
            "/api/v1/project-conversations/\(ConnectionModel.escape(conversationID))/fork", method: "POST",
            body: ForkConversationRequest(lastTurnId: lastTurnID).body())
        guard isCurrent(scope), let id = created.conversationId else { throw CancellationError() }
        if let projectID = details[conversationID]?.projectId, var state = threads[projectID],
           !state.threads.contains(where: { $0.conversationId == id }) {
            state.threads.insert(created, at: 0)
            threads[projectID] = state
            if threadTasks[projectID] != nil { createdDuringThreadRead[projectID, default: []].insert(id) }
            saveCache()
        }
        return id
    }

    func continuation(_ conversationID: String) async throws -> DesktopContinuation {
        guard let model, let scope = fenced() else { throw PairingFailure.response(401) }
        let response: DesktopContinuation = try await model.manage("/api/v1/conversations/\(ConnectionModel.escape(conversationID))/desktop-continuation")
        guard isCurrent(scope) else { throw CancellationError() }
        return response
    }

    // Bounded offline cache: the project list and each first thread page.
    private struct Cache: Codable {
        let projects: [ProjectSummary]
        let threads: [String: [ProjectThreadSummary]]
        let details: [String: ProjectConversationDetail]?
        let pinned: [PinnedProjectThread]?
        let supportsModes: Bool?
        let supportsProjects: Bool?
    }
    private func hostKey() -> String? { model?.connection.map { Data($0.credential.hostInstallationId.utf8).base64EncodedString() } }
    private var cacheKey: String? { hostKey().map { "wonder.projects." + $0 } }
    private var recentKey: String? { hostKey().map { "wonder.projects.recent." + $0 } }
    private func saveCache() {
        guard let cacheKey, model?.previewMode == false else { return }
        let firstPages = threads.mapValues { Array($0.threads.prefix(SidebarProjection.initialThreads + 10)) }
        let persisted = detailIDsToPersist()
        if let data = try? JSONEncoder().encode(Cache(projects: projects, threads: firstPages,
            details: details.filter { persisted.contains($0.key) },
            pinned: pinned, supportsModes: supportsModes, supportsProjects: supportsProjects)) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        widgetSnapshotChanged?()
    }
    private func restoreCache() {
        if let recentKey, let data = UserDefaults.standard.data(forKey: recentKey),
           let recent = try? JSONDecoder().decode(RecentlyOpenedConversations.self, from: data) {
            recentlyOpened = RecentlyOpenedConversations(ids: recent.ids)
        }
        guard let cacheKey, let data = UserDefaults.standard.data(forKey: cacheKey),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        projects = cache.projects
        details = cache.details ?? [:]
        pinned = cache.pinned ?? []
        supportsModes = cache.supportsModes ?? false
        supportsProjects = cache.supportsProjects
        details.values.forEach { model?.registerProjectConversation($0) }
        for (project, rows) in cache.threads where threads[project] == nil {
            var state = ProjectThreadsState()
            state.threads = rows
            threads[project] = state
        }
    }
    func forgetCache() {
        if let cacheKey { UserDefaults.standard.removeObject(forKey: cacheKey) }
        if let recentKey { UserDefaults.standard.removeObject(forKey: recentKey) }
        widgetSnapshotChanged?()
    }
}

extension ConnectionModel {
    /// Present a project thread through the shared conversation surface. It is
    /// not a Bot conversation and never enters the Bot inbox list.
    func projectChat(_ detail: ProjectConversationDetail) -> ChatSummary {
        ChatSummary(conversationId: detail.conversationId, botId: nil, title: detail.title, lastMessagePreview: nil,
                    lastMessageAt: nil, messageCount: 0, deliveryState: nil, hasUnread: detail.hasUnread,
                    isArchived: detail.isArchived == true, isPinned: detail.isPinned)
    }
    func projectDetail(_ chat: ChatSummary) -> ProjectConversationDetail? { projects.details[chat.id] }
}
