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

/// The loaded defaults of every paired Mac, and the writes that keep them in step.
@MainActor final class AppDefaultModelsModel: ObservableObject {
    @Published private(set) var macs: [AppDefaultModels.Mac] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    /// Per Mac name: why its models could not be read.
    @Published private(set) var loadFailures: [(name: String, message: String)] = []
    @Published private(set) var saving: AgentFamily?
    /// Per harness: the Macs that did not take the change.
    @Published private(set) var saveFailures: [AgentFamily: [String]] = [:]
    private var connections: [String: ConnectionModel] = [:]

    private struct LoadOutcome: Sendable {
        let name: String
        let mac: AppDefaultModels.Mac?
        let failure: String?
    }
    private struct SaveOutcome: Sendable {
        let macID: String
        let confirmed: DefaultModelPreferences?
        let failure: String?
    }

    func load(library: ConnectionLibrary) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let usable = library.saved.connections.filter { !$0.requiresPairing }.map { library.model(for: $0) }
        // Every Mac is asked at once; one slow or offline Mac does not hold up the rest.
        let requests: [Task<LoadOutcome, Never>] = usable.map { model in
            Task { @MainActor in
                let name = model.macName
                do {
                    let options: BotOptions = try await model.manage("/api/v1/bot-options")
                    let stored: DefaultModelPreferences = try await model.manage("/api/v1/settings/default-models")
                    let id = model.connection?.credential.hostInstallationId ?? name
                    return LoadOutcome(name: name, mac: .init(id: id, name: name, models: options.models, stored: stored), failure: nil)
                } catch is CancellationError {
                    return LoadOutcome(name: name, mac: nil, failure: nil)
                } catch {
                    return LoadOutcome(name: name, mac: nil, failure: managementError(error))
                }
            }
        }
        var loadedMacs: [AppDefaultModels.Mac] = []
        var failures: [(name: String, message: String)] = []
        for (model, request) in zip(usable, requests) {
            let outcome = await request.value
            if let mac = outcome.mac { loadedMacs.append(mac); connections[mac.id] = model }
            else if let failure = outcome.failure { failures.append((outcome.name, failure)) }
        }
        macs = loadedMacs
        loadFailures = failures
        loaded = true
    }

    /// Writes each change to its Mac at once; a Mac that refuses keeps its old value and is named.
    func apply(_ writes: [AppDefaultModels.Write], family: AgentFamily) {
        guard saving == nil, !writes.isEmpty else { return }
        let previous = macs
        for write in writes { replace(write.macID, with: write.entry, in: &macs) }
        saving = family
        saveFailures[family] = nil
        let requests: [Task<SaveOutcome, Never>] = writes.compactMap { write in
            guard let model = connections[write.macID] else { return nil }
            return Task { @MainActor in
                do {
                    let confirmed: DefaultModelPreferences = try await model.manage(
                        DefaultModelChoices.path(family), method: "PUT", body: DefaultModelChoices.body(write.entry))
                    return SaveOutcome(macID: write.macID, confirmed: confirmed, failure: nil)
                } catch is CancellationError {
                    return SaveOutcome(macID: write.macID, confirmed: nil, failure: nil)
                } catch {
                    return SaveOutcome(macID: write.macID, confirmed: nil, failure: managementError(error))
                }
            }
        }
        Task {
            defer { saving = nil }
            var failed: [String] = []
            for request in requests {
                let outcome = await request.value
                guard let index = macs.firstIndex(where: { $0.id == outcome.macID }) else { continue }
                if let confirmed = outcome.confirmed {
                    macs[index] = .init(id: outcome.macID, name: macs[index].name, models: macs[index].models, stored: confirmed)
                } else {
                    if let old = previous.first(where: { $0.id == outcome.macID }) { macs[index] = old }
                    if let failure = outcome.failure { failed.append("\(macs[index].name): \(failure)") }
                }
            }
            saveFailures[family] = failed.isEmpty ? nil : failed
        }
    }

    private func replace(_ id: String, with entry: DefaultModelPreferences.Entry, in macs: inout [AppDefaultModels.Mac]) {
        guard let index = macs.firstIndex(where: { $0.id == id }) else { return }
        var stored = macs[index].stored
        stored.families = stored.families.filter { $0.family != entry.family } + [entry]
        macs[index] = .init(id: id, name: macs[index].name, models: macs[index].models, stored: stored)
    }
}

/// The default model, reasoning effort and speed for each harness, for the whole
/// app. Each Mac keeps them and applies them to its model list, so New Chat and
/// the composer follow without a rule of their own. A choice is saved to every
/// paired Mac that offers the model.
struct AppDefaultModelsView: View {
    @ObservedObject var library: ConnectionLibrary
    @StateObject private var state = AppDefaultModelsModel()

    var body: some View {
        Form {
            if !state.loadFailures.isEmpty {
                Section {
                    ForEach(state.loadFailures, id: \.name) { failure in
                        Text(state.macs.isEmpty && state.loadFailures.count == 1
                             ? failure.message : "\(failure.name): \(failure.message)")
                            .foregroundStyle(.secondary)
                    }
                    Button("Try again") { Task { await state.load(library: library) } }
                        .disabled(state.loading)
                        .accessibilityIdentifier("default-models-retry")
                }
            }
            if !state.macs.isEmpty {
                ForEach(AgentFamily.allCases) { family in
                    familySection(AppDefaultModels(family: family, macs: state.macs))
                }
            } else if state.loading || !state.loaded {
                Section { ProgressView("Loading models…") }
            } else if state.loadFailures.isEmpty {
                Section { Text("Pair a computer to choose default models.").foregroundStyle(.secondary) }
            }
        }
        .wonderGroupedStyle()
        .navigationTitle("Default models")
        .navigationBarTitleDisplayMode(.inline)
        .task { await state.load(library: library) }
    }

    @ViewBuilder private func familySection(_ defaults: AppDefaultModels) -> some View {
        let family = defaults.family
        let options = defaults.options
        let selected = defaults.selected
        Section {
            if options.isEmpty {
                Text(state.macs.count == 1 ? "\(family.title) has no models available on this computer."
                     : "\(family.title) has no models available on your computers.").foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: Binding(
                    get: { selected.model ?? "" },
                    set: { state.apply(defaults.writes(choosing: $0.isEmpty ? nil : $0), family: family) }
                )) {
                    Text("Wonder’s default").tag("")
                    ForEach(options) { option in
                        Text(option.partial ? "\(option.displayName) (only on \(option.macNames.joined(separator: ", ")))" : option.displayName)
                            .tag(option.id)
                    }
                }
                .accessibilityIdentifier("default-model-\(family.rawValue)")
                if !defaults.efforts.isEmpty {
                    Picker("Reasoning effort", selection: Binding(
                        get: { selected.effort ?? "" },
                        set: { state.apply(defaults.writes(choosingEffort: $0.isEmpty ? nil : $0), family: family) }
                    )) {
                        Text("Model default").tag("")
                        ForEach(defaults.efforts) { Text(ModelDefaults.title(of: $0)).tag($0.id) }
                    }
                    .accessibilityIdentifier("default-effort-\(family.rawValue)")
                }
                if defaults.speeds.count > 1 {
                    Picker("Speed", selection: Binding(
                        get: { selected.serviceTier ?? "" },
                        set: { state.apply(defaults.writes(choosingSpeed: $0.isEmpty ? nil : $0), family: family) }
                    )) {
                        Text("Model default").tag("")
                        ForEach(defaults.speeds) { Text($0.label).tag($0.id) }
                    }
                    .accessibilityIdentifier("default-speed-\(family.rawValue)")
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text(family.title)
                if state.saving == family { ProgressView().controlSize(.small) }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if !defaults.computersWithoutSelection.isEmpty {
                    Text("Not offered on \(defaults.computersWithoutSelection.joined(separator: ", ")), which keeps its own default.")
                } else if defaults.differsBetweenComputers {
                    Text("Your computers have different defaults. Choosing one here sets it on each computer that offers it.")
                }
                ForEach(state.saveFailures[family] ?? [], id: \.self) { Text($0).foregroundStyle(.red) }
            }
        }
        .disabled(state.saving == family)
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
            .wonderGroupedStyle()
            .navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $files) { WorkspaceSheet(close: { files = false }) { WorkspaceBrowser(model: model, chat: chat, attachmentIDs: nil) } }
        }
    }
}
