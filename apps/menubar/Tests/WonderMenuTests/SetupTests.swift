import AppKit
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
    func testSetupRequiresRuntimeButNoWonderAccount() {
        XCTAssertTrue(SetupStep.welcome.canEnter(executionReady: false))
        for step in [SetupStep.connection, .permissions, .dictation, .phone, .finish] {
            XCTAssertFalse(step.canEnter(executionReady: false))
            XCTAssertTrue(step.canEnter(executionReady: true))
        }
    }
}
