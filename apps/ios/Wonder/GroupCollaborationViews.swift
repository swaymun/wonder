import SwiftUI
import WonderPairing

private struct GroupEmptyReply: Decodable {}

private struct SuggestedBot: Codable, Identifiable {
    var id = UUID()
    var name: String
    var purpose: String
    var instructions: String
    private enum CodingKeys: String, CodingKey { case name, purpose, instructions }
}
private struct TeamProposal: Codable {
    var name: String
    var purpose: String
    var memberBotIds: [String]
    var newBots: [SuggestedBot]
    /// Wonder setup's one-sentence note; never part of the created team.
    var summary: String?
    private enum CodingKeys: String, CodingKey { case name, purpose, memberBotIds, newBots, summary }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name); try container.encode(purpose, forKey: .purpose)
        try container.encode(memberBotIds, forKey: .memberBotIds); try container.encode(newBots, forKey: .newBots)
    }
}
struct GroupCreationView: View {
    @ObservedObject var model: ConnectionModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var description = ""
    @State private var describing = false
    @State private var proposal: TeamProposal?
    @State private var busy = false
    @State private var failure: String?
    @State private var scope: String?
    @State private var request = ManagementDraft()
    @State private var resetRequested = false
    private var bots: [ManagedBot] { model.managedBots.filter { !$0.isArchived } }
    var body: some View {
        NavigationStack {
            Form {
                if let proposal {
                    Section("Your group") {
                        TextField("Name", text: Binding(get: { self.proposal?.name ?? "" }, set: { self.proposal?.name = $0 }))
                        TextField("Purpose", text: Binding(get: { self.proposal?.purpose ?? "" }, set: { self.proposal?.purpose = $0 }), axis: .vertical)
                    }
                    if !proposal.newBots.isEmpty {
                        Section("New Bots") {
                            ForEach(proposal.newBots) { bot in
                                NavigationLink {
                                    Form {
                                        TextField("Name", text: proposed(bot.id, \.name))
                                        TextField("Purpose", text: proposed(bot.id, \.purpose), axis: .vertical)
                                        TextField("Instructions", text: proposed(bot.id, \.instructions), axis: .vertical)
                                        Button("Remove Bot", role: .destructive) { self.proposal?.newBots.removeAll { $0.id == bot.id } }
                                    }.navigationTitle(bot.name)
                                } label: { Label(bot.name, systemImage: "plus.circle") }
                            }
                        }
                    }
                }
                Section(proposal == nil ? "Choose Bots" : "Existing Bots") {
                    ForEach(bots) { bot in
                        Toggle(isOn: Binding(get: { selected.contains(bot.id) }, set: { if $0 { selected.insert(bot.id) } else { selected.remove(bot.id) } })) {
                            HStack { ChatAvatar(name: bot.name, identity: bot.id, hexColor: bot.avatarColor, avatarShape: bot.avatarShape, avatarPalette: bot.avatarPalette); Text(bot.name) }
                        }
                    }
                    if bots.isEmpty { Text("Describe your group to create its first Bots.").foregroundStyle(.secondary) }
                }
                if proposal == nil {
                    Section {
                        if describing {
                            TextField("What should this group help with?", text: $description, axis: .vertical).lineLimit(3...8)
                            Button("Suggest a team") { Task { await suggest() } }.disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        } else { Button("Describe your group", systemImage: "text.bubble") { describing = true } }
                    }
                }
                if busy { ProgressView(proposal == nil && describing ? "Preparing your team…" : "Creating group…") }
                if let failure { Section { Text(failure).foregroundStyle(.secondary) } }
            }
            .disabled(busy || request.values["payload"] != nil || model.previewMode || (scope != nil && scope != model.assignmentScope) || model.accessEnded)
            .navigationTitle(proposal == nil ? "New Group Chat" : "Review your team")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.values["payload"] == nil ? "Create" : "Retry") { Task { await create() } }
                        .disabled(busy || model.previewMode || model.accessEnded || (selected.isEmpty && (proposal?.newBots.isEmpty ?? true)))
                }
                if request.values["payload"] != nil, failure != nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Start a new draft") { resetRequested = true }
                            .accessibilityIdentifier("group-new-draft-action")
                            .disabled(busy)
                    }
                }
            }
            .confirmationDialog("Start a new group draft?", isPresented: $resetRequested, titleVisibility: .visible) {
                Button("Start a new draft") {
                    guard scope == model.assignmentScope else { return }
                    model.managementDrafts?.remove("group.new")
                    request = ManagementDraft()
                    failure = nil
                }
                .accessibilityIdentifier("group-start-new-draft")
            } message: {
                Text("The previous request may have created a group. Check Chats before starting again.")
            }
            .task {
                scope = model.assignmentScope
                request = model.managementDrafts?.load("group.new") ?? ManagementDraft()
                if let payload = request.values["payload"], let data = payload.data(using: .utf8),
                   let saved = try? JSONDecoder().decode(TeamProposal.self, from: data) {
                    proposal = saved; selected = Set(saved.memberBotIds)
                }
            }
        }
    }
    private func proposed(_ id: UUID, _ key: WritableKeyPath<SuggestedBot, String>) -> Binding<String> {
        Binding(get: { self.proposal?.newBots.first { $0.id == id }?[keyPath: key] ?? "" },
                set: { value in guard let index = self.proposal?.newBots.firstIndex(where: { $0.id == id }) else { return }; self.proposal?.newBots[index][keyPath: key] = value })
    }
    private func settings(_ purpose: ModelDefaultPurpose, options: BotOptions) throws -> [String: String] {
        try purpose.load().creationValues(options: options)
    }
    private func suggest() async {
        guard !busy, let saved = model.connection, scope == model.assignmentScope, !model.accessEnded else { return }
        busy = true; defer { busy = false }
        do {
            let options: BotOptions = try await model.manage("/api/v1/bot-options")
            guard scope == model.assignmentScope, !Task.isCancelled, !model.accessEnded else { return }
            guard options.groupCollaboration == true else { failure = "Update Wonder on this computer to create conversational groups."; return }
            let payload: [String: Any] = ["description": description, "settings": try settings(.groupCreation, options: options)]
            let result: TeamProposal = try await model.api.request("/api/v1/group-chats/propose", origin: saved.origin, body: JSONSerialization.data(withJSONObject: payload), credential: saved.credential)
            guard scope == model.assignmentScope, !Task.isCancelled, !model.accessEnded else { return }
            proposal = result; selected = Set(result.memberBotIds); failure = nil
        } catch { failure = managementError(error) }
    }
    private func create() async {
        guard !busy, let saved = model.connection, scope == model.assignmentScope, !model.accessEnded else { return }
        busy = true; defer { busy = false }
        do {
            let data: Data
            if let frozen = request.values["payload"] { data = Data(frozen.utf8) }
            else {
                let options: BotOptions = try await model.manage("/api/v1/bot-options")
                guard scope == model.assignmentScope, !Task.isCancelled, !model.accessEnded else { return }
                guard options.groupCollaboration == true else { failure = "Update Wonder on this computer to create conversational groups."; return }
                let team = TeamProposal(name: proposal?.name ?? "New Group Chat", purpose: proposal?.purpose ?? "", memberBotIds: selected.sorted(), newBots: proposal?.newBots ?? [])
                var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(team)) as! [String: Any]
                payload["clientRequestId"] = request.requestId
                let routing = try settings(.groupParticipation, options: options)
                payload["routing"] = routing
                payload["newBotDefaults"] = team.newBots.isEmpty ? routing : try settings(.newBots, options: options)
                data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
                request.values["payload"] = String(decoding: data, as: UTF8.self)
                try model.managementDrafts?.save(request, key: "group.new")
            }
            let group: GroupRead = try await model.api.request("/api/v1/group-chats/new", origin: saved.origin, body: data, credential: saved.credential)
            guard scope == model.assignmentScope, !model.accessEnded else { return }
            model.managementDrafts?.remove("group.new")
            await model.refreshChatList()
            guard scope == model.assignmentScope, !model.accessEnded else { return }
            model.selectedChat = model.chats.first { $0.id == group.conversationId }
            dismiss()
        } catch { failure = managementError(error) }
    }
}

struct GroupWorkView: View {
    @ObservedObject var model: ConnectionModel
    let group: GroupRead
    let run: GroupCollaboration.Run
    var openFile: ((String) -> Void)? = nil
    @State private var activityDisclosure = ActivityDisclosurePolicy.State()
    @State private var expandedDetails: Set<String> = []
    @State private var failure: String?
    @State private var details: [String: ConversationSnapshot] = [:]
    private var lifecycle: ActivityDisclosurePolicy.Lifecycle {
        ActivityDisclosurePolicy.lifecycle(for: run.plan)
    }
    private var active: Bool { lifecycle.isActive }
    private var disclosureEntry: ActivityDisclosurePolicy.Entry {
        ActivityDisclosurePolicy.Entry(
            conversationID: group.conversationId,
            turnID: "run:" + run.parentMessageId,
            entryID: "group-work:" + group.conversationId + ":" + run.parentMessageId,
            lifecycle: lifecycle
        )
    }
    private var effectiveDisclosureState: ActivityDisclosurePolicy.State {
        ActivityDisclosurePolicy.reconciled(
            activityDisclosure,
            entries: [disclosureEntry],
            retainedConversationID: group.conversationId,
            retainedTurnIDs: [disclosureEntry.key.turnID]
        )
    }
    private var expanded: Bool {
        ActivityDisclosurePolicy.expandedEntryIDs(
            entries: [disclosureEntry],
            state: effectiveDisclosureState
        ).contains(disclosureEntry.key.entryID)
    }
    private var label: String {
        if active { return run.plan.assignments.isEmpty ? "Choosing teammates…" : "Team working…" }
        if run.plan.cancelled { return "Stopped" }
        if run.plan.error != nil { return "Couldn’t start" }
        if run.plan.assignments.contains(where: { $0.state != "completed" }) { return "Some work couldn’t finish" }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let endText = run.plan.finishedAt, let end = formatter.date(from: endText), let start = formatter.date(from: run.plan.startedAt) {
            return "Worked for \(max(1, Int(end.timeIntervalSince(start))))s"
        }
        return "Worked"
    }
    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expanded },
            set: { requested in
                guard requested != expanded else { return }
                toggleDisclosure()
            }
        )) {
            ForEach(run.plan.assignments) { assignment in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        let name = group.members?.first { $0.botId == assignment.botId }?.botName ?? "Bot"
                        let bot = model.managedBots.first { $0.id == assignment.botId }
                        ChatAvatar(name: name, identity: assignment.botId,
                                   hexColor: bot?.avatarColor,
                                   avatarShape: bot?.avatarShape,
                                   avatarPalette: bot?.avatarPalette)
                        Text(name).font(.subheadline.weight(.medium))
                        Spacer()
                        Text(status(assignment)).foregroundStyle(.secondary)
                    }
                    Text(assignment.brief).font(.footnote).foregroundStyle(.secondary)
                    if let snapshot = details[assignment.botId] {
                        ForEach(snapshot.rows(author: group.members?.first { $0.botId == assignment.botId }?.botName ?? "Bot").filter { $0.activitySummary != nil || $0.isCommentary }) { row in
                            if row.activitySummary != nil { ActivityItemView(row: row, expanded: expandedDetails.contains(row.id), openFile: openFile) { if !expandedDetails.insert(row.id).inserted { expandedDetails.remove(row.id) } } }
                            else if row.isCommentary { BotMessageText(text: row.text).font(.footnote) }
                        }
                    }
                    if assignment.state == "failed", !active {
                        Button("Retry this Bot") { Task { await retry(assignment.botId) } }
                    }
                }.padding(.vertical, 4)
            }
            if let error = run.plan.error {
                Text(error).foregroundStyle(.secondary)
                if run.plan.assignments.isEmpty && !run.plan.cancelled { Button("Retry") { Task { await retry("") } } }
            }
            if let failure { Text(failure).foregroundStyle(.secondary) }
            if active { Button("Stop", role: .destructive) { Task { await stop() } }.disabled(model.previewMode) }
        } label: {
            HStack(spacing: 8) {
                if active { ProgressView().controlSize(.small) }
                Text(label)
                    .font(.subheadline)
                ForEach(Array(run.plan.assignments.prefix(3))) { assignment in
                    let name = group.members?.first { $0.botId == assignment.botId }?.botName ?? "Bot"
                    let bot = model.managedBots.first { $0.id == assignment.botId }
                    ChatAvatar(name: name, identity: assignment.botId,
                               hexColor: bot?.avatarColor,
                               avatarShape: bot?.avatarShape,
                               avatarPalette: bot?.avatarPalette).scaleEffect(0.65).frame(width: 24, height: 24)
                        .accessibilityLabel("\(name), \(status(assignment))")
                }
            }
        }.tint(.primary).padding(.horizontal, 12)
        .accessibilityIdentifier(disclosureEntry.key.entryID)
        .onChange(of: lifecycle, initial: true) { _, _ in
            activityDisclosure = ActivityDisclosurePolicy.reconciled(
                activityDisclosure,
                entries: [disclosureEntry],
                retainedConversationID: group.conversationId,
                retainedTurnIDs: [disclosureEntry.key.turnID]
            )
        }
        .task(id: "\(expanded)-\(lifecycle.rawValue)-\(run.plan.assignments.map(\.state).joined())") {
            guard expanded, !model.previewMode else { return }
            repeat {
                await loadDetails()
                guard expanded, active else { break }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            } while !Task.isCancelled
        }
    }
    private func toggleDisclosure() {
        activityDisclosure = ActivityDisclosurePolicy.toggled(
            activityDisclosure,
            entry: disclosureEntry,
            isExpanded: expanded
        )
    }
    private func status(_ assignment: GroupCollaboration.Assignment) -> String {
        switch assignment.state {
        case "queued": return assignment.dependsOn.isEmpty ? "Queued" : "Waiting"
        case "working": return "Working"
        case "completed": return "Done"
        case "blocked": return "Waiting on failed work"
        case "cancelled": return "Stopped"
        default: return "Couldn’t finish"
        }
    }
    private func loadDetails() async {
        for assignment in run.plan.assignments {
            guard let id = assignment.conversationId else { continue }
            do { let snapshot: ConversationSnapshot = try await model.manage("/api/v1/conversations/\(ConnectionModel.escape(id))"); details[assignment.botId] = snapshot }
            catch { if assignment.state != "queued" { failure = "Some work details couldn’t be loaded. Reopen this row to retry." } }
        }
    }
    private func retry(_ bot: String) async {
        do { let _: GroupEmptyReply = try await model.manage("/api/v1/group-chats/\(group.id)/retry", method: "POST", values: ["parentMessageId": run.parentMessageId, "botId": bot]); failure = nil }
        catch { failure = managementError(error) }
    }
    private func stop() async {
        do { let _: GroupEmptyReply = try await model.manage("/api/v1/group-chats/\(group.id)/stop", method: "POST", values: ["parentMessageId": run.parentMessageId]); failure = nil }
        catch { failure = managementError(error) }
    }
}

/// Conversational Group setup: Wonder suggests a roster, the owner edits it
/// directly or asks for changes, and only Create commits the accepted team.
/// Nothing here creates Bots or starts group work.
struct GroupReviewSheet: View {
    @ObservedObject var model: ConnectionModel
    let initialDescription: String
    let draftID: String
    let onCreated: (String) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    private struct Note: Codable, Identifiable { var id = UUID(); let fromOwner: Bool; let text: String }
    @State private var proposal: TeamProposal?
    @State private var members: Set<String> = []
    @State private var notes: [Note] = []
    @State private var refinement = ""
    @State private var revision = 0
    @State private var thinking = false
    @State private var creating = false
    @State private var failure: String?
    @State private var scope: String?
    @State private var request = ManagementDraft()
    @State private var editing: UUID?
    @State private var editingResponsibilities = false
    @State private var detent: PresentationDetent = .large
    @State private var restored = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var draftKey: String { "group.review." + draftID }
    private var existing: [ManagedBot] { model.managedBots.filter { members.contains($0.id) && !$0.isArchived } }
    private var frozen: Bool { request.values["payload"] != nil }
    private var canCreate: Bool {
        guard let proposal, !creating, !thinking, !model.accessEnded, scope == model.assignmentScope else { return false }
        let count = members.count + proposal.newBots.count
        return (1...17).contains(count) && proposal.name.utf8.count <= 80 && proposal.purpose.count <= 500
            && proposal.newBots.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.utf8.count <= 80
                && !$0.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.purpose.utf8.count <= 160
                && !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.instructions.utf8.count <= 8000 }
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                List {
                    Section {
                        HStack { Spacer(minLength: 40); Text(initialDescription).padding(10)
                            .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 16)) }
                            .accessibilityLabel("You: " + initialDescription)
                    }.listRowSeparator(.hidden)
                    if let proposal {
                        Section("Team") {
                            TextField("Name", text: bind(\.name)).font(.headline).disabled(frozen)
                                .accessibilityIdentifier("group-review-name")
                            TextField("Purpose", text: bind(\.purpose), axis: .vertical).foregroundStyle(.secondary).disabled(frozen)
                            ForEach(existing) { bot in
                                HStack(spacing: 12) {
                                    ChatAvatar(name: bot.name, identity: bot.id, hexColor: bot.avatarColor, avatarShape: bot.avatarShape, avatarPalette: bot.avatarPalette, size: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bot.name).font(.subheadline.weight(.semibold))
                                        Text(bot.role.isEmpty ? "Existing Bot" : bot.role).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if !frozen { Button("Edit") { editingResponsibilities = true }.buttonStyle(.borderless) }
                                }
                                .swipeActions { if !frozen { Button("Remove", role: .destructive) { members.remove(bot.id); edited() } } }
                            }
                            ForEach(proposal.newBots) { bot in
                                HStack(spacing: 12) {
                                    Image(systemName: "plus.circle").font(.title3).frame(width: 32, height: 32).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bot.name).font(.subheadline.weight(.semibold))
                                        Text(bot.purpose).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    if !frozen { Button("Edit") { editing = bot.id }.buttonStyle(.borderless) }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("New Bot \(bot.name), \(bot.purpose)")
                                .swipeActions { if !frozen { Button("Remove", role: .destructive) { self.proposal?.newBots.removeAll { $0.id == bot.id }; edited() } } }
                            }
                            if !frozen {
                                Menu("Add member", systemImage: "person.badge.plus") {
                                    ForEach(model.managedBots.filter { !$0.isArchived && !members.contains($0.id) }) { bot in
                                        Button(bot.name) { members.insert(bot.id); edited() }
                                    }
                                    Button("New Bot", systemImage: "plus") {
                                        let bot = SuggestedBot(name: "", purpose: "", instructions: "")
                                        self.proposal?.newBots.append(bot); edited(); editing = bot.id
                                    }
                                }.disabled(members.count + proposal.newBots.count >= 17)
                            }
                        }
                    }
                    ForEach(notes) { note in
                        HStack {
                            if note.fromOwner { Spacer(minLength: 40) }
                            Text(note.text).padding(10)
                                .background(note.fromOwner ? Color.accentColor.opacity(0.25) : Color(uiColor: .secondarySystemBackground),
                                            in: RoundedRectangle(cornerRadius: 16))
                            if !note.fromOwner { Spacer(minLength: 40) }
                        }
                        .listRowSeparator(.hidden)
                        .accessibilityLabel((note.fromOwner ? "You: " : "Wonder setup: ") + note.text)
                        .id(note.id)
                    }
                    if thinking { ProgressView(proposal == nil ? "Preparing your team…" : "Updating your team…").listRowSeparator(.hidden) }
                    if let failure {
                        FailureDetails(message: failure).listRowSeparator(.hidden)
                        if proposal == nil && !thinking {
                            Button("Try again") { Task { await suggest(refinement: nil) } }
                                .frame(minHeight: 44).listRowSeparator(.hidden)
                        }
                    }
                }
                .listStyle(.plain)
                .onChange(of: notes.count) { _, _ in if let last = notes.last { withAnimation(reduceMotion ? nil : .default) { reader.scrollTo(last.id) } } }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if proposal != nil && !frozen {
                        HStack(spacing: 6) {
                            TextField("Adjust the team…", text: $refinement, axis: .vertical).lineLimit(1...4)
                                .padding(.leading, 14).padding(.vertical, 10)
                                .accessibilityIdentifier("group-review-refine")
                            Button { Task { await refine() } } label: {
                                Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                            }
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .background(refinement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || thinking ? Color.secondary.opacity(0.35) : Color.primary, in: Circle())
                            .disabled(refinement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || thinking || creating)
                            .accessibilityLabel("Send change")
                            .padding(4)
                        }
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
                    }
                    Button { Task { await create() } } label: {
                        Group { if creating { ProgressView() } else { Text(frozen && failure != nil ? "Retry create" : "Create group") } }
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!canCreate)
                    .accessibilityIdentifier("group-review-create")
                }
                .padding(.horizontal).padding(.vertical, 8).background(.bar)
            }
            .navigationTitle("Review your team").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { persistReview(); if !frozen { onCancel() }; dismiss() }.disabled(thinking || creating)
                }
            }
            .sheet(isPresented: $editingResponsibilities) {
                NavigationStack {
                    Form {
                        Section("Responsibilities in this group") {
                            TextField("Group instructions", text: bind(\.purpose), axis: .vertical).lineLimit(4...12)
                            Text("Describe each member’s role here. Existing Bots keep their own profiles.").font(.footnote).foregroundStyle(.secondary)
                            Text("\(proposal?.purpose.count ?? 0) / 500").font(.caption).foregroundStyle(.secondary)
                        }
                    }.navigationTitle("Group instructions")
                        .toolbar { Button("Done") { editingResponsibilities = false } }
                }.presentationDetents([.medium, .large])
            }
            .sheet(item: Binding(get: { editing.map(EditingID.init) }, set: { editing = $0?.id })) { item in
                NavigationStack {
                    Form {
                        TextField("Name", text: newBot(item.id, \.name))
                        TextField("What it does", text: newBot(item.id, \.purpose), axis: .vertical)
                        TextField("Standing instructions", text: newBot(item.id, \.instructions), axis: .vertical).lineLimit(3...10)
                    }
                    .navigationTitle("Edit Bot").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { editing = nil } }
                }.presentationDetents([.medium, .large])
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(thinking || creating)
        .task {
            scope = model.assignmentScope
            request = model.managementDrafts?.load(draftKey) ?? ManagementDraft()
            if let payload = request.values["payload"], let data = payload.data(using: .utf8),
               let saved = try? JSONDecoder().decode(TeamProposal.self, from: data) {
                // An uncertain Create keeps its exact accepted payload for retry.
                proposal = saved; members = Set(saved.memberBotIds)
                notes = [Note(fromOwner: false, text: "Your last Create wasn’t confirmed. Retry to finish it; it won’t create a duplicate.")]
            } else if let encoded = request.values["review"], let data = encoded.data(using: .utf8),
                      let saved = try? JSONDecoder().decode(TeamProposal.self, from: data) {
                proposal = saved; members = Set(saved.memberBotIds)
                if let identities = request.values["memberIDs"]?.data(using: .utf8),
                   let ids = try? JSONDecoder().decode([UUID].self, from: identities), ids.count == saved.newBots.count {
                    for index in ids.indices { proposal?.newBots[index].id = ids[index] }
                }
            }
            if let data = request.values["notes"]?.data(using: .utf8),
               let saved = try? JSONDecoder().decode([Note].self, from: data) { notes = saved }
            refinement = request.values["refinement"] ?? ""
            restored = true
            if proposal == nil { await suggest(refinement: nil) }
        }
        .onChange(of: refinement) { _, _ in persistReview() }
        .onDisappear { persistReview() }
    }
    private struct EditingID: Identifiable { let id: UUID }
    private func edited() { revision += 1; persistReview() }
    private func persistReview() {
        guard restored, scope == model.assignmentScope, !model.accessEnded else { return }
        do {
            if var current = proposal, !frozen {
                current.memberBotIds = members.sorted()
                request.values["review"] = String(decoding: try JSONEncoder().encode(current), as: UTF8.self)
                request.values["memberIDs"] = String(decoding: try JSONEncoder().encode(current.newBots.map(\.id)), as: UTF8.self)
            }
            request.values["notes"] = String(decoding: try JSONEncoder().encode(Array(notes.suffix(20))), as: UTF8.self)
            request.values["refinement"] = refinement
            try model.managementDrafts?.save(request, key: draftKey)
        } catch { failure = "The team could not be saved on this device. Free some storage before continuing." }
    }
    private func bind(_ key: WritableKeyPath<TeamProposal, String>) -> Binding<String> {
        Binding(get: { proposal?[keyPath: key] ?? "" }, set: { proposal?[keyPath: key] = $0; edited() })
    }
    private func newBot(_ id: UUID, _ key: WritableKeyPath<SuggestedBot, String>) -> Binding<String> {
        Binding(get: { proposal?.newBots.first { $0.id == id }?[keyPath: key] ?? "" },
                set: { value in
                    guard let index = proposal?.newBots.firstIndex(where: { $0.id == id }) else { return }
                    proposal?.newBots[index][keyPath: key] = value; edited()
                })
    }
    private func suggest(refinement change: String?) async {
        guard !thinking, let saved = model.connection, scope == model.assignmentScope, !model.accessEnded else { return }
        thinking = true; failure = nil
        defer { thinking = false }
        revision += 1
        let sent = revision
        do {
            let options: BotOptions = try await model.manage("/api/v1/bot-options")
            guard scope == model.assignmentScope, !Task.isCancelled, !model.accessEnded else { return }
            guard options.groupCollaboration == true else { failure = "Update Wonder on \(model.macName) to create Group Chats this way."; return }
            var payload: [String: Any] = ["description": initialDescription,
                                          "settings": try ModelDefaultPurpose.groupCreation.load().creationValues(options: options)]
            if let change, var current = proposal {
                // The owner's latest edits are the base of every refinement.
                current.memberBotIds = members.sorted()
                payload["current"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current))
                payload["refinement"] = change
            }
            var result: TeamProposal = try await model.api.request("/api/v1/group-chats/propose", origin: saved.origin,
                body: JSONSerialization.data(withJSONObject: payload), credential: saved.credential)
            guard scope == model.assignmentScope, !Task.isCancelled else { return }
            guard sent == revision else {
                notes.append(Note(fromOwner: false, text: "You changed the team while I was updating it, so I kept your edits."))
                return
            }
            // Keep stable local identities for Bots that survived the revision.
            for index in result.newBots.indices {
                if let match = proposal?.newBots.first(where: { $0.name.caseInsensitiveCompare(result.newBots[index].name) == .orderedSame }) {
                    result.newBots[index].id = match.id
                }
            }
            proposal = result
            members = Set(result.memberBotIds)
            notes.append(Note(fromOwner: false, text: result.summary ?? (change == nil ? "Here’s a team we can adjust." : "Updated.")))
            persistReview()
        } catch {
            guard scope == model.assignmentScope else { return }
            failure = managementError(error)
        }
    }
    private func refine() async {
        let change = refinement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !change.isEmpty else { return }
        notes.append(Note(fromOwner: true, text: change))
        refinement = ""
        persistReview()
        await suggest(refinement: change)
    }
    private func create() async {
        guard canCreate, let saved = model.connection else { return }
        creating = true; failure = nil
        defer { creating = false }
        do {
            let data: Data
            if let frozenPayload = request.values["payload"] { data = Data(frozenPayload.utf8) }
            else {
                let options: BotOptions = try await model.manage("/api/v1/bot-options")
                guard scope == model.assignmentScope, options.groupCollaboration == true else { failure = "Update Wonder on \(model.macName) to create Group Chats."; return }
                let accepted = TeamProposal(name: proposal?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? proposal!.name : "New Group Chat",
                                            purpose: proposal?.purpose ?? "", memberBotIds: members.sorted(), newBots: proposal?.newBots ?? [])
                var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(accepted)) as! [String: Any]
                payload["clientRequestId"] = request.requestId
                let routing = try ModelDefaultPurpose.groupParticipation.load().creationValues(options: options)
                payload["routing"] = routing
                payload["newBotDefaults"] = accepted.newBots.isEmpty ? routing : try ModelDefaultPurpose.newBots.load().creationValues(options: options)
                data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
                // Freeze the accepted roster and request before sending.
                request.values["payload"] = String(decoding: data, as: UTF8.self)
            }
            guard let drafts = model.managementDrafts else { throw ReadFailure.resync }
            try drafts.save(request, key: draftKey)
            let group: GroupRead = try await model.api.request("/api/v1/group-chats/new", origin: saved.origin, body: data, credential: saved.credential)
            guard scope == model.assignmentScope else { return }
            restored = false
            model.managementDrafts?.remove(draftKey)
            await model.refreshChatList()
            onCreated(group.conversationId)
            dismiss()
        } catch PairingFailure.response(410) {
            model.managementDrafts?.remove(draftKey)
            request = ManagementDraft()
            failure = "That Group Chat was deleted. Create it again to start fresh."
        } catch {
            failure = managementError(error) + " Your accepted team is saved; retry to finish."
        }
    }
}
