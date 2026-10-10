import SwiftUI
import UIKit
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import WonderPairing

/// Share sheet entry point. It sends with the paired phone's saved session and
/// never renews sessions or rewrites the app's saved connections.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let model = ShareModel { [weak self] sent in
            guard let context = self?.extensionContext else { return }
            if sent { context.completeRequest(returningItems: nil) }
            else { context.cancelRequest(withError: CocoaError(.userCancelled)) }
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        model.start(providers: items.flatMap { $0.attachments ?? [] })
    }
}

struct ShareDestination: Identifiable, Hashable, Sendable {
    let chat: ChatSummary
    let groupID: String?
    let acceptsFiles: Bool
    let modelSelectionRevision: Int?
    var id: String { chat.id }

    /// Mirrors the app's Chats list: active direct Bot chats and open Groups.
    static func list(chats: [ChatSummary], groups: [GroupRead], bots: [ManagedBot]) -> [Self] {
        let activeBots = Dictionary(bots.filter { !$0.isArchived }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groupIDs = Set(groups.map(\.conversationId))
        let direct = chats.compactMap { chat -> Self? in
            guard !groupIDs.contains(chat.id), !chat.isArchived, let bot = chat.botId.flatMap({ activeBots[$0] }) else { return nil }
            return Self(chat: chat, groupID: nil, acceptsFiles: true, modelSelectionRevision: bot.modelSelectionRevision)
        }
        let open = groups.filter { !$0.isArchived }.map {
            Self(chat: $0.summary, groupID: $0.id, acceptsFiles: $0.canAttachFiles, modelSelectionRevision: nil)
        }
        return (direct + open).sorted { first, second in
            if first.chat.isPinned != second.chat.isPinned { return first.chat.isPinned }
            return (first.chat.lastMessageAt ?? "") > (second.chat.lastMessageAt ?? "")
        }
    }
}

enum SharedItem: Sendable {
    case text(String)
    case file(StagedFile, CGImage?)
}

@MainActor final class ShareModel: ObservableObject {
    @Published private(set) var connections: [SavedConnection] = []
    @Published private(set) var hostID: String?
    @Published private(set) var destinations: [ShareDestination] = []
    @Published private(set) var loadingDestinations = false
    @Published private(set) var setupMessage: String?
    @Published private(set) var destinationError: String?
    @Published var selectionID: String?
    @Published var note = ""
    @Published var query = ""
    @Published private(set) var sharedText = ""
    @Published private(set) var files: [StagedFile] = []
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    @Published private(set) var loadingItems = true
    @Published private(set) var itemError: String?
    @Published private(set) var sending = false
    @Published private(set) var sendError: String?

    private let finish: (Bool) -> Void
    private let api = PairingAPI()
    private var destinationRequest = UUID()
    private var preferredChatID: String?
    /// Retries of the same content reuse the host's upload and message
    /// identities, so a lost response cannot create a duplicate message.
    private var uploads: [String: ConversationFile] = [:]
    private var attempts: [String: SendRequest] = [:]
    nonisolated static let maximumBytes = 8 * 1024 * 1024
    nonisolated static var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Wonder" }
    private static let lastDestinationKey = "wonder.share.lastDestination.v1"

    init(finish: @escaping (Bool) -> Void) { self.finish = finish }

    var selectedConnection: SavedConnection? { connections.first { $0.credential.hostInstallationId == hostID } }
    var selectedDestination: ShareDestination? { destinations.first { $0.id == selectionID } }
    var visibleDestinations: [ShareDestination] { destinations.filter { $0.chat.matchesName(query) } }
    var messageBody: String {
        [note.trimmingCharacters(in: .whitespacesAndNewlines), sharedText].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    var canSend: Bool {
        guard !loadingItems, !sending, setupMessage == nil, let destination = selectedDestination else { return false }
        return (!messageBody.isEmpty || !files.isEmpty) && messageBody.utf8.count <= 65536
            && (files.isEmpty || destination.acceptsFiles)
    }

    func start(providers: [NSItemProvider]) {
        loadConnections()
        Task { await loadItems(providers) }
        Task { await loadDestinations() }
    }

    func cancel() { finish(false) }

    func remove(_ fileID: String) {
        files.removeAll { $0.id == fileID }
        thumbnails[fileID] = nil
    }

    func selectHost(_ host: String?) {
        guard host != hostID else { return }
        hostID = host
        selectionID = nil
        destinations = []
        sendError = nil
        Task { await loadDestinations() }
    }

    private func loadConnections() {
        let identity = PhoneIdentity()
        do {
            var saved: [SavedConnection] = []
            if let data = try identity.read("connections-v1") {
                saved = try JSONDecoder().decode(SavedConnections.self, from: data).connections
            } else if let data = try identity.read("connection") {
                saved = [try JSONDecoder().decode(SavedConnection.self, from: data)]
            }
            connections = saved.filter { !$0.requiresPairing }
            if connections.isEmpty {
                setupMessage = saved.isEmpty ? "Open \(Self.appName) and pair it with your Mac first."
                    : "Open \(Self.appName) to reconnect to your Mac, then share again."
            }
            let last = UserDefaults.standard.dictionary(forKey: Self.lastDestinationKey) as? [String: String]
            hostID = (connections.first { $0.credential.hostInstallationId == last?["host"] } ?? connections.first)?.credential.hostInstallationId
            preferredChatID = last?["chat"]
        } catch {
            setupMessage = "\(Self.appName) couldn't open your saved Macs. Unlock your iPhone and try again."
        }
    }

    func loadDestinations() async {
        guard let connection = selectedConnection else { return }
        let request = UUID()
        destinationRequest = request
        loadingDestinations = true
        destinationError = nil
        defer { if destinationRequest == request { loadingDestinations = false } }
        if let expiry = connection.credential.expiresAtMs, expiry <= UInt64(Date().timeIntervalSince1970 * 1000) + 60_000 {
            destinationError = "Open \(Self.appName) to reconnect to \(Self.name(connection)), then share again."
            return
        }
        do {
            async let chats: [ChatSummary] = api.request("/api/v1/conversations", origin: connection.origin, credential: connection.credential)
            async let groups: [GroupRead] = api.request("/api/v1/group-chats", origin: connection.origin, credential: connection.credential)
            async let bots: [ManagedBot] = api.request("/api/v1/bots", origin: connection.origin, credential: connection.credential)
            let (chatList, groupList, botList) = try await (chats, groups, bots)
            guard destinationRequest == request else { return }
            destinations = ShareDestination.list(chats: chatList, groups: groupList, bots: botList)
            if selectionID == nil, let preferred = preferredChatID, destinations.contains(where: { $0.id == preferred }) {
                selectionID = preferred
            }
        } catch {
            guard destinationRequest == request else { return }
            destinationError = Self.message(for: error, connection: connection)
        }
    }

    private func loadItems(_ providers: [NSItemProvider]) async {
        defer { loadingItems = false }
        var texts: [String] = []
        var staged: [StagedFile] = []
        var skipped = false
        for provider in providers.prefix(8) {
            switch try? await Self.load(provider) {
            case .text(let text): texts.append(text)
            case .file(let file, let thumbnail):
                guard staged.count < 4 else { skipped = true; continue }
                staged.append(file)
                if let thumbnail { thumbnails[file.id] = UIImage(cgImage: thumbnail) }
            case nil: skipped = true
            }
        }
        sharedText = texts.joined(separator: "\n\n")
        files = staged
        if skipped { itemError = "Some items couldn't be added. Share up to four files, each 8 MB or smaller." }
    }

    func send() async {
        guard canSend, let connection = selectedConnection, let destination = selectedDestination else { return }
        sending = true
        sendError = nil
        defer { sending = false }
        let body = messageBody
        do {
            var attachmentIDs: [String] = []
            for file in files {
                let key = connection.credential.hostInstallationId + "\n" + destination.id + "\n" + file.id
                if let uploaded = uploads[key] { attachmentIDs.append(uploaded.id); continue }
                let uploaded: ConversationFile = try await api.request(
                    "/api/v1/conversations/\(Self.escape(destination.chat.id))/files",
                    origin: connection.origin, body: file.uploadBody(), credential: connection.credential)
                try uploaded.verify(file.data, mime: file.mimeType)
                uploads[key] = uploaded
                attachmentIDs.append(uploaded.id)
            }
            let fingerprint = ([connection.credential.hostInstallationId, destination.id, body] + attachmentIDs).joined(separator: "\n")
            let request: SendRequest
            if let previous = attempts[fingerprint] {
                request = previous
            } else {
                var intent = ComposerIntent()
                intent.draft = body
                intent.draftAttachmentIds = attachmentIDs
                try intent.begin(device: connection.credential.deviceId, modelSelectionRevision: destination.modelSelectionRevision)
                guard let pending = intent.pending else { throw SendFailure.pending }
                request = pending.request
                attempts[fingerprint] = request
            }
            let path = destination.groupID.map { "/api/v1/group-chats/\(Self.escape($0))/messages" }
                ?? "/api/v1/conversations/\(Self.escape(destination.chat.id))/messages"
            let receipt: SendReceipt = try await api.request(path, origin: connection.origin,
                body: JSONEncoder().encode(request), credential: connection.credential)
            let digest = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
            guard receipt.clientMessageId == request.clientMessageId, receipt.conversationId == destination.chat.id,
                  !receipt.wonderMessageId.isEmpty, receipt.bodySha256 == digest else { throw SendFailure.receiptMismatch }
            UserDefaults.standard.set(["host": connection.credential.hostInstallationId, "chat": destination.id],
                                      forKey: Self.lastDestinationKey)
            finish(true)
        } catch {
            sendError = Self.message(for: error, connection: connection)
        }
    }

    // MARK: Item loading

    /// Images and files become attachments; web links and plain text join the message.
    /// Providers stay on the main actor; decoding and re-encoding run detached.
    static func load(_ provider: NSItemProvider) async throws -> SharedItem? {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let suggestedName = provider.suggestedName
        if let image = types.first(where: { $0.conforms(to: .image) }) {
            let data = try await data(provider, type: image)
            return try await Task.detached(priority: .userInitiated) {
                let file = try prepareImage(data, type: image, suggestedName: suggestedName)
                return SharedItem.file(file, thumbnail(file.data))
            }.value
        }
        let isFile = types.contains { $0.conforms(to: .fileURL) } || suggestedName?.contains(".") == true
        if !isFile, types.contains(where: { $0.conforms(to: .url) }), let url = try await object(provider, URL.self), !url.isFileURL {
            return .text(url.absoluteString)
        }
        if !isFile, types.contains(where: { $0.conforms(to: .text) }), let text = try await object(provider, String.self) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(trimmed)
        }
        guard let type = types.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .url) }) else { return nil }
        let data = try await fileData(provider, type: type)
        return try await Task.detached(priority: .userInitiated) {
            SharedItem.file(try StagedFile(name: fileName(suggestedName, type: type, fallback: "File"),
                                           mimeType: type.preferredMIMEType ?? "application/octet-stream", data: data), nil)
        }.value
    }

    private static func data(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? FileFailure.integrity) }
            }
        }
    }

    private static func fileData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                // The file exists only for the duration of this callback.
                guard let url else { continuation.resume(throwing: error ?? FileFailure.integrity); return }
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard size > 0, size <= maximumBytes else { throw FileFailure.tooLarge }
                    continuation.resume(returning: try Data(contentsOf: url))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func object<T: _ObjectiveCBridgeable>(_ provider: NSItemProvider, _ type: T.Type) async throws -> T?
    where T._ObjectiveCType: NSItemProviderReading, T: Sendable {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
            }
        }
    }

    /// Photos larger than the host's attachment limit are re-encoded as a
    /// bounded JPEG instead of being rejected.
    nonisolated static func prepareImage(_ original: Data, type originalType: UTType, suggestedName: String?) throws -> StagedFile {
        var data = original, type = originalType
        if data.count > maximumBytes || type.preferredMIMEType == nil {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096,
                  ] as CFDictionary) else { throw FileFailure.integrity }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw FileFailure.integrity }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw FileFailure.integrity }
            data = output as Data
            type = .jpeg
        }
        return try StagedFile(name: fileName(suggestedName, type: type, fallback: "Photo-\(UUID().uuidString.prefix(8))"),
                              mimeType: type.preferredMIMEType ?? "image/jpeg", data: data)
    }

    nonisolated private static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ] as CFDictionary)
    }

    /// The host accepts one path component without control characters.
    nonisolated static func fileName(_ suggested: String?, type: UTType, fallback: String) -> String {
        let cleaned = (suggested ?? "").components(separatedBy: CharacterSet(charactersIn: "/\\").union(.controlCharacters))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        var base = (cleaned as NSString).deletingPathExtension
        if base.isEmpty || base == "." || base == ".." { base = fallback }
        let ext = String((type.preferredFilenameExtension ?? (cleaned as NSString).pathExtension).prefix(32))
        while (base + "." + ext).utf8.count > 255 { base.removeLast() }
        return ext.isEmpty ? base : base + "." + ext
    }

    nonisolated static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    nonisolated static func name(_ connection: SavedConnection) -> String {
        connection.hostName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "your Mac"
    }

    nonisolated static func message(for error: Error, connection: SavedConnection) -> String {
        let mac = name(connection)
        switch error {
        case PairingFailure.response(401), PairingFailure.response(403):
            return "This iPhone no longer has access to \(mac). Open \(Self.appName) to pair again."
        case PairingFailure.response(412):
            return "This chat's model settings changed. Open the chat in \(Self.appName) to send."
        case PairingFailure.response(404):
            return "This chat is no longer available."
        case PairingFailure.response(413), FileFailure.tooLarge:
            return "Files must be 8 MB or smaller."
        case FileFailure.integrity, SendFailure.receiptMismatch:
            return "\(mac) didn't confirm this message. Try again."
        case let error as URLError where error.code == .timedOut:
            return "\(mac) took too long to answer. Try again on a stronger connection."
        case is URLError:
            return "Couldn't reach \(mac). Check that Tailscale is connected, then try again."
        default:
            return "Couldn't send to \(mac). Try again."
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Add a message", text: $model.note, axis: .vertical)
                        .lineLimit(1...6)
                        .accessibilityIdentifier("share-note")
                    if !model.sharedText.isEmpty {
                        Text(model.sharedText).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                    }
                    if !model.files.isEmpty { attachmentStrip }
                    if model.loadingItems { ProgressView("Preparing items…") }
                    if let error = model.itemError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if model.connections.count > 1 {
                    Section {
                        Picker("Computer", selection: Binding(get: { model.hostID }, set: { model.selectHost($0) })) {
                            ForEach(model.connections, id: \.credential.hostInstallationId) { connection in
                                Text(ShareModel.name(connection)).tag(Optional(connection.credential.hostInstallationId))
                            }
                        }
                    }
                }
                Section("Send to") { destinationRows }
                if let error = model.sendError {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                            .accessibilityIdentifier("share-error")
                    }
                }
            }
            .disabled(model.sending)
            .searchable(text: $model.query, prompt: "Search chats")
            .navigationTitle("Share to \(ShareModel.appName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }.disabled(model.sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.sending {
                        ProgressView().accessibilityLabel("Sending")
                    } else {
                        Button("Send") { Task { await model.send() } }
                            .disabled(!model.canSend)
                            .accessibilityIdentifier("share-send")
                    }
                }
            }
        }
    }

    @ViewBuilder private var destinationRows: some View {
        if let message = model.setupMessage {
            Text(message).foregroundStyle(.secondary)
        } else if let error = model.destinationError {
            Text(error)
            Button("Try again") { Task { await model.loadDestinations() } }
        } else if model.loadingDestinations && model.destinations.isEmpty {
            ProgressView("Loading chats…")
        } else if model.visibleDestinations.isEmpty {
            Text(model.query.isEmpty ? "No chats yet." : "No matching chats.").foregroundStyle(.secondary)
        } else {
            ForEach(model.visibleDestinations) { destination in
                let blocked = !model.files.isEmpty && !destination.acceptsFiles
                let selected = model.selectionID == destination.id
                Button { model.selectionID = destination.id } label: {
                    HStack(spacing: 12) {
                        Image(systemName: destination.groupID == nil ? "bubble.left" : "person.2")
                            .foregroundStyle(.tint).frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(destination.chat.title).foregroundStyle(.primary).lineLimit(1)
                            if blocked { Text("Can't receive files").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 8)
                        if selected { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(blocked)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("share-destination:" + destination.id)
            }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(model.files) { file in
                    Group {
                        if let image = model.thumbnails[file.id] {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            VStack(spacing: 4) {
                                Image(systemName: "doc")
                                Text(file.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                            }.padding(6)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(file.name)
                    .overlay(alignment: .topTrailing) {
                        Button { model.remove(file.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("Remove \(file.name)")
                        .accessibilityIdentifier("share-attachment-remove")
                    }
                }
            }
        }
    }
}
