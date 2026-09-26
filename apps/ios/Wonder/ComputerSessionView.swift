import SwiftUI
import UIKit
import WonderPairing
import WonderComputerView

private struct ComputerEmptyReply: Decodable, Sendable {}

enum ComputerControlState: Equatable {
    case viewOnly
    case starting
    case active
    case stopping
    case failed(String)

    var title: String {
        switch self {
        case .viewOnly: "View only"
        case .starting: "Starting control…"
        case .active: "Control active"
        case .stopping: "Releasing control…"
        case .failed: "Control unavailable"
        }
    }
}

private struct ComputerControlSnapshot: Equatable, Sendable {
    let sessionID: String
    let generation: UInt64
    let geometryRevision: UInt64
    let sourceID: String?
}

@MainActor
final class ComputerSessionModel: ObservableObject {
    let chat: ChatSummary
    private let connectionModel: ConnectionModel
    private(set) var clientRequestID = UUID().uuidString.lowercased()
    private(set) var controlRequestID: String?
    @Published private(set) var session: ComputerSession?
    @Published private(set) var isLoading = false
    @Published private(set) var receiverState: ComputerReceiverState = .preparing
    @Published private(set) var controlState: ComputerControlState = .viewOnly
    @Published private(set) var controlLease: ComputerControlLease?
    @Published private(set) var controlMessage: String?
    @Published private(set) var clipboardMessage: String?
    @Published var keyboardPresented = false
    @Published var failure: String?
    @Published private(set) var zoomScale: CGFloat = 1
    @Published private(set) var viewportCenter = CGPoint(x: 0.5, y: 0.5)
    @Published private(set) var keyboardRevision: UInt64 = 0
    @Published var inputMode: ComputerInputMode {
        didSet {
            guard inputMode != oldValue else { return }
            finishPointerDrag()
            inputPreferences.set(inputMode.rawValue, forKey: "computer.inputMode")
        }
    }
    private let inputPreferences: UserDefaults
    let pointerState = ComputerPointerState()
    private var pointer: CGPoint {
        get { pointerState.position }
        set { pointerState.move(to: newValue) }
    }
    let receiver = ComputerReceiver()
    @Published private var ended = false
    var isClosed: Bool { ended }
    private var lifetimeRevision: UInt64 = 0
    private var receiverRevision: UInt64 = 0
    private var controlTask: Task<Void, Never>?
    private var controlSnapshot: ComputerControlSnapshot?
    private var heartbeatTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var inputBuffer = ComputerInputBuffer()
    private var inputEpoch: UInt64 = 0
    private var heldPointerButton: String?
    private var heldPointerPoint: (x: Double, y: Double)?
    private var releasingControl = false

    init(model: ConnectionModel, chat: ChatSummary, inputPreferences: UserDefaults = .standard) {
        self.inputPreferences = inputPreferences
        self.inputMode = inputPreferences.string(forKey: "computer.inputMode").flatMap(ComputerInputMode.init(rawValue:)) ?? .trackpad
        self.connectionModel = model
        self.chat = chat
        #if WONDER_DIAGNOSTICS
        if ProcessInfo.processInfo.arguments.contains("-diagnostics-computer-session-fixture") {
            inputMode = .trackpad
        }
        #endif
        receiver.onStateChange = { [weak self] state, revision in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard revision > receiverRevision else { return }
                receiverRevision = revision
                guard !ended else { receiverState = .closed; return }
                receiverState = state
                if case .failed(let message) = state { failure = message }
                if state != .live, self.controlLease != nil || self.isStarting {
                    failClosed("The computer view is no longer live. Control was released.")
                }
                if state == .awaitingSource || state == .live { await refresh() }
            }
        }
    }

    var isFixture: Bool {
        #if WONDER_DIAGNOSTICS
        return ProcessInfo.processInfo.arguments.contains("-diagnostics-computer-session-fixture")
        #else
        return false
        #endif
    }

    func start() async {
        guard session == nil, !ended, !isLoading else { return }
        let revision = lifetimeRevision
        let requestID = clientRequestID
        if isFixture || connectionModel.previewMode {
            let available = ProcessInfo.processInfo.arguments.contains("-diagnostics-computer-session-available-fixture")
            let fixture = Self.fixture(conversationID: chat.id, available: available)
            session = fixture
            receiverState = available ? .live : .preparing
            return
        }
        guard let connection = connectionModel.connection, !connectionModel.accessEnded else {
            failure = "Connect this device to your Mac before opening computer view."
            return
        }
        isLoading = true
        defer { if lifetimeRevision == revision { isLoading = false } }
        do {
            let body = try JSONEncoder().encode(StartComputerSessionRequest(
                clientRequestId: requestID,
                conversationId: chat.id,
                hostInstallationId: connection.credential.hostInstallationId
            ))
            let created: ComputerSession = try await connectionModel.manage(
                "/api/v1/computer/sessions",
                method: "POST",
                body: body
            )
            guard created.conversationId == chat.id,
                  created.ownerDeviceId == connection.credential.deviceId,
                  created.hostInstallationId == connection.credential.hostInstallationId else {
                throw PairingFailure.wrongHost
            }
            guard !Task.isCancelled, !ended, lifetimeRevision == revision, clientRequestID == requestID,
                  connectionModel.connection?.credential.hostInstallationId == connection.credential.hostInstallationId,
                  connectionModel.connection?.credential.deviceId == connection.credential.deviceId else {
                // End only the late session on the exact Mac that created it.
                // Never apply it to a new connection or restart a closed receiver.
                let _: ComputerEmptyReply? = try? await connectionModel.api.request(
                    "/api/v1/computer/sessions/\(Self.escape(created.id))?generation=\(created.generation)",
                    origin: connection.origin, credential: connection.credential, method: "DELETE"
                )
                return
            }
            session = created
            failure = nil
            receiverState = .preparing
            startReceiver(for: created, connection: connection)
        } catch {
            guard !ended, lifetimeRevision == revision, !Task.isCancelled else { return }
            failure = Self.readable(error, opening: true)
            receiverState = .failed(failure ?? "Could not open computer view.")
        }
    }

    func refresh() async {
        guard let current = session, !ended, !isFixture, !connectionModel.previewMode else { return }
        let revision = lifetimeRevision
        isLoading = true
        defer { if lifetimeRevision == revision { isLoading = false } }
        do {
            let updated: ComputerSession = try await connectionModel.manage(
                "/api/v1/computer/sessions/\(Self.escape(current.id))?generation=\(current.generation)"
            )
            guard !Task.isCancelled, !ended, lifetimeRevision == revision,
                  session?.id == current.id, session?.generation == current.generation else { return }
            guard updated.id == current.id,
                  updated.conversationId == chat.id,
                  updated.ownerDeviceId == current.ownerDeviceId,
                  updated.hostInstallationId == current.hostInstallationId else { throw PairingFailure.wrongHost }
            if let snapshot = controlSnapshot, !Self.snapshotMatches(snapshot, session: updated) {
                failClosed("The computer view changed. Control was released.")
            } else if let lease = controlLease, !Self.bindingMatches(lease, session: updated) {
                failClosed("The computer view changed. Control was released.")
            }
            if (controlLease != nil || isStarting)
                && (updated.state != .live || updated.control?.available != true) {
                failClosed("The computer view is no longer available for control.")
            }
            session = updated
            if case .failed = receiverState {
                // Keep a receiver failure visible when this session refresh
                // completes after the WebRTC path has already failed.
            } else {
                failure = nil
            }
            if updated.generation != current.generation { startReceiver(for: updated, connection: connectionModel.connection) }
        } catch {
            guard !Task.isCancelled, !ended, lifetimeRevision == revision else { return }
            if controlLease != nil { failClosed("The computer view could not be verified. Control was released.") }
            failure = Self.readable(error)
        }
    }

    func retry() async {
        guard !ended else { return }
        lifetimeRevision &+= 1
        let revision = lifetimeRevision
        await releaseControl()
        receiver.close(reason: "retry")
        if let current = session, !isFixture, !connectionModel.previewMode {
            do {
                let _: ComputerEmptyReply = try await connectionModel.manage(
                    "/api/v1/computer/sessions/\(Self.escape(current.id))?generation=\(current.generation)",
                    method: "DELETE"
                )
            } catch { }
        }
        guard !Task.isCancelled, !ended, lifetimeRevision == revision else { return }
        isLoading = false
        session = nil
        failure = nil
        controlMessage = nil
        clipboardMessage = nil
        controlRequestID = nil
        controlSnapshot = nil
        ended = false
        clientRequestID = UUID().uuidString.lowercased()
        await start()
    }

    func close() async {
        guard !ended else { return }
        ended = true
        lifetimeRevision &+= 1
        isLoading = false
        receiverState = .closed
        receiver.close()
        await releaseControl()
        guard let current = session, !isFixture, !connectionModel.previewMode else { return }
        do {
            let _: ComputerEmptyReply = try await connectionModel.manage(
                "/api/v1/computer/sessions/\(Self.escape(current.id))?generation=\(current.generation)",
                method: "DELETE"
            )
        } catch {
            // Closing is best-effort after the local receiver has been stopped.
        }
    }

    private func startReceiver(for session: ComputerSession, connection: SavedConnection?) {
        guard session.capability.available, let connection else { return }
        receiver.start(
            session: session,
            transport: AuthenticatedComputerSignalingTransport(api: connectionModel.api, connection: connection)
        )
    }

    func resetZoom() {
        zoomScale = 1
        viewportCenter = CGPoint(x: 0.5, y: 0.5)
    }

    func magnify(_ value: CGFloat) {
        guard value.isFinite else { return }
        zoomScale = min(max(value, 1), 3)
        let halfVisible = 0.5 / zoomScale
        viewportCenter = CGPoint(x: min(max(viewportCenter.x, halfVisible), 1 - halfVisible),
                                 y: min(max(viewportCenter.y, halfVisible), 1 - halfVisible))
    }

    func panViewport(by delta: CGSize, in size: CGSize) {
        guard zoomScale > 1 else { return }
        let transform = viewportTransform(in: size)
        viewportCenter = ComputerViewportTransform(size: size, aspect: Self.sourceAspectRatio(session), zoom: zoomScale,
            center: transform.panning(by: delta)).center
    }

    func viewportTransform(in size: CGSize) -> ComputerViewportTransform {
        ComputerViewportTransform(size: size, aspect: Self.sourceAspectRatio(session), zoom: zoomScale, center: viewportCenter)
    }

    func recenterPointer() {
        guard isControlActive else { return }
        finishPointerDrag()
        pointer = viewportCenter
        enqueueInput([.pointer(x: Double(pointer.x), y: Double(pointer.y), phase: "move", button: nil)])
    }

    var controlAvailable: Bool {
        guard let session else { return false }
        return session.state == .live
            && receiverState == .live
            && session.capability.available
            && session.control?.available == true
            && !ended
    }

    var canTakeControl: Bool {
        controlAvailable && controlLease == nil && controlState != .starting && controlState != .stopping
    }

    var isControlActive: Bool { controlState == .active && controlLease != nil }
    var isStarting: Bool { controlState == .starting }

    func takeControl() {
        guard canTakeControl, let session else { return }
        let snapshot = ComputerControlSnapshot(
            sessionID: session.id,
            generation: session.generation,
            geometryRevision: session.geometryRevision,
            sourceID: session.source.id
        )
        let requestID = controlRequestID ?? UUID().uuidString.lowercased()
        controlRequestID = requestID
        controlSnapshot = snapshot
        controlMessage = nil
        clipboardMessage = nil
        controlState = .starting
        controlTask?.cancel()
        controlTask = Task { [weak self] in
            await self?.acquireControl(snapshot: snapshot, requestID: requestID)
        }
    }

    func done() async {
        await releaseControl()
    }

    func toggleKeyboard() {
        guard isControlActive else {
            keyboardPresented = false
            return
        }
        keyboardPresented.toggle()
    }

    func sendDirectText(_ text: String) {
        guard isControlActive else { return }
        guard !text.isEmpty, text.unicodeScalars.count <= 4_096,
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t" }) else {
            controlMessage = "Keep text under 4,096 characters and use ordinary text."
            return
        }
        enqueueInput([.text(text)])
    }

    func sendKey(_ key: String) {
        guard isControlActive else { return }
        keyboardRevision &+= 1
        enqueueInput([.key(key: key, phase: "press", modifiers: 0)])
    }

    func pasteFromPhone() {
        guard isControlActive else { return }
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            controlMessage = "There is no text on this phone to paste."
            return
        }
        guard text.unicodeScalars.count <= 8_192,
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t" }) else {
            controlMessage = "Phone clipboard text is too large or contains unsupported characters."
            return
        }
        // The daemon intentionally accepts pasteFromPhone only as this one action.
        keyboardRevision &+= 1
        enqueueInput([.clipboard(operation: "pasteFromPhone", text: text)])
    }

    func copyFromMac() {
        guard isControlActive else { return }
        enqueueInput([.clipboard(operation: "copyToPhone", text: nil)])
    }

    func sendKeyboardActions(_ actions: [ComputerInputAction]) {
        guard isControlActive else { return }
        guard actions.allSatisfy({ action in
            guard case .text(let text) = action else { return true }
            return !text.isEmpty && text.unicodeScalars.count <= 4_096
                && !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        }) else {
            failClosed("The keyboard input was too large or contained unsupported characters. Take control again to continue.")
            return
        }
        for start in stride(from: 0, to: actions.count, by: 32) {
            enqueueInput(Array(actions[start..<min(start + 32, actions.count)]))
        }
    }

    func tap(at location: CGPoint, in size: CGSize, button: String = "left") {
        guard isControlActive else { return }
        finishPointerDrag()
        if inputMode == .directTouch {
            guard let point = viewportTransform(in: size).point(location) else { return }
            pointer = point
        }
        keyboardRevision &+= 1
        let actions: [ComputerInputAction] = [
            .pointer(x: Double(pointer.x), y: Double(pointer.y), phase: "down", button: button),
            .pointer(x: Double(pointer.x), y: Double(pointer.y), phase: "up", button: button)
        ]
        enqueueInput(actions)
    }

    func movePointer(by delta: CGSize, in size: CGSize) {
        guard isControlActive else { return }
        pointer = viewportTransform(in: size).moving(pointer, by: delta)
        heldPointerPoint = heldPointerButton == nil ? nil : (Double(pointer.x), Double(pointer.y))
        enqueueInput([.pointer(x: Double(pointer.x), y: Double(pointer.y), phase: "move", button: heldPointerButton)])
    }

    func dragBegan(at location: CGPoint, in size: CGSize) {
        guard isControlActive, heldPointerButton == nil else { return }
        if inputMode == .directTouch {
            guard let point = viewportTransform(in: size).point(location) else { return }
            pointer = point
        }
        keyboardRevision &+= 1
        heldPointerButton = "left"
        heldPointerPoint = (Double(pointer.x), Double(pointer.y))
        enqueueInput([.pointer(x: Double(pointer.x), y: Double(pointer.y), phase: "down", button: "left")])
    }

    func dragMoved(to location: CGPoint, in size: CGSize) {
        guard isControlActive, let button = heldPointerButton,
              let point = viewportTransform(in: size).point(location, clamped: true) else { return }
        pointer = point
        heldPointerPoint = (Double(point.x), Double(point.y))
        enqueueInput([.pointer(x: Double(point.x), y: Double(point.y), phase: "move", button: button)])
    }

    func dragEnded(at location: CGPoint?, in size: CGSize) {
        if inputMode == .directTouch, let location, let point = viewportTransform(in: size).point(location, clamped: true) {
            pointer = point
            heldPointerPoint = (Double(point.x), Double(point.y))
        }
        finishPointerDrag()
    }

    private func finishPointerDrag() {
        guard let button = heldPointerButton else { return }
        let point = heldPointerPoint ?? (Double(pointer.x), Double(pointer.y))
        heldPointerButton = nil
        heldPointerPoint = nil
        guard isControlActive else { return }
        enqueueInput([.pointer(x: point.0, y: point.1, phase: "up", button: button)])
    }

    func twoFingerScroll(delta: CGSize) {
        guard isControlActive, delta.width.isFinite, delta.height.isFinite else { return }
        let x = min(max(-Double(delta.width), -4_096), 4_096)
        let y = min(max(-Double(delta.height), -4_096), 4_096)
        guard x != 0 || y != 0 else { return }
        enqueueInput([.scroll(deltaX: x, deltaY: y)])
    }

    static func sourceAspectRatio(_ session: ComputerSession?) -> CGFloat {
        guard let source = session?.source else { return 16 / 9 }
        let width = source.crop?.width ?? Double(source.width ?? 16)
        let height = source.crop?.height ?? Double(source.height ?? 9)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return 16 / 9 }
        return CGFloat(width / height)
    }

    static func encodedAspectRatio(_ session: ComputerSession?) -> CGFloat {
        guard let width = session?.source.width, let height = session?.source.height,
              width > 0, height > 0 else { return sourceAspectRatio(session) }
        return CGFloat(width) / CGFloat(height)
    }

    static func normalizedPoint(location: CGPoint, in size: CGSize, session: ComputerSession,
                                zoomScale: CGFloat, clampToContent: Bool = false,
                                center: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> (x: Double, y: Double)? {
        ComputerViewportTransform(size: size, aspect: sourceAspectRatio(session), zoom: zoomScale, center: center)
            .point(location, clamped: clampToContent).map { (Double($0.x), Double($0.y)) }
    }

    private func acquireControl(snapshot: ComputerControlSnapshot, requestID: String) async {
        guard let session, Self.snapshotMatches(snapshot, session: session), controlAvailable else {
            controlState = .viewOnly
            return
        }
        if isFixture {
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled,
                  controlRequestID == requestID,
                  controlState == .starting,
                  Self.snapshotMatches(snapshot, session: session),
                  controlAvailable else { return }
            let lease = Self.fixtureLease(session: session)
            controlLease = lease
            controlState = .active
            controlMessage = nil
            recenterPointer()
            startHeartbeat()
            return
        }
        do {
            let body = try JSONEncoder().encode(AcquireComputerControlRequest(
                clientRequestId: requestID,
                generation: snapshot.generation,
                geometryRevision: snapshot.geometryRevision,
                sourceId: snapshot.sourceID
            ))
            let response: ComputerControlActionResponse = try await connectionModel.manage(
                "/api/v1/computer/sessions/\(Self.escape(snapshot.sessionID))/control/acquire",
                method: "POST",
                body: body,
                decodingStatuses: [409, 503]
            )
            guard !Task.isCancelled,
                  controlRequestID == requestID,
                  controlState == .starting else {
                if let lease = response.lease { await releaseLease(lease) }
                return
            }
            let current = session
            guard Self.snapshotMatches(snapshot, session: current),
                  controlAvailable else {
                if let lease = response.lease { await releaseLease(lease) }
                failClosed("The computer view changed while control was starting.")
                return
            }
            guard response.granted,
                  response.acknowledged,
                  response.status == "active",
                  response.control.available,
                  let lease = response.lease,
                  Self.leaseMatches(lease, session: current, connection: connectionModel.connection) else {
                if let lease = response.lease { await releaseLease(lease) }
                finishControlFailure(response.reason.isEmpty ? "Control was not granted on your Mac." : response.reason, resetRequest: true)
                return
            }
            controlLease = lease
            controlState = .active
            controlMessage = nil
            recenterPointer()
            startHeartbeat()
        } catch is CancellationError {
            if !ended && !releasingControl { controlState = .viewOnly }
        } catch PairingFailure.response(let status) where status == 409 {
            guard !ended, !releasingControl else { return }
            finishControlFailure("Control was not granted on your Mac. Try again when you are ready.", resetRequest: true)
        } catch {
            guard !ended, !releasingControl else { return }
            finishControlFailure("Your Mac could not confirm control. Try again.", resetRequest: false)
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let seconds = max(Int(session?.control?.heartbeatIntervalSeconds ?? 3), 1)
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(seconds)) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self?.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() async {
        guard !ended, !releasingControl, let session, let lease = controlLease else { return }
        if isFixture {
            #if WONDER_DIAGNOSTICS
            if ProcessInfo.processInfo.arguments.contains("-diagnostics-computer-live-updates") {
                controlLease = lease
            }
            #endif
            return
        }
        let epoch = inputEpoch
        guard Self.leaseMatches(lease, session: session, connection: connectionModel.connection) else {
            failClosed("The computer view changed. Control was released.")
            return
        }
        do {
            let response: ComputerControlActionResponse = try await connectionModel.manage(
                "/api/v1/computer/sessions/\(Self.escape(session.id))/control/heartbeat",
                method: "POST",
                body: JSONEncoder().encode(ComputerControlBindingRequest(
                    leaseId: lease.id,
                    generation: lease.generation,
                    geometryRevision: lease.geometryRevision,
                    sourceId: lease.sourceId
                )),
                decodingStatuses: [409, 503]
            )
            guard !Task.isCancelled, inputEpoch == epoch, !ended, !releasingControl, isControlActive,
                  controlLease?.id == lease.id else { return }
            guard response.acknowledged,
                  response.status == "active",
                  response.control.available,
                  let refreshed = response.lease,
                  adoptLease(refreshed, for: session) else {
                failClosed(response.reason.isEmpty ? "Control expired or is no longer available." : response.reason)
                return
            }
        } catch is CancellationError {
            if inputEpoch == epoch && controlLease?.id == lease.id && !ended && !releasingControl { failClosed("Control was interrupted.") }
        } catch {
            if inputEpoch == epoch && controlLease?.id == lease.id && !ended && !releasingControl { failClosed("Control was interrupted. The Mac may still be finishing release.") }
        }
    }

    func awaitInputIdle() async {
        await inputTask?.value
    }

    private func enqueueInput(_ actions: [ComputerInputAction]) {
        guard isControlActive, let lease = controlLease else { return }
        guard inputBuffer.append(actions) else {
            failClosed("Your Mac is not keeping up with input. Take control again to continue.")
            return
        }
        guard inputTask == nil else { return }
        let epoch = inputEpoch
        let leaseID = lease.id
        inputTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.inputEpoch == epoch,
                  self.controlLease?.id == leaseID, self.isControlActive,
                  let next = self.inputBuffer.popFirst() {
                await self.sendInput(next, epoch: epoch, leaseID: leaseID)
            }
            guard let self, self.inputEpoch == epoch else { return }
            self.inputTask = nil
        }
    }

    private func discardPendingInput() {
        inputEpoch &+= 1
        inputTask?.cancel()
        inputTask = nil
        inputBuffer.removeAll()
        heldPointerButton = nil
        heldPointerPoint = nil
        keyboardPresented = false
        keyboardRevision &+= 1
    }

    private func sendInput(_ actions: [ComputerInputAction], epoch: UInt64, leaseID: String) async {
        guard !Task.isCancelled, inputEpoch == epoch, !ended, !releasingControl,
              let session, let lease = controlLease, lease.id == leaseID, isControlActive else { return }
        if isFixture {
            guard lease.lastSequence < UInt64.max else {
                failClosed("The computer view changed. Input was discarded.")
                return
            }
            let sequence = lease.lastSequence + 1
            controlLease = Self.leaseWithSequence(lease, sequence: sequence)
            if actions.contains(where: {
                if case .clipboard(let operation, _) = $0 { return operation == "copyToPhone" }
                return false
            }) {
                // The diagnostic fixture stands in for the authenticated Mac
                // response; production writes only response.clipboardText.
                UIPasteboard.general.string = "Fixture clipboard text"
                clipboardMessage = "Copied from Mac"
            }
            return
        }
        guard Self.leaseMatches(lease, session: session, connection: connectionModel.connection),
              lease.lastSequence < UInt64.max else {
            failClosed("The computer view changed. Input was discarded.")
            return
        }
        let sequence = lease.lastSequence + 1
        let request = ComputerInputBatchRequest(
            leaseId: lease.id,
            generation: lease.generation,
            geometryRevision: lease.geometryRevision,
            sourceId: lease.sourceId,
            sequence: sequence,
            actions: actions
        )
        do {
            let response: ComputerControlActionResponse = try await connectionModel.manage(
                "/api/v1/computer/sessions/\(Self.escape(session.id))/control/input",
                method: "POST",
                body: JSONEncoder().encode(request),
                decodingStatuses: [409, 503]
            )
            guard !Task.isCancelled, inputEpoch == epoch, !ended, !releasingControl,
                  isControlActive, controlLease?.id == leaseID else { return }
            guard response.acknowledged,
                  response.status == "active",
                  response.control.available,
                  let refreshed = response.lease,
                  adoptLease(refreshed, for: session) else {
                failClosed(response.reason.isEmpty ? "The Mac rejected this input. Control was released." : response.reason)
                return
            }
            if actions.contains(where: {
                if case .clipboard(let operation, _) = $0 { return operation == "copyToPhone" }
                return false
            }) {
                guard let text = response.clipboardText else {
                    controlMessage = "The Mac did not return any clipboard text."
                    return
                }
                UIPasteboard.general.string = text
                clipboardMessage = "Copied from Mac"
            }
        } catch is CancellationError {
            if inputEpoch == epoch && !ended && !releasingControl { failClosed("Input was interrupted. Control was released.") }
        } catch {
            if inputEpoch == epoch && !ended && !releasingControl { failClosed("The Mac could not receive this input. Control was released.") }
        }
    }

    private func releaseControl() async {
        controlTask?.cancel()
        controlTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        discardPendingInput()
        let lease = controlLease
        controlLease = nil
        releasingControl = lease != nil
        if lease != nil { controlState = .stopping }
        if let lease, !isFixture { await releaseLease(lease) }
        releasingControl = false
        controlState = .viewOnly
        controlMessage = nil
        clipboardMessage = nil
        if lease != nil { controlRequestID = nil }
        controlSnapshot = nil
    }

    private func releaseLease(_ lease: ComputerControlLease) async {
        guard !isFixture else { return }
        do {
            let _: ComputerControlActionResponse = try await connectionModel.manage(
                "/api/v1/computer/sessions/\(Self.escape(lease.sessionId))/control/release",
                method: "POST",
                body: JSONEncoder().encode(ComputerControlBindingRequest(
                    leaseId: lease.id,
                    generation: lease.generation,
                    geometryRevision: lease.geometryRevision,
                    sourceId: lease.sourceId
                ))
            )
        } catch { }
    }

    private func failClosed(_ message: String) {
        guard !ended, !releasingControl else { return }
        let lease = controlLease
        controlLease = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        discardPendingInput()
        controlRequestID = nil
        controlSnapshot = nil
        controlMessage = message
        controlState = .failed(message)
        if let lease, !isFixture {
            Task { [weak self] in await self?.releaseLease(lease) }
        }
    }

    private func finishControlFailure(_ message: String, resetRequest: Bool) {
        discardPendingInput()
        controlLease = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heldPointerButton = nil
        heldPointerPoint = nil
        keyboardPresented = false
        if resetRequest {
            controlRequestID = nil
            controlSnapshot = nil
        }
        controlMessage = message
        controlState = .failed(message)
    }

    private func adoptLease(_ refreshed: ComputerControlLease, for session: ComputerSession) -> Bool {
        guard Self.leaseMatches(refreshed, session: session, connection: connectionModel.connection) else {
            return false
        }
        if let current = controlLease {
            guard let reconciled = Self.reconciledLease(current: current, refreshed: refreshed) else { return false }
            controlLease = reconciled
        } else {
            controlLease = refreshed
        }
        return true
    }

    private static func snapshotMatches(_ snapshot: ComputerControlSnapshot, session: ComputerSession) -> Bool {
        snapshot.sessionID == session.id
            && snapshot.generation == session.generation
            && snapshot.geometryRevision == session.geometryRevision
            && snapshot.sourceID == session.source.id
    }

    private static func bindingMatches(_ lease: ComputerControlLease, session: ComputerSession) -> Bool {
        lease.sessionId == session.id
            && lease.conversationId == session.conversationId
            && lease.generation == session.generation
            && lease.geometryRevision == session.geometryRevision
            && lease.sourceId == session.source.id
    }

    private static func leaseMatches(_ lease: ComputerControlLease, session: ComputerSession, connection: SavedConnection?) -> Bool {
        guard let connection else { return false }
        return bindingMatches(lease, session: session)
            && lease.status == "active"
            && lease.ownerDeviceId == connection.credential.deviceId
            && lease.hostInstallationId == connection.credential.hostInstallationId
    }

    private static func leaseWithSequence(_ lease: ComputerControlLease, sequence: UInt64) -> ComputerControlLease {
        ComputerControlLease(
            id: lease.id,
            sessionId: lease.sessionId,
            ownerDeviceId: lease.ownerDeviceId,
            hostInstallationId: lease.hostInstallationId,
            conversationId: lease.conversationId,
            generation: lease.generation,
            sourceId: lease.sourceId,
            geometryRevision: lease.geometryRevision,
            status: lease.status,
            lastSequence: sequence,
            acquiredAt: lease.acquiredAt,
            updatedAt: lease.updatedAt,
            expiresAt: lease.expiresAt,
            releasedAt: lease.releasedAt
        )
    }

    static func reconciledLease(current: ComputerControlLease,
                                refreshed: ComputerControlLease) -> ComputerControlLease? {
        guard current.id == refreshed.id else { return nil }
        return leaseWithSequence(
            refreshed,
            sequence: max(current.lastSequence, refreshed.lastSequence)
        )
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func readable(_ error: Error, opening: Bool = false) -> String {
        if case PairingFailure.response(let status) = error {
            switch status {
            case 401, 403: return "Access to this computer has ended. Reconnect in Settings, then try again."
            case 404 where opening: return "Computer viewing needs a newer Wonder host. Update Wonder on your Mac, then try again."
            case 404: return "This computer view is no longer available on your Mac."
            case 409: return "The computer view changed on your Mac. Close this screen and try again."
            case 503: return "Live computer viewing is unavailable on this Mac. Update Wonder on the Mac, then try again."
            default: break
            }
        }
        return "Wonder could not open computer view. Check your Mac connection and try again."
    }

    private static func fixture(conversationID: String, available: Bool) -> ComputerSession {
        let source = available ? ComputerSource(
            id: "display:1", name: "Main display", kind: "display", width: 1920, height: 1080, scale: 1
        ) : .unknown
        let control = available ? ComputerControlCapability(
            available: true, action: "none", reason: "Take control starts when paired-device control is enabled in Wonder Settings on your Mac."
        ) : .unavailable
        return ComputerSession(
            id: "fixture-computer-session",
            clientRequestId: "fixture-computer-request",
            ownerDeviceId: "fixture-device",
            hostInstallationId: "fixture-host",
            conversationId: conversationID,
            generation: 1,
            state: available ? .live : .unavailable,
            source: source,
            geometryRevision: available ? 1 : 0,
            failureReason: available ? nil : "Live computer viewing is unavailable on this Mac. Update Wonder on the Mac, then try again.",
            createdAt: "2026-09-12T00:00:00Z",
            updatedAt: "2026-09-12T00:00:00Z",
            lastStateAt: "2026-09-12T00:00:00Z",
            endedAt: nil,
            capability: available ? ComputerCapability(available: true, action: "none", reason: "Live computer viewing is available on this Mac.") : .oldHost,
            control: control
        )
    }

    private static func fixtureLease(session: ComputerSession) -> ComputerControlLease {
        ComputerControlLease(
            id: "fixture-control-lease",
            sessionId: session.id,
            ownerDeviceId: "fixture-device",
            hostInstallationId: "fixture-host",
            conversationId: session.conversationId,
            generation: session.generation,
            sourceId: session.source.id,
            geometryRevision: session.geometryRevision,
            status: "active",
            lastSequence: 0,
            acquiredAt: "2026-09-12T00:00:00Z",
            updatedAt: "2026-09-12T00:00:00Z",
            expiresAt: "2099-01-01T00:00:00Z",
            releasedAt: nil
        )
    }
}

private struct AuthenticatedComputerSignalingTransport: ComputerSignalingTransport {
    let api: PairingAPI
    let connection: SavedConnection

    func poll(sessionID: String, request: ComputerSignalingPollRequest) async throws -> ComputerSignalingResponse {
        try await api.request("/api/v1/computer/sessions/\(escape(sessionID))/signaling",
                              origin: connection.origin,
                              body: JSONEncoder().encode(request), credential: connection.credential)
    }

    func submitAnswer(sessionID: String, request: ComputerSignalingAnswerRequest) async throws -> ComputerSignalingMutationResponse {
        try await api.request("/api/v1/computer/sessions/\(escape(sessionID))/signaling/answer",
                              origin: connection.origin,
                              body: JSONEncoder().encode(request), credential: connection.credential)
    }

    func sendCandidate(sessionID: String, request: ComputerSignalingCandidateRequest) async throws -> ComputerSignalingMutationResponse {
        try await api.request("/api/v1/computer/sessions/\(escape(sessionID))/signaling/candidate",
                              origin: connection.origin,
                              body: JSONEncoder().encode(request), credential: connection.credential)
    }

    func close(sessionID: String, request: ComputerSignalingCloseRequest) async throws -> ComputerSignalingMutationResponse {
        try await api.request("/api/v1/computer/sessions/\(escape(sessionID))/signaling/close",
                              origin: connection.origin,
                              body: JSONEncoder().encode(request), credential: connection.credential)
    }

    private func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

struct ComputerSessionView: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var sessionModel: ComputerSessionModel

    init(model: ConnectionModel, chat: ChatSummary) {
        self.model = model
        self.chat = chat
        let computer = ComputerSessionModel(model: model, chat: chat)
        _sessionModel = StateObject(wrappedValue: computer)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let session = sessionModel.session {
                ComputerSessionHeader(model: model, session: session, receiverState: sessionModel.receiverState)
            } else {
                HStack(spacing: 10) {
                    if sessionModel.isLoading { ProgressView() }
                    Text(sessionModel.isClosed ? "Computer view closed" : sessionModel.isLoading ? "Opening computer view…" : "Computer view")
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }

            ComputerViewport(model: sessionModel)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)

            if let failure = sessionModel.failure, !sessionModel.isClosed {
                VStack(alignment: .leading, spacing: 8) {
                    FailureDetails("Computer view unavailable", message: failure)
                    Button("Try again") { Task { await sessionModel.retry() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(sessionModel.isLoading)
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            if !sessionModel.isClosed {
                ComputerSessionControls(model: sessionModel)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Computer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    Task {
                        await closeComputer()
                        dismiss()
                    }
                }
                .accessibilityIdentifier("computer-session-close")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Pointer mode", selection: $sessionModel.inputMode) {
                        ForEach(ComputerInputMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Button("Recenter pointer", systemImage: "scope") { sessionModel.recenterPointer() }
                        .disabled(!sessionModel.isControlActive)
                        .accessibilityIdentifier("computer-session-recenter")
                    Section("View") {
                        Button("Fit", systemImage: "arrow.up.left.and.arrow.down.right") { sessionModel.resetZoom() }
                            .accessibilityIdentifier("computer-session-fit")
                        Button("Zoom in", systemImage: "plus.magnifyingglass") { sessionModel.magnify(sessionModel.zoomScale + 0.25) }
                            .accessibilityIdentifier("computer-session-zoom-in")
                        Button("Zoom out", systemImage: "minus.magnifyingglass") { sessionModel.magnify(sessionModel.zoomScale - 0.25) }
                            .accessibilityIdentifier("computer-session-zoom-out")
                    }
                    Menu("Keys", systemImage: "keyboard") {
                        ForEach(["Return", "Delete", "Left", "Right", "Up", "Down"], id: \.self) { key in
                            Button(key) { sessionModel.sendKey(key.lowercased()) }
                                .accessibilityIdentifier("computer-session-key-\(key.lowercased())")
                        }
                    }
                    .disabled(!sessionModel.isControlActive)
                    .accessibilityIdentifier("computer-session-keys")
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                // Native toolbar menus omit accessibilityValue on iOS 27.
                // Keep zoom available to VoiceOver in the spoken label too.
                .accessibilityLabel("More, zoom \(Int((sessionModel.zoomScale * 100).rounded())) percent")
                .accessibilityValue("\(Int((sessionModel.zoomScale * 100).rounded())) percent")
                .accessibilityIdentifier("computer-session-more")
            }
        }
        .task { await sessionModel.start() }
        .onDisappear { Task { await closeComputer() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await handleLifetimeEnd() } }
        }
        .onChange(of: model.accessEnded) { _, ended in
            if ended { Task { await handleLifetimeEnd() } }
        }
        .onChange(of: model.macConnected) { _, connected in
            if connected == false { Task { await handleLifetimeEnd() } }
        }
        .onChange(of: model.connection?.credential.hostInstallationId) { _, _ in
            Task { await closeComputer(); dismiss() }
        }
        .onChange(of: chat.id) { _, _ in
            Task { await closeComputer(); dismiss() }
        }
        // Keep the container addressable without allowing its identifier to
        // replace the nested viewport's live status element in XCTest.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("computer-session-container")
    }

    private func handleLifetimeEnd() async {
        await closeComputer()
        dismiss()
    }

    private func closeComputer() async {
        await sessionModel.close()
    }
}

private struct ComputerSessionHeader: View {
    @ObservedObject var model: ConnectionModel
    let session: ComputerSession
    let receiverState: ComputerReceiverState

    private var statusTitle: String {
        session.state == .unavailable ? session.state.title : receiverState.title
    }

    private var sourceDescription: String {
        guard let name = session.source.name ?? session.source.kind else { return "Source not selected" }
        if let width = session.source.width, let height = session.source.height {
            return "\(name) · \(width) × \(height)"
        }
        return name
    }

    var body: some View {
        HStack(spacing: 12) {
            Label(statusTitle, systemImage: session.state == .unavailable ? "nosign" : "circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(session.state == .unavailable ? .secondary : .primary)
            Spacer(minLength: 8)
            Text(model.macName).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(minHeight: 36)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(sourceDescription)
        .accessibilityIdentifier("computer-session-status")
    }
}

struct ComputerViewport: View {
    @ObservedObject var model: ComputerSessionModel

    private var message: String {
        if model.isClosed { return "Computer view closed" }
        guard let session = model.session else { return "Preparing a verified computer view…" }
        if session.state == .unavailable { return "Live computer viewing is unavailable on this Mac." }
        if !session.capability.available { return "A verified computer stream is not configured on this Mac." }
        return model.receiverState.message
    }

    var body: some View {
        GeometryReader { proxy in
            let transform = model.viewportTransform(in: proxy.size)
            let videoFrame = transform.videoFrame(encodedAspect: ComputerSessionModel.encodedAspectRatio(model.session))
            ZStack {
                Color.black
                if model.session?.capability.available == true {
                    ComputerVideoView(receiver: model.receiver)
                        .frame(width: videoFrame.width, height: videoFrame.height)
                        .position(x: videoFrame.midX, y: videoFrame.midY)
                }
                if model.isControlActive {
                    ComputerPhonePointer(pointer: model.pointerState, transform: transform)
                }
                if model.receiverState != .live || model.session?.state == .unavailable {
                    VStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 34, weight: .light))
                        Text(message).font(.headline).multilineTextAlignment(.center)
                        if let reason = model.session?.failureReason, !reason.isEmpty {
                            Text(reason).font(.footnote).multilineTextAlignment(.center)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                }
            }
            .overlay {
                ComputerGestureSurface(
                    allowsInput: model.isControlActive,
                    mode: model.inputMode,
                    zoomScale: model.zoomScale,
                    onTap: { point, size, button in model.tap(at: point, in: size, button: button) },
                    onMove: { delta, size in model.movePointer(by: delta, in: size) },
                    onDragBegan: { point, size in model.dragBegan(at: point, in: size) },
                    onDragMoved: { point, size in model.dragMoved(to: point, in: size) },
                    onDragEnded: { point, size in model.dragEnded(at: point, in: size) },
                    onScroll: { model.twoFingerScroll(delta: $0) },
                    onPan: { delta, size in model.panViewport(by: delta, in: size) },
                    onPinch: { model.magnify($0) }
                )
            }
            .accessibilityAction(named: Text("Click")) {
                model.tap(at: CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2), in: proxy.size)
            }
            .accessibilityAction(named: Text("Right-click")) {
                model.tap(at: CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2), in: proxy.size, button: "right")
            }
            .accessibilityAction(named: Text("Recenter pointer")) { model.recenterPointer() }
        }
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Computer screen preview")
        .accessibilityValue(model.receiverState.title)
        .accessibilityIdentifier("computer-session-preview")
        .aspectRatio(ComputerSessionModel.sourceAspectRatio(model.session), contentMode: .fit)
    }
}

private struct ComputerPhonePointer: View {
    @ObservedObject var pointer: ComputerPointerState
    let transform: ComputerViewportTransform

    var body: some View {
        let location = transform.location(for: pointer.position)
        ComputerPointerShape()
            .fill(.black)
            .overlay { ComputerPointerShape().stroke(.white, lineWidth: 2) }
            .frame(width: 24, height: 30)
            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
            // The tip, not the center of the enlarged arrow, is the hot spot.
            .position(x: location.x + 12, y: location.y + 15)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct ComputerPointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0.82),
            CGPoint(x: 0.28, y: 0.62), CGPoint(x: 0.49, y: 1),
            CGPoint(x: 0.7, y: 0.91), CGPoint(x: 0.5, y: 0.54),
            CGPoint(x: 1, y: 0.54)
        ]
        path.addLines(points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) })
        path.closeSubpath()
        return path
    }
}

struct ComputerSessionControls: View {
    @ObservedObject var model: ComputerSessionModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = model.controlMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .accessibilityIdentifier("computer-session-control-message")
            }
            if let message = model.clipboardMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .accessibilityIdentifier("computer-session-clipboard-message")
            }
            if model.isControlActive {
                HStack(spacing: 4) {
                    keyButton("Esc", key: "escape", label: "Escape", symbol: "escape")
                    keyButton("Tab", key: "tab", label: "Tab", symbol: "arrow.right.to.line")
                    Menu {
                        Button("Paste from Phone", systemImage: "doc.on.clipboard") { model.pasteFromPhone() }
                            .accessibilityIdentifier("computer-session-paste-from-phone")
                        Button("Copy from Mac", systemImage: "doc.on.doc") { model.copyFromMac() }
                            .accessibilityIdentifier("computer-session-copy-from-mac")
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Clipboard")
                    .accessibilityIdentifier("computer-session-clipboard")
                    Button { model.toggleKeyboard() } label: {
                        Image(systemName: model.keyboardPresented ? "keyboard.chevron.compact.down" : "keyboard")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(model.keyboardPresented ? "Hide keyboard" : "Show keyboard")
                    .accessibilityIdentifier("computer-session-keyboard")
                    Button { Task { await model.done() } } label: {
                        Group {
                            if dynamicTypeSize.isAccessibilitySize { Image(systemName: "checkmark") }
                            else { Text("Done") }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Done")
                    .accessibilityIdentifier("computer-session-done")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Computer control active")
                .accessibilityIdentifier("computer-session-control-active")
            } else if model.isStarting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting control…").font(.footnote)
                    Spacer()
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("computer-session-waiting")
            } else {
                HStack(spacing: 8) {
                    Text("View only")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("computer-session-view-only")
                    Spacer(minLength: 4)
                    if model.controlAvailable {
                        Button { model.takeControl() } label: {
                            Text("Take control").frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("computer-session-take-control")
                    }
                    Button { Task { await model.refresh() } } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Refresh")
                    .disabled(model.isLoading || model.session == nil || model.isFixture)
                    .accessibilityIdentifier("computer-session-refresh")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .font(.body)
        .foregroundStyle(Color.accentColor)
        .buttonStyle(.plain)
        .background(Color(uiColor: .secondarySystemBackground))
        .background(alignment: .bottomLeading) {
            ComputerNativeKeyboard(
                presented: model.isControlActive && model.keyboardPresented,
                resetID: model.keyboardRevision,
                onActions: { model.sendKeyboardActions($0) },
                onDismiss: { model.keyboardPresented = false }
            )
            .frame(width: 1, height: 1)
            .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("computer-session-controls-row")
    }

    private func keyButton(_ title: String, key: String, label: String, symbol: String) -> some View {
        Button { model.sendKey(key) } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize { Image(systemName: symbol) }
                else { Text(title) }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier("computer-session-key-\(key)")
    }
}

#if WONDER_DIAGNOSTICS
struct ComputerSessionDiagnosticFixtureView: View {
    @StateObject private var model = ConnectionModel(saved: nil, persistConnection: { _ in })
    @State private var isPresented = true
    private let chat: ChatSummary = {
        let data = Data(#"{"conversationId":"computer-fixture","botId":"fixture-bot","title":"Computer fixture","messageCount":0,"hasUnread":false,"isArchived":false,"isPinned":false}"#.utf8)
        return try! JSONDecoder().decode(ChatSummary.self, from: data)
    }()

    var body: some View {
        Text("Computer viewer closed")
            .fullScreenCover(isPresented: $isPresented) {
                NavigationStack { ComputerSessionView(model: model, chat: chat) }
            }
    }
}
#endif
