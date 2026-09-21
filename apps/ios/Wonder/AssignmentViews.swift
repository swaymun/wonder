import SwiftUI
import WonderPairing

private struct AssignmentProjects: Decodable, Sendable {
    struct Project: Decodable, Identifiable, Sendable { let botId: String; let projectName: String; let baseRevision: String; var id: String { botId } }
    let projects: [Project]
}
private struct AssignmentPage: Decodable, Sendable { let assignments: [ProjectAssignment] }

extension ConnectionModel {
    var assignmentScope: String {
        guard let connection else { return "preview" }
        return connection.credential.hostInstallationId + ":" + connection.credential.deviceId
    }
    func assignmentKey(_ suffix: String) -> String { "assignments." + (connection?.credential.deviceId ?? "preview") + "." + suffix }
}

private func assignmentError(_ error: Error) -> String {
    if case PairingFailure.response(let status) = error {
        switch status {
        case 400, 422: return "Check the assignment and starting revision. The Bot must have access to this project."
        case 401, 403: return "Access has ended. Reconnect to your Mac in Settings."
        case 404: return "This assignment is no longer available. Refresh the Group."
        case 409: return "The work or project has changed. Check status and review the current revision before continuing."
        default: break
        }
    }
    return "Your Mac could not confirm this action. Your saved request can be checked after reconnecting."
}

struct AssignmentListView: View {
    @ObservedObject var model: ConnectionModel
    let group: GroupRead
    @State private var assignments: [ProjectAssignment] = []
    @State private var failure: String?
    @State private var loading = false
    @State private var creating = false
    @Environment(\.scenePhase) private var scenePhase
    private var cacheKey: String { model.assignmentKey("list." + group.id) }
    var body: some View {
        List {
            ForEach(assignments) { assignment in
                NavigationLink {
                    AssignmentDetailView(model: model, group: group, initial: assignment)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(assignment.title).font(.headline)
                        Text("\(botName(assignment.botId)) · \(assignment.statusLabel)").font(.subheadline).foregroundStyle(.secondary)
                        if let summary = assignment.summary { Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                    }.padding(.vertical, 3).accessibilityElement(children: .combine)
                }
            }
            if loading && assignments.isEmpty { ProgressView("Loading assignments…") }
            if let failure { FailureDetails("Assignments not refreshed", message: failure); Button("Check status") { Task { await load() } } }
            if assignments.isEmpty && !loading && failure == nil { Text("No assignments yet").foregroundStyle(.secondary) }
        }
        .navigationTitle("Assignments")
        .toolbar { Button("New assignment", systemImage: "plus") { creating = true }.keyboardShortcut("n", modifiers: .command).disabled(model.accessEnded || (model.connection == nil && !model.previewMode)) }
        .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) { AssignmentEditor(model: model, group: group, assignments: assignments) }
        .task(id: model.assignmentScope) {
            assignments = []
            if let encoded = model.managementDrafts?.load(cacheKey)?.values["records"], let data = Data(base64Encoded: encoded) {
                assignments = (try? JSONDecoder().decode([ProjectAssignment].self, from: data)) ?? []
            }
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if scenePhase == .active { await load() }
            }
        }
        .refreshable { await load() }
        .onChange(of: model.accessEnded) { _, ended in if ended { assignments = []; failure = "Access has ended. Reconnect in Settings." } }
    }
    private func botName(_ id: String) -> String { group.members?.first(where: { $0.botId == id })?.botName ?? model.managedBots.first(where: { $0.id == id })?.name ?? "Bot" }
    private func load() async {
        guard !loading else { return }
        if model.previewMode { assignments = AssignmentPreview.assignments; return }
        guard !model.accessEnded else { return }
        loading = true; defer { loading = false }
        let scope = model.assignmentScope
        do {
            let page: AssignmentPage = try await model.manage("/api/v1/groups/" + ConnectionModel.escape(group.id) + "/assignments")
            guard scope == model.assignmentScope, !model.accessEnded else { return }
            assignments = page.assignments; failure = nil
            var cache = ManagementDraft()
            cache.values["records"] = try JSONEncoder().encode(assignments).base64EncodedString()
            try model.managementDrafts?.save(cache, key: cacheKey)
        } catch { if scope == model.assignmentScope { failure = assignmentError(error) } }
    }
}

struct AssignmentEditor: View {
    @ObservedObject var model: ConnectionModel
    let group: GroupRead
    let assignments: [ProjectAssignment]
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ManagementDraft()
    @State private var loaded = false
    @State private var projects: [AssignmentProjects.Project] = []
    @State private var busy = false
    @State private var failure: String?
    private var key: String { model.assignmentKey("create." + group.id) }
    private var frozen: Bool { draft.values["_body"] != nil }
    private var valid: Bool {
        !draft.values["title", default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.values["instruction", default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.values["botId", default: ""].isEmpty &&
        draft.values["title", default: ""].utf8.count <= 160 &&
        draft.values["instruction", default: ""].utf8.count <= 32 * 1024 &&
        draft.values["dependencies", default: ""].split(separator: "\n").count <= 16 &&
        draft.values["baseRevision", default: ""].range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil
    }
    private func field(_ key: String) -> Binding<String> {
        Binding(get: { draft.values[key, default: ""] }, set: { draft.values[key] = $0; persist() })
    }
    private func persist() {
        do { try model.managementDrafts?.save(draft, key: key) }
        catch { failure = "This draft could not be saved on this device." }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: field("title"))
                    Picker("Bot", selection: field("botId")) {
                        Text("Choose Bot").tag("")
                        ForEach(projects) { project in Text(group.members?.first(where: { $0.botId == project.botId })?.botName ?? project.projectName).tag(project.botId) }
                    }
                    .onChange(of: draft.values["botId"]) { _, id in
                        guard !frozen else { return }
                        draft.values["baseRevision"] = projects.first(where: { $0.botId == id })?.baseRevision
                        persist()
                    }
                    TextField("Instructions, owned files and checks", text: field("instruction"), axis: .vertical).lineLimit(5...12)
                }.disabled(busy || frozen)
                Section {
                    if let project = projects.first(where: { $0.botId == draft.values["botId"] }) { LabeledContent("Project", value: project.projectName) }
                    if let revision = draft.values["baseRevision"], !revision.isEmpty {
                        DisclosureGroup("Starting revision") { Text(revision).font(.footnote.monospaced()).textSelection(.enabled) }
                    }
                    if !frozen {
                        Button("Refresh projects") { Task { await loadProjects() } }.disabled(busy)
                        if projects.isEmpty && !busy { Text("Add a specialist Bot with a writable project to this Group on your Mac.").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                if !assignments.isEmpty {
                    Section("Wait for") {
                        ForEach(assignments) { assignment in
                            Toggle(assignment.title, isOn: Binding(get: {
                                draft.values["dependencies", default: ""].split(separator: "\n").contains(Substring(assignment.id))
                            }, set: { selected in
                                var ids = Set(draft.values["dependencies", default: ""].split(separator: "\n").map(String.init))
                                if selected { ids.insert(assignment.id) } else { ids.remove(assignment.id) }
                                draft.values["dependencies"] = ids.sorted().joined(separator: "\n"); persist()
                            }))
                        }
                    }.disabled(busy || frozen)
                }
                if frozen { Section {
                    Text("Checking this saved assignment will reuse the original request.").font(.footnote).foregroundStyle(.secondary)
                    if draft.values["_rejected"] == "true" {
                        Button("Edit assignment") {
                            draft.requestId = UUID().uuidString
                            draft.values["_body"] = nil; draft.values["_rejected"] = nil; persist()
                        }
                    }
                } }
                if let failure { Section { FailureDetails(message: failure) } }
                if busy { ProgressView("Saving assignment…") }
            }
            .navigationTitle("New assignment").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button(frozen ? "Check assignment" : "Assign") { Task { await save() } }.disabled(busy || !valid || model.accessEnded || model.previewMode) }
            }
            .interactiveDismissDisabled(busy)
            .task {
                guard !loaded else { return }; loaded = true
                draft = model.managementDrafts?.load(key) ?? ManagementDraft()
                await loadProjects()
            }
        }
    }
    private func loadProjects() async {
        if model.previewMode {
            projects = [AssignmentProjects.Project(botId: "ada", projectName: "Wonder", baseRevision: String(repeating: "a", count: 40))]
            return
        }
        busy = true; defer { busy = false }
        do {
            let page: AssignmentProjects = try await model.manage("/api/v1/groups/" + ConnectionModel.escape(group.id) + "/assignment-projects")
            projects = page.projects
            if !frozen {
                draft.values["baseRevision"] = projects.first(where: { $0.botId == draft.values["botId"] })?.baseRevision
                persist()
            }
            failure = nil
        } catch { failure = assignmentError(error) }
    }
    private func save() async {
        guard let store = model.managementDrafts else { return }
        let scope = model.assignmentScope
        busy = true; failure = nil; defer { busy = false }
        do {
            let body = try AssignmentIntent.creationBody(&draft)
            try store.save(draft, key: key)
            let _: ProjectAssignment = try await model.manage("/api/v1/groups/" + ConnectionModel.escape(group.id) + "/assignments", method: "POST", body: body)
            guard scope == model.assignmentScope, !model.accessEnded else { return }
            store.remove(key); dismiss()
        } catch {
            guard scope == model.assignmentScope, !model.accessEnded else { return }
            failure = assignmentError(error)
            if case PairingFailure.response(let status) = error, [400, 409, 422].contains(status) {
                // Only allow editing after the Mac confirms that this identity has no assignment.
                do { let _: ProjectAssignment = try await model.manage("/api/v1/assignments/" + ConnectionModel.escape(draft.requestId)) }
                catch PairingFailure.response(404) {
                    guard scope == model.assignmentScope, !model.accessEnded else { return }
                    draft.values["_rejected"] = "true"; persist()
                }
                catch { }
            }
        }
    }
}

struct AssignmentDetailView: View {
    @ObservedObject var model: ConnectionModel
    let group: GroupRead
    @State private var assignment: ProjectAssignment
    @State private var intent = ManagementDraft()
    @State private var validation = ""
    @State private var failure: String?
    @State private var busy = false
    @State private var inspected = false
    @State private var integrating = false
    @Environment(\.scenePhase) private var scenePhase
    init(model: ConnectionModel, group: GroupRead, initial: ProjectAssignment) {
        self.model = model; self.group = group; _assignment = State(initialValue: initial)
    }
    private var key: String { model.assignmentKey("action." + assignment.id) }
    private var pendingAction: String? { intent.values["_action"] }
    private var actionsDisabled: Bool { busy || model.accessEnded || model.previewMode }
    var body: some View {
        List {
            Section {
                Text(assignment.title).font(.headline)
                LabeledContent("Status", value: assignment.statusLabel)
                LabeledContent("Project", value: assignment.projectName)
                if let summary = assignment.summary { Text(summary).textSelection(.enabled) }
            }
            if assignment.state == "awaiting_input" { Section { Text("Return to the conversation to answer the Bot’s question.").foregroundStyle(.secondary) } }
            Section {
                DisclosureGroup("Assignment") { Text(assignment.instruction).textSelection(.enabled) }
                if let dependencies = assignment.dependencyIds, !dependencies.isEmpty {
                    LabeledContent("Prerequisites", value: String(dependencies.count))
                }
            }
            if assignment.resultRevision != nil {
                Section("Changes") {
                    if let diff = assignment.diff {
                        if diff.isEmpty { Text("No changed files in this revision.").foregroundStyle(.secondary) }
                        else { ScrollView(.horizontal) { Text(diff).font(.footnote.monospaced()).textSelection(.enabled).fixedSize(horizontal: true, vertical: false).accessibilityLabel("Change diff. " + diff) } }
                    } else { Text("Changes have not loaded. Check status to review them.").foregroundStyle(.secondary) }
                    LabeledContent("Result revision") { Text(assignment.resultRevision ?? "Unavailable").font(.caption.monospaced()).textSelection(.enabled) }
                    if let head = assignment.repositoryHead { LabeledContent("Project revision") { Text(head).font(.caption.monospaced()).textSelection(.enabled) } }
                }
                Section("Checks and review") {
                    if let validation = assignment.validation, !validation.isEmpty { Text(validation).textSelection(.enabled) }
                    else { Text("No owner verification recorded.").foregroundStyle(.secondary) }
                    if assignment.state == "submitted", pendingAction == nil {
                        TextField("Checks you verified and review notes", text: $validation, axis: .vertical).lineLimit(3...8)
                            .onChange(of: validation) { _, value in intent.values["notes"] = value; persist() }
                        Button("Mark reviewed") { Task { await act("review") } }
                            .disabled(actionsDisabled || !inspected || assignment.diff == nil || validation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if assignment.state == "reviewed", pendingAction == nil {
                        Button("Integrate changes") { integrating = true }
                            .disabled(actionsDisabled || !inspected || assignment.repositoryHead == nil || assignment.diff == nil)
                    }
                }
            }
            Section {
                Button("Check status") { Task { await load() } }.disabled(busy)
                if let action = pendingAction {
                    Text("Your \(action == "integrate" ? "integration" : action) request is saved. Check status or retry the same request.").font(.footnote).foregroundStyle(.secondary)
                    Button("Retry saved request") { Task { await act(action) } }.disabled(actionsDisabled)
                    if action == "integrate", intent.values["_rejected"] == "true" {
                        Button("Review current changes") { Task { await reconsiderIntegration() } }.disabled(actionsDisabled)
                    }
                } else if assignment.canCancel == true {
                    Button("Cancel assignment", role: .destructive) { Task { await act("cancel") } }.disabled(actionsDisabled)
                }
                if busy { ProgressView() }
                if let failure { FailureDetails(message: failure) }
            }
        }
        .navigationTitle("Assignment").navigationBarTitleDisplayMode(.inline)
        .task(id: model.assignmentScope) {
            intent = model.managementDrafts?.load(key) ?? ManagementDraft(); validation = intent.values["notes", default: ""]
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                // Do not silently replace the revision or patch while the owner reviews it.
                if scenePhase == .active && !["submitted", "reviewed", "integrated"].contains(assignment.state) { await load() }
            }
        }
        .confirmationDialog("Integrate this reviewed revision?", isPresented: $integrating, titleVisibility: .visible) {
            Button("Integrate changes") { Task { await act("integrate") } }
        } message: { Text("The project will advance to the displayed result revision only if its current revision is unchanged.") }
    }
    private func persist() {
        do { try model.managementDrafts?.save(intent, key: key) }
        catch { failure = "This review could not be saved on this device." }
    }
    private func reconcile() {
        guard let action = pendingAction, let encoded = intent.values["_body"], let data = Data(base64Encoded: encoded), let values = try? JSONDecoder().decode([String:String].self, from: data) else { return }
        let revisionMatches = values["resultRevision"] == assignment.resultRevision
        let confirmed = action == "cancel" ? assignment.state == "cancelled" : revisionMatches && (action == "review" ? ["reviewed", "integrating", "integrated"].contains(assignment.state) : assignment.state == "integrated")
        if confirmed { model.managementDrafts?.remove(key); intent = ManagementDraft() }
    }
    private func load() async {
        guard !busy else { return }
        if model.previewMode { inspected = true; return }
        busy = true; defer { busy = false }
        let scope = model.assignmentScope
        do {
            let next: ProjectAssignment = try await model.manage("/api/v1/assignments/" + ConnectionModel.escape(assignment.id))
            guard scope == model.assignmentScope, !model.accessEnded else { return }
            if assignment.resultRevision != next.resultRevision {
                validation = ""; intent.values["notes"] = nil
                // A review is scoped to a result: an authoritative different result
                // cannot inherit the earlier review, including its saved retry.
                if pendingAction == "review" { intent = ManagementDraft(); model.managementDrafts?.remove(key) }
                else { persist() }
            }
            assignment = next; inspected = true; failure = nil; reconcile()
        } catch { failure = assignmentError(error); inspected = false }
    }
    private func act(_ action: String) async {
        guard !busy, let store = model.managementDrafts else { return }
        busy = true; failure = nil; defer { busy = false }
        let scope = model.assignmentScope
        do {
            let body = try AssignmentIntent.actionBody(&intent, action: action, revision: action == "cancel" ? nil : assignment.resultRevision, expectedHead: action == "integrate" ? assignment.repositoryHead : nil, validation: action == "review" ? validation : nil)
            try store.save(intent, key: key)
            let next: ProjectAssignment = try await model.manage("/api/v1/assignments/" + ConnectionModel.escape(assignment.id) + "/" + action, method: "POST", body: body)
            guard scope == model.assignmentScope, !model.accessEnded else { return }
            assignment = next; inspected = false; reconcile()
        } catch {
            guard scope == model.assignmentScope, !model.accessEnded else { return }
            failure = assignmentError(error)
            if action == "integrate", case PairingFailure.response(409) = error {
                intent.values["_rejected"] = "true"; persist()
            }
        }
    }
    private func reconsiderIntegration() async {
        guard !busy, !model.accessEnded, !model.previewMode else { return }
        let scope = model.assignmentScope
        busy = true; defer { busy = false }
        do {
            let next: ProjectAssignment = try await model.manage("/api/v1/assignments/" + ConnectionModel.escape(assignment.id))
            guard scope == model.assignmentScope, !model.accessEnded else { return }
            assignment = next; inspected = true; reconcile()
            guard AssignmentIntent.canReconsiderIntegration(intent, authoritativeState: next.state) else {
                if pendingAction != nil { failure = "The earlier integration is not confirmed. Check status or retry the saved request." }
                return
            }
            model.managementDrafts?.remove(key)
            intent = ManagementDraft(); validation = ""
            failure = next.repositoryHead != next.baseRevision
                ? "The project has changed. Rebase the assignment on its current revision and review it again before integrating."
                : nil
        } catch {
            guard scope == model.assignmentScope, !model.accessEnded else { return }
            failure = assignmentError(error)
        }
    }
}

private enum AssignmentPreview {
    static var assignments: [ProjectAssignment] {
        #if DEBUG && targetEnvironment(simulator)
        let fixture = #"[{"id":"fixture-assignment","groupId":"preview-group","botId":"ada","title":"Clarify setup copy","projectName":"Wonder","instruction":"Update the connected-app footer. Keep authorization unchanged. Run the focused tests and commit the result.","state":"submitted","baseRevision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","resultRevision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repositoryHead":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","summary":"Updated the connected-app footer.","dependencyIds":[],"createdAt":"2026-09-09T18:00:00Z","updatedAt":"2026-09-09T18:01:00Z","canCancel":false,"diff":"diff --git a/Setup.swift b/Setup.swift\n--- a/Setup.swift\n+++ b/Setup.swift\n@@ -1 +1 @@\n-Text(\"Connected apps from Codex\")\n+Text(\"Based on Codex connections\")"}]"#
        return (try? JSONDecoder().decode([ProjectAssignment].self, from: Data(fixture.utf8))) ?? []
        #else
        return []
        #endif
    }
}
