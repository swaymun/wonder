import SwiftUI
import WonderPairing
import VisionKit

@main struct WonderApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @StateObject private var library = ConnectionLibrary()
    @StateObject private var preview = ConnectionModel(saved: nil, persistConnection: { _ in })
    var body: some Scene {
        // WindowGroup can invoke its lazy builder on SwiftUI.AsyncRenderer.
        // Read app-owned state here; let the View body own actor-isolated work.
        let root = WonderRoot(library: library, preview: preview)
        let makeContent: @Sendable () -> WonderRoot = { root }
        WindowGroup(makeContent: makeContent)
    }
}

private struct WonderRoot: View {
    @ObservedObject var library: ConnectionLibrary
    @ObservedObject var preview: ConnectionModel

    var body: some View {
        #if WONDER_DIAGNOSTICS
        if ProcessInfo.processInfo.arguments.contains("-diagnostics-avatar-fixture") { ScienceAvatarDiagnosticFixtureView() }
        else if ProcessInfo.processInfo.arguments.contains("-diagnostics-connected-apps") { DiagnosticConnectedAppsFixtureView() }
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
    @ViewBuilder private var normalRoot: some View {
        if preview.previewMode && !library.isPreview { ChatsView(model: preview) }
        else { ChatShell(library: library) }
    }
}

struct ConnectionsView: View {
    @ObservedObject var library: ConnectionLibrary
    @Environment(\.dismiss) private var dismiss
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
                Button("Add computer", systemImage: "plus") { adding = true }.disabled(!library.loaded).accessibilityIdentifier("settings-add-computer")
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("settings-done") } }
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
                NavigationLink("Projects") { ManageProjectsView(model: model, library: model.projects, embedded: true) }
                    .accessibilityIdentifier("connection-projects")
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
            ClaudeUsageSection(model: model)
            Section {
                NavigationLink("Projects") {
                    ManageProjectsView(model: model, library: model.projects, embedded: true)
                }.accessibilityIdentifier("connection-projects")
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
            Button("Remove connection", role: .destructive) { Task { await model.forget() } }
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

private struct ClaudeUsageSection: View {
    @ObservedObject var model: ConnectionModel
    @State private var loading = false
    @State private var failure: String?
    var body: some View {
        Section {
            if let cached = model.claudeUsageCache[model.assignmentScope] {
                ForEach(cached.response.windows) { window in
                    HStack {
                        Text(window.label)
                        Spacer(minLength: 12)
                        Text("\(window.roundedRemainingPercent)% left").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("claude-usage-window:" + window.id)
                    .accessibilityLabel(window.label)
                    .accessibilityValue("\(window.roundedRemainingPercent)% left")
                }
            } else if loading { ProgressView("Loading usage…") }
            if let failure { Text(failure).foregroundStyle(.secondary) }
            Button("Refresh Claude usage") { Task { await load(force: true) } }.disabled(loading)
        } header: { Text("Claude usage").accessibilityIdentifier("claude-usage-section") }
        .task(id: model.assignmentScope) { await load(force: false) }
    }
    private func load(force: Bool) async {
        let scope = model.assignmentScope
        loading = true; failure = nil
        defer { if scope == model.assignmentScope { loading = false } }
        do { try await model.loadUsage(family: .claude, force: force) }
        catch {
            guard scope == model.assignmentScope, !model.accessEnded else { return }
            failure = "Claude usage couldn’t be loaded. Check your Claude sign-in in Wonder on your Mac, then refresh."
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
    var displayName: String {
        // Older Claude hosts included the account namespace in connector names.
        let normalized = name.replacingOccurrences(of: #"(?i)^claude\.ai(?:\s*[:/·-]\s*|\s+)"#, with: "", options: .regularExpression)
        return normalized.isEmpty ? name : normalized
    }
    var bundledIcon: String? {
        switch displayName.lowercased() {
        case "gmail": "ConnectorGmail"
        case "google calendar": "ConnectorGoogleCalendar"
        case "google drive": "ConnectorGoogleDrive"
        case "claude docs": "ConnectorClaudeDocs"
        case "github": "ConnectorGitHub"
        case "openai platform": "ConnectorOpenAIPlatform"
        case "linear": "ConnectorLinear"
        case "sites": "ConnectorSites"
        case "flashloop": "ConnectorFlashloop"
        case "adobe acrobat": "ConnectorAdobeAcrobat"
        default: nil
        }
    }
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
    let agentFamily: String?
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
    @State private var selectedFamily: AgentFamily = .codex
    @State private var reportedFamily: AgentFamily?
    @State private var loadingScope: String?
    @State private var loadID = UUID()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        List {
            if conversationId == nil {
                Picker("Connections", selection: $selectedFamily) {
                    ForEach(AgentFamily.allCases) { family in Text(family.title).tag(family) }
                }.pickerStyle(.segmented)
            }
            if let failure { FailureDetails(message: failure) }
            if let warning { Text(warning).foregroundStyle(.secondary) }
            Section {
                ForEach(apps) { app in
                    HStack(alignment: .top, spacing: 12) {
                        Group {
                            if let icon = app.bundledIcon {
                                Image(icon).resizable().scaledToFit()
                            } else {
                                AsyncImage(url: URL(string: (colorScheme == .dark ? app.logoUrlDark ?? app.logoUrl : app.logoUrl) ?? "")) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: { Image(systemName: "puzzlepiece.extension.fill").resizable().scaledToFit().foregroundStyle(.secondary) }
                            }
                        }
                        .frame(width: 32, height: 32).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            if dynamicTypeSize.isAccessibilitySize {
                                Text(app.displayName).font(.headline)
                                Text(failure == nil ? app.label : "Not verified").font(.subheadline).foregroundStyle(.secondary)
                            } else {
                                HStack { Text(app.displayName).font(.headline); Spacer(); Text(failure == nil ? app.label : "Not verified").font(.subheadline).foregroundStyle(.secondary) }
                            }
                            if let description = app.description { Text(description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }.padding(.vertical, 4)
                }
                if loading { ProgressView("Checking apps…") }
                else if cursor != nil { Button("Load more") { Task { await load(more: true) } } }
                else if apps.isEmpty && failure == nil { Text("No apps were found for this scope.").foregroundStyle(.secondary) }
            } footer: {
                if (reportedFamily ?? selectedFamily) == .claude {
                    Link("Manage Claude connections", destination: URL(string: "https://claude.ai/settings/connectors")!)
                }
            }
        }
        .navigationTitle("Connected apps")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(refresh: true) } }.disabled(loading) }
        .task(id: scope) { apps = []; cursor = nil; visited = []; reportedFamily = nil; await load() }
        .onChange(of: model.accessEnded) { _, ended in if ended { apps = []; cursor = nil; warning = nil; failure = "Access has ended. Reconnect in Settings." } }
        .onChange(of: scenePhase) { _, next in if next == .active { Task { await load() } } }
    }
    private var scope: String { model.assignmentScope + ":" + (conversationId ?? "host:" + selectedFamily.rawValue) }
    @MainActor private func load(more: Bool = false, refresh: Bool = false) async {
        guard !loading || loadingScope != scope, let saved = model.connection, !model.accessEnded else { return }
        let requestID = UUID(); loadID = requestID; loadingScope = scope
        loading = true; failure = nil
        defer { if loadID == requestID { loading = false } }
        var components = URLComponents()
        components.path = "/api/v1/connected-apps"
        components.queryItems = [URLQueryItem(name: "refresh", value: refresh ? "true" : "false")]
        if let conversationId { components.queryItems?.append(URLQueryItem(name: "conversationId", value: conversationId)) }
        else { components.queryItems?.append(URLQueryItem(name: "agentFamily", value: selectedFamily.rawValue)) }
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
            reportedFamily = page.agentFamily.flatMap(AgentFamily.init(rawValue:)) ?? .codex
            if conversationId == nil, reportedFamily != selectedFamily { throw ReadFailure.resync }
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
                        let approval = AgentFamily(model: value) == .claude && defaults.approvalMode == .approveForMe ? BotApprovalMode.askForApproval : defaults.approvalMode
                        save(NewBotDefaults(model: value, approvalMode: approval))
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
                            ForEach(BotApprovalMode.allCases.filter { selected?.family != .claude || $0 != .approveForMe }) { mode in Text(mode.title).tag(mode) }
                        }
                        .disabled(options.approvalModes == nil)
                        if options.approvalModes == nil {
                            Text("Update Wonder on your Mac to change approval settings.").font(.footnote).foregroundStyle(.secondary)
                        } else if options.approvalChoices(model: selected?.id)?.first(where: { $0.id == defaults.approvalMode.rawValue })?.allowed != true {
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
