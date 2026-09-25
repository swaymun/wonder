import Foundation
import SwiftUI
import CryptoKit
import UserNotifications
import WonderPairing

private struct PushConfiguration: Decodable, Sendable {
    let endpoint: String?
    let topic: String
    let environment: String
    let previewVersion: Int?
}
struct PushRegistration: Codable {
    let host: String
    let device: String
    let endpoint: String
    let key: Data
    var enabled = true
    var token = ""
    var pendingToken = ""
    var enrollmentSecret = ""
    var nonce = ""
    var senderSecret = ""
    var id: String?
    var previousIDs: [String] = []
    var registeredAt: Date?
    var lastAttempt: Date?
    var macRegistered = false
    var previewVersion: Int?
    var revocationCompleted: Bool?
    func belongs(to credential: Credential) -> Bool {
        host == credential.hostInstallationId && device == credential.deviceId
    }
}
struct PushDestination: Equatable {
    let host: String
    let conversation: String
    let receipt: String
}
private struct PushReceipt: Codable, Equatable {
    let registrationId: String
    let routeId: String
}
struct PushSettingsAlert: Identifiable {
    let id = UUID()
    let host: String
    let title: String
    let message: String
    var opensSettings = false
}
enum PushSetupState: Equatable {
    case settingUp
    case needsRetry(String)
}

struct PushRetry {
    private(set) var failures = 0
    private(set) var nextAttempt = Date.distantPast
    mutating func postpone(now: Date = Date()) {
        failures = min(failures + 1, 6)
        nextAttempt = now.addingTimeInterval(min(15 * pow(2, Double(failures - 1)), 300))
    }
}
private enum PushFailure: LocalizedError {
    case unavailable, identityMismatch, denied
    var errorDescription: String? {
        switch self {
        case .unavailable: "Notifications could not connect. Check Tailscale and try again."
        case .identityMismatch: "This iOS build needs a push service configured for its Apple app identity and environment."
        case .denied: "Notifications are off in iPhone Settings."
        }
    }
}

/// One application-owned coordinator. Tokens, private keys and sender capabilities
/// are kept in the device Keychain; preview keys are shared only with the paired Mac and notification extension.
@MainActor final class PushNotifications: ObservableObject {
    static let shared = PushNotifications()
    // The switch expresses durable user intent, independently of network setup.
    @Published private var requestedDevices: [String: String] = [:]
    @Published private(set) var settingsAlert: PushSettingsAlert?
    @Published private(set) var setupStates: [String: PushSetupState] = [:]
    @Published private(set) var destination: PushDestination?
    @Published private(set) var routingError: String?
    private var records: [String: PushRegistration] = [:]
    private var token: String?
    private var pendingReceipt: PushReceipt?
    private let write: (Data, String) throws -> Void
    private let authorize: () async throws -> Bool
    private let registerForPush: () -> Void
    private let api = PairingAPI()
    private weak var library: ConnectionLibrary?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var taskIDs: [String: UUID] = [:]
    private var proofTasks: [String: Task<Void, Never>] = [:]
    private var challengeTasks: [String: Task<Void, Never>] = [:]
    private var routingTask: Task<Void, Never>?
    private var foreground = false
    private var presenceTask: Task<Void, Never>?
    private var lastIssued: UInt64 = 0
    private var retries: [String: PushRetry] = [:]

    func setForeground(_ value: Bool) {
        guard foreground != value || presenceTask == nil else { return }
        foreground = value
        if value { retries.removeAll() }
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            // A bounded background task gives the final lease-clear request time
            // to finish. Failure still expires on the Mac after 45 seconds.
            let background = value ? UIBackgroundTaskIdentifier.invalid : UIApplication.shared.beginBackgroundTask(withName: "Wonder notification presence")
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            repeat {
                guard let self, !Task.isCancelled else { return }
                await sendPresenceToPairedMacs(value)
                if !value { return }
                refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            } while !Task.isCancelled
        }
    }
    private func sendPresenceToPairedMacs(_ value: Bool) async {
        guard let library, library.loaded, !library.isPreview else { return }
        let connections = library.saved.connections.filter { saved in
            !saved.requiresPairing && requestedDevices[saved.credential.hostInstallationId] == saved.credential.deviceId
        }
        await withTaskGroup(of: Void.self) { group in
            for saved in connections {
                group.addTask {
                    await self.sendPresence(value, saved: saved)
                }
            }
        }
    }
    private func sendPresence(_ value: Bool, saved: SavedConnection) async {
        guard !Task.isCancelled, foreground == value, records[saved.credential.hostInstallationId]?.belongs(to: saved.credential) == true else { return }
        do {
            let state = value ? "foreground" : "background"
            let body = try await signedBody(action: "push.presence", path: "/api/v1/push/presence", values: [state], fields: ["state": state], saved: saved)
            try Task.checkCancellation()
            guard foreground == value else { return }
            struct Presence: Decodable, Sendable { let updated: Bool }
            let _: Presence = try await api.request("/api/v1/push/presence", origin: saved.origin, body: body, credential: saved.credential)
        } catch { /* Presence is a short lease; foreground presentation is suppressed locally too. */ }
    }

    init(
        read: @escaping (String) throws -> Data? = { try PhoneIdentity().read($0) },
        write: @escaping (Data, String) throws -> Void = { try PhoneIdentity().save($0, account: $1) },
        authorize: @escaping () async throws -> Bool = { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) },
        registerForPush: @escaping () -> Void = { UIApplication.shared.registerForRemoteNotifications() }
    ) {
        self.write = write; self.authorize = authorize; self.registerForPush = registerForPush
        do {
            if let data = try read("push-registrations-v1") { records = try JSONDecoder().decode([String: PushRegistration].self, from: data) }
            if let data = try read("push-requested-devices-v1") {
                requestedDevices = try JSONDecoder().decode([String: String].self, from: data)
            } else {
                requestedDevices = records.filter { $0.value.enabled }.mapValues(\.device)
            }
            if let data = try read("push-receipt-v1"), !data.isEmpty { pendingReceipt = try JSONDecoder().decode(PushReceipt.self, from: data) }
        } catch { routingError = "Unlock your iPhone to open saved notification settings." }
    }
    func isEnabled(_ host: String) -> Bool {
        guard let saved = library?.saved.connections.first(where: { $0.credential.hostInstallationId == host }) else { return false }
        return requestedDevices[host] == saved.credential.deviceId
    }
    func attach(_ library: ConnectionLibrary) {
        self.library = library
        guard !library.isPreview else { return }
        registerForPush()
        setForeground(UIApplication.shared.applicationState != .background)
        refresh()
    }
    func refresh() {
        guard let library, library.loaded, !library.isPreview else { return }
        // A replacement pairing must retire the old delivery capability even
        // when the old Mac credential is no longer in the connection library.
        for (host, record) in records where !library.saved.connections.contains(where: { record.belongs(to: $0.credential) }) {
            if record.enabled { disable(host) }
            else { scheduleDisable(host) }
        }
        for saved in library.saved.connections {
            let host = saved.credential.hostInstallationId
            if requestedDevices[host] == saved.credential.deviceId {
                if isRegistered(host) { setupStates.removeValue(forKey: host) }
                else if setupStates[host] == nil { setupStates[host] = .settingUp }
                if let record = records[host], !record.nonce.isEmpty,
                   let lastAttempt = record.lastAttempt, Date().timeIntervalSince(lastAttempt) >= 45 {
                    challengeTimedOut(host, nonce: record.nonce)
                }
                schedule(host)
            }
            else if records[host]?.enabled == true { disable(host) }
            else { scheduleDisable(host) }
        }
        resolveReceipt()
    }
    func receivedToken(_ data: Data) {
        let value = data.map { String(format: "%02x", $0) }.joined()
        if token != value { token = value; retries.removeAll() }
        for host in requestedDevices.keys where isRegistered(host) { setupStates.removeValue(forKey: host) }
        refresh()
    }
    func registrationFailed() {
        guard token == nil else { return }
        for host in requestedDevices.keys where isEnabled(host) {
            setupStates[host] = .needsRetry("iPhone couldn't register with Apple's notification service. Check your connection and retry.")
        }
    }
    func setupState(_ host: String) -> PushSetupState? { isEnabled(host) ? setupStates[host] : nil }
    func retry(_ host: String) {
        guard isEnabled(host) else { return }
        if isRegistered(host) { setupStates.removeValue(forKey: host); return }
        challengeTasks.removeValue(forKey: host)?.cancel()
        tasks.removeValue(forKey: host)?.cancel()
        taskIDs.removeValue(forKey: host)
        if records[host]?.enabled == true {
            records[host]?.lastAttempt = nil
            records[host]?.nonce = ""
            do { try persist() }
            catch {
                setupStates[host] = .needsRetry("Unlock your iPhone, then retry notification setup.")
                return
            }
        }
        retries.removeValue(forKey: host)
        setupStates[host] = .settingUp
        if token == nil { registerForPush() }
        schedule(host)
    }
    private func isRegistered(_ host: String) -> Bool {
        guard let record = records[host] else { return false }
        return record.enabled && record.macRegistered && record.id != nil && record.token == token
    }
    func enable(_ model: ConnectionModel) {
        guard let saved = model.connection else { return }
        let host = saved.credential.hostInstallationId
        guard setRequested(saved.credential.deviceId, host: host) else { return }
        settingsAlert = nil
        if isRegistered(host) { setupStates.removeValue(forKey: host) }
        else { setupStates[host] = .settingUp }
        retries.removeValue(forKey: host)
        schedule(host)
    }
    private func prepare(_ host: String) async throws {
        guard let device = requestedDevices[host], let model = model(host, device: device), let saved = model.connection else { return }
        guard try await authorize() else { throw PushFailure.denied }
        try Task.checkCancellation()
        guard requestedDevices[host] == device, model.connection?.credential.deviceId == device else { return }
        // Already registered devices need no network work until renewal or rotation.
        if let record = records[host], record.enabled, record.belongs(to: saved.credential) {
            if token == nil { registerForPush() }
            try await enroll(host)
            return
        }
        let config: PushConfiguration = try await model.api.request("/api/v1/push/config", origin: saved.origin, credential: saved.credential)
        let environment = Bundle.main.object(forInfoDictionaryKey: "WonderAPNsEnvironment") as? String ?? "production"
        guard config.topic == Bundle.main.bundleIdentifier, config.environment == environment,
              let endpoint = config.endpoint, let url = URL(string: endpoint), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw PushFailure.identityMismatch }
        try Task.checkCancellation()
        guard requestedDevices[host] == device, model.connection?.credential.deviceId == device else { throw CancellationError() }
        let previous = records[host]
        if records[host]?.device != saved.credential.deviceId || records[host]?.endpoint != endpoint || records[host]?.enabled != true {
            if let previous { try await revokeAtService(previous) }
            try Task.checkCancellation()
            guard requestedDevices[host] == device, model.connection?.credential.deviceId == device else { throw CancellationError() }
            records[host] = PushRegistration(host: host, device: saved.credential.deviceId, endpoint: endpoint, key: P256.Signing.PrivateKey().rawRepresentation)
        }
        do { try persist() } catch { records[host] = previous; throw error }
        registerForPush()
        try await enroll(host)
    }
    private func schedule(_ host: String) {
        guard tasks[host] == nil, isEnabled(host), (retries[host]?.nextAttempt ?? .distantPast) <= Date() else { return }
        if let record = records[host], record.enabled, record.device == requestedDevices[host], record.macRegistered,
           record.previewVersion == 1, record.token == token, let date = record.registeredAt, Date().timeIntervalSince(date) < 30 * 86400 { return }
        let id = UUID(); taskIDs[host] = id
        tasks[host] = Task { [weak self] in
            guard let self else { return }
            do { try await prepare(host) }
            catch { if !Task.isCancelled { setupFailed(error, host: host) } }
            if taskIDs[host] == id {
                tasks.removeValue(forKey: host); taskIDs.removeValue(forKey: host)
                if isEnabled(host) { retries[host, default: PushRetry()].postpone() }
            }
        }
    }
    private func model(_ host: String, device: String) -> ConnectionModel? {
        guard let library, let saved = library.saved.connections.first(where: { $0.credential.hostInstallationId == host && $0.credential.deviceId == device && !$0.requiresPairing }) else { return nil }
        return library.model(for: saved)
    }
    private func enroll(_ host: String) async throws {
        guard !Task.isCancelled, var record = records[host], record.enabled, let token, let model = model(host, device: record.device) else { return }
        if record.token == token, record.id != nil, let date = record.registeredAt, Date().timeIntervalSince(date) < 30 * 86400 {
            if !record.macRegistered || record.previewVersion != 1 { try await registerWithMac(record, model: model) }
            try Task.checkCancellation()
            guard records[host]?.enabled == true else { return }
            return
        }
        // A pending proof may still arrive for ten minutes. Do not consume the
        // service's three-per-hour challenge quota in a foreground retry loop.
        if !record.nonce.isEmpty && record.pendingToken == token { return }
        record.pendingToken = token; record.nonce = try randomSecret(); record.enrollmentSecret = try randomSecret(); record.lastAttempt = Date(); record.macRegistered = false
        records[host] = record; try persist()
        setupStates[host] = .settingUp
        let key = try P256.Signing.PrivateKey(rawRepresentation: record.key)
        let body = try JSONSerialization.data(withJSONObject: ["token": token, "publicKey": key.publicKey.x963Representation.base64URL, "nonce": record.nonce])
        struct Challenge: Decodable, Sendable { let id: String }
        let _: Challenge = try await api.request("/v1/challenges", origin: record.endpoint, body: body, decodingStatuses: [202])
        // The proof arrives via APNs, never in this HTTP response.
        try Task.checkCancellation()
        let nonce = record.nonce
        challengeTasks[host]?.cancel()
        challengeTasks[host] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, !Task.isCancelled else { return }
            self.challengeTimedOut(host, nonce: nonce)
        }
    }
    func challengeTimedOut(_ host: String, nonce: String) {
        guard proofTasks[host] == nil, records[host]?.nonce == nonce,
              records[host]?.macRegistered != true, isEnabled(host) else { return }
        setupStates[host] = .needsRetry("Apple didn't confirm notification setup. Check your connection and retry.")
    }
    func receiveChallenge(id: String, challenge: String, nonce: String) async {
        guard UUID(uuidString: id) != nil, challenge.count == 43,
              let (host, record) = records.first(where: { $0.value.enabled && $0.value.nonce == nonce }),
              let model = model(host, device: record.device) else { return }
        guard proofTasks[host] == nil else { return }
        challengeTasks.removeValue(forKey: host)?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await acceptChallenge(id: id, challenge: challenge, nonce: nonce, host: host, record: record, model: model)
        }
        proofTasks[host] = task
        await task.value
        proofTasks.removeValue(forKey: host)
    }
    private func acceptChallenge(id: String, challenge: String, nonce: String, host: String, record: PushRegistration, model: ConnectionModel) async {
        do {
            try Task.checkCancellation()
            let key = try P256.Signing.PrivateKey(rawRepresentation: record.key)
            let signature = try key.signature(for: Data("register|\(id)|\(challenge)|\(record.enrollmentSecret)".utf8)).rawRepresentation.base64URL
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "challenge": challenge, "senderSecret": record.enrollmentSecret, "signature": signature])
            struct Accepted: Decodable, Sendable { let id: String }
            let accepted: Accepted = try await api.request("/v1/registrations", origin: record.endpoint, body: data)
            try Task.checkCancellation()
            guard accepted.id == id, records[host]?.nonce == nonce, records[host]?.enabled == true else { throw CancellationError() }
            var updated = record
            if record.previousIDs.count >= 16, let oldest = record.previousIDs.last { try PushPreviewKeys.remove(oldest) }
            if let old = record.id, old != id { updated.previousIDs = Array(([old] + record.previousIDs).prefix(16)) }
            updated.id = id; updated.token = record.pendingToken; updated.senderSecret = record.enrollmentSecret; updated.registeredAt = Date(); updated.macRegistered = false
            updated.nonce = ""
            records[host] = updated; try persist()
            try await registerWithMac(updated, model: model)
            challengeTasks.removeValue(forKey: host)?.cancel()
            retries.removeValue(forKey: host)
        } catch {
            if !Task.isCancelled {
                setupFailed(error, host: host)
                if isEnabled(host) { retries[host, default: PushRetry()].postpone() }
            }
        }
    }
    private func registerWithMac(_ record: PushRegistration, model: ConnectionModel) async throws {
        try Task.checkCancellation()
        guard let id = record.id, records[record.host]?.enabled == true, let saved = model.connection, record.belongs(to: saved.credential) else { throw CancellationError() }
        let config: PushConfiguration = try await model.api.request("/api/v1/push/config", origin: saved.origin, credential: saved.credential)
        var values = [id, record.senderSecret], fields = ["id": id, "senderSecret": record.senderSecret]
        if config.previewVersion == 1 {
            let key = try PushPreviewKeys.getOrCreate(id).base64URL
            values.append(key); fields["previewKey"] = key
        }
        // Establish foreground presence before enabling delivery on this Mac.
        await sendPresence(foreground, saved: saved)
        try Task.checkCancellation()
        guard records[record.host]?.id == id, records[record.host]?.enabled == true else { throw CancellationError() }
        let body = try await signedBody(action: "push.register", path: "/api/v1/push/registration", values: values, fields: fields, saved: saved)
        struct Registered: Decodable, Sendable { let registered: Bool }
        let result: Registered = try await model.api.request("/api/v1/push/registration", origin: saved.origin, body: body, credential: saved.credential)
        guard result.registered, records[record.host]?.id == id, records[record.host]?.enabled == true else { throw CancellationError() }
        records[record.host]?.macRegistered = true; records[record.host]?.previewVersion = config.previewVersion; try persist()
        setupStates.removeValue(forKey: record.host)
    }
    func disable(_ model: ConnectionModel) {
        guard let host = model.connection?.credential.hostInstallationId else { return }
        guard setRequested(nil, host: host) else { return }
        settingsAlert = nil
        setupStates.removeValue(forKey: host)
        disable(host)
    }
    func dismissSettingsAlert() { settingsAlert = nil }
    @discardableResult private func setRequested(_ device: String?, host: String) -> Bool {
        let previous = requestedDevices
        requestedDevices[host] = device
        do {
            try write(JSONEncoder().encode(requestedDevices), "push-requested-devices-v1")
            return true
        } catch {
            requestedDevices = previous
            settingsAlert = PushSettingsAlert(host: host, title: "Couldn't change notifications", message: "Unlock your iPhone and try again.")
            return false
        }
    }
    private func setupFailed(_ error: Error, host: String) {
        guard isEnabled(host) else { return }
        let message: String
        var opensSettings = false
        switch error {
        case PushFailure.denied:
            message = "Allow notifications for Wonder in iPhone Settings."
            opensSettings = true
        case PushFailure.identityMismatch:
            message = "This build needs a matching notification service. Check the push configuration on your Mac."
        case PairingFailure.wrongHost, PairingFailure.missingIdentity, PairingFailure.expired:
            message = "Pair this iPhone with your Mac again, then turn on notifications."
        case is SigningIdentityFailure:
            message = "Unlock your iPhone and try again."
        default:
            // Preserve intent for automatic retries, but make a stalled setup visible.
            setupStates[host] = .needsRetry("Couldn't finish notification setup. Check your connection and retry.")
            return
        }
        guard setRequested(nil, host: host) else { return }
        disable(host)
        settingsAlert = PushSettingsAlert(host: host, title: "Couldn't turn on notifications", message: message, opensSettings: opensSettings)
    }
    private func disable(_ host: String) {
        setupStates.removeValue(forKey: host)
        challengeTasks.removeValue(forKey: host)?.cancel()
        retries.removeValue(forKey: host)
        if records[host] != nil {
            records[host]?.enabled = false
            records[host]?.nonce = ""
            // The saved preference already authorizes revocation after a restart.
            do { try persist() } catch { /* Retry cleanup while the desired state stays off. */ }
        }
        if let record = records[host] {
            for id in ([record.id].compactMap { $0 } + record.previousIDs) { try? PushPreviewKeys.remove(id) }
        }
        let enrollment = tasks[host], proof = proofTasks[host]
        enrollment?.cancel(); proof?.cancel()
        tasks.removeValue(forKey: host)
        scheduleDisable(host, after: enrollment, proof: proof)
    }
    private func revokeAtService(_ record: PushRegistration) async throws {
        guard let id = record.id else { return }
        struct Revoked: Decodable, Sendable { let revoked: Bool }
        do {
            let _: Revoked = try await api.request("/v1/registrations/\(id)/revoke", origin: record.endpoint, body: Data("{}".utf8), bearerToken: record.senderSecret)
        } catch PairingFailure.response(410) { /* Already revoked or expired. */ }
    }
    private func scheduleDisable(_ host: String, after enrollment: Task<Void, Never>? = nil, proof: Task<Void, Never>? = nil) {
        guard tasks[host] == nil, let pending = records[host], pending.revocationCompleted != true else { return }
        guard (retries[host]?.nextAttempt ?? .distantPast) <= Date() else { return }
        let id = UUID(); taskIDs[host] = id
        tasks[host] = Task { [weak self] in
            guard let self else { return }
            defer {
                if taskIDs[host] == id {
                    tasks.removeValue(forKey: host); taskIDs.removeValue(forKey: host)
                    if isEnabled(host) { schedule(host) }
                }
            }
            await enrollment?.value; await proof?.value
            guard let record = records[host], !record.enabled else { return }
            do {
                var failure: Error?
                do { try await revokeAtService(record) } catch { failure = error }
                if let model = model(host, device: record.device), let saved = model.connection {
                    do {
                        let body = try await signedBody(action: "push.revoke", path: "/api/v1/push/revoke", values: [], fields: [:], saved: saved)
                        struct Revoked: Decodable, Sendable { let revoked: Bool }
                        let _: Revoked = try await model.api.request("/api/v1/push/revoke", origin: saved.origin, body: body, credential: saved.credential)
                    } catch { failure = error }
                }
                if let failure { throw failure }
                records[host]?.revocationCompleted = true
                try persist()
                retries.removeValue(forKey: host)
            } catch { retries[host, default: PushRetry()].postpone() }
        }
    }
    func receiveTap(registration: String, route: String) {
        guard UUID(uuidString: registration) != nil, UUID(uuidString: route) != nil else { return }
        pendingReceipt = PushReceipt(registrationId: registration, routeId: route)
        do { try persistReceipt() } catch { routingError = error.localizedDescription }
        resolveReceipt()
    }
    func retryOpening() { resolveReceipt() }
    var canRetryOpening: Bool { pendingReceipt != nil }
    func dismissRoutingError() {
        routingTask?.cancel()
        let previous = pendingReceipt
        pendingReceipt = nil
        do { try persistReceipt(); routingError = nil }
        catch { pendingReceipt = previous; routingError = "Unlock your iPhone to dismiss this notification, then try again." }
    }
    private func unavailableReceipt(_ receipt: PushReceipt, message: String) {
        guard pendingReceipt == receipt else { return }
        pendingReceipt = nil
        do { try persistReceipt(); routingError = message }
        catch { pendingReceipt = receipt; routingError = "Unlock your iPhone to update this notification, then try again." }
    }
    private func resolveReceipt() {
        guard routingTask == nil, let receipt = pendingReceipt, let library, !library.isPreview else { return }
        guard let (host, record) = records.first(where: { $0.value.id == receipt.registrationId || $0.value.previousIDs.contains(receipt.registrationId) }),
              let model = model(host, device: record.device) else {
            unavailableReceipt(receipt, message: "This notification belongs to a Mac that is no longer paired.")
            return
        }
        routingTask = Task { [weak self] in
            guard let self else { return }; defer { routingTask = nil }
            await model.check(renew: true)
            guard let saved = model.connection, saved.credential.deviceId == record.device else { return }
            do {
                struct Route: Decodable, Sendable { let conversationId: String }
                let route: Route = try await model.api.request("/api/v1/push/routes/\(receipt.routeId)", origin: saved.origin, credential: saved.credential)
                await model.loadChats(force: true)
                guard pendingReceipt == receipt, model.connection?.credential.deviceId == record.device else { throw CancellationError() }
                guard model.chats.contains(where: { $0.id == route.conversationId }) else { throw PushFailure.unavailable }
                destination = PushDestination(host: host, conversation: route.conversationId, receipt: receipt.routeId)
                pendingReceipt = nil; try persistReceipt(); routingError = nil
            } catch {
                guard !Task.isCancelled, pendingReceipt == receipt else { return }
                if case PairingFailure.response(let code) = error, code == 404 || code == 410 {
                    unavailableReceipt(receipt, message: "This notification is no longer available.")
                } else {
                    routingError = "Connect to your Mac over Tailscale to open this notification, then try again."
                }
            }
        }
    }
    private func signedBody(action: String, path: String, values: [String], fields: [String: String], saved: SavedConnection) async throws -> Data {
        let issued = max(UInt64(Date().timeIntervalSince1970 * 1000), lastIssued + 1), nonce = UUID().uuidString
        lastIssued = issued
        let canonical = try JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes])
        let hash = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        let transcript = ["wonder-action-v1", action, path, hash, nonce, saved.credential.csrfToken, saved.credential.deviceId, saved.credential.hostInstallationId, String(issued), "active"].joined(separator: "\n")
        var body: [String: Any] = fields
        body["actionNonce"] = nonce; body["issuedAtMs"] = issued; body["signature"] = try await PhoneIdentity.signing.sign(Data(transcript.utf8))
        return try JSONSerialization.data(withJSONObject: body)
    }
    private func randomSecret() throws -> String {
        var bytes = Data(count: 32)
        let result = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard result == errSecSuccess else { throw SigningIdentityFailure.keychain(result) }
        return bytes.base64URL
    }
    private func persist() throws { try write(JSONEncoder().encode(records), "push-registrations-v1") }
    private func persistReceipt() throws { try write(try pendingReceipt.map { try JSONEncoder().encode($0) } ?? Data(), "push-receipt-v1") }
}

final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushNotifications.shared.receivedToken(deviceToken) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushNotifications.shared.registrationFailed() }
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let value = userInfo["wonderPush"] as? [String: String], let id = value["challengeId"], let challenge = value["challenge"], let nonce = value["nonce"] else { completionHandler(.noData); return }
        Task { @MainActor in
            await PushNotifications.shared.receiveChallenge(id: id, challenge: challenge, nonce: nonce)
            completionHandler(.newData)
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let value = response.notification.request.content.userInfo["wonderPush"] as? [String: String], let registration = value["registrationId"], let route = value["routeId"] else { return }
        await MainActor.run { PushNotifications.shared.receiveTap(registration: registration, route: route) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [] }
}
