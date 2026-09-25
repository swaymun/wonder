import Combine
import AppKit
import Foundation
import ServiceManagement
import WonderComputerUseCore

@MainActor
protocol LoginRegistration {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
struct SystemLoginRegistration: LoginRegistration {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

@MainActor
final class ServiceControls: ObservableObject {
    @Published var message: String?
    @Published var busy = false
    @Published var launchAtLogin = false
    @Published var loginMessage: String?
    @Published var loginNeedsApproval = false
    @Published private(set) var allowControlFromPairedDevices = false
    @Published private(set) var controlPreferencesMessage: String?
    private let defaults: UserDefaults
    private var lastLoginStatus: SMAppService.Status?
    private let login: any LoginRegistration
    private let controlPreferences: ControlPreferencesStore?
    init(
        defaults: UserDefaults = .standard,
        login: any LoginRegistration = SystemLoginRegistration(),
        serviceDirectory: URL? = nil
    ) {
        self.defaults = defaults
        self.login = login
        let directory = serviceDirectory
            ?? ProcessInfo.processInfo.environment["WONDER_SERVICE_DIR"].map { URL(fileURLWithPath: $0) }
        controlPreferences = directory.map { ControlPreferencesStore(serviceDirectory: $0) }
        refreshLogin()
        refreshControlPreferences()
    }

    func refreshLogin() {
        let status = login.status
        guard status != lastLoginStatus else { return }
        lastLoginStatus = status
        launchAtLogin = status == .enabled
        loginNeedsApproval = status == .requiresApproval
        if loginNeedsApproval {
            loginMessage = "Launch at login needs your approval in System Settings."
        } else {
            loginMessage = nil
        }
    }

    func applyInitialLoginDefault() {
        guard !defaults.bool(forKey: "login.defaultApplied") else { refreshLogin(); return }
        defaults.set(true, forKey: "login.defaultApplied")
        // Never override an existing registration or a user's macOS denial.
        if login.status == .notRegistered || login.status == .notFound { setLaunchAtLogin(true) }
        else { refreshLogin() }
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    func refreshControlPreferences() {
        guard let controlPreferences else {
            allowControlFromPairedDevices = false
            controlPreferencesMessage = nil
            return
        }
        switch controlPreferences.state {
        case .enabled:
            allowControlFromPairedDevices = true
            controlPreferencesMessage = nil
        case .disabled:
            allowControlFromPairedDevices = false
            controlPreferencesMessage = nil
        case .unavailable:
            allowControlFromPairedDevices = false
            controlPreferencesMessage = "Paired-device control stays off until its saved setting can be verified."
        }
    }

    func setAllowControlFromPairedDevices(_ enabled: Bool) {
        guard let controlPreferences else {
            allowControlFromPairedDevices = false
            controlPreferencesMessage = "Paired-device control is unavailable. Open the installed Wonder app and try again."
            return
        }
        do {
            try controlPreferences.setAllowControlFromPairedDevices(enabled)
            refreshControlPreferences()
        } catch {
            // An atomic rename may have installed the requested value even if
            // the subsequent durability sync reported an error. Re-read the
            // authoritative file instead of showing a safer-looking lie.
            refreshControlPreferences()
            controlPreferencesMessage = "Paired-device control could not be changed. Try again from this Mac."
        }
    }

    @Published var remoteState: MenuReadinessState = .starting
    @Published var remoteDetail = "Checking remote access…"
    @Published var authURL: URL?
    private(set) var remoteOrigin: String?
    private var operation: Process?
    private var lastProbe = Date.distantPast
    private var probeGeneration = UUID()
    private let environment = ProcessInfo.processInfo.environment

    var serviceDirectory: URL? {
        environment["WONDER_SERVICE_DIR"].map { URL(fileURLWithPath: $0) }
    }

    func cancelSetup() { operation?.terminate() }

    func restart() {
        guard let directory = serviceDirectory else {
            message = "Open the installed Wonder app to restart it."
            return
        }
        do {
            try Data().write(to: directory.appendingPathComponent("restart"), options: .atomic)
            message = "Restarting services…"
        } catch {
            message = "Services could not restart. Check that your Mac has free disk space, then try again."
        }
    }

    func repair(signIn: Bool = false) {
        guard !busy, let resources = environment["WONDER_RESOURCES"],
              let directory = serviceDirectory else {
            message = "Open the installed Wonder app to finish setup."
            return
        }
        busy = true
        message = signIn ? "Complete sign-in in your browser. Wonder will reconnect afterward." : "Checking ChatGPT’s installed runtime…"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [resources + "/manage-runtime.sh", signIn ? "login" : "check"]
        process.environment = environment
        let log = directory.appendingPathComponent("repair.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        do {
            let output = try FileHandle(forWritingTo: log)
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { [weak self] finished in
                try? output.close()
                Task { @MainActor in
                    guard let self else { return }
                    self.busy = false
                    self.operation = nil
                    if finished.terminationStatus == 0 {
                        self.restart()
                    } else {
                        self.message = "Setup did not finish. Check your connection and free disk space, then try again. Your saved chats are kept."
                    }
                }
            }
            operation = process
            try process.run()
        } catch {
            busy = false
            operation = nil
            message = "The repair tool could not open. Reinstall Wonder and try again."
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        defaults.set(true, forKey: "login.defaultApplied")
        do {
            if enabled {
                if login.status != .enabled { try login.register() }
            } else { try login.unregister() }
            loginMessage = nil
            refreshLogin()
        } catch {
            refreshLogin()
            if !loginNeedsApproval {
                loginMessage = "The login setting could not be changed. Open Login Settings and try again."
            }
        }
    }

    func configureTailscale() async {
        guard !busy, let helper = Bundle.main.resourceURL?.appendingPathComponent("wonder-tunnel") else { return }
        busy = true; message = nil
        defer { busy = false }
        // Process and pipe I/O stay off MainActor; the helper bounds CLI time.
        let result = await Task.detached(priority: .userInitiated) { () -> String? in
            let process = Process(), output = Pipe()
            process.executableURL = helper
            process.arguments = ["--configure"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last,
                   let status = try? JSONDecoder().decode(TunnelStatus.self, from: Data(line.utf8)) {
                    return status.state == "ready" ? nil : status.error ?? "Tailscale setup was not confirmed."
                }
                return "Tailscale setup was not confirmed. Open Tailscale and retry."
            } catch { return "The connection helper could not run. Reinstall Wonder and retry." }
        }.value
        // The setup view already shows the live remote-address check. Keep this
        // message for failures so the success state is not rendered twice.
        message = result
        refreshRemote()
    }

    func refreshRemote() {
        authURL = nil
        remoteOrigin = nil
        guard let path = environment["WONDER_PUBLIC_ORIGIN_FILE"],
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              let line = text.split(separator: "\n").last,
              let data = String(line).data(using: .utf8),
              let status = try? JSONDecoder().decode(TunnelStatus.self, from: data) else {
            remoteState = .offline
            probeGeneration = UUID()
            lastProbe = .distantPast
            remoteDetail = "Remote access is unavailable. Local chats are kept on this Mac."
            return
        }
        if status.state != "ready" { lastProbe = .distantPast; probeGeneration = UUID() }
        switch status.state {
        case "ready":
            guard let raw = status.origin, let origin = URL(string: raw), origin.scheme == "https",
                  origin.user == nil, origin.password == nil else {
                remoteState = .offline; probeGeneration = UUID(); lastProbe = .distantPast
                return
            }
            remoteOrigin = origin.absoluteString
            guard Date().timeIntervalSince(lastProbe) >= 30 else { return }
            lastProbe = Date()
            probeGeneration = UUID()
            let generation = probeGeneration
            remoteDetail = "Checking the remote connection…"
            var request = URLRequest(url: origin.appendingPathComponent("healthz"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            request.httpMethod = "GET"
            URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                    && data.flatMap { try? JSONDecoder().decode(RemoteHealth.self, from: $0) }?.status == "ok"
                Task { @MainActor in
                    guard let self, self.probeGeneration == generation else { return }
                    self.remoteState = ok ? .ready : .offline
                    self.remoteDetail = ok
                        ? "Remote address responds from this Mac. Keep it awake and online."
                        : "Paired devices can’t reach this Mac remotely."
                }
            }.resume()
        case "auth_required":
            remoteState = .offline
            remoteDetail = status.error ?? "Open Tailscale and connect this Mac to your tailnet."
            if let raw = status.authUrl, let url = URL(string: raw),
               url.scheme == "https", url.host == "login.tailscale.com" { authURL = url }
        case "starting": remoteState = .starting; remoteDetail = "Connecting this Mac for remote access…"
        default: remoteState = .offline; remoteDetail = status.error ?? "Open Tailscale and retry the private connection."
        }
    }
}

private struct TunnelStatus: Decodable {
    let state: String
    let error: String?
    let authUrl: String?
    let origin: String?
}

private struct RemoteHealth: Decodable { let status: String }
