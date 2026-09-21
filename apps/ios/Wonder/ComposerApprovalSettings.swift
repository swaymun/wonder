import Foundation
import WonderPairing

struct ComposerApprovalTarget: Hashable {
    let conversationID: String
    let botID: String
    let queuedMessageID: String?
}

struct ComposerApprovalChange {
    var desired: BotApprovalMode
    var saving = true
    var reconciled = false
    var failure: String?
}

extension ConnectionModel {
    func approvalChange(_ target: ComposerApprovalTarget) -> ComposerApprovalChange? {
        composerApprovalChanges[target]
    }

    func approvalSettingsBlockSending(_ conversationID: String) -> Bool {
        composerApprovalChanges.contains { target, change in
            target.conversationID == conversationID && (change.saving || !change.reconciled)
        }
    }

    func cancelApprovalSettings() {
        composerApprovalTasks.values.forEach { $0.cancel() }
        composerApprovalTasks = [:]
        composerApprovalTokens = [:]
        composerApprovalChanges = [:]
    }

    /// The overlay is presentation-only. Only a confirmed response updates the
    /// saved Bot or queue snapshot, and execution waits for confirmation.
    func setApprovalMode(_ mode: BotApprovalMode, target: ComposerApprovalTarget, chat: ChatSummary) {
        guard connection != nil, !accessEnded, !previewMode,
              !savingComposerSettings.contains(chat.id), !isSubagent(chat) else { return }
        composerApprovalChanges[target] = ComposerApprovalChange(desired: mode)
        guard composerApprovalTasks[target] == nil else { return }
        let token = UUID(), scope = assignmentScope
        composerApprovalTokens[target] = token
        composerApprovalTasks[target] = Task { [weak self] in
            await self?.saveApprovalSettings(target, chat: chat, scope: scope, token: token)
        }
    }

    private func approvalSaveIsCurrent(_ target: ComposerApprovalTarget, scope: String, token: UUID) -> Bool {
        !Task.isCancelled && !accessEnded && assignmentScope == scope && composerApprovalTokens[target] == token
    }

    private func saveApprovalSettings(_ target: ComposerApprovalTarget, chat: ChatSummary, scope: String, token: UUID) async {
        defer {
            if composerApprovalTokens[target] == token {
                composerApprovalTasks[target] = nil
                composerApprovalTokens[target] = nil
            }
        }
        while approvalSaveIsCurrent(target, scope: scope, token: token), let change = composerApprovalChanges[target] {
            let attempted = change.desired
            do {
                if let messageID = target.queuedMessageID {
                    guard let queued = queues[chat.id]?.first(where: { $0.id == messageID }) else {
                        throw PairingFailure.response(409)
                    }
                    struct Empty: Decodable, Sendable {}
                    let body = try JSONSerialization.data(withJSONObject: [
                        "expectedRevision": queued.revision, "settings": ["approvalMode": attempted.rawValue]
                    ])
                    let _: Empty = try await manage("/api/v1/conversations/\(Self.escape(chat.id))/queue/\(Self.escape(messageID))", method: "POST", body: body)
                    guard approvalSaveIsCurrent(target, scope: scope, token: token) else { return }
                    try await loadQueue(chat)
                } else {
                    let saved: ManagedBot = try await manage("/api/v1/bots/\(Self.escape(target.botID))", method: "PATCH", values: ["approvalMode": attempted.rawValue])
                    guard approvalSaveIsCurrent(target, scope: scope, token: token) else { return }
                    applyConfirmedManagedBot(saved)
                }
                guard approvalSaveIsCurrent(target, scope: scope, token: token) else { return }
                if composerApprovalChanges[target]?.desired == attempted {
                    composerApprovalChanges[target] = nil
                    return
                }
            } catch {
                guard approvalSaveIsCurrent(target, scope: scope, token: token) else { return }
                // A timeout may have happened after the write. Read back the
                // authority before rolling back or allowing another send.
                var reconciled = false
                var confirmedMode: BotApprovalMode?
                do {
                    if target.queuedMessageID != nil {
                        try await loadQueue(chat)
                        confirmedMode = queues[chat.id]?.first { $0.id == target.queuedMessageID }?
                            .executionSettings?.approvalMode.flatMap(BotApprovalMode.init(rawValue:))
                    } else {
                        let saved: ManagedBot = try await manage("/api/v1/bots/\(Self.escape(target.botID))")
                        guard approvalSaveIsCurrent(target, scope: scope, token: token) else { return }
                        applyConfirmedManagedBot(saved)
                        confirmedMode = saved.approvalMode.flatMap(BotApprovalMode.init(rawValue:))
                    }
                    reconciled = true
                } catch { /* Keep execution fenced until a retry confirms state. */ }
                guard approvalSaveIsCurrent(target, scope: scope, token: token), var latest = composerApprovalChanges[target] else { return }
                if reconciled, confirmedMode == latest.desired {
                    composerApprovalChanges[target] = nil
                    return
                }
                if latest.desired != attempted && reconciled { continue }
                latest.saving = false
                latest.reconciled = reconciled
                latest.failure = reconciled
                    ? "Couldn’t save approval settings. Try again."
                    : "Couldn’t confirm approval settings. Reconnect and try again."
                composerApprovalChanges[target] = latest
                return
            }
        }
    }
}
