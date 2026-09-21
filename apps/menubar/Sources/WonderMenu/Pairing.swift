import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import CryptoKit

struct PhoneOffer: Decodable {
    let offerId: String
    let url: String
    let humanCode: String
    let expiresAtMs: UInt64
    var origin: String { url.components(separatedBy: "/pair#").first ?? "" }
}
struct EnrollmentChallenge: Decodable, Equatable {
    let deviceId: String
    let challengeId: String
    let nonce: String
    let origin: String
    let hostInstallationId: String
    let issuedAtMs: UInt64
    let expiresAtMs: UInt64
    var verification: String {
        let bytes = Data(["wonder-session-v1", deviceId, challengeId, nonce, origin, hostInstallationId, String(issuedAtMs), String(expiresAtMs)].joined(separator: "\n").utf8)
        return String(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(12)).uppercased()
    }
}
struct PhoneEnrollment: Decodable, Identifiable, Equatable {
    let deviceId: String
    let label: String
    let challenge: EnrollmentChallenge
    var id: String { deviceId }
    func isValid(at date: Date) -> Bool {
        date.timeIntervalSince1970 * 1000 < Double(challenge.expiresAtMs)
    }
}
struct PairedPhone: Decodable, Identifiable, Equatable {
    let id: String
    let label: String
    let createdAt: String?
    let revokedAt: String?
    let lastSeenAt: String?
}

@MainActor final class PhonePairing: ObservableObject {
    @Published var offer: PhoneOffer?
    @Published var pending: [PhoneEnrollment] = []
    @Published var devices: [PairedPhone] = []
    @Published var busy = false
    @Published var error: String?
    @Published var refreshError: String?
    @Published var message: String?
    @Published var now = Date()
    private var refreshing = false
    private var polling: Task<Void, Never>?
    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    func stop() { polling?.cancel(); polling = nil }
    private let origin: URL
    private let capability: String
    private let session: URLSession
    init(session: URLSession = .shared) {
        self.session = session
        let address = ProcessInfo.processInfo.environment["WONDER_LISTEN_ADDR"] ?? "127.0.0.1:3777"
        let candidate = URL(string: "http://" + address)
        origin = candidate?.host == "127.0.0.1" ? candidate! : URL(string: "http://127.0.0.1:3777")!
        capability = ProcessInfo.processInfo.environment["WONDER_LOOPBACK_CAPABILITY"] ?? UUID().uuidString
    }
    var expired: Bool { offer.map { UInt64(now.timeIntervalSince1970 * 1000) >= $0.expiresAtMs } ?? false }
    private func request(_ path: String, post: Bool = false) async throws -> Data {
        var request = URLRequest(url: origin.appendingPathComponent("api/v1/" + path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue(capability, forHTTPHeaderField: "x-wonder-loopback-capability")
        if post {
            request.httpMethod = "POST"; request.httpBody = Data("null".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "WonderPairing", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: [NSLocalizedDescriptionKey: "Wonder could not complete this request. Check your Mac’s connection and try again."])
        }
        return data
    }
    func refresh() async {
        now = Date()
        pending.removeAll { !$0.isValid(at: now) }
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do {
            let nextPending = try JSONDecoder().decode([PhoneEnrollment].self, from: await request("pairing/pending")).filter { $0.isValid(at: Date()) }
            let nextDevices = try JSONDecoder().decode([PairedPhone].self, from: await request("devices")).sorted {
                if ($0.revokedAt == nil) != ($1.revokedAt == nil) { return $0.revokedAt == nil }
                if $0.lastSeenAt != $1.lastSeenAt { return ($0.lastSeenAt ?? "") > ($1.lastSeenAt ?? "") }
                return $0.id < $1.id
            }
            if pending != nextPending { pending = nextPending }
            if devices != nextDevices { devices = nextDevices }
            if refreshError != nil { refreshError = nil }
        } catch { self.refreshError = error.localizedDescription }
    }
    func create() async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            if let offer, !expired { _ = try await request("pairing/offers/\(offer.offerId)/cancel", post: true) }
            offer = nil; now = Date()
            offer = try JSONDecoder().decode(PhoneOffer.self, from: await request("pairing/offers", post: true))
            message = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func decide(_ phone: PhoneEnrollment, approve: Bool) async {
        guard !busy else { return }
        guard phone.isValid(at: Date()) else {
            pending.removeAll { $0.id == phone.id }
            error = "Connection request expired. Create a new pairing code."
            return
        }
        busy = true; error = nil; defer { busy = false }
        do {
            _ = try await request("pairing/pending/\(phone.id)/\(approve ? "confirm" : "reject")", post: true)
            offer = nil
            message = approve ? "Phone approved. It can now finish connecting." : "Connection rejected. Create a new code to try again."
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func forget(_ phone: PairedPhone) async {
        guard !busy, phone.revokedAt != nil else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            _ = try await request("devices/\(phone.id)/forget", post: true)
            message = nil
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func revoke(_ phone: PairedPhone) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            _ = try await request("devices/\(phone.id)/revoke", post: true)
            message = "Access revoked for \(phone.label)."; await refresh()
        } catch { self.error = error.localizedDescription }
    }
}
