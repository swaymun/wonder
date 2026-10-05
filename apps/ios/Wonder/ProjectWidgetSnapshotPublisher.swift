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
        let showNames = UserDefaults.standard.bool(forKey: ProjectWidgetSnapshot.showNamesPreferenceKey)
        let (hostID, hostName, projects) = lastMacRows(from: library)
        let previous = ProjectWidgetSnapshotStore.load(bundleIdentifier: Bundle.main.bundleIdentifier)
        let candidate = ProjectWidgetSnapshot(savedAt: previous?.savedAt ?? Date(), showNamesOnWidgets: showNames,
                                              hostID: hostID, hostName: hostName, projects: projects).validated()
        if let candidate, let previous,
           candidate.showNamesOnWidgets == previous.showNamesOnWidgets, candidate.hostID == previous.hostID,
           candidate.hostName == previous.hostName, candidate.projects == previous.projects {
            let age = Date().timeIntervalSince(previous.savedAt)
            if !refreshIfUnchanged || (age >= 0 && age < 15 * 60) { return true }
        }
        let snapshot = ProjectWidgetSnapshot(showNamesOnWidgets: showNames, hostID: hostID, hostName: hostName, projects: projects)
        guard ProjectWidgetSnapshotStore.save(snapshot, bundleIdentifier: Bundle.main.bundleIdentifier) else { return false }
        WidgetCenter.shared.reloadTimelines(ofKind: ProjectWidgetSnapshot.widgetKind)
        return true
    }

    /// The Mac last chosen for a new chat (or the first paired one) and its
    /// Projects, most recently used first.
    static func lastMacRows(from library: ConnectionLibrary) -> (String?, String, [ProjectWidgetSnapshot.Project]) {
        let usable = library.saved.connections.filter { saved in
            guard !saved.requiresPairing else { return false }
            let model = library.model(for: saved)
            return model.connection?.credential.deviceId == saved.credential.deviceId
                && model.connection?.credential.sessionToken == saved.credential.sessionToken && !model.accessEnded
        }
        let last = NewChatDraftStore.lastHost
        guard let saved = usable.first(where: { $0.credential.hostInstallationId == last }) ?? usable.first else {
            return (nil, "Mac", [])
        }
        let model = library.model(for: saved)
        guard model.projects.supportsProjects != false else { return (saved.credential.hostInstallationId, model.macName, []) }
        let projects = model.projects.includedProjects
            .sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
            .prefix(ProjectWidgetSnapshot.maxProjects)
            .map { ProjectWidgetSnapshot.Project(id: $0.id, name: $0.name) }
        return (saved.credential.hostInstallationId, model.macName, projects)
    }
}
