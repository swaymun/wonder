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
