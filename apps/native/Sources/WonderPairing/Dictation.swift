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
/// different decoded duration. Audio expires 120 seconds after capture stops.
public struct DictationIntent: Codable, Sendable {
    public let requestID: String
    public let hostID: String
    public let deviceID: String
    public let conversationID: String
    public let conversationTitle: String
    public let modelID: String
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
    public mutating func finishCapture(durationMs: UInt64, now: Date = Date()) {
        self.durationMs = min(durationMs, 300_000); audioExpiresAt = now.addingTimeInterval(120); phase = "ready"
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
