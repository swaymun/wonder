import AppKit
import Combine

enum SetupStep: Int, CaseIterable {
    // Preserve persisted step values from the original four-step setup.
    case welcome = 0, connection = 4, permissions = 1, display = 6, phone = 2, finish = 3
    func canEnter(executionReady: Bool) -> Bool {
        self == .welcome || executionReady
    }
    var title: String {
        switch self {
        case .welcome: "Set up Wonder on this Mac"
        case .connection: "Connect with Tailscale"
        case .permissions: "Choose what Wonder can do"
        case .display: "Choose a screen to share"
        case .phone: "Connect your phone"
        case .finish: "Wonder stays with you"
        }
    }
}

@MainActor
final class SetupProgress: ObservableObject {
    @Published private(set) var step: SetupStep
    @Published private(set) var completed: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Retired dictation setup advances to pairing; persisted IDs stay stable.
        step = defaults.integer(forKey: "setup.step") == 5 ? .phone : defaults.object(forKey: "setup.step") == nil ? .welcome : (SetupStep(rawValue: defaults.integer(forKey: "setup.step")) ?? .welcome)
        completed = defaults.bool(forKey: "setup.completed")
    }

    func go(to step: SetupStep) {
        self.step = step
        defaults.set(step.rawValue, forKey: "setup.step")
    }

    func finish() {
        // Completion concerns this Mac's shell only, never device enrollment.
        completed = true
        defaults.set(true, forKey: "setup.completed")
    }

    func review() {
        // Revisit setup without resetting devices, folders or login preferences.
        go(to: .welcome)
        completed = false
        defaults.set(false, forKey: "setup.completed")
    }
}
