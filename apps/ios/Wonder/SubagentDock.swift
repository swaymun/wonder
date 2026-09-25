import SwiftUI
import WonderPairing

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
    private var label: String {
        let running = agents.filter { ["active", "running", "inProgress"].contains($0.status) }.count
        let count = available && running > 0 ? running : agents.count
        return "\(count) \(count == 1 ? "agent" : "agents")" + (available && running > 0 ? " running" : "")
    }

    var body: some View {
        if !agents.isEmpty {
            Button { isPresented.toggle() } label: {
                HStack(spacing: 6) {
                    familyIcon
                    Text(label).fixedSize(horizontal: false, vertical: true)
                }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                    .frame(minHeight: 44, alignment: .bottom)
                    .contentShape(Rectangle())
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

    private var statusLabel: String {
        switch goal.status {
        case "active": "active"
        case "paused": "paused"
        case "blocked": "blocked"
        case "usageLimited": "usage limited"
        case "budgetLimited": "budget reached"
        case "complete": "complete"
        default: "updated"
        }
    }

    var body: some View {
        Button { isPresented = true } label: {
            Label("1 goal \(statusLabel)", systemImage: "scope")
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                .frame(minHeight: 44, alignment: .bottom)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("goal-status-pill")
        .accessibilityLabel("1 goal \(statusLabel)")
        .accessibilityValue(isPresented ? "Expanded" : "Collapsed")
        .accessibilityHint("Show goal details and controls")
        .sheet(isPresented: $isPresented) {
            GoalDetailsSheet(goal: goal, error: error, save: save, pause: pause, resume: resume, clear: clear)
        }
    }
}

private struct GoalDetailsSheet: View {
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
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
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
                        HStack {
                            Button("Cancel") { editing = false; validationError = nil }
                            Spacer()
                            Button("Save") { saveDraft() }
                                .disabled(saving || objectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("goal-save")
                        }
                    } else {
                        Text(goal.objective)
                            .font(.body)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("goal-objective")
                        Button("Edit goal", systemImage: "pencil") {
                            objectiveDraft = goal.objective
                            budgetDraft = goal.tokenBudget.map(String.init) ?? ""
                            timeBudgetDraft = goal.timeBudgetSeconds.map { String(($0 + 59) / 60) } ?? ""
                            originalTimeBudgetDraft = timeBudgetDraft
                            editing = true
                            detent = .large
                        }
                        .disabled(saving)
                        .accessibilityIdentifier("goal-edit")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Status", value: statusTitle)
                        LabeledContent("Elapsed", value: elapsedText)
                        if goal.timeBudgetSeconds != nil {
                            LabeledContent("Active time", value: durationText(goal.timeUsedSeconds))
                        }
                        if goal.tokensUsed > 0 || goal.tokenBudget != nil {
                            LabeledContent("Tokens used", value: goal.tokensUsed.formatted())
                        }
                        if let budget = goal.tokenBudget {
                            LabeledContent("Token budget", value: budget.formatted())
                        }
                        if let seconds = goal.timeBudgetSeconds {
                            let minutes = max(1, (seconds + 59) / 60)
                            LabeledContent("Time limit", value: "\(minutes) min")
                        }
                    }
                    .font(.subheadline)

                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("goal-error")
                    }

                    if !editing {
                        if goal.status == "active" {
                            Button("Pause goal", systemImage: "pause.fill") { perform(pause) }
                                .disabled(saving)
                                .accessibilityIdentifier("goal-pause")
                        } else if goal.status != "complete" {
                            Button("Resume goal", systemImage: "play.fill") { perform(resume) }
                                .disabled(saving)
                                .accessibilityIdentifier("goal-resume")
                        }
                        Button("Remove goal", systemImage: "trash", role: .destructive) {
                            showingRemoveConfirmation = true
                        }
                        .disabled(saving)
                        .accessibilityIdentifier("goal-remove")
                    }
                    if saving { ProgressView("Updating goal…") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .accessibilityIdentifier("goal-details-scroll")
            .navigationTitle("Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.accessibilityIdentifier("goal-done")
            } }
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
