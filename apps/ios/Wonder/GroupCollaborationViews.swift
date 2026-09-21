import SwiftUI
import WonderPairing

private struct GroupEmptyReply: Decodable {}

private struct SuggestedBot: Codable, Identifiable {
    var name: String
    var purpose: String
    var instructions: String
    var id: String { name }
}
private struct TeamProposal: Codable {
    var name: String
    var purpose: String
    var memberBotIds: [String]
    var newBots: [SuggestedBot]
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
                            ForEach(Array(proposal.newBots.enumerated()), id: \.offset) { index, bot in
                                NavigationLink {
                                    Form {
                                        TextField("Name", text: proposed(index, \.name))
                                        TextField("Purpose", text: proposed(index, \.purpose), axis: .vertical)
                                        TextField("Instructions", text: proposed(index, \.instructions), axis: .vertical)
                                        Button("Remove Bot", role: .destructive) { self.proposal?.newBots.remove(at: index) }
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
    private func proposed(_ index: Int, _ key: WritableKeyPath<SuggestedBot, String>) -> Binding<String> {
        Binding(get: { guard let proposal, proposal.newBots.indices.contains(index) else { return "" }; return proposal.newBots[index][keyPath:key] },
                set: { value in guard proposal?.newBots.indices.contains(index) == true else { return }; proposal?.newBots[index][keyPath:key] = value })
    }
    private func settings(_ purpose: ModelDefaultPurpose, options: BotOptions) throws -> [String: String] {
        try purpose.load().creationValues(options: options)
    }
    private func suggest() async {
        guard let saved = model.connection else { return }
        busy = true; defer { busy = false }
        do {
            let options: BotOptions = try await model.manage("/api/v1/bot-options")
            guard options.groupCollaboration == true else { failure = "Update Wonder on this computer to create conversational groups."; return }
            let payload: [String: Any] = ["description": description, "settings": try settings(.groupCreation, options: options)]
            let result: TeamProposal = try await model.api.request("/api/v1/group-chats/propose", origin: saved.origin, body: JSONSerialization.data(withJSONObject: payload), credential: saved.credential)
            guard scope == model.assignmentScope else { return }
            proposal = result; selected = Set(result.memberBotIds); failure = nil
        } catch { failure = managementError(error) }
    }
    private func create() async {
        guard let saved = model.connection, scope == model.assignmentScope else { return }
        busy = true; defer { busy = false }
        do {
            let data: Data
            if let frozen = request.values["payload"] { data = Data(frozen.utf8) }
            else {
                let options: BotOptions = try await model.manage("/api/v1/bot-options")
            guard options.groupCollaboration == true else { failure = "Update Wonder on this computer to create conversational groups."; return }
                let team = TeamProposal(name: proposal?.name ?? "New Group Chat", purpose: proposal?.purpose ?? "", memberBotIds: selected.sorted(), newBots: proposal?.newBots ?? [])
                var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(team)) as! [String: Any]
                payload["clientRequestId"] = request.requestId
                payload["routing"] = try settings(.groupParticipation, options: options)
                payload["newBotDefaults"] = try settings(.newBots, options: options)
                data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
                request.values["payload"] = String(decoding: data, as: UTF8.self)
                try model.managementDrafts?.save(request, key: "group.new")
            }
            let group: GroupRead = try await model.api.request("/api/v1/group-chats/new", origin: saved.origin, body: data, credential: saved.credential)
            guard scope == model.assignmentScope else { return }
            model.managementDrafts?.remove("group.new")
            await model.loadChats(force: true)
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
