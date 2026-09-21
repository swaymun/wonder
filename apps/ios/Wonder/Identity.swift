import Foundation
import SwiftUI
import Combine
import CryptoKit
import Security
import WonderPairing

struct PhoneIdentity: Sendable {
    private let service = "com.saimun.wonder.native"
    func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SigningIdentityFailure.keychain(status) }
        return data
    }
    func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw SigningIdentityFailure.keychain(status) }
        } else if update != errSecSuccess { throw SigningIdentityFailure.keychain(update) }
    }
    func forgetConnection() throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "connection"] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PairingFailure.missingIdentity }
    }
    static let signing: SigningIdentity = {
        let storage = PhoneIdentity()
        #if targetEnvironment(simulator)
        // Only simulator builds use a software key.
        let account = "simulator-key"
        @Sendable func wrap(_ key: P256.Signing.PrivateKey) -> EnrollmentSigningIdentity {
            EnrollmentSigningIdentity(publicKey: key.publicKey, representation: key.rawRepresentation, sign: { try key.signature(for: $0) })
        }
        return SigningIdentity(read: { try storage.read(account) }, save: { try storage.save($0, account: account) },
                               restore: { try wrap(P256.Signing.PrivateKey(rawRepresentation: $0)) }, create: { wrap(P256.Signing.PrivateKey()) })
        #else
        let account = "enclave-key"
        @Sendable func wrap(_ key: SecureEnclave.P256.Signing.PrivateKey) -> EnrollmentSigningIdentity {
            EnrollmentSigningIdentity(publicKey: key.publicKey, representation: key.dataRepresentation, sign: { try key.signature(for: $0) })
        }
        return SigningIdentity(read: { try storage.read(account) }, save: { try storage.save($0, account: account) }, restore: {
            try wrap(SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: $0))
        }, create: {
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage], nil) else {
                throw SigningIdentityFailure.keychain(errSecParam)
            }
            return try wrap(SecureEnclave.P256.Signing.PrivateKey(accessControl: access))
        })
        #endif
    }()
}

@MainActor final class ConnectionLibrary: ObservableObject {
    @Published private(set) var saved = SavedConnections()
    @Published var error: String?
    @Published private(set) var loaded = false
    private let identity = PhoneIdentity()
    private var models: [String: ConnectionModel] = [:]
    private var leases: [String: UUID] = [:]
    private var observations: [String: AnyCancellable] = [:]
    private(set) var isPreview = false

    #if WONDER_DIAGNOSTICS
    init(diagnosticModel model: ConnectionModel) {
        loaded = true
        isPreview = true
        guard let connection = model.connection else { return }
        saved.save(connection)
        let host = connection.credential.hostInstallationId
        models[host] = model
        observations[host] = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    #endif

    init() {
        #if DEBUG || WONDER_DIAGNOSTICS
        if ProcessInfo.processInfo.arguments.contains("-read-preview") && !ProcessInfo.processInfo.arguments.contains("-connections-preview") {
            loaded = true
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-connections-preview") {
            isPreview = true
            loaded = true
            for (host, name) in [("studio", "Studio"), ("macbook", "Laptop"), ("mini", "Home")] {
                let value: [String: Any] = ["origin": "https://\(host).invalid", "hostName": name,
                    "credential": ["sessionToken": "synthetic", "csrfToken": "synthetic", "deviceId": "preview-device", "hostInstallationId": host]]
                if let data = try? JSONSerialization.data(withJSONObject: value), let connection = try? JSONDecoder().decode(SavedConnection.self, from: data) {
                    saved.save(connection)
                }
            }
            return
        }
        #endif
        load()
    }

    func load() {
        guard !loaded else { return }
        do {
            if let data = try identity.read("connections-v1") {
                saved = try JSONDecoder().decode(SavedConnections.self, from: data)
            } else {
                let legacy = try identity.read("connection").map { try JSONDecoder().decode(SavedConnection.self, from: $0) }
                let migrated = SavedConnections(legacy: legacy)
                try identity.save(JSONEncoder().encode(migrated), account: "connections-v1")
                saved = migrated
            }
            // The collection is authoritative before deleting the legacy value.
            try? identity.forgetConnection()
            loaded = true
            error = nil
        } catch { self.error = "Saved connections could not be opened. Try again when your device is unlocked." }
    }

    func model(for connection: SavedConnection) -> ConnectionModel {
        let host = connection.credential.hostInstallationId
        if let existing = models[host] { return existing }
        let device = connection.credential.deviceId
        let lease = UUID()
        leases[host] = lease
        let model = ConnectionModel(saved: connection) { [weak self] updated in
            guard let self, self.leases[host] == lease, self.saved.connections.contains(where: {
                $0.credential.hostInstallationId == host && $0.credential.deviceId == device
            }) else { throw PairingFailure.wrongHost }
            var next = self.saved
            if let updated {
                guard updated.credential.hostInstallationId == host, updated.credential.deviceId == device else { throw PairingFailure.wrongHost }
                guard !self.saved.connections.contains(where: { $0.credential.hostInstallationId == host && $0.requiresPairing && !updated.requiresPairing }) else {
                    throw SigningIdentityFailure.invalidated
                }
                next.save(updated)
            } else { next.remove(host) }
            try self.commit(next)
            if updated == nil { self.models.removeValue(forKey: host); self.leases.removeValue(forKey: host); self.observations.removeValue(forKey: host) }
        }
        model.identityNeedsRepair = { [weak self] in
            guard let self else { throw CancellationError() }
            try self.requirePairing()
        }
        if isPreview { model.connection = connection; model.macConnected = true; model.status = "Connected to your computer." }
        models[host] = model
        observations[host] = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return model
    }

    func pairingModel() -> ConnectionModel {
        let model = ConnectionModel { [weak self] connection in
            guard let self, let connection, self.loaded else { throw PairingFailure.missingIdentity }
            var next = self.saved
            let host = connection.credential.hostInstallationId
            next.save(connection)
            try self.commit(next)
            self.models[host]?.retireAfterPairingReplacement()
            self.models.removeValue(forKey: host)
            self.leases.removeValue(forKey: host)
            self.observations.removeValue(forKey: host)
        }
        model.identityNeedsRepair = { [weak self] in
            guard let self, self.loaded else { throw SigningIdentityFailure.missing }
            try self.requirePairing()
        }
        model.previousPairingConnection = { [weak self] host in
            self?.saved.connections.first { $0.credential.hostInstallationId == host }
        }
        return model
    }

    private func requirePairing() throws {
        var next = saved
        next.requirePairing()
        // Immediately fence callbacks, even if durable storage is unavailable.
        for model in models.values { model.stopForIdentityRecovery() }
        try commit(next)
    }

    func filter(_ host: String?) {
        do {
            var next = saved
            if let host { try next.select(host) } else { next.showAll() }
            try commit(next)
        } catch { self.error = "Your chat filter could not be saved. Try again." }
    }

    func suspendAll() { for model in models.values { model.setForeground(false) } }

    private func commit(_ next: SavedConnections) throws {
        if !isPreview { try identity.save(JSONEncoder().encode(next), account: "connections-v1") }
        saved = next
    }
}
