import Foundation

/// The only data shared with WidgetKit. It contains navigation labels and
/// opaque IDs, never message text, folder paths, credentials, or agent state.
struct ProjectWidgetSnapshot: Codable, Equatable, Sendable {
    static let version = 1
    static let widgetKind = "WonderProjectWidget"
    static let showNamesPreferenceKey = "wonder.widgets.showNames"
    static let staleAfter: TimeInterval = 60 * 60
    static let maxBytes = 32 * 1024

    struct Chat: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let title: String
    }

    struct Project: Codable, Equatable, Sendable, Identifiable {
        let hostID: String
        let id: String
        let name: String
        let recentChats: [Chat]

        var selectionID: String { "\(hostID)/\(id)" }
    }

    let schemaVersion: Int
    let savedAt: Date
    let showNamesOnWidgets: Bool
    let projects: [Project]

    init(savedAt: Date = Date(), showNamesOnWidgets: Bool = false, projects: [Project]) {
        self.schemaVersion = Self.version
        self.savedAt = savedAt
        self.showNamesOnWidgets = showNamesOnWidgets
        self.projects = projects
    }

    /// Validate after decoding as well as before writing: the shared container
    /// is a data boundary, not a source of trusted URLs or unbounded view text.
    func validated() -> Self? {
        guard schemaVersion == Self.version, savedAt.timeIntervalSince1970.isFinite else { return nil }
        var seenProjects = Set<String>()
        var safeProjects: [Project] = []
        for project in projects {
            if safeProjects.count == 10 { break }
            guard ProjectWidgetLink.validID(project.hostID), ProjectWidgetLink.validID(project.id),
                  seenProjects.insert(project.selectionID).inserted else { continue }
            var seenChats = Set<String>()
            var chats: [Chat] = []
            for chat in project.recentChats {
                if chats.count == 3 { break }
                guard ProjectWidgetLink.validID(chat.id), seenChats.insert(chat.id).inserted else { continue }
                let title = showNamesOnWidgets ? Self.safeLabel(chat.title, fallback: "Recent chat") :
                    "Recent chat \(chats.count + 1)"
                chats.append(Chat(id: chat.id, title: title))
            }
            let name = showNamesOnWidgets ? Self.safeLabel(project.name, fallback: "Project") :
                "Project \(safeProjects.count + 1)"
            safeProjects.append(Project(hostID: project.hostID, id: project.id, name: name, recentChats: chats))
        }
        return Self(savedAt: savedAt, showNamesOnWidgets: showNamesOnWidgets, projects: safeProjects)
    }

    func isStale(at date: Date) -> Bool {
        let age = date.timeIntervalSince(savedAt)
        return age < -5 * 60 || age >= Self.staleAfter
    }

    private static func safeLabel(_ raw: String, fallback: String) -> String {
        let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let label = String(String.UnicodeScalarView(scalars.prefix(80)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? fallback : label
    }
}

/// App and extension resolve their shared container from exact bundle IDs.
/// The blue Testing app can never read the orange production snapshot.
enum ProjectWidgetIdentity: String {
    case production = "com.swaymun.wonder"
    case testing = "com.swaymun.wonder.testing"

    init?(bundleIdentifier: String?) {
        switch bundleIdentifier {
        case Self.production.rawValue, Self.production.rawValue + ".Widget": self = .production
        case Self.testing.rawValue, Self.testing.rawValue + ".Widget": self = .testing
        default: return nil
        }
    }

    var appGroupID: String { "group.\(rawValue)" }
    var linkScheme: String { self == .testing ? "wonder-testing" : "wonder" }
}

enum ProjectWidgetLink {
    static func newChat(hostID: String, projectID: String, identity: ProjectWidgetIdentity) -> URL? {
        guard validID(hostID), validID(projectID) else { return nil }
        return url(path: "/hosts/\(hostID)/projects/\(projectID)/new", identity: identity)
    }

    static func chat(hostID: String, chatID: String, identity: ProjectWidgetIdentity) -> URL? {
        guard validID(hostID), validID(chatID) else { return nil }
        return url(path: "/hosts/\(hostID)/chats/\(chatID)", identity: identity)
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func url(path: String, identity: ProjectWidgetIdentity) -> URL? {
        var components = URLComponents()
        components.scheme = identity.linkScheme
        components.host = "v1"
        components.path = path
        guard let url = components.url, url.absoluteString.utf8.count <= 512 else { return nil }
        return url
    }
}

enum ProjectWidgetSnapshotStore {
    private static let fileName = "project-widget-snapshot-v1.json"

    static func containerURL(bundleIdentifier: String?) -> URL? {
        guard let identity = ProjectWidgetIdentity(bundleIdentifier: bundleIdentifier),
              let directory = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: identity.appGroupID) else { return nil }
        return directory
    }

    @discardableResult static func save(_ snapshot: ProjectWidgetSnapshot, bundleIdentifier: String?) -> Bool {
        guard let directory = containerURL(bundleIdentifier: bundleIdentifier) else { return false }
        return save(snapshot, in: directory)
    }

    /// Replaces the old file atomically, including when names are switched off
    /// or a previously corrupt snapshot needs to be recovered.
    @discardableResult static func save(_ snapshot: ProjectWidgetSnapshot, in directory: URL) -> Bool {
        guard let validated = snapshot.validated(),
              let data = try? JSONEncoder().encode(validated), data.count <= ProjectWidgetSnapshot.maxBytes else {
            return false
        }
        return (try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)) != nil
    }

    static func load(bundleIdentifier: String?) -> ProjectWidgetSnapshot? {
        guard let directory = containerURL(bundleIdentifier: bundleIdentifier) else { return nil }
        return load(from: directory)
    }

    static func load(from directory: URL) -> ProjectWidgetSnapshot? {
        let file = directory.appendingPathComponent(fileName)
        guard let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              properties.isRegularFile == true, properties.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        while data.count <= ProjectWidgetSnapshot.maxBytes {
            let part: Data
            do {
                part = try handle.read(upToCount: min(4096, ProjectWidgetSnapshot.maxBytes + 1 - data.count)) ?? Data()
            } catch {
                return nil
            }
            if part.isEmpty { break }
            data.append(part)
        }
        guard data.count <= ProjectWidgetSnapshot.maxBytes,
              let snapshot = try? JSONDecoder().decode(ProjectWidgetSnapshot.self, from: data) else { return nil }
        return snapshot.validated()
    }
}
