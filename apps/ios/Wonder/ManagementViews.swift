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
