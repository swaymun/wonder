import AppKit
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

private struct SourceSelectionRequest: Equatable, Sendable {
    let sessionID: String
    let generation: UInt64
}

/// Transfers one immutable ScreenCaptureKit enumeration result to the AppKit
/// run loop. The result is consumed there and never accessed again by the
/// completion queue.
private final class SourceSelectionPayload: @unchecked Sendable {
    let content: SCShareableContent?
    let requestedSourceID: String?
    let mainDisplayID: CGDirectDisplayID
    let request: SourceSelectionRequest

    init(
        content: SCShareableContent?,
        requestedSourceID: String?,
        mainDisplayID: CGDirectDisplayID,
        request: SourceSelectionRequest
    ) {
        self.content = content
        self.requestedSourceID = requestedSourceID
        self.mainDisplayID = mainDisplayID
        self.request = request
    }
}

public final class ScreenCaptureSession: NSObject, @unchecked Sendable {
    public typealias EventSink = @Sendable (CaptureEvent) -> Void

    private let lock = NSLock()
    private let captureQueue: DispatchQueue
    private let eventSink: EventSink
    private let frameQueue: LatestVideoFrameSink
    private var machine: CaptureStateMachine
    private var stream: SCStream?
    private var selectedFilter: SCContentFilter?
    private var selectedSource: CaptureSourceDescriptor?
    private var displays: [String: SCDisplay] = [:]
    private var windows: [String: SCWindow] = [:]
    private var pickerObserverRegistered = false
    private var pendingSelectionRequest: SourceSelectionRequest?
    private var pickerSelectionRequest: SourceSelectionRequest?
    private var frameSequence: UInt64 = 0
    private var lastFrameMetadataEmissionUptime: TimeInterval?
    private var intentionalStop = false
    private let maximumSourceCount = 128

    public init(
        configuration: CaptureConfiguration = CaptureConfiguration(),
        eventSink: @escaping EventSink = { _ in },
        frameSink: @escaping @Sendable (CapturedVideoFrame) -> Void = { _ in }
    ) {
        let pickerAvailable: Bool
        if #available(macOS 14.0, *) {
            pickerAvailable = true
        } else {
            pickerAvailable = false
        }
        self.captureQueue = DispatchQueue(label: "com.wonder.computer-use.capture", qos: .userInitiated)
        self.eventSink = eventSink
        self.frameQueue = LatestVideoFrameSink(capacity: configuration.queueDepth, consumer: frameSink)
        self.machine = CaptureStateMachine(configuration: configuration, pickerAvailable: pickerAvailable)
        super.init()
    }

    deinit {
        stopStream()
    }

    public func status() -> CaptureStatusSnapshot {
        let authorized = CGPreflightScreenCaptureAccess()
        lock.lock()
        let previousState = machine.status.state
        _ = machine.updateScreenRecordingAuthorization(authorized)
        let permissionWasRevoked = previousState != .permissionDenied && machine.status.state == .permissionDenied
        let currentStream = permissionWasRevoked ? stream : nil
        if permissionWasRevoked {
            intentionalStop = true
            stream = nil
            selectedFilter = nil
            selectedSource = nil
            pendingSelectionRequest = nil
            pickerSelectionRequest = nil
            frameQueue.clear()
        }
        let snapshot = currentStatusLocked()
        lock.unlock()
        if let currentStream {
            Task { try? await currentStream.stopCapture() }
        }
        return snapshot
    }

    /// Returns the exact source geometry selected for the current capture.
    /// Control coordinates are translated against this value, never against a
    /// caller-supplied or whole-desktop rectangle.
    public func selectedSourceDescriptor() -> CaptureSourceDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return selectedSource
    }

    public func prepare(
        sessionID: String,
        generation: UInt64,
        viewerCount: Int
    ) -> CaptureOperationResult {
        stopStream()
        frameQueue.reset()
        lock.lock()
        frameSequence = 0
        lastFrameMetadataEmissionUptime = nil
        selectedFilter = nil
        selectedSource = nil
        pendingSelectionRequest = nil
        pickerSelectionRequest = nil
        let snapshot = machine.prepare(
            sessionID: sessionID,
            generation: generation,
            viewerCount: viewerCount,
            screenRecordingAuthorized: CGPreflightScreenCaptureAccess()
        )
        lock.unlock()
        emit("capture.prepared", status: snapshot)
        return CaptureOperationResult(accepted: viewerCount > 0, action: "prepare", status: snapshot)
    }

    public func listSources() -> CaptureOperationResult {
        guard screenRecordingIsAvailable() else {
            let snapshot = markPermissionDenied()
            return CaptureOperationResult(
                accepted: false,
                action: "listSources",
                status: snapshot,
                message: "Allow Screen Recording for Wonder on your Mac",
                errorCode: "screen_recording_permission_required"
            )
        }

        let pending = status()
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            guard let content else {
                let snapshot = self.markPermissionDenied(reason: error == nil ? "shareable_content_unavailable" : "shareable_content_unavailable")
                self.emit("capture.sourcesFailed", status: snapshot, message: "Mac content is unavailable")
                return
            }
            let sources = self.cacheSources(content)
            self.emit("capture.sources", status: self.status(), sources: sources)
        }
        return CaptureOperationResult(
            accepted: true,
            action: "listSources",
            status: pending,
            message: "Loading shareable Mac windows and displays"
        )
    }

    public func pick(sourceID: String? = nil) -> CaptureOperationResult {
        if sourceID?.isEmpty == true {
            return rejected("pick", errorCode: "source_not_found")
        }
        let current = status()
        guard current.sessionID != nil else {
            return rejected("pick", errorCode: "capture_not_prepared")
        }
        guard current.screenRecordingAuthorized else {
            return CaptureOperationResult(
                accepted: false,
                action: "pick",
                status: current,
                message: current.message,
                errorCode: current.reason ?? "screen_recording_permission_required"
            )
        }

        lock.lock()
        let pending = machine.beginPickerSelection()
        let request: SourceSelectionRequest?
        if pending.state == .awaitingSource,
           let sessionID = pending.sessionID {
            request = SourceSelectionRequest(sessionID: sessionID, generation: pending.generation)
            pendingSelectionRequest = request
            pickerSelectionRequest = nil
        } else {
            request = nil
        }
        lock.unlock()
        guard let request else {
            return CaptureOperationResult(
                accepted: false,
                action: "pick",
                status: pending,
                message: pending.message,
                errorCode: pending.reason ?? "invalid_capture_state"
            )
        }

        let mainDisplayID = CGMainDisplayID()
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, error in
            // AppKit and the system picker are main-run-loop APIs. Keep the
            // asynchronous enumeration callback from touching either surface
            // on ScreenCaptureKit's unspecified completion queue.
            let payload = SourceSelectionPayload(
                content: content,
                requestedSourceID: sourceID,
                mainDisplayID: mainDisplayID,
                request: request
            )
            DispatchQueue.main.async { [weak self, payload] in
                self?.completeSourceSelection(
                    content: payload.content,
                    requestedSourceID: payload.requestedSourceID,
                    mainDisplayID: payload.mainDisplayID,
                    request: payload.request
                )
            }
        }
        return CaptureOperationResult(
            accepted: true,
            action: "pick",
            status: pending,
            message: sourceID == nil ? "Selecting your main Mac display" : "Loading the selected Mac source"
        )
    }

    public func start(sessionID: String, generation: UInt64) -> CaptureOperationResult {
        guard matchesIdentity(sessionID: sessionID, generation: generation) else {
            return rejected("start", errorCode: "invalid_capture_session")
        }
        guard screenRecordingIsAvailable() else {
            let snapshot = markPermissionDenied()
            return CaptureOperationResult(
                accepted: false,
                action: "start",
                status: snapshot,
                message: "Allow Screen Recording for Wonder on your Mac",
                errorCode: "screen_recording_permission_required"
            )
        }

        lock.lock()
        guard let source = selectedSource, let filter = selectedFilter else {
            let snapshot = machine.status
            lock.unlock()
            return CaptureOperationResult(accepted: false, action: "start", status: snapshot, errorCode: "source_not_selected")
        }
        let snapshot = machine.requestStart()
        let config = Self.makeStreamConfiguration(machine.status.configuration, source: source)
        lock.unlock()
        guard snapshot.state == .starting else {
            return CaptureOperationResult(accepted: false, action: "start", status: snapshot, errorCode: "invalid_capture_state")
        }

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        lock.lock()
        stream = newStream
        selectedSource = source
        intentionalStop = false
        lock.unlock()
        Task { [weak self, newStream] in
            guard let self else { return }
            do {
                try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.captureQueue)
                guard self.isCurrentStream(newStream) else {
                    try? await newStream.stopCapture()
                    return
                }
                try await newStream.startCapture()
                guard self.isCurrentStream(newStream) else { return }
                let started = self.markStarted()
                self.emit("capture.started", status: started)
            } catch {
                guard self.isTrackedStream(newStream) else { return }
                let failed = self.markFailed(reason: self.reason(for: error))
                self.emit("capture.failed", status: failed, message: "Mac sharing could not attach its capture output")
            }
        }
        return CaptureOperationResult(accepted: true, action: "start", status: status(), message: "Starting Mac sharing")
    }

    public func pause(sessionID: String, generation: UInt64) -> CaptureOperationResult {
        guard matchesIdentity(sessionID: sessionID, generation: generation) else {
            return rejected("pause", errorCode: "invalid_capture_session")
        }
        lock.lock()
        let snapshot = machine.pause()
        let currentStream = stream
        intentionalStop = true
        lock.unlock()
        guard snapshot.state == .paused else {
            return CaptureOperationResult(accepted: false, action: "pause", status: snapshot, errorCode: "invalid_capture_state")
        }
        if let currentStream {
            Task { [weak self, currentStream] in
                do {
                    try await currentStream.stopCapture()
                    guard self?.isTrackedStream(currentStream) == true else { return }
                    self?.emit("capture.paused", status: self?.status() ?? snapshot)
                } catch {
                    guard self?.isTrackedStream(currentStream) == true else { return }
                    let failed = self?.markFailed(reason: "pause_failed") ?? snapshot
                    self?.emit("capture.failed", status: failed, message: "Mac sharing could not pause")
                }
            }
        }
        return CaptureOperationResult(accepted: true, action: "pause", status: snapshot)
    }

    public func resume(sessionID: String, generation: UInt64) -> CaptureOperationResult {
        guard matchesIdentity(sessionID: sessionID, generation: generation) else {
            return rejected("resume", errorCode: "invalid_capture_session")
        }
        guard screenRecordingIsAvailable() else {
            let snapshot = markPermissionDenied()
            return CaptureOperationResult(accepted: false, action: "resume", status: snapshot, errorCode: "screen_recording_permission_required")
        }
        lock.lock()
        let snapshot = machine.resume()
        let currentStream = stream
        intentionalStop = false
        lock.unlock()
        guard snapshot.state == .starting, let currentStream else {
            return CaptureOperationResult(accepted: false, action: "resume", status: snapshot, errorCode: "capture_not_paused")
        }
        Task { [weak self, currentStream] in
            guard let self else { return }
            do {
                guard self.isCurrentStream(currentStream) else { return }
                try await currentStream.startCapture()
                guard self.isCurrentStream(currentStream) else { return }
                let started = self.markStarted()
                self.emit("capture.resumed", status: started)
            } catch {
                guard self.isTrackedStream(currentStream) else { return }
                let failed = self.markFailed(reason: self.reason(for: error))
                self.emit("capture.failed", status: failed, message: "Mac sharing could not resume")
            }
        }
        return CaptureOperationResult(accepted: true, action: "resume", status: snapshot)
    }

    public func stop(sessionID: String, generation: UInt64, reason: String = "stopped_by_request") -> CaptureOperationResult {
        if !matchesIdentity(sessionID: sessionID, generation: generation) {
            return rejected("stop", errorCode: "invalid_capture_session")
        }
        lock.lock()
        let wasStopped = machine.status.state == .stopped
        let snapshot = machine.stop(reason: reason)
        intentionalStop = true
        let currentStream = stream
        stream = nil
        selectedFilter = nil
        selectedSource = nil
        pendingSelectionRequest = nil
        pickerSelectionRequest = nil
        lock.unlock()
        frameQueue.clear()
        if let currentStream {
            Task { try? await currentStream.stopCapture() }
        }
        if !wasStopped { emit("capture.stopped", status: snapshot) }
        return CaptureOperationResult(accepted: true, action: "stop", status: snapshot)
    }

    public func markSourceRemoved(sessionID: String, generation: UInt64) -> CaptureOperationResult {
        guard matchesIdentity(sessionID: sessionID, generation: generation) else {
            return rejected("sourceRemoved", errorCode: "invalid_capture_session")
        }
        lock.lock()
        let snapshot = machine.sourceRemoved()
        intentionalStop = true
        let currentStream = stream
        stream = nil
        selectedFilter = nil
        selectedSource = nil
        pendingSelectionRequest = nil
        pickerSelectionRequest = nil
        lock.unlock()
        frameQueue.clear()
        if let currentStream {
            Task { try? await currentStream.stopCapture() }
        }
        emit("capture.sourceRemoved", status: snapshot, message: "The selected Mac window is no longer available")
        return CaptureOperationResult(accepted: true, action: "sourceRemoved", status: snapshot)
    }

    public func setViewerCount(_ count: Int, sessionID: String, generation: UInt64) -> CaptureOperationResult {
        guard matchesIdentity(sessionID: sessionID, generation: generation) else {
            return rejected("viewerCount", errorCode: "invalid_capture_session")
        }
        lock.lock()
        let snapshot = machine.setViewerCount(count)
        let shouldStop = snapshot.state == .stopped && snapshot.reason == "no_authorized_viewers"
        let currentStream = shouldStop ? stream : nil
        if shouldStop {
            stream = nil
            pendingSelectionRequest = nil
            pickerSelectionRequest = nil
        }
        lock.unlock()
        if shouldStop {
            if let currentStream {
                Task { try? await currentStream.stopCapture() }
            }
            frameQueue.clear()
            emit("capture.stopped", status: snapshot)
        }
        return CaptureOperationResult(accepted: true, action: "viewerCount", status: snapshot)
    }

    public func restart() -> CaptureOperationResult {
        stopStream()
        frameQueue.reset()
        let snapshot: CaptureStatusSnapshot = {
            lock.lock()
            defer { lock.unlock() }
            let snapshot = machine.helperRestarted()
            selectedFilter = nil
            selectedSource = nil
            pendingSelectionRequest = nil
            pickerSelectionRequest = nil
            frameSequence = 0
            lastFrameMetadataEmissionUptime = nil
            return snapshot
        }()
        emit("capture.helperRestarted", status: snapshot)
        return CaptureOperationResult(accepted: true, action: "restart", status: snapshot)
    }

    public func shutdown(reason: String = "helper_stopped") -> CaptureStatusSnapshot {
        lock.lock()
        let wasStopped = machine.status.state == .stopped
        let snapshot = machine.stop(reason: reason)
        intentionalStop = true
        let currentStream = stream
        stream = nil
        selectedFilter = nil
        selectedSource = nil
        pendingSelectionRequest = nil
        pickerSelectionRequest = nil
        lock.unlock()
        frameQueue.clear()
        if let currentStream {
            Task { try? await currentStream.stopCapture() }
        }
        if !wasStopped { emit("capture.stopped", status: snapshot) }
        return snapshot
    }

    private func completeSourceSelection(
        content: SCShareableContent?,
        requestedSourceID: String?,
        mainDisplayID: CGDirectDisplayID,
        request: SourceSelectionRequest
    ) {
        guard isCurrentSelection(request) else { return }

        guard screenRecordingIsAvailable() else {
            guard let denied = markPermissionDenied(for: request) else { return }
            emit("capture.failed", status: denied, message: "Allow Screen Recording for Wonder on your Mac")
            return
        }

        guard let content else {
            guard let failed = markSourceSelectionFailed(for: request, reason: "shareable_content_unavailable") else { return }
            emit("capture.failed", status: failed, message: "Mac content is unavailable")
            return
        }

        guard let sources = cacheSources(content, for: request) else { return }
        let plan = CaptureSourceSelectionPlanner.plan(
            requestedSourceID: requestedSourceID,
            displayIDs: Set(content.displays.map { UInt32($0.displayID) }),
            sourceIDs: Set(sources.map(\.id)),
            mainDisplayID: UInt32(mainDisplayID),
            pickerAvailable: pickerIsAvailable()
        )

        switch plan {
        case let .select(sourceID):
            guard let source = source(for: sourceID), let filter = makeFilter(for: source) else {
                guard let failed = markSourceSelectionFailed(for: request, reason: "source_unavailable") else { return }
                emit("capture.failed", status: failed, message: "The selected Mac source is unavailable")
                return
            }
            selectSource(source, filter: filter, for: request)

        case .presentSharingPicker:
            guard presentSystemPicker(for: request) else { return }
            guard let pending = currentSelectionStatus(for: request) else { return }
            emit("capture.pickerPresented", status: pending, message: "Choose a window or display on your Mac")

        case let .unavailable(reason):
            guard let failed = markSourceSelectionFailed(for: request, reason: reason) else { return }
            let message = reason == "system_picker_unavailable"
                ? "No display is available and the Mac sharing picker is unavailable"
                : "The requested Mac source is unavailable"
            emit("capture.failed", status: failed, message: message)
        }
    }

    private func cacheSources(_ content: SCShareableContent) -> [CaptureSourceDescriptor] {
        let cache = makeSourceCache(content)
        lock.lock()
        displays = cache.displays
        windows = cache.windows
        lock.unlock()
        return cache.descriptors
    }

    private func cacheSources(_ content: SCShareableContent, for request: SourceSelectionRequest) -> [CaptureSourceDescriptor]? {
        let cache = makeSourceCache(content)
        lock.lock()
        guard isCurrentSelectionLocked(request) else {
            lock.unlock()
            return nil
        }
        displays = cache.displays
        windows = cache.windows
        lock.unlock()
        return cache.descriptors
    }

    private func makeSourceCache(_ content: SCShareableContent) -> (
        descriptors: [CaptureSourceDescriptor],
        displays: [String: SCDisplay],
        windows: [String: SCWindow]
    ) {
        let displays = content.displays.map { display in
            let scale = NSScreen.screens.first(where: { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == display.displayID })?.backingScaleFactor ?? 1
            let descriptor = CaptureSourceDescriptor(
                id: "display:\(display.displayID)",
                kind: .display,
                title: "Display \(display.displayID)",
                width: display.width,
                height: display.height,
                scale: scale,
                contentRect: CaptureRect(x: display.frame.origin.x, y: display.frame.origin.y, width: display.frame.width, height: display.frame.height)
            )
            return (descriptor, display)
        }
        let remainingSourceCount = max(0, maximumSourceCount - displays.count)
        let windows = content.windows.prefix(remainingSourceCount).compactMap { window -> (CaptureSourceDescriptor, SCWindow)? in
            guard window.isOnScreen else { return nil }
            let title = boundedLabel(window.title, fallback: "Window \(window.windowID)")
            let application = boundedOptionalLabel(window.owningApplication?.applicationName)
            let descriptor = CaptureSourceDescriptor(
                id: "window:\(window.windowID)",
                kind: .window,
                title: title,
                application: application,
                width: Int(window.frame.width),
                height: Int(window.frame.height),
                scale: 1,
                contentRect: CaptureRect(x: window.frame.origin.x, y: window.frame.origin.y, width: window.frame.width, height: window.frame.height)
            )
            return (descriptor, window)
        }
        return (
            descriptors: (displays.map(\.0) + windows.map(\.0)).sorted { $0.id < $1.id },
            displays: Dictionary(uniqueKeysWithValues: displays.map { ("display:\($0.1.displayID)", $0.1) }),
            windows: Dictionary(uniqueKeysWithValues: windows.map { ("window:\($0.1.windowID)", $0.1) })
        )
    }

    private func source(for id: String) -> CaptureSourceDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        if id.hasPrefix("display:"), let display = displays[id] {
            return CaptureSourceDescriptor(
                id: id,
                kind: .display,
                title: "Display \(display.displayID)",
                width: display.width,
                height: display.height,
                scale: 1,
                contentRect: CaptureRect(x: display.frame.origin.x, y: display.frame.origin.y, width: display.frame.width, height: display.frame.height)
            )
        }
        if id.hasPrefix("window:"), let window = windows[id] {
            return CaptureSourceDescriptor(
                id: id,
                kind: .window,
                title: boundedLabel(window.title, fallback: "Window \(window.windowID)"),
                application: boundedOptionalLabel(window.owningApplication?.applicationName),
                width: Int(window.frame.width),
                height: Int(window.frame.height),
                scale: 1,
                contentRect: CaptureRect(x: window.frame.origin.x, y: window.frame.origin.y, width: window.frame.width, height: window.frame.height)
            )
        }
        return nil
    }

    private func makeFilter(for source: CaptureSourceDescriptor) -> SCContentFilter? {
        lock.lock()
        defer { lock.unlock() }
        switch source.kind {
        case .display:
            guard let display = displays[source.id] else { return nil }
            return SCContentFilter(display: display, excludingWindows: [])
        case .window:
            guard let window = windows[source.id] else { return nil }
            return SCContentFilter(desktopIndependentWindow: window)
        case .picker:
            return selectedFilter
        }
    }

    static func makeStreamConfiguration(_ configuration: CaptureConfiguration, source: CaptureSourceDescriptor) -> SCStreamConfiguration {
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = configuration.width
        streamConfiguration.height = configuration.height
        let destination = configuration.centeredDestinationRect(for: source)
        streamConfiguration.destinationRect = CGRect(
            x: destination.x, y: destination.y,
            width: destination.width, height: destination.height
        )
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.framesPerSecond))
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.queueDepth = configuration.queueDepth
        streamConfiguration.capturesAudio = configuration.audioEnabled
        streamConfiguration.showsCursor = true
        streamConfiguration.scalesToFit = true
        if #available(macOS 14.0, *) {
            streamConfiguration.preservesAspectRatio = true
        }
        return streamConfiguration
    }

    private func presentSystemPicker(for request: SourceSelectionRequest) -> Bool {
        guard #available(macOS 14.0, *) else { return false }
        lock.lock()
        guard isCurrentSelectionLocked(request) else {
            lock.unlock()
            return false
        }
        pickerSelectionRequest = request
        lock.unlock()

        let picker = SCContentSharingPicker.shared
        if !pickerObserverRegistered {
            picker.add(self)
            pickerObserverRegistered = true
        }
        var configuration = picker.defaultConfiguration
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        picker.defaultConfiguration = configuration
        picker.isActive = true
        picker.present(using: .display)
        return true
    }

    private func screenRecordingIsAvailable() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private func pickerIsAvailable() -> Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    private func matchesIdentity(sessionID: String, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return machine.status.sessionID == sessionID && machine.status.generation == generation
    }

    private func isCurrentSelection(_ request: SourceSelectionRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCurrentSelectionLocked(request)
    }

    private func isCurrentSelectionLocked(_ request: SourceSelectionRequest) -> Bool {
        pendingSelectionRequest == request
            && machine.status.sessionID == request.sessionID
            && machine.status.generation == request.generation
            && machine.status.viewerCount > 0
            && machine.status.screenRecordingAuthorized
            && machine.status.state == .awaitingSource
    }

    private func currentSelectionStatus(for request: SourceSelectionRequest) -> CaptureStatusSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrentSelectionLocked(request) else { return nil }
        return machine.status
    }

    private func selectSource(
        _ source: CaptureSourceDescriptor,
        filter: SCContentFilter,
        for request: SourceSelectionRequest
    ) {
        lock.lock()
        guard isCurrentSelectionLocked(request) else {
            lock.unlock()
            return
        }
        let snapshot = machine.selectSource(source, sessionID: request.sessionID, generation: request.generation)
        if snapshot.state == .ready {
            selectedSource = source
            selectedFilter = filter
            pendingSelectionRequest = nil
            pickerSelectionRequest = nil
        }
        lock.unlock()
        guard snapshot.state == .ready else { return }
        emit("capture.sourceSelected", status: snapshot, source: source)
    }

    private func currentStatusLocked() -> CaptureStatusSnapshot {
        let base = machine.status
        return CaptureStatusSnapshot(
            state: base.state,
            sessionID: base.sessionID,
            generation: base.generation,
            helperInstanceID: base.helperInstanceID,
            sourceID: base.sourceID,
            viewerCount: base.viewerCount,
            queuedFrameCount: frameQueue.statistics().count,
            droppedFrameCount: frameQueue.statistics().droppedCount,
            frameSequence: base.frameSequence,
            geometryRevision: base.geometryRevision,
            pickerAvailable: base.pickerAvailable,
            screenRecordingAuthorized: base.screenRecordingAuthorized,
            audioEnabled: base.audioEnabled,
            configuration: base.configuration,
            lastFrame: base.lastFrame,
            message: base.message,
            reason: base.reason
        )
    }

    private func markStarted() -> CaptureStatusSnapshot {
        lock.lock()
        let snapshot = machine.captureStarted()
        lock.unlock()
        return snapshot
    }

    private func markFailed(reason: String) -> CaptureStatusSnapshot {
        lock.lock()
        let snapshot = machine.failed(reason: reason)
        stream = nil
        pendingSelectionRequest = nil
        pickerSelectionRequest = nil
        lock.unlock()
        frameQueue.clear()
        return snapshot
    }

    private func markPermissionDenied(reason: String = "screen_recording_permission_required") -> CaptureStatusSnapshot {
        lock.lock()
        let snapshot = machine.permissionDenied(reason: reason)
        intentionalStop = true
        let currentStream = stream
        stream = nil
        selectedFilter = nil
        selectedSource = nil
        pendingSelectionRequest = nil
        pickerSelectionRequest = nil
        lock.unlock()
        frameQueue.clear()
        if let currentStream {
            Task { try? await currentStream.stopCapture() }
        }
        return snapshot
    }

    private func markPermissionDenied(for request: SourceSelectionRequest) -> CaptureStatusSnapshot? {
        lock.lock()
        guard isCurrentSelectionLocked(request) else {
            lock.unlock()
            return nil
        }
        let snapshot = machine.permissionDenied()
        intentionalStop = true
        let currentStream = stream
        stream = nil
        selectedFilter = nil
        selectedSource = nil
        pendingSelectionRequest = nil
        pickerSelectionRequest = nil
        lock.unlock()
        frameQueue.clear()
        if let currentStream {
            Task { try? await currentStream.stopCapture() }
        }
        return snapshot
    }

    private func markSourceSelectionFailed(
        for request: SourceSelectionRequest,
        reason: String
    ) -> CaptureStatusSnapshot? {
        lock.lock()
        guard isCurrentSelectionLocked(request) else {
            lock.unlock()
            return nil
        }
        let snapshot = machine.failed(reason: reason)
        intentionalStop = true
        let currentStream = stream
        stream = nil
        selectedFilter = nil
        selectedSource = nil
        pendingSelectionRequest = nil
        pickerSelectionRequest = nil
        lock.unlock()
        frameQueue.clear()
        if let currentStream {
            Task { try? await currentStream.stopCapture() }
        }
        return snapshot
    }

    private func rejected(_ action: String, errorCode: String) -> CaptureOperationResult {
        CaptureOperationResult(accepted: false, action: action, status: status(), errorCode: errorCode)
    }

    private func emit(_ event: String, status: CaptureStatusSnapshot, metadata: CaptureFrameMetadata? = nil, sources: [CaptureSourceDescriptor]? = nil, source: CaptureSourceDescriptor? = nil, message: String? = nil) {
        eventSink(CaptureEvent(event: event, status: status, metadata: metadata, sources: sources, source: source, message: message))
    }

    private func reason(for error: Error) -> String {
        let nsError = error as NSError
        return "stream_error_\(nsError.domain)_\(nsError.code)"
    }

    private func boundedLabel(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty else { return fallback }
        return String(value.prefix(256))
    }

    private func boundedOptionalLabel(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value.prefix(256))
    }

    private func stopStream() {
        lock.lock()
        intentionalStop = true
        let currentStream = stream
        stream = nil
        lock.unlock()
        if let currentStream {
            Task { try? await currentStream.stopCapture() }
        }
    }

    private func isCurrentStream(_ candidate: SCStream) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stream === candidate && machine.status.state == .starting
    }

    private func isTrackedStream(_ candidate: SCStream) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stream === candidate
    }
}

extension ScreenCaptureSession: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        guard self.stream === stream,
              machine.status.state == .capturing,
              let source = selectedSource,
              let sessionID = machine.status.sessionID else {
            lock.unlock()
            return
        }
        frameSequence &+= 1
        let sequence = frameSequence
        let generation = machine.status.generation
        let geometryRevision = machine.status.geometryRevision
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampSeconds = CMTimeGetSeconds(timestamp)
        let seconds = timestamp.isValid && timestampSeconds.isFinite && timestampSeconds >= 0
            ? timestampSeconds
            : Date().timeIntervalSince1970
        let metadata = CaptureFrameMetadata.make(
            timestamp: seconds,
            sourceWidth: width,
            sourceHeight: height,
            source: source,
            geometryRevision: geometryRevision,
            frameSequence: sequence,
            sessionID: sessionID,
            generation: generation
        )
        frameQueue.offer(CapturedVideoFrame(pixelBuffer: imageBuffer, timestamp: timestamp, metadata: metadata))
        let stats = frameQueue.statistics()
        let snapshot = machine.recordFrame(metadata, queuedFrameCount: stats.count, droppedFrameCount: stats.droppedCount)
        let now = ProcessInfo.processInfo.systemUptime
        let shouldEmitMetadata = lastFrameMetadataEmissionUptime.map { now - $0 >= 1 } ?? true
        if shouldEmitMetadata {
            lastFrameMetadataEmissionUptime = now
        }
        lock.unlock()
        // The frame itself never leaves this callback. Coalesce bounded status
        // metadata so the JSONL control pipe is not driven at the video frame rate.
        if shouldEmitMetadata {
            emit("capture.frameMetadata", status: snapshot, metadata: metadata)
        }
    }
}

extension ScreenCaptureSession: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        guard self.stream === stream else {
            lock.unlock()
            return
        }
        let wasIntentional = intentionalStop
        intentionalStop = false
        lock.unlock()
        guard !wasIntentional else { return }
        let failed = markFailed(reason: reason(for: error))
        emit("capture.failed", status: failed, message: "Mac sharing stopped")
    }

    @available(macOS 15.2, *)
    public func streamDidBecomeInactive(_ stream: SCStream) {
        lock.lock()
        guard self.stream === stream else {
            lock.unlock()
            return
        }
        let snapshot = machine.suspended()
        lock.unlock()
        emit("capture.suspended", status: snapshot, message: "The selected Mac window is not available")
    }

    @available(macOS 15.2, *)
    public func streamDidBecomeActive(_ stream: SCStream) {
        lock.lock()
        guard self.stream === stream else {
            lock.unlock()
            return
        }
        let snapshot: CaptureStatusSnapshot
        if machine.status.state == .suspended {
            snapshot = machine.resumedFromSuspension()
        } else {
            snapshot = machine.status
        }
        lock.unlock()
        emit("capture.resumed", status: snapshot)
    }
}

@available(macOS 14.0, *)
extension ScreenCaptureSession: SCContentSharingPickerObserver {
    public func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let descriptor: CaptureSourceDescriptor
        let info = SCShareableContent.info(for: filter)
        descriptor = CaptureSourceDescriptor(
            id: "picker-selection",
            kind: .picker,
            title: "Selected Mac content",
            width: Int(info.contentRect.width * CGFloat(info.pointPixelScale)),
            height: Int(info.contentRect.height * CGFloat(info.pointPixelScale)),
            scale: Double(info.pointPixelScale),
            contentRect: CaptureRect(x: info.contentRect.origin.x, y: info.contentRect.origin.y, width: info.contentRect.width, height: info.contentRect.height)
        )
        lock.lock()
        guard let request = pickerSelectionRequest, isCurrentSelectionLocked(request) else {
            lock.unlock()
            return
        }
        let snapshot = machine.selectSource(descriptor, sessionID: request.sessionID, generation: request.generation)
        if snapshot.state == .ready {
            selectedFilter = filter
            selectedSource = descriptor
            pendingSelectionRequest = nil
            pickerSelectionRequest = nil
        }
        lock.unlock()
        guard snapshot.state == .ready else { return }
        emit("capture.sourceSelected", status: snapshot, source: descriptor, message: "Mac content selected")
    }

    public func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        lock.lock()
        let request = pickerSelectionRequest
        let isCurrent = request.map { isCurrentSelectionLocked($0) } ?? false
        let snapshot = isCurrent ? machine.status : nil
        lock.unlock()
        guard let snapshot else { return }
        emit("capture.pickerCancelled", status: snapshot, message: "Choose what to share on your Mac")
    }

    public func contentSharingPickerStartDidFailWithError(_ error: Error) {
        lock.lock()
        let request = pickerSelectionRequest
        lock.unlock()
        guard let request,
              let failed = markSourceSelectionFailed(for: request, reason: reason(for: error)) else { return }
        emit("capture.failed", status: failed, message: "The Mac sharing picker could not open")
    }
}
