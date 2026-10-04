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
    @AppStorage(ChatBubblePalette.storageKey) private var bubblePaletteRaw = ChatBubblePalette.standard.rawValue

    var body: some View {
        content.environmentObject(library)
            .environment(\.chatBubblePalette, ChatBubblePalette(rawValue: bubblePaletteRaw) ?? .standard)
    }

    @ViewBuilder private var content: some View {
        #if WONDER_DIAGNOSTICS
        if ProcessInfo.processInfo.arguments.contains("-diagnostics-connected-apps") { DiagnosticConnectedAppsFixtureView() }
        else if ProcessInfo.processInfo.arguments.contains("-diagnostics-automations-fixture") { DiagnosticAutomationsFixtureView() }
        else if DiagnosticSubagentFixture.chatLayoutFixture { DiagnosticChatLayoutFixtureView() }
        else if ProcessInfo.processInfo.arguments.contains("-diagnostics-subagent-fixture") { DiagnosticSubagentFixtureView() }
        else if ProcessInfo.processInfo.arguments.contains("-diagnostics-computer-session-fixture") { ComputerSessionDiagnosticFixtureView() }
        else if ProcessInfo.processInfo.arguments.contains("-diagnostics-fixtures") { DiagnosticFixtureView() }
        else if DiagnosticScenarioLaunch.requested { DiagnosticLaunchView(library: library) }
        else { normalRoot }
        #else
        normalRoot
        #endif
    }
    @ViewBuilder private var normalRoot: some View {
        #if DEBUG || WONDER_DIAGNOSTICS
        if preview.previewMode && !library.isPreview { PreviewConversationRoot(model: preview) }
        else { ChatShell(library: library) }
        #else
        ChatShell(library: library)
        #endif
    }
}

#if DEBUG || WONDER_DIAGNOSTICS
/// The synthetic `-read-preview` fixture: its one conversation, shown directly
/// so the shared timeline and composer can be exercised without pairing.
private struct PreviewConversationRoot: View {
    @ObservedObject var model: ConnectionModel
    var body: some View {
        NavigationStack {
            if let chat = model.chats.first { ConversationView(model: model, chat: chat).id(chat.id) }
            else { ProgressView() }
        }
    }
}
#endif

/// Settings. It is pushed onto the main navigation stack with a Back button;
/// only first-launch pairing presents it as a sheet, which needs its own Done.
struct ConnectionsView: View {
    @ObservedObject var library: ConnectionLibrary
    var isSheet = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ProjectWidgetSnapshot.showNamesPreferenceKey) private var showNamesOnWidgets = false
    @State private var adding = false
    @State private var widgetFailure: String?
    var body: some View {
        if isSheet {
            NavigationStack {
                content
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("settings-done") } }
            }
        } else {
            content
        }
    }
    private var content: some View {
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
            Section("Appearance") {
                NavigationLink("Chat bubbles") { ChatAppearanceView() }
                    .accessibilityIdentifier("settings-chat-bubbles")
            }
            if ProjectWidgetIdentity(bundleIdentifier: Bundle.main.bundleIdentifier) != nil {
                Section {
                    Toggle("Show names on widgets", isOn: Binding(
                        get: { showNamesOnWidgets },
                        set: { value in
                            let previous = showNamesOnWidgets
                            showNamesOnWidgets = value
                            if !library.publishWidgetSnapshotNow() {
                                showNamesOnWidgets = previous
                                widgetFailure = "Widget settings could not be saved. Try again."
                            } else { widgetFailure = nil }
                        }
                    ))
                    .accessibilityIdentifier("widget-show-names")
                    if let widgetFailure { Text(widgetFailure).foregroundStyle(.red) }
                } header: {
                    Text("Widgets")
                } footer: {
                    Text("Names may appear on your Home Screen when enabled. Otherwise widgets use generic Project and chat labels.")
                }
            }
            #if WONDER_DIAGNOSTICS
            Section { NavigationLink("Diagnostics") { DiagnosticsView(library: library) }.accessibilityIdentifier("diagnostics-settings") }
            #endif
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $adding) { PairComputerView(model: library.pairingModel()) }
    }
}

private struct ChatAppearanceView: View {
    @AppStorage(ChatBubblePalette.storageKey) private var paletteRaw = ChatBubblePalette.standard.rawValue
    var body: some View {
        Form {
            Section {
                Picker("Bubble palette", selection: $paletteRaw) {
                    ForEach(ChatBubblePalette.allCases, id: \.rawValue) { palette in
                        Text(palette.title).tag(palette.rawValue)
                    }
                }
                .accessibilityIdentifier("chat-bubble-palette")
            }
            Section("Preview") {
                VStack(spacing: 12) {
                    Text("Agent response")
                        .modifier(ChatBubbleSurface())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Your message")
                        .modifier(ChatBubbleSurface(isUser: true))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .contain)
            }
        }
        .navigationTitle("Chat bubbles")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ConnectionDetail: View {
    @ObservedObject private var push = PushNotifications.shared
    @ObservedObject var model: ConnectionModel
    @ObservedObject var library: ConnectionLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var removing = false
    @State private var pairing = false
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
                NavigationLink("Automations") { AutomationsView(model: model) }
                    .accessibilityIdentifier("connection-automations")
                NavigationLink("Connected apps") { ConnectedAppsView(model: model) }
            }
            CodexUsageSection(model: model)
            ClaudeUsageSection(model: model)
            Section {
                Button("Remove connection", role: .destructive) { removing = true }.disabled(model.busy)
            }
            if let error = model.error { FailureDetails("Couldn’t connect", message: error) }
        }
        .navigationTitle(model.macName).navigationBarTitleDisplayMode(.inline)
        .task {
            await model.check()
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

}

struct ProviderUsageView: View {
    @ObservedObject var model: ConnectionModel
    let family: AgentFamily
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if family == .codex { CodexUsageSection(model: model) }
                else { ClaudeUsageSection(model: model) }
            }
            .navigationTitle("\(family.title) usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

private struct CodexUsageSection: View {
    @ObservedObject var model: ConnectionModel
    @State private var loading = false
    @State private var failure: String?
    var body: some View {
        Section {
            let windows = model.codexUsageCache[model.assignmentScope]?.response.windows ?? []
            if let failure, !loading {
                Text(failure).foregroundStyle(.secondary)
                if !windows.isEmpty { Text("Previous usage values may be out of date.").foregroundStyle(.secondary) }
            }
            if !windows.isEmpty {
                ForEach(windows) { window in
                    HStack(spacing: 12) {
                        Text(window.label)
                        Spacer(minLength: 12)
                        Text("\(window.roundedRemainingPercent)% left")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("codex-usage-window:\(window.id)")
                    .accessibilityLabel(window.label)
                    .accessibilityValue("\(window.roundedRemainingPercent)% left")
                }
            }
            if loading {
                ProgressView("Loading usage…").accessibilityIdentifier("codex-usage-loading")
            } else if failure == nil && windows.isEmpty && model.codexUsageCache[model.assignmentScope] != nil {
                Text("Codex returned no usage windows. Try refreshing after checking sign-in on your Mac.").foregroundStyle(.secondary)
            } else if failure == nil && windows.isEmpty {
                Text("Usage is unavailable right now.").foregroundStyle(.secondary)
            }
            Button(failure == nil ? "Refresh Codex usage" : "Try again") {
                Task { await load(force: true) }
            }
            .disabled(loading)
            .accessibilityIdentifier(failure == nil ? "codex-usage-refresh" : "codex-usage-retry")
        } header: {
            Text("Codex usage").accessibilityIdentifier("codex-usage-section")
        }
        .task(id: model.assignmentScope) { await load(force: false) }
        .onChange(of: model.accessEnded) { _, ended in
            if ended { failure = "Access ended. Reconnect this Mac to check usage." }
        }
    }

    @MainActor private func load(force: Bool = false) async {
        let scope = model.assignmentScope
        failure = nil
        loading = true
        defer { if scope == model.assignmentScope { loading = false } }
        do {
            try await model.loadCodexUsage(force: force)
        } catch {
            guard scope == model.assignmentScope, !model.accessEnded else { return }
            if case PairingFailure.response(404) = error {
                failure = "Update Wonder on this Mac to check Codex usage."
            } else if case PairingFailure.response(501) = error {
                failure = "This Codex version doesn't provide usage details in Wonder."
            } else if case PairingFailure.response(503) = error {
                failure = "Codex usage couldn't be verified on this Mac. Check Codex sign-in, then try again."
            } else {
                failure = "Usage couldn’t be loaded. Try again."
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
    @State private var address = ""
    @State private var code = ""
    @State private var enteringCode = false
    @State private var scanning = false
    var body: some View {
        NavigationStack {
            Form {
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
                    if enteringCode {
                        Section("Mac HTTPS address and code") {
                            TextField("Mac HTTPS address", text: $address)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .accessibilityIdentifier("pairing-mac-address")
                            TextField("Pairing code", text: $code)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                                .accessibilityIdentifier("pairing-code")
                        }
                    } else {
                        Section {
                            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                                Button("Scan QR code", systemImage: "qrcode.viewfinder") { scanning = true }
                            }
                            TextField("Or paste pairing link", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        } header: {
                            Text("QR code or pairing link")
                        } footer: {
                            if !DataScannerViewController.isSupported || !DataScannerViewController.isAvailable {
                                Text("Camera scanning is unavailable on this device. Paste a pairing link instead.")
                            }
                        }
                    }
                    Section {
                        Button(enteringCode ? "Use QR or pairing link" : "Use pairing code") {
                            enteringCode.toggle()
                        }
                        .accessibilityIdentifier("pairing-entry-mode")
                    }
                }
                Section {
                    Text("On your Mac, open Wonder → Settings → Devices → Pair Device.")
                }
                if let error = model.error { FailureDetails("Couldn’t connect", message: error) }
            }
            .safeAreaInset(edge: .bottom) {
                if !model.busy {
                    Button(enteringCode ? "Connect with code" : "Connect to computer") {
                        model.pair(link: enteringCode ? "" : link,
                                   address: enteringCode ? address : "",
                                   code: enteringCode ? code : "")
                    }
                    .disabled(enteringCode
                        ? address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        : link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier(enteringCode ? "pairing-connect-code" : "pairing-connect-link")
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
                }
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
            if let failure {
                Section {
                    Text(failure).foregroundStyle(.secondary)
                    Button("Try again") { Task { await load(refresh: true) } }
                        .disabled(loading)
                        .accessibilityIdentifier("connected-apps-retry")
                }
            }
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
            if conversationId != nil, case PairingFailure.response(424) = error {
                model.connectedAppsCache = model.connectedAppsCache.filter { !$0.key.hasPrefix(savedScope + ":") }
                cursor = nil; visited = []
                failure = "This conversation’s app access isn’t available right now. Check account-wide apps in Settings."
            } else if conversationId != nil, case PairingFailure.response(409) = error {
                failure = "Start this conversation or reopen it, then check its app access again."
            } else if case PairingFailure.response(501) = error {
                failure = "This provider doesn't offer Connected Apps in Wonder yet."
            } else if case PairingFailure.response(404) = error {
                failure = "Update Wonder on this Mac to check Connected Apps."
            } else {
                failure = "Apps could not be verified. Check Wonder on your computer, then refresh."
            }
        }
    }
}
