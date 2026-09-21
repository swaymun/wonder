import SwiftUI
import WonderPairing

private struct EmptyReply: Decodable, Sendable {}
func managementError(_ error: Error) -> String {
    if let error = error as? NewBotDefaults.SelectionError { return error.localizedDescription }
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
private func readableDate(_ value: String?) -> String {
    guard let value else { return "—" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    return date?.formatted(date: .abbreviated, time: .shortened) ?? value
}
extension ConnectionModel {
    func manage<T: Decodable & Sendable>(_ path: String, method: String = "GET", values: [String: String]? = nil,
                                          body: Data? = nil, decodingStatuses: Set<Int> = []) async throws -> T {
        guard let saved = connection, !accessEnded else { throw PairingFailure.response(401) }
        #if WONDER_DIAGNOSTICS
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        var diagnosticSucceeded = false
        let diagnosticOperation: String?
        if method == "POST", path == "/api/v1/bots/new" || path == "/api/v1/bots" { diagnosticOperation = "bot.create" }
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
    let onChange: (BotApprovalMode) -> Void
    let label: () -> LabelContent

    init(
        selection: Binding<BotApprovalMode>,
        options: [BotOptions.ApprovalMode]?,
        isDisabled: Bool = false,
        onChange: @escaping (BotApprovalMode) -> Void,
        @ViewBuilder label: @escaping () -> LabelContent
    ) {
        _selection = selection
        self.options = options
        self.isDisabled = isDisabled
        self.onChange = onChange
        self.label = label
    }

    var body: some View {
        Menu {
            ForEach(BotApprovalMode.allCases) { mode in
                Button {
                    selection = mode
                    onChange(mode)
                } label: {
                    Text(mode.title)
                    Text(mode.description)
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

struct ConversationDetails: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    @Environment(\.dismiss) private var dismiss
    @State private var bot: ManagedBot?
    @State private var failure: String?
    @State private var files = false
    @State private var members = false
    @State private var computer = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) { ChatAvatar(name: chat.title, identity: chat.botId ?? chat.id, hexColor: bot?.avatarColor, avatarShape: bot?.avatarShape, avatarPalette: bot?.avatarPalette); Text(chat.title).font(.headline) }
                    if chat.botId != nil {
                        if let bot { NavigationLink("Bot settings") { BotEditor(model: model, bot: bot) { _ in dismiss() } } }
                        else if failure == nil { ProgressView("Loading settings…") }
                    } else { Button("Group settings") { members = true } }
                }
                Section {
                    if let group = model.groups[chat.id] { NavigationLink { AssignmentListView(model: model, group: group) } label: { Label("Assignments", systemImage: "checklist") } }
                    Button("View computer", systemImage: "desktopcomputer") { computer = true }
                    Button("Files", systemImage: "doc") { files = true }
                    NavigationLink { AutomationListView(model: model, chat: chat) } label: { Label("Automations", systemImage: "clock") }
                }
                if let failure { Section { FailureDetails(message: failure); Button("Try again") { Task { await load() } } } }
            }
            .navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .sheet(isPresented: $files) { WorkspaceBrowser(model: model, chat: chat, attachmentIDs: nil) }
            .sheet(isPresented: $members) { GroupEditor(model: model, group: model.groups[chat.id]) }
            .fullScreenCover(isPresented: $computer) {
                NavigationStack { ComputerSessionView(model: model, chat: chat) }
            }
        }
    }
    private func load() async {
        guard let id = chat.botId else { return }
        do { let bots: [ManagedBot] = try await model.manage("/api/v1/bots"); bot = bots.first { $0.id == id }; failure = bot == nil ? "This Bot is no longer available." : nil }
        catch { failure = managementError(error) }
    }
}

struct TeachingPollingKey: Hashable {
    let sessionID: String?
    let state: String?
    let interrupted: Bool
}

@MainActor
final class TeachingSessionModel: ObservableObject {
    let model: ConnectionModel
    let botID: String
    let botName: String
    let conversationID: String
    weak var computer: ComputerSessionModel?
    private let controlBindingIsActive: (() -> Bool)?
    private let originScope: String
    private struct PendingStart {
        let request: StartTeachingSessionRequest
        let body: Data
    }
    private var pendingStart: PendingStart?
    private var cancelling = false
    private var controlReleaseRequested = false
    private var reviewedDraft: (sessionID: String, revision: UInt64, fields: [String])?
    @Published private(set) var isStarting = false
    var hasReviewDraft: Bool { session.map { ["reviewing", "skillDraft"].contains($0.state) } == true }
    var hasCaptureToResolve: Bool { isStarting || startRequestID != nil || session?.state == "recording" }
    private let fallbackComputerSessionID: String?
    var computerSessionID: String? { session?.computerSessionId ?? pendingStart?.request.computerSessionId ?? computer?.session?.id ?? fallbackComputerSessionID }
    private let fallbackControlLeaseID: String?
    var controlLeaseID: String? { session?.controlLeaseId ?? pendingStart?.request.controlLeaseId ?? computer?.controlLease?.id ?? fallbackControlLeaseID }
    @Published var response: BotSkillListResponse?
    @Published var session: TeachingSession?
    @Published var outcome: String
    @Published var draftName: String
    @Published var draftDescription: String
    @Published var draftGoal: String
    @Published var draftInputSchema: String
    @Published var draftPrerequisites: String
    @Published var draftSteps: String
    @Published var draftResultChecks: String
    @Published var recordingStartedAt = Date()
    @Published var startRequestID: String?
    @Published var saveRequestID: String?
    @Published var saveRequestFingerprint: String?
    @Published var busy = false
    @Published var failure: String?
    @Published private(set) var interrupted = false
    var isRecording: Bool { session?.state == "recording" && !interrupted }
    private var draftFields: [String] {
        [draftName, draftDescription, draftGoal, draftInputSchema, draftPrerequisites, draftSteps, draftResultChecks]
    }
    var hasReviewedCurrentDraft: Bool {
        guard let session, let reviewedDraft else { return false }
        return session.state == "skillDraft" && session.id == reviewedDraft.sessionID
            && session.revision == reviewedDraft.revision && reviewedDraft.fields == draftFields
    }

    init(model: ConnectionModel, botID: String, botName: String, conversationID: String,
         computer: ComputerSessionModel? = nil, computerSessionID: String? = nil,
         controlLeaseID: String? = nil, controlBindingIsActive: (() -> Bool)? = nil) {
        self.model = model
        self.originScope = model.assignmentScope
        self.controlBindingIsActive = controlBindingIsActive
        self.botID = botID
        self.botName = botName
        self.conversationID = conversationID
        self.computer = computer
        self.fallbackComputerSessionID = computerSessionID
        self.fallbackControlLeaseID = controlLeaseID
        outcome = Self.diagnosticsAvailableFixtureOutcome
        draftName = ""
        draftDescription = "Describe the task captured from the paired Mac."
        draftGoal = ""
        draftInputSchema = "{}"
        draftPrerequisites = "Confirm the intended app is open on the paired Mac."
        draftSteps = "Review the accepted actions and complete the task."
        draftResultChecks = "Confirm the intended result is visible on the Mac."
    }

    private static var diagnosticsAvailableFixtureOutcome: String {
        #if WONDER_DIAGNOSTICS
        if ProcessInfo.processInfo.arguments.contains("-diagnostics-teaching-flow-fixture")
            || ProcessInfo.processInfo.arguments.contains("-diagnostics-computer-session-available-fixture") {
            return "Create a preview file"
        }
        #endif
        return ""
    }

    var isFixture: Bool {
        #if WONDER_DIAGNOSTICS
        ProcessInfo.processInfo.arguments.contains("-diagnostics-teaching-fixture")
            || ProcessInfo.processInfo.arguments.contains("-diagnostics-teaching-flow-fixture")
            || ProcessInfo.processInfo.arguments.contains("-diagnostics-computer-session-fixture")
        #else
        false
        #endif
    }

    var isAvailableFixture: Bool {
        #if WONDER_DIAGNOSTICS
        ProcessInfo.processInfo.arguments.contains("-diagnostics-teaching-flow-fixture")
            || ProcessInfo.processInfo.arguments.contains("-diagnostics-computer-session-available-fixture")
        #else
        false
        #endif
    }

    var capability: TeachingCapability { response?.capability ?? .unavailable }

    // The computer viewer owns this model and its recording controls; closing
    // setup or review does not destroy an in-flight request or active capture.
    var dismissalLocked: Bool { false }

    var teachingPollingKey: TeachingPollingKey {
        TeachingPollingKey(sessionID: session?.id, state: session?.state, interrupted: interrupted)
    }

    var hasCurrentControlBinding: Bool {
        guard originScope == model.assignmentScope, !model.accessEnded else { return false }
        if let controlBindingIsActive { return controlBindingIsActive() }
        if let computer {
            guard let current = computer.session,
                  let lease = computer.controlLease,
                  let computerSessionID,
                  let controlLeaseID else { return false }
            return computer.isControlActive
                && current.id == computerSessionID
                && lease.id == controlLeaseID
                && current.conversationId == conversationID
        }
        return isAvailableFixture && computerSessionID != nil && controlLeaseID != nil
    }

    func load() async {
        guard originScope == model.assignmentScope, !model.accessEnded, !busy else { return }
        if isFixture || model.previewMode {
            response = isAvailableFixture ? Self.availableFixture : Self.oldHost
            failure = nil
            return
        }
        busy = true
        defer { busy = false }
        do {
            response = try await model.manage("/api/v1/bots/\(ConnectionModel.escape(botID))/skills")
            failure = nil
        } catch {
            if case PairingFailure.response(404) = error {
                response = Self.oldHost
                failure = nil
            } else { failure = managementError(error) }
        }
    }

    func start() async {
        guard !busy, !interrupted, capability.available, session == nil else { return }
        guard hasCurrentControlBinding, let computerSessionID, let controlLeaseID else {
            failure = "Take control is required for this live computer view."
            return
        }
        let normalizedOutcome = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOutcome.isEmpty, normalizedOutcome.utf8.count <= 2000 else {
            failure = "Describe the task in up to 2,000 bytes before starting."
            return
        }
        busy = true
        isStarting = true
        failure = nil
        defer { busy = false; isStarting = false }
        if isAvailableFixture {
            recordingStartedAt = Date()
            session = Self.recordingFixture
            return
        }
        do {
            if pendingStart == nil {
                let requestID = UUID().uuidString.lowercased()
                let request = StartTeachingSessionRequest(clientRequestId: requestID,
                    conversationId: conversationID, computerSessionId: computerSessionID,
                    controlLeaseId: controlLeaseID, captureScope: "authenticated-remote-control", outcome: normalizedOutcome)
                pendingStart = PendingStart(request: request, body: try JSONEncoder().encode(request))
                startRequestID = requestID
            }
            guard let pendingStart else { return }
            let received: TeachingSession = try await model.manage(
                "/api/v1/bots/\(ConnectionModel.escape(botID))/teaching/sessions",
                method: "POST", body: pendingStart.body)
            guard belongs(received), received.clientRequestId == pendingStart.request.clientRequestId else {
                throw PairingFailure.wrongHost
            }
            // A late success still owns a real Mac capture. Retain its exact
            // session and cancel it instead of dropping the response or restarting.
            if Task.isCancelled || !hasCurrentControlBinding { interrupted = true }
            self.pendingStart = nil
            startRequestID = nil
            session = received
            recordInterruptionIfNeeded(received)
            recordingStartedAt = Date()
            if interrupted {
                await cancelCurrentSession()
            } else if received.state != "recording" { seedDraft(received) }
        } catch {
            if case PairingFailure.response(let code) = error, [400, 403, 404, 422].contains(code) {
                pendingStart = nil
                startRequestID = nil
            }
            if Task.isCancelled { interrupted = true }
            failure = interrupted
                ? "Teaching was interrupted. The Mac has not confirmed the final capture state. Reconnect to check its state."
                : "Starting was not confirmed. Check the same request before starting again."
            if interrupted { await computer?.done() }
        }
    }

    private func belongs(_ value: TeachingSession) -> Bool {
        originScope == model.assignmentScope && value.botId == botID && value.conversationId == conversationID
            && value.computerSessionId == computerSessionID && value.controlLeaseId == controlLeaseID
    }

    @discardableResult private func accept(_ updated: TeachingSession, replacing current: TeachingSession) -> Bool {
        guard belongs(updated), updated.id == current.id, session?.id == current.id,
              updated.revision >= (session?.revision ?? current.revision) else { return false }
        let wasRecording = session?.state == "recording"
        session = updated
        recordInterruptionIfNeeded(updated)
        if wasRecording && ["reviewing", "skillDraft"].contains(updated.state) { seedDraft(updated) }
        return true
    }

    private func recordInterruptionIfNeeded(_ value: TeachingSession) {
        if value.state == "interrupted" || value.state == "expired" {
            interrupted = true
            failure = value.failureReason ?? (value.state == "expired"
                ? "Teaching reached its capture limit. Review its status before starting another task."
                : "Teaching was interrupted on your Mac.")
        }
    }

    func readSession() async {
        guard let current = session, !isFixture, originScope == model.assignmentScope else { return }
        do {
            let updated: TeachingSession = try await model.manage(
                "/api/v1/bots/\(ConnectionModel.escape(botID))/teaching/sessions/\(ConnectionModel.escape(current.id))")
            guard accept(updated, replacing: current) else { return }
            if interrupted, updated.state == "recording" { await cancelCurrentSession() }
            else if !interrupted { failure = nil }
        } catch { failure = "The Mac has not confirmed this teaching session. Reconnect to check its state." }
    }

    func stop() async {
        guard originScope == model.assignmentScope, !model.accessEnded, !busy else { return }
        guard let current = session, current.state == "recording" else { return }
        busy = true
        defer { busy = false }
        if isAvailableFixture {
            session = Self.reviewingFixture
            seedDraft(Self.reviewingFixture)
            return
        }
        await computer?.awaitInputIdle()
        if interrupted { await cancelCurrentSession(); return }
        do {
            let updated: TeachingSession
            do { updated = try await stopRequest(current) }
            catch PairingFailure.response(409) {
                // Accepted inputs advance the capture revision between polls.
                // Retry only a definite conflict, for this exact session, once.
                let latest: TeachingSession = try await model.manage(
                    "/api/v1/bots/\(ConnectionModel.escape(botID))/teaching/sessions/\(ConnectionModel.escape(current.id))")
                guard accept(latest, replacing: current) else { throw PairingFailure.wrongHost }
                guard latest.state == "recording" else { return }
                if interrupted { await cancelCurrentSession(); return }
                updated = try await stopRequest(latest)
            }
            if accept(updated, replacing: current), !interrupted { failure = nil }
        } catch {
            await readSession()
            if session?.state == "recording", !interrupted {
                failure = "Stopping was not confirmed. Check the session before trying again."
            }
        }
    }

    private func stopRequest(_ current: TeachingSession) async throws -> TeachingSession {
        try await model.manage(
            "/api/v1/bots/\(ConnectionModel.escape(botID))/teaching/sessions/\(ConnectionModel.escape(current.id))/stop",
            method: "POST",
            body: JSONEncoder().encode(TeachingRevisionRequest(expectedRevision: current.revision)))
    }

    func cancel() async {
        // Cancel remains available while Start is waiting for its receipt.
        if isStarting || (session == nil && pendingStart != nil) {
            interrupted = true
            failure = "Teaching was cancelled before its start was confirmed."
            await computer?.done()
            return
        }
        guard !busy, session != nil else { return }
        busy = true
        defer { busy = false }
        await cancelCurrentSession()
    }

    private func cancelCurrentSession() async {
        guard originScope == model.assignmentScope, !model.accessEnded, !cancelling, let current = session,
              ["recording", "reviewing", "skillDraft", "interrupted"].contains(current.state) else { return }
        cancelling = true
        defer { cancelling = false }
        if isAvailableFixture {
            session = Self.cancelledFixture
            return
        }
        do {
            // Cancellation is bound to the exact session. Omitting the optional
            // revision makes it safe when newly accepted inputs advanced it.
            let updated: TeachingSession = try await model.manage(
                "/api/v1/bots/\(ConnectionModel.escape(botID))/teaching/sessions/\(ConnectionModel.escape(current.id))/cancel",
                method: "POST", body: try JSONEncoder().encode(TeachingRevisionRequest(expectedRevision: nil)))
            if accept(updated, replacing: current), !interrupted { failure = nil }
        } catch {
            interrupted = true
            failure = "Cancellation was not confirmed. Reconnect to check the session."
            await computer?.done()
        }
    }

    func retry() async {
        if interrupted {
            if session != nil { await readSession(); await cancelCurrentSession() }
            else { await computer?.done() }
        } else if pendingStart != nil { await start() }
        else if session != nil { await readSession() }
        else { await load() }
    }

    func review() async {
        guard originScope == model.assignmentScope, !model.accessEnded, !busy else { return }
        guard let current = session, ["reviewing", "skillDraft"].contains(current.state) else { return }
        guard let inputSchema = try? JSONDecoder().decode([String: TeachingJSONValue].self, from: Data(draftInputSchema.utf8)) else {
            failure = "Inputs must be a JSON object."
            return
        }
        let submittedDraft = draftFields
        busy = true
        defer { busy = false }
        if isAvailableFixture {
            session = Self.skillDraftFixture
            reviewedDraft = (Self.skillDraftFixture.id, Self.skillDraftFixture.revision, submittedDraft)
            failure = nil
            return
        }
        do {
            let updated: TeachingSession = try await model.manage(
                "/api/v1/bots/\(ConnectionModel.escape(botID))/teaching/sessions/\(ConnectionModel.escape(current.id))/review",
                method: "POST",
                body: try JSONEncoder().encode(ReviewTeachingSessionRequest(
                    expectedRevision: current.revision, name: draftName, description: draftDescription,
                    goal: draftGoal, inputSchema: inputSchema, prerequisites: draftPrerequisites,
                    steps: draftSteps, resultChecks: draftResultChecks
                ))
            )
            if accept(updated, replacing: current) {
                reviewedDraft = (updated.id, updated.revision, submittedDraft)
                failure = nil
            }
        } catch { failure = managementError(error) }
    }

    func save() async {
        guard originScope == model.assignmentScope, !model.accessEnded, !busy else { return }
        guard let current = session, current.state == "skillDraft" else { return }
        guard hasReviewedCurrentDraft else {
            failure = "Review your latest changes before saving."
            return
        }
        busy = true
        defer { busy = false }
        if isAvailableFixture {
            session = Self.approvedFixture
            response = Self.savedFixture
            return
        }
        do {
            let fingerprint = "\(current.id)\u{0}\(current.revision)"
            if saveRequestFingerprint != fingerprint {
                saveRequestID = UUID().uuidString.lowercased()
                saveRequestFingerprint = fingerprint
            }
            let requestID = saveRequestID ?? UUID().uuidString.lowercased()
            saveRequestID = requestID
            let request = SaveBotSkillVersionRequest(
                clientRequestId: requestID, expectedRevision: current.revision, slug: nil
            )
            let saved: SaveBotSkillVersionResponse = try await model.manage(
                "/api/v1/bots/\(ConnectionModel.escape(botID))/teaching/sessions/\(ConnectionModel.escape(current.id))/save-version",
                method: "POST", body: try JSONEncoder().encode(request)
            )
            saveRequestID = nil
            saveRequestFingerprint = nil
            guard accept(saved.teachingSession, replacing: current) else { return }
            response = BotSkillListResponse(capability: capability,
                skills: (response?.skills ?? []).filter { $0.id != saved.skill.id } + [saved.skill])
            failure = nil
        } catch { failure = managementError(error) }
    }

    func seedDraft(_ session: TeachingSession) {
        draftName = session.name ?? String(outcome.prefix(120))
        draftDescription = session.description ?? draftDescription
        draftGoal = session.goal ?? session.outcome
        if let schema = session.inputSchema,
           let data = try? JSONEncoder().encode(schema),
           let value = String(data: data, encoding: .utf8) { draftInputSchema = value }
        draftPrerequisites = session.prerequisites ?? draftPrerequisites
        draftSteps = session.steps ?? draftSteps
        draftResultChecks = session.resultChecks ?? draftResultChecks
    }

    func poll() async {
        let id = session?.id
        guard !isFixture, session?.state == "recording" else { return }
        while !Task.isCancelled, session?.id == id, session?.state == "recording" {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            await readSession()
        }
    }

    var canStartAnotherTask: Bool {
        !busy && !hasCaptureToResolve && session.map { ["cancelled", "expired", "interrupted", "approvedVersion"].contains($0.state) } == true
    }

    func startAnotherTask() {
        guard canStartAnotherTask else { return }
        session = nil
        reviewedDraft = nil
        interrupted = false
        controlReleaseRequested = false
        failure = nil
        outcome = ""
        draftName = ""
        draftDescription = "Describe the task captured from the paired Mac."
        draftGoal = ""
        draftInputSchema = "{}"
        draftPrerequisites = "Confirm the intended app is open on the paired Mac."
        draftSteps = "Review the accepted actions and complete the task."
        draftResultChecks = "Confirm the intended result is visible on the Mac."
        saveRequestID = nil
        saveRequestFingerprint = nil
    }

    func markControlEnded() {
        guard hasCaptureToResolve else { return }
        if !interrupted { failure = "Teaching was interrupted when computer control ended." }
        interrupted = true
    }

    func controlEnded() async {
        guard hasCaptureToResolve else { return }
        markControlEnded()
        // Release also fences an unknown Start at the host's control lease.
        if !controlReleaseRequested {
            controlReleaseRequested = true
            await computer?.done()
        }
        if session != nil, !busy { await cancelCurrentSession() }
    }

    private static let oldHost: BotSkillListResponse = decodeFixture(#"{"capability":{"available":false,"action":"update-host","reason":"Teaching requires a newer Wonder host. Update Wonder on your Mac, then try again.","provider":"none","maxDurationSeconds":600,"maxEvents":20000,"maxEvidenceBytes":52428800},"skills":[{"id":"fixture-private-skill","botId":"fixture-bot","slug":"preview-file","name":"Preview file","description":"Create a preview file from reviewed inputs.","state":"active","activeVersion":1,"discoverability":"bot-private","versions":[{"id":"fixture-version","version":1,"sourceSessionId":"fixture-session","contentHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","inputSchema":{"date":{"format":"date","type":"string"},"title":{"type":"string"}},"verificationState":"structurallyVerified","createdAt":"2026-09-12T00:00:00Z"}]}]}"#)
    private static let availableFixture: BotSkillListResponse = decodeFixture(#"{"capability":{"available":true,"action":"none","reason":"Teaching records accepted computer actions from this paired Mac.","provider":"authenticated-remote-control-v1","maxDurationSeconds":600,"maxEvents":20000,"maxEvidenceBytes":52428800},"skills":[]}"#)
    private static let savedFixture: BotSkillListResponse = decodeFixture(#"{"capability":{"available":true,"action":"none","reason":"Teaching records accepted computer actions from this paired Mac.","provider":"authenticated-remote-control-v1","maxDurationSeconds":600,"maxEvents":20000,"maxEvidenceBytes":52428800},"skills":[{"id":"fixture-saved-skill","botId":"fixture-bot","slug":"preview-file","name":"Preview file","description":"Create a private preview file.","state":"active","activeVersion":1,"discoverability":"bot-private","versions":[{"id":"fixture-version","version":1,"sourceSessionId":"fixture-teaching-session","contentHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","inputSchema":{"title":{"type":"string"}},"verificationState":"unverified","createdAt":"2026-09-12T00:00:02Z"}]}]}"#)
    private static let recordingFixture: TeachingSession = decodeSession(#"{"id":"fixture-teaching-session","clientRequestId":"fixture-teaching-request","ownerDeviceId":"fixture-device","hostInstallationId":"fixture-host","botId":"fixture-bot","conversationId":"computer-fixture","computerSessionId":"fixture-computer-session","controlLeaseId":"fixture-control-lease","state":"recording","captureScope":"authenticated-remote-control","captureProvider":"authenticated-remote-control-v1","outcome":"Create a preview file","name":null,"description":null,"goal":null,"inputSchema":null,"prerequisites":null,"steps":null,"resultChecks":null,"failureReason":null,"revision":1,"eventCount":0,"evidenceBytes":0,"contentHash":null,"createdAt":"2026-09-12T00:00:00Z","updatedAt":"2026-09-12T00:00:00Z","startedAt":"2026-09-12T00:00:00Z","endedAt":null,"expiresAt":"2099-01-01T00:00:00Z","events":[],"capability":{"available":true,"action":"none","reason":"Teaching records accepted computer actions from this paired Mac.","provider":"authenticated-remote-control-v1","maxDurationSeconds":600,"maxEvents":20000,"maxEvidenceBytes":52428800}}"#)
    private static let reviewingFixture: TeachingSession = decodeSession(#"{"id":"fixture-teaching-session","clientRequestId":"fixture-teaching-request","ownerDeviceId":"fixture-device","hostInstallationId":"fixture-host","botId":"fixture-bot","conversationId":"computer-fixture","computerSessionId":"fixture-computer-session","controlLeaseId":"fixture-control-lease","state":"reviewing","captureScope":"authenticated-remote-control","captureProvider":"authenticated-remote-control-v1","outcome":"Create a preview file","name":null,"description":null,"goal":null,"inputSchema":null,"prerequisites":null,"steps":null,"resultChecks":null,"failureReason":null,"revision":2,"eventCount":4,"evidenceBytes":256,"contentHash":null,"createdAt":"2026-09-12T00:00:00Z","updatedAt":"2026-09-12T00:00:02Z","startedAt":"2026-09-12T00:00:00Z","endedAt":"2026-09-12T00:00:02Z","expiresAt":"2099-01-01T00:00:00Z","events":[{"sequence":1,"actionIndex":0,"kind":"pointer","payload":{"kind":"pointer","x":0.35,"y":0.42,"phase":"down","button":"left"},"createdAt":"2026-09-12T00:00:01Z"},{"sequence":1,"actionIndex":1,"kind":"pointer","payload":{"kind":"pointer","x":0.35,"y":0.42,"phase":"up","button":"left"},"createdAt":"2026-09-12T00:00:01Z"},{"sequence":2,"actionIndex":0,"kind":"text","payload":{"kind":"text","characterCount":12,"redacted":true},"createdAt":"2026-09-12T00:00:02Z"}],"capability":{"available":true,"action":"none","reason":"Teaching records accepted computer actions from this paired Mac.","provider":"authenticated-remote-control-v1","maxDurationSeconds":600,"maxEvents":20000,"maxEvidenceBytes":52428800}}"#)
    private static let skillDraftFixture: TeachingSession = decodeSession(#"{"id":"fixture-teaching-session","clientRequestId":"fixture-teaching-request","ownerDeviceId":"fixture-device","hostInstallationId":"fixture-host","botId":"fixture-bot","conversationId":"computer-fixture","computerSessionId":"fixture-computer-session","controlLeaseId":"fixture-control-lease","state":"skillDraft","captureScope":"authenticated-remote-control","captureProvider":"authenticated-remote-control-v1","outcome":"Create a preview file","name":"Preview file","description":"Create a private preview file.","goal":"Create the preview.","inputSchema":{"title":{"type":"string"}},"prerequisites":"The intended app is open.","steps":"Review the captured actions.","resultChecks":"The preview exists.","failureReason":null,"revision":3,"eventCount":3,"evidenceBytes":256,"contentHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","createdAt":"2026-09-12T00:00:00Z","updatedAt":"2026-09-12T00:00:03Z","startedAt":"2026-09-12T00:00:00Z","endedAt":"2026-09-12T00:00:02Z","expiresAt":"2099-01-01T00:00:00Z","events":[{"sequence":1,"actionIndex":0,"kind":"pointer","payload":{"kind":"pointer","x":0.35,"y":0.42,"phase":"down","button":"left"},"createdAt":"2026-09-12T00:00:01Z"},{"sequence":1,"actionIndex":1,"kind":"pointer","payload":{"kind":"pointer","x":0.35,"y":0.42,"phase":"up","button":"left"},"createdAt":"2026-09-12T00:00:01Z"},{"sequence":2,"actionIndex":0,"kind":"text","payload":{"kind":"text","characterCount":12,"redacted":true},"createdAt":"2026-09-12T00:00:02Z"}],"capability":{"available":true,"action":"none","reason":"Teaching records accepted computer actions from this paired Mac.","provider":"authenticated-remote-control-v1","maxDurationSeconds":600,"maxEvents":20000,"maxEvidenceBytes":52428800}}"#)
    private static let approvedFixture: TeachingSession = decodeSession(#"{"id":"fixture-teaching-session","clientRequestId":"fixture-teaching-request","ownerDeviceId":"fixture-device","hostInstallationId":"fixture-host","botId":"fixture-bot","conversationId":"computer-fixture","computerSessionId":"fixture-computer-session","controlLeaseId":"fixture-control-lease","state":"approvedVersion","captureScope":"authenticated-remote-control","captureProvider":"authenticated-remote-control-v1","outcome":"Create a preview file","name":"Preview file","description":"Create a private preview file.","goal":"Create the preview.","inputSchema":{"title":{"type":"string"}},"prerequisites":"The intended app is open.","steps":"Review the captured actions.","resultChecks":"The preview exists.","failureReason":null,"revision":4,"eventCount":3,"evidenceBytes":256,"contentHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","createdAt":"2026-09-12T00:00:00Z","updatedAt":"2026-09-12T00:00:04Z","startedAt":"2026-09-12T00:00:00Z","endedAt":"2026-09-12T00:00:02Z","expiresAt":"2099-01-01T00:00:00Z","events":[{"sequence":1,"actionIndex":0,"kind":"pointer","payload":{"kind":"pointer","x":0.35,"y":0.42,"phase":"down","button":"left"},"createdAt":"2026-09-12T00:00:01Z"},{"sequence":1,"actionIndex":1,"kind":"pointer","payload":{"kind":"pointer","x":0.35,"y":0.42,"phase":"up","button":"left"},"createdAt":"2026-09-12T00:00:01Z"},{"sequence":2,"actionIndex":0,"kind":"text","payload":{"kind":"text","characterCount":12,"redacted":true},"createdAt":"2026-09-12T00:00:02Z"}],"capability":{"available":true,"action":"none","reason":"Teaching records accepted computer actions from this paired Mac.","provider":"authenticated-remote-control-v1","maxDurationSeconds":600,"maxEvents":20000,"maxEvidenceBytes":52428800}}"#)
    private static let cancelledFixture: TeachingSession = decodeSession(#"{"id":"fixture-teaching-session","clientRequestId":"fixture-teaching-request","ownerDeviceId":"fixture-device","hostInstallationId":"fixture-host","botId":"fixture-bot","conversationId":"computer-fixture","computerSessionId":"fixture-computer-session","controlLeaseId":"fixture-control-lease","state":"cancelled","captureScope":"authenticated-remote-control","captureProvider":"authenticated-remote-control-v1","outcome":"Create a preview file","name":null,"description":null,"goal":null,"inputSchema":null,"prerequisites":null,"steps":null,"resultChecks":null,"failureReason":null,"revision":2,"eventCount":0,"evidenceBytes":0,"contentHash":null,"createdAt":"2026-09-12T00:00:00Z","updatedAt":"2026-09-12T00:00:02Z","startedAt":"2026-09-12T00:00:00Z","endedAt":"2026-09-12T00:00:02Z","expiresAt":"2099-01-01T00:00:00Z","events":[],"capability":{"available":true,"action":"none","reason":"Teaching records accepted computer actions from this paired Mac.","provider":"authenticated-remote-control-v1","maxDurationSeconds":600,"maxEvents":20000,"maxEvidenceBytes":52428800}}"#)

    private static func decodeFixture(_ json: String) -> BotSkillListResponse { try! JSONDecoder().decode(BotSkillListResponse.self, from: Data(json.utf8)) }
    private static func decodeSession(_ json: String) -> TeachingSession { try! JSONDecoder().decode(TeachingSession.self, from: Data(json.utf8)) }
}

struct TeachingView: View {
    @StateObject private var teaching: TeachingSessionModel
    let showsDoneButton: Bool

    init(model: ConnectionModel, botID: String, botName: String, conversationID: String,
         computer: ComputerSessionModel? = nil, computerSessionID: String? = nil,
         controlLeaseID: String? = nil, showsDoneButton: Bool = false) {
        self.showsDoneButton = showsDoneButton
        _teaching = StateObject(wrappedValue: TeachingSessionModel(model: model, botID: botID,
            botName: botName, conversationID: conversationID, computer: computer,
            computerSessionID: computerSessionID, controlLeaseID: controlLeaseID))
    }

    var body: some View {
        TeachingSessionContent(teaching: teaching, showsDoneButton: showsDoneButton)
            .task(id: teaching.teachingPollingKey) { await teaching.poll() }
    }
}

struct TeachingSessionContent: View {
    @ObservedObject var teaching: TeachingSessionModel
    let showsDoneButton: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var eventsExpanded = false
    private var session: TeachingSession? { teaching.session }

    var body: some View {
        Form {
            Section {
                TextField("What should this task accomplish?", text: $teaching.outcome, axis: .vertical)
                    .lineLimit(2...5)
                    .disabled(teaching.session != nil || teaching.startRequestID != nil)
                    .accessibilityIdentifier("teaching-outcome")
                Button("Start teaching", systemImage: "record.circle") { Task { await teaching.start() } }
                    .disabled(teaching.busy || teaching.interrupted || session != nil || !teaching.capability.available || !teaching.hasCurrentControlBinding || teaching.outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("teaching-start")
                if teaching.isStarting {
                    ProgressView("Starting teaching…")
                    Button("Cancel start", role: .cancel) { Task { await teaching.cancel() } }
                        .disabled(false)
                        .accessibilityIdentifier("teaching-cancel-start")
                }
            } header: {
                Text("Teach \(teaching.botName)")
            } footer: {
                Text("Take control to record a task. Typed and clipboard content is redacted. Saving does not verify that the task can be replayed.")
            }

            if teaching.capability.available && !teaching.hasCurrentControlBinding && session == nil {
                Section {
                    Label("Take control is required", systemImage: "hand.raised")
                    Text("Enable paired-device control in Wonder Settings on your Mac, then take control for this live computer view.")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("teaching-control-required")
            }

            if !teaching.capability.available {
                Section {
                    Label("Teaching capture unavailable", systemImage: "record.circle")
                        .font(.headline)
                    Text(teaching.capability.reason).foregroundStyle(.secondary)
                    LabeledContent("Provider", value: teaching.capability.provider == "none" ? "Not configured" : teaching.capability.provider)
                }
                .accessibilityIdentifier("teaching-unavailable")
            }

            if let session {
                Section("Current session") {
                    LabeledContent("Status", value: teaching.interrupted ? "Interrupted" : status(session.state))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Status")
                        .accessibilityValue(teaching.interrupted ? "Interrupted" : status(session.state))
                        .accessibilityIdentifier("teaching-session-status")
                    Text(session.outcome)
                    if teaching.isRecording {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Recording · \(duration(from: teaching.recordingStartedAt, to: context.date)) · \(session.eventCount) actions")
                                .font(.headline)
                                .accessibilityIdentifier("teaching-recording-status")
                        }
                        Text("Only accepted pointer, scroll, and redacted input actions are captured. No screenshots or clipboard text.")
                            .font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Button("Stop teaching", systemImage: "stop.circle") { Task { await teaching.stop() } }
                                .accessibilityIdentifier("teaching-stop")
                            Button("Cancel", systemImage: "xmark.circle", role: .cancel) { Task { await teaching.cancel() } }
                                .accessibilityIdentifier("teaching-cancel")
                        }
                        .buttonStyle(.borderless)
                    } else if session.state == "reviewing" || session.state == "skillDraft" {
                        events(session)
                        reviewForm(session)
                    } else if session.state == "approvedVersion" {
                        Label("Saved privately", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                        Text("Saved is distinct from Replay verified. This demonstration has not been replay-verified.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let reason = session.failureReason { Text(reason).foregroundStyle(.secondary) }
                    if teaching.canStartAnotherTask {
                        Button("Start another task") { teaching.startAnotherTask() }
                            .accessibilityIdentifier("teaching-new-task")
                    }
                }
            }

            Section("Saved skills") {
                if let skills = teaching.response?.skills, !skills.isEmpty {
                    ForEach(skills) { skill in
                        NavigationLink { BotSkillDetailView(model: teaching.model, skill: skill) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(skill.name)
                                Text(skillStatus(skill)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("teaching-skill-\(skill.id)")
                    }
                } else if teaching.response != nil {
                    Text("No saved skills").foregroundStyle(.secondary)
                } else {
                    ProgressView("Loading skills…")
                }
            }

            if let failure = teaching.failure {
                Section {
                    FailureDetails("Teaching needs attention", message: failure)
                    Button("Check status") { Task { await teaching.retry() } }
                }
            }
        }
        .navigationTitle("Teach a task")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(teaching.busy && !teaching.isStarting)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(teaching.dismissalLocked)
                        .accessibilityIdentifier("teaching-done")
                }
            }
        }
        .interactiveDismissDisabled(teaching.dismissalLocked)
        .task { await teaching.load() }
        .accessibilityIdentifier("teaching-view")
    }

    @ViewBuilder private func events(_ session: TeachingSession) -> some View {
        DisclosureGroup(isExpanded: $eventsExpanded) {
            if session.events.isEmpty {
                Text(session.eventCount == 0
                     ? "No accepted actions were captured. Stop did not create a demonstration."
                     : "Captured action details could not be loaded.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.events) { event in
                    Label(eventSummary(event), systemImage: event.kind == "pointer" ? "cursorarrow.click" : "keyboard")
                        .font(.footnote)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(eventSummary(event))
                        .accessibilityIdentifier("teaching-event-\(event.id)")
                }
                if UInt64(session.events.count) < session.eventCount {
                    Text("Showing first \(session.events.count) of \(session.eventCount) actions")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Text("Captured actions · \(session.eventCount)")
        }
        .accessibilityValue(eventsExpanded ? "Expanded" : "Collapsed")
    }

    @ViewBuilder private func reviewForm(_ session: TeachingSession) -> some View {
        Group {
            Text("Review draft")
                .font(.headline)
            TextField("Name", text: $teaching.draftName).accessibilityIdentifier("teaching-draft-name")
            TextField("Description", text: $teaching.draftDescription, axis: .vertical).lineLimit(2...4)
            TextField("Goal", text: $teaching.draftGoal, axis: .vertical).lineLimit(2...4)
            TextField("Inputs JSON object", text: $teaching.draftInputSchema, axis: .vertical)
                .font(.body.monospaced()).lineLimit(2...6).accessibilityIdentifier("teaching-draft-inputs")
            TextField("Prerequisites", text: $teaching.draftPrerequisites, axis: .vertical).lineLimit(2...4)
            TextField("Steps", text: $teaching.draftSteps, axis: .vertical).lineLimit(3...7)
            TextField("Result checks", text: $teaching.draftResultChecks, axis: .vertical).lineLimit(2...5)
            Button("Review draft", systemImage: "checkmark.circle") { Task { await teaching.review() } }
                .disabled(teaching.busy || teaching.draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("teaching-review")
            if session.state == "skillDraft" {
                Button("Save private skill version", systemImage: "square.and.arrow.down") { Task { await teaching.save() } }
                    .disabled(teaching.busy || !teaching.hasReviewedCurrentDraft).accessibilityIdentifier("teaching-save")
            }
        }
    }

    private func eventSummary(_ event: TeachingEvent) -> String {
        switch event.kind {
        case "text": return "Text input redacted"
        case "clipboard": return "Clipboard action · content redacted"
        case "key": return "Key \((event.payload["key"].flatMap { if case .string(let value) = $0 { return value } else { return nil } }) ?? "redacted")"
        case "scroll": return "Scroll"
        default: return "Pointer action"
        }
    }

    private func status(_ state: String) -> String {
        switch state {
        case "recording": return "Recording on Mac"
        case "reviewing", "skillDraft": return "Ready to review"
        case "approvedVersion": return "Saved · Replay not verified"
        case "interrupted": return "Interrupted"
        case "cancelled": return "Cancelled"
        case "expired": return "Expired"
        default: return "Unavailable"
        }
    }

    private func skillStatus(_ skill: BotSkill) -> String {
        guard let version = skill.activeVersion else { return "Not active" }
        let verification = skill.versions?.first(where: { $0.version == version })?.verificationState
        if verification == "replayVerified" { return "Replay verified · Version \(version)" }
        if verification == "fixtureVerified" { return "Fixture tested · Version \(version)" }
        return "Saved · Version \(version) · Replay not verified"
    }

    private func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return "\(seconds / 60)m \(seconds % 60)s"
    }

}

private struct BotSkillDetailView: View {
    @ObservedObject var model: ConnectionModel
    let skill: BotSkill
    @State private var title = "Changed preview title"
    @State private var date = "2026-09-12"
    @State private var receipt: BotSkillFixtureTestReceipt?
    @State private var busy = false
    @State private var failure: String?

    private var isFixture: Bool {
        #if WONDER_DIAGNOSTICS
        ProcessInfo.processInfo.arguments.contains("-diagnostics-teaching-fixture")
        #else
        false
        #endif
    }

    var body: some View {
        List {
            Section {
                Text(skill.description)
                LabeledContent("Visibility", value: "This Bot only")
                LabeledContent("Active version", value: skill.activeVersion.map(String.init) ?? "None")
            }
            if let version = skill.versions?.first(where: { $0.version == skill.activeVersion }) {
                Section("Deterministic fixture") {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("teaching-fixture-title")
                    TextField("Date", text: $date)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("teaching-fixture-date")
                    Button("Test with fixture", systemImage: "checkmark.seal") {
                        Task { await runFixture(version) }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("teaching-fixture-run")
                    if let receipt {
                        if receipt.status == "succeeded" {
                            Label("Fixture tested · Version \(receipt.version) · \(readableDate(receipt.completedAt))", systemImage: "checkmark.seal.fill")
                                .accessibilityIdentifier("teaching-fixture-success")
                            Text("Preview artifact verified (\(receipt.artifactBytes) bytes). Real supervised replay remains unverified.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("Fixture test failed", systemImage: "xmark.octagon")
                            if let reason = receipt.failureReason { Text(reason).foregroundStyle(.secondary) }
                        }
                    }
                    if let failure { Text(failure).foregroundStyle(.secondary) }
                }
            }
            Section("Versions") {
                ForEach(skill.versions ?? []) { version in
                    LabeledContent("Version \(version.version)", value: versionStatus(version))
                }
            }
        }
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runFixture(_ version: BotSkillVersion) async {
        busy = true
        defer { busy = false }
        let inputs: [String: TeachingJSONValue] = [
            "title": .string(title),
            "date": .string(date)
        ]
        if isFixture {
            receipt = Self.fixtureReceipt
            failure = nil
            return
        }
        do {
            let request = BotSkillFixtureTestRequest(
                clientRequestId: UUID().uuidString.lowercased(),
                contentHash: version.contentHash,
                inputSchema: version.inputSchema,
                inputs: inputs
            )
            receipt = try await model.manage(
                "/api/v1/bots/\(ConnectionModel.escape(skill.botId))/skills/\(ConnectionModel.escape(skill.id))/versions/\(version.version)/fixture-tests",
                method: "POST",
                body: try JSONEncoder().encode(request)
            )
            failure = nil
        } catch {
            failure = managementError(error)
        }
    }

    private func versionStatus(_ version: BotSkillVersion) -> String {
        if receipt?.status == "succeeded", receipt?.version == version.version {
            return "Fixture tested"
        }
        if version.verificationState == "replayVerified" { return "Replay verified" }
        if version.verificationState == "fixtureVerified" { return "Fixture tested" }
        return "Replay not verified"
    }

    private static let fixtureReceipt: BotSkillFixtureTestReceipt = decodeFixture(#"{"id":"fixture-run","clientRequestId":"11111111-1111-4111-8111-111111111111","ownerDeviceId":"fixture-owner","botId":"fixture-bot","skillId":"fixture-private-skill","version":1,"contentHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","inputSchemaHash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","inputSchema":{"date":{"format":"date","type":"string"},"title":{"type":"string"}},"inputs":{"date":"2026-09-12","title":"Changed preview title"},"workingDirectory":"fixture-cwd","provider":"deterministic-local","executionKind":"deterministicFixture","status":"succeeded","verificationState":"fixtureVerified","artifactPath":".wonder/fixture-runs/fixture-bot/11111111-1111-4111-8111-111111111111/preview.json","artifactHash":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","artifactBytes":256,"evidence":{"kind":"deterministicFixture","verified":true,"checks":["title","date","artifact contents"]},"failureReason":null,"createdAt":"2026-09-12T00:00:00Z","completedAt":"2026-09-12T12:00:00Z"}"#)

    private static func decodeFixture(_ json: String) -> BotSkillFixtureTestReceipt {
        try! JSONDecoder().decode(BotSkillFixtureTestReceipt.self, from: Data(json.utf8))
    }
}

#if WONDER_DIAGNOSTICS
struct TeachingDiagnosticFixtureView: View {
    @StateObject private var model = ConnectionModel(saved: nil, persistConnection: { _ in })

    var body: some View {
        NavigationStack {
            TeachingView(
                model: model,
                botID: "fixture-bot",
                botName: "Orbit",
                conversationID: "fixture-chat",
                computerSessionID: ProcessInfo.processInfo.arguments.contains("-diagnostics-teaching-flow-fixture") ? "fixture-computer-session" : nil,
                controlLeaseID: ProcessInfo.processInfo.arguments.contains("-diagnostics-teaching-flow-fixture") ? "fixture-control-lease" : nil
            )
        }
    }
}
#endif

struct BotEditor: View {
    let model: ConnectionModel
    let bot: ManagedBot?
    var completed: (String?) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ManagementDraft()
    @State private var options: BotOptions?
    @State private var busy = false
    @State private var failure: String?
    @State private var showingSaveFailure = false
    @State private var loaded = false
    @State private var archive = false
    @State private var adding: FileAccessChoice?
    @State private var botWorkspacePath: String?
    private var key: String { "bot." + (bot?.id ?? "new") }
    private func field(_ key: String) -> Binding<String> { Binding(get: { draft.values[key] ?? "" }, set: { draft.values[key] = $0; if key == "model" { draft.values["reasoningEffort"] = "" }; if key == "approvalMode" { draft.values["_approvalChanged"] = "true" }; persist() }) }
    private func persist() { do { try model.managementDrafts?.save(draft, key: key) } catch { failure = "This draft could not be saved on this device." } }
    private var fileSelection: Binding<BotFileSelection> {
        Binding(get: { BotFileSelection.draft(draft.values["_fileAccess"]) }, set: { draft.values["_fileAccess"] = $0.encodedDraft; persist() })
    }
    private var selectedAvatarShape: ScienceAvatarShape {
        ScienceAvatarPresentation.shape(
            rawValue: draft.values["avatarShape"] ?? bot?.avatarShape,
            identity: bot?.id ?? draft.values["name", default: "new-bot"]
        )
    }
    private var selectedAvatarPalette: ScienceAvatarPalette {
        ScienceAvatarPresentation.palette(
            rawValue: draft.values["avatarPalette"] ?? bot?.avatarPalette,
            legacyColor: bot?.avatarColor
        )
    }
    private var avatarShape: Binding<ScienceAvatarShape> {
        Binding(
            get: { selectedAvatarShape },
            set: { value in
                draft.values["avatarShape"] = value.rawValue
                draft.values["_avatarShapeChanged"] = "true"
                persist()
            }
        )
    }
    private var avatarPalette: Binding<String> {
        Binding(
            get: { selectedAvatarPalette.id },
            set: { value in
                draft.values["avatarPalette"] = ScienceAvatarPalette.resolve(value).id
                draft.values["_avatarPaletteChanged"] = "true"
                persist()
            }
        )
    }
    private var permissionMode: BotPermissionMode? { draft.values["permissionMode"].flatMap(BotPermissionMode.init(rawValue:)) }
    private var approvalMode: BotApprovalMode { draft.values["approvalMode"].flatMap(BotApprovalMode.init(rawValue:)) ?? .askForApproval }
    private var approvalAvailable: Bool { draft.canSaveBotApproval(options: options) && options?.approvalModes != nil }
    private var permissionDescription: String {
        permissionMode?.scopeDescription ?? "This Bot keeps its current selected-location access. Choose a mode to change its permissions."
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: field("name")).accessibilityIdentifier("bot-name")
                    TextField("Purpose", text: field("role"), axis: .vertical).lineLimit(2...4)
                } footer: { if bot == nil { Text("Your Bot starts with a workspace on your Mac and its own character and color.") } }
                Section {
                    ScienceAvatarPicker(
                        shape: avatarShape,
                        paletteID: avatarPalette
                    )
                } header: {
                    Text("Avatar")
                }
                Section {
                    ApprovalModeMenu(
                        selection: Binding(get: { approvalMode }, set: { field("approvalMode").wrappedValue = $0.rawValue }),
                        options: options?.approvalModes,
                        isDisabled: busy,
                        onChange: { _ in }
                    ) {
                        LabeledContent("Approval", value: approvalMode.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("bot-permission-mode")
                    if options?.approvalModes == nil { Text("Update Wonder on your Mac to change approval settings.").font(.footnote).foregroundStyle(.secondary) }
                    else if !approvalAvailable { Text("This approval choice is unavailable on your Mac. Choose an available option before saving.").font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Approval") } footer: { Text(approvalMode.description) }
                if bot == nil { BotFileAccessFields(selection: fileSelection, workspacePath: nil, permissionMode: permissionMode, adding: $adding) }
                Section {
                    DisclosureGroup("Advanced settings") {
                        TextField("Instructions", text: field("systemPrompt"), axis: .vertical).lineLimit(4...12)
                        if bot == nil { if let options {
                            Picker("Model", selection: field("model")) {
                                Text("Default").tag("")
                                ForEach(options.models.filter { !$0.hidden }) { Text($0.displayName).tag($0.id) }
                                if let selected = draft.values["model"], !selected.isEmpty, !options.models.contains(where: { $0.id == selected }) { Text("Saved model (unavailable)").tag(selected) }
                            }
                            if let selected = options.models.first(where: { $0.id == draft.values["model"] }) {
                                Picker("Reasoning", selection: field("reasoningEffort")) {
                                    Text("Default").tag("")
                                    ForEach(selected.reasoningEfforts) { Text($0.label).tag($0.id) }
                                }
                            }
                        } else { Text("Model choices are unavailable. Refresh after reconnecting to your Mac.").font(.footnote).foregroundStyle(.secondary) } }
                        if let bot {
                            LabeledContent("Workspace") {
                                Text(botWorkspacePath ?? bot.workingDirectory ?? bot.workspacePath)
                                    .font(.footnote)
                                    .textSelection(.enabled)
                            }
                            NavigationLink("File access") {
                                BotFileAccessView(model: model, bot: bot) { path in
                                    botWorkspacePath = path
                                }
                            }
                        }
                        if permissionMode == nil { Text("This Bot keeps its existing access boundary while approval settings are changed separately.").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                if let bot, !bot.isArchived { Section { Button("Archive Bot", role: .destructive) { archive = true } } }
                if let failure { Section { FailureDetails(message: failure); if bot == nil && draft.values["_submitted"] == "true" { Text("Retry Create to check the same request. The fields stay fixed until your Mac confirms it.").font(.footnote) } } }
                if busy { ProgressView("Saving…") }
            }
            .disabled(busy || (bot == nil && draft.values["_submitted"] == "true"))
            .navigationTitle(bot == nil ? "New Bot" : "Bot settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(bot == nil ? "Create" : "Save") { Task { await save() } }.disabled(busy || !valid).accessibilityIdentifier("save-bot") }
                ToolbarItem(placement: .bottomBar) {
                    if options?.approvalModes == nil { Button("Reload choices") { Task { await loadOptions() } }.disabled(busy) }
                }
            }
            .interactiveDismissDisabled(busy)
            .task { await load() }
            .alert("Couldn’t save Bot", isPresented: $showingSaveFailure) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "Your Mac could not confirm this change. Your choices are saved; reconnect and retry.")
            }
            .confirmationDialog("Archive \(bot?.name ?? "Bot")?", isPresented: $archive, titleVisibility: .visible) {
                Button("Archive Bot", role: .destructive) { Task { await archiveBot() } }
            } message: { Text("The Bot leaves active Chats and its automations pause. You can restore it in Settings → Archived Bots.") }
        }
        .sheet(item: $adding) { choice in
            MacLocationBrowser(model: model, title: choice.title, foldersOnly: choice == .workingDirectory) { path, directory in
                choice.apply(path: path, isDirectory: directory, to: &fileSelection.wrappedValue)
            }
        }
    }
    private var valid: Bool {
        let name = draft.values["name", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        let role = draft.values["role", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        let approvalChanged = draft.values["_approvalChanged"] == "true"
        return (bot != nil || approvalAvailable) && (!approvalChanged || approvalAvailable) && !name.isEmpty && name.utf8.count <= 80 && !role.isEmpty && role.utf8.count <= 160 && draft.values["systemPrompt", default: ""].utf8.count <= 8000
    }
    private func load() async {
        guard !loaded else { return }
        if let saved = model.managementDrafts?.load(key) {
            draft = saved
            // Drafts from the legacy editor may still contain an arbitrary
            // color. It is intentionally not sent by this editor.
            draft.values.removeValue(forKey: "avatarColor")
            if bot == nil {
                if draft.values["avatarShape"] == nil { draft.values["avatarShape"] = ScienceAvatarCatalog.stableShape(for: draft.requestId).rawValue }
                if draft.values["avatarPalette"] == nil { draft.values["avatarPalette"] = ScienceAvatarCatalog.stablePalette(for: draft.requestId) }
            }
        }
        else if let bot {
            draft.values = ["name": bot.name, "role": bot.role, "systemPrompt": bot.systemPrompt, "model": bot.model ?? "", "reasoningEffort": bot.reasoningEffort ?? "", "approvalMode": bot.approvalMode ?? (bot.permissionMode == BotPermissionMode.fullAccess.rawValue ? BotApprovalMode.fullAccess.rawValue : BotApprovalMode.askForApproval.rawValue)]
            if let avatarShape = bot.avatarShape { draft.values["avatarShape"] = avatarShape }
            if let avatarPalette = bot.avatarPalette { draft.values["avatarPalette"] = avatarPalette }
        } else {
            let defaults = NewBotDefaults.load()
            draft.values = ["avatarShape": ScienceAvatarCatalog.stableShape(for: draft.requestId).rawValue, "avatarPalette": ScienceAvatarCatalog.stablePalette(for: draft.requestId), "model":defaults.model, "reasoningEffort":defaults.reasoningEffort, "approvalMode":defaults.approvalMode.rawValue]
        }
        // Unrelated saved drafts must not replace the Bot's current appearance.
        // Keep only explicit unsaved avatar edits, including failed-save retries.
        if let bot {
            if draft.values["_avatarShapeChanged"] != "true" { draft.values["avatarShape"] = bot.avatarShape }
            if draft.values["_avatarPaletteChanged"] != "true" { draft.values["avatarPalette"] = bot.avatarPalette }
        }
        draft.prepareBotApproval(isNew: bot == nil, currentMode: bot?.approvalMode ?? (bot?.permissionMode == "full-access" ? "full-access" : nil))
        loaded = true
        await loadOptions()
    }
    private func loadOptions() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let path: String
            if let bot {
                guard let conversationID = bot.conversationId else { throw PairingFailure.response(404) }
                path = "/api/v1/conversations/\(ConnectionModel.escape(conversationID))/composer-options"
            } else { path = "/api/v1/bot-options" }
            options = try await model.manage(path)
            failure = nil
        }
        catch { failure = "Approval and model choices could not be loaded. Reconnect to your Mac, then reload choices." }
    }
    private func save() async {
        guard valid else { return }; busy = true; failure = nil
        if bot == nil { draft.values["_submitted"] = "true" }; persist()
        defer { busy = false }
        do {
            let avatarFields: Set<String> = bot == nil
                ? ["avatarShape", "avatarPalette"]
                : Set(["avatarShape", "avatarPalette"].filter { draft.values["_\($0)Changed"] == "true" })
            var values = BotAvatarPayload.sanitized(draft.values, avatarFields: avatarFields)
            if bot != nil { for key in ["model", "reasoningEffort", "serviceTier", "permissionMode"] { values.removeValue(forKey: key) }; if draft.values["_approvalChanged"] != "true" { values.removeValue(forKey: "approvalMode") } }
            values["systemPrompt"] = values["systemPrompt", default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? values["role"] : values["systemPrompt"]
            // Omission preserves the host default on creation; explicit empty fields clear overrides on edit.
            if bot == nil { values = values.filter { !$0.value.isEmpty }; values["clientRequestId"] = draft.requestId }
            let body = bot == nil ? try fileSelection.wrappedValue.creationBody(fields: values) : try JSONEncoder().encode(values)
            let saved: ManagedBot = try await model.manage("/api/v1/bots" + (bot.map { "/" + ConnectionModel.escape($0.id) } ?? ""), method: bot == nil ? "POST" : "PATCH", body: body)
            if bot != nil { model.applyConfirmedManagedBot(saved) }
            model.managementDrafts?.remove(key); await model.loadChats(force: true)
            if let id = saved.conversationId { model.selectedChat = model.chats.first { $0.id == id } }
            completed(saved.conversationId); dismiss()
        } catch {
            if case PairingFailure.response(let code) = error, [400, 422].contains(code) { draft.values.removeValue(forKey: "_submitted"); draft.requestId = UUID().uuidString; persist() }
            failure = managementError(error)
            showingSaveFailure = true
        }
    }
    private func archiveBot() async {
        guard let bot else { return }; busy = true; defer { busy = false }
        do { let _: ManagedBot = try await model.manage("/api/v1/bots/\(ConnectionModel.escape(bot.id))/archive", method: "POST", values: [:]); model.managementDrafts?.remove(key); await model.loadChats(force: true); completed(nil); dismiss() }
        catch { failure = managementError(error) }
    }
}

enum BotAvatarPayload {
    /// Legacy drafts can survive an app update. Remove their arbitrary color
    /// without inventing avatar fields for an old Bot whose identity is absent.
    /// Existing Bots omit unchanged avatar values so a newer host's unknown
    /// identity remains intact during unrelated edits.
    static func sanitized(
        _ values: [String: String],
        avatarFields: Set<String> = ["avatarShape", "avatarPalette"]
    ) -> [String: String] {
        values.filter { key, _ in
            guard !key.hasPrefix("_"), key != "avatarColor" else { return false }
            return !["avatarShape", "avatarPalette"].contains(key) || avatarFields.contains(key)
        }
    }
}

struct ArchivedBotsView: View {
    @ObservedObject var model: ConnectionModel
    @State private var bots: [ManagedBot] = []
    @State private var conversations: [ChatSummary] = []
    @State private var failure: String?
    @State private var busy = false
    @State private var deleting: ManagedBot?
    var body: some View {
        List {
            if busy { ProgressView() }
            if let failure { FailureDetails(message: failure) }
            ForEach(bots) { bot in
                Section {
                    NavigationLink { BotEditor(model: model, bot: bot) } label: { HStack { ChatAvatar(name: bot.name, identity: bot.id, hexColor: bot.avatarColor, avatarShape: bot.avatarShape, avatarPalette: bot.avatarPalette); VStack(alignment: .leading) { Text(bot.name); Text(bot.role).font(.subheadline).foregroundStyle(.secondary) } } }
                    if let id = bot.conversationId, let chat = conversations.first(where: { $0.id == id }) { NavigationLink("Conversation history") { ConversationView(model: model, chat: chat) } }
                    Button("Restore Bot") { Task { await change(bot, deleting: false) } }
                    Button("Delete forever", role: .destructive) { deleting = bot }
                }
            }
            if bots.isEmpty && !busy && failure == nil { Text("No archived Bots").foregroundStyle(.secondary) }
            Section {} footer: { Text("Restored Bots keep their automations paused until you resume them.") }
        }
        .navigationTitle("Archived Bots").disabled(busy)
        .task { await load() }.refreshable { await load() }
        .confirmationDialog("Delete \(deleting?.name ?? "Bot") forever?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let bot = deleting { Button("Delete forever", role: .destructive) { Task { await change(bot, deleting: true) } } }
        } message: { Text("This permanently removes this Bot’s direct conversations, automations and private files. Shared Group history and external project folders stay intact. This cannot be undone.") }
    }
    private func load() async { busy = true; defer { busy = false }; do { let all: [ManagedBot] = try await model.manage("/api/v1/bots"); bots = all.filter(\.isArchived); conversations = try await model.manage("/api/v1/conversations"); failure = nil } catch { failure = managementError(error) } }
    private func change(_ bot: ManagedBot, deleting: Bool) async {
        busy = true; failure = nil
        do {
            let path = "/api/v1/bots/" + ConnectionModel.escape(bot.id)
            if deleting { let _: EmptyReply = try await model.manage(path, method: "DELETE") }
            else { let _: ManagedBot = try await model.manage(path + "/unarchive", method: "POST", values: [:]) }
            self.deleting = nil; await model.loadChats(force: true); await load()
        } catch { failure = managementError(error) }
        busy = false
    }
}

struct AutomationListView: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    @State private var automations: [ManagedAutomation] = []
    @State private var creating = false
    @State private var failure: String?
    @State private var busy = false
    var body: some View {
        List {
            ForEach(automations) { automation in
                NavigationLink { AutomationDetailView(model: model, chat: chat, initial: automation, changed: { Task { await load() } }) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(automation.name).font(.headline); Spacer(); if automation.status != "active" { Text("Paused").font(.subheadline).foregroundStyle(.secondary) } }
                        Text(automation.prompt).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        if automation.status == "active" { Text("Next: \(readableDate(automation.nextRunAt))").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 3)
                }
            }
            if busy { ProgressView("Loading automations…") }
            if let failure { FailureDetails(message: failure); Button("Try again") { Task { await load() } } }
            if automations.isEmpty && !busy && failure == nil { Text("No automations yet").foregroundStyle(.secondary) }
            Section {} footer: { Text("Automations run while your Mac is awake and Wonder is available.") }
        }.navigationTitle("Automations")
        .toolbar { Button("New automation", systemImage: "plus") { creating = true } }
        .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) { AutomationEditor(model: model, chat: chat, automation: nil) }
        .task { await load() }.refreshable { await load() }
    }
    private func load() async {
        busy = true; defer { busy = false }
        do {
            let all: [ManagedAutomation] = try await model.manage("/api/v1/automations")
            let scopeId = chat.botId ?? model.groups[chat.id]?.id
            automations = all.filter { $0.scopeId == scopeId && $0.scopeType == (chat.botId == nil ? "group_chat" : "bot") }; failure = nil
        } catch { failure = managementError(error) }
    }
}

struct AutomationEditor: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    let automation: ManagedAutomation?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ManagementDraft()
    @State private var loaded = false
    @State private var busy = false
    @State private var failure: String?
    @State private var preview: SchedulePreview?
    @State private var previewedSchedule: [String: String]?
    @State private var discard = false
    private var key: String { "automation." + (automation?.id ?? "new." + chat.id) }
    private func persist() { do { try model.managementDrafts?.save(draft, key: key) } catch { failure = "This draft could not be saved on this device." } }
    private func field(_ key: String) -> Binding<String> {
        Binding(get: { draft.values[key] ?? "" }, set: { value in
            guard draft.values[key] != value else { return }
            draft.values[key] = value
            if AutomationScheduleForm.recurrenceFields.contains(key) { draft.values["_scheduleChanged"] = "true"; preview = nil }
            if key == "timezone" { preview = nil }
            persist()
        })
    }
    private var scheduleRequest: [String: String] { ["rrule": rule, "timezone": draft.values["timezone", default: ""]] }
    private var hasCurrentPreview: Bool { preview != nil && previewedSchedule == scheduleRequest }
    private var rule: String { AutomationScheduleForm.rule(for: draft.values) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: field("name"))
                    TextField("Task", text: field("prompt"), axis: .vertical).lineLimit(4...10)
                    if chat.botId != nil { Picker("Run in", selection: field("kind")) { Text("This conversation").tag("continuation"); Text("A new conversation").tag("standalone") } }
                }
                Section("Schedule") {
                    Picker("Repeats", selection: field("schedule")) { Text("Hourly").tag("hourly"); Text("Daily").tag("daily"); Text("Weekdays").tag("weekdays"); Text("Weekly").tag("weekly"); Text("Monthly").tag("monthly"); Text("Custom").tag("custom") }
                    if draft.values["schedule"] == "custom" { TextField("Recurrence rule", text: field("custom"), axis: .vertical).textInputAutocapitalization(.characters).autocorrectionDisabled() }
                    else {
                        if draft.values["schedule"] == "weekly" { Picker("Day", selection: field("weekday")) { Text("Monday").tag("MO"); Text("Tuesday").tag("TU"); Text("Wednesday").tag("WE"); Text("Thursday").tag("TH"); Text("Friday").tag("FR"); Text("Saturday").tag("SA"); Text("Sunday").tag("SU") } }
                        if draft.values["schedule"] == "monthly" { Picker("Day of month", selection: field("monthday")) { ForEach(1...31, id: \.self) { Text(String($0)).tag(String($0)) } } }
                        if draft.values["schedule"] != "hourly" { Picker("Hour", selection: field("hour")) { ForEach(0...23, id: \.self) { Text(String(format: "%02d", $0)).tag(String($0)) } } }
                        Picker("Minute", selection: field("minute")) { ForEach(0...59, id: \.self) { Text(String(format: "%02d", $0)).tag(String($0)) } }
                    }
                    TextField("Timezone", text: field("timezone")).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Check next occurrence") { Task { await checkSchedule() } }.disabled(busy)
                    if hasCurrentPreview, let preview { LabeledContent("Next", value: readableDate(preview.nextRunAt)) }
                }
                if let failure { Section { FailureDetails(message: failure) } }
                if busy { ProgressView() }
                Section {} footer: { Text("The timezone stays fixed when you travel. Your Mac must be awake and Wonder available. Missed runs may be combined when it returns.") }
            }.disabled(busy || (automation == nil && draft.values["_submitted"] == "true"))
            .navigationTitle(automation == nil ? "New automation" : "Edit automation").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Menu("Close") { Button("Keep draft and close") { dismiss() }; Button("Discard changes", role: .destructive) { discard = true } }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(busy || !valid || !hasCurrentPreview) }
            }
            .interactiveDismissDisabled(busy)
            .task { await load() }
            .confirmationDialog("Discard these changes?", isPresented: $discard, titleVisibility: .visible) { Button("Discard changes", role: .destructive) { model.managementDrafts?.remove(key); dismiss() } }
        }
    }
    private var valid: Bool { !draft.values["name", default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.values["name", default: ""].utf8.count <= 120 && !draft.values["prompt", default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.values["prompt", default: ""].utf8.count <= 8000 }
    private func load() async {
        guard !loaded else { return }; loaded = true
        if let saved = model.managementDrafts?.load(key) {
            draft = saved
            // Upgrade drafts saved by the earlier editor without changing their recurrence payload.
            if draft.values["schedule"] == "custom", draft.values["_originalRule"] == nil, let rule = draft.values["custom"] {
                draft.values.merge(AutomationScheduleForm.values(for: rule)) { _, parsed in parsed }
            }
        }
        else if let automation {
            draft.values = AutomationScheduleForm.values(for: automation.rrule)
            draft.values.merge(["name": automation.name, "prompt": automation.prompt, "kind": automation.kind, "timezone": automation.timezone]) { _, value in value }
        }
        else {
            draft.values = ["kind": "continuation", "schedule": "daily", "hour": "9", "minute": "0", "weekday": "MO", "monthday": "1"]
            do { let options: BotOptions = try await model.manage("/api/v1/bot-options"); draft.values["timezone"] = options.timezone ?? "UTC" }
            catch { failure = "Enter your Mac’s timezone, such as America/New_York, before checking the schedule." }
        }
        persist(); if !draft.values["timezone", default: ""].isEmpty { await checkSchedule() }
    }
    private func checkSchedule() async {
        busy = true; failure = nil; preview = nil; previewedSchedule = nil; defer { busy = false }
        let request = scheduleRequest
        do {
            let result: SchedulePreview = try await model.manage("/api/v1/automations/preview", method: "POST", values: request)
            guard scheduleRequest == request else { return }
            preview = result; previewedSchedule = request
        }
        catch { failure = "This schedule could not be verified. Check the recurrence and timezone, or reconnect to your Mac." }
    }
    private func save() async {
        guard valid, hasCurrentPreview else { return }; busy = true; failure = nil
        if automation == nil { draft.values["_submitted"] = "true" }; persist(); defer { busy = false }
        do {
            let group = model.groups[chat.id]
            guard let botId = chat.botId ?? group?.coordinatorBotId else { failure = "Refresh this Group’s details before saving."; return }
            let kind = chat.botId == nil ? "continuation" : draft.values["kind", default: "continuation"]
            let target = automation?.targetConversation(selectedKind: kind, currentConversation: chat.id) ?? chat.id
            var values = ["name": draft.values["name", default: ""], "prompt": draft.values["prompt", default: ""], "kind": kind, "conversationId": target, "rrule": rule, "timezone": draft.values["timezone", default: ""]]
            if automation == nil { values.merge(["botId": botId, "scopeType": chat.botId == nil ? "group_chat" : "bot", "scopeId": chat.botId ?? group!.id, "clientRequestId": draft.requestId]) { _, new in new } }
            let _: ManagedAutomation = try await model.manage("/api/v1/automations" + (automation.map { "/" + ConnectionModel.escape($0.id) } ?? ""), method: automation == nil ? "POST" : "PATCH", values: values)
            model.managementDrafts?.remove(key); dismiss()
        } catch {
            if case PairingFailure.response(let code) = error, [400, 422].contains(code) { draft.values.removeValue(forKey: "_submitted"); draft.requestId = UUID().uuidString; persist() }
            failure = managementError(error)
        }
    }
}

struct AutomationDetailView: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    let initial: ManagedAutomation
    var changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var current: ManagedAutomation?
    @State private var runs: [ManagedAutomationRun] = []
    @State private var editing = false
    @State private var deleting = false
    @State private var busy = false
    @State private var failure: String?
    @State private var destination: ChatSummary?
    private var automation: ManagedAutomation { current ?? initial }
    private var path: String { "/api/v1/automations/" + ConnectionModel.escape(initial.id) }
    var body: some View {
        List {
            Section {
                Text(automation.prompt)
                LabeledContent("Status", value: automation.status.capitalized)
                LabeledContent("Next run", value: readableDate(automation.nextRunAt))
                LabeledContent("Last attempt", value: readableDate(automation.lastAttemptAt))
                LabeledContent("Last success", value: readableDate(automation.lastSuccessAt))
                LabeledContent("Timezone", value: automation.timezone)
            }
            Section {
                Button("Edit") { editing = true }
                Button(automation.status == "active" ? "Pause" : "Resume") { Task { await toggle() } }
                Button("Run now") { Task { await runNow() } }
            }
            Section("Run history") {
                if runs.isEmpty { Text("No runs yet").foregroundStyle(.secondary) }
                ForEach(runs) { run in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(run.status.replacingOccurrences(of: "_", with: " ").capitalized); Spacer(); Text(readableDate(run.startedAt)).font(.caption).foregroundStyle(.secondary) }
                        if let error = run.error { FailureDetails("Run failed", message: error) }
                        if let id = run.conversationId { Button("Open conversation") { Task { await openConversation(id) } } }
                    }
                }
            }
            Section { Button("Delete automation", role: .destructive) { deleting = true } }
            if let failure { FailureDetails(message: failure) }
            if busy { ProgressView() }
        }.navigationTitle(automation.name).disabled(busy)
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } } }
        .sheet(isPresented: $editing, onDismiss: { Task { await load(); changed() } }) { AutomationEditor(model: model, chat: chat, automation: automation) }
        .sheet(item: $destination) { target in NavigationStack { ConversationView(model: model, chat: target).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { destination = nil } } } } }
        .confirmationDialog("Delete this automation?", isPresented: $deleting, titleVisibility: .visible) { Button("Delete automation", role: .destructive) { Task { await delete() } } } message: { Text("Future runs stop and the run history is removed. Conversation messages are kept.") }
        .task { await load() }.refreshable { await load() }
    }
    private func load() async {
        busy = true; defer { busy = false }
        do { let all: [ManagedAutomation] = try await model.manage("/api/v1/automations"); current = all.first { $0.id == initial.id }; runs = try await model.manage(path + "/runs"); failure = nil } catch { failure = managementError(error) }
    }
    private func toggle() async {
        busy = true; defer { busy = false }
        do { current = try await model.manage(path, method: "PATCH", values: ["status": automation.status == "active" ? "paused" : "active"]); changed() } catch { failure = managementError(error) }
    }
    private func runNow() async {
        busy = true; defer { busy = false }
        let key = "run." + initial.id
        let request = model.managementDrafts?.load(key) ?? ManagementDraft()
        do {
            try model.managementDrafts?.save(request, key: key)
            let _: EmptyReply = try await model.manage(path + "/run", method: "POST", values: ["clientRequestId": request.requestId])
            model.managementDrafts?.remove(key); await load(); changed()
        } catch { failure = managementError(error) }
    }
    private func delete() async {
        busy = true; defer { busy = false }
        do { let _: EmptyReply = try await model.manage(path, method: "DELETE"); model.managementDrafts?.remove("automation." + initial.id); model.managementDrafts?.remove("run." + initial.id); changed(); dismiss() } catch { failure = managementError(error) }
    }
    private func openConversation(_ id: String) async {
        await model.loadChats(force: true)
        if let target = model.chats.first(where: { $0.id == id }) { destination = target }
        else { failure = "This run’s conversation is no longer available in Chats." }
    }
}

extension ConnectionModel {
    /// A lost response retries the same creation rather than making a second Bot.
    @MainActor func createConversationalBot() async throws -> String? {
        let key = "bot.conversational-new"
        var draft = managementDrafts?.load(key) ?? ManagementDraft()
        if draft.values["_defaultsResolved"] == nil {
            let options: BotOptions = try await manage("/api/v1/bot-options")
            try draft.prepareNewBot(defaults: NewBotDefaults.load(), options: options)
        }
        try managementDrafts?.save(draft, key: key)
        var values = draft.values.filter { !$0.key.hasPrefix("_") }
        values["clientRequestId"] = draft.requestId
        let saved: ManagedBot = try await manage("/api/v1/bots/new", method: "POST", values: values)
        managementDrafts?.remove(key)
        applyConfirmedManagedBot(saved)
        await loadChats(force: true)
        if let id = saved.conversationId { selectedChat = chats.first { $0.id == id } }
        return saved.conversationId
    }
}
