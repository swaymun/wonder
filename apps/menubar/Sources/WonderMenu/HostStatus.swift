import AppKit
import Combine

private struct HostStatus: Decodable {
    let state: String
    let execution: ExecutionStatus
}

private struct ExecutionStatus: Decodable {
    let ready: Bool
}

enum PrivacyPane {
    case accessibility
    case screenRecording

    var url: URL? {
        let anchor: String
        switch self {
        case .accessibility:
            anchor = "Privacy_Accessibility"
        case .screenRecording:
            anchor = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

enum MenuReadinessState: Equatable {
    case ready
    case starting
    case offline

    static func fromHostState(_ state: String) -> Self {
        switch state.lowercased() {
        case "ready", "running":
            return .ready
        default:
            return .starting
        }
    }

    var presentation: MenuStatusPresentation {
        switch self {
        case .ready:
            return MenuStatusPresentation(
                title: "Connected",
                detail: "Your Mac is ready."
            )
        case .starting:
            return MenuStatusPresentation(
                title: "Connecting…",
                detail: "Your Mac is opening your saved chats."
            )
        case .offline:
            return MenuStatusPresentation(
                title: "Offline",
                detail: "Wonder is not responding. Restart it below; your saved chats are kept."
            )

        }
    }
}

struct MenuStatusPresentation: Equatable {
    let title: String
    let detail: String
}

@MainActor
final class MenuModel: ObservableObject {
    @Published var serviceRunning = false
    @Published var executionReady = false
    @Published var needsRepair = false
    private var refreshing = false
    @Published var status = "Checking Wonder…"
    @Published var statusDetail = "Opening your saved chats…"
    private let capability: String
    private let localURL: URL
    private var failedPolls = 0

    private func apply(_ state: MenuReadinessState) {
        let presentation = state.presentation
        status = presentation.title
        statusDetail = presentation.detail
    }

    init() {
        let address = ProcessInfo.processInfo.environment["WONDER_LISTEN_ADDR"] ?? "127.0.0.1:3777"
        let candidate = URL(string: "http://" + address)
        localURL = candidate?.host == "127.0.0.1" ? candidate! : URL(string: "http://127.0.0.1:3777")!
        capability = ProcessInfo.processInfo.environment["WONDER_LOOPBACK_CAPABILITY"] ?? UUID().uuidString
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        var request = URLRequest(url: localURL.appendingPathComponent("api/v1/host/status"))
        request.timeoutInterval = 1.5
        request.setValue(capability, forHTTPHeaderField: "x-wonder-loopback-capability")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            Task { @MainActor in
                defer { self.refreshing = false }
                if error != nil || !(response is HTTPURLResponse) {
                    self.serviceRunning = false
                    self.executionReady = false
                    self.failedPolls += 1
                    if self.failedPolls >= 3 {
                        self.serviceRunning = false
                    self.executionReady = false
                        self.needsRepair = true
                        self.apply(.offline)
                    } else {
                        self.statusDetail = "Opening your saved chats…"
                    }
                    return
                }
                guard let data, let response = response as? HTTPURLResponse else { return }
                guard response.statusCode == 200 else {
                    self.serviceRunning = false
                    self.executionReady = false
                    self.failedPolls += 1
                    if self.failedPolls >= 3 {
                        self.serviceRunning = false
                    self.executionReady = false
                        self.needsRepair = true
                        self.apply(.offline)
                    } else {
                        self.status = "Checking Wonder…"
                        self.statusDetail = "Wonder is opening your saved chats."
                    }
                    return
                }
                if let host = try? JSONDecoder().decode(HostStatus.self, from: data) {
                    self.serviceRunning = true
                    self.failedPolls = 0
                    self.executionReady = host.execution.ready
                    self.needsRepair = !self.executionReady
                    self.apply(self.executionReady ? .ready : .starting)
                    if !host.execution.ready {
                        self.status = "Needs attention"
                        self.statusDetail = "Your Bots need attention. Open setup to reconnect your account or repair Wonder."
                    }
                } else {
                    self.serviceRunning = false
                    self.executionReady = false
                    self.needsRepair = true
                    self.apply(.offline)
                }
            }
        }.resume()
    }

}
