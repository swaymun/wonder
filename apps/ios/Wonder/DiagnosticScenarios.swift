#if WONDER_DIAGNOSTICS
import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WonderPairing

enum DiagnosticScenarioLaunch {
    static var requested: Bool {
        ProcessInfo.processInfo.arguments.contains("-diagnostics-scenario")
            || ProcessInfo.processInfo.environment["WONDER_DIAGNOSTICS_SCENARIO"] == "1"
    }

    static var soak: Bool {
        ProcessInfo.processInfo.arguments.contains("-diagnostics-soak")
            || ProcessInfo.processInfo.environment["WONDER_DIAGNOSTICS_SOAK"] == "1"
    }
}

@MainActor final class DiagnosticScenarioControl: NSObject, ObservableObject {
    enum Action { case expand, detail, top, bottom }
    struct Command { let id = UUID(); let chatID: String; let action: Action }
    static let shared = DiagnosticScenarioControl()
    @Published var command: Command?
    private var completed: UUID?
    private var succeeded = false
    private var link: CADisplayLink?
    private var ticks = 0
    private var started = 0.0
    private var continuation: CheckedContinuation<Double, Error>?
    func acknowledge(_ id: UUID, performed: Bool) { completed=id; succeeded=performed }
    @discardableResult func perform(_ action: Action, chat: String) async throws -> Double {
        try Task.checkCancellation()
        let elapsed = try await withCheckedThrowingContinuation { continuation in
            self.continuation=continuation; ticks=0; started=ProcessInfo.processInfo.systemUptime
            let value=CADisplayLink(target:self,selector:#selector(frame)); value.add(to:.main,forMode:.common); link=value
            command=Command(chatID:chat,action:action)
        }
        // Settling time is deliberately outside the measured two-callback proxy.
        try await Task.sleep(for: .milliseconds(350))
        return elapsed
    }
    @objc private func frame() {
        let elapsed=(ProcessInfo.processInfo.systemUptime-started)*1000
        if completed == command?.id {
            ticks += 1
            if !succeeded { finish(.failure(ScenarioFailure.unavailable)) }
            else if ticks >= 2 { finish(.success(elapsed)) }
        } else if elapsed > 5000 { finish(.failure(ScenarioFailure.unavailable)) }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<Double, Error>) {
        link?.invalidate(); link=nil; command=nil
        continuation?.resume(with:result); continuation=nil
    }
    enum ScenarioFailure: Error { case unavailable }
}

struct DiagnosticScenariosView: View {
    @ObservedObject var model: ConnectionModel
    @State private var selected: ChatSummary?
    @State private var showingChat = false
    @State private var target = ""
    @State private var status = "Uses live chats. No messages are sent."
    @State private var run: Task<Void, Never>?
    @State private var busy = false
    @State private var autoStarted = false
    @Environment(\.scenePhase) private var phase
    private var cleanupKey: String { "diagnostics.bot." + (model.connection?.credential.hostInstallationId ?? "none") }
    var body: some View {
        List {
            Picker("Conversation", selection: $target) { ForEach(model.chats) { chat in Text(chat.title).tag(chat.id) } }
            Text(status).accessibilityIdentifier("scenario-status")
            Button("Run 30 expansion cycles") { start(seconds: 0) }.disabled(busy || target.isEmpty).accessibilityIdentifier("scenario-cycles")
            Button("Run ten-minute live session") { start(seconds: 600) }.disabled(busy || target.isEmpty).accessibilityIdentifier("scenario-soak")
            Button("Compare recording overhead") { start(seconds:0,comparison:true) }.disabled(busy || target.isEmpty).accessibilityIdentifier("scenario-compare")
            if busy { Button("Stop test") { run?.cancel(); DiagnosticScenarioControl.shared.cancel() } }
            Button("Clean up test Bot") { Task { do { try await cleanup(); status="Test Bot archived" } catch { status="Cleanup could not finish. Reconnect and retry." } } }.disabled(busy)
            Text("These tests use the same conversation views and actions. They verify layout execution, not touch recognition or measured scroll hitches.").font(.caption).foregroundStyle(.secondary)
        }.navigationTitle("Live tests")
            .navigationDestination(isPresented: $showingChat) {
                if let selected { ConversationView(model: model, chat: selected).id(selected.id) }
            }
            .task {
                await model.check(renew:true)
                model.setForeground(true)
                await model.loadChats(force: true)
                target=model.chats.first(where: { $0.title.contains("Wonder") })?.id ?? model.chats.first?.id ?? ""
                let args=ProcessInfo.processInfo.arguments
                if DiagnosticScenarioLaunch.requested, !autoStarted { autoStarted=true; start(seconds: DiagnosticScenarioLaunch.soak ? 600 : 0,comparison:args.contains("-diagnostics-compare")) }
            }
            .onChange(of:phase) { _, next in
                if next != .active { run?.cancel(); DiagnosticScenarioControl.shared.cancel() }
            }
    }
    private func start(seconds: Double, comparison: Bool = false) {
        guard !busy else { return }; busy=true
        run=Task {
            let previousRecording=Diagnostics.shared.recording
            Diagnostics.shared.recording=true
            defer { Diagnostics.shared.stopCapture(); Diagnostics.shared.recording=previousRecording; busy=false; showingChat=false; run=nil }
            do {
                guard let chat=model.chats.first(where: { $0.id == target }), let saved=model.connection else { throw DiagnosticScenarioControl.ScenarioFailure.unavailable }
                Diagnostics.shared.selectHost(saved)
                DiagnosticJournal.shared.record(DiagnosticEvent(operation:"scenario",phase:"start"))
                if !comparison { Diagnostics.shared.startCapture() }
                selected=chat; showingChat=true
                try await Task.sleep(for:.seconds(2))
                if comparison {
                    try await compare(chat:chat)
                    return
                }
                let start=ProcessInfo.processInfo.systemUptime
                var cycles=0
                repeat {
                    try Task.checkCancellation()
                    try await DiagnosticScenarioControl.shared.perform(.expand,chat:chat.id)
                    try await DiagnosticScenarioControl.shared.perform(.detail,chat:chat.id)
                    try await DiagnosticScenarioControl.shared.perform(.detail,chat:chat.id)
                    try await DiagnosticScenarioControl.shared.perform(.expand,chat:chat.id)
                    try await DiagnosticScenarioControl.shared.perform(.top,chat:chat.id)
                    try await DiagnosticScenarioControl.shared.perform(.bottom,chat:chat.id)
                    cycles += 1
                    if cycles.isMultiple(of: 5) { DiagnosticJournal.shared.record(Diagnostics.memorySample(count:UInt64(model.feedRows(for:chat).count))) }
                } while cycles < 30 || ProcessInfo.processInfo.systemUptime-start < seconds
                try await lifecycle()
                status="Completed \(cycles) live cycles and test Bot creation/open/archive. Touch and hitch verification are separate."
                DiagnosticJournal.shared.record(DiagnosticEvent(operation:"scenario",phase:"end",durationMs:(ProcessInfo.processInfo.systemUptime-start)*1000,count:UInt64(cycles)))
            } catch {
                status="Test interrupted or unavailable. Saved measurements remain available; retry cleanup if needed."
                let code: Double
                if case PairingFailure.response(let status)=error { code=Double(status) } else { code=0 }
                DiagnosticJournal.shared.record(DiagnosticEvent(operation:"scenario",phase:error is CancellationError ? "interrupted" : "failed",metrics:["httpStatus":code]))
            }
        }
    }
    private func compare(chat: ChatSummary) async throws {
        // Interleave modes on the same live view to reduce thermal/order bias.
        // The external display fence stays enabled in both modes and is a proxy.
        var samples: [DiagnosticEvent]=[]
        for cycle in 0..<35 {
            for enabled in cycle.isMultiple(of:2) ? [false,true] : [true,false] {
                Diagnostics.shared.recording=enabled
                try await Task.sleep(for:.milliseconds(100))
                for action in [DiagnosticScenarioControl.Action.expand,.detail,.detail,.expand] {
                    let elapsed=try await DiagnosticScenarioControl.shared.perform(action,chat:chat.id)
                    if cycle >= 5 { samples.append(DiagnosticEvent(operation:"scenario",phase:"sample",durationMs:elapsed,metrics:["recording":enabled ? 1 : 0,"detail":action == .detail ? 1 : 0])) }
                }
            }
        }
        Diagnostics.shared.recording=true
        for sample in samples { DiagnosticJournal.shared.record(sample) }
        DiagnosticJournal.shared.record(DiagnosticEvent(operation:"scenario",phase:"end",count:UInt64(samples.count)))
        status="Recording comparison saved: 120 interactions per mode after warmup. Review p95 in the report; timings are display-callback proxies."
    }
    private func lifecycle() async throws {
        try await cleanup()
        var draft=["request":UUID().uuidString]
        UserDefaults.standard.set(draft,forKey:cleanupKey)
        // /bots/new starts a model-backed onboarding turn. The existing explicit
        // creation path exercises persistence/navigation without submitting work.
        let bot: ManagedBot = try await model.manage("/api/v1/bots",method:"POST",values:["clientRequestId":draft["request"]!,"name":"Diagnostics test Bot","role":"UI lifecycle testing","systemPrompt":"Dedicated UI test Bot. No messages are submitted.","permissionMode":"read-only"])
        draft["bot"]=bot.id; draft["chat"]=bot.conversationId; UserDefaults.standard.set(draft,forKey:cleanupKey)
        await model.loadChats(force:true)
        guard let chat=model.chats.first(where: { $0.id == bot.conversationId }) else { throw DiagnosticScenarioControl.ScenarioFailure.unavailable }
        selected=chat; try await Task.sleep(for:.seconds(1))
        try await cleanup()
    }
    private func cleanup() async throws {
        guard let draft=UserDefaults.standard.dictionary(forKey:cleanupKey) as? [String:String] else { return }
        // Creation uses the client UUID as the Bot identity. Recover a lost
        // response by reading that identity; cleanup must never create a Bot.
        var id=draft["bot"]; var chat=draft["chat"]
        if id == nil, let request=draft["request"] {
            do {
                let bot: ManagedBot = try await model.manage("/api/v1/bots/\(ConnectionModel.escape(request))",method:"GET")
                id=bot.id; chat=bot.conversationId
            } catch PairingFailure.response(404) {
                // A creation that never reached this Mac leaves nothing to
                // archive. Do not let its saved request block every later run.
                UserDefaults.standard.removeObject(forKey:cleanupKey)
                return
            }
        }
        guard let id else { return }
        struct Empty: Decodable, Sendable {}
        let _: ManagedBot = try await model.manage("/api/v1/bots/\(ConnectionModel.escape(id))/archive",method:"POST",values:[:])
        if let chat {
            let _: Empty = try await model.manage("/api/v1/conversations/\(ConnectionModel.escape(chat))",method:"PATCH",body:Data(#"{"isArchived":true}"#.utf8))
        }
        UserDefaults.standard.removeObject(forKey:cleanupKey)
        await model.loadChats(force:true)
    }
}
struct DiagnosticLaunchView: View {
    @ObservedObject var library: ConnectionLibrary
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            if let saved=library.saved.connections.first {
                DiagnosticScenariosView(model: library.model(for:saved))
                    .task {
                        let model=library.model(for:saved)
                        await model.check(renew:true); model.setForeground(true)
                        Diagnostics.shared.configure(library.saved.connections)
                    }
            } else { Text("Pair this app with your Mac before starting a live scenario.") }
        }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("diagnostics-scenario-root")
            .task { library.load() }
            .onChange(of:phase,initial:true) { _, next in
                Diagnostics.shared.setActive(next == .active)
                if next != .active { library.suspendAll() }
                else if let saved=library.saved.connections.first { library.model(for:saved).setForeground(true) }
            }
            .onChange(of:library.saved.connections.map { $0.credential.sessionToken },initial:true) { _, _ in Diagnostics.shared.configure(library.saved.connections) }
    }
}

/// A Diagnostics-only App Server-shaped parent/child route. This uses the
/// production ChatsView/ConversationView and durable ReadStore with a
/// synthetic URLProtocol transport, so later image/workspace fixtures can add
/// responses without introducing successful-send branches into Release.
enum DiagnosticSubagentFixture {
    // Synthetic release artwork uses the real native views and transport fixture.
    // This entire file is excluded from Release; no personal history is loaded.
    static var marketingFixture: Bool { ProcessInfo.processInfo.arguments.contains("-diagnostics-marketing") }
    static var botName: String { marketingFixture ? "Weekend plans" : "Fixture Bot" }
    static var approvalSettingsFixture: Bool { ProcessInfo.processInfo.arguments.contains("-diagnostics-optimistic-approval") }
    static var approvalDefaults: UserDefaults { UserDefaults(suiteName: "wonder.diagnostics.approval-settings")! }
    static var chatLayoutFixture: Bool { ProcessInfo.processInfo.arguments.contains("-diagnostics-chat-layout") }
    static var readStatusFixture: Bool { ProcessInfo.processInfo.arguments.contains("-diagnostics-read-status") }
    static var avatarSettingsFixture: Bool { ProcessInfo.processInfo.arguments.contains("-diagnostics-avatar-settings") }
    static var hostID: String { avatarSettingsFixture ? "diagnostic-avatar-settings-host" : "diagnostic-host" }
    static var avatarDefaults: UserDefaults { UserDefaults(suiteName: "wonder.diagnostics.avatar-settings")! }
    static let parentID = "fixture-parent-conversation"
    static let childID = "fixture-child-conversation"
    static let parentThreadID = "fixture-parent-thread"
    static let childThreadID = "fixture-child-thread"
    static let unavailableChildID = "fixture-unavailable-child-conversation"
    static let unavailableChildThreadID = "fixture-unavailable-child-thread"
    static let ordinaryTaskThreadID = "fixture-created-task-thread"

    static func savedConnection() -> SavedConnection {
        let credential = try! JSONDecoder().decode(Credential.self, from: Data("""
        {"sessionToken":"diagnostic-session","deviceId":"diagnostic-device","csrfToken":"diagnostic-csrf","hostInstallationId":"\(hostID)","expiresAtMs":null}
        """.utf8))
        return SavedConnection(
            origin: "https://synthetic.invalid",
            credential: credential,
            hostName: "Synthetic fixture")
    }

    static func parentChat() -> ChatSummary {
        try! JSONDecoder().decode(ChatSummary.self, from: Data(#"{"conversationId":"fixture-parent-conversation","botId":"fixture-bot","title":"Fixture Bot","lastMessagePreview":"A verified subagent is working.","lastMessageAt":"1700000000000","messageCount":1,"deliveryState":"completed","hasUnread":false,"isArchived":false,"isPinned":false}"#.utf8))
    }

    @MainActor static func model() -> ConnectionModel {
        if approvalSettingsFixture && ProcessInfo.processInfo.arguments.contains("-diagnostics-approval-reset") {
            approvalDefaults.removePersistentDomain(forName: "wonder.diagnostics.approval-settings")
        }
        if avatarSettingsFixture && ProcessInfo.processInfo.arguments.contains("-diagnostics-avatar-settings-reset") {
            avatarDefaults.removePersistentDomain(forName: "wonder.diagnostics.avatar-settings")
            // An unrelated edit saved before this Bot changed on another device.
            var staleDraft = ManagementDraft()
            staleDraft.values = ["name": "Fixture Bot", "role": "Diagnostics", "systemPrompt": "Fixture", "avatarShape": "sun", "avatarPalette": "amber"]
            try! ManagementDraftStore(host: hostID).save(staleDraft, key: "bot.fixture-bot")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticSubagentURLProtocol.self]
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wonder-subagent-fixture-\(UUID().uuidString)", isDirectory: true)
        let model = ConnectionModel(
            cameraFixtureStoreRoot: root,
            saved: savedConnection(),
            chat: nil,
            api: PairingAPI(configuration: configuration), replayEnabled: !readStatusFixture && !avatarSettingsFixture && !chatLayoutFixture && !approvalSettingsFixture)
        if chatLayoutFixture {
            model.snapshots[parentID] = try! JSONDecoder().decode(ConversationSnapshot.self, from: JSONSerialization.data(withJSONObject: chatLayoutSnapshot()))
            let entries = ChatFeedEntry.grouping(model.feedRows(for: parentChat()))
            if !ProcessInfo.processInfo.arguments.contains("-diagnostics-chat-layout-unsaved") {
                let anchor = ProcessInfo.processInfo.arguments.contains("-diagnostics-chat-layout-older")
                    ? entries.first { $0.rows.contains { $0.text.hasPrefix("Reply 6.") } }?.id
                    : entries.suffix(2).first?.id
                precondition(anchor != nil, "The synthetic reading anchor must exist")
                model.savePosition(anchor, chat: parentID)
            }
        }
        return model
    }
    static func chatLayoutSnapshot() -> [String: Any] {
        let text = "The update is ready.\n\n- The action, filename, and counts stay together.\n- The extra metadata has been removed.\n- A completed change uses the same compact spacing.\n\nThe new build includes these changes.\n\nThe layout should already be in place when this conversation opens."
        let turns: [[String: Any]] = (1...12).map { index -> [String: Any] in
            let work: [String: Any] = ["id": "layout-work-\(index)", "type": "commandExecution", "state": "completed", "createdAt": String(index * 1000 + 100), "payload": ["command": "fixture check", "exitCode": 0]]
            let reply: [String: Any] = ["id": "layout-reply-\(index)", "type": "agentMessage", "state": "completed", "createdAt": String(index * 1000 + 900), "text": "Reply \(index). " + text]
            return ["id": "layout-turn-\(index)", "status": "completed", "createdAt": String(index * 1000), "updatedAt": String(index * 1000 + 900), "items": [work, reply]]
        }
        let messages: [[String: Any]] = (1...12).map { index -> [String: Any] in [
            "messageId": "layout-question-\(index)", "body": "Question \(index): Please check the compact layout and keep the same content spacing.",
            "state": "completed", "codexTurnId": "layout-turn-\(index)", "codexThreadId": parentThreadID,
            "createdAt": String(index * 1000), "attachmentIds": []
        ] }
        return ["conversationId": parentID, "hostEpoch": "fixture", "lastSequence": 1,
                "messages": messages, "assistantMessages": [],
                "thread": ["threadId": parentThreadID, "hydrated": true, "turns": turns]]
    }
    static func resetTransport() {
        let state = DiagnosticSubagentURLProtocol.state
        state.lock.withLock {
            state.requests.removeAll()
            state.delayNextChildSend = false
            state.childRevision = 2
            state.childStatus = "completed"
        }
    }
    static func updateChild(status: String) {
        let state = DiagnosticSubagentURLProtocol.state
        state.lock.withLock { state.childRevision += 1; state.childStatus = status }
    }
    static func recordedPaths() -> [String] {
        let state = DiagnosticSubagentURLProtocol.state
        return state.lock.withLock { state.requests.map { $0.path } }
    }
    static func recordedMessagePaths() -> [String] {
        let state = DiagnosticSubagentURLProtocol.state
        return state.lock.withLock {
            state.requests.filter { $0.method == "POST" && $0.path.hasSuffix("/messages") }.map { $0.path }
        }
    }
    static func delayNextChildSend() {
        let state = DiagnosticSubagentURLProtocol.state
        state.lock.withLock { state.delayNextChildSend = true }
    }
}

private final class DiagnosticSubagentURLProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests: [(method: String, path: String, body: Data?)] = []
        var delayNextChildSend = false
        var childRevision = 2
        var childStatus = "completed"
        var unread = true
        var readAttempts = 0
    }
    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "synthetic.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { finish(status: 400, body: Data("{}".utf8)); return }
        let method = request.httpMethod ?? "GET"
        let path = url.path
        let body: Data?
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { body = nil }
        let state = Self.state
        state.lock.withLock { state.requests.append((method, path, body)) }
        let delayed: Bool = state.lock.withLock {
            guard method == "POST" && path == "/api/v1/conversations/\(DiagnosticSubagentFixture.childID)/messages" else { return false }
            let value = state.delayNextChildSend
            state.delayNextChildSend = false
            return value
        }
        let work = DispatchWorkItem { [weak self] in self?.respond(method: method, path: path, body: body) }
        let delayedApproval = DiagnosticSubagentFixture.approvalSettingsFixture && method == "PATCH" && path == "/api/v1/bots/fixture-bot"
        if delayed || delayedApproval { DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250), execute: work) }
        else { work.perform() }
    }

    override func stopLoading() {}

    private func respond(method: String, path: String, body: Data?) {
        if DiagnosticSubagentFixture.approvalSettingsFixture, method == "PATCH", path == "/api/v1/bots/fixture-bot" {
            guard let values = try? JSONDecoder().decode([String: String].self, from: body ?? Data()),
                  values.count == 1, let raw = values["approvalMode"], BotApprovalMode(rawValue: raw) != nil else {
                finish(status: 400, body: Data("{}".utf8)); return
            }
            DiagnosticSubagentFixture.approvalDefaults.set(raw, forKey: "mode")
            finish(status: 200, body: json(bot())); return
        }
        if DiagnosticSubagentFixture.avatarSettingsFixture, method == "PATCH", path == "/api/v1/bots/fixture-bot" {
            guard let values = try? JSONDecoder().decode([String: String].self, from: body ?? Data()),
                  values["avatarColor"] == nil, values["model"] == nil, values["approvalMode"] == nil else {
                finish(status: 400, body: Data("{}".utf8)); return
            }
            let defaults = DiagnosticSubagentFixture.avatarDefaults
            var requests = defaults.array(forKey: "patches") as? [[String: String]] ?? []
            requests.append(values)
            defaults.set(requests, forKey: "patches")
            if !defaults.bool(forKey: "failedOnce") {
                defaults.set(true, forKey: "failedOnce")
                finish(status: 409, body: Data("{}".utf8)); return
            }
            var appearance = defaults.dictionary(forKey: "appearance") as? [String: String] ?? [:]
            for key in ["avatarShape", "avatarPalette"] {
                if let value = values[key] { appearance[key] = value }
            }
            defaults.set(appearance, forKey: "appearance")
            finish(status: 200, body: json(bot())); return
        }
        if DiagnosticSubagentFixture.readStatusFixture, method == "PATCH", path == "/api/v1/conversations/\(DiagnosticSubagentFixture.parentID)" {
            let attempts = Self.state.lock.withLock {
                Self.state.readAttempts += 1
                if Self.state.readAttempts > 1 { Self.state.unread = false }
                return Self.state.readAttempts
            }
            // First read deliberately fails to exercise bounded retry while
            // the reader remains stationary. The second persists on this host.
            finish(status: attempts == 1 ? 503 : 200, body: attempts == 1 ? Data("{}".utf8) : json(parentSummary()))
            return
        }
        if method == "POST" && path == "/api/v1/conversations/\(DiagnosticSubagentFixture.childID)/messages" {
            let request = (try? JSONDecoder().decode(SendRequest.self, from: body ?? Data()))
            let messageBody = request?.body ?? ""
            let hash = SHA256.hash(data: Data(messageBody.utf8)).map { String(format: "%02x", $0) }.joined()
            finish(status: 202, body: json([
                "clientMessageId": request?.clientMessageId ?? "fixture-client-message",
                "wonderMessageId": "fixture-child-message",
                "bodySha256": hash,
                "conversationId": DiagnosticSubagentFixture.childID,
                "deliveryState": "accepted_by_wonder"
            ]))
            return
        }
        switch path {
        case "/api/v1/bots/fixture-bot/file-access/requests" where DiagnosticSubagentFixture.chatLayoutFixture || DiagnosticSubagentFixture.marketingFixture:
            finish(status: 200, body: Data("[]".utf8))
        case "/api/v1/devices": finish(status: 200, body: json([["id": "diagnostic-device", "revokedAt": NSNull()]]))
        case "/api/v1/host/status": finish(status: 200, body: json(["hostInstallationId": DiagnosticSubagentFixture.hostID, "hostName": "Synthetic fixture"]))
        case "/api/v1/conversations/\(DiagnosticSubagentFixture.parentID)/composer-options" where DiagnosticSubagentFixture.approvalSettingsFixture:
            finish(status: 200, body: json(["models": [], "allowedApprovalPolicies": [], "approvalModes": BotApprovalMode.allCases.map { ["id": $0.rawValue, "allowed": true] as [String: Any] }]))
        case "/api/v1/bots/fixture-bot" where DiagnosticSubagentFixture.approvalSettingsFixture:
            finish(status: 200, body: json(bot()))
        case "/api/v1/conversations/\(DiagnosticSubagentFixture.parentID)/composer-options" where DiagnosticSubagentFixture.avatarSettingsFixture:
            finish(status: 200, body: json(["models": [], "allowedApprovalPolicies": [], "approvalModes": [["id": "ask-for-approval", "allowed": true]]]))
        case "/api/v1/conversations":
            var summaries = [parentSummary()]
            if DiagnosticSubagentFixture.readStatusFixture {
                for (id, title, state, unread) in [("fixture-working", "Working Bot", "streaming", true), ("fixture-read", "Read Bot", "completed", false)] {
                    var summary = parentSummary()
                    summary["conversationId"] = id; summary["title"] = title
                    summary["deliveryState"] = state; summary["hasUnread"] = unread
                    summaries.append(summary)
                }
            }
            finish(status: 200, body: json(summaries))
        case "/api/v1/group-chats": finish(status: 200, body: Data("[]".utf8))
        case "/api/v1/bots": finish(status: 200, body: json([bot()]))
        case "/api/v1/approvals": finish(status: 200, body: Data("[]".utf8))
        case "/api/v1/conversations/\(DiagnosticSubagentFixture.parentID)/queue",
             "/api/v1/conversations/\(DiagnosticSubagentFixture.childID)/queue",
             "/api/v1/conversations/\(DiagnosticSubagentFixture.parentID)/questions",
             "/api/v1/conversations/\(DiagnosticSubagentFixture.childID)/questions": finish(status: 200, body: Data("[]".utf8))
        case "/api/v1/conversations/\(DiagnosticSubagentFixture.parentID)/subagents": finish(status: 200, body: json([
            "available": true,
            "detail": NSNull(),
            "subagents": [childSummary(), unavailableChildSummary()]
        ]))
        case "/api/v1/conversations/\(DiagnosticSubagentFixture.childID)/subagents": finish(status: 200, body: json([
            "available": true,
            "detail": NSNull(),
            "subagents": []
        ]))
        case "/api/v1/conversations/\(DiagnosticSubagentFixture.parentID)": finish(status: 200, body: json(DiagnosticSubagentFixture.chatLayoutFixture ? DiagnosticSubagentFixture.chatLayoutSnapshot() : parentSnapshot()))
        case "/api/v1/conversations/\(DiagnosticSubagentFixture.childID)": finish(status: 200, body: json(childSnapshot()))
        default: finish(status: 404, body: Data("{}".utf8))
        }
    }

    private func finish(status: Int, body: Data) {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
    private func parentSummary() -> [String: Any] { [
        "conversationId": DiagnosticSubagentFixture.parentID, "botId": "fixture-bot", "title": DiagnosticSubagentFixture.botName,
        "lastMessagePreview": "A verified subagent is working.", "lastMessageAt": "1700000000000", "messageCount": 1,
        "deliveryState": "completed", "hasUnread": DiagnosticSubagentFixture.readStatusFixture && Self.state.lock.withLock { Self.state.unread }, "isArchived": false, "isPinned": false
    ] }
    private func bot() -> [String: Any] {
        let appearance = DiagnosticSubagentFixture.avatarSettingsFixture
            ? DiagnosticSubagentFixture.avatarDefaults.dictionary(forKey: "appearance") as? [String: String] ?? [:] : [:]
        return [
        "id": "fixture-bot", "name": DiagnosticSubagentFixture.botName, "role": "Diagnostics", "systemPrompt": "Fixture",
        "workspacePath": "/tmp/fixture", "permissionProfile": ":read-only", "permissionMode": "read-only",
        "approvalMode": DiagnosticSubagentFixture.approvalSettingsFixture ? DiagnosticSubagentFixture.approvalDefaults.string(forKey: "mode") ?? "ask-for-approval" : "ask-for-approval", "model": DiagnosticSubagentFixture.marketingFixture ? "gpt-5.6-luna" : "fixture-model", "reasoningEffort": "medium",
        "serviceTier": "priority", "isArchived": false, "conversationId": DiagnosticSubagentFixture.parentID,
        "avatarShape": appearance["avatarShape"] ?? "luna", "avatarPalette": appearance["avatarPalette"] ?? "ocean"
    ] }
    private func childSummary() -> [String: Any] { [
        "conversationId": DiagnosticSubagentFixture.childID, "threadId": DiagnosticSubagentFixture.childThreadID,
        "parentConversationId": DiagnosticSubagentFixture.parentID, "parentThreadId": DiagnosticSubagentFixture.parentThreadID,
        "title": "Scout", "agentNickname": "Scout", "agentRole": "research", "agentPath": "worker",
        "status": "idle", "canAcceptDirectInput": true, "isArchived": false
    ] }
    private func unavailableChildSummary() -> [String: Any] { [
        "conversationId": DiagnosticSubagentFixture.unavailableChildID, "threadId": DiagnosticSubagentFixture.unavailableChildThreadID,
        "parentConversationId": DiagnosticSubagentFixture.parentID, "parentThreadId": DiagnosticSubagentFixture.parentThreadID,
        "title": "Sleeping Scout", "agentNickname": "Sleeping Scout", "agentRole": "research", "agentPath": "worker",
        "status": "notFound", "canAcceptDirectInput": false, "isArchived": true
    ] }
    private func parentSnapshot() -> [String: Any] { [
        "conversationId": DiagnosticSubagentFixture.parentID, "hostEpoch": "fixture", "lastSequence": 1,
        "messages": [["messageId": "fixture-parent-message", "body": DiagnosticSubagentFixture.marketingFixture ? "Help me plan a relaxed Saturday. Ask Scout for a rainy-day option too." : "Start the verified Scout.", "state": "completed", "codexTurnId": "fixture-parent-turn", "codexThreadId": DiagnosticSubagentFixture.parentThreadID, "createdAt": "1000", "attachmentIds": []]],
        "assistantMessages": [], "thread": ["threadId": DiagnosticSubagentFixture.parentThreadID, "hydrated": true, "turns": [[
            "id": "fixture-parent-turn", "status": "completed", "createdAt": "1000", "updatedAt": "3000",
            "items": [["id": "fixture-subagent-activity", "type": "subAgentActivity", "state": "completed", "createdAt": "2000", "payload": [
                "agentThreadId": DiagnosticSubagentFixture.childThreadID, "agentNickname": "Scout", "agentRole": "research", "kind": "completed", "status": "completed"
            ]], ["id": "fixture-created-task", "type": "dynamicToolCall", "state": "completed", "createdAt": "2500", "payload": ["threadId": DiagnosticSubagentFixture.ordinaryTaskThreadID]], ["id": "fixture-parent-reply", "type": "agentMessage", "state": "completed", "createdAt": "3000", "text": DiagnosticSubagentFixture.marketingFixture ? "A little structure, plenty of room.\n\n**Morning**\nBreakfast at home, then a walk by the water.\n\n**Afternoon**\nA bookshop and a long lunch. If it rains, Scout suggests swapping the walk for a museum.\n\n**Evening**\nKeep it free. Nothing else to fit in." : "The Scout is ready."]
        ]]]
    ]] }
    private func childSnapshot() -> [String: Any] {
        let (revision, status) = Self.state.lock.withLock { (Self.state.childRevision, Self.state.childStatus) }
        return [
            "conversationId": DiagnosticSubagentFixture.childID, "hostEpoch": "fixture", "lastSequence": revision,
            "messages": [], "assistantMessages": [], "thread": ["threadId": DiagnosticSubagentFixture.childThreadID, "hydrated": true, "turns": [[
                "id": "fixture-child-turn", "status": status, "createdAt": "1000", "updatedAt": "2000",
                "items": [["id": "fixture-child-reply", "type": "agentMessage", "state": "completed", "createdAt": "2000", "text": "I am the verified Scout child."]]
            ]]]
        ]
    }
}

struct DiagnosticChatLayoutFixtureView: View {
    @StateObject private var library: ConnectionLibrary
    @State private var prepared = false
    init() {
        _library = StateObject(wrappedValue: ConnectionLibrary(diagnosticModel: DiagnosticSubagentFixture.model()))
    }
    var body: some View {
        Group {
            if prepared {
                TabView {
                    UnifiedChatsView(library: library).tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                    Text("Offline fixture").tabItem { Label("Settings", systemImage: "gearshape") }
                }
            } else { ProgressView() }
        }.task {
            guard !prepared, let saved = library.saved.connections.first else { return }
            let model = library.model(for: saved)
            await model.loadChats(force: true)
            await model.open(DiagnosticSubagentFixture.parentChat())
            model.selectedChat = nil
            prepared = true
        }
    }
}

struct DiagnosticSubagentFixtureView: View {
    @StateObject private var model: ConnectionModel
    init() { _model = StateObject(wrappedValue: DiagnosticSubagentFixture.model()) }
    var body: some View {
        ChatsView(model: model)
            .task {
                model.setForeground(true)
                await model.loadChats(force: true)
            }
    }
}

/// Deterministic stress inputs supplement the live tests through the product renderers.
@MainActor struct DiagnosticFixtureView: View {
    @State private var selection=0
    @State private var expanded=false
    @State private var composerAttachments: [ComposerAttachment]
    @State private var composerImagePreviews: ToolImagePreviews
    @State private var composerImagePreviewScope: UUID
    @StateObject private var lifecycleModel: ConnectionModel
    @State private var workspaceRequest: WorkspaceBrowserRequest?
    private let lifecycleChat: ChatSummary
    private let commandFixtureWidth: CGFloat?
    private let shortCommandFixture: Bool
    private let staleActiveFixture: Bool
    private let cancelledQueueFixture: Bool
    private let longFileFixture: Bool
    private static let output=(0..<5000).map { "Output line \($0): a deterministic tool result." }.joined(separator:"\n")
    private static let diff=(0..<3000).map { ($0.isMultiple(of:2) ? "+" : "-") + "line \($0)" }.joined(separator:"\n")
    private static let commentary=String(repeating:"A commentary paragraph with **formatted text** and a list.\n\n- One item\n- Another item\n\n",count:200)
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let cameraRequested = arguments.contains { $0.hasPrefix("-diagnostics-camera-") } || arguments.contains("-diagnostics-composer-paste")
        let permissionRequested = arguments.contains("-diagnostics-permission-fixture")
        let workingFolderRequested = arguments.contains("-diagnostics-working-folder")
        staleActiveFixture = arguments.contains("-diagnostics-stale-active")
        cancelledQueueFixture = arguments.contains("-diagnostics-cancelled-queue")
        longFileFixture = arguments.contains("-diagnostics-file-long")
        _selection = State(initialValue: cancelledQueueFixture ? 9 : staleActiveFixture ? 8 : cameraRequested ? 5 : permissionRequested ? 6 : workingFolderRequested ? 7 : 0)
        commandFixtureWidth = arguments.contains("-diagnostics-command-constrained") ? 150
            : arguments.contains("-diagnostics-command-narrow") ? 220 : nil
        shortCommandFixture = arguments.contains("-diagnostics-command-short")
        _composerAttachments = State(initialValue: Self.makeComposerAttachments())
        _composerImagePreviews = State(initialValue: ToolImagePreviews())
        _composerImagePreviewScope = State(initialValue: UUID())
        let model = ConnectionModel(saved: nil, persistConnection: { _ in })
        if cancelledQueueFixture && model.previewMode { model.connection = DiagnosticSubagentFixture.savedConnection() }
        let chat = try! JSONDecoder().decode(ChatSummary.self, from: JSONSerialization.data(withJSONObject: [
            "conversationId": "diagnostics-lifecycle", "botId": "fixture-bot", "title": "Turn lifecycle",
            "lastMessagePreview": NSNull(), "lastMessageAt": NSNull(), "messageCount": 0,
            "deliveryState": NSNull(), "hasUnread": false, "isArchived": false, "isPinned": false
        ]))
        model.snapshots = [chat.id: cancelledQueueFixture ? Self.cancelledQueueSnapshot() : staleActiveFixture ? Self.staleActiveRefreshSnapshot() : Self.lifecycleSnapshot()]
        _lifecycleModel = StateObject(wrappedValue: model)
        lifecycleChat = chat
    }
    var body: some View {
        NavigationStack {
            VStack {
                Picker("Fixture",selection:$selection) { Text("Command").tag(0); Text("Diff").tag(1); Text("Commentary").tag(2); Text("Attachments").tag(3); Text("Turn lifecycle").tag(4); Text("Camera").tag(5); Text("Approval permissions").tag(6); Text("Workspace").tag(7); Text("Stale active refresh").tag(8); Text("Cancelled queue").tag(9) }.pickerStyle(.menu)
                    .accessibilityIdentifier("diagnostic-fixture-picker")
                // A sheet and its durable draft must have a stable owner, not
                // a lazy row whose lifetime changes while covered or scrolled.
                if selection == 5 {
                    CameraDiagnosticFixtureView()
                } else if selection == 6 {
                    PermissionPickerFixtureView()
                } else if selection == 7 {
                    WorkingFolderDiagnosticFixtureView()
                } else if selection == 9 {
                    Button("Add activity") { lifecycleModel.snapshots[lifecycleChat.id] = Self.cancelledQueueSnapshot(commandCount: 2) }
                        .accessibilityIdentifier("fixture-add-activity")
                    ConversationView(model: lifecycleModel, chat: lifecycleChat)
                } else if selection == 8 {
                    ConversationView(model: lifecycleModel, chat: lifecycleChat)
                } else {
                ScrollView {
                    LazyVStack(alignment:.leading) {
                        if selection == 2 { BotMessageText(text:Self.commentary) }
                        else if selection == 3 {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Composer attachments").font(.headline)
                                Text("Synthetic local inputs for thumbnail loading and removal.").font(.caption).foregroundStyle(.secondary)
                                Button("Reset attachments", systemImage: "arrow.counterclockwise") {
                                    composerImagePreviews.invalidate()
                                    composerImagePreviewScope = UUID()
                                    composerAttachments = Self.makeComposerAttachments()
                                }
                                .accessibilityIdentifier("reset-composer-attachments")
                                ComposerAttachmentStrip(
                                    attachments: composerAttachments,
                                    imagePreviews: composerImagePreviews,
                                    imagePreviewScope: composerImagePreviewScope,
                                    chatID: "diagnostics-composer",
                                    removalDisabled: false,
                                    loadRemoteData: { _ in throw FileFailure.unsupported },
                                    openPhoto: { _ in },
                                    remove: { id in composerAttachments.removeAll { $0.id == id } }
                                )
                            }
                            .padding(.horizontal, 4)
                        }
                        else if selection == 4 {
                            ActivityLifecycleFixtureView(model: lifecycleModel, chat: lifecycleChat)
                        }
                        else {
                            let item=Self.item(selection, shortCommand: shortCommandFixture, longFile: longFileFixture)
                            let row=ReadRow(id:"fixture/row",author:"Bot",text:"",isUser:false,timestamp:"1700000000000",turnId:"fixture",item:item)
                            ActivityItemView(row:row,expanded:expanded,openFile: { path in workspaceRequest = WorkspaceBrowserRequest(initialFilePath: path) }) { expanded.toggle() }
                                .frame(maxWidth: selection == 0 ? (commandFixtureWidth ?? .infinity) : .infinity, alignment: .leading)
                        }
                    }.padding()
                }
                }
            }.navigationTitle("Rendering fixtures").onChange(of:selection) { _, _ in expanded=false }
            .sheet(item: $workspaceRequest) { request in
                WorkspaceBrowser(model: lifecycleModel, chat: lifecycleChat, attachmentIDs: request.attachmentIDs, initialFilePath: request.initialFilePath)
            }
        }
    }
    private static func makeComposerAttachments() -> [ComposerAttachment] {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 240)).pngData { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 360, height: 240))
            UIColor.white.setFill(); context.fill(CGRect(x: 34, y: 36, width: 292, height: 168))
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 58, y: 60, width: 118, height: 120))
            UIColor.systemMint.setFill(); context.fill(CGRect(x: 194, y: 60, width: 108, height: 120))
        }
        let fileData = Data("Diagnostics attachment fixture".utf8)
        return [
            ComposerAttachment(id: "diagnostics-composer-photo", name: "Diagnostics photo.png", mimeType: "image/png", data: image, remoteFile: nil, sha256: nil, byteSize: image.count, state: "local", updatedAt: "fixture"),
            ComposerAttachment(id: "diagnostics-composer-file", name: "Diagnostics notes.txt", mimeType: "text/plain", data: fileData, remoteFile: nil, sha256: nil, byteSize: fileData.count, state: "local", updatedAt: "fixture")
        ]
    }
    private static func item(_ selection: Int, shortCommand: Bool, longFile: Bool) -> ReadItem {
        let command = shortCommand ? "/bin/zsh -lc 'swift test'"
            : "/bin/zsh -lc 'swift test --filter WonderPairingTests.CommandSummaryTests.testLongUnicodeAndMultilineCommandsStayCompleteInPreparedAccessibility --verbose'"
        let value:[String:Any]=["id":"fixture","type":selection == 0 ? "commandExecution" : "fileChange","state":"completed","createdAt":"1700000000000","payload":["command":selection == 0 ? command : "example","durationMs":selection == 0 ? 5000 : 0,"exitCode":selection == 0 ? 0 : NSNull(),"output":output,"diffs":[["path":longFile ? "Tests/FileChangeSummaryTests.swift" : "Sources/Authentication.swift","kind":"update","additions":1500,"deletions":1500,"diff":diff]]]]
        return try! JSONDecoder().decode(ReadItem.self,from:JSONSerialization.data(withJSONObject:value))
    }

    private static func lifecycleSnapshot() -> ConversationSnapshot {
        func item(_ id: String, _ type: String, _ state: String, _ timestamp: String, _ text: String? = nil, _ payload: [String: Any] = [:]) -> [String: Any] {
            var value: [String: Any] = [
                "id": id, "type": type, "state": state, "createdAt": timestamp,
                "payload": payload
            ]
            value["text"] = text ?? NSNull()
            return value
        }
        let turns: [[String: Any]] = [
            [
                "id": "turn-completed", "status": "completed", "createdAt": "0", "updatedAt": "5000",
                "startedAt": "0", "completedAt": "1312000",
                "items": [
                    item("command", "commandExecution", "completed", "2000", nil, ["command": "fixture command"]),
                    item("reply-one", "agentMessage", "completed", "3000", "The first reply."),
                    item("compact-completed", "contextCompaction", "completed", "3500", "PRIVATE COMPACTION SUMMARY"),
                    item("search", "webSearch", "completed", "4000", nil, ["action": ["type": "search"]]),
                    item("compact-completed-2", "contextCompaction", "completed", "4500", "PRIVATE SECOND SUMMARY"),
                    item("reply-two", "agentMessage", "completed", "5000", "The completed turn is represented once.")
                ]
            ],
            [
                "id": "turn-stopped", "status": "interrupted", "createdAt": "9000", "updatedAt": "10000",
                "items": [
                    item("stopped-command", "commandExecution", "interrupted", "9000", nil, ["command": "stopped fixture command"]),
                    item("compact-stopped", "contextCompaction", "interrupted", "9500", "PRIVATE STOPPED SUMMARY"),
                    item("stopped-reply", "agentMessage", "interrupted", "10000", "The stopped turn keeps its truthful lifecycle label.")
                ]
            ],
            [
                "id": "turn-failed", "status": "failed", "createdAt": "11000", "updatedAt": "11000",
                "items": [item("compact-failed", "contextCompaction", "failed", "11000", "PRIVATE FAILED SUMMARY")]
            ],
            [
                "id": "turn-unknown", "status": "unknown", "createdAt": "12000", "updatedAt": "12000",
                "items": [item("compact-unknown", "contextCompaction", "unknown", "12000", "PRIVATE UNKNOWN SUMMARY")]
            ],
            [
                "id": "turn-active", "status": "inProgress", "createdAt": "13000", "updatedAt": "15000",
                "startedAt": "13000",
                "items": [
                    item("active-command", "commandExecution", "completed", "13000", nil, ["command": "active fixture command"]),
                    item("active-reply", "agentMessage", "completed", "14000", "A reply separates the active segments."),
                    item("compact-running", "contextCompaction", "started", "14500", "PRIVATE RUNNING SUMMARY"),
                    item("active-search", "webSearch", "streaming", "15000", nil, ["action": ["type": "search"]])
                ]
            ]
        ]
        let value: [String: Any] = [
            "conversationId": "diagnostics-lifecycle", "hostEpoch": "fixture", "lastSequence": 1,
            "messages": [
                ["messageId": "completed-receipt", "body": "completed", "state": "streaming", "codexTurnId": "turn-completed", "createdAt": "1000", "attachmentIds": []],
                ["messageId": "active-receipt", "body": "active", "state": "completed", "codexTurnId": "turn-active", "createdAt": "13000", "attachmentIds": []],
                ["messageId": "stopped-receipt", "body": "stopped", "state": "accepted_by_codex", "codexTurnId": "turn-stopped", "createdAt": "9000", "attachmentIds": []]
            ],
            "assistantMessages": [],
            "thread": ["hydrated": true, "turns": turns]
        ]
        return try! JSONDecoder().decode(ConversationSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private static func cancelledQueueSnapshot(commandCount: Int = 1) -> ConversationSnapshot {
        let user: [String: Any] = ["id": "guide", "type": "userMessage", "state": "completed", "createdAt": "1000",
                                   "text": "Add filename links", "payload": ["clientId": "guide"]]
        let commands: [[String: Any]] = (0..<commandCount).map { index in
            ["id": "command-\(index)", "type": "commandExecution", "state": "completed", "createdAt": String(3000 + index),
             "payload": ["command": "fixture command \(index)", "output": "Fixture output"]]
        }
        let value: [String: Any] = [
            "conversationId": "diagnostics-lifecycle", "hostEpoch": "fixture", "lastSequence": commandCount,
            "messages": [
                ["messageId": "guide", "clientMessageId": "guide", "codexTurnId": "runtime", "codexThreadId": "fixture",
                 "body": "Add filename links", "state": "streaming", "createdAt": "1000", "attachmentIds": []],
                ["messageId": "cancelled", "clientMessageId": "cancelled", "body": "Add filename links", "state": "interrupted", "createdAt": "2000", "attachmentIds": []]
            ], "assistantMessages": [], "thread": ["hydrated": true, "turns": [
                ["id": "runtime", "status": "inProgress", "startedAt": "1000", "items": [user] + commands],
                ["id": "local:cancelled", "status": "unknown", "items": [
                    ["id": "cancelled", "type": "userMessage", "state": "interrupted", "createdAt": "2000", "text": "Add filename links", "payload": ["clientId": "cancelled"]]
                ]]
            ]]
        ]
        return try! JSONDecoder().decode(ConversationSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private static func staleActiveRefreshSnapshot() -> ConversationSnapshot {
        let cached: [String: Any] = [
            "conversationId": "diagnostics-lifecycle", "hostEpoch": "fixture", "lastSequence": 1,
            "messages": [], "assistantMessages": [], "thread": ["hydrated": true, "nextCursor": "older", "turns": [
                ["id": "turn-old", "status": "inProgress", "startedAt": "0", "items": [
                    ["id": "old-command", "type": "commandExecution", "state": "completed", "createdAt": "1000", "payload": ["command": "stale cached command"]]
                ]],
                ["id": "turn-new", "status": "completed", "startedAt": "2000", "completedAt": "3000", "items": [
                    ["id": "new-item", "type": "agentMessage", "state": "completed", "createdAt": "3000", "text": "The canonical turn is complete."]
                ]]
            ]]
        ]
        let newest: [String: Any] = [
            "conversationId": "diagnostics-lifecycle", "hostEpoch": "fixture", "lastSequence": 2,
            "messages": [], "assistantMessages": [], "thread": ["hydrated": true, "nextCursor": "older", "turns": [
                ["id": "turn-new", "status": "completed", "startedAt": "2000", "completedAt": "3000", "items": [
                    ["id": "new-reply", "type": "agentMessage", "state": "completed", "createdAt": "3000", "text": "The newest canonical turn is complete."]
                ]]
            ]]
        ]
        let decode: ([String: Any]) -> ConversationSnapshot = { value in
            try! JSONDecoder().decode(ConversationSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let cachedSnapshot = decode(cached)
        let newestSnapshot = decode(newest)
        return try! newestSnapshot.mergingOlder(cachedSnapshot)
    }
}

@MainActor struct ScienceAvatarDiagnosticFixtureView: View {
    private static let storageKey = "wonder.diagnostics.science-avatar"
    @State private var shape = ScienceAvatarCatalog.defaultShape
    @State private var paletteID = ScienceAvatarCatalog.defaultPalette
    @State private var motionState: ScienceAvatarMotionState = .idle
    @State private var savedPayload = "No avatar payload saved"
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Offline avatar fixture")
                        .font(.headline)
                    Text("Seven characters, twelve named palettes, and motion states. This fixture never connects or starts model work.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("Avatar").font(.headline)
                    ScienceAvatarPicker(shape: $shape, paletteID: $paletteID)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Conversation header").font(.subheadline.weight(.semibold))
                        ConversationAvatarHeader(
                            name: "Fixture Bot",
                            identity: "fixture-bot",
                            hexColor: nil,
                            avatarShape: shape.rawValue,
                            avatarPalette: paletteID,
                            motion: ScienceAvatarHeaderMotionOutput(state: motionState)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Preview motion").font(.subheadline.weight(.semibold))
                        ScienceAvatar(shape: shape.rawValue, palette: paletteID, size: 144, state: motionState, animate: true)
                            .accessibilityIdentifier("science-avatar-preview")
                        Picker("Preview motion", selection: $motionState) {
                            ForEach(ScienceAvatarMotionState.allCases) { state in
                                Text(state.title).tag(state)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("science-avatar-motion-picker")
                        Text("Only this enlarged preview animates; list avatars stay static.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Persistence payload").font(.subheadline.weight(.semibold))
                        Text(savedPayload)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("science-avatar-saved-payload")
                        HStack {
                            Button("Save avatar selection") { save() }
                                .accessibilityIdentifier("science-avatar-save")
                            Button("Reload saved avatar") { restore() }
                                .accessibilityIdentifier("science-avatar-reload")
                        }
                    }
                }
                .padding()
            }
            .accessibilityIdentifier("science-avatar-fixture-scroll")
            .navigationTitle("Science avatars")
        }
        .task {
            guard !loaded else { return }
            loaded = true
            if ProcessInfo.processInfo.arguments.contains("-diagnostics-avatar-reset") {
                UserDefaults.standard.removeObject(forKey: Self.storageKey)
            }
            restore()
        }
    }

    private func save() {
        let payload = ["avatarPalette": paletteID, "avatarShape": shape.rawValue]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
        savedPayload = String(decoding: data, as: UTF8.self)
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let rawShape = payload["avatarShape"],
              let restoredShape = ScienceAvatarShape(rawValue: rawShape),
              let restoredPalette = payload["avatarPalette"] else {
            savedPayload = "No avatar payload saved"
            return
        }
        shape = restoredShape
        paletteID = ScienceAvatarPalette.resolve(restoredPalette).id
        savedPayload = String(decoding: data, as: UTF8.self)
    }
}

@MainActor private struct WorkingFolderDiagnosticFixtureView: View {
    @State private var state = "pending"
    private var request: BotFolderRequest {
        BotFolderRequest(
            id: "diagnostic-working-folder",
            botId: "fixture-bot",
            path: "/Users/owner/Projects/Wonder/A very long folder name used to verify wrapping at large text sizes",
            access: "write",
            useAsWorkingDirectory: true,
            state: state)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if state == "pending" {
                    FolderRequestCard(
                        request: request,
                        status: "Approve this folder as the Workspace for the next turn.",
                        busy: false,
                        disabled: false,
                        resolve: { accepted in state = accepted ? "approved" : "declined" })
                }
            }
            .padding()
        }
        .navigationTitle("Workspace fixture")
    }
}

@MainActor private struct PermissionPickerFixtureView: View {
    private static let key = "wonder.diagnostics.approval-mode"
    @State private var selection: BotApprovalMode = .askForApproval
    @State private var saved: BotApprovalMode = .askForApproval
    @State private var loaded = false
    private let oldHost = ProcessInfo.processInfo.arguments.contains("-diagnostics-permission-old-host")
    private let automaticAvailable = ProcessInfo.processInfo.arguments.contains("-diagnostics-permission-auto-available")

    private var options: [BotOptions.ApprovalMode]? {
        guard !oldHost else { return nil }
        return [
            BotOptions.ApprovalMode(id: BotApprovalMode.askForApproval.rawValue, allowed: true),
            BotOptions.ApprovalMode(id: BotApprovalMode.approveForMe.rawValue, allowed: automaticAvailable),
            BotOptions.ApprovalMode(id: BotApprovalMode.fullAccess.rawValue, allowed: true)
        ]
    }

    var body: some View {
        Form {
            Section {
                ApprovalModeMenu(selection: $selection, options: options, onChange: save) {
                    LabeledContent("Approval", value: selection.title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("diagnostic-approval-picker")
                if oldHost {
                    Text("Update Wonder on your Mac to change approval settings.").font(.footnote).foregroundStyle(.secondary)
                } else if !automaticAvailable {
                    Text("Approve for me is unavailable in this managed fixture.").font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("Approval choices") } footer: { Text("This isolated fixture saves only the selected approval mode; it never connects or sends work.") }
            Section("Saved selection") {
                Text(saved.title).accessibilityIdentifier("diagnostic-approval-saved")
                Button("Save selection") { save(selection) }.accessibilityIdentifier("diagnostic-approval-save")
                Button("Reload saved selection") {
                    selection = UserDefaults.standard.string(forKey: Self.key).flatMap(BotApprovalMode.init(rawValue:)) ?? .askForApproval
                    saved = selection
                }.accessibilityIdentifier("diagnostic-approval-reload")
            }
        }
        .navigationTitle("Approval fixture")
        .task {
            guard !loaded else { return }
            loaded = true
            if ProcessInfo.processInfo.arguments.contains("-diagnostics-permission-reset") {
                UserDefaults.standard.removeObject(forKey: Self.key)
            }
            selection = UserDefaults.standard.string(forKey: Self.key).flatMap(BotApprovalMode.init(rawValue:)) ?? .askForApproval
            saved = selection
        }
    }

    private func save(_ mode: BotApprovalMode) {
        guard !oldHost else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
        saved = mode
    }
}

@MainActor private struct CameraDiagnosticFixtureView: View {
    @StateObject private var model: ConnectionModel
    @State private var pasteTask: Task<Void, Never>?
    @State private var showingCamera = false
    @State private var didLaunch = false
    private let chat: ChatSummary
    private let fixture: CameraCaptureFixture?
    private let scope: String
    private let pasteFixture = ProcessInfo.processInfo.arguments.contains("-diagnostics-composer-paste")

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        var initial = ComposerIntent()
        if arguments.contains("-diagnostics-composer-paste") { initial.draft = "Keep this draft." }
        if arguments.contains("-diagnostics-camera-physical") {
            // Real permission, session, preview and shutter. Only the paired
            // model/store are isolated; no fixture bytes reach capture.
            fixture = nil
        } else if arguments.contains("-diagnostics-camera-denied") {
            fixture = .denied
        } else if arguments.contains("-diagnostics-camera-unavailable") {
            fixture = .unavailable
        } else {
            let data = Self.fixtureImageData()
            let preview = UIImage(data: data) ?? UIImage()
            fixture = .ready(data: data, preview: preview)
            if arguments.contains("-diagnostics-camera-limit") {
                initial.stagedFiles = (0..<4).map { index in
                    try! StagedFile(id: "camera-existing-\(index)", name: "Existing photo \(index + 1).jpg", mimeType: "image/jpeg", data: data)
                }
            }
        }
        let chat = Self.fixtureChat()
        let saved = Self.fixtureSavedConnection()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wonder-camera-fixture-\(UUID().uuidString)", isDirectory: true)
        self.chat = chat
        self.scope = saved.credential.hostInstallationId + ":" + saved.credential.deviceId
        _model = StateObject(wrappedValue: ConnectionModel(cameraFixtureStoreRoot: root, saved: saved, chat: chat, initialIntent: initial))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Camera fixture").font(.headline)
            Text(fixture == nil ? "Real camera · isolated draft" : "Deterministic camera · isolated draft")
                .accessibilityIdentifier("camera-input-source")
            Text("No message sending, uploads, or Photos library writes. Reload the saved draft to check its on-disk identity.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Draft attachments: \(model.composers[chat.id]?.attachmentCount ?? 0)")
                .accessibilityIdentifier("camera-draft-count")
            Text(model.composers[chat.id]?.pending == nil ? "No pending send" : "Pending send")
                .accessibilityIdentifier("camera-pending-send")
            Text((model.composers[chat.id]?.stagedFiles ?? []).allSatisfy { $0.uploaded == nil }
                 && model.sending.isEmpty && model.uploading.isEmpty ? "Local draft only" : "Transfer started")
                .accessibilityIdentifier("camera-draft-transfers")
            Button("Open Camera", systemImage: "camera") { showingCamera = true }
                .frame(minHeight: 44)
                .accessibilityIdentifier("open-camera")
            Button("Reload saved draft") { model.reloadCameraFixtureDraft(chat.id) }
                .frame(minHeight: 44)
                .accessibilityIdentifier("camera-reload-draft")
            if pasteFixture {
                HStack {
                    Button("Copy image") { UIPasteboard.general.setItems([[UTType.png.identifier: UIImage(data: Self.fixtureImageData())!.pngData()!]], options: [.localOnly: true]) }
                        .accessibilityIdentifier("fixture-copy-image")
                    Button("Copy text") { UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: " Pasted text."]], options: [.localOnly: true]) }
                        .accessibilityIdentifier("fixture-copy-text")
                }
                BoundedComposerEditor(text: Binding(
                    get: { model.composers[chat.id]?.draft ?? "" },
                    set: { model.editDraft($0, chat: chat.id) }),
                    maximumLines: 3, label: "Message", editable: true,
                    canPasteImages: model.canAttach(chat) && !model.loadingPhotos.contains(chat.id),
                    pasteImages: { providers in
                        pasteTask?.cancel()
                        pasteTask = Task { await model.stagePastedImages(providers, chat: chat, scope: scope) }
                    })
                if model.loadingPhotos.contains(chat.id) { ProgressView("Loading photo…") }
                if let error = model.controlErrors[chat.id] { Text(error) }
            }
            if !composerAttachments.isEmpty {
                ComposerAttachmentStrip(
                    attachments: composerAttachments,
                    imagePreviews: model.imagePreviews,
                    imagePreviewScope: model.imagePreviewScope,
                    chatID: "diagnostics-camera",
                    removalDisabled: !pasteFixture,
                    loadRemoteData: { _ in throw FileFailure.unsupported },
                    openPhoto: { _ in },
                    remove: { model.removeStaged($0, chat: chat.id) }
                )
            }
            Spacer()
        }
        .padding()
        .onDisappear { pasteTask?.cancel() }
        .sheet(isPresented: $showingCamera) {
            CameraCaptureView(
                chatID: "diagnostics-camera",
                chatTitle: "Camera fixture",
                originatingScope: scope,
                currentContextToken: model.cameraContextID.uuidString,
                fixture: fixture,
                attachPhoto: { data in await model.stageCameraPhoto(data, chat: chat, scope: scope) }
            )
        }
        .task {
            guard !didLaunch else { return }
            didLaunch = true
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-diagnostics-camera-") }) {
                showingCamera = true
            }
        }
    }

    private var composerAttachments: [ComposerAttachment] {
        (model.composers[chat.id]?.stagedFiles ?? []).map { file in
            ComposerAttachment(id: file.id, name: file.name, mimeType: file.mimeType, data: file.data,
                               remoteFile: file.uploaded, sha256: file.uploaded?.sha256,
                               byteSize: file.uploaded?.byteSize ?? file.data.count,
                               state: file.uploaded?.state ?? "local", updatedAt: file.uploaded?.updatedAt ?? "fixture")
        }
    }

    private static func fixtureChat() -> ChatSummary {
        let value: [String: Any] = [
            "conversationId": "diagnostics-camera",
            "botId": "camera-fixture-bot",
            "title": "Camera fixture",
            "messageCount": 0,
            "hasUnread": false,
            "isArchived": false,
            "isPinned": false
        ]
        return try! JSONDecoder().decode(ChatSummary.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private static func fixtureSavedConnection() -> SavedConnection {
        let value: [String: Any] = [
            "origin": "https://camera-fixture.invalid",
            "hostName": "Camera fixture",
            "credential": [
                "sessionToken": "camera-fixture-session",
                "deviceId": "camera-fixture-device",
                "csrfToken": "camera-fixture-csrf",
                "hostInstallationId": "camera-fixture-host"
            ]
        ]
        return try! JSONDecoder().decode(SavedConnection.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private static func fixtureImageData() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 720, height: 960), format: format).jpegData(withCompressionQuality: 0.82) { context in
            UIColor(white: 0.18, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 720, height: 960))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 110, y: 190, width: 500, height: 580))
            UIColor.white.setFill()
            context.fill(CGRect(x: 170, y: 270, width: 380, height: 420))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 220, y: 320, width: 120, height: 320))
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 380, y: 320, width: 120, height: 320))
        }
    }
}

@MainActor private struct ActivityLifecycleFixtureView: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    @State private var activityDisclosure = ActivityDisclosurePolicy.State()
    @State private var expandedDetails: Set<String> = []

    var body: some View {
        let timeline = model.feedRows(for: chat)
        let activeTurnIDs = model.activeTurnIDs(chat.id)
        let entries = ChatFeedEntry.grouping(timeline, activeTurnIDs: activeTurnIDs)
        let latestByTurn = ChatFeedEntry.latestActivityEntryIDs(entries)
        let latestActive = ChatFeedEntry.latestActivityEntryID(entries, turnID: model.activeTurn(chat.id))
        let disclosureEntries = entries.compactMap { entry -> ActivityDisclosurePolicy.Entry? in
            guard entry.isActivity, let turnID = entry.rows.first?.turnId else { return nil }
            return ActivityDisclosurePolicy.Entry(
                conversationID: chat.id,
                turnID: turnID,
                entryID: entry.id,
                lifecycle: ActivityDisclosurePolicy.lifecycle(for: model.turn(turnID, in: chat.id)),
                autoOpenWhileActive: activeTurnIDs.contains(turnID)
            )
        }
        let retainedTurnIDs = Set(model.snapshots[chat.id]?.thread.turns?.map(\.id) ?? disclosureEntries.map { $0.key.turnID })
        let reconciledDisclosure = ActivityDisclosurePolicy.reconciled(
            activityDisclosure,
            entries: disclosureEntries,
            retainedConversationID: chat.id,
            retainedTurnIDs: retainedTurnIDs
        )
        let expandedEntries = ActivityDisclosurePolicy.expandedEntryIDs(entries: disclosureEntries, state: reconciledDisclosure)
        let nodes = ChatFeedNode.visible(entries, expanded: expandedEntries)
        VStack(alignment: .leading, spacing: 12) {
            Text("Authoritative turn lifecycle").font(.headline)
            Text("Stale receipts are intentionally mixed into this fixture. The daemon turn status controls activity state.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Complete active turn") { setActiveTurnStatus("completed") }
                    .accessibilityIdentifier("fixture-complete-active-turn")
                Button("Reset active turn") { setActiveTurnStatus("inProgress") }
                    .accessibilityIdentifier("fixture-reset-active-turn")
            }
            ForEach(nodes) { node in
                switch node.content {
                case .entry(let entry):
                    if entry.isActivity {
                        let descriptor = disclosureEntries.first { $0.key.entryID == entry.id }
                        ActivityGroupView(
                            rows: entry.rows,
                            turn: model.turn(entry.rows.first?.turnId, in: chat.id),
                            isLatestSegmentForTurn: latestByTurn.contains(entry.id),
                            isLatestActiveSegment: latestActive == entry.id,
                            expanded: expandedEntries.contains(entry.id)
                        ) {
                            if let descriptor {
                                activityDisclosure = ActivityDisclosurePolicy.toggled(
                                    activityDisclosure,
                                    entry: descriptor,
                                    isExpanded: expandedEntries.contains(entry.id)
                                )
                            }
                        }
                    } else {
                        ForEach(entry.rows) { row in
                            Text(row.text).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                case .activity(let row):
                    if row.isCommentary {
                        Text(row.text).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ActivityItemView(row: row, expanded: expandedDetails.contains(row.id)) {
                            if expandedDetails.contains(row.id) {
                                expandedDetails.remove(row.id)
                            } else {
                                expandedDetails.insert(row.id)
                            }
                        }
                    }
                case .compaction(let row):
                    ContextCompactionMarker(row: row)
                case .file:
                    EmptyView()
                }
            }
        }
        .onChange(of: disclosureEntries, initial: true) { _, _ in
            activityDisclosure = ActivityDisclosurePolicy.reconciled(
                activityDisclosure,
                entries: disclosureEntries,
                retainedConversationID: chat.id,
                retainedTurnIDs: retainedTurnIDs
            )
        }
        .padding(.horizontal, 4)
    }

    private func setActiveTurnStatus(_ status: String) {
        guard let snapshot = model.snapshots[chat.id], let turns = snapshot.thread.turns else { return }
        let updatedTurns = turns.map { turn -> ReadTurn in
            guard turn.id == "turn-active" else { return turn }
            return ReadTurn(
                id: turn.id,
                items: turn.items,
                startedAt: turn.startedAt,
                completedAt: status == "completed" ? "1313000" : nil,
                status: status
            )
        }
        model.snapshots[chat.id] = ConversationSnapshot(
            conversationId: snapshot.conversationId,
            hostEpoch: snapshot.hostEpoch,
            lastSequence: snapshot.lastSequence,
            messages: snapshot.messages,
            assistantMessages: snapshot.assistantMessages,
            thread: ThreadProjection(
                threadId: snapshot.thread.threadId,
                nextCursor: snapshot.thread.nextCursor,
                hydrated: snapshot.thread.hydrated,
                turns: updatedTurns
            )
        )
    }
}
#endif
