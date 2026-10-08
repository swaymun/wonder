import Foundation

/// The model one message is sent with. For a Project thread it may belong to
/// the other provider; the host then moves the thread to that provider when the
/// message is delivered, in order and without stopping work that is running.
public struct ProjectMessageModel: Codable, Hashable, Sendable {
    public var family: AgentFamily
    public var model: String
    public var effort: String?
    public var serviceTier: String?

    public init(family: AgentFamily, model: String, effort: String? = nil, serviceTier: String? = nil) {
        self.family = family
        self.model = model
        self.effort = effort
        self.serviceTier = serviceTier
    }
}

/// One provider's models in the composer picker.
public struct ProjectModelGroup: Identifiable, Sendable {
    public let family: AgentFamily
    public let models: [BotOptions.Model]
    public var id: String { family.rawValue }
    /// Shown under the other provider's models, where the choice does more
    /// than change a setting.
    public var note: String? {
        "Your next message goes to \(family.title). It starts a fresh \(family.title) session with a summary-free copy of recent messages; older details stay readable to it on request."
    }
}

/// How the composer treats a model chosen for a Project thread.
public enum ProjectModelPicker {
    /// Visible models grouped by provider, the thread's own provider first.
    public static func groups(models: [BotOptions.Model], current: AgentFamily) -> [ProjectModelGroup] {
        let visible = models.filter { !$0.hidden }
        return ([current] + AgentFamily.allCases.filter { $0 != current }).compactMap { family in
            let own = visible.filter { $0.family == family }
            return own.isEmpty ? nil : ProjectModelGroup(family: family, models: own)
        }
    }

    public enum Choice: Equatable, Sendable {
        /// Same provider: saved on the thread now, as before.
        case saveToThread
        /// Other provider: carried by the next message and applied on delivery.
        case sendWithNextMessage(ProjectMessageModel)
    }

    public static func choice(current: AgentFamily, option: BotOptions.Model, effort: String?, serviceTier: String?) -> Choice {
        option.family == current
            ? .saveToThread
            : .sendWithNextMessage(ProjectMessageModel(family: option.family, model: option.id, effort: effort, serviceTier: serviceTier))
    }

    /// A carried choice ends once the host has applied it to the thread.
    public static func isApplied(_ pending: ProjectMessageModel, to detail: ProjectConversationDetail?) -> Bool {
        guard let detail else { return false }
        return detail.family == pending.family && detail.model == pending.model
    }
}
