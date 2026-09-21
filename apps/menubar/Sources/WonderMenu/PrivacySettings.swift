import AppKit
import CoreGraphics

@MainActor
enum PrivacySettings {
    static func applicationBundle(containing executable: URL) -> URL? {
        var directory = executable.deletingLastPathComponent()
        while directory.path != "/" {
            if directory.pathExtension == "app" { return directory }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    static var dragRequest: [String: Any] = [:]
    private static var presentation: Task<Void, Never>?

    static func shouldPresent(setup: Bool, alreadyAllowed: Bool) -> Bool {
        setup && !alreadyAllowed
    }
    static func dismiss() {
        presentation?.cancel()
        dragRequest = [:]
    }
    static func open(_ pane: URL, revealApplication: Bool = false) -> Bool {
        dismiss()
        guard NSWorkspace.shared.open(pane) else { return false }
        if revealApplication, let executable = Bundle.main.executableURL,
           let app = applicationBundle(containing: executable) {
            presentation = Task { @MainActor in
                // Wait for the pane to appear before reading its window position.
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    if let frame = settingsFrame() {
                        present(app, beside: frame)
                        return
                    }
                }
                present(app, beside: nil)
            }
        }
        return true
    }
    private static func settingsFrame() -> CGRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == pid && (window[kCGWindowLayer as String] as? Int) == 0 {
            if let bounds = window[kCGWindowBounds as String] as? NSDictionary,
               let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 200 { return frame }
        }
        return nil
    }
    private static func present(_ app: URL, beside frame: CGRect?) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let desktopHeight = NSScreen.screens.first?.frame.height ?? 900
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let top = desktopHeight - visible.maxY
        let x = min(max(frame.map { $0.maxX + 12 } ?? (visible.maxX - 252), visible.minX), visible.maxX - 240)
        let y = min(max(frame?.minY ?? (top + 120), top), top + visible.height - 200)
        dragRequest = ["id": UUID().uuidString, "path": app.path, "x": x, "y": y]
    }
}
