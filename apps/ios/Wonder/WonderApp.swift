import SwiftUI
import WonderPairing
import VisionKit

@main struct WonderApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @StateObject private var library = ConnectionLibrary()
    @StateObject private var preview = ConnectionModel(saved: nil, persistConnection: { _ in })
    var body: some Scene {
        WindowGroup {
            #if WONDER_DIAGNOSTICS
            if ProcessInfo.processInfo.arguments.contains("-diagnostics-avatar-fixture") { ScienceAvatarDiagnosticFixtureView() }
            else if DiagnosticSubagentFixture.chatLayoutFixture { DiagnosticChatLayoutFixtureView() }
            else if ProcessInfo.processInfo.arguments.contains("-diagnostics-subagent-fixture") { DiagnosticSubagentFixtureView() }
            else if ProcessInfo.processInfo.arguments.contains("-diagnostics-computer-session-fixture") { ComputerSessionDiagnosticFixtureView() }
            else if ProcessInfo.processInfo.arguments.contains("-diagnostics-teaching-fixture") { TeachingDiagnosticFixtureView() }
            else if ProcessInfo.processInfo.arguments.contains("-diagnostics-fixtures") { DiagnosticFixtureView() }
            else if DiagnosticScenarioLaunch.requested { DiagnosticLaunchView(library: library) }
            else { normalRoot }
            #else
            normalRoot
            #endif
        }
    }
    @ViewBuilder private var normalRoot: some View {
            if preview.previewMode && !library.isPreview { ChatsView(model: preview) }
            else { ClientRoot(library: library) }
    }
}

struct ClientRoot: View {
    @ObservedObject var library: ConnectionLibrary
    @ObservedObject private var push = PushNotifications.shared
    @Environment(\.scenePhase) private var phase
    @State private var tab: String
    init(library: ConnectionLibrary) {
        self.library = library
        _tab = State(initialValue: library.saved.connections.isEmpty || ProcessInfo.processInfo.arguments.contains("-show-connections") ? "connections" : "chats")
    }
    var body: some View {
        TabView(selection: $tab) {
            UnifiedChatsView(library: library)
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }.tag("chats")
            ConnectionsView(library: library)
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag("connections")
        }
        .onChange(of: phase) { _, next in
                if next != .active { library.suspendAll() }
                #if WONDER_DIAGNOSTICS
                Diagnostics.shared.setActive(next == .active)
                #endif
            }
            #if WONDER_DIAGNOSTICS
            .onChange(of: library.saved.connections.map { $0.credential.sessionToken }, initial: true) { _, _ in Diagnostics.shared.configure(library.saved.connections) }
            #endif
        .task { library.load(); PushNotifications.shared.attach(library) }
        .onChange(of: phase) { _, value in
            // Another iPad window may still be in the foreground.
            push.setForeground(UIApplication.shared.applicationState != .background)
            if value == .active { push.refresh() }
        }
        .onChange(of: library.saved.connections.map { $0.credential.deviceId }) { _, _ in PushNotifications.shared.refresh() }
        .onChange(of: push.destination) { _, value in if value != nil { tab = "chats" } }
        .background {
            ForEach(library.saved.connections, id: \.credential.hostInstallationId) { saved in
                let model = library.model(for: saved)
                ConnectionLifecycle(model: model).id(ObjectIdentifier(model))
            }
        }
    }
}

private struct ConnectionLifecycle: View {
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
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    await model.loadChats(force: true)
                }
            }
            .onDisappear { model.setForeground(false) }
    }
}

private struct ComputerChatAddress: Hashable {
    let host: String
    let chat: String
}

private struct BotCreationFailure: Identifiable {
    let hostID: String
    let message: String
    var id: String { hostID }
}

private enum ChatsModal: Identifiable {
    case group(hostID: String)
    case requests(hostID: String)

    var id: String {
        switch self {
        case .group(let hostID): return "group:" + hostID
        case .requests(let hostID): return "requests:" + hostID
        }
    }

    var hostID: String {
        switch self {
        case .group(let hostID), .requests(let hostID): return hostID
        }
    }
}

struct UnifiedChatsView: View {
    @ObservedObject var library: ConnectionLibrary
    @ObservedObject private var push = PushNotifications.shared
    @StateObject private var chatActions = ChatListActions()
    @State private var selection: ComputerChatAddress?
    @State private var searchText = ""
    // These states belong to the Chats screen, not to a Menu submenu. SwiftUI
    // is free to recreate menu content after the menu dismisses.
    @State private var creatingBotHostID: String?
    @State private var creationError: BotCreationFailure?
    @State private var presentedModal: ChatsModal?
    private var visibleComputers: [SavedConnection] {
        library.saved.connections.filter { library.saved.includes($0.credential.hostInstallationId) }
    }
    private var chats: [(address: ComputerChatAddress, chat: ChatSummary, model: ConnectionModel)] {
        visibleComputers.flatMap { saved in
            let model = library.model(for: saved)
            guard model.hasConnectedThisLaunch && !model.accessEnded else { return [(address: ComputerChatAddress, chat: ChatSummary, model: ConnectionModel)]() }
            return model.chats.filter { $0.matchesName(searchText) }.map {
                (address: ComputerChatAddress(host: saved.credential.hostInstallationId, chat: $0.id), chat: $0, model: model)
            }
        }.sorted {
            if $0.chat.isPinned != $1.chat.isPinned { return $0.chat.isPinned }
            return ($0.chat.lastMessageAt ?? "") > ($1.chat.lastMessageAt ?? "")
        }
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if !library.saved.connections.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            filterPill("All", selected: library.saved.selectedHostIDs.isEmpty) { library.filter(nil) }
                            ForEach(library.saved.connections, id: \.credential.hostInstallationId) { saved in
                                ComputerFilterPill(model: library.model(for: saved),
                                                   selected: library.saved.selectedHostIDs.contains(saved.credential.hostInstallationId)) {
                                    library.filter(saved.credential.hostInstallationId)
                                }
                            }
                        }
                    }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                if let error = library.error { FailureDetails("Connection problem", message: error) }
                if let error = push.routingError {
                    Section {
                        Text(error)
                        if push.canRetryOpening { Button("Open notification") { push.retryOpening() } }
                        Button("Dismiss") { push.dismissRoutingError() }
                    }
                }
                ForEach(visibleComputers, id: \.credential.hostInstallationId) { saved in
                    ComputerConnectionNotice(model: library.model(for: saved))
                }
                Section {
                ForEach(chats, id: \.address) { entry in
                    NavigationLink(value: entry.address) {
                        HStack(spacing: 10) {
                            ChatAvatar(name: entry.chat.title, identity: entry.chat.botId ?? entry.chat.id,
                                       hexColor: entry.model.managedBots.first { $0.id == entry.chat.botId }?.avatarColor,
                                       avatarShape: entry.model.managedBots.first { $0.id == entry.chat.botId }?.avatarShape,
                                       avatarPalette: entry.model.managedBots.first { $0.id == entry.chat.botId }?.avatarPalette,
                                       isLoaded: entry.chat.botId == nil || entry.model.managedBots.contains { $0.id == entry.chat.botId })
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.chat.title).font(.headline)
                                    Spacer()
                                }
                                Text(entry.chat.lastMessagePreview ?? "No messages yet").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                if library.saved.connections.count > 1 {
                                    Text(entry.model.macName).font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 5)
                            ChatStatusIndicator(status: entry.model.chatListStatus(entry.chat), action: chatActions.status(entry.chat, model: entry.model))
                        }
                    }
                    .navigationLinkIndicatorVisibility(.hidden)
                    .accessibilityValue(chatActions.status(entry.chat, model: entry.model) ?? entry.model.chatListStatus(entry.chat).accessibilityValue)
                    .accessibilityIdentifier("chat-row:" + entry.address.host + ":" + entry.chat.id)
                    .contextMenu { ChatContextMenu(actions: chatActions, model: entry.model, chat: entry.chat) }
                }
                }
                if chats.isEmpty && visibleComputers.allSatisfy({ library.model(for: $0).macConnected == true }) {
                    ContentUnavailableView(library.saved.connections.isEmpty ? "Add a computer in Settings" : "No chats", systemImage: "bubble.left.and.bubble.right")
                }
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(visibleComputers, id: \.credential.hostInstallationId) { saved in
                        let model = library.model(for: saved)
                        if model.macConnected == true && !model.accessEnded {
                            Text(model.macName).font(.headline)
                            MessageSearchResults(model: model, query: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                }
            }
            .onChange(of: push.destination, initial: true) { _, value in
                guard let value else { return }
                library.filter(value.host)
                selection = ComputerChatAddress(host: value.host, chat: value.conversation)
            }
            .navigationTitle("Chats")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats and messages")
            .toolbar {
                Button {
                    Task {
                        await withTaskGroup(of: Void.self) { group in
                            for saved in visibleComputers {
                                let model = library.model(for: saved)
                                group.addTask { await model.loadChats(force: true) }
                            }
                        }
                    }
                } label: { Image(systemName: "arrow.clockwise").accessibilityLabel("Refresh chats") }
                .disabled(visibleComputers.isEmpty)
                if !library.saved.selectedHostIDs.isEmpty, let saved = visibleComputers.first {
                    chatMenu(for: saved, showComputerMenu: false)
                } else {
                    Menu {
                        ForEach(visibleComputers, id: \.credential.hostInstallationId) { saved in
                            chatMenu(for: saved)
                        }
                    } label: { newChatToolbarLabel }
                    .disabled(visibleComputers.isEmpty)
                }
                if visibleComputers.contains(where: { !library.model(for: $0).unmappedApprovalRequests.isEmpty }) {
                    Menu {
                        ForEach(visibleComputers, id: \.credential.hostInstallationId) { saved in
                            let model = library.model(for: saved)
                            if !model.unmappedApprovalRequests.isEmpty {
                                chatMenu(for: saved, requestsOnly: true)
                            }
                        }
                    } label: { Image(systemName: "hand.raised").accessibilityLabel("Requests") }
                }
            }
        } detail: {
            if let selection, let saved = library.saved.connections.first(where: { $0.credential.hostInstallationId == selection.host }) {
                ComputerConversation(model: library.model(for: saved), chatID: selection.chat).id(selection)
            } else { ContentUnavailableView("Choose a chat", systemImage: "bubble.left") }
        }
        .modifier(ChatActionDialogs(actions: chatActions))
        .alert("Couldn’t create Bot", isPresented: Binding(get: { creationError != nil }, set: { if !$0 { creationError = nil } })) {
            Button("Retry") {
                guard let failure = creationError else { return }
                creationError = nil
                startBotCreation(hostID: failure.hostID)
            }
            Button("Cancel", role: .cancel) { creationError = nil }
        } message: { Text(creationError?.message ?? "") }
        .sheet(item: $presentedModal) { modal in
            if let model = model(forHostID: modal.hostID) {
                switch modal {
                case .group:
                    GroupCreationView(model: model)
                case .requests:
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if model.unmappedApprovalRequests.isEmpty {
                                    Text("No requests waiting.").foregroundStyle(.secondary)
                                }
                                ForEach(model.unmappedApprovalRequests) { request in
                                    AttentionRow(model: model, request: request)
                                }
                            }.padding()
                        }
                        .navigationTitle("Requests")
                        .toolbar { Button("Done") { presentedModal = nil } }
                        .task { await model.loadAttention() }
                    }
                }
            } else {
                ContentUnavailableView("Computer unavailable", systemImage: "desktopcomputer")
            }
        }
        .background {
            ForEach(visibleComputers, id: \.credential.hostInstallationId) { saved in
                ComputerSelectionObserver(model: library.model(for: saved), selection: $selection)
            }
        }
        .onChange(of: library.saved.selectedHostIDs) { _, _ in
            if let selection, !library.saved.includes(selection.host) { self.selection = nil }
        }
        .onChange(of: selection) { previous, next in
            if let previous, previous.host != next?.host, let saved = library.saved.connections.first(where: { $0.credential.hostInstallationId == previous.host }) {
                library.model(for: saved).selectedChat = nil
            }
        }
        .onChange(of: coveredHostID, initial: true) { previous, next in
            if previous != next, let previous, let model = model(forHostID: previous) {
                model.setChatsModalPresented(false)
            }
            if let next, let model = model(forHostID: next) {
                model.setChatsModalPresented(true)
            }
        }
    }

    private var coveredHostID: String? {
        creatingBotHostID ?? presentedModal?.hostID
    }

    @ViewBuilder private var newChatToolbarLabel: some View {
        if creatingBotHostID != nil {
            ProgressView()
                .accessibilityIdentifier("new-bot-progress")
                .accessibilityLabel("Creating Bot…")
        } else {
            Image(systemName: "plus").accessibilityLabel("New chat and requests")
        }
    }

    private func model(forHostID hostID: String) -> ConnectionModel? {
        guard let saved = library.saved.connections.first(where: { $0.credential.hostInstallationId == hostID }) else { return nil }
        return library.model(for: saved)
    }

    @ViewBuilder private func chatMenu(for saved: SavedConnection, showComputerMenu: Bool = true, requestsOnly: Bool = false) -> some View {
        let model = library.model(for: saved)
        ComputerChatMenu(
            hostName: model.macName,
            showComputerMenu: showComputerMenu,
            requestsOnly: requestsOnly,
            hasRequests: !model.unmappedApprovalRequests.isEmpty,
            isConnected: model.macConnected == true && !model.accessEnded,
            isCreatingBot: creatingBotHostID == saved.credential.hostInstallationId,
            isAnyBotCreationInFlight: creatingBotHostID != nil,
            onNewBot: { startBotCreation(hostID: saved.credential.hostInstallationId) },
            onNewGroup: { presentedModal = .group(hostID: saved.credential.hostInstallationId) },
            onRequests: { presentedModal = .requests(hostID: saved.credential.hostInstallationId) }
        )
    }

    private func startBotCreation(hostID: String) {
        guard creatingBotHostID == nil,
              let saved = library.saved.connections.first(where: { $0.credential.hostInstallationId == hostID }) else { return }
        let model = library.model(for: saved)
        guard model.macConnected == true, !model.accessEnded else { return }

        // Set this before creating the Task. The synchronous guard and state
        // transition make repeated menu taps a single request.
        creatingBotHostID = hostID
        Task { @MainActor in
            do {
                let chat = try await model.createConversationalBot()
                if let chat {
                    // Use the initiating host captured above even if the user
                    // changed the filter or another host became selected.
                    selection = ComputerChatAddress(host: hostID, chat: chat)
                } else {
                    creationError = BotCreationFailure(hostID: hostID, message: "The Bot was created, but its conversation could not be opened.")
                }
            } catch {
                creationError = BotCreationFailure(hostID: hostID, message: managementError(error))
            }
            if creatingBotHostID == hostID { creatingBotHostID = nil }
        }
    }

    private func filterPill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(selected ? Color(uiColor: .systemBackground) : Color.primary)
                .background(selected ? Color(uiColor: .label) : Color(uiColor: .secondarySystemBackground), in: Capsule())
                .frame(minHeight: 44)
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ComputerFilterPill: View {
    @ObservedObject var model: ConnectionModel
    var selected: Bool
    var action: () -> Void
    private var status: String {
        model.macConnected == nil ? "Connecting" : model.accessEnded ? "Access ended" : model.macStatus
    }
    private var symbol: String {
        model.macName.localizedCaseInsensitiveContains("laptop") || model.macName.localizedCaseInsensitiveContains("book") ? "laptopcomputer" : "desktopcomputer"
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if !model.accessEnded && model.macConnected == nil {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle().fill(model.macConnected == true && !model.accessEnded ? Color.green : Color.red)
                            .frame(width: 7, height: 7)
                    }
                }.frame(width: 12, height: 12).accessibilityHidden(true)
                Image(systemName: symbol)
                Text(model.macName).lineLimit(1)
            }.font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(selected ? Color(uiColor: .systemBackground) : Color.primary)
                .background(selected ? Color(uiColor: .label) : Color(uiColor: .secondarySystemBackground), in: Capsule())
                .frame(minHeight: 44)
        }.buttonStyle(.plain)
            .accessibilityLabel(model.macName).accessibilityValue(status)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu {
                Button("Refresh connection", systemImage: "arrow.clockwise") { Task { await model.loadChats(force: true) } }
            }
    }
}

private struct ComputerConnectionNotice: View {
    @ObservedObject var model: ConnectionModel
    var body: some View {
        if model.accessEnded {
            Text("\(model.macName): pair again in Settings.").font(.caption).foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        }
    }
}

private struct ComputerConversation: View {
    @ObservedObject var model: ConnectionModel
    let chatID: String
    var body: some View {
        if model.hasConnectedThisLaunch && !model.accessEnded, let chat = model.chats.first(where: { $0.id == chatID }) {
            ConversationView(model: model, chat: chat)
        } else { ContentUnavailableView("Computer unavailable", systemImage: "desktopcomputer", description: Text("Check this computer in Settings.")) }
    }
}

private struct ComputerSelectionObserver: View {
    @ObservedObject var model: ConnectionModel
    @Binding var selection: ComputerChatAddress?
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: model.selectedChat?.id) { previous, chat in
                guard let host = model.connection?.credential.hostInstallationId else { return }
                if let chat { selection = ComputerChatAddress(host: host, chat: chat) }
                else if selection?.host == host, selection?.chat == previous { selection = nil }
            }
    }
}

private struct ComputerChatMenu: View {
    let hostName: String
    let showComputerMenu: Bool
    let requestsOnly: Bool
    let hasRequests: Bool
    let isConnected: Bool
    let isCreatingBot: Bool
    let isAnyBotCreationInFlight: Bool
    let onNewBot: () -> Void
    let onNewGroup: () -> Void
    let onRequests: () -> Void

    var body: some View {
        Menu {
            if !requestsOnly {
                Button(isCreatingBot ? "Creating Bot…" : "New Bot", systemImage: "plus", action: onNewBot)
                    .disabled(!isConnected || isAnyBotCreationInFlight)
                Button("New Group Chat", systemImage: "person.2", action: onNewGroup)
                    .disabled(!isConnected)
            }
            if hasRequests { Button("Requests", systemImage: "hand.raised", action: onRequests) }
        } label: {
            if showComputerMenu { Text(hostName) }
            else if isAnyBotCreationInFlight {
                ProgressView().accessibilityIdentifier("new-bot-progress").accessibilityLabel("Creating Bot…")
            } else { Image(systemName: "plus").accessibilityLabel("New chat and requests") }
        }
        .accessibilityValue(isAnyBotCreationInFlight ? "Creating Bot…" : "")
    }
}

struct ConnectionsView: View {
    @ObservedObject var library: ConnectionLibrary
    @State private var adding = false
    var body: some View {
        NavigationStack {
            List {
                if let error = library.error {
                    FailureDetails("Connection problem", message: error)
                    if !library.loaded { Button("Try again") { library.load() } }
                }
                Section("Connections") {
                ForEach(library.saved.connections, id: \.credential.hostInstallationId) { saved in
                    NavigationLink {
                        ConnectionDetail(model: library.model(for: saved), library: library)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(saved.hostName ?? URL(string: saved.origin)?.host ?? "Computer")
                            }
                        }.frame(minHeight: 44)
                    }
                }
                Button("Add computer", systemImage: "plus") { adding = true }.disabled(!library.loaded)
                }
                #if WONDER_DIAGNOSTICS
                Section { NavigationLink("Diagnostics") { DiagnosticsView(library: library) }.accessibilityIdentifier("diagnostics-settings") }
                #endif
                Section("Models") {
                    NavigationLink("Model settings") {
                        List { ForEach(ModelDefaultPurpose.allCases) { purpose in
                            NavigationLink(purpose.title) { NewBotModelSettings(library: library, purpose: purpose) }
                        } }.navigationTitle("Model settings")
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $adding) { PairComputerView(model: library.pairingModel()) }
        }
    }
}

struct ConnectionDetail: View {
    @ObservedObject private var push = PushNotifications.shared
    @ObservedObject var model: ConnectionModel
    @ObservedObject var library: ConnectionLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var removing = false
    @State private var pairing = false
    @State private var codexUsageLoading = false
    @State private var codexUsageFailure: String?
    var body: some View {
        Form {
            Section {
                Text(model.status).accessibilityIdentifier("connection-status")
                Button("Check connection") { Task { await model.check(renew: true, userInitiated: true) } }.disabled(model.busy)
                if model.accessEnded { Button("Pair again") { pairing = true } }
            }
            if let host = model.connection?.credential.hostInstallationId {
                Section {
                    Toggle("Notifications", isOn: Binding(
                        get: { push.isEnabled(host) },
                        set: { enabled in
                            if enabled { push.enable(model) }
                            else { push.disable(model) }
                        }
                    ))
                    .accessibilityIdentifier("connection-notifications")
                    if let state = push.setupState(host) {
                        switch state {
                        case .settingUp:
                            Text("Setting up notifications…")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("connection-notifications-status")
                        case .needsRetry(let message):
                            Text(message)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("connection-notifications-status")
                            Button("Retry notification setup") { push.retry(host) }
                                .accessibilityIdentifier("connection-notifications-retry")
                        }
                    }
                }
                .alert(push.settingsAlert?.title ?? "Couldn't change notifications", isPresented: Binding(
                    get: { push.settingsAlert?.host == host },
                    set: { if !$0 { push.dismissSettingsAlert() } }
                ), presenting: push.settingsAlert) { alert in
                    if alert.opensSettings {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    Button("OK", role: .cancel) { push.dismissSettingsAlert() }
                } message: { alert in Text(alert.message) }
            }
            Section {
                NavigationLink("Archived Bots") { ArchivedBotsView(model: model) }
                NavigationLink("Connected apps") { ConnectedAppsView(model: model) }
                NavigationLink("Voice & Dictation") { VoiceSettingsView(model: model, controller: model.dictation) }
            }
            Section {
                let windows = model.codexUsageCache[model.assignmentScope]?.response.windows ?? []
                if !windows.isEmpty {
                    ForEach(windows) { window in
                        HStack(spacing: 12) {
                            Text(window.label)
                            Spacer(minLength: 12)
                            Text("\(window.roundedRemainingPercent)% left")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("codex-usage-window:\(window.id)")
                        .accessibilityLabel(window.label)
                        .accessibilityValue("\(window.roundedRemainingPercent)% left")
                    }
                } else if codexUsageLoading {
                    ProgressView("Loading usage…")
                        .accessibilityIdentifier("codex-usage-loading")
                } else if let codexUsageFailure {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(codexUsageFailure).foregroundStyle(.secondary)
                        Button("Try again") { Task { await loadCodexUsage(force: true) } }
                            .accessibilityIdentifier("codex-usage-retry")
                    }
                } else {
                    Text("Usage is unavailable right now.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Codex usage").accessibilityIdentifier("codex-usage-section")
            }
            Section {
                Button("Remove connection", role: .destructive) { removing = true }.disabled(model.busy)
            }
            if let error = model.error { FailureDetails("Couldn’t connect", message: error) }
        }
        .navigationTitle(model.macName).navigationBarTitleDisplayMode(.inline)
        .task {
            await model.check()
            await loadCodexUsage()
        }
        .onChange(of: model.assignmentScope) { _, _ in codexUsageFailure = nil }
        .onChange(of: model.accessEnded) { _, ended in
            if ended { codexUsageFailure = "Usage is unavailable. Wonder on that Mac may need updating." }
        }
        .onChange(of: model.connection == nil) { _, removed in if removed { dismiss() } }
        .sheet(isPresented: $pairing, onDismiss: {
            if let host = model.connection?.credential.hostInstallationId,
               let latest = library.saved.connections.first(where: { $0.credential.hostInstallationId == host }),
               library.model(for: latest) !== model { dismiss() }
        }) { PairComputerView(model: library.pairingModel()) }
        .alert("Remove \(model.macName)?", isPresented: $removing) {
            Button("Cancel", role: .cancel) { }
            Button("Remove connection", role: .destructive) { model.forget() }
        } message: {
            Text("This removes this computer’s saved chats, drafts and credentials from this device. Other connections stay saved. To revoke this device’s access, use Wonder on the computer.")
        }
    }

    @MainActor private func loadCodexUsage(force: Bool = false) async {
        let scope = model.assignmentScope
        codexUsageFailure = nil
        codexUsageLoading = model.codexUsageCache[scope] == nil
        defer { codexUsageLoading = false }
        do {
            try await model.loadCodexUsage(force: force)
        } catch {
            guard scope == model.assignmentScope, !model.accessEnded,
                  model.codexUsageCache[scope] == nil else { return }
            if case PairingFailure.response(404) = error {
                codexUsageFailure = "Usage is unavailable. Wonder on that Mac may need updating."
            } else if case PairingFailure.response(503) = error {
                codexUsageFailure = "Usage is unavailable. Wonder on that Mac may need updating."
            } else {
                codexUsageFailure = "Usage couldn’t be loaded. Try again."
            }
        }
    }
}

struct PairComputerView: View {
    @StateObject var model: ConnectionModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var scanning = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("On your Mac, open Wonder → Settings → Devices → Pair Device.")
                }
                if model.busy {
                    Section {
                        ProgressView(model.status)
                        if let verification = model.verification {
                            Text(verification).font(.title2.monospaced()).textSelection(.enabled)
                                .accessibilityLabel("Verification text \(verification.map(String.init).joined(separator: " "))")
                        }
                        Button("Stop pairing", role: .cancel) { model.cancel() }
                    }
                } else {
                    Section("QR code or pairing link") {
                        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                            Button("Scan QR code", systemImage: "qrcode.viewfinder") { scanning = true }
                        } else { Text("Camera scanning is unavailable. Paste a pairing link to connect.").foregroundStyle(.secondary) }
                        TextField("Or paste pairing link", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Button("Connect to computer") { model.pair(link: link, address: "", code: "") }
                            .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let error = model.error { FailureDetails("Couldn’t connect", message: error) }
            }
            .navigationTitle("Add computer").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel(); dismiss() } } }
            .onChange(of: model.connection != nil) { _, paired in if paired { dismiss() } }
            .onDisappear { model.cancel() }
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    QRScanner(scanned: { value in scanning = false; link = value; model.pair(link: value, address: "", code: "") }, failed: { message in scanning = false; model.error = message + " Paste a pairing link to connect." })
                        .navigationTitle("Scan your computer’s code").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
                }
            }
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    var scanned: (String) -> Void
    var failed: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned, failed: failed) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        do { try controller.startScanning() } catch {
            Task { @MainActor in context.coordinator.failed(error.localizedDescription) }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) { uiViewController.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let scanned: (String) -> Void
        var used = false
        let failed: (String) -> Void
        init(scanned: @escaping (String) -> Void, failed: @escaping (String) -> Void) { self.scanned = scanned; self.failed = failed }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) { failed("Camera scanning is unavailable.") }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !used else { return }
            for case .barcode(let barcode) in addedItems {
                if let value = barcode.payloadStringValue { used = true; dataScanner.stopScanning(); scanned(value); break }
            }
        }
    }
}

struct ConnectedApp: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String?
    let status: String
    let logoUrl: String?
    let logoUrlDark: String?
    var label: String {
        switch status {
        case "available": "Available"
        case "disabled": "Disabled"
        case "not_connected": "Not connected"
        case "unavailable": "Unavailable"
        default: "Not verified"
        }
    }
}
struct ConnectedAppPage: Decodable, Sendable {
    let hostInstallationId: String
    let conversationId: String?
    let apps: [ConnectedApp]
    let nextCursor: String?
    let warning: String?
}
struct ConnectedAppCacheEntry {
    let page: ConnectedAppPage
    let fetchedAt: Date
}

struct ConnectedAppsView: View {
    @ObservedObject var model: ConnectionModel
    var conversationId: String? = nil
    @State private var apps: [ConnectedApp] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var failure: String?
    @State private var warning: String?
    @State private var visited: Set<String> = []
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        List {
            if let failure { FailureDetails(message: failure) }
            if let warning { Text(warning).foregroundStyle(.secondary) }
            Section {
                ForEach(apps) { app in
                    HStack(alignment: .top, spacing: 12) {
                        AsyncImage(url: URL(string: (colorScheme == .dark ? app.logoUrlDark ?? app.logoUrl : app.logoUrl) ?? "")) { image in
                            image.resizable().scaledToFit()
                        } placeholder: { Image(systemName: "app").foregroundStyle(.secondary) }
                        .frame(width: 32, height: 32).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(app.name).font(.headline); Spacer(); Text(failure == nil ? app.label : "Not verified").font(.subheadline).foregroundStyle(.secondary) }
                            if let description = app.description { Text(description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }.padding(.vertical, 4)
                }
                if loading { ProgressView("Checking apps…") }
                else if cursor != nil { Button("Load more") { Task { await load(more: true) } } }
                else if apps.isEmpty && failure == nil { Text("No apps were found for this scope.").foregroundStyle(.secondary) }
            } footer: {
                Text("Based on Codex connections.")
            }
        }
        .navigationTitle("Connected apps")
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(refresh: true) } }.disabled(loading) }
        .task(id: scope) { apps = []; cursor = nil; visited = []; await load() }
        .onChange(of: model.accessEnded) { _, ended in if ended { apps = []; cursor = nil; warning = nil; failure = "Access has ended. Reconnect in Settings." } }
        .onChange(of: scenePhase) { _, next in if next == .active { Task { await load() } } }
    }
    private var scope: String { model.assignmentScope + ":" + (conversationId ?? "host") }
    @MainActor private func load(more: Bool = false, refresh: Bool = false) async {
        guard !loading, let saved = model.connection, !model.accessEnded else { return }
        loading = true; failure = nil
        defer { loading = false }
        var components = URLComponents()
        components.path = "/api/v1/connected-apps"
        components.queryItems = [URLQueryItem(name: "refresh", value: refresh ? "true" : "false")]
        if let conversationId { components.queryItems?.append(URLQueryItem(name: "conversationId", value: conversationId)) }
        if more, let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        let savedScope = scope
        let cacheKey = savedScope + ":" + (more ? cursor ?? "" : "")
        if !more, apps.isEmpty, let cached = model.connectedAppsCache[cacheKey] {
            apps = cached.page.apps; cursor = cached.page.nextCursor; warning = cached.page.warning
        }
        do {
            let page: ConnectedAppPage
            if !refresh, let cached = model.connectedAppsCache[cacheKey], Date().timeIntervalSince(cached.fetchedAt) < 300 {
                page = cached.page
            } else {
                page = try await model.api.request(components.string!, origin: saved.origin, credential: saved.credential)
                guard savedScope == scope, page.hostInstallationId == saved.credential.hostInstallationId,
                    page.conversationId == conversationId, !model.accessEnded else { return }
                if refresh { model.connectedAppsCache = model.connectedAppsCache.filter { !$0.key.hasPrefix(savedScope + ":") } }
                model.connectedAppsCache[cacheKey] = ConnectedAppCacheEntry(page: page, fetchedAt: Date())
            }
            guard savedScope == scope,
                page.hostInstallationId == saved.credential.hostInstallationId, page.conversationId == conversationId,
                !model.accessEnded else { return }
            if !more { apps = []; visited = [] }
            var ids = Set(apps.map(\.id))
            apps += page.apps.filter { ids.insert($0.id).inserted }
            warning = page.warning
            cursor = page.nextCursor
            if let next = cursor, !visited.insert(next).inserted { cursor = nil; warning = "More apps could not be loaded. Refresh to try again." }
        } catch {
            guard savedScope == scope, !model.accessEnded else { return }
            if conversationId != nil, case PairingFailure.response(409) = error {
                failure = "Send this Bot a message, then check its app access again."
            } else {
                failure = "Apps could not be verified. Check Wonder on your computer, then refresh."
            }
        }
    }
}

struct NewBotModelSettings: View {
    @ObservedObject var library: ConnectionLibrary
    let purpose: ModelDefaultPurpose
    @State private var defaults: NewBotDefaults
    init(library: ConnectionLibrary, purpose: ModelDefaultPurpose = .newBots) {
        self.library = library; self.purpose = purpose
        _defaults = State(initialValue: purpose.load())
    }
    @State private var options: BotOptions?
    @State private var loading = false
    @State private var failure: String?
    private var selected: BotOptions.Model? {
        defaults.model.isEmpty ? options?.models.first(where: { !$0.hidden }) : options?.models.first(where: { $0.id == defaults.model })
    }
    private var automaticModel: String {
        options?.models.first(where: { !$0.hidden }).map { "Automatic (\($0.displayName))" } ?? "Automatic"
    }
    private var automaticEffort: String {
        guard let selected, let effort = selected.reasoningEfforts.first(where: { $0.id == selected.defaultReasoningEffort }) else { return "Model default" }
        return "Model default (\(effort.label.capitalized))"
    }
    var body: some View {
        Form {
            Section {
                if let options {
                    Picker("Model", selection: Binding(get: { defaults.model }, set: { value in
                        save(NewBotDefaults(model: value, approvalMode: defaults.approvalMode))
                    })) {
                        Text(automaticModel).tag("")
                        ForEach(options.models.filter { !$0.hidden }) { Text($0.displayName).tag($0.id) }
                        if !defaults.model.isEmpty && selected == nil { Text("\(defaults.model) (unavailable)").tag(defaults.model) }
                    }
                    if let selected, !selected.reasoningEfforts.isEmpty {
                        Picker("Reasoning", selection: Binding(get: { defaults.reasoningEffort }, set: { value in
                            save(NewBotDefaults(model: defaults.model, reasoningEffort: value, serviceTier: defaults.serviceTier, approvalMode: defaults.approvalMode))
                        })) {
                            Text(automaticEffort).tag("")
                            ForEach(selected.reasoningEfforts) { Text($0.label == "xhigh" ? "Extra high" : $0.label.capitalized).tag($0.id) }
                            if !defaults.reasoningEffort.isEmpty && !selected.reasoningEfforts.contains(where: { $0.id == defaults.reasoningEffort }) {
                                Text("\(defaults.reasoningEffort) (unavailable)").tag(defaults.reasoningEffort)
                            }
                        }
                    }
                    if let selected, let speeds = selected.serviceTiers, !speeds.isEmpty {
                        Picker("Speed", selection: Binding(get: { defaults.serviceTier ?? "" }, set: { value in
                            save(NewBotDefaults(model: defaults.model, reasoningEffort: defaults.reasoningEffort, serviceTier: value.isEmpty ? nil : value, approvalMode: defaults.approvalMode))
                        })) {
                            Text("Model default").tag("")
                            ForEach(speeds) { Text($0.label).tag($0.id) }
                            if let speed = defaults.serviceTier, !speeds.contains(where: { $0.id == speed }) { Text("\(speed) (unavailable)").tag(speed) }
                        }
                    }
                    Section("Approval") {
                        Picker("Mode", selection: Binding(get: { defaults.approvalMode }, set: { value in
                            save(NewBotDefaults(model: defaults.model, reasoningEffort: defaults.reasoningEffort, serviceTier: defaults.serviceTier, approvalMode: value))
                        })) {
                            ForEach(BotApprovalMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        .disabled(options.approvalModes == nil)
                        if options.approvalModes == nil {
                            Text("Update Wonder on your Mac to change approval settings.").font(.footnote).foregroundStyle(.secondary)
                        } else if options.approvalModes?.first(where: { $0.id == defaults.approvalMode.rawValue })?.allowed != true {
                            Text("This approval choice is unavailable on your Mac. Choose an available option before creating a Bot.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else if loading { ProgressView("Loading models") }
                else { Text("Connect a computer to load its available models.").foregroundStyle(.secondary) }
            } header: { Text(purpose.title) } footer: {
                Text(purpose == .newBots ? "Applies to new Bots across all connections. Existing Bots keep their own settings." : "Applies across all connections. Participating Bots keep their own model settings.")
            }
            if let failure {
                Section {
                    Text(failure).foregroundStyle(.secondary)
                    Button("Try again") { Task { await load() } }.disabled(loading)
                }
            }
            Section {
                Button("Use automatic defaults") { save(NewBotDefaults()) }
                    .disabled(defaults == NewBotDefaults())
            }
        }
        .navigationTitle("Model settings").navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }
    private func save(_ value: NewBotDefaults) {
        do {
            if !library.isPreview { try value.save(key: purpose.key) }
            defaults = value; failure = nil
        } catch { failure = "Couldn’t save model defaults. Try again." }
    }
    private func load() async {
        loading = true; defer { loading = false }
        #if DEBUG && targetEnvironment(simulator)
        if library.isPreview {
            let json = #"{"groupCollaboration":true,"models":[{"id":"gpt-6-astra","displayName":"GPT-6 Astra","hidden":false,"defaultReasoningEffort":"medium","reasoningEfforts":[{"id":"low","label":"Low"},{"id":"medium","label":"Medium"},{"id":"high","label":"High"},{"id":"xhigh","label":"Extra high"}],"serviceTiers":[{"id":"default","label":"Standard"},{"id":"priority","label":"Fast"}]},{"id":"gpt-5.6-luna","displayName":"GPT-5.6 Luna","hidden":false,"defaultReasoningEffort":"medium","reasoningEfforts":[{"id":"low","label":"Low"},{"id":"medium","label":"Medium"},{"id":"high","label":"High"},{"id":"xhigh","label":"Extra high"}],"serviceTiers":[{"id":"default","label":"Standard"},{"id":"priority","label":"Fast"}]}],"timezone":"UTC","allowedApprovalPolicies":["on-request"],"approvalModes":[{"id":"ask-for-approval","allowed":true},{"id":"approve-for-me","allowed":true},{"id":"full-access","allowed":true}]}"#
            options = try? JSONDecoder().decode(BotOptions.self, from: Data(json.utf8)); return
        }
        #endif
        let computers = library.saved.connections.map { library.model(for: $0) }
        for model in computers.sorted(by: { $0.macConnected == true && $1.macConnected != true }) {
            do {
                let loaded: BotOptions = try await model.manage("/api/v1/bot-options")
                if loaded.models.contains(where: { !$0.hidden }) { options = loaded; failure = nil; return }
            } catch { continue }
        }
        failure = "Model choices are unavailable. Check your computer connection and try again."
    }
}
