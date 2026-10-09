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

/// One harness's default across every paired Mac. The picker lists the union of
/// the Macs' catalogs; a choice is written to each Mac that offers that model.
public struct AppDefaultModels: Sendable {
    public struct Mac: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let models: [BotOptions.Model]
        public let stored: DefaultModelPreferences
        public init(id: String, name: String, models: [BotOptions.Model], stored: DefaultModelPreferences) {
            self.id = id; self.name = name; self.models = models; self.stored = stored
        }
    }
    public struct Option: Identifiable, Sendable, Equatable {
        public let id: String
        public let displayName: String
        /// Names of the Macs that offer this model.
        public let macNames: [String]
        /// True when some paired Mac does not offer it.
        public let partial: Bool
    }
    public struct Write: Equatable, Sendable {
        public let macID: String
        public let entry: DefaultModelPreferences.Entry
    }

    public let family: AgentFamily
    public let macs: [Mac]
    private let perMac: [(mac: Mac, choices: DefaultModelChoices)]

    public init(family: AgentFamily, macs: [Mac]) {
        self.family = family
        self.macs = macs
        perMac = macs.map { ($0, DefaultModelChoices(family: family, options: $0.models, stored: $0.stored.entry(family))) }
    }

    public var options: [Option] {
        var order: [String] = []
        var names: [String: String] = [:]
        var holders: [String: [String]] = [:]
        for (mac, choices) in perMac {
            for model in choices.models {
                if names[model.id] == nil { order.append(model.id); names[model.id] = model.displayName }
                holders[model.id, default: []].append(mac.name)
            }
        }
        return order.map { id in
            Option(id: id, displayName: names[id] ?? id, macNames: holders[id] ?? [], partial: (holders[id] ?? []).count < macs.count)
        }
    }

    /// The first Mac with a valid stored model speaks for the picker; with none, Wonder's default.
    private var reference: DefaultModelChoices? {
        perMac.first { $0.choices.selected.model != nil }?.choices
    }
    public var selected: DefaultModelPreferences.Entry { reference?.selected ?? .init(family: family) }
    public var efforts: [BotOptions.Choice] { reference?.efforts ?? [] }
    public var speeds: [BotOptions.Choice] { reference?.speeds ?? [] }

    private func offering(_ id: String?) -> [(mac: Mac, choices: DefaultModelChoices)] {
        guard let id else { return perMac }
        return perMac.filter { $0.choices.models.contains { $0.id == id } }
    }

    /// True when the Macs that offer the chosen model do not store the same choice.
    public var differsBetweenComputers: Bool {
        let entries = offering(selected.model).map(\.choices.selected)
        return entries.contains { $0 != entries[0] }
    }

    /// Macs that do not offer the chosen model and keep their own default.
    public var computersWithoutSelection: [String] {
        guard let id = selected.model else { return [] }
        return perMac.filter { !$0.choices.models.contains { $0.id == id } }.map(\.mac.name)
    }

    public func writes(choosing model: String?) -> [Write] {
        let entry = model == nil ? DefaultModelPreferences.Entry(family: family)
            : .init(family: family, model: model, effort: selected.effort, serviceTier: selected.serviceTier)
        return writes(applying: entry, to: offering(model))
    }
    public func writes(choosingEffort effort: String?) -> [Write] {
        var entry = selected; entry.effort = effort
        return writes(applying: entry, to: offering(selected.model))
    }
    public func writes(choosingSpeed speed: String?) -> [Write] {
        var entry = selected; entry.serviceTier = speed
        return writes(applying: entry, to: offering(selected.model))
    }

    /// Each Mac keeps only what its own catalog offers for the model.
    private func writes(applying entry: DefaultModelPreferences.Entry,
                        to targets: [(mac: Mac, choices: DefaultModelChoices)]) -> [Write] {
        targets.map { Write(macID: $0.mac.id, entry: DefaultModelChoices(family: family, options: $0.mac.models, stored: entry).selected) }
    }
}
