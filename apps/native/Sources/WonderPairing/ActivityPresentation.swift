import Foundation

public struct ChatFeedEntry: Identifiable, Sendable {
    public var rows: [ReadRow]
    public var id: String { rows[0].id }
    public var isContextCompaction: Bool { rows.count == 1 && rows[0].isContextCompaction }
    public var isActivity: Bool { !isContextCompaction && (rows[0].activitySummary != nil || rows[0].isCommentary) }

    public static func visibleRows(_ rows: [ReadRow], queuedClientIDs: Set<String>) -> [ReadRow] {
        let queuedRows = Set(queuedClientIDs.map { "user-" + $0 })
        return rows.filter { !queuedRows.contains($0.id) }
    }

    public static func grouping(_ rows: [ReadRow], activeTurnIDs: Set<String> = [], focusedRowID: String? = nil) -> [Self] {
        var entries: [Self] = []
        for row in rows {
            if row.item?.type == "reasoning",
               !(row.turnId.map(activeTurnIDs.contains) == true && row.activitySummary?.isRunning == true) { continue }
            if row.isContextCompaction {
                // A compaction is a durable boundary in the transcript, not a
                // row inside the surrounding Working disclosure.
                entries.append(Self(rows: [row]))
                continue
            }
            if row.activitySummary != nil || row.isCommentary, let first = entries.last?.rows.first,
               !entries.last!.isContextCompaction,
               first.activitySummary != nil || first.isCommentary,
               row.id != focusedRowID, first.id != focusedRowID,
               let turn = row.turnId, first.turnId == turn,
               first.authorId == row.authorId {
                entries[entries.count - 1].rows.append(row)
            } else { entries.append(Self(rows: [row])) }
        }
        return entries
    }

    /// Returns the entries that are the final visible activity segment for
    /// each turn. A turn can have multiple activity groups when visible Bot
    /// text separates them, so duration and the active spinner belong only to
    /// the final segment.
    public static func latestActivityEntryIDs(_ entries: [Self]) -> Set<String> {
        var latest: [String: String] = [:]
        for entry in entries where entry.isActivity {
            guard let turn = entry.rows.first?.turnId else { continue }
            latest[turn] = entry.id
        }
        return Set(latest.values)
    }

    /// Returns the final visible activity segment for one canonical turn.
    /// The projection can contain more than one in-progress turn after a
    /// steer/replay, so callers choose the turn from the daemon lifecycle and
    /// never infer it from an activity row or receipt.
    public static func latestActivityEntryID(_ entries: [Self], turnID: String?) -> String? {
        guard let turnID else { return nil }
        return entries.last(where: { entry in
            entry.isActivity && entry.rows.first?.turnId == turnID
        })?.id
    }

    public static func actionSummary(rows: [ReadRow]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for row in rows {
            let category: String?
            switch row.item?.type {
            case "commandExecution": category = "command"
            case "webSearch": category = "web"
            case "fileChange": category = "file"
            case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "functionCallOutput": category = "tool"
            case "subAgentActivity": category = "agent"
            case "sleep": category = "wait"
            case "imageView", "imageGeneration": category = "image"
            case "enteredReviewMode", "exitedReviewMode": category = "review"
            case "plan": category = "plan"
            case "hookPrompt": category = "instructions"
            case "error": category = "error"
            case "agentMessage" where row.isCommentary: category = "commentary"
            default: category = nil
            }
            guard let category else { continue }
            if counts[category] == nil { order.append(category) }
            counts[category, default: 0] += 1
        }

        let labels = order.prefix(3).map { category -> String in
            let count = counts[category] ?? 0
            switch category {
            case "command": return count == 1 ? "Ran 1 command" : "Ran \(count) commands"
            case "web": return count == 1 ? "Searched the web" : "Searched the web \(count) times"
            case "file": return count == 1 ? "Changed 1 file" : "Changed \(count) files"
            case "tool": return count == 1 ? "Used 1 tool" : "Used \(count) tools"
            case "agent": return count == 1 ? "Worked with 1 subagent" : "Worked with \(count) subagents"
            case "wait": return count == 1 ? "Waited" : "Waited \(count) times"
            case "image": return count == 1 ? "1 image action" : "\(count) image actions"
            case "review": return count == 1 ? "Reviewed" : "Reviewed \(count) times"
            case "plan": return count == 1 ? "Made a plan" : "Made \(count) plans"
            case "instructions": return count == 1 ? "Applied instructions" : "Applied instructions \(count) times"
            case "error": return count == 1 ? "Encountered 1 error" : "Encountered \(count) errors"
            case "commentary": return count == 1 ? "Progress update" : "\(count) progress updates"
            default: return "Activity"
            }
        }
        guard !labels.isEmpty else { return nil }
        var result = labels.joined(separator: " · ")
        if order.count > labels.count { result += " · +\(order.count - labels.count) more" }
        return result
    }

    public static func lifecycleLabel(rows: [ReadRow], turn: ReadTurn?, isLatestSegmentForTurn: Bool, isLatestActiveSegment: Bool) -> String {
        if turn?.isInProgress == true {
            if isLatestActiveSegment {
                return rows.last?.activitySummary?.title == "Thinking" ? "Thinking…" : "Working…"
            }
            return actionSummary(rows: rows) ?? "Work status unavailable"
        }
        if isLatestSegmentForTurn, let terminal = turn?.terminalLabel {
            return terminal
        }
        if let summary = actionSummary(rows: rows) { return summary }
        return turn?.status == "unknown" || turn == nil ? "Work status unavailable" : "Worked"
    }
}

public struct ActivityDetail: Identifiable, Sendable {
    public let title: String
    public let text: String
    public var id: String { title }
    public var isDiff: Bool = false
    public var filePath: String? = nil
}

/// Every visible item is a peer in the conversation's one lazy layout.
public struct ChatFeedNode: Identifiable, Sendable {
    public enum Content: Sendable {
        case entry(ChatFeedEntry)
        case activity(ReadRow)
        case compaction(ReadRow)
        case file(ConversationFile)
    }
    public let id: String
    public let entryID: String
    public let content: Content

    /// Returns the surviving activity header for a child node that was
    /// removed by disclosure collapse. This is intentionally pure so the
    /// scroller can preserve a reading anchor without following the bottom.
    public static func survivingAnchor(
        for anchor: String?,
        entries: [ChatFeedEntry],
        nodeIDs: [String]
    ) -> String? {
        guard let anchor, !nodeIDs.contains(anchor) else { return anchor }
        guard let entry = entries.first(where: { owns(anchor: anchor, entry: $0) }),
              entry.isActivity, nodeIDs.contains(entry.id) else { return nil }
        return entry.id
    }

    private static func owns(anchor: String, entry: ChatFeedEntry) -> Bool {
        if anchor == entry.id { return true }
        if anchor.hasPrefix("activity:") {
            let rowID = String(anchor.dropFirst("activity:".count))
            return entry.rows.contains { $0.id == rowID }
        }
        return anchor.hasPrefix("file:" + entry.id + ":")
    }

    public static func visible(_ entries: [ChatFeedEntry], expanded: Set<String>) -> [Self] {
        var result: [Self] = []
        for entry in entries {
            if entry.isContextCompaction, let row = entry.rows.first {
                // Keep the marker in the single lazy timeline regardless of
                // disclosure state. Its identity is the App Server item ID.
                result.append(Self(id: row.id, entryID: entry.id, content: .compaction(row)))
                continue
            }
            result.append(Self(id: entry.id, entryID: entry.id, content: .entry(entry)))
            let isActivity = entry.isActivity
            // Working images belong to the disclosure just like tool details.
            // Only files attached to a visible message stay in the main feed.
            guard !isActivity || expanded.contains(entry.id) else { continue }
            var seen: Set<String> = []
            for row in entry.rows {
                if isActivity && (row.isCommentary || row.item?.type != "reasoning") {
                    result.append(Self(id: "activity:" + row.id, entryID: entry.id, content: .activity(row)))
                }
                for file in row.toolFiles where seen.insert(file.id).inserted {
                    result.append(Self(id: "file:" + entry.id + ":" + file.id, entryID: entry.id, content: .file(file)))
                }
            }
        }
        return result
    }
}

public struct ActivityPresentation: Sendable {
    public let title: String
    public let symbol: String
    public let state: String
    public let details: [ActivityDetail]
    public var kind: String = ""
    public var isRunning: Bool { ["started", "streaming", "waiting"].contains(state) }
    public var failed: Bool { state == "failed" }
    public var status: String {
        switch state {
        case "started", "streaming": "Running"
        case "completed": "Completed"
        case "failed": "Failed"
        case "interrupted": "Stopped"
        case "waiting": "Waiting"
        default: "Status unavailable"
        }
    }
}

/// Cheap, product-facing data for one command disclosure row. The daemon has
/// already sanitized and bounded the command payload; this type only removes
/// an unambiguous shell launch prefix for the collapsed label. It never runs,
/// expands, or evaluates shell syntax.
public struct CommandSummary: Equatable, Sendable {
    public let rawCommand: String
    public let displayCommand: String
    public let duration: String?
    public let state: String
    public let exitCode: Int64?
    public let failed: Bool
    public let stopped: Bool
    public let accessibilityLabel: String

    private init(rawCommand: String, displayCommand: String, duration: String?, state: String,
                 exitCode: Int64?, failed: Bool, stopped: Bool) {
        self.rawCommand = rawCommand
        self.displayCommand = displayCommand
        self.duration = duration
        self.state = state
        self.exitCode = exitCode
        self.failed = failed
        self.stopped = stopped
        let prefix = Self.prefix(for: state, failed: failed, stopped: stopped)
        self.accessibilityLabel = Self.makeLabel(prefix: prefix, command: displayCommand, duration: duration)
    }

    public var prefix: String {
        Self.prefix(for: state, failed: failed, stopped: stopped)
    }

    public func label(includeDuration: Bool) -> String {
        if includeDuration { return accessibilityLabel }
        return Self.makeLabel(prefix: prefix, command: displayCommand, duration: nil)
    }

    public static func prepare(item: ReadItem) -> Self? {
        guard item.type == "commandExecution",
              let command = item.payload?["command"]?.string,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let rawCommand = command
        let source = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let unwrapped = shellCommand(from: source) ?? source
        let displayCommand = singleLine(unwrapped)
        guard !displayCommand.isEmpty else { return nil }

        let exitCode = integer(item.payload?["exitCode"])
        let stopped = item.state == "interrupted"
        let running = ["started", "streaming", "waiting"].contains(item.state)
        let resultIsError: Bool
        if case .object(let result) = item.payload?["result"] {
            resultIsError = result["isError"]?.bool == true
        } else {
            resultIsError = false
        }
        let hasError = item.payload?["error"].map { $0 != .null && $0.string != "" } == true
        let failed = item.state == "failed"
            || (!stopped && !running && (exitCode.map { $0 != 0 } == true || item.payload?["success"]?.bool == false || resultIsError || hasError))

        return Self(rawCommand: rawCommand, displayCommand: displayCommand,
                    duration: compactDuration(item.payload?["durationMs"]), state: item.state,
                    exitCode: exitCode, failed: failed, stopped: stopped)
    }

    private static func prefix(for state: String, failed: Bool, stopped: Bool) -> String {
        if stopped { return "Stopped" }
        if failed { return "Failed" }
        switch state {
        case "started", "streaming", "waiting": return "Running"
        case "completed": return "Ran"
        default: return "Command"
        }
    }

    private static func makeLabel(prefix: String, command: String, duration: String?) -> String {
        let base = prefix + " `" + command + "`"
        return duration.map { base + " for " + $0 } ?? base
    }

    private struct LexicalToken {
        let value: String
        let raw: String
    }

    private static func shellCommand(from source: String) -> String? {
        // Most rows are ordinary commands. Read only their first lexical word
        // before invoking the bounded scanner used for recognized wrappers.
        let firstWord = String(source.prefix { !$0.isWhitespace })
        guard recognizedShells.contains(basename(firstWord)) || basename(firstWord) == "env" else { return nil }
        guard let tokens = tokenize(source), !tokens.isEmpty else { return nil }
        var shellIndex = 0
        if basename(tokens[0].value) == "env" {
            shellIndex = 1
            while shellIndex < tokens.count && isEnvironmentAssignment(tokens[shellIndex].value) {
                shellIndex += 1
            }
        }
        guard shellIndex < tokens.count,
              recognizedShells.contains(basename(tokens[shellIndex].value)) else { return nil }

        let commandOptions = ["-c", "-lc", "-ic", "-ilc"]
        let optionStart = shellIndex + 1
        guard optionStart < tokens.count else { return nil }
        var optionIndex = optionStart
        while optionIndex < tokens.count {
            let option = tokens[optionIndex].value
            if commandOptions.contains(option) {
                let commandIndex = optionIndex + 1
                guard commandIndex == tokens.count - 1 else { return nil }
                return commandText(from: tokens[commandIndex])
            }
            guard shellFlags.contains(option) else { return nil }
            optionIndex += 1
        }
        return nil
    }

    private static func commandText(from token: LexicalToken) -> String? {
        guard !token.value.isEmpty else { return nil }
        let characters = Array(token.raw)
        if characters.count >= 2,
           (characters.first == "'" || characters.first == "\""),
           characters.last == characters.first {
            guard !characters.dropFirst().dropLast().contains(characters.first!) else { return nil }
            return String(characters.dropFirst().dropLast())
        }
        guard !characters.contains(where: { "'\"\\;$|&<>()`".contains($0) || $0.isWhitespace }) else { return nil }
        // Keep an unquoted command argument byte-for-byte. In particular, do
        // not reinterpret backslashes or substitutions while preparing UI.
        return token.raw
    }

    private static func tokenize(_ source: String) -> [LexicalToken]? {
        var result: [LexicalToken] = []
        var wordStart: String.Index?
        var value = ""
        var quote: Character?
        var escaped = false

        func finish(_ end: String.Index, source: String) {
            guard let start = wordStart else { return }
            result.append(LexicalToken(value: value, raw: String(source[start..<end])))
            wordStart = nil
            value = ""
        }

        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if escaped {
                value.append(character)
                escaped = false
                index = source.index(after: index)
                continue
            }
            if character == "\\" && quote != "'" {
                if wordStart == nil { wordStart = index }
                escaped = true
                index = source.index(after: index)
                continue
            }
            if quote != nil {
                if character == quote { quote = nil }
                else { value.append(character) }
                index = source.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                if wordStart == nil { wordStart = index }
                quote = character
                index = source.index(after: index)
                continue
            }
            // Operators outside the sole quoted command argument belong to
            // the caller's shell, not to a wrapper we can safely remove.
            if ";$|&<>()`".contains(character) { return nil }
            if character.isWhitespace {
                finish(index, source: source)
            } else {
                if wordStart == nil { wordStart = index }
                value.append(character)
            }
            index = source.index(after: index)
        }
        guard quote == nil, !escaped else { return nil }
        finish(source.endIndex, source: source)
        return result
    }

    private static let recognizedShells: Set<String> = ["sh", "bash", "zsh"]
    private static let shellFlags: Set<String> = ["-l", "-i", "--login", "--interactive", "--noprofile", "--norc", "--no-profile", "--no-rcs"]

    private static func basename(_ value: String) -> String {
        value.split(separator: "/").last.map(String.init) ?? value
    }

    private static func isEnvironmentAssignment(_ value: String) -> Bool {
        guard let equals = value.firstIndex(of: "="), equals > value.startIndex else { return false }
        let name = value[..<equals]
        guard let first = name.first, first == "_" || first.isASCII && first.isLetter else { return false }
        return name.dropFirst().allSatisfy { $0 == "_" || $0.isASCII && $0.isLetter || $0.isASCII && $0.isNumber }
    }

    private static func integer(_ value: ThreadValue?) -> Int64? {
        guard let value = value?.number, value.isFinite, value.rounded() == value,
              value >= -9_223_372_036_854_775_808.0, value < 9_223_372_036_854_775_808.0 else { return nil }
        return Int64(value)
    }

    private static func compactDuration(_ value: ThreadValue?) -> String? {
        guard let rawMilliseconds = value?.number, rawMilliseconds.isFinite, rawMilliseconds >= 0,
              rawMilliseconds.rounded() == rawMilliseconds, rawMilliseconds <= 9_007_199_254_740_991 else { return nil }
        let milliseconds = Int64(rawMilliseconds)
        if milliseconds < 1_000 { return "\(milliseconds)ms" }
        if milliseconds < 60_000 {
            if milliseconds % 1_000 == 0 { return "\(milliseconds / 1_000)s" }
            let seconds = milliseconds / 1_000
            let tenths = (milliseconds % 1_000 + 50) / 100
            if tenths == 10 { return "\(seconds + 1)s" }
            return "\(seconds).\(tenths)s"
        }
        let seconds = milliseconds / 1_000
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes < 60 { return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }

    private static func singleLine(_ value: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in value {
            if character.isWhitespace {
                if !result.isEmpty { pendingSpace = true }
                continue
            }
            if pendingSpace { result.append(" "); pendingSpace = false }
            result.append(character)
        }
        return result
    }
}

public struct ContextCompactionPresentation: Equatable, Sendable {
    public let label: String
    public let symbol: String
    public let isRunning: Bool

    public static func forState(_ state: String) -> Self {
        switch state.lowercased() {
        case "started", "streaming", "waiting":
            return Self(label: "Compacting context…", symbol: "arrow.triangle.2.circlepath", isRunning: true)
        case "completed":
            return Self(label: "Context compacted", symbol: "text.badge.checkmark", isRunning: false)
        case "interrupted":
            return Self(label: "Context compaction stopped", symbol: "stop.circle", isRunning: false)
        case "failed":
            return Self(label: "Context compaction failed", symbol: "exclamationmark.triangle", isRunning: false)
        default:
            return Self(label: "Context compaction status unavailable", symbol: "questionmark.circle", isRunning: false)
        }
    }
}

extension ReadRow {
    /// Only confirmed tool results become status lines; failures retain their details.
    public var profileStatus: String? {
        if let groupStatus { return groupStatus }
        guard !isUser, let item, item.type == "dynamicToolCall", item.state == "completed",
              let payload = item.payload, payload["tool"]?.string == "wonder_update_profile",
              payload["success"]?.bool == true,
              let output = (payload["contentItems"] ?? payload["result"])?.toolOutputText,
              let data = output.data(using: .utf8),
              let result = try? JSONDecoder().decode([String: ThreadValue].self, from: data),
              result["saved"]?.bool == true else { return nil }
        return result["statusLine"]?.string ?? "Bot updated"
    }

    public var activitySummary: ActivityPresentation? { presentation(includeDetails: false) }
    public var activity: ActivityPresentation? { presentation(includeDetails: true) }
    public var isContextCompaction: Bool { !isUser && item?.type == "contextCompaction" }
    public var contextCompactionPresentation: ContextCompactionPresentation? {
        guard isContextCompaction, let item else { return nil }
        return .forState(item.state)
    }

    private func presentation(includeDetails: Bool) -> ActivityPresentation? {
        guard profileStatus == nil, !isUser, let item, !["userMessage", "agentMessage", "approval"].contains(item.type) else { return nil }
        let payload = item.payload ?? [:]
        var details: [ActivityDetail] = []
        func add(_ title: String, _ makeText: @autoclosure () -> String?) {
            guard includeDetails, let text = makeText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            details.append(ActivityDetail(title: title, text: text))
        }
        func value(_ key: String) -> String? {
            guard let value = payload[key], value != .null else { return nil }
            if let text = value.string { return text }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        }
        let title: String
        let symbol: String
        switch item.type {
        case "commandExecution":
            title = "Run command"; symbol = "terminal"
            add("Command", value("command")); add("Folder", value("cwd"))
            add("Output", value("output") ?? value("aggregatedOutput"))
            add("Exit code", value("exitCode"))
        case "webSearch":
            var action: [String: ThreadValue] = [:]
            if case .object(let fields) = payload["action"] { action = fields }
            switch action["type"]?.string {
            case "openPage": title = "Open web page"
            case "findInPage": title = "Find in page"
            default: title = "Search the web"
            }
            symbol = "magnifyingglass"
            add("Search", value("query") ?? action["query"]?.string
                ?? action["queries"]?.array?.compactMap(\.string).joined(separator: "\n"))
            add("Page", action["url"]?.string); add("Find", action["pattern"]?.string)
            add("Results", value("resultCount"))
        case "fileChange":
            title = fileChangeSummary?.title ?? "Edited a file"; symbol = "doc.badge.gearshape"
            add("Files", payload["paths"]?.array?.compactMap(\.string).map(FileChangeSummary.filename).joined(separator: "\n"))
            add("Added lines", value("additions")); add("Removed lines", value("deletions"))
            for change in includeDetails ? (payload["diffs"]?.array ?? []) : [] {
                if case .object(let fields) = change, let diff = fields["diff"]?.string, !diff.isEmpty {
                    details.append(ActivityDetail(title: fields["path"]?.string.map(FileChangeSummary.filename) ?? "Changes", text: diff, isDiff: true, filePath: FileChangeSummary.relativePath(fields["path"]?.string)))
                }
            }
            add("Changes", value("detail"))
        case "collabAgentToolCall":
            let agent = payload["agentNickname"]?.string
                ?? payload["agentRole"]?.string
                ?? payload["senderThreadId"]?.string
                ?? "Subagent"
            let state = payload["status"]?.string
                ?? payload["kind"]?.string
                ?? item.state
            title = "\(agent) · \(state.replacingOccurrences(of: "_", with: " ").capitalized)"
            symbol = "person.2"
            add("Details", value("result") ?? "A subagent collaboration update.")
            add("Input", value("arguments"))
        case "mcpToolCall", "dynamicToolCall":
            title = (payload["tool"]?.string ?? "Tool call").replacingOccurrences(of: "_", with: " ").capitalized
            symbol = "wrench.and.screwdriver"
            add("Input", value("arguments")); add("Result", (payload["result"] ?? payload["contentItems"])?.toolOutputText)
        case "imageView":
            title = "Image"; symbol = "photo"
            add("Result", payload["result"]?.toolOutputText)
        case "imageGeneration":
            title = "Generate image"; symbol = "photo"
            // Older Mac versions stored truncated base64 here. Keep it out of
            // the detail view until history refresh provides a verified file.
            if payload["result"]?.string != nil {
                add("Result", "Preview unavailable. Update Wonder on your Mac and refresh this chat’s history.")
            } else {
                add("Result", payload["result"]?.toolOutputText)
            }
            add("Error", value("failure"))
        case "functionCallOutput":
            title = "Tool result"; symbol = "checklist"
            add("Result", payload["output"]?.toolOutputText ?? item.text)
        case "error":
            title = "Couldn’t complete an action"; symbol = "exclamationmark.triangle"
            add("Error", item.text)
        case "reasoning": title = "Thinking"; symbol = "ellipsis"
        case "plan":
            title = "Plan"; symbol = "list.bullet.clipboard"; add("Plan", item.text)
        case "hookPrompt":
            title = "Additional instructions"; symbol = "text.badge.plus"
            if includeDetails {
                let fragments = payload["fragments"]?.array?.compactMap { fragment -> String? in
                    guard case .object(let fields) = fragment,
                          let text = fields["text"]?.string else { return nil }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                } ?? []
                add("Instructions", fragments.isEmpty ? nil : fragments.joined(separator: "\n\n"))
            }
        case "subAgentActivity":
            symbol = "person.2"
            let agent = payload["agentNickname"]?.string
                ?? payload["agentRole"]?.string
                ?? payload["agentPath"]?.string
                ?? "Subagent"
            let state = (payload["status"]?.string ?? payload["kind"]?.string ?? item.state)
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            title = "\(agent) · \(state)"
            switch payload["kind"]?.string {
            case "started":
                add("Details", "Another agent was started.")
            case "interacted":
                add("Details", "Another agent received an update.")
            case "interrupted":
                add("Details", "Another agent was stopped.")
            case "completed":
                add("Details", "Another agent finished its work.")
            default:
                add("Details", "A subagent activity update.")
            }
        case "sleep":
            title = "Wait"; symbol = "clock"
            add("Requested duration", Self.durationLabel(payload["durationMs"]))
        case "enteredReviewMode":
            title = "Start review"; symbol = "checkmark.shield"
            add("Review", payload["review"]?.string)
        case "exitedReviewMode":
            title = "Finish review"; symbol = "checkmark.shield.fill"
            add("Review", payload["review"]?.string)
        case "contextCompaction":
            let marker = ContextCompactionPresentation.forState(item.state)
            title = "Context compaction"; symbol = marker.symbol
            // The runtime item may carry a private summary or instruction
            // body. Compaction is represented only by the structural marker.
        default:
            title = "New activity"; symbol = "ellipsis.circle"
            add("Details", "This activity isn’t supported in this version of Wonder, so its details are unavailable.")
        }
        if item.type != "error" && item.type != "contextCompaction" { add("Error", value("error")) }
        let resultIsError: Bool
        if case .object(let result) = payload["result"] { resultIsError = result["isError"]?.bool == true }
        else { resultIsError = false }
        let failureHint = resultIsError || item.type == "error" || payload["success"]?.bool == false
            || (item.type == "imageGeneration" && payload["failure"].map { $0 != .null && $0.string != "" } == true)
            || payload["error"].map { $0 != .null && $0.string != "" } == true
        let failed: Bool
        if item.type == "commandExecution" {
            let hasTerminalHints = failureHint || payload["exitCode"]?.number.map { $0 != 0 } == true
            failed = commandSummary?.failed ?? (!["started", "streaming", "waiting", "interrupted"].contains(item.state) && hasTerminalHints)
        } else {
            failed = failureHint
        }
        return ActivityPresentation(title: title, symbol: symbol, state: failed ? "failed" : item.state, details: details, kind: item.type)
    }

    /// Convert the schema's nonnegative integer milliseconds into a short,
    /// human-readable duration. Invalid or unrepresentable values stay hidden.
    /// A Double can represent integers exactly only through 2^53 - 1; values
    /// above that boundary are not safe to present as a claimed duration.
    private static func durationLabel(_ value: ThreadValue?) -> String? {
        guard let rawMilliseconds = value?.number,
              rawMilliseconds.isFinite,
              rawMilliseconds >= 0,
              rawMilliseconds.rounded() == rawMilliseconds,
              rawMilliseconds <= 9_007_199_254_740_991 else { return nil }
        let milliseconds = Int64(rawMilliseconds)
        if milliseconds < 1_000 {
            return quantity(milliseconds, singular: "millisecond")
        }

        var seconds = milliseconds / 1_000
        let remainder = milliseconds % 1_000
        if seconds < 60 {
            if remainder == 0 { return quantity(seconds, singular: "second") }
            let tenths = (remainder + 50) / 100
            if tenths == 10 {
                seconds += 1
                return seconds == 60 ? "1 minute" : quantity(seconds, singular: "second")
            }
            return "\(seconds).\(tenths) seconds"
        }

        let minutes = seconds / 60
        seconds %= 60
        if minutes < 60 {
            return [quantity(minutes, singular: "minute"), seconds > 0 ? quantity(seconds, singular: "second") : nil]
                .compactMap { $0 }.joined(separator: " ")
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            return [quantity(hours, singular: "hour"), remainingMinutes > 0 ? quantity(remainingMinutes, singular: "minute") : nil]
                .compactMap { $0 }.joined(separator: " ")
        }

        let days = hours / 24
        let remainingHours = hours % 24
        return [quantity(days, singular: "day"), remainingHours > 0 ? quantity(remainingHours, singular: "hour") : nil]
            .compactMap { $0 }.joined(separator: " ")
    }

    private static func quantity(_ value: Int64, singular: String) -> String {
        "\(value) \(value == 1 ? singular : singular + "s")"
    }
}

// Tool content is a union, not necessarily a printable JSON object. Keep media
// inert until the attachment renderer can validate and display it.
extension ThreadValue {
    var toolOutputText: String {
        switch self {
        case .string(let text): return text
        case .null: return ""
        case .array(let values): return values.map(\.toolOutputText).filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .object(let fields):
            switch fields["type"]?.string {
            case "inputText", "input_text", "output_text", "text": return fields["text"]?.string ?? ""
            case "wonderArtifact": return ""
            case "inputImage", "input_image", "image": return "Image result — preview unavailable"
            case "inputAudio", "input_audio", "audio": return "Audio result — playback unavailable"
            case "resource", "resource_link": return "Resource result — preview unavailable"
            default: break
            }
            if let content = fields["content"] {
                let text = content.toolOutputText
                if !text.isEmpty { return text }
                if let structured = fields["structuredContent"] { return structured.toolOutputText }
                return ""
            }
            return formattedJSON
        default: return formattedJSON
        }
    }
    private var formattedJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

extension ReadRow {
    public var toolFiles: [ConversationFile] {
        guard let payload = item?.payload else { return [] }
        return ["result", "contentItems", "output"].flatMap { payload[$0]?.toolFiles ?? [] }
    }
}
extension ThreadValue {
    var toolFiles: [ConversationFile] {
        switch self {
        case .array(let values): return values.flatMap(\.toolFiles)
        case .object(let fields):
            if fields["type"]?.string == "wonderArtifact", let value = fields["file"],
               let bytes = try? JSONEncoder().encode(value),
               let file = try? JSONDecoder().decode(ConversationFile.self, from: bytes) { return [file] }
            return ["content", "contentItems"].flatMap { fields[$0]?.toolFiles ?? [] }
        default: return []
        }
    }
}
