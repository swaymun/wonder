import Combine
import AppKit
import Sparkle

@MainActor
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    private(set) var preparingInstall = false
    @Published var available = false
    @Published var automaticallyChecks = false
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        // This beta ships signed downloads. A feed/key alone is not evidence
        // that automatic update delivery has been qualified.
        available = false
        automaticallyChecks = false
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { preparingInstall = true }

    func check() { controller?.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecks = controller?.updater.automaticallyChecksForUpdates ?? false
    }
}
