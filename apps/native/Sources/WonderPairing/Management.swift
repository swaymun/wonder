import Foundation

public enum ScienceAvatarShape: String, CaseIterable, Codable, Sendable, Identifiable {
    case sun, orbit, nova, comet, prism, atom, luna
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct ScienceAvatarPalette: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let body: String
    public let shadow: String
    public let accent: String
    public let ink: String
    public init(id: String, name: String, body: String, shadow: String, accent: String, ink: String) {
        self.id = id; self.name = name; self.body = body; self.shadow = shadow; self.accent = accent; self.ink = ink
    }
    public static let all: [Self] = [
        .init(id: "amber", name: "Amber", body: "#ffb51c", shadow: "#ff8b20", accent: "#fff0b3", ink: "#3b2709"),
        .init(id: "coral", name: "Coral", body: "#ff925c", shadow: "#db633b", accent: "#ffe4ad", ink: "#392623"),
        .init(id: "rose", name: "Rose", body: "#e893b5", shadow: "#ba638d", accent: "#f9dce9", ink: "#54243a"),
        .init(id: "violet", name: "Violet", body: "#b4a0f3", shadow: "#7765c8", accent: "#e4dcff", ink: "#312653"),
        .init(id: "indigo", name: "Indigo", body: "#8893ee", shadow: "#5d65b8", accent: "#d9dcff", ink: "#262d56"),
        .init(id: "ocean", name: "Ocean", body: "#5699e7", shadow: "#3264ad", accent: "#b4e8ef", ink: "#182d49"),
        .init(id: "sky", name: "Sky", body: "#77cedf", shadow: "#4298b4", accent: "#d1f5f7", ink: "#17424a"),
        .init(id: "teal", name: "Teal", body: "#57b8b3", shadow: "#308e8c", accent: "#b9e9e0", ink: "#153d3c"),
        .init(id: "mint", name: "Mint", body: "#62c8aa", shadow: "#359d85", accent: "#c8f1df", ink: "#163d35"),
        .init(id: "olive", name: "Olive", body: "#adbe66", shadow: "#788c42", accent: "#e4edbe", ink: "#343d1b"),
        .init(id: "cocoa", name: "Cocoa", body: "#c49a7d", shadow: "#946d56", accent: "#ecd6c0", ink: "#40291f"),
        .init(id: "slate", name: "Slate", body: "#a4b0c5", shadow: "#77849d", accent: "#dee4ee", ink: "#293447"),
    ]
    public static func resolve(_ id: String?, legacyColor: String? = nil) -> Self {
        if let id, let exact = all.first(where: { $0.id == id }) { return exact }
        // An unknown stored ID is a future value, not a legacy color. Keep the
        // server value untouched and use the stable Amber render fallback.
        guard id == nil, let legacyID = legacyID(for: legacyColor) else { return all[0] }
        return all.first { $0.id == legacyID } ?? all[0]
    }

    /// Resolve the compatibility color used by pre-science-avatar clients.
    /// Known historical choices use explicit mappings; other valid colors use
    /// the deterministic nearest body color from the fixed catalog.
    public static func legacyID(for color: String?) -> String? {
        guard let color else { return nil }
        let normalized = color.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "#9a5a00", "#9a7253": return "amber"
        case "#3864a0", "#3478cb": return "ocean"
        case "#287b75", "#167a7a", "#168c8c": return "teal"
        case "#7654a3", "#5856d6", "#9656ad": return "violet"
        case "#a44d68": return "rose"
        default: break
        }
        guard let source = parseHex(normalized) else { return nil }
        return all.min { distance(source, to: $0) < distance(source, to: $1) }?.id
    }

    private static func parseHex(_ value: String) -> UInt32? {
        guard value.hasPrefix("#") else { return nil }
        let hex = String(value.dropFirst())
        guard hex.count == 6 else { return nil }
        return UInt32(hex, radix: 16)
    }

    private static func distance(_ source: UInt32, to palette: Self) -> Int {
        guard let body = parseHex(palette.body) else { return Int.max }
        let dr = Int((source >> 16) & 255) - Int((body >> 16) & 255)
        let dg = Int((source >> 8) & 255) - Int((body >> 8) & 255)
        let db = Int(source & 255) - Int(body & 255)
        return dr * dr + dg * dg + db * db
    }
}

/// Shared identity/catalog data for native clients. The hash identifies the
/// authored palettes and seven root SVGs validated at build time; it is not a
/// runtime asset parser or renderer input.
public enum ScienceAvatarCatalog {
    public static let sourceVersion = "science-avatar-v1"
    public static let sourceHash = "9324e397b3c5d27dd693bac25f5a776d451fb7ad941f7567f21446e79fc63c3a"
    public static let defaultShape = ScienceAvatarShape.sun
    public static let defaultPalette = "amber"
    public static let shapes = ScienceAvatarShape.allCases
    public static let palettes = ScienceAvatarPalette.all

    public static func stableShape(for identity: String) -> ScienceAvatarShape {
        let hash = identity.utf8.reduce(UInt32(2_166_136_261)) { value, byte in
            (value ^ UInt32(byte)) &* 16_777_619
        }
        return shapes[Int(hash) % shapes.count]
    }
}

public enum AgentFamily: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex, claude
    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude" : "Codex" }
    public init(model: String?) { self = model?.hasPrefix("claude:") == true ? .claude : .codex }
}

public struct ManagedBot: Codable, Identifiable, Sendable {
    public var modelSelectionRevision: Int? = nil
    public var agentFamily: String? = nil
    public var family: AgentFamily { agentFamily.flatMap(AgentFamily.init(rawValue:)) ?? AgentFamily(model: model) }
    public let id: String
    public let name: String
    public let role: String
    public let systemPrompt: String
    public let workspacePath: String
    public let permissionProfile: String
    public let permissionMode: String?
    public let approvalMode: String?
    public let model: String?
    public let reasoningEffort: String?
    public let serviceTier: String?
    public let isArchived: Bool
    public let conversationId: String?
    public let avatarColor: String?
    public let avatarShape: String?
    public let avatarPalette: String?
    public let workingDirectory: String?
}
public enum BotPermissionMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case readOnly = "read-only", workspace, fullAccess = "full-access"
    public var id: String { rawValue }
    public var title: String {
        switch self { case .readOnly: "Read-only"; case .workspace: "Workspace"; case .fullAccess: "Full access" }
    }
}

public enum BotApprovalMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case askForApproval = "ask-for-approval"
    case approveForMe = "approve-for-me"
    case fullAccess = "full-access"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .askForApproval: "Ask for approval"
        case .approveForMe: "Approve for me"
        case .fullAccess: "Full access"
        }
    }
    public var description: String {
        switch self {
        case .askForApproval: "Ask you before actions that need approval."
        case .approveForMe: "Approve eligible actions automatically within this Bot’s access."
        case .fullAccess: "Allow unrestricted file and network access without approval prompts."
        }
    }
    public func description(for family: AgentFamily) -> String {
        guard family == .claude else { return description }
        return self == .fullAccess
            ? "Allow actions within this Bot’s file access without approval prompts. Commands cannot access the network."
            : "Ask before file changes, commands, web requests and connected-app actions. Commands cannot access the network."
    }
}

public struct BotOptions: Decodable, Sendable {
    public var firstMessageModelSelection: Bool? = nil
    public struct Provider: Decodable, Identifiable, Sendable {
        public let id: String
        public let installed: Bool
        public let ready: Bool
        public let detail: String
    }
    public struct ProviderPermissions: Decodable, Sendable {
        public let permissionModes: [PermissionMode]
        public let approvalModes: [ApprovalMode]
    }
    public var agentProviders: [Provider]? = nil
    public var permissionsByFamily: [String: ProviderPermissions]? = nil
    public let groupCollaboration: Bool?
    public struct PermissionMode: Decodable, Identifiable, Sendable { public let id: String; public let allowed: Bool }
    public let permissionModes: [PermissionMode]?
    public struct ApprovalMode: Decodable, Identifiable, Sendable {
        public let id: String
        public let allowed: Bool
        public init(id: String, allowed: Bool) { self.id = id; self.allowed = allowed }
    }
    public let approvalModes: [ApprovalMode]?

    public struct Choice: Decodable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public let description: String?
    }
    public struct Model: Decodable, Identifiable, Sendable {
        public var agentFamily: String? = nil
        public var family: AgentFamily { agentFamily.flatMap(AgentFamily.init(rawValue:)) ?? AgentFamily(model: id) }
        public struct Capabilities: Decodable, Sendable {
            public let guide: Bool?
            public let goals: Bool?
            public let imageGeneration: Bool?
        }
        public var capabilities: Capabilities? = nil
        public let id: String
        public let displayName: String
        public let hidden: Bool
        public let reasoningEfforts: [Choice]
        public let serviceTiers: [Choice]?
        public let defaultServiceTier: String?
        public let defaultReasoningEffort: String?
    }
    public let models: [Model]
    public let timezone: String?
    public let allowedApprovalPolicies: [String]
    public func approvalChoices(model: String?) -> [ApprovalMode]? {
        let family = AgentFamily(model: (model?.isEmpty == false ? model : models.first(where: { !$0.hidden })?.id))
        return permissionsByFamily?[family.rawValue]?.approvalModes ?? approvalModes
    }
}
/// Only display a visible speaker at a change of speaker in a Group.
/// Direct conversations retain their identity in the header and accessibility text.
public enum SpeakerPresentation {
    public static func showsIdentity(row: ReadRow, previous: ReadRow?, isGroup: Bool) -> Bool {
        guard isGroup, !row.isUser else { return false }
        guard let previous, !previous.isUser else { return true }
        return (row.authorId ?? row.author) != (previous.authorId ?? previous.author)
    }
}

/// Durable request identity and payload live together: retries reuse both.
public struct ManagementDraft: Codable, Equatable, Sendable {
    public var requestId = UUID().uuidString
    public var values: [String: String] = [:]
    public init() {}
}
public struct ManagementDraftStore {
    public let host: String
    public let defaults: UserDefaults
    public init(host: String, defaults: UserDefaults = .standard) { self.host = host; self.defaults = defaults }
    private var prefix: String { "wonder.management." + Data(host.utf8).base64EncodedString() + "." }
    public func load(_ key: String) -> ManagementDraft? {
        defaults.data(forKey: prefix + key).flatMap { try? JSONDecoder().decode(ManagementDraft.self, from: $0) }
    }
    public func save(_ draft: ManagementDraft, key: String) throws { defaults.set(try JSONEncoder().encode(draft), forKey: prefix + key) }
    public func remove(_ key: String) { defaults.removeObject(forKey: prefix + key) }
    public func removeAll() { for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) { defaults.removeObject(forKey: key) } }
}

public struct MacLocationPage: Decodable, Sendable {
    public struct Entry: Decodable, Identifiable, Sendable {
        public let name: String
        public let path: String
        public let isDirectory: Bool
        public var id: String { path + "\u{0}" + name }
    }
    public let path: String
    public let parentPath: String?
    public let entries: [Entry]
    public let nextOffset: Int?
}
/// Global client preference, deliberately independent of host-scoped drafts.
public struct NewBotDefaults: Codable, Equatable, Sendable {
    public static let storageKey = "wonder.newBotDefaults.v1"
    public var model: String
    public var reasoningEffort: String
    public var serviceTier: String?
    public var approvalMode: BotApprovalMode
    public init(model: String = "", reasoningEffort: String = "", serviceTier: String? = nil, approvalMode: BotApprovalMode = .askForApproval) {
        self.model = model; self.reasoningEffort = reasoningEffort; self.serviceTier = serviceTier; self.approvalMode = approvalMode
    }
    private enum CodingKeys: String, CodingKey { case model, reasoningEffort, serviceTier, approvalMode }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        model = try values.decode(String.self, forKey: .model)
        reasoningEffort = try values.decode(String.self, forKey: .reasoningEffort)
        serviceTier = try values.decodeIfPresent(String.self, forKey: .serviceTier)
        approvalMode = try values.decodeIfPresent(BotApprovalMode.self, forKey: .approvalMode) ?? .askForApproval
    }
    public static func load(from defaults: UserDefaults = .standard, key: String = storageKey, fallback: Self = Self()) -> Self {
        guard let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Self.self, from: data) else { return fallback }
        return saved
    }
    public func save(to defaults: UserDefaults = .standard, key: String = Self.storageKey) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: key)
    }
    public func creationValues(options: BotOptions) throws -> [String: String] {
        let selected = model.isEmpty ? options.models.first(where: { !$0.hidden }) : options.models.first(where: { $0.id == model && !$0.hidden })
        guard let selected else { throw SelectionError.unavailableModel }
        guard let approvalModes = options.approvalChoices(model: selected.id) else { throw SelectionError.unavailableApprovalMode }
        guard approvalModes.first(where: { $0.id == approvalMode.rawValue })?.allowed == true else { throw SelectionError.unavailableApprovalMode }
        let effort = reasoningEffort.isEmpty ? selected.defaultReasoningEffort : reasoningEffort
        if let effort, !selected.reasoningEfforts.contains(where: { $0.id == effort }) { throw SelectionError.unavailableEffort }
        var values = ["model": selected.id, "approvalMode": approvalMode.rawValue]
        if let effort { values["reasoningEffort"] = effort }
        if let speed = serviceTier, !speed.isEmpty {
            guard selected.serviceTiers?.contains(where: { $0.id == speed }) == true else { throw SelectionError.unavailableSpeed }
            values["serviceTier"] = speed
        }
        return values
    }
    public enum SelectionError: LocalizedError, Equatable {
        case unavailableModel, unavailableEffort, unavailableSpeed, unavailableApprovalMode
        public var errorDescription: String? {
            switch self {
            case .unavailableModel: "The default model isn’t available on this computer. Choose another model in Settings → Model settings."
            case .unavailableSpeed: "The selected speed isn’t available on this computer. Update it in Settings → Model settings."
            case .unavailableEffort: "The default reasoning effort isn’t available on this computer. Update it in Settings → Model settings."
            case .unavailableApprovalMode: "Approval settings are unavailable. Update Wonder on your Mac, then try again."
            }
        }
    }
}

/// Client-wide choices. Each accepted operation snapshots these settings.
public enum ModelDefaultPurpose: String, CaseIterable {
    case groupParticipation
    public var key: String { "wonder.\(rawValue).v1" }
    public var initial: NewBotDefaults { NewBotDefaults(model: "gpt-5.6-luna", reasoningEffort: "xhigh") }
    public func load() -> NewBotDefaults { NewBotDefaults.load(key: key, fallback: initial) }
}
