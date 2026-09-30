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
    /// Pinned threads across this Mac's included projects.
    @Published private(set) var pinned: [PinnedProjectThread] = []
    /// Conversations the Mac reported gone while a saved copy was still open.
    @Published private(set) var unavailable: Set<String> = []
    @Published var failure: String?
    /// Model catalog for project composer settings, per connection scope.
    @Published var options: BotOptions?
    var owner: ConnectionModel? { model }
    private var scope: String?
    private var threadTasks: [String: Task<Void, Never>] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private var refreshPinRevision = 0
    /// Newest first; bounded so saved history stays small (see `retainedConversationIDs`).
    private var recentlyOpened = RecentlyOpenedConversations()
    /// Bumped by every local pin change so an older refresh cannot undo it.
    private var pinRevision = 0
    private var pendingPins: [String: Bool] = [:]
    private var detailRevisions: [String: Int] = [:]
    private var updatingDetails: Set<String> = []
    /// In-memory detail cache bound; open, recent, pinned and first-page threads always stay.
    private static let detailLimit = 120

    init(model: ConnectionModel) {
        self.model = model
        restoreCache()
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
            projects = []; families = []; loadingProjects = false; failure = nil
            threads = [:]; details = [:]; supportsProjects = nil; options = nil
            supportsModes = false; pinned = []; unavailable = []; recentlyOpened = RecentlyOpenedConversations()
            pendingPins = [:]; detailRevisions = [:]; updatingDetails = []
            restoreCache()
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
        do {
            let response: ProjectsResponse = try await model.manage("/api/v1/projects")
            guard isCurrent(scope) else { return }
            supportsProjects = true
            let previous = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.rootsRevision) })
            projects = response.projects
            families = response.families
            supportsModes = (response.modesVersion ?? 0) >= 1
            // A pin changed while this request was in flight; the next refresh reports it.
            if pinRevision == pinRevisionAtStart, pendingPins.isEmpty, updatingDetails.isEmpty {
                pinned = response.pinned ?? []
            }
            failure = nil
            for project in projects where threads[project.id] != nil {
                if previous[project.id] != project.rootsRevision { threads[project.id]?.nextCursor = nil }
                loadThreads(project.id)
            }
            saveCache()
        } catch PairingFailure.response(404) {
            guard isCurrent(scope) else { return }
            supportsProjects = false
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
        threadTasks[key] = Task { [weak self] in
            defer { if self?.scope == scope { self?.threadTasks[key] = nil } }
            var path = "/api/v1/projects/\(ConnectionModel.escape(projectID))/threads?limit=\(more ? 10 : SidebarProjection.initialThreads)"
            if let cursor { path += "&cursor=" + ConnectionModel.escape(cursor) }
            do {
                let page: ProjectThreadsPage = try await model.manage(path)
                guard let self, self.isCurrent(scope), !Task.isCancelled else { return }
                var next = self.threads[projectID] ?? ProjectThreadsState()
                next.apply(self.reconcilingPins(page, startedAt: pinRevisionAtStart), replacing: !more)
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
                    let page: ProjectThreadsPage = try await model.manage("/api/v1/projects/\(ConnectionModel.escape(projectID))/threads?limit=\(SidebarProjection.initialThreads)")
                    guard self.isCurrent(scope) else { return }
                    var next = self.threads[projectID] ?? ProjectThreadsState()
                    next.apply(self.reconcilingPins(page, startedAt: revision), replacing: true); next.isLoading = false
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
        } catch {}
    }

    func updateConversation(_ conversationID: String, fields: [String: Any]) async throws {
        guard let model, let scope = fenced() else { throw PairingFailure.response(401) }
        guard updatingDetails.insert(conversationID).inserted else { throw PairingFailure.response(409) }
        let changesPin = fields["isPinned"] != nil
        detailRevisions[conversationID, default: 0] += 1
        if changesPin { pinRevision += 1 }
        defer {
            if self.scope == scope, model.assignmentScope == scope {
                updatingDetails.remove(conversationID)
                detailRevisions[conversationID, default: 0] += 1
                if changesPin { pinRevision += 1 }
            }
        }
        let detail: ProjectConversationDetail = try await model.manage(
            "/api/v1/project-conversations/\(ConnectionModel.escape(conversationID))", method: "PATCH",
            body: JSONSerialization.data(withJSONObject: fields))
        guard isCurrent(scope) else { throw CancellationError() }
        details[conversationID] = detail
        model.registerProjectConversation(detail)
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
        guard revision != pinRevision || !pendingPins.isEmpty || !updatingDetails.isEmpty else { return page }
        let rows = page.threads.map { row in
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
        guard recentlyOpened.ids.first != conversationID else { return }
        recentlyOpened.note(conversationID)
        if model?.previewMode == false, let recentKey, let data = try? JSONEncoder().encode(recentlyOpened) {
            UserDefaults.standard.set(data, forKey: recentKey)
        }
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

    func hasUnread(_ conversationID: String) -> Bool {
        details[conversationID]?.hasUnread == true
            || pinned.contains { $0.thread.conversationId == conversationID && $0.thread.hasUnread }
            || threads.values.contains { $0.threads.contains { $0.conversationId == conversationID && $0.hasUnread } }
    }

    /// Applies a read acknowledgement the Mac has confirmed.
    func markRead(_ conversationID: String) {
        for (project, var state) in threads where state.threads.contains(where: { $0.conversationId == conversationID && $0.hasUnread }) {
            state.threads = state.threads.map { $0.conversationId == conversationID ? $0.settingRead() : $0 }
            threads[project] = state
        }
        if pinned.contains(where: { $0.thread.conversationId == conversationID && $0.thread.hasUnread }) {
            pinned = pinned.map { $0.thread.conversationId == conversationID ? PinnedProjectThread(projectId: $0.projectId, thread: $0.thread.settingRead()) : $0 }
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
        if supportsModes {
            if family == .claude, let approval = draft.claudeApproval { fields["claudeApproval"] = approval.rawValue }
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
        if let index = projects.firstIndex(where: { $0.id == projectID }) {
            let old = projects[index]
            projects[index] = ProjectSummary(id: old.id, name: old.name, isIncluded: old.isIncluded, isPinned: old.isPinned,
                rootsRevision: old.rootsRevision, folders: old.folders, lastFamily: family, lastUsedAt: old.lastUsedAt, createdAt: old.createdAt)
        }
        return response
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
            pinned: pinned, supportsModes: supportsModes)) { UserDefaults.standard.set(data, forKey: cacheKey) }
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
    }
}

extension ConnectionModel {
    /// Present a project thread through the shared conversation surface. It is
    /// not a Bot conversation and never enters the Bot inbox list.
    func projectChat(_ detail: ProjectConversationDetail) -> ChatSummary {
        ChatSummary(conversationId: detail.conversationId, botId: nil, title: detail.title, lastMessagePreview: nil,
                    lastMessageAt: nil, messageCount: 0, deliveryState: nil, hasUnread: detail.hasUnread,
                    isArchived: false, isPinned: detail.isPinned)
    }
    func projectDetail(_ chat: ChatSummary) -> ProjectConversationDetail? { projects.details[chat.id] }
}
