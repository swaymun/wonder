import SwiftUI
import WonderPairing

/// One shared visual envelope keeps both controls aligned as text scales.
private struct ComposerStatusPill: ViewModifier {
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 36
    @Environment(\.wonderTheme) private var theme
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: height)
            .background(theme.surface, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// Small, value-only surface: opening the roster never replaces the parent route.
struct SubagentDock: View {
    let agents: [SubagentSummary]
    let available: Bool
    let avatarShape: ScienceAvatarShape
    let avatarPalette: ScienceAvatarPalette
    @Binding var isPresented: Bool
    let open: (SubagentSummary) -> Void

    private var active: [SubagentSummary] { agents.filter { !$0.isFinished } }
    private var completed: [SubagentSummary] { agents.filter(\.isFinished) }
    private var running: Int { agents.filter { ["active", "running", "inProgress"].contains($0.status) }.count }
    private var count: Int { available && running > 0 ? running : agents.count }
    private var label: String {
        return "\(count) \(count == 1 ? "agent" : "agents")" + (available && running > 0 ? " running" : "")
    }

    var body: some View {
        if !agents.isEmpty {
            Button { isPresented.toggle() } label: {
                HStack(spacing: 6) {
                    familyIcon
                    Text(count.formatted()).monospacedDigit().fixedSize()
                }
                    .modifier(ComposerStatusPill())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("subagent-status-pill")
            .accessibilityLabel(label)
            .accessibilityValue(isPresented ? "Expanded" : "Collapsed")
            .accessibilityHint("Show running and completed agent tasks")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        section("Running", agents: active)
                        section("Completed", agents: completed)
                    }.padding()
                }
                .frame(idealWidth: 320, maxWidth: 360, idealHeight: 280, maxHeight: 360)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    @ViewBuilder private func section(_ title: String, agents: [SubagentSummary]) -> some View {
        if !agents.isEmpty {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(agents) { agent in
                Button { open(agent) } label: {
                    HStack(spacing: 10) {
                        familyIcon
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agent.title).foregroundStyle(.primary)
                            Text(available ? agent.statusLabel : "Last known: " + agent.statusLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("subagent-roster:" + agent.id)
                .accessibilityLabel(agent.title + ", " + (available ? agent.statusLabel : "Last known: " + agent.statusLabel))
                .accessibilityHint("Open read-only agent task")
            }
        }
    }

    private var familyIcon: some View {
        ScienceAvatarGroup(shape: avatarShape, palette: avatarPalette)
            .accessibilityHidden(true)
    }
}

/// Project helpers are provider threads, not Wonder conversations. Keep their
/// roster and history read-only under the parent Project thread; the one action
/// is stopping a running Claude task. Codex helpers have names and keep their
/// roster; Claude tasks have only a description, so they are grouped into Running
/// and Completed and show a status glyph instead of an avatar.
struct ProjectSubagentDock: View {
    let agents: [ProjectSubagentSummary]
    let available: Bool
    let freshIDs: Set<String>
    let detail: String?
    let stoppingIDs: Set<String>
    let stopError: String?
    let hasOlder: Bool
    let loadingOlder: Bool
    @Binding var isPresented: Bool
    let loadOlder: () -> Void
    let stop: (ProjectSubagentSummary) -> Void
    let open: (ProjectSubagentSummary) -> Void
    @State private var confirmingStop: ProjectSubagentSummary?

    private var tasksOnly: Bool { !agents.isEmpty && !agents.contains(where: \.usesAvatar) }
    private var runningCount: Int { agents.runningCount }

    var body: some View {
        if !agents.isEmpty || hasOlder {
            Button { isPresented.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: tasksOnly ? (runningCount > 0 ? "circle.dotted" : "checkmark.circle") : "person.2")
                    if tasksOnly && available && runningCount > 0 {
                        Text("\(runningCount.formatted()) running").monospacedDigit()
                    } else {
                        Text(agents.count.formatted()).monospacedDigit()
                    }
                }
                .modifier(ComposerStatusPill())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("project-subagent-status-pill")
            .accessibilityLabel(pillLabel)
            .accessibilityValue(isPresented ? "Expanded" : "Collapsed")
            .accessibilityHint(tasksOnly ? "Show running and completed agent tasks" : "Show agent tasks in this Project thread")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        Text("Agent tasks").font(.headline).accessibilityAddTraits(.isHeader)
                        if tasksOnly {
                            let sections = agents.sectioned()
                            taskSection("Running", sections.running)
                            taskSection("Completed", sections.completed)
                        } else {
                            ForEach(agents) { agent in
                                rosterButton(agent)
                            }
                        }
                        if hasOlder {
                            Button(action: loadOlder) {
                                if loadingOlder { ProgressView() }
                                else { Text("Load older agent tasks") }
                            }
                            .disabled(!available || loadingOlder)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("project-subagent-roster-load-older")
                        }
                        if let stopError {
                            Text(stopError).font(.caption).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("project-subagent-stop-error")
                        }
                        if let detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("project-subagent-roster-detail")
                        }
                    }
                    .padding()
                }
                .frame(idealWidth: 320, maxWidth: 360, idealHeight: 280, maxHeight: 360)
                .presentationCompactAdaptation(.popover)
                .confirmationDialog("Stop this task?", isPresented: Binding(
                    get: { confirmingStop != nil }, set: { if !$0 { confirmingStop = nil } }),
                    titleVisibility: .visible, presenting: confirmingStop) { task in
                    Button("Stop task", role: .destructive) { stop(task) }
                        .accessibilityIdentifier("project-subagent-stop-confirm")
                    Button("Keep running", role: .cancel) {}
                } message: { task in
                    Text("Claude will stop \u{201C}\(task.title)\u{201D}. Work it already finished is kept.")
                }
            }
        }
    }

    private var pillLabel: String {
        let prefix = available ? "" : "Last known: "
        guard tasksOnly else {
            return prefix + "\(agents.count) Project \(agents.count == 1 ? "agent task" : "agent tasks")"
        }
        return prefix + (runningCount > 0
            ? "\(runningCount) agent \(runningCount == 1 ? "task" : "tasks") running"
            : "\(agents.count) agent \(agents.count == 1 ? "task" : "tasks")")
    }

    @ViewBuilder private func taskSection(_ title: String, _ tasks: [ProjectSubagentSummary]) -> some View {
        if !tasks.isEmpty {
            Text("\(title) \u{00B7} \(tasks.count.formatted())").font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary).padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("project-subagent-section:" + title.lowercased())
            // A task keeps its row identity within a state; moving to Completed is a new row.
            ForEach(tasks) { agent in taskRow(agent).id(agent.threadId + "|" + agent.status) }
        }
    }

    private func taskRow(_ agent: ProjectSubagentSummary) -> some View {
        let fresh = available && freshIDs.contains(agent.threadId)
        let stopping = stoppingIDs.contains(agent.threadId)
        let status = agent.isRunningElsewhere ? "Running on your Mac" : agent.statusLabel(available: fresh)
        return HStack(spacing: 8) {
            Button { open(agent) } label: {
                HStack(spacing: 10) {
                    Image(systemName: agent.statusSymbol)
                        .foregroundStyle(agent.isRunning ? Color.accentColor : .secondary)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.title).foregroundStyle(.primary).lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text([agent.kindLabel, status].compactMap { $0 }.joined(separator: " \u{00B7} "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("project-subagent-roster:" + agent.threadId)
            .accessibilityLabel(agent.title + ", " + (agent.kindLabel.map { $0 + ", " } ?? "") + status)
            .accessibilityHint("Open read-only agent task")
            if stopping {
                ProgressView().frame(width: 56, height: 44)
                    .accessibilityLabel("Stopping")
                    .accessibilityIdentifier("project-subagent-stopping:" + agent.threadId)
            } else if agent.isStoppable && fresh {
                Button("Stop", role: .destructive) { confirmingStop = agent }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.bordered)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Stop " + agent.title)
                    .accessibilityIdentifier("project-subagent-stop:" + agent.threadId)
            } else {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private func rosterButton(_ agent: ProjectSubagentSummary) -> some View {
        let fresh = available && freshIDs.contains(agent.threadId)
        return Button { open(agent) } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.title).foregroundStyle(.primary)
                    Text(agent.statusLabel(available: fresh)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("project-subagent-roster:" + agent.threadId)
        .accessibilityLabel(agent.title + ", " + agent.statusLabel(available: fresh))
        .accessibilityHint("Open read-only agent task")
    }
}

struct ProjectSubagentTranscriptView: View {
    @ObservedObject var model: ConnectionModel
    let parent: ChatSummary
    let child: ProjectSubagentSummary
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ConversationSnapshot?
    @State private var entries: [ChatFeedEntry] = []
    @State private var turns: [String: ReadTurn] = [:]
    @State private var lastActivityEntries: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var error: String?
    @State private var loading = true
    @State private var loadingOlder = false
    @State private var olderTask: Task<Void, Never>?
    @State private var loadToken = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let cursor = snapshot?.thread.nextCursor {
                        Button {
                            olderTask?.cancel()
                            olderTask = Task { await loadOlder(cursor: cursor) }
                        } label: {
                            if loadingOlder { ProgressView() }
                            else { Text("Load older activity") }
                        }
                        .disabled(loadingOlder)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("project-subagent-load-older")
                    }
                    ForEach(entries) { entry in
                        transcriptEntry(entry)
                    }
                    if !loading, entries.isEmpty, error == nil {
                        ContentUnavailableView("No activity yet", systemImage: "text.bubble",
                            description: Text("This agent task has no saved messages."))
                    }
                    if loading { ProgressView("Loading agent task…").frame(maxWidth: .infinity) }
                    if let error {
                        VStack(spacing: 8) {
                            Text(error).font(.footnote).foregroundStyle(.secondary)
                            Button("Try again") { Task { await loadInitial() } }
                                .accessibilityIdentifier("project-subagent-retry")
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
            .wonderPage()
            .accessibilityIdentifier("project-subagent-transcript")
            .navigationTitle(child.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("project-subagent-sheet-done")
                }
            }
        }
        .task(id: child.threadId + ":" + model.assignmentScope) { await loadInitial() }
        .onDisappear {
            loadToken = UUID()
            olderTask?.cancel()
        }
    }

    @ViewBuilder private func transcriptEntry(_ entry: ChatFeedEntry) -> some View {
        if entry.isActivity {
            ActivityGroupView(rows: entry.rows,
                turn: entry.rows.first?.turnId.flatMap { turns[$0] },
                isLatestSegmentForTurn: lastActivityEntries.contains(entry.id),
                isLatestActiveSegment: false,
                isProjectConversation: true,
                expanded: expanded.contains(entry.id)) {
                    if expanded.contains(entry.id) { expanded.remove(entry.id) }
                    else { expanded.insert(entry.id) }
                }
            if expanded.contains(entry.id) {
                ForEach(entry.rows, id: \.id) { row in
                    ActivityItemView(row: row, expanded: true) {}
                        .padding(.leading, 12)
                }
            }
        } else if let row = entry.rows.first {
            MessageRow(row: row)
                .accessibilityIdentifier("project-subagent-row:" + row.id)
        }
    }

    private func display(_ value: ConversationSnapshot) {
        snapshot = value
        let rows = value.rows(author: child.title)
        entries = ChatFeedEntry.grouping(rows)
        turns = Dictionary((value.thread.turns ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        lastActivityEntries = ChatFeedEntry.latestActivityEntryIDs(entries)
    }

    private func loadInitial() async {
        olderTask?.cancel()
        olderTask = nil
        let token = UUID()
        loadToken = token
        let requestedChild = child
        let scope = model.assignmentScope
        snapshot = nil
        entries = []
        turns = [:]
        lastActivityEntries = []
        expanded = []
        loading = true
        loadingOlder = false
        error = nil
        do {
            let response = try await model.projectSubagentTranscript(parent: parent, child: requestedChild)
            guard !Task.isCancelled, loadToken == token, child.threadId == requestedChild.threadId,
                  model.assignmentScope == scope else { return }
            display(response.snapshot)
        } catch {
            guard !Task.isCancelled, loadToken == token, child.threadId == requestedChild.threadId,
                  model.assignmentScope == scope else { return }
            self.error = "This agent task could not be opened. Refresh the Project thread and try again."
        }
        loading = false
    }

    private func loadOlder(cursor: String) async {
        guard let snapshot else { return }
        let token = loadToken
        let requestedChild = child
        let scope = model.assignmentScope
        loadingOlder = true
        error = nil
        do {
            let response = try await model.projectSubagentTranscript(parent: parent, child: requestedChild, cursor: cursor)
            guard !Task.isCancelled, loadToken == token, child.threadId == requestedChild.threadId,
                  model.assignmentScope == scope else { return }
            display(try snapshot.mergingOlder(response.snapshot))
        } catch {
            guard !Task.isCancelled, loadToken == token, child.threadId == requestedChild.threadId,
                  model.assignmentScope == scope else { return }
            self.error = "Older activity could not be loaded. Try again."
        }
        loadingOlder = false
    }
}

/// Opens the conversation's computer view from the composer's status row.
struct ComputerDock: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button { isPresented = true } label: {
            Label("Computer", systemImage: "desktopcomputer")
                .labelStyle(.iconOnly)
                .lineLimit(1)
                .modifier(ComposerStatusPill())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("computer-status-pill")
        .accessibilityLabel("View computer")
        .accessibilityHint("Show your Mac's screen")
    }
}

struct FilesDock: View {
    let isPresented: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Label("Files", systemImage: "folder")
                .labelStyle(.iconOnly)
                .modifier(ComposerStatusPill())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("conversation-files-pill")
        .accessibilityLabel("Files")
        .accessibilityValue(isPresented ? "Open" : "Closed")
        .accessibilityAddTraits(isPresented ? .isSelected : [])
        .accessibilityHint(isPresented ? "Return to the conversation" : "Browse this conversation's files and changes")
    }
}

/// Pending permission requests and questions. Like Files, it replaces the
/// conversation with their review and returns to it.
struct AttentionDock: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    let isPresented: Bool
    let toggle: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let pending = PendingAttention(model: model, chat: chat, now: context.date)
            if pending.count > 0 {
                Button(action: toggle) {
                    Label(pending.label, systemImage: pending.symbol)
                        .modifier(ComposerStatusPill())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("question-dock-open")
                .accessibilityValue(isPresented ? "Open" : "Closed")
                .accessibilityAddTraits(isPresented ? .isSelected : [])
                .accessibilityHint(isPresented ? "Return to the conversation" : "Answer what the agent is waiting for")
            }
        }
    }
}

/// Every saved edit in the conversation; opens and closes their review.
struct EditedFilesDock: View {
    let summary: ResponseEditedFiles
    let isPresented: Bool
    let toggle: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    private var additions: Int? {
        summary.files.allSatisfy { $0.additions != nil } ? summary.files.reduce(0) { $0 + ($1.additions ?? 0) } : nil
    }
    private var deletions: Int? {
        summary.files.allSatisfy { $0.deletions != nil } ? summary.files.reduce(0) { $0 + ($1.deletions ?? 0) } : nil
    }
    private var title: String {
        summary.files.count == 1 ? "Edited \(summary.files[0].name)" : "Edited \(summary.files.count) files"
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                // Large text keeps the composer row on screen; the label still reads the counts.
                if typeSize.isAccessibilitySize {
                } else if additions == nil && deletions == nil {
                    Text(summary.files.count.formatted())
                } else {
                    if let additions { Text("+\(additions)").foregroundStyle(DiffColors.added(scheme)) }
                    if let deletions { Text("−\(deletions)").foregroundStyle(DiffColors.removed(scheme)) }
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .modifier(ComposerStatusPill())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("response-edits-pill")
        .accessibilityLabel(([title] + [additions.map { "\($0) added lines" }, deletions.map { "\($0) removed lines" }].compactMap { $0 })
            .joined(separator: ", "))
        .accessibilityValue(isPresented ? "Open" : "Closed")
        .accessibilityAddTraits(isPresented ? .isSelected : [])
        .accessibilityHint(isPresented ? "Return to the conversation" : "Show the files edited in this chat")
    }
}

/// A compact status control. The sheet owns only presentation and draft state;
/// the connection model remains the source of truth for Goal mutations.
struct GoalDock: View {
    let goal: ConversationGoal
    let error: String?
    @Binding var isPresented: Bool
    let save: (String, Int?, Int?) async -> Bool
    let pause: () async -> Void
    let resume: () async -> Void
    let clear: () async -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 20

    private var statusLabel: String {
        switch goal.status {
        case "active": "active"
        case "paused": "paused"
        case "blocked": "needs attention"
        case "usageLimited": "usage limited"
        case "budgetLimited": "budget reached"
        case "complete": "complete"
        default: "updated"
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch goal.status {
        case "active":
            if reduceMotion { Image(systemName: "hourglass") }
            else { ProgressView().tint(.primary) }
        case "paused", "usageLimited", "budgetLimited": Image(systemName: "pause.fill")
        case "complete": Image(systemName: "checkmark")
        case "blocked": Image(systemName: "exclamationmark.circle")
        default: Image(systemName: "questionmark.circle")
        }
    }

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .frame(width: iconSize, height: iconSize)
                statusIcon
                    .frame(width: iconSize, height: iconSize)
            }
            .accessibilityHidden(true)
            .modifier(ComposerStatusPill())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("goal-status-pill")
        .accessibilityLabel("Goal \(statusLabel)")
        .accessibilityValue(isPresented ? "Expanded" : "Collapsed")
        .accessibilityHint("Show goal details and controls")
        .sheet(isPresented: $isPresented) {
            GoalDetailsSheet(goal: goal, error: error, save: save, pause: pause, resume: resume, clear: clear)
        }
    }
}

private struct GoalDetailsSheet: View {
    @Environment(\.wonderTheme) private var theme
    let goal: ConversationGoal
    let error: String?
    let save: (String, Int?, Int?) async -> Bool
    let pause: () async -> Void
    let resume: () async -> Void
    let clear: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var objectiveDraft = ""
    @State private var budgetDraft = ""
    @State private var timeBudgetDraft = ""
    @State private var originalTimeBudgetDraft = ""
    @State private var validationError: String?
    @State private var saving = false
    @State private var showingRemoveConfirmation = false
    @State private var detent: PresentationDetent = .medium

    private var statusTitle: String {
        switch goal.status {
        case "active": "Active"
        case "paused": "Paused"
        case "blocked": "Needs attention"
        case "usageLimited": "Usage limit reached"
        case "budgetLimited": "Budget reached"
        case "complete": "Complete"
        default: "Status unavailable"
        }
    }

    private var elapsedText: String {
        let seconds = goal.createdAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? goal.timeUsedSeconds
        return durationText(seconds)
    }

    private func durationText(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        let hours = minutes / 60
        return hours > 0 ? "\(hours) hr \(minutes % 60) min" : "\(minutes) min"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if editing {
                        Text("Objective").font(.headline)
                        TextEditor(text: $objectiveDraft)
                            .frame(minHeight: 100)
                            .padding(6)
                            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("goal-objective-editor")
                        TextField("Token budget (optional)", text: $budgetDraft)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("goal-budget-editor")
                        TextField("Time limit in minutes (optional)", text: $timeBudgetDraft)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("goal-time-budget-editor")
                        Text("Only active work counts toward the time limit.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let validationError {
                            Text(validationError).font(.footnote).foregroundStyle(.red)
                        }
                    } else {
                        Text(goal.objective)
                            .font(.body)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("goal-objective")
                        actionRow
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        metadataRow {
                            metadata(statusTitle, icon: statusSymbol, meaning: "Status, " + statusTitle, id: "status")
                            metadata(elapsedText, icon: "clock", meaning: "Elapsed, " + elapsedText, id: "elapsed")
                        }
                        metadataRow {
                        if goal.tokensUsed > 0 || goal.tokenBudget != nil {
                            let usage = goal.tokensUsed.formatted()
                            let value = goal.tokenBudget.map { usage + " / " + $0.formatted() + " tokens" } ?? usage + " tokens"
                            let meaning = "Tokens used, " + usage + (goal.tokenBudget.map { ". Token budget, " + $0.formatted() } ?? "")
                            metadata(value, icon: "number.circle", meaning: meaning, id: "tokens")
                        }
                        if let seconds = goal.timeBudgetSeconds {
                            let minutes = max(1, (seconds + 59) / 60)
                            metadata("\(max(0, goal.timeUsedSeconds) / 60) / \(minutes) min", icon: "timer",
                                     meaning: "Active time, " + durationText(goal.timeUsedSeconds) + ". Time limit, \(minutes) min",
                                     id: "time")
                        }
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("goal-error")
                    }

                    if saving { ProgressView("Updating goal…") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .wonderPage()
            .accessibilityIdentifier("goal-details-scroll")
            .navigationTitle("Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if editing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editing = false; validationError = nil }
                            .disabled(saving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveDraft() }
                            .disabled(saving || objectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("goal-save")
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("goal-done")
                    }
                }
            }
            .presentationDetents([.medium, .large], selection: $detent)
            .presentationDragIndicator(.visible)
            .confirmationDialog("Remove this goal?", isPresented: $showingRemoveConfirmation, titleVisibility: .visible) {
                Button("Remove goal", role: .destructive) {
                    perform(clear)
                }
            } message: {
                Text("This removes the goal from this conversation.")
            }
        }
    }

    private var statusSymbol: String {
        switch goal.status {
        case "active": "play.circle"
        case "paused", "usageLimited", "budgetLimited": "pause.circle"
        case "complete": "checkmark.circle"
        case "blocked": "exclamationmark.circle"
        default: "questionmark.circle"
        }
    }

    private func metadataRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) { content() }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 12) { content() }
        }
    }

    private func metadata(_ value: String, icon: String, meaning: String, id: String) -> some View {
        Label(value, systemImage: icon)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(meaning)
            .accessibilityIdentifier("goal-metadata-" + id)
    }

    private var actionRow: some View {
        HStack(spacing: 16) {
            Button {
                objectiveDraft = goal.objective
                budgetDraft = goal.tokenBudget.map(String.init) ?? ""
                timeBudgetDraft = goal.timeBudgetSeconds.map { String(($0 + 59) / 60) } ?? ""
                originalTimeBudgetDraft = timeBudgetDraft
                editing = true
                detent = .large
            } label: {
                Label("Edit goal", systemImage: "pencil").frame(minWidth: 48, minHeight: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("goal-edit")
            if goal.status == "active" {
                Button { perform(pause) } label: {
                    Label("Pause goal", systemImage: "pause.fill").frame(minWidth: 48, minHeight: 48)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("goal-pause")
            } else if goal.status != "complete" {
                Button { perform(resume) } label: {
                    Label("Resume goal", systemImage: "play.fill").frame(minWidth: 48, minHeight: 48)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("goal-resume")
            }
            Spacer(minLength: 0)
            Button(role: .destructive) { showingRemoveConfirmation = true } label: {
                Label("Remove goal", systemImage: "trash").frame(minWidth: 48, minHeight: 48)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.red)
            .accessibilityIdentifier("goal-remove")
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .disabled(saving)
    }

    private func saveDraft() {
        let objective = objectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else { validationError = "Enter a goal."; return }
        let budgetText = budgetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let budget: Int?
        if budgetText.isEmpty {
            budget = nil
        } else if let value = Int(budgetText), value > 0 {
            budget = value
        } else {
            validationError = "Enter a positive token budget."; return
        }
        let timeText = timeBudgetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeBudgetSeconds: Int?
        if timeText == originalTimeBudgetDraft {
            timeBudgetSeconds = goal.timeBudgetSeconds
        } else if timeText.isEmpty {
            timeBudgetSeconds = nil
        } else if let minutes = Int(timeText), minutes > 0, minutes <= Int.max / 60 {
            timeBudgetSeconds = minutes * 60
        } else {
            validationError = "Enter a positive time limit in minutes."; return
        }
        validationError = nil
        guard !saving else { return }
        saving = true
        Task { @MainActor in
            if await save(objective, budget, timeBudgetSeconds) { editing = false }
            saving = false
        }
    }

    private func perform(_ action: @escaping () async -> Void) {
        guard !saving else { return }
        saving = true
        Task { @MainActor in
            await action()
            saving = false
        }
    }
}

/// Pull requests the thread worked with, read through the GitHub CLI signed in
/// on the Mac. Shown only when there are some; tapping refreshes and lists them
/// with their state and checks, and a row opens the pull request in Safari.
struct PullRequestDock: View {
    let pullRequests: ThreadPullRequests
    let error: String?
    let refreshing: Bool
    @Binding var isPresented: Bool
    let refresh: () async -> Void
    @ScaledMetric(relativeTo: .subheadline) private var markSize: CGFloat = 17

    private var items: [ThreadPullRequests.PullRequest] { pullRequests.pullRequests }
    /// The checks that need attention most, among pull requests still open.
    private var checks: ThreadPullRequests.PullRequest.Checks.State {
        let open = items.filter { $0.state == .open || $0.state == .draft }.map(\.checks.state)
        if open.contains(.failing) { return .failing }
        if open.contains(.pending) { return .pending }
        return open.contains(.passing) ? .passing : .none
    }
    private var title: String { items.count == 1 ? "#\(items[0].number)" : items.count.formatted() }
    private var accessibilityText: String {
        let base = items.count == 1 ? "Pull request \(items[0].number), \(items[0].state.title)" : "\(items.count) pull requests"
        switch checks {
        case .failing: return base + ", checks failing"
        case .pending: return base + ", checks running"
        case .passing: return base + ", checks passed"
        case .none: return base
        }
    }

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 6) {
                Image("ConnectorGitHub")
                    .resizable().scaledToFit()
                    .frame(width: markSize, height: markSize)
                Text(title)
                if checks != .none { PullRequestChecksGlyph(state: checks) }
            }
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .modifier(ComposerStatusPill())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pull-requests-pill")
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(isPresented ? "Expanded" : "Collapsed")
        .accessibilityHint("Show this thread's pull requests")
        .sheet(isPresented: $isPresented) {
            PullRequestSheet(pullRequests: pullRequests, error: error, refreshing: refreshing, refresh: refresh)
        }
    }
}

private struct PullRequestChecksGlyph: View {
    let state: ThreadPullRequests.PullRequest.Checks.State
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        switch state {
        case .failing: Image(systemName: "xmark.circle.fill").foregroundStyle(DiffColors.removed(scheme))
        case .pending: Image(systemName: "clock.fill").foregroundStyle(.orange)
        case .passing: Image(systemName: "checkmark.circle.fill").foregroundStyle(DiffColors.added(scheme))
        case .none: EmptyView()
        }
    }
}

private struct PullRequestSheet: View {
    let pullRequests: ThreadPullRequests
    let error: String?
    let refreshing: Bool
    let refresh: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("pull-requests-error")
                        Button("Try again") { Task { await refresh() } }
                            .disabled(refreshing)
                            .accessibilityIdentifier("pull-requests-retry")
                    }
                }
                Section {
                    ForEach(pullRequests.pullRequests) { pr in
                        Button { openURL(pr.url) } label: { PullRequestRow(pr: pr) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("pull-request-row:\(pr.number)")
                            .accessibilityHint("Opens in Safari")
                    }
                } footer: {
                    Text("From the GitHub CLI signed in on your Mac.")
                }
            }
            .wonderGroupedStyle()
            .refreshable { await refresh() }
            // Opening asks for current states; the Mac answers from its cache
            // when it read GitHub moments ago.
            .task { await refresh() }
            .accessibilityIdentifier("pull-requests-list")
            .navigationTitle("Pull Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("pull-requests-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct PullRequestRow: View {
    let pr: ThreadPullRequests.PullRequest
    @Environment(\.colorScheme) private var scheme

    private var stateSymbol: String {
        switch pr.state {
        case .open: "arrow.triangle.pull"
        case .draft: "circle.dashed"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        case .unknown: "questionmark.circle"
        }
    }
    private var stateColor: Color {
        switch pr.state {
        case .open: DiffColors.added(scheme)
        case .merged: .purple
        case .closed: DiffColors.removed(scheme)
        case .draft, .unknown: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: stateSymbol).foregroundStyle(stateColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(pr.title).font(.body).foregroundStyle(.primary).lineLimit(3)
                Text("\(pr.repository) #\(pr.number) · \(pr.state.title)")
                    .font(.caption).foregroundStyle(.secondary)
                if let summary = pr.checks.summary {
                    HStack(spacing: 4) {
                        PullRequestChecksGlyph(state: pr.checks.state)
                        Text(summary)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
