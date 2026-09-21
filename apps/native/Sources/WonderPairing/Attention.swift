import Foundation
import CryptoKit

public struct AttentionRequest: Codable, Identifiable, Sendable {
    public let approvalId: String
    public let method: String
    public let params: AttentionParams
    public let actionNonce: String
    public let conversationId: String?
    public let resolutionIdempotencyKey: String?
    public var id: String { approvalId }
    /// Only the daemon's top-level mapping can route a Group child request.
    /// Legacy thread matching is restricted to direct conversations.
    public func belongs(to conversationID: String, isDirect: Bool, threadIDs: Set<String>) -> Bool {
        if let conversationId { return conversationId == conversationID }
        return isDirect && params.threadId.map(threadIDs.contains) == true
    }
    public var isQuestion: Bool { method == "item/tool/requestUserInput" }
    public var computerAction: ComputerAction? {
        guard method == "item/tool/call", params.tool == "wonder_computer_use",
              let action = params.arguments, action.detail != nil else { return nil }
        return action
    }
    public var supportsDecision: Bool {
        !phoneChoices.isEmpty
    }
}
public struct AttentionParams: Codable, Sendable {
    public let tool: String?
    public let arguments: ComputerAction?
    public let threadId: String?
    public let turnId: String?
    public let reason: String?
    public let command: String?
    public let cwd: String?
    public let filePath: String?
    public let isBlocking: Bool?
    public let expiresAtMs: UInt64?
    public let questions: [ChatQuestion]?
    public let changes: [RequestedFileChange]?
    // Unknown structured decisions are deliberately not converted to strings.
    public let availableDecisions: [DecisionValue]?
    public let permissions: TeachingJSONValue?
    public let additionalPermissions: TeachingJSONValue?
    public let networkApprovalContext: TeachingJSONValue?
    public let grantRoot: String?
    public let message: String?
    public let mode: String?
    public let url: String?
    public let requestedSchema: TeachingJSONValue?
}

public struct PhoneApprovalChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let decision: String
    public let structuredDecision: TeachingJSONValue?
    fileprivate init(_ id: String, _ title: String, _ detail: String? = nil,
                     decision: String? = nil, structured: TeachingJSONValue? = nil) {
        self.id = id; self.title = title; self.detail = detail
        self.decision = decision ?? id; structuredDecision = structured
    }
}

public struct PhoneApprovalField: Identifiable, Sendable {
    public enum Kind: String, Sendable { case text, number, integer, boolean, choice, multiChoice }
    public let id: String
    public let title: String
    public let kind: Kind
    public let options: [String]
    public let optionTitles: [String: String]
    public let detail: String?
    public let defaultValue: String?
    public let required: Bool
    public let secret: Bool
    fileprivate let schema: [String: TeachingJSONValue]
}

public enum PhoneApprovalError: Error, LocalizedError {
    case invalidChoice, invalidAnswers
    public var errorDescription: String? {
        switch self {
        case .invalidChoice: "This choice is no longer available. Refresh the request."
        case .invalidAnswers: "Complete the requested fields with valid values before replying."
        }
    }
}

extension AttentionRequest {
    public var phoneChoices: [PhoneApprovalChoice] {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            let advertised = params.availableDecisions ?? [.text("accept"), .text("acceptForSession"), .text("decline"), .text("cancel")]
            var seen = Set<String>()
            return advertised.compactMap(commandChoice).filter { seen.insert($0.id).inserted }
        case "item/permissions/requestApproval":
            var choices: [PhoneApprovalChoice] = []
            if parsedPermissions != nil {
                choices += [PhoneApprovalChoice("allowTurn", "Allow for this turn", decision: "accept"),
                            PhoneApprovalChoice("allowSession", "Allow for this session", "Keeps these permissions for the current session.", decision: "acceptForSession")]
            }
            choices.append(PhoneApprovalChoice("decline", "Decline"))
            return choices
        case "mcpServer/elicitation/request":
            var choices: [PhoneApprovalChoice] = []
            if elicitationURL != nil {
                choices.append(PhoneApprovalChoice("accept", "I’ve completed this", "Confirm after finishing the request in your browser."))
            } else if parsedForm != nil {
                choices.append(PhoneApprovalChoice("accept", "Submit"))
            }
            return choices + [PhoneApprovalChoice("decline", "Decline"), PhoneApprovalChoice("cancel", "Cancel request")]
        case "item/tool/call":
            if computerAction != nil {
                return [PhoneApprovalChoice("accept", "Allow once"), PhoneApprovalChoice("decline", "Decline")]
            }
            return [PhoneApprovalChoice("decline", "Decline", decision: "respond")]
        default: return []
        }
    }

    private func commandChoice(_ value: DecisionValue) -> PhoneApprovalChoice? {
        switch value {
        case .text(let decision):
            switch decision {
            case "accept": return PhoneApprovalChoice(decision, "Allow once")
            case "acceptForSession": return PhoneApprovalChoice(decision, "Allow for this session", "Future matching requests in this session can run without asking again.")
            case "decline": return PhoneApprovalChoice(decision, "Decline")
            case "cancel": return PhoneApprovalChoice(decision, "Stop this turn", "Decline the request and stop the current response.")
            default: return nil
            }
        case .structured(let value):
            guard method == "item/commandExecution/requestApproval", let object = value.approvalDictionary, object.count == 1 else { return nil }
            if let amendment = object["acceptWithExecpolicyAmendment"]?.approvalDictionary,
               Set(amendment.keys) == ["execpolicy_amendment"],
               let prefix = amendment["execpolicy_amendment"]?.approvalStrings, !prefix.isEmpty {
                let words = prefix.map { (try? approvalJSON(.string($0))) ?? $0 }.joined(separator: " ")
                return PhoneApprovalChoice("execpolicy:" + words, "Allow and remember command", "Future commands starting with these exact arguments can run without asking:\n" + words,
                    decision: "acceptWithExecpolicyAmendment", structured: value)
            }
            if let amendment = object["applyNetworkPolicyAmendment"]?.approvalDictionary,
               Set(amendment.keys) == ["network_policy_amendment"],
               let rule = amendment["network_policy_amendment"]?.approvalDictionary,
               Set(rule.keys) == ["action", "host"],
               let action = rule["action"]?.approvalString, ["allow", "deny"].contains(action),
               let host = rule["host"]?.approvalString, !host.isEmpty {
                return PhoneApprovalChoice("network:" + action + ":" + host,
                    action == "allow" ? "Always allow this host" : "Always block this host",
                    "Save a network rule for \(host).", decision: "applyNetworkPolicyAmendment", structured: value)
            }
            return nil
        case .unsupported: return nil
        }
    }

    public var permissionDetails: [String] {
        var details: [String] = []
        if let root = params.grantRoot { details.append("Requested write access for this session: \(root)") }
        for profile in [params.permissions, params.additionalPermissions].compactMap({ $0 }) {
            if let parsed = permissionDescriptions(profile) { details += parsed }
            else { details.append("Some requested permissions cannot be displayed safely.") }
        }
        if let network = params.networkApprovalContext?.approvalDictionary,
           let host = network["host"]?.approvalString {
            details.append("Connect to \(host)" + (network["protocol"]?.approvalString.map { " using \($0)." } ?? "."))
        }
        return details
    }

    private var parsedPermissions: TeachingJSONValue? {
        guard let permissions = params.permissions, permissionDescriptions(permissions) != nil else { return nil }
        return permissions
    }

    public var elicitationFields: [PhoneApprovalField] { parsedForm ?? [] }

    public var elicitationURL: URL? {
        guard method == "mcpServer/elicitation/request", params.mode == "url",
              let value = params.url, let url = URL(string: value),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    public var unsupportedReason: String? {
        switch method {
        case "item/tool/call" where computerAction == nil:
            return "This action cannot be run safely. You can decline it here so the Bot can choose another approach."
        case "item/permissions/requestApproval" where parsedPermissions == nil:
            return "This permission request has details Wonder cannot safely interpret. Decline it to continue."
        case "mcpServer/elicitation/request" where parsedForm == nil && elicitationURL == nil:
            return params.mode == "openai/userVerification"
                ? "This service requires device verification that Wonder does not support. You can decline or cancel it here."
                : "This service requested an unsupported form or link. You can decline or cancel it here."
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            return phoneChoices.isEmpty ? "No supported choices were provided. Refresh the request or stop the current turn." : nil
        default: return isQuestion || !phoneChoices.isEmpty ? nil : "This request type is unavailable. Refresh the request or stop the current turn."
        }
    }

    public func canSubmit(choice: PhoneApprovalChoice, answers: [String: String]) -> Bool {
        guard phoneChoices.contains(choice) else { return false }
        if method == "mcpServer/elicitation/request", choice.decision == "accept", elicitationURL == nil {
            return (try? formContent(answers)) != nil
        }
        return true
    }

    public func responseJSON(for choice: PhoneApprovalChoice, answers: [String: String]) throws -> String? {
        guard phoneChoices.contains(choice) else { throw PhoneApprovalError.invalidChoice }
        switch method {
        case "item/permissions/requestApproval":
            let permissions: TeachingJSONValue
            if choice.id == "decline" { permissions = .object([:]) }
            else if let requested = parsedPermissions { permissions = requested }
            else { throw PhoneApprovalError.invalidChoice }
            return try approvalJSON(.object(["permissions": permissions, "scope": .string(choice.id == "allowSession" ? "session" : "turn")]))
        case "mcpServer/elicitation/request":
            var value: [String: TeachingJSONValue] = ["action": .string(choice.decision)]
            if choice.decision == "accept", elicitationURL == nil { value["content"] = try formContent(answers) }
            return try approvalJSON(.object(value))
        case "item/tool/call":
            return try approvalJSON(.object(["success": .bool(computerAction != nil && choice.id == "accept"), "contentItems": .array([])]))
        default: return nil
        }
    }

    private var parsedForm: [PhoneApprovalField]? {
        guard method == "mcpServer/elicitation/request", ["form", "openai/form", "openaiForm"].contains(params.mode ?? "form"),
              let schema = params.requestedSchema?.approvalDictionary,
              Set(schema.keys).isSubset(of: ["$schema", "type", "properties", "required", "title", "description", "additionalProperties"]),
              schema["type"]?.approvalString == "object", let properties = schema["properties"]?.approvalDictionary,
              properties.count <= 32,
              schema["additionalProperties"] == nil || schema["additionalProperties"] == .bool(false) else { return nil }
        let required: [String]
        if let value = schema["required"], value != .null {
            guard let names = value.approvalStrings, Set(names).isSubset(of: Set(properties.keys)) else { return nil }
            required = names
        } else { required = [] }
        var result: [PhoneApprovalField] = []
        for id in properties.keys.sorted() {
            guard let field = PhoneApprovalField(id: id, value: properties[id]!, required: required.contains(id)) else { return nil }
            result.append(field)
        }
        return result
    }

    private func formContent(_ answers: [String: String]) throws -> TeachingJSONValue {
        guard let fields = parsedForm, Set(answers.keys).isSubset(of: Set(fields.map(\.id))) else { throw PhoneApprovalError.invalidAnswers }
        var content: [String: TeachingJSONValue] = [:]
        for field in fields {
            if let value = try field.answer(answers[field.id]) { content[field.id] = value }
        }
        return .object(content)
    }
}

/// Unknown or incomplete actions remain unsupported; an approval must describe
/// exactly the arguments the Mac will execute.
public struct ComputerAction: Codable, Sendable {
    public let action: String?
    public let x: Double?
    public let y: Double?
    public let text: String?
    public let keyCode: UInt16?
    public let modifiers: UInt64?
    public let bundleId: String?
    private let validFields: Bool
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Key.self) else {
            action = nil; x = nil; y = nil; text = nil; keyCode = nil; modifiers = nil; bundleId = nil; validFields = false
            return
        }
        func value<T: Decodable>(_ name: String, _ type: T.Type) -> T? { try? c.decode(type, forKey: Key(stringValue: name)!) }
        action = value("action", String.self); x = value("x", Double.self); y = value("y", Double.self)
        text = value("text", String.self); keyCode = value("keyCode", UInt16.self)
        modifiers = value("modifiers", UInt64.self); bundleId = value("bundleId", String.self)
        let fields: Set<String>
        switch action {
        case "status", "screenshot": fields = ["action"]
        case "click": fields = ["action", "x", "y"]
        case "type": fields = ["action", "text"]
        case "key": fields = ["action", "keyCode", "modifiers"]
        case "focusApp": fields = ["action", "bundleId"]
        default: fields = []
        }
        validFields = Set(c.allKeys.map(\.stringValue)).isSubset(of: fields)
            && (!c.contains(Key(stringValue: "modifiers")!) || modifiers != nil)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encodeIfPresent(action, forKey: Key(stringValue: "action")!)
        try c.encodeIfPresent(x, forKey: Key(stringValue: "x")!); try c.encodeIfPresent(y, forKey: Key(stringValue: "y")!)
        try c.encodeIfPresent(text, forKey: Key(stringValue: "text")!); try c.encodeIfPresent(keyCode, forKey: Key(stringValue: "keyCode")!)
        try c.encodeIfPresent(modifiers, forKey: Key(stringValue: "modifiers")!); try c.encodeIfPresent(bundleId, forKey: Key(stringValue: "bundleId")!)
        // Preserve unsupported status across caching and restoration.
        if !validFields { try c.encode(true, forKey: Key(stringValue: "unsupported")!) }
    }
    public var detail: String? {
        guard validFields else { return nil }
        switch action {
        case "screenshot": return "Capture your Mac’s screen."
        case "status": return "Read the active app and computer access status."
        case "click": guard let x, let y, x.isFinite, y.isFinite else { return nil }; return "Click at (\(x), \(y)) on your Mac."
        case "type": guard let text, text.utf8.count <= 32768 else { return nil }; return "Type into the focused field on your Mac:\n\(text)"
        case "key":
            guard let keyCode, (modifiers ?? 0) & ~(UInt64(31) << 16) == 0 else { return nil }
            let names = [(16, "Caps Lock"), (17, "Shift"), (18, "Control"), (19, "Option"), (20, "Command")]
                .filter { (modifiers ?? 0) & (UInt64(1) << $0.0) != 0 }.map(\.1)
            return "Press key code \(keyCode)" + (names.isEmpty ? " on your Mac." : " with " + names.joined(separator: ", ") + ".")
        case "focusApp": guard let bundleId, !bundleId.isEmpty, bundleId.utf8.count <= 256 else { return nil }; return "Focus the Mac app \(bundleId)."
        default: return nil
        }
    }
}
private extension PhoneApprovalField {
    init?(id: String, value: TeachingJSONValue, required: Bool) {
        guard let schema = value.approvalDictionary, let type = schema["type"]?.approvalString else { return nil }
        let common: Set<String> = ["type", "title", "description", "default", "writeOnly", "isSecret"]
        let allowed: Set<String>
        switch type {
        case "string": allowed = common.union(["format", "minLength", "maxLength", "enum", "enumNames", "oneOf"])
        case "number", "integer": allowed = common.union(["minimum", "maximum"])
        case "boolean": allowed = common
        case "array": allowed = common.union(["items", "minItems", "maxItems"])
        default: return nil
        }
        guard Set(schema.keys).isSubset(of: allowed) else { return nil }
        for key in ["title", "description", "format"] {
            if let value = schema[key], value != .null, value.approvalString == nil { return nil }
        }
        for key in ["isSecret", "writeOnly"] {
            if let value = schema[key], value != .null, value != .bool(true), value != .bool(false) { return nil }
        }
        for key in ["minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems"] {
            if let value = schema[key], value != .null {
                guard let number = value.approvalNumber, number.isFinite else { return nil }
                if !["minimum", "maximum"].contains(key), number < 0 || number.rounded() != number { return nil }
            }
        }
        if let min = schema["minimum"]?.approvalNumber, let max = schema["maximum"]?.approvalNumber, min > max { return nil }
        if let min = schema["minLength"]?.approvalNumber, let max = schema["maxLength"]?.approvalNumber, min > max { return nil }
        if let min = schema["minItems"]?.approvalNumber, let max = schema["maxItems"]?.approvalNumber, min > max { return nil }
        let kind: Kind
        var options: [String] = []
        var optionTitles: [String: String] = [:]
        if type == "array" || schema["enum"] != nil || schema["oneOf"] != nil {
            let source: [String: TeachingJSONValue]
            if type == "array" {
                guard let items = schema["items"]?.approvalDictionary,
                      Set(items.keys).isSubset(of: ["type", "enum", "anyOf"]),
                      items["type"] == nil || items["type"] == .string("string") else { return nil }
                source = items; kind = .multiChoice
            } else { source = schema; kind = .choice }
            if let values = source["enum"] {
                guard source["oneOf"] == nil, source["anyOf"] == nil, let strings = values.approvalStrings else { return nil }
                options = strings
                if let names = schema["enumNames"], names != .null {
                    guard let titles = names.approvalStrings, titles.count == strings.count else { return nil }
                    for (value, title) in zip(strings, titles) { optionTitles[value] = title }
                }
            } else {
                guard let variants = source[type == "array" ? "anyOf" : "oneOf"]?.approvalArray else { return nil }
                for variant in variants {
                    guard let entry = variant.approvalDictionary, Set(entry.keys) == ["const", "title"],
                          let value = entry["const"]?.approvalString, let title = entry["title"]?.approvalString else { return nil }
                    options.append(value); optionTitles[value] = title
                }
            }
            guard !options.isEmpty, Set(options).count == options.count else { return nil }
        } else {
            switch type {
            case "string":
                if let format = schema["format"]?.approvalString,
                   !["email", "uri", "date", "date-time", "password"].contains(format) { return nil }
                kind = .text
            case "number": kind = .number
            case "integer": kind = .integer
            case "boolean": kind = .boolean
            default: return nil
            }
        }
        self.id = id; self.title = schema["title"]?.approvalString ?? id; self.kind = kind
        self.options = options; self.optionTitles = optionTitles; detail = schema["description"]?.approvalString
        self.required = required; self.schema = schema
        secret = schema["writeOnly"] == .bool(true) || schema["isSecret"] == .bool(true) || schema["format"] == .string("password")
        if let value = schema["default"], value != .null {
            switch value {
            case .string(let text): defaultValue = text
            case .number, .bool, .array: defaultValue = try? approvalJSON(value)
            default: defaultValue = nil
            }
        } else { defaultValue = nil }
        if schema["default"] != nil, schema["default"] != .null {
            guard let defaultValue, (try? answer(defaultValue)) != nil else { return nil }
        }
    }

    func answer(_ input: String?) throws -> TeachingJSONValue? {
        guard let input, !input.isEmpty else {
            if required { throw PhoneApprovalError.invalidAnswers }
            return nil
        }
        guard input.utf8.count <= 32768 else { throw PhoneApprovalError.invalidAnswers }
        func within(_ value: Double, _ lower: String, _ upper: String) -> Bool {
            (schema[lower]?.approvalNumber.map { value >= $0 } ?? true)
                && (schema[upper]?.approvalNumber.map { value <= $0 } ?? true)
        }
        switch kind {
        case .text:
            guard within(Double(input.unicodeScalars.count), "minLength", "maxLength"), validFormat(input) else { throw PhoneApprovalError.invalidAnswers }
            return .string(input)
        case .number, .integer:
            guard let number = Double(input), number.isFinite,
                  kind != .integer || (number.rounded() == number && abs(number) <= 9_007_199_254_740_991),
                  within(number, "minimum", "maximum") else { throw PhoneApprovalError.invalidAnswers }
            return .number(number)
        case .boolean:
            guard ["true", "false"].contains(input) else { throw PhoneApprovalError.invalidAnswers }
            return .bool(input == "true")
        case .choice:
            guard options.contains(input),
                  within(Double(input.unicodeScalars.count), "minLength", "maxLength"),
                  validFormat(input) else { throw PhoneApprovalError.invalidAnswers }
            return .string(input)
        case .multiChoice:
            guard let choices = try? JSONDecoder().decode([String].self, from: Data(input.utf8)),
                  Set(choices).count == choices.count, choices.allSatisfy(options.contains),
                  within(Double(choices.count), "minItems", "maxItems") else { throw PhoneApprovalError.invalidAnswers }
            return .array(choices.map(TeachingJSONValue.string))
        }
    }

    func validFormat(_ input: String) -> Bool {
        switch schema["format"]?.approvalString {
        case "email":
            let parts = input.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && !input.contains(where: \.isWhitespace)
        case "uri": return URL(string: input)?.scheme?.isEmpty == false
        case "date":
            guard input.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            return formatter.date(from: input).map { formatter.string(from: $0) == input } ?? false
        case "date-time":
            let formatter = ISO8601DateFormatter()
            if formatter.date(from: input) != nil { return true }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: input) != nil
        default: return true
        }
    }
}

private func permissionDescriptions(_ value: TeachingJSONValue) -> [String]? {
    guard let profile = value.approvalDictionary, Set(profile.keys).isSubset(of: ["fileSystem", "network"]) else { return nil }
    var result: [String] = []
    if let value = profile["network"], value != .null {
        guard let network = value.approvalDictionary, Set(network.keys).isSubset(of: ["enabled"]) else { return nil }
        if let enabled = network["enabled"], enabled != .null {
            guard enabled == .bool(true) || enabled == .bool(false) else { return nil }
            result.append(enabled == .bool(true) ? "Allow network access." : "Keep network access disabled.")
        }
    }
    if let value = profile["fileSystem"], value != .null {
        guard let files = value.approvalDictionary, Set(files.keys).isSubset(of: ["entries", "read", "write", "globScanMaxDepth"]) else { return nil }
        for (key, label) in [("read", "Read"), ("write", "Read and write")] {
            if let paths = files[key], paths != .null {
                guard let strings = paths.approvalStrings else { return nil }
                result += strings.map { "\(label): \($0)" }
            }
        }
        if let entries = files["entries"], entries != .null {
            guard let entries = entries.approvalArray else { return nil }
            for entry in entries {
                guard let entry = entry.approvalDictionary, Set(entry.keys) == ["access", "path"],
                      let access = entry["access"]?.approvalString, let label = ["read":"Read", "write":"Read and write", "deny":"Deny access"][access],
                      let path = entry["path"], let description = permissionPath(path) else { return nil }
                result.append("\(label): \(description)")
            }
        }
        if let depth = files["globScanMaxDepth"], depth != .null {
            guard let number = depth.approvalNumber, number >= 1, number <= 9_007_199_254_740_991, number.rounded() == number else { return nil }
            result.append("Search matching paths up to \(Int(number)) folders deep.")
        }
    }
    return result.isEmpty ? ["No additional file or network access."] : result
}

private func permissionPath(_ value: TeachingJSONValue) -> String? {
    guard let path = value.approvalDictionary else { return nil }
    switch path["type"]?.approvalString {
    case "path": guard Set(path.keys) == ["type", "path"] else { return nil }; return path["path"]?.approvalString
    case "glob_pattern": guard Set(path.keys) == ["type", "pattern"] else { return nil }; return path["pattern"]?.approvalString.map { "paths matching \($0)" }
    case "special":
        guard Set(path.keys) == ["type", "value"], let special = path["value"]?.approvalDictionary,
              let kind = special["kind"]?.approvalString else { return nil }
        let label: String
        switch kind {
        case "root", "minimal", "tmpdir", "slash_tmp":
            guard Set(special.keys) == ["kind"] else { return nil }
            label = ["root":"all filesystem roots", "minimal":"minimal system paths", "tmpdir":"the temporary folder", "slash_tmp":"/tmp"][kind]!
        case "project_roots":
            guard Set(special.keys).isSubset(of: ["kind", "subpath"]) else { return nil }; label = "project folders"
        case "unknown":
            guard Set(special.keys).isSubset(of: ["kind", "path", "subpath"]), let name = special["path"]?.approvalString else { return nil }; label = name
        default: return nil
        }
        if let subpath = special["subpath"], subpath != .null {
            guard let name = subpath.approvalString else { return nil }; return label + "/" + name
        }
        return label
    default: return nil
    }
}

private extension TeachingJSONValue {
    var approvalDictionary: [String: TeachingJSONValue]? { if case .object(let value) = self { return value }; return nil }
    var approvalArray: [TeachingJSONValue]? { if case .array(let value) = self { return value }; return nil }
    var approvalString: String? { if case .string(let value) = self { return value }; return nil }
    var approvalNumber: Double? { if case .number(let value) = self { return value }; return nil }
    var approvalStrings: [String]? {
        guard let array = approvalArray else { return nil }
        let strings = array.compactMap(\.approvalString); return strings.count == array.count ? strings : nil
    }
    var approvalObject: Any {
        switch self {
        case .object(let value): value.mapValues(\.approvalObject)
        case .array(let value): value.map(\.approvalObject)
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .null: NSNull()
        }
    }
}

/// Rust serde_json stores object keys in UTF-8 lexical order. Foundation's
/// sortedKeys can use numeric or locale collation, so order objects explicitly.
private func approvalJSON(_ value: TeachingJSONValue) throws -> String {
    switch value {
    case .object(let object):
        let keys = object.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return "{" + (try keys.map { try approvalJSON(.string($0)) + ":" + approvalJSON(object[$0]!) }).joined(separator: ",") + "}"
    case .array(let array): return "[" + (try array.map(approvalJSON)).joined(separator: ",") + "]"
    default:
        return String(decoding: try JSONSerialization.data(withJSONObject: value.approvalObject, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }
}

public enum DecisionValue: Codable, Sendable {
    case text(String), structured(TeachingJSONValue), unsupported
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let text = try? c.decode(String.self) { self = .text(text) }
        else if let value = try? c.decode(TeachingJSONValue.self), case .object = value { self = .structured(value) }
        else { self = .unsupported }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s): try c.encode(s)
        case .structured(let value): try c.encode(value)
        case .unsupported: try c.encodeNil()
        }
    }
    public var text: String? { if case .text(let s) = self { return s }; return nil }
}
public struct RequestedFileChange: Codable, Sendable { public let path: String; public let kind: String? }
public struct ChatQuestion: Codable, Identifiable, Sendable {
    public let id: String
    public let header: String?
    public let isSecret: Bool?
    public let isOther: Bool?
    public let question: String
    public let options: [QuestionOption]?
}
public struct QuestionOption: Codable, Sendable { public let label: String; public let description: String? }

/// The HTTP route escapes one path segment. Rust's Axum Path<String> decodes
/// that segment once, then constructs the action target from the original ID.
public struct ApprovalResolutionTarget: Sendable {
    public let requestPath: String
    public let signedTarget: String
    public init(approvalID: String) {
        let escaped = approvalID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        requestPath = "/api/v1/approvals/" + escaped + "/resolve"
        signedTarget = "/api/v1/approvals/" + approvalID + "/resolve"
    }
}

/// The logical decision is persisted before signing. Timestamps/signatures may
/// refresh after session renewal; decision bytes, nonce and identity never change.
public struct DecisionIntent: Codable, Sendable {
    public let decision: String
    public let actionNonce: String
    public let expectedState = "pending"
    public let idempotencyKey: String
    public let responseJson: String?
    public let structuredDecision: TeachingJSONValue?
    public init(request: AttentionRequest, decision: String, responseJson: String?, structuredDecision: TeachingJSONValue? = nil) {
        let computer = request.computerAction != nil && ["accept", "decline"].contains(decision)
        self.decision = computer ? "respond" : decision; actionNonce = request.actionNonce
        idempotencyKey = request.resolutionIdempotencyKey ?? UUID().uuidString
        self.responseJson = computer ? "{\"success\":\(decision == "accept" ? "true" : "false"),\"contentItems\":[]}" : responseJson
        self.structuredDecision = structuredDecision
    }
    public func transcript(path: String, connection: SavedConnection, issuedAtMs: UInt64) throws -> Data {
        let canonical = Data(try approvalJSON(.array([structuredDecision ?? .string(decision), .string(actionNonce), .string(expectedState), .string(idempotencyKey), .string(responseJson ?? "")])).utf8)
        let hash = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        return Data(["wonder-action-v1", "approval.resolve", path, hash, actionNonce,
            connection.credential.csrfToken, connection.credential.deviceId, connection.credential.hostInstallationId,
            String(issuedAtMs), expectedState].joined(separator: "\n").utf8)
    }
    public func payload(issuedAtMs: UInt64, signature: String) throws -> Data {
        var body: [String: Any] = ["decision": (structuredDecision ?? .string(decision)).approvalObject, "actionNonce": actionNonce, "expectedState": expectedState,
            "idempotencyKey": idempotencyKey, "issuedAtMs": issuedAtMs, "signature": signature]
        if let responseJson { body["responseJson"] = responseJson }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

public struct AsyncQuestion: Codable, Identifiable, Sendable {
    public let id: String
    public let conversationId: String
    public let turnId: String
    public let itemId: String
    public let questions: [AsyncQuestionPrompt]
    public let state: String
    public let expiresAtMs: UInt64
    public let response: AsyncAnswerIntent?
    public var rowId: String { turnId + "/" + itemId }
    public func canAnswer(now: UInt64) -> Bool { state == "pending" && now < expiresAtMs }
}
public struct AsyncQuestionPrompt: Codable, Sendable {
    public let title: String
    public let options: [String]?
}
public struct AsyncAnswerIntent: Codable, Sendable {
    public let answers: [String]
    public let skip: Bool
    public init(answers: [String], skip: Bool) { self.answers = answers; self.skip = skip }
    public func validationError(for question: AsyncQuestion) -> AsyncAnswerValidationError? {
        if skip { return answers.isEmpty ? nil : .answerRequired }
        guard answers.count == question.questions.count,
              answers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return .answerRequired }
        guard answers.allSatisfy({ $0.utf8.count <= 8192 }) else { return .answerTooLong }
        // Match the host's title/newline/answer envelope, including separators.
        let bytes = zip(question.questions, answers).reduce(0) { $0 + $1.0.title.utf8.count + 1 + $1.1.utf8.count }
            + max(0, answers.count - 1) * 2
        return bytes > 65536 ? .responseTooLong : nil
    }
}

public enum AsyncAnswerValidationError: LocalizedError, Equatable, Sendable {
    case answerRequired, answerTooLong, responseTooLong
    public var errorDescription: String? {
        switch self {
        case .answerRequired: "Answer every question before replying, or choose Skip."
        case .answerTooLong: "An answer is too long. Shorten it and try again."
        case .responseTooLong: "This reply is too long. Shorten your answers and try again."
        }
    }
}
