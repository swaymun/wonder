import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import WonderComputerUseCore

private struct SharedDisplayChoice {
    let identifier: String
    let name: String
    let isMain: Bool

    var snapshot: [String: Any] {
        ["id": identifier, "name": name, "main": isMain]
    }
}

// This process owns only macOS integrations. All Wonder windows are rendered by GPUI.
struct BridgeCommand: Decodable, Sendable {
    let id: String
    let action: String
    var enabled: Bool?
    var key: String?
    var paths: [String]?
    var setup: Bool?
    var verification: String?
    var step: Int?
}

@MainActor
final class NativeBridge: NSObject, NSApplicationDelegate {
    let model = MenuModel()
    let service: ServiceControls
    let updates = AppUpdates()
    let setup: SetupProgress
    private let sharedDisplay: SharedDisplayPreference

    init(defaults: UserDefaults = .standard, serviceDirectory: URL? = nil) {
        service = ServiceControls(defaults: defaults, serviceDirectory: serviceDirectory)
        setup = SetupProgress(defaults: defaults)
        sharedDisplay = SharedDisplayPreference(defaults: defaults)
        super.init()
    }
    let permissions = PermissionModel()
    let pairing = PhonePairing()
    let files = FileAccessModel()
    let computerFolders = ComputerFolders()
    private var importedFolders = false
    private var lastState = Data()
    private var timer: Timer?
    private var commandBusy = false
    private var acknowledged = ""
    private var commandError: String?
    private var qrURL: String?
    private var qrBytes: [UInt8] = []
    private var updateTerminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LaunchServices registration of a second executable in this bundle can
        // remove GPUI's status item. Restore it once registration has settled.
        DispatchQueue.main.async {
            if let directory = self.service.serviceDirectory {
                do { try Data().write(to: directory.appendingPathComponent("refresh-menu"), options: .atomic) }
                catch { self.commandError = "The menu bar could not refresh. Reopen Wonder." }
            }
        }
        if !setup.completed && setup.step == .finish { service.applyInitialLoginDefault() }
        if setup.completed { updates.start() }
        pairing.start()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
        Task { @MainActor in
            while !Task.isCancelled {
                refresh()
                await files.load()
                if !importedFolders, let paths = try? await files.existingFolderPaths() {
                    computerFolders.importExisting(paths)
                    importedFolders = true
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // readLine() holds stdin's C FILE lock while it waits. Foundation's
            // XML parser also uses that lock when Sparkle reads an appcast.
            // Read the pipe directly so an idle bridge cannot stall updates.
            var pending = Data()
            var discardingOversizeLine = false
            while true {
                let chunk = FileHandle.standardInput.availableData
                if chunk.isEmpty { break }
                for byte in chunk {
                    if byte == 0x0A {
                        if !discardingOversizeLine,
                           let command = try? JSONDecoder().decode(BridgeCommand.self, from: pending) {
                            Task { @MainActor in await self?.perform(command) }
                        }
                        pending.removeAll(keepingCapacity: true)
                        discardingOversizeLine = false
                    } else if !discardingOversizeLine {
                        if pending.count < 65535 {
                            pending.append(byte)
                        } else {
                            pending.removeAll(keepingCapacity: true)
                            discardingOversizeLine = true
                        }
                    }
                }
            }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private func refresh() {
        model.refresh(); service.refreshLogin(); service.refreshControlPreferences(); service.refreshRemote(); permissions.refresh()
    }

    func perform(_ command: BridgeCommand) async {
        guard !commandBusy else { return }
        commandBusy = true; commandError = nil
        defer { commandBusy = false; acknowledged = command.id; publish() }
        switch command.action {
        case "tailscale-open":
            if !NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app")) {
                NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
            }
        case "tailscale-configure": await service.configureTailscale()
        case "download-update": NSWorkspace.shared.open(URL(string: "https://github.com/swaymun/wonder/releases")!)
        case "refresh": refresh(); await pairing.refresh()
        case "restart": service.restart()
        case "repair": service.repair()
        case "sign-in": service.repair(signIn: true)
        case "login":
            guard let enabled = command.enabled else { return }
            service.setLaunchAtLogin(enabled)
        case "login-settings": service.openLoginSettings()
        case "allow-control-from-paired-devices":
            guard let enabled = command.enabled else { return }
            service.setAllowControlFromPairedDevices(enabled)
        case "shared-display":
            guard let identifier = command.key else { return }
            guard identifier.isEmpty || sharedDisplayChoices().contains(where: { $0.identifier == identifier }) else {
                commandError = "That display is no longer connected. Choose another screen."
                return
            }
            if !sharedDisplay.setPreferredIdentifier(identifier.isEmpty ? nil : identifier) {
                commandError = "The screen choice could not be saved. Try again."
            }
        case "automatic-updates":
            guard let enabled = command.enabled, updates.available else { return }
            updates.setAutomaticChecks(enabled)
        case "automatic-update-downloads":
            guard let enabled = command.enabled, updates.available else { return }
            updates.setAutomaticDownloads(enabled)
        case "check-updates":
            // A foreground Sparkle check may keep its caller in a modal run loop.
            // Acknowledge the bridge command before opening that UI.
            Task { @MainActor [updates] in updates.check() }
        case "connect-mac":
            if let url = service.authURL, !NSWorkspace.shared.open(url) { commandError = "The sign-in page could not open." }
        case "screen": permissions.request(.screenRecording, setup: command.setup == true)
        case "input": permissions.request(.accessibility, setup: command.setup == true)
        case "setup-step":
            guard let raw = command.step, let next = SetupStep(rawValue: raw),
                  next.canEnter(executionReady: model.executionReady) else { return }
            setup.go(to: next)
            if next == .finish { service.applyInitialLoginDefault() }
        case "setup-review":
            setup.review()
        case "setup-finish":
            guard setup.step == .finish, model.executionReady else { return }
            PrivacySettings.dismiss()
            setup.finish()
            updates.start()
        case "pair": await pairing.create()
        case "approve", "reject":
            guard pairing.refreshError == nil,
                  let phone = pairing.pending.first(where: { $0.id == command.key }),
                  phone.challenge.verification == command.verification else {
                commandError = "The connection request changed. Refresh and match the code again."; return
            }
            await pairing.decide(phone, approve: command.action == "approve")
        case "forget-device":
            guard let phone = pairing.devices.first(where: { $0.id == command.key && $0.revokedAt != nil }) else { return }
            await pairing.forget(phone)
        case "revoke":
            guard let phone = pairing.devices.first(where: { $0.id == command.key && $0.revokedAt == nil }) else { return }
            await pairing.revoke(phone)
        case "computer-folder-add":
            computerFolders.message = nil
            for path in command.paths ?? [] {
                do { try computerFolders.remember(URL(fileURLWithPath: path, isDirectory: true)) }
                catch { computerFolders.message = error.localizedDescription }
            }
        case "computer-folder-remove":
            if let path = command.key { computerFolders.remove(path) }
        case "computer-folder-settings": computerFolders.openPrivacy(fullDisk: false)
        case "computer-full-disk": computerFolders.openPrivacy(fullDisk: true, setup: command.setup == true)
        case "review-folder", "decline-folder":
            guard let item = files.requests.first(where: { $0.id == command.key }) else { return }
            if command.action == "review-folder" { NSApp.activate(ignoringOtherApps: true); files.review(item) }
            else { await files.decide(item, accepted: false) }
        default: commandError = "This settings action is unavailable. Reopen Wonder."
        }
    }

    func snapshot() -> [String: Any] {
        updates.refresh()
        if qrURL != pairing.offer?.url {
            qrURL = pairing.offer?.url; qrBytes = []
            if let url = qrURL {
                let filter = CIFilter.qrCodeGenerator(); filter.message = Data(url.utf8)
                if let output = filter.outputImage,
                   let cg = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 6, y: 6)), from: output.extent.applying(CGAffineTransform(scaleX: 6, y: 6))),
                   let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) { qrBytes = Array(data) }
            }
        }
        var value: [String: Any] = [
            "acknowledged": acknowledged, "error": commandError ?? "", "busy": commandBusy,
            "hostName": Host.current().localizedName ?? "Mac",
            "serviceRunning": model.serviceRunning, "remoteReady": service.remoteState == .ready,
            "remoteChecking": service.remoteState == .starting, "remoteOrigin": service.remoteOrigin ?? "",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
            "status": model.status, "detail": model.statusDetail, "ready": model.executionReady,
            "needsRepair": model.needsRepair, "remoteStatus": service.remoteState.presentation.title,
            "remoteDetail": service.remoteDetail, "canConnect": service.authURL != nil,
            "serviceBusy": service.busy, "serviceMessage": service.message ?? "",
            "login": service.launchAtLogin, "loginMessage": service.loginMessage ?? "", "loginApproval": service.loginNeedsApproval,
            "allowControlFromPairedDevices": service.allowControlFromPairedDevices,
            "controlPreferencesMessage": service.controlPreferencesMessage ?? "",
            "sharedDisplays": sharedDisplayChoices().map(\.snapshot),
            "preferredDisplayID": sharedDisplay.preferredIdentifier ?? "",
            "updatesAvailable": updates.available, "automaticUpdates": updates.automaticallyChecks,
            "automaticUpdateDownloads": updates.automaticallyDownloads,
            "canCheckUpdates": updates.canCheck, "updatesMessage": updates.message ?? "",
            "updateVersion": updates.latestAvailableVersion ?? "",
            "screen": permissions.screen.label, "input": permissions.input.label,
            "permissionsBusy": permissions.busy, "permissionsMessage": permissions.message ?? "",
            "setupCompleted": setup.completed, "setupStep": setup.step.rawValue,
            "pairingBusy": pairing.busy, "pairingError": pairing.error ?? pairing.refreshError ?? "",
            "pairingFresh": pairing.refreshError == nil, "pairingMessage": pairing.message ?? "",
            "pending": pairing.pending.filter { $0.isValid(at: Date()) }.map { ["id": $0.id, "label": $0.label, "verification": $0.challenge.verification, "expiresAtMs": $0.challenge.expiresAtMs] as [String: Any] },
            "devices": pairing.devices.map { ["id": $0.id, "label": $0.label, "revoked": $0.revokedAt != nil, "lastSeen": $0.lastSeenAt ?? "", "pairedAt": $0.createdAt ?? ""] as [String: Any] },
            "permissionDrag": PrivacySettings.dragRequest,
            "computerFolders": computerFolders.rows, "computerFoldersMessage": computerFolders.message ?? "",
            "filesBusy": files.busy, "filesMessage": files.message ?? "",
            "fileRequests": files.requests.map { ["id": $0.id, "path": $0.path, "access": $0.access, "project": $0.useAsWorkingDirectory, "botName": files.snapshot?.botName ?? "Bot"] as [String: Any] }
        ]
        if let offer = pairing.offer {
            value["offer"] = ["id": offer.offerId, "url": offer.url, "origin": offer.origin, "code": offer.humanCode.uppercased(), "expired": pairing.expired, "expiresAtMs": offer.expiresAtMs, "qr": qrBytes] as [String: Any]
        }
        return value
    }

    private func sharedDisplayChoices() -> [SharedDisplayChoice] {
        let mainID = CGMainDisplayID()
        let choices = NSScreen.screens.compactMap { screen -> SharedDisplayChoice? in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let identifier = SharedDisplayPreference.identifier(for: displayID) else { return nil }
            return SharedDisplayChoice(
                identifier: identifier,
                name: String(screen.localizedName.prefix(80)),
                isMain: displayID == mainID
            )
        }
        let counts = Dictionary(grouping: choices, by: \.identifier)
        return choices.filter { counts[$0.identifier]?.count == 1 }
            .sorted { $0.isMain == $1.isMain ? $0.name < $1.name : $0.isMain }
    }

    private func publish() {
        guard timer != nil else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot(), options: [.sortedKeys]), data != lastState else { return }
        lastState = data
        do { try FileHandle.standardOutput.write(contentsOf: data + Data([10])) }
        catch { NSApp.terminate(nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard updates.preparingInstall else {
            service.cancelSetup(); pairing.stop()
            return .terminateNow
        }
        guard let directory = service.serviceDirectory else {
            updates.installationFailed("Open the installed Wonder app to finish its update.")
            return .terminateCancel
        }
        guard !updateTerminationPending else { return .terminateLater }
        updateTerminationPending = true
        Task { @MainActor in
            guard await updates.prepareTermination() else {
                updateTerminationPending = false
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            service.cancelSetup(); pairing.stop()
            // Prepare the host's exit marker before stopping its services. The
            // host acts on it only after the supervisor acknowledges shutdown.
            let ready = directory.appendingPathComponent("update-ready")
            do { try Data().write(to: ready, options: .atomic) }
            catch {
                updates.installationFailed("Wonder could not prepare its update. Try again.")
                updateTerminationPending = false
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            do { try Data().write(to: directory.appendingPathComponent("stop"), options: .atomic) }
            catch {
                try? FileManager.default.removeItem(at: ready)
                updates.installationFailed("Wonder could not stop for its update. Try again.")
                updateTerminationPending = false
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            // Once stop is written, the supervisor can no longer resume the
            // old services. Complete termination even if an acknowledgement is
            // delayed; cancelling here would strand an open, unusable app.
            for _ in 0..<120 {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stopped").path) {
                    // Sparkle runs in this bridge child. Wait for the responsible
                    // native launcher as well, so reopening cannot hit its old lock.
                    if let raw = ProcessInfo.processInfo.environment["WONDER_APP_LAUNCHER_PID"],
                       let launcher = Int32(raw), launcher > 1, launcher != getpid() {
                        for _ in 0..<150 {
                            if kill(launcher, 0) == -1 && errno == ESRCH {
                                sender.reply(toApplicationShouldTerminate: true)
                                return
                            }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct BridgeMain {
    @MainActor static func main() {
        guard CommandLine.arguments.contains("--bridge") else { return }
        let app = NSApplication.shared
        let delegate = NativeBridge()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
