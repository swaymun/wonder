import CryptoKit
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import ReadiumZIPFoundation
import SwiftUI

/// An unprotected EPUB read from a revision-bound copy of authenticated bytes.
struct WorkspacePublicationPreview: View {
    let name: String
    let data: Data
    let origin: String
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var reader = WorkspacePublicationReader()
    @State private var failure: String?
    @State private var largeText = false

    static func supports(_ name: String) -> Bool {
        URL(fileURLWithPath: name).pathExtension.lowercased() == "epub"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let navigator = reader.navigator {
                    PublicationNavigator(navigator: navigator)
                        .accessibilityIdentifier("workspace-epub-content")
                    if onClose != nil {
                        HStack(spacing: 16) {
                            readerControls(navigator)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                    }
                    HStack {
                        Button("Previous") { Task { await navigator.goBackward() } }
                            .accessibilityIdentifier("workspace-epub-previous")
                        Spacer(minLength: 8)
                        Text(reader.locationLabel)
                            .font(.caption)
                            .lineLimit(1)
                            .accessibilityIdentifier("workspace-epub-location")
                        Spacer(minLength: 8)
                        Button("Next") { Task { await navigator.goForward() } }
                            .accessibilityIdentifier("workspace-epub-next")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                } else if let failure {
                    ContentUnavailableView("EPUB preview unavailable", systemImage: "books.vertical",
                                           description: Text(failure))
                        .accessibilityIdentifier("workspace-epub-error")
                } else {
                    ProgressView("Opening EPUB…")
                        .accessibilityIdentifier("workspace-epub-loading")
                }
            }
            .navigationTitle(reader.title ?? name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(onClose == nil ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if onClose == nil {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if let navigator = reader.navigator { readerControls(navigator) }
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("workspace-epub-close")
                    }
                }
            }
        }
        .task {
            do {
                let (file, key) = try await WorkspacePublicationStore.shared.prepare(data: data, origin: origin)
                try Task.checkCancellation()
                guard let url = file.anyURL.absoluteURL else { throw WorkspacePublicationFailure.invalid }
                let client = DefaultHTTPClient()
                let retriever = AssetRetriever(httpClient: client)
                let opener = PublicationOpener(parser: DefaultPublicationParser(
                    httpClient: client, assetRetriever: retriever,
                    pdfFactory: DefaultPDFDocumentFactory()))
                let asset = try await retriever.retrieve(url: url).get()
                guard asset.format.mediaType == .epub else { throw WorkspacePublicationFailure.invalid }
                let publication = try await opener.open(asset: asset, allowUserInteraction: false).get()
                guard !publication.isRestricted else { throw WorkspacePublicationFailure.protected }
                let locator = UserDefaults.standard.string(forKey: key).flatMap { raw in
                    try? Locator(json: JSONValue(jsonString: raw, warnings: nil), warnings: nil)
                }
                let navigator = try EPUBNavigatorViewController(
                    publication: publication, initialLocation: locator,
                    config: .init(preferences: EPUBPreferences(fontSize: largeText ? 2 : 1)))
                guard !Task.isCancelled else { return }
                reader.configure(publication: publication, navigator: navigator, storageKey: key)
            } catch is CancellationError {
                // A dismissed sheet no longer needs its navigation controller.
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "This book could not be opened."
            }
        }
        .onDisappear { reader.close() }
    }

    @ViewBuilder private func readerControls(_ navigator: EPUBNavigatorViewController) -> some View {
        Menu("Chapters") {
            ForEach(Array(reader.chapters.enumerated()), id: \.offset) { index, chapter in
                Button(chapter.title ?? "Chapter \(index + 1)") {
                    Task { await navigator.go(to: chapter) }
                }
            }
        }
        .accessibilityIdentifier("workspace-epub-chapters")
        Button(largeText ? "Normal Text" : "Large Text") {
            largeText.toggle()
            navigator.submitPreferences(EPUBPreferences(fontSize: largeText ? 2 : 1))
        }
        .accessibilityIdentifier("workspace-epub-text-size")
    }
}

private struct PublicationNavigator: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    func makeUIViewController(context: Context) -> EPUBNavigatorViewController { navigator }
    func updateUIViewController(_ controller: EPUBNavigatorViewController, context: Context) {}
}

@MainActor private final class WorkspacePublicationReader: NSObject, ObservableObject, EPUBNavigatorDelegate {
    @Published private(set) var navigator: EPUBNavigatorViewController?
    @Published private(set) var title: String?
    @Published private(set) var locationLabel = "Starting page"
    @Published private(set) var chapters: [ReadiumShared.Link] = []
    private var storageKey: String?

    func configure(publication: Publication, navigator: EPUBNavigatorViewController, storageKey: String) {
        self.storageKey = storageKey
        title = publication.metadata.title
        chapters = publication.manifest.tableOfContents
        navigator.delegate = self
        self.navigator = navigator
    }

    func close() {
        navigator?.delegate = nil
        navigator = nil
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        let percent = locator.locations.totalProgression.map { Int($0 * 100) }
        locationLabel = "\(locator.title ?? "Reading") \(percent.map { "\($0)%" } ?? "")"
        if let storageKey, let raw = try? locator.jsonString() {
            UserDefaults.standard.set(raw, forKey: storageKey)
        }
    }

    func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
        // File previews do not open book-provided links outside Wonder.
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        locationLabel = "This page could not be opened"
    }
}

private enum WorkspacePublicationFailure: LocalizedError {
    case invalid, protected, externalContent

    var errorDescription: String? {
        switch self {
        case .invalid: "This EPUB is damaged or uses a format Wonder cannot preview."
        case .protected: "Protected EPUBs cannot be previewed in Wonder."
        case .externalContent: "This EPUB includes active or remote content that Wonder cannot safely preview."
        }
    }
}

private actor WorkspacePublicationStore {
    static let shared = WorkspacePublicationStore()

    func prepare(data: Data, origin: String) async throws -> (URL, String) {
        try WorkspaceArchivePreflight.validate(data, as: .epub)
        let bytesHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let identity = Data((origin + "\0" + bytesHash).utf8)
        let key = "wonder.epub.location." + SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WonderEPUB", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(key + ".epub")
        if let existing = try? Data(contentsOf: file),
           SHA256.hash(data: existing).map({ String(format: "%02x", $0) }).joined() == bytesHash {
            try await WorkspacePublicationResourceGate.validate(file)
            return (file, key)
        }
        let temporary = folder.appendingPathComponent(UUID().uuidString + ".epub")
        do {
            try data.write(to: temporary, options: .atomic)
            try await WorkspacePublicationResourceGate.validate(temporary)
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: temporary, to: file)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
            trim(folder: folder, keeping: file)
            return (file, key)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func trim(folder: URL, keeping current: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        let old = files.filter { $0 != current }.sorted {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return first > second
        }
        for file in old.dropFirst(7) { try? FileManager.default.removeItem(at: file) }
    }
}

enum WorkspacePublicationResourceGate {
    static func validate(_ file: URL) async throws {
        let archive = try await ReadiumZIPFoundation.Archive(url: file, accessMode: .read)
        let entries = try await archive.entries()
        guard !entries.isEmpty, entries.count <= 512 else { throw WorkspacePublicationFailure.invalid }
        var total: UInt64 = 0
        for entry in entries {
            try Task.checkCancellation()
            guard entry.type == .file || entry.type == .directory,
                  entry.uncompressedSize <= 2 * 1024 * 1024,
                  total <= 8 * 1024 * 1024 - entry.uncompressedSize else {
                throw WorkspacePublicationFailure.invalid
            }
            total += entry.uncompressedSize
            let ext = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
            if ["js", "mjs"].contains(ext) { throw WorkspacePublicationFailure.externalContent }
            guard ["xhtml", "html", "htm", "svg", "xml", "opf", "ncx", "css"].contains(ext) else { continue }
            let collector = PublicationEntryCollector()
            _ = try await archive.extract(entry, bufferSize: 64 * 1024) { chunk in
                try await collector.append(chunk)
            }
            let bytes = await collector.bytes
            guard let text = String(data: bytes, encoding: .utf8) else { throw WorkspacePublicationFailure.invalid }
            if ext == "css" {
                try checkCSS(text)
            } else {
                try checkXML(text)
            }
        }
    }

    fileprivate static func checkCSS(_ text: String) throws {
        let lower = text.lowercased()
        guard !lower.contains("@import"), !lower.contains("expression("), !text.contains("\\") else {
            throw WorkspacePublicationFailure.externalContent
        }
        let pattern = try NSRegularExpression(pattern: "(?i)url\\s*\\(([^)]*)\\)")
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in pattern.matches(in: text, range: full) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let target = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"'")))
            if isExternal(target) { throw WorkspacePublicationFailure.externalContent }
        }
    }

    private static func checkXML(_ text: String) throws {
        let lower = text.lowercased()
        guard !lower.contains("<!entity"), !lower.contains("<?xml-stylesheet"),
              !lower.contains("<!doctype") || (!lower.contains(" system ") && !lower.contains(" public ")) else {
            throw WorkspacePublicationFailure.externalContent
        }
        let guardDelegate = PublicationXMLGuard()
        let parser = XMLParser(data: Data(text.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = guardDelegate
        guard parser.parse() else { throw WorkspacePublicationFailure.invalid }
        if guardDelegate.rejected { throw WorkspacePublicationFailure.externalContent }
    }

    static func isExternal(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Reject encoded paths altogether: a second decoder must not turn a
        // seemingly relative EPUB link into ../, an absolute path, or a URL.
        if value.contains("%") || value.contains("\\") || value.hasPrefix("/")
            || URL(string: value)?.scheme != nil { return true }
        let path = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        if path.isEmpty { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}

private actor PublicationEntryCollector {
    private(set) var bytes = Data()
    func append(_ chunk: Data) throws {
        guard chunk.count <= 2 * 1024 * 1024,
              bytes.count <= 2 * 1024 * 1024 - chunk.count else {
            throw WorkspacePublicationFailure.invalid
        }
        bytes.append(chunk)
    }
}

private final class PublicationXMLGuard: NSObject, XMLParserDelegate {
    private(set) var rejected = false
    private var style = ""
    private var inStyle = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let element = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? ""
        if ["script", "iframe", "frame", "object", "embed", "form", "base", "foreignobject"].contains(element) {
            rejected = true
        }
        if element == "style" { inStyle = true; style = "" }
        if element == "meta", attributeDict.contains(where: { $0.key.lowercased() == "http-equiv" && $0.value.lowercased() == "refresh" }) {
            rejected = true
        }
        for (rawName, value) in attributeDict {
            let name = rawName.lowercased()
            if name.hasPrefix("on") || name == "srcdoc" { rejected = true }
            if name == "srcset" { rejected = true }
            if name == "style", (try? WorkspacePublicationResourceGate.checkCSS(value)) == nil { rejected = true }
            if ["src", "href", "xlink:href", "poster", "action", "data", "srcset", "xml:base"].contains(name) {
                if element == "a", name == "href",
                   let scheme = URL(string: value)?.scheme?.lowercased(),
                   ["http", "https"].contains(scheme) { continue }
                if WorkspacePublicationResourceGate.isExternal(value) { rejected = true }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inStyle { style += string; if style.utf8.count > 2 * 1024 * 1024 { rejected = true } }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased().hasSuffix("style") {
            inStyle = false
            if (try? WorkspacePublicationResourceGate.checkCSS(style)) == nil { rejected = true }
        }
    }
}
