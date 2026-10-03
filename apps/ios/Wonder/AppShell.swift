import SwiftUI
import Combine
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
    var exactProject = false
}

/// Widget and external links carry only bounded, nonsecret addresses. The
/// channel-specific scheme is registered in BuildInfo.plist.
enum WonderDeepLink: Equatable {
    case chat(host: String, id: String)
    case newProjectChat(host: String, project: String)

    static func parse(_ url: URL, scheme: String) -> Self? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              url.absoluteString.utf8.count <= 512,
              parts.scheme == scheme, parts.host == "v1", parts.user == nil,
              parts.password == nil, parts.port == nil, parts.query == nil,
              parts.fragment == nil else { return nil }
        let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (path.count == 5 || path.count == 6), path[0].isEmpty,
              path[1] == "hosts", validID(path[2]), validID(path[4]) else { return nil }
        if path.count == 5, path[3] == "chats" { return .chat(host: path[2], id: path[4]) }
        if path.count == 6, path[3] == "projects", path[5] == "new" {
            return .newProjectChat(host: path[2], project: path[4])
        }
        return nil
    }

    var host: String {
        switch self {
        case .chat(let host, _), .newProjectChat(let host, _): host
        }
    }

    func url(scheme: String) -> URL? {
        guard !scheme.isEmpty, Self.validID(host) else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "v1"
        switch self {
        case .chat(_, let id):
            guard Self.validID(id) else { return nil }
            parts.path = "/hosts/\(host)/chats/\(id)"
        case .newProjectChat(_, let project):
            guard Self.validID(project) else { return nil }
            parts.path = "/hosts/\(host)/projects/\(project)/new"
        }
        return parts.url
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

/// Per-window navigation state. Another iPad window keeps its own selection;
/// connection transports stay owned by the shared connection models.
@MainActor final class ShellState: ObservableObject {
    @Published var route: ShellRoute = .newChat
    @Published var sidebarOpen = false
    @Published var newChatRequest: NewChatRequest?
    /// Settings is pushed onto the main navigation stack.
    @Published var settingsOpen = false
    /// The Mac the new-chat draft is addressed to, reported by the draft view.
    @Published var draftHost: String?
    @Published var linkedConversation: ShellRoute?

    func open(host: String, conversation: String, fromLink: Bool = false) {
        route = .conversation(host: host, id: conversation)
        linkedConversation = fromLink ? route : nil
        sidebarOpen = false
        settingsOpen = false
    }
    /// A fresh draft; in a project the draft stays in that project.
    func newChat(host: String? = nil, destination: ChatDestination? = nil, exactProject: Bool = false) {
        newChatRequest = NewChatRequest(host: host, destination: destination, exactProject: exactProject)
        route = .newChat
        linkedConversation = nil
        sidebarOpen = false
        settingsOpen = false
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
    @Environment(\.scenePhase) private var phase
    @State private var showWideSidebar = true
    @State private var choosingProjectsHost: String?
    /// First launch has no Mac to show, so pairing comes first as a sheet.
    @State private var pairing = false
    @State private var linkIssue: String?

    var body: some View {
        Group {
            // Keep the presentation owner stable when an iPhone rotates. A
            // size-class switch used to replace this branch and dismiss the
            // full-screen computer viewer with it.
            if UIDevice.current.userInterfaceIdiom == .pad {
                GeometryReader { window in
                    let compact = window.size.width < 760
                    let sidebarWidth = compact ? min(window.size.width * 0.85, 420)
                        : min(380, max(280, window.size.width * 0.31))
                    let sidebarVisible = compact ? shell.sidebarOpen : showWideSidebar
                    HStack(spacing: 0) {
                        Color.clear.frame(width: !compact && showWideSidebar ? sidebarWidth + 1 : 0)
                            .accessibilityHidden(true)
                        VStack(spacing: 0) {
                            if compact {
                                // iPad window controls overlay the upper leading
                                // corner instead of contributing to safe area.
                                Color.clear.frame(height: 52).accessibilityHidden(true)
                            }
                            NavigationStack {
                                ShellMain(library: library, shell: shell,
                                          compactIPadWindow: compact,
                                          showSidebarButton: true,
                                          sidebarButtonLabel: compact || !showWideSidebar ? "Show Chats" : "Hide Chats") {
                                    if compact { shell.sidebarOpen = true }
                                    else { showWideSidebar.toggle() }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .overlay(alignment: .leading) {
                        Button { shell.sidebarOpen = false } label: {
                            Color.black.opacity(compact && shell.sidebarOpen ? 0.35 : 0)
                                .ignoresSafeArea()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close Chats")
                        .accessibilityIdentifier("ipad-sidebar-scrim")
                        .allowsHitTesting(compact && shell.sidebarOpen)
                        .accessibilityHidden(!compact || !shell.sidebarOpen)
                    }
                    .overlay(alignment: .leading) {
                        VStack(spacing: 0) {
                            if compact { Color.clear.frame(height: 52).accessibilityHidden(true) }
                            SidebarView(library: library, shell: shell)
                        }
                        .frame(width: sidebarWidth)
                        .background(Color(uiColor: .systemBackground))
                        .overlay(alignment: .trailing) {
                            if !compact && showWideSidebar { Divider() }
                        }
                        .offset(x: sidebarVisible ? 0 : -sidebarWidth)
                        .allowsHitTesting(sidebarVisible)
                        .accessibilityHidden(!sidebarVisible)
                    }
                    .onChange(of: compact) { _, isCompact in
                        if !isCompact { shell.sidebarOpen = false }
                    }
                }
            } else {
                PhoneDrawerLayout(library: library, shell: shell)
            }
        }
        .sheet(isPresented: $pairing) { ConnectionsView(library: library, isSheet: true) }
        .alert("Couldn’t open link", isPresented: Binding(get: { linkIssue != nil }, set: { if !$0 { linkIssue = nil } })) {
            Button("OK", role: .cancel) { linkIssue = nil }
        } message: { Text(linkIssue ?? "") }
        .sheet(item: Binding(get: { choosingProjectsHost.map(HostSheet.init) }, set: { choosingProjectsHost = $0?.id })) { sheet in
            if let model = model(sheet.id) { ChooseProjectsView(model: model, library: model.projects) }
        }
        .onChange(of: push.destination, initial: true) { _, value in
            guard let value else { return }
            shell.open(host: value.host, conversation: value.conversation)
        }
        .onOpenURL { openLink($0) }
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
            #if WONDER_DIAGNOSTICS
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-diagnostics-deep-link"), arguments.indices.contains(index + 1),
               let url = URL(string: arguments[index + 1]) { openLink(url) }
            #endif
            #if DEBUG || WONDER_DIAGNOSTICS
            if ProcessInfo.processInfo.arguments.contains("-show-connections") { pairing = true }
            #endif
        }
        .task(id: library.saved.connections.isEmpty) {
            if library.loaded, library.saved.connections.isEmpty, !library.isPreview { pairing = true }
        }
        #if WONDER_DIAGNOSTICS
        .task {
            // The layout fixture opens its synthetic conversation as a notification would.
            if DiagnosticSubagentFixture.chatLayoutFixture && !DiagnosticSubagentFixture.projectReadFixture {
                shell.open(host: DiagnosticSubagentFixture.hostID, conversation: DiagnosticSubagentFixture.parentID)
            }
        }
        #endif
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
    private func model(_ host: String) -> ConnectionModel? {
        library.saved.connections.first { $0.credential.hostInstallationId == host }.map { library.model(for: $0) }
    }

    private func openLink(_ url: URL) {
        // Keychain loading can complete after the URL arrives on a cold launch.
        library.load()
        guard library.loaded else {
            linkIssue = "Saved computers are unavailable. Unlock your device and try again."
            return
        }
        let scheme = Bundle.main.object(forInfoDictionaryKey: "WonderDeepLinkScheme") as? String ?? ""
        guard let target = WonderDeepLink.parse(url, scheme: scheme) else {
            linkIssue = "This link is invalid or belongs to another Wonder app. Ask for a new link."
            return
        }
        guard let linkedModel = model(target.host) else {
            linkIssue = "The linked computer is not paired on this device. Pair that computer to open it."
            return
        }
        #if WONDER_DIAGNOSTICS
        if library.isPreview && ProcessInfo.processInfo.arguments.contains("-diagnostics-deep-link-offline") {
            linkedModel.macConnected = false
        }
        #endif
        switch target {
        case .chat(let host, let id): shell.open(host: host, conversation: id, fromLink: true)
        case .newProjectChat(let host, let project):
            shell.newChat(host: host, destination: .project(id: project), exactProject: true)
        }
        linkIssue = nil
    }
}

private struct HostSheet: Identifiable { let id: String }

/// The iPhone layout: a compact drawer or a regular-width sidebar beside the
/// conversation. The navigation stack remains mounted as the size class changes.
/// Drag state lives here, so only the drawer's offset and dimming change per frame.
private struct PhoneDrawerLayout: View {
    @ObservedObject var library: ConnectionLibrary
    @ObservedObject var shell: ShellState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The finger's horizontal travel while a drag opens or closes the drawer.
    @State private var drag: CGFloat = 0
    @State private var dragEngaged = false
    /// The drawer width of the last drag, for a settle that has no gesture geometry.
    @State private var dragWidth: CGFloat = 0
    /// True while a finger is down, so a cancelled drag still settles.
    @GestureState private var touching = false

    private static let edgeWidth: CGFloat = 20
    private static let navigationBarHeight: CGFloat = 44
    private static let commitFraction: CGFloat = 0.4
    private static let commitVelocity: CGFloat = 500
    private var animation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.22) }

    var body: some View {
        GeometryReader { geometry in
            let wide = horizontalSizeClass == .regular
            let width = wide ? min(380, max(240, geometry.size.width * 0.31))
                : min(geometry.size.width * 0.85, 420)
            let drawerOpen = !wide && shell.sidebarOpen
            let offset = wide ? 0 : min(0, max(-width, (drawerOpen ? 0 : -width) + drag))
            let progress = !wide && width > 0 ? 1 + offset / width : 0
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: wide ? width + 1 : 0)
                        .accessibilityHidden(true)
                    NavigationStack {
                        ShellMain(library: library, shell: shell, compactIPadWindow: false,
                                  showSidebarButton: !wide, sidebarButtonLabel: "Open sidebar") {
                            shell.sidebarOpen = true
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                    .accessibilityHidden(drawerOpen)
                    .allowsHitTesting(!drawerOpen)
                    .overlay(alignment: .leading) {
                        // Only the leading edge below the navigation bar opens the drawer, so
                        // horizontal scrolling in the conversation and the header buttons keep working.
                        if !wide && !drawerOpen && !shell.settingsOpen {
                            Color.clear.frame(width: Self.edgeWidth).contentShape(Rectangle())
                                .padding(.top, Self.navigationBarHeight)
                                .gesture(openGesture(width: width))
                                .accessibilityHidden(true)
                        }
                    }
                // Background controls are inert while the drawer is open.
                Color.black.opacity(0.4 * progress).ignoresSafeArea()
                    .onTapGesture { close() }
                    .simultaneousGesture(closeGesture(width: width))
                    .allowsHitTesting(drawerOpen)
                    .accessibilityHidden(!drawerOpen)
                    .accessibilityLabel("Close sidebar")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("sidebar-scrim")
                SidebarView(library: library, shell: shell)
                    .frame(width: width)
                    .background(Color(uiColor: .systemBackground))
                    // A horizontal dismissal must cancel a pressed row rather than open it.
                    .disabled(dragEngaged)
                    .accessibilityElement(children: .contain)
                    .accessibilityAction(.escape) { close() }
                    .offset(x: offset)
                    .allowsHitTesting(wide || drawerOpen)
                    .accessibilityHidden(!wide && !drawerOpen)
                    .simultaneousGesture(closeGesture(width: width, enabled: !wide))
                    .zIndex(1)
            }
            .animation(animation, value: shell.sidebarOpen)
            .onChange(of: wide) { _, isWide in
                drag = 0
                dragEngaged = false
                if isWide { shell.sidebarOpen = false }
            }
        }
        .onChange(of: shell.sidebarOpen) { _, open in
            if open {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .onChange(of: touching) { _, isTouching in
            // A system-cancelled drag delivers no end; put the drawer where it belongs.
            if !isTouching, dragEngaged { settle(width: dragWidth, translation: drag, velocity: 0) }
        }
    }

    private func close() {
        withAnimation(animation) { shell.sidebarOpen = false; drag = 0 }
    }

    private func openGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                guard !shell.sidebarOpen else { return }
                let travel = value.translation
                if dragEngaged || abs(travel.width) > abs(travel.height) {
                    dragEngaged = true; dragWidth = width
                    drag = max(0, min(travel.width, width))
                }
            }
            .onEnded { value in settle(width: width, translation: value.translation.width, velocity: value.velocity.width) }
    }

    private func closeGesture(width: CGFloat, enabled: Bool = true) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                guard enabled, shell.sidebarOpen else { return }
                let travel = value.translation
                if dragEngaged || (travel.width < 0 && abs(travel.width) > abs(travel.height) * 1.5) {
                    dragEngaged = true; dragWidth = width
                    drag = max(-width, min(0, travel.width))
                }
            }
            .onEnded { value in settle(width: width, translation: value.translation.width, velocity: value.velocity.width) }
    }

    /// Commits on a quick flick or once the drawer moved past 40% of its travel.
    private func settle(width: CGFloat, translation: CGFloat, velocity: CGFloat) {
        guard dragEngaged else { return }
        dragEngaged = false
        let wasOpen = shell.sidebarOpen
        let open: Bool
        if velocity > Self.commitVelocity { open = true }
        else if velocity < -Self.commitVelocity { open = false }
        else if wasOpen { open = -translation <= width * Self.commitFraction }
        else { open = translation > width * Self.commitFraction }
        withAnimation(animation) { drag = 0; shell.sidebarOpen = open }
    }
}

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
                // After renewal: a composer that loaded before it may have no models.
                await model.projects.loadOptions()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    await model.loadChats(force: true)
                    guard !Task.isCancelled else { return }
                    await model.projects.refresh()
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
    let compactIPadWindow: Bool
    let showSidebarButton: Bool
    let sidebarButtonLabel: String
    let sidebarAction: () -> Void
    @AccessibilityFocusState private var sidebarButtonFocused: Bool
    @AccessibilityFocusState private var compactChatsFocused: Bool
    @State private var creatingProjectHost: String?
    private var onNewChat: Bool { shell.route == .newChat }
    /// The Mac a new project belongs to: the one the draft is addressed to.
    private var draftHostID: String? {
        let connections = library.saved.connections
        let chosen = connections.first { $0.credential.hostInstallationId == shell.draftHost }
            ?? (connections.count == 1 ? connections.first : connections.first { library.model(for: $0).macConnected == true })
        return chosen?.credential.hostInstallationId
    }
    var body: some View {
        Group {
            switch shell.route {
            case .newChat:
                NewChatView(library: library, shell: shell)
            case .conversation(let host, let id):
                if let saved = library.saved.connections.first(where: { $0.credential.hostInstallationId == host }) {
                    let model = library.model(for: saved)
                    ShellConversation(model: model, projects: model.projects, chatID: id,
                                      fromLink: shell.linkedConversation == shell.route) { shell.route = .newChat }
                        .id(shell.route)
                } else {
                    ContentUnavailableView("Chat unavailable", systemImage: "bubble.left",
                                           description: Text("This computer is no longer paired. Pair it again in Settings."))
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if compactIPadWindow {
                HStack {
                    Button("Chats", systemImage: "line.3.horizontal") { shell.sidebarOpen = true }
                        .accessibilityIdentifier("compact-ipad-chats")
                        .accessibilityFocused($compactChatsFocused)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Color(uiColor: .systemBackground))
            }
        }
        .toolbar {
            if !compactIPadWindow && showSidebarButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: sidebarAction) { Image(systemName: "line.3.horizontal") }
                        .accessibilityLabel(sidebarButtonLabel)
                        .accessibilityIdentifier("open-sidebar")
                        .accessibilityFocused($sidebarButtonFocused)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { plus() } label: { Image(systemName: onNewChat ? "folder.badge.plus" : "plus") }
                    .accessibilityLabel(onNewChat ? "New project" : "New chat")
                    .accessibilityIdentifier(onNewChat ? "new-project" : "new-chat")
                    .disabled(shell.sidebarOpen || (onNewChat && draftHostID == nil))
            }
        }
        .navigationDestination(isPresented: $shell.settingsOpen) { ConnectionsView(library: library) }
        .sheet(item: Binding(get: { creatingProjectHost.map(HostSheet.init) }, set: { creatingProjectHost = $0?.id })) { sheet in
            if let saved = library.saved.connections.first(where: { $0.credential.hostInstallationId == sheet.id }) {
                let model = library.model(for: saved)
                ProjectEditorView(model: model, library: model.projects, project: nil) { created in
                    shell.newChat(host: sheet.id, destination: .project(id: created.id))
                }
            }
        }
        .onChange(of: shell.sidebarOpen) { _, open in
            guard !open, !shell.settingsOpen else { return }
            if compactIPadWindow { compactChatsFocused = true }
            else if showSidebarButton { sidebarButtonFocused = true }
        }
    }
    private func plus() {
        if onNewChat {
            // On the new-chat screen the destination is the project, so "+" adds one.
            creatingProjectHost = draftHostID
        } else if let selected = shell.selectedConversation,
                  let saved = library.saved.connections.first(where: { $0.credential.hostInstallationId == selected.host }),
                  let detail = library.model(for: saved).projects.details[selected.id] {
            // In a project thread, the new draft stays in that project.
            shell.newChat(host: selected.host, destination: .project(id: detail.projectId))
        } else {
            shell.newChat(host: shell.selectedConversation?.host)
        }
    }
}

/// Resolves an address to a project thread on its Mac, or a Bot chat opened
/// from a notification. A thread with saved detail renders at once; the
/// detail refreshes behind it.
private struct ShellConversation: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var projects: ProjectLibrary
    let chatID: String
    let fromLink: Bool
    var onArchived: () -> Void
    @State private var resolving = false
    @State private var unavailable = false
    @State private var archived = false
    @State private var loadFailed = false
    var body: some View {
        Group {
            if !archived, !model.accessEnded, !projects.unavailable.contains(chatID),
               let detail = projects.details[chatID] {
                ConversationView(model: model, chat: model.projectChat(detail))
            } else if archived {
                ContentUnavailableView("Chat archived", systemImage: "archivebox",
                                       description: Text("This chat has been archived on \(model.macName)."))
            } else if unavailable || model.accessEnded || projects.unavailable.contains(chatID) {
                ContentUnavailableView("Chat unavailable", systemImage: "bubble.left",
                                       description: Text(model.accessEnded ? "Pair this computer again in Settings." : "This chat is no longer on \(model.macName)."))
            } else if let chat = model.chats.first(where: { $0.id == chatID }) {
                ConversationView(model: model, chat: chat)
            } else if model.macConnected != true {
                ContentUnavailableView {
                    Label("Computer offline", systemImage: "wifi.slash")
                } description: {
                    Text("Connect to \(model.macName) to open this chat.")
                } actions: {
                    Button("Try again") { Task { await model.check(renew: true); await resolve() } }
                }
            } else if loadFailed {
                ContentUnavailableView {
                    Label("Couldn’t load chat", systemImage: "exclamationmark.arrow.circlepath")
                } description: {
                    Text("Check the connection to \(model.macName) and try again.")
                } actions: {
                    Button("Try again") { Task { await resolve() } }
                }
            } else {
                ProgressView("Loading chat…").accessibilityIdentifier("conversation-loading")
            }
        }
        .task(id: chatID + ":" + String(model.macConnected == true)) { await resolve() }
        .onChange(of: projects.details[chatID]?.isArchived) { _, archived in
            if archived == true { onArchived() }
        }
    }

    private func resolve() async {
        if projects.details[chatID] != nil {
            if fromLink, projects.details[chatID]?.isArchived == true { archived = true; return }
            projects.noteOpened(chatID)
            guard model.macConnected == true else { return }
            await projects.refreshDetail(chatID)
            if !Task.isCancelled, projects.details[chatID]?.isArchived == true {
                if fromLink { archived = true } else { onArchived() }
            }
            return
        }
        // A notification or restored route can arrive before anything is saved.
        guard model.macConnected == true, !resolving, !model.chats.contains(where: { $0.id == chatID }) else { return }
        resolving = true
        defer { resolving = false }
        loadFailed = false
        do {
            let detail = try await projects.loadDetail(chatID)
            guard !Task.isCancelled else { return }
            if detail.isArchived == true {
                if fromLink { archived = true } else { onArchived() }
                return
            }
            projects.noteOpened(chatID)
            return
        } catch PairingFailure.response(404) {
        } catch {
            if !Task.isCancelled { loadFailed = true }
            return
        }
        await model.loadChats(force: true)
        guard !Task.isCancelled, model.macConnected == true else { return }
        guard !model.chats.contains(where: { $0.id == chatID }) else { return }
        unavailable = true
    }
}

// MARK: - Sidebar presentation

/// Prepares the whole sidebar as one flat row list whenever an input or a Mac's
/// catalog changes, so the view only renders rows. Change notifications from the
/// Macs are coalesced to one rebuild per main-actor turn and unchanged results
/// are not published.
@MainActor private final class SidebarPresenter: ObservableObject {
    struct Inputs: Equatable {
        var models: [ObjectIdentifier]
        /// Empty shows every Mac; otherwise the single selected Mac.
        var visibleHosts: Set<String>
        var search: String
        var expanded: Set<String>
        var collapsedHosts: Set<String>
        var selection: ShellRoute
        var expansionInitialized: Bool
    }
    struct Source {
        let hostID: String
        let model: ConnectionModel
    }
    struct Pill: Identifiable, Equatable {
        let id: String
        let name: String
        let isOnline: Bool
    }

    @Published private(set) var rows: [SidebarRow] = []
    @Published private(set) var pills: [Pill] = []
    @Published private(set) var hasResults = false
    /// First run: the project to open so the sidebar is not a list of closed folders.
    @Published private(set) var expansionSuggestion: String?
    private var inputs: Inputs?
    private var sources: [Source] = []
    private var subscriptions: [AnyCancellable] = []
    private var rebuildScheduled = false

    func configure(_ inputs: Inputs, sources: [Source]) {
        let rebind = self.inputs?.models != inputs.models
        self.inputs = inputs
        self.sources = sources
        if rebind { subscribe() }
        rebuild()
    }

    private func subscribe() {
        subscriptions = sources.flatMap { source -> [AnyCancellable] in
            let model = source.model
            let changes: [AnyPublisher<Void, Never>] = [
                model.projects.objectWillChange.map { _ in }.eraseToAnyPublisher(),
                model.$macConnected.dropFirst().map { _ in }.eraseToAnyPublisher(),
                model.$accessEnded.dropFirst().map { _ in }.eraseToAnyPublisher(),
                model.$connection.dropFirst().map { _ in }.eraseToAnyPublisher(),
            ]
            return changes.map { $0.sink { [weak self] in self?.scheduleRebuild() } }
        }
    }

    /// The observed change has not been applied yet when it is announced.
    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        Task { @MainActor [weak self] in
            self?.rebuildScheduled = false
            self?.rebuild()
        }
    }

    private func rebuild() {
        guard let inputs else { return }
        let visible = sources.filter { inputs.visibleHosts.isEmpty || inputs.visibleHosts.contains($0.hostID) }
        let hosts = visible.map { source -> SidebarHostProjects in
            let model = source.model, catalog = model.projects
            return SidebarHostProjects(hostID: source.hostID, name: model.macName, isOnline: model.macConnected == true && !model.accessEnded,
                                       supportsProjects: catalog.supportsProjects, projects: catalog.projects, threads: catalog.threads,
                                       pinned: catalog.pinned,
                                       notice: model.accessEnded ? .pairAgain : (model.macConnected == false ? .offline : nil))
        }
        var selectedHost: String?, selectedConversation: String?
        if case .conversation(let host, let id) = inputs.selection { selectedHost = host; selectedConversation = id }
        let next = SidebarProjection.rows(hosts: hosts, expanded: inputs.expanded, collapsedHosts: inputs.collapsedHosts,
                                          selectedHost: selectedHost, selectedConversation: selectedConversation, search: inputs.search)
        if next != rows { rows = next }
        let results = next.contains(where: \.isResult)
        if results != hasResults { hasResults = results }
        let nextPills = sources.map { Pill(id: $0.hostID, name: $0.model.macName, isOnline: $0.model.macConnected == true && !$0.model.accessEnded) }
        if nextPills != pills { pills = nextPills }
        let suggestion = inputs.expansionInitialized ? nil : firstRunExpansion(visible)
        if suggestion != expansionSuggestion { expansionSuggestion = suggestion }
        loadExpandedThreads(visible, inputs)
    }

    private func firstRunExpansion(_ visible: [Source]) -> String? {
        for source in visible {
            let included = source.model.projects.projects.filter(\.isIncluded)
            let recent = included.max { ($0.lastUsedAt ?? $0.createdAt) < ($1.lastUsedAt ?? $1.createdAt) } ?? included.first
            if let recent { return SidebarProjection.expansionKey(host: source.hostID, project: recent.id) }
        }
        return nil
    }

    /// First page for each expanded project that has not been asked for. A failed
    /// load keeps its retry row instead of looping.
    private func loadExpandedThreads(_ visible: [Source], _ inputs: Inputs) {
        for source in visible where !(inputs.search.isEmpty && inputs.collapsedHosts.contains(source.hostID)) {
            let catalog = source.model.projects
            guard catalog.supportsProjects != false else { continue }
            for project in catalog.projects where project.isIncluded
                && inputs.expanded.contains(SidebarProjection.expansionKey(host: source.hostID, project: project.id)) {
                if let state = catalog.threads[project.id], state.hasLoaded || state.isLoading || state.failure != nil { continue }
                catalog.loadThreads(project.id)
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var library: ConnectionLibrary
    @ObservedObject var shell: ShellState
    @StateObject private var presenter = SidebarPresenter()
    @AccessibilityFocusState private var headingFocused: Bool
    @SceneStorage("sidebar.search") private var search = ""
    @SceneStorage("sidebar.expanded") private var expandedStorage = ""
    @SceneStorage("sidebar.collapsedHosts") private var collapsedStorage = ""
    @SceneStorage("sidebar.expansionInitialized") private var expansionInitialized = false
    /// The thread being attached or copied; its row shows a spinner.
    @State private var busyThread: String?
    @State private var failure: String?
    @State private var editing: ProjectEditTarget?
    @State private var renaming: ThreadTarget?
    @State private var renameText = ""

    private struct ProjectEditTarget: Identifiable {
        let host: String
        /// nil creates a project.
        let project: ProjectSummary?
        var id: String { host + "/" + (project?.id ?? "new") }
    }
    private struct ThreadTarget: Identifiable {
        let host: String
        let project: String
        let thread: ProjectThreadSummary
        var id: String { host + "/" + thread.reference }
    }

    private var expanded: Set<String> { Set(expandedStorage.split(separator: "\n").map(String.init)) }
    private var collapsedHosts: Set<String> { Set(collapsedStorage.split(separator: "\n").map(String.init)) }
    private func setExpanded(_ key: String, _ value: Bool) {
        var next = expanded
        if value { next.insert(key) } else { next.remove(key) }
        expandedStorage = next.sorted().joined(separator: "\n")
    }
    private func setHostCollapsed(_ host: String, _ collapsed: Bool) {
        var next = collapsedHosts
        if collapsed { next.insert(host) } else { next.remove(host) }
        collapsedStorage = next.sorted().joined(separator: "\n")
    }
    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var inputs: SidebarPresenter.Inputs {
        SidebarPresenter.Inputs(models: library.saved.connections.map { ObjectIdentifier(library.model(for: $0)) },
                                visibleHosts: library.saved.selectedHostIDs, search: search, expanded: expanded,
                                collapsedHosts: collapsedHosts, selection: shell.route, expansionInitialized: expansionInitialized)
    }
    private func model(_ host: String) -> ConnectionModel? {
        library.saved.connections.first { $0.credential.hostInstallationId == host }.map { library.model(for: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Wonder").font(.title3.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 12)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
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
            if presenter.pills.count > 1 { filterPills }
            List {
                if let error = library.error { FailureDetails("Connection problem", message: error).listRowSeparator(.hidden) }
                ForEach(presenter.rows) { row in
                    rowView(row)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                }
                if library.saved.connections.isEmpty {
                    Text("Add a computer in Settings").foregroundStyle(.secondary).listRowSeparator(.hidden)
                } else if !trimmedSearch.isEmpty && !presenter.hasResults {
                    Text("No matching chats").foregroundStyle(.secondary).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 40)
            .refreshable {
                await withTaskGroup(of: Void.self) { group in
                    for saved in library.saved.connections where library.saved.includes(saved.credential.hostInstallationId) {
                        let model = library.model(for: saved)
                        group.addTask { await model.loadChats(force: true); await model.projects.refresh() }
                    }
                }
            }
            .alert("Rename thread", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $renameText)
                Button("Rename") { if let target = renaming { rename(target) } }
                Button("Cancel", role: .cancel) {}
            }
            Button { shell.settingsOpen = true; shell.sidebarOpen = false } label: {
                Label("Settings", systemImage: "gearshape").font(.body).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            }
            .buttonStyle(.plain).padding(.horizontal, 20).padding(.bottom, 4)
            .accessibilityIdentifier("sidebar-settings")
        }
        .alert("Couldn’t complete that", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
        .sheet(item: $editing) { target in
            if let model = model(target.host) {
                ProjectEditorView(model: model, library: model.projects, project: target.project) { saved in
                    if target.project == nil { setExpanded(SidebarProjection.expansionKey(host: target.host, project: saved.id), true) }
                }
            }
        }
        .onChange(of: inputs, initial: true) {
            presenter.configure(inputs, sources: library.saved.connections.map {
                SidebarPresenter.Source(hostID: $0.credential.hostInstallationId, model: library.model(for: $0))
            })
        }
        .onChange(of: presenter.expansionSuggestion, initial: true) { _, key in
            guard let key, !expansionInitialized else { return }
            expansionInitialized = true
            setExpanded(key, true)
        }
        .onChange(of: shell.sidebarOpen) { _, open in headingFocused = open }
    }

    // MARK: Header

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill("All", isOnline: nil, selected: library.saved.selectedHostIDs.isEmpty, id: "all") { library.filter(nil) }
                ForEach(presenter.pills) { item in
                    pill(item.name, isOnline: item.isOnline, selected: library.saved.selectedHostIDs.contains(item.id), id: item.id) { library.filter(item.id) }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    private func pill(_ title: String, isOnline: Bool?, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(1)
                if let isOnline { Circle().fill(isOnline ? Color.green : Color.secondary.opacity(0.6)).frame(width: 7, height: 7).accessibilityHidden(true) }
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 12).frame(minHeight: 32)
            .background(selected ? Color.accentColor.opacity(0.16) : Color(uiColor: .secondarySystemFill), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(isOnline == nil ? title : title + (isOnline == true ? ", connected" : ", not connected"))
        .accessibilityIdentifier("computer-filter:" + id)
    }

    // MARK: Rows

    @ViewBuilder private func rowView(_ row: SidebarRow) -> some View {
        switch row {
        case .pinnedHeader:
            sectionTitle("Pinned")
        case .pinned(let host, let projectID, let projectName, let hostName, let thread, let isSelected):
            threadRow(host: host, projectID: projectID, thread: thread, isSelected: isSelected,
                      subtitle: hostName.map { projectName + " · " + $0 } ?? projectName, leading: 4, prefix: "pinned-thread:")
        case .host(let host, let name, let isOnline, let isCollapsed):
            Button { setHostCollapsed(host, !isCollapsed) } label: {
                HStack(spacing: 8) {
                    Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    Circle().fill(isOnline ? Color.green : Color.secondary.opacity(0.6)).frame(width: 8, height: 8).accessibilityHidden(true)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                }
                .padding(.horizontal, 4).frame(minHeight: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name + (isOnline ? ", connected" : ", not connected"))
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("host-header:" + host)
        case .hostNotice(_, let name, let kind):
            switch kind {
            case .pairAgain:
                Text("\(name): pair again in Settings.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            case .offline:
                Text("Can’t reach \(name). Showing saved chats.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                    .accessibilityIdentifier("computer-offline-notice")
            }
        case .project(let host, let project, let isExpanded, let isSelected):
            projectRow(host: host, project: project, isExpanded: isExpanded, isSelected: isSelected)
        case .thread(let host, let projectID, let thread, let isSelected):
            threadRow(host: host, projectID: projectID, thread: thread, isSelected: isSelected, subtitle: nil, leading: 34, prefix: "project-thread:")
        case .threadsLoading:
            ProgressView().frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 38)
        case .threadsNotice(let host, let projectID, let message, let canRetry):
            Button { if canRetry { model(host)?.projects.loadThreads(projectID) } } label: {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.leading, 38).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).disabled(!canRetry)
        case .moreThreads(let host, let projectID, let isLoading):
            Button { model(host)?.projects.loadThreads(projectID, more: true) } label: {
                HStack { Text("Show more"); if isLoading { ProgressView().controlSize(.small) } }
                    .font(.subheadline).foregroundStyle(.secondary).padding(.leading, 38).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            }.buttonStyle(.plain).disabled(isLoading)
        case .updateRequired(let host):
            Text("Update Wonder on \(model(host)?.macName ?? "your computer") to use Projects.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
        case .newProject(let host):
            Button { editing = ProjectEditTarget(host: host, project: nil) } label: {
                Label("New project", systemImage: "plus").font(.subheadline).foregroundStyle(.secondary)
                    .padding(.leading, 6).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("new-project:" + host)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 4).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func projectRow(host: String, project: ProjectSummary, isExpanded: Bool, isSelected: Bool) -> some View {
        let key = SidebarProjection.expansionKey(host: host, project: project.id)
        return HStack(spacing: 0) {
            Button { setExpanded(key, !isExpanded) } label: {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0)).frame(width: 36, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(project.name)" : "Expand \(project.name)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("project-disclosure:" + project.id)
            Button {
                setExpanded(key, true)
                shell.newChat(host: host, destination: .project(id: project.id))
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.primary)
                    Text(project.name).lineLimit(1)
                    Spacer(minLength: 4)
                    if project.isPinned { Image(systemName: "pin").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Pinned") }
                }.contentShape(Rectangle()).frame(minHeight: 40)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Starts a new chat in this project")
            .accessibilityIdentifier("project-row:" + project.id)
        }
        .listRowBackground(selectionFill(isSelected))
        .contextMenu {
            Button(project.isPinned ? "Unpin" : "Pin", systemImage: project.isPinned ? "pin.slash" : "pin") {
                Task { await update(host, project, ["isPinned": !project.isPinned]) }
            }
            Button("Edit project", systemImage: "pencil") { editing = ProjectEditTarget(host: host, project: project) }
            Button("Hide from sidebar", systemImage: "eye.slash") { Task { await update(host, project, ["isIncluded": false]) } }
        }
    }

    private func threadRow(host: String, projectID: String, thread: ProjectThreadSummary, isSelected: Bool,
                           subtitle: String?, leading: CGFloat, prefix: String) -> some View {
        Button { open(host, projectID, thread) } label: {
            HStack(spacing: 8) {
                SidebarProviderIcon(family: thread.family)
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.title).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if busyThread == thread.reference { ProgressView().controlSize(.small) }
                else if thread.isWorking { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                else if thread.hasUnread { Circle().fill(Color.primary).frame(width: 7, height: 7).accessibilityLabel("Unread") }
            }
            .padding(.leading, leading).contentShape(Rectangle()).frame(minHeight: subtitle == nil ? 40 : 46)
        }
        .buttonStyle(.plain)
        .listRowBackground(selectionFill(isSelected))
        .accessibilityLabel(thread.title)
        .accessibilityValue([thread.family.title, subtitle,
                             busyThread == thread.reference ? "Updating" : thread.isWorking ? "Working" : thread.hasUnread ? "Unread" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(prefix + thread.reference)
        .contextMenu {
            Button(thread.hasUnread ? "Mark as Read" : "Mark as Unread", systemImage: thread.hasUnread ? "envelope.open" : "envelope.badge") {
                setUnread(host, projectID, thread, !thread.hasUnread)
            }.disabled(busyThread != nil)
            Button(thread.isPinned ? "Unpin" : "Pin", systemImage: thread.isPinned ? "pin.slash" : "pin") {
                setPinned(host, projectID, thread, !thread.isPinned)
            }
            Button("Rename", systemImage: "pencil") {
                renameText = thread.title
                renaming = ThreadTarget(host: host, project: projectID, thread: thread)
            }
            Button("Copy resume command", systemImage: "terminal") { copyResumeCommand(host, projectID, thread) }
            if thread.family == .codex, !thread.reference.hasPrefix("wonder:"), model(host)?.projects.supportsArchive == true {
                Button("Archive", systemImage: "archivebox") { archive(host, projectID, thread) }
                    .disabled(busyThread != nil || thread.isWorking || model(host)?.macConnected != true)
                    .accessibilityIdentifier("archive-project-thread")
            }
        }
    }

    // MARK: Actions

    private func archive(_ host: String, _ projectID: String, _ thread: ProjectThreadSummary) {
        guard busyThread == nil, let model = model(host) else { return }
        let scope = model.assignmentScope
        busyThread = thread.reference
        Task {
            defer { busyThread = nil }
            do {
                try await model.projects.archive(projectID, thread: thread)
                guard scope == model.assignmentScope else { return }
                if shell.selectedConversation?.host == host, shell.selectedConversation?.id == thread.conversationId {
                    shell.route = .newChat
                }
            } catch is CancellationError {
            } catch {
                guard scope == model.assignmentScope else { return }
                failure = "The chat couldn’t be archived. " + managementError(error)
            }
        }
    }

    private func setUnread(_ host: String, _ projectID: String, _ thread: ProjectThreadSummary, _ unread: Bool) {
        guard busyThread == nil, let model = model(host) else { return }
        busyThread = thread.reference
        Task {
            defer { busyThread = nil }
            do {
                let conversation: String
                if let id = thread.conversationId { conversation = id }
                else { conversation = try await model.projects.attach(projectID, thread: thread) }
                try await model.projects.updateConversation(conversation, fields: ["hasUnread": unread])
            } catch is CancellationError {
            } catch {
                failure = "The read status couldn’t be saved. Check \(model.macName) and try again."
            }
        }
    }

    /// A thread with a conversation opens at once from what is saved; only a
    /// provider-only thread waits for attach.
    private func open(_ host: String, _ projectID: String, _ thread: ProjectThreadSummary) {
        guard let model = model(host) else { return }
        if let conversation = thread.conversationId {
            model.projects.noteOpened(conversation)
            shell.open(host: host, conversation: conversation)
            // Saved history opens immediately, including offline. A native
            // Codex thread can still need its desktop project repaired.
            if thread.family == .codex, !thread.reference.hasPrefix("wonder:"), model.macConnected == true {
                let scope = model.assignmentScope
                let repairFailure = "Your chat opened, but its project on your Mac couldn’t be updated. Try opening it again."
                Task {
                    do {
                        _ = try await model.projects.attach(projectID, thread: thread)
                        if scope == model.assignmentScope, model.controlErrors[conversation] == repairFailure {
                            model.controlErrors[conversation] = nil
                        }
                    }
                    catch is CancellationError {}
                    catch {
                        guard scope == model.assignmentScope, !model.accessEnded else { return }
                        model.controlErrors[conversation] = repairFailure
                    }
                }
            }
            return
        }
        guard busyThread == nil else { return }
        busyThread = thread.reference
        Task {
            defer { busyThread = nil }
            do {
                let conversation = try await model.projects.attach(projectID, thread: thread)
                model.projects.noteOpened(conversation)
                shell.open(host: host, conversation: conversation)
            } catch PairingFailure.response(404) {
                failure = "That thread is no longer on \(model.macName)."
            } catch is CancellationError {
            } catch {
                failure = "The thread couldn’t be opened. Check \(model.macName) and try again."
            }
        }
    }

    private func setPinned(_ host: String, _ projectID: String, _ thread: ProjectThreadSummary, _ value: Bool) {
        guard let model = model(host) else { return }
        Task {
            do { try await model.projects.setPinned(projectID, thread: thread, value) }
            catch is CancellationError {}
            catch { failure = "The pin couldn’t be saved. Try again." }
        }
    }

    private func rename(_ target: ThreadTarget) {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != target.thread.title, let model = model(target.host) else { return }
        Task {
            do { try await model.projects.rename(target.project, thread: target.thread, to: title) }
            catch is CancellationError {}
            catch { failure = "The new name couldn’t be saved. Try again." }
        }
    }

    private func copyResumeCommand(_ host: String, _ projectID: String, _ thread: ProjectThreadSummary) {
        guard busyThread == nil, let model = model(host) else { return }
        busyThread = thread.reference
        Task {
            defer { busyThread = nil }
            do {
                let conversation = try await model.projects.attach(projectID, thread: thread)
                let continuation = try await model.projects.continuation(conversation)
                guard let command = continuation.options.first?.command else {
                    failure = "There is no resume command for this thread yet."
                    return
                }
                UIPasteboard.general.string = command
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch PairingFailure.response(409) {
                failure = "Send the first message before continuing on your Mac."
            } catch is CancellationError {
            } catch {
                failure = "The resume command couldn’t be loaded. Check \(model.macName) and try again."
            }
        }
    }

    private func update(_ host: String, _ project: ProjectSummary, _ fields: [String: Any]) async {
        guard let model = model(host) else { return }
        do { _ = try await model.projects.update(project.id, fields: fields) }
        catch { failure = managementError(error) }
    }
}

/// A restrained fill for the one selected row; other rows stay on the sidebar.
func selectionFill(_ selected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 8)
        .fill(selected ? Color(uiColor: .tertiarySystemFill) : Color.clear)
        .padding(.horizontal, 6)
}

/// The provider's mark in place of its name.
private struct SidebarProviderIcon: View {
    let family: AgentFamily
    var body: some View {
        Image(family == .claude ? "ProviderClaude" : "ProviderCodex").resizable().scaledToFit()
            .frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(family.title)
    }
}
