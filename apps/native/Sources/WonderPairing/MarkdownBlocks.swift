import Foundation

/// Block-level Markdown for chat bubbles. Inline syntax (emphasis, code spans,
/// links) is left to each block's text; this only finds the block structure.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case listItem(marker: String, depth: Int, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case table(header: [String], rows: [[String]])
    case rule

    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = [], quote: [String] = [], code: [String] = []
        var fence: (marker: Character, count: Int, language: String?)?
        let lines = text.components(separatedBy: "\n")
        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let indent = line.prefix(while: { $0 == " " }).count
            let body = line.dropFirst(indent)
            // Fenced code keeps every line exactly.
            if let open = fence {
                let count = body.prefix(while: { $0 == open.marker }).count
                if indent <= 3, count >= open.count, body.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                    blocks.append(.code(language: open.language, text: code.joined(separator: "\n"))); code = []; fence = nil
                } else { code.append(line) }
                continue
            }
            if indent <= 3, let marker = body.first, marker == "`" || marker == "~" {
                let count = body.prefix(while: { $0 == marker }).count
                let info = body.dropFirst(count).trimmingCharacters(in: .whitespaces)
                if count >= 3, marker != "`" || !info.contains("`") {
                    flushParagraph(); flushQuote()
                    fence = (marker, count, info.isEmpty ? nil : String(info.split(separator: " ")[0]))
                    continue
                }
            }
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flushParagraph(); flushQuote(); continue }
            if indent <= 3, body.hasPrefix(">") {
                flushParagraph()
                quote.append(String(body.dropFirst().drop(while: { $0 == " " })))
                continue
            }
            flushQuote()
            if indent <= 3, let level = heading(body) {
                flushParagraph()
                blocks.append(.heading(level: level, text: String(body.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if indent <= 3, isRule(trimmed) {
                flushParagraph(); blocks.append(.rule); continue
            }
            if let (marker, text) = listItem(body) {
                flushParagraph()
                blocks.append(.listItem(marker: marker, depth: min(indent / 2, 6), text: text))
                continue
            }
            // A pipe table needs a header and a --- separator row.
            if trimmed.hasPrefix("|") || trimmed.contains(" | "), index < lines.count, isTableSeparator(lines[index]) {
                flushParagraph()
                let header = cells(trimmed)
                index += 1
                var rows: [[String]] = []
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(normalized(cells(row), count: header.count)); index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            // A line under an open list item continues it.
            if indent >= 2, paragraph.isEmpty, case .listItem(let marker, let depth, let text)? = blocks.last {
                blocks[blocks.count - 1] = .listItem(marker: marker, depth: depth, text: text + "\n" + trimmed)
                continue
            }
            paragraph.append(line)
        }
        if fence != nil { blocks.append(.code(language: fence?.language, text: code.joined(separator: "\n"))) }
        flushParagraph(); flushQuote()
        return blocks
    }

    /// What the formatted message says, for VoiceOver and previews: block and
    /// inline syntax removed, list markers and table cells kept as words.
    public static func plainText(_ text: String) -> String {
        func inline(_ source: String) -> String {
            guard let value = try? AttributedString(markdown: source,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return source }
            return String(value.characters)
        }
        return parse(text).compactMap { block -> String? in
            switch block {
            case .paragraph(let text), .quote(let text): inline(text)
            case .heading(_, let text): inline(text)
            case .listItem(let marker, _, let text): (marker == "•" ? "" : marker + " ") + inline(text)
            case .code(_, let text): text
            case .table(let header, let rows):
                ([header] + rows).map { $0.map(inline).joined(separator: ", ") }.joined(separator: "\n")
            case .rule: nil
            }
        }.joined(separator: "\n")
    }

    private static func heading(_ body: Substring) -> Int? {
        let level = body.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = body.dropFirst(level)
        return rest.isEmpty || rest.first == " " ? level : nil
    }
    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }
    private static func listItem(_ body: Substring) -> (String, String)? {
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            let text = String(body.dropFirst(2))
            if text.hasPrefix("[ ] ") { return ("☐", String(text.dropFirst(4))) }
            if text.lowercased().hasPrefix("[x] ") { return ("☑", String(text.dropFirst(4))) }
            return ("•", text)
        }
        let digits = body.prefix(while: \.isNumber)
        guard (1...9).contains(digits.count) else { return nil }
        let rest = body.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")", rest.dropFirst().first == " " else { return nil }
        return (digits + ".", String(rest.dropFirst(2)))
    }
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }
    private static func cells(_ row: String) -> [String] {
        var row = row
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }
    private static func normalized(_ cells: [String], count: Int) -> [String] {
        Array((cells + Array(repeating: "", count: max(0, count - cells.count))).prefix(max(count, 1)))
    }
}
