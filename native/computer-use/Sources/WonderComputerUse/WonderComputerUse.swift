import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WonderComputerUseCore

private let maxTextLength = 4_096
private let maxScreenshotBytes = 16 * 1024 * 1024
private let maxRequestBytes = 64 * 1024
private let stdinReadSize = 4 * 1024
private let controlLeaseLifetime: TimeInterval = 10

// Local Stop is exposed in Wonder's existing menu bar menu. The helper owns
// the active lease and held inputs; the notification can only revoke control.
private final class ControlSurfaceController: NSObject, @unchecked Sendable {
    private var stopHandler: (() -> Void)?

    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(stopControl),
            name: Notification.Name("com.wonder.stop-control"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    @MainActor
    func show(stopHandler: @escaping () -> Void) {
        self.stopHandler = stopHandler
    }

    @MainActor
    func hide() {
        stopHandler = nil
    }

    @objc private func stopControl() {
        Task { @MainActor [weak self] in self?.stopHandler?() }
    }
}

@main
struct WonderComputerUse {
    private final class HeldInputState: @unchecked Sendable {
        var mouseButtons: Set<String> = []
        var keyCodes: Set<UInt16> = []
    }

    private static let publisher = WebRTCPublisher { object in
        write(object)
    }

    private static let captureSession = ScreenCaptureSession(eventSink: { event in
        guard let object = jsonObject(event) else { return }
        write(object)
    }, frameSink: { frame in
        publisher.push(frame)
    })

    private static let controlGate = ControlLeaseGate(
        consentProvider: { identity in requestLocalControlConsent(identity) },
        enabledProvider: { controlPreferenceEnabled() }
    )
    private static let heldInput = HeldInputState()
    private static let controlSurface = ControlSurfaceController()

    @MainActor static func main() {
        // A permission-only helper never reads screen content or accepts input actions.
        // Relaunching this same executable avoids caching grants across helper updates.
        if CommandLine.arguments.contains("--permissions") {
            if CommandLine.arguments.contains("--request-screen") {
                _ = CGRequestScreenCaptureAccess()
            }
            if CommandLine.arguments.contains("--request-input") {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            }
            write(["screenRecording": CGPreflightScreenCaptureAccess(),
                   "accessibility": AXIsProcessTrusted()])
            exit(EXIT_SUCCESS)
        }
        let dryRun = CommandLine.arguments.contains("--dry-run")
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        startStdinReader(dryRun: dryRun)
        _ = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if !controlPreferenceEnabled(), let identity = controlGate.activeIdentity() {
                revokeActiveControl(identity, reason: "control_disabled")
            } else if let identity = controlGate.expireAndReturnIdentity() {
                releaseHeldInput()
                MainActor.assumeIsolated {
                    controlSurface.hide()
                }
                emitControlRevoked(identity, reason: "lease_expired")
            }
        }
        // ScreenCaptureKit's picker and observer callbacks are delivered on
        // the process run loop. Keep request parsing off this thread, but
        // serialize each request back onto the main run loop.
        application.run()
    }

    private static func startStdinReader(dryRun: Bool) {
        DispatchQueue(label: "com.wonder.computer-use.stdin", qos: .userInitiated).async {
            var line = Data()
            line.reserveCapacity(maxRequestBytes)
            var discardingOversizedLine = false

            while true {
                var chunk = [UInt8](repeating: 0, count: stdinReadSize)
                let count = chunk.withUnsafeMutableBytes { buffer in
                    Darwin.read(STDIN_FILENO, buffer.baseAddress, buffer.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }

                for byte in chunk.prefix(count) {
                    if discardingOversizedLine {
                        if byte == 0x0A {
                            discardingOversizedLine = false
                        }
                        continue
                    }
                    if byte == 0x0A {
                        enqueue(line, dryRun: dryRun)
                        line.removeAll(keepingCapacity: true)
                    } else if line.count < maxRequestBytes {
                        line.append(byte)
                    } else {
                        enqueueInvalidRequest()
                        line.removeAll(keepingCapacity: true)
                        discardingOversizedLine = true
                    }
                }
            }

            DispatchQueue.main.async {
                _ = captureSession.shutdown(reason: "stdin_closed")
                releaseHeldInput()
                _ = controlGate.releaseAll()
                exit(0)
            }
        }
    }

    private static func enqueue(_ data: Data, dryRun: Bool) {
        var data = data
        if data.last == 0x0D {
            data.removeLast()
        }
        guard let line = String(data: data, encoding: .utf8) else {
            enqueueInvalidRequest()
            return
        }
        DispatchQueue.main.async {
            handle(line, dryRun: dryRun)
        }
    }

    private static func enqueueInvalidRequest() {
        DispatchQueue.main.async {
            write(["error": "invalid_request"])
        }
    }

    @MainActor
    private static func handle(_ line: String, dryRun: Bool) {
        precondition(Thread.isMainThread)
        guard line.utf8.count <= maxRequestBytes,
              let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = request["method"] as? String else {
            write(["error": "invalid_request"])
            return
        }
        let id = request["id"]
        let params = request["params"] as? [String: Any] ?? [:]
        do {
            if method != "stop" {
                try requireHandshake(params)
            }
            var result: [String: Any]
            switch method {
            case "capabilities":
                result = [
                    "protocolVersion": 1,
                    "capture": ["available": true],
                    "control": [
                        "available": AXIsProcessTrusted(),
                        "provider": "core-graphics-v1",
                        "requiresAccessibility": true,
                    ],
                ]
            case "status":
                result = [
                    "accessibility": AXIsProcessTrusted(),
                    "screenRecording": CGPreflightScreenCaptureAccess(),
                    "lockedUse": false,
                    "dryRun": dryRun,
                    "observation": accessibilityObservation(),
                    "capture": jsonObject(captureSession.status()) as Any,
                ]
            case "screenshot":
                result = try screenshot()
                    .merging(["observation": accessibilityObservation()]) { current, _ in current }
            case "click":
                try click(params, dryRun: dryRun)
                result = ["accepted": true, "dryRun": dryRun, "observation": accessibilityObservation()]
            case "type":
                try typeText(params, dryRun: dryRun)
                result = ["accepted": true, "dryRun": dryRun, "observation": accessibilityObservation()]
            case "key":
                try keyPress(params, dryRun: dryRun)
                result = ["accepted": true, "dryRun": dryRun, "observation": accessibilityObservation()]
            case "focusApp":
                try focusApp(params, dryRun: dryRun)
                result = ["accepted": true, "dryRun": dryRun, "observation": accessibilityObservation()]
            case "control.consent":
                let identity = try controlIdentity(params)
                try requireCaptureBinding(identity)
                if !controlPreferenceEnabled() {
                    revokeActiveControl(identity, reason: "control_disabled")
                    result = ["granted": false, "decision": "deny", "replayed": false, "reason": "control_disabled"]
                    break
                }
                switch controlGate.requestConsent(identity) {
                case let .allowOnce(replayed):
                    result = ["granted": true, "decision": "allowOnce", "replayed": replayed]
                case let .denied(replayed):
                    result = [
                        "granted": false,
                        "decision": "deny",
                        "replayed": replayed,
                        "reason": controlPreferenceEnabled() ? "consent_denied" : "control_disabled",
                    ]
                case .identityConflict:
                    result = ["granted": false, "decision": "deny", "reason": "request_identity_conflict"]
                }
            case "control.activate":
                let identity = try controlIdentity(params)
                try requireCaptureBinding(identity)
                if !controlPreferenceEnabled() {
                    revokeActiveControl(identity, reason: "control_disabled")
                    result = ["activated": false, "reason": "control_disabled"]
                    break
                }
                switch controlGate.activate(identity, now: Date(), lifetime: controlLeaseLifetime) {
                case let .activated(replayed):
                    controlSurface.show {
                        _ = controlGate.release(identity)
                        releaseHeldInput()
                        controlSurface.hide()
                        emitControlRevoked(identity, reason: "local_stop")
                    }
                    result = ["activated": true, "replayed": replayed]
                case .consentRequired:
                    result = ["activated": false, "reason": "consent_required"]
                case .denied:
                    result = ["activated": false, "reason": "consent_denied"]
                case .busy:
                    result = ["activated": false, "reason": "control_busy"]
                case .identityConflict:
                    result = ["activated": false, "reason": "request_identity_conflict"]
                }
            case "control.heartbeat":
                let identity = try controlIdentity(params)
                try requireCaptureBinding(identity)
                if !controlPreferenceEnabled() {
                    revokeActiveControl(identity, reason: "control_disabled")
                    result = ["renewed": false, "reason": "control_disabled"]
                    break
                }
                result = ["renewed": controlGate.heartbeat(identity, now: Date(), lifetime: controlLeaseLifetime)]
            case "control.input":
                let identity = try controlIdentity(params)
                try requireCaptureBinding(identity)
                if !controlPreferenceEnabled() {
                    revokeActiveControl(identity, reason: "control_disabled")
                    result = ["accepted": false, "reason": "control_disabled"]
                    break
                }
                guard captureSession.status().state == .capturing else {
                    result = ["accepted": false, "reason": "capture_not_live"]
                    break
                }
                guard let sequence = number(params["sequence"]), sequence > 0,
                      let rawActions = params["actions"] as? [[String: Any]],
                      !rawActions.isEmpty,
                      rawActions.count <= 32,
                      let actionsData = try? JSONSerialization.data(withJSONObject: rawActions),
                      let actions = try? JSONDecoder().decode([ControlInputAction].self, from: actionsData),
                      actions.count == rawActions.count,
                      validControlBatch(actions) else {
                    throw ComputerUseError.invalidInput
                }
                let payload = try JSONEncoder().encode(actions)
                var clipboardText: String?
                let delivery = controlGate.deliver(identity, sequence: sequence, payload: payload) {
                    if dryRun { return true }
                    do {
                        clipboardText = try deliverControlActions(actions, clipboardText: &clipboardText)
                        return true
                    } catch {
                        releaseHeldInput()
                        return false
                    }
                }
                switch delivery {
                case .delivered:
                    result = ["accepted": true, "duplicate": false]
                case .duplicate:
                    result = ["accepted": true, "duplicate": true]
                case let .rejected(reason):
                    if reason == "control_disabled" {
                        releaseHeldInput()
                        MainActor.assumeIsolated {
                            controlSurface.hide()
                        }
                        emitControlRevoked(identity, reason: "control_disabled")
                    }
                    result = ["accepted": false, "reason": reason]
                }
                if let clipboardText { result["clipboardText"] = clipboardText }
            case "control.release":
                let identity = try controlIdentity(params)
                let released = controlGate.release(identity)
                if released {
                    releaseHeldInput()
                    controlSurface.hide()
                }
                result = ["released": released]
            case "control.releaseAll":
                releaseHeldInput()
                controlSurface.hide()
                result = ["released": controlGate.releaseAll()]
            case "control.revoke":
                releaseHeldInput()
                controlSurface.hide()
                result = ["released": controlGate.releaseAll()]
            case "capture.prepare", "prepare":
                let sessionID: String
                if let suppliedSessionID = params["sessionID"] as? String {
                    guard !suppliedSessionID.isEmpty, suppliedSessionID.count <= 128 else { throw ComputerUseError.invalidInput }
                    sessionID = suppliedSessionID
                } else {
                    sessionID = UUID().uuidString
                }
                let generation = number(params["generation"]) ?? 0
                let viewerCount = Int(min(number(params["viewerCount"]) ?? 1, UInt64(Int.max)))
                let captureResult = captureSession.prepare(sessionID: sessionID, generation: generation, viewerCount: viewerCount)
                if captureResult.accepted {
                    publisher.prepare(sessionID: sessionID, generation: generation)
                }
                result = jsonObject(captureResult) ?? [:]
            case "capture.sources", "capture.listSources", "listSources":
                result = jsonObject(captureSession.listSources()) ?? [:]
            case "capture.pick", "pick":
                if let sessionID = params["sessionID"] as? String {
                    let status = captureSession.status()
                    guard let generation = number(params["generation"]),
                          sessionID == status.sessionID,
                          generation == status.generation else {
                        throw ComputerUseError.invalidInput
                    }
                }
                result = jsonObject(captureSession.pick(sourceID: params["sourceID"] as? String)) ?? [:]
            case "capture.start", "startCapture":
                result = jsonObject(captureSession.start(
                    sessionID: try captureSessionID(params),
                    generation: try captureGeneration(params)
                )) ?? [:]
            case "capture.pause", "pauseCapture":
                result = jsonObject(captureSession.pause(
                    sessionID: try captureSessionID(params),
                    generation: try captureGeneration(params)
                )) ?? [:]
            case "capture.resume", "resumeCapture":
                result = jsonObject(captureSession.resume(
                    sessionID: try captureSessionID(params),
                    generation: try captureGeneration(params)
                )) ?? [:]
            case "capture.stop", "stopCapture":
                let reason = (params["reason"] as? String) ?? "stopped_by_request"
                guard !reason.isEmpty, reason.count <= 128 else { throw ComputerUseError.invalidInput }
                let sessionID = try captureSessionID(params)
                let generation = try captureGeneration(params)
                let captureResult = captureSession.stop(
                    sessionID: sessionID,
                    generation: generation,
                    reason: reason
                )
                guard publisher.close(sessionID: sessionID, generation: generation, reason: reason) else {
                    throw ComputerUseError.invalidInput
                }
                result = jsonObject(captureResult) ?? [:]
            case "capture.sourceRemoved":
                let sessionID = try captureSessionID(params)
                let generation = try captureGeneration(params)
                let captureResult = captureSession.markSourceRemoved(
                    sessionID: sessionID,
                    generation: generation
                )
                _ = publisher.close(sessionID: sessionID, generation: generation, reason: "source_removed")
                result = jsonObject(captureResult) ?? [:]
            case "capture.status":
                result = jsonObject(captureSession.status()) ?? [:]
            case "capture.viewerCount":
                result = jsonObject(captureSession.setViewerCount(
                    Int(min(number(params["viewerCount"]) ?? 0, UInt64(Int.max))),
                    sessionID: try captureSessionID(params),
                    generation: try captureGeneration(params)
                )) ?? [:]
            case "capture.restart":
                publisher.close(reason: "helper_restart")
                result = jsonObject(captureSession.restart()) ?? [:]
            case "signal.answer":
                guard let sdp = params["sdp"] as? String,
                      let sessionID = params["sessionID"] as? String,
                      let generation = number(params["generation"]),
                      let peerRevision = params["peerRevision"] as? String,
                      validSignalText(peerRevision, maximumBytes: 128),
                      publisher.setRemoteAnswer(sessionID: sessionID, generation: generation,
                                                peerRevision: peerRevision, sdp: sdp) else {
                    throw ComputerUseError.invalidInput
                }
                result = ["accepted": true]
            case "signal.candidate":
                guard let candidate = params["candidate"] as? String,
                      let sessionID = params["sessionID"] as? String,
                      let generation = number(params["generation"]),
                      let peerRevision = params["peerRevision"] as? String,
                      validSignalText(peerRevision, maximumBytes: 128),
                      let sequence = number(params["sequence"]),
                      let rawIndex = exactInt32(params["sdpMLineIndex"]) else {
                    throw ComputerUseError.invalidInput
                }
                let sdpMid = params["sdpMid"] as? String
                let usernameFragment = params["usernameFragment"] as? String
                guard publisher.addRemoteCandidate(sessionID: sessionID, generation: generation,
                                                    peerRevision: peerRevision,
                                                    sequence: sequence, sdp: candidate, sdpMid: sdpMid,
                                                    sdpMLineIndex: rawIndex, usernameFragment: usernameFragment) else {
                    throw ComputerUseError.invalidInput
                }
                result = ["accepted": true]
            case "signal.close":
                let reason = (params["reason"] as? String) ?? "closed_by_request"
                guard let sessionID = params["sessionID"] as? String,
                      let generation = number(params["generation"]),
                      let peerRevision = params["peerRevision"] as? String,
                      validSignalText(peerRevision, maximumBytes: 128),
                      validSignalText(reason, maximumBytes: 128) else { throw ComputerUseError.invalidInput }
                guard publisher.close(sessionID: sessionID, generation: generation,
                                      peerRevision: peerRevision, reason: reason) else {
                    throw ComputerUseError.invalidInput
                }
                result = ["closed": true, "sessionID": sessionID, "generation": generation]
            case "stop":
                _ = captureSession.shutdown()
                releaseHeldInput()
                _ = controlGate.releaseAll()
                publisher.close(reason: "helper_stopped")
                writeResponse(id: id, result: ["stopped": true])
                exit(0)
            default:
                throw ComputerUseError.unsupportedAction
            }
            if method != "stop" { result["action"] = method }
            writeResponse(id: id, result: result)
        } catch let error as ComputerUseError {
            writeResponse(id: id, error: error.rawValue)
        } catch {
            writeResponse(id: id, error: "computer_use_failed")
        }
    }

    private static func screenshot() throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else {
            throw ComputerUseError.screenRecordingRequired
        }
        guard let image = CGWindowListCreateImage(
            .null,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            throw ComputerUseError.screenRecordingRequired
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ComputerUseError.screenshotFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= maxScreenshotBytes else {
            throw ComputerUseError.screenshotFailed
        }
        return [
            "mimeType": "image/png",
            "imageBase64": (data as Data).base64EncodedString(),
        ]
    }

    private static func click(_ params: [String: Any], dryRun: Bool) throws {
        try requireAccessibility()
        let point = try screenPoint(params)
        if dryRun { return }
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw ComputerUseError.inputUnavailable
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func typeText(_ params: [String: Any], dryRun: Bool) throws {
        try requireAccessibility()
        guard let text = params["text"] as? String,
              !text.isEmpty,
              text.count <= maxTextLength else {
            throw ComputerUseError.invalidInput
        }
        if dryRun { return }
        let utf16 = Array(text.utf16)
        for start in stride(from: 0, to: utf16.count, by: 64) {
            let end = min(start + 64, utf16.count)
            let chunk = Array(utf16[start..<end])
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
                throw ComputerUseError.inputUnavailable
            }
            event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            event.post(tap: .cghidEventTap)
        }
    }

    private static func keyPress(_ params: [String: Any], dryRun: Bool) throws {
        try requireAccessibility()
        guard let rawKeyCode = params["keyCode"] as? NSNumber,
              rawKeyCode.intValue >= 0,
              rawKeyCode.intValue <= Int(UInt16.max) else {
            throw ComputerUseError.invalidInput
        }
        let allowedModifiers = CGEventFlags.maskShift.rawValue
            | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskAlphaShift.rawValue
        let rawModifiers = (params["modifiers"] as? NSNumber)?.uint64Value ?? 0
        guard rawModifiers & ~allowedModifiers == 0 else {
            throw ComputerUseError.invalidInput
        }
        if dryRun { return }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(rawKeyCode.intValue), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(rawKeyCode.intValue), keyDown: false) else {
            throw ComputerUseError.inputUnavailable
        }
        let flags = CGEventFlags(rawValue: rawModifiers)
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func focusApp(_ params: [String: Any], dryRun: Bool) throws {
        guard let bundleId = params["bundleId"] as? String,
              bundleId.count <= 256 else {
            throw ComputerUseError.appNotFound
        }
        if dryRun { return }
        guard let application = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) else {
            throw ComputerUseError.appNotFound
        }
        guard application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) else {
            throw ComputerUseError.inputUnavailable
        }
    }

    private static func controlIdentity(_ params: [String: Any]) throws -> ControlLeaseIdentity {
        let sourceID: String?
        if let rawSourceID = params["sourceID"], !(rawSourceID is NSNull) {
            guard let value = rawSourceID as? String else { throw ComputerUseError.invalidInput }
            sourceID = value
        } else {
            sourceID = nil
        }
        guard let leaseID = boundedString(params["leaseID"], maximum: 128),
              let requestID = boundedString(params["requestID"], maximum: 160),
              let sessionID = boundedString(params["sessionID"], maximum: 128),
              let generation = number(params["generation"]), generation > 0,
              let geometryRevision = number(params["geometryRevision"]) else {
            throw ComputerUseError.invalidInput
        }
        if let sourceID, !validSignalText(sourceID, maximumBytes: 160) { throw ComputerUseError.invalidInput }
        return ControlLeaseIdentity(
            leaseID: leaseID,
            requestID: requestID,
            sessionID: sessionID,
            generation: generation,
            geometryRevision: geometryRevision,
            sourceID: sourceID
        )
    }

    private static func requireCaptureBinding(_ identity: ControlLeaseIdentity) throws {
        let status = captureSession.status()
        guard status.sessionID == identity.sessionID,
              status.generation == identity.generation,
              status.sourceID == identity.sourceID,
              status.geometryRevision == identity.geometryRevision else {
            throw ComputerUseError.invalidInput
        }
    }

    private static func controlPreferenceEnabled() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["WONDER_SERVICE_DIR"] else {
            return false
        }
        return ControlPreferencesStore(serviceDirectory: URL(fileURLWithPath: path)).isEnabled
    }

    private static func requestLocalControlConsent(_ identity: ControlLeaseIdentity) -> ControlConsentDecision {
        // The preference gate is checked again by ControlLeaseGate before it
        // records this decision. There is intentionally no modal consent path:
        // only the local Mac Settings toggle can opt in.
        _ = identity
        return .allowOnce
    }

    @discardableResult
    private static func revokeActiveControl(_ identity: ControlLeaseIdentity, reason: String) -> Bool {
        guard controlGate.release(identity) else { return false }
        releaseHeldInput()
        MainActor.assumeIsolated {
            controlSurface.hide()
        }
        emitControlRevoked(identity, reason: reason)
        return true
    }

    private static func emitControlRevoked(_ identity: ControlLeaseIdentity, reason: String) {
        var event: [String: Any] = [
            "event": "control.revoked",
            "sessionID": identity.sessionID,
            "generation": identity.generation,
            "leaseID": identity.leaseID,
            "requestID": identity.requestID,
            "geometryRevision": identity.geometryRevision,
            "reason": reason,
        ]
        if let sourceID = identity.sourceID {
            event["sourceID"] = sourceID
        }
        write(event)
    }

    private static func boundedString(_ value: Any?, maximum: Int) -> String? {
        guard let value = value as? String,
              !value.isEmpty,
              value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return value
    }

    private static func validControlAction(_ action: ControlInputAction) -> Bool {
        switch action {
        case let .pointer(x, y, phase, button):
            return x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
                && ["move", "down", "up"].contains(phase)
                && button.map { ["left", "right", "middle"].contains($0) } ?? true
                && (phase == "move" || button != nil)
        case let .scroll(deltaX, deltaY):
            return deltaX.isFinite && deltaY.isFinite && abs(deltaX) <= 4_096 && abs(deltaY) <= 4_096
        case let .key(key, phase, modifiers):
            return !key.isEmpty && key.count <= 32 && ControlInputTranslator.keyCode(for: key) != nil
                && ["down", "up", "press"].contains(phase)
                && modifiers & ~ControlInputTranslator.allowedModifierMask == 0
        case let .text(text):
            return ControlInputTranslator.validText(text, maximum: maxTextLength)
        case let .clipboard(operation, text):
            return (operation == "copyToPhone" && text == nil) || (operation == "pasteFromPhone" && text.map { ControlInputTranslator.validText($0, maximum: 8_192, allowEmpty: true) } == true)
        case .releaseAll:
            return true
        }
    }

    private static func validControlBatch(_ actions: [ControlInputAction]) -> Bool {
        guard actions.allSatisfy(validControlAction) else { return false }
        let containsPasteFromPhone = actions.contains { action in
            if case let .clipboard(operation, _) = action {
                return operation == "pasteFromPhone"
            }
            return false
        }
        return !containsPasteFromPhone || actions.count == 1
    }

    private enum PreparedControlEffect {
        case post(CGEvent)
        case setMouseHeld(String, Bool)
        case setKeyHeld(UInt16, Bool)
        case setClipboardResult(String)
    }

    private static func deliverControlActions(_ actions: [ControlInputAction], clipboardText: inout String?) throws -> String? {
        try requireAccessibility()
        guard let source = captureSession.selectedSourceDescriptor() else { throw ComputerUseError.inputUnavailable }

        var effects: [PreparedControlEffect] = []
        var preparedMouseButtons = heldInput.mouseButtons
        var preparedKeyCodes = heldInput.keyCodes
        var preparedPointerLocation = CGEvent(source: nil)?.location ?? .zero
        var preparedClipboard: String?
        var readSystemClipboard = false

        func appendKey(keyCode: UInt16, phase: String, modifiers: UInt32) throws {
            let flags = modifierFlags(modifiers)
            if phase == "down" || phase == "press" {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else {
                    throw ComputerUseError.inputUnavailable
                }
                event.flags = flags
                effects.append(.post(event))
                effects.append(.setKeyHeld(keyCode, true))
                preparedKeyCodes.insert(keyCode)
            }
            if phase == "up" || phase == "press" {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
                    throw ComputerUseError.inputUnavailable
                }
                event.flags = flags
                effects.append(.post(event))
                effects.append(.setKeyHeld(keyCode, false))
                preparedKeyCodes.remove(keyCode)
            }
        }

        func appendText(_ text: String) throws {
            for chunk in ControlInputTranslator.unicodeEventChunks(text) {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
                    throw ComputerUseError.inputUnavailable
                }
                event.keyboardSetUnicodeString(
                    stringLength: chunk.count,
                    unicodeString: chunk
                )
                effects.append(.post(event))
            }
        }

        for action in actions {
            switch action {
            case let .pointer(x, y, phase, button):
                guard let point = ControlInputTranslator.point(x: x, y: y, in: source) else {
                    throw ComputerUseError.invalidInput
                }
                if phase != "move" && button == nil {
                    throw ComputerUseError.invalidInput
                }
                let buttonName = button ?? "left"
                guard let mouseButton = mouseButton(buttonName, required: phase != "move") else {
                    throw ComputerUseError.invalidInput
                }
                let mouseType: CGEventType = phase == "down" ? .leftMouseDown : phase == "up" ? .leftMouseUp : .mouseMoved
                let eventType = button == nil ? .mouseMoved : mouseEventType(mouseType, button: mouseButton)
                guard let event = CGEvent(
                    mouseEventSource: nil,
                    mouseType: eventType,
                    mouseCursorPosition: CGPoint(x: point.x, y: point.y),
                    mouseButton: mouseButton
                ) else {
                    throw ComputerUseError.inputUnavailable
                }
                effects.append(.post(event))
                preparedPointerLocation = CGPoint(x: point.x, y: point.y)
                if phase == "down" {
                    effects.append(.setMouseHeld(buttonName, true))
                    preparedMouseButtons.insert(buttonName)
                } else if phase == "up" {
                    effects.append(.setMouseHeld(buttonName, false))
                    preparedMouseButtons.remove(buttonName)
                }
            case let .scroll(deltaX, deltaY):
                guard let event = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .pixel,
                    wheelCount: 2,
                    wheel1: Int32(deltaY.rounded()),
                    wheel2: Int32(deltaX.rounded()),
                    wheel3: 0
                ) else {
                    throw ComputerUseError.inputUnavailable
                }
                effects.append(.post(event))
            case let .key(key, phase, modifiers):
                guard let keyCode = ControlInputTranslator.keyCode(for: key) else {
                    throw ComputerUseError.invalidInput
                }
                try appendKey(keyCode: keyCode, phase: phase, modifiers: modifiers)
            case let .text(text):
                try appendText(text)
            case let .clipboard(operation, text):
                if operation == "copyToPhone" {
                    if !readSystemClipboard && preparedClipboard == nil {
                        preparedClipboard = NSPasteboard.general.string(forType: .string)
                        readSystemClipboard = true
                    }
                    guard let value = preparedClipboard, value.count <= 8_192 else {
                        throw ComputerUseError.inputUnavailable
                    }
                    effects.append(.setClipboardResult(value))
                } else if let text {
                    // Insert the phone text directly. This preserves the Mac
                    // clipboard and lets the entire input be prepared before
                    // the first native event is posted.
                    try appendText(text)
                } else {
                    throw ComputerUseError.invalidInput
                }
            case .releaseAll:
                for buttonName in preparedMouseButtons {
                    guard let button = mouseButton(buttonName, required: true),
                          let event = CGEvent(
                            mouseEventSource: nil,
                            mouseType: mouseEventType(.leftMouseUp, button: button),
                            mouseCursorPosition: preparedPointerLocation,
                            mouseButton: button
                          ) else {
                        throw ComputerUseError.inputUnavailable
                    }
                    effects.append(.post(event))
                    effects.append(.setMouseHeld(buttonName, false))
                }
                for keyCode in preparedKeyCodes {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
                        throw ComputerUseError.inputUnavailable
                    }
                    effects.append(.post(event))
                    effects.append(.setKeyHeld(keyCode, false))
                }
                preparedMouseButtons.removeAll()
                preparedKeyCodes.removeAll()
            }
        }

        for effect in effects {
            switch effect {
            case let .post(event):
                event.post(tap: .cghidEventTap)
            case let .setMouseHeld(buttonName, held):
                if held { heldInput.mouseButtons.insert(buttonName) }
                else { heldInput.mouseButtons.remove(buttonName) }
            case let .setKeyHeld(keyCode, held):
                if held { heldInput.keyCodes.insert(keyCode) }
                else { heldInput.keyCodes.remove(keyCode) }
            case let .setClipboardResult(value):
                clipboardText = value
            }
        }
        return clipboardText
    }

    private static func mouseButton(_ name: String, required: Bool) -> CGMouseButton? {
        switch name { case "left": return .left; case "right": return .right; case "middle": return .center; default: return required ? nil : .left }
    }

    private static func mouseEventType(_ type: CGEventType, button: CGMouseButton) -> CGEventType {
        switch (type, button) {
        case (.leftMouseDown, .right): return .rightMouseDown
        case (.leftMouseUp, .right): return .rightMouseUp
        case (.leftMouseDown, .center): return .otherMouseDown
        case (.leftMouseUp, .center): return .otherMouseUp
        case (.mouseMoved, .left): return .leftMouseDragged
        case (.mouseMoved, .right): return .rightMouseDragged
        case (.mouseMoved, .center): return .otherMouseDragged
        default: return type
        }
    }

    private static func modifierFlags(_ modifiers: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & ControlInputTranslator.shiftModifier != 0 { flags.insert(.maskShift) }
        if modifiers & ControlInputTranslator.controlModifier != 0 { flags.insert(.maskControl) }
        if modifiers & ControlInputTranslator.optionModifier != 0 { flags.insert(.maskAlternate) }
        if modifiers & ControlInputTranslator.commandModifier != 0 { flags.insert(.maskCommand) }
        if modifiers & ControlInputTranslator.capsLockModifier != 0 { flags.insert(.maskAlphaShift) }
        return flags
    }

    private static func releaseHeldInput() {
        let point = CGEvent(source: nil)?.location ?? .zero
        for name in heldInput.mouseButtons {
            guard let button = mouseButton(name, required: true),
                  let event = CGEvent(mouseEventSource: nil, mouseType: mouseEventType(.leftMouseUp, button: button), mouseCursorPosition: point, mouseButton: button) else { continue }
            event.post(tap: .cghidEventTap)
        }
        for keyCode in heldInput.keyCodes {
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                event.post(tap: .cghidEventTap)
            }
        }
        heldInput.mouseButtons.removeAll()
        heldInput.keyCodes.removeAll()
    }

    private static func accessibilityObservation() -> [String: Any] {
        let frontmost = NSWorkspace.shared.frontmostApplication
        var observation: [String: Any] = [
            "available": AXIsProcessTrusted(),
            "frontmostApp": frontmost?.localizedName as Any,
            "frontmostBundleId": frontmost?.bundleIdentifier as Any,
        ]
        guard AXIsProcessTrusted() else { return observation }

        let system = AXUIElementCreateSystemWide()
        guard let focusedApplication = axElement(system, attribute: kAXFocusedApplicationAttribute) else {
            return observation
        }
        if let window = axElement(focusedApplication, attribute: kAXFocusedWindowAttribute) {
            observation["window"] = axSummary(window)
        }
        if let focusedElement = axElement(focusedApplication, attribute: kAXFocusedUIElementAttribute) {
            observation["focusedElement"] = axSummary(focusedElement)
        }
        return observation
    }

    private static func axElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func axString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        return value as? String
    }

    private static func axSummary(_ element: AXUIElement) -> [String: Any] {
        var summary: [String: Any] = [:]
        if let role = axString(element, attribute: kAXRoleAttribute) { summary["role"] = role }
        if let subrole = axString(element, attribute: kAXSubroleAttribute) { summary["subrole"] = subrole }
        if let title = axString(element, attribute: kAXTitleAttribute) { summary["title"] = title }
        if let description = axString(element, attribute: kAXDescriptionAttribute) { summary["description"] = description }
        if let identifier = axString(element, attribute: kAXIdentifierAttribute) { summary["identifier"] = identifier }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success {
            summary["valueSettable"] = settable.boolValue
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let value {
            if let text = value as? String {
                summary["valueLength"] = text.count
            } else {
                summary["valueType"] = String(describing: type(of: value))
            }
        }
        return summary
    }

    private static func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw ComputerUseError.accessibilityRequired
        }
    }

    private static func requireHandshake(_ params: [String: Any]) throws {
        guard let expected = ProcessInfo.processInfo.environment["WONDER_COMPUTER_USE_HANDSHAKE"],
              let supplied = params["handshake"] as? String,
              !expected.isEmpty,
              supplied == expected else {
            throw ComputerUseError.handshakeRequired
        }
    }

    private static func number(_ value: Any?) -> UInt64? {
        guard let value = value as? NSNumber,
              String(cString: value.objCType) != "c" else { return nil }
        if let exact = UInt64(value.stringValue) {
            return exact
        }
        guard value.doubleValue.isFinite,
              value.doubleValue >= 0,
              value.doubleValue.rounded(.towardZero) == value.doubleValue,
              value.doubleValue < 18_446_744_073_709_551_616 else { return nil }
        return UInt64(value.doubleValue)
    }

    private static func exactInt32(_ value: Any?) -> Int32? {
        guard let value = value as? NSNumber,
              String(cString: value.objCType) != "c",
              value.doubleValue.isFinite,
              value.doubleValue.rounded(.towardZero) == value.doubleValue,
              value.doubleValue >= 0,
              value.doubleValue <= Double(Int32.max) else { return nil }
        return Int32(value.int64Value)
    }

    private static func validSignalText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    }

    private static func captureSessionID(_ params: [String: Any]) throws -> String {
        guard let sessionID = params["sessionID"] as? String, !sessionID.isEmpty, sessionID.count <= 128 else {
            throw ComputerUseError.invalidInput
        }
        return sessionID
    }

    private static func captureGeneration(_ params: [String: Any]) throws -> UInt64 {
        guard let generation = number(params["generation"]) else { throw ComputerUseError.invalidInput }
        return generation
    }

    private static func jsonObject<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func screenPoint(_ params: [String: Any]) throws -> CGPoint {
        guard let rawX = params["x"] as? NSNumber,
              let rawY = params["y"] as? NSNumber,
              rawX.doubleValue.isFinite,
              rawY.doubleValue.isFinite else {
            throw ComputerUseError.invalidInput
        }
        let point = CGPoint(x: rawX.doubleValue, y: rawY.doubleValue)
        let visibleBounds = NSScreen.screens.reduce(into: CGRect.null) { result, screen in
            result = result.union(screen.visibleFrame)
        }
        guard visibleBounds.contains(point) else {
            throw ComputerUseError.invalidInput
        }
        return point
    }

    private static func write(_ object: [String: Any]) {
        outputLock.lock()
        defer { outputLock.unlock() }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static let outputLock = NSLock()

    private static func writeResponse(id: Any?, result: [String: Any]? = nil, error: String? = nil) {
        var response: [String: Any] = [:]
        if let id { response["id"] = id }
        if let result { response["result"] = result }
        if let error { response["error"] = ["code": error] }
        write(response)
    }
}

private enum ComputerUseError: String, Error {
    case accessibilityRequired = "accessibility_required"
    case appNotFound = "app_not_found"
    case handshakeRequired = "handshake_required"
    case inputUnavailable = "input_unavailable"
    case invalidInput = "invalid_input"
    case screenRecordingRequired = "screen_recording_required"
    case screenshotFailed = "screenshot_failed"
    case unsupportedAction = "unsupported_action"
}
