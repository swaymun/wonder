import SwiftUI
import WonderPairing
import PhotosUI
import UniformTypeIdentifiers

/// Durable new-chat drafts: one per Mac, plus the last explicitly chosen Mac.
enum NewChatDraftStore {
    private static func key(_ host: String) -> String { "wonder.newchat.draft." + Data(host.utf8).base64EncodedString() }
    private static let hostKey = "wonder.newchat.host"
    private static var draftDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NewChatDrafts", isDirectory: true)
    }
    private static func url(_ key: String) -> URL { draftDirectory.appendingPathComponent(ConversationFile.digest(Data(key.utf8))) }
    private static func read(_ key: String) -> NewChatDraft? {
        let data = (try? Data(contentsOf: url(key))) ?? UserDefaults.standard.data(forKey: key)
        return data.flatMap { try? JSONDecoder().decode(NewChatDraft.self, from: $0) }
    }
    static func load(host: String) -> NewChatDraft? { read(key(host)) }
    @discardableResult static func save(_ draft: NewChatDraft, host: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(draft)
            for target in [key(host), destinationKey(host, draft.destination)] {
                try data.write(to: url(target), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                // Small ownership index supports scoped unpair cleanup.
                UserDefaults.standard.set(true, forKey: target)
            }
            return true
        } catch { return false }
    }
    static func load(host: String, destination: ChatDestination) -> NewChatDraft? { read(destinationKey(host, destination)) }
    /// A recording remains bound to its original draft when the owner navigates.
    static func insertDictation(_ text: String, requestID: String, draftID: String, host: String) throws {
        let prefix = key(host)
        let targets = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0 == prefix || $0.hasPrefix(prefix + ".") }
        guard var draft = targets.compactMap({ read($0) }).first(where: { $0.requestID == draftID }) else { throw ReadFailure.resync }
        try draft.appendDictation(text, requestID: requestID)
        let data = try JSONEncoder().encode(draft)
        for target in targets where read(target)?.requestID == draftID {
            try data.write(to: url(target), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    private static func destinationKey(_ host: String, _ destination: ChatDestination?) -> String {
        let encoded = (try? JSONEncoder().encode(destination)) ?? Data()
        return key(host) + "." + encoded.base64EncodedString()
    }
    static func remove(host: String) {
        let prefix = key(host)
        for stored in UserDefaults.standard.dictionaryRepresentation().keys where stored == prefix || stored.hasPrefix(prefix + ".") {
            try? FileManager.default.removeItem(at: url(stored))
            UserDefaults.standard.removeObject(forKey: stored)
        }
        if lastHost == host { lastHost = nil }
    }
    static func selecting(_ destination: ChatDestination, from draft: NewChatDraft, host: String, project: ProjectSummary? = nil) -> NewChatDraft {
        guard !draft.isSubmitted, draft.destination != destination else { return draft }
        save(draft, host: host)
        if let saved = load(host: host, destination: destination) { return saved }
        var next = NewChatDraft(text: draft.destination == nil ? draft.text : "")
        if draft.destination == nil && destination != .newGroup { next.attachments = draft.attachments }
        next.choose(destination, project: project)
        return next
    }
    private static var attachmentDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NewChatAttachments", isDirectory: true)
    }
    nonisolated static func stage(_ file: StagedFile) throws -> NewChatAttachment {
        let descriptor = NewChatAttachment(file)
        try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        guard UUID(uuidString: file.id) != nil else { throw FileFailure.integrity }
        try file.data.write(to: attachmentDirectory.appendingPathComponent(file.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return descriptor
    }
    nonisolated static func files(_ descriptors: [NewChatAttachment]) throws -> [StagedFile] {
        try descriptors.map { descriptor in
            guard UUID(uuidString: descriptor.id) != nil else { throw FileFailure.integrity }
            let path = attachmentDirectory.appendingPathComponent(descriptor.id)
            let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size == descriptor.byteSize, size <= 8 * 1024 * 1024 else { throw FileFailure.integrity }
            let data = try Data(contentsOf: path)
            guard ConversationFile.digest(data) == descriptor.sha256 else { throw FileFailure.integrity }
            return try StagedFile(id: descriptor.id, name: descriptor.name, mimeType: descriptor.mimeType, data: data)
        }
    }
    nonisolated static func pruneAttachments() {
        let references = Set(UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("wonder.newchat.draft.") }
            .compactMap { read($0) }.flatMap { ($0.attachments ?? []).map(\.id) })
        guard let files = try? FileManager.default.contentsOfDirectory(at: attachmentDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        for file in files where UUID(uuidString: file.lastPathComponent) != nil && !references.contains(file.lastPathComponent) {
            // Leave in-flight imports time to publish their metadata.
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(date) > 3600 { try? FileManager.default.removeItem(at: file) }
        }
    }
    static var lastHost: String? {
        get { UserDefaults.standard.string(forKey: hostKey) }
        set { UserDefaults.standard.set(newValue, forKey: hostKey) }
    }
}

/// The normal cold-launch surface: a draft chat whose Connection and
/// Destination are chosen separately. Choosing either never starts work.
struct NewChatView: View {
    @ObservedObject var library: ConnectionLibrary
    @ObservedObject var shell: ShellState
    @State private var hostID: String?
    @State private var draft = NewChatDraft()
    @State private var sending = false
    @State private var failure: String?
    @State private var addingProject = false
    @State private var groupDescription: GroupReviewRequest?
    @State private var pairing = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var model: ConnectionModel? {
        guard let hostID, let saved = library.saved.connections.first(where: { $0.credential.hostInstallationId == hostID }) else { return nil }
        return library.model(for: saved)
    }

    var body: some View {
        Group {
            if let model {
                NewChatContent(library: library, shell: shell, model: model, projects: model.projects,
                               hostID: $hostID, draft: $draft, sending: $sending, failure: $failure,
                               addingProject: $addingProject, groupDescription: $groupDescription, pairing: $pairing)
            } else {
                noConnection
            }
        }
        .navigationTitle("New chat")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: restore)
        .onChange(of: shell.newChatRequest) { _, request in apply(request) }
        .onChange(of: library.saved.connections.map(\.credential.hostInstallationId)) { _, hosts in
            if let hostID, !hosts.contains(hostID) { self.hostID = nil; draft = NewChatDraft() }
            if hostID == nil { restore() }
        }
        .task(id: PersistenceKey(host: hostID, draft: draft)) {
            let savedDraft = draft, host = hostID
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let host else { return }
            let saved = NewChatDraftStore.save(savedDraft, host: host)
            if !saved, !Task.isCancelled { failure = "Your draft could not be saved. Free some storage before leaving this chat." }
        }
        .onDisappear { if let hostID { NewChatDraftStore.save(draft, host: hostID) } }
        .onReceive(NotificationCenter.default.publisher(for: .newChatDictationInserted)) { notification in
            guard let hostID, notification.object as? String == hostID,
                  let saved = NewChatDraftStore.load(host: hostID), saved.requestID == draft.requestID else { return }
            draft = saved
        }
        .task { await Task.detached { NewChatDraftStore.pruneAttachments() }.value }
        .sheet(isPresented: $pairing) { PairComputerView(model: library.pairingModel()) }
    }

    private struct PersistenceKey: Hashable { let host: String?; let draft: NewChatDraft }

    private var noConnection: some View {
        VStack(spacing: 16) {
            Spacer()
            ScienceAvatar(shape: "sun", palette: "amber", size: 56).accessibilityHidden(true)
            Text(library.saved.connections.isEmpty ? "Pair your Mac to get started" : "Choose a connection").font(.title3.weight(.semibold))
            if library.saved.connections.isEmpty {
                Button("Add computer", systemImage: "plus") { pairing = true }.buttonStyle(.borderedProminent)
            } else {
                ConnectionMenu(library: library, hostID: hostID, choose: switchHost, addComputer: { pairing = true })
            }
            Spacer()
        }.frame(maxWidth: .infinity).padding()
    }

    private func restore() {
        guard hostID == nil else { apply(shell.newChatRequest); return }
        let hosts = library.saved.connections.map(\.credential.hostInstallationId)
        // Restore only an explicitly chosen, still-paired Mac; never infer one.
        if let last = NewChatDraftStore.lastHost, hosts.contains(last) { hostID = last }
        if let hostID { draft = NewChatDraftStore.load(host: hostID) ?? NewChatDraft() }
        apply(shell.newChatRequest)
    }

    private func apply(_ request: NewChatRequest?) {
        guard let request else { return }
        if let host = request.host, host != hostID { switchHost(host) }
        if let destination = request.destination, !draft.isSubmitted {
            if let hostID { draft = NewChatDraftStore.selecting(destination, from: draft, host: hostID, project: projectSummary(destination)) }
        } else if request.destination == nil, request.host == nil || request.host == hostID, !draft.isSubmitted, draft.destination != nil,
                  case .conversation = draft.destination {
            draft.destination = nil
        }
        shell.newChatRequest = nil
    }

    private func projectSummary(_ destination: ChatDestination) -> ProjectSummary? {
        if case .project(let id) = destination { return model?.projects.project(id) }
        return nil
    }

    private func switchHost(_ host: String) {
        guard host != hostID else { return }
        if let hostID { NewChatDraftStore.save(draft, host: hostID) }
        draft = NewChatDraft.switching(from: draft, toSaved: NewChatDraftStore.load(host: host))
        hostID = host
        NewChatDraftStore.lastHost = host
        failure = nil
    }
}

struct GroupReviewRequest: Identifiable {
    let id = UUID()
    let description: String
}

private struct NewChatContent: View {
    @ObservedObject var library: ConnectionLibrary
    @ObservedObject var shell: ShellState
    @ObservedObject var model: ConnectionModel
    @ObservedObject var projects: ProjectLibrary
    @Binding var hostID: String?
    @Binding var draft: NewChatDraft
    @Binding var sending: Bool
    @Binding var failure: String?
    @Binding var addingProject: Bool
    @Binding var groupDescription: GroupReviewRequest?
    @Binding var pairing: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var importing = false
    @State private var selectingPhoto = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importingFor: String?
    @State private var attachmentTask: Task<Void, Never>?
    @State private var loadingAttachment = false
    @State private var attachmentPresentation: [ComposerAttachment] = []
    @State private var previewAttachment: ComposerAttachment?
    @State private var showingCamera = false
    @State private var cameraScope: String?
    @State private var showingModel = false

    private var draftChat: ChatSummary {
        ChatSummary(conversationId: "new-chat:" + draft.requestID, botId: nil, title: "New chat",
            lastMessagePreview: nil, lastMessageAt: nil, messageCount: 0, deliveryState: nil,
            hasUnread: false, isArchived: false, isPinned: false)
    }

    private var canAttach: Bool {
        !sending && !draft.isSubmitted && !loadingAttachment && (draft.attachments ?? []).count < 4 && draft.destination != .newGroup
    }

    private var project: ProjectSummary? {
        if case .project(let id) = draft.destination { return projects.project(id) }
        return nil
    }
    private var familyModels: [BotOptions.Model] {
        (projects.options?.models ?? []).filter { !$0.hidden && $0.family == draft.family }
    }
    private var selectedModel: BotOptions.Model? { familyModels.first { $0.id == draft.model } }
    private var placeholder: String {
        switch draft.destination {
        case .newBot: return "Describe what this Bot should help with"
        case .newGroup: return "Describe the team you want"
        case .project: return "Message \(project?.name ?? "project")"
        default: return "Message…"
        }
    }
    private var canSend: Bool {
        guard !sending, model.connection != nil, !model.accessEnded, model.macConnected == true else { return false }
        let text = (draft.submittedBody ?? draft.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !(draft.attachments ?? []).isEmpty), text.utf8.count <= 65536, !loadingAttachment else { return false }
        switch draft.destination {
        case .project: return project != nil && draft.family != nil && draft.model != nil && projects.isAvailable(draft.family ?? .codex)
        case .newBot:
            return selectedModel != nil && projects.options?.approvalChoices(model: draft.model)?
                .contains(where: { $0.id == (draft.botApprovalMode ?? .askForApproval).rawValue && $0.allowed }) == true
        case .newGroup: return !text.isEmpty && (draft.attachments ?? []).isEmpty
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            emptyState
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        .safeAreaInset(edge: .bottom) { composer }
        .task(id: model.assignmentScope) {
            await projects.loadOptions()
            if projects.supportsProjects == nil { await projects.refresh() }
            ensureModel()
        }
        .onChange(of: draft.family) { _, _ in ensureModel() }
        .onChange(of: projects.options?.models.count) { _, _ in ensureModel() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard importingFor == draft.requestID, canAttach else { return }
            if case .success(let url) = result {
                importAttachment {
                    try await Task.detached {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard size <= 8 * 1024 * 1024 else { throw FileFailure.tooLarge }
                    return [try StagedFile(name: url.lastPathComponent,
                        mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", data: Data(contentsOf: url))]
                    }.value
                }
            }
        }
        .photosPicker(isPresented: $selectingPhoto, selection: $selectedPhoto, matching: .images, preferredItemEncoding: .compatible)
        .sheet(isPresented: $showingCamera, onDismiss: { cameraScope = nil }) {
            if let cameraScope {
                CameraCaptureView(chatID: draft.requestID, chatTitle: "New chat", originatingScope: cameraScope,
                    currentContextToken: model.cameraContextID.uuidString + ":" + draft.requestID,
                    attachPhoto: { data in
                        guard cameraScope == model.assignmentScope, canAttach else { return .cancelled }
                        let request = draft.requestID
                        do {
                            let file = try await ConnectionModel.prepareImageAttachment(data)
                            let item = try await Task.detached { try NewChatDraftStore.stage(file) }.value
                            guard !Task.isCancelled, cameraScope == model.assignmentScope, request == draft.requestID, canAttach else { return .cancelled }
                            draft.attachments = (draft.attachments ?? []) + [item]
                            return .attached
                        } catch { return .failed }
                    })
            }
        }
        .sheet(isPresented: $showingModel) { modelSheet }
        .task(id: selectedPhoto) {
            guard let photo = selectedPhoto, importingFor == draft.requestID, canAttach else { return }
            let request = draft.requestID
            loadingAttachment = true
            defer { loadingAttachment = false; selectedPhoto = nil }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else { throw FileFailure.integrity }
                let file = try await ConnectionModel.prepareImageAttachment(data)
                let item = try await Task.detached { try NewChatDraftStore.stage(file) }.value
                guard request == draft.requestID, !Task.isCancelled else { return }
                draft.attachments = (draft.attachments ?? []) + [item]
            } catch { failure = "Could not attach this photo. Use files up to 8 MB and try again." }
        }
        .task(id: draft.attachments) {
            let descriptors = draft.attachments ?? []
            do {
                let files = try await Task.detached { try NewChatDraftStore.files(descriptors) }.value
                guard !Task.isCancelled else { return }
                attachmentPresentation = files.map { ComposerAttachment(id: $0.id, name: $0.name, mimeType: $0.mimeType,
                    data: $0.data, remoteFile: nil, sha256: nil, byteSize: $0.data.count, state: "available", updatedAt: "") }
            } catch {
                attachmentPresentation = descriptors.map { ComposerAttachment(id: $0.id, name: $0.name, mimeType: $0.mimeType,
                    data: nil, remoteFile: nil, sha256: $0.sha256, byteSize: $0.byteSize, state: "unavailable", updatedAt: "") }
                failure = "A saved attachment is unavailable. Remove it and attach the file again."
            }
        }
        .fullScreenCover(item: $previewAttachment) { attachment in
            PhotoViewer(model: model, chat: ChatSummary(conversationId: draft.requestID, botId: nil, title: "New chat",
                lastMessagePreview: nil, lastMessageAt: nil, messageCount: 0, deliveryState: nil, hasUnread: false, isArchived: false, isPinned: false),
                name: attachment.name, mimeType: attachment.mimeType, sourceID: attachment.id,
                localData: attachment.data, file: nil)
        }
        .onDisappear {
            attachmentTask?.cancel()
            model.dictation.captureControlsHidden(conversationID: draftChat.id)
        }
        .sheet(isPresented: $addingProject) {
            ProjectEditorView(model: model, library: projects, project: nil) { saved in
                choose(destination: .project(id: saved.id), project: saved)
            }
        }
        .sheet(item: $groupDescription) { request in
            GroupReviewSheet(model: model, initialDescription: request.description, draftID: draft.requestID) { conversation in
                draft.completeSubmission()
                if let host = hostID {
                    NewChatDraftStore.save(draft, host: host)
                    shell.open(host: host, conversation: conversation)
                }
            } onCancel: {
                // The description stays in the draft for another attempt.
                draft.submittedBody = nil
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 14) {
            switch draft.destination {
            case .project:
                Image(systemName: "folder").font(.system(size: 34)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(project?.name ?? "Project").font(.title3.weight(.semibold))
                if let folder = folderName { Text("Starts in \(folder) on \(model.macName)").font(.subheadline).foregroundStyle(.secondary) }
            case .newBot:
                ScienceAvatar(shape: "sun", palette: "amber", size: 52).accessibilityHidden(true)
                Text("New Bot").font(.title3.weight(.semibold))
                Text("Describe what it should help with. Its name and look can change later.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            case .newGroup:
                Image(systemName: "person.2").font(.system(size: 34)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text("New Group Chat").font(.title3.weight(.semibold))
                Text("Describe the team. You’ll review who joins before anything starts.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            default:
                ScienceAvatar(shape: "sun", palette: "amber", size: 52).accessibilityHidden(true)
                Text("What would you like to do?").font(.title3.weight(.semibold))
            }
        }
        .padding(.horizontal, 32)
        .accessibilityElement(children: .combine)
    }

    private var folderName: String? {
        guard let project else { return nil }
        return (project.folders.first { $0.id == draft.folderId } ?? project.primaryFolder)?.name
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            DictationControls(controller: model.dictation, model: model, chat: draftChat)
            if let failure {
                FailureDetails(draft.isSubmitted ? "Not confirmed" : "Couldn’t send", message: failure)
            }
            if model.macConnected == false {
                Text("Can’t reach \(model.macName). Your draft is saved.").font(.caption).foregroundStyle(.secondary)
            }
            if case .project = draft.destination, projects.supportsProjects == false {
                Text("Update Wonder on \(model.macName) to use Projects.").font(.caption).foregroundStyle(.secondary)
            }
            pickers
            DictationComposerSurface(controller: model.dictation, conversationID: draftChat.id) {
            VStack(spacing: 0) {
                if !attachmentPresentation.isEmpty {
                    ComposerAttachmentStrip(attachments: attachmentPresentation, imagePreviews: model.imagePreviews,
                        imagePreviewScope: model.imagePreviewScope, chatID: draft.requestID,
                        removalDisabled: sending || draft.isSubmitted,
                        loadRemoteData: { _ in throw FileFailure.notUploaded }, openPhoto: { previewAttachment = $0 },
                        remove: { id in draft.attachments?.removeAll { $0.id == id } })
                }
                BoundedComposerEditor(
                    text: Binding(get: { draft.submittedBody ?? draft.text }, set: { if !draft.isSubmitted { draft.text = $0 } }),
                    maximumLines: typeSize >= .accessibility3 ? 1 : typeSize.isAccessibilitySize ? 2 : 6,
                    label: placeholder, editable: !sending && !draft.isSubmitted,
                    canPasteImages: canAttach, pasteImages: pasteImages)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .topLeading) {
                        if (draft.submittedBody ?? draft.text).isEmpty {
                            Text(placeholder).foregroundStyle(.secondary).padding(.top, 12).padding(.leading, 5)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(placeholder)
                    .accessibilityIdentifier("new-chat-draft")
                    .padding(.horizontal, 8)
                HStack(alignment: .center, spacing: 4) {
                    Menu {
                        Button("Camera", systemImage: "camera") {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            cameraScope = model.assignmentScope; showingCamera = true
                        }
                        Button("Add photo", systemImage: "photo") { importingFor = draft.requestID; selectingPhoto = true }
                        Button("Attach file", systemImage: "paperclip") { importingFor = draft.requestID; importing = true }
                    } label: { Image(systemName: "plus").font(.system(size: 22)).frame(width: 44, height: 44) }
                    .disabled(!canAttach).accessibilityLabel("Message actions").accessibilityIdentifier("new-chat-attach")
                    DictationButton(controller: model.dictation, chat: draftChat,
                        unavailable: sending || draft.isSubmitted || model.accessEnded,
                        prepare: {
                            guard let hostID, NewChatDraftStore.save(draft, host: hostID) else {
                                failure = "Your draft could not be saved. Free some storage and try again."
                                return false
                            }
                            return true
                        })
                    if project != nil || draft.destination == .newBot { projectSettings }
                    else { Spacer(minLength: 0) }
                    Button { Task { await send() } } label: {
                        if sending { ProgressView().frame(width: 44, height: 44) }
                        else { Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44) }
                    }
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .background(canSend ? Color.primary : Color.secondary.opacity(0.35), in: Circle())
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(draft.isSubmitted ? "Send again" : "Send")
                    .accessibilityIdentifier("new-chat-send")
                }
            }
            }
            .padding(5)
            .foregroundStyle(.primary)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 28))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("new-chat-composer")
        }
        .frame(maxWidth: 768).padding(.horizontal).padding(.top, 4).padding(.bottom, 2)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var pickers: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ConnectionMenu(library: library, hostID: hostID, choose: choose(host:), addComputer: { pairing = true })
                destinationMenu
            }
            VStack(alignment: .leading, spacing: 8) {
                ConnectionMenu(library: library, hostID: hostID, choose: choose(host:), addComputer: { pairing = true })
                destinationMenu
            }
        }
        .disabled(sending || draft.isSubmitted)
    }

    private func choose(destination: ChatDestination, project: ProjectSummary? = nil) {
        guard let hostID else { return }
        model.dictation.captureControlsHidden(conversationID: draftChat.id)
        draft = NewChatDraftStore.selecting(destination, from: draft, host: hostID, project: project)
        ensureModel()
    }

    private func choose(host: String) {
        guard host != hostID else { return }
        model.dictation.captureControlsHidden(conversationID: draftChat.id)
        if let hostID { NewChatDraftStore.save(draft, host: hostID) }
        draft = NewChatDraft.switching(from: draft, toSaved: NewChatDraftStore.load(host: host))
        hostID = host
        NewChatDraftStore.lastHost = host
        failure = nil
    }

    private var destinationTitle: String {
        switch draft.destination {
        case .project: return project?.name ?? "Project"
        case .newBot: return "New Bot"
        case .newGroup: return "New Group Chat"
        case .conversation(let id): return model.chats.first { $0.id == id }?.title ?? "Destination"
        case nil: return "Destination"
        }
    }

    private var destinationMenu: some View {
        let recent = RecentConversations.visible(model.chats.filter { !$0.isArchived }, showAll: false).rows
        return Menu {
            if !recent.isEmpty {
                Section("Recent Bots") {
                    ForEach(recent) { chat in
                        Button { open(chat) } label: {
                            Label(chat.title, systemImage: chat.botId == nil ? "person.2" : "sun.max")
                        }
                    }
                }
            }
            if projects.supportsProjects != false {
                let listed = Array(projects.includedProjects.prefix(8))
                if !listed.isEmpty {
                    Section("Projects") {
                        ForEach(listed) { project in
                            Button { choose(destination: .project(id: project.id), project: project) } label: {
                                if case .project(project.id) = draft.destination { Label(project.name, systemImage: "checkmark") }
                                else { Label(project.name, systemImage: project.isPinned ? "pin" : "folder") }
                            }
                        }
                    }
                }
            }
            Section {
                if projects.supportsProjects != false {
                    Button("Add new project", systemImage: "folder.badge.plus") { addingProject = true }
                }
                Button("Add new Bot", systemImage: "sun.max") { choose(destination: .newBot) }
                Button("Add new Group Chat", systemImage: "person.2.badge.plus") { choose(destination: .newGroup) }
            }
        } label: {
            PickerChip(title: destinationTitle, systemImage: nil)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Destination")
        .accessibilityValue(draft.destination == nil ? "None" : destinationTitle)
        .accessibilityIdentifier("destination-picker")
    }

    private var projectSettings: some View {
        let family = draft.family ?? .codex
        return HStack(spacing: 4) {
            if draft.destination == .newBot {
                ApprovalModeMenu(selection: Binding(get: { draft.botApprovalMode ?? .askForApproval }, set: { draft.botApprovalMode = $0 }),
                    options: projects.options?.approvalChoices(model: draft.model), family: family, onChange: { _ in }) {
                    Image(systemName: "shield").font(.system(size: 18)).frame(width: 44, height: 44)
                        .foregroundStyle(draft.botApprovalMode == .fullAccess ? Color.orange : Color.primary)
                }
                .accessibilityLabel("Approval").accessibilityIdentifier("new-chat-access")
            } else {
            Menu {
                ForEach(ProjectAccessMode.allCases) { mode in
                    Button { draft.accessMode = mode } label: {
                        if mode == draft.accessMode { Label(mode.title(for: family), systemImage: "checkmark") }
                        else { Text(mode.title(for: family)) }
                    }
                }
                Section { Text(draft.accessMode.detail(for: family)) }
            } label: {
                Image(systemName: "shield").font(.system(size: 18)).frame(width: 44, height: 44)
                    .foregroundStyle(draft.accessMode == .fullAccess ? Color.orange : Color.primary)
            }
            .accessibilityLabel("Access")
            .accessibilityValue(draft.accessMode.title(for: family))
            .accessibilityIdentifier("new-chat-access")
            }
            Spacer(minLength: 0)
            Button { showingModel = true } label: {
                Group {
                    if typeSize.isAccessibilitySize { Image(systemName: "slider.horizontal.3").font(.system(size: 20)) }
                    else {
                        HStack(spacing: 4) {
                            Text(selectedModel?.displayName ?? family.title).lineLimit(1)
                            Image(systemName: "chevron.down").imageScale(.small)
                        }.font(.subheadline)
                    }
                }.padding(.horizontal, 4).frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Model")
            .accessibilityValue(family.title + ", " + (selectedModel?.displayName ?? "Choose model"))
            .accessibilityIdentifier("project-agent-picker")
        }
        .disabled(sending || draft.isSubmitted)
    }

    private var modelSheet: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    ForEach(AgentFamily.allCases) { option in
                        Button { var next = draft; next.chooseFamily(option); draft = next } label: {
                            HStack {
                                Text(projects.isAvailable(option) ? option.title : option.title + " (unavailable)")
                                Spacer()
                                if option == draft.family { Image(systemName: "checkmark") }
                            }
                        }.disabled(!projects.isAvailable(option))
                    }
                }
                Section("Model") {
                    if familyModels.isEmpty { Text("Models are unavailable. Check \(model.macName).").foregroundStyle(.secondary) }
                    ForEach(familyModels) { option in
                        Button { draft.model = option.id; draft.effort = nil; draft.serviceTier = nil } label: {
                            HStack { Text(option.displayName); Spacer(); if option.id == draft.model { Image(systemName: "checkmark") } }
                        }
                    }
                }
                if let selectedModel, !selectedModel.reasoningEfforts.isEmpty {
                    Section("Reasoning") {
                        ForEach(selectedModel.reasoningEfforts) { option in
                            Button { draft.effort = option.id } label: {
                                HStack {
                                    Text(option.label == "xhigh" ? "Extra high" : option.label.capitalized)
                                    Spacer()
                                    if option.id == draft.effort { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
                if let project, project.folders.count > 1 {
                    Section("Working folder") {
                        ForEach(project.folders) { folder in
                            Button { draft.folderId = folder.id } label: {
                                HStack {
                                    Text(folder.name); Spacer()
                                    if folder.id == (draft.folderId ?? project.primaryFolder?.id) { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
                if draft.destination == .newBot, let tiers = selectedModel?.serviceTiers, tiers.count > 1 {
                    Section("Speed") {
                        ForEach(tiers) { tier in
                            Button { draft.serviceTier = tier.id } label: {
                                HStack { Text(tier.label.capitalized); Spacer(); if tier.id == (draft.serviceTier ?? "default") { Image(systemName: "checkmark") } }
                            }
                        }
                    }
                }
            }
            .foregroundStyle(.primary)
            .disabled(sending || draft.isSubmitted)
            .navigationTitle("Model").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { showingModel = false } }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }

    /// Choose a model when the family has none selected: the owner's default
    /// for new Bots if it belongs to this family, otherwise the first offered.
    private func ensureModel() {
        guard !draft.isSubmitted, project != nil || draft.destination == .newBot else { return }
        if draft.destination == .newBot, draft.botApprovalMode == nil {
            let defaults = ModelDefaultPurpose.newBots.load()
            draft.family = AgentFamily(model: defaults.model)
            draft.model = defaults.model
            draft.effort = defaults.reasoningEffort.isEmpty ? nil : defaults.reasoningEffort
            draft.serviceTier = defaults.serviceTier
            draft.botApprovalMode = defaults.approvalMode
        }
        guard let family = draft.family,
              !familyModels.contains(where: { $0.id == draft.model }), !familyModels.isEmpty else { return }
        let preferred = ModelDefaultPurpose.newBots.load().model
        if AgentFamily(model: preferred) == family, familyModels.contains(where: { $0.id == preferred }) { draft.model = preferred }
        else { draft.model = (familyModels.first { $0.id != "claude:haiku" } ?? familyModels[0]).id }
        draft.effort = nil
    }

    private func importAttachment(_ load: @escaping @MainActor () async throws -> [StagedFile]) {
        guard canAttach else { return }
        let request = draft.requestID, scope = model.assignmentScope
        let remaining = 4 - (draft.attachments ?? []).count
        loadingAttachment = true
        attachmentTask = Task {
            defer { loadingAttachment = false }
            do {
                let files = try await load()
                guard files.count <= remaining else { throw FileFailure.tooLarge }
                let worker = Task.detached {
                    try Task.checkCancellation()
                    return try files.map { try NewChatDraftStore.stage($0) }
                }
                let items = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, request == draft.requestID, scope == model.assignmentScope else { return }
                draft.attachments = (draft.attachments ?? []) + items
            } catch is CancellationError {
            } catch { failure = "Could not attach these files. Use up to four files, each no larger than 8 MB." }
        }
    }

    private func pasteImages(_ providers: [NSItemProvider]) {
        importAttachment {
            var files: [StagedFile] = []
            for provider in providers {
                guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { throw FileFailure.integrity }
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: FileFailure.integrity) }
                    }
                }
                files.append(try await ConnectionModel.prepareImageAttachment(data))
            }
            return files
        }
    }

    /// Keep an existing conversation's durable draft when selecting it.
    private func open(_ chat: ChatSummary) {
        guard let hostID else { return }
        let current = draft, scope = model.assignmentScope
        Task {
            do {
                let files = try await Task.detached { try NewChatDraftStore.files(current.attachments ?? []) }.value
                guard scope == model.assignmentScope, draft.requestID == current.requestID else { return }
                if try model.transferDraft(current.text, files: files, to: chat) {
                    draft.text = ""; draft.attachments = nil
                    NewChatDraftStore.save(draft, host: hostID)
                }
                shell.open(host: hostID, conversation: chat.id)
            } catch { failure = "Your draft could not be moved. Check its attachments and try again." }
        }
    }

    private func send() async {
        guard canSend, let hostID, let device = model.connection?.credential.deviceId else { return }
        sending = true; failure = nil
        let scope = model.assignmentScope
        defer { sending = false }
        guard draft.submittedDeviceID == nil || draft.submittedDeviceID == device else {
            failure = "This request belongs to the previous pairing. Its delivery must be checked on your Mac before sending again."
            return
        }
        if !draft.isSubmitted {
            if let project { draft.folderId = draft.folderId ?? project.primaryFolder?.id; draft.rootsRevision = project.rootsRevision }
            draft.submittedDeviceID = device
            draft.freeze()
        }
        guard NewChatDraftStore.save(draft, host: hostID) else {
            failure = "Your message could not be saved. Free some storage and try again."
            return
        }
        let body = draft.submittedBody ?? draft.text
        let descriptors = draft.attachments ?? []
        let files: [StagedFile]
        do { files = try await Task.detached { try NewChatDraftStore.files(descriptors) }.value }
        catch {
            if draft.preparedConversationID == nil { draft.rejectSubmission() }
            failure = "A saved attachment is unavailable. Remove it and attach the file again."
            return
        }
        guard scope == model.assignmentScope, !model.accessEnded, !Task.isCancelled else { return }
        switch draft.destination {
        case .project(let projectID):
            do {
                let conversation: String
                if let prepared = draft.preparedConversationID { conversation = prepared }
                else {
                    let response = try await projects.createThread(projectID: projectID, draft: draft, body: body, deviceID: device)
                    guard let created = response.conversation.conversationId else { throw PairingFailure.response(500) }
                    conversation = created
                    draft.preparedConversationID = created
                    NewChatDraftStore.save(draft, host: hostID)
                }
                let detail = try await projects.loadDetail(conversation)
                let chat = model.projectChat(detail)
                try await model.prepareCreation(chat, body: body, requestID: draft.requestID, files: files)
                draft.completeSubmission()
                NewChatDraftStore.save(draft, host: hostID)
                shell.open(host: hostID, conversation: conversation)
                await model.deliver(chat)
            } catch PairingFailure.response(412) {
                draft.rejectSubmission()
                await projects.refresh()
                failure = "The project's folders changed. Review the working folder and send again."
            } catch PairingFailure.response(409) {
                failure = "This request conflicts with the saved thread or its folder. Check the project on your Mac, then retry this same request."
            } catch PairingFailure.response(422) {
                draft.rejectSubmission()
                failure = "This project, model or access choice can’t be used. Check them and send again."
            } catch PairingFailure.response(503) {
                failure = "\(model.macName) isn’t ready yet. Send again in a moment to check the same request."
            } catch {
                failure = "Your Mac didn’t confirm the new thread. Send again to retry the same request; it won’t start twice."
            }
        case .newBot:
            do {
                let defaults = NewBotDefaults(model: draft.model ?? "", reasoningEffort: draft.effort ?? "",
                    serviceTier: draft.serviceTier, approvalMode: draft.botApprovalMode ?? .askForApproval)
                guard let conversation = try await model.createConversationalBot(requestID: draft.requestID, defaults: defaults) else { throw PairingFailure.response(500) }
                guard let chat = model.chats.first(where: { $0.id == conversation }) else { throw PairingFailure.response(503) }
                // Transfer the frozen request to the existing durable outbox
                // before clearing this creation draft or performing networking.
                try await model.prepareCreation(chat, body: body, requestID: draft.requestID, files: files)
                draft.completeSubmission()
                NewChatDraftStore.save(draft, host: hostID)
                shell.open(host: hostID, conversation: conversation)
                await model.deliver(chat)
            } catch {
                failure = managementError(error) + " Retry to finish the same Bot and message."
            }
        case .newGroup:
            groupDescription = GroupReviewRequest(description: body)
        default:
            draft.submittedBody = nil
        }
    }
}

/// Paired Macs, the current choice and meaningful availability.
struct ConnectionMenu: View {
    @ObservedObject var library: ConnectionLibrary
    let hostID: String?
    let choose: (String) -> Void
    let addComputer: () -> Void
    private var current: ConnectionModel? {
        guard let hostID, let saved = library.saved.connections.first(where: { $0.credential.hostInstallationId == hostID }) else { return nil }
        return library.model(for: saved)
    }
    var body: some View {
        Menu {
            ForEach(library.saved.connections, id: \.credential.hostInstallationId) { saved in
                let model = library.model(for: saved)
                Button { choose(saved.credential.hostInstallationId) } label: {
                    let detail = model.accessEnded ? "Access ended" : model.macConnected == true ? "Connected" : model.macConnected == false ? "Offline" : "Connecting"
                    if saved.credential.hostInstallationId == hostID { Label("\(model.macName) · \(detail)", systemImage: "checkmark") }
                    else { Text("\(model.macName) · \(detail)") }
                }
            }
            Section { Button("Add computer", systemImage: "plus", action: addComputer) }
        } label: {
            PickerChip(title: current?.macName ?? "Choose a connection", systemImage: "laptopcomputer")
        }
        .accessibilityLabel("Connection")
        .accessibilityValue(current?.macName ?? "None")
        .accessibilityIdentifier("connection-picker")
    }
}

/// A compact rounded control that opens an anchored native menu.
struct PickerChip: View {
    let title: String
    let systemImage: String?
    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Capsule().strokeBorder(Color.secondary.opacity(0.35)))
        .contentShape(Capsule())
    }
}

extension Notification.Name {
    static let newChatDictationInserted = Notification.Name("wonder.newChatDictationInserted")
}
