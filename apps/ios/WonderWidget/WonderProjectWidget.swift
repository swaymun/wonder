import SwiftUI
import WidgetKit

/// The most recently active threads on the Mac last used for a new chat.
/// Tapping one opens that thread; Live View opens that Mac's screen. Before any
/// thread is known, recent Projects start a new chat instead.
struct WonderProjectWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: ProjectWidgetSnapshot?
    let identity: ProjectWidgetIdentity?

    var isStale: Bool { snapshot?.isStale(at: date) ?? true }
}

struct WonderProjectWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WonderProjectWidgetEntry {
        WonderProjectWidgetEntry(date: Date(), snapshot: ProjectWidgetSnapshot(hostID: "mac", hostName: "Mac", projects: [], threads: [
            .init(projectID: "one", family: "codex", nativeID: "one", conversationID: nil, title: "Thread 1", projectName: "Project"),
            .init(projectID: "one", family: "codex", nativeID: "two", conversationID: nil, title: "Thread 2", projectName: "Project"),
            .init(projectID: "one", family: "claude", nativeID: "three", conversationID: nil, title: "Thread 3", projectName: "Project"),
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

    /// Larger widgets show three recent threads (or Projects) and Live View as equal tiles.
    static let projectLimit = 3

    /// One tile: a thread to open, or a Project to start a chat in.
    private struct Destination: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: String
        let url: URL?
        let accessibility: String
    }

    private func destinations(_ snapshot: ProjectWidgetSnapshot, hostID: String,
                              identity: ProjectWidgetIdentity) -> [Destination] {
        if !snapshot.threads.isEmpty {
            return snapshot.threads.prefix(Self.projectLimit).map { thread in
                Destination(id: "thread-" + thread.id, title: thread.title, detail: thread.projectName,
                            icon: "bubble.left.and.text.bubble.right",
                            url: ProjectWidgetLink.thread(hostID: hostID, thread: thread, identity: identity),
                            accessibility: "\(thread.title), \(thread.projectName)")
            }
        }
        return snapshot.projects.prefix(Self.projectLimit).map { project in
            Destination(id: "project-" + project.id, title: project.name, detail: "New chat", icon: "plus.bubble",
                        url: ProjectWidgetLink.newChat(hostID: hostID, projectID: project.id, identity: identity),
                        accessibility: "\(project.name), new chat")
        }
    }
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
                    Text(entry.snapshot == nil ? "Your recent threads appear here." : "Pair a Mac to see its threads.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    /// One tap target: the most recent thread (or Project), or the computer.
    private func small(_ snapshot: ProjectWidgetSnapshot, hostID: String, identity: ProjectWidgetIdentity) -> some View {
        let first = destinations(snapshot, hostID: hostID, identity: identity).first
        let url = first?.url ?? ProjectWidgetLink.computer(hostID: hostID, identity: identity)
        return VStack(alignment: .leading, spacing: 6) {
            hostLabel(snapshot)
            Spacer(minLength: 0)
            if let first {
                Image(systemName: first.icon).font(.title3).foregroundStyle(.tint)
                Text(first.title).font(.headline).lineLimit(2).privacySensitive()
                Text(first.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
            } else {
                Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(.tint)
                Text("Live View").font(.headline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
        .widgetURL(url)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(first.map { "\($0.accessibility) on \(snapshot.hostName)" } ?? "Live View of \(snapshot.hostName)")
    }

    private func grid(_ snapshot: ProjectWidgetSnapshot, hostID: String, identity: ProjectWidgetIdentity) -> some View {
        let projects = destinations(snapshot, hostID: hostID, identity: identity)
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
                                destinationLink(projects[index])
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

    @ViewBuilder private func destinationLink(_ destination: Destination) -> some View {
        if let url = destination.url {
            Link(destination: url) {
                tile(icon: destination.icon, title: destination.title, private: true, detail: destination.detail)
            }
            .accessibilityLabel(destination.accessibility)
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
        .configurationDisplayName("Recent Threads")
        .description("Open the threads you worked on most recently on your Mac, or Live View of its screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main struct WonderProjectWidgetBundle: WidgetBundle {
    var body: some Widget { WonderProjectWidget() }
}
