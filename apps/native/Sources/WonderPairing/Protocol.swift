import Foundation
import CryptoKit

public extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

public enum PairingFailure: LocalizedError {
    case invalidLink, wrongHost, expired, response(Int), annotationRejected(Int, String), missingIdentity
    public var errorDescription: String? {
        switch self {
        case .invalidLink: "Use the complete HTTPS address or pairing QR code shown on your Mac."
        case .wrongHost: "This connection does not match your Mac. Create a new pairing code on the intended Mac."
        case .expired: "This pairing request expired. Create a new code on your Mac."
        case .response(let code): code == 409 ? "Confirm this phone on your Mac." : code == 410 ? "This request expired or was rejected. Create a new code on your Mac." : code == 401 || code == 404 ? "Access is no longer available. Check this phone in Wonder on your Mac." : "Wonder could not connect (\(code)). Check your Mac and try again."
        case .annotationRejected(_, let detail): detail
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
public struct WorkspaceMediaChunk: Sendable {
    public let bytes: Data
    public let start: UInt64
    public let end: UInt64
    public let total: UInt64
    public let mimeType: String
    /// A file-change token from the opened Mac descriptor, not a content hash.
    public let revision: String
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
        request.setValue(Self.compactView, forHTTPHeaderField: Self.compactViewHeader)
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
    /// Workspace previews stream from the paired Mac; large PDFs and images
    /// take time over Wi-Fi, so callers can show progress.
    public static let workspacePreviewLimit = 256 * 1024 * 1024
    public func downloadWorkspaceBytes(_ path: String, connection: SavedConnection, byteSize: Int?, sha256: String?, mimeType: String?,
                                       progress: (@Sendable (_ received: Int, _ expected: Int?) -> Void)? = nil) async throws -> Data {
        let limit = Self.workspacePreviewLimit
        guard byteSize.map({ $0 >= 0 && $0 <= limit }) != false else { throw FileFailure.tooLarge }
        let origin = try PairingLink.origin(connection.origin)
        guard let url = URL(string: origin + path) else { throw PairingFailure.invalidLink }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("__Host-wonder_session=\(connection.credential.sessionToken)", forHTTPHeaderField: "Cookie")
        // Download to a file and map it: a large PDF or image never needs a
        // second full copy in memory while it arrives.
        let watcher = WorkspaceDownloadProgress(limit: limit, byteSize: byteSize, progress: progress)
        progress?(0, byteSize)
        let session = session
        let (file, response): (URL, URLResponse) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request) { location, response, error in
                    watcher.finish()
                    if let error { continuation.resume(throwing: watcher.exceeded ? FileFailure.tooLarge : error); return }
                    guard let location, let response else { continuation.resume(throwing: URLError(.badServerResponse)); return }
                    // The system removes its file when this handler returns.
                    let kept = FileManager.default.temporaryDirectory
                        .appendingPathComponent("wonder-preview-" + UUID().uuidString)
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: (kept, response))
                    } catch { continuation.resume(throwing: error) }
                }
                watcher.start(task)
            }
        } onCancel: { watcher.cancel() }
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw status == 413 ? FileFailure.tooLarge : PairingFailure.response(status)
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= limit else { throw FileFailure.tooLarge }
        // A mapped file stays readable after its directory entry is removed.
        let data = size == 0 ? Data() : try Data(contentsOf: file, options: .alwaysMapped)
        progress?(data.count, data.count)
        guard byteSize == nil || byteSize == data.count,
              sha256 == nil || sha256 == ConversationFile.digest(data) else { throw FileFailure.integrity }
        if let mimeType { try ConversationFile.validateContent(data, mime: mimeType) }
        return data
    }
    public func downloadWorkspaceMediaRange(_ path: String, connection: SavedConnection,
                                            start: UInt64, end: UInt64, revision: String?) async throws -> WorkspaceMediaChunk {
        guard end >= start, end - start < 1024 * 1024,
              (start == 0 && end == 0) || revision != nil else { throw FileFailure.integrity }
        let origin = try PairingLink.origin(connection.origin)
        guard let url = URL(string: origin + path) else { throw PairingFailure.invalidLink }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("__Host-wonder_session=\(connection.credential.sessionToken)", forHTTPHeaderField: "Cookie")
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        if let revision { request.setValue(revision, forHTTPHeaderField: "X-Wonder-Revision") }
        let (bytes, response) = try await session.bytes(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 409 { throw FileFailure.stale }
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            throw PairingFailure.response((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
              let range = Self.parseMediaContentRange(contentRange), range.start == start,
              range.end <= end, range.end < range.total,
              let contentLength = http.value(forHTTPHeaderField: "Content-Length").flatMap(UInt64.init),
              contentLength == range.end - range.start + 1,
              let mime = http.mimeType?.lowercased(),
              ["video/mp4", "video/quicktime", "audio/mp4", "audio/mpeg", "audio/wav"].contains(mime),
              let responseRevision = http.value(forHTTPHeaderField: "X-Wonder-Revision"),
              responseRevision.count == 64, responseRevision.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else { throw FileFailure.integrity }
        if let revision, revision != responseRevision { throw FileFailure.stale }
        var data = Data()
        data.reserveCapacity(Int(contentLength))
        for try await byte in bytes {
            guard data.count < Int(contentLength) else { throw FileFailure.integrity }
            data.append(byte)
        }
        guard UInt64(data.count) == contentLength else { throw FileFailure.integrity }
        return WorkspaceMediaChunk(bytes: data, start: range.start, end: range.end,
                                   total: range.total, mimeType: mime, revision: responseRevision)
    }

    private static func parseMediaContentRange(_ value: String) -> (start: UInt64, end: UInt64, total: UInt64)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let range = value.dropFirst("bytes ".count)
        let parts = range.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = UInt64(parts[1]) else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = UInt64(bounds[0]), let end = UInt64(bounds[1]), end >= start else { return nil }
        return (start, end, total)
    }
    /// Asks hosts to omit history data native clients never render (the raw
    /// event list and inline computer-use screenshots). Older hosts ignore it.
    static let compactViewHeader = "X-Wonder-History-View"
    static let compactView = "compact"

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
        if path.hasPrefix("/api/v1/conversations/") { request.setValue(Self.compactView, forHTTPHeaderField: Self.compactViewHeader) }
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
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if path.hasPrefix("/api/v1/conversations/"), path.hasSuffix("/messages"),
               [403, 409, 422].contains(status),
               let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               message.utf8.count <= 512,
               (message.hasPrefix("This annotation") || message.hasPrefix("Annotations require") ||
                message.hasPrefix("This file changed since you annotated") ||
                message.hasPrefix("Project folders changed. Reopen the annotation preview") ||
                message.hasPrefix("An annotated Project folder changed. Reopen the preview")) {
                throw PairingFailure.annotationRejected(status, message)
            }
            throw PairingFailure.response(status)
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

}


/// Reports a workspace download's progress and stops one that grows past the limit.
final class WorkspaceDownloadProgress: @unchecked Sendable {
    private let limit: Int
    private let byteSize: Int?
    private let progress: (@Sendable (_ received: Int, _ expected: Int?) -> Void)?
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false
    private var tooLarge = false
    private var lastReported = 0
    var exceeded: Bool { lock.withLock { tooLarge } }

    init(limit: Int, byteSize: Int?, progress: (@Sendable (_ received: Int, _ expected: Int?) -> Void)?) {
        self.limit = limit; self.byteSize = byteSize; self.progress = progress
    }
    func start(_ task: URLSessionDownloadTask) {
        let observation = task.observe(\.countOfBytesReceived, options: [.new]) { [weak self] task, _ in
            self?.received(Int(clamping: task.countOfBytesReceived), Int(clamping: task.countOfBytesExpectedToReceive), task)
        }
        let cancel = lock.withLock { () -> Bool in
            self.task = task; self.observation = observation
            return cancelled
        }
        if cancel { task.cancel() } else { task.resume() }
    }
    func cancel() {
        let task = lock.withLock { () -> URLSessionDownloadTask? in cancelled = true; return self.task }
        task?.cancel()
    }
    func finish() {
        let observation = lock.withLock { () -> NSKeyValueObservation? in
            defer { self.observation = nil }
            return self.observation
        }
        observation?.invalidate()
    }
    private func received(_ received: Int, _ reported: Int, _ task: URLSessionDownloadTask) {
        let expected = reported > 0 ? reported : byteSize
        if received > limit || (expected ?? 0) > limit {
            lock.withLock { tooLarge = true }
            task.cancel()
            return
        }
        // About every 256 KB; the UI coalesces further.
        let report = lock.withLock { () -> Bool in
            guard received - lastReported >= 256 * 1024 || received == expected else { return false }
            lastReported = received
            return true
        }
        if report { progress?(received, expected) }
    }
}
