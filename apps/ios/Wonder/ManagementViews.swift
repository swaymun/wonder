import SwiftUI
import WonderPairing

func managementError(_ error: Error) -> String {
    if let error = error as? NewBotDefaults.SelectionError { return error.localizedDescription }
    if (error as NSError).domain == "Wonder" { return error.localizedDescription }
    if case PairingFailure.response(let status) = error {
        switch status {
        case 400, 422: return "These settings could not be saved. Check the fields and try again."
        case 401, 403: return "Access has ended. Reconnect to your Mac in Settings."
        case 404: return "This item is no longer available. Refresh to see the latest changes."
        case 409: return "This change is blocked. Stop any active work and check Group lead assignments on your Mac, then refresh and try again."
        default: break
        }
    }
    return "Your Mac could not confirm this change. Your choices are saved; reconnect and retry."
}
extension ConnectionModel {
    func manage<T: Decodable & Sendable>(_ path: String, method: String = "GET", values: [String: String]? = nil,
                                          body: Data? = nil, decodingStatuses: Set<Int> = []) async throws -> T {
        guard let saved = connection, !accessEnded else { throw PairingFailure.response(401) }
        #if WONDER_DIAGNOSTICS
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        var diagnosticSucceeded = false
        let diagnosticOperation: String?
        if method == "POST", path == "/api/v1/bots" { diagnosticOperation = "bot.create" }
        else if method == "POST", path.hasPrefix("/api/v1/bots/"), path.hasSuffix("/archive") { diagnosticOperation = "bot.archive" }
        else { diagnosticOperation = nil }
        defer {
            if let diagnosticOperation {
                DiagnosticJournal.shared.record(DiagnosticEvent(operation: diagnosticOperation, phase: diagnosticSucceeded ? "duration" : "failed", durationMs: (ProcessInfo.processInfo.systemUptime-diagnosticStart)*1000))
            }
        }
        #endif
        let value: T = try await api.request(
            path,
            origin: saved.origin,
            body: try body ?? values.map { try JSONEncoder().encode($0) },
            credential: saved.credential,
            method: method,
            decodingStatuses: decodingStatuses
        )
        guard connection?.credential.hostInstallationId == saved.credential.hostInstallationId,
            connection?.credential.deviceId == saved.credential.deviceId, !accessEnded else { throw CancellationError() }
        #if WONDER_DIAGNOSTICS
        diagnosticSucceeded = true
        #endif
        return value
    }
    var managementDrafts: ManagementDraftStore? { connection.map { ManagementDraftStore(host: $0.credential.hostInstallationId) } }
}

/// The default model, reasoning effort and speed for each harness. The Mac keeps
/// them and applies them to its model list, so New Chat and the composer follow
/// without a rule of their own.
struct DefaultModelsView: View {
    @ObservedObject var model: ConnectionModel
    @State private var options: [BotOptions.Model]?
    @State private var stored: DefaultModelPreferences?
    @State private var loading = false
    @State private var loadFailure: String?
    @State private var saving: AgentFamily?
    @State private var saveFailures: [AgentFamily: String] = [:]

    var body: some View {
        Form {
            if let loadFailure {
                Section {
                    Text(loadFailure).foregroundStyle(.secondary)
                    Button("Try again") { Task { await load() } }
                        .disabled(loading)
                        .accessibilityIdentifier("default-models-retry")
                }
            }
            if let options, let stored {
                ForEach(AgentFamily.allCases) { family in
                    familySection(DefaultModelChoices(family: family, options: options, stored: stored.entry(family)))
                }
            } else if loading {
                Section { ProgressView("Loading models…") }
            }
        }
        .wonderGroupedStyle()
        .navigationTitle("Default models")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder private func familySection(_ choices: DefaultModelChoices) -> some View {
        let family = choices.family
        Section {
            if choices.models.isEmpty {
                Text("\(family.title) has no models available on this computer.").foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: Binding(
                    get: { choices.selected.model ?? "" },
                    set: { save(choices.choosing(model: $0.isEmpty ? nil : $0)) }
                )) {
                    Text("Wonder’s default").tag("")
                    ForEach(choices.models) { Text($0.displayName).tag($0.id) }
                }
                .accessibilityIdentifier("default-model-\(family.rawValue)")
                if !choices.efforts.isEmpty {
                    Picker("Reasoning effort", selection: Binding(
                        get: { choices.selected.effort ?? "" },
                        set: { save(choices.choosing(effort: $0.isEmpty ? nil : $0)) }
                    )) {
                        Text("Model default").tag("")
                        ForEach(choices.efforts) { Text(ModelDefaults.title(of: $0)).tag($0.id) }
                    }
                    .accessibilityIdentifier("default-effort-\(family.rawValue)")
                }
                if choices.speeds.count > 1 {
                    Picker("Speed", selection: Binding(
                        get: { choices.selected.serviceTier ?? "" },
                        set: { save(choices.choosing(speed: $0.isEmpty ? nil : $0)) }
                    )) {
                        Text("Model default").tag("")
                        ForEach(choices.speeds) { Text($0.label).tag($0.id) }
                    }
                    .accessibilityIdentifier("default-speed-\(family.rawValue)")
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text(family.title)
                if saving == family { ProgressView().controlSize(.small) }
            }
        } footer: {
            if let failure = saveFailures[family] { Text(failure).foregroundStyle(.red) }
        }
        .disabled(saving == family)
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let fetchedOptions: BotOptions = try await model.manage("/api/v1/bot-options")
            let fetched: DefaultModelPreferences = try await model.manage("/api/v1/settings/default-models")
            options = fetchedOptions.models
            stored = fetched
            loadFailure = nil
        } catch is CancellationError {
        } catch {
            loadFailure = options == nil
                ? "Your Mac couldn’t send its models. Update Wonder on your Mac, then try again."
                : managementError(error)
        }
    }

    private func save(_ entry: DefaultModelPreferences.Entry) {
        guard let previous = stored, saving == nil else { return }
        var next = previous
        next.families = previous.families.filter { $0.family != entry.family } + [entry]
        stored = next
        saving = entry.family
        saveFailures[entry.family] = nil
        Task {
            defer { saving = nil }
            do {
                let confirmed: DefaultModelPreferences = try await model.manage(
                    DefaultModelChoices.path(entry.family), method: "PUT", body: DefaultModelChoices.body(entry))
                stored = confirmed
            } catch is CancellationError {
                stored = previous
            } catch {
                stored = previous
                saveFailures[entry.family] = managementError(error)
            }
        }
    }
}

struct ApprovalModeMenu<LabelContent: View>: View {
    @Binding var selection: BotApprovalMode
    let options: [BotOptions.ApprovalMode]?
    let isDisabled: Bool
    let family: AgentFamily
    let onChange: (BotApprovalMode) -> Void
    let label: () -> LabelContent

    init(
        selection: Binding<BotApprovalMode>,
        options: [BotOptions.ApprovalMode]?,
        isDisabled: Bool = false,
        family: AgentFamily = .codex,
        onChange: @escaping (BotApprovalMode) -> Void,
        @ViewBuilder label: @escaping () -> LabelContent
    ) {
        _selection = selection
        self.options = options
        self.isDisabled = isDisabled
        self.family = family
        self.onChange = onChange
        self.label = label
    }

    var body: some View {
        Menu {
            ForEach(BotApprovalMode.allCases.filter { family != .claude || $0 != .approveForMe }) { mode in
                Button {
                    selection = mode
                    onChange(mode)
                } label: {
                    Text(mode.title)
                    Text(mode.description(for: family))
                    if mode == selection { Image(systemName: "checkmark") }
                }
                .disabled(options?.first(where: { $0.id == mode.rawValue })?.allowed != true)
                .accessibilityIdentifier("approval-choice-" + mode.rawValue)
            }
        } label: { label().contentShape(Rectangle()) }
        .disabled(isDisabled || options == nil)
        .accessibilityValue(selection.title)
    }
}

/// Details for a conversation that is not a project thread, such as an existing
/// Bot chat opened from a notification.
struct ConversationDetails: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    @Environment(\.dismiss) private var dismiss
    @State private var files = false
    private var bot: ManagedBot? { model.managedBots.first { $0.id == chat.botId } }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        ChatAvatar(name: chat.title, identity: chat.botId ?? chat.id, hexColor: bot?.avatarColor, avatarShape: bot?.avatarShape, avatarPalette: bot?.avatarPalette)
                        Text(chat.title).font(.headline)
                    }
                }
                Section { Button("Files", systemImage: "doc") { files = true }.accessibilityIdentifier("conversation-details-files") }
            }
            .navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $files) { WorkspaceSheet(close: { files = false }) { WorkspaceBrowser(model: model, chat: chat, attachmentIDs: nil) } }
        }
    }
}
