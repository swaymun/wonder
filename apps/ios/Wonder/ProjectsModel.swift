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
    @Published var failure: String?
    /// Model catalog for project composer settings, per connection scope.
    @Published var options: BotOptions?
    var owner: ConnectionModel? { model }
    private var scope: String?
    private var threadTasks: [String: Task<Void, Never>] = [:]
    private var refreshTask: Task<Void, Never>?

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
            refreshTask?.cancel(); refreshTask = nil
            threadTasks = [:]
            projects = []; families = []; loadingProjects = false; failure = nil
            threads = [:]; details = [:]; supportsProjects = nil; options = nil
            restoreCache()
        }
        return current
    }

    private func isCurrent(_ expected: String) -> Bool {
        scope == expected && model?.assignmentScope == expected && model?.accessEnded == false && !Task.isCancelled
    }

    func refresh() async {
        guard let expected = fenced() else { return }
        if let refreshTask { return await refreshTask.value }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        if isCurrent(expected) { refreshTask = nil }
    }

    private func performRefresh() async {
        guard let model, let scope = fenced(), !model.previewMode else { return }
        loadingProjects = true
        defer { if scope == self.scope { loadingProjects = false } }
        do {
            let response: ProjectsResponse = try await model.manage("/api/v1/projects")
            guard isCurrent(scope) else { return }
            supportsProjects = true
            let previous = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.rootsRevision) })
            projects = response.projects
            families = response.families
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
        threadTasks[key] = Task { [weak self] in
            defer { if self?.scope == scope { self?.threadTasks[key] = nil } }
            var path = "/api/v1/projects/\(ConnectionModel.escape(projectID))/threads?limit=\(more ? 10 : SidebarProjection.initialThreads)"
            if let cursor { path += "&cursor=" + ConnectionModel.escape(cursor) }
            do {
                let page: ProjectThreadsPage = try await model.manage(path)
                guard let self, self.isCurrent(scope), !Task.isCancelled else { return }
                var next = self.threads[projectID] ?? ProjectThreadsState()
                next.apply(page, replacing: !more)
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
                    let page: ProjectThreadsPage = try await model.manage("/api/v1/projects/\(ConnectionModel.escape(projectID))/threads?limit=\(SidebarProjection.initialThreads)")
                    guard self.isCurrent(scope) else { return }
                    var next = self.threads[projectID] ?? ProjectThreadsState()
                    next.apply(page, replacing: true); next.isLoading = false
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
        if let id = thread.conversationId { return id }
        guard let model, let scope = fenced() else { throw PairingFailure.response(401) }
        let attached: ProjectThreadSummary = try await model.manage(
            "/api/v1/projects/\(ConnectionModel.escape(projectID))/threads/attach", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["reference": thread.reference]))
        guard isCurrent(scope), let id = attached.conversationId else { throw CancellationError() }
        if var state = threads[projectID], let index = state.threads.firstIndex(where: { $0.reference == thread.reference }) {
            state.threads[index] = attached
            threads[projectID] = state
        }
        return id
    }

    @discardableResult func loadDetail(_ conversationID: String) async throws -> ProjectConversationDetail {
        guard let model, let scope = fenced() else { throw PairingFailure.response(401) }
        let detail: ProjectConversationDetail = try await model.manage("/api/v1/project-conversations/\(ConnectionModel.escape(conversationID))")
        guard isCurrent(scope) else { throw CancellationError() }
        details[conversationID] = detail
        model.registerProjectConversation(detail)
        saveCache()
        return detail
    }

    func updateConversation(_ conversationID: String, fields: [String: Any]) async throws {
        guard let model, let scope = fenced() else { throw PairingFailure.response(401) }
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
    }

    /// The first message creates the native thread; the request ID makes a
    /// lost response retry the same creation instead of starting another.
    func createThread(projectID: String, draft: NewChatDraft, body: String, deviceID: String) async throws -> CreateProjectThreadResponse {
        guard let model, let scope = fenced(), let family = draft.family, let modelID = draft.model else { throw PairingFailure.response(422) }
        var fields: [String: Any] = ["deviceId": deviceID, "clientMessageId": draft.requestID, "family": family.rawValue,
                                     "model": modelID, "accessMode": draft.accessMode.rawValue, "body": body, "prepareOnly": true]
        if let effort = draft.effort { fields["effort"] = effort }
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
    }
    private var cacheKey: String? { model?.connection.map { "wonder.projects." + Data($0.credential.hostInstallationId.utf8).base64EncodedString() } }
    private func saveCache() {
        guard let cacheKey, model?.previewMode == false else { return }
        let firstPages = threads.mapValues { Array($0.threads.prefix(SidebarProjection.initialThreads + 10)) }
        if let data = try? JSONEncoder().encode(Cache(projects: projects, threads: firstPages, details: details.filter { id, _ in firstPages.values.contains { $0.contains { $0.conversationId == id } } })) { UserDefaults.standard.set(data, forKey: cacheKey) }
    }
    private func restoreCache() {
        guard let cacheKey, let data = UserDefaults.standard.data(forKey: cacheKey),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        projects = cache.projects
        details = cache.details ?? [:]
        details.values.forEach { model?.registerProjectConversation($0) }
        for (project, rows) in cache.threads where threads[project] == nil {
            var state = ProjectThreadsState()
            state.threads = rows
            threads[project] = state
        }
    }
    func forgetCache() { if let cacheKey { UserDefaults.standard.removeObject(forKey: cacheKey) } }
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
