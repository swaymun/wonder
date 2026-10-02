import AppIntents
import SwiftUI
import WidgetKit

struct WonderWidgetProject: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Project")
    static let defaultQuery = WonderWidgetProjectQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WonderWidgetProjectQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WonderWidgetProject] {
        let saved = Dictionary(uniqueKeysWithValues: Self.savedProjects().map { ($0.id, $0) })
        return identifiers.compactMap { id in
            if let project = saved[id] { return project }
            let parts = id.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ ProjectWidgetLink.validID(String($0)) }) else { return nil }
            // Keep the configured identity after a Project is removed so the
            // widget can explain recovery instead of selecting another one.
            return WonderWidgetProject(id: id, name: "Project unavailable")
        }
    }

    func suggestedEntities() async throws -> [WonderWidgetProject] { Self.savedProjects() }

    private static func savedProjects() -> [WonderWidgetProject] {
        guard let snapshot = ProjectWidgetSnapshotStore.load(bundleIdentifier: Bundle.main.bundleIdentifier) else { return [] }
        return snapshot.projects.map { WonderWidgetProject(id: $0.selectionID, name: $0.name) }
    }
}

struct WonderProjectWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Wonder Project"
    static let description = IntentDescription("Open a Project chat or start one in Wonder.")

    @Parameter(title: "Project") var project: WonderWidgetProject?
}

struct WonderProjectWidgetEntry: TimelineEntry {
    enum EmptyReason {
        case chooseProject, snapshotUnavailable, projectUnavailable
    }

    let date: Date
    let project: ProjectWidgetSnapshot.Project?
    let savedAt: Date?
    let identity: ProjectWidgetIdentity?
    let emptyReason: EmptyReason?

    var isStale: Bool {
        guard let savedAt else { return true }
        return ProjectWidgetSnapshot(savedAt: savedAt, projects: []).isStale(at: date)
    }
}

struct WonderProjectWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WonderProjectWidgetEntry {
        WonderProjectWidgetEntry(date: Date(), project: nil, savedAt: nil,
                                 identity: nil, emptyReason: .chooseProject)
    }

    func snapshot(for configuration: WonderProjectWidgetConfiguration, in context: Context) async -> WonderProjectWidgetEntry {
        entry(for: configuration, at: Date())
    }

    func timeline(for configuration: WonderProjectWidgetConfiguration, in context: Context) async -> Timeline<WonderProjectWidgetEntry> {
        let now = Date()
        let first = entry(for: configuration, at: now)
        var entries = [first]
        if let savedAt = first.savedAt {
            let staleAt = savedAt.addingTimeInterval(ProjectWidgetSnapshot.staleAfter)
            if staleAt > now { entries.append(entry(for: configuration, at: staleAt)) }
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(60 * 60)))
    }

    private func entry(for configuration: WonderProjectWidgetConfiguration, at date: Date) -> WonderProjectWidgetEntry {
        guard let identity = ProjectWidgetIdentity(bundleIdentifier: Bundle.main.bundleIdentifier),
              let snapshot = ProjectWidgetSnapshotStore.load(bundleIdentifier: Bundle.main.bundleIdentifier) else {
            return WonderProjectWidgetEntry(date: date, project: nil, savedAt: nil,
                                            identity: nil, emptyReason: configuration.project == nil ?
                                                .chooseProject : .snapshotUnavailable)
        }
        let selectedID = configuration.project?.id
        let project = snapshot.projects.first { $0.selectionID == selectedID }
        return WonderProjectWidgetEntry(date: date, project: project, savedAt: snapshot.savedAt,
                                        identity: identity, emptyReason: selectedID == nil ? .chooseProject :
                                            project == nil ? .projectUnavailable : nil)
    }
}

struct WonderProjectWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WonderProjectWidgetEntry

    var body: some View {
        Group {
            if let project = entry.project, let identity = entry.identity {
                Group {
                    switch family {
                    case .systemSmall: small(project, identity: identity)
                    case .systemLarge: expanded(project, identity: identity, chatLimit: 3)
                    case .systemExtraLarge: expanded(project, identity: identity, chatLimit: 3)
                    default: expanded(project, identity: identity, chatLimit: 1)
                    }
                }
                .privacySensitive()
            } else {
                emptyState
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func small(_ project: ProjectWidgetSnapshot.Project, identity: ProjectWidgetIdentity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.tint)
            Spacer(minLength: 0)
            Text(project.name).font(.headline).lineLimit(2).privacySensitive()
            Text("New chat").font(.subheadline).foregroundStyle(.secondary)
            savedLabel.font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
        .widgetURL(ProjectWidgetLink.newChat(hostID: project.hostID, projectID: project.id, identity: identity))
        .accessibilityLabel("\(project.name), new chat. \(savedAccessibility)")
    }

    private func expanded(_ project: ProjectWidgetSnapshot.Project, identity: ProjectWidgetIdentity,
                          chatLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.headline).lineLimit(1).privacySensitive()
                    savedLabel.font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let url = ProjectWidgetLink.newChat(hostID: project.hostID, projectID: project.id,
                                                      identity: identity) {
                    Link(destination: url) {
                        Label("New chat", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("New chat in selected Project")
                }
            }
            if project.recentChats.isEmpty {
                Text("Open Wonder to see recent chats.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(project.recentChats.prefix(chatLimit)) { chat in
                    if let url = ProjectWidgetLink.chat(hostID: project.hostID, chatID: chat.id,
                                                        identity: identity) {
                        Link(destination: url) {
                            Label(chat.title, systemImage: "bubble.left")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                                .privacySensitive()
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if entry.isStale {
                Text("Open Wonder to refresh saved links")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "square.stack.3d.up").foregroundStyle(.tint)
            Text("Wonder Projects").font(.headline)
            Text(emptyMessage)
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
    }

    private var emptyMessage: String {
        switch entry.emptyReason {
        case .snapshotUnavailable: "Saved links unavailable. Open Wonder to refresh."
        case .projectUnavailable: "Project unavailable. Choose another Project in widget settings."
        default: "Choose a Project in widget settings."
        }
    }

    private var savedLabel: Text {
        guard let savedAt = entry.savedAt else { return Text("No saved links") }
        if savedAt.timeIntervalSince(entry.date) > 5 * 60 { return Text("Saved links need refresh") }
        let prefix = entry.isStale ? "Last saved" : "Saved"
        return Text("\(prefix) \(savedAt.formatted(date: .abbreviated, time: .shortened))")
    }

    private var savedAccessibility: String {
        guard let savedAt = entry.savedAt else { return "No saved links" }
        if savedAt.timeIntervalSince(entry.date) > 5 * 60 { return "Saved links need refresh" }
        return "\(entry.isStale ? "Last saved" : "Saved") \(savedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct WonderProjectWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: ProjectWidgetSnapshot.widgetKind, intent: WonderProjectWidgetConfiguration.self,
                               provider: WonderProjectWidgetProvider()) { entry in
            WonderProjectWidgetView(entry: entry)
        }
        .configurationDisplayName("Project")
        .description("Open a recent Project chat or start a new one.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main struct WonderProjectWidgetBundle: WidgetBundle {
    var body: some Widget { WonderProjectWidget() }
}
