import Foundation

// MARK: - Wire contract (packages/protocol/schemas/wonder-http-v1.json)

/// Additive host capability names from `GET /api/v1/host/status`.
public enum HostFeature {
    public static let projects = "projects-v1"
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

public struct ProjectConversationDetail: Codable, Hashable, Sendable {
    public let conversationId: String
    public let projectId: String
    public let projectName: String
    public let title: String
    public let family: AgentFamily
    public let model: String?
    public let effort: String?
    public let accessMode: ProjectAccessMode
    public let workingFolder: String
    public let workingFolderName: String
    public let isPinned: Bool
    public let hasUnread: Bool
    public let hasNativeSession: Bool
    public let folderInProject: Bool
    public let notice: String?
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
            if case .project = destination {
                let preferred = project?.lastFamily ?? family ?? .codex
                if family != preferred { family = preferred; model = nil; effort = nil }
            }
        }
        self.destination = destination
    }

    /// Provider family is fixed once a thread exists, but a draft may change it.
    public mutating func chooseFamily(_ next: AgentFamily) {
        guard !isSubmitted, family != next else { return }
        family = next; model = nil; effort = nil
        serviceTier = nil
        if next == .claude, botApprovalMode == .approveForMe { botApprovalMode = .askForApproval }
    }

    public mutating func freeze() {
        if submittedBody == nil { submittedBody = text }
    }

    public mutating func appendDictation(_ transcript: String, requestID: String) throws {
        guard !isSubmitted else { throw SendFailure.pending }
        guard lastDictationRequestID != requestID else { return }
        var composer = ComposerIntent()
        composer.draft = text
        try composer.appendDictation(transcript, requestID: requestID)
        text = composer.draft
        lastDictationRequestID = composer.lastDictationRequestID
    }

    /// Only a definitive rejection permits editing under a fresh request ID.
    public mutating func rejectSubmission() {
        submittedBody = nil; submittedDeviceID = nil; rootsRevision = nil
        preparedConversationID = nil; requestID = UUID().uuidString.lowercased()
    }

    /// After a confirmed creation, start a fresh draft for the same place.
    public mutating func completeSubmission() {
        text = ""; attachments = nil; rejectSubmission()
    }

    /// Carry typed text to another Mac without its destinations or settings.
    /// A saved draft on the new Mac wins; its text is never overwritten.
    public static func switching(from current: NewChatDraft, toSaved saved: NewChatDraft?) -> NewChatDraft {
        if let saved, !saved.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saved.isSubmitted || !(saved.attachments ?? []).isEmpty { return saved }
        var next = saved ?? NewChatDraft()
        if !current.isSubmitted { next.text = current.text; next.attachments = current.attachments }
        return next
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

// MARK: - Sidebar presentation

public enum SidebarRow: Hashable, Identifiable, Sendable {
    case host(hostID: String, name: String, isOnline: Bool)
    case project(hostID: String, project: ProjectSummary, isExpanded: Bool, isSelected: Bool)
    case thread(hostID: String, projectID: String, thread: ProjectThreadSummary, isSelected: Bool)
    case threadsLoading(hostID: String, projectID: String)
    case threadsNotice(hostID: String, projectID: String, message: String, canRetry: Bool)
    case moreThreads(hostID: String, projectID: String, isLoading: Bool)
    case updateRequired(hostID: String)
    case emptyProjects(hostID: String)

    /// Stable across paging, expansion and streaming updates.
    public var id: String {
        switch self {
        case .host(let host, _, _): return "host:\(host)"
        case .project(let host, let project, _, _): return "project:\(host):\(project.id)"
        case .thread(let host, let project, let thread, _): return "thread:\(host):\(project):\(thread.reference)"
        case .threadsLoading(let host, let project): return "loading:\(host):\(project)"
        case .threadsNotice(let host, let project, _, _): return "notice:\(host):\(project)"
        case .moreThreads(let host, let project, _): return "more:\(host):\(project)"
        case .updateRequired(let host): return "update:\(host)"
        case .emptyProjects(let host): return "empty:\(host)"
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
    public init(hostID: String, name: String, isOnline: Bool, supportsProjects: Bool?,
                projects: [ProjectSummary], threads: [String: ProjectThreadsState]) {
        self.hostID = hostID; self.name = name; self.isOnline = isOnline
        self.supportsProjects = supportsProjects; self.projects = projects; self.threads = threads
    }
}

public enum SidebarProjection {
    public static let initialThreads = 5

    /// One flat array for the whole Projects section. Views render rows; they
    /// never nest a lazy list per project.
    public static func projectRows(hosts: [SidebarHostProjects], expanded: Set<String>, selectedConversation: String?,
                                   selectedProject: String?, search: String = "") -> [SidebarRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [SidebarRow] = []
        for host in hosts {
            if hosts.count > 1 { rows.append(.host(hostID: host.hostID, name: host.name, isOnline: host.isOnline)) }
            if host.supportsProjects == false { rows.append(.updateRequired(hostID: host.hostID)); continue }
            let visible = sorted(host.projects.filter(\.isIncluded))
            if visible.isEmpty && query.isEmpty && host.supportsProjects == true { rows.append(.emptyProjects(hostID: host.hostID)) }
            for project in visible {
                let state = host.threads[project.id] ?? ProjectThreadsState()
                let key = expansionKey(host: host.hostID, project: project.id)
                let nameMatches = query.isEmpty || matches(project.name, query)
                let matchingThreads = nameMatches ? state.threads : state.threads.filter { matches($0.title, query) }
                if !query.isEmpty && !nameMatches && matchingThreads.isEmpty { continue }
                // Search temporarily expands matches without changing saved expansion.
                let isExpanded = expanded.contains(key) || (!nameMatches && !matchingThreads.isEmpty)
                rows.append(.project(hostID: host.hostID, project: project, isExpanded: isExpanded,
                                     isSelected: selectedProject == project.id && selectedConversation == nil))
                guard isExpanded else { continue }
                let threads = orderedThreads(matchingThreads)
                for thread in threads {
                    rows.append(.thread(hostID: host.hostID, projectID: project.id, thread: thread,
                                        isSelected: thread.conversationId != nil && thread.conversationId == selectedConversation))
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

    /// Pinned threads lead, the rest keep server recency, with stable ties.
    public static func orderedThreads(_ threads: [ProjectThreadSummary]) -> [ProjectThreadSummary] {
        threads.enumerated().sorted { lhs, rhs in
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
