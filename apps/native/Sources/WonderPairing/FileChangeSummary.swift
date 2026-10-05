import Foundation

/// Prepared with the read row, never by scanning patches during SwiftUI layout.
public struct FileChangeSummary: Equatable, Sendable {
    public let action: String
    public let target: String
    public let path: String?
    public let title: String
    public let fileCount: Int
    public let additions: Int?
    public let deletions: Int?
    public let accessibilityLabel: String

    public static func filename(_ path: String) -> String {
        guard !path.isEmpty, !path.hasPrefix("[") else { return "a file" }
        return path.split(separator: "/").last.map(String.init) ?? "a file"
    }

    public static func relativePath(_ path: String?) -> String? {
        guard let path, !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("["), !path.contains("\0"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return path
    }

    public static func prepare(_ item: ReadItem) -> Self? {
        guard item.type == "fileChange" else { return nil }
        let payload = item.payload ?? [:]
        let diffs = (payload["diffs"]?.array ?? []).compactMap { value -> [String: ThreadValue]? in
            if case .object(let fields) = value { return fields }; return nil
        }
        let paths = payload["paths"]?.array?.compactMap(\.string) ?? diffs.compactMap { $0["path"]?.string }
        let count = max(paths.count, diffs.count)
        let target = count > 1 ? "\(count) files" : paths.first.map(filename) ?? "a file"
        let kinds = Set(diffs.compactMap { $0["kind"]?.string })
        let verb: String
        switch item.state {
        case "completed": verb = kinds == ["add"] ? "Wrote" : kinds == ["delete"] ? "Deleted" : "Edited"
        case "started", "streaming", "waiting": verb = "Editing"
        case "failed": verb = "Couldn’t edit"
        case "interrupted": verb = "Stopped editing"
        default: verb = "Changes to"
        }
        func total(_ key: String, marker: Character) -> Int? {
            if let value = payload[key]?.number, value.isFinite, value >= 0, value <= Double(Int32.max) { return Int(value) }
            guard !diffs.isEmpty, diffs.allSatisfy({ $0[key]?.number != nil || $0["diff"]?.string != nil }) else { return nil }
            return diffs.reduce(0) { total, fields in
                if let value = fields[key]?.number, value.isFinite, value >= 0, value <= Double(Int32.max) { return total + Int(value) }
                return total + (fields["diff"]?.string?.split(separator: "\n").filter {
                    $0.first == marker && !$0.hasPrefix(String(repeating: String(marker), count: 3))
                }.count ?? 0)
            }
        }
        let added = total("additions", marker: "+"), removed = total("deletions", marker: "-")
        let title = "\(verb) \(target)"
        let counts = [added.map { "\($0) added lines" }, removed.map { "\($0) removed lines" }].compactMap { $0 }
        return Self(action: verb, target: target, path: count == 1 ? relativePath(paths.first) : nil, title: title, fileCount: max(count, 1), additions: added, deletions: removed,
                    accessibilityLabel: ([title] + counts).joined(separator: ", "))
    }
}

/// Saved edits from one response, distinct from the workspace's current Git status.
/// Patch strings stay inert and are assembled only when their file is opened.
public struct ResponseEditedFile: Identifiable, Sendable {
    public let path: String
    public var additions: Int?
    public var deletions: Int?
    public var patches: [String]
    /// The host caps each saved patch; its line counts still describe the full edit.
    public var partial = false
    public var id: String { path }
    public var name: String { FileChangeSummary.filename(path) }
}

public struct ResponseEditedFiles: Sendable {
    public let turnID: String
    public let files: [ResponseEditedFile]

    /// Attach once, after the turn's last visible entry, even when commentary
    /// splits its activity into several groups. Failed/pending edits are not receipts.
    public static func footers(entries: [ChatFeedEntry], activeTurnIDs: Set<String>) -> [String: Self] {
        var lastEntry: [String: String] = [:]
        var files: [String: [ResponseEditedFile]] = [:]
        var indices: [String: [String: Int]] = [:]
        for entry in entries {
            for row in entry.rows {
                guard !row.isUser, let turn = row.turnId, !activeTurnIDs.contains(turn) else { continue }
                lastEntry[turn] = entry.id
                guard let item = row.item, item.type == "fileChange", item.state == "completed" else { continue }
                let payload = item.payload ?? [:]
                let diffs = (payload["diffs"]?.array ?? []).compactMap { value -> [String: ThreadValue]? in
                    if case .object(let fields) = value { return fields }; return nil
                }
                let savedPaths = payload["paths"]?.array?.compactMap(\.string) ?? []
                let paths = savedPaths.isEmpty ? diffs.compactMap { $0["path"]?.string } : savedPaths
                let byPath = Dictionary(grouping: diffs, by: { $0["path"]?.string ?? "" })
                var seen = Set<String>()
                for path in paths where !path.isEmpty && seen.insert(path).inserted {
                    let matching = byPath[path] ?? []
                    func count(_ key: String) -> Int? {
                        if paths.count == 1 {
                            return key == "additions" ? row.fileChangeSummary?.additions : row.fileChangeSummary?.deletions
                        }
                        let values = matching.compactMap { $0[key]?.number }
                        if !matching.isEmpty, values.count == matching.count,
                           values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= Double(Int32.max) }) {
                            return values.reduce(0) { $0 + Int($1) }
                        }
                        guard !matching.isEmpty, matching.allSatisfy({ $0["diff"]?.string != nil }) else { return nil }
                        let marker = key == "additions" ? "+" : "-"
                        return matching.reduce(0) { total, fields in
                            total + (fields["diff"]?.string?.split(separator: "\n").filter {
                                $0.hasPrefix(marker) && !$0.hasPrefix(String(repeating: marker, count: 3))
                            }.count ?? 0)
                        }
                    }
                    let added = count("additions"), removed = count("deletions")
                    let patches = matching.compactMap { $0["diff"]?.string }.filter { !$0.isEmpty }
                    let partial = matching.contains { fields in
                        guard let text = fields["diff"]?.string else { return false }
                        let lines = text.split(separator: "\n")
                        func short(_ key: String, _ marker: String) -> Bool {
                            guard let expected = fields[key]?.number, expected.isFinite else { return false }
                            let shown = lines.filter { $0.hasPrefix(marker) && !$0.hasPrefix(String(repeating: marker, count: 3)) }.count
                            return Double(shown) < expected
                        }
                        return short("additions", "+") || short("deletions", "-")
                    }
                    if let index = indices[turn]?[path] {
                        var file = files[turn]![index]
                        file.additions = file.additions.flatMap { prior in added.map { prior + $0 } }
                        file.deletions = file.deletions.flatMap { prior in removed.map { prior + $0 } }
                        file.patches += patches
                        file.partial = file.partial || partial
                        files[turn]![index] = file
                    } else {
                        indices[turn, default: [:]][path] = files[turn, default: []].count
                        files[turn, default: []].append(ResponseEditedFile(path: path, additions: added, deletions: removed, patches: patches, partial: partial))
                    }
                }
            }
        }
        return Dictionary(files.compactMap { turn, files in
            guard !files.isEmpty, let entry = lastEntry[turn] else { return nil }
            return (entry, Self(turnID: turn, files: files))
        }, uniquingKeysWith: { first, _ in first })
    }
}

/// One line of a unified diff, numbered for display. Hunk headers without
/// line numbers (as Claude's edits produce) leave the numbers unknown.
public struct DiffLine: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable { case context, added, removed, hunk, note }
    public let id: Int
    public let kind: Kind
    public let oldNumber: Int?
    public let newNumber: Int?
    public let text: String

    public static func parse(_ diff: String, limit: Int = 20_000) -> [DiffLine] {
        var lines: [DiffLine] = []
        var old: Int?, new: Int?
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(limit) {
            let line = String(raw)
            let id = lines.count
            if line.hasPrefix("@@") {
                let numbers = hunkStarts(line)
                old = numbers?.0; new = numbers?.1
                lines.append(DiffLine(id: id, kind: .hunk, oldNumber: nil, newNumber: nil, text: line))
            } else if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                lines.append(DiffLine(id: id, kind: .note, oldNumber: nil, newNumber: nil, text: line))
            } else if line.hasPrefix("Edit "), line.dropFirst(5).allSatisfy(\.isNumber) {
                old = nil; new = nil
                lines.append(DiffLine(id: id, kind: .note, oldNumber: nil, newNumber: nil, text: line))
            } else if line.hasPrefix("+") {
                lines.append(DiffLine(id: id, kind: .added, oldNumber: nil, newNumber: new, text: String(line.dropFirst())))
                new = new.map { $0 + 1 }
            } else if line.hasPrefix("-") {
                lines.append(DiffLine(id: id, kind: .removed, oldNumber: old, newNumber: nil, text: String(line.dropFirst())))
                old = old.map { $0 + 1 }
            } else if line.hasPrefix("\\") {
                lines.append(DiffLine(id: id, kind: .note, oldNumber: nil, newNumber: nil, text: line))
            } else {
                // A blank line at the very end is the patch's trailing newline.
                if line.isEmpty, raw.endIndex == diff.endIndex { continue }
                lines.append(DiffLine(id: id, kind: .context, oldNumber: old, newNumber: new,
                                      text: line.hasPrefix(" ") ? String(line.dropFirst()) : line))
                old = old.map { $0 + 1 }; new = new.map { $0 + 1 }
            }
        }
        return lines
    }

    private static func hunkStarts(_ header: String) -> (Int, Int)? {
        // @@ -12,3 +12,4 @@
        let parts = header.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let old = Int(parts[1].dropFirst().split(separator: ",")[0]),
              let new = Int(parts[2].dropFirst().split(separator: ",")[0]) else { return nil }
        return (old, new)
    }
}

/// Side-by-side rows: each removal pairs with the addition that replaced it.
public struct SplitDiffRow: Equatable, Sendable, Identifiable {
    public let id: Int
    public let left: DiffLine?
    public let right: DiffLine?

    public static func pair(_ lines: [DiffLine]) -> [SplitDiffRow] {
        var rows: [SplitDiffRow] = []
        var removed: [DiffLine] = [], added: [DiffLine] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                rows.append(SplitDiffRow(id: rows.count, left: index < removed.count ? removed[index] : nil,
                                         right: index < added.count ? added[index] : nil))
            }
            removed = []; added = []
        }
        for line in lines {
            switch line.kind {
            case .removed: if !added.isEmpty { flush() }; removed.append(line)
            case .added: added.append(line)
            default: flush(); rows.append(SplitDiffRow(id: rows.count, left: line, right: line))
            }
        }
        flush()
        return rows
    }
}
