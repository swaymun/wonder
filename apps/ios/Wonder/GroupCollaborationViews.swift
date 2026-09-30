import SwiftUI
import WonderPairing

private struct GroupEmptyReply: Decodable {}

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
