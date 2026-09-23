import Combine
import AppKit
import Sparkle

/// Sparkle owns preferences and archive/signature verification. Wonder only
/// coordinates admission and shutdown with the host that owns ongoing work.
@MainActor
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var available = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var canCheck = false
    @Published private(set) var message: String?
    private(set) var preparingInstall = false
    private(set) var admissionGranted = false
    private var updater: SPUUpdater?
    private var pendingInstallation: (() -> Void)?
    private var preparationTask: Task<Void, Never>?
    private var attempt = UUID()
    private let prepare: (String) async throws -> Bool
    private let cancelPreparation: (String) async -> Void

    init(prepare: ((String) async throws -> Bool)? = nil, cancel: ((String) async -> Void)? = nil) {
        let admission = UpdateAdmission()
        self.prepare = prepare ?? { try await admission.prepare($0) }
        self.cancelPreparation = cancel ?? { await admission.cancel($0) }
        super.init()
    }

    static func configured(_ info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String, let url = URL(string: feed),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let encoded = info["SUPublicEDKey"] as? String,
              let key = Data(base64Encoded: encoded), key.count == 32,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true else { return false }
        return true
    }

    func start() {
        guard updater == nil, Self.configured(Bundle.main.infoDictionary ?? [:]) else { return }
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let candidate = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do {
            try candidate.start()
            updater = candidate
            available = true
            refresh()
        } catch {
            message = "Updates could not start. Reinstall Wonder from its official download."
        }
    }

    func refresh() {
        guard let updater else { return }
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        canCheck = updater.canCheckForUpdates
    }

    func check() {
        guard let updater, updater.canCheckForUpdates else { return }
        message = nil
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
        refresh()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
        refresh()
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        guard let updater, !enabled || updater.automaticallyChecksForUpdates else { return }
        updater.automaticallyDownloadsUpdates = enabled
        refresh()
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        preparingInstall = true
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallation(installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallation(installHandler)
        return true
    }

    func postponeInstallation(_ installHandler: @escaping () -> Void) {
        preparingInstall = true
        pendingInstallation = installHandler
        message = "Update ready. It will install after current work and messages needing attention are resolved."
        guard preparationTask == nil else { return }
        preparationTask = Task { [weak self] in
            while !Task.isCancelled {
                if await self?.tryInstallation() != false { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    /// Rechecked on termination too: Sparkle can resume a previously staged
    /// update without invoking its postponement delegate again.
    func prepareTermination() async -> Bool {
        let current = attempt
        do {
            let ready = try await prepare(current.uuidString)
            guard current == attempt, !Task.isCancelled else {
                if ready { await cancelPreparation(current.uuidString) }
                return false
            }
            admissionGranted = ready
            if !admissionGranted {
                message = "Update ready. It will install after current work and messages needing attention are resolved."
            }
            return admissionGranted
        } catch {
            message = "Wonder could not confirm that work has finished. The update will retry."
            return false
        }
    }

    private func tryInstallation() async -> Bool {
        let current = attempt
        guard pendingInstallation != nil else { preparationTask = nil; return true }
        let ready = await prepareTermination()
        guard current == attempt, !Task.isCancelled else {
            if ready { await cancelPreparation(current.uuidString) }
            return true
        }
        guard ready else { return false }
        let handler = pendingInstallation
        pendingInstallation = nil
        preparationTask = nil
        message = "Restarting Wonder to install the update…"
        handler?()
        return true
    }

    func installationFailed(_ description: String) {
        let cancelled = attempt.uuidString
        attempt = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        pendingInstallation = nil
        preparingInstall = false
        admissionGranted = false
        message = description
        Task { await cancelPreparation(cancelled) }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Sparkle's ordinary no-new-version result is not an installation error.
        if (error as NSError).domain == SUSparkleErrorDomain,
           (error as NSError).code == Int(SUError.noUpdateError.rawValue) { refresh(); return }
        installationFailed("The update could not finish. Check for updates to try again.")
    }
}

private struct UpdateAdmission {
    private func request(_ action: String, requestID: String) throws -> URLRequest {
        let environment = ProcessInfo.processInfo.environment
        let address = environment["WONDER_LISTEN_ADDR"] ?? "127.0.0.1:3777"
        guard let capability = environment["WONDER_LOOPBACK_CAPABILITY"], !capability.isEmpty,
              let origin = URL(string: "http://" + address), origin.host == "127.0.0.1" else {
            throw URLError(.cannotConnectToHost)
        }
        var request = URLRequest(url: origin.appendingPathComponent("api/v1/host/update/" + action))
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue(capability, forHTTPHeaderField: "x-wonder-loopback-capability")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["requestId": requestID])
        return request
    }
    func prepare(_ requestID: String) async throws -> Bool {
        let (data, response) = try await URLSession.shared.data(for: request("prepare", requestID: requestID))
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 409 { return false }
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Reply: Decodable { let ready: Bool; let requestId: String }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.requestId == requestID else { throw URLError(.badServerResponse) }
        return reply.ready
    }
    func cancel(_ requestID: String) async {
        guard let request = try? request("cancel", requestID: requestID) else { return }
        _ = try? await URLSession.shared.data(for: request)
    }
}
