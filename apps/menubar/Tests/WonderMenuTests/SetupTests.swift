import AppKit
import Combine
import ServiceManagement
import XCTest
@testable import WonderMenu

@MainActor
private final class TestLogin: LoginRegistration {
    var status: SMAppService.Status = .notRegistered
    var registrations = 0
    var deny = false
    var fail = false
    func register() throws {
        registrations += 1
        if fail { throw NSError(domain: "test", code: 1) }
        status = deny ? .requiresApproval : .enabled
    }
    func unregister() throws { status = .notRegistered }
}

final class SetupTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "WonderSetupTests.\(UUID().uuidString)")!
    }

    @MainActor
    func testEveryInterruptedStepResumesWithoutClaimingCompletion() {
        let defaults = isolatedDefaults()
        for step in SetupStep.allCases {
            SetupProgress(defaults: defaults).go(to: step)
            let relaunched = SetupProgress(defaults: defaults)
            XCTAssertEqual(relaunched.step, step)
            XCTAssertFalse(relaunched.completed)
        }
        SetupProgress(defaults: defaults).finish()
        XCTAssertTrue(SetupProgress(defaults: defaults).completed)
    }

    @MainActor
    func testReviewSetupPreservesExistingPreferencesAndResumesWelcome() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "login.defaultApplied")
        defaults.set("retained", forKey: "paired-device-test")
        let progress = SetupProgress(defaults: defaults)
        progress.go(to: .finish)
        progress.finish()
        progress.review()
        let reopened = SetupProgress(defaults: defaults)
        XCTAssertFalse(reopened.completed)
        XCTAssertEqual(reopened.step, .welcome)
        XCTAssertTrue(defaults.bool(forKey: "login.defaultApplied"))
        XCTAssertEqual(defaults.string(forKey: "paired-device-test"), "retained")
    }

    @MainActor
    func testSkippedPermissionsDoNotGateRemainingSetup() {
        let defaults = isolatedDefaults()
        let permissions = PermissionModel(helper: nil, defaults: defaults)
        permissions.apply(PermissionSnapshot(screenRecording: false, accessibility: false))
        let progress = SetupProgress(defaults: defaults)
        progress.go(to: .phone)
        progress.go(to: .finish)
        progress.finish()
        XCTAssertTrue(progress.completed)
        XCTAssertEqual(permissions.screen, .notEnabled)
        XCTAssertEqual(permissions.input, .notEnabled)
    }

    @MainActor
    func testGrantRevokeAndHelperFailureNeverKeepEnabledState() {
        let defaults = isolatedDefaults()
        let permissions = PermissionModel(helper: nil, defaults: defaults)
        permissions.apply(PermissionSnapshot(screenRecording: true, accessibility: true))
        XCTAssertEqual(permissions.screen, .enabled)
        permissions.apply(PermissionSnapshot(screenRecording: false, accessibility: true))
        XCTAssertEqual(permissions.screen, .needsAttention)
        XCTAssertEqual(permissions.input, .enabled)
        permissions.apply(nil)
        XCTAssertEqual(permissions.screen, .unavailable)
        XCTAssertEqual(permissions.input, .unavailable)
        let relaunched = PermissionModel(helper: nil, defaults: defaults)
        XCTAssertEqual(relaunched.screen, .checking)
        relaunched.apply(PermissionSnapshot(screenRecording: false, accessibility: false))
        XCTAssertEqual(relaunched.screen, .needsAttention)
        XCTAssertEqual(relaunched.input, .needsAttention)
        relaunched.apply(PermissionSnapshot(screenRecording: true, accessibility: true))
        XCTAssertEqual(relaunched.input, .enabled)
    }

    @MainActor
    func testLoginDefaultsOnOnceAndPreservesOptOutAcrossRelaunch() {
        let defaults = isolatedDefaults()
        let login = TestLogin()
        login.status = .notFound
        let service = ServiceControls(defaults: defaults, login: login)
        service.applyInitialLoginDefault()
        XCTAssertTrue(service.launchAtLogin)
        service.setLaunchAtLogin(false)
        let relaunched = ServiceControls(defaults: defaults, login: login)
        relaunched.applyInitialLoginDefault()
        XCTAssertFalse(relaunched.launchAtLogin)
        XCTAssertEqual(login.registrations, 1)
    }

    @MainActor
    func testLoginApprovalGrantAndSystemRevocationAreReflected() {
        let defaults = isolatedDefaults()
        let login = TestLogin()
        login.deny = true
        let service = ServiceControls(defaults: defaults, login: login)
        service.applyInitialLoginDefault()
        XCTAssertFalse(service.launchAtLogin)
        XCTAssertTrue(service.loginNeedsApproval)
        login.status = .enabled
        service.refreshLogin()
        XCTAssertTrue(service.launchAtLogin)
        XCTAssertFalse(service.loginNeedsApproval)
        login.status = .requiresApproval
        service.refreshLogin()
        XCTAssertFalse(service.launchAtLogin)
        ServiceControls(defaults: defaults, login: login).applyInitialLoginDefault()
        XCTAssertEqual(login.registrations, 1)
    }

    @MainActor
    func testLoginFailureDoesNotClaimRegistrationOrRetryOnUpdate() {
        let defaults = isolatedDefaults()
        let login = TestLogin()
        login.fail = true
        let service = ServiceControls(defaults: defaults, login: login)
        service.applyInitialLoginDefault()
        XCTAssertFalse(service.launchAtLogin)
        XCTAssertTrue(service.loginMessage?.contains("could not") == true)
        service.refreshLogin()
        XCTAssertTrue(service.loginMessage?.contains("could not") == true)
        ServiceControls(defaults: defaults, login: login).applyInitialLoginDefault()
        XCTAssertEqual(login.registrations, 1)
    }

    @MainActor
    func testProviderStatusSignInAndSignOutFollowManageRuntimeResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WonderProviders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The fake records each action and replies with the exit code saved for it.
        let script = directory.appendingPathComponent("manage-runtime.sh")
        try """
        #!/bin/sh
        echo "$1" >> "$WONDER_SERVICE_DIR/actions"
        printf '1.2.3\\tTest plan\\n'
        exit $(cat "$WONDER_SERVICE_DIR/$1" 2>/dev/null || echo 1)
        """.write(to: script, atomically: true, encoding: .utf8)
        func reply(_ action: String, _ code: Int32) throws {
            try "\(code)".write(to: directory.appendingPathComponent(action), atomically: true, encoding: .utf8)
        }
        let providers = ProviderControls(environment: ["WONDER_RESOURCES": directory.path, "WONDER_SERVICE_DIR": directory.path])
        var restarts = 0
        providers.restartServices = { restarts += 1 }
        func settle() async {
            for _ in 0..<200 where providers.busy { try? await Task.sleep(for: .milliseconds(25)) }
            XCTAssertFalse(providers.busy)
        }
        func state(_ provider: ProviderKind) -> String? {
            providers.snapshot.first { $0["id"] as? String == provider.rawValue }?["state"] as? String
        }

        try reply("status", 0); try reply("claude-status", 42)
        providers.refresh()
        await settle()
        XCTAssertEqual(state(.codex), "signedIn")
        XCTAssertEqual(providers.statuses[.codex], ProviderStatus(state: .signedIn, version: "1.2.3", account: "Test plan"))
        XCTAssertEqual(state(.claude), "signedOut")
        providers.refresh()
        XCTAssertFalse(providers.busy, "A fresh status is not checked again")

        try reply("claude-login", 1)
        providers.signIn(.claude)
        await settle()
        XCTAssertEqual(providers.messages[.claude]?.failure, true)
        try reply("claude-login", 0); try reply("claude-status", 0)
        providers.signIn(.claude)
        await settle()
        XCTAssertNil(providers.messages[.claude])
        XCTAssertEqual(state(.claude), "signedIn")
        XCTAssertEqual(restarts, 0, "Claude reads its login per request")

        try reply("logout", 0); try reply("status", 42)
        providers.signOut(.codex)
        await settle()
        XCTAssertEqual(state(.codex), "signedOut")
        XCTAssertEqual(restarts, 1, "The daemon reconnects after the Codex login changes")

        for (code, expected) in [(43, "unsupported"), (44, "notInstalled"), (7, "unavailable")] {
            try reply("status", Int32(code))
            providers.refresh(maximumAge: 0)
            await settle()
            XCTAssertEqual(state(.codex), expected)
        }
        let actions = try String(contentsOf: directory.appendingPathComponent("actions"), encoding: .utf8)
        XCTAssertFalse(actions.contains("check"), "Status never runs the model-starting SDK check")
    }

    @MainActor
    func testReconnectRestartsTheRuntimeWonderRunsAndReportsTheOutcome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WonderReconnect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "#!/bin/sh\nprintf '1.2.3\\tTest plan\\n'\nexit 0\n".write(
            to: directory.appendingPathComponent("manage-runtime.sh"), atomically: true, encoding: .utf8)
        let daemon = FakeProviderDaemon()
        daemon.set([ProviderRuntime(id: "codex", incompatible: true, detail: "Codex was updated."),
                    ProviderRuntime(id: "claude", running: false)])
        let providers = ProviderControls(environment: ["WONDER_RESOURCES": directory.path, "WONDER_SERVICE_DIR": directory.path], daemon: daemon)
        func settle() async {
            for _ in 0..<200 where providers.busy { try? await Task.sleep(for: .milliseconds(25)) }
            XCTAssertFalse(providers.busy)
        }
        func field(_ provider: ProviderKind, _ key: String) -> String? {
            providers.snapshot.first { $0["id"] as? String == provider.rawValue }?[key] as? String
        }
        providers.refresh()
        await settle()
        XCTAssertEqual(field(.codex, "state"), "signedIn")
        XCTAssertEqual(field(.codex, "runtime"), "incompatible", "Installed and running versions can disagree")
        XCTAssertEqual(field(.codex, "runtimeDetail"), "Codex was updated.")
        XCTAssertEqual(field(.claude, "runtime"), "stopped")

        daemon.set([ProviderRuntime(id: "codex", running: true), ProviderRuntime(id: "claude", running: false)])
        providers.reconnect(.codex)
        XCTAssertEqual(field(.codex, "operation"), "reconnecting")
        await settle()
        XCTAssertEqual(daemon.reconnected, [.codex])
        XCTAssertEqual(field(.codex, "runtime"), "ok")
        XCTAssertEqual(providers.messages[.codex]?.failure, false)

        daemon.failure = "Claude didn’t restart."
        providers.reconnect(.claude)
        await settle()
        XCTAssertEqual(providers.messages[.claude]?.text, "Claude didn’t restart.")
        XCTAssertEqual(providers.messages[.claude]?.failure, true)
        XCTAssertEqual(field(.claude, "runtime"), "stopped")
    }

    func testHelperRelaunchUpdateAndInvalidOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("helper")
        func replace(_ output: String) throws {
            try "#!/bin/sh\nprintf '%s\\n' '\(output)'\n".write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        }
        try replace("{\"screenRecording\":false,\"accessibility\":false}")
        XCTAssertEqual(PermissionModel.readPermissions(helper: helper.path, requestFlag: nil)?.screenRecording, false)
        try replace("{\"screenRecording\":true,\"accessibility\":true}")
        XCTAssertEqual(PermissionModel.readPermissions(helper: helper.path, requestFlag: nil)?.screenRecording, true)
        try replace("invalid")
        XCTAssertNil(PermissionModel.readPermissions(helper: helper.path, requestFlag: nil))
    }


    @MainActor
    func testRetiredDictationSetupAdvancesToPairing() {
        let suite = "wonder-retired-dictation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(5, forKey: "setup.step")
        XCTAssertEqual(SetupProgress(defaults: defaults).step, .phone)
    }

    @MainActor
    func testSetupRequiresRuntimeButNoWonderAccount() {
        XCTAssertTrue(SetupStep.welcome.canEnter(executionReady: false))
        for step in [SetupStep.connection, .permissions, .phone, .finish] {
            XCTAssertFalse(step.canEnter(executionReady: false))
            XCTAssertTrue(step.canEnter(executionReady: true))
        }
    }
}

private final class FakeProviderDaemon: ProviderDaemon, @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [ProviderRuntime] = []
    private var calls: [ProviderKind] = []
    private var nextFailure: String?
    var reconnected: [ProviderKind] { lock.withLock { calls } }
    var failure: String? {
        get { lock.withLock { nextFailure } }
        set { lock.withLock { nextFailure = newValue } }
    }
    func set(_ runtimes: [ProviderRuntime]) { lock.withLock { reports = runtimes } }
    func runtimes() async -> [ProviderRuntime]? { lock.withLock { reports } }
    func reconnect(_ provider: ProviderKind) async -> String? {
        lock.withLock { calls.append(provider); return nextFailure }
    }
}
