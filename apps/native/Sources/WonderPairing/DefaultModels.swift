import Foundation

/// The owner's default model, reasoning effort and speed for each harness, as
/// the Mac stores them. A nil model means Wonder's own default. The Mac applies
/// them to the model catalog (`isDefault`, `defaultReasoningEffort`), so New
/// Chat and the composer need no rule of their own.
public struct DefaultModelPreferences: Decodable, Equatable, Sendable {
    public struct Entry: Decodable, Equatable, Sendable {
        public var family: AgentFamily
        public var model: String?
        public var effort: String?
        public var serviceTier: String?
        public init(family: AgentFamily, model: String? = nil, effort: String? = nil, serviceTier: String? = nil) {
            self.family = family; self.model = model; self.effort = effort; self.serviceTier = serviceTier
        }
    }
    public var families: [Entry]
    public init(families: [Entry]) { self.families = families }
    public func entry(_ family: AgentFamily) -> Entry { families.first { $0.family == family } ?? Entry(family: family) }
}

/// What the Settings picker offers for one harness, limited to the catalog.
public struct DefaultModelChoices: Sendable {
    public let family: AgentFamily
    public let models: [BotOptions.Model]
    public let selected: DefaultModelPreferences.Entry

    /// A stored model the catalog no longer offers shows as Wonder's default,
    /// which is what the Mac uses in that case.
    public init(family: AgentFamily, options: [BotOptions.Model], stored: DefaultModelPreferences.Entry) {
        self.family = family
        models = options.filter { $0.family == family && !$0.hidden }
        var entry = DefaultModelPreferences.Entry(family: family)
        if let model = models.first(where: { $0.id == stored.model }) {
            entry.model = model.id
            entry.effort = model.reasoningEfforts.contains { $0.id == stored.effort } ? stored.effort : nil
            entry.serviceTier = (model.serviceTiers ?? []).contains { $0.id == stored.serviceTier } ? stored.serviceTier : nil
        }
        selected = entry
    }

    public var model: BotOptions.Model? { models.first { $0.id == selected.model } }
    public var efforts: [BotOptions.Choice] { model?.reasoningEfforts ?? [] }
    public var speeds: [BotOptions.Choice] { model?.serviceTiers ?? [] }

    /// Picking another model drops an effort or speed it does not offer.
    public func choosing(model id: String?) -> DefaultModelPreferences.Entry {
        DefaultModelChoices(family: family, options: models, stored: .init(family: family, model: id, effort: selected.effort, serviceTier: selected.serviceTier)).selected
    }
    public func choosing(effort: String?) -> DefaultModelPreferences.Entry {
        var entry = selected; entry.effort = effort; return entry
    }
    public func choosing(speed: String?) -> DefaultModelPreferences.Entry {
        var entry = selected; entry.serviceTier = speed; return entry
    }

    /// The PUT body: nulls are sent so a cleared effort or speed is cleared.
    public static func body(_ entry: DefaultModelPreferences.Entry) throws -> Data {
        let value: [String: Any] = ["model": entry.model ?? NSNull(), "effort": entry.effort ?? NSNull(), "serviceTier": entry.serviceTier ?? NSNull()]
        return try JSONSerialization.data(withJSONObject: value)
    }
    public static func path(_ family: AgentFamily) -> String { "/api/v1/settings/default-models/\(family.rawValue)" }

    /// "Model · Effort", or Wonder's default when none is chosen.
    public var summary: String {
        guard let model else { return "Wonder’s default" }
        return ModelDefaults.summary(model: model, effort: selected.effort)
    }
}
