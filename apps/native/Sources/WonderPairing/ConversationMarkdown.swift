import Foundation

/// The loaded conversation as Markdown: who spoke, what they said, and one line
/// for each thing the agent did. It is built from projected rows, not from a
/// view, so the same text comes out whatever is on screen.
public enum ConversationMarkdown {
    public struct Output: Equatable, Sendable {
        public let markdown: String
        /// Messages written: the owner's and the agent's words, and plans.
        public let messageCount: Int
        /// Earlier history exists on the Mac that is not loaded on this device.
        public let isPartial: Bool

        /// What the reader is told after copying.
        public var confirmation: String {
            let noun = messageCount == 1 ? "message" : "messages"
            return isPartial ? "Copied \(messageCount) \(noun). Earlier messages are not loaded yet."
                : "Copied \(messageCount) \(noun)"
        }
    }

    public static func render(title: String, agentName: String, rows: [ReadRow], isPartial: Bool) -> Output {
        var lines = ["# " + singleLine(title, fallback: "Conversation")]
        if isPartial { lines.append("_Earlier messages are not included._") }
        var speaker: String?
        var activity: [String] = []
        var count = 0
        func flushActivity() {
            guard !activity.isEmpty else { return }
            lines.append(activity.map { "- " + $0 }.joined(separator: "\n"))
            activity = []
        }
        func heading(_ name: String) {
            guard speaker != name else { return }
            lines.append("## " + singleLine(name, fallback: "Agent"))
            speaker = name
        }
        func speak(_ name: String, _ text: String) {
            flushActivity()
            heading(name)
            lines.append(text)
            count += 1
        }
        for row in rows {
            if row.profileStatus != nil || row.item?.type == "reasoning" || row.isContextCompaction || row.isProviderSwitch { continue }
            let text = (row.isPlan ? row.planText : row.text)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if row.isUser {
                if !text.isEmpty { speak("You", text) }
            } else if row.isPlan {
                if !text.isEmpty { speak(name(row), text) }
            } else if let summary = summary(row) {
                heading(name(row))
                activity.append(summary)
            } else if !text.isEmpty {
                speak(name(row), text)
            }
        }
        flushActivity()
        return Output(markdown: lines.joined(separator: "\n\n") + "\n", messageCount: count, isPartial: isPartial)
    }

    private static func name(_ row: ReadRow) -> String {
        let author = row.author.trimmingCharacters(in: .whitespaces)
        return author.isEmpty ? "Agent" : author
    }

    /// One line per action. Never tool output and never identifiers.
    private static func summary(_ row: ReadRow) -> String? {
        if let command = row.commandSummary { return command.label(includeDuration: true) }
        if let change = row.fileChangeSummary { return change.title }
        guard let activity = row.activitySummary else { return nil }
        return activity.state == "completed" ? activity.title : "\(activity.title) (\(activity.status.lowercased()))"
    }

    private static func singleLine(_ text: String, fallback: String) -> String {
        let value = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? fallback : value
    }
}
