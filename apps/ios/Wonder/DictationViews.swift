import SwiftUI
@preconcurrency import AVFoundation
@preconcurrency import Speech
import CryptoKit
import WonderPairing

@MainActor protocol DictationEditor: AnyObject {
    var dictationLocale: String { get }
    func beginDictation() -> Bool
    func showDictation(_ words: String) -> Bool
    func endDictation(commitWords: Bool) -> Bool
}

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
    @Published private(set) var speechDenied = false
    @Published private(set) var nativeConversationID: String?
    private weak var editor: (any DictationEditor)?
    private var editorConversationID: String?
    private var nativeCapture: NativeSpeechCapture?
    private var nativeRecognizer: SFSpeechRecognizer?
    private var nativeTask: SFSpeechRecognitionTask?
    private var nativeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var finalization: Task<Void, Never>?
    @Published private var nativeWords = ""
    private var nativeStartedAt: Date?
    private var nativeFailed = false
    private var nativeRecordingFailed = false
    private weak var model: ConnectionModel?
    private var recorder: AVAudioRecorder?
    private var audioSessionActive = false
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var interruptions: Task<Void, Never>?
    private var routeChanges: Task<Void, Never>?
    private var scope: String?
    private var maximum: TimeInterval = 600
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
        discardNative()
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
        discardNative()
        work?.cancel(); stopCapture()
        removeAudio()
        timer?.cancel(); interruptions?.cancel(); scope = nil; intent = nil; models = nil; busy = false; requiresResume = false; audioLevels = []
    }
    func foreground(_ active: Bool) {
        if !active {
            if nativeConversationID != nil { finishNativeImmediately() }
            else if recording { finishCapture(submit: false) }
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
        if nativeConversationID == conversationID { finishNativeImmediately() }
        else if recording, intent?.conversationID == conversationID { finishCapture(submit: false) }
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
        if await startNative(chat: chat, scope: initialScope, generation: generation) { return }
        guard initialScope == model.assignmentScope, generation == captureGeneration, !Task.isCancelled else { return }
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
            audioSessionActive = true
            let next = DictationIntent(hostID: host, deviceID: device, conversationID: chat.id, conversationTitle: chat.title, modelID: modelID)
            try model.persistDictationIntent(next)
            intent = next
            let capture = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AVAudioSession.sharedInstance().sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
            capture.delegate = self
            capture.isMeteringEnabled = true
            guard capture.prepareToRecord() else { throw DictationFailure(errorCategory: "no_audio") }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            maximum = Double(min(catalog.maxRecordingDurationMs, 600_000)) / 1000
            guard maximum >= 0.25, capture.record(forDuration: maximum) else { throw DictationFailure(errorCategory: "no_audio") }
            nativeRecordingFailed = false
            recorder = capture; elapsed = 0; audioLevels = []; startTimer(); observeInterruptions()
        } catch {
            stopCapture()
            intent?.phase = "failed"; intent?.cancelled = true; persist(); removeAudio()
            failure = "Recording could not start. Check microphone access in Settings and try again."
        }
    }
    func attachEditor(_ editor: any DictationEditor, conversationID: String) {
        guard nativeConversationID == nil || (editorConversationID == conversationID && self.editor === editor) else { return }
        self.editor = editor; editorConversationID = conversationID
    }
    func cancelNativeForExternalEdit() {
        guard nativeConversationID != nil else { return }
        discardNative(); stopCapture(); clear()
        failure = "Dictation stopped because the draft changed. Your current draft is kept."
    }
    private func startNative(chat: ChatSummary, scope: String, generation: Int) async -> Bool {
        guard editorConversationID == chat.id, let editor,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: editor.dictationLocale)),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return false }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard let model, model.assignmentScope == scope, captureGeneration == generation,
              !model.accessEnded, !Task.isCancelled else { return true }
        speechDenied = authorization != .authorized
        guard authorization == .authorized else {
            failure = "Live words need Speech Recognition access in Settings. Your Mac can still transcribe recordings."
            return false
        }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard model.assignmentScope == scope, captureGeneration == generation,
              !model.accessEnded, !Task.isCancelled, UIApplication.shared.applicationState == .active else { return true }
        microphoneDenied = !granted
        guard granted else { failure = "Allow microphone access in Settings to dictate."; return true }
        guard editorConversationID == chat.id, self.editor === editor,
              let saved = model.connection, let url = audioURL, editor.beginDictation() else { return false }
        do {
            var directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try directory.setResourceValues(values)
            let pending = DictationIntent(hostID: saved.credential.hostInstallationId, deviceID: saved.credential.deviceId,
                conversationID: chat.id, conversationTitle: chat.title, modelID: "native")
            try model.persistDictationIntent(pending)
            intent = pending
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
            try AVAudioSession.sharedInstance().setActive(true); audioSessionActive = true
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.addsPunctuation = true
            nativeRecognizer = recognizer
            nativeRequest = request; nativeWords = ""; nativeFailed = false; nativeRecordingFailed = false
            nativeConversationID = chat.id
            let capture = try NativeSpeechCapture(url: url, request: request)
            nativeCapture = capture
            nativeTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let words = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in
                    self?.receiveNative(words: words, final: final, failed: failed, pending: pending)
                }
            }
            try capture.start()
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            nativeStartedAt = Date(); elapsed = 0; maximum = 60
            startTimer(); observeInterruptions()
            return true
        } catch {
            discardNative(); stopCapture()
            clear()
            return false
        }
    }
    private func receiveNative(words: String?, final: Bool, failed: Bool, pending: DictationIntent) {
        guard matches(pending), nativeConversationID == pending.conversationID else { return }
        if let words, !words.isEmpty {
            guard editor?.showDictation(words) == true else {
                finishNativeImmediately()
                failure = "Dictation stopped. The draft could not accept more text."
                return
            }
            nativeWords = words
        }
        if failed, nativeWords.isEmpty, nativeCapture != nil, recording {
            // Asset initialization can fail despite capability flags. Continue
            // recording the same audio for the Mac rather than losing the start.
            nativeConversationID = nil
            nativeCapture?.stopRecognition()
            nativeTask?.cancel(); nativeTask = nil; nativeRequest = nil; nativeRecognizer = nil
            _ = editor?.endDictation(commitWords: false)
            failure = "Live words are unavailable. Finish recording to transcribe on your Mac."
        } else if failed { nativeFailed = true; finishNativeImmediately() }
        else if final { finishNativeImmediately() }
    }
    #if WONDER_DIAGNOSTICS
    /// Drives the real editor/session lifecycle without microphone or network.
    @discardableResult func beginNativeFixture(chat: ChatSummary) -> DictationIntent? {
        guard intent == nil, editorConversationID == chat.id, let saved = model?.connection,
              editor?.beginDictation() == true else { return nil }
        let pending = DictationIntent(hostID: saved.credential.hostInstallationId, deviceID: saved.credential.deviceId,
            conversationID: chat.id, conversationTitle: chat.title, modelID: "native")
        intent = pending; nativeConversationID = chat.id; nativeWords = ""; nativeFailed = false
        observeInterruptions()
        return pending
    }
    func receiveNativeFixture(_ words: String, pending: DictationIntent, final: Bool = false, failed: Bool = false) {
        receiveNative(words: words, final: final, failed: failed, pending: pending)
    }
    #endif
    private func finishNative() {
        guard nativeConversationID != nil, finalization == nil else { return }
        stopNativeAudio()
        intent?.phase = "processing"
        nativeRequest?.endAudio()
        let id = intent?.requestID
        finalization = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.intent?.requestID == id else { return }
            self.finishNativeImmediately()
        }
    }
    func finishNativeImmediately() {
        guard nativeConversationID != nil else { return }
        // Retire callback ownership before cancelling the recognizer.
        let hasWords = !nativeWords.isEmpty
        let failed = nativeFailed
        nativeConversationID = nil
        finalization?.cancel(); finalization = nil
        nativeTask?.cancel(); nativeTask = nil; nativeRequest = nil; nativeRecognizer = nil
        stopCapture()
        if hasWords {
            guard editor?.endDictation(commitWords: true) == true else {
                // The editor retains the projection until its binding accepts it.
                nativeConversationID = intent?.conversationID
                intent?.phase = "recording"
                failure = "Dictation stopped. Finish to save the words, or cancel to keep the original draft."
                return
            }
            clear()
            if failed { failure = "On-device dictation stopped. The words shown were kept in your draft." }
        } else {
            _ = editor?.endDictation(commitWords: false)
            // The exact captured audio remains recoverable through the existing
            // paired-Mac path, including when local speech assets failed to load.
            finishRecordedNativeForMac()
        }
    }
    private func finishRecordedNativeForMac() {
        guard var pending = intent, let url = audioURL else { return }
        do {
            guard !nativeRecordingFailed else { throw DictationFailure(errorCategory: "no_audio") }
            let audio = try AVAudioFile(forReading: url)
            let duration = UInt64(max(0, Double(audio.length) / audio.processingFormat.sampleRate * 1000))
            pending.finishCapture(durationMs: try DictationIntent.captureDuration(milliseconds: duration, maximumMs: 60_000))
            intent = pending; persist()
            failure = "Live words are unavailable for this language or device. Retry to transcribe the recording on your Mac."
        } catch {
            clear(); failure = "No speech was captured. Try again, or use dictation on your Mac."
        }
    }
    private func discardNative() {
        nativeConversationID = nil
        finalization?.cancel(); finalization = nil
        nativeTask?.cancel(); nativeTask = nil; nativeRequest = nil; nativeRecognizer = nil
        _ = editor?.endDictation(commitWords: false)
        nativeWords = ""
    }
    #if DEBUG && targetEnvironment(simulator)
    var fixtureMode: Bool { ProcessInfo.processInfo.arguments.contains("-dictation-fixtures") }
    func transcribeFixture(seconds: Int, chat: ChatSummary) async {
        guard fixtureMode, [180, 300, 600].contains(seconds), let model, !model.previewMode,
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
            let duration = try DictationIntent.captureDuration(milliseconds: milliseconds, maximumMs: catalog.maxRecordingDurationMs)
            var directory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try directory.setResourceValues(values)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: source, to: destination)
            var pending = DictationIntent(hostID: saved.credential.hostInstallationId, deviceID: saved.credential.deviceId,
                conversationID: chat.id, conversationTitle: chat.title, modelID: modelID)
            pending.finishCapture(durationMs: duration)
            try model.persistDictationIntent(pending); intent = pending; busy = false; startTimer(); upload()
        } catch { busy = false; failure = readable(error); removeAudio() }
    }
    #endif

    func finishCapture(submit: Bool = true) {
        if nativeConversationID != nil {
            if submit { finishNative() } else { finishNativeImmediately() }
            return
        }
        guard recording, var pending = intent, let url = audioURL else { return }
        stopCapture()
        do {
            guard !nativeRecordingFailed else { throw DictationFailure(errorCategory: "no_audio") }
            let audio = try AVAudioFile(forReading: url)
            let milliseconds = UInt64(max(0, Double(audio.length) / audio.processingFormat.sampleRate * 1000))
            let duration = try DictationIntent.captureDuration(milliseconds: milliseconds, maximumMs: UInt64(maximum * 1000))
            pending.finishCapture(durationMs: duration); intent = pending
        } catch {
            intent?.phase = "failed"; intent?.cancelled = true; failure = readable(error); persist(); removeAudio()
            return
        }
        do { try model?.persistDictationIntent(pending) }
        catch {
            // Keep a valid clip recoverable in this session if its metadata cannot
            // be saved. Retry must save the intent before beginning an upload.
            failure = "This recording could not be saved. Free some space, then retry."
            return
        }
        if submit { if pending.modelID == "native" { retry() } else { upload() } }
        else { failure = "Recording interrupted. Retry to transcribe it, or cancel." }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recording, self.recorder === recorder else { return }
            if flag { self.finishCapture() }
            else { self.finishCapture(submit: false) }
        }
    }
    private func observeInterruptions() {
        routeChanges?.cancel()
        routeChanges = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                guard !Task.isCancelled else { return }
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ||
                      reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue else { continue }
                if self?.nativeConversationID != nil { self?.finishNativeImmediately() }
                else if self?.recording == true { self?.finishCapture(submit: false) }
            }
        }
        interruptions?.cancel()
        interruptions = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                guard !Task.isCancelled else { return }
                if self?.nativeConversationID != nil { self?.finishNativeImmediately() }
                else if self?.recording == true { self?.finishCapture(submit: false) }
            }
        }
    }
    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.intent != nil else { return }
                if self.recording, let started = self.nativeStartedAt {
                    self.elapsed = Date().timeIntervalSince(started)
                    if self.elapsed >= 55 { self.finishCapture() }
                } else if self.recording, let recorder = self.recorder {
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
        do { try model.persistDictationIntent(pending) }
        catch { failure = "This recording could not be saved. Free some space, then retry."; return }
        busy = true; intent?.phase = "uploading"; failure = nil; persist()
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.intent?.requestID == pending.requestID { self.busy = false } }
            do {
                let bytes = try await DictationAudioReader.shared.read(url)
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
        if let pending = intent, pending.modelID == "native" {
            guard !busy else { return }
            busy = true
            work = Task { [weak self] in
                guard let self else { return }
                let result = await self.loadModels()
                guard self.matches(pending), !Task.isCancelled else { return }
                self.busy = false
                guard case .success(let catalog) = result, catalog.ready,
                      catalog.languages.contains("auto"), let modelID = catalog.selectedModelId else {
                    self.failure = "Set up dictation on your Mac, then retry this recording."; return
                }
                self.intent?.modelID = modelID
                self.retry()
            }
            return
        }
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
            guard let model else { return }
            try model.insertDictation(job: job, intent: current)
            clear()
        case "cancelled": removeAudio(); clear()
        case "failed": failure = DictationFailure(errorCategory: job.errorCategory ?? "transcription").message
        default: break
        }
    }
    func cancel() {
        if nativeConversationID != nil {
            discardNative(); stopCapture(); clear(); return
        }
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
        removeAudio(); timer?.cancel(); interruptions?.cancel(); routeChanges?.cancel(); audioLevels = []
        do { try model?.clearDictationIntent(); intent = nil; busy = false; requiresResume = false; failure = nil }
        catch { failure = "The saved recording could not be cleared. Try again." }
    }
    func forget() { work?.cancel(); discardNative(); stopCapture(); clear() }
    private func stopNativeAudio() {
        if let capture = nativeCapture {
            capture.stop()
            nativeRecordingFailed = capture.recordingFailed
        }
        nativeCapture = nil; nativeStartedAt = nil
    }
    private func stopCapture() {
        stopNativeAudio()
        recorder?.delegate = nil; recorder?.stop(); recorder = nil
        interruptions?.cancel(); interruptions = nil
        routeChanges?.cancel(); routeChanges = nil
        // Stopping the recorder alone does not release the app's audio session.
        // Revocation and connection replacement must release it just like Finish.
        // Restoring an idle controller must not activate the audio service at launch.
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
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

private actor DictationAudioReader {
    static let shared = DictationAudioReader()
    func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
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
        VStack(spacing: 0) {
            content()
                .opacity(active && controller.nativeConversationID == nil ? 0 : 1)
                .disabled(active && controller.nativeConversationID == nil)
                .allowsHitTesting(!active || controller.nativeConversationID != nil)
                .accessibilityHidden(active && controller.nativeConversationID == nil)
                .frame(height: active && controller.nativeConversationID == nil ? max(52, overlayHeight) : nil)
                .clipped()
            if active { DictationComposerOverlay(controller: controller) }
        }
        .onChange(of: active && controller.nativeConversationID == nil) { _, hidden in
            if hidden { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
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
                    Button("Test 10-minute audio") { Task { await controller.transcribeFixture(seconds: 600, chat: chat) } }
                }.font(.caption).disabled(controller.busy)
            }
            #endif
            if let failure = controller.failure { FailureDetails("Dictation unavailable", message: failure) }
            if controller.microphoneDenied || controller.speechDenied { Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.font(.caption) }
        }
        .task(id: model.assignmentScope) { controller.restore() }
    }
}

struct DictationButton: View {
    @ObservedObject var controller: DictationController
    let chat: ChatSummary
    let unavailable: Bool
    var prepare: () -> Bool = { true }
    var body: some View {
        Button {
            guard prepare() else { return }
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
                LabeledContent("Mac dictation", value: controller.models?.ready == true ? "Ready" : "Unavailable")
                if let name = controller.selectedModelName { LabeledContent("Model", value: name) }
                LabeledContent("Live language", value: "Keyboard language")
                Text("Live words use on-device speech when available. Otherwise your recording is transcribed on your Mac, with automatic language detection.").font(.footnote)
                Button("Refresh") { Task { await controller.loadModels() } }
            } footer: { Text("Models are managed on your Mac.") }
            if let failure = controller.modelsFailure { FailureDetails(message: failure) }
        }.navigationTitle("Voice & Dictation")
            .task(id: model.assignmentScope) { await controller.loadModels() }
    }
}

/// Audio rendering never calls the main actor. The file and recognition request
/// are owned by this capture and released only after removing the engine tap.
private final class NativeSpeechCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var file: AVAudioFile?
    private var tapped = false
    private let fileLock = NSLock()
    private var failed = false
    var recordingFailed: Bool { fileLock.lock(); defer { fileLock.unlock() }; return failed }
    init(url: URL, request: SFSpeechAudioBufferRecognitionRequest) throws {
        self.request = request
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationFailure(errorCategory: "no_audio") }
        file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 64_000],
            commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.fileLock.lock()
            self.request?.append(buffer)
            do { try self.file?.write(from: buffer) } catch { self.failed = true }
            self.fileLock.unlock()
        }
        tapped = true
    }
    func start() throws { engine.prepare(); try engine.start() }
    func stopRecognition() { fileLock.lock(); request = nil; fileLock.unlock() }
    func stop() {
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        fileLock.lock(); file = nil; fileLock.unlock()
    }
    deinit { stop() }
}
