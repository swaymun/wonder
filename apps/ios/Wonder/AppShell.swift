import SwiftUI
import WonderPairing

/// What the main surface shows. Every conversation address carries its Mac.
enum ShellRoute: Hashable {
    case newChat
    case conversation(host: String, id: String)
}

/// A new-chat request from the sidebar or header, applied by the draft view.
struct NewChatRequest: Equatable {
    let id = UUID()
    let host: String?
    let destination: ChatDestination?
}

/// Per-window navigation state. Another iPad window keeps its own selection;
/// connection transports stay owned by the shared connection models.
@MainActor final class ShellState: ObservableObject {
    @Published var route: ShellRoute = .newChat
    @Published var sidebarOpen = false
    @Published var newChatRequest: NewChatRequest?
    @Published var settingsOpen = false
    @Published var managingProjectsHost: String?

    func open(host: String, conversation: String) {
        route = .conversation(host: host, id: conversation)
        sidebarOpen = false
    }
    /// A fresh draft; in a project the draft stays in that project.
    func newChat(host: String? = nil, destination: ChatDestination? = nil) {
        newChatRequest = NewChatRequest(host: host, destination: destination)
        route = .newChat
        sidebarOpen = false
    }
    var selectedConversation: (host: String, id: String)? {
        if case .conversation(let host, let id) = route { return (host, id) }
        return nil
    }
}

/// Root of the signed-in app: one chat surface with a navigation tree.
struct ChatShell: View {
    @ObservedObject var library: ConnectionLibrary
    @ObservedObject private var push = PushNotifications.shared
    @StateObject private var shell = ShellState()
    @State private var sceneID = UUID()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var choosingProjectsHost: String?
    @AccessibilityFocusState private var sidebarFocused: Bool

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView(columnVisibility: $columns) {
                    SidebarView(library: library, shell: shell, isDrawer: false)
                        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
                        .toolbar(.hidden, for: .navigationBar)
                } detail: {
                    NavigationStack { ShellMain(library: library, shell: shell, showsSidebarButton: false) }
                }
            } else {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        NavigationStack { ShellMain(library: library, shell: shell, showsSidebarButton: true) }
                            .accessibilityHidden(shell.sidebarOpen)
                        if shell.sidebarOpen {
                            // Background controls are inert while the drawer is open.
                            Color.black.opacity(0.4).ignoresSafeArea()
                                .onTapGesture { closeDrawer() }
                                .accessibilityLabel("Close sidebar")
                                .accessibilityAddTraits(.isButton)
                                .transition(.opacity)
                        }
                            SidebarView(library: library, shell: shell, isDrawer: true)
                                .frame(width: min(geometry.size.width * 0.85, 420))
                                .background(Color(uiColor: .systemBackground))
                                .overlay(alignment: .trailing) { Divider() }
                                .accessibilityFocused($sidebarFocused)
                                .offset(x: shell.sidebarOpen ? 0 : -min(geometry.size.width * 0.85, 420))
                                .opacity(shell.sidebarOpen ? 1 : 0)
                                .allowsHitTesting(shell.sidebarOpen)
                                .accessibilityHidden(!shell.sidebarOpen)
                                .zIndex(1)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: shell.sidebarOpen)
        .onChange(of: shell.sidebarOpen) { _, open in
            if open {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            sidebarFocused = open
        }
        .sheet(isPresented: $shell.settingsOpen) { ConnectionsView(library: library) }
        .sheet(item: Binding(get: { shell.managingProjectsHost.map(HostSheet.init) }, set: { shell.managingProjectsHost = $0?.id })) { sheet in
            if let model = model(sheet.id) { ManageProjectsView(model: model, library: model.projects) }
        }
        .sheet(item: Binding(get: { choosingProjectsHost.map(HostSheet.init) }, set: { choosingProjectsHost = $0?.id })) { sheet in
            if let model = model(sheet.id) { ChooseProjectsView(model: model, library: model.projects) }
        }
        .onChange(of: push.destination, initial: true) { _, value in
            guard let value else { return }
            shell.open(host: value.host, conversation: value.conversation)
        }
        .onChange(of: phase, initial: true) { _, next in
            library.setScene(sceneID, active: next == .active)
            #if WONDER_DIAGNOSTICS
            Diagnostics.shared.setActive(next == .active)
            #endif
            // Another iPad window may still be in the foreground.
            push.setForeground(UIApplication.shared.applicationState != .background)
            if next == .active { push.refresh() }
        }
        .onDisappear { library.setScene(sceneID, active: false) }
        #if WONDER_DIAGNOSTICS
        .onChange(of: library.saved.connections.map { $0.credential.sessionToken }, initial: true) { _, _ in Diagnostics.shared.configure(library.saved.connections) }
        #endif
        .task {
            library.load(); PushNotifications.shared.attach(library)
            #if DEBUG || WONDER_DIAGNOSTICS
            if ProcessInfo.processInfo.arguments.contains("-show-connections") { shell.settingsOpen = true }
            #endif
        }
        .task(id: library.saved.connections.isEmpty) {
            // First launch: pairing comes before anything else.
            if library.loaded, library.saved.connections.isEmpty, !library.isPreview { shell.settingsOpen = true }
        }
        .onChange(of: library.saved.connections.map { $0.credential.deviceId }) { _, _ in PushNotifications.shared.refresh() }
        .background {
            ForEach(library.saved.connections, id: \.credential.hostInstallationId) { saved in
                let model = library.model(for: saved)
                if library.foregroundOwner == sceneID {
                    ConnectionLifecycle(model: model).id(ObjectIdentifier(model))
                }
                ProjectOnboardingObserver(model: model, library: model.projects) { choosingProjectsHost = $0 }
            }
        }
    }
    private func closeDrawer() { shell.sidebarOpen = false }
    private func model(_ host: String) -> ConnectionModel? {
        library.saved.connections.first { $0.credential.hostInstallationId == host }.map { library.model(for: $0) }
    }
}

private struct HostSheet: Identifiable { let id: String }

/// Keeps a connection's checks and project catalog fresh while the app is in
/// the foreground; one owner per connection, cancelled with the scene.
struct ConnectionLifecycle: View {
    @ObservedObject var model: ConnectionModel
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                model.imagePreviews.removeCachedImages()
            }
            .task(id: phase) {
                guard phase == .active else { return }
                await model.check(renew: true)
                guard !Task.isCancelled else { return }
                model.setForeground(true)
                await model.projects.refresh()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    await model.loadChats(force: true)
                }
            }
    }
}

/// Offers Choose projects once per Mac after it is paired and supports them.
private struct ProjectOnboardingObserver: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var library: ProjectLibrary
    let offer: (String) -> Void
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: library.supportsProjects) { _, supported in
                guard supported == true, library.projects.isEmpty, !model.previewMode,
                      let host = model.connection?.credential.hostInstallationId else { return }
                let key = "wonder.projects.offered." + Data(host.utf8).base64EncodedString()
                guard !UserDefaults.standard.bool(forKey: key) else { return }
                UserDefaults.standard.set(true, forKey: key)
                offer(host)
            }
    }
}

/// The main surface: a chat or its draft, with the shared header controls.
private struct ShellMain: View {
    @ObservedObject var library: ConnectionLibrary
    @ObservedObject var shell: ShellState
    let showsSidebarButton: Bool
    @AccessibilityFocusState private var sidebarButtonFocused: Bool
    var body: some View {
        Group {
            switch shell.route {
            case .newChat:
                NewChatView(library: library, shell: shell)
            case .conversation(let host, let id):
                if let saved = library.saved.connections.first(where: { $0.credential.hostInstallationId == host }) {
                    let model = library.model(for: saved)
                    ShellConversation(model: model, projects: model.projects, chatID: id)
                        .id(shell.route)
                } else {
                    ContentUnavailableView("Chat unavailable", systemImage: "bubble.left",
                                           description: Text("This computer is no longer paired. Pair it again in Settings."))
                }
            }
        }
        .toolbar {
            if showsSidebarButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button { shell.sidebarOpen = true } label: { Image(systemName: "line.3.horizontal") }
                        .accessibilityLabel("Open sidebar")
                        .accessibilityIdentifier("open-sidebar")
                        .accessibilityFocused($sidebarButtonFocused)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { newChat() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New chat")
                    .accessibilityIdentifier("new-chat")
                    .disabled(shell.sidebarOpen)
            }
        }
        .onChange(of: shell.sidebarOpen) { _, open in if !open { sidebarButtonFocused = true } }
    }
    private func newChat() {
        // In a project thread, the new draft stays in that project.
        if let selected = shell.selectedConversation,
           let saved = library.saved.connections.first(where: { $0.credential.hostInstallationId == selected.host }),
           let detail = library.model(for: saved).projects.details[selected.id] {
            shell.newChat(host: selected.host, destination: .project(id: detail.projectId))
        } else {
            shell.newChat(host: shell.selectedConversation?.host)
        }
    }
}

/// Resolves an address to a Bot/Group chat or a project thread on its Mac.
private struct ShellConversation: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var projects: ProjectLibrary
    let chatID: String
    @State private var resolving = false
    @State private var unavailable = false
    var body: some View {
        if !model.accessEnded, let detail = projects.details[chatID] {
            ConversationView(model: model, chat: model.projectChat(detail))
        } else if !model.accessEnded, let chat = model.chats.first(where: { $0.id == chatID }) {
            ConversationView(model: model, chat: chat)
        } else if unavailable || model.accessEnded {
            ContentUnavailableView("Chat unavailable", systemImage: "bubble.left",
                                   description: Text(model.accessEnded ? "Pair this computer again in Settings." : "This chat is no longer on \(model.macName)."))
        } else {
            ProgressView("Loading chat…").accessibilityIdentifier("conversation-loading")
                .task(id: chatID + ":" + String(model.macConnected == true)) {
                    // A notification or restored route can arrive before chats load.
                    guard model.macConnected == true, !resolving else { return }
                    resolving = true
                    defer { resolving = false }
                    if model.chats.isEmpty { await model.loadChats(force: true) }
                    guard !model.chats.contains(where: { $0.id == chatID }) else { return }
                    do { try await projects.loadDetail(chatID) }
                    catch PairingFailure.response(404) { unavailable = true }
                    catch {}
                }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var library: ConnectionLibrary
    @ObservedObject var shell: ShellState
    let isDrawer: Bool
    @StateObject private var chatActions = ChatListActions()
    @SceneStorage("sidebar.search") private var search = ""
    @SceneStorage("sidebar.allBots") private var showAllBots = false
    @SceneStorage("sidebar.expanded") private var expandedStorage = ""
    @SceneStorage("sidebar.expansionInitialized") private var expansionInitialized = false
    private var visibleComputers: [SavedConnection] {
        library.saved.connections.filter { library.saved.includes($0.credential.hostInstallationId) }
    }
    private var expanded: Set<String> {
        Set(expandedStorage.split(separator: "\n").map(String.init))
    }
    private func setExpanded(_ key: String, _ value: Bool) {
        var next = expanded
        if value { next.insert(key) } else { next.remove(key) }
        expandedStorage = next.sorted().joined(separator: "\n")
    }
    private struct BotEntry: Identifiable {
        let host: String
        let chat: ChatSummary
        let model: ConnectionModel
        var id: String { host + ":" + chat.id }
    }
    private var botEntries: (rows: [BotEntry], hasMore: Bool) {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = visibleComputers.flatMap { saved -> [BotEntry] in
            let model = library.model(for: saved)
            guard !model.accessEnded else { return [] }
            return model.chats.filter { !$0.isArchived && $0.matchesName(query) }
                .map { BotEntry(host: saved.credential.hostInstallationId, chat: $0, model: model) }
        }
        let ordered = all.sorted { lhs, rhs in
            if lhs.chat.isPinned != rhs.chat.isPinned { return lhs.chat.isPinned }
            let left = lhs.chat.lastMessageAt ?? "", right = rhs.chat.lastMessageAt ?? ""
            if left != right { return left > right }
            return lhs.id < rhs.id
        }
        if showAllBots || !query.isEmpty { return (ordered, false) }
        let pinned = ordered.filter(\.chat.isPinned), recent = ordered.filter { !$0.chat.isPinned }
        return (pinned + recent.prefix(RecentConversations.initialLimit), recent.count > RecentConversations.initialLimit)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Wonder").font(.title2.weight(.bold))
                Spacer()
                if library.saved.connections.count > 1 { computerFilter }
                if isDrawer {
                    Button { shell.sidebarOpen = false } label: { Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44) }
                        .accessibilityLabel("Close sidebar")
                        .accessibilityIdentifier("close-sidebar")
                }
            }
            .padding(.leading, 20).padding(.trailing, isDrawer ? 8 : 20).padding(.top, 8)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chats and projects", text: $search)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("sidebar-search")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12).frame(minHeight: 40)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16).padding(.vertical, 8)
            List {
                if let error = library.error { FailureDetails("Connection problem", message: error).listRowSeparator(.hidden) }
                botsSection
                ForEach(visibleComputers, id: \.credential.hostInstallationId) { saved in
                    let model = library.model(for: saved)
                    HostProjectsSection(model: model, projects: model.projects, shell: shell, search: search,
                                        showsHeader: saved.credential.hostInstallationId == visibleComputers.first?.credential.hostInstallationId,
                                        expanded: expanded, setExpanded: setExpanded,
                                        expansionInitialized: $expansionInitialized)
                }
                if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(visibleComputers, id: \.credential.hostInstallationId) { saved in
                        let model = library.model(for: saved)
                        if model.macConnected == true && !model.accessEnded {
                            Section {
                                MessageSearchResults(model: model, query: search.trimmingCharacters(in: .whitespacesAndNewlines))
                            } header: { Text(visibleComputers.count > 1 ? "Messages on \(model.macName)" : "Messages") }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 44)
            .refreshable {
                await withTaskGroup(of: Void.self) { group in
                    for saved in visibleComputers {
                        let model = library.model(for: saved)
                        group.addTask { await model.loadChats(force: true); await model.projects.refresh() }
                    }
                }
            }
            Divider().padding(.horizontal, 16)
            Button { shell.settingsOpen = true; shell.sidebarOpen = false } label: {
                Label("Settings", systemImage: "gearshape").font(.body).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            }
            .buttonStyle(.plain).padding(.horizontal, 20).padding(.bottom, 4)
            .accessibilityIdentifier("sidebar-settings")
        }
        .modifier(ChatActionDialogs(actions: chatActions))
    }

    @ViewBuilder private var botsSection: some View {
        let entries = botEntries
        Section {
            ForEach(entries.rows) { entry in
                SidebarBotRow(model: entry.model, chat: entry.chat, host: entry.host, actions: chatActions,
                              showsComputer: library.saved.connections.count > 1,
                              selected: shell.selectedConversation.map { $0.host == entry.host && $0.id == entry.chat.id } ?? false) {
                    shell.open(host: entry.host, conversation: entry.chat.id)
                }
            }
            if entries.hasMore || showAllBots {
                Button(showAllBots ? "Show less" : "Show more") { showAllBots.toggle() }
                    .foregroundStyle(.secondary).listRowSeparator(.hidden)
            }
            if entries.rows.isEmpty {
                let connecting = visibleComputers.contains { let model = library.model(for: $0); return model.macConnected == nil && !model.accessEnded }
                Text(connecting ? "Loading chats…" : visibleComputers.isEmpty ? "Add a computer in Settings" : search.isEmpty ? "No chats yet" : "No matching chats")
                    .foregroundStyle(.secondary).listRowSeparator(.hidden)
            }
            ForEach(visibleComputers, id: \.credential.hostInstallationId) { saved in
                SidebarConnectionNotice(model: library.model(for: saved))
            }
        } header: {
            Text("Bots").font(.subheadline).foregroundStyle(.secondary).textCase(nil)
        }
    }

    private var computerFilter: some View {
        Menu {
            Button { library.filter(nil) } label: {
                if library.saved.selectedHostIDs.isEmpty { Label("All computers", systemImage: "checkmark") } else { Text("All computers") }
            }
            ForEach(library.saved.connections, id: \.credential.hostInstallationId) { saved in
                let model = library.model(for: saved)
                Button { library.filter(saved.credential.hostInstallationId) } label: {
                    if library.saved.selectedHostIDs.contains(saved.credential.hostInstallationId) { Label(model.macName, systemImage: "checkmark") }
                    else { Text(model.macName) }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.title3).frame(width: 44, height: 44)
        }
        .accessibilityLabel("Filter computers")
    }
}

/// A restrained fill for the one selected row; other rows stay on the sidebar.
func selectionFill(_ selected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 10)
        .fill(selected ? Color(uiColor: .tertiarySystemFill) : Color.clear)
        .padding(.horizontal, 8)
}

private struct SidebarBotRow: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    let host: String
    @ObservedObject var actions: ChatListActions
    let showsComputer: Bool
    let selected: Bool
    let open: () -> Void
    private var bot: ManagedBot? { model.managedBots.first { $0.id == chat.botId } }
    private var status: ChatListStatus { model.chatListStatus(chat) }
    var body: some View {
        Button(action: open) { label }
            .buttonStyle(.plain)
            .listRowBackground(selectionFill(selected))
            .listRowSeparator(.hidden)
            .accessibilityLabel(chat.title + (chat.botId == nil ? ", Group Chat" : ""))
            .accessibilityValue(actions.status(chat, model: model) ?? status.accessibilityValue)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("chat-row:" + host + ":" + chat.id)
            .contextMenu {
                Button(chat.isPinned ? "Unpin" : "Pin", systemImage: chat.isPinned ? "pin.slash" : "pin") {
                    Task { await actions.setPinned(ChatListActions.Target(chat, model: model), !chat.isPinned) }
                }
                ChatContextMenu(actions: actions, model: model, chat: chat)
            }
    }
    private var label: some View {
        HStack(spacing: 12) {
            avatar
            Text(chat.title).lineLimit(1)
            Spacer(minLength: 4)
            if chat.isPinned {
                Image(systemName: "pin").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Pinned")
            }
            if showsComputer {
                Text(model.macName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            ChatStatusIndicator(status: status, action: actions.status(chat, model: model))
        }.contentShape(Rectangle())
    }
    @ViewBuilder private var avatar: some View {
        if chat.botId == nil {
            Image(systemName: "person.2").font(.system(size: 17)).frame(width: 30, height: 30)
        } else {
            ChatAvatar(name: chat.title, identity: chat.botId, hexColor: bot?.avatarColor, avatarShape: bot?.avatarShape,
                       avatarPalette: bot?.avatarPalette, isLoaded: bot != nil, size: 30)
        }
    }
}

private struct SidebarConnectionNotice: View {
    @ObservedObject var model: ConnectionModel
    var body: some View {
        if model.accessEnded {
            Text("\(model.macName): pair again in Settings.").font(.caption).foregroundStyle(.secondary).listRowSeparator(.hidden)
        } else if model.macConnected == false {
            Text("Can’t reach \(model.macName). Showing saved chats.").font(.caption).foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("computer-offline-notice")
        }
    }
}

/// One Mac's projects as flat rows: folders, indented threads and paging.
private struct HostProjectsSection: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var projects: ProjectLibrary
    @ObservedObject var shell: ShellState
    let search: String
    let showsHeader: Bool
    let expanded: Set<String>
    let setExpanded: (String, Bool) -> Void
    @Binding var expansionInitialized: Bool
    @State private var opening: String?
    @State private var failure: String?
    @State private var editing: ProjectSummary?
    @State private var rows: [SidebarRow] = []
    private var host: String { model.connection?.credential.hostInstallationId ?? "" }
    private func prepareRows() {
        rows = SidebarProjection.projectRows(
            hosts: [SidebarHostProjects(hostID: host, name: model.macName, isOnline: model.macConnected == true,
                                        supportsProjects: projects.supportsProjects, projects: projects.projects, threads: projects.threads)],
            expanded: expanded,
            selectedConversation: shell.selectedConversation.flatMap { $0.host == host ? $0.id : nil },
            selectedProject: nil,
            search: search)
    }
    var body: some View {
        Section {
            HStack(spacing: 8) {
                Circle().fill(model.macConnected == true && !model.accessEnded ? Color.green : Color.secondary.opacity(0.6)).frame(width: 8, height: 8)
                Text(model.macName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .listRowSeparator(.hidden)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.macName + (model.macConnected == true ? ", connected" : ", not connected"))
            ForEach(rows) { row in
                rowView(row)
                    .listRowSeparator(.hidden)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.secondary).listRowSeparator(.hidden) }
            if projects.supportsProjects != false && search.isEmpty {
                Button { shell.managingProjectsHost = host; shell.sidebarOpen = false } label: {
                    Label("Manage projects", systemImage: "slider.horizontal.3").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).listRowSeparator(.hidden)
                .accessibilityIdentifier("manage-projects:" + host)
            }
        } header: {
            if showsHeader { Text("Projects").font(.subheadline).foregroundStyle(.secondary).textCase(nil) }
        }
        .task(id: projects.projects.map(\.id)) { initializeExpansion() }
        .onChange(of: host, initial: true) { prepareRows() }
        .onChange(of: projects.projects) { prepareRows() }
        .onChange(of: projects.threads) { prepareRows() }
        .onChange(of: projects.supportsProjects) { prepareRows() }
        .onChange(of: model.macConnected) { prepareRows() }
        .onChange(of: shell.route) { prepareRows() }
        .onChange(of: search) { prepareRows() }
        .onChange(of: expanded) { _, keys in prepareRows(); loadExpanded(keys) }
        .onAppear { loadExpanded(expanded) }
        .sheet(item: $editing) { project in ProjectEditorView(model: model, library: projects, project: project) }
    }

    @ViewBuilder private func rowView(_ row: SidebarRow) -> some View {
        switch row {
        case .host:
            EmptyView()
        case .project(_, let project, let isExpanded, let isSelected):
            let key = SidebarProjection.expansionKey(host: host, project: project.id)
            HStack(spacing: 6) {
                Button { setExpanded(key, !isExpanded) } label: {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0)).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse \(project.name)" : "Expand \(project.name)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("project-disclosure:" + project.id)
                Button {
                    setExpanded(key, true)
                    shell.newChat(host: host, destination: .project(id: project.id))
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(.primary)
                        Text(project.name).lineLimit(1)
                        Spacer(minLength: 4)
                        if project.isPinned { Image(systemName: "pin").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Pinned") }
                    }.contentShape(Rectangle()).frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Starts a new chat in this project")
                .accessibilityIdentifier("project-row:" + project.id)
            }
            .listRowBackground(selectionFill(isSelected))
            .contextMenu {
                Button(project.isPinned ? "Unpin" : "Pin", systemImage: project.isPinned ? "pin.slash" : "pin") {
                    Task { await update(project, ["isPinned": !project.isPinned]) }
                }
                Button("Edit project", systemImage: "pencil") { editing = project }
                Button("Hide from sidebar", systemImage: "eye.slash") { Task { await update(project, ["isIncluded": false]) } }
            }
        case .thread(_, let projectID, let thread, let isSelected):
            Button { Task { await open(projectID, thread) } } label: {
                HStack(spacing: 8) {
                    Text(thread.title).lineLimit(1)
                    Spacer(minLength: 4)
                    if opening == thread.reference { ProgressView().controlSize(.small) }
                    else if thread.isWorking { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                    else if thread.hasUnread { Circle().fill(Color.primary).frame(width: 7, height: 7).accessibilityLabel("Unread") }
                    if thread.isPinned { Image(systemName: "pin").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Pinned") }
                    Text(thread.family.title).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 38).contentShape(Rectangle()).frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .listRowBackground(selectionFill(isSelected))
            .accessibilityLabel("\(thread.title), \(thread.family.title)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("project-thread:" + thread.reference)
            .contextMenu {
                Button(thread.isPinned ? "Unpin" : "Pin", systemImage: thread.isPinned ? "pin.slash" : "pin") {
                    Task { await pin(projectID, thread, !thread.isPinned) }
                }
            }
        case .threadsLoading:
            ProgressView().frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 38)
        case .threadsNotice(_, let projectID, let message, let canRetry):
            Button { if canRetry { projects.loadThreads(projectID) } } label: {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.leading, 38).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).disabled(!canRetry)
        case .moreThreads(_, let projectID, let isLoading):
            Button { projects.loadThreads(projectID, more: true) } label: {
                HStack { Text("Show more"); if isLoading { ProgressView().controlSize(.small) } }
                    .foregroundStyle(.secondary).padding(.leading, 38).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain).disabled(isLoading)
        case .updateRequired:
            Text("Update Wonder on \(model.macName) to use Projects.").font(.caption).foregroundStyle(.secondary)
        case .emptyProjects:
            Button { shell.managingProjectsHost = host; shell.sidebarOpen = false } label: {
                Text("Add a project folder").foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
    }

    private func initializeExpansion() {
        guard !expansionInitialized, !projects.projects.isEmpty else { return }
        expansionInitialized = true
        // First run: open the most recently used included project.
        let included = projects.projects.filter(\.isIncluded)
        let recent = included.max { ($0.lastUsedAt ?? $0.createdAt) < ($1.lastUsedAt ?? $1.createdAt) } ?? included.first
        if let recent { setExpanded(SidebarProjection.expansionKey(host: host, project: recent.id), true) }
    }
    private func loadExpanded(_ keys: Set<String>) {
        for project in projects.projects where keys.contains(SidebarProjection.expansionKey(host: host, project: project.id)) {
            if !(projects.threads[project.id]?.hasLoaded ?? false) { projects.loadThreads(project.id) }
        }
    }
    private func open(_ projectID: String, _ thread: ProjectThreadSummary) async {
        guard opening == nil else { return }
        opening = thread.reference; failure = nil
        defer { opening = nil }
        do {
            let conversation = try await projects.attach(projectID, thread: thread)
            if model.macConnected == true || projects.details[conversation] == nil { try await projects.loadDetail(conversation) }
            shell.open(host: host, conversation: conversation)
        } catch PairingFailure.response(404) {
            failure = "That thread is no longer on \(model.macName)."
        } catch {
            failure = "The thread couldn’t be opened. Check \(model.macName) and try again."
        }
    }
    private func pin(_ projectID: String, _ thread: ProjectThreadSummary, _ value: Bool) async {
        do {
            // Pinning a provider-only thread first attaches it, without work.
            let conversation = try await projects.attach(projectID, thread: thread)
            try await projects.updateConversation(conversation, fields: ["isPinned": value])
            projects.loadThreads(projectID)
        } catch { failure = "The pin couldn’t be saved. Try again." }
    }
    private func update(_ project: ProjectSummary, _ fields: [String: Any]) async {
        do { _ = try await projects.update(project.id, fields: fields) }
        catch { failure = managementError(error) }
    }
}
