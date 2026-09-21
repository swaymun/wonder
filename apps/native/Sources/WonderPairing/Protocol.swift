import Foundation
import CryptoKit

public extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

public enum PairingFailure: LocalizedError {
    case invalidLink, wrongHost, expired, response(Int), missingIdentity
    public var errorDescription: String? {
        switch self {
        case .invalidLink: "Use the complete HTTPS address or pairing QR code shown on your Mac."
        case .wrongHost: "This connection does not match your Mac. Create a new pairing code on the intended Mac."
        case .expired: "This pairing request expired. Create a new code on your Mac."
        case .response(let code): code == 409 ? "Confirm this phone on your Mac." : code == 410 ? "This request expired or was rejected. Create a new code on your Mac." : code == 401 || code == 404 ? "Access is no longer available. Check this phone in Wonder on your Mac." : "Wonder could not connect (\(code)). Check your Mac and try again."
        case .missingIdentity: "This phone’s saved identity is unavailable. Pair again from your Mac."
        }
    }
}

public struct PairingLink: Sendable {
    public let origin: String
    public let offerID: String
    public let secret: String
    public let hostID: String
    public static func origin(_ input: String) throws -> String {
        guard let url = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil,
              url.fragment == nil, url.path.isEmpty || url.path == "/" else { throw PairingFailure.invalidLink }
        return "https://" + host + (url.port.map { ":\($0)" } ?? "")
    }
    public init(_ input: String) throws {
        guard var url = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.path == "/pair", url.query == nil, let fragment = url.fragment,
              let fields = URLComponents(string: "?" + fragment)?.queryItems,
              fields.count == 3, Set(fields.map(\.name)).count == 3,
              let secret = fields.first(where: { $0.name == "secret" })?.value, !secret.isEmpty,
              let offer = fields.first(where: { $0.name == "offerId" })?.value, UUID(uuidString: offer) != nil,
              let host = fields.first(where: { $0.name == "hostInstallationId" })?.value, !host.isEmpty else { throw PairingFailure.invalidLink }
        url.path = ""; url.fragment = nil
        origin = try Self.origin(url.string ?? "")
        offerID = offer; self.secret = secret; hostID = host
    }
}

public struct PublicKey: Codable, Sendable {
    public let kty: String
    public let crv: String
    public let x: String
    public let y: String
    public init(_ key: P256.Signing.PublicKey) {
        let bytes = key.x963Representation
        kty = "EC"; crv = "P-256"; x = bytes[1..<33].base64URL; y = bytes[33..<65].base64URL
    }
}

public struct Challenge: Codable, Sendable {
    public let challengeId: String
    public let deviceId: String
    public let nonce: String
    public let origin: String
    public let hostInstallationId: String
    public let offerId: String
    public let issuedAtMs: UInt64
    public let expiresAtMs: UInt64
    public var transcript: Data {
        Data(["wonder-session-v1", deviceId, challengeId, nonce, origin, hostInstallationId, String(issuedAtMs), String(expiresAtMs)].joined(separator: "\n").utf8)
    }
    public var verificationCode: String { String(SHA256.hash(data: transcript).map { String(format: "%02x", $0) }.joined().prefix(12)).uppercased() }
    public func validate(origin: String, hostID: String?, deviceID: String?, now: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) throws {
        guard self.origin == origin, hostID == nil || hostInstallationId == hostID, deviceID == nil || deviceId == deviceID,
              !hostInstallationId.isEmpty, !deviceId.isEmpty, issuedAtMs < expiresAtMs else { throw PairingFailure.wrongHost }
        guard now < expiresAtMs, issuedAtMs <= now + 30_000 else { throw PairingFailure.expired }
    }
}
public struct Claim: Codable, Sendable { public let deviceId: String; public let challenge: Challenge }
public struct Credential: Codable, Sendable {
    public let sessionToken: String
    public let deviceId: String
    public let csrfToken: String
    public let hostInstallationId: String
    public let expiresAtMs: UInt64?
}
public struct SavedConnection: Codable, Sendable {
    public let origin: String
    public let credential: Credential
    public let hostName: String?
    public var requiresPairing: Bool
    public let storageDeviceId: String
    public init(origin: String, credential: Credential, hostName: String? = nil, requiresPairing: Bool = false, storageDeviceId: String? = nil) {
        self.origin = origin; self.credential = credential; self.hostName = hostName
        self.requiresPairing = requiresPairing
        self.storageDeviceId = storageDeviceId ?? credential.deviceId
    }
    private enum CodingKeys: String, CodingKey { case origin, credential, hostName, requiresPairing, storageDeviceId }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        origin = try values.decode(String.self, forKey: .origin)
        credential = try values.decode(Credential.self, forKey: .credential)
        hostName = try values.decodeIfPresent(String.self, forKey: .hostName)
        requiresPairing = try values.decodeIfPresent(Bool.self, forKey: .requiresPairing) ?? false
        storageDeviceId = try values.decodeIfPresent(String.self, forKey: .storageDeviceId) ?? credential.deviceId
    }
    public func preservingStorage(from previous: SavedConnection?) -> SavedConnection {
        guard let previous, previous.credential.hostInstallationId == credential.hostInstallationId else { return self }
        return SavedConnection(origin: origin, credential: credential, hostName: hostName ?? previous.hostName,
                               requiresPairing: requiresPairing, storageDeviceId: previous.storageDeviceId)
    }
}

// Pairing secrets and credentials must never follow a redirect to another host.
private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
public final class PairingAPI: Sendable {
    private let session: URLSession
    private let timing: (@Sendable (Double, Double, Int, Bool) -> Void)?
    public convenience init(timing: (@Sendable (Double, Double, Int, Bool) -> Void)? = nil) { self.init(configuration: .ephemeral, timing: timing) }
    public init(configuration: URLSessionConfiguration, timing: (@Sendable (Double, Double, Int, Bool) -> Void)? = nil) {
        self.timing = timing
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func eventSocket(connection: SavedConnection) throws -> URLSessionWebSocketTask {
        let origin = try PairingLink.origin(connection.origin)
        guard var components = URLComponents(string: origin) else { throw PairingFailure.invalidLink }
        components.scheme = "wss"
        components.path = "/api/v1/events"
        guard let url = components.url else { throw PairingFailure.invalidLink }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("__Host-wonder_session=\(connection.credential.sessionToken)", forHTTPHeaderField: "Cookie")
        return session.webSocketTask(with: request)
    }
    public func download(_ path: String, connection: SavedConnection, file: ConversationFile) async throws -> Data {
        guard file.byteSize.map({ $0 >= 0 && $0 <= 8 * 1024 * 1024 }) == true else { throw FileFailure.tooLarge }
        let origin = try PairingLink.origin(connection.origin)
        guard let url = URL(string: origin + path) else { throw PairingFailure.invalidLink }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("__Host-wonder_session=\(connection.credential.sessionToken)", forHTTPHeaderField: "Cookie")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw PairingFailure.response((response as? HTTPURLResponse)?.statusCode ?? 0) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8 * 1024 * 1024 else { throw FileFailure.tooLarge }
            data.append(byte)
        }
        try file.verify(data, mime: http.mimeType)
        return data
    }
    public func downloadWorkspaceBytes(_ path: String, connection: SavedConnection, byteSize: Int?, sha256: String?, mimeType: String?) async throws -> Data {
        guard byteSize.map({ $0 >= 0 && $0 <= 8 * 1024 * 1024 }) != false else { throw FileFailure.tooLarge }
        let origin = try PairingLink.origin(connection.origin)
        guard let url = URL(string: origin + path) else { throw PairingFailure.invalidLink }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("__Host-wonder_session=\(connection.credential.sessionToken)", forHTTPHeaderField: "Cookie")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw PairingFailure.response((response as? HTTPURLResponse)?.statusCode ?? 0) }
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > 8 * 1024 * 1024 { throw FileFailure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8 * 1024 * 1024 else { throw FileFailure.tooLarge }
            data.append(byte)
        }
        guard byteSize == nil || byteSize == data.count,
              sha256 == nil || sha256 == ConversationFile.digest(data) else { throw FileFailure.integrity }
        if let mimeType { try ConversationFile.validateContent(data, mime: mimeType) }
        return data
    }
    public static func timeoutInterval(for path: String) -> TimeInterval {
        if path == "/api/v1/group-chats/propose" { return 330 }
        if path.hasSuffix("/control/acquire") { return 135 }
        return 15
    }

    public func request<T: Decodable & Sendable>(_ path: String, origin: String, body: Data? = nil,
                                                  credential: Credential? = nil, method: String? = nil,
                                                  decodingStatuses: Set<Int> = [], bearerToken: String? = nil) async throws -> T {
        guard let url = URL(string: try PairingLink.origin(origin) + path) else { throw PairingFailure.invalidLink }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.timeoutInterval(for: path)
        )
        request.httpMethod = method ?? (body == nil ? "GET" : "POST")
        request.httpBody = body
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        if let credential {
            request.setValue("__Host-wonder_session=\(credential.sessionToken)", forHTTPHeaderField: "Cookie")
            request.setValue(credential.csrfToken, forHTTPHeaderField: "x-wonder-csrf")
        }
        if let bearerToken, credential == nil { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        let start = timing == nil ? 0 : ProcessInfo.processInfo.systemUptime
        var received = start; var byteCount = 0; var succeeded = false
        defer { if let timing { timing((received-start)*1000, (ProcessInfo.processInfo.systemUptime-received)*1000, byteCount, succeeded) } }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { received = ProcessInfo.processInfo.systemUptime; throw error }
        received = timing == nil ? 0 : ProcessInfo.processInfo.systemUptime; byteCount = data.count
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) || decodingStatuses.contains(http.statusCode) else {
            throw PairingFailure.response((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let value: T
        do {
            value = try JSONDecoder().decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
        } catch where !(200..<300).contains(http.statusCode) {
            throw PairingFailure.response(http.statusCode)
        }
        succeeded = true
        return value
    }
    /// The same ephemeral, redirect-rejecting transport carries device-scoped ASR jobs.
    public func asrRequest<T: Decodable & Sendable>(_ path: String, connection: SavedConnection, method: String = "GET", recording: Data? = nil, intent: DictationIntent? = nil) async throws -> T {
        guard path.hasPrefix("/api/v1/asr/"), let url = URL(string: try PairingLink.origin(connection.origin) + path) else { throw PairingFailure.invalidLink }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method; request.httpBody = recording; request.httpShouldHandleCookies = false
        request.setValue(connection.origin, forHTTPHeaderField: "Origin")
        request.setValue("__Host-wonder_session=\(connection.credential.sessionToken)", forHTTPHeaderField: "Cookie")
        request.setValue(connection.credential.csrfToken, forHTTPHeaderField: "x-wonder-csrf")
        if let recording, let intent {
            guard recording.count <= 16 * 1024 * 1024, intent.deviceID == connection.credential.deviceId,
                intent.hostID == connection.credential.hostInstallationId else { throw PairingFailure.wrongHost }
            request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
            request.setValue(intent.requestID, forHTTPHeaderField: "X-Wonder-Request-ID")
            request.setValue(String(intent.durationMs), forHTTPHeaderField: "X-Wonder-Duration-Ms")
            request.setValue(intent.modelID, forHTTPHeaderField: "X-Wonder-Model-ID")
            request.setValue(intent.language, forHTTPHeaderField: "X-Wonder-Language")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PairingFailure.response(0) }
        guard (200..<300).contains(http.statusCode) else {
            if let failure = try? JSONDecoder().decode(DictationFailure.self, from: data) { throw failure }
            throw PairingFailure.response(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }

}
