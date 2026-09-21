import Combine
import AppKit
import Foundation

enum PermissionState: Equatable {
    case checking, enabled, notEnabled, needsAttention, unavailable
    var label: String {
        switch self {
        case .checking: "Checking…"
        case .enabled: "Enabled"
        case .notEnabled: "Not enabled"
        case .needsAttention: "Needs attention"
        case .unavailable: "Unavailable"
        }
    }
}

struct PermissionSnapshot: Decodable, Sendable {
    let screenRecording: Bool
    let accessibility: Bool
}

@MainActor
final class PermissionModel: ObservableObject {
    @Published private(set) var screen: PermissionState = .checking
    @Published private(set) var input: PermissionState = .checking
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private var requestedPane: PrivacyPane?
    private var instructions: String?
    private let helper: String?
    private var hadScreen: Bool
    private var hadInput: Bool
    private let defaults: UserDefaults

    init(helper: String? = ProcessInfo.processInfo.environment["WONDER_COMPUTER_USE_BIN"], defaults: UserDefaults = .standard) {
        self.helper = helper
        self.defaults = defaults
        hadScreen = defaults.bool(forKey: "permissions.hadScreen")
        hadInput = defaults.bool(forKey: "permissions.hadInput")
    }

    func apply(_ snapshot: PermissionSnapshot?) {
        guard let snapshot else {
            screen = .unavailable
            input = .unavailable
            message = "Screen and input access could not be checked. Reopen the installed Wonder app to try again. Messaging does not require these permissions."
            return
        }
        screen = snapshot.screenRecording ? .enabled : hadScreen ? .needsAttention : .notEnabled
        input = snapshot.accessibility ? .enabled : hadInput ? .needsAttention : .notEnabled
        hadScreen = hadScreen || snapshot.screenRecording
        hadInput = hadInput || snapshot.accessibility
        defaults.set(hadScreen, forKey: "permissions.hadScreen")
        defaults.set(hadInput, forKey: "permissions.hadInput")
        if let requestedPane,
           (requestedPane == .screenRecording ? snapshot.screenRecording : snapshot.accessibility) {
            PrivacySettings.dismiss()
            self.requestedPane = nil
            instructions = nil
        }
        message = instructions ?? (screen == .needsAttention || input == .needsAttention
            ? "Access was removed. Review the affected permission in System Settings. Messaging does not need this access."
            : nil)
    }

    func refresh() { probe(request: nil) }

    func request(_ pane: PrivacyPane, setup: Bool = false) {
        guard !busy else { return }
        message = pane == .screenRecording
            ? "Allow Wonder in Privacy & Security → Screen Recording. If macOS asks you to quit and reopen Wonder, setup will resume. Access rechecks automatically."
            : "Allow Wonder in Privacy & Security → Accessibility. Access rechecks automatically."
        requestedPane = pane
        instructions = message
        probe(request: pane)
        if let url = pane.url, !PrivacySettings.open(url, revealApplication: PrivacySettings.shouldPresent(setup: setup, alreadyAllowed: pane == .screenRecording ? screen == .enabled : input == .enabled)) {
            message = "System Settings could not open. Open Privacy & Security in System Settings and review Wonder's access."
        }
    }

    private func probe(request: PrivacyPane?) {
        guard !busy else { return }
        guard let helper, FileManager.default.isExecutableFile(atPath: helper) else { apply(nil); return }
        busy = true
        let flag: String? = request.map { $0 == .screenRecording ? "--request-screen" : "--request-input" }
        Task { @MainActor in
            let snapshot = await Task.detached {
                Self.readPermissions(helper: helper, requestFlag: flag)
            }.value
            apply(snapshot)
            busy = false
        }
    }

    nonisolated static func readPermissions(helper: String, requestFlag: String?) -> PermissionSnapshot? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["--permissions"] + (requestFlag.map { [$0] } ?? [])
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Only two booleans are emitted, well below pipe capacity. Bound even a hung prompt.
        let deadline = Date().addingTimeInterval(requestFlag == nil ? 3 : 30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return try? JSONDecoder().decode(PermissionSnapshot.self, from: data)
    }
}
