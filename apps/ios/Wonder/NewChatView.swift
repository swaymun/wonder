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
    private static func pendingKey(_ host: String, _ request: String) -> String { key(host) + ".pending." + request }
    @discardableResult static func save(_ draft: NewChatDraft, host: String, separately: Bool = false) -> Bool {
        do {
            try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(draft)
            // A pending request is separate from the editable destination draft.
            // Reviewing it must not overwrite newer words for that project.
            let archived = draft.isSubmitted || separately || UserDefaults.standard.bool(forKey: pendingKey(host, draft.requestID))
            var targets = archived
                ? [pendingKey(host, draft.requestID), key(host)]
                : [destinationKey(host, draft.destination), key(host)]
            if archived, read(destinationKey(host, draft.destination))?.requestID == draft.requestID {
                targets.insert(destinationKey(host, draft.destination), at: 0)
            }
            for target in targets {
                try data.write(to: url(target), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                // Small ownership index supports scoped unpair cleanup.
                UserDefaults.standard.set(true, forKey: target)
            }
            return true
        } catch { return false }
    }
    static func load(host: String, destination: ChatDestination) -> NewChatDraft? { read(destinationKey(host, destination)) }
    static func savedMessages(host: String) -> [NewChatDraft] {
        let prefix = key(host) + ".pending."
        return UserDefaults.standard.dictionaryRepresentation().keys.sorted()
            .filter { $0.hasPrefix(prefix) }.compactMap { read($0) }
    }
    static func removePending(host: String, requestID: String) {
        let target = pendingKey(host, requestID)
        try? FileManager.default.removeItem(at: url(target))
        UserDefaults.standard.removeObject(forKey: target)
    }
    /// Escape an unconfirmed send without changing or losing its retry identity.
    static func startNew(from submitted: NewChatDraft, host: String) -> NewChatDraft? {
        guard submitted.isSubmitted, save(submitted, host: host) else { return nil }
        let next = editableDraft(after: submitted, host: host)
        return save(next, host: host) ? next : nil
    }
    /// A confirmed handoff retires only this request. An independent draft made
    /// while it was unconfirmed keeps its words and attachments.
    static func complete(_ submitted: NewChatDraft, host: String) -> NewChatDraft? {
        let next = editableDraft(after: submitted, host: host)
        guard save(next, host: host) else { return nil }
        removePending(host: host, requestID: submitted.requestID)
        return next
    }
    static func reject(_ submitted: NewChatDraft, host: String) -> NewChatDraft? {
        var next = submitted
        next.rejectSubmission()
        let saved = submitted.destination.flatMap { load(host: host, destination: $0) }
        let independent = saved.map { !$0.isSubmitted && $0.requestID != submitted.requestID } ?? false
        guard save(next, host: host, separately: independent) else { return nil }
        removePending(host: host, requestID: submitted.requestID)
        return next
    }
    private static func editableDraft(after submitted: NewChatDraft, host: String) -> NewChatDraft {
        var next = submitted
        next.completeSubmission()
        if let destination = submitted.destination,
           let saved = load(host: host, destination: destination),
           !saved.isSubmitted, saved.requestID != submitted.requestID {
            next = read(pendingKey(host, saved.requestID)) ?? saved
        }
        return next
    }
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
    /// An empty project draft starts with the owner's words and attachments.
    /// Both destinations remain recoverable, including when a write fails.
    static func selecting(_ destination: ChatDestination, from draft: NewChatDraft, host: String, project: ProjectSummary? = nil) -> NewChatDraft {
        guard !draft.isSubmitted, draft.destination != destination else { return draft }
        var next = load(host: host, destination: destination) ?? NewChatDraft()
        if case .project = destination, !next.isSubmitted, next.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           (next.attachments ?? []).isEmpty, (next.annotations ?? []).isEmpty {
            next.text = draft.text; next.attachments = draft.attachments
        }
        guard save(draft, host: host) else { return draft }
        next.choose(destination, project: project)
        guard save(next, host: host) else {
            save(draft, host: host)
            return draft
        }
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

/// The normal cold-launch surface: a draft chat addressed to a Mac and one of
/// its projects. Choosing either never starts work.
struct NewChatView: View {
    @ObservedObject var library: ConnectionLibrary
    @ObservedObject var shell: ShellState
    @State private var hostID: String?
    @State private var draft = NewChatDraft()
    @State private var sending = false
    @State private var sendTask = NewChatSendTask()
    @State private var failure: String?
    @State private var addingProject = false
    @State private var pairing = false
    @State private var linkedProjectID: String?
    @State private var linkedProjectChecked = false
    @State private var linkRetry = 0
    @State private var pendingLinkedRequest: NewChatRequest?

    private var model: ConnectionModel? {
        guard let hostID, let saved = library.saved.connections.first(where: { $0.credential.hostInstallationId == hostID }) else { return nil }
        return library.model(for: saved)
    }

    var body: some View {
        Group {
            if let model {
                ProjectRouteGate(projects: model.projects) {
                    if let linkedProjectID,
                       (!linkedProjectChecked || model.macConnected != true ||
                        model.projects.failure != nil ||
                        model.projects.project(linkedProjectID)?.isIncluded != true ||
                        draft.destination != .project(id: linkedProjectID)) {
                        linkedProjectRecovery(model)
                    } else {
                        NewChatContent(library: library, shell: shell, model: model, projects: model.projects,
                                       hostID: $hostID, draft: $draft, sending: $sending, sendTask: $sendTask, failure: $failure,
                                       addingProject: $addingProject, pairing: $pairing,
                                       linkedProjectID: $linkedProjectID)
                    }
                }
            } else {
                noConnection
            }
        }
        .navigationTitle("New chat")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: restore)
        .onChange(of: hostID, initial: true) { _, host in shell.draftHost = host }
        .onChange(of: model.map(ObjectIdentifier.init)) { previous, current in
            guard previous != current else { return }
            sendTask.cancel()
            sending = false
            failure = nil
        }
        .onChange(of: shell.newChatRequest) { _, request in apply(request) }
        .onChange(of: library.saved.connections.map(\.credential.hostInstallationId)) { _, hosts in
            if let hostID, !hosts.contains(hostID), linkedProjectID == nil {
                self.hostID = nil; draft = NewChatDraft()
            }
            if hostID == nil, linkedProjectID == nil { restore() }
        }
        .task(id: "\(hostID ?? ""):\(linkedProjectID ?? ""):\(model?.macConnected == true):\(linkRetry)") {
            guard linkedProjectID != nil, pendingLinkedRequest == nil, let model else { return }
            linkedProjectChecked = false
            guard model.macConnected == true else { linkedProjectChecked = true; return }
            await model.projects.refresh()
            if !Task.isCancelled { linkedProjectChecked = true }
        }
        .task(id: PersistenceKey(host: hostID, draft: draft)) {
            let savedDraft = draft, host = hostID
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let host, !Task.isCancelled, host == hostID, savedDraft == draft else { return }
            let saved = NewChatDraftStore.save(savedDraft, host: host)
            if !saved, !Task.isCancelled { failure = "Your draft could not be saved. Free some storage before leaving this chat." }
        }
        .onDisappear {
            if let hostID { NewChatDraftStore.save(draft, host: hostID) }
            sendTask.cancel()
            sending = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChatDictationInserted)) { notification in
            guard let hostID, notification.object as? String == hostID,
                  let saved = NewChatDraftStore.load(host: hostID), saved.requestID == draft.requestID else { return }
            draft = saved
        }
        .task { await Task.detached { NewChatDraftStore.pruneAttachments() }.value }
        .sheet(isPresented: $pairing) { PairComputerView(model: library.pairingModel()) }
    }

    private struct PersistenceKey: Hashable { let host: String?; let draft: NewChatDraft }

    /// Only shown while no Mac is paired; otherwise a Mac is always selected.
    private var noConnection: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(linkedProjectID == nil ? "Pair your Mac to get started" : "Linked computer is not paired")
                .font(.title3.weight(.semibold))
            if linkedProjectID != nil {
                Text("Pair the computer from this link to open its project.").foregroundStyle(.secondary)
            }
            Button("Add computer", systemImage: "plus") { pairing = true }.buttonStyle(.borderedProminent)
            Spacer()
        }.frame(maxWidth: .infinity).padding()
    }

    private func linkedProjectRecovery(_ model: ConnectionModel) -> some View {
        Group {
            if let pendingLinkedRequest {
                ContentUnavailableView {
                    Label("Couldn’t open project", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Your current draft could not be saved. Free some storage and try again.")
                } actions: {
                    Button("Try again") { apply(pendingLinkedRequest) }
                }
            } else if let linkedProjectID, model.projects.project(linkedProjectID)?.isIncluded == true,
               draft.destination != .project(id: linkedProjectID) {
                ContentUnavailableView {
                    Label("Couldn’t open project", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Your draft could not be saved. Free some storage and try again.")
                } actions: {
                    Button("Try again") {
                        if let hostID {
                            let destination = ChatDestination.project(id: linkedProjectID)
                            if NewChatDraftStore.save(draft, host: hostID) {
                                draft = NewChatDraftStore.load(host: hostID, destination: destination)
                                    ?? NewChatDraft(destination: destination)
                            }
                        }
                    }
                }
            } else if model.macConnected != true {
                ContentUnavailableView {
                    Label("Computer offline", systemImage: "wifi.slash")
                } description: {
                    Text("Connect to \(model.macName) to open this project.")
                } actions: {
                    Button("Try again") { linkRetry += 1; Task { await model.check(renew: true) } }
                }
            } else if !linkedProjectChecked || model.projects.loadingProjects {
                ProgressView("Checking project…")
            } else {
                ContentUnavailableView {
                    Label(model.projects.failure == nil ? "Project unavailable" : "Couldn’t check project",
                          systemImage: "folder.badge.questionmark")
                } description: {
                    Text(model.projects.failure == nil
                         ? "This project is no longer available on \(model.macName). Check the link or choose another project."
                         : "Check the connection to \(model.macName) and try again.")
                } actions: {
                    Button("Try again") { linkRetry += 1 }
                    Button("Choose a project") { linkedProjectID = nil; draft.destination = nil }
                }
            }
        }
        .accessibilityIdentifier("linked-project-recovery")
    }

    private func restore() {
        #if WONDER_DIAGNOSTICS
        if ProcessInfo.processInfo.arguments.contains("-reset-new-chat-annotations-preview") {
            NewChatDraftStore.remove(host: "studio")
        }
        if ProcessInfo.processInfo.arguments.contains("-reset-new-chat-pending-preview") {
            // Owned offline fixture; no real pairing, messages or model work.
            NewChatDraftStore.remove(host: "studio")
            let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60)).pngData { context in
                UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
            }
            if let file = try? StagedFile(name: "saved-image.png", mimeType: "image/png", data: image),
               let attachment = try? NewChatDraftStore.stage(file) {
                var pending = NewChatDraft(destination: .project(id: "preview-project"), text: "Saved unconfirmed message",
                    family: .codex, model: "preview-model")
                pending.attachments = [attachment]; pending.freeze()
                NewChatDraftStore.save(pending, host: "studio")
            }
            NewChatDraftStore.lastHost = "studio"
        }
        #endif
        guard hostID == nil else { apply(shell.newChatRequest); return }
        let saved = library.saved.connections
        let hosts = saved.map(\.credential.hostInstallationId)
        // One paired Mac needs no choice. With several, the last one used wins,
        // then one that answers, then the first, so this surface is never a dead end.
        var chosen = NewChatDraftStore.lastHost.flatMap { hosts.contains($0) ? $0 : nil }
        if chosen == nil, saved.count > 1 {
            chosen = saved.first { library.model(for: $0).macConnected == true }?.credential.hostInstallationId
        }
        if chosen == nil { chosen = hosts.first }
        if let chosen {
            hostID = chosen
            draft = NewChatDraftStore.load(host: chosen) ?? NewChatDraft()
        }
        apply(shell.newChatRequest)
    }

    private func apply(_ request: NewChatRequest?) {
        guard let request else { return }
        if request.exactProject, let host = request.host,
           case .project(let id)? = request.destination {
            // A link opens this project's own draft. Never carry words or
            // attachments from another Mac or project into the linked target.
            let destination = ChatDestination.project(id: id)
            if host != hostID || draft.destination != destination {
                if !sendTask.cancelAfterSaving(draft, hostID: hostID) {
                    linkedProjectID = id
                    pendingLinkedRequest = request
                    failure = "Your draft could not be saved. Free some storage and try again."
                    shell.newChatRequest = nil
                    return
                }
                sending = false
                failure = nil
                hostID = host
                draft = NewChatDraftStore.load(host: host, destination: destination)
                    ?? NewChatDraft(destination: destination)
                NewChatDraftStore.lastHost = host
            }
            linkedProjectID = id
            pendingLinkedRequest = nil
            linkedProjectChecked = false
            shell.newChatRequest = nil
            return
        }
        if let host = request.host, host != hostID, !switchHost(host) {
            shell.newChatRequest = nil
            return
        }
        linkedProjectID = nil
        pendingLinkedRequest = nil
        linkedProjectChecked = false
        if let destination = request.destination, !draft.isSubmitted, let hostID {
            draft = NewChatDraftStore.selecting(destination, from: draft, host: hostID, project: projectSummary(destination))
        }
        shell.newChatRequest = nil
    }

    private func projectSummary(_ destination: ChatDestination) -> ProjectSummary? {
        if case .project(let id) = destination { return model?.projects.project(id) }
        return nil
    }

    private func switchHost(_ host: String) -> Bool {
        guard host != hostID else { return true }
        guard sendTask.cancelAfterSaving(draft, hostID: hostID) else {
            failure = "Your draft could not be saved. Free some storage and try again."
            return false
        }
        sending = false
        draft = NewChatDraft.switching(from: draft, toSaved: NewChatDraftStore.load(host: host))
        hostID = host
        NewChatDraftStore.lastHost = host
        failure = nil
        return true
    }
}

/// The exact linked destination must respond to catalog changes even when the
/// connection library itself has not changed.
private struct ProjectRouteGate<Content: View>: View {
    @ObservedObject var projects: ProjectLibrary
    let content: () -> Content
    init(projects: ProjectLibrary, @ViewBuilder content: @escaping () -> Content) {
        self.projects = projects
        self.content = content
    }
    var body: some View { content() }
}

/// A send can outlive the view's pairing, including when a replacement uses the
/// same Mac and the draft still has the same request ID.
@MainActor struct NewChatSendAttempt {
    let scope: String
    let hostID: String
    let requestID: String

    func applies(to model: ConnectionModel, hostID: String?, draft: NewChatDraft) -> Bool {
        scope == model.assignmentScope && !model.accessEnded && hostID == self.hostID &&
            draft.requestID == requestID && !Task.isCancelled
    }
}

/// The view releases its send control immediately when its paired model changes.
/// Finishing a cancelled request cannot release a newer send's control.
@MainActor struct NewChatSendTask {
    private(set) var generation = UUID()
    private(set) var task: Task<Void, Never>?
    var isActive: Bool { task != nil }

    mutating func start(_ task: Task<Void, Never>) {
        guard self.task == nil else { task.cancel(); return }
        self.task = task
    }
    mutating func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
    }
    mutating func cancelAfterSaving(_ draft: NewChatDraft, hostID: String?) -> Bool {
        if let hostID, !NewChatDraftStore.save(draft, host: hostID) { return false }
        cancel()
        return true
    }
    mutating func finish(_ expected: UUID) -> Bool {
        guard generation == expected else { return false }
        task = nil
        return true
    }
}

private struct NewChatContent: View {
    @ObservedObject var library: ConnectionLibrary
    @ObservedObject var shell: ShellState
    @ObservedObject var model: ConnectionModel
    @ObservedObject var projects: ProjectLibrary
    @Binding var hostID: String?
    @Binding var draft: NewChatDraft
    @Binding var sending: Bool
    @Binding var sendTask: NewChatSendTask
    @Binding var failure: String?
    @Binding var addingProject: Bool
    @Binding var pairing: Bool
    @Binding var linkedProjectID: String?
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
    @State private var showingComputer = false
    @State private var showingFiles = false
    @State private var showingConnectionPicker = false
    @State private var pairAfterConnectionPicker = false
    @State private var savedMessages: [NewChatDraft] = []
    @State private var pendingFolderSelection: ProjectFolder?
    @State private var showingFolderChangeConfirmation = false
    @State private var editingAnnotation: PendingNewChatAnnotation?

    private var draftChat: ChatSummary {
        ChatSummary(conversationId: "new-chat:" + draft.requestID, botId: nil, title: "New chat",
            lastMessagePreview: nil, lastMessageAt: nil, messageCount: 0, deliveryState: nil,
            hasUnread: false, isArchived: false, isPinned: false)
    }

    /// The host-level computer view has no conversation; the host reserves this ID for it.
    private var hostViewChat: ChatSummary {
        ChatSummary(conversationId: "wonder-host-view", botId: nil, title: "Computer", lastMessagePreview: nil,
            lastMessageAt: nil, messageCount: 0, deliveryState: nil, hasUnread: false, isArchived: false, isPinned: false)
    }

    private var canAttach: Bool {
        !sending && !draft.isSubmitted && !loadingAttachment && draft.attachmentCount < 4
    }

    private var project: ProjectSummary? {
        if case .project(let id) = draft.destination { return projects.project(id) }
        return nil
    }
    private var projectFilesChat: ChatSummary? {
        guard let project, project.isIncluded,
              let folder = project.folders.first(where: { $0.id == (draft.folderId ?? project.primaryFolder?.id) }) else { return nil }
        return ChatSummary(conversationId: "project-files:\(project.id):\(folder.id)", botId: nil,
            title: project.name, lastMessagePreview: nil, lastMessageAt: nil, messageCount: 0,
            deliveryState: nil, hasUnread: false, isArchived: false, isPinned: false)
    }
    private var draftAnnotationActions: WorkspaceDraftAnnotationActions? {
        guard projectFilesChat != nil, let project,
              let folderID = project.folders.first(where: { $0.id == (draft.folderId ?? project.primaryFolder?.id) })?.id,
              let hostID else { return nil }
        let draftID = draft.annotations?.first?.draftID ?? draft.requestID
        let scope = model.assignmentScope
        let reason: String? = sending || draft.isSubmitted ? "Wait for this message before adding a note."
            : loadingAttachment ? "Wait for the file to finish attaching."
            : draft.attachmentCount >= 4 ? "Remove an attachment to add a note."
            : model.macConnected != true ? "Reconnect to your Mac to add a note."
            : nil
        return WorkspaceDraftAnnotationActions(projectID: project.id, draftID: draftID,
            unavailableReason: reason, stage: { annotation in
                guard scope == model.assignmentScope, self.hostID == hostID,
                      !sending, !draft.isSubmitted, !loadingAttachment, draft.attachmentCount < 4,
                      draft.destination == .project(id: project.id),
                      annotation.projectId == project.id,
                      annotation.conversationId == "new-chat:" + draftID else { throw FileFailure.integrity }
                let pending = try PendingNewChatAnnotation(annotation: annotation, draftID: draftID,
                                                           folderID: folderID, rootsRevision: project.rootsRevision)
                var next = draft
                try next.addAnnotation(pending)
                guard NewChatDraftStore.save(next, host: hostID) else { throw FileFailure.integrity }
                draft = next
                return pending.id
            }, contains: { id in draft.annotations?.contains(where: { $0.id == id }) == true },
            noteRevision: { rootID, path, sha256 in
                guard scope == model.assignmentScope, self.hostID == hostID,
                      draft.destination == .project(id: project.id),
                      (draft.folderId ?? project.primaryFolder?.id) == folderID,
                      (draft.annotations?.first?.draftID ?? draft.requestID) == draftID else { return }
                var next = draft
                next.noteWorkspaceRevision(folderID: folderID, draftID: draftID,
                                           rootID: rootID, path: path, sha256: sha256)
                if next != draft, NewChatDraftStore.save(next, host: hostID) { draft = next }
            })
    }
    private var displayedAttachments: [ComposerAttachment] {
        attachmentPresentation + (draft.annotations ?? []).map { pending in
            ComposerAttachment(id: pending.id, name: String(pending.annotation.path.split(separator: "/").last ?? "File"),
                mimeType: ArtifactAnnotation.mimeType, data: nil, remoteFile: nil,
                sha256: nil, byteSize: nil, state: "available", updatedAt: "")
        }
    }
    private var familyModels: [BotOptions.Model] {
        (projects.options?.models ?? []).filter { !$0.hidden && $0.family == draft.family }
    }
    private var selectedModel: BotOptions.Model? { familyModels.first { $0.id == draft.model } }
    private var modelTitle: String {
        guard let selectedModel else { return "Model" }
        let summary = ModelDefaults.summary(model: selectedModel, effort: draft.effort)
        let speed = selectedModel.serviceTiers?.first { $0.id == draft.serviceTier }
        return speed.map { $0.id == "default" ? summary : summary + " · " + $0.label } ?? summary
    }
    private var placeholder: String { "Message \(project?.name ?? "project")" }
    private var canSend: Bool {
        guard !sending, model.connection != nil, !model.accessEnded, model.macConnected == true else { return false }
        let text = (draft.submittedBody ?? draft.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || draft.attachmentCount > 0), draft.attachmentCount <= 4,
              text.utf8.count <= 65536, !loadingAttachment else { return false }
        guard case .project = draft.destination else { return false }
        return project != nil && draft.family != nil && draft.model != nil && projects.isAvailable(draft.family ?? .codex)
    }

    private var optionsLoadKey: String { model.assignmentScope + (model.macConnected == true ? ":ready" : ":waiting") }

    private var baseContent: some View {
        VStack(spacing: 0) {
            Group {
                if showingFiles, let projectFilesChat {
                    WorkspaceBrowser(model: model, chat: projectFilesChat, attachmentIDs: nil,
                                     draftAnnotationActions: draftAnnotationActions)
                } else {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Rerun once the connection is ready: a launch-time read can fail
        // before the session renews, and the model list must not stay empty.
        .task(id: optionsLoadKey) {
            settleDestination()
            await projects.loadOptions()
            if projects.supportsProjects == nil { await projects.refresh() }
            settleDestination()
            ensureModel()
        }
        .onChange(of: projects.projects.filter(\.isIncluded).map(\.id)) { _, _ in settleDestination() }
        .onChange(of: draft.family) { _, _ in ensureModel() }
        .onChange(of: projects.options?.models.count) { _, _ in ensureModel() }
        .task(id: model.assignmentScope + ":" + draft.requestID) {
            if let hostID { savedMessages = NewChatDraftStore.savedMessages(host: hostID).filter { $0.requestID != draft.requestID } }
        }
    }

    private var attachmentContent: some View {
        baseContent.fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
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
                            try draft.addAttachments([item])
                            return .attached
                        } catch { return .failed }
                    })
            }
        }
        .sheet(isPresented: $showingModel) { modelSheet }
        .sheet(item: $editingAnnotation) { pending in
            NewChatAnnotationEditor(pending: pending) { note in
                guard let hostID, !sending, !draft.isSubmitted,
                      draft.annotations?.contains(where: { $0.id == pending.id }) == true else { throw FileFailure.integrity }
                var next = draft
                try next.updateAnnotation(id: pending.id, note: note)
                guard NewChatDraftStore.save(next, host: hostID) else { throw FileFailure.integrity }
                draft = next
            }
        }
        .fullScreenCover(isPresented: $showingComputer) {
            NavigationStack { ComputerSessionView(model: model, chat: hostViewChat) }
        }
        .onChange(of: projectFilesChat?.id) { _, _ in showingFiles = false }
        .onChange(of: showingComputer) { _, showing in
            if showing { model.dictation.captureControlsHidden(conversationID: draftChat.id) }
        }
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
                try draft.addAttachments([item])
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
    }

    var body: some View {
        attachmentContent.fullScreenCover(item: $previewAttachment) { attachment in
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
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            DictationControls(controller: model.dictation, model: model, chat: draftChat)
            if draft.isSubmitted && !sending {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Your Mac hasn’t confirmed this message. Retry it or start a new draft. The original stays saved.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("new-chat-pending-notice")
                    HStack {
                        Button(action: startSend) { Text("Retry message").frame(minHeight: 44) }
                            .disabled(!canSend).accessibilityIdentifier("new-chat-retry")
                        Button(action: startNewDraft) { Text("New draft").frame(minHeight: 44) }
                            .accessibilityIdentifier("new-chat-start-new-draft")
                    }.buttonStyle(.plain).font(.subheadline)
                }.padding(.horizontal, 4)
            } else if !savedMessages.isEmpty && !sending {
                Menu {
                    ForEach(savedMessages, id: \.requestID) { pending in
                        Button(pending.text.isEmpty ? "Message with attachments" : String(pending.text.prefix(60))) {
                            review(pending)
                        }
                    }
                } label: {
                    Label("Saved messages", systemImage: "clock.badge.exclamationmark")
                        .font(.subheadline).frame(minHeight: 44)
                }.accessibilityIdentifier("new-chat-pending-messages")
            }
            if let failure {
                FailureDetails(draft.isSubmitted ? "Not confirmed" : "Couldn’t send", message: failure)
            }
            if model.macConnected == false {
                Text("Can’t reach \(model.macName). Your draft is saved.").font(.caption).foregroundStyle(.secondary)
            }
            if projects.supportsProjects == false {
                Text("Update Wonder on \(model.macName) to use Projects.").font(.caption).foregroundStyle(.secondary)
            }
            pickers
            DictationComposerSurface(controller: model.dictation, conversationID: draftChat.id) {
            VStack(spacing: 0) {
                if !displayedAttachments.isEmpty {
                    ComposerAttachmentStrip(attachments: displayedAttachments, imagePreviews: model.imagePreviews,
                        imagePreviewScope: model.imagePreviewScope, chatID: draft.requestID,
                        staleAnnotationIDs: Set((draft.annotations ?? []).filter(\.sourceChanged).map(\.id)),
                        removalDisabled: sending || draft.isSubmitted,
                        loadRemoteData: { _ in throw FileFailure.notUploaded }, openPhoto: { previewAttachment = $0 },
                        remove: { id in
                            if draft.annotations?.contains(where: { $0.id == id }) == true {
                                guard let hostID else { return }
                                var next = draft
                                next.removeAnnotation(id: id)
                                if NewChatDraftStore.save(next, host: hostID) { draft = next }
                                else { failure = "Could not save this change. Free some storage and try again." }
                            } else { draft.attachments?.removeAll { $0.id == id } }
                        }, editAnnotation: { item in
                            editingAnnotation = draft.annotations?.first(where: { $0.id == item.id })
                        })
                }
                if projects.supportsModes, draft.planMode == true {
                    HStack(spacing: 0) {
                        PlanModeChip(isDisabled: sending || draft.isSubmitted) { draft.planMode = nil }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 8).padding(.top, 4)
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
                        // Listed bottom-up when the menu opens above the composer.
                        if projects.supportsModes {
                            Toggle(isOn: Binding(get: { draft.planMode == true }, set: { draft.planMode = $0 ? true : nil })) {
                                Label("Plan mode", systemImage: "list.bullet.clipboard")
                            }.accessibilityIdentifier("new-chat-plan-mode")
                        }
                        Button("Camera", systemImage: "camera") {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            cameraScope = model.assignmentScope; showingCamera = true
                        }.disabled(!canAttach)
                        Button("Add photo", systemImage: "photo") { importingFor = draft.requestID; selectingPhoto = true }.disabled(!canAttach)
                        Button("Attach file", systemImage: "paperclip") { importingFor = draft.requestID; importing = true }.disabled(!canAttach)
                    } label: { Image(systemName: "plus").font(.system(size: 22)).frame(width: 44, height: 44) }
                    .disabled(sending || draft.isSubmitted).accessibilityLabel("Message actions").accessibilityIdentifier("new-chat-attach")
                    DictationButton(controller: model.dictation, chat: draftChat,
                        unavailable: sending || draft.isSubmitted || model.accessEnded,
                        prepare: {
                            guard let hostID, NewChatDraftStore.save(draft, host: hostID) else {
                                failure = "Your draft could not be saved. Free some storage and try again."
                                return false
                            }
                            return true
                        })
                    if project != nil { projectSettings } else { Spacer(minLength: 0) }
                    Button(action: startSend) {
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

    /// Where the chat goes, stacked and left-aligned above the composer.
    private var pickers: some View {
        VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 4 : 0) {
            HStack(spacing: 0) { computerMenu.disabled(sending || draft.isSubmitted); Spacer(minLength: 0) }
            HStack(spacing: 0) { projectMenu.disabled(sending || draft.isSubmitted); Spacer(minLength: 0) }
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    viewComputerButton
                    if projectFilesChat != nil { filesButton }
                }
            } else {
                HStack(spacing: 16) {
                    viewComputerButton
                    if projectFilesChat != nil { filesButton }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var viewComputerButton: some View {
        Button { showingComputer = true } label: { PickerRow(systemImage: "desktopcomputer", title: "View computer", showsChevron: false) }
            .buttonStyle(.plain).disabled(model.accessEnded)
            .accessibilityHint("Shows the screen of \(model.macName)")
            .accessibilityIdentifier("view-computer")
    }

    private var filesButton: some View {
        Button { showingFiles.toggle() } label: { PickerRow(systemImage: "folder", title: "Files", showsChevron: false) }
            .buttonStyle(.plain).disabled(model.accessEnded)
            .accessibilityValue(showingFiles ? "Open" : "Closed")
            .accessibilityHint(showingFiles ? "Return to the new chat" : "Browse the selected project folder and changes")
            .accessibilityIdentifier("new-chat-files")
    }

    private var computerMenu: some View {
        let status = model.accessEnded ? "Access ended" : model.macConnected == true ? "Connected" : model.macConnected == false ? "Offline" : "Connecting"
        return Button { showingConnectionPicker = true } label: {
            PickerRow(systemImage: "laptopcomputer", title: model.macName)
        }
        .buttonStyle(.plain).tint(.primary)
        .accessibilityLabel("Computer")
        .accessibilityValue("\(model.macName), \(status)")
        .accessibilityIdentifier("connection-picker")
        .popover(isPresented: $showingConnectionPicker, arrowEdge: .bottom) {
            let preferredHeight = CGFloat(library.saved.connections.count + 1) * 44 + 21
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(library.saved.connections, id: \.credential.hostInstallationId) { saved in
                        let candidate = library.model(for: saved)
                        let connected = !candidate.accessEnded && candidate.macConnected == true
                        let detail = candidate.accessEnded ? "Access ended" : connected ? "Connected" : candidate.macConnected == false ? "Offline" : "Connecting"
                        let selected = saved.credential.hostInstallationId == hostID
                        Button {
                            showingConnectionPicker = false
                            choose(host: saved.credential.hostInstallationId)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark")
                                    .opacity(selected ? 1 : 0).frame(width: 16)
                                Text(candidate.macName).lineLimit(2)
                                Circle().fill(connected ? Color.green : Color.secondary.opacity(0.6))
                                    .frame(width: 7, height: 7).accessibilityHidden(true)
                                Spacer(minLength: 12)
                            }
                            .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .accessibilityLabel(candidate.macName)
                        .accessibilityValue(selected ? "\(detail), Selected" : detail)
                        .accessibilityIdentifier("connection-option:" + saved.credential.hostInstallationId)
                    }
                    Divider().padding(.vertical, 4)
                    Button {
                        pairAfterConnectionPicker = true
                        showingConnectionPicker = false
                    } label: {
                        Label("Add computer", systemImage: "plus")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("connection-add-computer")
                }
                .font(.body).foregroundStyle(.primary).buttonStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("connection-options")
            .frame(idealWidth: 280, maxWidth: 320, idealHeight: preferredHeight, maxHeight: preferredHeight)
            .presentationCompactAdaptation(.popover)
            .onDisappear {
                if pairAfterConnectionPicker {
                    pairAfterConnectionPicker = false
                    pairing = true
                }
            }
        }
    }

    private var projectMenu: some View {
        Menu {
            if projects.supportsProjects != false {
                ForEach(projects.includedProjects) { listed in
                    Button { choose(destination: .project(id: listed.id), project: listed) } label: {
                        if listed.id == project?.id { Label(listed.name, systemImage: "checkmark") }
                        else { Label(listed.name, systemImage: listed.isPinned ? "pin" : "folder") }
                    }
                }
                Section {
                    Button("New project", systemImage: "folder.badge.plus") { addingProject = true }
                }
            }
        } label: {
            PickerRow(systemImage: "folder", title: project?.name ?? "Choose a project")
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain).tint(.primary)
        .accessibilityLabel("Project")
        .accessibilityValue(project?.name ?? "None")
        .accessibilityIdentifier("destination-picker")
    }

    private func choose(destination: ChatDestination, project: ProjectSummary? = nil) {
        guard let hostID else { return }
        linkedProjectID = nil
        model.dictation.captureControlsHidden(conversationID: draftChat.id)
        draft = NewChatDraftStore.selecting(destination, from: draft, host: hostID, project: project)
        ensureModel()
    }

    private func choose(host: String) {
        guard host != hostID else { return }
        guard sendTask.cancelAfterSaving(draft, hostID: hostID) else {
            failure = "Your draft could not be saved. Free some storage and try again."
            return
        }
        sending = false
        linkedProjectID = nil
        model.dictation.captureControlsHidden(conversationID: draftChat.id)
        draft = NewChatDraft.switching(from: draft, toSaved: NewChatDraftStore.load(host: host))
        hostID = host
        NewChatDraftStore.lastHost = host
        failure = nil
    }

    private var projectSettings: some View {
        let family = draft.family ?? .codex
        return HStack(spacing: 4) {
            ProjectAccessMenu(family: family, supportsModes: projects.supportsModes, access: draft.access,
                              identifier: "new-chat-access") { choice in
                draft.access = choice.result(from: draft.access, family: family, supportsModes: projects.supportsModes)
            }
            Spacer(minLength: 0)
            Button { showingModel = true } label: { ComposerModelLabel(family: draft.family, title: modelTitle) }
                .accessibilityLabel("Model")
                .accessibilityValue(family.title + ", " + (selectedModel == nil ? "Choose model" : modelTitle))
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
                            HStack(spacing: 10) {
                                ProviderIcon(family: option, size: 22)
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
                        Button { if option.id != draft.model { draft.chooseModel(option) }; remember() } label: {
                            HStack { Text(option.displayName); Spacer(); if option.id == draft.model { Image(systemName: "checkmark") } }
                        }
                    }
                }
                if let selectedModel, !selectedModel.reasoningEfforts.isEmpty {
                    Section("Reasoning") {
                        ForEach(selectedModel.reasoningEfforts) { option in
                            Button { draft.effort = option.id; remember() } label: {
                                HStack {
                                    Text(ModelDefaults.title(of: option))
                                    Spacer()
                                    if option.id == draft.effort { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
                if let selectedModel, let tiers = selectedModel.serviceTiers, tiers.count > 1 {
                    Section("Speed") {
                        ForEach(tiers) { option in
                            Button { draft.serviceTier = option.id } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.label)
                                        if let description = option.description {
                                            Text(description).font(.footnote).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if option.id == (draft.serviceTier ?? "default") { Image(systemName: "checkmark") }
                                }
                            }
                            .accessibilityIdentifier("new-chat-speed:\(option.id)")
                        }
                    }
                }
                if let project, project.folders.count > 1 {
                    Section("Working folder") {
                        ForEach(project.folders) { folder in
                            Button {
                                guard folder.id != (draft.folderId ?? project.primaryFolder?.id) else { return }
                                if (draft.annotations ?? []).isEmpty { chooseFolder(folder) }
                                else { pendingFolderSelection = folder; showingFolderChangeConfirmation = true }
                            } label: {
                                HStack {
                                    Text(folder.name); Spacer()
                                    if folder.id == (draft.folderId ?? project.primaryFolder?.id) { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
            }
            .foregroundStyle(.primary)
            .disabled(sending || draft.isSubmitted)
            .navigationTitle("Model").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { showingModel = false } }
        }
        .alert("Switch working folder?", isPresented: $showingFolderChangeConfirmation,
               presenting: pendingFolderSelection) { folder in
            Button("Keep current folder", role: .cancel) {}
            Button("Switch and remove preview notes", role: .destructive) { chooseFolder(folder) }
        } message: { _ in
            Text("The saved preview notes belong to this folder. Switching removes them from this draft.")
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
    }

    /// The next thread with this provider starts from the choice just made.
    private func remember() {
        guard let family = draft.family, let model = draft.model else { return }
        RememberedModels.save(family, model: model, effort: draft.effort)
    }

    private func chooseFolder(_ folder: ProjectFolder) {
        guard !sending, !draft.isSubmitted, let hostID else { return }
        var next = draft
        next.chooseFolder(folder.id)
        if NewChatDraftStore.save(next, host: hostID) { draft = next; showingFiles = false }
        else { failure = "Could not save the working folder. Free some storage and try again." }
    }

    /// A draft with no destination, a Bot, or a project that is gone belongs in
    /// the first included project.
    private func settleDestination() {
        if linkedProjectID != nil { return }
        var next = draft
        guard next.settle(in: projects.includedProjects) else { return }
        draft = next
        ensureModel()
    }

    /// Keep the draft on a model its provider offers, with an effort that model
    /// supports: the last choice for this provider, else the host's default.
    private func ensureModel() {
        guard !draft.isSubmitted, let project else { return }
        // A draft saved before its provider was known starts from the project's.
        if draft.family == nil { draft.family = project.lastFamily ?? .codex; return }
        var next = draft
        next.ensureModel(among: familyModels, remembered: RememberedModels.load(draft.family))
        if next != draft { draft = next }
    }

    private func importAttachment(_ load: @escaping @MainActor () async throws -> [StagedFile]) {
        guard canAttach else { return }
        let request = draft.requestID, scope = model.assignmentScope
        let remaining = 4 - draft.attachmentCount
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
                try draft.addAttachments(items)
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

    private func startSend() {
        guard !sendTask.isActive else { return }
        let generation = sendTask.generation
        sendTask.start(Task { await send(generation: generation) })
    }

    private func send(generation: UUID) async {
        defer { if sendTask.finish(generation) { sending = false } }
        guard generation == sendTask.generation, canSend,
              case .project(let projectID) = draft.destination, let hostID,
              let device = model.connection?.credential.deviceId else { return }
        sending = true; failure = nil
        guard !(draft.annotations ?? []).contains(where: \.sourceChanged) else {
            failure = "A noted file changed. Remove its note and select the current content before sending."
            return
        }
        let noteDraftID = draft.annotations?.first?.draftID ?? draft.requestID
        let folderID = draft.folderId ?? project?.primaryFolder?.id ?? ""
        let rootsRevision = draft.preparedConversationID == nil ? project?.rootsRevision : draft.rootsRevision
        do {
            for pending in draft.annotations ?? [] {
                _ = try pending.file(conversationID: "pending-validation", projectID: projectID,
                                     folderID: folderID, draftID: noteDraftID,
                                     rootsRevision: rootsRevision ?? -1)
            }
        } catch {
            failure = "A preview note no longer matches this Project folder. Remove it and select the current file before sending."
            return
        }
        let scope = model.assignmentScope
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
        let request = draft.requestID
        let attempt = NewChatSendAttempt(scope: scope, hostID: hostID, requestID: request)
        let descriptors = draft.attachments ?? []
        var files: [StagedFile]
        do { files = try await Task.detached { try NewChatDraftStore.files(descriptors) }.value }
        catch {
            guard attempt.applies(to: model, hostID: self.hostID, draft: draft) else { return }
            if draft.preparedConversationID == nil { rejectSubmission(host: hostID) }
            failure = "A saved attachment is unavailable. Remove it and attach the file again."
            return
        }
        guard attempt.applies(to: model, hostID: self.hostID, draft: draft) else { return }
        do {
            let conversation: String
            if let prepared = draft.preparedConversationID { conversation = prepared }
            else {
                let response = try await projects.createThread(projectID: projectID, draft: draft, body: body, deviceID: device)
                guard attempt.applies(to: model, hostID: self.hostID, draft: draft) else { return }
                guard let created = response.conversation.conversationId else { throw PairingFailure.response(500) }
                conversation = created
                draft.preparedConversationID = created
                NewChatDraftStore.save(draft, host: hostID)
            }
            for pending in draft.annotations ?? [] {
                files.append(try pending.file(conversationID: conversation, projectID: projectID,
                                              folderID: draft.folderId ?? "", draftID: noteDraftID,
                                              rootsRevision: draft.rootsRevision ?? -1))
            }
            let detail = try await projects.loadDetail(conversation)
            guard attempt.applies(to: model, hostID: self.hostID, draft: draft) else { return }
            let chat = model.projectChat(detail)
            try await model.prepareCreation(chat, body: body, requestID: draft.requestID, files: files)
            guard attempt.applies(to: model, hostID: self.hostID, draft: draft) else { return }
            guard let next = NewChatDraftStore.complete(draft, host: hostID) else {
                failure = "Your message is saved, but the new draft could not be saved. Free some storage and retry this message."
                return
            }
            draft = next
            // Delivery now belongs to the connection model's durable intent;
            // leaving New Chat must not cancel it or reopen this screen later.
            let deliveryModel = model
            Task { await deliveryModel.deliver(chat) }
            shell.open(host: hostID, conversation: conversation)
        } catch PairingFailure.response(412) {
            guard attempt.applies(to: model, hostID: self.hostID, draft: draft) else { return }
            rejectSubmission(host: hostID)
            let visibleRequest = draft.requestID
            await projects.refresh()
            guard scope == model.assignmentScope, !model.accessEnded, self.hostID == hostID,
                  draft.requestID == visibleRequest, !Task.isCancelled else { return }
            failure = "The project's folders changed. Review the working folder and send again."
        } catch PairingFailure.response(409) {
            guard attempt.applies(to: model, hostID: self.hostID, draft: draft) else { return }
            failure = "This request conflicts with the saved thread or its folder. Check the project on your Mac, then retry this same request."
        } catch PairingFailure.response(422) {
            guard attempt.applies(to: model, hostID: self.hostID, draft: draft) else { return }
            rejectSubmission(host: hostID)
            failure = "This project, model or access choice can’t be used. Check them and send again."
        } catch PairingFailure.response(503) {
            guard attempt.applies(to: model, hostID: self.hostID, draft: draft) else { return }
            failure = "\(model.macName) isn’t ready yet. Send again in a moment to check the same request."
        } catch {
            guard attempt.applies(to: model, hostID: self.hostID, draft: draft) else { return }
            failure = "Your Mac didn’t confirm the new thread. Send again to retry the same request; it won’t start twice."
        }
    }

    private func rejectSubmission(host: String) {
        if let next = NewChatDraftStore.reject(draft, host: host) { draft = next }
    }

    private func startNewDraft() {
        guard !sending, let hostID else { return }
        guard let next = NewChatDraftStore.startNew(from: draft, host: hostID) else {
            failure = "Your pending message could not be saved. Free some storage before starting a new draft."
            return
        }
        model.dictation.captureControlsHidden(conversationID: draftChat.id)
        draft = next; failure = nil
        savedMessages = NewChatDraftStore.savedMessages(host: hostID).filter { $0.requestID != draft.requestID }
        settleDestination(); ensureModel()
    }

    private func review(_ pending: NewChatDraft) {
        guard !sending, let hostID else { return }
        guard NewChatDraftStore.save(draft, host: hostID) else {
            failure = "Your draft could not be saved. Free some storage before reviewing this message."
            return
        }
        if !draft.text.isEmpty || draft.attachmentCount > 0 {
            guard NewChatDraftStore.save(draft, host: hostID, separately: true) else {
                failure = "Your draft could not be saved. Free some storage before reviewing this message."
                return
            }
        }
        guard NewChatDraftStore.save(pending, host: hostID, separately: true) else {
            failure = "Your draft could not be saved. Free some storage before reviewing this message."
            return
        }
        model.dictation.captureControlsHidden(conversationID: draftChat.id)
        draft = pending; failure = nil
    }
}

private struct NewChatAnnotationEditor: View {
    @Environment(\.dismiss) private var dismiss
    let pending: PendingNewChatAnnotation
    let onSave: (String) throws -> Void
    @State private var note: String
    @State private var failure: String?

    init(pending: PendingNewChatAnnotation, onSave: @escaping (String) throws -> Void) {
        self.pending = pending; self.onSave = onSave
        _note = State(initialValue: pending.annotation.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("\(pending.annotation.path) · Preview note") {
                    TextEditor(text: $note)
                        .frame(minHeight: 110)
                        .accessibilityIdentifier("annotation-edit-note")
                    if pending.sourceChanged {
                        Text("This file changed. Remove this note and select the current text before sending.")
                            .foregroundStyle(.orange)
                    }
                    if note.utf8.count > 4096 {
                        Text("Keep the note under 4,096 bytes.").foregroundStyle(.red)
                    }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle("Preview note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try onSave(note); dismiss() }
                        catch { failure = "Could not save this note. Check its text and available storage." }
                    }
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.utf8.count > 4096)
                    .accessibilityIdentifier("annotation-edit-save")
                }
            }
        }
    }
}

/// A plain, left-aligned row that opens an anchored native menu or an action:
/// a secondary icon, primary text and, for menus, the up-down chevron.
struct PickerRow: View {
    let systemImage: String
    let title: String
    var showsChevron = true
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(spacing: typeSize.isAccessibilitySize ? 12 : 8) {
            Image(systemName: systemImage)
                .font(.system(size: typeSize.isAccessibilitySize ? 28 : 17))
                .foregroundStyle(.secondary)
                .frame(width: typeSize.isAccessibilitySize ? 36 : 22)
            Text(title).foregroundStyle(.primary).lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(typeSize.isAccessibilitySize ? .system(size: 18, weight: .semibold) : .caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

extension Notification.Name {
    static let newChatDictationInserted = Notification.Name("wonder.newChatDictationInserted")
}
