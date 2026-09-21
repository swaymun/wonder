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

    public static func stablePalette(for identity: String) -> String {
        let hash = ("palette:" + identity).utf8.reduce(UInt32(2_166_136_261)) { value, byte in
            (value ^ UInt32(byte)) &* 16_777_619
        }
        return palettes[Int(hash) % palettes.count].id
    }
}

public struct ManagedBot: Codable, Identifiable, Sendable {
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
    public static let selectedWorkspaceDescription = "Use the Workspace and locations added in Bot settings, keeping each location’s saved read or write access."
    public var scopeDescription: String {
        switch self {
        case .readOnly: "Read files across your Mac. Ask before editing files or accessing the network. macOS protections still apply."
        case .workspace: "Read files across your Mac. Edit the Workspace, folders you added with write access in Bot settings, and system temporary folders. Ask before writing elsewhere or accessing the network."
        case .fullAccess: "Access files and the network without Codex sandbox restrictions or approval prompts. Saved locations do not limit access. macOS protections still apply."
        }
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
}

public struct BotOptions: Decodable, Sendable {
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
}
public struct ManagedAutomation: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let botId: String
    public let conversationId: String?
    public let prompt: String
    public let rrule: String
    public let timezone: String
    public let status: String
    public let scopeType: String
    public let scopeId: String
    public let nextRunAt: String?
    public let lastAttemptAt: String?
    public let lastSuccessAt: String?
    /// A Bot-level automation may be edited while another of its chats is open.
    public func targetConversation(selectedKind: String, currentConversation: String) -> String {
        if kind == "continuation", selectedKind == "continuation", let conversationId { return conversationId }
        return currentConversation
    }
}
public struct ManagedAutomationRun: Decodable, Identifiable, Sendable {
    public let id: String
    public let status: String
    public let startedAt: String
    public let finishedAt: String?
    public let error: String?
    public let conversationId: String?
}
public struct SchedulePreview: Decodable, Sendable { public let nextRunAt: String?; public let timezone: String }

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
    public mutating func prepareNewBot(defaults: NewBotDefaults, options: BotOptions) throws {
        guard values["_defaultsResolved"] == nil else { return }
        values = try defaults.creationValues(options: options)
        values["_defaultsResolved"] = "true"
    }
    public func canSaveBotPermission(options: BotOptions?) -> Bool {
        guard let selected = values["permissionMode"] else { return true }
        return options?.permissionModes?.first(where: { $0.id == selected })?.allowed == true
    }
    public func canSaveBotApproval(options: BotOptions?) -> Bool {
        guard let selected = values["approvalMode"] else { return true }
        return options?.approvalModes?.first(where: { $0.id == selected })?.allowed == true
    }
    /// A submitted create is an immutable retry payload, including omitted fields.
    public mutating func prepareBotPermission(isNew: Bool, currentMode: String?) {
        guard values["permissionMode"] == nil, values["_submitted"] != "true" else { return }
        if let currentMode { values["permissionMode"] = currentMode }
        else if isNew { values["permissionMode"] = BotPermissionMode.workspace.rawValue }
    }
    public mutating func prepareBotApproval(isNew: Bool, currentMode: String?) {
        guard values["approvalMode"] == nil, values["_submitted"] != "true" else { return }
        values["approvalMode"] = currentMode ?? (values["permissionMode"] == BotPermissionMode.fullAccess.rawValue ? BotApprovalMode.fullAccess.rawValue : BotApprovalMode.askForApproval.rawValue)
    }
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

/// Map only recurrence combinations the native controls can represent exactly.
/// Keep the received rule byte-for-byte until a recurrence control is changed.
public enum AutomationScheduleForm {
    public static let recurrenceFields: Set<String> = ["schedule", "hour", "minute", "weekday", "monthday", "custom"]
    public static func values(for rule: String) -> [String: String] {
        var result = ["schedule": "custom", "custom": rule, "_originalRule": rule, "_scheduleChanged": "false", "hour": "9", "minute": "0", "weekday": "MO", "monthday": "1"]
        var fields: [String: String] = [:]
        for component in rule.split(separator: ";", omittingEmptySubsequences: false) {
            let parts = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, fields[String(parts[0])] == nil else { return result }
            fields[String(parts[0])] = String(parts[1])
        }
        guard Set(fields.keys).isSubset(of: ["FREQ", "INTERVAL", "BYHOUR", "BYMINUTE", "BYDAY", "BYMONTHDAY"]),
              Int(fields["INTERVAL"] ?? "1") == 1,
              let hour = Int(fields["BYHOUR"] ?? "9"), (0...23).contains(hour),
              let minute = Int(fields["BYMINUTE"] ?? "0"), (0...59).contains(minute),
              let monthDay = Int(fields["BYMONTHDAY"] ?? "1"), (1...31).contains(monthDay)
        else { return result }
        let days = Set((fields["BYDAY"] ?? "").split(separator: ",").map(String.init))
        let validDays: Set<String> = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
        guard days.isSubset(of: validDays) else { return result }
        let schedule: String
        switch fields["FREQ"] {
        case "HOURLY" where fields["BYHOUR"] == nil && fields["BYDAY"] == nil && fields["BYMONTHDAY"] == nil:
            schedule = "hourly"
        case "DAILY", "WEEKLY":
            guard fields["BYMONTHDAY"] == nil else { return result }
            if days.isEmpty && fields["FREQ"] == "DAILY" && fields["BYDAY"] == nil { schedule = "daily" }
            else if days == ["MO", "TU", "WE", "TH", "FR"] { schedule = "weekdays" }
            else if days.count == 1 { schedule = "weekly"; result["weekday"] = days.first }
            else { return result }
        case "MONTHLY" where fields["BYDAY"] == nil:
            schedule = "monthly"
        default: return result
        }
        result["schedule"] = schedule; result["hour"] = String(hour); result["minute"] = String(minute); result["monthday"] = String(monthDay)
        return result
    }
    public static func rule(for values: [String: String]) -> String {
        if values["_scheduleChanged"] != "true", let original = values["_originalRule"] { return original }
        let hour = values["hour", default: "9"], minute = values["minute", default: "0"]
        switch values["schedule", default: "daily"] {
        case "hourly": return "FREQ=HOURLY;BYMINUTE=\(minute)"
        case "weekdays": return "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=\(hour);BYMINUTE=\(minute)"
        case "weekly": return "FREQ=WEEKLY;BYDAY=\(values["weekday", default: "MO"]);BYHOUR=\(hour);BYMINUTE=\(minute)"
        case "monthly": return "FREQ=MONTHLY;BYMONTHDAY=\(values["monthday", default: "1"]);BYHOUR=\(hour);BYMINUTE=\(minute)"
        case "custom": return values["custom", default: ""]
        default: return "FREQ=DAILY;BYHOUR=\(hour);BYMINUTE=\(minute)"
        }
    }
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
public struct BotFileAccessState: Decodable, Sendable {
    public let revision: Int
    public let appliedRevision: Int
    public let readRoots: [String]
    public let writeRoots: [String]
}
public struct BotFileAccessReply: Decodable, Sendable { public let access: BotFileAccessState }

/// Persist both permission level and location kind with the Bot draft.
public struct BotFileSelection: Codable, Equatable, Sendable {
    public var readRoots: [String] = []
    public var writeRoots: [String] = []
    public var directoryRoots: [String] = []
    public var workingDirectory: String?
    public init() {}
    public mutating func select(path: String, isDirectory: Bool, writable: Bool) {
        readRoots.removeAll { $0 == path }; writeRoots.removeAll { $0 == path }
        if writable { writeRoots.append(path); writeRoots.sort() }
        else { readRoots.append(path); readRoots.sort() }
        if isDirectory, !directoryRoots.contains(path) { directoryRoots.append(path); directoryRoots.sort() }
    }
    public mutating func remove(path: String) {
        readRoots.removeAll { $0 == path }; writeRoots.removeAll { $0 == path }; directoryRoots.removeAll { $0 == path }
        if let directory = workingDirectory, (directory == path || directory.hasPrefix(path + "/")),
           !(readRoots + writeRoots).contains(where: { directory == $0 || directory.hasPrefix($0 + "/") }) { workingDirectory = nil }
    }
    public var encodedDraft: String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "" }
    public static func draft(_ value: String?) -> Self {
        value.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
    public func matches(_ state: BotFileAccessState) -> Bool {
        Set(readRoots) == Set(state.readRoots) && Set(writeRoots) == Set(state.writeRoots)
    }
    public func creationBody(fields: [String: String]) throws -> Data {
        var body: [String: Any] = fields.filter { !$0.key.hasPrefix("_") }
        body["readRoots"] = readRoots; body["writeRoots"] = writeRoots
        if let workingDirectory { body["workingDirectory"] = workingDirectory }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
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
        guard let approvalModes = options.approvalModes else { throw SelectionError.unavailableApprovalMode }
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
public enum ModelDefaultPurpose: String, CaseIterable, Identifiable {
    case newBots, groupParticipation, groupCreation
    public var id: String { rawValue }
    public var title: String {
        switch self { case .newBots: "New Bots"; case .groupParticipation: "Group participation"; case .groupCreation: "Group creation" }
    }
    public var key: String { self == .newBots ? NewBotDefaults.storageKey : "wonder.\(rawValue).v1" }
    public var initial: NewBotDefaults { self == .newBots ? NewBotDefaults() : NewBotDefaults(model: "gpt-5.6-luna", reasoningEffort: "xhigh") }
    public func load() -> NewBotDefaults { NewBotDefaults.load(key: key, fallback: initial) }
}
