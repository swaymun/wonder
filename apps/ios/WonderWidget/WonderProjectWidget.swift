import SwiftUI
import WidgetKit

/// Recent Projects on the Mac last used for a new chat. Tapping a Project
/// starts a new chat there; Live View opens that Mac's screen.
struct WonderProjectWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: ProjectWidgetSnapshot?
    let identity: ProjectWidgetIdentity?

    var isStale: Bool { snapshot?.isStale(at: date) ?? true }
}

struct WonderProjectWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WonderProjectWidgetEntry {
        WonderProjectWidgetEntry(date: Date(), snapshot: ProjectWidgetSnapshot(hostID: "mac", hostName: "Mac", projects: [
            .init(id: "one", name: "Project 1"), .init(id: "two", name: "Project 2"),
            .init(id: "three", name: "Project 3"), .init(id: "four", name: "Project 4"),
        ]), identity: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (WonderProjectWidgetEntry) -> Void) {
        completion(entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WonderProjectWidgetEntry>) -> Void) {
        let now = Date()
        let first = entry(at: now)
        var entries = [first]
        if let savedAt = first.snapshot?.savedAt {
            let staleAt = savedAt.addingTimeInterval(ProjectWidgetSnapshot.staleAfter)
            if staleAt > now { entries.append(entry(at: staleAt)) }
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(60 * 60))))
    }

    private func entry(at date: Date) -> WonderProjectWidgetEntry {
        WonderProjectWidgetEntry(date: date,
                                 snapshot: ProjectWidgetSnapshotStore.load(bundleIdentifier: Bundle.main.bundleIdentifier),
                                 identity: ProjectWidgetIdentity(bundleIdentifier: Bundle.main.bundleIdentifier))
    }
}

struct WonderProjectWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WonderProjectWidgetEntry

    /// Larger widgets show three recent Projects and Live View as equal tiles.
    static let projectLimit = 3
    private var columns: Int { family == .systemExtraLarge ? 4 : 2 }
    /// Large and extra-large tiles fill their space with a stacked layout.
    private var tall: Bool { family == .systemLarge || family == .systemExtraLarge }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, let hostID = snapshot.hostID, let identity = entry.identity {
                if family == .systemSmall { small(snapshot, hostID: hostID, identity: identity) }
                else { grid(snapshot, hostID: hostID, identity: identity) }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "laptopcomputer").foregroundStyle(.tint)
                    Spacer(minLength: 0)
                    Text("Open Wonder").font(.headline)
                    Text(entry.snapshot == nil ? "Your recent Projects appear here." : "Pair a Mac to see its Projects.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    /// One tap target: the most recent Project's new chat, or the computer.
    private func small(_ snapshot: ProjectWidgetSnapshot, hostID: String, identity: ProjectWidgetIdentity) -> some View {
        let project = snapshot.projects.first
        let url = project.flatMap { ProjectWidgetLink.newChat(hostID: hostID, projectID: $0.id, identity: identity) }
            ?? ProjectWidgetLink.computer(hostID: hostID, identity: identity)
        return VStack(alignment: .leading, spacing: 6) {
            hostLabel(snapshot)
            Spacer(minLength: 0)
            if let project {
                Image(systemName: "plus.bubble").font(.title3).foregroundStyle(.tint)
                Text(project.name).font(.headline).lineLimit(2).privacySensitive()
                Text("New chat").font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(.tint)
                Text("Live View").font(.headline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
        .widgetURL(url)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(project.map { "\($0.name), new chat on \(snapshot.hostName)" } ?? "Live View of \(snapshot.hostName)")
    }

    private func grid(_ snapshot: ProjectWidgetSnapshot, hostID: String, identity: ProjectWidgetIdentity) -> some View {
        let projects = Array(snapshot.projects.prefix(Self.projectLimit))
        let rows = (projects.count + 1 + columns - 1) / columns
        return VStack(alignment: .leading, spacing: 8) {
            hostLabel(snapshot)
            if projects.isEmpty {
                Text("Choose Projects in Wonder to start chats from here.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(0..<rows, id: \.self) { row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            if index < projects.count {
                                projectLink(projects[index], hostID: hostID, identity: identity)
                            } else if index == projects.count {
                                liveViewLink(snapshot, hostID: hostID, identity: identity)
                            } else {
                                Color.clear
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: tall ? .infinity : nil)
            if !tall { Spacer(minLength: 0) }
            if entry.isStale {
                Text("Open Wonder to refresh").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    @ViewBuilder private func projectLink(_ project: ProjectWidgetSnapshot.Project, hostID: String,
                                          identity: ProjectWidgetIdentity) -> some View {
        if let url = ProjectWidgetLink.newChat(hostID: hostID, projectID: project.id, identity: identity) {
            Link(destination: url) {
                tile(icon: "plus.bubble", title: project.name, private: true, detail: "New chat")
            }
            .accessibilityLabel("\(project.name), new chat")
        }
    }

    @ViewBuilder private func liveViewLink(_ snapshot: ProjectWidgetSnapshot, hostID: String,
                                           identity: ProjectWidgetIdentity) -> some View {
        if let url = ProjectWidgetLink.computer(hostID: hostID, identity: identity) {
            Link(destination: url) {
                tile(icon: "desktopcomputer", title: "Live View", private: false, detail: "See your Mac")
            }
            .accessibilityLabel("Live View of \(snapshot.hostName)")
        }
    }

    private func tile(icon: String, title: String, private isPrivate: Bool, detail: String) -> some View {
        Group {
            if tall {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: icon).font(.title3).foregroundStyle(.tint)
                    Spacer(minLength: 0)
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
                        .privacySensitive(isPrivate)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(.tint)
                    Text(title).font(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
                        .privacySensitive(isPrivate)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    private func hostLabel(_ snapshot: ProjectWidgetSnapshot) -> some View {
        Label(snapshot.hostName, systemImage: "laptopcomputer")
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            .privacySensitive()
    }
}

struct WonderProjectWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ProjectWidgetSnapshot.widgetKind, provider: WonderProjectWidgetProvider()) { entry in
            WonderProjectWidgetView(entry: entry)
        }
        .configurationDisplayName("Recent Projects")
        .description("Start a chat in a recent Project on your Mac, or open Live View of its screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main struct WonderProjectWidgetBundle: WidgetBundle {
    var body: some Widget { WonderProjectWidget() }
}
