import Foundation

public struct ControlLeaseIdentity: Equatable, Sendable {
    public let leaseID: String
    public let requestID: String
    public let sessionID: String
    public let generation: UInt64
    public let geometryRevision: UInt64
    public let sourceID: String?

    public init(
        leaseID: String,
        requestID: String,
        sessionID: String,
        generation: UInt64,
        geometryRevision: UInt64,
        sourceID: String?
    ) {
        self.leaseID = leaseID
        self.requestID = requestID
        self.sessionID = sessionID
        self.generation = generation
        self.geometryRevision = geometryRevision
        self.sourceID = sourceID
    }
}

public enum ControlConsentDecision: String, Equatable, Sendable {
    case allowOnce
    case deny
}

public enum ControlConsentResult: Equatable, Sendable {
    case allowOnce(replayed: Bool)
    case denied(replayed: Bool)
    case identityConflict
}

public enum ControlActivationResult: Equatable, Sendable {
    case activated(replayed: Bool)
    case consentRequired
    case denied
    case busy
    case identityConflict
}

public enum ControlDeliveryResult: Equatable, Sendable {
    case delivered
    case duplicate
    case rejected(String)
}

/// The helper-side lease boundary is deliberately independent of AppKit. The
/// executable injects the local authorization policy and native delivery
/// closure; tests can exercise both without starting the helper UI.
public final class ControlLeaseGate: @unchecked Sendable {
    public typealias ConsentProvider = (ControlLeaseIdentity) -> ControlConsentDecision
    public typealias EnabledProvider = () -> Bool

    private struct ConsentRecord {
        let identity: ControlLeaseIdentity
        let decision: ControlConsentDecision
    }

    private struct ActiveLease {
        let identity: ControlLeaseIdentity
        var expiresAt: Date
        var lastSequence: UInt64
        var payloads: [UInt64: Data]
    }

    private let lock = NSLock()
    private let consentProvider: ConsentProvider
    private let enabledProvider: EnabledProvider
    private var consents: [String: ConsentRecord] = [:]
    private var active: ActiveLease?
    private let maximumRememberedPayloads = 64

    public init(
        consentProvider: @escaping ConsentProvider,
        enabledProvider: @escaping EnabledProvider = { true }
    ) {
        self.consentProvider = consentProvider
        self.enabledProvider = enabledProvider
    }

    public func requestConsent(_ identity: ControlLeaseIdentity) -> ControlConsentResult {
        guard enabledProvider() else {
            lock.lock()
            active = nil
            lock.unlock()
            return .denied(replayed: false)
        }
        lock.lock()
        if let record = consents[identity.requestID] {
            lock.unlock()
            guard record.identity == identity else { return .identityConflict }
            return record.decision == .allowOnce ? .allowOnce(replayed: true) : .denied(replayed: true)
        }
        lock.unlock()

        let decision = consentProvider(identity)
        lock.lock()
        defer { lock.unlock() }
        guard enabledProvider() else {
            active = nil
            return .denied(replayed: false)
        }
        // A request can only be recorded once. This also keeps a late replay
        // from replacing a decision made by an earlier request.
        if let record = consents[identity.requestID] {
            guard record.identity == identity else { return .identityConflict }
            return record.decision == .allowOnce ? .allowOnce(replayed: true) : .denied(replayed: true)
        }
        consents[identity.requestID] = ConsentRecord(identity: identity, decision: decision)
        return decision == .allowOnce ? .allowOnce(replayed: false) : .denied(replayed: false)
    }

    public func activate(_ identity: ControlLeaseIdentity, now: Date, lifetime: TimeInterval) -> ControlActivationResult {
        lock.lock()
        defer { lock.unlock() }
        guard enabledProvider() else {
            active = nil
            return .denied
        }
        if let active {
            if active.expiresAt <= now {
                self.active = nil
            } else if active.identity == identity {
                return .activated(replayed: true)
            } else {
                return .busy
            }
        }
        guard let consent = consents[identity.requestID] else { return .consentRequired }
        guard consent.identity == identity else { return .identityConflict }
        guard consent.decision == .allowOnce else { return .denied }
        active = ActiveLease(
            identity: identity,
            expiresAt: now.addingTimeInterval(lifetime),
            lastSequence: 0,
            payloads: [:]
        )
        return .activated(replayed: false)
    }

    public func heartbeat(_ identity: ControlLeaseIdentity, now: Date, lifetime: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard enabledProvider() else {
            active = nil
            return false
        }
        guard var active, active.identity == identity, active.expiresAt > now else {
            self.active = nil
            return false
        }
        active.expiresAt = now.addingTimeInterval(lifetime)
        self.active = active
        return true
    }

    public func deliver(
        _ identity: ControlLeaseIdentity,
        sequence: UInt64,
        payload: Data,
        now: Date = Date(),
        nativeDelivery: () -> Bool
    ) -> ControlDeliveryResult {
        lock.lock()
        defer { lock.unlock() }
        guard enabledProvider() else {
            active = nil
            return .rejected("control_disabled")
        }
        guard let active, active.identity == identity else {
            return .rejected("lease_not_active")
        }
        guard active.expiresAt > now else {
            self.active = nil
            return .rejected("lease_expired")
        }
        if let previous = active.payloads[sequence] {
            return previous == payload ? .duplicate : .rejected("sequence_payload_conflict")
        }
        let nextSequence = active.lastSequence == UInt64.max ? UInt64.max : active.lastSequence + 1
        guard sequence == nextSequence else {
            return .rejected("input_sequence_must_increase_by_one")
        }
        guard nativeDelivery() else { return .rejected("input_delivery_failed") }
        guard var current = self.active, current.identity == identity else {
            return .rejected("lease_not_active")
        }
        current.lastSequence = sequence
        current.payloads[sequence] = payload
        if current.payloads.count > maximumRememberedPayloads,
           let oldest = current.payloads.keys.min() {
            current.payloads.removeValue(forKey: oldest)
        }
        self.active = current
        return .delivered
    }

    @discardableResult
    public func release(_ identity: ControlLeaseIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active?.identity == identity else { return false }
        active = nil
        return true
    }

    @discardableResult
    public func releaseAll() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let hadActive = active != nil
        active = nil
        return hadActive
    }

    @discardableResult
    public func expire(now: Date = Date()) -> Bool {
        expireAndReturnIdentity(now: now) != nil
    }

    /// Expires the active lease and returns its exact identity so the
    /// executable can revoke the matching durable lease without guessing.
    public func expireAndReturnIdentity(now: Date = Date()) -> ControlLeaseIdentity? {
        lock.lock()
        defer { lock.unlock() }
        guard let active, active.expiresAt <= now else { return nil }
        self.active = nil
        return active.identity
    }

    public func activeIdentity() -> ControlLeaseIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return active?.identity
    }
}

public struct ControlPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum ControlInputTranslator {
    public static func validText(_ text: String, maximum: Int, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !text.isEmpty) && text.unicodeScalars.count <= maximum
            && text.unicodeScalars.allSatisfy { $0.properties.generalCategory != .control || $0 == "\n" || $0 == "\t" }
    }

    /// CGEvent accepts at most 64 UTF-16 units per text event. Keep surrogate
    /// pairs together so an emoji at an event boundary remains valid text.
    public static func unicodeEventChunks(_ text: String) -> [[UInt16]] {
        let units = Array(text.utf16)
        var chunks: [[UInt16]] = []
        var start = 0
        while start < units.count {
            var end = min(start + 64, units.count)
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
            chunks.append(Array(units[start..<end]))
            start = end
        }
        return chunks
    }

    public static let shiftModifier: UInt32 = 1 << 0
    public static let controlModifier: UInt32 = 1 << 1
    public static let optionModifier: UInt32 = 1 << 2
    public static let commandModifier: UInt32 = 1 << 3
    public static let capsLockModifier: UInt32 = 1 << 4
    public static let allowedModifierMask: UInt32 = 0b1_1111

    public static func point(x: Double, y: Double, in source: CaptureSourceDescriptor) -> ControlPoint? {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        let bounds = source.contentRect.width > 0 && source.contentRect.height > 0
            ? source.contentRect
            : CaptureRect(
                x: source.contentRect.x,
                y: source.contentRect.y,
                width: Double(source.width) / max(source.scale, 0.01),
                height: Double(source.height) / max(source.scale, 0.01)
            )
        return ControlPoint(x: bounds.x + x * bounds.width, y: bounds.y + y * bounds.height)
    }

    public static func keyCode(for key: String) -> UInt16? {
        let normalized = key.lowercased()
        if normalized.count == 1, let scalar = normalized.unicodeScalars.first {
            let letters: [Unicode.Scalar: UInt16] = [
                "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
                "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
                "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
                "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
                "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
                "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
                "n": 45, "m": 46, ".": 47, "`": 50,
            ]
            return letters[scalar]
        }
        return [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
            "backspace": 51, "escape": 53, "esc": 53, "command": 55, "shift": 56,
            "capslock": 57, "option": 58, "control": 59, "rightcommand": 54,
            "rightshift": 60, "rightoption": 61, "rightcontrol": 62, "left": 123,
            "right": 124, "down": 125, "up": 126, "home": 115, "end": 119,
            "pageup": 116, "pagedown": 121, "forwarddelete": 117,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        ][normalized]
    }
}

public enum ControlInputAction: Codable, Equatable, Sendable {
    case pointer(x: Double, y: Double, phase: String, button: String?)
    case scroll(deltaX: Double, deltaY: Double)
    case key(key: String, phase: String, modifiers: UInt32)
    case text(String)
    case clipboard(operation: String, text: String?)
    case releaseAll

    private enum CodingKeys: String, CodingKey { case type, x, y, phase, button, deltaX, deltaY, key, modifiers, text, operation }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "pointer":
            self = .pointer(
                x: try container.decode(Double.self, forKey: .x),
                y: try container.decode(Double.self, forKey: .y),
                phase: try container.decode(String.self, forKey: .phase),
                button: try container.decodeIfPresent(String.self, forKey: .button)
            )
        case "scroll":
            self = .scroll(deltaX: try container.decode(Double.self, forKey: .deltaX), deltaY: try container.decode(Double.self, forKey: .deltaY))
        case "key":
            self = .key(key: try container.decode(String.self, forKey: .key), phase: try container.decode(String.self, forKey: .phase), modifiers: try container.decode(UInt32.self, forKey: .modifiers))
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "clipboard":
            self = .clipboard(operation: try container.decode(String.self, forKey: .operation), text: try container.decodeIfPresent(String.self, forKey: .text))
        case "releaseAll":
            self = .releaseAll
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unsupported control action")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pointer(x, y, phase, button):
            try container.encode("pointer", forKey: .type); try container.encode(x, forKey: .x); try container.encode(y, forKey: .y); try container.encode(phase, forKey: .phase); try container.encodeIfPresent(button, forKey: .button)
        case let .scroll(deltaX, deltaY):
            try container.encode("scroll", forKey: .type); try container.encode(deltaX, forKey: .deltaX); try container.encode(deltaY, forKey: .deltaY)
        case let .key(key, phase, modifiers):
            try container.encode("key", forKey: .type); try container.encode(key, forKey: .key); try container.encode(phase, forKey: .phase); try container.encode(modifiers, forKey: .modifiers)
        case let .text(text):
            try container.encode("text", forKey: .type); try container.encode(text, forKey: .text)
        case let .clipboard(operation, text):
            try container.encode("clipboard", forKey: .type); try container.encode(operation, forKey: .operation); try container.encodeIfPresent(text, forKey: .text)
        case .releaseAll:
            try container.encode("releaseAll", forKey: .type)
        }
    }
}
