import Foundation
import WonderComputerUseCore

/// Tracks whether the control helper holds a lease so Settings can offer Stop
/// only while a paired device controls this Mac.
@MainActor
final class ControlSessionObserver: NSObject {
    private(set) var active = false
    private var observing = false

    func start() {
        guard !observing else { return }
        observing = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(stateChanged(_:)), name: ControlSessionSignal.state,
            object: nil, suspensionBehavior: .deliverImmediately)
        // A helper that started before Settings reposts its state.
        DistributedNotificationCenter.default().postNotificationName(
            ControlSessionSignal.stateRequest, object: nil, userInfo: nil, deliverImmediately: true)
    }

    nonisolated func update(_ state: String?) {
        Task { @MainActor in self.active = state == ControlSessionSignal.active }
    }

    @objc nonisolated private func stateChanged(_ notification: Notification) {
        update(notification.object as? String)
    }

    isolated deinit { DistributedNotificationCenter.default().removeObserver(self) }
}
