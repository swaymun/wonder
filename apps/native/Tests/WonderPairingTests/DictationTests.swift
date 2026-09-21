import XCTest
@testable import WonderPairing

final class DictationTests: XCTestCase {
    func testCancellationStopsCaptureAndSuppressesReceiptEvenWhenPersistenceFails() throws {
        enum DiskFailure: Error { case full }
        var intent = DictationIntent(hostID: "mac", deviceID: "phone", conversationID: "first", conversationTitle: "Ada", modelID: "parakeet")
        var recorderRunning = true
        var published: DictationIntent?
        XCTAssertThrowsError(try intent.cancelLocally(stopCapture: { recorderRunning = false }, persist: {
            XCTAssertFalse(recorderRunning)
            published = $0
            throw DiskFailure.full
        }))
        XCTAssertFalse(recorderRunning)
        XCTAssertTrue(intent.cancelled)
        XCTAssertTrue(published?.cancelled == true)
        let late = #"{"id":"job","state":"completed","sourceDeviceId":"phone","durationMs":1000,"modelId":"parakeet","language":"auto","processingSource":"paired_mac","transcriptText":"Never append"}"#
        XCTAssertFalse(try XCTUnwrap(published).accepts(JSONDecoder().decode(TranscriptionJob.self, from: Data(late.utf8))))
    }
    func testInterruptedUnknownUploadRestoresExplicitRetryWithoutChangingIdentity() throws {
        var intent = DictationIntent(hostID: "mac", deviceID: "phone", conversationID: "first", conversationTitle: "Ada", modelID: "parakeet")
        let now = Date()
        intent.finishCapture(durationMs: 300_000, now: now); intent.phase = "uploading"
        var restored = try JSONDecoder().decode(DictationIntent.self, from: JSONEncoder().encode(intent))
        restored.pauseInterruptedUpload()
        XCTAssertEqual(restored.phase, "paused")
        XCTAssertEqual(restored.requestID, intent.requestID)
        XCTAssertEqual(restored.durationMs, 300_000)
        XCTAssertEqual(restored.audioExpiresAt, intent.audioExpiresAt)
        XCTAssertTrue(restored.canRetryAudio(now: now.addingTimeInterval(119)))
        XCTAssertFalse(restored.canRetryAudio(now: now.addingTimeInterval(120)))
        restored.jobID = "known"; restored.phase = "processing"
        restored.pauseInterruptedUpload()
        XCTAssertEqual(restored.phase, "processing")
    }
    func testThreeAndFiveMinuteRecordingsKeepBoundedRetryAndOriginalMetadata() throws {
        for duration: UInt64 in [180_000, 300_000] {
            var intent = DictationIntent(hostID: "mac", deviceID: "phone", conversationID: "first", conversationTitle: "Ada", modelID: "parakeet")
            let now = Date(timeIntervalSince1970: 100)
            intent.finishCapture(durationMs: duration, now: now)
            let restored = try JSONDecoder().decode(DictationIntent.self, from: JSONEncoder().encode(intent))
            XCTAssertEqual(restored.requestID, intent.requestID)
            XCTAssertEqual(restored.durationMs, duration)
            XCTAssertEqual(restored.conversationID, "first")
            XCTAssertTrue(restored.canRetryAudio(now: now.addingTimeInterval(119)))
            XCTAssertFalse(restored.canRetryAudio(now: now.addingTimeInterval(120)))
        }
    }
    func testAppendPreservesInterveningTypingAndIsExactlyOnceAfterRestart() throws {
        var intent = ComposerIntent(); intent.draft = "Typed while transcribing."
        XCTAssertTrue(try intent.appendDictation("Spoken text.", requestID: "recording"))
        var restored = try JSONDecoder().decode(ComposerIntent.self, from: JSONEncoder().encode(intent))
        XCTAssertFalse(try restored.appendDictation("Spoken text.", requestID: "recording"))
        XCTAssertEqual(restored.draft, "Typed while transcribing. Spoken text.")
        XCTAssertNil(restored.pending)
    }
    func testWrongDeviceModelAndCancellationCannotBeAccepted() throws {
        var intent = DictationIntent(hostID: "mac", deviceID: "phone", conversationID: "first", conversationTitle: "Ada", modelID: "parakeet")
        intent.finishCapture(durationMs: 180_000)
        let json = #"{"id":"job","state":"completed","sourceDeviceId":"other","durationMs":179995,"modelId":"parakeet","language":"auto","processingSource":"paired_mac","transcriptText":"No"}"#
        XCTAssertFalse(intent.accepts(try JSONDecoder().decode(TranscriptionJob.self, from: Data(json.utf8))))
        intent.cancelled = true
        XCTAssertFalse(intent.canRetryAudio())
    }
    func testOversizedAppendPreservesDraftAndInsertionIdentity() throws {
        var intent = ComposerIntent(); intent.draft = String(repeating: "a", count: 65536)
        XCTAssertThrowsError(try intent.appendDictation("text", requestID: "id"))
        XCTAssertNil(intent.lastDictationRequestID)
        XCTAssertEqual(intent.draft.count, 65536)
    }
}
