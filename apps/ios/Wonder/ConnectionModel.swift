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
    let checkedAtMs: UInt64
    let windows: [CodexUsageWindow]
}

struct CodexUsageCacheEntry: Sendable {
    let response: CodexUsageResponse
    let fetchedAt: Date
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
                codexUsageCache = [:]
                goals = [:]; goalErrors = [:]; goalMutationTokens = [:]
                resetImagePreviews()
                dictation.connectionChanged()
                cameraContextID = UUID()
            }
        }
    }
    var connectedAppsCache: [String: ConnectedAppCacheEntry] = [:]
    @Published var codexUsageCache: [String: CodexUsageCacheEntry] = [:]
    let imagePreviews = ToolImagePreviews()
    private(set) var imagePreviewScope = UUID()
    private func resetImagePreviews() {
        imagePreviewScope = UUID()
        imagePreviews.invalidate()
    }
    lazy var dictation = DictationController(model: self)
    @Published var status = "Connect to your computer to get started."
    @Published var busy = false
    @Published var verification: String?
    @Published var error: String?
    @Published var accessEnded = false { didSet { if accessEnded { cancelApprovalSettings(); connectedAppsCache = [:]; codexUsageCache = [:]; goals = [:]; goalErrors = [:]; goalMutationTokens = [:]; resetImagePreviews(); dictation.forget(); cameraContextID = UUID() } } }
    @Published var chats: [ChatSummary] = []
    @Published var subagents: [String: [SubagentSummary]] = [:]
    @Published var subagentAvailability: [String: Bool] = [:]
    @Published var subagentErrors: [String: String] = [:]
    @Published var goals: [String: ConversationGoal] = [:]
    @Published var goalErrors: [String: String] = [:]
    private var goalMutationTokens: [String: UUID] = [:]
    @Published var savingComposerSettings: Set<String> = []
    @Published var composerApprovalChanges: [ComposerApprovalTarget: ComposerApprovalChange] = [:]
    var composerApprovalTasks: [ComposerApprovalTarget: Task<Void, Never>] = [:]
    var composerApprovalTokens: [ComposerApprovalTarget: UUID] = [:]
    @Published var managedBots: [ManagedBot] = []
    @Published var snapshots: [String: ConversationSnapshot] = [:] { didSet { rowCache = nil } }
    @Published var groups: [String: GroupRead] = [:] { didSet { rowCache = nil } }
    // Retain only the most recently presented conversation. Expansion and scroll
    // state do not change its source rows or require reparsing every timestamp.
    private var rowCache: (id: String, title: String, rows: [ReadRow])?
    @Published var selectedChat: ChatSummary? {
        didSet { if selectedChat?.id != oldValue?.id { visibleChat = selectedChat } }
    }
    // The list keeps the root selected while navigation can show a verified child.
    @Published private(set) var visibleChat: ChatSummary? {
        didSet { if visibleChat?.id != oldValue?.id { cameraContextID = UUID() } }
    }
    @Published private(set) var cameraContextID = UUID()
    @Published var searchFocus: SearchMessageFocus?
    @Published private(set) var chatsReadPresentation = ReadPresentationFence()
    @Published var loadingChats = false
    @Published var loadingConversation = false
    @Published var cachedConversationIds: Set<String> = []
    @Published var chatsStatus = "Saved chats"
    @Published private(set) var hasConnectedThisLaunch = false
    @Published private(set) var checkingConnection = false
    @Published private var listRefreshCount = 0
    var isRefreshing: Bool { checkingConnection || loadingChats || listRefreshCount > 0 }
    @Published var macConnected: Bool? {
        didSet { if macConnected == true { hasConnectedThisLaunch = true } }
    }
    var macName: String { connection?.hostName ?? (previewMode ? "Studio" : "Your computer") }
    var macStatus: String {
        if connection?.requiresPairing == true { return "Pair again" }
        if accessEnded { return "Access ended" }
        switch macConnected {
        case true: return "Connected"
        case false: return "Disconnected"
        default: return "Connecting…"
        }
    }
    var chatNotice: String? {
        ["Connected to your computer", "Saved chats", "Computer unavailable. Showing saved chats.", "This device’s access has ended."].contains(chatsStatus) ? nil : chatsStatus
    }
    @Published var composers: [String: ComposerIntent] = [:]
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
    @Published var attention: [AttentionRequest] = []
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
    private var enrollment: Task<Void, Never>?
    private var replay: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    private var projection = ProjectionState()
    private var summaryRevision: UInt64 = 0
    private var managedBotMutations = ManagedBotListMutationState()
    private var partition: String?
    private var retiredAfterPairing = false
    private var store: ReadStore?
    private var foreground = false
    #if WONDER_DIAGNOSTICS
    private var diagnosticReplayEnabled = true
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
            var group: [String: Any] = [
                "id": "preview-group", "conversationId": "preview", "name": ProcessInfo.processInfo.arguments.contains("-assignment-preview") ? "Wonder Developers" : (saved?.hostName == "Laptop" ? "Travel plans" : saved?.hostName == "Home" ? "Reading list" : "Weekend plans"), "isArchived": false,
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
                    composerAttachmentsPreview || composerRestoredPreview || composerRunningPreview || composerQueuedPreview || messageAttachmentsPreview ||
                    (ProcessInfo.processInfo.arguments.contains("-connections-preview") && saved?.hostName == "Studio") {
                    let thread: [String: Any] = composerRunningPreview
                        ? ["hydrated": true, "turns": [[
                            "id": "fixture-turn", "status": "inProgress", "startedAt": "1700000000000", "items": []
                        ]]]
                        : ["hydrated": true]
                    var assistantMessages: [[String: Any]] = [[
                        "messageId": "2", "codexTurnId": "fixture-turn", "itemId": "fixture-item",
                        "text": "Start with breakfast at home, then take a walk. Leave the afternoon open so the day stays flexible.",
                        "state": "completed", "createdAt": "1700000001000", "updatedAt": "1700000001000"
                    ]]
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
                        "messages": [["messageId": "1", "body": messageAttachmentsPreview ? "Here are the reference images and notes." : "Can you help me plan a relaxed Saturday?", "state": (ProcessInfo.processInfo.arguments.contains("-active-preview") || composerRunningPreview) ? "streaming" : "completed", "codexTurnId": "fixture-turn", "codexThreadId": "fixture-thread", "createdAt": "1700000000000", "attachmentIds": messageAttachmentsPreview ? ["message-image-1", "message-image-2", "message-notes"] : []]],
                        "assistantMessages": assistantMessages,
                        "thread": thread
                    ]
                    let summary: [String: Any] = ["conversationId": "preview", "botId": "ada", "title": "Ada", "lastMessagePreview": "Leave the afternoon open so the day stays flexible.", "messageCount": 2, "hasUnread": false, "isArchived": false, "isPinned": false]
                    if let data = try? JSONSerialization.data(withJSONObject: fixture),
                       let snapshot = try? JSONDecoder().decode(ConversationSnapshot.self, from: data),
                       let data = try? JSONSerialization.data(withJSONObject: summary),
                       let chat = try? JSONDecoder().decode(ChatSummary.self, from: data) {
                        groups = [:]; snapshots = ["preview": snapshot]; chats = [chat]
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
                    "url": #"{"approvalId":"fixture-url","conversationId":"preview","method":"mcpServer/elicitation/request","actionNonce":"fixture","params":{"threadId":"fixture-thread","turnId":"fixture-turn","mode":"url","message":"Connect the export service.","url":"https://example.com/authorize"}}"#,
                    "unknown": #"{"approvalId":"fixture-unknown","conversationId":"preview","method":"item/tool/call","actionNonce":"fixture","params":{"threadId":"fixture-thread","turnId":"fixture-turn","tool":"unknown_tool","arguments":{"secret":"not exposed"}}}"#,
                ]
                if let json = fixtures[arguments[index + 1]], let value = try? JSONDecoder().decode(AttentionRequest.self, from: Data(json.utf8)) { attention = [value] }
            }
            if ProcessInfo.processInfo.arguments.contains("-question-preview") {
                let json = """
                {"approvalId":"fixture-question","method":"item/tool/requestUserInput","actionNonce":"fixture","params":{"threadId":"fixture-thread","isBlocking":false,"questions":[{"id":"day","question":"Which day works best?","options":[{"label":"Saturday","description":"Keep Sunday free."},{"label":"Sunday"}]}]}}
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
                let reply = commandFailed ? "The test command failed. I checked the remaining project files and notes." : failed ? "The tests passed, but I couldn’t load the project notes." : "The tests passed. I updated the chat labels and checked the project notes."
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
            if ProcessInfo.processInfo.arguments.contains("-onboarding-preview") {
                let waiting = arguments.contains("-onboarding-loading-preview")
                let fixture: [String: Any] = ["conversationId":"preview", "hostEpoch":"preview", "lastSequence":0, "messages":[], "assistantMessages":[], "thread":["hydrated":true], "initialization": waiting ? [:] : ["questionId":"onboarding-fixture"]]
                let summary: [String: Any] = ["conversationId":"preview", "botId":"ada", "title":"Luna", "messageCount":0, "hasUnread":false, "isArchived":false, "isPinned":false]
                if let data = try? JSONSerialization.data(withJSONObject: fixture), let snapshot = try? JSONDecoder().decode(ConversationSnapshot.self, from: data),
                   let data = try? JSONSerialization.data(withJSONObject: summary), let chat = try? JSONDecoder().decode(ChatSummary.self, from: data) {
                    groups = [:]; snapshots = ["preview":snapshot]; chats = [chat]; composers["preview"] = ComposerIntent()
                    // Recorded Luna questionnaire; only the preview supplies fixture content.
                    let question: [String: Any] = ["id":"onboarding-fixture", "conversationId":"preview", "turnId":"fixture-turn", "itemId":"wonder-purpose", "questions":[["title":"What should I help with?", "options":["Build and debug software", "Research and explain ideas", "Plan and organize projects"]]], "state":"pending", "expiresAtMs":UInt64(Date().timeIntervalSince1970 * 1000) + 300_000]
                    if !waiting, let data = try? JSONSerialization.data(withJSONObject: question), let value = try? JSONDecoder().decode(AsyncQuestion.self, from: data) { asyncQuestions["preview"] = [value] }
                    if waiting { asyncQuestions["preview"] = [] }
                    let appearance = #"{"id":"ada","name":"Luna","role":"Test","systemPrompt":"","workspacePath":"/preview","permissionProfile":":workspace","isArchived":false,"avatarShape":"luna","avatarPalette":"ocean"}"#
                    if let bot = try? JSONDecoder().decode(ManagedBot.self, from: Data(appearance.utf8)) { managedBots = [bot] }
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
    init(cameraFixtureStoreRoot root: URL, saved: SavedConnection, chat: ChatSummary? = nil, initialIntent: ComposerIntent = ComposerIntent(), api: PairingAPI? = nil, replayEnabled: Bool = true) {
        signingIdentity = PhoneIdentity.signing
        persistConnection = nil
        diagnosticReplayEnabled = replayEnabled
        #if WONDER_DIAGNOSTICS
        self.api = api ?? Self.diagnosticAPI()
        #else
        self.api = api ?? PairingAPI()
        #endif
        connection = saved
        let fixtureStore = ReadStore(root: root, host: saved.credential.hostInstallationId, device: saved.storageDeviceId)
        store = fixtureStore
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
                if let data = try fixtureStore.loadIntent(conversation: chat.id) {
                    composers[chat.id] = try JSONDecoder().decode(ComposerIntent.self, from: data)
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
        guard let saved = connection, !accessEnded else { return }
        let scope = assignmentScope
        let origin = saved.origin
        if !force, let cached = codexUsageCache[scope], Date().timeIntervalSince(cached.fetchedAt) < 300 {
            return
        }

        #if WONDER_DIAGNOSTICS
        if ProcessInfo.processInfo.arguments.contains("-diagnostics-usage-fixture") {
            let fixture = CodexUsageResponse(
                checkedAtMs: 1_700_000_000_000,
                windows: [
                    CodexUsageWindow(id: "five-hours", label: "5 hours", usedPercent: 27, remainingPercent: 73, windowDurationMins: 300, resetsAt: 1_700_018_000_000),
                    CodexUsageWindow(id: "weekly", label: "Weekly", usedPercent: 41, remainingPercent: 59, windowDurationMins: 10_080, resetsAt: 1_700_604_800_000)
                ]
            )
            guard scope == assignmentScope, connection?.origin == origin, !accessEnded else { return }
            codexUsageCache[scope] = CodexUsageCacheEntry(response: fixture, fetchedAt: Date())
            return
        }
        #endif

        let response: CodexUsageResponse = try await api.request("/api/v1/account/usage", origin: saved.origin, credential: saved.credential)
        guard scope == assignmentScope, connection?.origin == origin, !accessEnded else { return }
        codexUsageCache[scope] = CodexUsageCacheEntry(response: response, fetchedAt: Date())
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
            cachedConversationIds = Set(snapshots.keys)
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

    private func prepare(_ saved: SavedConnection) {
        guard !retiredAfterPairing else { return }
        let key = saved.credential.hostInstallationId + ":" + saved.credential.deviceId
        guard partition != key else { return }
        stopReading()
        partition = key
        subagents = [:]; subagentAvailability = [:]; subagentErrors = [:]; composers = [:]; composerErrors = [:]; sending = []; preparingSends = []; intentLoadFailures = []; attention = []; asyncQuestions = [:]; retryableAsyncReplies = []; savedAsyncReplies = [:]; attentionErrors = [:]; resolving = []; savedDecisions = [:]; files = [:]; queues = [:]; uploading = []; stopping = []; controlErrors = [:]
        store = ReadStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wonder/Hosts"), host: saved.credential.hostInstallationId, device: saved.storageDeviceId)
        do { projection = try store?.load() ?? ProjectionState() }
        catch { projection = ProjectionState(); chatsStatus = "Saved chats could not be read. Reconnect to refresh." }
        projection.dirty.formUnion(projection.snapshots.keys)
        projection.dirty.formUnion(projection.groups.keys)
        managedBotMutations = ManagedBotListMutationState()
        publish()
        selectedChat = nil
        dictation.restore(force: true)
    }

    private func publish() {
        #if WONDER_DIAGNOSTICS
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        defer { DiagnosticJournal.shared.record(DiagnosticEvent(operation: "projection", durationMs: (ProcessInfo.processInfo.systemUptime-diagnosticStart)*1000)) }
        #endif
        managedBots = projection.managedBots ?? []
        chats = projection.summaries.filter { !$0.isArchived }
        snapshots = projection.snapshots
        groups = projection.groups
        cachedConversationIds = projection.dirty
    }

    private func commit(_ next: ProjectionState) throws {
        guard let store else { throw ReadFailure.resync }
        try store.save(next)
        projection = next
        publish()
    }

    func loadChats(force: Bool = false) async {
        guard !previewMode else { return }
        // Startup and foreground reads must use the session established by the
        // shared check, not race renewal with the credential restored from disk.
        await check()
        guard let saved = connection, !accessEnded, macConnected == true else { return }
        prepare(saved)
        if replay == nil && foreground { startReplay() }
        guard !loadingChats else { return }
        loadingChats = true
        defer { loadingChats = false }
        let run = generation
        do {
            try await refreshList(saved, run: run)
            if let chat = visibleChat {
                if let parent = selectedChat, parent.botId != nil { await loadSubagents(parent) }
                await refreshConversation(chat)
                await loadAsyncQuestions(chat)
                if chat.botId != nil { try? await loadQueue(chat) }
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
        summaryRevision &+= 1
        next.summaries = projectVisibleChatSummaries(remote: remote, groups: groupList, activeBotIDs: activeBotIDs)
        let groupIDs = Set(groupList.map(\.conversationId))
        next.groups = Dictionary(uniqueKeysWithValues: groupList.map { ($0.conversationId, $0) })
        if cursor == projection.lastSequence { next.dirty.subtract(groupIDs) }
        next.listDirty = cursor != projection.lastSequence
        try commit(next)
        macConnected = true
        chatsStatus = "Connected to your computer"
    }

    /// Applies only a server-confirmed Bot mutation. Callers must not mutate
    /// `managedBots` directly after a PATCH response, otherwise an older list
    /// request can overwrite the new avatar or settings.
    func applyConfirmedManagedBot(_ bot: ManagedBot) {
        managedBots = managedBotMutations.confirm(bot, current: managedBots)
        projection.managedBots = managedBots
        do { try store?.save(projection) }
        catch { chatsStatus = "Bot saved. Reconnect before closing the app to save its updated appearance on this device." }
    }

    func subagentSummary(for conversationID: String) -> SubagentSummary? {
        subagents.values.lazy.flatMap { $0 }.first(where: { $0.conversationId == conversationID })
    }

    func isSubagent(_ chat: ChatSummary) -> Bool {
        subagentSummary(for: chat.id) != nil
    }

    func loadGoal(_ chat: ChatSummary) async {
        guard chat.botId != nil, !isSubagent(chat), !previewMode,
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
        guard chat.botId != nil, !isSubagent(chat), let saved = connection, !accessEnded else { return false }
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
        guard chat.botId != nil, !isSubagent(chat), let saved = connection, !accessEnded else { return }
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
        if chat.botId != nil { await loadSubagents(chat) }
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

    func editDraft(_ text: String, chat: String) {
        guard !intentLoadFailures.contains(chat), !uploading.contains(chat), !preparingSends.contains(chat) else { return }
        var next = composers[chat] ?? ComposerIntent()
        next.draft = text
        // Keep the text in memory even if disk is full, and block Send until saved.
        composers[chat] = next
        do { try saveComposer(next, chat: chat); composerErrors[chat] = nil }
        catch { composerErrors[chat] = "This draft could not be saved. Free some storage before sending." }
    }

    func savedDictationIntent() throws -> DictationIntent? {
        guard let data = try store?.loadIntent(conversation: "dictation.current") else { return nil }
        let intent = try JSONDecoder().decode(DictationIntent.self, from: data)
        guard intent.hostID == connection?.credential.hostInstallationId,
            intent.deviceID == connection?.credential.deviceId else { throw PairingFailure.wrongHost }
        return intent
    }
    func persistDictationIntent(_ intent: DictationIntent) throws {
        guard let store, intent.hostID == connection?.credential.hostInstallationId,
            intent.deviceID == connection?.credential.deviceId else { throw PairingFailure.wrongHost }
        try store.saveIntent(JSONEncoder().encode(intent), conversation: "dictation.current")
    }
    func clearDictationIntent() throws { try store?.removeIntent(conversation: "dictation.current") }
    func insertDictation(job: TranscriptionJob, intent: DictationIntent) throws {
        guard !intent.cancelled, intent.accepts(job), job.state == "completed", let text = job.transcriptText,
            intent.hostID == connection?.credential.hostInstallationId,
            intent.deviceID == connection?.credential.deviceId, !accessEnded,
            chats.contains(where: { $0.id == intent.conversationID }) else { throw PairingFailure.wrongHost }
        loadComposer(intent.conversationID)
        guard !intentLoadFailures.contains(intent.conversationID) else { throw ReadFailure.resync }
        guard !preparingSends.contains(intent.conversationID) else { throw SendFailure.pending }
        var composer = composers[intent.conversationID] ?? ComposerIntent()
        try composer.appendDictation(text, requestID: intent.requestID)
        // Text and insertion receipt are one atomic write, including after reconnect.
        try saveComposer(composer, chat: intent.conversationID)
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

    func chatListStatus(_ chat: ChatSummary) -> ChatListStatus {
        let working: Bool
        if chat.botId == nil || (snapshots[chat.id] != nil && !cachedConversationIds.contains(chat.id)) {
            working = botWorking(chat.id)
        } else {
            // The list must show live work before a conversation is opened.
            // A refreshed summary also supersedes an invalidated cached turn.
            working = ["accepted_by_wonder", "dispatching_to_codex", "accepted_by_codex", "streaming"].contains(chat.deliveryState ?? "")
        }
        return working ? .working : chat.hasUnread ? .unread : .read
    }

    func activeTurn(_ chat: String) -> String? {
        snapshots[chat]?.activeTurnID
    }

    func activeTurnIDs(_ chat: String) -> Set<String> {
        snapshots[chat]?.activeTurnIDs ?? []
    }

    func turn(_ turnID: String?, in chat: String) -> ReadTurn? {
        guard let turnID else { return nil }
        return snapshots[chat]?.thread.turns?.first(where: { $0.id == turnID })
    }
    func canGuide(_ chat: ChatSummary) -> Bool {
        !preparingSends.contains(chat.id) && !savingComposerSettings.contains(chat.id) && !approvalSettingsBlockSending(chat.id) && !chat.isArchived && !uploading.contains(chat.id) && !loadingPhotos.contains(chat.id) && chat.botId != nil && activeTurn(chat.id) != nil && connection != nil && !accessEnded
            && !isSubagent(chat)
            && !sending.contains(chat.id)
            && composers[chat.id]?.pending == nil && composerErrors[chat.id] == nil
            && !(composers[chat.id]?.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (composers[chat.id]?.draft.utf8.count ?? 0) <= 65536
            && (composers[chat.id]?.attachmentCount ?? 0) <= 4
    }
    func guide(_ chat: ChatSummary) async {
        guard canGuide(chat), let saved = connection, let turn = activeTurn(chat.id) else { return }
        let scope = assignmentScope
        do {
            var next = composers[chat.id] ?? ComposerIntent()
            try await uploadStaged(chat)
            guard scope == assignmentScope, connection?.origin == saved.origin, !accessEnded,
                  !Task.isCancelled, activeTurn(chat.id) == turn,
                  !savingComposerSettings.contains(chat.id), !approvalSettingsBlockSending(chat.id) else { return }
            next = composers[chat.id] ?? next
            try next.begin(device: saved.credential.deviceId, expectedTurnId: turn)
            try saveComposer(next, chat: chat.id)
            await deliver(chat)
        } catch { controlErrors[chat.id] = "Guide could not be saved. Your text is still here." }
    }
    func stop(_ chat: ChatSummary) async {
        guard !isSubagent(chat) else { return }
        guard let turn = activeTurn(chat.id), let saved = connection, !accessEnded,
              chat.botId != nil, !stopping.contains(chat.id) else { return }
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

    func waitingForInitialQuestion(_ chat: ChatSummary) -> Bool {
        snapshots[chat.id]?.initialization?.isWaiting(questions: asyncQuestions[chat.id] ?? []) == true
    }

    func canSend(_ chat: ChatSummary) -> Bool {
        let draft = composers[chat.id]?.draft ?? ""
        return !waitingForInitialQuestion(chat) && !preparingSends.contains(chat.id) && !savingComposerSettings.contains(chat.id) && !approvalSettingsBlockSending(chat.id) && !chat.isArchived && (chat.botId != nil || groups[chat.id] != nil) && connection != nil && !accessEnded
            && !isSubagent(chat)
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
    }

    func send(_ chat: ChatSummary) async {
        guard canSend(chat), let saved = connection else { return }
        let scope = assignmentScope
        preparingSends.insert(chat.id)
        controlErrors[chat.id] = nil
        defer { if scope == assignmentScope { preparingSends.remove(chat.id) } }
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
        guard scope == assignmentScope, connection?.origin == saved.origin, !accessEnded,
              !Task.isCancelled, !savingComposerSettings.contains(chat.id),
              !approvalSettingsBlockSending(chat.id) else { return }
        do {
            var next = composers[chat.id] ?? ComposerIntent()
            try next.begin(device: saved.credential.deviceId, groupRouting: routing)
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
            composerErrors[chat.id] = nil
            if foreground { await refreshConversation(chat) }
        } catch {
            guard partition == key else { return }
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
        loadingConversation = true
        defer { if run == generation { loadingConversation = false } }
        do {
            if projection.groups[chat.id] != nil {
                try await refreshList(saved, run: run)
                if let group = groups[chat.id], var intent = composers[chat.id] {
                    intent.reconcile(group)
                    try saveComposer(intent, chat: chat.id)
                }
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
            guard projection.summaries.contains(where: { $0.id == chat.id }) || isSubagent(chat) else { return }
            var next = projection
            // Snapshot cursor only establishes an epoch at bootstrap. It never
            // skips events in this epoch, including events for other chats.
            guard next.hostEpoch.isEmpty || next.hostEpoch == page.hostEpoch else { throw ReadFailure.resync }
            next.install(page)
            try commit(next)
            if var intent = composers[chat.id], intent.pending != nil || !(intent.recoveredPending ?? []).isEmpty {
                intent.reconcile(page)
                try saveComposer(intent, chat: chat.id)
                if intent.pending == nil { composerErrors[chat.id] = nil }
            }
        } catch {
            if run == generation, case PairingFailure.response(404) = error {
                do { try removeDeletedConversation(chat.id) } catch { readFailed(error, run: run) }
                chatsStatus = "This conversation was removed."
            } else { readFailed(error, run: run) }
        }
    }

    func removeDeletedConversation(_ id: String) throws {
        var next = projection
        next.summaries.removeAll { $0.id == id }
        next.snapshots.removeValue(forKey: id); next.groups.removeValue(forKey: id)
        next.positions.removeValue(forKey: id); next.dirty.remove(id)
        try commit(next)
        try store?.removeIntent(conversation: id)
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
        guard !loadingConversation, let saved = connection,
              let current = projection.snapshots[chat.id],
              let cursor = current.thread.nextCursor else { return nil }
        let run = generation
        loadingConversation = true
        defer { if run == generation { loadingConversation = false } }
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
            try commit(next)
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
        chat.botId != nil || groups[chat.id]?.canAttachFiles == true
    }
    private func attachmentCount(_ chat: String) -> Int {
        composers[chat]?.attachmentCount ?? 0
    }
    func canAttach(_ chat: ChatSummary) -> Bool {
        attachmentsSupported(chat) && !chat.isArchived && !accessEnded && !previewMode
            && connection != nil && (chats.contains(where: { $0.id == chat.id }) || isSubagent(chat))
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

    private static func prepareImageAttachment(_ data: Data) async throws -> StagedFile {
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
                  (chats.contains(where: { $0.id == chat.id }) || isSubagent(chat)),
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
        do { var intent = composers[chat] ?? ComposerIntent(); intent.removeAttachment(id: id); try saveComposer(intent, chat: chat) }
        catch { controlErrors[chat] = "Could not save the attachment change." }
    }
    private func uploadStaged(_ chat: ChatSummary) async throws {
        guard let saved = connection, !accessEnded else { throw PairingFailure.missingIdentity }
        let scope = assignmentScope
        let key = partition
        uploading.insert(chat.id)
        defer { if key == partition { uploading.remove(chat.id) } }
        for file in composers[chat.id]?.stagedFiles ?? [] where file.uploaded == nil {
            let uploaded: ConversationFile = try await api.request("/api/v1/conversations/\(Self.escape(chat.id))/files",
                origin: saved.origin, body: file.uploadBody(), credential: saved.credential)
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
        if previewMode { return previewWorkspaceRoots(chat) }
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
        if previewMode { return previewWorkspaceDirectory(root: root, path: path, showHidden: showHidden, offset: offset) }
        guard let saved = connection, !accessEnded else { throw PairingFailure.missingIdentity }
        var components = Self.workspaceComponents(conversationID: chat.id, operation: "directory")
        components.queryItems = [URLQueryItem(name: "root", value: root.id), URLQueryItem(name: "path", value: path), URLQueryItem(name: "showHidden", value: showHidden ? "true" : "false"), URLQueryItem(name: "offset", value: String(offset))]
        guard let endpoint = components.string else { throw PairingFailure.invalidLink }
        return try await api.request(endpoint, origin: saved.origin, credential: saved.credential)
    }
    func downloadWorkspaceFile(_ chat: ChatSummary, root: WorkspaceRoot, entry: WorkspaceEntry) async throws -> Data {
        if previewMode { return previewWorkspaceData(entry: entry) }
        guard let saved = connection, !accessEnded else { throw PairingFailure.missingIdentity }
        var components = Self.workspaceComponents(conversationID: chat.id, operation: "file")
        components.queryItems = [URLQueryItem(name: "root", value: root.id), URLQueryItem(name: "path", value: entry.path)]
        guard let endpoint = components.string else { throw PairingFailure.invalidLink }
        let data = try await api.downloadWorkspaceBytes(endpoint, connection: saved, byteSize: entry.byteSize.map(Int.init), sha256: nil, mimeType: entry.mimeType)
        guard !accessEnded else { throw CancellationError() }
        return data
    }
    func loadWorkspaceGitStatus(_ chat: ChatSummary, root: WorkspaceRoot) async throws -> WorkspaceGitStatusResponse {
        if previewMode { return previewWorkspaceGitStatus() }
        guard let saved = connection, !accessEnded else { throw PairingFailure.missingIdentity }
        var components = Self.workspaceComponents(conversationID: chat.id, operation: "git/status")
        components.queryItems = [URLQueryItem(name: "root", value: root.id)]
        guard let endpoint = components.string else { throw PairingFailure.invalidLink }
        return try await api.request(endpoint, origin: saved.origin, credential: saved.credential)
    }
    func loadWorkspaceGitDiff(_ chat: ChatSummary, root: WorkspaceRoot, path: String, staged: Bool) async throws -> WorkspaceDiffResponse {
        if previewMode { return WorkspaceDiffResponse(path: path, staged: staged, diff: "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n@@\n-fixture line\n+updated fixture line\n") }
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
            values = rootEntries
        }
        return WorkspaceDirectoryPage(rootId: root.id, path: path, parentPath: path.isEmpty ? nil : "", entries: Array(values.dropFirst(offset).prefix(200)), nextOffset: nil)
    }
    private func previewWorkspaceData(entry: WorkspaceEntry) -> Data {
        if entry.mimeType?.hasPrefix("image/") == true, let data = previewBytes["Saturday.png"] { return data }
        if entry.name == ".gitignore" { return Data(".DS_Store\n".utf8) }
        return Data("Fixture workspace file: \(entry.name)\n".utf8)
    }
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
            request.belongs(to: chat.id, isDirect: chat.botId != nil, threadIDs: threads)
                || descendants.contains { request.belongs(to: $0.id, isDirect: true, threadIDs: [$0.threadId]) }
        }
    }
    var unmappedApprovalRequests: [AttentionRequest] {
        let mapped = Set(chats.flatMap { requests(for: $0).map(\.id) })
        return attention.filter { !$0.isQuestion && !mapped.contains($0.id) }
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
                 responseJSON: String? = nil, structuredDecision: TeachingJSONValue? = nil) async {
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
                    let values = answers.mapValues { ["answers": [$0]] }
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
    func rows(for chat: ChatSummary) -> [ReadRow] {
        if rowCache?.id != chat.id || rowCache?.title != chat.title {
            rowCache = (chat.id, chat.title, groups[chat.id]?.rows ?? snapshots[chat.id]?.rows(author: chat.title) ?? [])
        }
        var rows = rowCache?.rows ?? []
        let pendingMessages = (composers[chat.id]?.recoveredPending ?? []) + [composers[chat.id]?.pending].compactMap { $0 }
        for pending in pendingMessages where !rows.contains(where: { $0.id == "user-" + pending.request.clientMessageId }) {
            rows.append(ReadRow(id: "user-" + pending.request.clientMessageId, author: "You",
                text: pending.request.body, isUser: true, timestamp: pending.createdAt, attachmentIds: pending.request.attachmentIds))
        }
        return rows
    }
    func setChatsModalPresented(_ presented: Bool) {
        chatsReadPresentation.setCovered(presented)
    }
    var searchEpoch: String { projection.hostEpoch }
    private var searchStoreMatchesConnection: Bool {
        guard let connection else { return false }
        return partition == connection.credential.hostInstallationId + ":" + connection.credential.deviceId
    }
    func cachedSearch(query: String) throws -> PersistedSearchPage? {
        guard !accessEnded, searchStoreMatchesConnection, let data = try store?.loadIntent(conversation: "search-cache-v1") else { return nil }
        return try JSONDecoder().decode(PersistedSearchCache.self, from: data).pages[query]
    }
    func saveSearch(_ page: PersistedSearchPage, query: String) throws {
        guard !accessEnded, searchStoreMatchesConnection, let store else { throw ReadFailure.resync }
        var cache = try store.loadIntent(conversation: "search-cache-v1").map { try JSONDecoder().decode(PersistedSearchCache.self, from: $0) } ?? PersistedSearchCache()
        cache.remember(page, query: query)
        try store.saveIntent(JSONEncoder().encode(cache), conversation: "search-cache-v1")
    }
    func fetchSearch(query: String, cursor: String?) async throws -> PersistedSearchPage {
        guard !accessEnded, searchStoreMatchesConnection, let saved = connection, !query.isEmpty, query.utf8.count <= 256 else { throw ReadFailure.resync }
        let scope = assignmentScope
        var components = URLComponents(); components.path = "/api/v1/search"
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "30")]
        if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        let page: PersistedSearchPage = try await api.request(components.string!, origin: saved.origin, credential: saved.credential)
        guard assignmentScope == scope, !accessEnded, !Task.isCancelled else { throw CancellationError() }
        return page
    }
    func openSearchMessage(_ result: PersistedSearchResult) async throws {
        guard !accessEnded, searchStoreMatchesConnection, let conversation = result.conversationId,
            let chat = chats.first(where: { $0.id == conversation && !$0.isArchived }) else { throw SearchOpenFailure.unavailable }
        let scope = assignmentScope
        if macConnected == true {
            await refreshConversation(chat)
            guard scope == assignmentScope, !Task.isCancelled, !accessEnded else { throw CancellationError() }
            if chat.botId != nil { try await loadQueue(chat) }
        }
        for pageNumber in 0...5 {
            guard scope == assignmentScope, foreground, !accessEnded, !Task.isCancelled,
                chats.contains(where: { $0.id == conversation }) else { throw CancellationError() }
            if let row = result.rowID(snapshot: snapshots[conversation], group: groups[conversation]) {
                guard let entry = ChatFeedEntry.grouping(feedRows(for: chat), focusedRowID: row).first(where: { $0.rows.contains(where: { $0.id == row }) }) else { throw SearchOpenFailure.queued }
                savePosition(entry.id, chat: conversation)
                searchFocus = SearchMessageFocus(conversationID: conversation, rowID: row, scrollID: entry.id)
                selectedChat = chat
                return
            }
            guard chat.botId != nil else { throw SearchOpenFailure.unavailable }
            if pageNumber == 5 { throw SearchOpenFailure.moreHistory }
            guard let saved = connection else { throw ReadFailure.resync }
            let current = snapshots[conversation]
            var path = "/api/v1/conversations/" + Self.escape(conversation)
            if let current {
                guard let cursor = current.thread.nextCursor else { throw SearchOpenFailure.unavailable }
                path += "/history?before=" + Self.escape(cursor)
            }
            let older: ConversationSnapshot = try await api.request(path, origin: saved.origin, credential: saved.credential)
            guard scope == assignmentScope, foreground, !accessEnded, !Task.isCancelled else { throw CancellationError() }
            guard older.conversationId == conversation, projection.hostEpoch.isEmpty || projection.hostEpoch == older.hostEpoch else { throw ReadFailure.resync }
            guard snapshots[conversation]?.lastSequence == current?.lastSequence else { continue }
            var next = projection
            if let latest = next.snapshots[conversation] { next.snapshots[conversation] = try latest.mergingOlder(older) }
            else { next.install(older) }
            try commit(next)
        }
    }
    func readReceipt(for conversation: String) -> VisibleReadReceipt? {
        if let group = groups[conversation] { return VisibleReadReceipt(group: group) }
        return snapshots[conversation].map(VisibleReadReceipt.init(snapshot:))
    }
    func acknowledgeVisibleRead(_ visible: VisibleReadReceipt) async {
        guard !previewMode, foreground, !accessEnded, macConnected == true, !chatsReadPresentation.isCovered,
            visibleChat?.id == visible.conversationId,
            let saved = connection, readReceipt(for: visible.conversationId) == visible,
            !projection.dirty.contains(visible.conversationId) else { return }
        let run = generation
        let cursor = projection.lastSequence
        let summaryVersion = summaryRevision
        let presentationRevision = chatsReadPresentation.revision
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
            guard !Task.isCancelled, foreground, run == generation, summaryRevision == summaryVersion,
                chatsReadPresentation.acceptsReply(startedAt: presentationRevision),
                visibleChat?.id == visible.conversationId,
                connection?.credential.hostInstallationId == saved.credential.hostInstallationId,
                connection?.credential.deviceId == saved.credential.deviceId, !accessEnded else { return }
            var next = projection
            let applied: Bool
            if let groupReply { applied = next.applyGroupReadAcknowledgement(groupReply, visible: visible, startedAtSequence: cursor) }
            else if let botReply { applied = next.applyReadAcknowledgement(botReply, visible: visible, startedAtSequence: cursor) }
            else { applied = false }
            if applied { summaryRevision &+= 1; try commit(next) }
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
                        let event = try JSONDecoder().decode(ReplayEvent.self, from: data)
                        guard run == self.generation else { return }
                        var next = self.projection
                        do { try next.consume(event) }
                        catch { try await self.resnapshot(saved, run: run); break }
                        try self.commit(next)
                        struct Ack: Encodable { let type = "ack"; let hostEpoch: String; let sequence: UInt64 }
                        let ack = try JSONEncoder().encode(Ack(hostEpoch: next.hostEpoch, sequence: next.lastSequence))
                        try await socket.send(.string(String(decoding: ack, as: UTF8.self)))
                        self.scheduleRefresh(run: run)
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
        next.dirty.formUnion(next.snapshots.keys)
        next.dirty.formUnion(next.groups.keys)
        next.listDirty = true
        // Commit invalidations and head together; all stale scopes stay marked
        // until a successful authoritative read replaces them.
        try commit(next)
        try await refreshList(saved, run: run)
        if let chat = visibleChat {
            await refreshConversation(chat)
            await loadAsyncQuestions(chat)
            if chat.botId != nil { try? await loadQueue(chat) }
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
                if let chat = self.visibleChat { await self.refreshConversation(chat) }
                if let parent = self.selectedChat, parent.botId != nil { await self.loadSubagents(parent) }
                await self.loadAttention()
                if let chat = self.visibleChat, chat.botId != nil { try? await self.loadQueue(chat) }
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
            if store == nil { prepare(saved) }
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
        prepare(saved)
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
            status = "Could not connect to your computer."
            self.error = error is SigningIdentityFailure ? error.localizedDescription : nil
        }
    }
    private func saveConnection(_ saved: SavedConnection) throws {
        if let persistConnection { try persistConnection(saved) }
        else { try identity.save(JSONEncoder().encode(saved), account: "connection") }
    }

    func forget() {
        guard !busy else { error = "Wait for the connection check to finish, then try again."; return }
        do {
            dictation.forget()
            stopReading()
            if let saved = connection { prepare(saved) }
            try store?.remove()
            if let saved = connection { ManagementDraftStore(host: saved.credential.hostInstallationId).removeAll() }
            if let persistConnection { try persistConnection(nil) }
            else { try identity.forgetConnection() }
            partition = nil; store = nil; projection = ProjectionState(); publish()
            subagents = [:]; subagentAvailability = [:]; subagentErrors = [:]; composers = [:]; composerErrors = [:]; sending = []; preparingSends = []; intentLoadFailures = []; attention = []; asyncQuestions = [:]; retryableAsyncReplies = []; savedAsyncReplies = [:]; attentionErrors = [:]; resolving = []; savedDecisions = [:]; files = [:]; queues = [:]; uploading = []; stopping = []; controlErrors = [:]
            selectedChat = nil; managedBots = []; managedBotMutations = ManagedBotListMutationState(); macConnected = nil; hasConnectedThisLaunch = false; connection = nil; error = nil; accessEnded = false
            status = "Connect to your computer to get started."
        }
        catch { self.error = error.localizedDescription }
    }
}
