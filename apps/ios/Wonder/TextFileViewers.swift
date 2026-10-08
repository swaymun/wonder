import SwiftUI
import UIKit
import WonderPairing

/// Prepared viewer content per (file hash, view, theme), bounded in count and
/// bytes so reopening a file or flipping a toggle does not redo the work.
final class TextViewerCache: @unchecked Sendable {
    static let shared = TextViewerCache()
    private let cache: NSCache<NSString, AnyObject> = {
        let cache = NSCache<NSString, AnyObject>()
        cache.countLimit = 40
        cache.totalCostLimit = 8_000_000
        return cache
    }()

    static func key(sha: String, view: String, theme: WonderTheme? = nil) -> String {
        "\(sha)|\(view)|\(theme?.cacheKey ?? "-")"
    }
    func value<T: AnyObject>(_ type: T.Type, for key: String) -> T? { cache.object(forKey: key as NSString) as? T }
    func store(_ value: AnyObject, for key: String, cost: Int) {
        cache.setObject(value, forKey: key as NSString, cost: cost)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The Preview | Source switch shared by Markdown and JSON files. The choice is
/// remembered per device and kind.
struct TextViewerModeBar: View {
    let kind: TextViewerKind
    @Binding var mode: TextViewerMode
    var onCopy: (() -> Void)?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Picker("View", selection: Binding(get: { mode }, set: { newValue in
                mode = newValue
                TextViewerPreference.remember(newValue, for: kind)
            })) {
                Text(kind.titles.rendered).tag(TextViewerMode.rendered)
                Text(kind.titles.source).tag(TextViewerMode.source)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .accessibilityIdentifier("workspace-viewer-mode")
            Spacer(minLength: 0)
            if let onCopy {
                Button {
                    onCopy()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("workspace-viewer-copy")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
    }
}

/// Rendered Markdown with the message renderer. The text is cut into chunks of a
/// few KB off the main thread and shown in a lazy stack, so each parse is small
/// and only visible chunks are laid out. Past a size limit the rest waits behind
/// "Show all"; the Source view is always the whole file.
struct MarkdownFileView: View {
    let text: String
    let sha: String
    static let initialLimitBytes = 64 * 1024
    @State private var chunks: [String]?
    @State private var showAll = false

    var body: some View {
        ScrollView {
            if let chunks {
                let visible = showAll ? chunks.count : MarkdownChunker.visibleCount(of: chunks, limitBytes: Self.initialLimitBytes)
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<visible, id: \.self) { index in
                        BotMessageText(text: chunks[index])
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if visible < chunks.count {
                        Button("Show all (\(ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)))") { showAll = true }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("workspace-markdown-show-all")
                    }
                }
                .padding(16)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            } else {
                ProgressView().padding(40).frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier("workspace-markdown-preview")
        .task(id: sha) {
            showAll = false
            let key = TextViewerCache.key(sha: sha, view: "markdown-chunks")
            if let cached = TextViewerCache.shared.value(ChunkBox.self, for: key) { chunks = cached.chunks; return }
            chunks = nil
            let source = text
            let result = await Task.detached(priority: .userInitiated) { MarkdownChunker.chunks(source) }.value
            guard !Task.isCancelled else { return }
            TextViewerCache.shared.store(ChunkBox(result), for: key, cost: source.utf8.count * 2)
            chunks = result
        }
    }

    private final class ChunkBox { let chunks: [String]; init(_ chunks: [String]) { self.chunks = chunks } }
}

/// Source and raw text is monospaced and exact: long tokens break at any character
/// and never take a hyphen. Layout only; the characters are unchanged.
enum SourceTextLayout {
    static func paragraph() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        style.hyphenationFactor = 0
        return style
    }

    static func apply(to storage: NSTextStorage) {
        guard storage.length > 0 else { return }
        storage.addAttribute(.paragraphStyle, value: paragraph(), range: NSRange(location: 0, length: storage.length))
    }
}

/// Read-only, selectable, scrollable attributed text. UITextView lays out only
/// what is on screen, so a long formatted document stays cheap. Updates are
/// idempotent: the text is replaced only when `identity` changes.
struct ReadOnlyAttributedTextView: UIViewRepresentable {
    let text: NSAttributedString
    let identity: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view.textContainer.lineFragmentPadding = 0
        view.attributedText = text
        SourceTextLayout.apply(to: view.textStorage)
        context.coordinator.identity = identity
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        guard context.coordinator.identity != identity else { return }
        context.coordinator.identity = identity
        view.attributedText = text
        SourceTextLayout.apply(to: view.textStorage)
        view.setContentOffset(CGPoint(x: 0, y: -view.adjustedContentInset.top), animated: false)
    }
    final class Coordinator { var identity = "" }
}

private final class PreparedJSON: @unchecked Sendable {
    let shown: String
    let attributed: NSAttributedString
    let notice: String?
    init(shown: String, attributed: NSAttributedString, notice: String?) {
        self.shown = shown; self.attributed = attributed; self.notice = notice
    }

    /// Pure: formats and colours off the main thread. Files cut at the preview
    /// limit cannot be valid JSON, so they are shown as written.
    static func make(text: String, truncated: Bool, palette: ThemePalette) -> PreparedJSON {
        func plain(_ notice: String) -> PreparedJSON {
            PreparedJSON(shown: text, attributed: attributed(lines: nil, plain: text, palette: palette), notice: notice)
        }
        if truncated { return plain("This file is too large to format here, so the first part is shown as written.") }
        switch JSONFormatter.format(text) {
        case .formatted(let pretty):
            return PreparedJSON(shown: pretty, attributed: attributed(lines: JSONFormatter.highlightedLines(pretty),
                                                                      plain: pretty, palette: palette), notice: nil)
        case .invalid(let error):
            return plain("This file isn't valid JSON; showing it as-is. \(error.summary).")
        case .tooLarge:
            return plain("This file is too large to format here; showing it as-is.")
        }
    }

    /// Coloured when `lines` are given, otherwise `plain` in the theme's text colour.
    private static func attributed(lines: [[SyntaxSpan]]?, plain: String, palette: ThemePalette) -> NSAttributedString {
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        let base = UIColor(hex: palette.primaryText)
        guard let lines else {
            return NSAttributedString(string: plain, attributes: [.font: font, .foregroundColor: base])
        }
        let output = NSMutableAttributedString()
        for (index, spans) in lines.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            for span in spans {
                let color = span.role.map { UIColor(hex: palette.color(for: $0)) } ?? base
                output.append(NSAttributedString(string: span.text, attributes: [.font: font, .foregroundColor: color]))
            }
        }
        return output
    }
}

private struct ViewerNotice: View {
    let text: String
    let id: String
    var body: some View {
        Text(text)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground))
            .accessibilityIdentifier(id)
    }
}

/// Pretty-printed, syntax-coloured JSON. Key order and number text are exactly
/// as written. Formatting runs off the main thread and is cached per file,
/// view and theme; `onShownText` reports what Copy should put on the pasteboard.
struct JSONFileView: View {
    let text: String
    let sha: String
    let truncated: Bool
    let onShownText: (String) -> Void
    @Environment(\.wonderTheme) private var theme
    @State private var prepared: PreparedJSON?

    var body: some View {
        let key = TextViewerCache.key(sha: sha, view: "json-formatted", theme: theme)
        VStack(spacing: 0) {
            if let notice = prepared?.notice { ViewerNotice(text: notice, id: "workspace-json-notice") }
            if let prepared {
                ReadOnlyAttributedTextView(text: prepared.attributed, identity: key)
                    .accessibilityIdentifier("workspace-json-formatted")
            } else {
                ProgressView("Formatting…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: key) {
            if let cached = TextViewerCache.shared.value(PreparedJSON.self, for: key) {
                prepared = cached; onShownText(cached.shown); return
            }
            prepared = nil
            let (source, truncated, palette) = (text, truncated, theme.palette)
            let result = await Task.detached(priority: .userInitiated) {
                PreparedJSON.make(text: source, truncated: truncated, palette: palette)
            }.value
            guard !Task.isCancelled else { return }
            TextViewerCache.shared.store(result, for: key, cost: source.utf8.count * 6)
            prepared = result
            onShownText(result.shown)
        }
    }
}

private final class PreparedJSONL {
    let document: JSONLDocument
    init(_ document: JSONLDocument) { self.document = document }
}

private final class PreparedRecordText {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

/// A formatted JSON Lines record's text, coloured off the main thread.
private struct RecordText: View {
    let text: String
    let sha: String
    let line: Int
    @Environment(\.wonderTheme) private var theme
    @State private var colored: (key: String, text: AttributedString)?

    var body: some View {
        let key = TextViewerCache.key(sha: sha, view: "jsonl-record-\(line)", theme: theme)
        let shown = TextViewerCache.shared.value(PreparedRecordText.self, for: key)?.value
            ?? (colored?.key == key ? colored?.text : nil)
        Text(shown ?? AttributedString(text))
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(theme.primaryText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: key) {
                guard shown == nil, let lines = JSONFormatter.highlightedLines(text, maxBytes: 64 * 1024) else { return }
                let palette = theme.palette
                let result = await Task.detached(priority: .userInitiated) {
                    CodeHighlightCache.attributed(lines: lines, palette: palette)
                }.value
                guard !Task.isCancelled else { return }
                TextViewerCache.shared.store(PreparedRecordText(result), for: key, cost: text.utf8.count * 6)
                colored = (key, result)
            }
    }
}

/// A JSON Lines file: one collapsible record per line, with its line number.
/// Invalid and oversize lines stay visible as written and are marked. Records
/// live in a lazy stack and are formatted off the main thread.
struct JSONLFileView: View {
    let text: String
    let sha: String
    let truncated: Bool
    let onShownText: (String) -> Void
    @State private var document: JSONLDocument?
    @State private var expanded: Set<Int> = []

    var body: some View {
        Group { content }.task(id: sha) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let document {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(document.records.count == 1 ? "1 record" : "\(document.records.count) records")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    ForEach(document.records) { record in
                        row(record)
                        Divider()
                    }
                    if document.omittedLines > 0 {
                        Text("\(document.omittedLines) more lines aren't shown here. Switch to Raw to read them.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(16)
                            .accessibilityIdentifier("workspace-jsonl-omitted")
                    }
                }
            }
            .accessibilityIdentifier("workspace-jsonl-records")
        } else {
            ProgressView("Formatting…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func row(_ record: JSONLRecord) -> some View {
        if let formatted = record.formatted {
            let isOpen = expanded.contains(record.line)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if isOpen { expanded.remove(record.line) } else { expanded.insert(record.line) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0)).foregroundStyle(.secondary)
                        Text("Line \(record.line)").font(.caption.weight(.semibold).monospacedDigit())
                        if !isOpen {
                            Text(record.raw).font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Line \(record.line)")
                .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("jsonl-record:\(record.line)")
                if isOpen { RecordText(text: formatted, sha: sha, line: record.line).padding(.bottom, 10) }
            }
            .padding(.horizontal, 16)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Line \(record.line)").font(.caption.weight(.semibold).monospacedDigit())
                    Text(record.isOversize ? "Too large to format" : "Not valid JSON")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(record.raw).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let error = record.error {
                    Text(error.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("jsonl-record:\(record.line)")
        }
    }

    private func load() async {
        let key = TextViewerCache.key(sha: sha, view: "jsonl-records")
        if let cached = TextViewerCache.shared.value(PreparedJSONL.self, for: key) {
            apply(cached.document); return
        }
        let (source, truncated) = (text, truncated)
        let result = await Task.detached(priority: .userInitiated) {
            JSONLDocument(parsing: source, isTruncated: truncated)
        }.value
        guard !Task.isCancelled else { return }
        TextViewerCache.shared.store(PreparedJSONL(result), for: key, cost: source.utf8.count * 4)
        apply(result)
    }
    private func apply(_ result: JSONLDocument) {
        document = result
        expanded = result.records.first(where: { $0.formatted != nil }).map { [$0.line] } ?? []
        onShownText(result.shownText)
    }
}

/// Colours for a text view's source, by UTF-16 range. Applied to the text
/// storage after the text itself, so selection offsets are untouched.
struct PreviewColorRuns: Equatable {
    let key: String
    let runs: [SyntaxRun]
    let palette: ThemePalette

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    func apply(to storage: NSTextStorage, base: UIColor) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: base, range: full)
        for run in runs where NSMaxRange(run.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: UIColor(hex: palette.color(for: run.role)), range: run.range)
        }
        storage.endEditing()
    }
}
