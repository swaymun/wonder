import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import WonderPairing

struct CodexUsageWindow: Decodable, Identifiable, Sendable {
    let id: String
    let label: String
    let usedPercent: Double
    let remainingPercent: Double
    let windowDurationMins: UInt64?
    let resetsAt: UInt64?

    var roundedRemainingPercent: Int {
        Int(min(max(remainingPercent, 0), 100).rounded())
    }
}

struct CodexUsageResponse: Decodable, Sendable {
    var agentFamily: String? = nil
    let checkedAtMs: UInt64
    let windows: [CodexUsageWindow]
    var additionalUsageAvailable: Bool? = nil
}

struct CodexUsageCacheEntry: Sendable {
    let response: CodexUsageResponse
    let fetchedAt: Date

    func exhaustedWindow(model: String, now: Date = Date()) -> CodexUsageWindow? {
        guard now.timeIntervalSince(fetchedAt) < 300, response.additionalUsageAvailable != true else { return nil }
        let name = model.lowercased()
        return response.windows.first { window in
            guard window.usedPercent >= 100, window.remainingPercent <= 0 else { return false }
            if let reset = window.resetsAt, Double(reset) <= now.timeIntervalSince1970 { return false }
            switch window.id {
            case "seven_day_sonnet": return name.contains("sonnet")
            case "seven_day_opus": return name.contains("opus")
            default: return true
            }
        }
    }
}

struct ConversationGoal: Decodable, Equatable, Sendable {
    let objective: String
    let status: String
    let createdAt: Date?
    let tokenBudget: Int?
    let tokensUsed: Int
    let timeBudgetSeconds: Int?
    let timeUsedSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case objective, status, createdAt, tokenBudget, tokensUsed, timeBudgetSeconds, timeUsedSeconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        objective = try values.decode(String.self, forKey: .objective)
        status = try values.decode(String.self, forKey: .status)
        let stamp = try values.decodeIfPresent(Double.self, forKey: .createdAt)
        createdAt = stamp.map { Date(timeIntervalSince1970: $0 > 1_000_000_000_000 ? $0 / 1000 : $0) }
        tokenBudget = try values.decodeIfPresent(Int.self, forKey: .tokenBudget)
        tokensUsed = try values.decodeIfPresent(Int.self, forKey: .tokensUsed) ?? 0
        timeBudgetSeconds = try values.decodeIfPresent(Int.self, forKey: .timeBudgetSeconds)
        timeUsedSeconds = try values.decodeIfPresent(Int.self, forKey: .timeUsedSeconds) ?? 0
    }
}

private struct ConversationGoalResponse: Decodable, Sendable { let goal: ConversationGoal? }
private struct EmptyGoalResponse: Decodable, Sendable {}

/// Projects the server's mixed conversation response into the active Chats
/// list. Bot IDs are intentionally supplied by the caller after it has
/// applied the Bot archive state; the complete Bot ID set remains useful for
/// deletion/cache cleanup, but must not keep archived direct chats visible.
func projectVisibleChatSummaries(
    remote: [ChatSummary],
    groups: [GroupRead],
    activeBotIDs: Set<String>
) -> [ChatSummary] {
    let groupIDs = Set(groups.map(\.conversationId))
    let direct = remote.filter { summary in
        guard !groupIDs.contains(summary.id) else { return false }
        return summary.botId.map(activeBotIDs.contains) ?? true
    }
    return direct + groups.map(\.summary)
}

/// Keeps an authoritative Bot mutation visible while a list request that began
/// before the mutation is still in flight. A later successful list request is
/// allowed to reconcile the protection because the mutation already completed
/// durably on the host.
struct ManagedBotListMutationState {
    private struct Confirmation {
        let revision: UInt64
        let bot: ManagedBot
    }

    private(set) var revision: UInt64 = 0
    private var confirmations: [String: Confirmation] = [:]

    mutating func confirm(_ bot: ManagedBot, current: [ManagedBot]) -> [ManagedBot] {
        revision &+= 1
        confirmations[bot.id] = Confirmation(revision: revision, bot: bot)
        return Self.upserting([bot], into: current)
    }

    mutating func reconcile(_ fetched: [ManagedBot], startedAt snapshot: UInt64) -> [ManagedBot] {
        guard snapshot < revision else {
            confirmations = confirmations.filter { $0.value.revision > snapshot }
            return fetched
        }

        let protectedBots = confirmations.values
            .filter { $0.revision > snapshot }
            .map(\.bot)
        return Self.upserting(protectedBots, into: fetched)
    }

    private static func upserting(_ bots: [ManagedBot], into current: [ManagedBot]) -> [ManagedBot] {
        var result = current
        for bot in bots {
            if let index = result.firstIndex(where: { $0.id == bot.id }) {
                result[index] = bot
            } else {
                result.append(bot)
            }
        }
        return result
    }
}

@MainActor final class ConnectionModel: ObservableObject {
    @Published var connection: SavedConnection? {
        didSet {
            if oldValue?.credential.hostInstallationId != connection?.credential.hostInstallationId ||
                oldValue?.credential.deviceId != connection?.credential.deviceId || oldValue?.origin != connection?.origin {
                cancelApprovalSettings()
                connectedAppsCache = [:]
                codexUsageCache = [:]; claudeUsageCache = [:]
                goals = [:]; goalErrors = [:]; goalMutationTokens = [:]
                resetImagePreviews()
                dictation.connectionChanged()
                cameraContextID = UUID()
            }
            noteListChange()
        }
    }
    var connectedAppsCache: [String: ConnectedAppCacheEntry] = [:]
    @Published var codexUsageCache: [String: CodexUsageCacheEntry] = [:]
    @Published var claudeUsageCache: [String: CodexUsageCacheEntry] = [:]
    let imagePreviews = ToolImagePreviews()
    private(set) var imagePreviewScope = UUID()
    private func resetImagePreviews() {
        imagePreviewScope = UUID()
        imagePreviews.invalidate()
    }
    lazy var dictation = DictationController(model: self)
    /// Owner-selected projects on this Mac, observed directly by the sidebar.
    lazy var projects = ProjectLibrary(model: self)
    /// Project threads opened on this device. They share the conversation
    /// surface but are not Bot conversations.
    @Published private(set) var projectConversationIDs: Set<String> = []
    func registerProjectConversation(_ detail: ProjectConversationDetail) {
        if !projectConversationIDs.contains(detail.conversationId) { projectConversationIDs.insert(detail.conversationId) }
    }
    func isProject(_ chat: ChatSummary) -> Bool { projectConversationIDs.contains(chat.id) }
    /// Native provider history being re-read; Send waits so a new turn never
    /// follows a stale view of work done on the Mac.
    @Published private(set) var nativeHistoryRefreshing: Set<String> = []
    @Published private(set) var nativeHistoryFailures: Set<String> = []
    func reloadNativeHistory(_ chat: ChatSummary) async {
        guard isProject(chat), !previewMode, !nativeHistoryRefreshing.contains(chat.id) else { return }
        let scope = assignmentScope
        nativeHistoryRefreshing.insert(chat.id)
        guard await connectionReady(), let saved = connection, !accessEnded, scope == assignmentScope else {
            if scope == assignmentScope {
                nativeHistoryRefreshing.remove(chat.id)
                if !Task.isCancelled { nativeHistoryFailures.insert(chat.id) }
            }
            return
        }
        defer { if scope == assignmentScope { nativeHistoryRefreshing.remove(chat.id) } }
        struct Status: Decodable, Sendable { let state: String }
        let path = "/api/v1/conversations/\(Self.escape(chat.id))/history/refresh"
        do {
            let detail = try await projects.loadDetail(chat.id)
            guard detail.hasNativeSession else { nativeHistoryFailures.remove(chat.id); return }
            var status: Status = try await api.request(path, origin: saved.origin, body: Data("{}".utf8), credential: saved.credential, decodingStatuses: [202])
            // Bounded wait; saved history stays on screen meanwhile. A long chat
            // can take a while: one still refreshing is not a failure, and the
            // open conversation's activity check picks up its result later.
            for _ in 0..<120 where status.state == "refreshing" {
                try await Task.sleep(for: .milliseconds(250))
                guard scope == assignmentScope, !Task.isCancelled else { return }
                status = try await api.request(path, origin: saved.origin, credential: saved.credential)
            }
            guard scope == assignmentScope else { return }
            if status.state == "refreshing" { nativeHistoryFailures.remove(chat.id); return }
            guard status.state == "completed" else { throw PairingFailure.response(503) }
            nativeHistoryFailures.remove(chat.id)
            await refreshConversation(chat)
        } catch is CancellationError {
        } catch PairingFailure.response(429) {
            // Other history is refreshing on the Mac; the next check retries.
        } catch {
            guard scope == assignmentScope else { return }
            nativeHistoryFailures.insert(chat.id)
        }
    }
    /// Claude conversations open in Claude Code in a terminal on the Mac, which
    /// keeps Wonder's messages waiting until it is exited there.
    @Published private(set) var nativeOpenElsewhere: Set<String> = []
    /// The newest native turn seen per conversation, from the cheap activity check.
    private var nativeActivity: [String: String] = [:]
    private var nativeActivityUnsupported: Set<String> = []
    /// Checks whether work on the Mac started, finished or moved on, without
    /// re-reading history. Returns true when the conversation should reload.
    func nativeActivityChanged(_ chat: ChatSummary) async -> Bool {
        guard isProject(chat), !previewMode, let saved = connection, !accessEnded,
              !nativeActivityUnsupported.contains(assignmentScope) else { return false }
        struct Activity: Decodable, Sendable {
            let latestTurnId: String?; let latestTurnStatus: String; let runningElsewhere: Bool; let openElsewhere: Bool?
        }
        let scope = assignmentScope
        do {
            let activity: Activity = try await api.request("/api/v1/conversations/\(Self.escape(chat.id))/history/activity",
                origin: saved.origin, credential: saved.credential)
            guard scope == assignmentScope else { return false }
            if activity.openElsewhere == true { nativeOpenElsewhere.insert(chat.id) } else { nativeOpenElsewhere.remove(chat.id) }
            let signature = [activity.latestTurnId ?? "", activity.latestTurnStatus, String(activity.runningElsewhere)].joined(separator: "\u{1F}")
            let previous = nativeActivity.updateValue(signature, forKey: chat.id)
            return previous != nil && previous != signature
                || (previous == nil && activity.runningElsewhere != turnRunsElsewhere(chat.id))
        } catch PairingFailure.response(404) {
            // An older Mac without the check: keep the slower running refresh.
            if scope == assignmentScope { nativeActivityUnsupported.insert(scope) }
            return false
        } catch { return false }
    }
    @Published var status = "Connect to your computer to get started."
    @Published var busy = false
    @Published var verification: String?
    @Published var error: String?
    @Published var accessEnded = false { didSet { noteListChange(); if accessEnded { cancelApprovalSettings(); connectedAppsCache = [:]; codexUsageCache = [:]; claudeUsageCache = [:]; goals = [:]; goalErrors = [:]; goalMutationTokens = [:]; projectSubagents = [:]; projectSubagentLookup = [:]; projectSubagentFreshIDs = [:]; projectSubagentAvailability = [:]; projectSubagentErrors = [:]; projectSubagentNextCurrentCursor = [:]; projectSubagentNextArchivedCursor = [:]; projectSubagentInitialCurrentCursor = [:]; projectSubagentInitialArchivedCursor = [:]; projectSubagentSeenCurrentCursors = [:]; projectSubagentSeenArchivedCursors = [:]; projectSubagentExpandedParents = []; projectSubagentPagingLimited = []; projectSubagentRefreshPending = []; projectSubagentPageRevision = [:]; loadingOlderProjectSubagents = []; projectSubagentLoadTokens = [:]; resetImagePreviews(); dictation.forget(); cameraContextID = UUID() } } }
    @Published var chats: [ChatSummary] = [] { didSet { noteListChange() } }
    @Published var subagents: [String: [SubagentSummary]] = [:] { didSet { noteListChange() } }
    @Published var subagentAvailability: [String: Bool] = [:]
    @Published var subagentErrors: [String: String] = [:]
    @Published var projectSubagents: [String: [ProjectSubagentSummary]] = [:]
    @Published var projectSubagentFreshIDs: [String: Set<String>] = [:]
    private var projectSubagentLookup: [String: [String: ProjectSubagentSummary]] = [:]
    @Published var projectSubagentAvailability: [String: Bool] = [:]
    @Published var projectSubagentErrors: [String: String] = [:]
    @Published var projectSubagentNextCurrentCursor: [String: String] = [:]
    @Published var projectSubagentNextArchivedCursor: [String: String] = [:]
    @Published var loadingOlderProjectSubagents: Set<String> = []
    private var projectSubagentLoadTokens: [String: UUID] = [:]
    private var projectSubagentSeenCurrentCursors: [String: Set<String>] = [:]
    private var projectSubagentSeenArchivedCursors: [String: Set<String>] = [:]
    private var projectSubagentInitialCurrentCursor: [String: String] = [:]
    private var projectSubagentInitialArchivedCursor: [String: String] = [:]
    private var projectSubagentExpandedParents: Set<String> = []
    private var projectSubagentPagingLimited: Set<String> = []
    private var projectSubagentRefreshPending: Set<String> = []
    private var projectSubagentPageRevision: [String: Int] = [:]
    @Published var goals: [String: ConversationGoal] = [:]
    @Published var goalErrors: [String: String] = [:]
    private var goalMutationTokens: [String: UUID] = [:]
    @Published var savingComposerSettings: Set<String> = []
    @Published var composerApprovalChanges: [ComposerApprovalTarget: ComposerApprovalChange] = [:]
    var composerApprovalTasks: [ComposerApprovalTarget: Task<Void, Never>] = [:]
    var composerApprovalTokens: [ComposerApprovalTarget: UUID] = [:]
    @Published var managedBots: [ManagedBot] = [] { didSet { noteListChange() } }
    @Published var snapshots: [String: ConversationSnapshot] = [:] {
        didSet {
            // A snapshot read is pinned to one host sequence, so an unchanged
            // sequence, page and size means the open chat's rows are unchanged.
            if let id = rowCache?.id {
                let old = oldValue[id], new = snapshots[id]
                if old?.hostEpoch != new?.hostEpoch || old?.lastSequence != new?.lastSequence || old?.thread.nextCursor != new?.thread.nextCursor
                    || old?.messages.count != new?.messages.count || old?.assistantMessages.count != new?.assistantMessages.count
                    || old?.thread.turns?.count != new?.thread.turns?.count || old?.thread.turns?.last?.items.count != new?.thread.turns?.last?.items.count {
                    rowCache = nil
                }
            }
            noteListChange()
        }
    }
    @Published var groups: [String: GroupRead] = [:] {
        didSet {
            if let id = rowCache?.id, oldValue[id] != nil || groups[id] != nil,
               groups[id]?.lastSequence == nil || oldValue[id]?.hostEpoch != groups[id]?.hostEpoch
                || oldValue[id]?.lastSequence != groups[id]?.lastSequence
                || oldValue[id]?.messages.count != groups[id]?.messages.count {
                rowCache = nil
            }
            noteListChange()
        }
    }
    // Retain only the most recently presented conversation. Expansion and scroll
    // state do not change its source rows or require reparsing every timestamp.
    private var rowCache: (id: String, title: String, rows: [ReadRow])? { didSet { rowRevision &+= 1 } }
    private var rowRevision: UInt64 = 0
    private var timelineCache: (key: ConversationTimeline.Key, value: ConversationTimeline)?
    /// The Chats list observes this instead of every model change, so typing,
    /// sends and per-chat state do not re-render the whole list and root.
    @Published private(set) var listRevision: UInt64 = 0
    private func noteListChange() { listRevision &+= 1 }
    @Published var selectedChat: ChatSummary? {
        didSet { if selectedChat?.id != oldValue?.id { visibleChat = selectedChat } }
    }
    // The list keeps the root selected while navigation can show a verified child.
    @Published private(set) var visibleChat: ChatSummary? {
        didSet { if visibleChat?.id != oldValue?.id { cameraContextID = UUID() } }
    }
    @Published private(set) var cameraContextID = UUID()
    @Published var searchFocus: SearchMessageFocus?
    @Published var loadingChats = false
    /// Conversations with a history request in flight. Per conversation so a
    /// slow load cannot make a different chat look busy or empty.
    @Published private(set) var loadingConversationIDs: Set<String> = []
    /// Set only when a conversation has no saved content and loading failed.
    @Published private(set) var conversationLoadFailures: [String: String] = [:]
    @Published var cachedConversationIds: Set<String> = [] { didSet { noteListChange() } }
    @Published var chatsStatus = "Saved chats"
    @Published private(set) var hasConnectedThisLaunch = false { didSet { noteListChange() } }
    @Published private(set) var checkingConnection = false
    @Published private var listRefreshCount = 0
    var isRefreshing: Bool { checkingConnection || loadingChats || listRefreshCount > 0 }
    @Published var macConnected: Bool? {
        didSet { if macConnected == true { hasConnectedThisLaunch = true }; noteListChange() }
    }
    var macName: String { connection?.hostName ?? (previewMode ? "Studio" : "Your computer") }
    /// Keys this host and device's stored state so a replaced pairing never reuses it.
    var assignmentScope: String {
        guard let connection else { return "preview" }
        return connection.credential.hostInstallationId + ":" + connection.credential.deviceId
    }
    @Published var composers: [String: ComposerIntent] = [:]
    @Published private(set) var staleAnnotationIDs: [String: Set<String>] = [:]
    private var staleAnnotationScope: String?
    private struct AnnotationRevisionKey: Hashable {
        let scope: String
        let chatID: String
        let rootID: String
        let path: String
    }
    private var annotationRevisionRequests: [AnnotationRevisionKey: UUID] = [:]
    @Published var composerErrors: [String: String] = [:]
    @Published var sending: Set<String> = []
    @Published private(set) var preparingSends: Set<String> = []
    @Published var queues: [String: [QueuedMessage]] = [:]
    @Published var uploading: Set<String> = []
    @Published var loadingPhotos: Set<String> = []
    @Published var files: [String: [ConversationFile]] = [:]
    @Published var savedDecisions: [String: DecisionIntent] = [:]
    @Published var asyncQuestions: [String: [AsyncQuestion]] = [:]
    @Published private(set) var retryableAsyncReplies: Set<String> = []
    @Published private(set) var savedAsyncReplies: [String: AsyncAnswerIntent] = [:]
    @Published var attention: [AttentionRequest] = [] { didSet { noteListChange() } }
    @Published var attentionErrors: [String: String] = [:]
    @Published var resolving: Set<String> = []
    @Published var stopping: Set<String> = []
    @Published var controlErrors: [String: String] = [:]
    private var previewBytes: [String: Data] = [:]
    private var intentLoadFailures: Set<String> = []
    private let identity = PhoneIdentity()
    private let signingIdentity: SigningIdentity
    var identityNeedsRepair: (() throws -> Void)?
    var previousPairingConnection: ((String) -> SavedConnection?)?
    private let persistConnection: ((SavedConnection?) throws -> Void)?
    let api: PairingAPI
    #if WONDER_DIAGNOSTICS
    private static func diagnosticAPI() -> PairingAPI { PairingAPI { network, decode, bytes, success in
        DiagnosticJournal.shared.record(DiagnosticEvent(operation: "network", phase: success ? "duration" : "failed", durationMs: network, bytes: UInt64(bytes)))
        DiagnosticJournal.shared.record(DiagnosticEvent(operation: "decode", durationMs: decode, bytes: UInt64(bytes)))
    } }
    #endif
    private var connectionCheck: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var writer: ProjectionWriter?
    private var loadingTokens: [String: UUID] = [:]
    private var enrollment: Task<Void, Never>?
    private var replay: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    private var projection = ProjectionState()
    private var managedBotMutations = ManagedBotListMutationState()
    private var partition: String?
    private var retiredAfterPairing = false
    private var store: ReadStore?
    private var foreground = false
    #if WONDER_DIAGNOSTICS
    private var diagnosticReplayEnabled = true
    private var previewProjectFilesRootReads = 0
    private var previewWorkspaceRootReads = 0
    private var previewWorkspaceFileOpens: [String: Int] = [:]
    #endif
    var previewMode: Bool {
        #if DEBUG || WONDER_DIAGNOSTICS
        ProcessInfo.processInfo.arguments.contains("-read-preview") || ProcessInfo.processInfo.arguments.contains("-connections-preview")
        #else
        false
        #endif
    }
    init(saved: SavedConnection? = nil, persistConnection: ((SavedConnection?) throws -> Void)? = nil, api: PairingAPI? = nil, signingIdentity: SigningIdentity = PhoneIdentity.signing) {
        self.signingIdentity = signingIdentity
        self.persistConnection = persistConnection
        #if WONDER_DIAGNOSTICS
        self.api = api ?? Self.diagnosticAPI()
        #else
        self.api = api ?? PairingAPI()
        #endif
        #if DEBUG || WONDER_DIAGNOSTICS
        if previewMode {
            // Explicit synthetic UI fixture. No pairing, network or production storage.
            let arguments = ProcessInfo.processInfo.arguments
            let composerAttachmentsPreview = arguments.contains("-composer-attachments-preview")
            let composerRestoredPreview = arguments.contains("-composer-restored-attachments-preview")
            let composerRunningPreview = arguments.contains("-composer-running-preview")
            let composerQueuedPreview = arguments.contains("-composer-queued-preview")
            let messageAttachmentsPreview = arguments.contains("-message-attachments-preview")
            let projectRunningElsewherePreview = arguments.contains("-project-running-elsewhere-preview")
            // A Claude chat open, idle, in Claude on the Mac, with a message waiting for it.
            let projectOpenOnMacPreview = arguments.contains("-project-open-on-mac-preview")
            if projectOpenOnMacPreview { nativeOpenElsewhere.insert("preview") }
            let projectTerminalTurnPreview = arguments.contains("-project-terminal-turn-preview") || projectRunningElsewherePreview
            var group: [String: Any] = [
                "id": "preview-group", "conversationId": "preview", "name": saved?.hostName == "Laptop" ? "Travel plans" : saved?.hostName == "Home" ? "Reading list" : "Weekend plans", "isArchived": false,
                "members": [["botId":"ada", "botName":"Ada", "role":"worker"]],
                "messages": [
                    ["messageId": "1", "body": "Can you help me plan a relaxed Saturday?", "createdAt": "1700000000000", "authorKind": "user", "presentationKind": "message"],
                    ["messageId": "2", "body": "Start with breakfast at home, then take a walk. Leave the afternoon open so the day stays flexible.", "createdAt": "1700000001000", "authorKind": "member", "authorBotName": "Ada", "authorBotId":"ada", "presentationKind": "message"],
                    ["messageId": "3", "body": "Sounds good. Keep the evening free too.", "createdAt": "1700000002000", "authorKind": "user", "presentationKind": "message"],
                    ["messageId": "4", "body": "A quiet evening it is. You can return to these notes even when your computer is offline.", "createdAt": "1700000003000", "authorKind": "member", "authorBotName": "Ada", "authorBotId":"ada", "presentationKind": "message"]
                ]
            ]
            if ProcessInfo.processInfo.arguments.contains("-group-work-preview") {
                group["members"] = [["botId":"ada", "botName":"Ada", "role":"worker"], ["botId":"sam", "botName":"Sam", "role":"worker"]]
                group["collaboration"] = ["configuration": ["instructions":"Plan relaxed weekends", "routing":["model":"gpt-5.6-luna","reasoningEffort":"xhigh"], "workspace":"/preview", "needsPurpose":false],
                    "runs":[["parentMessageId":"1", "plan":["assignments":[["botId":"ada","brief":"Suggest a relaxed morning","dependsOn":[],"access":"read","state":"completed","outputId":"2"], ["botId":"sam","brief":"Review the plan for flexibility","dependsOn":["ada"],"access":"read","state":"working"]], "startedAt":ISO8601DateFormatter().string(from:Date().addingTimeInterval(-18)), "cancelled":false]]]]
            }
            if ProcessInfo.processInfo.arguments.contains("-scroll-performance-preview") {
                group["name"] = "Scroll performance"
                group["messages"] = (1...300).map { index -> [String: Any] in
                    ["messageId": "perf-\(index)",
                     "body": index.isMultiple(of: 2)
                        ? "Message \(index)\n\nA repeatable conversation for scrolling measurements. **Readable text** and a [link](https://example.com) exercise the normal message renderer.\n\n- Keep existing messages stable.\n- Return to the latest message when requested.\n\nThis final paragraph makes each response tall enough to scroll through at a natural reading pace."
                        : "Question \(index): How does this conversation behave while scrolling?",
                     "createdAt": String(1_700_000_000_000 + index * 1000),
                     "authorKind": index.isMultiple(of: 2) ? "member" : "user",
                     "authorBotName": "Ada", "authorBotId": "ada", "presentationKind": "message"]
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: group),
               let value = try? JSONDecoder().decode(GroupRead.self, from: data) {
                groups = ["preview": value]; chats = [value.summary]
                chatsStatus = "Saved chats"
                macConnected = !ProcessInfo.processInfo.arguments.contains("-disconnected-preview")
                cachedConversationIds = ["preview"]
                if ProcessInfo.processInfo.arguments.contains("-send-preview") ||
                    composerAttachmentsPreview || composerRestoredPreview || composerRunningPreview || composerQueuedPreview || messageAttachmentsPreview || projectTerminalTurnPreview ||
                    (ProcessInfo.processInfo.arguments.contains("-connections-preview") && saved?.hostName == "Studio") {
                    var thread: [String: Any] = composerRunningPreview
                        ? ["hydrated": true, "turns": [[
                            "id": "fixture-turn", "status": "inProgress", "startedAt": "1700000000000", "items": []
                        ]]]
                        : ["hydrated": true]
                    if projectRunningElsewherePreview {
                        // A turn the Claude desktop app is running on the Mac.
                        thread = ["hydrated": true, "turns": [[
                            "id": "fixture-turn", "status": "inProgress", "runningElsewhere": true, "items": [[
                                "id": "desktop-command", "type": "commandExecution", "state": "started",
                                "createdAt": "1700000001000", "payload": ["command": "swift test"]
                            ]]
                        ]]]
                    } else if projectTerminalTurnPreview {
                        thread = ["hydrated": true, "turns": [[
                            "id": "fixture-turn", "status": "interrupted", "items": [[
                                "id": "stopped-command", "type": "commandExecution", "state": "interrupted",
                                "createdAt": "1700000001000", "payload": ["command": "swift test"]
                            ], [
                                "id": "compact-stopped", "type": "contextCompaction", "state": "interrupted",
                                "createdAt": "1700000002000"
                            ]]
                        ]]]
                    }
                    var assistantMessages: [[String: Any]] = [[
                        "messageId": "2", "codexTurnId": "fixture-turn", "itemId": "fixture-item",
                        "text": "Start with breakfast at home, then take a walk. Leave the afternoon open so the day stays flexible.",
                        "state": "completed", "createdAt": "1700000001000", "updatedAt": "1700000001000"
                    ]]
                    if projectTerminalTurnPreview { assistantMessages = [] }
                    if composerQueuedPreview {
                        assistantMessages = []
                        for index in 1...14 {
                            let timestamp = String(1_700_000_001_000 + index * 1000)
                            assistantMessages.append([
                                "messageId": "queued-fixture-\(index)", "codexTurnId": "fixture-turn-\(index)",
                                "itemId": "fixture-item-\(index)",
                                "text": "Planning note \(index): keep the conversation readable while a queued message remains anchored after the history.",
                                "state": "completed", "createdAt": timestamp, "updatedAt": timestamp
                            ])
                        }
                    }
                    let fixture: [String: Any] = [
                        "conversationId": "preview", "hostEpoch": "preview", "lastSequence": 1,
                        "messages": [["messageId": "1", "body": messageAttachmentsPreview ? "Here are the reference images and notes." : "Can you help me plan a relaxed Saturday?", "state": (ProcessInfo.processInfo.arguments.contains("-active-preview") || composerRunningPreview) ? "streaming" : "completed", "codexTurnId": "fixture-turn", "codexThreadId": "fixture-thread", "createdAt": "1700000000000", "attachmentIds": messageAttachmentsPreview ? ["message-image-1", "message-image-2", "message-notes"] : []]]
                            + (projectOpenOnMacPreview ? [["messageId": "2", "body": "Also check the tests.", "state": "accepted_by_wonder", "createdAt": "1700000002000", "attachmentIds": [String]()]] : []),
                        "assistantMessages": assistantMessages,
                        "thread": thread
                    ]
                    let projectFilesConversation = arguments.contains("-project-files-conversation-preview") || projectTerminalTurnPreview
                    var summary: [String: Any] = ["conversationId": "preview", "botId": "ada", "title": "Ada", "lastMessagePreview": "Leave the afternoon open so the day stays flexible.", "messageCount": 2, "hasUnread": false, "isArchived": false, "isPinned": false]
                    if projectFilesConversation { summary["botId"] = nil; summary["title"] = "Project notes" }
                    if let data = try? JSONSerialization.data(withJSONObject: fixture),
                       let snapshot = try? JSONDecoder().decode(ConversationSnapshot.self, from: data),
                       let data = try? JSONSerialization.data(withJSONObject: summary),
                       let chat = try? JSONDecoder().decode(ChatSummary.self, from: data) {
                        groups = [:]; snapshots = ["preview": snapshot]; chats = [chat]
                        if projectFilesConversation {
                            let projectDetail: [String: Any] = [
                                "conversationId": "preview", "projectId": "preview-project", "projectName": "Preview project",
                                "title": "Project notes", "family": "codex", "accessMode": "workspace",
                                "workingFolder": "/preview", "workingFolderName": "Preview", "isPinned": false,
                                "hasUnread": false, "hasNativeSession": true, "folderInProject": true
                            ]
                            if let data = try? JSONSerialization.data(withJSONObject: projectDetail),
                               let detail = try? JSONDecoder().decode(ProjectConversationDetail.self, from: data) {
                                #if WONDER_DIAGNOSTICS
                                projects.installPreviewFilesConversation(detail)
                                #endif
                            }
                            if arguments.contains("-project-goal-preview"),
                               let goal = try? JSONDecoder().decode(ConversationGoal.self, from: Data(#"{"objective":"Review the Project plan","status":"active","timeBudgetSeconds":600,"timeUsedSeconds":60}"#.utf8)) {
                                goals["preview"] = goal
                            }
                        }
                        let botFixture: [String: Any] = ["id":"ada", "name":"Ada", "role":"Planning", "systemPrompt":"", "workspacePath":"/preview", "permissionProfile":":workspace", "permissionMode":"workspace", "approvalMode":"ask-for-approval", "model":"preview-model", "reasoningEffort":"medium", "serviceTier":"priority", "isArchived":false, "conversationId":"preview"]
                        if let data = try? JSONSerialization.data(withJSONObject: botFixture), let bot = try? JSONDecoder().decode(ManagedBot.self, from: data) { managedBots = [bot] }

                        var intent = ComposerIntent(); intent.draft = "Keep the evening free too."
                        if ProcessInfo.processInfo.arguments.contains("-send-unconfirmed-preview") {
                            try? intent.begin(device: "preview")
                            intent.draft = "Tomorrow works too."
                        }
                        if ProcessInfo.processInfo.arguments.contains("-files-preview") || composerAttachmentsPreview || composerQueuedPreview {
                            intent.stagedFiles = [try! StagedFile(id: "composer-file", name: "weekend-notes.txt", mimeType: "text/plain", data: Data("Keep Saturday relaxed. Leave Sunday free.".utf8))]
                            let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 420)).pdfData { context in
                                context.beginPage()
                                ("Weekend notes\n\nSaturday: breakfast and a walk.\nSunday: free time." as NSString).draw(in: CGRect(x: 24, y: 24, width: 252, height: 360), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
                                if arguments.contains("-artifact-annotation-preview") {
                                    context.beginPage()
                                    ("Second page\n\nReview the schedule." as NSString).draw(in: CGRect(x: 24, y: 24, width: 252, height: 360), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
                                }
                            }
                            let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 180)).pngData { context in
                                UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0,y: 0,width: 300,height: 180))
                                ("Saturday" as NSString).draw(at: CGPoint(x: 24,y: 70),withAttributes: [.font:UIFont.systemFont(ofSize: 28),.foregroundColor:UIColor.white])
                            }
                            let samples: [(String,String,Data)] = [("notes.pdf","application/pdf",pdf),("Saturday.png","image/png",image),("notes.txt","text/plain",Data("Saturday: breakfast and a walk. Sunday: free time.".utf8)),("planner.html","text/html",Data("<h1>Weekend planner</h1><button onclick=\"this.textContent='Saturday selected'\">Choose Saturday</button>".utf8))]
                            var list: [ConversationFile] = []
                            for (name,mime,data) in samples {
                                let value: [String:Any] = ["id":name,"name":name,"mimeType":mime,"byteSize":data.count,"sha256":ConversationFile.digest(data),"state":"available","updatedAt":"Synthetic fixture"]
                                if let file = try? JSONDecoder().decode(ConversationFile.self,from: JSONSerialization.data(withJSONObject:value)) { list.append(file); previewBytes[file.id] = data }
                            }
                            if arguments.contains("-preview-malformed-image") {
                                let data = Data("not an image".utf8)
                                let value: [String:Any] = ["id":"broken.png","name":"broken.png","mimeType":"image/png","byteSize":data.count,"sha256":ConversationFile.digest(data),"state":"available","updatedAt":"Synthetic fixture"]
                                if let file = try? JSONDecoder().decode(ConversationFile.self,from:JSONSerialization.data(withJSONObject:value)) { list.append(file); previewBytes[file.id] = data }
                            }
                            files["preview"] = list
                        }
                        if composerAttachmentsPreview {
                            let image = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 240)).pngData { context in
                                UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 360, height: 240))
                                UIColor.white.setFill(); context.fill(CGRect(x: 36, y: 42, width: 288, height: 126))
                                UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 58, y: 64, width: 100, height: 82))
                                UIColor.systemTeal.setFill(); context.fill(CGRect(x: 176, y: 64, width: 126, height: 82))
                            }
                            intent.stagedFiles = [
                                try! StagedFile(id: "composer-photo", name: "Saturday-plan.png", mimeType: "image/png", data: image),
                                try! StagedFile(id: "composer-file", name: "weekend-notes.txt", mimeType: "text/plain", data: Data("Keep Saturday relaxed. Leave Sunday free.".utf8))
                            ]
                        }
                        if composerRestoredPreview {
                            intent.stagedFiles = nil
                            intent.draftAttachmentIds = ["restored-photo", "missing-restored-file"]
                            let restoredImage = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 240)).pngData { context in
                                UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 360, height: 240))
                                UIColor.white.setFill(); context.fill(CGRect(x: 28, y: 28, width: 304, height: 184))
                                UIColor.systemOrange.setFill(); context.fill(CGRect(x: 52, y: 52, width: 108, height: 136))
                                UIColor.systemPink.setFill(); context.fill(CGRect(x: 180, y: 52, width: 128, height: 136))
                            }
                            previewBytes["restored-photo"] = restoredImage
                            let metadata: [[String: Any]] = [
                                ["id": "restored-photo", "name": "Saturday-plan.png", "mimeType": "image/png", "byteSize": restoredImage.count, "sha256": ConversationFile.digest(restoredImage), "state": "available", "updatedAt": "Synthetic fixture" ]
                            ]
                            files["preview"] = metadata.compactMap { value in
                                try? JSONDecoder().decode(ConversationFile.self, from: JSONSerialization.data(withJSONObject: value))
                            }
                        }
                        if messageAttachmentsPreview {
                            func fixtureImage(_ background: UIColor, _ foreground: UIColor, _ title: String) -> Data {
                                UIGraphicsImageRenderer(size: CGSize(width: 360, height: 240)).pngData { context in
                                    background.setFill(); context.fill(CGRect(x: 0, y: 0, width: 360, height: 240))
                                    foreground.setFill(); context.fill(CGRect(x: 28, y: 28, width: 304, height: 184))
                                    (title as NSString).draw(at: CGPoint(x: 48, y: 98), withAttributes: [
                                        .font: UIFont.systemFont(ofSize: 26, weight: .semibold),
                                        .foregroundColor: background
                                    ])
                                }
                            }
                            let samples: [(String, String, Data)] = [
                                ("message-image-1", "reference-one.png", fixtureImage(.systemIndigo, .white, "Reference one")),
                                ("message-image-2", "reference-two.png", fixtureImage(.systemTeal, .white, "Reference two")),
                                ("message-notes", "reference-notes.txt", Data("Keep the two reference images together.".utf8))
                            ]
                            var list: [ConversationFile] = []
                            for (id, name, data) in samples {
                                let mime = name.hasSuffix(".png") ? "image/png" : "text/plain"
                                let value: [String: Any] = ["id": id, "name": name, "mimeType": mime, "byteSize": data.count,
                                    "sha256": ConversationFile.digest(data), "state": "available", "updatedAt": "Synthetic message fixture"]
                                if let file = try? JSONDecoder().decode(ConversationFile.self, from: JSONSerialization.data(withJSONObject: value)) {
                                    list.append(file)
                                    previewBytes[file.id] = data
                                }
                            }
                            files["preview"] = list
                        }
                        composers["preview"] = intent
                    }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-queue-preview") || composerQueuedPreview {
                let json = """
                [{"id":"one","clientMessageId":"one","body":"Find a walking route for Saturday.","revision":2,"attachmentIds":[]},{"id":"two","clientMessageId":"two","body":"Summarize the plan in the attached notes.","revision":1,"attachmentIds":["Saturday.png","notes.txt"]}]
                """
                queues["preview"] = try? JSONDecoder().decode([QueuedMessage].self,from:Data(json.utf8))
            }
            if ProcessInfo.processInfo.arguments.contains("-async-question-preview") || ProcessInfo.processInfo.arguments.contains("-answered-question-preview") {
                var fixture: [String:Any] = ["id":"async-fixture", "conversationId":"preview", "turnId":"fixture-turn", "itemId":"fixture-item", "questions":[["title":"Which day works best?", "options":["Saturday", "Sunday"]]], "state":"pending", "expiresAtMs":UInt64(Date().timeIntervalSince1970 * 1000) + 300_000]
                if ProcessInfo.processInfo.arguments.contains("-answered-question-preview") {
                    fixture["state"] = "answered"
                    fixture["response"] = ["answers":["Saturday"], "skip":false]
                }
                if let data = try? JSONSerialization.data(withJSONObject: fixture), let value = try? JSONDecoder().decode(AsyncQuestion.self,from:data) { asyncQuestions["preview"] = [value] }
            }
            if arguments.contains("-native-question-history-preview") {
                let reply = #"<send_user_message_question_reply>[{"questionItemId":"[\"request_user_input_async\",\"native-history-question\",0]","question":"Which day works best?","answer":"Saturday"},{"questionItemId":"[\"request_user_input_async\",\"native-history-question\",1]","question":"What should we check?","answer":"Navigation"}]</send_user_message_question_reply>"#
                let fixture: [String: Any] = ["conversationId":"preview", "hostEpoch":"preview", "lastSequence":1,
                    "messages":[], "assistantMessages":[], "thread":["hydrated":true, "turns":[["id":"native-history-turn", "status":"completed", "items":[
                        ["id":"native-history-question", "type":"agentMessage", "state":"completed", "text":"Which day works best?", "createdAt":"1000", "payload":["delivery":"async", "questions":[["title":"Which day works best?", "options":["Saturday", "Sunday"]], ["title":"What should we check?"]]]],
                        ["id":"native-history-answer", "type":"userMessage", "state":"completed", "text":reply, "createdAt":"2000"],
                        ["id":"native-history-final", "type":"agentMessage", "state":"completed", "text":"The saved reply is available.", "createdAt":"3000"]
                    ]]]]]
                if let data = try? JSONSerialization.data(withJSONObject: fixture),
                   let snapshot = try? JSONDecoder().decode(ConversationSnapshot.self, from: data) {
                    groups.removeValue(forKey: "preview")
                    snapshots["preview"] = snapshot
                }
            }
            if arguments.contains("-computer-approval-preview") {
                let fixture: [String: Any] = ["approvalId":"fixture-computer", "conversationId":"preview", "method":"item/tool/call", "actionNonce":"fixture", "params":["threadId":"fixture-thread", "turnId":"fixture-turn", "tool":"wonder_computer_use", "arguments":["action":"screenshot"]]]
                if let data = try? JSONSerialization.data(withJSONObject: fixture), let value = try? JSONDecoder().decode(AttentionRequest.self, from: data) { attention = [value] }
            }
            if let index = arguments.firstIndex(of: "-phone-approval-preview"), arguments.indices.contains(index + 1) {
                let fixtures: [String: String] = [
                    "command": #"{"approvalId":"fixture-command","conversationId":"preview","method":"item/commandExecution/requestApproval","actionNonce":"fixture","params":{"threadId":"fixture-thread","turnId":"fixture-turn","command":"convert original.png output.png","availableDecisions":["accept","acceptForSession",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["convert"]}},"decline","cancel"]}}"#,
                    "network": #"{"approvalId":"fixture-network","conversationId":"preview","method":"item/commandExecution/requestApproval","actionNonce":"fixture","params":{"threadId":"fixture-thread","turnId":"fixture-turn","networkApprovalContext":{"host":"example.com","protocol":"https"},"availableDecisions":["accept",{"applyNetworkPolicyAmendment":{"network_policy_amendment":{"host":"example.com","action":"allow"}}},"decline"]}}"#,
                    "file": #"{"approvalId":"fixture-file","conversationId":"preview","method":"item/fileChange/requestApproval","actionNonce":"fixture","params":{"threadId":"fixture-thread","turnId":"fixture-turn","grantRoot":"/Users/example/Movies","reason":"Save the upscaled copy."}}"#,
                    "permissions": #"{"approvalId":"fixture-permissions","conversationId":"preview","method":"item/permissions/requestApproval","actionNonce":"fixture","params":{"threadId":"fixture-thread","turnId":"fixture-turn","permissions":{"fileSystem":{"read":["/Users/example/Movies"]},"network":{"enabled":true}}}}"#,
                    "form": #"{"approvalId":"fixture-form","conversationId":"preview","method":"mcpServer/elicitation/request","actionNonce":"fixture","params":{"threadId":"fixture-thread","turnId":"fixture-turn","mode":"form","serverName":"Example","message":"Choose export settings.","requestedSchema":{"type":"object","properties":{"quality":{"type":"string","title":"Quality","enum":["Standard","High"]},"copies":{"type":"integer","title":"Copies","minimum":1,"maximum":5},"watermark":{"type":"boolean","title":"Watermark"}},"required":["quality","copies"]}}}"#,
                    "native": #"{"approvalId":"fixture-native","conversationId":"preview","method":"mcpServer/elicitation/request","actionNonce":"fixture","params":{"threadId":"fixture-thread","turnId":"fixture-turn","mode":"form","message":"Allow Computer Use to use Calculator?","requestedSchema":{"type":"object","properties":{}},"elicitationContext":{"isComputerUse":true,"riskLevel":"low","details":["App: Calculator"]}}}"#,
                    "url": #"{"approvalId":"fixture-url","conversationId":"preview","method":"mcpServer/elicitation/request","actionNonce":"fixture","params":{"threadId":"fixture-thread","turnId":"fixture-turn","mode":"url","message":"Connect the export service.","url":"https://example.com/authorize"}}"#,
                    "unknown": #"{"approvalId":"fixture-unknown","conversationId":"preview","method":"item/tool/call","actionNonce":"fixture","params":{"threadId":"fixture-thread","turnId":"fixture-turn","tool":"unknown_tool","arguments":{"secret":"not exposed"}}}"#,
                ]
                if let json = fixtures[arguments[index + 1]], let value = try? JSONDecoder().decode(AttentionRequest.self, from: Data(json.utf8)) { attention = [value] }
            }
            if ProcessInfo.processInfo.arguments.contains("-question-preview") {
                let json = """
                {"approvalId":"fixture-question","method":"item/tool/requestUserInput","actionNonce":"fixture","params":{"threadId":"fixture-thread","isBlocking":false,"questions":[{"id":"day","question":"Which day works best?","options":[{"label":"Saturday","description":"Keep Sunday free."},{"label":"Sunday"}]},{"id":"fixtures","question":"Which fixtures should I check?","multiSelect":true,"options":[{"label":"A, B"},{"label":"C"}]}]}}
                """
                if let value = try? JSONDecoder().decode(AttentionRequest.self, from: Data(json.utf8)) { attention = [value] }
            }
            if ProcessInfo.processInfo.arguments.contains("-activity-preview") {
                let failed = ProcessInfo.processInfo.arguments.contains("-activity-failure-preview")
                let commandFailed = ProcessInfo.processInfo.arguments.contains("-activity-command-failure-preview")
                let running = ProcessInfo.processInfo.arguments.contains("-activity-running-preview")
                let mixed = ProcessInfo.processInfo.arguments.contains("-activity-mixed-preview")
                var finalPayload: [String: Any] = ["phase":"final_answer"]
                var toolPayload: [String: Any] = failed
                    ? ["tool":"fetch_document", "error":"The document service is unavailable. Try again later."]
                    : ["tool":"fetch_document", "arguments":["document":"Project notes"], "result":["text":"Keep the chat compact and accessible."]]
                if mixed {
                    let data = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 240)).pngData { context in
                        UIColor.secondarySystemBackground.setFill(); context.fill(CGRect(x: 0, y: 0, width: 480, height: 240))
                        ("Project notes" as NSString).draw(at: CGPoint(x: 24, y: 24), withAttributes: [.font: UIFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: UIColor.label])
                        for (index, height) in [55, 92, 126, 105, 142].enumerated() {
                            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 32 + index * 84, y: 210 - height, width: 44, height: height))
                        }
                    }
                    let file: [String: Any] = ["id":"tool-preview", "name":"Project notes.png", "mimeType":"image/png", "byteSize":data.count, "sha256":ConversationFile.digest(data), "state":"available", "updatedAt":"Synthetic fixture"]
                    previewBytes["tool-preview"] = data
                    toolPayload["result"] = ["content":[["type":"text", "text":"Found a chart in the project notes."], ["type":"wonderArtifact", "file":file]]]
                    if ProcessInfo.processInfo.arguments.contains("-activity-final-image-preview") {
                        var finalFile = file
                        finalFile["id"] = "final-preview"; finalFile["name"] = "Final chart.png"
                        previewBytes["final-preview"] = data
                        finalPayload["contentItems"] = [["type":"wonderArtifact", "file":finalFile]]
                    }
                }
                let markdownReply = """
                ## Summary
                The tests passed. I updated the **chat labels** and checked the `project notes`.

                - Labels read naturally
                - Notes stay in sync
                1. Run the tests
                2. Review the diff

                > Remaining work is optional.

                | File | Change |
                |------|--------|
                | ChatView.swift | Labels |
                """
                let reply = commandFailed ? "The test command failed. I checked the remaining project files and notes." : failed ? "The tests passed, but I couldn’t load the project notes." : ProcessInfo.processInfo.arguments.contains("-markdown-reply-preview") ? markdownReply : "The tests passed. I updated the chat labels and checked the project notes."
                let toolState = failed ? "failed" : running ? "streaming" : "completed"
                var items: [[String: Any]] = [
                    ["id":"echo", "type":"userMessage", "state":"completed", "text":"Runtime input wrapper", "createdAt":"0", "payload":["clientId":"fixture-user"]],
                    ["id":"command", "type":"commandExecution", "state":"completed", "createdAt":"2000", "payload":["command":"swift test", "cwd":"project", "output":"Executed 30 tests, with 0 failures.", "exitCode":0]],
                    ["id":"search", "type":"webSearch", "state":"completed", "createdAt":"3000", "payload":["query":"SwiftUI accessibility labels", "resultCount":3]],
                    ["id":"files", "type":"fileChange", "state":"completed", "createdAt":"4000", "payload":["paths":["Sources/ChatView.swift"], "additions":12, "deletions":4]],
                    ["id":"tool", "type":"mcpToolCall", "state":toolState, "createdAt":"5000", "payload":toolPayload],
                    ["id":"reply", "type":"agentMessage", "state":"completed", "text":reply, "createdAt":"6000", "payload":finalPayload]
                ]
                if commandFailed {
                    items[1] = ["id":"command", "type":"commandExecution", "state":"failed", "createdAt":"2000", "payload":["command":"swift test", "cwd":"project", "output":"The test command could not complete.", "exitCode":1]]
                }
                if ProcessInfo.processInfo.arguments.contains("-response-edits-preview") {
                    let paths = ["Sources/ChatView.swift", "Tests/ChatViewTests.swift", "Documentation/Changes.md", "Sources/Long folder name/Accessible layout.swift"]
                    let diffs = paths.map { path in
                        // The last saved patch is shorter than its counts, like a host-capped diff.
                        ["path": path, "kind": "update", "additions": path == paths.last ? 40 : 2, "deletions": 1,
                         "diff": "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n@@ -12,2 +12,3 @@\n let title = \"Wonder\"\n-let label = \"Files\"\n+let label = \"Edited files\"\n+let accessible = true\n"] as [String: Any]
                    }
                    items[3]["payload"] = ["paths": paths, "diffs": diffs]
                }
                if mixed {
                    items.insert(["id":"z-commentary", "type":"agentMessage", "state":"completed", "text":"I’ll check the project files and notes.", "createdAt":"1500", "payload":["phase":"commentary"]], at: 1)
                }
                let fixture: [String: Any] = ["conversationId":"preview", "hostEpoch":"fixture", "lastSequence":1,
                    "messages":[["messageId":"stored", "clientMessageId":"fixture-user", "codexTurnId":"turn", "body":"Check the project and summarize the changes.", "state":running ? "streaming" : "completed", "createdAt":"1000", "attachmentIds":[]]],
                    "assistantMessages":[], "thread":["hydrated":true, "turns":[["id":"turn", "status":running ? "inProgress" : "completed", "items":running ? Array(items.dropLast()) : items]]]]
                if let data = try? JSONSerialization.data(withJSONObject: fixture),
                   let snapshot = try? JSONDecoder().decode(ConversationSnapshot.self, from: data) {
                    groups.removeValue(forKey: "preview")
                    snapshots["preview"] = snapshot
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-profile-preview") {
                let fixture: [String: Any] = ["conversationId":"preview", "hostEpoch":"preview", "lastSequence":1,
                    "messages":[["messageId":"stored", "clientMessageId":"fixture-user", "codexTurnId":"turn", "body":"Please call yourself iOS Scout and help me plan native iPhone apps. What should we work on first?", "state":"completed", "createdAt":"1000", "attachmentIds":[]]],
                    "assistantMessages":[], "thread":["hydrated":true, "turns":[["id":"turn", "items":[
                        ["id":"rename", "type":"dynamicToolCall", "state":"completed", "createdAt":"2000", "payload":["tool":"wonder_update_profile", "success":true, "contentItems":[["type":"inputText", "text":#"{"saved":true,"name":"iOS Scout","statusLine":"Renamed to iOS Scout"}"#]]]],
                        ["id":"reply", "type":"agentMessage", "state":"completed", "createdAt":"3000", "text":"Let’s start with the app idea: what problem should it solve, and who is it for? Share a rough concept, or choose:\n\n- Personal productivity\n- Health and fitness\n- Social or community\n- Creative tool"]
                    ]]]]]
                let summary: [String: Any] = ["conversationId":"preview", "botId":"ada", "title":"iOS Scout", "lastMessagePreview":"Let’s start with the app idea: what problem should it solve, and who is it for?", "messageCount":2, "hasUnread":false, "isArchived":false, "isPinned":false]
                if let data = try? JSONSerialization.data(withJSONObject: fixture), let snapshot = try? JSONDecoder().decode(ConversationSnapshot.self, from: data),
                   let data = try? JSONSerialization.data(withJSONObject: summary), let chat = try? JSONDecoder().decode(ChatSummary.self, from: data) {
                    groups = [:]; snapshots = ["preview":snapshot]; chats = [chat]; composers["preview"] = ComposerIntent()
                }
            }
            return
        }
        #endif
        do {
            if persistConnection != nil {
                connection = saved
                if saved != nil { status = "Checking your computer…" }
            } else if let data = try identity.read("connection") {
                connection = try JSONDecoder().decode(SavedConnection.self, from: data)
                status = "Checking your computer…"
            }
        } catch { self.error = error.localizedDescription }
        if connection?.requiresPairing == true { stopForIdentityRecovery() }
    }

    #if WONDER_DIAGNOSTICS
    /// Creates an offline diagnostics model with the same durable composer
    /// boundary used by a paired connection. No network API is invoked.
    init(cameraFixtureStoreRoot root: URL, saved: SavedConnection, chat: ChatSummary? = nil, initialIntent: ComposerIntent = ComposerIntent(), api: PairingAPI? = nil, replayEnabled: Bool = true, signingIdentity: SigningIdentity = PhoneIdentity.signing) {
        self.signingIdentity = signingIdentity
        // Synthetic connection checks must never replace the app's pairing.
        persistConnection = { _ in }
        diagnosticReplayEnabled = replayEnabled
        #if WONDER_DIAGNOSTICS
        self.api = api ?? Self.diagnosticAPI()
        #else
        self.api = api ?? PairingAPI()
        #endif
        connection = saved
        let fixtureStore = ReadStore(root: root, host: saved.credential.hostInstallationId, device: saved.storageDeviceId)
        store = fixtureStore
        writer = makeWriter(fixtureStore)
        partition = saved.credential.hostInstallationId + ":" + saved.credential.deviceId
        chats = chat.map { [$0] } ?? []
        selectedChat = chat
        visibleChat = chat
        macConnected = true
        hasConnectedThisLaunch = true
        status = "Connected to your computer."
        chatsStatus = "Saved chats"
        if let chat {
            do {
                if try fixtureStore.loadIntent(conversation: chat.id) != nil {
                    composers[chat.id] = try fixtureStore.loadComposer(conversation: chat.id)
                } else {
                    try fixtureStore.saveComposer(initialIntent, conversation: chat.id)
                    composers[chat.id] = initialIntent
                }
            } catch {
                composers[chat.id] = initialIntent
                intentLoadFailures.insert(chat.id)
                composerErrors[chat.id] = "The camera fixture draft could not be read."
            }
        }
    }

    func reloadCameraFixtureDraft(_ chat: String) {
        composers[chat] = nil
        loadComposer(chat)
    }
    #endif

    func loadCodexUsage(force: Bool = false) async throws {
        try await loadUsage(family: .codex, force: force)
    }
    func loadUsage(family: AgentFamily, force: Bool = false, maxAge: TimeInterval = 300) async throws {
        guard let saved = connection, !accessEnded else { return }
        let scope = assignmentScope
        let origin = saved.origin
        if !force, let cached = (family == .claude ? claudeUsageCache : codexUsageCache)[scope], Date().timeIntervalSince(cached.fetchedAt) < maxAge {
            return
        }

        #if WONDER_DIAGNOSTICS
        if family == .codex, codexUsageCache[scope] != nil, ProcessInfo.processInfo.arguments.contains("-diagnostics-usage-refresh-fails") {
            throw PairingFailure.response(503)
        }
        if family == .codex, ProcessInfo.processInfo.arguments.contains("-diagnostics-usage-unsupported") {
            throw PairingFailure.response(501)
        }
        if family == .codex, ProcessInfo.processInfo.arguments.contains("-diagnostics-usage-unavailable") {
            throw PairingFailure.response(503)
        }
        if ProcessInfo.processInfo.arguments.contains("-diagnostics-usage-fixture") {
            let exhausted = ProcessInfo.processInfo.arguments.contains("-diagnostics-usage-exhausted")
            let empty = family == .codex && ProcessInfo.processInfo.arguments.contains("-diagnostics-usage-empty")
            let fixture = CodexUsageResponse(
                agentFamily: family.rawValue,
                checkedAtMs: 1_700_000_000_000,
                windows: empty ? [] : [
                    CodexUsageWindow(id: family == .claude ? "five_hour" : "five-hours", label: "5 hours", usedPercent: exhausted ? 100 : (family == .claude ? 14 : 27), remainingPercent: exhausted ? 0 : (family == .claude ? 86 : 73), windowDurationMins: 300, resetsAt: 1_700_018_000_000),
                    CodexUsageWindow(id: family == .claude ? "seven_day" : "weekly", label: "Weekly", usedPercent: family == .claude ? 8 : 41, remainingPercent: family == .claude ? 92 : 59, windowDurationMins: 10_080, resetsAt: 1_700_604_800_000)
                ]
            )
            guard scope == assignmentScope, connection?.origin == origin, !accessEnded else { return }
            if family == .claude { claudeUsageCache[scope] = CodexUsageCacheEntry(response: fixture, fetchedAt: Date()) }
            else { codexUsageCache[scope] = CodexUsageCacheEntry(response: fixture, fetchedAt: Date()) }
            return
        }
        #endif

        let path = "/api/v1/account/usage" + (family == .claude ? "?agentFamily=claude" : "")
        let response: CodexUsageResponse = try await api.request(path, origin: saved.origin, credential: saved.credential)
        guard scope == assignmentScope, connection?.origin == origin, !accessEnded else { return }
        guard response.agentFamily == family.rawValue || (family == .codex && response.agentFamily == nil) else { throw ReadFailure.resync }
        if family == .claude { claudeUsageCache[scope] = CodexUsageCacheEntry(response: response, fetchedAt: Date()) }
        else { codexUsageCache[scope] = CodexUsageCacheEntry(response: response, fetchedAt: Date()) }
    }

    func pair(link: String, address: String, code: String) {
        guard !busy else { return }
        busy = true; error = nil; verification = nil; status = "Contacting your computer…"
        enrollment = Task {
            defer { busy = false; verification = nil }
            do {
                try Task.checkCancellation()
                let origin: String, body: Data, path: String, expectedHost: String?, expectedOffer: String?
                // Validate the input before any identity recovery. Preflight the
                // signing operation before consuming the Mac's single-use offer.
                if !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { _ = try PairingLink(link) }
                else { _ = try PairingLink.origin(address) }
                let enrollmentIdentity = try await signingIdentity.prepareForEnrollment { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.requireIdentityRepair()
                }
                try Task.checkCancellation()
                let key = enrollmentIdentity.publicKey
                if !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let parsed = try PairingLink(link)
                    origin = parsed.origin; expectedHost = parsed.hostID; expectedOffer = parsed.offerID; path = "/api/v1/pairing/claim"
                    struct Request: Encodable { let offerId: String; let secret: String; let publicKey: PublicKey; let label: String; let sessionExpiration = "never" }
                    body = try JSONEncoder().encode(Request(offerId: parsed.offerID, secret: parsed.secret, publicKey: key, label: UIDevice.current.name))
                } else {
                    origin = try PairingLink.origin(address); expectedHost = nil; expectedOffer = nil; path = "/api/v1/pairing/code"
                    struct Request: Encodable { let humanCode: String; let publicKey: PublicKey; let label: String; let sessionExpiration = "never" }
                    body = try JSONEncoder().encode(Request(humanCode: code.trimmingCharacters(in: .whitespacesAndNewlines), publicKey: key, label: UIDevice.current.name))
                }
                try await signingIdentity.validateCurrent(enrollmentIdentity)
                try Task.checkCancellation()
                try enrollmentIdentity.checkCurrent()
                let claim: Claim = try await api.request(path, origin: origin, body: body)
                try Task.checkCancellation()
                try claim.challenge.validate(origin: origin, hostID: expectedHost, deviceID: claim.deviceId)
                guard expectedOffer == nil || claim.challenge.offerId == expectedOffer else { throw PairingFailure.wrongHost }
                verification = claim.challenge.verificationCode
                status = "Confirm this device in Wonder on your computer. Check that the verification text matches."
                struct Signed: Encodable { let challengeId: String; let signature: String }
                let signature = try await signingIdentity.sign(claim.challenge.transcript, using: enrollmentIdentity)
                try Task.checkCancellation()
                let signed = try JSONEncoder().encode(Signed(challengeId: claim.challenge.challengeId, signature: signature))
                while !Task.isCancelled {
                    try claim.challenge.validate(origin: origin, hostID: claim.challenge.hostInstallationId, deviceID: claim.deviceId)
                    do {
                        let credential: Credential = try await api.request("/api/v1/pairing/session", origin: origin, body: signed)
                        try Task.checkCancellation()
                        guard credential.deviceId == claim.deviceId, credential.hostInstallationId == claim.challenge.hostInstallationId else { throw PairingFailure.wrongHost }
                        try await signingIdentity.validateCurrent(enrollmentIdentity)
                        try Task.checkCancellation()
                        try enrollmentIdentity.checkCurrent()
                        let saved = SavedConnection(origin: origin, credential: credential)
                            .preservingStorage(from: previousPairingConnection?(credential.hostInstallationId))
                        try saveConnection(saved)
                        connection = saved; status = "Phone paired. Checking your computer…"
                        break
                    } catch PairingFailure.response(409) { try await Task.sleep(for: .seconds(2)) }
                }
            } catch is CancellationError { status = "Pairing stopped. Reject the request on your computer if it is still waiting." }
            catch {
                if SigningIdentityFailure.requiresPairing(error) {
                    try? requireIdentityRepair()
                    self.error = SigningIdentityFailure.invalidated.localizedDescription
                } else { self.error = error.localizedDescription }
                status = "Phone not connected."
            }
        }
    }
    func cancel() { enrollment?.cancel() }

    private func requireIdentityRepair() throws {
        if let identityNeedsRepair { try identityNeedsRepair() }
        else if var saved = connection {
            saved.requiresPairing = true
            stopForIdentityRecovery()
            try saveConnection(saved)
        }
    }

    func stopForIdentityRecovery() {
        stopReading()
        // Network writers capture this namespace before awaiting. Retire it
        // without changing the disk directory or discarding readable drafts.
        partition = "identity-recovery:" + UUID().uuidString
        connectionCheck?.cancel()
        connectionCheck = nil
        if connection != nil { connection?.requiresPairing = true }
        macConnected = false
        accessEnded = true
        status = "This iPhone’s connection needs to be set up again."
        chatsStatus = "Pair again to reconnect."
        cachedConversationIds = Set(snapshots.keys).union(groups.keys)
    }

    func retireAfterPairingReplacement() {
        stopForIdentityRecovery()
        retiredAfterPairing = true
        // A replacement model's cache load is queued behind this final write.
        writer?.retire(); writer = nil
        store = nil
    }

    func setForeground(_ active: Bool) {
        guard !previewMode else { return }
        dictation.foreground(active)
        foreground = active
        if !active {
            stopReading()
            chatsStatus = "Saved chats"
            macConnected = nil
            // Replay stops here, so saved chats are unverified until the next
            // foreground refresh. Persist that with the cursor before suspension.
            projection.invalidateAll()
            cachedConversationIds = projection.dirty
            if let writer {
                writer.schedule(projection)
                let task = UIApplication.shared.beginBackgroundTask(withName: "Save chats")
                writer.flush { Task { @MainActor in UIApplication.shared.endBackgroundTask(task) } }
            }
        } else {
            Task { await loadChats(force: true) }
        }
    }

    private func stopReading() {
        generation = UUID()
        replay?.cancel(); replay = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        refreshTask?.cancel(); refreshTask = nil
    }

    private static func readStore(for saved: SavedConnection) -> ReadStore {
        ReadStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wonder/Hosts"), host: saved.credential.hostInstallationId, device: saved.storageDeviceId)
    }

    private func makeWriter(_ store: ReadStore) -> ProjectionWriter {
        ProjectionWriter(store: store) { [weak self] result, elapsed in
            #if WONDER_DIAGNOSTICS
            if case .success(let bytes) = result {
                DiagnosticJournal.shared.record(DiagnosticEvent(operation: "persistence.save", durationMs: elapsed * 1000, bytes: UInt64(bytes)))
            }
            #endif
            guard case .failure = result else { return }
            Task { @MainActor [weak self] in
                self?.chatsStatus = "Chats could not be saved on this phone. Free some storage and refresh."
            }
        }
    }

    /// Restores this host's saved chats off the main thread. Network reads wait
    /// for it through `check()`, so an unloaded cache is never overwritten.
    private func prepare(_ saved: SavedConnection) async {
        guard !retiredAfterPairing else { return }
        let key = saved.credential.hostInstallationId + ":" + saved.credential.deviceId
        guard partition != key else { await preparation?.value; return }
        stopReading()
        partition = key
        projectSubagentLoadTokens = [:]
        projectSubagentAvailability = [:]
        projectSubagentLookup = [:]
        projectSubagentFreshIDs = [:]
        projectSubagentNextCurrentCursor = [:]
        projectSubagentNextArchivedCursor = [:]
        projectSubagentInitialCurrentCursor = [:]
        projectSubagentInitialArchivedCursor = [:]
        projectSubagentSeenCurrentCursors = [:]
        projectSubagentSeenArchivedCursors = [:]
        projectSubagentExpandedParents = []
        projectSubagentPagingLimited = []
        projectSubagentRefreshPending = []
        projectSubagentPageRevision = [:]
        loadingOlderProjectSubagents = []
        subagents = [:]; subagentAvailability = [:]; subagentErrors = [:]; projectSubagents = [:]; projectSubagentErrors = [:]; composers = [:]; composerErrors = [:]; sending = []; preparingSends = []; intentLoadFailures = []; attention = []; asyncQuestions = [:]; retryableAsyncReplies = []; savedAsyncReplies = [:]; attentionErrors = [:]; resolving = []; savedDecisions = [:]; files = [:]; queues = [:]; uploading = []; stopping = []; controlErrors = [:]; loadingConversationIDs = []; loadingTokens = [:]; conversationLoadFailures = [:]
        let store = Self.readStore(for: saved)
        self.store = store
        writer?.retire(); writer = nil
        selectedChat = nil
        let load = Task { [weak self] in
            #if WONDER_DIAGNOSTICS
            let loadStart = ProcessInfo.processInfo.systemUptime
            #endif
            let loaded: Result<ProjectionState, Error>
            do { loaded = .success(try await ProjectionWriter.load(store)) }
            catch { loaded = .failure(error) }
            guard !Task.isCancelled, let self, self.partition == key else { return }
            switch loaded {
            case .success(var state):
                state.invalidateAll()
                self.projection = state
            case .failure:
                self.projection = ProjectionState()
                self.chatsStatus = "Saved chats could not be read. Reconnect to refresh."
            }
            #if WONDER_DIAGNOSTICS
            DiagnosticJournal.shared.record(DiagnosticEvent(operation: "persistence.load", durationMs: (ProcessInfo.processInfo.systemUptime - loadStart) * 1000, count: UInt64(self.projection.snapshots.count)))
            #endif
            self.managedBotMutations = ManagedBotListMutationState()
            self.writer = self.makeWriter(store)
            self.publish(.everything)
            self.dictation.restore(force: true)
        }
        preparation = load
        await load.value
    }

    private struct PublishScope: OptionSet {
        let rawValue: Int
        static let list = PublishScope(rawValue: 1)
        static let snapshots = PublishScope(rawValue: 2)
        static let groups = PublishScope(rawValue: 4)
        static let everything: PublishScope = [.list, .snapshots, .groups]
    }

    /// Publishes only the parts of the projection a change touched. Replacing
    /// every snapshot on each list refresh or replay event re-projected the
    /// open conversation and re-rendered every observer.
    private func publish(_ scope: PublishScope) {
        #if WONDER_DIAGNOSTICS
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        defer { DiagnosticJournal.shared.record(DiagnosticEvent(operation: "projection", durationMs: (ProcessInfo.processInfo.systemUptime-diagnosticStart)*1000)) }
        #endif
        if scope.contains(.list) {
            managedBots = projection.managedBots ?? []
            let visible = projection.summaries.filter { !$0.isArchived }
            if chats != visible { chats = visible }
        }
        if scope.contains(.snapshots) { snapshots = projection.snapshots }
        if scope.contains(.groups) { groups = projection.groups }
        if cachedConversationIds != projection.dirty { cachedConversationIds = projection.dirty }
    }

    /// Updates memory and the screen now; the disk copy follows off the main
    /// thread (coalesced). Replay resumes from an older durable cursor if the
    /// app ends before a write, so a delayed write never loses host history.
    private func commit(_ next: ProjectionState, publishing scope: PublishScope = .everything) throws {
        guard let writer else { throw ReadFailure.resync }
        projection = next
        writer.schedule(next)
        publish(scope)
    }

    func loadChats(force: Bool = false) async {
        await loadChats(refreshVisibleConversation: true)
    }

    /// Creation needs the new list entry before navigation, not a refresh of
    /// the conversation that happened to be open behind the creation sheet.
    func refreshChatList() async {
        await loadChats(refreshVisibleConversation: false)
    }

    private func loadChats(refreshVisibleConversation: Bool) async {
        guard !previewMode else { return }
        // Startup and foreground reads must use the session established by the
        // shared check, not race renewal with the credential restored from disk.
        await check()
        guard let saved = connection, !accessEnded, macConnected == true else { return }
        await prepare(saved)
        if replay == nil && foreground { startReplay() }
        guard !loadingChats else { return }
        loadingChats = true
        defer { loadingChats = false }
        let run = generation
        do {
            try await refreshList(saved, run: run)
            if refreshVisibleConversation, let chat = visibleChat {
                if let parent = selectedChat {
                    if parent.botId != nil { await loadSubagents(parent) }
                    else if isProject(parent) { await loadProjectSubagents(parent) }
                }
                await refreshConversation(chat)
                await loadAsyncQuestions(chat)
                // Project sends use the same queue even though they have no Bot ID.
                if chat.botId != nil || isProject(chat) { try? await loadQueue(chat) }
                if composers[chat.id]?.pending != nil, composers[chat.id]?.pending?.receipt == nil {
                    await deliver(chat)
                }
            }
        }
        catch { readFailed(error, run: run) }
    }

    private func refreshList(_ saved: SavedConnection, run: UUID) async throws {
        listRefreshCount += 1
        defer { listRefreshCount -= 1 }
        let botMutationSnapshot = managedBotMutations.revision
        let cursor = projection.lastSequence
        async let summaryRequest: [ChatSummary] = api.request("/api/v1/conversations", origin: saved.origin, credential: saved.credential)
        async let groupRequest: [GroupRead] = api.request("/api/v1/group-chats", origin: saved.origin, credential: saved.credential)
        async let botRequest: [ManagedBot] = api.request("/api/v1/bots", origin: saved.origin, credential: saved.credential)
        let (remote, groupList, botList) = try await (summaryRequest, groupRequest, botRequest)
        guard run == generation else { throw CancellationError() }
        let effectiveBots = managedBotMutations.reconcile(botList, startedAt: botMutationSnapshot)
        let botIDs = Set(effectiveBots.map(\.id))
        let activeBotIDs = Set(effectiveBots.filter { !$0.isArchived }.map(\.id))
        let deleted = projection.summaries.filter { $0.botId.map { !botIDs.contains($0) } == true }
        for chat in deleted { try removeDeletedConversation(chat.id) }
        var next = projection
        next.managedBots = effectiveBots
        next.summaries = projectVisibleChatSummaries(remote: remote, groups: groupList, activeBotIDs: activeBotIDs)
        next.groups = Dictionary(uniqueKeysWithValues: groupList.map { ($0.conversationId, $0) })
        // The list read includes every change through `cursor`; a group stays
        // stale only if it was invalidated after the request began.
        for group in groupList where next.covers(group.conversationId, through: max(cursor, group.lastSequence ?? 0)) {
            next.markClean(group.conversationId)
        }
        next.listDirty = cursor != projection.lastSequence
        // Saved history is disposable. Keep it only for listed chats, their
        // known helper conversations and the chat on screen; archived Bots'
        // histories otherwise stay in every cache write indefinitely.
        var retained = Set(next.summaries.map(\.id)).union(subagents.values.flatMap { $0.map(\.conversationId) })
        if let visible = visibleChat?.id { retained.insert(visible) }
        // Project threads are not in the conversation list. Their saved history
        // stays for pinned threads and the most recently opened ones only.
        retained.formUnion(projects.retainedConversationIDs)
        let pruned = next.snapshots.keys.filter { !retained.contains($0) }
        for id in pruned { next.snapshots.removeValue(forKey: id); next.markClean(id) }
        try commit(next, publishing: pruned.isEmpty ? [.list, .groups] : .everything)
        macConnected = true
        chatsStatus = "Connected to your computer"
    }

    /// Applies only a server-confirmed Bot mutation. Callers must not mutate
    /// `managedBots` directly after a PATCH response, otherwise an older list
    /// request can overwrite the new avatar or settings.
    func applyConfirmedManagedBot(_ bot: ManagedBot) {
        managedBots = managedBotMutations.confirm(bot, current: managedBots)
        projection.managedBots = managedBots
        writer?.schedule(projection)
    }

    func subagentSummary(for conversationID: String) -> SubagentSummary? {
        subagents.values.lazy.flatMap { $0 }.first(where: { $0.conversationId == conversationID })
    }

    func isSubagent(_ chat: ChatSummary) -> Bool {
        subagentSummary(for: chat.id) != nil
    }

    func agentFamily(_ chat: ChatSummary) -> AgentFamily {
        if let detail = projects.details[chat.id] { return detail.family }
        if let group = groups[chat.id]?.collaboration { return AgentFamily(model: group.configuration.routing.model) }
        return managedBots.first(where: { $0.id == chat.botId })?.family ?? .codex
    }

    func loadGoal(_ chat: ChatSummary) async {
        guard (chat.botId != nil || isProject(chat)), agentFamily(chat) == .codex, !isSubagent(chat), !previewMode,
              let saved = connection, !accessEnded else { return }
        let key = partition
        let mutation = goalMutationTokens[chat.id]
        do {
            let response: ConversationGoalResponse = try await api.request(
                "/api/v1/conversations/\(Self.escape(chat.id))/goal",
                origin: saved.origin, credential: saved.credential)
            guard key == partition, mutation == goalMutationTokens[chat.id], !Task.isCancelled else { return }
            if goals[chat.id] != response.goal { goals[chat.id] = response.goal }
            if goalErrors[chat.id] == "Goal status could not be refreshed. Try again." { goalErrors[chat.id] = nil }
        } catch PairingFailure.response(404) {
            guard key == partition else { return }
            if goals[chat.id] != nil { goals[chat.id] = nil }
        } catch {
            guard key == partition else { return }
            if goals[chat.id] != nil { goalErrors[chat.id] = "Goal status could not be refreshed. Try again." }
        }
    }

    @discardableResult private func mutateGoal(_ chat: ChatSummary, body: [String: Any]) async -> Bool {
        guard (chat.botId != nil || isProject(chat)), agentFamily(chat) == .codex,
              !isSubagent(chat), let saved = connection, !accessEnded else { return false }
        let key = partition
        let token = UUID()
        goalMutationTokens[chat.id] = token
        goalErrors[chat.id] = nil
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            let response: ConversationGoalResponse = try await api.request(
                "/api/v1/conversations/\(Self.escape(chat.id))/goal",
                origin: saved.origin, body: data, credential: saved.credential, method: "PUT")
            guard key == partition, goalMutationTokens[chat.id] == token else { return false }
            goals[chat.id] = response.goal
            return true
        } catch {
            guard key == partition, goalMutationTokens[chat.id] == token else { return false }
            await loadGoal(chat)
            if key == partition, goalMutationTokens[chat.id] == token {
                goalErrors[chat.id] = "Goal could not be saved. Try again."
            }
            return false
        }
    }

    func updateGoal(_ chat: ChatSummary, objective: String, tokenBudget: Int?, timeBudgetSeconds: Int?) async -> Bool {
        await mutateGoal(chat, body: [
            "objective": objective,
            "tokenBudget": tokenBudget.map { $0 as Any } ?? NSNull(),
            "timeBudgetSeconds": timeBudgetSeconds.map { $0 as Any } ?? NSNull()
        ])
    }

    func pauseGoal(_ chat: ChatSummary) async { await mutateGoal(chat, body: ["status": "paused"]) }
    func resumeGoal(_ chat: ChatSummary) async { await mutateGoal(chat, body: ["status": "active"]) }

    func clearGoal(_ chat: ChatSummary) async {
        guard (chat.botId != nil || isProject(chat)), agentFamily(chat) == .codex,
              !isSubagent(chat), let saved = connection, !accessEnded else { return }
        let key = partition
        let token = UUID()
        goalMutationTokens[chat.id] = token
        goalErrors[chat.id] = nil
        do {
            let _: EmptyGoalResponse = try await api.request(
                "/api/v1/conversations/\(Self.escape(chat.id))/goal",
                origin: saved.origin, credential: saved.credential, method: "DELETE")
            guard key == partition, goalMutationTokens[chat.id] == token else { return }
            goals[chat.id] = nil
        } catch {
            guard key == partition, goalMutationTokens[chat.id] == token else { return }
            await loadGoal(chat)
            if key == partition, goalMutationTokens[chat.id] == token {
                goalErrors[chat.id] = "Goal could not be removed. Try again."
            }
        }
    }

    func loadSubagents(_ parent: ChatSummary) async {
        guard !previewMode, let saved = connection, !accessEnded else { return }
        let key = partition
        if subagents[parent.id] == nil,
           let data = try? store?.loadIntent(conversation: "subagents-" + parent.id),
           let cached = try? JSONDecoder().decode([SubagentSummary].self, from: data) {
            subagents[parent.id] = cached
            subagentAvailability[parent.id] = false
        }
        do {
            let response: SubagentListResponse = try await api.request(
                "/api/v1/conversations/\(Self.escape(parent.id))/subagents",
                origin: saved.origin,
                credential: saved.credential)
            guard key == partition, !Task.isCancelled else { return }
            subagents[parent.id] = response.subagents
            try? store?.saveIntent(JSONEncoder().encode(response.subagents), conversation: "subagents-" + parent.id)
            subagentAvailability[parent.id] = response.available
            subagentErrors[parent.id] = response.detail
        } catch PairingFailure.response(404) {
            guard key == partition else { return }
            subagentAvailability[parent.id] = false
            subagentErrors[parent.id] = "Subagent conversations require a newer host. Update Wonder on your computer to open them."
        } catch PairingFailure.response(409) {
            guard key == partition else { return }
            subagentAvailability[parent.id] = false
            subagentErrors[parent.id] = "Subagent conversations are unavailable on this host. Reopen the parent chat after updating Wonder."
        } catch PairingFailure.response(503) {
            guard key == partition else { return }
            subagentAvailability[parent.id] = false
            subagentErrors[parent.id] = "Subagent conversations require a newer or available host. Update Wonder on your computer, then retry."
        } catch {
            guard key == partition else { return }
            subagentAvailability[parent.id] = false
            subagentErrors[parent.id] = "Subagent conversations could not be loaded. Reopen the parent chat to retry."
        }
    }

    private func setProjectSubagents(_ agents: [ProjectSubagentSummary], for conversationID: String) {
        projectSubagentLookup[conversationID] = Dictionary(agents.map { ($0.threadId, $0) },
                                                           uniquingKeysWith: { _, newer in newer })
        projectSubagents[conversationID] = agents
    }

    func projectSubagent(threadID: String, parentConversationID: String) -> ProjectSubagentSummary? {
        projectSubagentLookup[parentConversationID]?[threadID]
    }

    func loadProjectSubagents(_ parent: ChatSummary) async {
        guard isProject(parent), !previewMode, let saved = connection, !accessEnded else { return }
        if loadingOlderProjectSubagents.contains(parent.id) {
            projectSubagentRefreshPending.insert(parent.id)
            return
        }
        let key = partition
        let token = UUID()
        projectSubagentLoadTokens[parent.id] = token
        let pageRevision = projectSubagentPageRevision[parent.id, default: 0]
        loadingOlderProjectSubagents.remove(parent.id)
        do {
            let path = try ProjectSubagentPaths.roster(parentConversationId: parent.id)
            let response: ProjectSubagentList = try await api.request(path,
                origin: saved.origin, credential: saved.credential)
            guard key == partition, projectSubagentLoadTokens[parent.id] == token, !Task.isCancelled else { return }
            if loadingOlderProjectSubagents.contains(parent.id) {
                projectSubagentRefreshPending.insert(parent.id)
                return
            }
            if projectSubagentPageRevision[parent.id, default: 0] != pageRevision {
                Task { [weak self] in await self?.loadProjectSubagents(parent) }
                return
            }
            let firstPage = response.subagents.filter { $0.parentConversationId == parent.id }
            let fresh = Set(firstPage.map(\.threadId))
            let preservePaging = projectSubagentExpandedParents.contains(parent.id)
                && projectSubagentInitialCurrentCursor[parent.id] == response.nextCurrentCursor
                && projectSubagentInitialArchivedCursor[parent.id] == response.nextArchivedCursor
            let older = projectSubagentExpandedParents.contains(parent.id)
                ? (projectSubagents[parent.id] ?? []).filter { !fresh.contains($0.threadId) } : []
            setProjectSubagents(firstPage + older, for: parent.id)
            projectSubagentFreshIDs[parent.id] = fresh
            projectSubagentAvailability[parent.id] = response.available
            if !preservePaging {
                projectSubagentPagingLimited.remove(parent.id)
                projectSubagentNextCurrentCursor[parent.id] = response.nextCurrentCursor
                projectSubagentNextArchivedCursor[parent.id] = response.nextArchivedCursor
                projectSubagentSeenCurrentCursors[parent.id] = []
                projectSubagentSeenArchivedCursors[parent.id] = []
            }
            projectSubagentErrors[parent.id] = projectSubagentPagingLimited.contains(parent.id)
                ? "Some older agent tasks are beyond this Mac's verified history limit."
                : response.detail
            projectSubagentInitialCurrentCursor[parent.id] = response.nextCurrentCursor
            projectSubagentInitialArchivedCursor[parent.id] = response.nextArchivedCursor
        } catch PairingFailure.response(let status) where [403, 404, 409].contains(status) {
            guard key == partition, projectSubagentLoadTokens[parent.id] == token, !Task.isCancelled else { return }
            setProjectSubagents([], for: parent.id)
            projectSubagentFreshIDs[parent.id] = []
            projectSubagentExpandedParents.remove(parent.id)
            projectSubagentPagingLimited.remove(parent.id)
            projectSubagentAvailability[parent.id] = false
            projectSubagentNextCurrentCursor[parent.id] = nil
            projectSubagentNextArchivedCursor[parent.id] = nil
            projectSubagentInitialCurrentCursor[parent.id] = nil
            projectSubagentInitialArchivedCursor[parent.id] = nil
            projectSubagentSeenCurrentCursors[parent.id] = nil
            projectSubagentSeenArchivedCursors[parent.id] = nil
            projectSubagentErrors[parent.id] = status == 404
                ? "Agent tasks need a newer Wonder on your computer. Update it, then refresh this Project thread."
                : "Agent tasks are no longer available in this Project thread. Refresh the Project to try again."
        } catch {
            guard key == partition, projectSubagentLoadTokens[parent.id] == token, !Task.isCancelled else { return }
            projectSubagentAvailability[parent.id] = false
            projectSubagentErrors[parent.id] = "Agent tasks could not be loaded. Refresh this Project thread to try again."
        }
    }

    func hasOlderProjectSubagents(_ conversationID: String) -> Bool {
        projectSubagentNextCurrentCursor[conversationID] != nil
            || projectSubagentNextArchivedCursor[conversationID] != nil
    }

    func loadOlderProjectSubagents(_ parent: ChatSummary) async {
        guard isProject(parent), !previewMode, let saved = connection, !accessEnded,
              projectSubagentAvailability[parent.id] == true,
              !loadingOlderProjectSubagents.contains(parent.id),
              let token = projectSubagentLoadTokens[parent.id] else { return }
        let archived: Bool
        let cursor: String
        if let current = projectSubagentNextCurrentCursor[parent.id] {
            archived = false; cursor = current
        } else if let older = projectSubagentNextArchivedCursor[parent.id] {
            archived = true; cursor = older
        } else { return }
        let seenCursors = archived ? projectSubagentSeenArchivedCursors[parent.id] ?? []
                                   : projectSubagentSeenCurrentCursors[parent.id] ?? []
        guard !seenCursors.contains(cursor) else {
            if archived { projectSubagentNextArchivedCursor[parent.id] = nil }
            else { projectSubagentNextCurrentCursor[parent.id] = nil }
            projectSubagentErrors[parent.id] = "Older agent tasks could not be loaded. Refresh this Project thread to try again."
            return
        }
        let key = partition
        loadingOlderProjectSubagents.insert(parent.id)
        defer {
            if projectSubagentLoadTokens[parent.id] == token {
                loadingOlderProjectSubagents.remove(parent.id)
                if projectSubagentRefreshPending.remove(parent.id) != nil {
                    Task { [weak self] in await self?.loadProjectSubagents(parent) }
                }
            }
        }
        do {
            let path = try ProjectSubagentPaths.roster(parentConversationId: parent.id,
                                                        archived: archived, cursor: cursor)
            let response: ProjectSubagentList = try await api.request(path,
                origin: saved.origin, credential: saved.credential)
            guard key == partition, projectSubagentLoadTokens[parent.id] == token,
                  !Task.isCancelled,
                  (archived ? projectSubagentNextArchivedCursor[parent.id]
                            : projectSubagentNextCurrentCursor[parent.id]) == cursor else { return }
            let nextCursor = archived ? response.nextArchivedCursor : response.nextCurrentCursor
            guard response.available else { throw ReadFailure.resync }
            let existing = projectSubagents[parent.id] ?? []
            let verified = response.subagents.filter {
                $0.parentConversationId == parent.id && $0.isArchived == archived
            }
            let updates = Dictionary(verified.map { ($0.threadId, $0) },
                                     uniquingKeysWith: { _, newer in newer })
            var seen = Set(existing.map(\.threadId))
            let added = verified.filter { seen.insert($0.threadId).inserted }
            setProjectSubagents(existing.map { updates[$0.threadId] ?? $0 } + added, for: parent.id)
            projectSubagentFreshIDs[parent.id, default: []].formUnion(verified.map(\.threadId))
            projectSubagentExpandedParents.insert(parent.id)
            projectSubagentPageRevision[parent.id, default: 0] += 1
            var consumed = seenCursors
            consumed.insert(cursor)
            let nextIsCycle = nextCursor.map { consumed.contains($0) } ?? false
            let beyondVerifiedLimit = nextCursor != nil && consumed.count >= 9
            if beyondVerifiedLimit { projectSubagentPagingLimited.insert(parent.id) }
            if archived {
                projectSubagentSeenArchivedCursors[parent.id] = consumed
                projectSubagentNextArchivedCursor[parent.id] = nextIsCycle || beyondVerifiedLimit ? nil : nextCursor
            } else {
                projectSubagentSeenCurrentCursors[parent.id] = consumed
                projectSubagentNextCurrentCursor[parent.id] = nextIsCycle || beyondVerifiedLimit ? nil : nextCursor
            }
            projectSubagentErrors[parent.id] = nextIsCycle
                ? "Older agent tasks could not be loaded. Refresh this Project thread to try again."
                : projectSubagentPagingLimited.contains(parent.id)
                    ? "Some older agent tasks are beyond this Mac's verified history limit."
                    : hasOlderProjectSubagents(parent.id) ? "More agent tasks are available." : nil
        } catch {
            guard key == partition, projectSubagentLoadTokens[parent.id] == token,
                  !Task.isCancelled else { return }
            projectSubagentErrors[parent.id] = "Older agent tasks could not be loaded. Try again."
        }
    }

    func projectSubagentTranscript(parent: ChatSummary, child: ProjectSubagentSummary,
                                   cursor: String? = nil) async throws -> ProjectSubagentTranscript {
        guard isProject(parent), child.parentConversationId == parent.id,
              projectSubagents[parent.id]?.contains(where: { $0.threadId == child.threadId }) == true,
              let saved = connection, !accessEnded else { throw PairingFailure.invalidLink }
        let key = partition
        let path = try ProjectSubagentPaths.transcript(parentConversationId: parent.id,
                                                       threadId: child.threadId, cursor: cursor)
        let response: ProjectSubagentTranscript = try await api.request(path,
            origin: saved.origin, credential: saved.credential)
        guard key == partition, !Task.isCancelled else { throw CancellationError() }
        guard response.subagent.parentConversationId == parent.id,
              response.subagent.threadId == child.threadId,
              response.snapshot.thread.threadId == child.threadId else { throw ReadFailure.resync }
        return response
    }

    private func connectionReady() async -> Bool {
        await preparation?.value
        if let connectionCheck { await connectionCheck.value }
        else if macConnected != true && !accessEnded && !Task.isCancelled { await check() }
        return macConnected == true && !accessEnded && !Task.isCancelled
    }

    /// Retries a conversation that has no saved content after a failed load.
    /// Quiet first-load retries before a chat with nothing saved shows a failure.
    private var conversationLoadRetries: [String: Int] = [:]
    func retryConversation(_ chat: ChatSummary) async {
        conversationLoadFailures[chat.id] = nil
        conversationLoadRetries[chat.id] = nil
        if macConnected != true { await loadChats(force: true) }
        else { await refreshConversation(chat) }
    }

    private func beginLoading(_ conversation: String) -> UUID {
        let token = UUID()
        loadingTokens[conversation] = token
        loadingConversationIDs.insert(conversation)
        return token
    }

    private func endLoading(_ conversation: String, _ token: UUID) {
        guard loadingTokens[conversation] == token else { return }
        loadingTokens[conversation] = nil
        loadingConversationIDs.remove(conversation)
    }

    func presentConversation(_ chat: ChatSummary, root: ChatSummary? = nil) {
        selectedChat = root ?? chat
        visibleChat = chat
    }

    func dismissConversation(_ chat: ChatSummary) {
        // Outgoing views can disappear after the next route has appeared.
        if visibleChat?.id == chat.id { visibleChat = nil }
    }

    func open(_ chat: ChatSummary, root: ChatSummary? = nil, readOnly: Bool = false) async {
        presentConversation(chat, root: root)
        guard !previewMode else { return }
        loadComposer(chat.id)
        if let data = try? store?.loadIntent(conversation: "async-list-" + chat.id), let items = try? JSONDecoder().decode([AsyncQuestion].self, from: data) {
            asyncQuestions[chat.id] = items
            restoreAsyncReplies(items)
        }
        // Saved history is already on screen. Network reads wait for the shared
        // launch/foreground check instead of racing credential renewal.
        guard await connectionReady(), visibleChat?.id == chat.id else { return }
        // Helpers load first: their pill resizes the composer, and a helper
        // route needs its parent's ownership record before its history.
        if chat.botId != nil { await loadSubagents(chat) }
        else if isProject(chat) { await loadProjectSubagents(chat) }
        await refreshConversation(chat)
        await loadAttention()
        try? await loadQueue(chat)
        if !readOnly, !isSubagent(chat), !chat.isArchived, composers[chat.id]?.pending?.receipt == nil, composers[chat.id]?.pending != nil {
            await deliver(chat)
        }
    }

    private func loadComposer(_ chat: String) {
        guard composers[chat] == nil, !previewMode else { return }
        do {
            guard let store else { return }
            var composer = try store.loadComposer(conversation: chat)
            if let device = connection?.credential.deviceId, composer.preservePreviousIdentityPending(currentDevice: device) {
                try store.saveComposer(composer, conversation: chat)
            }
            composers[chat] = composer
            intentLoadFailures.remove(chat)
        } catch {
            intentLoadFailures.insert(chat)
            composerErrors[chat] = "Your saved message could not be read. Free some storage and reopen this chat."
        }
    }

    /// Creation and its first message share a durable request identity. Repeating
    /// this after a crash cannot start a second message on the recovered Bot.
    func prepareCreationMessage(_ chat: ChatSummary, body: String, requestID: String) throws {
        guard let saved = connection, !accessEnded else { throw PairingFailure.response(401) }
        loadComposer(chat.id)
        guard !intentLoadFailures.contains(chat.id) else { throw ReadFailure.resync }
        var intent = composers[chat.id] ?? ComposerIntent()
        if let pending = intent.pending {
            guard pending.request.clientMessageId == requestID, pending.request.body == body else { throw SendFailure.pending }
            return
        }
        if snapshots[chat.id]?.messages.contains(where: { $0.clientMessageId == requestID }) == true { return }
        guard intent.draft.isEmpty || intent.draft == body else { throw SendFailure.pending }
        intent.draft = body
        try intent.begin(device: saved.credential.deviceId, clientMessageID: requestID,
                         modelSelectionRevision: managedBots.first(where: { $0.id == chat.botId })?.modelSelectionRevision)
        try saveComposer(intent, chat: chat.id)
    }

    func editDraft(_ text: String, chat: String) {
        loadComposer(chat)
        guard !intentLoadFailures.contains(chat), !uploading.contains(chat), !preparingSends.contains(chat) else { return }
        var next = composers[chat] ?? ComposerIntent()
        next.draft = text
        // Keep the text in memory even if disk is full, and block Send until saved.
        composers[chat] = next
        do {
            if !previewMode, (next.stagedFiles ?? []).reduce(0, { $0 + $1.data.count }) > 128 * 1024 {
                guard let store else { throw ReadFailure.resync }
                // A large staged file is already durable. Save only the new
                // text until the next full intent mutation or Send.
                try store.saveComposerDraft(text, conversation: chat)
            } else {
                try saveComposer(next, chat: chat)
            }
            composerErrors[chat] = nil
        }
        catch { composerErrors[chat] = "This draft could not be saved. Free some storage before sending." }
    }

    /// Draft navigation must inspect durable state before deciding the target
    /// is empty; an unopened conversation may already have a saved draft.
    func transferDraft(_ text: String, files: [StagedFile], to chat: ChatSummary) throws -> Bool {
        loadComposer(chat.id)
        guard !intentLoadFailures.contains(chat.id) else { throw ReadFailure.resync }
        var intent = composers[chat.id] ?? ComposerIntent()
        guard intent.pending == nil, intent.draft.isEmpty, intent.attachmentCount == 0 else { return false }
        intent.draft = text; intent.stagedFiles = files
        try saveComposer(intent, chat: chat.id)
        return true
    }

    func prepareCreation(_ chat: ChatSummary, body: String, requestID: String, files: [StagedFile]) async throws {
        loadComposer(chat.id)
        guard !intentLoadFailures.contains(chat.id) else { throw ReadFailure.resync }
        // The first message may already be reconciled while its New Chat draft
        // is still awaiting retirement. Do not restage accepted bytes on replay.
        if composers[chat.id]?.pending != nil ||
            snapshots[chat.id]?.messages.contains(where: { $0.clientMessageId == requestID }) == true {
            try prepareCreationMessage(chat, body: body, requestID: requestID)
            return
        }
        var intent = composers[chat.id] ?? ComposerIntent()
        guard intent.draft.isEmpty || intent.draft == body else { throw SendFailure.pending }
        intent.draft = body
        let existing = intent.stagedFiles ?? []
        guard existing.allSatisfy({ item in files.contains { $0.id == item.id } }) else { throw SendFailure.pending }
        intent.stagedFiles = files.map { file in existing.first { $0.id == file.id } ?? file }
        try saveComposer(intent, chat: chat.id)
        try await uploadStaged(chat)
        try prepareCreationMessage(chat, body: body, requestID: requestID)
    }

    private func saveComposer(_ value: ComposerIntent, chat: String) throws {
        if previewMode { composers[chat] = value; return }
        guard let store else { throw ReadFailure.resync }
        try store.saveComposer(value, conversation: chat)
        composers[chat] = value
    }

    func botWorking(_ chat: String) -> Bool {
        if let snapshot = snapshots[chat], snapshot.activeTurnID != nil || snapshot.hasUnassignedPreTurnWork { return true }
        guard let run = groups[chat]?.collaboration?.runs.last else { return false }
        return run.plan.finishedAt == nil && !run.plan.cancelled && run.plan.error == nil
    }

    func activeTurn(_ chat: String) -> String? {
        snapshots[chat]?.activeTurnID
    }

    /// A Project turn started in Codex or Claude on the Mac. Wonder can't stop
    /// or steer it, and a new message waits until it finishes.
    func turnRunsElsewhere(_ chat: String) -> Bool {
        snapshots[chat]?.activeTurnRunsElsewhere == true
    }

    func activeTurnIDs(_ chat: String) -> Set<String> {
        snapshots[chat]?.activeTurnIDs ?? []
    }

    func turn(_ turnID: String?, in chat: String) -> ReadTurn? {
        guard let turnID else { return nil }
        return snapshots[chat]?.thread.turns?.first(where: { $0.id == turnID })
    }
    func canGuide(_ chat: ChatSummary) -> Bool {
        !dictation.blocksSending(conversationID: chat.id) && agentFamily(chat) == .codex && !preparingSends.contains(chat.id) && !savingComposerSettings.contains(chat.id) && !approvalSettingsBlockSending(chat.id) && !chat.isArchived && !uploading.contains(chat.id) && !loadingPhotos.contains(chat.id) && chat.botId != nil && activeTurn(chat.id) != nil && !turnRunsElsewhere(chat.id) && connection != nil && !accessEnded
            && !isSubagent(chat) && usageLimitMessage(chat) == nil
            && !sending.contains(chat.id)
            && composers[chat.id]?.pending == nil && composerErrors[chat.id] == nil
            && !(composers[chat.id]?.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (composers[chat.id]?.draft.utf8.count ?? 0) <= 65536
            && (composers[chat.id]?.attachmentCount ?? 0) <= 4
    }
    func guide(_ chat: ChatSummary) async {
        guard canGuide(chat), let saved = connection, let turn = activeTurn(chat.id) else { return }
        let scope = assignmentScope
        preparingSends.insert(chat.id)
        defer { if scope == assignmentScope { preparingSends.remove(chat.id) } }
        do {
            await refreshComposerUsage(chat)
            guard usageLimitMessage(chat) == nil else { return }
            var next = composers[chat.id] ?? ComposerIntent()
            try await uploadStaged(chat)
            guard scope == assignmentScope, connection?.origin == saved.origin, !accessEnded,
                  !Task.isCancelled, activeTurn(chat.id) == turn, composers[chat.id]?.pending == nil,
                  !savingComposerSettings.contains(chat.id), !approvalSettingsBlockSending(chat.id) else { return }
            next = composers[chat.id] ?? next
            try next.begin(device: saved.credential.deviceId, expectedTurnId: turn)
            try saveComposer(next, chat: chat.id)
            await deliver(chat)
        } catch { controlErrors[chat.id] = "Guide could not be saved. Your text is still here." }
    }
    func stop(_ chat: ChatSummary) async {
        guard !isSubagent(chat), !turnRunsElsewhere(chat.id) else { return }
        guard let turn = activeTurn(chat.id), let saved = connection, !accessEnded,
              chat.botId != nil || isProject(chat), !stopping.contains(chat.id) else { return }
        let key = partition
        stopping.insert(chat.id); controlErrors[chat.id] = nil
        defer { if key == partition { stopping.remove(chat.id) } }
        do {
            struct Empty: Decodable, Sendable {}
            let _: Empty = try await api.request("/api/v1/conversations/\(Self.escape(chat.id))/turns/\(Self.escape(turn))/interrupt",
                origin: saved.origin, body: Data("{}".utf8), credential: saved.credential)
            guard key == partition else { return }
            await refreshConversation(chat)
        } catch {
            guard key == partition else { return }
            controlErrors[chat.id] = "Stop was not confirmed. Refresh the chat before trying again; the work may have finished."
            await refreshConversation(chat)
        }
    }

    func usageModel(_ chat: ChatSummary) -> String {
        if let detail = projects.details[chat.id] { return detail.model ?? (detail.family == .claude ? "claude:haiku" : "") }
        if groups[chat.id]?.collaboration != nil { return ModelDefaultPurpose.groupParticipation.load().model }
        return managedBots.first(where: { $0.id == chat.botId })?.model ?? (agentFamily(chat) == .claude ? "claude:haiku" : "")
    }

    func usageLimitMessage(_ chat: ChatSummary, model: String? = nil) -> String? {
        let selected = model ?? usageModel(chat)
        let family = AgentFamily(model: selected)
        guard let cached = (family == .claude ? claudeUsageCache : codexUsageCache)[assignmentScope],
            let exhausted = cached.exhaustedWindow(model: selected) else { return nil }
        let provider = exhausted.id == "seven_day_sonnet" ? "Claude Sonnet" : exhausted.id == "seven_day_opus" ? "Claude Opus" : family.title
        return "\(provider) usage limit reached. Try another model or wait for usage to reset."
    }

    func refreshComposerUsage(_ chat: ChatSummary) async {
        guard !previewMode, !isSubagent(chat), !chat.isArchived else { return }
        let selected = usageModel(chat), family = AgentFamily(model: selected)
        try? await loadUsage(family: family, maxAge: 60)
        // Drop expired gates even if the refresh is offline. A stale observation
        // cannot permanently disable Send after the provider's reset time.
        let cache = family == .claude ? claudeUsageCache : codexUsageCache
        if let entry = cache[assignmentScope], entry.response.windows.contains(where: { $0.usedPercent >= 100 }),
            Date().timeIntervalSince(entry.fetchedAt) >= 300 || !entry.response.windows.contains(where: {
                $0.usedPercent >= 100 && ($0.resetsAt == nil || Double($0.resetsAt!) > Date().timeIntervalSince1970)
            }) {
            if family == .claude { claudeUsageCache[assignmentScope] = nil }
            else { codexUsageCache[assignmentScope] = nil }
        }
    }

    func canSend(_ chat: ChatSummary) -> Bool {
        let draft = composers[chat.id]?.draft ?? ""
        return !dictation.blocksSending(conversationID: chat.id) && !preparingSends.contains(chat.id) && !savingComposerSettings.contains(chat.id) && !approvalSettingsBlockSending(chat.id) && !chat.isArchived && (chat.botId != nil || groups[chat.id] != nil || isProject(chat)) && connection != nil && !accessEnded
            // While the Mac app runs this conversation, the Mac holds a sent
            // message in its queue and delivers it when that turn finishes.
            && !isSubagent(chat) && usageLimitMessage(chat) == nil
            // Both direct and Group sends have durable host-side acceptance.
            // Replay invalidation does not revoke permission to submit intent.
            && (snapshots[chat.id] != nil || groups[chat.id] != nil)
            && composers[chat.id]?.pending == nil
            && !sending.contains(chat.id) && !intentLoadFailures.contains(chat.id)
            && composerErrors[chat.id] == nil
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(composers[chat.id]?.stagedFiles ?? []).isEmpty || !(composers[chat.id]?.draftAttachmentIds ?? []).isEmpty) && draft.utf8.count <= 65536
            && (composers[chat.id]?.attachmentCount ?? 0) <= 4
            && (attachmentsSupported(chat) || ((composers[chat.id]?.stagedFiles ?? []).isEmpty && (composers[chat.id]?.draftAttachmentIds ?? []).isEmpty))
            && !uploading.contains(chat.id) && !loadingPhotos.contains(chat.id)
            && !nativeHistoryRefreshing.contains(chat.id) && !nativeHistoryFailures.contains(chat.id)
    }

    func send(_ chat: ChatSummary) async {
        guard canSend(chat), let saved = connection else { return }
        let scope = assignmentScope
        preparingSends.insert(chat.id)
        controlErrors[chat.id] = nil
        defer { if scope == assignmentScope { preparingSends.remove(chat.id) } }
        if isProject(chat) {
            await reloadNativeHistory(chat)
            guard scope == assignmentScope, !nativeHistoryFailures.contains(chat.id), !Task.isCancelled else { return }
        }
        do { try await uploadStaged(chat) }
        catch {
            guard assignmentScope == scope else { return }
            controlErrors[chat.id] = "Attachment upload was not confirmed. Your files are saved; send again to retry."
            return
        }
        guard assignmentScope == scope, !accessEnded else { return }
        var routing: NewBotDefaults?
        do {
            if groups[chat.id]?.collaboration != nil {
                let options: BotOptions = try await manage("/api/v1/bot-options")
                routing = ModelDefaultPurpose.groupParticipation.load()
                let values = try routing!.creationValues(options: options)
                routing = NewBotDefaults(model: values["model"] ?? "", reasoningEffort: values["reasoningEffort"] ?? "", serviceTier: values["serviceTier"], approvalMode: routing!.approvalMode)
                guard assignmentScope == scope, !accessEnded else { return }
            }
        } catch {
            guard assignmentScope == scope else { return }
            controlErrors[chat.id] = managementError(error)
            return
        }
        let selectedModel = routing?.model ?? usageModel(chat)
        try? await loadUsage(family: AgentFamily(model: selectedModel), maxAge: 60)
        guard usageLimitMessage(chat, model: selectedModel) == nil, routing != nil || selectedModel == usageModel(chat) else { return }
        guard scope == assignmentScope, connection?.origin == saved.origin, !accessEnded,
              !Task.isCancelled, !savingComposerSettings.contains(chat.id),
              !approvalSettingsBlockSending(chat.id) else { return }
        do {
            var next = composers[chat.id] ?? ComposerIntent()
            try next.begin(device: saved.credential.deviceId, groupRouting: routing, modelSelectionRevision: groups[chat.id] == nil ? managedBots.first(where: { $0.id == chat.botId })?.modelSelectionRevision : nil)
            try saveComposer(next, chat: chat.id)
        } catch {
            guard assignmentScope == scope else { return }
            composerErrors[chat.id] = managementError(error)
            return
        }
        preparingSends.remove(chat.id)
        await deliver(chat)
    }

    func deliver(_ chat: ChatSummary) async {
        guard !isSubagent(chat) else { return }
        if composers[chat.id]?.pending?.rejected == true {
            do { var intent = composers[chat.id]!; try intent.restoreRejected(); try saveComposer(intent, chat: chat.id); controlErrors[chat.id] = nil }
            catch { controlErrors[chat.id] = "Clear or save your current draft before restoring the unsent Guide. Both messages are still saved." }
            return
        }
        guard !sending.contains(chat.id), !accessEnded,
              let saved = connection, let pending = composers[chat.id]?.pending,
              pending.request.deviceId == saved.credential.deviceId else { return }
        let key = partition
        let intentStore = store
        sending.insert(chat.id)
        defer { if partition == key { sending.remove(chat.id) } }
        do {
            let path = pending.request.expectedTurnId.map { "/api/v1/conversations/\(Self.escape(chat.id))/turns/\(Self.escape($0))/steer" } ?? groups[chat.id].map { "/api/v1/group-chats/\(Self.escape($0.id))/messages" } ?? "/api/v1/conversations/\(Self.escape(chat.id))/messages"
            let receipt: SendReceipt = try await api.request(path,
                origin: saved.origin, body: JSONEncoder().encode(pending.request), credential: saved.credential)
            // A lifecycle change does not invalidate a send receipt, but unpairing does.
            guard partition == key, let intentStore, var next = composers[chat.id],
                  next.pending?.request.clientMessageId == pending.request.clientMessageId else { return }
            try next.accept(receipt, conversation: chat.id)
            try intentStore.saveComposer(next, conversation: chat.id)
            composers[chat.id] = next
            if pending.request.modelSelectionRevision != nil, let index = managedBots.firstIndex(where: { $0.id == chat.botId }) {
                var started = managedBots[index]
                started.modelSelectionRevision = nil
                applyConfirmedManagedBot(started)
            }
            composerErrors[chat.id] = nil
            if foreground { await refreshConversation(chat) }
        } catch {
            guard partition == key else { return }
            if case PairingFailure.annotationRejected(_, let detail) = error, var intent = composers[chat.id],
               intent.pending?.request.clientMessageId == pending.request.clientMessageId {
                intent.markRejected()
                if intent.draft.isEmpty { try? intent.restoreRejected() }
                do { try saveComposer(intent, chat: chat.id) }
                catch { composerErrors[chat.id] = "The unsent message could not be restored. Free some storage and reopen the chat." }
                controlErrors[chat.id] = detail + " Reopen the file preview to select its current version, then send again."
                try? await loadFiles(chat)
                return
            }
            if case PairingFailure.response(412) = error, pending.request.expectedTurnId == nil, var intent = composers[chat.id] {
                intent.markRejected()
                if intent.draft.isEmpty { try? intent.restoreRejected() }
                do { try saveComposer(intent, chat: chat.id) } catch { composerErrors[chat.id] = "Your unsent message could not be restored. Free some storage and reopen the chat." }
                controlErrors[chat.id] = "Model settings changed. Your message was not sent. Check the model and send again."
                await loadChats(force: true)
            }
            if case PairingFailure.response(412) = error, var intent = composers[chat.id], intent.pending?.request.expectedTurnId != nil {
                intent.markRejected()
                if intent.draft.isEmpty { try? intent.restoreRejected() }
                do { try saveComposer(intent, chat: chat.id) } catch { composerErrors[chat.id] = "The unsent Guide could not be restored. Free some storage and reopen the chat." }
                controlErrors[chat.id] = "That response already finished. Your unsent Guide is saved for editing."
            }
            // The persisted pending request drives the message's retry indicator.
            // Draft-storage errors remain separate and must not be overwritten.
            if case PairingFailure.response(401) = error { readFailed(error, run: generation) }
        }
    }

    private func refreshConversation(_ chat: ChatSummary) async {
        #if WONDER_DIAGNOSTICS
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        defer { DiagnosticJournal.shared.record(DiagnosticEvent(operation: "chat.open", durationMs: (ProcessInfo.processInfo.systemUptime-diagnosticStart)*1000)) }
        #endif
        guard let saved = connection, !accessEnded else { return }
        let run = generation
        let loading = beginLoading(chat.id)
        defer { endLoading(chat.id, loading) }
        do {
            if projection.groups[chat.id] != nil {
                try await refreshList(saved, run: run)
                try reconcileGroupIntent(chat)
                return
            }
            var page: ConversationSnapshot = try await api.request("/api/v1/conversations/\(Self.escape(chat.id))", origin: saved.origin, credential: saved.credential)
            // Reuse settled history. Refresh any loaded unfinished items too:
            // an older tool can complete while newer items are already streaming.
            if let cached = projection.snapshots[chat.id], cached.hostEpoch == page.hostEpoch {
                let unsettled = Set((cached.thread.turns ?? []).flatMap { turn in
                    turn.items.filter { ["started", "streaming", "waiting"].contains($0.state) }.map { turn.id + "/" + $0.id }
                })
                while !unsettled.isSubset(of: Set((page.thread.turns ?? []).flatMap { turn in turn.items.map { turn.id + "/" + $0.id } })) {
                    guard let before = page.thread.nextCursor else { break }
                    let older: ConversationSnapshot = try await api.request("/api/v1/conversations/\(Self.escape(chat.id))/history?before=\(Self.escape(before))", origin: saved.origin, credential: saved.credential)
                    let merged = try page.mergingOlder(older)
                    guard merged.thread.nextCursor != before else { throw ReadFailure.resync }
                    page=merged
                }
                guard page.lastSequence >= cached.lastSequence else { return }
                page = try page.mergingOlder(cached)
            }
            guard run == generation else { return }
            guard page.conversationId == chat.id else { throw ReadFailure.wrongConversation }
            guard projection.summaries.contains(where: { $0.id == chat.id }) || isSubagent(chat) || isProject(chat) else {
                if projection.snapshots[chat.id] == nil { conversationLoadFailures[chat.id] = "This chat is no longer available." }
                return
            }
            var next = projection
            // Snapshot cursor only establishes an epoch at bootstrap. It never
            // skips events in this epoch, including events for other chats.
            guard next.hostEpoch.isEmpty || next.hostEpoch == page.hostEpoch else { throw ReadFailure.resync }
            next.install(page)
            try commit(next, publishing: .snapshots)
            conversationLoadFailures[chat.id] = nil
            conversationLoadRetries[chat.id] = nil
            if var intent = composers[chat.id], intent.pending != nil || !(intent.recoveredPending ?? []).isEmpty {
                intent.reconcile(page)
                try saveComposer(intent, chat: chat.id)
                if intent.pending == nil { composerErrors[chat.id] = nil }
            }
        } catch {
            if run == generation, case PairingFailure.response(404) = error {
                do { try removeDeletedConversation(chat.id) } catch { readFailed(error, run: run) }
                chatsStatus = "This conversation was removed."
            } else {
                // Saved content stays on screen; only an empty chat shows the failure,
                // and only after quiet retries: a long chat's first page can time out
                // while the Mac is still reading its history.
                if run == generation, !(error is CancellationError),
                   projection.snapshots[chat.id] == nil, projection.groups[chat.id] == nil {
                    let attempt = conversationLoadRetries[chat.id, default: 0]
                    if attempt < 2 {
                        conversationLoadRetries[chat.id] = attempt + 1
                        Task { [weak self] in
                            try? await Task.sleep(for: .seconds(attempt == 0 ? 2 : 5))
                            guard let self, !Task.isCancelled, run == self.generation,
                                  self.projection.snapshots[chat.id] == nil else { return }
                            await self.refreshConversation(chat)
                        }
                    } else {
                        conversationLoadFailures[chat.id] = "Wonder couldn’t load this chat from your computer."
                    }
                }
                readFailed(error, run: run)
            }
        }
    }

    private func reconcileGroupIntent(_ chat: ChatSummary) throws {
        guard let group = groups[chat.id], var intent = composers[chat.id],
              intent.pending != nil || !(intent.recoveredPending ?? []).isEmpty else { return }
        intent.reconcile(group)
        try saveComposer(intent, chat: chat.id)
    }

    func removeDeletedConversation(_ id: String) throws {
        var next = projection
        next.summaries.removeAll { $0.id == id }
        next.snapshots.removeValue(forKey: id); next.groups.removeValue(forKey: id)
        next.positions.removeValue(forKey: id); next.markClean(id)
        try commit(next)
        try store?.removeComposer(conversation: id)
        try store?.removeIntent(conversation: "async-list-" + id)
        composers.removeValue(forKey: id); composerErrors.removeValue(forKey: id)
        files.removeValue(forKey: id); queues.removeValue(forKey: id); asyncQuestions.removeValue(forKey: id)
        controlErrors.removeValue(forKey: id); sending.remove(id); uploading.remove(id)
        if selectedChat?.id == id { selectedChat = nil }
        if visibleChat?.id == id { visibleChat = nil }
    }

    func loadOlder(_ chat: ChatSummary) async -> String? {
        #if WONDER_DIAGNOSTICS
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        defer { DiagnosticJournal.shared.record(DiagnosticEvent(operation: "history.load", durationMs: (ProcessInfo.processInfo.systemUptime-diagnosticStart)*1000)) }
        #endif
        guard !loadingConversationIDs.contains(chat.id), let saved = connection,
              let current = projection.snapshots[chat.id],
              let cursor = current.thread.nextCursor else { return nil }
        let run = generation
        let loading = beginLoading(chat.id)
        defer { endLoading(chat.id, loading) }
        do {
            let older: ConversationSnapshot = try await api.request("/api/v1/conversations/\(Self.escape(chat.id))/history?before=\(Self.escape(cursor))", origin: saved.origin, credential: saved.credential)
            guard run == generation else { return nil }
            // History hydration may advance the replay sequence itself. Merge
            // into the latest page so a concurrent refresh wins for shared IDs.
            guard let latest = projection.snapshots[chat.id],
                  latest.hostEpoch == current.hostEpoch, older.hostEpoch == latest.hostEpoch else { return nil }
            guard latest.thread.nextCursor == cursor else { return nil }
            var next = projection
            next.snapshots[chat.id] = try latest.mergingOlder(older)
            guard next.snapshots[chat.id]?.thread.nextCursor != cursor else { return "Could not load earlier messages. Tap to retry." }
            try commit(next, publishing: .snapshots)
            return nil
        } catch {
            if Task.isCancelled || run != generation { return nil }
            readFailed(error, run: run)
            return "Could not load earlier messages. Tap to retry."
        }
    }

    func loadQueue(_ chat: ChatSummary) async throws {
        if previewMode { return }
        guard let saved = connection, !accessEnded else { throw PairingFailure.missingIdentity }
        let key = partition, scope = assignmentScope
        let approvalTargets = composerApprovalChanges.keys.filter { $0.conversationID == chat.id }
        let approvalTokens = composerApprovalTokens
        let items: [QueuedMessage] = try await api.request("/api/v1/conversations/\(Self.escape(chat.id))/queue", origin: saved.origin, credential: saved.credential)
        guard key == partition, scope == assignmentScope, connection?.origin == saved.origin,
              !accessEnded, !Task.isCancelled else { throw CancellationError() }
        if key == partition {
            // An older GET may finish after a confirmed settings mutation.
            let current = Dictionary(uniqueKeysWithValues: (queues[chat.id] ?? []).map { ($0.id, $0) })
            queues[chat.id] = items.map { item in
                if let newer = current[item.id], newer.revision > item.revision { return newer }
                return item
            }
            // Started/cancelled messages no longer have editable settings. A
            // failed save must not leave an invisible conversation-wide fence.
            let ids = Set(items.map(\.id))
            for target in approvalTargets {
                guard let id = target.queuedMessageID, !ids.contains(id),
                      composerApprovalTokens[target] == approvalTokens[target] else { continue }
                composerApprovalTasks.removeValue(forKey: target)?.cancel()
                composerApprovalTokens[target] = nil
                composerApprovalChanges[target] = nil
            }
        }
    }
    func changeQueue(_ chat: ChatSummary, item: QueuedMessage, body: String? = nil, cancel: Bool = false, turn: String? = nil) async throws {
        guard !isSubagent(chat) else { throw PairingFailure.response(403) }
        guard let saved = connection, !accessEnded else { throw PairingFailure.missingIdentity }
        var value: [String: Any] = ["expectedRevision": item.revision]
        if let body { value["body"] = body }
        if cancel { value["cancel"] = true }
        if let turn { value["expectedTurnId"] = turn }
        struct Empty: Decodable, Sendable {}
        let _: Empty = try await api.request("/api/v1/conversations/\(Self.escape(chat.id))/queue/\(Self.escape(item.id))", origin: saved.origin, body: JSONSerialization.data(withJSONObject: value), credential: saved.credential, method: "POST")
        try await loadQueue(chat)
        await refreshConversation(chat)
    }
    func reorderQueue(_ chat: ChatSummary, items: [QueuedMessage]) async throws {
        guard !isSubagent(chat) else { throw PairingFailure.response(403) }
        guard let saved = connection, !accessEnded else { throw PairingFailure.missingIdentity }
        let pairs: [[Any]] = items.map { [$0.id, $0.revision] }
        struct Empty: Decodable, Sendable {}
        let _: Empty = try await api.request("/api/v1/conversations/\(Self.escape(chat.id))/queue", origin: saved.origin,
            body: JSONSerialization.data(withJSONObject: ["items": pairs]), credential: saved.credential)
        try await loadQueue(chat)
    }

    func attachmentsSupported(_ chat: ChatSummary) -> Bool {
        if isProject(chat) { return true }
        return chat.botId != nil || groups[chat.id]?.canAttachFiles == true
    }
    private func attachmentCount(_ chat: String) -> Int {
        composers[chat]?.attachmentCount ?? 0
    }
    func canAttach(_ chat: ChatSummary) -> Bool {
        attachmentsSupported(chat) && !chat.isArchived && !accessEnded && !previewMode
            && connection != nil && (chats.contains(where: { $0.id == chat.id }) || isProject(chat))
            && !isSubagent(chat)
            && !preparingSends.contains(chat.id) && !uploading.contains(chat.id) && composers[chat.id]?.pending == nil
            && attachmentCount(chat.id) < 4
    }
    func stagePhoto(_ photo: PhotosPickerItem, chat: ChatSummary) async {
        guard canAttach(chat), !loadingPhotos.contains(chat.id) else { return }
        let key = partition
        let scope = assignmentScope
        loadingPhotos.insert(chat.id)
        controlErrors.removeValue(forKey: chat.id)
        defer { loadingPhotos.remove(chat.id) }
        do {
            guard attachmentCount(chat.id) < 4 else { throw FileFailure.tooLarge }
            guard let data = try await photo.loadTransferable(type: Data.self) else { throw FileFailure.integrity }
            try Task.checkCancellation()
            guard key == partition, scope == assignmentScope, canAttach(chat) else { return }
            let file = try await Self.prepareImageAttachment(data)
            try Task.checkCancellation()
            guard key == partition, scope == assignmentScope, canAttach(chat) else { return }
            var intent = composers[chat.id] ?? ComposerIntent()
            guard intent.attachmentCount < 4 else { throw FileFailure.tooLarge }
            intent.stagedFiles = (intent.stagedFiles ?? []) + [file]
            try saveComposer(intent, chat: chat.id)
        } catch is CancellationError {
            // Leaving the conversation cancels the import without changing the draft.
        } catch {
            guard key == partition, scope == assignmentScope, !Task.isCancelled else { return }
            controlErrors[chat.id] = "Could not attach this photo. Select it again and check your connection if it is stored in iCloud. Use up to four attachments, each no larger than 8 MB."
        }
    }

    /// Load a paste sequentially and save it atomically, preserving the draft if
    /// any image is unreadable or the whole paste exceeds the attachment limit.
    func stagePastedImages(_ providers: [NSItemProvider], chat: ChatSummary, scope: String) async {
        guard scope == assignmentScope, canAttach(chat), !loadingPhotos.contains(chat.id), !Task.isCancelled else { return }
        let key = partition
        let contextID = cameraContextID
        loadingPhotos.insert(chat.id)
        controlErrors.removeValue(forKey: chat.id)
        defer { if key == partition { loadingPhotos.remove(chat.id) } }
        do {
            guard !providers.isEmpty else { throw FileFailure.integrity }
            guard providers.count + attachmentCount(chat.id) <= 4 else { throw FileFailure.tooLarge }
            var files: [StagedFile] = []
            for provider in providers {
                guard let type = provider.registeredTypeIdentifiers.first(where: {
                    UTType($0)?.conforms(to: .image) == true
                }) else { throw FileFailure.integrity }
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: FileFailure.integrity) }
                    }
                }
                try Task.checkCancellation()
                guard contextID == cameraContextID, key == partition, scope == assignmentScope, canAttach(chat) else { return }
                files.append(try await Self.prepareImageAttachment(data))
            }
            try Task.checkCancellation()
            guard contextID == cameraContextID, key == partition, scope == assignmentScope, canAttach(chat) else { return }
            var intent = composers[chat.id] ?? ComposerIntent()
            guard intent.attachmentCount + files.count <= 4 else { throw FileFailure.tooLarge }
            intent.stagedFiles = (intent.stagedFiles ?? []) + files
            try saveComposer(intent, chat: chat.id)
        } catch is CancellationError {
            // A paste belongs to the conversation and pairing that started it.
        } catch {
            guard contextID == cameraContextID, key == partition, scope == assignmentScope, !Task.isCancelled else { return }
            controlErrors[chat.id] = "Could not paste these images. Use up to four attachments, each no larger than 8 MB, and try again."
        }
    }

    static func prepareImageAttachment(_ data: Data) async throws -> StagedFile {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw FileFailure.tooLarge }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil,
                  let identifier = CGImageSourceGetType(source),
                  let type = UTType(identifier as String), type.conforms(to: .image),
                  let mime = type.preferredMIMEType, let ext = type.preferredFilenameExtension else { throw FileFailure.integrity }
            return try StagedFile(name: "Photo-\(UUID().uuidString.prefix(8)).\(ext)", mimeType: mime, data: data)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    func stageCameraPhoto(_ data: Data, chat: ChatSummary, scope: String) async -> CameraAttachmentResult {
        guard !Task.isCancelled, scope == assignmentScope, visibleChat?.id == chat.id else { return .cancelled }
        loadComposer(chat.id)
        guard !intentLoadFailures.contains(chat.id), canAttach(chat), !loadingPhotos.contains(chat.id) else { return .cancelled }
        let key = partition
        let contextID = cameraContextID
        loadingPhotos.insert(chat.id)
        controlErrors.removeValue(forKey: chat.id)
        defer { if key == partition { loadingPhotos.remove(chat.id) } }
        do {
            let prepared = try await CameraPhotoPreparation.prepare(data)
            try Task.checkCancellation()
            guard contextID == cameraContextID, key == partition, scope == assignmentScope, visibleChat?.id == chat.id,
                  !accessEnded, !previewMode, connection != nil,
                  (chats.contains(where: { $0.id == chat.id }) || isProject(chat)),
                  composers[chat.id]?.pending == nil, attachmentCount(chat.id) < 4 else { return .cancelled }
            let file = try StagedFile(
                name: "Photo-\(UUID().uuidString.prefix(8)).\(prepared.fileExtension)",
                mimeType: prepared.mimeType,
                data: prepared.data
            )
            var intent = composers[chat.id] ?? ComposerIntent()
            guard intent.attachmentCount < 4 else { throw FileFailure.tooLarge }
            intent.stagedFiles = (intent.stagedFiles ?? []) + [file]
            try saveComposer(intent, chat: chat.id)
            return .attached
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard contextID == cameraContextID, key == partition, scope == assignmentScope, visibleChat?.id == chat.id, !Task.isCancelled else { return .cancelled }
            controlErrors[chat.id] = "Could not attach this photo. Use up to four attachments, each no larger than 8 MB."
            return .failed
        }
    }

    func stage(_ url: URL, chat: ChatSummary, mime: String) {
        guard canAttach(chat), !loadingPhotos.contains(chat.id) else { return }
        do {
            guard attachmentCount(chat.id) < 4 else { throw FileFailure.tooLarge }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 8 * 1024 * 1024 else { throw FileFailure.tooLarge }
            let file = try StagedFile(name: url.lastPathComponent, mimeType: mime, data: Data(contentsOf: url))
            var intent = composers[chat.id] ?? ComposerIntent()
            intent.stagedFiles = (intent.stagedFiles ?? []) + [file]
            try saveComposer(intent, chat: chat.id)
        } catch { controlErrors[chat.id] = "Could not attach this file. Use up to four files, each no larger than 8 MB, and try again." }
    }
    func removeStaged(_ id: String, chat: String) {
        guard !uploading.contains(chat), !preparingSends.contains(chat) else { return }
        guard composers[chat]?.pending == nil else { return }
        do {
            var intent = composers[chat] ?? ComposerIntent()
            intent.removeAttachment(id: id)
            try saveComposer(intent, chat: chat)
            staleAnnotationIDs[chat]?.remove(id)
        }
        catch { controlErrors[chat] = "Could not save the attachment change." }
    }
    func canAnnotate(_ chat: ChatSummary, replacing oldID: String? = nil) -> Bool {
        let replacesAnnotation = oldID.map { id in
            composers[chat.id]?.stagedFiles?.contains(where: { $0.id == id && $0.mimeType == ArtifactAnnotation.mimeType }) == true ||
            ((composers[chat.id]?.draftAttachmentIds ?? []).contains(id) &&
             files[chat.id]?.contains(where: { $0.id == id && $0.mimeType == ArtifactAnnotation.mimeType }) == true)
        } ?? false
        guard let detail = projects.details[chat.id], detail.isArchived != true,
              !chat.isArchived, !accessEnded,
              macConnected == true, composers[chat.id]?.pending == nil,
              (attachmentCount(chat.id) < 4 || replacesAnnotation), !uploading.contains(chat.id),
              !preparingSends.contains(chat.id) else { return false }
        if !previewMode { return connection != nil }
        #if WONDER_DIAGNOSTICS
        return ProcessInfo.processInfo.arguments.contains("-artifact-annotation-preview")
        #else
        return false
        #endif
    }

    func stageAnnotation(_ annotation: ArtifactAnnotation, chat: ChatSummary,
                         expectedScope: String, replacing oldID: String? = nil,
                         preserveStaleOnReplace: Bool = false) throws {
        guard canAnnotate(chat, replacing: oldID),
              expectedScope == assignmentScope,
              let detail = projects.details[chat.id], detail.projectId == annotation.projectId,
              detail.isArchived != true, annotation.conversationId == chat.id,
              !chat.isArchived, !accessEnded,
              (connection != nil || previewMode),
              !uploading.contains(chat.id), !preparingSends.contains(chat.id) else { throw FileFailure.integrity }
        loadComposer(chat.id)
        guard !intentLoadFailures.contains(chat.id) else { throw ReadFailure.resync }
        var intent = composers[chat.id] ?? ComposerIntent()
        guard intent.pending == nil else { throw SendFailure.pending }
        let replacedStale = preserveStaleOnReplace && oldID.map { isAnnotationStale($0, chat: chat.id) } == true
        if let oldID {
            let local = intent.stagedFiles?.contains(where: { $0.id == oldID && $0.mimeType == ArtifactAnnotation.mimeType }) == true
            let remote = (intent.draftAttachmentIds ?? []).contains(oldID) && files[chat.id]?.contains(where: {
                $0.id == oldID && $0.mimeType == ArtifactAnnotation.mimeType
            }) == true
            guard local || remote else { throw FileFailure.integrity }
            intent.removeAttachment(id: oldID)
        }
        guard intent.attachmentCount < 4 else { throw FileFailure.tooLarge }
        let staged = try annotation.stagedFile()
        intent.stagedFiles = (intent.stagedFiles ?? []) + [staged]
        try saveComposer(intent, chat: chat.id)
        if let oldID {
            staleAnnotationIDs[chat.id]?.remove(oldID)
            if replacedStale { staleAnnotationIDs[chat.id, default: []].insert(staged.id) }
        }
        controlErrors[chat.id] = nil
    }

    func isAnnotationStale(_ id: String, chat: String) -> Bool {
        staleAnnotationScope == assignmentScope && staleAnnotationIDs[chat]?.contains(id) == true
    }

    /// The host still validates the source hash at send. This early check gives
    /// an open draft a useful warning as soon as a refreshed preview changes.
    func noteWorkspaceRevision(_ chat: ChatSummary, rootID: String, path: String,
                               currentSha256: String) async {
        let scope = assignmentScope
        let key = AnnotationRevisionKey(scope: scope, chatID: chat.id, rootID: rootID, path: path)
        let requestID = UUID()
        annotationRevisionRequests[key] = requestID
        defer {
            if annotationRevisionRequests[key] == requestID { annotationRevisionRequests.removeValue(forKey: key) }
        }
        let intent = composers[chat.id] ?? ComposerIntent()
        var candidates: [(String, Data)] = (intent.stagedFiles ?? [])
            .filter { $0.mimeType == ArtifactAnnotation.mimeType }
            .map { ($0.id, $0.data) }
        for id in intent.draftAttachmentIds ?? [] {
            guard let file = files[chat.id]?.first(where: { $0.id == id && $0.mimeType == ArtifactAnnotation.mimeType }),
                  let data = try? await download(file, chat: chat) else { continue }
            candidates.append((id, data))
        }
        guard !Task.isCancelled, scope == assignmentScope, !accessEnded,
              annotationRevisionRequests[key] == requestID else { return }
        let currentIDs = Set((composers[chat.id]?.stagedFiles ?? []).map(\.id) +
                             (composers[chat.id]?.draftAttachmentIds ?? []))
        var stale = staleAnnotationScope == scope ? (staleAnnotationIDs[chat.id] ?? []) : []
        stale.formIntersection(currentIDs)
        for (id, data) in candidates {
            guard currentIDs.contains(id) else { continue }
            guard let annotation = try? ArtifactAnnotation.read(data),
                  annotation.conversationId == chat.id,
                  annotation.projectId == projects.details[chat.id]?.projectId,
                  annotation.rootId == rootID, annotation.path == path else { continue }
            if annotation.sourceSha256 == currentSha256 { stale.remove(id) }
            else { stale.insert(id) }
        }
        staleAnnotationScope = scope
        staleAnnotationIDs[chat.id] = stale
    }
    private func uploadStaged(_ chat: ChatSummary) async throws {
        guard let saved = connection, !accessEnded else { throw PairingFailure.missingIdentity }
        let scope = assignmentScope
        let key = partition
        uploading.insert(chat.id)
        defer { if key == partition { uploading.remove(chat.id) } }
        for file in composers[chat.id]?.stagedFiles ?? [] where file.uploaded == nil {
            let encoding = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let body = try file.uploadBody()
                try Task.checkCancellation()
                return body
            }
            let body = try await withTaskCancellationHandler(operation: { try await encoding.value },
                                                              onCancel: { encoding.cancel() })
            guard key == partition, scope == assignmentScope, !accessEnded, !Task.isCancelled else { throw CancellationError() }
            let uploaded: ConversationFile = try await api.request("/api/v1/conversations/\(Self.escape(chat.id))/files",
                origin: saved.origin, body: body, credential: saved.credential)
            guard key == partition, scope == assignmentScope, !accessEnded else { throw CancellationError() }
            try uploaded.verify(file.data, mime: file.mimeType)
            guard var next = composers[chat.id], let index = next.stagedFiles?.firstIndex(where: { $0.id == file.id }) else { throw CancellationError() }
            next.stagedFiles?[index].uploaded = uploaded
            try saveComposer(next, chat: chat.id)
        }
    }
    func loadFiles(_ chat: ChatSummary) async throws {
        if previewMode { return }
        guard let saved = connection, !accessEnded else { throw PairingFailure.missingIdentity }
        let key = partition
        let scope = assignmentScope
        try Task.checkCancellation()
        let items: [ConversationFile] = try await api.request("/api/v1/conversations/\(Self.escape(chat.id))/files", origin: saved.origin, credential: saved.credential)
        if key == partition, scope == assignmentScope, !Task.isCancelled { files[chat.id] = items }
    }
    func loadFilesIfNeeded(_ chat: ChatSummary, attachmentIDs: [String]) async {
        guard !previewMode, !accessEnded, !attachmentIDs.isEmpty else { return }
        let requested = Set(attachmentIDs)
        let known = Set((files[chat.id] ?? []).map(\.id))
        guard !requested.isSubset(of: known) else { return }
        let key = partition
        let scope = assignmentScope
        do {
            try Task.checkCancellation()
            try await loadFiles(chat)
            guard key == partition, scope == assignmentScope, !Task.isCancelled else { return }
        } catch is CancellationError {
            // The view or host scope changed; keep its fallback attachment chips.
        } catch {
            // Offline and unavailable hosts leave the useful fallback chips in place.
        }
    }
    func loadWorkspaceRoots(_ chat: ChatSummary) async throws -> WorkspaceRootsResponse {
        if previewMode {
            #if WONDER_DIAGNOSTICS
            if ProcessInfo.processInfo.arguments.contains("-workspace-delayed-background-roots") {
                previewWorkspaceRootReads += 1
                if previewWorkspaceRootReads > 1 { try await Task.sleep(for: .seconds(5)) }
            }
            if chat.id.hasPrefix("project-files:") {
                if ProcessInfo.processInfo.arguments.contains("-project-files-root-revoked") { throw PairingFailure.response(403) }
                if ProcessInfo.processInfo.arguments.contains("-project-files-project-removed") { throw PairingFailure.response(404) }
                if ProcessInfo.processInfo.arguments.contains("-project-files-root-changed") {
                    previewProjectFilesRootReads += 1
                    if previewProjectFilesRootReads == 1 {
                        return WorkspaceRootsResponse(available: true, detail: nil, roots: [
                            WorkspaceRoot(id: "removed-root", label: "Workspace", path: "/preview-old", isDirectory: true, kind: "workingDirectory", readOnly: true)
                        ], attachments: [])
                    }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-workspace-delayed-roots") {
                try await Task.sleep(for: .seconds(5))
            }
            #endif
            return previewWorkspaceRoots(chat)
        }
        guard let saved = connection, !accessEnded else { throw PairingFailure.missingIdentity }
        let response: WorkspaceRootsResponse = try await api.request(
            "/api/v1/conversations/\(Self.escape(chat.id))/workspace/roots",
            origin: saved.origin,
            credential: saved.credential)
        guard response.available else { throw PairingFailure.response(503) }
        return response
    }
    /// URLComponents.path expects decoded path text. Use percentEncodedPath
    /// here because the conversation segment is already escaped exactly once.
    private static func workspaceComponents(conversationID: String, operation: String) -> URLComponents {
        var components = URLComponents()
        components.percentEncodedPath = "/api/v1/conversations/\(Self.escape(conversationID))/workspace/\(operation)"
        return components
    }
    static func workspaceEndpoint(conversationID: String, operation: String) -> String? {
        Self.workspaceComponents(conversationID: conversationID, operation: operation).string
    }
    func loadWorkspaceDirectory(_ chat: ChatSummary, root: WorkspaceRoot, path: String, showHidden: Bool, offset: Int = 0) async throws -> WorkspaceDirectoryPage {
        if previewMode {
            #if WONDER_DIAGNOSTICS
            if ProcessInfo.processInfo.arguments.contains("-workspace-delayed-hidden"),
               path.isEmpty, showHidden {
                try await Task.sleep(for: .seconds(3))
            }
            if root.id == "removed-root" && ProcessInfo.processInfo.arguments.contains("-project-files-root-changed") {
                throw PairingFailure.response(404)
            }
            if path == "Projects" && ProcessInfo.processInfo.arguments.contains("-project-files-directory-moved") {
                throw PairingFailure.response(404)
            }
            #endif
            return previewWorkspaceDirectory(root: root, path: path, showHidden: showHidden, offset: offset)
        }
        guard let saved = connection, !accessEnded else { throw PairingFailure.missingIdentity }
        var components = Self.workspaceComponents(conversationID: chat.id, operation: "directory")
        components.queryItems = [URLQueryItem(name: "root", value: root.id), URLQueryItem(name: "path", value: path), URLQueryItem(name: "showHidden", value: showHidden ? "true" : "false"), URLQueryItem(name: "offset", value: String(offset))]
        guard let endpoint = components.string else { throw PairingFailure.invalidLink }
        return try await api.request(endpoint, origin: saved.origin, credential: saved.credential)
    }
    func downloadWorkspaceFile(_ chat: ChatSummary, root: WorkspaceRoot, entry: WorkspaceEntry,
                               countsAsOpen: Bool = true,
                               progress: (@Sendable (_ received: Int, _ expected: Int?) -> Void)? = nil) async throws -> Data {
        if previewMode {
            #if WONDER_DIAGNOSTICS
            // A large fixture arrives in steps, like a slow Wi-Fi transfer.
            if ProcessInfo.processInfo.arguments.contains("-workspace-large-text-preview"), entry.name == "large.txt" {
                let data = previewWorkspaceData(entry: entry)
                for step in 0...8 {
                    progress?(data.count * step / 8, data.count)
                    try await Task.sleep(for: .milliseconds(700))
                }
                return data
            }
            if entry.path == "Weekend.pdf",
               ProcessInfo.processInfo.arguments.contains("-malformed-pdf-preview") {
                return Data("%PDF-1.7\ninvalid document".utf8)
            }
            if countsAsOpen, ProcessInfo.processInfo.arguments.contains("-artifact-revision-preview") {
                // Opening always shows the original. The open preview's own
                // checks see the revision once the file has been opened enough
                // times (README needs a second open after its first comment).
                previewWorkspaceFileOpens[root.id + ":" + entry.path, default: 0] += 1
            }
            #endif
            return previewWorkspaceData(entry: entry)
        }
        guard let saved = connection, !accessEnded else { throw PairingFailure.missingIdentity }
        let scope = assignmentScope
        var components = Self.workspaceComponents(conversationID: chat.id, operation: "file")
        components.queryItems = [URLQueryItem(name: "root", value: root.id), URLQueryItem(name: "path", value: entry.path)]
        guard let endpoint = components.string else { throw PairingFailure.invalidLink }
        let data = try await api.downloadWorkspaceBytes(endpoint, connection: saved, byteSize: entry.byteSize.map(Int.init), sha256: nil,
                                                        mimeType: entry.mimeType, progress: progress)
        guard scope == assignmentScope, !accessEnded else { throw CancellationError() }
        return data
    }

    func refreshWorkspaceFile(_ chat: ChatSummary, root: WorkspaceRoot, entry: WorkspaceEntry) async throws -> Data {
        // Listing size belongs to the previous revision. Fetch the same path
        // without that expectation, then validate the advertised format again.
        let current = WorkspaceEntry(name: entry.name, path: entry.path, isDirectory: false,
                                     byteSize: nil, mimeType: entry.mimeType)
        #if WONDER_DIAGNOSTICS
        if previewMode, ProcessInfo.processInfo.arguments.contains("-artifact-revision-preview"),
           previewWorkspaceFileOpens[root.id + ":" + entry.path, default: 0] >= (entry.path == "README.md" ? 2 : 1) {
            if entry.path == "Weekend.pdf",
               ProcessInfo.processInfo.arguments.contains("-malformed-pdf-revision-preview") {
                return Data("%PDF-1.7\ninvalid revision".utf8)
            }
            return previewWorkspaceRevisionData(entry: current)
        }
        #endif
        let data = try await downloadWorkspaceFile(chat, root: root, entry: current, countsAsOpen: false)
        if let mime = current.mimeType { try ConversationFile.validateContent(data, mime: mime) }
        return data
    }
    func workspaceMediaLoader(_ chat: ChatSummary, root: WorkspaceRoot, entry: WorkspaceEntry) throws -> WorkspaceMediaResourceLoader {
        var components = Self.workspaceComponents(conversationID: chat.id, operation: "media")
        components.queryItems = [URLQueryItem(name: "root", value: root.id), URLQueryItem(name: "path", value: entry.path)]
        guard let endpoint = components.string else { throw PairingFailure.invalidLink }
        #if WONDER_DIAGNOSTICS
        if previewMode, ProcessInfo.processInfo.arguments.contains("-workspace-media-preview") {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DiagnosticWorkspaceMediaProtocol.self]
            let credential = try JSONDecoder().decode(Credential.self, from: Data(
                #"{"sessionToken":"fixture-only","deviceId":"fixture","csrfToken":"fixture","hostInstallationId":"fixture"}"#.utf8))
            let fixture = SavedConnection(origin: "https://workspace-media.invalid", credential: credential)
            return WorkspaceMediaResourceLoader(api: PairingAPI(configuration: configuration),
                                                connection: fixture, path: endpoint)
        }
        #endif
        guard let saved = connection, !accessEnded, !previewMode else { throw PairingFailure.missingIdentity }
        return WorkspaceMediaResourceLoader(api: api, connection: saved, path: endpoint)
    }
    func loadWorkspaceGitStatus(_ chat: ChatSummary, root: WorkspaceRoot) async throws -> WorkspaceGitStatusResponse {
        if previewMode {
            #if WONDER_DIAGNOSTICS
            if ProcessInfo.processInfo.arguments.contains("-workspace-delayed-git") {
                try await Task.sleep(for: .seconds(3))
                throw PairingFailure.response(503)
            }
            #endif
            return previewWorkspaceGitStatus()
        }
        guard let saved = connection, !accessEnded else { throw PairingFailure.missingIdentity }
        var components = Self.workspaceComponents(conversationID: chat.id, operation: "git/status")
        components.queryItems = [URLQueryItem(name: "root", value: root.id)]
        guard let endpoint = components.string else { throw PairingFailure.invalidLink }
        return try await api.request(endpoint, origin: saved.origin, credential: saved.credential)
    }
    func loadWorkspaceGitDiff(_ chat: ChatSummary, root: WorkspaceRoot, path: String, staged: Bool) async throws -> WorkspaceDiffResponse {
        if previewMode {
            #if WONDER_DIAGNOSTICS
            if ProcessInfo.processInfo.arguments.contains("-workspace-delayed-diff"), path == "README.md" {
                try await Task.sleep(for: .seconds(3))
            }
            #endif
            return WorkspaceDiffResponse(path: path, staged: staged, diff: "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n@@\n-fixture line\n+updated fixture line\n")
        }
        guard let saved = connection, !accessEnded else { throw PairingFailure.missingIdentity }
        var components = Self.workspaceComponents(conversationID: chat.id, operation: "git/diff")
        components.queryItems = [URLQueryItem(name: "root", value: root.id), URLQueryItem(name: "path", value: path), URLQueryItem(name: "staged", value: staged ? "true" : "false")]
        guard let endpoint = components.string else { throw PairingFailure.invalidLink }
        return try await api.request(endpoint, origin: saved.origin, credential: saved.credential)
    }
    private func previewWorkspaceRoots(_ chat: ChatSummary) -> WorkspaceRootsResponse {
        let root = WorkspaceRoot(id: "workspace", label: "Workspace", path: "/preview", isDirectory: true, kind: "workingDirectory", readOnly: true)
        let attachments = files[chat.id] ?? []
        return WorkspaceRootsResponse(available: true, detail: nil, roots: [root], attachments: attachments)
    }
    private func previewWorkspaceDirectory(root: WorkspaceRoot, path: String, showHidden: Bool, offset: Int) -> WorkspaceDirectoryPage {
        let values: [WorkspaceEntry]
        if path == "Sources" {
            values = [WorkspaceEntry(name: "Authentication.swift", path: "Sources/Authentication.swift", isDirectory: false, byteSize: nil, mimeType: "text/plain")]
        } else if path == "Projects" {
            values = [WorkspaceEntry(name: "Plan.md", path: "Projects/Plan.md", isDirectory: false, byteSize: 44, mimeType: "text/markdown")]
        } else {
            var rootEntries = [
                WorkspaceEntry(name: "Projects", path: "Projects", isDirectory: true, byteSize: nil, mimeType: nil),
                WorkspaceEntry(name: "README.md", path: "README.md", isDirectory: false, byteSize: 45, mimeType: "text/markdown"),
                WorkspaceEntry(name: "diagram.png", path: "diagram.png", isDirectory: false, byteSize: UInt64(previewBytes["Saturday.png"]?.count ?? 0), mimeType: "image/png")
            ]
            if showHidden { rootEntries.append(WorkspaceEntry(name: ".gitignore", path: ".gitignore", isDirectory: false, byteSize: 12, mimeType: "text/plain")) }
            if ProcessInfo.processInfo.arguments.contains("-artifact-annotation-preview") {
                rootEntries.append(WorkspaceEntry(name: "Weekend.pdf", path: "Weekend.pdf", isDirectory: false,
                                                   byteSize: UInt64(previewBytes["notes.pdf"]?.count ?? 0), mimeType: "application/pdf"))
            }
            #if WONDER_DIAGNOSTICS
            if ProcessInfo.processInfo.arguments.contains("-workspace-media-preview") {
                rootEntries.append(WorkspaceEntry(name: "black.mp4", path: "black.mp4", isDirectory: false,
                                                   byteSize: UInt64(DiagnosticWorkspaceMediaProtocol.video.count), mimeType: "video/mp4"))
            }
            if ProcessInfo.processInfo.arguments.contains("-workspace-document-preview") {
                rootEntries += DiagnosticWorkspaceFileFixtures.entries
            }
            if ProcessInfo.processInfo.arguments.contains("-workspace-html-scroll-preview") ||
               ProcessInfo.processInfo.arguments.contains("-workspace-html-script-preview") {
                rootEntries.append(WorkspaceEntry(name: "reader.html", path: "reader.html", isDirectory: false,
                                                  byteSize: nil, mimeType: "text/html"))
            }
            if ProcessInfo.processInfo.arguments.contains("-workspace-large-text-preview") {
                rootEntries.append(WorkspaceEntry(name: "large.txt", path: "large.txt", isDirectory: false,
                                                  byteSize: 40 * 1024 * 1024, mimeType: "text/plain"))
            }
            #endif
            values = rootEntries
        }
        #if WONDER_DIAGNOSTICS
        let pageSize = ProcessInfo.processInfo.arguments.contains("-workspace-paged-preview") ? 2 : 200
        #else
        let pageSize = 200
        #endif
        let entries = Array(values.dropFirst(offset).prefix(pageSize))
        let nextOffset = offset + entries.count < values.count ? offset + entries.count : nil
        return WorkspaceDirectoryPage(rootId: root.id, path: path, parentPath: path.isEmpty ? nil : "",
                                      entries: entries, nextOffset: nextOffset)
    }
    private func previewWorkspaceData(entry: WorkspaceEntry) -> Data {
        #if WONDER_DIAGNOSTICS
        if ProcessInfo.processInfo.arguments.contains("-workspace-large-text-preview"), entry.name == "large.txt" {
            return Data(repeating: 65, count: 40 * 1024 * 1024)
        }
        if ProcessInfo.processInfo.arguments.contains("-workspace-document-preview"),
           let data = DiagnosticWorkspaceFileFixtures.data(name: entry.name) { return data }
        if ProcessInfo.processInfo.arguments.contains("-workspace-html-script-preview"), entry.name == "reader.html" {
            return Data("<h1>Script safety page</h1><p id='result'>Safe content remains</p><script>document.getElementById('result').textContent='SCRIPT EXECUTED'</script>".utf8)
        }
        if ProcessInfo.processInfo.arguments.contains("-workspace-html-scroll-preview"), entry.name == "reader.html" {
            let paragraphs = (1...30).map { "<p style='min-height:80px'>Reading section \($0)</p>" }.joined()
            return Data("<h1>Original reading page</h1>\(paragraphs)<p>End of original page</p>".utf8)
        }
        #endif
        if entry.mimeType?.hasPrefix("image/") == true, let data = previewBytes["Saturday.png"] { return data }
        if entry.name == "Weekend.pdf", let data = previewBytes["notes.pdf"] { return data }
        if entry.name == ".gitignore" { return Data(".DS_Store\n".utf8) }
        return Data("Fixture workspace file: \(entry.name)\n".utf8)
    }
    #if WONDER_DIAGNOSTICS
    private func previewWorkspaceRevisionData(entry: WorkspaceEntry) -> Data {
        if entry.name == "reader.html" {
            return Data("<h1>Revised reading page</h1><p>Accepted HTML revision</p>".utf8)
        }
        if entry.name == "workspace-reader.epub",
           let revised = DiagnosticWorkspaceFileFixtures.data(name: "workspace-reader-revised.epub") {
            return revised
        }
        if entry.name == "sidecar.obj" {
            return Data("o revised-triangle\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8)
        }
        if entry.mimeType?.hasPrefix("image/") == true {
            return UIGraphicsImageRenderer(size: CGSize(width: 300, height: 180)).pngData { context in
                UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 180))
                ("Sunday" as NSString).draw(at: CGPoint(x: 24, y: 70), withAttributes: [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.white])
            }
        }
        if entry.name == "Weekend.pdf" {
            return UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 420)).pdfData { context in
                for page in 1...2 {
                    context.beginPage()
                    ("Revised page \(page)\n\nReview the new schedule." as NSString)
                        .draw(in: CGRect(x: 24, y: 24, width: 252, height: 360),
                              withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
                }
            }
        }
        return Data("Revised workspace file: \(entry.name)\nKeep Sunday open.\n".utf8)
    }
    #endif
    private func previewWorkspaceGitStatus() -> WorkspaceGitStatusResponse {
        WorkspaceGitStatusResponse(available: true, detail: nil, repositoryPath: "/preview", changes: [
            WorkspaceGitChange(path: "README.md", originalPath: nil, state: "staged", indexStatus: "M", worktreeStatus: " "),
            WorkspaceGitChange(path: "new-name.md", originalPath: "old-name.md", state: "renamed", indexStatus: "R", worktreeStatus: " "),
            WorkspaceGitChange(path: "scratch.txt", originalPath: nil, state: "untracked", indexStatus: "?", worktreeStatus: "?"),
            WorkspaceGitChange(path: "conflict.txt", originalPath: nil, state: "conflicted", indexStatus: "U", worktreeStatus: "U")
        ])
    }
    func download(_ file: ConversationFile, chat: ChatSummary) async throws -> Data {
        if previewMode, let data = previewBytes[file.id] { try file.verify(data,mime:file.mimeType); return data }
        guard let saved = connection, !accessEnded else { throw PairingFailure.missingIdentity }
        let key = partition
        let data = try await api.download("/api/v1/conversations/\(Self.escape(chat.id))/files/\(Self.escape(file.id))", connection: saved, file: file)
        guard key == partition, !accessEnded else { throw CancellationError() }
        return data
    }

    func loadAttention() async {
        guard !previewMode else { return }
        guard let saved = connection, !accessEnded else { return }
        let key = partition
        do {
            let items: [AttentionRequest] = try await api.request("/api/v1/approvals", origin: saved.origin, credential: saved.credential)
            if key == partition {
                attention = items
                for item in items {
                    if let data = try store?.loadIntent(conversation: "decision-" + item.id) {
                        savedDecisions[item.id] = try JSONDecoder().decode(DecisionIntent.self, from: data)
                    }
                }
            }
        } catch { /* Background refresh keeps the last known requests. */ }
        guard key == partition, !Task.isCancelled else { return }
        if let parent = selectedChat {
            await loadAsyncQuestions(parent)
            // Bound network concurrency; completed children may still own a
            // pending question, so preserve all verified ownership records.
            let children = subagents[parent.id] ?? []
            for start in stride(from: 0, to: children.count, by: 4) {
                guard key == partition, !Task.isCancelled else { return }
                await withTaskGroup(of: Void.self) { group in
                    for child in children[start..<min(start + 4, children.count)] {
                        let chat = child.chatSummary(botId: parent.botId)
                        group.addTask { [weak self] in _ = await self?.loadAsyncQuestions(chat) }
                    }
                }
            }
        } else if let chat = visibleChat { await loadAsyncQuestions(chat) }

    }
    @discardableResult
    func loadAsyncQuestions(_ chat: ChatSummary) async -> [AsyncQuestion]? {
        guard let saved = connection, !accessEnded, !previewMode else { return nil }
        let key = partition
        do {
            let items: [AsyncQuestion] = try await api.request("/api/v1/conversations/\(Self.escape(chat.id))/questions", origin: saved.origin, credential: saved.credential)
            guard key == partition else { return nil }
            let currentIDs = Set(items.map(\.id))
            // Keep an unresolved saved reply reachable if the bounded host list
            // no longer includes its question. It can only check status or copy.
            let retained = (asyncQuestions[chat.id] ?? []).filter {
                !currentIDs.contains($0.id) && (try? store?.loadIntent(conversation: "async-reply-" + $0.id)) != nil
            }
            let visible = items + retained
            try store?.saveIntent(JSONEncoder().encode(visible), conversation: "async-list-" + chat.id)
            asyncQuestions[chat.id] = visible
            restoreAsyncReplies(visible, authoritativeIDs: currentIDs)
            return items
        } catch { return nil } // Keep saved questions until a successful refresh.
    }

    private func restoreAsyncReplies(_ questions: [AsyncQuestion], authoritativeIDs: Set<String>? = nil) {
        guard let store else { return }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        for question in questions {
            do {
                guard let data = try store.loadIntent(conversation: "async-reply-" + question.id) else {
                    savedAsyncReplies.removeValue(forKey: question.id)
                    retryableAsyncReplies.remove(question.id)
                    continue
                }
                let answer = try JSONDecoder().decode(AsyncAnswerIntent.self, from: data)
                savedAsyncReplies[question.id] = answer
                let terminal = question.state == "answered" || question.state == "dismissed"
                if authoritativeIDs?.contains(question.id) == true, terminal,
                   let response = question.response,
                   response.answers == answer.answers, response.skip == answer.skip {
                    try store.removeIntent(conversation: "async-reply-" + question.id)
                    savedAsyncReplies.removeValue(forKey: question.id)
                    retryableAsyncReplies.remove(question.id)
                    attentionErrors[question.id] = nil
                    continue
                }
                if let authoritativeIDs, !authoritativeIDs.contains(question.id) {
                    retryableAsyncReplies.remove(question.id)
                    attentionErrors[question.id] = "Your Mac no longer lists this question. Your saved reply is available to copy."
                } else if question.canAnswer(now: now) {
                    retryableAsyncReplies.insert(question.id)
                    if !resolving.contains(question.id), attentionErrors[question.id] == nil {
                        attentionErrors[question.id] = "Reply not confirmed. Check the saved reply before sending another answer."
                    }
                } else {
                    retryableAsyncReplies.remove(question.id)
                    attentionErrors[question.id] = terminal
                        ? "This question was answered or skipped. Your saved reply is available to copy."
                        : "This question expired. Your saved reply is available to copy."
                }
            } catch {
                // Status checking remains available after a local storage error.
                retryableAsyncReplies.insert(question.id)
                attentionErrors[question.id] = "The saved reply could not be read or updated. Free some storage and check again."
            }
        }
    }
    func replyAsync(_ question: AsyncQuestion, chat: ChatSummary, answers: [String], skip: Bool, retry: Bool = false) async {
        guard let saved = connection, let store, !accessEnded, !previewMode, !resolving.contains(question.id) else { return }
        let key = partition
        resolving.insert(question.id); attentionErrors[question.id] = nil
        defer { if key == partition { resolving.remove(question.id) } }
        do {
            if retry {
                // Status must be authoritative before replaying uncertain bytes.
                // Terminal or missing questions never receive another POST.
                guard let current = await loadAsyncQuestions(chat) else {
                    guard key == partition else { return }
                    attentionErrors[question.id] = "Your Mac could not confirm this question's status. Your saved reply is still here."
                    return
                }
                guard key == partition else { return }
                guard let latest = current.first(where: { $0.id == question.id }) else {
                    attentionErrors[question.id] = "Your Mac no longer lists this question. Your saved reply is available to copy."
                    return
                }
                guard latest.canAnswer(now: UInt64(Date().timeIntervalSince1970 * 1000)) else { return }
            }
            let latest = asyncQuestions[chat.id]?.first(where: { $0.id == question.id }) ?? question
            guard latest.canAnswer(now: UInt64(Date().timeIntervalSince1970 * 1000)) else {
                restoreAsyncReplies([latest])
                return
            }
            let intentKey = "async-reply-" + question.id
            let payload: Data
            if let existing = try store.loadIntent(conversation: intentKey) { payload = existing }
            else {
                guard !retry else { throw ReadFailure.resync }
                let answer = AsyncAnswerIntent(answers: answers, skip: skip)
                if let error = answer.validationError(for: question) {
                    attentionErrors[question.id] = error.localizedDescription
                    return
                }
                payload = try JSONEncoder().encode(answer)
                try store.saveIntent(payload, conversation: intentKey)
            }
            savedAsyncReplies[question.id] = try JSONDecoder().decode(AsyncAnswerIntent.self, from: payload)
            retryableAsyncReplies.insert(question.id)
            struct Empty: Decodable, Sendable {}
            let _: Empty = try await api.request("/api/v1/conversations/\(Self.escape(chat.id))/questions/\(Self.escape(question.id))", origin: saved.origin, body: payload, credential: saved.credential)
            guard key == partition else { return }
            do {
                try store.removeIntent(conversation: intentKey)
                savedAsyncReplies.removeValue(forKey: question.id)
                retryableAsyncReplies.remove(question.id)
            } catch {
                attentionErrors[question.id] = "Your reply was accepted, but the saved copy could not be cleared. Check status again."
            }
            await loadAsyncQuestions(chat)
            await loadChats(force: true)
        } catch PairingFailure.response(let code) where code == 400 || code == 413 {
            guard key == partition else { return }
            // These responses reject the answer before it is recorded. Keep
            // the editable draft, but allow a corrected reply or an explicit Skip.
            do {
                try store.removeIntent(conversation: "async-reply-" + question.id)
                savedAsyncReplies.removeValue(forKey: question.id)
                retryableAsyncReplies.remove(question.id)
                attentionErrors[question.id] = code == 413
                    ? "This reply is too long. Shorten your answers and try again."
                    : "This reply was not accepted. Check your answers and try again, or skip the question."
            } catch {
                attentionErrors[question.id] = "The saved reply could not be cleared. Free some storage and try again."
            }
            await loadAsyncQuestions(chat)
        } catch {
            guard key == partition else { return }
            attentionErrors[question.id] = "Reply not confirmed. Check the saved reply; it may have expired or been answered elsewhere."
            await loadAsyncQuestions(chat)
        }
    }
    func requests(for chat: ChatSummary) -> [AttentionRequest] {
        var threads = Set(snapshots[chat.id]?.messages.compactMap(\.codexThreadId) ?? [])
        if let threadID = snapshots[chat.id]?.thread.threadId { threads.insert(threadID) }
        if let threadID = subagentSummary(for: chat.id)?.threadId { threads.insert(threadID) }
        let descendants = subagents[chat.id] ?? []
        return attention.filter { request in
            request.belongs(to: chat.id, isDirect: chat.botId != nil || isProject(chat), threadIDs: threads)
                || descendants.contains { request.belongs(to: $0.id, isDirect: true, threadIDs: [$0.threadId]) }
        }
    }
    func answerDraft(_ id: String) -> [String: String] {
        guard let data = try? store?.loadIntent(conversation: "answer-" + id) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
    func saveAnswerDraft(_ answers: [String: String], id: String) {
        do { try store?.saveIntent(JSONEncoder().encode(answers), conversation: "answer-" + id) }
        catch { attentionErrors[id] = "This answer could not be saved. Free some storage before replying." }
    }
    func resolve(_ request: AttentionRequest, choice: PhoneApprovalChoice, answers: [String: String]) async {
        do {
            let response = try request.responseJSON(for: choice, answers: answers)
            await resolve(request, decision: choice.decision, responseJSON: response, structuredDecision: choice.structuredDecision)
        } catch {
            attentionErrors[request.id] = "Check the required answers before replying."
        }
    }
    func resolve(_ request: AttentionRequest, decision: String, answers: [String: String] = [:],
                 responseJSON: String? = nil, structuredDecision: JSONValue? = nil) async {
        guard let saved = connection, !accessEnded, !resolving.contains(request.id), let store else { return }
        let key = partition
        resolving.insert(request.id); attentionErrors[request.id] = nil
        defer { if partition == key { resolving.remove(request.id) } }
        do {
            let intent: DecisionIntent
            if let data = try store.loadIntent(conversation: "decision-" + request.id) {
                intent = try JSONDecoder().decode(DecisionIntent.self, from: data)
                guard intent.actionNonce == request.actionNonce else { throw ReadFailure.resync }
            } else {
                var response = responseJSON
                if request.isQuestion {
                    let values = Dictionary(uniqueKeysWithValues: (request.params.questions ?? []).map {
                        ($0.id, ["answers": $0.answers(from: answers[$0.id] ?? "")])
                    })
                    let data = try JSONSerialization.data(withJSONObject: ["answers": values], options: [.sortedKeys, .withoutEscapingSlashes])
                    response = String(decoding: data, as: UTF8.self)
                }
                intent = DecisionIntent(request: request, decision: decision, responseJson: response, structuredDecision: structuredDecision)
                try store.saveIntent(JSONEncoder().encode(intent), conversation: "decision-" + request.id)
            }
            savedDecisions[request.id] = intent
            let target = ApprovalResolutionTarget(approvalID: request.id)
            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            let signature = try await signingIdentity.sign(intent.transcript(path: target.signedTarget, connection: saved, issuedAtMs: now))
            guard !accessEnded, connection?.credential.deviceId == saved.credential.deviceId else { throw CancellationError() }
            struct Empty: Decodable, Sendable {}
            let _: Empty = try await api.request(target.requestPath, origin: saved.origin, body: intent.payload(issuedAtMs: now, signature: signature), credential: saved.credential)
            guard partition == key else { return }
            attention.removeAll { $0.id == request.id }
            await loadAttention()
        } catch PairingFailure.response(400) {
            guard partition == key else { return }
            // The host rejects invalid replies before recording or forwarding
            // them. Let the owner correct a form or decline it; uncertain
            // transport failures still retain the exact signed intent below.
            do {
                try store.removeIntent(conversation: "decision-" + request.id)
                savedDecisions.removeValue(forKey: request.id)
                await loadAttention()
                attentionErrors[request.id] = "This reply was not accepted. Check the requested details, or decline the request."
            } catch {
                attentionErrors[request.id] = "The saved reply could not be cleared. Free some storage and try again."
            }
        } catch {
            guard partition == key else { return }
            if SigningIdentityFailure.requiresPairing(error) {
                try? requireIdentityRepair()
                stopForIdentityRecovery()
                return
            }
            await loadAttention()
            attentionErrors[request.id] = attention.contains(where: { $0.id == request.id })
                ? "Reply not confirmed. Try again to check the same saved answer."
                : "This request is no longer pending. It may have been resolved on another device or expired."
        }
    }

    func position(for chat: String) -> String? {
        (try? store?.loadPosition(conversation: chat)) ?? projection.positions[chat]
    }
    func feedRows(for chat: ChatSummary) -> [ReadRow] {
        ChatFeedEntry.visibleRows(rows(for: chat), queuedClientIDs: Set((queues[chat.id] ?? []).map(\.clientMessageId)))
    }
    private func projectedRows(for chat: ChatSummary) -> [ReadRow] {
        if rowCache?.id != chat.id || rowCache?.title != chat.title {
            #if WONDER_DIAGNOSTICS
            let projectStart = ProcessInfo.processInfo.systemUptime
            #endif
            rowCache = (chat.id, chat.title, groups[chat.id]?.rows ?? snapshots[chat.id]?.rows(author: chat.title) ?? [])
            #if WONDER_DIAGNOSTICS
            DiagnosticJournal.shared.record(DiagnosticEvent(operation: "rows.project", durationMs: (ProcessInfo.processInfo.systemUptime - projectStart) * 1000, count: UInt64(rowCache?.rows.count ?? 0)))
            #endif
        }
        return rowCache?.rows ?? []
    }
    private func pendingSends(_ chat: String) -> [PendingSend] {
        (composers[chat]?.recoveredPending ?? []) + [composers[chat]?.pending].compactMap { $0 }
    }
    func rows(for chat: ChatSummary) -> [ReadRow] {
        var rows = projectedRows(for: chat)
        for pending in pendingSends(chat.id) where !rows.contains(where: { $0.id == "user-" + pending.request.clientMessageId }) {
            rows.append(ReadRow(id: "user-" + pending.request.clientMessageId, author: "You",
                text: pending.request.body, isUser: true, timestamp: pending.createdAt, attachmentIds: pending.request.attachmentIds))
        }
        return rows
    }

    /// The open conversation's grouped timeline. Prepared once per content,
    /// queue, pending-send, active-turn or search-focus change; typing, scroll
    /// and unrelated model updates reuse it instead of regrouping all history.
    func timeline(for chat: ChatSummary, focusedRowID: String?) -> ConversationTimeline {
        _ = projectedRows(for: chat)
        let queued = Set((queues[chat.id] ?? []).map(\.clientMessageId))
        let key = ConversationTimeline.Key(chatID: chat.id, title: chat.title, rows: rowRevision, queued: queued,
            pending: pendingSends(chat.id).map(\.request.clientMessageId),
            activeTurns: activeTurnIDs(chat.id), activeTurn: activeTurn(chat.id), focusedRowID: focusedRowID)
        if let timelineCache, timelineCache.key == key { return timelineCache.value }
        #if WONDER_DIAGNOSTICS
        let start = ProcessInfo.processInfo.systemUptime
        #endif
        let value = ConversationTimeline(chatID: chat.id,
            rows: ChatFeedEntry.visibleRows(rows(for: chat), queuedClientIDs: queued),
            activeTurnIDs: key.activeTurns, activeTurnID: key.activeTurn, focusedRowID: focusedRowID,
            turns: groups[chat.id] == nil ? snapshots[chat.id]?.thread.turns : nil)
        #if WONDER_DIAGNOSTICS
        DiagnosticJournal.shared.record(DiagnosticEvent(operation: "timeline.group", durationMs: (ProcessInfo.processInfo.systemUptime - start) * 1000, count: UInt64(value.rows.count)))
        #endif
        timelineCache = (key, value)
        return value
    }
    func readReceipt(for conversation: String) -> VisibleReadReceipt? {
        if let group = groups[conversation] { return VisibleReadReceipt(group: group) }
        return snapshots[conversation].map(VisibleReadReceipt.init(snapshot:))
    }
    func hasUnread(_ conversation: String) -> Bool {
        if projectConversationIDs.contains(conversation) { return projects.hasUnread(conversation) }
        return chats.first { $0.id == conversation }?.hasUnread == true
    }
    func acknowledgeVisibleRead(_ visible: VisibleReadReceipt) async {
        guard !previewMode, foreground, !accessEnded, macConnected == true,
            visibleChat?.id == visible.conversationId,
            let saved = connection, readReceipt(for: visible.conversationId) == visible,
            !projection.dirty.contains(visible.conversationId) else { return }
        let run = generation
        let cursor = projection.lastSequence
        let summary = projection.summaries.first { $0.id == visible.conversationId }
        if projectConversationIDs.contains(visible.conversationId) {
            // Project threads keep read state in project metadata; the Mac
            // confirms with an empty reply rather than a Bot summary.
            guard projects.hasUnread(visible.conversationId), !projects.manuallyUnread.contains(visible.conversationId) else { return }
            let readRevision = projects.readRevision(visible.conversationId)
            struct Empty: Decodable, Sendable {}
            do {
                let _: Empty = try await api.request("/api/v1/conversations/" + Self.escape(visible.conversationId),
                    origin: saved.origin, body: visible.requestBody(), credential: saved.credential, method: "PATCH")
                guard !Task.isCancelled, foreground, run == generation, visibleChat?.id == visible.conversationId,
                    readReceipt(for: visible.conversationId) == visible, !projection.dirty.contains(visible.conversationId),
                    projects.readRevision(visible.conversationId) == readRevision,
                    connection?.credential.hostInstallationId == saved.credential.hostInstallationId,
                    connection?.credential.deviceId == saved.credential.deviceId, !accessEnded else { return }
                projects.markRead(visible.conversationId)
            } catch {
                if case PairingFailure.response(401) = error { readFailed(error, run: run) }
            }
            return
        }
        do {
            let group = groups[visible.conversationId]
            let groupReply: GroupRead?
            let botReply: ChatSummary?
            if let group {
                groupReply = try await api.request("/api/v1/group-chats/" + Self.escape(group.id) + "/read",
                    origin: saved.origin, body: visible.requestBody(isGroup: true), credential: saved.credential, method: "POST")
                botReply = nil
            } else {
                botReply = try await api.request("/api/v1/conversations/" + Self.escape(visible.conversationId),
                    origin: saved.origin, body: visible.requestBody(), credential: saved.credential, method: "PATCH")
                groupReply = nil
            }
            guard !Task.isCancelled, foreground, run == generation,
                projection.summaries.first(where: { $0.id == visible.conversationId }) == summary,
                visibleChat?.id == visible.conversationId,
                connection?.credential.hostInstallationId == saved.credential.hostInstallationId,
                connection?.credential.deviceId == saved.credential.deviceId, !accessEnded else { return }
            var next = projection
            let applied: Bool
            if let groupReply { applied = next.applyGroupReadAcknowledgement(groupReply, visible: visible, startedAtSequence: cursor) }
            else if let botReply { applied = next.applyReadAcknowledgement(botReply, visible: visible, startedAtSequence: cursor) }
            else { applied = false }
            if applied { try commit(next, publishing: group == nil ? .list : [.list, .groups]) }
        } catch {
            // Keep the unread indicator until an authoritative acknowledgement succeeds.
            if case PairingFailure.response(401) = error { readFailed(error, run: run) }
        }
    }

    func savePosition(_ position: String?, chat: String) {
        guard let position, !previewMode, projection.positions[chat] != position, let store else { return }
        // A scroll anchor must not re-encode and replace the entire chat history.
        // Replay cursor/invalidation persistence remains atomic in ReadStore.save.
        do { try store.savePosition(position, conversation: chat); projection.positions[chat] = position }
        catch { chatsStatus = "Reading position could not be saved." }
    }

    private func startReplay() {
        #if WONDER_DIAGNOSTICS
        guard diagnosticReplayEnabled else { return }
        #endif
        let run = generation
        replay = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == run { self.replay = nil } }
            while !Task.isCancelled && self.generation == run && self.foreground {
                do {
                    await self.check()
                    guard let saved = self.connection, !self.accessEnded else { return }
                    if self.projection.hostEpoch.isEmpty { try await self.resnapshot(saved, run: run) }
                    let challenge: Challenge = try await self.api.request("/api/v1/events/challenge", origin: saved.origin, credential: saved.credential)
                    try challenge.validate(origin: saved.origin, hostID: saved.credential.hostInstallationId, deviceID: saved.credential.deviceId)
                    let signature = try await self.signingIdentity.sign(challenge.transcript)
                    guard run == self.generation else { return }
                    let socket = try self.api.eventSocket(connection: saved)
                    self.socket = socket
                    socket.resume()
                    defer { socket.cancel(with: .goingAway, reason: nil) }
                    struct Subscription: Encodable { let deviceId: String; let hostEpoch: String; let lastSequence: UInt64; let csrfToken: String; let challengeId: String; let signature: String }
                    let payload = try JSONEncoder().encode(Subscription(deviceId: saved.credential.deviceId, hostEpoch: self.projection.hostEpoch, lastSequence: self.projection.lastSequence, csrfToken: saved.credential.csrfToken, challengeId: challenge.challengeId, signature: signature))
                    try await socket.send(.string(String(decoding: payload, as: UTF8.self)))
                    while !Task.isCancelled && run == self.generation {
                        let received = try await socket.receive()
                        let data: Data
                        switch received { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: throw ReadFailure.resync }
                        #if WONDER_DIAGNOSTICS
                        let applyStart = ProcessInfo.processInfo.systemUptime
                        #endif
                        let event = try JSONDecoder().decode(ReplayEvent.self, from: data)
                        guard run == self.generation else { return }
                        var next = self.projection
                        do { try next.consume(event) }
                        catch { try await self.resnapshot(saved, run: run); break }
                        // An event only advances the cursor and marks what is stale.
                        // Content arrives with the coalesced refresh below, so do not
                        // republish every chat or rewrite the cache on this thread.
                        guard let writer = self.writer else { throw ReadFailure.resync }
                        self.projection = next
                        writer.schedule(next)
                        if self.cachedConversationIds != next.dirty { self.cachedConversationIds = next.dirty }
                        #if WONDER_DIAGNOSTICS
                        DiagnosticJournal.shared.record(DiagnosticEvent(operation: "replay.apply", durationMs: (ProcessInfo.processInfo.systemUptime - applyStart) * 1000, bytes: UInt64(data.count)))
                        #endif
                        struct Ack: Encodable { let type = "ack"; let hostEpoch: String; let sequence: UInt64 }
                        let ack = try JSONEncoder().encode(Ack(hostEpoch: next.hostEpoch, sequence: next.lastSequence))
                        try await socket.send(.string(String(decoding: ack, as: UTF8.self)))
                        if event.conversationId != nil || !event.event.isHostRuntimeNotice { self.scheduleRefresh(run: run) }
                    }
                } catch {
                    self.readFailed(error, run: run)
                    if Task.isCancelled || run != self.generation { return }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private func resnapshot(_ saved: SavedConnection, run: UUID) async throws {
        struct Checkpoint: Decodable, Sendable { let hostEpoch: String; let lastSequence: UInt64; let hostInstallationId: String }
        let head: Checkpoint = try await api.request("/api/v1/sync/checkpoint", origin: saved.origin, credential: saved.credential)
        guard run == generation else { throw CancellationError() }
        guard head.hostInstallationId == saved.credential.hostInstallationId else { throw PairingFailure.wrongHost }
        var next = projection
        next.hostEpoch = head.hostEpoch
        next.lastSequence = head.lastSequence
        next.invalidatedThrough = nil
        next.invalidateAll()
        // Commit invalidations and head together; all stale scopes stay marked
        // until a successful authoritative read replaces them.
        try commit(next, publishing: [])
        try await refreshList(saved, run: run)
        if let chat = visibleChat {
            await refreshConversation(chat)
            await loadAsyncQuestions(chat)
            if chat.botId != nil || isProject(chat) { try? await loadQueue(chat) }
        }
    }

    private func scheduleRefresh(run: UUID) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self, run == self.generation, !Task.isCancelled else { return }
            defer { if run == self.generation { self.refreshTask = nil } }
            while run == self.generation && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard run == self.generation, !Task.isCancelled else { return }
                let before = self.projection.lastSequence
                if let saved = self.connection {
                    do { try await self.refreshList(saved, run: run) }
                    catch { self.readFailed(error, run: run) }
                }
                if let chat = self.visibleChat {
                    if self.projection.groups[chat.id] != nil {
                        // The list read above already replaced Group content.
                        try? self.reconcileGroupIntent(chat)
                    } else if self.projection.dirty.contains(chat.id) || self.projection.snapshots[chat.id] == nil {
                        // Events elsewhere do not re-download the open history.
                        await self.refreshConversation(chat)
                    }
                }
                if let parent = self.selectedChat {
                    if parent.botId != nil { await self.loadSubagents(parent) }
                    else if self.isProject(parent) { await self.loadProjectSubagents(parent) }
                }
                await self.loadAttention()
                if let chat = self.visibleChat, chat.botId != nil || self.isProject(chat) { try? await self.loadQueue(chat) }
                // Events arriving during the request require another refresh,
                // including the final token/completion when the stream goes quiet.
                if before == self.projection.lastSequence { return }
            }
        }
    }

    private func readFailed(_ failure: Error, run: UUID) {
        guard run == generation, !(failure is CancellationError) else { return }
        if SigningIdentityFailure.requiresPairing(failure) {
            try? requireIdentityRepair()
            stopForIdentityRecovery()
            return
        }
        cachedConversationIds = Set(snapshots.keys)
        cachedConversationIds.formUnion(groups.keys)
        if failure is URLError { macConnected = false }
        chatsStatus = "Computer unavailable. Showing saved chats."
        if (failure as NSError).domain == NSCocoaErrorDomain {
            chatsStatus = "Chats could not be saved on this phone. Free some storage and refresh."
        }
        if case PairingFailure.response(401) = failure {
            accessEnded = true
            stopReading()
            chatsStatus = "This device’s access has ended."
        }
    }

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
    func check(renew: Bool = false, userInitiated: Bool = false) async {
        guard !previewMode, !retiredAfterPairing, let saved = connection else { return }
        if saved.requiresPairing {
            if store == nil { await prepare(saved) }
            stopForIdentityRecovery()
            return
        }
        if let connectionCheck {
            await connectionCheck.value
            return
        }
        guard !busy else { return }
        checkingConnection = true
        defer { checkingConnection = false }
        // Preparing the cache changes the read generation. Do it before a
        // renewal captures that generation, including on a cold launch.
        await prepare(saved)
        guard !Task.isCancelled, !busy, !retiredAfterPairing,
              preparation?.isCancelled != true,
              connection?.credential.hostInstallationId == saved.credential.hostInstallationId,
              connection?.credential.deviceId == saved.credential.deviceId else { return }
        // Loading saved chats suspends; join a check another caller started meanwhile.
        if let connectionCheck {
            await connectionCheck.value
            return
        }
        if userInitiated { busy = true }
        defer { if userInitiated { busy = false } }
        let task = Task { await performConnectionCheck(renew: renew || macConnected != true || accessEnded) }
        connectionCheck = task
        await task.value
        connectionCheck = nil
    }

    private func performConnectionCheck(renew: Bool) async {
        guard let saved = connection else { return }
        let run = generation
        do {
            let nearingExpiry = saved.credential.expiresAtMs.map { $0 <= UInt64(Date().timeIntervalSince1970 * 1000) + 60_000 } ?? false
            if renew || nearingExpiry {
                struct Refresh: Encodable { let deviceId: String }
                let challenge: Challenge = try await api.request("/api/v1/pairing/session/refresh-challenge", origin: saved.origin, body: JSONEncoder().encode(Refresh(deviceId: saved.credential.deviceId)))
                guard run == generation else { return }
                try challenge.validate(origin: saved.origin, hostID: saved.credential.hostInstallationId, deviceID: saved.credential.deviceId)
                struct Signed: Encodable { let challengeId: String; let signature: String }
                let signature = try await signingIdentity.sign(challenge.transcript)
                guard run == generation else { return }
                let credential: Credential = try await api.request("/api/v1/pairing/session", origin: saved.origin, body: JSONEncoder().encode(Signed(challengeId: challenge.challengeId, signature: signature)))
                guard run == generation else { return }
                guard credential.deviceId == saved.credential.deviceId, credential.hostInstallationId == saved.credential.hostInstallationId else { throw PairingFailure.wrongHost }
                let updated = SavedConnection(origin: saved.origin, credential: credential, hostName: saved.hostName, storageDeviceId: saved.storageDeviceId)
                try saveConnection(updated); connection = updated
            }
            struct Device: Decodable, Sendable { let id: String; let revokedAt: String? }
            let current = connection ?? saved
            let devices: [Device] = try await api.request("/api/v1/devices", origin: current.origin, credential: current.credential)
            guard run == generation else { return }
            guard devices.contains(where: { $0.id == current.credential.deviceId && $0.revokedAt == nil }) else { throw PairingFailure.response(401) }
            guard connection?.credential.hostInstallationId == current.credential.hostInstallationId else { return }
            macConnected = true
            status = "Connected to your computer."; error = nil; accessEnded = false
            struct Host: Decodable, Sendable { let hostInstallationId: String; let hostName: String? }
            if let host: Host = try? await api.request("/api/v1/host/status", origin: current.origin, credential: current.credential),
               run == generation, host.hostInstallationId == current.credential.hostInstallationId,
               let name = host.hostName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
               let latest = connection, latest.credential.hostInstallationId == host.hostInstallationId,
               latest.hostName != name {
                let updated = SavedConnection(origin: latest.origin, credential: latest.credential, hostName: name, storageDeviceId: latest.storageDeviceId)
                try saveConnection(updated)
                connection = updated
            }
        } catch PairingFailure.response(401) {
            guard run == generation else { return }
            status = "This device’s access has ended."; error = nil; accessEnded = true; stopReading(); cachedConversationIds = Set(snapshots.keys)
        } catch {
            guard run == generation, !(error is CancellationError) else { return }
            if SigningIdentityFailure.requiresPairing(error) {
                do { try requireIdentityRepair() }
                catch { self.error = error.localizedDescription }
                stopForIdentityRecovery()
                return
            }
            macConnected = false
            if let network = error as? URLError {
                switch network.code {
                case .notConnectedToInternet:
                    status = "Your iPhone is offline. Connect to the internet and try again."
                case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .timedOut:
                    status = "Could not reach your Mac. Check that Tailscale is connected on both devices, then try again."
                default:
                    status = "The connection was interrupted. Try again."
                }
            } else if let failure = error as? PairingFailure {
                status = failure.localizedDescription
            } else {
                status = "Could not connect to your computer."
            }
            self.error = error is SigningIdentityFailure ? error.localizedDescription : nil
        }
    }
    private func saveConnection(_ saved: SavedConnection) throws {
        if let persistConnection { try persistConnection(saved) }
        else { try identity.save(JSONEncoder().encode(saved), account: "connection") }
    }

    func forget() async {
        guard !busy else { error = "Wait for the connection check to finish, then try again."; return }
        busy = true
        defer { busy = false }
        do {
            dictation.forget()
            stopReading()
            preparation?.cancel()
            // Removal runs on the writer queue, after any write already started,
            // so a pending cache write cannot recreate the forgotten chats.
            if let writer { try await writer.remove() }
            else if let target = store ?? connection.map(Self.readStore(for:)) { try await ProjectionWriter(store: target).remove() }
            if let saved = connection { ManagementDraftStore(host: saved.credential.hostInstallationId).removeAll() }
            projects.forgetCache()
            if let saved = connection { NewChatDraftStore.remove(host: saved.credential.hostInstallationId) }
            if let persistConnection { try persistConnection(nil) }
            else { try identity.forgetConnection() }
            partition = nil; store = nil; writer = nil; projection = ProjectionState(); publish(.everything)
            projectSubagentLoadTokens = [:]
            projectSubagentAvailability = [:]
            projectSubagentLookup = [:]
            projectSubagentFreshIDs = [:]
            projectSubagentNextCurrentCursor = [:]
            projectSubagentNextArchivedCursor = [:]
            projectSubagentInitialCurrentCursor = [:]
            projectSubagentInitialArchivedCursor = [:]
            projectSubagentSeenCurrentCursors = [:]
            projectSubagentSeenArchivedCursors = [:]
            projectSubagentExpandedParents = []
            projectSubagentPagingLimited = []
            projectSubagentRefreshPending = []
            projectSubagentPageRevision = [:]
            loadingOlderProjectSubagents = []
            subagents = [:]; subagentAvailability = [:]; subagentErrors = [:]; projectSubagents = [:]; projectSubagentErrors = [:]; composers = [:]; composerErrors = [:]; sending = []; preparingSends = []; intentLoadFailures = []; attention = []; asyncQuestions = [:]; retryableAsyncReplies = []; savedAsyncReplies = [:]; attentionErrors = [:]; resolving = []; savedDecisions = [:]; files = [:]; queues = [:]; uploading = []; stopping = []; controlErrors = [:]
            selectedChat = nil; managedBots = []; managedBotMutations = ManagedBotListMutationState(); macConnected = nil; hasConnectedThisLaunch = false; connection = nil; error = nil; accessEnded = false
            status = "Connect to your computer to get started."
        }
        catch { self.error = error.localizedDescription }
    }
}

/// A conversation's grouped rows and the per-row lookups its view needs,
/// derived once from one projection revision.
struct ConversationTimeline {
    struct Key: Equatable {
        let chatID: String
        let title: String
        let rows: UInt64
        let queued: Set<String>
        let pending: [String]
        let activeTurns: Set<String>
        let activeTurn: String?
        let focusedRowID: String?
    }
    let rows: [ReadRow]
    let previous: [String: ReadRow]
    let entries: [ChatFeedEntry]
    let latestActivityEntryIDs: Set<String>
    let latestActiveActivityEntryID: String?
    let disclosureEntries: [ActivityDisclosurePolicy.Entry]
    let retainedTurnIDs: Set<String>
    let attachmentIDs: [String]
    let turns: [String: ReadTurn]
    let conversationEdits: ResponseEditedFiles?

    init(chatID: String, rows: [ReadRow], activeTurnIDs: Set<String>, activeTurnID: String?, focusedRowID: String?, turns: [ReadTurn]?) {
        self.rows = rows
        previous = Dictionary(zip(rows.dropFirst(), rows).map { ($0.0.id, $0.1) }, uniquingKeysWith: { first, _ in first })
        entries = ChatFeedEntry.grouping(rows, activeTurnIDs: activeTurnIDs, focusedRowID: focusedRowID)
        conversationEdits = ResponseEditedFiles.conversation(entries: entries, activeTurnIDs: activeTurnIDs)
        latestActivityEntryIDs = ChatFeedEntry.latestActivityEntryIDs(entries)
        latestActiveActivityEntryID = ChatFeedEntry.latestActivityEntryID(entries, turnID: activeTurnID)
        var byID: [String: ReadTurn] = [:]
        for turn in turns ?? [] where byID[turn.id] == nil { byID[turn.id] = turn }
        self.turns = byID
        disclosureEntries = entries.compactMap { entry in
            guard entry.isActivity, let turnID = entry.rows.first?.turnId else { return nil }
            return ActivityDisclosurePolicy.Entry(conversationID: chatID, turnID: turnID, entryID: entry.id,
                lifecycle: ActivityDisclosurePolicy.lifecycle(for: byID[turnID]),
                autoOpenWhileActive: activeTurnIDs.contains(turnID))
        }
        retainedTurnIDs = turns.map { Set($0.map(\.id)) } ?? Set(disclosureEntries.map { $0.key.turnID })
        attachmentIDs = rows.flatMap(\.attachmentIds)
    }
}

#if WONDER_DIAGNOSTICS
/// A tiny generated black MP4 lets the real Files sheet exercise AVFoundation's
/// authenticated range path without a paired Mac or a model request.
private final class DiagnosticWorkspaceMediaProtocol: URLProtocol, @unchecked Sendable {
    static let video = Data(base64Encoded: "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMxbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAB9AAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAlx0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAB9AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAEAAAABAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAfQAAAAAAABAAAAAAHUbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAAAgABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABf21pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAT9zdGJsAAAAv3N0c2QAAAAAAAAAAQAAAK9hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEAAQABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMSBsaWJ4MjY0AAAAAAAAAAAAAAAAGP//AAAANWF2Y0MBZAAK/+EAGGdkAAqs2UQmwEQAAAMABAAAAwAIPEiWWAEABmjr48siwP34+AAAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAAALmAAAAAAAAAAYc3R0cwAAAAAAAAABAAAAAgAAQAAAAAAUc3RzcwAAAAAAAAABAAAAAQAAABxzdHNjAAAAAAAAAAEAAAABAAAAAgAAAAEAAAAcc3RzegAAAAAAAAAAAAAAAgAAAtcAAAAPAAAAFHN0Y28AAAAAAAAAAQAAA2EAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAxAAAACGZyZWUAAALubWRhdAAAAq0GBf//qdxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0zIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDM6MHgxMTMgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTEgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0yIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MyBiX3B5cmFtaWQ9MiBiX2FkYXB0PTEgYl9iaWFzPTAgZGlyZWN0PTEgd2VpZ2h0Yj0xIG9wZW5fZ29wPTAgd2VpZ2h0cD0yIGtleWludD0yNTAga2V5aW50X21pbj0xIHNjZW5lY3V0PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAAImWIhAAW//730z/MsuyaJLXjqPeinIvz0z8pUaJ8gb17Rs0AAAALQZohbEFf/talm0A=") ?? Data()
    private static let revision = String(repeating: "a", count: 64)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "workspace-media.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if ProcessInfo.processInfo.arguments.contains("-workspace-media-offline-preview") {
            reply(url: url, status: 503, bytes: Data(), headers: [:])
            return
        }
        guard request.value(forHTTPHeaderField: "Origin") == "https://workspace-media.invalid",
              request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("__Host-wonder_session=") == true,
              let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") else {
            reply(url: url, status: 403, bytes: Data(), headers: [:])
            return
        }
        let parts = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]), let requestedEnd = Int(parts[1]),
              start >= 0, requestedEnd >= start, start < Self.video.count else {
            reply(url: url, status: 416, bytes: Data(), headers: [:])
            return
        }
        if let revision = request.value(forHTTPHeaderField: "X-Wonder-Revision"),
           revision != Self.revision {
            reply(url: url, status: 409, bytes: Data(), headers: [:])
            return
        }
        if request.value(forHTTPHeaderField: "X-Wonder-Revision") != nil,
           ProcessInfo.processInfo.arguments.contains("-workspace-media-stale-preview") {
            reply(url: url, status: 409, bytes: Data(), headers: [:])
            return
        }
        let end = min(requestedEnd, Self.video.count - 1)
        let bytes = Self.video.subdata(in: start..<(end + 1))
        reply(url: url, status: 206, bytes: bytes, headers: [
            "Content-Type": "video/mp4",
            "Content-Length": String(bytes.count),
            "Content-Range": "bytes \(start)-\(end)/\(Self.video.count)",
            "X-Wonder-Revision": Self.revision
        ])
    }

    override func stopLoading() {}

    private func reply(url: URL, status: Int, bytes: Data, headers: [String: String]) {
        guard let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !bytes.isEmpty { client?.urlProtocol(self, didLoad: bytes) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
