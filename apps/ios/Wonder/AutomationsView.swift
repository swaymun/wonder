import SwiftUI
import WonderPairing

private struct AutomationItem: Decodable, Identifiable, Sendable {
    let id: String
    let revision: Int64
    let name: String
    let botId: String?
    let scopeType: String
    let scopeId: String
    let prompt: String
    let rrule: String
    let timezone: String
    let notificationPolicy: String
    let status: String
    let nextRunText: String?
    let lastRunText: String?

    private enum CodingKeys: String, CodingKey {
        case id, revision, name, botId, scopeType, scopeId, prompt, rrule, timezone, notificationPolicy, status, nextRunAt, lastRunAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        revision = try values.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        name = try values.decode(String.self, forKey: .name)
        botId = try values.decodeIfPresent(String.self, forKey: .botId)
        scopeType = try values.decode(String.self, forKey: .scopeType)
        scopeId = try values.decode(String.self, forKey: .scopeId)
        prompt = try values.decode(String.self, forKey: .prompt)
        rrule = try values.decode(String.self, forKey: .rrule)
        timezone = try values.decode(String.self, forKey: .timezone)
        notificationPolicy = try values.decode(String.self, forKey: .notificationPolicy)
        status = try values.decode(String.self, forKey: .status)
        nextRunText = Self.displayTime(try values.decodeIfPresent(String.self, forKey: .nextRunAt))
        lastRunText = Self.displayTime(try values.decodeIfPresent(String.self, forKey: .lastRunAt))
    }

    private static func displayTime(_ value: String?) -> String? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened)
    }

    var isPaused: Bool { status == "paused" }
    var canToggle: Bool { status == "active" || status == "paused" }
}

private struct AutomationBotTarget: Decodable, Sendable {
    let id: String
    let name: String
}

private struct AutomationGroupTarget: Decodable, Sendable {
    let id: String
    let conversationId: String
    let name: String
}

private struct AutomationStatusChange: Encodable {
    let status: String
    let expectedRevision: Int64
}

private struct AutomationProjectDetail: Decodable, Sendable {
    let projectName: String
    let title: String
}

private struct AutomationEditorContext: Identifiable {
    let id = UUID()
    let item: AutomationItem?
}

struct AutomationsView: View {
    @ObservedObject var model: ConnectionModel
    @State private var items: [AutomationItem] = []
    @State private var targetNames: [String: String] = [:]
    @State private var loadToken: UUID?
    @State private var loaded = false
    @State private var failure: String?
    @State private var changing: Set<String> = []
    @State private var changeFailures: [String: String] = [:]
    @State private var mutationRevision: UInt64 = 0
    @State private var editor: AutomationEditorContext?

    private var loading: Bool { loadToken != nil }

    var body: some View {
        Form {
            if model.macConnected != true || model.accessEnded {
                Section {
                    Label(model.accessEnded ? "Access ended. Pair this device again to manage automations." :
                        "Your Mac is offline. Saved schedule details may be out of date.", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("automations-offline")
                }
            }
            if let failure {
                Section {
                    Text(failure).foregroundStyle(.secondary)
                        .accessibilityIdentifier("automations-failure")
                    Button("Try again") { Task { await load(recheck: true) } }
                        .disabled(loading || model.accessEnded)
                        .accessibilityIdentifier("automations-retry")
                }
            }
            Section("Scheduled tasks") {
                if loading && !loaded {
                    ProgressView("Loading automations…")
                        .accessibilityIdentifier("automations-loading")
                } else if items.isEmpty && loaded {
                    Text("No automations yet.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("automations-empty")
                } else if items.isEmpty && !loading {
                    Text("Connect to your Mac to see its automations.")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    automationRow(item)
                }
            }
            Section("Project automations") {
                Button("New Project automation", systemImage: "plus") {
                    editor = AutomationEditorContext(item: nil)
                }
                .disabled(model.macConnected != true || model.accessEnded)
                .accessibilityIdentifier("project-automation-new")
                Text("Continue an existing Project thread on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .wonderGroupedStyle()
        .navigationTitle("Automations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(recheck: true) } }
                    .disabled(loading || model.accessEnded)
                    .accessibilityIdentifier("automations-refresh")
            }
        }
        .refreshable { await load(recheck: true) }
        .sheet(item: $editor) { context in
            NavigationStack {
                ProjectAutomationEditor(model: model, item: context.item, targetLabel: context.item.map(targetName)) { saved, label in
                    mutationRevision &+= 1
                    if let index = items.firstIndex(where: { $0.id == saved.id }) { items[index] = saved }
                    else { items.append(saved) }
                    if let label { targetNames["project:\(saved.scopeId)"] = label }
                    editor = nil
                } onCancel: {
                    editor = nil
                } onReload: {
                    editor = nil
                    Task { await load(recheck: true) }
                }
            }
        }
        .task(id: model.assignmentScope) {
            items = []; targetNames = [:]; loaded = false; failure = nil; changeFailures = [:]; changing = []; loadToken = nil; mutationRevision = 0; editor = nil
            await load()
        }
        .onChange(of: model.macConnected) { _, connected in
            if connected == true && !loading { Task { await load() } }
        }
    }

    @ViewBuilder private func automationRow(_ item: AutomationItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name).font(.headline)
                Spacer(minLength: 8)
                Text(item.isPaused ? "Paused" : item.status == "active" ? "Active" : "Unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(targetName(for: item))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Label(item.isPaused ? "Next: paused" : "Next: \(item.nextRunText ?? "not scheduled")", systemImage: "calendar")
                Label("Last: \(item.lastRunText ?? "never")", systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let error = changeFailures[item.id] {
                Text(error).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("automation-change-failure:\(item.id)")
            }
            HStack(spacing: 20) {
                if item.canToggle {
                    Button {
                        Task { await changeStatus(item) }
                    } label: {
                        Text(item.isPaused ? "Resume" : "Pause")
                            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(changing.contains(item.id) || model.macConnected != true || model.accessEnded)
                    .accessibilityIdentifier("automation-toggle:\(item.id)")
                }
                if item.scopeType == "project_thread" {
                    Button {
                        editor = AutomationEditorContext(item: item)
                    } label: {
                        Text("Edit")
                            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.macConnected != true || model.accessEnded)
                    .accessibilityIdentifier("automation-edit:\(item.id)")
                }
            }
            if changing.contains(item.id) {
                ProgressView(item.isPaused ? "Resuming…" : "Pausing…")
                    .font(.caption)
                    .accessibilityIdentifier("automation-changing:\(item.id)")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("automation-row:\(item.id)")
    }

    private func targetName(for item: AutomationItem) -> String {
        if item.scopeType == "project_thread" {
            return targetNames["project:\(item.scopeId)"] ?? "Project thread"
        }
        if item.scopeType == "group_chat" {
            if let name = targetNames["group:\(item.scopeId)"] { return "Group Chat · \(name)" }
            let group = model.groups.values.first { $0.id == item.scopeId || $0.conversationId == item.scopeId }
            return "Group Chat · \(group?.name ?? "Unavailable Group Chat")"
        }
        guard let botId = item.botId else { return "Unavailable target" }
        if let name = targetNames["bot:\(botId)"] { return "Bot · \(name)" }
        let bot = model.managedBots.first { $0.id == botId }
        return "Bot · \(bot?.name ?? "Unavailable Bot")"
    }

    @MainActor private func load(recheck: Bool = false) async {
        guard !loading else { return }
        let token = UUID()
        loadToken = token
        defer { if loadToken == token { loadToken = nil } }
        failure = nil
        let scope = model.assignmentScope
        let revision = mutationRevision
        if model.macConnected != true { await model.check(renew: recheck, userInitiated: recheck) }
        guard scope == model.assignmentScope, !Task.isCancelled else { return }
        guard let saved = model.connection, !model.accessEnded, model.macConnected == true else {
            failure = model.accessEnded ? "Pair this device again to manage automations." : "Connect to your Mac, then try again."
            return
        }
        do {
            async let botRequest: [AutomationBotTarget] = model.api.request("/api/v1/bots", origin: saved.origin, credential: saved.credential)
            async let groupRequest: [AutomationGroupTarget] = model.api.request("/api/v1/group-chats", origin: saved.origin, credential: saved.credential)
            let response: [AutomationItem] = try await model.api.request("/api/v1/automations", origin: saved.origin, credential: saved.credential)
            let projectIDs = Set(response.filter { $0.scopeType == "project_thread" }.map(\.scopeId))
            var projectNames: [String: String] = [:]
            for id in projectIDs {
                guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { continue }
                if let detail: AutomationProjectDetail = try? await model.api.request(
                    "/api/v1/project-conversations/\(escaped)", origin: saved.origin, credential: saved.credential) {
                    projectNames["project:\(id)"] = "\(detail.projectName) · \(detail.title)"
                }
            }
            let fetchedBots = try? await botRequest
            let fetchedGroups = try? await groupRequest
            let bots = fetchedBots ?? []
            let groups = fetchedGroups ?? []
            guard scope == model.assignmentScope, model.connection?.origin == saved.origin,
                  revision == mutationRevision, !model.accessEnded, !Task.isCancelled else { return }
            var names = Dictionary(uniqueKeysWithValues: bots.map { ("bot:\($0.id)", $0.name) })
            for group in groups {
                names["group:\(group.id)"] = group.name
                names["group:\(group.conversationId)"] = group.name
            }
            names.merge(projectNames) { _, new in new }
            targetNames = names
            items = response
            loaded = true
            changeFailures = [:]
            if (response.contains { $0.scopeType == "bot" } && fetchedBots == nil)
                || (response.contains { $0.scopeType == "group_chat" } && fetchedGroups == nil)
                || (projectIDs.count > projectNames.count) {
                failure = "Some target names couldn’t be loaded. Try again."
            }
        } catch {
            guard scope == model.assignmentScope, model.connection?.origin == saved.origin,
                  revision == mutationRevision, !model.accessEnded, !Task.isCancelled else { return }
            failure = loadFailure(error)
        }
    }

    @MainActor private func changeStatus(_ item: AutomationItem) async {
        guard item.canToggle, !changing.contains(item.id), let saved = model.connection,
              !model.accessEnded, model.macConnected == true else { return }
        let scope = model.assignmentScope
        changing.insert(item.id)
        changeFailures[item.id] = nil
        defer { if scope == model.assignmentScope { changing.remove(item.id) } }
        do {
            let body = try JSONEncoder().encode(AutomationStatusChange(
                status: item.isPaused ? "active" : "paused", expectedRevision: item.revision))
            guard let pathID = item.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw PairingFailure.invalidLink }
            let updated: AutomationItem = try await model.api.request(
                "/api/v1/automations/\(pathID)",
                origin: saved.origin, body: body, credential: saved.credential, method: "PATCH")
            guard scope == model.assignmentScope, model.connection?.origin == saved.origin,
                  !model.accessEnded, !Task.isCancelled else { return }
            guard updated.id == item.id else { throw ReadFailure.resync }
            mutationRevision &+= 1
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = updated }
        } catch {
            guard scope == model.assignmentScope, model.connection?.origin == saved.origin,
                  !model.accessEnded, !Task.isCancelled else { return }
            let detail: String
            if case PairingFailure.response(404) = error { detail = "It is no longer available. Refresh the list." }
            else { detail = requestFailure(error) }
            changeFailures[item.id] = "Couldn’t \(item.isPaused ? "resume" : "pause") this automation. \(detail)"
        }
    }

    private func loadFailure(_ error: Error) -> String {
        let detail = requestFailure(error)
        return detail == "Try again." ? "Automations couldn’t be loaded. Try again." : detail
    }

    private func requestFailure(_ error: Error) -> String {
        if case PairingFailure.response(404) = error { return "Update Wonder on your Mac to manage automations." }
        if case PairingFailure.response(409) = error { return "The automation or its target changed. Refresh and try again." }
        if error is URLError { return "Couldn’t reach your Mac. Check the connection and try again." }
        return "Try again."
    }
}

private struct AutomationProjectsResponse: Decodable {
    let projects: [AutomationProjectChoice]
}

private struct AutomationProjectChoice: Decodable, Identifiable {
    let id: String
    let name: String
    let isIncluded: Bool
}

private struct AutomationThreadsPage: Decodable {
    let threads: [AutomationThreadChoice]
    let nextCursor: String?
}

private struct AutomationThreadChoice: Decodable, Identifiable {
    let reference: String
    let conversationId: String?
    let title: String
    let family: String
    var id: String { conversationId ?? reference }
    var isSchedulable: Bool { conversationId != nil && !reference.hasPrefix("wonder:") }
    var label: String { "\(title) · \(family == "claude" ? "Claude" : "Codex")" }
}

private enum AutomationRecurrence: String, CaseIterable, Identifiable {
    case daily, weekdays, weekly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .daily: "Every day"
        case .weekdays: "Weekdays"
        case .weekly: "Every week"
        }
    }
}

private struct AutomationWrite: Encodable {
    let name: String
    let prompt: String
    let rrule: String
    let timezone: String
    let status: String
    let notificationPolicy: String
    let kind: String?
    let scopeType: String?
    let scopeId: String?
    let conversationId: String?
    let clientRequestId: String?
    let expectedRevision: Int64?
}

private struct ProjectAutomationEditor: View {
    @ObservedObject var model: ConnectionModel
    let item: AutomationItem?
    let targetLabel: String?
    let onSaved: (AutomationItem, String?) -> Void
    let onCancel: () -> Void
    let onReload: () -> Void

    @State private var name: String
    @State private var prompt: String
    @State private var isActive: Bool
    @State private var notificationPolicy: String
    @State private var recurrence: AutomationRecurrence
    @State private var weekday: String
    @State private var time: Date
    @State private var scheduleEditable: Bool
    @State private var projects: [AutomationProjectChoice] = []
    @State private var projectID = ""
    @State private var threads: [AutomationThreadChoice] = []
    @State private var threadID = ""
    @State private var nextCursor: String?
    @State private var loadingProjects = false
    @State private var loadingThreads = false
    @State private var threadLoadToken = UUID()
    @State private var targetFailure: String?
    @State private var saveFailure: String?
    @State private var saveConflict = false
    @State private var createConflict = false
    @State private var saving = false
    @State private var requestID = UUID().uuidString

    init(model: ConnectionModel, item: AutomationItem?, targetLabel: String?,
         onSaved: @escaping (AutomationItem, String?) -> Void, onCancel: @escaping () -> Void,
         onReload: @escaping () -> Void) {
        self.model = model; self.item = item; self.targetLabel = targetLabel
        self.onSaved = onSaved; self.onCancel = onCancel; self.onReload = onReload
        _name = State(initialValue: item?.name ?? "")
        _prompt = State(initialValue: item?.prompt ?? "")
        _isActive = State(initialValue: item?.status != "paused")
        _notificationPolicy = State(initialValue: item?.notificationPolicy ?? "all_runs")
        let schedule = Self.readSchedule(item)
        _recurrence = State(initialValue: schedule.0)
        _weekday = State(initialValue: schedule.1)
        _time = State(initialValue: schedule.2)
        _scheduleEditable = State(initialValue: item == nil || schedule.3)
    }

    var body: some View {
        Form {
            Section("Project thread") {
                if let item {
                    Text(targetLabel ?? "Project thread")
                        .accessibilityIdentifier("project-automation-target")
                    if item.scopeId.isEmpty { Text("This thread is unavailable.").foregroundStyle(.secondary) }
                } else {
                    if loadingProjects { ProgressView("Loading Projects…") }
                    if let targetFailure {
                        Text(targetFailure).foregroundStyle(.red)
                            .accessibilityIdentifier("project-automation-target-failure")
                        Button("Try again") { Task {
                            if projects.isEmpty { await loadProjects() }
                            else { await loadThreads(more: false) }
                        } }
                            .accessibilityIdentifier("project-automation-target-retry")
                    }
                    if projects.isEmpty && !loadingProjects && targetFailure == nil {
                        Text("Open a Project thread on your Mac before scheduling it.")
                            .foregroundStyle(.secondary)
                    }
                    if !projects.isEmpty {
                        Picker("Project", selection: $projectID) {
                            ForEach(projects) { project in Text(project.name).tag(project.id) }
                        }
                        .accessibilityIdentifier("project-automation-project")
                        .task(id: projectID) {
                            guard !projectID.isEmpty else { return }
                            threadLoadToken = UUID()
                            loadingThreads = false
                            threads = []; threadID = ""; nextCursor = nil
                            await loadThreads(more: false)
                        }
                        if loadingThreads { ProgressView("Loading threads…") }
                        if !threads.isEmpty {
                            Picker("Thread", selection: $threadID) {
                                Text("Choose a thread").tag("")
                                ForEach(threads.filter(\.isSchedulable)) { thread in
                                    if let id = thread.conversationId { Text(thread.label).tag(id) }
                                }
                            }
                            .accessibilityIdentifier("project-automation-thread")
                        } else if !loadingThreads {
                            Text("No ready Project threads yet. Open one in Wonder first.")
                                .foregroundStyle(.secondary)
                        }
                        if nextCursor != nil {
                            Button("Show more threads") { Task { await loadThreads(more: true) } }
                                .disabled(loadingThreads)
                                .accessibilityIdentifier("project-automation-more-threads")
                        }
                    }
                }
            }
            Section("Task") {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("project-automation-name")
                TextField("What should the agent do?", text: $prompt, axis: .vertical)
                    .lineLimit(3...6)
                    .accessibilityIdentifier("project-automation-prompt")
            }
            Section("Schedule") {
                if scheduleEditable {
                    Picker("Repeat", selection: $recurrence) {
                        ForEach(AutomationRecurrence.allCases) { option in Text(option.title).tag(option) }
                    }
                    .accessibilityIdentifier("project-automation-repeat")
                    if recurrence == .weekly {
                        Picker("Day", selection: $weekday) {
                            ForEach(Self.weekdays, id: \.0) { day in Text(day.1).tag(day.0) }
                        }
                        .accessibilityIdentifier("project-automation-day")
                    }
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("project-automation-time")
                    Text("Times use \(TimeZone.current.identifier).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("This schedule uses a custom recurrence. Its timing stays the same when you save.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Change schedule") { scheduleEditable = true }
                        .accessibilityIdentifier("project-automation-change-schedule")
                }
                Toggle("Active", isOn: $isActive).systemSwitch()
                    .accessibilityIdentifier("project-automation-active")
                Picker("Notify me", selection: $notificationPolicy) {
                    Text("Every run").tag("all_runs")
                    Text("Failures only").tag("failed_runs_only")
                }
                .accessibilityIdentifier("project-automation-notifications")
            }
        }
        .disabled(saving)
        .safeAreaInset(edge: .top) { failureBanner }
        .wonderGroupedStyle()
        .navigationTitle(item == nil ? "New automation" : "Edit automation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel", action: onCancel) }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { Task { await save() } }
                    .disabled(!canSave)
                    .accessibilityIdentifier("project-automation-save")
            }
        }
        .interactiveDismissDisabled(saving)
        .task(id: model.assignmentScope) {
            saving = false
            loadingProjects = false
            loadingThreads = false
            threadLoadToken = UUID()
            projects = []; projectID = ""; threads = []; threadID = ""; nextCursor = nil
            if item == nil { await loadProjects() }
        }
    }

    @ViewBuilder private var failureBanner: some View {
        if let saveFailure {
            VStack(alignment: .leading, spacing: 6) {
                Text(saveFailure)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("project-automation-save-failure")
                if saveConflict {
                    Button("Reload latest version") { onReload() }
                        .accessibilityIdentifier("project-automation-reload")
                    Text("Your draft will be replaced with the version on your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if createConflict {
                    Button("Keep draft for a new task") {
                        requestID = UUID().uuidString
                        createConflict = false
                        self.saveFailure = nil
                    }
                    .accessibilityIdentifier("project-automation-new-request")
                    Text("The first request may have created a task. Check the list before saving another.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial)
        }
    }

    private var canSave: Bool {
        !saving && model.macConnected == true && !model.accessEnded
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (item != nil || !threadID.isEmpty)
    }

    private var rrule: String {
        if !scheduleEditable, let item { return item.rrule }
        let hour = Calendar.current.component(.hour, from: time)
        let minute = Calendar.current.component(.minute, from: time)
        let start: String
        switch recurrence {
        case .daily: start = "FREQ=DAILY"
        case .weekdays: start = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        case .weekly: start = "FREQ=WEEKLY;BYDAY=\(weekday)"
        }
        return "\(start);BYHOUR=\(hour);BYMINUTE=\(minute)"
    }

    private static let weekdays: [(String, String)] = [
        ("MO", "Monday"), ("TU", "Tuesday"), ("WE", "Wednesday"),
        ("TH", "Thursday"), ("FR", "Friday"), ("SA", "Saturday"), ("SU", "Sunday")
    ]

    private static func readSchedule(_ item: AutomationItem?) -> (AutomationRecurrence, String, Date, Bool) {
        let fallback = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        guard let item, item.timezone == TimeZone.current.identifier else { return (.daily, "MO", fallback, item == nil) }
        let fields = item.rrule.split(separator: ";").compactMap { part -> (String, String)? in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            return pair.count == 2 ? (pair[0], pair[1]) : nil
        }
        let values = Dictionary(fields, uniquingKeysWith: { _, new in new })
        guard let hour = values["BYHOUR"].flatMap(Int.init), (0...23).contains(hour),
              let minute = values["BYMINUTE"].flatMap(Int.init), (0...59).contains(minute),
              let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) else {
            return (.daily, "MO", fallback, false)
        }
        if values["FREQ"] == "DAILY", values["BYDAY"] == nil { return (.daily, "MO", date, true) }
        if values["FREQ"] == "WEEKLY", values["BYDAY"] == "MO,TU,WE,TH,FR" { return (.weekdays, "MO", date, true) }
        if values["FREQ"] == "WEEKLY", let day = values["BYDAY"], weekdays.contains(where: { $0.0 == day }) {
            return (.weekly, day, date, true)
        }
        return (.daily, "MO", fallback, false)
    }

    @MainActor private func loadProjects() async {
        guard !loadingProjects, let saved = model.connection, model.macConnected == true, !model.accessEnded else { return }
        let scope = model.assignmentScope
        loadingProjects = true; targetFailure = nil
        defer { if scope == model.assignmentScope { loadingProjects = false } }
        do {
            let response: AutomationProjectsResponse = try await model.api.request(
                "/api/v1/projects", origin: saved.origin, credential: saved.credential)
            guard scope == model.assignmentScope, model.connection?.origin == saved.origin, !Task.isCancelled else { return }
            projects = response.projects.filter(\.isIncluded).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if projectID.isEmpty, let first = projects.first { projectID = first.id }
        } catch {
            guard scope == model.assignmentScope, !Task.isCancelled else { return }
            targetFailure = "Projects couldn’t be loaded. Check your Mac connection and try again."
        }
    }

    @MainActor private func loadThreads(more: Bool) async {
        guard !loadingThreads, !projectID.isEmpty, let saved = model.connection,
              model.macConnected == true, !model.accessEnded else { return }
        let scope = model.assignmentScope
        let requestedProject = projectID
        let token = threadLoadToken
        let cursor = more ? nextCursor : nil
        loadingThreads = true; targetFailure = nil
        defer { if scope == model.assignmentScope, threadLoadToken == token { loadingThreads = false } }
        guard let escaped = requestedProject.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }
        var path = "/api/v1/projects/\(escaped)/threads?limit=30"
        if let cursor, let value = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { path += "&cursor=\(value)" }
        do {
            let page: AutomationThreadsPage = try await model.api.request(path, origin: saved.origin, credential: saved.credential)
            guard scope == model.assignmentScope, threadLoadToken == token, projectID == requestedProject,
                  model.connection?.origin == saved.origin, !Task.isCancelled else { return }
            if !more { threads = [] }
            let existing = Set(threads.map(\.id))
            threads += page.threads.filter { $0.isSchedulable && !existing.contains($0.id) }
            nextCursor = page.nextCursor
            if threadID.isEmpty, threads.count == 1, nextCursor == nil {
                threadID = threads[0].conversationId ?? ""
            }
        } catch {
            guard scope == model.assignmentScope, threadLoadToken == token,
                  projectID == requestedProject, !Task.isCancelled else { return }
            targetFailure = "Project threads couldn’t be loaded. Try again."
        }
    }

    @MainActor private func save() async {
        guard canSave, let saved = model.connection else { return }
        let scope = model.assignmentScope
        let selectedProject = projectID
        let selectedThread = item?.scopeId ?? threadID
        let selectedLabel = item == nil ? projects.first(where: { $0.id == selectedProject }).flatMap { project in
            threads.first(where: { $0.conversationId == selectedThread }).map { "\(project.name) · \($0.title)" }
        } : targetLabel
        saving = true; saveFailure = nil; saveConflict = false; createConflict = false
        defer { if scope == model.assignmentScope { saving = false } }
        do {
            let body = try JSONEncoder().encode(AutomationWrite(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), rrule: rrule,
                timezone: scheduleEditable ? TimeZone.current.identifier : (item?.timezone ?? TimeZone.current.identifier),
                status: isActive ? "active" : "paused", notificationPolicy: notificationPolicy,
                kind: item == nil ? "continuation" : nil,
                scopeType: item == nil ? "project_thread" : nil,
                scopeId: item == nil ? selectedThread : nil,
                conversationId: item == nil ? selectedThread : nil,
                clientRequestId: item == nil ? requestID : nil,
                expectedRevision: item?.revision))
            let path = item.map { "/api/v1/automations/\(ConnectionModel.escape($0.id))" } ?? "/api/v1/automations"
            let updated: AutomationItem = try await model.api.request(path, origin: saved.origin, body: body,
                credential: saved.credential, method: item == nil ? "POST" : "PATCH")
            guard scope == model.assignmentScope, model.connection?.origin == saved.origin,
                  !model.accessEnded, !Task.isCancelled else { return }
            guard updated.scopeType == "project_thread", updated.scopeId == selectedThread else {
                throw ReadFailure.resync
            }
            onSaved(updated, selectedLabel)
        } catch {
            guard scope == model.assignmentScope, model.connection?.origin == saved.origin,
                  !model.accessEnded, !Task.isCancelled else { return }
            if case PairingFailure.response(409) = error {
                if item == nil {
                    createConflict = true
                    saveFailure = "This request may already have created an automation, or the Project thread changed. Your draft is still here."
                } else {
                    saveConflict = true
                    saveFailure = "This automation or Project thread changed. Reload the latest version to continue."
                }
            } else if case PairingFailure.response(404) = error {
                saveFailure = "This automation or Project thread is no longer available."
            } else {
                saveFailure = "Couldn’t save this automation. Check your Mac connection and try again."
            }
        }
    }
}

#if WONDER_DIAGNOSTICS
/// An isolated, owner-authenticated transport fixture for iPhone and iPad UI checks.
struct DiagnosticAutomationsFixtureView: View {
    @StateObject private var model: ConnectionModel

    init() {
        let credential = try! JSONDecoder().decode(Credential.self, from: Data(#"{"sessionToken":"automation-fixture-session","deviceId":"automation-fixture-device","csrfToken":"automation-fixture-csrf","hostInstallationId":"automation-fixture-host"}"#.utf8))
        let saved = SavedConnection(origin: "https://automations.invalid", credential: credential, hostName: "Fixture Mac")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticAutomationURLProtocol.self]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wonder-automations-fixture-\(UUID().uuidString)")
        _model = StateObject(wrappedValue: ConnectionModel(cameraFixtureStoreRoot: root, saved: saved,
            api: PairingAPI(configuration: configuration), replayEnabled: false))
    }

    var body: some View { NavigationStack { AutomationsView(model: model) } } // theme-exempt: Diagnostics fixture host
}

private final class DiagnosticAutomationURLProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var botStatus = "active"
        var botRevision = 0
        var groupStatus = "paused"
        var groupRevision = 0
        var projectCreated = ProcessInfo.processInfo.arguments.contains("-diagnostics-automations-existing-project")
        var projectRevision = 0
        var projectStatus = "active"
        var projectName = "Project check-in"
        var projectPrompt = "Review the Project progress."
        var projectRRule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
        var projectTimezone = TimeZone.current.identifier
        var projectNotifications = "all_runs"
        var createdRequestID: String?
        var lostCreateResponseRemaining = ProcessInfo.processInfo.arguments.contains("-diagnostics-automations-create-lost-response") ? 1 : 0
        var listFailuresRemaining = ProcessInfo.processInfo.arguments.contains("-diagnostics-automations-list-fails") ? 1 : 0
        var patchFailuresRemaining = ProcessInfo.processInfo.arguments.contains("-diagnostics-automations-patch-fails") ? 1 : 0
        var projectSaveFailuresRemaining = ProcessInfo.processInfo.arguments.contains("-diagnostics-automations-project-save-fails") ? 1 : 0
        var staleBotPatchesRemaining = ProcessInfo.processInfo.arguments.contains("-diagnostics-automations-revision-conflict") ? 1 : 0
        var staleProjectPatchesRemaining = ProcessInfo.processInfo.arguments.contains("-diagnostics-automations-revision-conflict") ? 1 : 0
    }
    private static let state = State()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "automations.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { respond(status: 400); return }
        let path = url.path
        let method = request.httpMethod ?? "GET"
        guard request.value(forHTTPHeaderField: "Cookie") == "__Host-wonder_session=automation-fixture-session",
              request.value(forHTTPHeaderField: "x-wonder-csrf") == "automation-fixture-csrf" else {
            respond(status: 401); return
        }
        if method == "GET" && path == "/api/v1/bots" {
            respond(json: #"[{"id":"fixture-bot","name":"Research Bot"}]"#)
        } else if method == "GET" && path == "/api/v1/group-chats" {
            respond(json: #"[{"id":"fixture-group","conversationId":"fixture-group-chat","name":"Launch Team"}]"#)
        } else if method == "GET" && path == "/api/v1/projects" {
            if ProcessInfo.processInfo.arguments.contains("-diagnostics-automations-switch-project") ||
                ProcessInfo.processInfo.arguments.contains("-diagnostics-automations-slow-create") {
                respond(json: #"{"projects":[{"id":"fixture-project","name":"Roadmap","isIncluded":true},{"id":"fixture-project-two","name":"Zephyr","isIncluded":true}]}"#)
            } else {
                respond(json: #"{"projects":[{"id":"fixture-project","name":"Roadmap","isIncluded":true}]}"#)
            }
        } else if method == "GET" && path == "/api/v1/projects/fixture-project/threads" {
            let response = #"{"threads":[{"reference":"codex:fixture-native-thread","conversationId":"fixture-project-thread","title":"Plan launch","family":"codex"},{"reference":"wonder:draft","conversationId":"fixture-draft","title":"Unstarted draft","family":"codex"}],"nextCursor":null}"#
            if ProcessInfo.processInfo.arguments.contains("-diagnostics-automations-switch-project") {
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in self?.respond(json: response) }
            } else { respond(json: response) }
        } else if method == "GET" && path == "/api/v1/projects/fixture-project-two/threads" {
            respond(json: #"{"threads":[{"reference":"codex:zephyr-thread","conversationId":"zephyr-project-thread","title":"Check Zephyr","family":"codex"}],"nextCursor":null}"#)
        } else if method == "GET" && path == "/api/v1/project-conversations/fixture-project-thread" {
            respond(json: #"{"projectName":"Roadmap","title":"Plan launch"}"#)
        } else if method == "GET" && path == "/api/v1/automations" {
            let response = Self.state.lock.withLock { () -> String? in
                if Self.state.listFailuresRemaining > 0 { Self.state.listFailuresRemaining -= 1; return nil }
                return Self.listJSON(Self.state)
            }
            if let response { respond(json: response) } else { respond(status: 503) }
        } else if method == "POST" && path == "/api/v1/automations" {
            guard let body = requestBody(), let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  fields["scopeType"] as? String == "project_thread",
                  fields["scopeId"] as? String == "fixture-project-thread",
                  fields["conversationId"] as? String == "fixture-project-thread",
                  fields["botId"] == nil,
                  let name = fields["name"] as? String, let prompt = fields["prompt"] as? String,
                  let rrule = fields["rrule"] as? String, let timezone = fields["timezone"] as? String,
                  let status = fields["status"] as? String,
                  let notifications = fields["notificationPolicy"] as? String else { respond(status: 400); return }
            let result = Self.state.lock.withLock { () -> (Int, String?) in
                if Self.state.projectSaveFailuresRemaining > 0 {
                    Self.state.projectSaveFailuresRemaining -= 1; return (503, nil)
                }
                let requestID = fields["clientRequestId"] as? String
                if Self.state.projectCreated, requestID == Self.state.createdRequestID,
                   Self.state.createdRequestID != nil {
                    return Self.state.projectName == name && Self.state.projectPrompt == prompt
                        ? (200, Self.projectJSON(Self.state)) : (409, nil)
                }
                Self.state.projectCreated = true; Self.state.projectRevision = 0
                Self.state.createdRequestID = requestID
                Self.state.projectName = name; Self.state.projectPrompt = prompt
                Self.state.projectRRule = rrule; Self.state.projectTimezone = timezone
                Self.state.projectStatus = status; Self.state.projectNotifications = notifications
                if Self.state.lostCreateResponseRemaining > 0 {
                    Self.state.lostCreateResponseRemaining -= 1
                    return (503, nil)
                }
                return (201, Self.projectJSON(Self.state))
            }
            if ProcessInfo.processInfo.arguments.contains("-diagnostics-automations-slow-create") {
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self else { return }
                    if let body = result.1 { self.respond(status: result.0, data: Data(body.utf8)) }
                    else { self.respond(status: result.0) }
                }
            } else if let body = result.1 { respond(status: result.0, data: Data(body.utf8)) }
            else { respond(status: result.0) }
        } else if method == "PATCH" && path.hasPrefix("/api/v1/automations/") {
            let id = String(path.dropFirst("/api/v1/automations/".count))
            let fields = (requestBody().flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            guard id == "fixture-bot-schedule" || id == "fixture-group-schedule" || id == "fixture-project-schedule" else {
                respond(status: 400); return
            }
            let response = Self.state.lock.withLock { () -> (Int, String?) in
                if id == "fixture-bot-schedule", Self.state.staleBotPatchesRemaining > 0 {
                    Self.state.staleBotPatchesRemaining -= 1
                    Self.state.botRevision += 1
                }
                if id == "fixture-project-schedule", Self.state.staleProjectPatchesRemaining > 0 {
                    Self.state.staleProjectPatchesRemaining -= 1
                    Self.state.projectRevision += 1
                    Self.state.projectName = "Project updated on Mac"
                    Self.state.projectPrompt = "Updated on Mac."
                }
                let revision = id == "fixture-project-schedule" ? Self.state.projectRevision :
                    id == "fixture-bot-schedule" ? Self.state.botRevision : Self.state.groupRevision
                if let expected = fields["expectedRevision"] as? Int, expected != revision {
                    return (409, nil)
                }
                if id == "fixture-project-schedule" {
                    guard Self.state.projectCreated else { return (404, nil) }
                    if Self.state.projectSaveFailuresRemaining > 0 {
                        Self.state.projectSaveFailuresRemaining -= 1; return (503, nil)
                    }
                    if let name = fields["name"] as? String { Self.state.projectName = name }
                    if let prompt = fields["prompt"] as? String { Self.state.projectPrompt = prompt }
                    if let rrule = fields["rrule"] as? String { Self.state.projectRRule = rrule }
                    if let timezone = fields["timezone"] as? String { Self.state.projectTimezone = timezone }
                    if let notifications = fields["notificationPolicy"] as? String { Self.state.projectNotifications = notifications }
                    if let status = fields["status"] as? String { Self.state.projectStatus = status }
                    Self.state.projectRevision += 1
                    return (200, Self.projectJSON(Self.state))
                }
                guard let requested = fields["status"] as? String,
                      requested == "active" || requested == "paused" else { return (400, nil) }
                if Self.state.patchFailuresRemaining > 0 { Self.state.patchFailuresRemaining -= 1; return (503, nil) }
                if id == "fixture-bot-schedule" {
                    Self.state.botStatus = requested; Self.state.botRevision += 1
                    return (200, Self.itemJSON(id: id, status: requested, revision: Self.state.botRevision))
                }
                Self.state.groupStatus = requested; Self.state.groupRevision += 1
                return (200, Self.itemJSON(id: id, status: requested, revision: Self.state.groupRevision))
            }
            if let body = response.1 { respond(json: body) } else { respond(status: response.0) }
        } else {
            respond(status: 404)
        }
    }

    override func stopLoading() {}

    private func requestBody() -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func listJSON(_ state: State) -> String {
        var entries = [itemJSON(id: "fixture-bot-schedule", status: state.botStatus, revision: state.botRevision),
                       itemJSON(id: "fixture-group-schedule", status: state.groupStatus, revision: state.groupRevision)]
        if state.projectCreated { entries.append(projectJSON(state)) }
        return "[\(entries.joined(separator: ","))]"
    }

    private static func itemJSON(id: String, status: String, revision: Int) -> String {
        let bot = id == "fixture-bot-schedule"
        return """
        {"id":"\(id)","revision":\(revision),"name":"\(bot ? "Morning brief" : "Weekly recap")","botId":"fixture-bot","scopeType":"\(bot ? "bot" : "group_chat")","scopeId":"\(bot ? "fixture-bot" : "fixture-group")","prompt":"Check progress","rrule":"FREQ=DAILY;BYHOUR=9;BYMINUTE=0","timezone":"UTC","notificationPolicy":"all_runs","status":"\(status)","nextRunAt":\(status == "paused" ? "null" : "\"2026-10-03T09:00:00.000Z\""),"lastRunAt":"2026-10-01T09:00:00.000Z"}
        """
    }

    private static func projectJSON(_ state: State) -> String {
        let fields: [String: Any] = [
            "id": "fixture-project-schedule", "revision": state.projectRevision,
            "name": state.projectName, "scopeType": "project_thread",
            "scopeId": "fixture-project-thread", "prompt": state.projectPrompt, "rrule": state.projectRRule,
            "timezone": state.projectTimezone, "notificationPolicy": state.projectNotifications,
            "status": state.projectStatus, "nextRunAt": state.projectStatus == "paused" ? NSNull() : "2026-10-03T09:00:00.000Z",
            "lastRunAt": NSNull()
        ]
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func respond(json: String) { respond(status: 200, data: Data(json.utf8)) }
    private func respond(status: Int, data: Data = Data()) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
