import Foundation
import WidgetKit
import WonderPairing

/// Publishes only already loaded Project catalog rows. WidgetKit never starts
/// network or model work; opening a saved link lets the main app reconcile it.
@MainActor enum ProjectWidgetSnapshotPublisher {
    @discardableResult static func publish(from library: ConnectionLibrary, refreshIfUnchanged: Bool = false) -> Bool {
        guard !library.isPreview, library.loaded,
              ProjectWidgetIdentity(bundleIdentifier: Bundle.main.bundleIdentifier) != nil,
              ProjectWidgetSnapshotStore.containerURL(bundleIdentifier: Bundle.main.bundleIdentifier) != nil else {
            return false
        }
        let (hostID, hostName, projects, threads) = lastMacRows(from: library)
        let previous = ProjectWidgetSnapshotStore.load(bundleIdentifier: Bundle.main.bundleIdentifier)
        let candidate = ProjectWidgetSnapshot(savedAt: previous?.savedAt ?? Date(),
                                              hostID: hostID, hostName: hostName, projects: projects, threads: threads).validated()
        if let candidate, let previous,
           candidate.hostID == previous.hostID, candidate.hostName == previous.hostName, candidate.projects == previous.projects,
           candidate.threads == previous.threads {
            let age = Date().timeIntervalSince(previous.savedAt)
            if !refreshIfUnchanged || (age >= 0 && age < 15 * 60) { return true }
        }
        let snapshot = ProjectWidgetSnapshot(hostID: hostID, hostName: hostName, projects: projects, threads: threads)
        guard ProjectWidgetSnapshotStore.save(snapshot, bundleIdentifier: Bundle.main.bundleIdentifier) else { return false }
        WidgetCenter.shared.reloadTimelines(ofKind: ProjectWidgetSnapshot.widgetKind)
        return true
    }

    /// The Mac last chosen for a new chat (or the first paired one), its
    /// Projects most recently used first, and its loaded Project threads most
    /// recently active first.
    static func lastMacRows(from library: ConnectionLibrary)
        -> (String?, String, [ProjectWidgetSnapshot.Project], [ProjectWidgetSnapshot.Thread]) {
        let usable = library.saved.connections.filter { saved in
            guard !saved.requiresPairing else { return false }
            let model = library.model(for: saved)
            return model.connection?.credential.deviceId == saved.credential.deviceId
                && model.connection?.credential.sessionToken == saved.credential.sessionToken && !model.accessEnded
        }
        let last = NewChatDraftStore.lastHost
        guard let saved = usable.first(where: { $0.credential.hostInstallationId == last }) ?? usable.first else {
            return (nil, "Mac", [], [])
        }
        let model = library.model(for: saved)
        guard model.projects.supportsProjects != false else { return (saved.credential.hostInstallationId, model.macName, [], []) }
        let included = model.projects.includedProjects
        let projects = included
            .sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
            .prefix(ProjectWidgetSnapshot.maxProjects)
            .map { ProjectWidgetSnapshot.Project(id: $0.id, name: $0.name) }
        return (saved.credential.hostInstallationId, model.macName, projects,
                recentThreads(projects: included, threads: model.projects.threads, pinned: model.projects.pinned))
    }

    /// Threads already loaded for included Projects, most recently active first.
    static func recentThreads(projects: [ProjectSummary], threads: [String: ProjectThreadsState],
                              pinned: [PinnedProjectThread]) -> [ProjectWidgetSnapshot.Thread] {
        let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var rows: [(project: String, thread: ProjectThreadSummary)] = pinned.map { ($0.projectId, $0.thread) }
        for (project, state) in threads { rows += state.threads.map { (project, $0) } }
        var seen = Set<String>()
        return rows
            .filter { names[$0.project] != nil && seen.insert($0.thread.reference).inserted }
            .sorted { $0.thread.updatedAt > $1.thread.updatedAt }
            .compactMap { row -> ProjectWidgetSnapshot.Thread? in
                let thread = row.thread
                guard thread.conversationId != nil || thread.nativeID != nil else { return nil }
                return ProjectWidgetSnapshot.Thread(projectID: row.project, family: thread.family.rawValue,
                    nativeID: thread.nativeID, conversationID: thread.conversationId,
                    title: thread.title, projectName: names[row.project] ?? "Project")
            }
            .prefix(ProjectWidgetSnapshot.maxThreads)
            .map { $0 }
    }
}
