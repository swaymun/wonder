import Foundation
import SwiftUI
import Combine
import CryptoKit
import Security
import WonderPairing

@MainActor final class ConnectionLibrary: ObservableObject {
    @Published private(set) var saved = SavedConnections()
    @Published var error: String?
    @Published private(set) var loaded = false
    @Published private(set) var foregroundOwner: UUID?
    private var activeScenes: Set<UUID> = []
    private let identity = PhoneIdentity()
    private var models: [String: ConnectionModel] = [:]
    private var leases: [String: UUID] = [:]
    private var observations: [String: AnyCancellable] = [:]
    private var widgetPublishTask: Task<Void, Never>?
    private var widgetPublishNeedsRefresh = false
    private(set) var isPreview = false

    #if WONDER_DIAGNOSTICS
    init(diagnosticModel model: ConnectionModel) {
        loaded = true
        isPreview = true
        guard let connection = model.connection else { return }
        saved.save(connection)
        let host = connection.credential.hostInstallationId
        models[host] = model
        observations[host] = model.$listRevision.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
    }
    #endif

    init() {
        #if WONDER_DIAGNOSTICS
        // First launch without touching the Keychain: no saved computers, whatever an earlier run paired.
        if ProcessInfo.processInfo.arguments.contains("-diagnostics-unpaired") {
            loaded = true
            return
        }
        #endif
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
        // The widget follows the Mac last used for a new chat.
        lastHostObservation = NotificationCenter.default.publisher(for: NewChatDraftStore.lastHostChanged)
            .sink { [weak self] _ in self?.scheduleWidgetSnapshot() }
    }
    private var lastHostObservation: AnyCancellable?

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
            publishWidgetSnapshotNow()
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
        // Views reading a model's own state observe it directly. The library
        // re-renders the list and root only for list-visible changes.
        observations[host] = model.$listRevision.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.scheduleWidgetSnapshot()
        }
        model.projects.widgetSnapshotChanged = { [weak self] in self?.scheduleWidgetSnapshot(refresh: true) }
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

    /// Exactly one visible scene runs shared transport/catalog maintenance.
    /// Closing another iPad window cannot suspend the surviving window.
    func setScene(_ scene: UUID, active: Bool) {
        if active { activeScenes.insert(scene) } else { activeScenes.remove(scene) }
        if let foregroundOwner, activeScenes.contains(foregroundOwner) { return }
        foregroundOwner = activeScenes.sorted { $0.uuidString < $1.uuidString }.first
        if foregroundOwner == nil { suspendAll() }
    }

    private func commit(_ next: SavedConnections) throws {
        if !isPreview { try identity.save(JSONEncoder().encode(next), account: "connections-v1") }
        saved = next
        publishWidgetSnapshotNow()
    }

    @discardableResult func publishWidgetSnapshotNow() -> Bool {
        widgetPublishTask?.cancel()
        widgetPublishTask = nil
        let refresh = widgetPublishNeedsRefresh
        widgetPublishNeedsRefresh = false
        return ProjectWidgetSnapshotPublisher.publish(from: self, refreshIfUnchanged: refresh)
    }

    private func scheduleWidgetSnapshot(refresh: Bool = false) {
        widgetPublishNeedsRefresh = widgetPublishNeedsRefresh || refresh
        widgetPublishTask?.cancel()
        widgetPublishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.publishWidgetSnapshotNow()
        }
    }
}
