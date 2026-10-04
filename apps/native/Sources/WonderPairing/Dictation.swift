import Foundation

public struct DictationModels: Decodable, Sendable {
    public struct Model: Decodable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let installed: Bool
        public let supportedLanguages: [String]
        public let testedLanguages: [String]?
    }
    public let selectedModelId: String?
    public let ready: Bool
    public let maxRecordingDurationMs: UInt64
    public let languages: [String]
    public let models: [Model]
}
public struct TranscriptionJob: Codable, Sendable {
    public let id: String
    public let state: String
    public let sourceDeviceId: String
    public let durationMs: UInt64
    public let modelId: String
    public let language: String
    public let processingSource: String
    public let transcriptText: String?
    public let retryExpiresAtMs: UInt64?
    public let errorCategory: String?
}
public struct DictationFailure: Error, Decodable, Sendable {
    public let errorCategory: String
    public init(errorCategory: String) { self.errorCategory = errorCategory }
    public var message: String {
        switch errorCategory {
        case "busy": "Your Mac is transcribing another recording."
        case "rate_limited": "Your Mac is receiving too many recordings. Try again shortly."
        case "model_unavailable": "Set up dictation on your Mac."
        case "too_short", "no_audio": "No speech was recorded. Record again."
        case "interrupted": "Transcription was interrupted. Retry while the recording is available."
        case "timeout": "Transcription took too long. Retry while the recording is available."
        case "unsupported_language": "This model uses automatic language detection."
        default: "Your Mac could not transcribe this recording."
        }
    }
}

/// Metadata never changes on an upload retry, even if the daemon reports a
/// different decoded duration. Audio expires 10 minutes after capture stops.
public struct DictationIntent: Codable, Sendable {
    public let requestID: String
    public let hostID: String
    public let deviceID: String
    public let conversationID: String
    public let conversationTitle: String
    public var modelID: String
    public let language: String
    public var durationMs: UInt64 = 0
    public var audioExpiresAt: Date?
    public var jobID: String?
    public var jobState: String?
    public var retryExpiresAtMs: UInt64?
    public var cancelled = false
    public var phase = "recording"
    public init(hostID: String, deviceID: String, conversationID: String, conversationTitle: String, modelID: String) {
        requestID = UUID().uuidString.lowercased(); self.hostID = hostID; self.deviceID = deviceID
        self.conversationID = conversationID; self.conversationTitle = conversationTitle; self.modelID = modelID; language = "auto"
    }
    /// AAC can include a partial final packet. Accept at most 250 ms of padding
    /// and keep the upload metadata within the negotiated recording limit.
    public static func captureDuration(milliseconds: UInt64, maximumMs: UInt64) throws -> UInt64 {
        let limit = min(maximumMs, 600_000)
        guard milliseconds >= 250 else { throw DictationFailure(errorCategory: "too_short") }
        guard limit >= 250, milliseconds <= limit + 250 else {
            throw DictationFailure(errorCategory: "unsupported_recording_format")
        }
        return min(milliseconds, limit)
    }
    public mutating func finishCapture(durationMs: UInt64, now: Date = Date()) {
        self.durationMs = min(durationMs, 600_000); audioExpiresAt = now.addingTimeInterval(600); phase = "ready"
    }
    /// Cancellation must release microphone/transport even when the disk is full.
    /// The caller publishes this cancelled value before attempting its durable write.
    public mutating func cancelLocally(stopCapture: () -> Void, persist: (Self) throws -> Void) throws {
        cancelled = true; phase = "cancelled"
        stopCapture()
        try persist(self)
    }
    public mutating func pauseInterruptedUpload() {
        if !cancelled, jobID == nil, phase == "uploading" { phase = "paused" }
    }
    public func canRetryAudio(now: Date = Date()) -> Bool { !cancelled && audioExpiresAt.map { now < $0 } == true }
    public func accepts(_ job: TranscriptionJob) -> Bool {
        !cancelled && job.sourceDeviceId == deviceID && job.modelId == modelID && job.language == language && job.processingSource == "paired_mac" && (jobID == nil || jobID == job.id)
    }
}

/// A volatile replacement in UTF-16 coordinates, matching UITextView selection.
/// The saved draft remains `base` until the user finishes or starts editing.
public struct DictationProjection: Sendable {
    public let base: String
    public let range: NSRange
    public private(set) var transcript = ""
    public init(base: String, selection: NSRange) {
        self.base = base
        let length = (base as NSString).length
        let location = min(max(0, selection.location), length)
        range = NSRange(location: location, length: min(max(0, selection.length), length - location))
    }
    public var text: String {
        guard !transcript.isEmpty else { return base }
        return (base as NSString).replacingCharacters(in: range, with: insertion)
    }
    public var insertion: String {
        guard !transcript.isEmpty else { return "" }
        let before = (base as NSString).substring(to: range.location)
        let after = (base as NSString).substring(from: NSMaxRange(range))
        let left = before.last.map { !$0.isWhitespace } == true ? " " : ""
        let right = after.first.map { !$0.isWhitespace && !$0.isPunctuation } == true ? " " : ""
        return left + transcript + right
    }
    @discardableResult public mutating func update(_ words: String) -> Bool {
        let previous = transcript
        transcript = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 65536 else { transcript = previous; return false }
        return true
    }
    public func selection(afterReplacing previous: Self, selection: NSRange) -> NSRange {
        let oldEnd = previous.transcript.isEmpty ? NSMaxRange(range) : range.location + (previous.insertion as NSString).length
        let newEnd = transcript.isEmpty ? NSMaxRange(range) : range.location + (insertion as NSString).length
        func move(_ offset: Int) -> Int {
            if offset < range.location { return offset }
            if offset <= oldEnd { return newEnd }
            return offset + newEnd - oldEnd
        }
        let start = move(selection.location), end = move(NSMaxRange(selection))
        return NSRange(location: start, length: max(0, end - start))
    }
}

/// SpeechAnalyzer finalizes phrases, not the whole recording. Keep finalized
/// ranges once and replace only the current volatile range. None is a saved draft.
public struct DictationTranscript: Sendable {
    private var finalized = ""
    private var provisional = ""
    private var finalizedEnd = -Double.infinity
    public init() {}
    public var text: String { finalized + provisional }
    @discardableResult public mutating func update(_ words: String, start: Double, end: Double, isFinal: Bool) -> Bool {
        guard start.isFinite, end.isFinite, end > start, start >= finalizedEnd else { return false }
        // Preserve the recognizer's spacing and punctuation, including languages
        // that do not put spaces between words or phrase boundaries.
        if isFinal {
            finalized += words
            finalizedEnd = end
            provisional = ""
        } else { provisional = words }
        return true
    }
}
