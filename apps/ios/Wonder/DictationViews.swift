import SwiftUI
import AVFoundation
import CryptoKit
import WonderPairing

@MainActor final class DictationController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var intent: DictationIntent?
    @Published private(set) var models: DictationModels?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var audioLevels: [CGFloat] = []
    @Published private(set) var now = Date()
    @Published private(set) var modelsFailure: String?
    @Published private(set) var busy = false
    @Published private(set) var requiresResume = false
    @Published private(set) var failure: String?
    @Published private(set) var microphoneDenied = false
    private weak var model: ConnectionModel?
    private var recorder: AVAudioRecorder?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var interruptions: Task<Void, Never>?
    private var scope: String?
    private var maximum: TimeInterval = 300
    private var captureGeneration = 0
    private var audioURL: URL? {
        guard let connection = model?.connection else { return nil }
        let identity = (intent?.hostID ?? connection.credential.hostInstallationId) + ":" + (intent?.deviceID ?? connection.credential.deviceId)
        let partition = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wonder/Dictation/" + partition + "/recording.m4a")
    }
    var recording: Bool { intent?.phase == "recording" }
    var processing: Bool { ["uploading", "processing"].contains(intent?.phase ?? "") }
    var canRetry: Bool {
        guard !busy, let intent, !intent.cancelled else { return false }
        if intent.jobID != nil {
            return intent.jobState != "failed" || intent.retryExpiresAtMs.map { UInt64(now.timeIntervalSince1970 * 1000) < $0 } == true
        }
        return intent.canRetryAudio(now: now) && audioURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }
    var selectedModelName: String? { models?.models.first(where: { $0.id == models?.selectedModelId })?.name }
    init(model: ConnectionModel) { self.model = model; super.init() }

    func restore(force: Bool = false) {
        guard let model else { return }
        guard force || scope != model.assignmentScope else { return }
        work?.cancel(); timer?.cancel(); interruptions?.cancel()
        stopCapture()
        scope = model.assignmentScope; models = nil; busy = false; failure = nil; audioLevels = []
        do { intent = try model.savedDictationIntent() }
        catch { intent = nil; failure = "Your saved recording could not be opened." }
        if intent?.phase == "recording" {
            intent?.cancelled = true; intent?.phase = "cancelled"; removeAudio()
            failure = "Recording was interrupted. Record again."; persist()
        }
        pauseInterruptedUpload()
        // Reopening the app never consumes a saved result without an explicit resume.
        // This also fails closed if cancellation could not be written before exit.
        requiresResume = intent != nil && intent?.cancelled == false
        if requiresResume { intent?.phase = "paused"; failure = "Resume dictation to check your recording, or cancel." }
        startTimer()
    }
    func connectionChanged() {
        captureGeneration += 1
        work?.cancel(); stopCapture()
        removeAudio()
        timer?.cancel(); interruptions?.cancel(); scope = nil; intent = nil; models = nil; busy = false; requiresResume = false; audioLevels = []
    }
    func foreground(_ active: Bool) {
        if !active {
            if recording { finishCapture(submit: false) }
            work?.cancel(); busy = false
            pauseInterruptedUpload()
        } else {
            restore()
            if intent?.jobID != nil, intent?.cancelled == false, !requiresResume { inspect() }
        }
    }
    private func pauseInterruptedUpload() {
        guard intent?.phase == "uploading", intent?.jobID == nil, intent?.cancelled == false else { return }
        intent?.pauseInterruptedUpload()
        failure = "Upload was interrupted. Retry to check it, or cancel."
        persist()
    }
    func captureControlsHidden(conversationID: String) {
        captureGeneration += 1
        if recording, intent?.conversationID == conversationID { finishCapture(submit: false) }
    }
    @discardableResult
    func loadModels() async -> Result<DictationModels, Error> {
        guard let model, !model.previewMode, let saved = model.connection, !model.accessEnded else { return .failure(PairingFailure.wrongHost) }
        let currentScope = model.assignmentScope
        do {
            let result: DictationModels = try await model.api.asrRequest("/api/v1/asr/models", connection: saved)
            guard model.assignmentScope == currentScope, !model.accessEnded else { return .failure(CancellationError()) }
            models = result; modelsFailure = nil
            return .success(result)
        } catch {
            if model.assignmentScope == currentScope { models = nil; modelsFailure = readable(error) }
            return .failure(error)
        }
    }
    func start(chat: ChatSummary) async {
        guard let model, !model.previewMode, !busy, intent == nil, !model.accessEnded else { return }
        restore(); guard intent == nil else { return }
        busy = true; failure = nil
        let initialScope = model.assignmentScope, generation = captureGeneration
        defer { if initialScope == model.assignmentScope { busy = false } }
        let status = await loadModels()
        guard initialScope == model.assignmentScope, generation == captureGeneration else { return }
        guard case .success(let catalog) = status else {
            if case .failure(let error) = status { failure = readable(error) }
            return
        }
        guard catalog.ready, let modelID = catalog.selectedModelId,
            catalog.languages.contains("auto"), let saved = model.connection else {
            failure = "Set up dictation on your Mac."; return
        }
        let host = saved.credential.hostInstallationId, device = saved.credential.deviceId
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        microphoneDenied = !granted
        guard granted else { failure = "Allow microphone access in Settings to dictate."; return }
        guard initialScope == model.assignmentScope, generation == captureGeneration,
            model.connection?.credential.hostInstallationId == host, model.connection?.credential.deviceId == device,
            !model.accessEnded, UIApplication.shared.applicationState == .active, let url = audioURL else { return }
        do {
            var directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try directory.setResourceValues(values)
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
            try AVAudioSession.sharedInstance().setActive(true)
            let next = DictationIntent(hostID: host, deviceID: device, conversationID: chat.id, conversationTitle: chat.title, modelID: modelID)
            try model.persistDictationIntent(next)
            intent = next
            let capture = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AVAudioSession.sharedInstance().sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
            capture.delegate = self
            capture.isMeteringEnabled = true
            guard capture.prepareToRecord() else { throw DictationFailure(errorCategory: "no_audio") }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            maximum = Double(min(catalog.maxRecordingDurationMs, 300_000)) / 1000
            guard maximum >= 0.25, capture.record(forDuration: maximum) else { throw DictationFailure(errorCategory: "no_audio") }
            recorder = capture; elapsed = 0; audioLevels = []; startTimer(); observeInterruptions()
        } catch {
            stopCapture()
            intent?.phase = "failed"; intent?.cancelled = true; persist(); removeAudio()
            failure = "Recording could not start. " + ((error as? DictationFailure)?.message ?? error.localizedDescription)
        }
    }
    #if DEBUG && targetEnvironment(simulator)
    var fixtureMode: Bool { ProcessInfo.processInfo.arguments.contains("-dictation-fixtures") }
    func transcribeFixture(seconds: Int, chat: ChatSummary) async {
        guard fixtureMode, [180, 300].contains(seconds), let model, !model.previewMode,
            !busy, intent == nil, !model.accessEnded else { return }
        restore(); guard intent == nil else { return }
        busy = true; failure = nil
        let initialScope = model.assignmentScope, generation = captureGeneration
        let status = await loadModels()
        guard initialScope == model.assignmentScope, generation == captureGeneration else { busy = false; return }
        guard case .success(let catalog) = status else {
            busy = false
            if case .failure(let error) = status { failure = readable(error) }
            return
        }
        guard catalog.ready, let modelID = catalog.selectedModelId,
            let saved = model.connection, let destination = audioURL else {
            busy = false; failure = "Set up dictation on your Mac."; return
        }
        do {
            let source = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DictationFixtures/english-\(seconds)s.m4a")
            let audio = try AVAudioFile(forReading: source)
            let milliseconds = UInt64(Double(audio.length) / audio.processingFormat.sampleRate * 1000)
            guard milliseconds >= 250, milliseconds <= 300_000 else { throw DictationFailure(errorCategory: "unsupported_recording_format") }
            var directory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try directory.setResourceValues(values)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: source, to: destination)
            var pending = DictationIntent(hostID: saved.credential.hostInstallationId, deviceID: saved.credential.deviceId,
                conversationID: chat.id, conversationTitle: chat.title, modelID: modelID)
            pending.finishCapture(durationMs: milliseconds)
            try model.persistDictationIntent(pending); intent = pending; busy = false; startTimer(); upload()
        } catch { busy = false; failure = readable(error); removeAudio() }
    }
    #endif

    func finishCapture(submit: Bool = true) {
        guard recording, var pending = intent, let url = audioURL else { return }
        stopCapture()
        do {
            let audio = try AVAudioFile(forReading: url)
            let milliseconds = UInt64(max(0, Double(audio.length) / audio.processingFormat.sampleRate * 1000))
            guard milliseconds >= 250 else { throw DictationFailure(errorCategory: "too_short") }
            guard milliseconds <= 300_000 else { throw DictationFailure(errorCategory: "unsupported_recording_format") }
            pending.finishCapture(durationMs: milliseconds); intent = pending
            try model?.persistDictationIntent(pending)
            if submit { upload() }
            else { failure = "Recording interrupted. Retry to transcribe it, or cancel." }
        } catch { intent?.phase = "failed"; intent?.cancelled = true; failure = readable(error); persist(); removeAudio() }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recording, self.recorder === recorder else { return }
            if flag { self.finishCapture() }
            else { self.finishCapture(submit: false) }
        }
    }
    private func observeInterruptions() {
        interruptions?.cancel()
        interruptions = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                guard !Task.isCancelled else { return }
                if self?.recording == true { self?.finishCapture(submit: false) }
            }
        }
    }
    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.intent != nil else { return }
                if self.recording, let recorder = self.recorder {
                    self.elapsed = recorder.currentTime
                    recorder.updateMeters()
                    let decibels = recorder.averagePower(forChannel: 0)
                    // A bounded logarithmic display of actual recorder power. No
                    // synthetic movement or speech is inferred from these samples.
                    let level = decibels.isFinite ? CGFloat(max(0, min(1, (decibels + 60) / 60))) : 0
                    self.audioLevels.append(level)
                    if self.audioLevels.count > 48 { self.audioLevels.removeFirst(self.audioLevels.count - 48) }
                }
                else {
                    // Also refresh expiry-dependent controls while a failed clip is retained.
                    self.now = Date()
                    if let expires = self.intent?.audioExpiresAt, Date() >= expires { self.removeAudio() }
                }
                do { try await Task.sleep(for: .milliseconds(self.recording ? 100 : 1000)) } catch { return }
            }
        }
    }
    private func upload() {
        guard !busy, let pending = intent, !pending.cancelled, pending.canRetryAudio(), let url = audioURL,
            let model, let saved = matchingConnection(pending) else { return }
        busy = true; intent?.phase = "uploading"; failure = nil; persist()
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.intent?.requestID == pending.requestID { self.busy = false } }
            do {
                let bytes = try Data(contentsOf: url)
                let job: TranscriptionJob = try await model.api.asrRequest("/api/v1/asr/transcriptions", connection: saved, method: "POST", recording: bytes, intent: pending)
                guard self.matches(pending), !Task.isCancelled else { return }
                try self.receive(job, pending: pending)
                if self.processing { await self.poll(pending) }
            } catch { self.fail(error, pending: pending) }
        }
    }
    func inspect(retryFailed: Bool = false) {
        guard !busy, let pending = intent, pending.jobID != nil, !pending.cancelled else { return }
        busy = true; failure = nil
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.intent?.requestID == pending.requestID { self.busy = false } }
            do {
                guard let model = self.model, let saved = self.matchingConnection(pending), let id = pending.jobID else { return }
                var job: TranscriptionJob = try await model.api.asrRequest("/api/v1/asr/transcriptions/" + ConnectionModel.escape(id), connection: saved)
                guard self.matches(pending), !Task.isCancelled else { return }
                if retryFailed, job.state == "failed", job.retryExpiresAtMs.map({ UInt64(Date().timeIntervalSince1970 * 1000) < $0 }) == true {
                    job = try await model.api.asrRequest("/api/v1/asr/transcriptions/" + ConnectionModel.escape(id) + "/retry", connection: saved, method: "POST")
                }
                guard self.matches(pending), !Task.isCancelled else { return }
                try self.receive(job, pending: pending)
                if self.processing { await self.poll(pending) }
            } catch { self.fail(error, pending: pending) }
        }
    }
    func retry() {
        requiresResume = false
        if intent?.jobID != nil { inspect(retryFailed: true) } else { upload() }
    }
    private func poll(_ pending: DictationIntent) async {
        while matches(pending), !Task.isCancelled, processing {
            do {
                try await Task.sleep(for: .seconds(1))
                guard let model, let saved = matchingConnection(pending), let id = intent?.jobID else { return }
                let job: TranscriptionJob = try await model.api.asrRequest("/api/v1/asr/transcriptions/" + ConnectionModel.escape(id), connection: saved)
                guard matches(pending), !Task.isCancelled else { return }
                try receive(job, pending: pending)
            } catch { fail(error, pending: pending); return }
        }
    }
    private func receive(_ job: TranscriptionJob, pending: DictationIntent) throws {
        guard matches(pending), var current = intent, current.accepts(job) else { throw PairingFailure.wrongHost }
        current.jobID = job.id; current.jobState = job.state; current.retryExpiresAtMs = job.retryExpiresAtMs
        current.phase = job.state == "queued" ? "processing" : job.state
        intent = current; try model?.persistDictationIntent(current)
        switch job.state {
        case "completed":
            removeAudio()
            guard let model else { return }
            try model.insertDictation(job: job, intent: current)
            clear()
        case "cancelled": removeAudio(); clear()
        case "failed": failure = DictationFailure(errorCategory: job.errorCategory ?? "transcription").message
        default: break
        }
    }
    func cancel() {
        guard var pending = intent else { return }
        var cancellationSaved = true
        do {
            try pending.cancelLocally(stopCapture: {
                work?.cancel(); stopCapture(); removeAudio(); busy = false
            }, persist: { cancelled in
                // Publish suppression before a potentially failing durable write.
                intent = cancelled
                try model?.persistDictationIntent(cancelled)
            })
        } catch {
            cancellationSaved = false
            failure = "Recording stopped. Cancellation could not be saved. Keep this screen open and retry cancellation."
        }
        guard let model, let saved = matchingConnection(pending) else {
            failure = cancellationSaved ? "Cancellation is saved. Reconnect to confirm it on your Mac."
                : "Recording stopped, but cancellation could not be saved. Keep this screen open and retry cancellation."
            return
        }
        busy = true
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.intent?.requestID == pending.requestID { self.busy = false } }
            do {
                struct Empty: Decodable, Sendable {}
                let _: Empty = try await model.api.asrRequest("/api/v1/asr/transcriptions/by-request/" + pending.requestID, connection: saved, method: "DELETE")
                guard self.intent?.requestID == pending.requestID else { return }; self.clear()
            } catch { if self.intent?.requestID == pending.requestID { self.failure = cancellationSaved
                    ? "Cancelled on this device. Your Mac could not confirm cancellation. Retry when it reconnects."
                    : "Recording stopped, but cancellation could not be saved or confirmed. Keep this screen open and retry cancellation." } }
        }
    }
    func clear() {
        removeAudio(); timer?.cancel(); interruptions?.cancel(); audioLevels = []
        do { try model?.clearDictationIntent(); intent = nil; busy = false; requiresResume = false; failure = nil }
        catch { failure = "The saved recording could not be cleared. Try again." }
    }
    func forget() { work?.cancel(); stopCapture(); clear() }
    private func stopCapture() {
        recorder?.delegate = nil; recorder?.stop(); recorder = nil
        interruptions?.cancel(); interruptions = nil
        // Stopping the recorder alone does not release the app's audio session.
        // Revocation and connection replacement must release it just like Finish.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func removeAudio() { if let url = audioURL, FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) } }
    private func persist() { if let intent { do { try model?.persistDictationIntent(intent) } catch { failure = "This recording could not be saved on this device." } } }
    private func matchingConnection(_ pending: DictationIntent) -> SavedConnection? {
        guard let model, !model.accessEnded, let saved = model.connection,
            saved.credential.hostInstallationId == pending.hostID, saved.credential.deviceId == pending.deviceID else { return nil }
        return saved
    }
    private func matches(_ pending: DictationIntent) -> Bool { intent?.requestID == pending.requestID && intent?.cancelled == false && matchingConnection(pending) != nil }
    private func fail(_ error: Error, pending: DictationIntent) {
        guard matches(pending), !(error is CancellationError), !Task.isCancelled else { return }
        intent?.phase = "failed"; failure = readable(error); persist()
    }
    private func readable(_ error: Error) -> String {
        if let failure = error as? DictationFailure { return failure.message }
        if case PairingFailure.response(let code) = error {
            switch code {
            case 401, 403: return "Access has ended. Reconnect to your Mac in Settings."
            case 404: return "This recording is no longer available on your Mac."
            case 409: return "Your Mac could not match this recording. Cancel and record again."
            case 410: return "This recording expired. Record again."
            default: break
            }
        }
        if case SendFailure.tooLarge = error { return "The transcript does not fit in this draft. Shorten the draft, then retry." }
        return "Your Mac is unavailable. Retry while the recording is still available."
    }
}

/// The draft editor remains mounted while its own recording takes over the composer.
struct DictationComposerSurface<Content: View>: View {
    @ObservedObject var controller: DictationController
    let conversationID: String
    @ViewBuilder var content: () -> Content
    @ScaledMetric(relativeTo: .body) private var overlayHeight: CGFloat = 52
    private var active: Bool {
        controller.intent?.conversationID == conversationID && (controller.recording || controller.processing)
    }
    var body: some View {
        ZStack {
            content()
                .opacity(active ? 0 : 1)
                .disabled(active)
                .allowsHitTesting(!active)
                .accessibilityHidden(active)
                .frame(height: active ? max(52, overlayHeight) : nil)
                .clipped()
            if active { DictationComposerOverlay(controller: controller) }
        }
        .onChange(of: active) { _, active in
            if active { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        }
    }
}

private struct DictationComposerOverlay: View {
    @ObservedObject var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var duration: String {
        let seconds = Int(controller.recording ? controller.elapsed : Double(controller.intent?.durationMs ?? 0) / 1000)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
    var body: some View {
        HStack(spacing: 8) {
            Button { controller.cancel() } label: {
                Image(systemName: "xmark").font(.body.weight(.medium)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Cancel dictation")
            .accessibilityHint("Discards this recording and keeps your message draft.")
            .accessibilityIdentifier("cancel-dictation")
            VStack(alignment: .leading, spacing: 2) {
                if controller.audioLevels.isEmpty {
                    if controller.recording {
                        Text("Listening…")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    AudioLevelWaveform(levels: reduceMotion ? Array(controller.audioLevels.suffix(1)) : controller.audioLevels)
                        .frame(height: 26).accessibilityHidden(true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(duration).font(.callout.monospacedDigit()).fixedSize()
                .accessibilityLabel("Recorded duration \(duration)")
            if controller.recording {
                Button { controller.finishCapture() } label: {
                    Image(systemName: "checkmark").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .background(Color.primary, in: Circle())
                }
                .accessibilityLabel("Finish dictation")
                .accessibilityHint("Stops recording and transcribes into your draft without sending.")
                .accessibilityIdentifier("finish-dictation")
            } else {
                ProgressView().frame(width: 44, height: 44).accessibilityLabel("Transcribing recording")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictation-composer-overlay")
    }
}

private struct AudioLevelWaveform: View {
    let levels: [CGFloat]
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 4
            let visible = Array(levels.suffix(max(1, Int(size.width / spacing))))
            let start = max(0, size.width - CGFloat(visible.count) * spacing)
            for (index, level) in visible.enumerated() {
                let height = max(2, level * size.height)
                let rect = CGRect(x: start + CGFloat(index) * spacing, y: (size.height - height) / 2, width: 2, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .foreground)
            }
        }
    }
}

struct DictationControls: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let intent = controller.intent, !(intent.conversationID == chat.id && (controller.recording || controller.processing)) {
                HStack {
                    if controller.recording { Text("Recording · \(Int(controller.elapsed) / 60):\(String(format: "%02d", Int(controller.elapsed) % 60))").monospacedDigit() }
                    else if controller.processing { ProgressView().controlSize(.small).accessibilityLabel("Transcribing recording") }
                    else { Text(intent.phase == "failed" && intent.jobID == nil ? "Recording unavailable" : (intent.cancelled ? "Recording cancelled" : "Dictation paused")) }
                    Spacer()
                    if controller.recording { Button("Stop") { controller.finishCapture() } }
                    else if intent.phase == "failed", intent.jobID == nil, intent.durationMs == 0 { Button("Record again") { controller.clear() }.disabled(controller.busy) }
                    else if intent.cancelled { Button("Retry cancellation") { controller.cancel() }.disabled(controller.busy) }
                    else if !controller.processing { Button(controller.requiresResume ? "Resume" : "Retry") { controller.retry() }.disabled(!controller.canRetry) }
                    if !intent.cancelled { Button("Cancel") { controller.cancel() } }
                }.font(.subheadline)
                if intent.conversationID != chat.id { Text("For \(intent.conversationTitle)").font(.caption).foregroundStyle(.secondary) }
                if !controller.recording, !controller.processing, !controller.canRetry, !controller.busy, !intent.cancelled { Text("This recording expired. Record again.").font(.caption).foregroundStyle(.secondary) }
            }
            #if DEBUG && targetEnvironment(simulator)
            if controller.fixtureMode, controller.intent == nil {
                HStack {
                    Button("Test 3-minute audio") { Task { await controller.transcribeFixture(seconds: 180, chat: chat) } }
                    Button("Test 5-minute audio") { Task { await controller.transcribeFixture(seconds: 300, chat: chat) } }
                }.font(.caption).disabled(controller.busy)
            }
            #endif
            if let failure = controller.failure { FailureDetails("Dictation unavailable", message: failure) }
            if controller.microphoneDenied { Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.font(.caption) }
        }
        .task(id: model.assignmentScope) { controller.restore() }
    }
}

struct DictationButton: View {
    @ObservedObject var controller: DictationController
    let chat: ChatSummary
    let unavailable: Bool
    var body: some View {
        Button {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            Task { await controller.start(chat: chat) }
        } label: {
            if controller.busy && controller.intent == nil { ProgressView().frame(width: 44, height: 44) }
            else { Image(systemName: "mic").font(.system(size: 20)).frame(width: 44, height: 44) }
        }.accessibilityLabel("Dictate message").accessibilityIdentifier("dictate-message")
            .disabled(unavailable || controller.busy || controller.intent != nil)
    }
}

struct VoiceSettingsView: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var controller: DictationController
    var body: some View {
        List {
            Section {
                LabeledContent("Mac", value: model.macName)
                LabeledContent("Dictation", value: controller.models?.ready == true ? "Ready" : "Unavailable")
                if let name = controller.selectedModelName { LabeledContent("Model", value: name) }
                LabeledContent("Language", value: "Detect automatically")
                Button("Refresh") { Task { await controller.loadModels() } }
            } footer: { Text("Models are managed on your Mac.") }
            if let failure = controller.modelsFailure { FailureDetails(message: failure) }
        }.navigationTitle("Voice & Dictation")
            .task(id: model.assignmentScope) { await controller.loadModels() }
    }
}
