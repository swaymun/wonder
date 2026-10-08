import SwiftUI
import WonderPairing

/// Finished highlighted text per (code, language, theme), bounded in count and
/// bytes so scrolling back through a long chat does not re-tokenize.
final class CodeHighlightCache: @unchecked Sendable {
    static let shared = CodeHighlightCache()
    private final class Box { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }
    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 80
        cache.totalCostLimit = 4_000_000
        return cache
    }()

    static func key(code: String, language: String?, theme: WonderTheme) -> String {
        "\(theme.cacheKey)|\(language ?? "")|\(code.utf8.count)|\(code.hashValue)"
    }
    func value(for key: String) -> AttributedString? { cache.object(forKey: key as NSString)?.value }
    func store(_ value: AttributedString, for key: String, cost: Int) {
        cache.setObject(Box(value), forKey: key as NSString, cost: cost)
    }

    /// Tokenizes and colours a block with the theme's syntax palette. Pure, so
    /// callers run it off the main thread; nil when the block stays plain.
    static func highlight(_ code: String, language: String?, palette: ThemePalette) -> AttributedString? {
        guard let lines = CodeHighlighter.lines(code, language: language) else { return nil }
        return attributed(lines: lines, palette: palette)
    }

    /// Joins tokenized lines into coloured text with the theme's syntax palette.
    static func attributed(lines: [[SyntaxSpan]], palette: ThemePalette) -> AttributedString {
        var output = AttributedString()
        for (index, spans) in lines.enumerated() {
            if index > 0 { output.append(AttributedString("\n")) }
            for span in spans {
                var run = AttributedString(span.text)
                if let role = span.role { run.foregroundColor = Color(hex: palette.color(for: role)) }
                output.append(run)
            }
        }
        return output
    }
}

/// A fenced code block in a message. It shows plain text at once and swaps in
/// the coloured text when the off-main tokenizer finishes, or immediately from
/// the cache. Unknown languages and very long blocks stay plain.
struct CodeBlockView: View {
    let code: String
    let language: String?
    @Environment(\.wonderTheme) private var theme
    @State private var colored: (key: String, text: AttributedString)?

    var body: some View {
        let key = CodeHighlightCache.key(code: code, language: language, theme: theme)
        let text = CodeHighlightCache.shared.value(for: key) ?? (colored?.key == key ? colored?.text : nil)
        ScrollView(.horizontal) {
            Text(text ?? AttributedString(code))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                .padding(10)
        }
        .background(theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
        .task(id: key) {
            guard text == nil, CodeHighlighter.supports(language: language) else { return }
            // A streaming block changes on every delta; wait for it to settle.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let (code, language, palette) = (code, language, theme.palette)
            let result = await Task.detached(priority: .userInitiated) {
                CodeHighlightCache.highlight(code, language: language, palette: palette)
            }.value
            guard !Task.isCancelled, let result else { return }
            CodeHighlightCache.shared.store(result, for: key, cost: code.utf8.count * 4)
            colored = (key, result)
        }
    }
}
