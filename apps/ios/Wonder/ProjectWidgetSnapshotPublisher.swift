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
        let projects = projectRows(from: library)
        let previous = ProjectWidgetSnapshotStore.load(bundleIdentifier: Bundle.main.bundleIdentifier)
        let candidate = ProjectWidgetSnapshot(savedAt: previous?.savedAt ?? Date(),
                                              showNamesOnWidgets: showNames, projects: projects).validated()
        if let candidate, let previous,
           candidate.showNamesOnWidgets == previous.showNamesOnWidgets,
           candidate.projects == previous.projects {
            let age = Date().timeIntervalSince(previous.savedAt)
            if !refreshIfUnchanged || (age >= 0 && age < 15 * 60) { return true }
        }
        let snapshot = ProjectWidgetSnapshot(showNamesOnWidgets: showNames, projects: projects)
        guard ProjectWidgetSnapshotStore.save(snapshot, bundleIdentifier: Bundle.main.bundleIdentifier) else { return false }
        WidgetCenter.shared.reloadTimelines(ofKind: ProjectWidgetSnapshot.widgetKind)
        return true
    }

    static func projectRows(from library: ConnectionLibrary) -> [ProjectWidgetSnapshot.Project] {
        var result: [ProjectWidgetSnapshot.Project] = []
        for saved in library.saved.connections where !saved.requiresPairing {
            if result.count == 10 { break }
            let model = library.model(for: saved)
            guard model.connection?.credential.deviceId == saved.credential.deviceId,
                  model.connection?.credential.sessionToken == saved.credential.sessionToken,
                  !model.accessEnded, model.projects.supportsProjects != false else { continue }
            let hostID = saved.credential.hostInstallationId
            for project in model.projects.includedProjects.prefix(10 - result.count) {
                let rows = (model.projects.threads[project.id]?.threads ?? []) + model.projects.pinned
                    .filter { $0.projectId == project.id }.map(\.thread)
                var seen = Set<String>()
                let recent = rows.sorted { left, right in
                    if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
                    return left.reference < right.reference
                }.compactMap { row -> ProjectWidgetSnapshot.Chat? in
                    guard let id = row.conversationId,
                          seen.insert(id).inserted, !model.projects.unavailable.contains(id),
                          model.projects.details[id]?.isArchived != true,
                          model.projects.details[id].map({ $0.projectId == project.id }) ?? true else { return nil }
                    return ProjectWidgetSnapshot.Chat(id: id, title: row.title)
                }
                result.append(.init(hostID: hostID, id: project.id, name: project.name,
                                    recentChats: Array(recent.prefix(3))))
            }
        }
        return result
    }
}
