import AppKit
import Foundation

/// The agent providers Wonder can run, each set up and signed in deliberately
/// from Settings → Providers. Status comes from `manage-runtime.sh status` and
/// `claude-status`, which read the stored login without starting model work.
enum ProviderKind: String, CaseIterable, Sendable {
    case codex, claude

    var name: String { self == .codex ? "Codex" : "Claude" }
    fileprivate var prefix: String { self == .codex ? "" : "claude-" }
}

enum ProviderState: String, Sendable {
    case checking, signedIn, signedOut, needsSubscription, unsupported, notInstalled, unavailable

    /// Exit codes shared by both status commands.
    init(exitCode: Int32) {
        switch exitCode {
        case 0: self = .signedIn
        case 42: self = .signedOut
        case 43: self = .unsupported
        case 44: self = .notInstalled
        case 45: self = .needsSubscription
        default: self = .unavailable
        }
    }
}

enum ProviderOperation: String, Sendable {
    case checking, signingIn, signingOut, reconnecting
}

struct ProviderStatus: Equatable, Sendable {
    var state: ProviderState = .checking
    var version = ""
    var account = ""
}

/// What wonderd reports about the runtime it runs for a provider.
struct ProviderRuntime: Equatable, Sendable, Decodable {
    var id: String
    var running = false
    var incompatible = false
    var updatePending = false
    var detail: String?

    /// `incompatible`: wonderd still holds an earlier rejection. `stopped`:
    /// Claude's always-on runtime is not running. `updatePending`: a newer
    /// install waits for agents to finish. Codex starts on demand, so a
    /// stopped Codex runtime is normal.
    func state(for provider: ProviderKind) -> String {
        if incompatible { return "incompatible" }
        if provider == .claude && !running { return "stopped" }
        return updatePending ? "updatePending" : "ok"
    }
}

/// wonderd's local provider endpoints; tests substitute a fake.
protocol ProviderDaemon: Sendable {
    func runtimes() async -> [ProviderRuntime]?
    /// Restarts the provider's runtime; returns a failure message, or nil.
    func reconnect(_ provider: ProviderKind) async -> String?
}

struct LocalProviderDaemon: ProviderDaemon {
    let environment: [String: String]

    private func request(_ path: String, method: String = "GET", timeout: TimeInterval) -> URLRequest? {
        let address = environment["WONDER_LISTEN_ADDR"] ?? "127.0.0.1:3777"
        guard let capability = environment["WONDER_LOOPBACK_CAPABILITY"], !capability.isEmpty,
              let origin = URL(string: "http://" + address), origin.host == "127.0.0.1" else { return nil }
        var request = URLRequest(url: origin.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(capability, forHTTPHeaderField: "x-wonder-loopback-capability")
        return request
    }

    func runtimes() async -> [ProviderRuntime]? {
        struct Reply: Decodable { let providers: [ProviderRuntime] }
        guard let request = request("api/v1/host/providers", timeout: 5),
              let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.providers
    }

    func reconnect(_ provider: ProviderKind) async -> String? {
        struct Failure: Decodable { let detail: String }
        // Restarting verifies the runtime and may wait for Claude to start.
        guard let request = request("api/v1/host/providers/\(provider.rawValue)/reconnect", method: "POST", timeout: 60) else {
            return "Open the installed Wonder app to manage providers."
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else {
            return "Wonder isn’t running on this Mac. Open Wonder, then try again."
        }
        if status == 200 { return nil }
        return (try? JSONDecoder().decode(Failure.self, from: data))?.detail
            ?? "\(provider.name) could not reconnect. Try again."
    }
}

@MainActor
final class ProviderControls: ObservableObject {
    @Published private(set) var statuses: [ProviderKind: ProviderStatus] = [:]
    @Published private(set) var operations: [ProviderKind: ProviderOperation] = [:]
    @Published private(set) var messages: [ProviderKind: (text: String, failure: Bool)] = [:]
    @Published private(set) var runtimes: [ProviderKind: ProviderRuntime] = [:]
    private var lastChecked: [ProviderKind: Date] = [:]
    private var running: [ProviderKind: Process] = [:]
    private var cancelled: Set<ProviderKind> = []
    private let environment: [String: String]
    /// Restarts Wonder's services so a changed Codex login reaches the daemon.
    var restartServices: () -> Void = {}

    private let daemon: any ProviderDaemon

    init(environment: [String: String] = ProcessInfo.processInfo.environment, daemon: (any ProviderDaemon)? = nil) {
        self.environment = environment
        self.daemon = daemon ?? LocalProviderDaemon(environment: environment)
    }

    var busy: Bool { !operations.isEmpty }
    /// One sign-in or sign-out at a time; a status check never blocks one.
    private func canChange(_ provider: ProviderKind) -> Bool {
        operations[provider] == nil && !operations.values.contains { $0 != .checking }
    }

    /// Checks each idle provider whose status is older than `maximumAge`.
    func refresh(maximumAge: TimeInterval = 30) {
        for provider in ProviderKind.allCases where operations[provider] == nil
            && Date().timeIntervalSince(lastChecked[provider] ?? .distantPast) >= maximumAge {
            check(provider)
        }
    }

    private func check(_ provider: ProviderKind) {
        operations[provider] = .checking
        if statuses[provider] == nil { statuses[provider] = ProviderStatus() }
        Task { @MainActor in
            let result = await run(provider, "status", capture: true)
            // What is installed can differ from what wonderd runs.
            let runtime = await daemon.runtimes()?.first { $0.id == provider.rawValue }
            runtimes[provider] = runtime
            operations[provider] = nil
            lastChecked[provider] = Date()
            guard let result else {
                statuses[provider] = ProviderStatus(state: .unavailable)
                return
            }
            let fields = result.output.split(separator: "\n").last.map {
                $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            } ?? []
            statuses[provider] = ProviderStatus(
                state: ProviderState(exitCode: result.status),
                version: String((fields.first ?? "").replacingOccurrences(of: "codex-cli ", with: "").prefix(40)),
                account: String((fields.count > 1 ? fields[1] : "").prefix(60))
            )
        }
    }

    /// Re-locates and re-verifies the provider, restarts its runtime in
    /// wonderd, then checks its status again.
    func reconnect(_ provider: ProviderKind) {
        guard canChange(provider) else { return }
        operations[provider] = .reconnecting
        messages[provider] = nil
        Task { @MainActor in
            let failure = await daemon.reconnect(provider)
            operations[provider] = nil
            messages[provider] = failure.map { ($0, true) } ?? ("\(provider.name) reconnected.", false)
            check(provider)
        }
    }

    func signIn(_ provider: ProviderKind) {
        guard canChange(provider) else { return }
        operations[provider] = .signingIn
        messages[provider] = ("Finish signing in to \(provider.name) in your browser.", false)
        Task { @MainActor in
            let result = await run(provider, "login", capture: false)
            operations[provider] = nil
            if cancelled.remove(provider) != nil {
                messages[provider] = nil
            } else if result?.status == 0 {
                messages[provider] = nil
                if provider == .codex { restartServices() }
            } else {
                messages[provider] = ("Sign-in did not finish. Check your connection and try again.", true)
            }
            check(provider)
        }
    }

    func signOut(_ provider: ProviderKind) {
        guard canChange(provider) else { return }
        operations[provider] = .signingOut
        messages[provider] = nil
        Task { @MainActor in
            let result = await run(provider, "logout", capture: false)
            operations[provider] = nil
            if result?.status == 0 {
                if provider == .codex { restartServices() }
            } else {
                messages[provider] = ("\(provider.name) could not sign out. Try again.", true)
            }
            check(provider)
        }
    }

    /// Opens what a missing or outdated provider needs: ChatGPT supplies Codex,
    /// and Wonder bundles its Claude runtime.
    func setUp(_ provider: ProviderKind) {
        let url: URL
        switch (provider, statuses[provider]?.state) {
        case (.codex, .unsupported):
            url = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        case (.codex, _):
            url = URL(string: "https://openai.com/chatgpt/download/")!
        case (.claude, _):
            url = URL(string: "https://github.com/swaymun/wonder/releases")!
        }
        if !NSWorkspace.shared.open(url) {
            messages[provider] = ("The download page could not open.", true)
        }
    }

    func cancel(_ provider: ProviderKind) {
        guard operations[provider] == .signingIn, let process = running[provider] else { return }
        cancelled.insert(provider)
        process.terminate()
    }

    func stop() {
        for provider in ProviderKind.allCases { cancel(provider) }
    }

    var snapshot: [[String: Any]] {
        ProviderKind.allCases.map { provider in
            let status = statuses[provider] ?? ProviderStatus()
            return [
                "id": provider.rawValue, "name": provider.name,
                "state": status.state.rawValue, "version": status.version, "account": status.account,
                "runtime": runtimes[provider]?.state(for: provider) ?? "",
                "runtimeDetail": runtimes[provider]?.detail ?? "",
                "operation": operations[provider]?.rawValue ?? "",
                "message": messages[provider]?.text ?? "", "failure": messages[provider]?.failure ?? false,
            ]
        }
    }

    /// Runs one manage-runtime action. Status output is captured; sign-in and
    /// sign-out output goes to the service log because it can include URLs.
    private func run(_ provider: ProviderKind, _ action: String, capture: Bool) async -> (status: Int32, output: String)? {
        guard let resources = environment["WONDER_RESOURCES"] else {
            messages[provider] = ("Open the installed Wonder app to manage providers.", true)
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [resources + "/manage-runtime.sh", provider.prefix + action]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let log = environment["WONDER_SERVICE_DIR"].flatMap { directory -> FileHandle? in
            let path = URL(fileURLWithPath: directory).appendingPathComponent("providers.log").path
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = FileHandle(forWritingAtPath: path)
            _ = try? handle?.seekToEnd()
            return handle
        }
        process.standardOutput = capture ? output : (log ?? FileHandle.nullDevice)
        process.standardError = log ?? FileHandle.nullDevice
        running[provider] = process
        defer { running[provider] = nil; try? log?.close() }
        // Bound a stuck status check; sign-in waits for the user in their browser.
        let limit: TimeInterval = capture ? 45 : 15 * 60
        return await withCheckedContinuation { continuation in
            let buffer = OutputBuffer()
            if capture {
                output.fileHandleForReading.readabilityHandler = { handle in buffer.append(handle.availableData) }
            }
            process.terminationHandler = { finished in
                output.fileHandleForReading.readabilityHandler = nil
                if capture { buffer.append(output.fileHandleForReading.readDataToEndOfFile()) }
                continuation.resume(returning: (finished.terminationStatus, buffer.text))
            }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) { [weak process] in
                if process?.isRunning == true { process?.terminate() }
            }
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count < 65_536 { data.append(chunk) }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
