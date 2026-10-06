import Foundation

// MARK: - Wire contract (packages/protocol/schemas/wonder-http-v1.json)

/// Additive host capability names from `GET /api/v1/host/status`.
public enum HostFeature {
    public static let projects = "projects-v1"
}

/// A provider-verified child of one Codex Project thread. Project tasks are
/// read-only and have no Bot conversation identity.
public struct ProjectSubagentSummary: Codable, Hashable, Identifiable, Sendable {
    public let parentConversationId: String
    public let threadId: String
    public let title: String
    public let agentNickname: String?
    public let agentRole: String?
    public let status: String
    public let isArchived: Bool
    public let canAcceptDirectInput: Bool
    public var id: String { threadId }

    public var statusLabel: String {
        let state: String = switch status {
        case "active", "running", "inProgress": "Running"
        case "idle": "Idle"
        case "pendingInit", "pending", "waiting": "Waiting"
        case "waitingOnApproval": "Waiting for approval"
        case "waitingOnUserInput": "Waiting for input"
        case "completed": "Completed"
        case "interrupted", "shutdown": "Stopped"
        case "failed", "errored": "Failed"
        case "notLoaded": "Status unknown"
        default: "Status unknown"
        }
        return isArchived ? "Archived · \(state)" : state
    }

    public func statusLabel(available: Bool) -> String {
        available ? statusLabel : "Last known: " + statusLabel
    }
}

public struct ProjectSubagentList: Codable, Sendable {
    public let available: Bool
    public let detail: String?
    public let subagents: [ProjectSubagentSummary]
    public let nextCurrentCursor: String?
    public let nextArchivedCursor: String?
}

public struct ProjectSubagentTranscript: Codable, Sendable {
    public let subagent: ProjectSubagentSummary
    public let snapshot: ConversationSnapshot
}

public enum ProjectSubagentPaths {
    private static func component(_ value: String) throws -> String {
        guard !value.isEmpty,
              let escaped = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw PairingFailure.invalidLink
        }
        return escaped
    }

    public static func roster(parentConversationId: String, archived: Bool? = nil,
                              cursor: String? = nil) throws -> String {
        let base = "/api/v1/project-conversations/\(try component(parentConversationId))/subagents"
        guard let archived else {
            guard cursor == nil else { throw PairingFailure.invalidLink }
            return base
        }
        let path = base + "?archived=\(archived ? "true" : "false")"
        guard let cursor else { return path }
        guard cursor.count <= 2048 else { throw PairingFailure.invalidLink }
        return path + "&cursor=\(try component(cursor))"
    }

    public static func transcript(parentConversationId: String, threadId: String, cursor: String? = nil) throws -> String {
        let base = try roster(parentConversationId: parentConversationId)
            + "/\(try component(threadId))/transcript"
        guard let cursor else { return base }
        return base + "?cursor=\(try component(cursor))"
    }
}

public struct ProjectFolder: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let path: String
    public let name: String
    public let isPrimary: Bool
    public let isAvailable: Bool
    public init(id: String, path: String, name: String, isPrimary: Bool, isAvailable: Bool) {
        self.id = id; self.path = path; self.name = name; self.isPrimary = isPrimary; self.isAvailable = isAvailable
    }
}

/// A named group of source folders on one paired Mac.
public struct ProjectSummary: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isIncluded: Bool
    public let isPinned: Bool
    public let rootsRevision: Int
    public let folders: [ProjectFolder]
    public let lastFamily: AgentFamily?
    public let lastUsedAt: String?
    public let createdAt: String
    public init(id: String, name: String, isIncluded: Bool = true, isPinned: Bool = false, rootsRevision: Int = 1,
                folders: [ProjectFolder], lastFamily: AgentFamily? = nil, lastUsedAt: String? = nil, createdAt: String = "") {
        self.id = id; self.name = name; self.isIncluded = isIncluded; self.isPinned = isPinned; self.rootsRevision = rootsRevision
        self.folders = folders; self.lastFamily = lastFamily; self.lastUsedAt = lastUsedAt; self.createdAt = createdAt
    }
    public var primaryFolder: ProjectFolder? { folders.first(where: \.isPrimary) ?? folders.first }
}

public struct ProjectFamilyAvailability: Codable, Hashable, Sendable {
    public let family: AgentFamily
    public let available: Bool
}

public struct ProjectsResponse: Codable, Sendable {
    public let projects: [ProjectSummary]
    public let families: [ProjectFamilyAvailability]
    /// 1 when the host accepts `claudeApproval` and `planMode`; nil on older hosts.
    public let modesVersion: Int?
    /// 1 when the host supports provider-synchronized Codex archiving.
    public let archiveVersion: Int?
    /// Pinned threads across included projects, most recent first; nil on older hosts.
    public let pinned: [PinnedProjectThread]?
    public init(projects: [ProjectSummary], families: [ProjectFamilyAvailability], modesVersion: Int? = nil, pinned: [PinnedProjectThread]? = nil, archiveVersion: Int? = nil) {
        self.projects = projects; self.families = families; self.modesVersion = modesVersion; self.pinned = pinned
        self.archiveVersion = archiveVersion
    }
}

/// A pinned thread and the project it belongs to on the same Mac.
public struct PinnedProjectThread: Codable, Hashable, Identifiable, Sendable {
    public let projectId: String
    public let thread: ProjectThreadSummary
    public var id: String { thread.reference }
    public init(projectId: String, thread: ProjectThreadSummary) { self.projectId = projectId; self.thread = thread }
}

/// How a Claude thread with project access asks before acting. Codex uses
/// its own approval policy; this applies only when `accessMode` is workspace.
public enum ClaudeApproval: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Asks before edits and commands.
    case ask
    /// Edits project files without asking; asks before commands.
    case acceptEdits = "accept_edits"
    /// Edits and runs sandboxed commands in the project without asking.
    case auto
    public var id: String { rawValue }
}

public struct ProjectPartialFailure: Codable, Hashable, Sendable {
    public let family: AgentFamily
    public let detail: String
}

public struct ProjectCandidate: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let folders: [String]
    public let sources: [AgentFamily]
    public let updatedAt: Int?
    public let isIncluded: Bool
    public var id: String { folders.joined(separator: "\n") }
}

public struct ProjectCandidatesResponse: Codable, Sendable {
    public let candidates: [ProjectCandidate]
    public let partial: [ProjectPartialFailure]
}

/// A native Codex or Claude Code thread. `conversationId` is nil until the
/// owner opens it in Wonder, which attaches it without starting work.
public struct ProjectThreadSummary: Codable, Hashable, Identifiable, Sendable {
    public let reference: String
    public let conversationId: String?
    public let title: String
    public let family: AgentFamily
    public let updatedAt: Int
    public let isPinned: Bool
    public let hasUnread: Bool
    public let isWorking: Bool
    public var id: String { reference }
    public init(reference: String, conversationId: String?, title: String, family: AgentFamily, updatedAt: Int,
                isPinned: Bool = false, hasUnread: Bool = false, isWorking: Bool = false) {
        self.reference = reference; self.conversationId = conversationId; self.title = title; self.family = family
        self.updatedAt = updatedAt; self.isPinned = isPinned; self.hasUnread = hasUnread; self.isWorking = isWorking
    }
}

public struct ProjectThreadsPage: Codable, Sendable {
    public let threads: [ProjectThreadSummary]
    public let nextCursor: String?
    public let partial: [ProjectPartialFailure]
    public init(threads: [ProjectThreadSummary], nextCursor: String?, partial: [ProjectPartialFailure]) {
        self.threads = threads; self.nextCursor = nextCursor; self.partial = partial
    }
}

/// Provider-honest access choices for a project thread.
public enum ProjectAccessMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case readOnly = "read_only", workspace, fullAccess = "full_access"
    public var id: String { rawValue }
    public func title(for family: AgentFamily) -> String {
        switch self {
        case .readOnly: return "Read only"
        case .workspace: return family == .claude ? "Ask for approval" : "Edit project"
        case .fullAccess: return "Full access"
        }
    }
    public func detail(for family: AgentFamily) -> String {
        switch self {
        case .readOnly: return "Reads files and asks before changing anything."
        case .workspace: return family == .claude
            ? "Asks before edits and commands."
            : "Edits files in the project’s folders and asks before anything else."
        case .fullAccess: return "Runs without asking, including outside the project."
        }
    }
}

/// The three settings that together describe how much a thread may do.
public struct ProjectAccess: Hashable, Sendable {
    public var accessMode: ProjectAccessMode
    public var claudeApproval: ClaudeApproval?
    public var planMode: Bool
    public init(accessMode: ProjectAccessMode = .workspace, claudeApproval: ClaudeApproval? = nil, planMode: Bool = false) {
        self.accessMode = accessMode; self.claudeApproval = claudeApproval; self.planMode = planMode
    }

    /// The fields a PATCH needs to move from `self` to `next`. Older hosts
    /// reject unknown fields, and Codex threads reject `claudeApproval`.
    public func changes(to next: ProjectAccess, family: AgentFamily, supportsModes: Bool) -> [String: Any] {
        var fields: [String: Any] = [:]
        if accessMode != next.accessMode { fields["accessMode"] = next.accessMode.rawValue }
        guard supportsModes else { return fields }
        if family == .claude, (claudeApproval ?? .ask) != (next.claudeApproval ?? .ask) {
            fields["claudeApproval"] = (next.claudeApproval ?? .ask).rawValue
        }
        if planMode != next.planMode { fields["planMode"] = next.planMode }
        return fields
    }
}

/// One row of a project thread's access menu. Codex offers its three access
/// levels; Claude offers its permission modes. Hosts without project modes keep
/// the original three levels.
public enum ProjectAccessChoice: String, CaseIterable, Identifiable, Sendable {
    case readOnly, workspace, manual, acceptEdits, auto, plan, fullAccess
    public var id: String { rawValue }

    /// Read only stays out of Claude's menu unless the thread already uses it.
    public static func choices(family: AgentFamily, supportsModes: Bool, current: ProjectAccess) -> [Self] {
        guard supportsModes, family == .claude else { return [.readOnly, .workspace, .fullAccess] }
        return (current.accessMode == .readOnly ? [.readOnly] : []) + [.manual, .acceptEdits, .auto, .plan, .fullAccess]
    }

    public static func selected(for access: ProjectAccess, family: AgentFamily, supportsModes: Bool) -> Self {
        guard supportsModes, family == .claude else {
            switch access.accessMode {
            case .readOnly: return .readOnly
            case .workspace: return .workspace
            case .fullAccess: return .fullAccess
            }
        }
        if access.planMode { return .plan }
        switch access.accessMode {
        case .readOnly: return .readOnly
        case .fullAccess: return .fullAccess
        case .workspace:
            switch access.claudeApproval ?? .ask {
            case .ask: return .manual
            case .acceptEdits: return .acceptEdits
            case .auto: return .auto
            }
        }
    }

    public func title(for family: AgentFamily, supportsModes: Bool) -> String {
        switch self {
        case .readOnly: return "Read only"
        case .workspace: return supportsModes ? "Auto" : ProjectAccessMode.workspace.title(for: family)
        case .manual: return "Manual"
        case .acceptEdits: return "Accept edits"
        case .auto: return "Auto"
        case .plan: return "Plan"
        case .fullAccess: return supportsModes && family == .claude ? "Bypass permissions" : "Full access"
        }
    }

    /// A short line that says what the choice allows.
    public func detail(for family: AgentFamily) -> String {
        switch self {
        case .readOnly: return ProjectAccessMode.readOnly.detail(for: family)
        case .workspace: return ProjectAccessMode.workspace.detail(for: family)
        case .manual: return "Asks before edits and commands."
        case .acceptEdits: return "Edits files without asking. Asks before commands."
        case .auto: return "Edits files and runs commands in the project without asking."
        case .plan: return "Plans the work without changing files."
        case .fullAccess: return ProjectAccessMode.fullAccess.detail(for: family)
        }
    }

    /// Choices that remove the safety net are drawn in warning color.
    public var isElevated: Bool { self == .fullAccess }

    public func result(from access: ProjectAccess, family: AgentFamily, supportsModes: Bool) -> ProjectAccess {
        var next = access
        switch self {
        case .readOnly: next.accessMode = .readOnly
        case .workspace: next.accessMode = .workspace
        case .manual: next.accessMode = .workspace; next.claudeApproval = ClaudeApproval.ask
        case .acceptEdits: next.accessMode = .workspace; next.claudeApproval = .acceptEdits
        case .auto: next.accessMode = .workspace; next.claudeApproval = .auto
        case .fullAccess: next.accessMode = .fullAccess
        case .plan: next.planMode = true; return next
        }
        // Claude's Plan is one of its permission modes: any other choice leaves it.
        if supportsModes && family == .claude { next.planMode = false }
        return next
    }
}

public struct ProjectConversationDetail: Codable, Hashable, Sendable {
    public let conversationId: String
    public let projectId: String
    public let projectName: String
    public let title: String
    public let family: AgentFamily
    public let model: String?
    public let effort: String?
    public let serviceTier: String?
    public let accessMode: ProjectAccessMode
    public let workingFolder: String
    public let workingFolderName: String
    public let isPinned: Bool
    public let hasUnread: Bool
    public let hasNativeSession: Bool
    /// nil on older hosts; the provider owns this state.
    public let isArchived: Bool?
    public let folderInProject: Bool
    public let notice: String?
    /// nil on hosts without project modes; see `ProjectsResponse.modesVersion`.
    public let claudeApproval: ClaudeApproval?
    /// Present only when the host supports an explicit command-sandbox opt-out.
    public let unsandboxedCommands: Bool?
    /// Codex collaboration plan mode, or Claude's plan permission mode.
    public let planMode: Bool?
    public var access: ProjectAccess {
        ProjectAccess(accessMode: accessMode, claudeApproval: claudeApproval, planMode: planMode == true)
    }
}

public struct CreateProjectThreadResponse: Codable, Sendable {
    public let conversation: ProjectThreadSummary
    public let receipt: SendReceipt?
}

public struct DesktopContinuation: Codable, Sendable {
    public struct Option: Codable, Hashable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let detail: String
        public let command: String
    }
    public let options: [Option]
    public let notes: [String]
}

// MARK: - New chat routing

/// Where the draft composer sends. Every destination belongs to the draft's
/// selected connection; changing Macs never keeps another Mac's destination.
public enum ChatDestination: Codable, Hashable, Sendable {
    /// An existing direct Bot or Group Chat conversation.
    case conversation(id: String)
    /// A genuinely new provider thread in this project.
    case project(id: String)
    case newBot
    case newGroup

    public var isCreation: Bool { self == .newBot || self == .newGroup }
}

/// One durable new-chat draft per connection. Picking a destination never
/// starts model work; only an explicit Send does.
public struct NewChatDraft: Codable, Hashable, Sendable {
    public var destination: ChatDestination?
    public var text: String
    public var family: AgentFamily?
    public var model: String?
    public var effort: String?
    public var serviceTier: String?
    public var botApprovalMode: BotApprovalMode?
    public var accessMode: ProjectAccessMode
    /// Claude only; nil keeps the host default (ask).
    public var claudeApproval: ClaudeApproval?
    /// Starts the thread in plan mode; nil or false starts normally.
    public var planMode: Bool?
    public var folderId: String?
    /// Reserved before dispatch so a lost response retries the same creation.
    public var requestID: String
    /// Set once a project thread's creation request is committed; the draft
    /// then retries the exact frozen request instead of editing it.
    public var submittedBody: String?
    public var submittedDeviceID: String?
    public var rootsRevision: Int?
    public var preparedConversationID: String?
    /// Local bytes live in the draft store, never in preferences or a Mac's
    /// remote attachment references.
    public var attachments: [NewChatAttachment]?
    /// Preview notes stay local until prepare-only creation returns a real
    /// conversation ID. They are bound to this Project and selected folder.
    public var annotations: [PendingNewChatAnnotation]?
    public var lastDictationRequestID: String?

    public init(destination: ChatDestination? = nil, text: String = "", family: AgentFamily? = nil,
                model: String? = nil, effort: String? = nil, accessMode: ProjectAccessMode = .workspace,
                folderId: String? = nil, requestID: String = UUID().uuidString.lowercased(), submittedBody: String? = nil) {
        self.destination = destination; self.text = text; self.family = family; self.model = model
        self.effort = effort; self.accessMode = accessMode; self.folderId = folderId
        self.requestID = requestID; self.submittedBody = submittedBody
    }

    public var isSubmitted: Bool { submittedBody != nil }

    /// Choosing a project applies its last-used provider as a convenience. The
    /// choice stays visible and editable; it is never a silent substitution.
    public mutating func choose(_ destination: ChatDestination, project: ProjectSummary? = nil) {
        guard !isSubmitted else { return }
        if self.destination != destination {
            folderId = nil
            annotations = nil
            if case .project = destination {
                let preferred = project?.lastFamily ?? family ?? .codex
                if family != preferred { family = preferred; model = nil; effort = nil; serviceTier = nil; claudeApproval = nil }
            }
        }
        self.destination = destination
    }

    /// Provider family is fixed once a thread exists, but a draft may change it.
    public mutating func chooseFamily(_ next: AgentFamily) {
        guard !isSubmitted, family != next else { return }
        family = next; model = nil; effort = nil
        serviceTier = nil; claudeApproval = nil
        if next == .claude, botApprovalMode == .approveForMe { botApprovalMode = .askForApproval }
    }

    /// Bots and Group Chats are no longer destinations. A draft with no
    /// destination, a retired one, or a project that is gone belongs in the
    /// first included project, keeping its words. A frozen project request is
    /// never moved: it must retry exactly what was committed.
    @discardableResult
    public mutating func settle(in projects: [ProjectSummary]) -> Bool {
        if case .project(let id) = destination, isSubmitted || projects.contains(where: { $0.id == id }) { return false }
        guard let fallback = projects.first else { return false }
        if isSubmitted { rejectSubmission() }
        destination = nil
        choose(.project(id: fallback.id), project: fallback)
        return true
    }

    /// The access settings this draft will create the thread with.
    public var access: ProjectAccess {
        get { ProjectAccess(accessMode: accessMode, claudeApproval: claudeApproval, planMode: planMode == true) }
        set { accessMode = newValue.accessMode; claudeApproval = newValue.claudeApproval; planMode = newValue.planMode ? true : nil }
    }

    /// Selecting a model starts from its own default reasoning effort.
    public mutating func chooseModel(_ option: BotOptions.Model) {
        guard !isSubmitted else { return }
        model = option.id; effort = ModelDefaults.effort(for: option); serviceTier = nil
    }

    /// Keeps the draft on a model its provider offers, with an effort that
    /// model supports. `models` is the visible catalog for `family`; a remembered
    /// choice wins over the host's default, and an existing valid choice stays.
    public mutating func ensureModel(among models: [BotOptions.Model], remembered: RememberedModel? = nil) {
        guard !isSubmitted, !models.isEmpty else { return }
        if let current = models.first(where: { $0.id == model }) {
            let valid = ModelDefaults.effort(effort, for: current)
            if valid != effort { effort = valid }
            if let serviceTier,
               !(current.serviceTiers ?? []).contains(where: { $0.id == serviceTier }),
               current.defaultServiceTier != serviceTier { self.serviceTier = nil }
        } else if let remembered, let option = models.first(where: { $0.id == remembered.model }) {
            model = option.id; effort = ModelDefaults.effort(remembered.effort, for: option); serviceTier = nil
        } else if let option = ModelDefaults.defaultModel(in: models) {
            chooseModel(option)
        }
    }

    public mutating func freeze() {
        if submittedBody == nil { submittedBody = text }
    }

    public var attachmentCount: Int { (attachments?.count ?? 0) + (annotations?.count ?? 0) }

    public mutating func addAttachments(_ items: [NewChatAttachment]) throws {
        guard !isSubmitted, attachmentCount + items.count <= 4 else { throw FileFailure.tooLarge }
        attachments = (attachments ?? []) + items
    }

    public mutating func addAnnotation(_ pending: PendingNewChatAnnotation) throws {
        guard !isSubmitted, case .project(let projectID) = destination,
              projectID == pending.annotation.projectId,
              folderId == nil || folderId == pending.folderID,
              pending.draftID == (annotations?.first?.draftID ?? requestID),
              annotations?.first?.rootsRevision == nil || annotations?.first?.rootsRevision == pending.rootsRevision,
              attachmentCount < 4 else { throw FileFailure.integrity }
        folderId = pending.folderID
        annotations = (annotations ?? []) + [pending]
    }

    public mutating func removeAnnotation(id: String) {
        guard !isSubmitted else { return }
        annotations?.removeAll { $0.id == id }
    }

    public mutating func updateAnnotation(id: String, note: String) throws {
        guard !isSubmitted, var current = annotations,
              let index = current.firstIndex(where: { $0.id == id }) else { throw FileFailure.integrity }
        current[index].annotation = try current[index].annotation.replacingNote(note)
        annotations = current
    }

    public mutating func chooseFolder(_ id: String) {
        guard !isSubmitted, folderId != id else { return }
        folderId = id
        annotations = nil
    }

    public mutating func noteWorkspaceRevision(folderID: String, draftID: String,
                                               rootID: String, path: String, sha256: String) {
        guard !isSubmitted, var current = annotations else { return }
        for index in current.indices {
            guard current[index].folderID == folderID, current[index].draftID == draftID,
                  current[index].annotation.rootId == rootID,
                  current[index].annotation.path == path else { continue }
            current[index].sourceChanged = current[index].sourceChanged || current[index].annotation.sourceSha256 != sha256
        }
        annotations = current
    }

    /// Only a definitive rejection permits editing under a fresh request ID.
    public mutating func rejectSubmission() {
        submittedBody = nil; submittedDeviceID = nil; rootsRevision = nil
        preparedConversationID = nil; requestID = UUID().uuidString.lowercased()
    }

    /// After a confirmed creation, start a fresh draft for the same place.
    public mutating func completeSubmission() {
        text = ""; attachments = nil; annotations = nil; rejectSubmission()
    }

    /// Carry typed text to another Mac without its destinations or settings.
    /// A saved draft on the new Mac wins; its text is never overwritten.
    public static func switching(from current: NewChatDraft, toSaved saved: NewChatDraft?) -> NewChatDraft {
        if let saved, !saved.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saved.isSubmitted || saved.attachmentCount > 0 { return saved }
        var next = saved ?? NewChatDraft()
        if !current.isSubmitted { next.text = current.text; next.attachments = current.attachments }
        return next
    }
}

/// The model and effort chosen last for a provider, offered to its next thread.
public struct RememberedModel: Codable, Hashable, Sendable {
    public let model: String
    public let effort: String?
    public init(model: String, effort: String?) { self.model = model; self.effort = effort }
}

/// Defaults shared by new chats and existing threads so the composer never
/// shows a model without its reasoning effort.
public enum ModelDefaults {
    /// A model's own default when it offers it, else high, medium, or its first.
    public static func effort(for model: BotOptions.Model) -> String? {
        let offered = model.reasoningEfforts.map(\.id)
        guard !offered.isEmpty else { return nil }
        if let preferred = model.defaultReasoningEffort, offered.contains(preferred) { return preferred }
        return ["high", "medium"].first(where: offered.contains) ?? offered.first
    }

    /// `requested` when the model supports it, otherwise the model's default.
    public static func effort(_ requested: String?, for model: BotOptions.Model) -> String? {
        if let requested, model.reasoningEfforts.contains(where: { $0.id == requested }) { return requested }
        return effort(for: model)
    }

    /// The model the host uses for a provider when a thread has none. Mirrors
    /// `default_model` in the host: the first visible model, avoiding Haiku.
    public static func defaultModel(in models: [BotOptions.Model]) -> BotOptions.Model? {
        models.first { !$0.hidden && $0.id != "claude:haiku" } ?? models.first { !$0.hidden }
    }

    public static func title(of effort: BotOptions.Choice) -> String {
        ["xhigh", "extra high"].contains(effort.label.lowercased()) || effort.id == "xhigh" ? "Extra high" : effort.label.capitalized
    }

    /// "Model · Effort", or just the model when it has no effort choices.
    public static func summary(model: BotOptions.Model, effort: String?) -> String {
        guard let choice = model.reasoningEfforts.first(where: { $0.id == effort }) else { return model.displayName }
        return model.displayName + " · " + title(of: choice)
    }
}

public struct NewChatAttachment: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let mimeType: String
    public let byteSize: Int
    public let sha256: String
    public init(_ file: StagedFile) {
        id = file.id; name = file.name; mimeType = file.mimeType
        byteSize = file.data.count; sha256 = ConversationFile.digest(file.data)
    }
}

/// A preview note in a New Chat draft has no provider conversation yet. The
/// immutable source binding and stable upload ID survive creation retries.
public struct PendingNewChatAnnotation: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let draftID: String
    public let folderID: String
    public let rootsRevision: Int
    public var annotation: ArtifactAnnotation
    public var sourceChanged: Bool

    public init(annotation: ArtifactAnnotation, draftID: String, folderID: String,
                rootsRevision: Int) throws {
        try annotation.validate()
        guard !draftID.isEmpty, !folderID.isEmpty, rootsRevision > 0,
              annotation.conversationId == "new-chat:" + draftID else { throw FileFailure.integrity }
        id = UUID().uuidString
        self.draftID = draftID; self.folderID = folderID; self.rootsRevision = rootsRevision
        self.annotation = annotation; sourceChanged = false
    }

    public func file(conversationID: String, projectID: String, folderID: String,
                     draftID: String, rootsRevision: Int) throws -> StagedFile {
        guard UUID(uuidString: id) != nil, !sourceChanged,
              self.draftID == draftID, self.folderID == folderID,
              self.rootsRevision == rootsRevision,
              annotation.projectId == projectID,
              annotation.conversationId == "new-chat:" + draftID,
              !conversationID.hasPrefix("new-chat:") else { throw FileFailure.integrity }
        let bound = try annotation.bound(to: conversationID)
        let file = try bound.stagedFile()
        return try StagedFile(id: id, name: file.name, mimeType: file.mimeType, data: file.data)
    }
}

// MARK: - Sidebar presentation

/// Why a Mac's rows cannot be trusted right now.
public enum SidebarHostNotice: Hashable, Sendable {
    /// The pairing ended; saved projects stay readable.
    case pairAgain
    /// The Mac cannot be reached; saved projects stay readable.
    case offline
}

public enum SidebarRow: Hashable, Identifiable, Sendable {
    case pinnedHeader
    /// A pinned thread from any Mac; `hostName` is set only when several Macs are paired.
    case pinned(hostID: String, projectID: String, projectName: String, hostName: String?, thread: ProjectThreadSummary, isSelected: Bool)
    case host(hostID: String, name: String, isOnline: Bool, isCollapsed: Bool)
    case hostNotice(hostID: String, name: String, kind: SidebarHostNotice)
    case project(hostID: String, project: ProjectSummary, isExpanded: Bool, isSelected: Bool)
    case thread(hostID: String, projectID: String, thread: ProjectThreadSummary, isSelected: Bool)
    case threadsLoading(hostID: String, projectID: String)
    case threadsNotice(hostID: String, projectID: String, message: String, canRetry: Bool)
    case moreThreads(hostID: String, projectID: String, isLoading: Bool)
    case updateRequired(hostID: String)
    case newProject(hostID: String)

    /// Stable across paging, expansion and streaming updates.
    public var id: String {
        switch self {
        case .pinnedHeader: return "pinned-header"
        case .pinned(let host, _, _, _, let thread, _): return "pinned:\(host):\(thread.reference)"
        case .host(let host, _, _, _): return "host:\(host)"
        case .hostNotice(let host, _, _): return "host-notice:\(host)"
        case .project(let host, let project, _, _): return "project:\(host):\(project.id)"
        case .thread(let host, let project, let thread, _): return "thread:\(host):\(project):\(thread.reference)"
        case .threadsLoading(let host, let project): return "loading:\(host):\(project)"
        case .threadsNotice(let host, let project, _, _): return "notice:\(host):\(project)"
        case .moreThreads(let host, let project, _): return "more:\(host):\(project)"
        case .updateRequired(let host): return "update:\(host)"
        case .newProject(let host): return "new-project:\(host)"
        }
    }

    /// A project or thread the owner can open, as opposed to headers and notices.
    public var isResult: Bool {
        switch self {
        case .pinned, .project, .thread: return true
        default: return false
        }
    }
}

/// Loaded thread pages for one expanded project, in server order.
public struct ProjectThreadsState: Hashable, Sendable {
    public var threads: [ProjectThreadSummary] = []
    public var nextCursor: String?
    public var isLoading = false
    public var failure: String?
    public var partial: [ProjectPartialFailure] = []
    public var hasLoaded = false
    public init() {}

    /// Paging appends without reordering earlier rows or duplicating a thread
    /// that moved between pages.
    public mutating func apply(_ page: ProjectThreadsPage, replacing: Bool) {
        if replacing {
            let unavailable = Set(page.partial.map(\.family))
            threads = threads.filter { unavailable.contains($0.family) }
        }
        var seen = Set(threads.map(\.reference))
        var conversations = Set(threads.compactMap(\.conversationId))
        for thread in page.threads where seen.insert(thread.reference).inserted {
            if let id = thread.conversationId, !conversations.insert(id).inserted { continue }
            threads.append(thread)
        }
        nextCursor = page.nextCursor
        partial = page.partial
        failure = nil
        hasLoaded = true
    }
}

public struct SidebarHostProjects: Sendable {
    public let hostID: String
    public let name: String
    public let isOnline: Bool
    public let supportsProjects: Bool?
    public let projects: [ProjectSummary]
    public let threads: [String: ProjectThreadsState]
    /// Pinned threads the Mac reported; empty for older Macs, whose loaded pages still show pins.
    public let pinned: [PinnedProjectThread]
    public let notice: SidebarHostNotice?
    public init(hostID: String, name: String, isOnline: Bool, supportsProjects: Bool?,
                projects: [ProjectSummary], threads: [String: ProjectThreadsState],
                pinned: [PinnedProjectThread] = [], notice: SidebarHostNotice? = nil) {
        self.hostID = hostID; self.name = name; self.isOnline = isOnline
        self.supportsProjects = supportsProjects; self.projects = projects; self.threads = threads
        self.pinned = pinned; self.notice = notice
    }
}

extension ProjectThreadSummary {
    /// The same thread with a different pin state.
    public func settingPinned(_ value: Bool) -> ProjectThreadSummary {
        ProjectThreadSummary(reference: reference, conversationId: conversationId, title: title, family: family,
                             updatedAt: updatedAt, isPinned: value, hasUnread: hasUnread, isWorking: isWorking)
    }
    /// The same thread with a confirmed read status.
    public func settingUnread(_ value: Bool) -> ProjectThreadSummary {
        ProjectThreadSummary(reference: reference, conversationId: conversationId, title: title, family: family,
                             updatedAt: updatedAt, isPinned: isPinned, hasUnread: value, isWorking: isWorking)
    }
}

/// The most recently opened project conversations, newest first. Their saved
/// history stays on the phone after the conversation list prunes the rest.
public struct RecentlyOpenedConversations: Codable, Equatable, Sendable {
    public static let limit = 30
    public private(set) var ids: [String]
    public init(ids: [String] = []) { self.ids = Array(ids.prefix(Self.limit)) }
    public mutating func note(_ id: String) {
        guard ids.first != id else { return }
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > Self.limit { ids.removeLast(ids.count - Self.limit) }
    }
}

public enum SidebarProjection {
    public static let initialThreads = 5

    /// The whole sidebar as one flat array: Pinned first, then each Mac's
    /// projects. Views render rows; they never nest a lazy list per project.
    public static func rows(hosts: [SidebarHostProjects], expanded: Set<String>, collapsedHosts: Set<String> = [],
                            selectedHost: String? = nil, selectedConversation: String?, search: String = "") -> [SidebarRow] {
        pinnedRows(hosts: hosts, selectedHost: selectedHost, selectedConversation: selectedConversation, search: search)
            + projectRows(hosts: hosts, expanded: expanded, collapsedHosts: collapsedHosts, selectedHost: selectedHost,
                          selectedConversation: selectedConversation, selectedProject: nil, search: search)
    }

    /// Pinned threads of one Mac's included projects: what the Mac reported,
    /// plus pinned threads already loaded (older Macs, or a pin not yet
    /// reported), most recent activity first.
    public static func pinnedThreads(_ host: SidebarHostProjects) -> [PinnedProjectThread] {
        let included = Set(host.projects.filter(\.isIncluded).map(\.id))
        var references = Set<String>(), conversations = Set<String>()
        var entries: [PinnedProjectThread] = []
        func add(_ entry: PinnedProjectThread) {
            guard included.contains(entry.projectId), references.insert(entry.thread.reference).inserted else { return }
            if let id = entry.thread.conversationId, !conversations.insert(id).inserted { return }
            entries.append(entry)
        }
        host.pinned.forEach(add)
        for project in host.projects where included.contains(project.id) {
            for thread in host.threads[project.id]?.threads ?? [] where thread.isPinned {
                add(PinnedProjectThread(projectId: project.id, thread: thread))
            }
        }
        return entries.enumerated().sorted { lhs, rhs in
            if lhs.element.thread.updatedAt != rhs.element.thread.updatedAt { return lhs.element.thread.updatedAt > rhs.element.thread.updatedAt }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The Pinned section across every visible Mac. Empty when nothing is pinned.
    public static func pinnedRows(hosts: [SidebarHostProjects], selectedHost: String? = nil, selectedConversation: String?,
                                  search: String = "") -> [SidebarRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var entries: [(host: SidebarHostProjects, entry: PinnedProjectThread, projectName: String)] = []
        for host in hosts where host.supportsProjects != false {
            for entry in pinnedThreads(host) {
                guard let project = host.projects.first(where: { $0.id == entry.projectId }) else { continue }
                if !query.isEmpty && !matches(entry.thread.title, query) && !matches(project.name, query) { continue }
                entries.append((host, entry, project.name))
            }
        }
        guard !entries.isEmpty else { return [] }
        let ordered = entries.enumerated().sorted { lhs, rhs in
            let left = lhs.element.entry.thread.updatedAt, right = rhs.element.entry.thread.updatedAt
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
        return [.pinnedHeader] + ordered.map { item in
            .pinned(hostID: item.host.hostID, projectID: item.entry.projectId, projectName: item.projectName,
                    hostName: hosts.count > 1 ? item.host.name : nil, thread: item.entry.thread,
                    isSelected: isSelected(item.entry.thread, host: item.host.hostID, selectedHost: selectedHost, conversation: selectedConversation))
        }
    }

    private static func isSelected(_ thread: ProjectThreadSummary, host: String, selectedHost: String?, conversation: String?) -> Bool {
        guard let id = thread.conversationId, id == conversation else { return false }
        return selectedHost == nil || selectedHost == host
    }

    /// Each Mac's header and projects. A collapsed Mac keeps only its header and notice;
    /// a search shows every match regardless.
    public static func projectRows(hosts: [SidebarHostProjects], expanded: Set<String>, collapsedHosts: Set<String> = [],
                                   selectedHost: String? = nil, selectedConversation: String?,
                                   selectedProject: String?, search: String = "") -> [SidebarRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [SidebarRow] = []
        for host in hosts {
            let isCollapsed = query.isEmpty && collapsedHosts.contains(host.hostID)
            rows.append(.host(hostID: host.hostID, name: host.name, isOnline: host.isOnline, isCollapsed: isCollapsed))
            if let notice = host.notice { rows.append(.hostNotice(hostID: host.hostID, name: host.name, kind: notice)) }
            if isCollapsed { continue }
            if host.supportsProjects == false { rows.append(.updateRequired(hostID: host.hostID)); continue }
            let visible = sorted(host.projects.filter(\.isIncluded))
            // Pinned threads live in the Pinned section, not again under their project.
            let pinnedReferences = Set(pinnedThreads(host).map(\.thread.reference))
            for project in visible {
                let state = host.threads[project.id] ?? ProjectThreadsState()
                let key = expansionKey(host: host.hostID, project: project.id)
                let nameMatches = query.isEmpty || matches(project.name, query)
                let unpinned = state.threads.filter { !pinnedReferences.contains($0.reference) }
                let matchingThreads = nameMatches ? unpinned : unpinned.filter { matches($0.title, query) }
                if !query.isEmpty && !nameMatches && matchingThreads.isEmpty { continue }
                // Search temporarily expands matches without changing saved expansion.
                let isExpanded = expanded.contains(key) || (!nameMatches && !matchingThreads.isEmpty)
                rows.append(.project(hostID: host.hostID, project: project, isExpanded: isExpanded,
                                     isSelected: selectedProject == project.id && selectedConversation == nil))
                guard isExpanded else { continue }
                for thread in matchingThreads {
                    rows.append(.thread(hostID: host.hostID, projectID: project.id, thread: thread,
                                        isSelected: isSelected(thread, host: host.hostID, selectedHost: selectedHost, conversation: selectedConversation)))
                }
                if state.isLoading && state.threads.isEmpty {
                    rows.append(.threadsLoading(hostID: host.hostID, projectID: project.id))
                } else if let failure = state.failure {
                    rows.append(.threadsNotice(hostID: host.hostID, projectID: project.id, message: failure, canRetry: true))
                } else if let partial = state.partial.first {
                    rows.append(.threadsNotice(hostID: host.hostID, projectID: project.id, message: partial.detail, canRetry: true))
                } else if state.hasLoaded && state.threads.isEmpty && nameMatches {
                    rows.append(.threadsNotice(hostID: host.hostID, projectID: project.id, message: "No threads yet", canRetry: false))
                }
                if nameMatches, state.nextCursor != nil {
                    rows.append(.moreThreads(hostID: host.hostID, projectID: project.id, isLoading: state.isLoading))
                }
            }
            if query.isEmpty, host.supportsProjects == true || !host.projects.isEmpty {
                rows.append(.newProject(hostID: host.hostID))
            }
        }
        return rows
    }

    public static func expansionKey(host: String, project: String) -> String { host + "/" + project }

    /// Pinned projects in pin order first, then recently used.
    public static func sorted(_ projects: [ProjectSummary]) -> [ProjectSummary] {
        projects.enumerated().sorted { lhs, rhs in
            if lhs.element.isPinned != rhs.element.isPinned { return lhs.element.isPinned }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func matches(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// Recent direct Bots and Group Chats: pinned first, then latest message.
/// Opening a chat or a presence update never changes this order.
public enum RecentConversations {
    public static let initialLimit = 5
    public static func ordered(_ chats: [ChatSummary]) -> [ChatSummary] {
        chats.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            let left = lhs.lastMessageAt ?? "", right = rhs.lastMessageAt ?? ""
            if left != right { return left > right }
            return lhs.id < rhs.id
        }
    }
    /// Pins always remain visible; the limit applies to unpinned rows.
    public static func visible(_ chats: [ChatSummary], showAll: Bool, limit: Int = initialLimit) -> (rows: [ChatSummary], hasMore: Bool) {
        let ordered = ordered(chats)
        if showAll { return (ordered, false) }
        let pinned = ordered.filter(\.isPinned)
        let recent = ordered.filter { !$0.isPinned }
        return (pinned + recent.prefix(limit), recent.count > limit)
    }
}
