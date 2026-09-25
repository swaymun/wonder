import XCTest
import CryptoKit
import UIKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import WonderPairing
@testable import Wonder

final class WonderDiagnosticsTests: XCTestCase {
    func testPushPreviewAuthenticatesContentAndRouting() throws {
        let key = try XCTUnwrap(Data(pushBase64URL: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"))
        var payload: [String: String] = ["eventId": "00000000-0000-4000-8000-000000000003", "preview": "AAECAwQFBgcICQoLPCCicrGJpzm3Y8Xk0I1YGfG_9xQyzH8tTQKW8XQGbpAtMsyTy7gwolbzF4Tr7whcjyBA-jWkyKkAt9qGj3AaVn8eu2CVVyfnz0FMKbT7GBkXrL4", "registrationId": "00000000-0000-4000-8000-000000000001", "routeId": "00000000-0000-4000-8000-000000000002"]
        let decoded = try PushPreview.decrypt(payload, key: key)
        XCTAssertEqual(decoded.title, "Road trip · Question")
        XCTAssertEqual(decoded.body, "Which day works? 🗓️")
        for field in ["registrationId", "routeId", "eventId"] {
            var wrong = payload; wrong[field] = UUID().uuidString.lowercased()
            XCTAssertThrowsError(try PushPreview.decrypt(wrong, key: key))
        }
        XCTAssertThrowsError(try PushPreview.decrypt(payload, key: Data(repeating: 0, count: 32)))
        payload["preview"] = String(repeating: "a", count: 3241)
        XCTAssertThrowsError(try PushPreview.decrypt(payload, key: key))
    }


    @MainActor func testPushSetupStatusAndOwnershipSurvivePersistence() throws {
        let saved = Self.cameraSavedConnection()
        var record = PushRegistration(host: saved.credential.hostInstallationId, device: saved.credential.deviceId, endpoint: "https://push.example.test", key: Data(repeating: 1, count: 32))
        XCTAssertFalse(record.macRegistered)
        XCTAssertTrue(record.belongs(to: saved.credential))
        record.macRegistered = true
        XCTAssertTrue(record.macRegistered)
        record.enabled = false
        let restored = try JSONDecoder().decode(PushRegistration.self, from: JSONEncoder().encode(record))
        XCTAssertFalse(restored.enabled)
        let differentDevice = PushRegistration(host: saved.credential.hostInstallationId, device: "repaired-device", endpoint: record.endpoint, key: record.key)
        XCTAssertFalse(differentDevice.belongs(to: saved.credential))
    }

    @MainActor func testPushPreferenceIsImmediateAndSurvivesOfflineMacAndRestart() async throws {
        MessageRecoveryURLProtocol.reset()
        MessageRecoveryURLProtocol.fail(path: "/api/v1/push/config", error: .notConnectedToInternet)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root), host = Self.cameraSavedConnection().credential.hostInstallationId
        let library = ConnectionLibrary(diagnosticModel: model)
        var values: [String: Data] = [:]
        var attempts = 0
        let push = PushNotifications(read: { values[$0] }, write: { values[$1] = $0 }, authorize: {
            attempts += 1
            return true
        }, registerForPush: { XCTFail("Offline setup must not reach APNs enrollment") })
        push.attach(library)
        push.enable(model)
        XCTAssertTrue(push.isEnabled(host), "The preference changes before any asynchronous work")
        XCTAssertNotNil(values["push-requested-devices-v1"])
        for _ in 0..<100 { if !MessageRecoveryURLProtocol.bodies(path: "/api/v1/push/config", includingEmpty: true).isEmpty { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: "/api/v1/push/config", includingEmpty: true).count, 1)
        XCTAssertTrue(push.isEnabled(host))
        XCTAssertNil(push.settingsAlert, "An offline Mac must not interrupt the user")
        for _ in 0..<100 {
            if case .some(.needsRetry) = push.setupState(host) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .some(.needsRetry) = push.setupState(host) else {
            return XCTFail("An offline setup should offer retry in Settings")
        }
        let restored = PushNotifications(read: { values[$0] }, write: { values[$1] = $0 }, registerForPush: {})
        restored.attach(library)
        XCTAssertTrue(restored.isEnabled(host), "Pending intent survives relaunch without a registration")
        restored.disable(model)
        let off = PushNotifications(read: { values[$0] }, write: { values[$1] = $0 }, registerForPush: {})
        off.attach(library)
        XCTAssertFalse(off.isEnabled(host))
        push.disable(model)
    }

    @MainActor func testPushDeniedPermissionTurnsOffAndOffersSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root), host = Self.cameraSavedConnection().credential.hostInstallationId
        let library = ConnectionLibrary(diagnosticModel: model)
        var values: [String: Data] = [:]
        let push = PushNotifications(read: { values[$0] }, write: { values[$1] = $0 }, authorize: { false }, registerForPush: { XCTFail("Denied permission must not enroll") })
        push.attach(library); push.enable(model)
        XCTAssertTrue(push.isEnabled(host))
        for _ in 0..<100 { if push.settingsAlert != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(push.isEnabled(host))
        XCTAssertEqual(push.settingsAlert?.host, host)
        XCTAssertEqual(push.settingsAlert?.opensSettings, true)
        let saved = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(values["push-requested-devices-v1"]))
        XCTAssertNil(saved[host])
    }

    @MainActor func testPushAPNsFailureIsVisibleAndRetryableWithoutLosingPreference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root), host = Self.cameraSavedConnection().credential.hostInstallationId
        let library = ConnectionLibrary(diagnosticModel: model)
        var values: [String: Data] = [:]
        var registrations = 0
        let push = PushNotifications(read: { values[$0] }, write: { values[$1] = $0 },
                                     authorize: { true }, registerForPush: { registrations += 1 })
        push.attach(library)
        push.enable(model)
        XCTAssertEqual(push.setupState(host), .settingUp)

        push.registrationFailed()
        guard case .some(.needsRetry(let message)) = push.setupState(host) else {
            return XCTFail("APNs failure should offer a retry")
        }
        XCTAssertTrue(message.contains("Apple"))
        XCTAssertTrue(push.isEnabled(host), "An APNs failure must preserve the requested setting")

        let beforeRetry = registrations
        push.retry(host)
        XCTAssertEqual(push.setupState(host), .settingUp)
        XCTAssertEqual(registrations, beforeRetry + 1)
        push.disable(model)
        XCTAssertNil(push.setupState(host))
    }

    @MainActor func testPushChallengeTimeoutIgnoresStaleProof() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root), saved = Self.cameraSavedConnection(), host = saved.credential.hostInstallationId
        let library = ConnectionLibrary(diagnosticModel: model)
        var record = PushRegistration(host: host, device: saved.credential.deviceId,
                                      endpoint: "https://push.example.test", key: Data(repeating: 1, count: 32))
        record.nonce = "current"
        var values = ["push-registrations-v1": try JSONEncoder().encode([host: record])]
        let push = PushNotifications(read: { values[$0] }, write: { values[$1] = $0 },
                                     authorize: { true }, registerForPush: {})
        push.attach(library)
        push.enable(model)
        push.challengeTimedOut(host, nonce: "stale")
        XCTAssertEqual(push.setupState(host), .settingUp)
        push.challengeTimedOut(host, nonce: "current")
        guard case .some(.needsRetry(let message)) = push.setupState(host) else {
            return XCTFail("An unanswered current challenge should offer retry")
        }
        XCTAssertTrue(message.contains("Apple"))
        let pending = try JSONDecoder().decode([String: PushRegistration].self,
                                               from: XCTUnwrap(values["push-registrations-v1"]))
        XCTAssertEqual(pending[host]?.nonce, "current", "A late APNs proof must remain eligible after the warning")
        push.disable(model)
    }

    @MainActor func testPushRestoredRegistrationClearsSetupWhenAPNsTokenArrives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root), saved = Self.cameraSavedConnection(), host = saved.credential.hostInstallationId
        let library = ConnectionLibrary(diagnosticModel: model)
        var record = PushRegistration(host: host, device: saved.credential.deviceId,
                                      endpoint: "https://push.example.test", key: Data(repeating: 1, count: 32))
        record.id = UUID().uuidString
        record.token = "0102"
        record.macRegistered = true
        record.previewVersion = 1
        record.registeredAt = Date()
        var values = ["push-registrations-v1": try JSONEncoder().encode([host: record])]
        let push = PushNotifications(read: { values[$0] }, write: { values[$1] = $0 },
                                     authorize: { true }, registerForPush: {})
        push.attach(library)
        push.enable(model)
        XCTAssertEqual(push.setupState(host), .settingUp)
        push.receivedToken(Data([0x01, 0x02]))
        XCTAssertNil(push.setupState(host), "A confirmed registration must not look stuck after relaunch")
    }

    @MainActor func testPushOffCancelsDelayedPermissionWithoutReenabling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root), host = Self.cameraSavedConnection().credential.hostInstallationId
        let library = ConnectionLibrary(diagnosticModel: model)
        var values: [String: Data] = [:]
        var permission: CheckedContinuation<Bool, Error>?
        let push = PushNotifications(read: { values[$0] }, write: { values[$1] = $0 }, authorize: {
            try await withCheckedThrowingContinuation { permission = $0 }
        }, registerForPush: { XCTFail("A cancelled preference must never enroll") })
        push.attach(library); push.enable(model)
        for _ in 0..<100 { if permission != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        let pending = try XCTUnwrap(permission)
        push.disable(model)
        pending.resume(returning: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(push.isEnabled(host))
        XCTAssertNil(push.settingsAlert)
        XCTAssertNil(values["push-registrations-v1"])
    }

    @MainActor func testPushPreferenceWriteFailureDoesNotPretendItSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root), host = Self.cameraSavedConnection().credential.hostInstallationId
        let library = ConnectionLibrary(diagnosticModel: model)
        let push = PushNotifications(read: { _ in nil }, write: { _, _ in throw CocoaError(.fileWriteNoPermission) }, authorize: { XCTFail("An unsaved preference must not enroll"); return true }, registerForPush: {})
        push.attach(library); push.enable(model)
        XCTAssertFalse(push.isEnabled(host))
        XCTAssertEqual(push.settingsAlert?.title, "Couldn't change notifications")
    }

    @MainActor func testPushPreferenceMigrationPreservesOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root), saved = Self.cameraSavedConnection()
        let library = ConnectionLibrary(diagnosticModel: model)
        let record = PushRegistration(host: saved.credential.hostInstallationId, device: saved.credential.deviceId, endpoint: "https://push.example.test", key: Data(repeating: 1, count: 32))
        let data = try JSONEncoder().encode([record.host: record])
        let migrated = PushNotifications(read: { $0 == "push-registrations-v1" ? data : nil }, write: { _, _ in }, registerForPush: {})
        migrated.attach(library)
        XCTAssertTrue(migrated.isEnabled(record.host))
        let wrongDevice = try JSONEncoder().encode([record.host: "old-device"])
        let repaired = PushNotifications(read: { $0 == "push-requested-devices-v1" ? wrongDevice : nil }, write: { _, _ in }, registerForPush: {})
        repaired.attach(library)
        XCTAssertFalse(repaired.isEnabled(record.host))
    }

    func testPushRetryBacksOffAndStaysBounded() {
        var retry = PushRetry()
        let now = Date(timeIntervalSince1970: 1000)
        for delay: TimeInterval in [15, 30, 60, 120, 240, 300, 300, 300] {
            retry.postpone(now: now)
            XCTAssertEqual(retry.nextAttempt.timeIntervalSince(now), delay)
        }
        XCTAssertEqual(retry.failures, 6)
        XCTAssertLessThan(PushRetry().nextAttempt, now)
    }

    @MainActor func testChatListStatusPrioritizesWorkAndUsesFreshState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: Self.cameraSavedConnection())
        func chat(_ state: String, unread: Bool = true) throws -> ChatSummary {
            try JSONDecoder().decode(ChatSummary.self, from: Data("""
            {"conversationId":"status","botId":"bot","title":"Bot","messageCount":1,"deliveryState":"\(state)","hasUnread":\(unread),"isArchived":false,"isPinned":false}
            """.utf8))
        }
        for state in ["accepted_by_wonder", "dispatching_to_codex", "accepted_by_codex", "streaming"] {
            XCTAssertEqual(model.chatListStatus(try chat(state)), .working)
        }
        XCTAssertEqual(model.chatListStatus(try chat("completed")), .unread)
        XCTAssertEqual(model.chatListStatus(try chat("completed", unread: false)), .read)
        for state in ["interrupted", "failed", "uncertain", "safe_to_retry"] {
            XCTAssertEqual(model.chatListStatus(try chat(state)), .unread)
        }
        func snapshot(_ status: String) throws -> ConversationSnapshot {
            try JSONDecoder().decode(ConversationSnapshot.self, from: Data("""
            {"conversationId":"status","hostEpoch":"epoch","lastSequence":1,"messages":[],"assistantMessages":[],"thread":{"hydrated":true,"turns":[{"id":"turn","status":"\(status)","items":[]}]}}
            """.utf8))
        }
        model.snapshots["status"] = try snapshot("completed")
        XCTAssertEqual(model.chatListStatus(try chat("streaming")), .unread)
        model.snapshots["status"] = try snapshot("inProgress")
        XCTAssertEqual(model.chatListStatus(try chat("interrupted")), .working)
        model.cachedConversationIds.insert("status")
        XCTAssertEqual(model.chatListStatus(try chat("completed", unread: false)), .read)
    }

    private func managedBot(_ id: String, avatar: String, archived: Bool = false) throws -> ManagedBot {
        let json = """
        {"id":"\(id)","name":"\(id)","role":"Test","systemPrompt":"","workspacePath":"/Bots/\(id)","permissionProfile":"bot-\(id)","permissionMode":"workspace","approvalMode":"ask-for-approval","model":"model","reasoningEffort":"medium","serviceTier":"default","isArchived":\(archived),"conversationId":"chat-\(id)","avatarColor":"#ffb51c","avatarShape":"sun","avatarPalette":"\(avatar)","workingDirectory":"/Workspace"}
        """
        return try JSONDecoder().decode(ManagedBot.self, from: Data(json.utf8))
    }

    func testManagedBotMutationAppliesAuthoritativeBotImmediately() throws {
        let old = try managedBot("ada", avatar: "amber")
        let saved = try managedBot("ada", avatar: "ocean")
        var state = ManagedBotListMutationState()

        let result = state.confirm(saved, current: [old])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.avatarPalette, "ocean")
    }

    func testManagedBotMutationProtectsConfirmedBotFromPreMutationRefresh() throws {
        let old = try managedBot("ada", avatar: "amber")
        let saved = try managedBot("ada", avatar: "ocean")
        var state = ManagedBotListMutationState()
        let snapshot = state.revision
        _ = state.confirm(saved, current: [old])

        let result = state.reconcile([old], startedAt: snapshot)

        XCTAssertEqual(result.first?.avatarPalette, "ocean")
    }

    func testManagedBotMutationAllowsPostMutationRefreshToReconcile() throws {
        let saved = try managedBot("ada", avatar: "ocean")
        let server = try managedBot("ada", avatar: "violet")
        var state = ManagedBotListMutationState()
        _ = state.confirm(saved, current: [])
        let snapshot = state.revision

        let result = state.reconcile([server], startedAt: snapshot)

        XCTAssertEqual(result.first?.avatarPalette, "violet")
        XCTAssertEqual(state.reconcile([saved], startedAt: snapshot).first?.avatarPalette, "ocean")
    }

    func testManagedBotMutationLeavesUnrelatedBotsFromRefreshUntouched() throws {
        let oldAda = try managedBot("ada", avatar: "amber")
        let savedAda = try managedBot("ada", avatar: "ocean")
        let refreshedLin = try managedBot("lin", avatar: "rose")
        var state = ManagedBotListMutationState()
        let snapshot = state.revision
        _ = state.confirm(savedAda, current: [oldAda])

        let result = state.reconcile([oldAda, refreshedLin], startedAt: snapshot)

        XCTAssertEqual(result.map(\.id), ["ada", "lin"])
        XCTAssertEqual(result.first?.avatarPalette, "ocean")
        XCTAssertEqual(result.last?.avatarPalette, "rose")
    }

    func testCodexUsageResponseDecodesTheHostContract() throws {
        let data = Data(#"{"checkedAtMs":1700000000000,"windows":[{"id":"five-hours","label":"5 hours","usedPercent":27,"remainingPercent":73,"windowDurationMins":300,"resetsAt":1700018000000},{"id":"weekly","label":"Weekly","usedPercent":41,"remainingPercent":59,"windowDurationMins":10080,"resetsAt":1700604800000}]}"#.utf8)
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        XCTAssertEqual(response.windows.map(\.label), ["5 hours", "Weekly"])
        XCTAssertEqual(response.windows.map(\.roundedRemainingPercent), [73, 59])
        XCTAssertEqual(response.windows[0].windowDurationMins, 300)
    }

    func testVisibleChatProjectionExcludesArchivedBotDirectChatsAndRestoresThem() throws {
        func summary(_ id: String, botID: String?) throws -> ChatSummary {
            let botValue = botID.map { "\"\($0)\"" } ?? "null"
            let json = """
            {"conversationId":"\(id)","botId":\(botValue),"title":"\(id)","lastMessagePreview":null,"lastMessageAt":null,"messageCount":0,"deliveryState":null,"hasUnread":false,"isArchived":false,"isPinned":false}
            """
            return try JSONDecoder().decode(ChatSummary.self, from: Data(json.utf8))
        }

        let remote = try [
            summary("archived-direct", botID: "archived-bot"),
            summary("active-direct", botID: "active-bot"),
            summary("botless-summary", botID: nil),
            summary("shared-group", botID: nil)
        ]
        let group = try JSONDecoder().decode(
            GroupRead.self,
            from: Data(#"{"id":"group-1","conversationId":"shared-group","name":"Shared","isArchived":false,"messages":[]}"#.utf8))

        let active = projectVisibleChatSummaries(remote: remote, groups: [group], activeBotIDs: ["active-bot"])
        XCTAssertEqual(active.map(\.id), ["active-direct", "botless-summary", "shared-group"])
        XCTAssertFalse(active.contains { $0.id == "archived-direct" })

        let restored = projectVisibleChatSummaries(
            remote: remote,
            groups: [group],
            activeBotIDs: ["active-bot", "archived-bot"])
        XCTAssertEqual(restored.map(\.id), ["archived-direct", "active-direct", "botless-summary", "shared-group"])
    }

    @MainActor func testScienceAvatarRenderedCatalog() throws {
        for scheme in [ColorScheme.light, .dark] {
            let gallery = HStack(alignment: .top, spacing: 16) {
                ForEach(ScienceAvatarCatalog.shapes) { shape in
                    VStack(spacing: 12) {
                        ScienceAvatar(shape: shape.rawValue, palette: "violet", size: 160)
                        Text(shape.title).font(.headline)
                        HStack(spacing: 12) {
                            ScienceAvatar(shape: shape.rawValue, palette: "violet", size: 32)
                            ScienceAvatar(shape: shape.rawValue, palette: "violet", size: 48)
                        }
                        ScienceAvatarGroup(shape: shape, palette: .resolve("violet"), size: 28)
                    }
                }
            }
            .padding(24)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: gallery)
            renderer.scale = 2
            let rendered = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThan(rendered.size.width, 1000)
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "Native SVG geometry - \(scheme) - Violet 160 32 48 and agents 28"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor func testScienceAvatarGeometryFitsSmallAndLargeSizesInLightAndDark() {
        for colorScheme in [ColorScheme.light, .dark] {
            for shape in ScienceAvatarCatalog.shapes {
                for size in [CGFloat(32), 48, 96] {
                    let view = ScienceAvatar(shape: shape.rawValue, palette: ScienceAvatarCatalog.defaultPalette, size: size)
                        .environment(\.colorScheme, colorScheme)
                    let host = UIHostingController(rootView: view)
                    host.loadViewIfNeeded()
                    let measured = host.sizeThatFits(in: CGSize(width: size, height: size))
                    XCTAssertLessThanOrEqual(measured.width, size + 0.5, "\(shape.title) exceeds \(size)pt in \(colorScheme)")
                    XCTAssertLessThanOrEqual(measured.height, size + 0.5, "\(shape.title) exceeds \(size)pt in \(colorScheme)")
                }
            }
        }
    }

    @MainActor func testScienceAvatarPickerContainsLargeTextWithoutHorizontalOverflow() {
        let view = ScienceAvatarPicker(shape: .constant(.sun), paletteID: .constant(ScienceAvatarCatalog.defaultPalette))
            .environment(\.dynamicTypeSize, .accessibility5)
        let host = UIHostingController(rootView: view)
        host.loadViewIfNeeded()
        let measured = host.sizeThatFits(in: CGSize(width: 390, height: 4000))
        XCTAssertLessThanOrEqual(measured.width, 390.5)
    }

    @MainActor func testScienceAvatarFallbacksAndMotionSemanticsAreDeterministic() {
        XCTAssertEqual(ScienceAvatarPresentation.shape(rawValue: nil, identity: "fixture-bot"), ScienceAvatarCatalog.stableShape(for: "fixture-bot"))
        XCTAssertEqual(ScienceAvatarPresentation.palette(rawValue: nil, legacyColor: "#3864A0").id, "ocean")
        XCTAssertEqual(ScienceAvatarPresentation.palette(rawValue: "not-a-palette", legacyColor: nil).id, ScienceAvatarCatalog.defaultPalette)
        XCTAssertEqual(ScienceAvatar.motionMode(for: .done, animate: true, reduceMotion: false), .finite)
        XCTAssertEqual(ScienceAvatar.motionMode(for: .working, animate: true, reduceMotion: false), .looping)
        XCTAssertEqual(ScienceAvatar.motionMode(for: .working, animate: true, reduceMotion: true), .static)
        XCTAssertEqual(ScienceAvatar.doneMotionDuration, 0.8, accuracy: 0.001)
        for state in ScienceAvatarMotionState.allCases {
            XCTAssertEqual(ScienceAvatar.motionTransform(for: state, active: true, reduceMotion: true, phase: true), .zero)
        }
        XCTAssertNotEqual(ScienceAvatar.motionTransform(for: .working, active: true, reduceMotion: false, phase: true), .zero)
    }

    func testScienceAvatarHeaderMotionReducerRequiresAnObservedActiveTurn() {
        var reducer = ScienceAvatarHeaderMotionReducer()
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.state, .idle)
        XCTAssertEqual(reducer.output.doneTrigger, 0)

        reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.state, .working)
        XCTAssertTrue(reducer.output.animate)
        XCTAssertEqual(reducer.output.doneTrigger, 0)

        reducer.reduce(
            activeTurnID: "turn-active",
            trackedTurnStatus: .inProgress,
            isPresented: true,
            reduceMotion: false,
            activeState: .thinking
        )
        XCTAssertEqual(reducer.output.state, .thinking)
    }

    func testScienceAvatarHeaderMotionReducerBouncesOnceForSuccessfulCompletion() {
        var reducer = ScienceAvatarHeaderMotionReducer()
        reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: true, reduceMotion: false)
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.state, .idle)
        XCTAssertEqual(reducer.output.doneTrigger, 1)

        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.doneTrigger, 1, "A replayed terminal snapshot must not replay the bounce")
    }

    func testScienceAvatarHeaderMotionReducerDoesNotBounceForFailedOrStoppedWork() {
        for status in [ScienceAvatarObservedTurnStatus.failed, .interrupted] {
            var reducer = ScienceAvatarHeaderMotionReducer()
            reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: true, reduceMotion: false)
            reducer.reduce(activeTurnID: nil, trackedTurnStatus: status, isPresented: true, reduceMotion: false)
            XCTAssertEqual(reducer.output.state, .idle)
            XCTAssertEqual(reducer.output.doneTrigger, 0)
        }
    }

    func testScienceAvatarHeaderMotionReducerDeduplicatesAReplayedTurnID() {
        var reducer = ScienceAvatarHeaderMotionReducer()
        reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: true, reduceMotion: false)
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.doneTrigger, 1)

        reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: true, reduceMotion: false)
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.doneTrigger, 1)
    }

    func testScienceAvatarHeaderMotionReducerDoesNotInferCompletionAcrossReconnect() {
        var reducer = ScienceAvatarHeaderMotionReducer()
        reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: true, reduceMotion: false)
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .unknown, isPresented: true, reduceMotion: false)
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.doneTrigger, 0)
    }

    func testScienceAvatarHeaderMotionReducerSuppressesMotionForReduceMotion() {
        var reducer = ScienceAvatarHeaderMotionReducer()
        reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: true, reduceMotion: true)
        XCTAssertEqual(reducer.output.state, .working)
        XCTAssertFalse(reducer.output.animate)
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: true)
        XCTAssertEqual(reducer.output.doneTrigger, 0)
    }

    func testScienceAvatarHeaderMotionReducerDefersDoneBounceWhileInactive() {
        var reducer = ScienceAvatarHeaderMotionReducer()
        reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: false, reduceMotion: false)
        XCTAssertFalse(reducer.output.animate)
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: false, reduceMotion: false)
        XCTAssertEqual(reducer.output.doneTrigger, 0)

        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.doneTrigger, 1)
    }

    func testScienceAvatarHeaderMotionReducerDefersDoneBounceWhileCovered() {
        var reducer = ScienceAvatarHeaderMotionReducer()
        reducer.reduce(activeTurnID: "turn-active", trackedTurnStatus: .inProgress, isPresented: false, reduceMotion: false)
        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: false, reduceMotion: false)
        XCTAssertEqual(reducer.output.doneTrigger, 0)
        XCTAssertFalse(reducer.output.animate)

        reducer.reduce(activeTurnID: nil, trackedTurnStatus: .completed, isPresented: true, reduceMotion: false)
        XCTAssertEqual(reducer.output.doneTrigger, 1)
    }

    func testBotAvatarPayloadUsesNamedIdentityAndPreservesUnrelatedFields() {
        let draft = [
            "name": "Renamed Bot",
            "role": "A useful Bot",
            "avatarColor": "#123456",
            "avatarShape": ScienceAvatarShape.atom.rawValue,
            "avatarPalette": "ocean",
            "_approvalChanged": "true"
        ]
        let payload = BotAvatarPayload.sanitized(draft)
        XCTAssertEqual(payload["name"], "Renamed Bot")
        XCTAssertEqual(payload["role"], "A useful Bot")
        XCTAssertEqual(payload["avatarShape"], "atom")
        XCTAssertEqual(payload["avatarPalette"], "ocean")
        XCTAssertNil(payload["avatarColor"])
        XCTAssertNil(payload["_approvalChanged"])

        let oldBot = BotAvatarPayload.sanitized(["name": "Old", "avatarColor": "#3864A0"])
        XCTAssertEqual(oldBot["name"], "Old")
        XCTAssertNil(oldBot["avatarShape"])
        XCTAssertNil(oldBot["avatarPalette"])

        let futureBot = BotAvatarPayload.sanitized(
            ["name": "Future", "avatarShape": "quasar", "avatarPalette": "ultraviolet"],
            avatarFields: []
        )
        XCTAssertEqual(futureBot["name"], "Future")
        XCTAssertNil(futureBot["avatarShape"])
        XCTAssertNil(futureBot["avatarPalette"])

        let shapeOnly = BotAvatarPayload.sanitized(
            ["name": "Future", "avatarShape": "luna", "avatarPalette": "ultraviolet"],
            avatarFields: ["avatarShape"]
        )
        XCTAssertEqual(shapeOnly["avatarShape"], "luna")
        XCTAssertNil(shapeOnly["avatarPalette"])
    }

    @MainActor func testImageCanvasKeepsItsHeightWhileLoadingAndOnFailure() {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for size in [CGSize(width: 600, height: 200), CGSize(width: 200, height: 600)] {
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in }
            for width in [280.0, 360.0] {
                for canvas in [ToolImageCanvas(image: nil, failed: false), ToolImageCanvas(image: image, failed: false), ToolImageCanvas(image: nil, failed: true)] {
                    let host = UIHostingController(rootView: canvas)
                    let measured = host.sizeThatFits(in: CGSize(width: width, height: 1000))
                    XCTAssertEqual(measured.height, 220, accuracy: 0.1)
                    XCTAssertEqual(measured.width, width, accuracy: 0.1)
                }
            }
        }
    }

    @MainActor func testThumbnailsDeduplicateCacheAndInvalidateRevisions() async throws {
        let data = Self.imageData()
        let probe = ImageLoadProbe(data: data)
        let cache = ToolImagePreviews()
        let scope = UUID()
        let original = try Self.imageRequest(scope: scope, data: data)
        async let first = cache.image(for: original) { try await probe.load() }
        async let second = cache.image(for: original) { try await probe.load() }
        let (a, b) = try await (first, second)
        XCTAssertTrue(a === b)
        _ = try await cache.image(for: original) { try await probe.load() }
        let initialCalls = await probe.calls; XCTAssertEqual(initialCalls, 1)

        for request in [try Self.imageRequest(scope: scope, data: data, revision: "changed"),
                        try Self.imageRequest(scope: UUID(), data: data)] {
            _ = try await cache.image(for: request) { try await probe.load() }
        }
        let removed = try Self.imageRequest(scope: scope, data: data, state: "removed")
        do {
            _ = try await cache.image(for: removed) {
                _ = try await probe.load()
                throw FileFailure.integrity
            }
            XCTFail("A removed file reused its old thumbnail")
        } catch FileFailure.integrity { }
        let revisedCalls = await probe.calls; XCTAssertEqual(revisedCalls, 4)
        cache.invalidate(); XCTAssertEqual(cache.cachedBytes, 0)
        _ = try await cache.image(for: original) { try await probe.load() }
        let reloadedCalls = await probe.calls; XCTAssertEqual(reloadedCalls, 5)
    }

    @MainActor func testThumbnailWorkIsBoundedAndCancelledConsumersDoNotReload() async throws {
        let data = Self.imageData()
        let probe = ImageLoadProbe(data: data, delay: .milliseconds(200))
        let cache = ToolImagePreviews(maximumBytes: 250_000)
        let scope = UUID()
        let requests = try (0..<8).map { try Self.imageRequest(scope: scope, data: data, revision: String($0)) }
        var tasks = requests.prefix(2).map { key in Task { try await cache.image(for: key) { try await probe.load() } } }
        while await probe.calls < 2 { await Task.yield() }
        tasks += requests.dropFirst(2).map { key in Task { try await cache.image(for: key) { try await probe.load() } } }
        // This request is queued behind the two active workers.
        tasks[7].cancel()
        for (index, task) in tasks.enumerated() {
            do { _ = try await task.value; XCTAssertNotEqual(index, 7) }
            catch is CancellationError { XCTAssertEqual(index, 7) }
        }
        let maximum = await probe.maximumActive; XCTAssertEqual(maximum, 2)
        let calls = await probe.calls; XCTAssertEqual(calls, 7)
        XCTAssertLessThanOrEqual(cache.cachedBytes, 250_000)
        // An evicted image must be loaded again, without retaining all history.
        _ = try await cache.image(for: requests[0]) { try await probe.load() }
        let afterEviction = await probe.calls; XCTAssertEqual(afterEviction, 8)

        let pending = Task { try await cache.image(for: requests[7]) { try await probe.load() } }
        while await probe.calls < 9 { await Task.yield() }
        cache.invalidate()
        do { _ = try await pending.value; XCTFail("Invalidated work returned a stale image") }
        catch is CancellationError { }
        XCTAssertEqual(cache.cachedBytes, 0)
        _ = try await cache.image(for: requests[7]) { try await probe.load() }
        let afterCancellation = await probe.calls; XCTAssertEqual(afterCancellation, 10)
        XCTAssertLessThanOrEqual(cache.cachedBytes, 250_000)
    }

    @MainActor private static func imageData() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240), format: format).pngData { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
        }
    }
    private static func imageRequest(scope: UUID, data: Data, revision: String = "original", state: String = "available") throws -> ToolImageRequest {
        let value: [String: Any] = ["id": "image", "name": "image.png", "mimeType": "image/png", "byteSize": data.count, "sha256": ConversationFile.digest(data), "state": state, "updatedAt": revision]
        let file = try JSONDecoder().decode(ConversationFile.self, from: JSONSerialization.data(withJSONObject: value))
        return ToolImageRequest(scope: scope, chatID: "chat", file: file)
    }
    @MainActor func testPresentedRowsInvalidateWhenLiveSourceChanges() throws {
        func group(_ text: String) throws -> GroupRead {
            let value:[String:Any] = ["id":"group","conversationId":"chat","name":"Test","isArchived":false,"members":[],"messages":[["messageId":"1","body":text,"createdAt":"1700000000000","authorKind":"user","presentationKind":"message"]]]
            return try JSONDecoder().decode(GroupRead.self,from:JSONSerialization.data(withJSONObject:value))
        }
        let model=ConnectionModel(); let original=try group("Before")
        model.groups=["chat":original]
        XCTAssertEqual(model.rows(for:original.summary).first?.text,"Before")
        XCTAssertEqual(model.rows(for:original.summary).first?.text,"Before")
        model.groups["chat"]=try group("After")
        XCTAssertEqual(model.rows(for:original.summary).first?.text,"After")
        model.groups=[:]
        XCTAssertTrue(model.rows(for:original.summary).isEmpty)
    }
    @MainActor func testTurnLifecycleKeepsPreTurnQueueStateSeparateFromCanonicalControls() throws {
        func snapshot(turns: [[String: Any]], messages: [[String: Any]]) throws -> ConversationSnapshot {
            let value: [String: Any] = [
                "conversationId": "chat", "hostEpoch": "epoch", "lastSequence": 1,
                "messages": messages, "assistantMessages": [],
                "thread": ["hydrated": true, "turns": turns]
            ]
            return try JSONDecoder().decode(ConversationSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let model = ConnectionModel(saved: nil, persistConnection: { _ in })
        let preTurn = try snapshot(turns: [], messages: [
            ["messageId": "accepted", "body": "accepted", "state": "accepted_by_wonder", "createdAt": "1000", "attachmentIds": []],
            ["messageId": "dispatching", "body": "dispatching", "state": "dispatching_to_codex", "createdAt": "1001", "attachmentIds": []]
        ])
        model.snapshots = ["chat": preTurn]
        XCTAssertTrue(model.botWorking("chat"))
        XCTAssertNil(model.activeTurn("chat"), "Pre-turn acceptance cannot be targeted by Guide or Stop")

        let turns: [[String: Any]] = [
            ["id": "old", "status": "inProgress", "createdAt": "2000", "updatedAt": "2000", "items": []],
            ["id": "canonical", "status": "inProgress", "createdAt": "3000", "updatedAt": "3000", "items": []]
        ]
        let active = try snapshot(turns: turns, messages: [
            ["messageId": "late", "body": "late", "state": "streaming", "codexTurnId": "old", "createdAt": "2000", "attachmentIds": []],
            ["messageId": "canonical-receipt", "body": "canonical", "state": "completed", "codexTurnId": "canonical", "createdAt": "3000", "attachmentIds": []]
        ])
        model.snapshots = ["chat": active]
        XCTAssertTrue(model.botWorking("chat"))
        XCTAssertEqual(model.activeTurn("chat"), "canonical")
    }

    @MainActor func testVisibleChildRefreshAndBackNavigationKeepTheRootSelected() async throws {
        DiagnosticSubagentFixture.resetTransport()
        let model = DiagnosticSubagentFixture.model()
        await model.loadChats(force: true)
        let parent = try XCTUnwrap(model.chats.first)
        await model.open(parent)
        let child = try XCTUnwrap(model.subagents[parent.id]?.first).chatSummary(botId: parent.botId)
        await model.open(child, root: parent)
        XCTAssertEqual(model.selectedChat?.id, parent.id)
        XCTAssertEqual(model.visibleChat?.id, child.id)
        let cameraContext = model.cameraContextID
        model.dismissConversation(parent)
        XCTAssertEqual(model.visibleChat?.id, child.id, "A late parent disappearance must not clear its child")

        DiagnosticSubagentFixture.resetTransport()
        DiagnosticSubagentFixture.updateChild(status: "inProgress")
        await model.loadChats(force: true)
        XCTAssertEqual(model.activeTurn(child.id), "fixture-child-turn")
        for suffix in ["", "/questions", "/queue"] {
            XCTAssertTrue(DiagnosticSubagentFixture.recordedPaths().contains("/api/v1/conversations/\(child.id)\(suffix)"))
        }
        DiagnosticSubagentFixture.updateChild(status: "completed")
        await model.loadChats(force: true)
        XCTAssertNil(model.activeTurn(child.id))
        XCTAssertEqual(model.selectedChat?.id, parent.id)

        model.presentConversation(parent)
        model.dismissConversation(child)
        XCTAssertEqual(model.visibleChat?.id, parent.id)
        XCTAssertNotEqual(model.cameraContextID, cameraContext)
        DiagnosticSubagentFixture.resetTransport()
        await model.loadChats(force: true)
        XCTAssertFalse(DiagnosticSubagentFixture.recordedPaths().contains("/api/v1/conversations/\(child.id)"))
        model.dismissConversation(parent)
        XCTAssertNil(model.visibleChat)
    }

    @MainActor func testCameraAttachesOnlyToTheVisibleVerifiedChild() async throws {
        DiagnosticSubagentFixture.resetTransport()
        let model = DiagnosticSubagentFixture.model()
        await model.loadChats(force: true)
        let parent = try XCTUnwrap(model.chats.first)
        await model.open(parent)
        let child = try XCTUnwrap(model.subagents[parent.id]?.first).chatSummary(botId: parent.botId)
        await model.open(child, root: parent)
        XCTAssertFalse(model.chats.contains { $0.id == child.id })
        let attached = await model.stageCameraPhoto(Self.cameraImageData(), chat: child, scope: model.assignmentScope)
        guard case .cancelled = attached else { return XCTFail("A read-only agent accepted a capture") }
        XCTAssertEqual(model.composers[child.id]?.attachmentCount, 0)
        XCTAssertEqual(model.composers[parent.id]?.attachmentCount, 0)
        model.presentConversation(parent)
        let cancelled = await model.stageCameraPhoto(Self.cameraImageData(), chat: child, scope: model.assignmentScope)
        guard case .cancelled = cancelled else { return XCTFail("An outgoing child accepted a capture") }
        XCTAssertEqual(model.composers[child.id]?.attachmentCount, 0)
    }

    @MainActor func testGroupPreparationFailureKeepsAttachmentOnlyDraftRetryable() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat) = try recoveryGroup(root: root)
        var intent = ComposerIntent(); intent.draftAttachmentIds = ["uploaded-file"]
        model.composers[chat.id] = intent
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/bot-options", status: 503)
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/bot-options", body: try recoveryOptions())

        await model.send(chat)
        XCTAssertNil(model.composerErrors[chat.id])
        XCTAssertNotNil(model.controlErrors[chat.id])
        XCTAssertTrue(model.canSend(chat))
        XCTAssertNil(model.composers[chat.id]?.pending)
        XCTAssertEqual(model.composers[chat.id]?.draftAttachmentIds, ["uploaded-file"])
        await model.send(chat)
        XCTAssertNil(model.controlErrors[chat.id])
        let request = try JSONDecoder().decode(SendRequest.self, from: XCTUnwrap(MessageRecoveryURLProtocol.bodies(path: "/api/v1/group-chats/group/messages").first))
        XCTAssertEqual(request.attachmentIds, ["uploaded-file"])
        XCTAssertEqual(request.body, "")
        XCTAssertNotNil(model.composers[chat.id]?.pending?.receipt)
    }

    @MainActor func testGroupPreparationRejectsOverlappingSendsAndPreservesClickedDraft() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat) = try recoveryGroup(root: root)
        model.editDraft("Original message", chat: chat.id)
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/bot-options", body: try recoveryOptions())
        MessageRecoveryURLProtocol.hold(path: "/api/v1/bot-options")
        let first = Task { @MainActor in await model.send(chat) }
        defer { MessageRecoveryURLProtocol.releaseHeld() }
        for _ in 0..<100 {
            if !MessageRecoveryURLProtocol.bodies(path: "/api/v1/bot-options", includingEmpty: true).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.preparingSends.contains(chat.id))
        XCTAssertFalse(model.canSend(chat))
        model.editDraft("Later edit", chat: chat.id)
        await model.send(chat)
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: "/api/v1/bot-options", includingEmpty: true).count, 1)
        MessageRecoveryURLProtocol.releaseHeld()
        await first.value
        let bodies = MessageRecoveryURLProtocol.bodies(path: "/api/v1/group-chats/group/messages")
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(SendRequest.self, from: XCTUnwrap(bodies.first)).body, "Original message")
        XCTAssertFalse(model.preparingSends.contains(chat.id))
    }

    @MainActor func testUnavailableGroupDefaultDoesNotBecomeADraftStorageError() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat) = try recoveryGroup(root: root)
        model.editDraft("Still here", chat: chat.id)
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/bot-options", body: Data(#"{"models":[],"approvalModes":[],"allowedApprovalPolicies":[]}"#.utf8))
        await model.send(chat)
        XCTAssertTrue(model.canSend(chat))
        XCTAssertNil(model.composerErrors[chat.id])
        XCTAssertNil(model.composers[chat.id]?.pending)
        XCTAssertEqual(model.composers[chat.id]?.draft, "Still here")
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/bot-options", body: try recoveryOptions())
        await model.send(chat)
        XCTAssertNotNil(model.composers[chat.id]?.pending?.receipt)
    }

    @MainActor func testAsyncReplyRejectsOversizedTextBeforePersistingOrSending() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = recoveryModel(root: root)
        let chat = try Self.cameraChat(id: "recovery-chat")
        let question = try recoveryQuestion()
        await model.replyAsync(question, chat: chat, answers: [String(repeating: "é", count: 4097)], skip: false)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/conversations/recovery-chat/questions/q").isEmpty)
        XCTAssertNil(try ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device").loadIntent(conversation: "async-reply-q"))
        XCTAssertNotNil(model.attentionErrors[question.id])
        XCTAssertFalse(model.retryableAsyncReplies.contains(question.id))
    }

    @MainActor func testDefinitivelyRejectedAsyncReplyCanBeCorrectedOrSkipped() async throws {
        for status in [400, 413] {
            for skip in [false, true] {
                MessageRecoveryURLProtocol.reset()
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let model = recoveryModel(root: root)
                let chat = try Self.cameraChat(id: "recovery-chat")
                let question = try recoveryQuestion()
                let store = ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
                let old = AsyncAnswerIntent(answers: [String(repeating: "a", count: 8193)], skip: false)
                try store.saveIntent(JSONEncoder().encode(old), conversation: "async-reply-q")
                model.saveAnswerDraft(["0": "Editable answer"], id: question.id)
                let path = "/api/v1/conversations/recovery-chat/questions/q"
                MessageRecoveryURLProtocol.enqueue(path: path, status: status)
                await model.replyAsync(question, chat: chat, answers: ["Ignored during exact retry"], skip: false)
                XCTAssertNil(try store.loadIntent(conversation: "async-reply-q"))
                XCTAssertFalse(model.retryableAsyncReplies.contains(question.id))
                XCTAssertEqual(model.answerDraft(question.id), ["0": "Editable answer"])
                MessageRecoveryURLProtocol.enqueue(path: path, status: 204)
                await model.replyAsync(question, chat: chat, answers: skip ? [] : ["Corrected answer"], skip: skip)
                let bodies = MessageRecoveryURLProtocol.bodies(path: path)
                XCTAssertEqual(bodies.count, 2)
                let retried = try JSONDecoder().decode(AsyncAnswerIntent.self, from: XCTUnwrap(bodies.last))
                XCTAssertEqual(retried.skip, skip)
                XCTAssertEqual(retried.answers, skip ? [] : ["Corrected answer"])
                XCTAssertNil(model.attentionErrors[question.id])
            }
        }
    }

    @MainActor func testAmbiguousAsyncReplyRetainsExactSavedPayloadAcrossRestart() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try Self.cameraChat(id: "recovery-chat")
        let question = try recoveryQuestion()
        let path = "/api/v1/conversations/recovery-chat/questions/q"
        MessageRecoveryURLProtocol.fail(path: path, error: .timedOut)
        await recoveryModel(root: root).replyAsync(question, chat: chat, answers: ["Original answer"], skip: false)
        MessageRecoveryURLProtocol.enqueue(path: path, status: 204)
        await recoveryModel(root: root).replyAsync(question, chat: chat, answers: [], skip: true)
        let bodies = MessageRecoveryURLProtocol.bodies(path: path)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.first, bodies.last, "An ambiguous reply must not silently become Skip")
    }

    @MainActor private func recoveryModel(root: URL) -> ConnectionModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MessageRecoveryURLProtocol.self]
        return ConnectionModel(cameraFixtureStoreRoot: root, saved: Self.cameraSavedConnection(),
            api: PairingAPI(configuration: configuration), replayEnabled: false)
    }

    @MainActor private func recoveryGroup(root: URL) throws -> (ConnectionModel, ChatSummary) {
        let group = try JSONDecoder().decode(GroupRead.self, from: Data(#"{"id":"group","conversationId":"recovery-chat","name":"Group","isArchived":false,"messages":[],"attachmentsSupported":true,"collaboration":{"configuration":{"instructions":"","routing":{"model":"","reasoningEffort":""},"workspace":"/fixture","needsPurpose":false},"runs":[]}}"#.utf8))
        let model = recoveryModel(root: root)
        model.groups[group.conversationId] = group
        model.chats = [group.summary]
        return (model, group.summary)
    }

    private func recoveryOptions() throws -> Data {
        let defaults = ModelDefaultPurpose.groupParticipation.load()
        return try JSONSerialization.data(withJSONObject: [
            "models": [["id": defaults.model.isEmpty ? "fixture-model" : defaults.model, "displayName": "Fixture", "hidden": false,
                "reasoningEfforts": [["id": defaults.reasoningEffort, "label": "Fixture"]],
                "serviceTiers": [["id": defaults.serviceTier ?? "default", "label": "Fixture"]]]],
            "approvalModes": [["id": defaults.approvalMode.rawValue, "allowed": true]],
            "allowedApprovalPolicies": []
        ])
    }

    private func recoveryQuestion() throws -> AsyncQuestion {
        try JSONDecoder().decode(AsyncQuestion.self, from: Data(#"{"id":"q","conversationId":"recovery-chat","turnId":"turn","itemId":"item","questions":[{"title":"Question?"}],"state":"pending","expiresAtMs":9999999999999}"#.utf8))
    }

    @MainActor func testSubagentSheetReadsExactChildAndRejectsDirectSend() async throws {
        DiagnosticSubagentFixture.resetTransport()
        let model = DiagnosticSubagentFixture.model()
        await model.loadChats(force: true)
        let parent = try XCTUnwrap(model.chats.first(where: { $0.id == DiagnosticSubagentFixture.parentID }))
        await model.open(parent)
        let child = try XCTUnwrap(model.subagents[parent.id]?.first)
        XCTAssertEqual(child.threadId, DiagnosticSubagentFixture.childThreadID)
        XCTAssertFalse(model.subagents[parent.id, default: []].contains { $0.threadId == DiagnosticSubagentFixture.ordinaryTaskThreadID })
        let unavailable = try XCTUnwrap(model.subagents[parent.id]?.first { $0.id == DiagnosticSubagentFixture.unavailableChildID })
        XCTAssertEqual(unavailable.canAcceptDirectInput, false)
        XCTAssertTrue(unavailable.isArchived)

        let childChat = child.chatSummary(botId: parent.botId)
        await model.open(childChat, root: parent)
        var intent = ComposerIntent()
        intent.draft = "Direct child message"
        model.composers[childChat.id] = intent
        await model.send(childChat)

        let paths = DiagnosticSubagentFixture.recordedPaths()
        XCTAssertTrue(paths.contains("/api/v1/conversations/\(DiagnosticSubagentFixture.childID)"))
        XCTAssertFalse(paths.contains("/api/v1/conversations/\(DiagnosticSubagentFixture.childID)/messages"))
        XCTAssertEqual(model.composers[childChat.id]?.draft, "Direct child message")
        XCTAssertFalse(model.canSend(childChat))
        XCTAssertFalse(model.canGuide(childChat))
        XCTAssertFalse(paths.contains("/api/v1/conversations/\(DiagnosticSubagentFixture.parentID)/messages"))
    }

    @MainActor func testSavedChildPendingIntentNeverResumesAfterOpeningOrRefresh() async throws {
        DiagnosticSubagentFixture.resetTransport()
        let model = DiagnosticSubagentFixture.model()
        await model.loadChats(force: true)
        let parent = try XCTUnwrap(model.chats.first(where: { $0.id == DiagnosticSubagentFixture.parentID }))
        await model.open(parent)
        let child = try XCTUnwrap(model.subagents[parent.id]?.first).chatSummary(botId: parent.botId)
        await model.open(child, root: parent, readOnly: true)
        model.editDraft("Saved child intent", chat: child.id)
        var intent = try XCTUnwrap(model.composers[child.id])
        try intent.begin(device: try XCTUnwrap(model.connection?.credential.deviceId))
        model.composers[child.id] = intent
        await model.open(parent)
        await model.open(child, root: parent, readOnly: true)
        await model.loadChats(force: true)
        await model.deliver(child)
        await model.stop(child)
        XCTAssertEqual(model.composers[child.id]?.pending?.request.body, "Saved child intent")
        XCTAssertTrue(DiagnosticSubagentFixture.recordedMessagePaths().isEmpty)
        XCTAssertFalse(DiagnosticSubagentFixture.recordedPaths().contains { $0.hasSuffix("/interrupt") })
        XCTAssertEqual(model.selectedChat?.id, parent.id)
    }

    @MainActor func testLargeImagePreviewIsDownsampledAndMalformedDataIsRejected() async throws {
        let data=try autoreleasepool {
            let format=UIGraphicsImageRendererFormat(); format.scale=1
            return try XCTUnwrap(UIGraphicsImageRenderer(size:CGSize(width:4000,height:3000),format:format).image { context in
                UIColor.systemBlue.setFill(); context.fill(CGRect(x:0,y:0,width:4000,height:3000))
            }.jpegData(compressionQuality: 0.5))
        }
        let decoded=await Task.detached { ToolPreviewImage.decode(data) }.value
        let image=try XCTUnwrap(decoded)
        XCTAssertEqual(image.size.width,1080); XCTAssertEqual(image.size.height,810)
        XCTAssertNil(ToolPreviewImage.decode(Data("invalid".utf8)))
    }

    @MainActor func testPhotoViewerRoutingDecodeBoundsOrientationAndDocumentSeparation() async throws {
        let data = try autoreleasepool {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format).image { context in
                UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
            }
            let output = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
            guard let cgImage = image.cgImage else { throw FileFailure.unsupported }
            CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyOrientation: 6] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return output as Data
        }

        let decodedImage = await Task.detached { PhotoViewerImage.decode(data) }.value
        let decoded = try XCTUnwrap(decodedImage)
        XCTAssertEqual(decoded.size.width, 3000, accuracy: 1)
        XCTAssertEqual(decoded.size.height, 4000, accuracy: 1)
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 4096)
        XCTAssertNil(PhotoViewerImage.decode(Data("malformed".utf8)))

        let imageFile = try Self.makeFile(id: "photo", name: "photo.png", mime: "image/png", data: Self.imageData())
        let documentFile = try Self.makeFile(id: "document", name: "notes.txt", mime: "text/plain", data: Data("notes".utf8))
        XCTAssertTrue(PhotoViewerRouting.isImage(imageFile))
        XCTAssertFalse(PhotoViewerRouting.isImage(documentFile))
        XCTAssertFalse(PhotoViewerRouting.isImage(mimeType: "application/pdf"))
    }

    @MainActor func testConversationAttachmentGalleryPreservesMessageOrderAndExcludesDocuments() throws {
        let first = try Self.makeFile(id: "first", name: "first.png", mime: "image/png", data: Self.imageData())
        let document = try Self.makeFile(id: "notes", name: "notes.txt", mime: "text/plain", data: Data("notes".utf8))
        let second = try Self.makeFile(id: "second", name: "second.png", mime: "image/png", data: Self.imageData())

        let gallery = ConversationAttachmentGallery.imageFiles(
            [first, document, second],
            attachmentIDs: ["second", "notes", "first"]
        )

        XCTAssertEqual(gallery.map(\.id), ["second", "first"])
        XCTAssertTrue(gallery.allSatisfy(PhotoViewerRouting.isImage))
        XCTAssertEqual(ConversationAttachmentGallery.imageFiles([first, document]).map(\.id), ["first"])
    }

    @MainActor func testWorkspaceBrowserFixturesKeepRootsViewsAndPreviewRoutesTyped() throws {
        let response = WorkspaceRootsResponse(
            available: true,
            detail: nil,
            roots: [WorkspaceRoot(id: "workspace", label: "Workspace", path: "/preview", isDirectory: true, kind: "workingDirectory", readOnly: true)],
            attachments: [try Self.makeFile(id: "photo", name: "photo.png", mime: "image/png", data: Self.imageData())]
        )
        let encoded = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(WorkspaceRootsResponse.self, from: encoded)
        XCTAssertEqual(decoded.roots.first?.kind, "workingDirectory")
        XCTAssertTrue(decoded.roots.first?.readOnly == true)

        let page = WorkspaceDirectoryPage(
            rootId: "workspace", path: "", parentPath: nil,
            entries: [WorkspaceEntry(name: "notes.txt", path: "notes.txt", isDirectory: false, byteSize: 5, mimeType: "text/plain")],
            nextOffset: 200
        )
        XCTAssertEqual(page.entries.first?.id, "notes.txt")
        XCTAssertEqual(page.nextOffset, 200)
        let change = WorkspaceGitChange(path: "notes.txt", originalPath: nil, state: "unstaged", indexStatus: " ", worktreeStatus: "M")
        XCTAssertEqual(change.id, "notes.txt:unstaged")
        XCTAssertTrue(PhotoViewerRouting.isImage(decoded.attachments[0]))
    }

    @MainActor func testWorkspaceEndpointEncodesConversationSegmentExactlyOnce() {
        let conversationID = "550e8400-e29b-41d4-a716-446655440000/child"
        let endpoint = ConnectionModel.workspaceEndpoint(conversationID: conversationID, operation: "git/diff")
        XCTAssertEqual(
            endpoint,
            "/api/v1/conversations/550e8400%2De29b%2D41d4%2Da716%2D446655440000%2Fchild/workspace/git/diff"
        )
        XCTAssertFalse(endpoint?.contains("%252D") == true)
        XCTAssertFalse(endpoint?.contains("%252F") == true)
    }

    private static func makeFile(id: String, name: String, mime: String, data: Data) throws -> ConversationFile {
        let value: [String: Any] = [
            "id": id, "name": name, "mimeType": mime, "byteSize": data.count,
            "sha256": ConversationFile.digest(data), "state": "available", "updatedAt": "test"
        ]
        return try JSONDecoder().decode(ConversationFile.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @MainActor func testCameraIgnoresDelayedSessionNotificationsAfterStop() {
        let camera = CameraCaptureController(fixture: .ready(data: Data(), preview: UIImage()))
        camera.start { _ in XCTFail("A stopped camera must not deliver a photo") }
        XCTAssertEqual(camera.state, .ready)
        camera.stop()
        camera.runtimeError()
        camera.retry()
        XCTAssertEqual(camera.state, .checking)
    }

    @MainActor func testCameraStageNormalizesOrientationAndSurvivesModelRestart() async throws {
        let input = try Self.orientedCameraImageData()
        let prepared = try await CameraPhotoPreparation.prepare(input)
        XCTAssertEqual(prepared.mimeType, "image/jpeg")
        guard let source = CGImageSourceCreateWithData(prepared.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return XCTFail("Prepared camera data was not readable")
        }
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 960)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 720)
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 1)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wonder-camera-restart-\(UUID().uuidString)", isDirectory: true)
        let saved = Self.cameraSavedConnection()
        let chat = try Self.cameraChat(id: "camera-restart")
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: saved, chat: chat)
        let scope = model.assignmentScope
        let result = await model.stageCameraPhoto(input, chat: chat, scope: scope)
        guard case .attached = result else { return XCTFail("Camera photo was not staged") }
        XCTAssertEqual(model.composers[chat.id]?.attachmentIDs.count, 1)
        XCTAssertNil(model.composers[chat.id]?.pending)

        let restarted = ConnectionModel(cameraFixtureStoreRoot: root, saved: saved, chat: chat)
        XCTAssertEqual(restarted.selectedChat?.id, chat.id)
        XCTAssertEqual(restarted.composers[chat.id]?.attachmentIDs, model.composers[chat.id]?.attachmentIDs)
        XCTAssertNil(restarted.composers[chat.id]?.pending)
    }

    @MainActor func testCameraStageIgnoresDifferentSelectedChatAndScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wonder-camera-context-\(UUID().uuidString)", isDirectory: true)
        let saved = Self.cameraSavedConnection()
        let chat = try Self.cameraChat(id: "camera-origin")
        let other = try Self.cameraChat(id: "camera-other")
        var initial = ComposerIntent()
        let existing = try StagedFile(id: "existing-camera", name: "Existing.jpg", mimeType: "image/jpeg", data: Self.cameraImageData())
        initial.stagedFiles = [existing]
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: saved, chat: chat, initialIntent: initial)
        let input = Self.cameraImageData()
        let scope = model.assignmentScope

        model.selectedChat = other
        let differentChat = await model.stageCameraPhoto(input, chat: chat, scope: scope)
        guard case .cancelled = differentChat else { return XCTFail("A changed selected chat accepted a stale capture") }
        XCTAssertEqual(model.composers[chat.id]?.attachmentIDs, ["existing-camera"])

        model.selectedChat = chat
        let differentScope = await model.stageCameraPhoto(input, chat: chat, scope: "other-host:other-device")
        guard case .cancelled = differentScope else { return XCTFail("A changed assignment scope accepted a stale capture") }
        XCTAssertEqual(model.composers[chat.id]?.attachmentIDs, ["existing-camera"])
        XCTAssertNil(model.composers[chat.id]?.pending)
    }

    @MainActor func testCameraStageRejectsFourthAttachmentWithoutChangingDurableDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wonder-camera-limit-\(UUID().uuidString)", isDirectory: true)
        let saved = Self.cameraSavedConnection()
        let chat = try Self.cameraChat(id: "camera-limit")
        var initial = ComposerIntent()
        initial.stagedFiles = try (0..<4).map { index in
            try StagedFile(id: "existing-camera-\(index)", name: "Existing \(index).jpg", mimeType: "image/jpeg", data: Self.cameraImageData())
        }
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: saved, chat: chat, initialIntent: initial)
        let result = await model.stageCameraPhoto(Self.cameraImageData(), chat: chat, scope: model.assignmentScope)
        guard case .cancelled = result else { return XCTFail("Camera accepted a fifth attachment") }
        XCTAssertEqual(model.composers[chat.id]?.attachmentCount, 4)
        XCTAssertEqual(model.composers[chat.id]?.attachmentIDs, initial.attachmentIDs)
        XCTAssertNil(model.composers[chat.id]?.pending)

        let restarted = ConnectionModel(cameraFixtureStoreRoot: root, saved: saved, chat: chat)
        XCTAssertEqual(restarted.composers[chat.id]?.attachmentIDs, initial.attachmentIDs)
        XCTAssertNil(restarted.composers[chat.id]?.pending)
    }

    @MainActor func testImagePastePreservesPNGTextAndExistingAttachmentsAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try Self.cameraChat(id: "paste")
        var initial = ComposerIntent(); initial.draft = "Keep this draft."
        initial.stagedFiles = [try StagedFile(name: "notes.txt", mimeType: "text/plain", data: Data("Notes".utf8))]
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: Self.cameraSavedConnection(), chat: chat, initialIntent: initial)
        let png = try XCTUnwrap(UIImage(data: Self.cameraImageData())?.pngData())
        let providers = [NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier),
                         NSItemProvider(item: Self.cameraImageData() as NSData, typeIdentifier: UTType.jpeg.identifier)]
        await model.stagePastedImages(providers, chat: chat, scope: model.assignmentScope)
        XCTAssertNil(model.controlErrors[chat.id])
        let restarted = ConnectionModel(cameraFixtureStoreRoot: root, saved: Self.cameraSavedConnection(), chat: chat)
        let intent = try XCTUnwrap(restarted.composers[chat.id])
        XCTAssertEqual(intent.draft, initial.draft)
        XCTAssertEqual(intent.stagedFiles?.map(\.mimeType), ["text/plain", "image/png", "image/jpeg"])
        XCTAssertEqual(intent.stagedFiles?[1].data, png)
        XCTAssertNil(intent.pending)
        XCTAssertTrue(intent.stagedFiles?.allSatisfy { $0.uploaded == nil } == true)
        restarted.removeStaged(intent.stagedFiles![1].id, chat: chat.id)
        XCTAssertEqual(restarted.composers[chat.id]?.attachmentCount, 2)
        XCTAssertEqual(restarted.composers[chat.id]?.draft, initial.draft)
    }

    @MainActor func testImagePasteRejectsInvalidOversizedAndExcessImagesAtomically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try Self.cameraChat(id: "paste-limits")
        var initial = ComposerIntent(); initial.draft = "Preserved"
        initial.stagedFiles = [try StagedFile(name: "notes.txt", mimeType: "text/plain", data: Data("Notes".utf8))]
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: Self.cameraSavedConnection(), chat: chat, initialIntent: initial)
        let valid = NSItemProvider(item: Self.cameraImageData() as NSData, typeIdentifier: UTType.jpeg.identifier)
        for providers in [
            [valid, NSItemProvider(item: Data("not an image".utf8) as NSData, typeIdentifier: UTType.png.identifier)],
            [NSItemProvider(item: Data(count: 8 * 1024 * 1024 + 1) as NSData, typeIdentifier: UTType.png.identifier)],
            [valid, valid, valid, valid]
        ] {
            await model.stagePastedImages(providers, chat: chat, scope: model.assignmentScope)
            XCTAssertEqual(model.composers[chat.id]?.attachmentIDs, initial.attachmentIDs)
            XCTAssertEqual(model.composers[chat.id]?.draft, initial.draft)
            XCTAssertNotNil(model.controlErrors[chat.id])
            XCTAssertFalse(model.loadingPhotos.contains(chat.id))
        }
    }

    @MainActor func testImagePasteIgnoresNavigationAndCancellationDuringProviderLoad() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try Self.cameraChat(id: "paste-delayed")
        let other = try Self.cameraChat(id: "other")
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: Self.cameraSavedConnection(), chat: chat)
        let data = Self.cameraImageData()
        for cancel in [false, true] {
            model.selectedChat = chat
            let started = expectation(description: "Provider began")
            let delivery = DelayedPasteDelivery()
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
                delivery.set(completion)
                started.fulfill()
                return nil
            }
            let task = Task { await model.stagePastedImages([provider], chat: chat, scope: model.assignmentScope) }
            await fulfillment(of: [started], timeout: 5)
            if cancel { task.cancel() } else { model.selectedChat = other }
            delivery.complete(data)
            await task.value
            XCTAssertEqual(model.composers[chat.id]?.attachmentCount, 0)
            XCTAssertNil(model.controlErrors[chat.id])
            XCTAssertFalse(model.loadingPhotos.contains(chat.id))
        }
    }

    @MainActor func testImagePasteUsesSystemActionAndLeavesSelectionAndTextUnchanged() async throws {
        let original = UIPasteboard.general.items
        defer { UIPasteboard.general.items = original }
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.text = "Keep selected text"; view.selectedRange = NSRange(location: 5, length: 8)
        view.canPasteImages = true
        var received = 0
        view.pasteImages = { received += $0.count }
        UIPasteboard.general.items = [[UTType.png.identifier: try XCTUnwrap(UIImage(data: Self.cameraImageData())?.pngData())]]
        XCTAssertTrue(view.canPerformAction(#selector(view.paste(_:)), withSender: nil))
        view.paste(nil)
        XCTAssertEqual(received, 1)
        XCTAssertEqual(view.text, "Keep selected text")
        XCTAssertEqual(view.selectedRange, NSRange(location: 5, length: 8))
        view.canPasteImages = false
        XCTAssertFalse(view.canPerformAction(#selector(view.paste(_:)), withSender: nil))
        view.paste(nil)
        XCTAssertEqual(received, 1)
        UIPasteboard.general.string = "ordinary"
        view.paste(nil)
        let textPasted = expectation(for: NSPredicate { _, _ in view.text == "Keep ordinary text" }, evaluatedWith: nil)
        await fulfillment(of: [textPasted], timeout: 3)
    }

    @MainActor private static func cameraImageData() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 720, height: 960), format: format).jpegData(withCompressionQuality: 0.82) { context in
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 720, height: 960))
            UIColor.white.setFill(); context.fill(CGRect(x: 120, y: 170, width: 480, height: 620))
        }
    }

    @MainActor private static func orientedCameraImageData() throws -> Data {
        let image = try XCTUnwrap(UIImage(data: cameraImageData())?.cgImage)
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func cameraSavedConnection() -> SavedConnection {
        let value: [String: Any] = ["origin": "https://camera-unit.invalid", "credential": [
            "sessionToken": "camera-unit-session", "deviceId": "camera-unit-device", "csrfToken": "camera-unit-csrf",
            "hostInstallationId": "camera-unit-host"
        ]]
        return try! JSONDecoder().decode(SavedConnection.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private static func cameraChat(id: String) throws -> ChatSummary {
        let value: [String: Any] = ["conversationId": id, "botId": "camera-unit-bot", "title": id,
                                     "messageCount": 0, "hasUnread": false, "isArchived": false, "isPinned": false]
        return try JSONDecoder().decode(ChatSummary.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @MainActor func testBackgroundSuspendsDetailedCapture() {
        let recorder=Diagnostics.shared; let previous=recorder.recording
        recorder.recording=true; recorder.setActive(true); recorder.startCapture()
        XCTAssertTrue(recorder.capturing)
        recorder.setActive(false)
        XCTAssertFalse(recorder.capturing)
        recorder.startCapture()
        XCTAssertFalse(recorder.capturing)
        recorder.setActive(true); recorder.recording=previous
    }
    func testReportsStayAssignedToTheirSelectedMac() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal=DiagnosticJournal(root:root); let first=UUID().uuidString; let second=UUID().uuidString
        journal.selectHost(first); journal.record(DiagnosticEvent(operation:"capture",phase:"start"))
        journal.selectHost(second); journal.record(DiagnosticEvent(operation:"system.hang",durationMs:10))
        let a=await journal.pending(host:first); let b=await journal.pending(host:second)
        XCTAssertEqual(a.count,1); XCTAssertEqual(b.count,1)
        XCTAssertTrue(String(decoding:a[0].1,as:UTF8.self).contains("capture"))
        XCTAssertFalse(String(decoding:a[0].1,as:UTF8.self).contains("system.hang"))
    }
    func testJournalRetriesUntilAcknowledgedAndExportsSentBatches() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal=DiagnosticJournal(root:root); let host=UUID().uuidString
        journal.selectHost(host)
        journal.record(DiagnosticEvent(operation:"activity.expand",durationMs:10))
        let first=await journal.pending(host:host)
        XCTAssertEqual(first.count,1)
        let retry=await journal.pending(host:host)
        XCTAssertEqual(first.first?.1,retry.first?.1)
        journal.acknowledge(first[0].0)
        let pending=await journal.pending(host:host); XCTAssertTrue(pending.isEmpty)
        let exported=try await journal.export()
        let values=try JSONSerialization.jsonObject(with:Data(contentsOf:exported)) as? [[String:Any]]
        XCTAssertEqual(values?.count,1)
        XCTAssertFalse(String(data:try Data(contentsOf:exported),encoding:.utf8)!.contains(host))
    }
    func testRetentionAndStorageBudget() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host=UUID().uuidString
        let journal=DiagnosticJournal(root:root,maximumBytes:1024,retention:10)
        journal.selectHost(host)
        journal.record(DiagnosticEvent(operation:"history.load",durationMs:1))
        let initial=await journal.pending(host:host)
        XCTAssertFalse(initial.isEmpty)
        try FileManager.default.setAttributes([.modificationDate:Date.distantPast],ofItemAtPath:initial[0].0.path)
        let expired=await journal.pending(host:host)
        XCTAssertTrue(expired.isEmpty)
        for _ in 0..<3 {
            journal.record(DiagnosticEvent(operation:"activity.expand",durationMs:1))
            _=await journal.pending(host:host)
        }
        let retained=await journal.pending(host:host)
        XCTAssertLessThanOrEqual(retained.reduce(0) { $0+$1.1.count },1024)
    }

    @MainActor func testComputerControlGeometryUsesAspectFitAndZoomWithoutLeakingOutOfBounds() {
        let session = ComputerSession(
            id: "session", clientRequestId: "request", ownerDeviceId: "phone", hostInstallationId: "mac",
            conversationId: "chat", generation: 2, state: .live,
            source: ComputerSource(id: "display:1", name: "Main display", kind: "display", width: 1920, height: 1080, scale: 2),
            geometryRevision: 3, failureReason: nil, createdAt: "now", updatedAt: "now", lastStateAt: "now",
            endedAt: nil, capability: ComputerCapability(available: true, action: "none", reason: "Live"),
            control: ComputerControlCapability(available: true, action: "none", reason: "Active")
        )

        XCTAssertEqual(ComputerSessionModel.sourceAspectRatio(session), 16.0 / 9.0, accuracy: 0.001)
        let center = ComputerSessionModel.normalizedPoint(
            location: CGPoint(x: 200, y: 100), in: CGSize(width: 400, height: 200), session: session, zoomScale: 1
        )
        XCTAssertEqual(center?.x ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(center?.y ?? -1, 0.5, accuracy: 0.001)

        let letterbox = ComputerSessionModel.normalizedPoint(
            location: CGPoint(x: 0, y: 100), in: CGSize(width: 400, height: 200), session: session, zoomScale: 1
        )
        XCTAssertNil(letterbox)

        let zoomed = ComputerSessionModel.normalizedPoint(
            location: CGPoint(x: 200, y: 100), in: CGSize(width: 400, height: 200), session: session, zoomScale: 2
        )
        XCTAssertEqual(zoomed?.x ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(zoomed?.y ?? -1, 0.5, accuracy: 0.001)
        let clamped = ComputerSessionModel.normalizedPoint(
            location: CGPoint(x: -20, y: 100),
            in: CGSize(width: 400, height: 200),
            session: session,
            zoomScale: 1,
            clampToContent: true
        )
        XCTAssertEqual(clamped?.x ?? -1, 0, accuracy: 0.001)
        XCTAssertTrue([ComputerControlState.viewOnly, .starting, .active].map(\.title).contains("Starting control…"))
    }

    @MainActor func testComputerKeyboardCommitsCompositionWithoutDuplicatingMarkedText() {
        var input = ComputerKeyboardComposition()
        XCTAssertEqual(input.update("ni", hasMarkedText: true), [])
        XCTAssertEqual(input.update("你", hasMarkedText: true), [])
        XCTAssertEqual(input.update("你", hasMarkedText: false), [.text("你")])
        XCTAssertEqual(input.update("你", hasMarkedText: false), [])
        XCTAssertEqual(input.update("你好", hasMarkedText: false), [.text("好")])
        XCTAssertEqual(input.update("你", hasMarkedText: false), [.key(key: "delete", phase: "press", modifiers: 0)])
        input.reset()
        XCTAssertEqual(input.update("👨‍👩‍👧‍👦", hasMarkedText: false), [.text("👨‍👩‍👧‍👦")])
        XCTAssertEqual(input.update("", hasMarkedText: false), [.key(key: "delete", phase: "press", modifiers: 0)])
    }

    @MainActor func testComputerKeyboardReturnAndTabAreKeysAndContextIsBounded() {
        var input = ComputerKeyboardComposition()
        XCTAssertEqual(input.update("hello\n\t", hasMarkedText: false), [
            .text("hello"), .key(key: "return", phase: "press", modifiers: 0),
            .key(key: "tab", phase: "press", modifiers: 0)
        ])
        input.reset()
        XCTAssertEqual(input.update(String(repeating: "a", count: 200), hasMarkedText: false), [.text(String(repeating: "a", count: 200))])
        XCTAssertEqual(input.committed.count, 128)
        XCTAssertEqual(input.update(input.committed + "b", hasMarkedText: false), [.text("b")])
        let combining = String(repeating: "e\u{301}", count: 2_100)
        input.reset()
        let chunks = input.update(combining, hasMarkedText: false)
        XCTAssertTrue(chunks.allSatisfy { if case .text(let value) = $0 { return value.unicodeScalars.count <= 4_096 }; return false })
        XCTAssertEqual(chunks.compactMap { if case .text(let value) = $0 { return value }; return nil }.joined(), combining)
    }

    @MainActor func testComputerInputBufferCoalescesMotionWithoutCrossingClicksOrDragBoundaries() {
        var buffer = ComputerInputBuffer()
        XCTAssertTrue(buffer.append([.pointer(x: 0.1, y: 0.2, phase: "move", button: nil)]))
        XCTAssertTrue(buffer.append([.pointer(x: 0.2, y: 0.3, phase: "move", button: nil)]))
        XCTAssertTrue(buffer.append([.pointer(x: 0.2, y: 0.3, phase: "down", button: "left")]))
        XCTAssertTrue(buffer.append([.pointer(x: 0.3, y: 0.4, phase: "move", button: "left")]))
        XCTAssertTrue(buffer.append([.pointer(x: 0.4, y: 0.5, phase: "move", button: "left")]))
        XCTAssertTrue(buffer.append([.pointer(x: 0.4, y: 0.5, phase: "up", button: "left")]))
        XCTAssertEqual(buffer.popFirst(), [.pointer(x: 0.2, y: 0.3, phase: "move", button: nil)])
        XCTAssertEqual(buffer.popFirst(), [.pointer(x: 0.2, y: 0.3, phase: "down", button: "left")])
        XCTAssertEqual(buffer.popFirst(), [.pointer(x: 0.4, y: 0.5, phase: "move", button: "left")])
        XCTAssertEqual(buffer.popFirst(), [.pointer(x: 0.4, y: 0.5, phase: "up", button: "left")])
        XCTAssertNil(buffer.popFirst())
        XCTAssertTrue(buffer.append([.text("hello")]))
        XCTAssertTrue(buffer.append([.text(" world")]))
        XCTAssertTrue(buffer.append([.key(key: "return", phase: "press", modifiers: 0)]))
        XCTAssertTrue(buffer.append([.text("next line")]))
        XCTAssertEqual(buffer.popFirst(), [.text("hello world")])
        XCTAssertEqual(buffer.popFirst(), [.key(key: "return", phase: "press", modifiers: 0)])
        XCTAssertEqual(buffer.popFirst(), [.text("next line")])
    }

    @MainActor func testComputerInputBufferRefusesOverflowAndClearsAllPendingWork() {
        var buffer = ComputerInputBuffer()
        for _ in 0..<64 { XCTAssertTrue(buffer.append([.key(key: "delete", phase: "press", modifiers: 0)])) }
        XCTAssertFalse(buffer.append([.text("must not disappear silently")]))
        XCTAssertEqual(buffer.batches.count, 64)
        buffer.removeAll()
        XCTAssertNil(buffer.popFirst())
        XCTAssertTrue(buffer.append([.text("new lease")]))
        XCTAssertEqual(buffer.popFirst(), [.text("new lease")])
    }

    @MainActor func testComputerViewportPanAndKeyboardResizeUseOneTransform() {
        let large = ComputerViewportTransform(size: CGSize(width: 400, height: 225), aspect: 16 / 9, zoom: 2,
                                             center: CGPoint(x: 0.65, y: 0.4))
        XCTAssertEqual(large.point(CGPoint(x: 200, y: 112.5))?.x ?? -1, 0.65, accuracy: 0.001)
        XCTAssertEqual(large.point(CGPoint(x: 200, y: 112.5))?.y ?? -1, 0.4, accuracy: 0.001)
        let small = ComputerViewportTransform(size: CGSize(width: 200, height: 112.5), aspect: 16 / 9, zoom: 2,
                                             center: large.center)
        XCTAssertEqual(small.point(CGPoint(x: 100, y: 56.25))?.x ?? -1, 0.65, accuracy: 0.001)
        let moved = small.moving(CGPoint(x: 0.5, y: 0.5), by: CGSize(width: 40, height: -22.5))
        XCTAssertEqual(moved.x, 0.6, accuracy: 0.001)
        XCTAssertEqual(moved.y, 0.4, accuracy: 0.001)
        XCTAssertEqual(small.moving(moved, by: CGSize(width: 10_000, height: -10_000)), CGPoint(x: 1, y: 0))
        let panned = ComputerViewportTransform(size: small.size, aspect: 16 / 9, zoom: 2,
                                              center: small.panning(by: CGSize(width: 10_000, height: -10_000)))
        XCTAssertEqual(panned.center, CGPoint(x: 0.25, y: 0.75))
    }

    @MainActor func testComputerEncodedPaddingAndPhonePointerShareSourceGeometry() {
        // The host centers a 16:10 source inside its fixed 16:9 encoded frame.
        let fit = ComputerViewportTransform(size: CGSize(width: 420, height: 262.5), aspect: 1.6, zoom: 1)
        let video = fit.videoFrame(encodedAspect: 16.0 / 9.0)
        XCTAssertEqual(video.width, 466.6667, accuracy: 0.001)
        XCTAssertEqual(video.minX, -23.3333, accuracy: 0.001)
        XCTAssertEqual(video.height, 262.5, accuracy: 0.001)
        XCTAssertEqual(fit.content.width, 420, accuracy: 0.001)
        for transform in [fit,
            ComputerViewportTransform(size: CGSize(width: 420, height: 262.5), aspect: 1.6, zoom: 2, center: CGPoint(x: 0.65, y: 0.4)),
            ComputerViewportTransform(size: CGSize(width: 320, height: 200), aspect: 1.6, zoom: 2, center: CGPoint(x: 0.65, y: 0.4))] {
            let point = CGPoint(x: 0.6, y: 0.45)
            let location = transform.location(for: point)
            XCTAssertEqual(transform.point(location)?.x ?? -1, point.x, accuracy: 0.001)
            XCTAssertEqual(transform.point(location)?.y ?? -1, point.y, accuracy: 0.001)
            let frame = transform.videoFrame(encodedAspect: 16.0 / 9.0)
            XCTAssertEqual(frame.midX, transform.content.midX, accuracy: 0.001)
            XCTAssertEqual(frame.midY, transform.content.midY, accuracy: 0.001)
            XCTAssertEqual(frame.height, transform.content.height, accuracy: 0.001)
        }
        let wide = ComputerViewportTransform(size: CGSize(width: 420, height: 180), aspect: 21.0 / 9.0, zoom: 1)
        XCTAssertEqual(wide.videoFrame(encodedAspect: 16.0 / 9.0).width, 420, accuracy: 0.001)
        XCTAssertEqual(wide.videoFrame(encodedAspect: 16.0 / 9.0).height, 236.25, accuracy: 0.001)
    }

    @MainActor func testComputerPointerModeDefaultsToTrackpadAndRemembersSelection() throws {
        let suite = "computer-mode-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let chat = try JSONDecoder().decode(ChatSummary.self, from: Data(#"{"conversationId":"fixture-chat","botId":"fixture-bot","title":"Computer fixture","messageCount":0,"hasUnread":false,"isArchived":false,"isPinned":false}"#.utf8))
        let connection = ConnectionModel(saved: nil, persistConnection: { _ in })
        let first = ComputerSessionModel(model: connection, chat: chat, inputPreferences: preferences)
        XCTAssertEqual(first.inputMode, .trackpad)
        XCTAssertFalse(first.isControlActive)
        first.toggleKeyboard()
        XCTAssertFalse(first.keyboardPresented)
        first.recenterPointer()
        XCTAssertNil(first.controlLease)
        first.inputMode = .directTouch
        let second = ComputerSessionModel(model: connection, chat: chat, inputPreferences: preferences)
        XCTAssertEqual(second.inputMode, .directTouch)
    }

    @MainActor func testClosedComputerSessionCannotRestartOrPresentInput() async throws {
        let chat = try JSONDecoder().decode(ChatSummary.self, from: Data(#"{"conversationId":"closed-fixture","botId":"fixture-bot","title":"Closed fixture","messageCount":0,"hasUnread":false,"isArchived":false,"isPinned":false}"#.utf8))
        let connection = ConnectionModel(saved: nil, persistConnection: { _ in })
        let computer = ComputerSessionModel(model: connection, chat: chat)
        await computer.close()
        await computer.start()
        await computer.retry()
        computer.toggleKeyboard()
        XCTAssertTrue(computer.isClosed)
        XCTAssertEqual(computer.receiverState, .closed)
        XCTAssertFalse(computer.isLoading)
        XCTAssertNil(computer.session)
        XCTAssertFalse(computer.keyboardPresented)
        XCTAssertFalse(computer.controlAvailable)
    }

    @MainActor func testComputerControlLeaseReconciliationNeverRollsSequenceBackward() {
        func lease(id: String = "lease", sequence: UInt64) -> ComputerControlLease {
            ComputerControlLease(
                id: id, sessionId: "session", ownerDeviceId: "phone", hostInstallationId: "mac",
                conversationId: "chat", generation: 1, sourceId: "display:1", geometryRevision: 1,
                status: "active", lastSequence: sequence, acquiredAt: "a", updatedAt: "u",
                expiresAt: "e", releasedAt: nil
            )
        }

        let reconciled = ComputerSessionModel.reconciledLease(
            current: lease(sequence: 7),
            refreshed: lease(sequence: 6)
        )
        XCTAssertEqual(reconciled?.lastSequence, 7)
        XCTAssertNil(ComputerSessionModel.reconciledLease(
            current: lease(sequence: 7),
            refreshed: lease(id: "other", sequence: 8)
        ))
    }
}

/// NSItemProvider calls its loader on an arbitrary queue. Synchronize the
/// test-controlled delivery instead of sharing a mutable closure across actors.
private final class DelayedPasteDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Data?, Error?) -> Void)?
    func set(_ value: @escaping (Data?, Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        completion = value
    }
    func complete(_ data: Data) {
        lock.lock()
        let value = completion; completion = nil
        lock.unlock()
        value?(data, nil)
    }
}

private actor ImageLoadProbe {
    let data: Data
    let delay: Duration
    private(set) var calls = 0
    private(set) var maximumActive = 0
    private var active = 0
    init(data: Data, delay: Duration = .milliseconds(20)) { self.data = data; self.delay = delay }
    func load() async throws -> Data {
        calls += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        return data
    }
}

extension WonderDiagnosticsTests {
    @MainActor func testApprovalSelectionIsImmediateAndSurvivesNavigationUntilConfirmed() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); MessageRecoveryURLProtocol.releaseHeld() }
        let (model, chat, target) = try approvalFixture(root: root)
        let path = "/api/v1/bots/\(target.botID)"
        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(approvalBot(.fullAccess)))
        MessageRecoveryURLProtocol.hold(path: path)
        XCTAssertTrue(model.canSend(chat))
        XCTAssertTrue(model.canGuide(chat))

        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        let saving = try XCTUnwrap(model.composerApprovalTasks[target])
        XCTAssertEqual(model.approvalChange(target)?.desired, .fullAccess)
        XCTAssertEqual(model.approvalChange(target)?.saving, true)
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.askForApproval.rawValue)
        XCTAssertFalse(model.canSend(chat))
        XCTAssertFalse(model.canGuide(chat))
        await model.send(chat)
        await model.guide(chat)
        XCTAssertNil(model.composers[chat.id]?.pending, "Execution must wait for the server-confirmed permission")
        XCTAssertTrue(model.savingComposerSettings.isEmpty, "Permission saving must not trigger the model settings spinner")
        try await waitForRecoveryRequests(path: path)

        model.dismissConversation(chat)
        model.presentConversation(try Self.cameraChat(id: "other-chat"))
        model.presentConversation(chat)
        XCTAssertEqual(model.approvalChange(target)?.desired, .fullAccess)
        // A stale source refresh must leave the pending presentation intact.
        model.managedBots = [try approvalBot(.askForApproval)]
        XCTAssertEqual(model.approvalChange(target)?.desired, .fullAccess)
        XCTAssertFalse(model.canSend(chat))

        MessageRecoveryURLProtocol.releaseHeld()
        await saving.value
        XCTAssertNil(model.approvalChange(target))
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.fullAccess.rawValue)
        XCTAssertTrue(model.canSend(chat))
        XCTAssertTrue(model.canGuide(chat))
    }

    @MainActor func testApprovalRapidSelectionsSerializeAndCoalesceToLatestChoice() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); MessageRecoveryURLProtocol.releaseHeld() }
        let (model, chat, target) = try approvalFixture(root: root)
        let path = "/api/v1/bots/\(target.botID)"
        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(approvalBot(.fullAccess)))
        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(approvalBot(.approveForMe)))
        MessageRecoveryURLProtocol.hold(path: path)
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        let saving = try XCTUnwrap(model.composerApprovalTasks[target])
        try await waitForRecoveryRequests(path: path)

        model.setApprovalMode(.askForApproval, target: target, chat: chat)
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        model.setApprovalMode(.approveForMe, target: target, chat: chat)
        XCTAssertEqual(model.approvalChange(target)?.desired, .approveForMe)
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path).count, 1)
        MessageRecoveryURLProtocol.releaseHeld()
        await saving.value

        let writes = try MessageRecoveryURLProtocol.bodies(path: path).map {
            try JSONDecoder().decode([String: String].self, from: $0)
        }
        XCTAssertEqual(writes.map { $0["approvalMode"] }, ["full-access", "approve-for-me"])
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.approveForMe.rawValue)
        XCTAssertNil(model.approvalChange(target))
        XCTAssertTrue(model.canSend(chat))
    }

    @MainActor func testApprovalFailureReadsBackConfirmedStateAndKeepsRetryIntent() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat, target) = try approvalFixture(root: root)
        let path = "/api/v1/bots/\(target.botID)"
        MessageRecoveryURLProtocol.enqueue(path: path, status: 503)
        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(approvalBot(.askForApproval)))
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value

        let failure = try XCTUnwrap(model.approvalChange(target))
        XCTAssertFalse(failure.saving)
        XCTAssertTrue(failure.reconciled)
        XCTAssertNotNil(failure.failure)
        XCTAssertEqual(failure.desired, .fullAccess)
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.askForApproval.rawValue)
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path, includingEmpty: true).count, 2)
        XCTAssertTrue(model.canSend(chat), "Successful readback restores a known execution policy")

        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(approvalBot(.fullAccess)))
        model.setApprovalMode(failure.desired, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.fullAccess.rawValue)
        XCTAssertNil(model.approvalChange(target))
    }

    @MainActor func testApprovalTimeoutWithConfirmedDesiredReadbackCompletesWithoutError() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat, target) = try approvalFixture(root: root)
        let path = "/api/v1/bots/\(target.botID)"
        MessageRecoveryURLProtocol.fail(path: path, error: .timedOut)
        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(approvalBot(.fullAccess)))

        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value

        XCTAssertNil(model.approvalChange(target), "A lost write response is successful when the server confirms the intended mode")
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.fullAccess.rawValue)
        XCTAssertTrue(model.canSend(chat))
        XCTAssertTrue(model.canGuide(chat))
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path).count, 1, "Authoritative readback must avoid a redundant write retry")
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: path, includingEmpty: true).count, 2)
    }

    @MainActor func testApprovalAmbiguousFailureBlocksSendAndGuideUntilRetryConfirmsState() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat, target) = try approvalFixture(root: root)
        let path = "/api/v1/bots/\(target.botID)"
        MessageRecoveryURLProtocol.fail(path: path, error: .timedOut)
        MessageRecoveryURLProtocol.fail(path: path, error: .notConnectedToInternet)
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value

        let failure = try XCTUnwrap(model.approvalChange(target))
        XCTAssertFalse(failure.saving)
        XCTAssertFalse(failure.reconciled)
        XCTAssertNotNil(failure.failure)
        XCTAssertFalse(model.canSend(chat))
        XCTAssertFalse(model.canGuide(chat))
        await model.send(chat)
        await model.guide(chat)
        XCTAssertNil(model.composers[chat.id]?.pending)
        XCTAssertEqual(model.composers[chat.id]?.draft, "Keep this draft")

        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(approvalBot(.fullAccess)))
        model.setApprovalMode(failure.desired, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value
        XCTAssertNil(model.approvalChange(target))
        XCTAssertTrue(model.canSend(chat))
        XCTAssertTrue(model.canGuide(chat))
    }

    @MainActor func testApprovalChangeDuringDelayedUploadPreventsSendFromBeginning() async throws {
        try await assertApprovalChangeDuringDelayedUploadPreventsExecution(guide: false)
    }

    @MainActor func testApprovalChangeDuringDelayedUploadPreventsGuideFromBeginning() async throws {
        try await assertApprovalChangeDuringDelayedUploadPreventsExecution(guide: true)
    }

    @MainActor private func assertApprovalChangeDuringDelayedUploadPreventsExecution(guide: Bool) async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); MessageRecoveryURLProtocol.releaseHeld() }
        let (model, chat, target) = try approvalFixture(root: root)
        let file = try StagedFile(id: "approval-file", name: "Notes.txt", mimeType: "text/plain", data: Data("Retain this attachment".utf8))
        var draft = try XCTUnwrap(model.composers[chat.id])
        draft.stagedFiles = [file]
        model.composers[chat.id] = draft
        let uploadPath = "/api/v1/conversations/\(chat.id)/files"
        let uploaded: [String: Any] = ["id": "uploaded-approval-file", "name": file.name, "mimeType": file.mimeType,
            "byteSize": file.data.count, "sha256": ConversationFile.digest(file.data), "state": "available", "updatedAt": "2026-09-20T00:00:00Z"]
        MessageRecoveryURLProtocol.enqueue(path: uploadPath, body: try JSONSerialization.data(withJSONObject: uploaded))
        MessageRecoveryURLProtocol.hold(path: uploadPath)
        XCTAssertTrue(guide ? model.canGuide(chat) : model.canSend(chat))
        let execution = Task { @MainActor in
            if guide { await model.guide(chat) } else { await model.send(chat) }
        }
        try await waitForRecoveryRequests(path: uploadPath)
        XCTAssertTrue(model.uploading.contains(chat.id))

        // The selection happens after Send/Guide passed its initial guard,
        // while attachment upload is suspended. An unknown save result must
        // remain a fence when that earlier action resumes.
        let settingsPath = "/api/v1/bots/\(target.botID)"
        MessageRecoveryURLProtocol.fail(path: settingsPath, error: .timedOut)
        MessageRecoveryURLProtocol.fail(path: settingsPath, error: .notConnectedToInternet)
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value
        XCTAssertEqual(model.approvalChange(target)?.reconciled, false)
        XCTAssertTrue(model.approvalSettingsBlockSending(chat.id))
        MessageRecoveryURLProtocol.releaseHeld()
        await execution.value

        XCTAssertNil(model.composers[chat.id]?.pending)
        XCTAssertEqual(model.composers[chat.id]?.draft, "Keep this draft")
        XCTAssertEqual(model.composers[chat.id]?.stagedFiles?.first?.uploaded?.id, "uploaded-approval-file")
        XCTAssertEqual(model.composers[chat.id]?.stagedFiles?.first?.data, file.data)
        XCTAssertFalse(model.uploading.contains(chat.id))
        XCTAssertFalse(model.preparingSends.contains(chat.id))
        XCTAssertNil(model.controlErrors[chat.id])
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/conversations/\(chat.id)/messages").isEmpty)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/conversations/\(chat.id)/turns/active-turn/steer").isEmpty)
    }

    @MainActor func testApprovalHostChangeCancelsPendingSaveAndIgnoresOldResponse() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); MessageRecoveryURLProtocol.releaseHeld() }
        let (model, chat, target) = try approvalFixture(root: root)
        let path = "/api/v1/bots/\(target.botID)"
        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode(approvalBot(.fullAccess)))
        MessageRecoveryURLProtocol.hold(path: path)
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        let saving = try XCTUnwrap(model.composerApprovalTasks[target])
        try await waitForRecoveryRequests(path: path)

        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.cameraSavedConnection())) as? [String: Any])
        var credential = try XCTUnwrap(fields["credential"] as? [String: Any])
        credential["hostInstallationId"] = "another-unit-host"
        fields["credential"] = credential
        model.connection = try JSONDecoder().decode(SavedConnection.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertTrue(model.composerApprovalChanges.isEmpty)
        XCTAssertTrue(model.composerApprovalTasks.isEmpty)
        MessageRecoveryURLProtocol.releaseHeld()
        await saving.value
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.askForApproval.rawValue)
        XCTAssertTrue(model.composerApprovalChanges.isEmpty)
    }

    @MainActor func testQueuedApprovalConflictReloadsRevisionAndRetryUsesLatestRevision() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat, directTarget) = try approvalFixture(root: root)
        let target = ComposerApprovalTarget(conversationID: chat.id, botID: directTarget.botID, queuedMessageID: "queued")
        let queuePath = "/api/v1/conversations/\(chat.id)/queue", writePath = queuePath + "/queued"
        model.queues[chat.id] = [try approvalQueuedMessage(revision: 1, mode: .askForApproval)]
        MessageRecoveryURLProtocol.enqueue(path: writePath, status: 409)
        MessageRecoveryURLProtocol.enqueue(path: queuePath, body: try JSONEncoder().encode([approvalQueuedMessage(revision: 2, mode: .approveForMe)]))
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value
        XCTAssertEqual(model.queues[chat.id]?.first?.revision, 2)
        XCTAssertEqual(model.queues[chat.id]?.first?.executionSettings?.approvalMode, BotApprovalMode.approveForMe.rawValue)
        XCTAssertEqual(model.approvalChange(target)?.reconciled, true)
        XCTAssertNotNil(model.approvalChange(target)?.failure)

        MessageRecoveryURLProtocol.enqueue(path: writePath)
        MessageRecoveryURLProtocol.enqueue(path: queuePath, body: try JSONEncoder().encode([approvalQueuedMessage(revision: 3, mode: .fullAccess)]))
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value
        let writes = try MessageRecoveryURLProtocol.bodies(path: writePath).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        XCTAssertEqual(writes.compactMap { $0["expectedRevision"] as? Int }, [1, 2])
        XCTAssertEqual(writes.compactMap { ($0["settings"] as? [String: String])?["approvalMode"] }, ["full-access", "full-access"])
        XCTAssertEqual(model.queues[chat.id]?.first?.revision, 3)
        XCTAssertEqual(model.queues[chat.id]?.first?.executionSettings?.approvalMode, BotApprovalMode.fullAccess.rawValue)
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.askForApproval.rawValue, "Queued settings must not change the Bot defaults")
        XCTAssertNil(model.approvalChange(target))
    }

    @MainActor func testQueuedApprovalAmbiguousFailureClearsFenceWhenMessageDisappears() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat, directTarget) = try approvalFixture(root: root)
        let target = ComposerApprovalTarget(conversationID: chat.id, botID: directTarget.botID, queuedMessageID: "queued")
        let queuePath = "/api/v1/conversations/\(chat.id)/queue"
        model.queues[chat.id] = [try approvalQueuedMessage(revision: 1, mode: .askForApproval)]
        MessageRecoveryURLProtocol.fail(path: queuePath + "/queued", error: .timedOut)
        MessageRecoveryURLProtocol.fail(path: queuePath, error: .notConnectedToInternet)
        model.setApprovalMode(.fullAccess, target: target, chat: chat)
        await model.composerApprovalTasks[target]?.value
        XCTAssertEqual(model.approvalChange(target)?.reconciled, false)
        XCTAssertNotNil(model.approvalChange(target)?.failure)
        XCTAssertFalse(model.canSend(chat))
        XCTAssertFalse(model.canGuide(chat))

        // A later authoritative queue refresh reports that this message was
        // started or cancelled, so there is no longer a settings target to retry.
        MessageRecoveryURLProtocol.enqueue(path: queuePath, body: Data("[]".utf8))
        try await model.loadQueue(chat)

        XCTAssertTrue(model.queues[chat.id]?.isEmpty == true)
        XCTAssertNil(model.approvalChange(target))
        XCTAssertNil(model.composerApprovalTasks[target])
        XCTAssertNil(model.composerApprovalTokens[target])
        XCTAssertFalse(model.approvalSettingsBlockSending(chat.id))
        XCTAssertTrue(model.canSend(chat))
        XCTAssertTrue(model.canGuide(chat))
        XCTAssertEqual(model.composers[chat.id]?.draft, "Keep this draft")
        XCTAssertEqual(model.managedBots.first?.approvalMode, BotApprovalMode.askForApproval.rawValue)
    }

    @MainActor func testQueuedApprovalOlderRefreshCannotReplaceConfirmedRevision() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); MessageRecoveryURLProtocol.releaseHeld() }
        let (model, chat, _) = try approvalFixture(root: root)
        let path = "/api/v1/conversations/\(chat.id)/queue"
        MessageRecoveryURLProtocol.enqueue(path: path, body: try JSONEncoder().encode([approvalQueuedMessage(revision: 1, mode: .askForApproval)]))
        MessageRecoveryURLProtocol.hold(path: path)
        let refresh = Task { @MainActor in try await model.loadQueue(chat) }
        try await waitForRecoveryRequests(path: path)
        model.queues[chat.id] = [try approvalQueuedMessage(revision: 3, mode: .fullAccess)]
        MessageRecoveryURLProtocol.releaseHeld()
        try await refresh.value
        XCTAssertEqual(model.queues[chat.id]?.first?.revision, 3)
        XCTAssertEqual(model.queues[chat.id]?.first?.executionSettings?.approvalMode, BotApprovalMode.fullAccess.rawValue)
    }

    @MainActor private func approvalFixture(root: URL) throws -> (ConnectionModel, ChatSummary, ComposerApprovalTarget) {
        let model = recoveryModel(root: root)
        let chat = try Self.cameraChat(id: "approval-chat")
        model.managedBots = [try approvalBot(.askForApproval)]
        model.chats = [chat]
        model.presentConversation(chat)
        model.snapshots[chat.id] = try JSONDecoder().decode(ConversationSnapshot.self, from: Data(#"{"conversationId":"approval-chat","hostEpoch":"epoch","lastSequence":1,"messages":[],"assistantMessages":[],"thread":{"hydrated":true,"turns":[{"id":"active-turn","status":"inProgress","items":[]}]}}"#.utf8))
        model.editDraft("Keep this draft", chat: chat.id)
        return (model, chat, ComposerApprovalTarget(conversationID: chat.id, botID: "camera-unit-bot", queuedMessageID: nil))
    }

    private func approvalBot(_ mode: BotApprovalMode) throws -> ManagedBot {
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(managedBot("camera-unit-bot", avatar: "ocean"))) as? [String: Any])
        fields["approvalMode"] = mode.rawValue
        fields["conversationId"] = "approval-chat"
        return try JSONDecoder().decode(ManagedBot.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func approvalQueuedMessage(revision: Int, mode: BotApprovalMode) throws -> QueuedMessage {
        let fields: [String: Any] = ["id": "queued", "clientMessageId": "queued-client", "body": "Queued draft", "revision": revision,
            "attachmentIds": [], "executionSettings": ["approvalMode": mode.rawValue, "model": "model"]]
        return try JSONDecoder().decode(QueuedMessage.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @MainActor private func waitForRecoveryRequests(path: String, count: Int = 1) async throws {
        for _ in 0..<100 {
            if MessageRecoveryURLProtocol.bodies(path: path, includingEmpty: true).count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The expected synthetic request did not arrive: \(path)")
    }

    @MainActor func testCancelledPairingDoesNotReadIdentityOrConsumeOffer() async throws {
        let signing = SigningIdentity(read: {
            XCTFail("Cancelled enrollment must not read an identity")
            throw SigningIdentityFailure.missing
        }, save: { _ in XCTFail("Cancelled enrollment must not save a key") }, restore: { _ in
            XCTFail("Cancelled enrollment must not restore a key")
            throw SigningIdentityFailure.missing
        }, create: {
            XCTFail("Cancelled enrollment must not create a key")
            throw SigningIdentityFailure.missing
        })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingDelayedResponse.self]
        let model = ConnectionModel(persistConnection: { _ in XCTFail("Cancelled enrollment must not save credentials") },
                                    api: PairingAPI(configuration: configuration), signingIdentity: signing)
        model.pair(link: "https://pairing-recovery-unit.invalid/pair#offerId=11111111-1111-1111-1111-111111111111&secret=synthetic&hostInstallationId=test-host", address: "", code: "")
        model.cancel()
        for _ in 0..<100 {
            if !model.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.connection)
        XCTAssertFalse(PairingDelayedResponse.delivery.isWaiting)
        XCTAssertTrue(model.status.contains("Pairing stopped"))
    }

    @MainActor func testReplacedPairingRejectsLateSendReceiptAndPreservesFreshDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = SavedConnection(origin: "https://pairing-recovery-unit.invalid", credential: Self.cameraSavedConnection().credential)
        let chat = try Self.cameraChat(id: "pairing-recovery-chat")
        var initial = ComposerIntent(); initial.draft = "Possibly sent before reconnect"
        try initial.begin(device: old.credential.deviceId)
        let request = try XCTUnwrap(initial.pending?.request)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingDelayedResponse.self]
        let model = ConnectionModel(cameraFixtureStoreRoot: root, saved: old, chat: chat, initialIntent: initial,
                                    api: PairingAPI(configuration: configuration), replayEnabled: false)
        let delivery = Task { await model.deliver(chat) }
        for _ in 0..<200 {
            if PairingDelayedResponse.delivery.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(PairingDelayedResponse.delivery.isWaiting)
        model.retireAfterPairingReplacement()
        let store = ReadStore(root: root, host: old.credential.hostInstallationId, device: old.storageDeviceId)
        var fresh = ComposerIntent(); fresh.draft = "Typed after new pairing"
        try store.saveComposer(fresh, conversation: chat.id)
        let receipt: [String: Any] = ["clientMessageId": request.clientMessageId, "wonderMessageId": "accepted-old-message",
            "bodySha256": ConversationFile.digest(Data(request.body.utf8)), "conversationId": chat.id, "deliveryState": "accepted_by_wonder"]
        PairingDelayedResponse.delivery.complete(try JSONSerialization.data(withJSONObject: receipt))
        await delivery.value
        XCTAssertEqual(try store.loadComposer(conversation: chat.id).draft, fresh.draft)
        XCTAssertNil(try store.loadComposer(conversation: chat.id).pending)
        model.editDraft("Stale view edit", chat: chat.id)
        XCTAssertEqual(try store.loadComposer(conversation: chat.id).draft, fresh.draft)
        XCTAssertTrue(model.accessEnded)
        XCTAssertEqual(model.macStatus, "Pair again")
    }
}

private final class PairingDelayedDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var response: PairingDelayedResponse?
    var isWaiting: Bool { lock.withLock { response != nil } }
    func hold(_ value: PairingDelayedResponse) { lock.withLock { response = value } }
    func complete(_ data: Data) {
        let value = lock.withLock { let value = response; response = nil; return value }
        value?.complete(data)
    }
}

private final class PairingDelayedResponse: URLProtocol, @unchecked Sendable {
    static let delivery = PairingDelayedDelivery()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pairing-recovery-unit.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.delivery.hold(self) }
    override func stopLoading() { }
    func complete(_ data: Data) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// Identical regression checks run before and after the Release 2 product patch.
extension WonderDiagnosticsTests {

    @MainActor func testRelease2RegressionVisibleChildRefreshKeepsRootSelection() async throws {
        DiagnosticSubagentFixture.resetTransport()
        let model = DiagnosticSubagentFixture.model()
        await model.loadChats(force: true)
        let parent = try XCTUnwrap(model.chats.first(where: { $0.id == DiagnosticSubagentFixture.parentID }))
        await model.open(parent)
        let child = try XCTUnwrap(model.subagents[parent.id]?.first).chatSummary(botId: parent.botId)
        await model.open(child, root: parent)
        XCTAssertEqual(model.selectedChat?.id, parent.id)

        // Clear requests only; the active route must survive a background refresh.
        DiagnosticSubagentFixture.resetTransport()
        await model.loadChats(force: true)
        for suffix in ["", "/questions", "/queue"] {
            XCTAssertTrue(DiagnosticSubagentFixture.recordedPaths().contains("/api/v1/conversations/\(child.id)\(suffix)"),
                "Background refresh did not refresh the visible child route: \(suffix)")
        }
        XCTAssertEqual(model.selectedChat?.id, parent.id)
    }

    @MainActor func testReadOnlyChildRejectsCameraWithoutChangingParent() async throws {
        DiagnosticSubagentFixture.resetTransport()
        let model = DiagnosticSubagentFixture.model()
        await model.loadChats(force: true)
        let parent = try XCTUnwrap(model.chats.first(where: { $0.id == DiagnosticSubagentFixture.parentID }))
        await model.open(parent)
        let child = try XCTUnwrap(model.subagents[parent.id]?.first).chatSummary(botId: parent.botId)
        await model.open(child, root: parent)
        XCTAssertFalse(model.chats.contains { $0.id == child.id })
        let attached = await model.stageCameraPhoto(Self.cameraImageData(), chat: child, scope: model.assignmentScope)
        guard case .cancelled = attached else { return XCTFail("A read-only agent accepted a capture") }
        XCTAssertEqual(model.composers[child.id]?.attachmentCount, 0)
        XCTAssertEqual(model.composers[parent.id]?.attachmentCount, 0)
        await model.open(parent)
        let cancelled = await model.stageCameraPhoto(Self.cameraImageData(), chat: child, scope: model.assignmentScope)
        guard case .cancelled = cancelled else { return XCTFail("An outgoing child accepted a capture") }
        XCTAssertEqual(model.composers[child.id]?.attachmentCount, 0)
    }

    @MainActor func testRelease2RegressionGroupPreparationFailureKeepsDraftRetryable() async throws {
        Release2RegressionURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, chat) = try release2RegressionGroup(root: root)
        var intent = ComposerIntent(); intent.draftAttachmentIds = ["uploaded-file"]
        model.composers[chat.id] = intent
        Release2RegressionURLProtocol.enqueue(path: "/api/v1/bot-options", status: 503)
        Release2RegressionURLProtocol.enqueue(path: "/api/v1/bot-options", body: try release2RegressionOptions())

        await model.send(chat)
        XCTAssertNil(model.composerErrors[chat.id])
        XCTAssertNotNil(model.controlErrors[chat.id])
        XCTAssertTrue(model.canSend(chat))
        XCTAssertNil(model.composers[chat.id]?.pending)
        XCTAssertEqual(model.composers[chat.id]?.draftAttachmentIds, ["uploaded-file"])
        await model.send(chat)
        XCTAssertNil(model.controlErrors[chat.id])
        let request = try JSONDecoder().decode(SendRequest.self, from: XCTUnwrap(Release2RegressionURLProtocol.bodies(path: "/api/v1/group-chats/group/messages").first))
        XCTAssertEqual(request.attachmentIds, ["uploaded-file"])
        XCTAssertEqual(request.body, "")
        XCTAssertNotNil(model.composers[chat.id]?.pending?.receipt)
    }

    @MainActor func testRelease2RegressionRejectedAsyncReplyCanBeCorrectedOrSkipped() async throws {
        for status in [400, 413] {
            for skip in [false, true] {
                Release2RegressionURLProtocol.reset()
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let model = release2RegressionModel(root: root)
                let chat = try Self.cameraChat(id: "recovery-chat")
                let question = try release2RegressionQuestion()
                let store = ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
                let old = AsyncAnswerIntent(answers: [String(repeating: "a", count: 8193)], skip: false)
                try store.saveIntent(JSONEncoder().encode(old), conversation: "async-reply-q")
                model.saveAnswerDraft(["0": "Editable answer"], id: question.id)
                let path = "/api/v1/conversations/recovery-chat/questions/q"
                Release2RegressionURLProtocol.enqueue(path: path, status: status)
                await model.replyAsync(question, chat: chat, answers: ["Ignored during exact retry"], skip: false)
                XCTAssertNil(try store.loadIntent(conversation: "async-reply-q"))
                XCTAssertEqual(model.answerDraft(question.id), ["0": "Editable answer"])
                Release2RegressionURLProtocol.enqueue(path: path, status: 204)
                await model.replyAsync(question, chat: chat, answers: skip ? [] : ["Corrected answer"], skip: skip)
                let bodies = Release2RegressionURLProtocol.bodies(path: path)
                XCTAssertEqual(bodies.count, 2)
                let retried = try JSONDecoder().decode(AsyncAnswerIntent.self, from: XCTUnwrap(bodies.last))
                XCTAssertEqual(retried.skip, skip)
                XCTAssertEqual(retried.answers, skip ? [] : ["Corrected answer"])
                XCTAssertNil(model.attentionErrors[question.id])
            }
        }
    }

    @MainActor private func release2RegressionModel(root: URL) -> ConnectionModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Release2RegressionURLProtocol.self]
        return ConnectionModel(cameraFixtureStoreRoot: root, saved: Self.cameraSavedConnection(),
            api: PairingAPI(configuration: configuration), replayEnabled: false)
    }

    @MainActor private func release2RegressionGroup(root: URL) throws -> (ConnectionModel, ChatSummary) {
        let group = try JSONDecoder().decode(GroupRead.self, from: Data(#"{"id":"group","conversationId":"recovery-chat","name":"Group","isArchived":false,"messages":[],"attachmentsSupported":true,"collaboration":{"configuration":{"instructions":"","routing":{"model":"","reasoningEffort":""},"workspace":"/fixture","needsPurpose":false},"runs":[]}}"#.utf8))
        let model = release2RegressionModel(root: root)
        model.groups[group.conversationId] = group
        model.chats = [group.summary]
        return (model, group.summary)
    }

    private func release2RegressionOptions() throws -> Data {
        let defaults = ModelDefaultPurpose.groupParticipation.load()
        return try JSONSerialization.data(withJSONObject: [
            "models": [["id": defaults.model.isEmpty ? "fixture-model" : defaults.model, "displayName": "Fixture", "hidden": false,
                "reasoningEfforts": [["id": defaults.reasoningEffort, "label": "Fixture"]],
                "serviceTiers": [["id": defaults.serviceTier ?? "default", "label": "Fixture"]]]],
            "approvalModes": [["id": defaults.approvalMode.rawValue, "allowed": true]],
            "allowedApprovalPolicies": []
        ])
    }

    private func release2RegressionQuestion() throws -> AsyncQuestion {
        try JSONDecoder().decode(AsyncQuestion.self, from: Data(#"{"id":"q","conversationId":"recovery-chat","turnId":"turn","itemId":"item","questions":[{"title":"Question?"}],"state":"pending","expiresAtMs":9999999999999}"#.utf8))
    }

}

/// Synthetic, scoped transport. Held requests are released explicitly by tests;
/// no real host, credentials or model execution is involved.
private final class Release2RegressionURLProtocol: URLProtocol, @unchecked Sendable {
    private enum Reply { case response(Int, Data), failure(URLError.Code) }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var replies: [String: [Reply]] = [:]
        var requests: [(String, Data?)] = []
        var heldPath: String?
        var held: [() -> Void] = []
    }
    private static let state = State()
    static func reset() {
        releaseHeld()
        state.lock.withLock { state.replies = [:]; state.requests = []; state.heldPath = nil }
    }
    static func enqueue(path: String, status: Int = 200, body: Data = Data("{}".utf8)) {
        state.lock.withLock { state.replies[path, default: []].append(.response(status, body)) }
    }
    static func fail(path: String, error: URLError.Code) {
        state.lock.withLock { state.replies[path, default: []].append(.failure(error)) }
    }
    static func bodies(path: String, includingEmpty: Bool = false) -> [Data] {
        state.lock.withLock { state.requests.filter { $0.0 == path }.compactMap { $0.1 ?? (includingEmpty ? Data() : nil) } }
    }
    static func hold(path: String) { state.lock.withLock { state.heldPath = path } }
    static func releaseHeld() {
        let work = state.lock.withLock { let work = state.held; state.held = []; state.heldPath = nil; return work }
        work.forEach { $0() }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "camera-unit.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: Data?
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { body = nil }
        let held = Self.state.lock.withLock {
            Self.state.requests.append((path, body))
            guard Self.state.heldPath == path else { return false }
            Self.state.held.append { [weak self] in self?.respond(path: path, body: body) }
            return true
        }
        if !held { respond(path: path, body: body) }
    }
    override func stopLoading() {}
    private func respond(path: String, body: Data?) {
        let reply: Reply? = Self.state.lock.withLock {
            guard Self.state.replies[path]?.isEmpty == false else { return nil }
            return Self.state.replies[path]?.removeFirst()
        }
        if case .failure(let code) = reply { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        if case .response(let status, let data) = reply { finish(status: status, body: data); return }
        if path == "/api/v1/group-chats/group/messages", let body,
           let sent = try? JSONDecoder().decode(SendRequest.self, from: body) {
            let value = ["clientMessageId": sent.clientMessageId, "wonderMessageId": "accepted",
                "bodySha256": ConversationFile.digest(Data(sent.body.utf8)), "conversationId": "recovery-chat", "deliveryState": "accepted_by_wonder"]
            finish(status: 202, body: try! JSONEncoder().encode(value)); return
        }
        if path == "/api/v1/devices" {
            finish(status: 200, body: Data(#"[{"id":"camera-unit-device","revokedAt":null}]"#.utf8)); return
        }
        if path == "/api/v1/host/status" {
            finish(status: 200, body: Data(#"{"hostInstallationId":"camera-unit-host"}"#.utf8)); return
        }
        finish(status: 200, body: Data("[]".utf8))
    }
    private func finish(status: Int, body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Synthetic, scoped transport. Held requests are released explicitly by tests;
/// no real host, credentials or model execution is involved.
private final class MessageRecoveryURLProtocol: URLProtocol, @unchecked Sendable {
    private enum Reply { case response(Int, Data), failure(URLError.Code) }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var replies: [String: [Reply]] = [:]
        var requests: [(String, Data?)] = []
        var heldPath: String?
        var held: [() -> Void] = []
    }
    private static let state = State()
    static func reset() {
        releaseHeld()
        state.lock.withLock { state.replies = [:]; state.requests = []; state.heldPath = nil }
    }
    static func enqueue(path: String, status: Int = 200, body: Data = Data("{}".utf8)) {
        state.lock.withLock { state.replies[path, default: []].append(.response(status, body)) }
    }
    static func fail(path: String, error: URLError.Code) {
        state.lock.withLock { state.replies[path, default: []].append(.failure(error)) }
    }
    static func bodies(path: String, includingEmpty: Bool = false) -> [Data] {
        state.lock.withLock { state.requests.filter { $0.0 == path }.compactMap { $0.1 ?? (includingEmpty ? Data() : nil) } }
    }
    static func hold(path: String) { state.lock.withLock { state.heldPath = path } }
    static func releaseHeld() {
        let work = state.lock.withLock { let work = state.held; state.held = []; state.heldPath = nil; return work }
        work.forEach { $0() }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "camera-unit.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: Data?
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { body = nil }
        let held = Self.state.lock.withLock {
            Self.state.requests.append((path, body))
            guard Self.state.heldPath == path else { return false }
            Self.state.held.append { [weak self] in self?.respond(path: path, body: body) }
            return true
        }
        if !held { respond(path: path, body: body) }
    }
    override func stopLoading() {}
    private func respond(path: String, body: Data?) {
        let reply: Reply? = Self.state.lock.withLock {
            guard Self.state.replies[path]?.isEmpty == false else { return nil }
            return Self.state.replies[path]?.removeFirst()
        }
        if case .failure(let code) = reply { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        if case .response(let status, let data) = reply { finish(status: status, body: data); return }
        if path == "/api/v1/group-chats/group/messages", let body,
           let sent = try? JSONDecoder().decode(SendRequest.self, from: body) {
            let value = ["clientMessageId": sent.clientMessageId, "wonderMessageId": "accepted",
                "bodySha256": ConversationFile.digest(Data(sent.body.utf8)), "conversationId": "recovery-chat", "deliveryState": "accepted_by_wonder"]
            finish(status: 202, body: try! JSONEncoder().encode(value)); return
        }
        if path == "/api/v1/devices" {
            finish(status: 200, body: Data(#"[{"id":"camera-unit-device","revokedAt":null}]"#.utf8)); return
        }
        if path == "/api/v1/host/status" {
            finish(status: 200, body: Data(#"{"hostInstallationId":"camera-unit-host"}"#.utf8)); return
        }
        finish(status: 200, body: Data("[]".utf8))
    }
    private func finish(status: Int, body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

extension WonderDiagnosticsTests {
    @MainActor func testAsyncReplyRestoresPendingSubmissionAndRetriesExactBytes() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let question = try recoveryQuestion()
        let chat = try Self.cameraChat(id: "recovery-chat")
        let store = ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
        let bytes = Data(#"{ "skip" : false, "answers" : ["Original answer"] }"#.utf8)
        try store.saveIntent(bytes, conversation: "async-reply-q")
        let model = recoveryModel(root: root)
        let listPath = "/api/v1/conversations/recovery-chat/questions"
        let replyPath = listPath + "/q"
        MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([question]))
        await model.loadAsyncQuestions(chat)
        XCTAssertEqual(model.savedAsyncReplies[question.id]?.answers, ["Original answer"])
        XCTAssertTrue(model.retryableAsyncReplies.contains(question.id))
        XCTAssertNotNil(model.attentionErrors[question.id])
        MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([question]))
        MessageRecoveryURLProtocol.enqueue(path: replyPath, status: 204)
        await model.replyAsync(question, chat: chat, answers: [], skip: true, retry: true)
        XCTAssertEqual(MessageRecoveryURLProtocol.bodies(path: replyPath), [bytes])
        XCTAssertNil(try store.loadIntent(conversation: "async-reply-q"))
        XCTAssertNil(model.savedAsyncReplies[question.id])
    }

    @MainActor func testAsyncReplyRestoresExpiredSubmissionForCopyWithoutResubmitting() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try Self.cameraChat(id: "recovery-chat")
        let expired = try recoveryQuestionWithState("expired", response: nil)
        let store = ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
        let bytes = try JSONEncoder().encode(AsyncAnswerIntent(answers: ["Keep this reply"], skip: false))
        try store.saveIntent(bytes, conversation: "async-reply-q")
        let model = recoveryModel(root: root)
        let listPath = "/api/v1/conversations/recovery-chat/questions"
        MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([expired]))
        await model.loadAsyncQuestions(chat)
        XCTAssertEqual(model.savedAsyncReplies[expired.id]?.answers, ["Keep this reply"])
        XCTAssertNotNil(model.attentionErrors[expired.id], "The expired row must remain reachable in QuestionDock")
        XCTAssertFalse(model.retryableAsyncReplies.contains(expired.id))
        MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([expired]))
        await model.replyAsync(expired, chat: chat, answers: [], skip: true, retry: true)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: listPath + "/q").isEmpty)
        XCTAssertEqual(try store.loadIntent(conversation: "async-reply-q"), bytes)
    }

    @MainActor func testAsyncReplyReconcilesConfirmedTerminalResponseWithoutResubmitting() async throws {
        for state in ["answered", "dismissed"] {
            MessageRecoveryURLProtocol.reset()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let chat = try Self.cameraChat(id: "recovery-chat")
            let answer = AsyncAnswerIntent(answers: state == "answered" ? ["Confirmed reply"] : [], skip: state == "dismissed")
            let terminal = try recoveryQuestionWithState(state, response: answer)
            let store = ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
            try store.saveIntent(JSONEncoder().encode(answer), conversation: "async-reply-q")
            let model = recoveryModel(root: root)
            let listPath = "/api/v1/conversations/recovery-chat/questions"
            MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([terminal]))
            await model.loadAsyncQuestions(chat)
            XCTAssertNil(try store.loadIntent(conversation: "async-reply-q"))
            XCTAssertNil(model.savedAsyncReplies[terminal.id])
            XCTAssertNil(model.attentionErrors[terminal.id])
            XCTAssertFalse(model.retryableAsyncReplies.contains(terminal.id))
            MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([terminal]))
            await model.replyAsync(terminal, chat: chat, answers: [], skip: true, retry: true)
            XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: listPath + "/q").isEmpty)
        }
    }

    @MainActor func testAsyncReplyPreservesDifferentTerminalResponseWithoutResubmitting() async throws {
        for state in ["answered", "dismissed"] {
            MessageRecoveryURLProtocol.reset()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let chat = try Self.cameraChat(id: "recovery-chat")
            let stalePending = try recoveryQuestion()
            let response = AsyncAnswerIntent(answers: state == "answered" ? ["Answered elsewhere"] : [], skip: state == "dismissed")
            let terminal = try recoveryQuestionWithState(state, response: response)
            let store = ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
            let bytes = try JSONEncoder().encode(AsyncAnswerIntent(answers: ["My original reply"], skip: false))
            try store.saveIntent(bytes, conversation: "async-reply-q")
            let model = recoveryModel(root: root)
            let listPath = "/api/v1/conversations/recovery-chat/questions"
            MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([terminal]))
            await model.loadAsyncQuestions(chat)
            XCTAssertEqual(model.savedAsyncReplies[terminal.id]?.answers, ["My original reply"])
            XCTAssertNotNil(model.attentionErrors[terminal.id])
            XCTAssertFalse(model.retryableAsyncReplies.contains(terminal.id))
            // Even a stale pending row may not submit after authoritative terminal state.
            await model.replyAsync(stalePending, chat: chat, answers: ["Changed"], skip: false)
            MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([terminal]))
            await model.replyAsync(stalePending, chat: chat, answers: [], skip: true, retry: true)
            XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: listPath + "/q").isEmpty)
            XCTAssertEqual(try store.loadIntent(conversation: "async-reply-q"), bytes)
        }
    }

    @MainActor func testAsyncReplyStatusFailureAndMissingQuestionNeverResubmit() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try Self.cameraChat(id: "recovery-chat")
        let question = try recoveryQuestion()
        let store = ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
        let bytes = try JSONEncoder().encode(AsyncAnswerIntent(answers: ["My reply"], skip: false))
        try store.saveIntent(bytes, conversation: "async-reply-q")
        let model = recoveryModel(root: root)
        let listPath = "/api/v1/conversations/recovery-chat/questions"
        MessageRecoveryURLProtocol.enqueue(path: listPath, body: try JSONEncoder().encode([question]))
        await model.loadAsyncQuestions(chat)
        MessageRecoveryURLProtocol.enqueue(path: listPath, status: 503)
        await model.replyAsync(question, chat: chat, answers: [], skip: true, retry: true)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: listPath + "/q").isEmpty)
        XCTAssertNotNil(model.savedAsyncReplies[question.id])
        MessageRecoveryURLProtocol.enqueue(path: listPath, body: Data("[]".utf8))
        await model.replyAsync(question, chat: chat, answers: [], skip: true, retry: true)
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: listPath + "/q").isEmpty)
        XCTAssertEqual(model.asyncQuestions[chat.id]?.map(\.id), [question.id])
        XCTAssertNotNil(model.attentionErrors[question.id])
        XCTAssertFalse(model.retryableAsyncReplies.contains(question.id))
        XCTAssertEqual(try store.loadIntent(conversation: "async-reply-q"), bytes)
    }

    @MainActor func testAsyncReplyRestoresCachedExpiredSubmissionWhileOffline() async throws {
        MessageRecoveryURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try Self.cameraChat(id: "recovery-chat")
        let expired = try recoveryQuestionWithState("expired", response: nil)
        let store = ReadStore(root: root, host: "camera-unit-host", device: "camera-unit-device")
        try store.saveIntent(JSONEncoder().encode([expired]), conversation: "async-list-" + chat.id)
        try store.saveIntent(JSONEncoder().encode(AsyncAnswerIntent(answers: ["Offline saved reply"], skip: false)), conversation: "async-reply-q")
        let model = recoveryModel(root: root)
        MessageRecoveryURLProtocol.enqueue(path: "/api/v1/conversations/recovery-chat/questions", status: 503)
        await model.open(chat)
        XCTAssertEqual(model.savedAsyncReplies[expired.id]?.answers, ["Offline saved reply"])
        XCTAssertNotNil(model.attentionErrors[expired.id])
        XCTAssertEqual(model.asyncQuestions[chat.id]?.map(\.id), [expired.id])
        XCTAssertTrue(MessageRecoveryURLProtocol.bodies(path: "/api/v1/conversations/recovery-chat/questions/q").isEmpty)
    }

    private func recoveryQuestionWithState(_ state: String, response: AsyncAnswerIntent?) throws -> AsyncQuestion {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(recoveryQuestion())) as? [String: Any])
        value["state"] = state
        if state == "expired" { value["expiresAtMs"] = 1 }
        if let response { value["response"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) }
        else { value.removeValue(forKey: "response") }
        return try JSONDecoder().decode(AsyncQuestion.self, from: JSONSerialization.data(withJSONObject: value))
    }
}

extension WonderDiagnosticsTests {
    @MainActor func testTeachingCancelWhileStartingCancelsTheLateReceipt() async throws {
        let (teaching, root) = try teachingModel()
        defer { try? FileManager.default.removeItem(at: root); TeachingLifecycleURLProtocol.releaseHeld() }
        TeachingLifecycleURLProtocol.hold(method: "POST", suffix: "/sessions")
        let start = Task { await teaching.start() }
        try await waitForTeachingRequest(suffix: "/sessions")
        XCTAssertTrue(teaching.isStarting)
        XCTAssertTrue(teaching.hasCaptureToResolve)
        await teaching.cancel()
        XCTAssertTrue(teaching.interrupted)
        XCTAssertFalse(teaching.isRecording)
        TeachingLifecycleURLProtocol.releaseHeld()
        await start.value
        XCTAssertEqual(teaching.session?.state, "cancelled")
        XCTAssertFalse(teaching.isStarting)
        XCTAssertFalse(teaching.hasCaptureToResolve)
        XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/cancel"), 1)
        XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/sessions"), 1)
    }

    @MainActor func testTeachingControlEndedDuringStartIsIdempotent() async throws {
        let (teaching, root) = try teachingModel()
        defer { try? FileManager.default.removeItem(at: root); TeachingLifecycleURLProtocol.releaseHeld() }
        TeachingLifecycleURLProtocol.hold(method: "POST", suffix: "/sessions")
        let start = Task { await teaching.start() }
        try await waitForTeachingRequest(suffix: "/sessions")
        teaching.markControlEnded()
        XCTAssertTrue(teaching.interrupted)
        XCTAssertFalse(teaching.isRecording)
        await teaching.controlEnded()
        await teaching.controlEnded()
        TeachingLifecycleURLProtocol.releaseHeld()
        await start.value
        await teaching.controlEnded()
        XCTAssertTrue(teaching.interrupted)
        XCTAssertFalse(teaching.isRecording)
        XCTAssertEqual(teaching.session?.state, "cancelled")
        XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/cancel"), 1)
    }

    @MainActor func testTeachingAmbiguousStartRetriesExactRequest() async throws {
        let (teaching, root) = try teachingModel()
        defer { try? FileManager.default.removeItem(at: root) }
        TeachingLifecycleURLProtocol.failNextStart()
        await teaching.start()
        XCTAssertNil(teaching.session)
        XCTAssertNotNil(teaching.startRequestID)
        teaching.outcome = "A changed field must not alter the saved request"
        await teaching.retry()
        let requests = TeachingLifecycleURLProtocol.bodies(suffix: "/sessions")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first, requests.last)
        XCTAssertTrue(teaching.isRecording)
        XCTAssertNil(teaching.startRequestID)
    }

    @MainActor func testTeachingInterruptedUnknownStartDoesNotCreateAnotherCapture() async throws {
        let (teaching, root) = try teachingModel()
        defer { try? FileManager.default.removeItem(at: root) }
        TeachingLifecycleURLProtocol.failNextStart()
        await teaching.start()
        await teaching.controlEnded()
        await teaching.retry()
        await teaching.start()
        XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/sessions"), 1)
        XCTAssertTrue(teaching.interrupted)
        XCTAssertTrue(teaching.hasCaptureToResolve)
        XCTAssertFalse(teaching.isRecording)
        XCTAssertNotNil(teaching.failure)
    }

    @MainActor func testTeachingStopReviewsSameSessionAndIgnoresLateRecordingPoll() async throws {
        let (teaching, root) = try teachingModel()
        defer { try? FileManager.default.removeItem(at: root); TeachingLifecycleURLProtocol.releaseHeld() }
        await teaching.start()
        let id = try XCTUnwrap(teaching.session?.id)
        TeachingLifecycleURLProtocol.hold(method: "GET", suffix: "/capture")
        let read = Task { await teaching.readSession() }
        try await waitForTeachingRequest(suffix: "/capture")
        await teaching.stop()
        XCTAssertEqual(teaching.session?.id, id)
        XCTAssertEqual(teaching.session?.state, "reviewing")
        teaching.draftName = "My reviewed name"
        TeachingLifecycleURLProtocol.releaseHeld()
        await read.value
        XCTAssertEqual(teaching.session?.state, "reviewing")
        XCTAssertEqual(teaching.session?.revision, 2)
        XCTAssertEqual(teaching.draftName, "My reviewed name")
        XCTAssertFalse(teaching.hasCaptureToResolve)
        let stop = try XCTUnwrap(TeachingLifecycleURLProtocol.bodies(suffix: "/stop").first)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: stop) as? [String: Any])
        XCTAssertEqual(payload["expectedRevision"] as? Int, 1)
    }

    @MainActor func testTeachingStopRefreshesStaleRevisionAndRetriesSameSessionOnce() async throws {
        let (teaching, root) = try teachingModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await teaching.start()
        TeachingLifecycleURLProtocol.advanceCaptureRevision()
        await teaching.stop()
        XCTAssertEqual(teaching.session?.id, "capture")
        XCTAssertEqual(teaching.session?.state, "reviewing")
        XCTAssertEqual(teaching.session?.revision, 4)
        XCTAssertNil(teaching.failure)
        let revisions = try TeachingLifecycleURLProtocol.bodies(suffix: "/stop").map {
            try XCTUnwrap((JSONSerialization.jsonObject(with: $0) as? [String: Any])?["expectedRevision"] as? Int)
        }
        XCTAssertEqual(revisions, [1, 3])
        XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/sessions"), 1)
    }

    @MainActor func testTeachingStopConflictRetryIsBounded() async throws {
        let (teaching, root) = try teachingModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await teaching.start()
        TeachingLifecycleURLProtocol.advanceCaptureRevision(alwaysConflict: true)
        await teaching.stop()
        XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/stop"), 2)
        XCTAssertEqual(teaching.session?.id, "capture")
        XCTAssertEqual(teaching.session?.state, "recording")
        XCTAssertNotNil(teaching.failure)
    }

    @MainActor func testTeachingCancellationDoesNotDependOnStaleRevision() async throws {
        let (teaching, root) = try teachingModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await teaching.start()
        await teaching.controlEnded()
        await teaching.controlEnded()
        XCTAssertEqual(teaching.session?.state, "cancelled")
        XCTAssertTrue(teaching.interrupted)
        XCTAssertFalse(teaching.isRecording)
        let body = try XCTUnwrap(TeachingLifecycleURLProtocol.bodies(suffix: "/cancel").first)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(payload["expectedRevision"])
        XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/cancel"), 1)
    }

    @MainActor func testTeachingSaveKeepsUnverifiedStateAndExistingSkills() async throws {
        let (teaching, root) = try teachingModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldSkill = try JSONDecoder().decode(BotSkill.self, from: TeachingLifecycleURLProtocol.skillData(id: "existing"))
        teaching.response = BotSkillListResponse(capability: teaching.capability, skills: [oldSkill])
        await teaching.start()
        await teaching.stop()
        teaching.draftName = "Reviewed task"
        await teaching.review()
        await teaching.save()
        XCTAssertEqual(teaching.session?.id, "capture")
        XCTAssertEqual(teaching.session?.state, "approvedVersion")
        XCTAssertEqual(Set(teaching.response?.skills.map(\.id) ?? []), ["existing", "saved"])
        let version = try XCTUnwrap(teaching.response?.skills.first(where: { $0.id == "saved" })?.versions?.first)
        XCTAssertEqual(version.verificationState, "unverified")
    }

    @MainActor func testTeachingSaveRequiresReviewOfEveryEditedDraftField() async throws {
        let (teaching, root) = try teachingModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await teaching.start()
        await teaching.stop()
        await teaching.review()
        XCTAssertTrue(teaching.hasReviewedCurrentDraft)
        let fields: [(ReferenceWritableKeyPath<TeachingSessionModel, String>, String)] = [
            (\.draftName, "Changed name"), (\.draftDescription, "Changed description"),
            (\.draftGoal, "Changed goal"), (\.draftInputSchema, #"{"flag":true}"#),
            (\.draftPrerequisites, "Changed prerequisites"), (\.draftSteps, "Changed steps"),
            (\.draftResultChecks, "Changed result checks")
        ]
        for (field, edited) in fields {
            let reviewed = teaching[keyPath: field]
            teaching[keyPath: field] = edited
            XCTAssertFalse(teaching.hasReviewedCurrentDraft)
            await teaching.save()
            XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/save-version"), 0)
            XCTAssertEqual(teaching[keyPath: field], edited)
            XCTAssertEqual(teaching.session?.state, "skillDraft")
            XCTAssertEqual(teaching.failure, "Review your latest changes before saving.")
            teaching[keyPath: field] = reviewed
            XCTAssertTrue(teaching.hasReviewedCurrentDraft)
        }
        teaching.draftSteps = "Save only these newly reviewed instructions"
        await teaching.review()
        XCTAssertTrue(teaching.hasReviewedCurrentDraft)
        let review = try XCTUnwrap(TeachingLifecycleURLProtocol.bodies(suffix: "/review").last)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: review) as? [String: Any])
        XCTAssertEqual(payload["steps"] as? String, teaching.draftSteps)
        await teaching.save()
        XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/save-version"), 1)
        XCTAssertEqual(teaching.session?.state, "approvedVersion")
    }

    @MainActor func testTeachingNewerSessionRevisionRequiresAnotherReviewBeforeSave() async throws {
        let (teaching, root) = try teachingModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await teaching.start()
        await teaching.stop()
        await teaching.review()
        let reviewed = try XCTUnwrap(teaching.session)
        let draft = teaching.draftSteps
        var latest = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reviewed)) as? [String: Any])
        latest["revision"] = reviewed.revision + 1
        latest["steps"] = "A newer accepted review"
        teaching.session = try JSONDecoder().decode(TeachingSession.self, from: JSONSerialization.data(withJSONObject: latest))
        XCTAssertFalse(teaching.hasReviewedCurrentDraft)
        await teaching.save()
        XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/save-version"), 0)
        XCTAssertEqual(teaching.draftSteps, draft)
    }

    @MainActor func testTeachingLateReviewReceiptDoesNotApproveNewerEdits() async throws {
        let (teaching, root) = try teachingModel()
        defer { try? FileManager.default.removeItem(at: root); TeachingLifecycleURLProtocol.releaseHeld() }
        await teaching.start()
        await teaching.stop()
        TeachingLifecycleURLProtocol.hold(method: "POST", suffix: "/review")
        let review = Task { await teaching.review() }
        try await waitForTeachingRequest(suffix: "/review")
        teaching.draftSteps = "Edited after the review request was sent"
        TeachingLifecycleURLProtocol.releaseHeld()
        await review.value
        XCTAssertFalse(teaching.hasReviewedCurrentDraft)
        await teaching.save()
        XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/save-version"), 0)
        XCTAssertEqual(teaching.draftSteps, "Edited after the review request was sent")
        XCTAssertEqual(teaching.session?.state, "skillDraft")
    }

    @MainActor func testTeachingReviewDraftSurvivesControlEndWithoutRecordingAgain() async throws {
        let (teaching, root) = try teachingModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await teaching.start()
        await teaching.stop()
        let sessionID = try XCTUnwrap(teaching.session?.id)
        teaching.draftName = "My unsaved review"
        teaching.draftSteps = "Keep my edited instructions"
        for expectedState in ["reviewing", "skillDraft"] {
            XCTAssertEqual(teaching.session?.state, expectedState)
            XCTAssertTrue(teaching.hasReviewDraft)
            XCTAssertFalse(teaching.hasCaptureToResolve)
            teaching.markControlEnded()
            await teaching.controlEnded()
            XCTAssertEqual(teaching.session?.id, sessionID)
            XCTAssertEqual(teaching.session?.state, expectedState)
            XCTAssertEqual(teaching.draftName, "My unsaved review")
            XCTAssertEqual(teaching.draftSteps, "Keep my edited instructions")
            XCTAssertFalse(teaching.interrupted)
            if expectedState == "reviewing" { await teaching.review() }
        }
        XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/sessions"), 1)
        XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/cancel"), 0)
    }

    @MainActor func testTeachingNewTaskRequiresResolvedCaptureAndExplicitReset() async throws {
        let (teaching, root) = try teachingModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await teaching.start()
        XCTAssertFalse(teaching.canStartAnotherTask)
        teaching.startAnotherTask()
        XCTAssertTrue(teaching.isRecording)
        await teaching.cancel()
        XCTAssertTrue(teaching.canStartAnotherTask)
        XCTAssertEqual(teaching.session?.state, "cancelled")
        teaching.startAnotherTask()
        XCTAssertNil(teaching.session)
        XCTAssertFalse(teaching.interrupted)
        XCTAssertFalse(teaching.hasCaptureToResolve)
        XCTAssertEqual(teaching.outcome, "")
        XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/sessions"), 1)
    }

    @MainActor func testTeachingHostInterruptionStaysVisibleWithoutRestarting() async throws {
        let (teaching, root) = try teachingModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await teaching.start()
        TeachingLifecycleURLProtocol.interruptNextRead()
        await teaching.readSession()
        XCTAssertEqual(teaching.session?.state, "interrupted")
        XCTAssertTrue(teaching.interrupted)
        XCTAssertFalse(teaching.isRecording)
        XCTAssertFalse(teaching.hasCaptureToResolve)
        XCTAssertTrue(teaching.canStartAnotherTask)
        XCTAssertNotNil(teaching.failure)
        XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/sessions"), 1)
    }

    @MainActor func testTeachingValidatesOutcomeByteLimitBeforeStarting() async throws {
        let (teaching, root) = try teachingModel()
        defer { try? FileManager.default.removeItem(at: root) }
        teaching.outcome = String(repeating: "😀", count: 501)
        await teaching.start()
        XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/sessions"), 0)
        XCTAssertNotNil(teaching.failure)
        teaching.outcome = String(repeating: "😀", count: 500)
        await teaching.start()
        XCTAssertEqual(TeachingLifecycleURLProtocol.count(suffix: "/sessions"), 1)
        XCTAssertTrue(teaching.isRecording)
    }

    @MainActor private func teachingModel() throws -> (TeachingSessionModel, URL) {
        TeachingLifecycleURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeachingLifecycleURLProtocol.self]
        let saved = try JSONDecoder().decode(SavedConnection.self, from: Data(#"{"origin":"https://teaching-unit.invalid","credential":{"sessionToken":"fixture-session","deviceId":"fixture-device","csrfToken":"fixture-csrf","hostInstallationId":"fixture-host"}}"#.utf8))
        let connection = ConnectionModel(cameraFixtureStoreRoot: root, saved: saved,
            api: PairingAPI(configuration: configuration), replayEnabled: false)
        let teaching = TeachingSessionModel(model: connection, botID: "fixture-bot", botName: "Fixture",
            conversationID: "computer-fixture", computerSessionID: "fixture-computer-session",
            controlLeaseID: "fixture-control-lease", controlBindingIsActive: { true })
        teaching.response = BotSkillListResponse(capability: TeachingLifecycleURLProtocol.capability, skills: [])
        teaching.outcome = "Create a preview file"
        return (teaching, root)
    }

    @MainActor private func waitForTeachingRequest(suffix: String) async throws {
        for _ in 0..<100 {
            if TeachingLifecycleURLProtocol.count(suffix: suffix) > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The synthetic teaching request was not received")
        throw URLError(.timedOut)
    }
}

private final class TeachingLifecycleURLProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests: [(String, Data)] = []
        var heldMethod: String?
        var heldSuffix: String?
        var held: [() -> Void] = []
        var failStart = false
        var requestID = ""
        var interruptRead = false
        var recordingRevision = 1
        var alwaysConflict = false
    }
    private static let state = State()
    static let capability = TeachingCapability(available: true, action: "none", reason: "Synthetic teaching",
        provider: "authenticated-remote-control-v1", maxDurationSeconds: 600, maxEvents: 20_000, maxEvidenceBytes: 52_428_800)
    static func reset() {
        releaseHeld()
        state.lock.withLock { state.requests = []; state.failStart = false; state.requestID = ""; state.interruptRead = false; state.recordingRevision = 1; state.alwaysConflict = false }
    }
    static func advanceCaptureRevision(alwaysConflict: Bool = false) {
        state.lock.withLock { state.recordingRevision = 3; state.alwaysConflict = alwaysConflict }
    }
    static func interruptNextRead() { state.lock.withLock { state.interruptRead = true } }
    static func failNextStart() { state.lock.withLock { state.failStart = true } }
    static func hold(method: String, suffix: String) {
        state.lock.withLock { state.heldMethod = method; state.heldSuffix = suffix }
    }
    static func releaseHeld() {
        let work = state.lock.withLock {
            let work = state.held; state.held = []; state.heldMethod = nil; state.heldSuffix = nil; return work
        }
        work.forEach { $0() }
    }
    static func count(suffix: String) -> Int { state.lock.withLock { state.requests.filter { $0.0.hasSuffix(suffix) }.count } }
    static func bodies(suffix: String) -> [Data] { state.lock.withLock { state.requests.filter { $0.0.hasSuffix(suffix) }.map(\.1) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "teaching-unit.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let size = stream.read(&buffer, maxLength: buffer.count)
                guard size > 0 else { break }
                body.append(contentsOf: buffer.prefix(size))
            }
        }
        let path = request.url!.path
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let action: (Bool, Bool) = Self.state.lock.withLock {
            Self.state.requests.append((path, body))
            if let id = payload?["clientRequestId"] as? String, path.hasSuffix("/sessions") { Self.state.requestID = id }
            let fail = path.hasSuffix("/sessions") && Self.state.failStart
            if fail { Self.state.failStart = false }
            let hold = Self.state.heldMethod == request.httpMethod && Self.state.heldSuffix.map(path.hasSuffix) == true
            if hold { Self.state.held.append { [weak self] in self?.respond(path: path, fail: fail) } }
            return (fail, hold)
        }
        if !action.1 { respond(path: path, fail: action.0) }
    }
    private func respond(path: String, fail: Bool) {
        if fail { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let (id, revision, alwaysConflict) = Self.state.lock.withLock {
            (Self.state.requestID, Self.state.recordingRevision, Self.state.alwaysConflict)
        }
        if path.hasSuffix("/stop") {
            let data = Self.bodies(suffix: "/stop").last ?? Data()
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if alwaysConflict || body?["expectedRevision"] as? Int != revision {
                finish(status: 409, body: Data("{}".utf8))
                return
            }
        }
        let body: Data
        if path.hasSuffix("/save-version") {
            let value: [String: Any] = ["teachingSession": Self.sessionObject(state: "approvedVersion", revision: 4, requestID: id),
                "skill": Self.skillObject(id: "saved"), "version": Self.versionObject()]
            body = try! JSONSerialization.data(withJSONObject: value)
        } else {
            let interrupted = Self.state.lock.withLock { Self.state.interruptRead }
            let status: (String, Int) = path.hasSuffix("/capture") && interrupted ? ("interrupted", 2) : path.hasSuffix("/cancel") ? ("cancelled", 5)
                : path.hasSuffix("/review") ? ("skillDraft", 3) : path.hasSuffix("/stop") ? ("reviewing", revision + 1) : ("recording", revision)
            body = try! JSONSerialization.data(withJSONObject: Self.sessionObject(state: status.0, revision: status.1, requestID: id))
        }
        finish(status: 200, body: body)
    }
    private func finish(status: Int, body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    private static func sessionObject(state: String, revision: Int, requestID: String) -> [String: Any] {
        ["id": "capture", "clientRequestId": requestID, "ownerDeviceId": "fixture-device", "hostInstallationId": "fixture-host",
         "botId": "fixture-bot", "conversationId": "computer-fixture", "computerSessionId": "fixture-computer-session",
         "controlLeaseId": "fixture-control-lease", "state": state, "captureScope": "authenticated-remote-control",
         "captureProvider": "authenticated-remote-control-v1", "outcome": "Create a preview file", "revision": revision,
         "eventCount": 1, "evidenceBytes": 0, "createdAt": "2026-09-19T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z",
         "events": [], "capability": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(capability))]
    }
    static func skillData(id: String) throws -> Data { try JSONSerialization.data(withJSONObject: skillObject(id: id)) }
    private static func skillObject(id: String) -> [String: Any] {
        ["id": id, "botId": "fixture-bot", "slug": id, "name": "Preview file", "description": "Reviewed task",
         "state": "active", "activeVersion": 1, "discoverability": "bot-private", "versions": [versionObject()]]
    }
    private static func versionObject() -> [String: Any] {
        ["id": "version", "version": 1, "sourceSessionId": "capture", "contentHash": String(repeating: "a", count: 64),
         "inputSchema": [:], "createdAt": "2026-09-19T00:00:00Z", "verificationState": "unverified"]
    }
}
