import XCTest
@testable import WonderPairing

final class DictationTests: XCTestCase {
    func testFinalPhrasesAccumulateAndVolatilePhrasesReplaceWithoutDuplicates() {
        var transcript = DictationTranscript()
        for (words, start, end, final, expected) in [
            ("A blue", 0.0, 1.0, false, "A blue"),
            ("A green card.", 0, 2, true, "A green card."),
            (" A new", 2, 3, false, "A green card. A new"),
            (" Another phrase.", 2, 4, true, "A green card. Another phrase."),
            (" Another phrase.", 2, 4, true, "A green card. Another phrase."),
            ("stale", 0, 1, false, "A green card. Another phrase."),
            (" 最後", 4, 5, false, "A green card. Another phrase. 最後"),
            (" 最後。", 4, 6, true, "A green card. Another phrase. 最後。")
        ] {
            transcript.update(words, start: start, end: end, isFinal: final)
            XCTAssertEqual(transcript.text, expected)
        }
    }

    func testProgressiveRevisionsReplaceOnlySelectedSpanWithoutChangingBase() {
        var projection = DictationProjection(base: "Hello old friend 👋", selection: NSRange(location: 6, length: 3))
        XCTAssertTrue(projection.update("blue"))
        XCTAssertEqual(projection.text, "Hello blue friend 👋")
        XCTAssertTrue(projection.update("green card"))
        XCTAssertEqual(projection.text, "Hello green card friend 👋")
        XCTAssertEqual(projection.base, "Hello old friend 👋")
        XCTAssertTrue(projection.update(""))
        XCTAssertEqual(projection.text, projection.base)
    }
    func testProgressiveUnicodeCursorMappingAndLimitKeepLastAcceptedWords() {
        var projection = DictationProjection(base: "👋 tail", selection: NSRange(location: 3, length: 0))
        let original = projection
        XCTAssertTrue(projection.update("こんにちは"))
        XCTAssertEqual(projection.text, "👋 こんにちは tail")
        XCTAssertEqual(projection.selection(afterReplacing: original, selection: NSRange(location: 7, length: 0)),
                       NSRange(location: 13, length: 0))
        let accepted = projection.text
        XCTAssertFalse(projection.update(String(repeating: "x", count: 65537)))
        XCTAssertEqual(projection.text, accepted)
    }

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
        XCTAssertTrue(restored.canRetryAudio(now: now.addingTimeInterval(599)))
        XCTAssertFalse(restored.canRetryAudio(now: now.addingTimeInterval(600)))
        restored.jobID = "known"; restored.phase = "processing"
        restored.pauseInterruptedUpload()
        XCTAssertEqual(restored.phase, "processing")
    }
    func testThreeFiveAndTenMinuteRecordingsKeepBoundedRetryAndOriginalMetadata() throws {
        for duration: UInt64 in [180_000, 300_000, 600_000] {
            var intent = DictationIntent(hostID: "mac", deviceID: "phone", conversationID: "first", conversationTitle: "Ada", modelID: "parakeet")
            let now = Date(timeIntervalSince1970: 100)
            intent.finishCapture(durationMs: duration, now: now)
            let restored = try JSONDecoder().decode(DictationIntent.self, from: JSONEncoder().encode(intent))
            XCTAssertEqual(restored.requestID, intent.requestID)
            XCTAssertEqual(restored.durationMs, duration)
            XCTAssertEqual(restored.conversationID, "first")
            XCTAssertTrue(restored.canRetryAudio(now: now.addingTimeInterval(599)))
            XCTAssertFalse(restored.canRetryAudio(now: now.addingTimeInterval(600)))
        }
    }
    func testCaptureAllowsOnlyBoundedEncoderPaddingAtNegotiatedLimit() throws {
        XCTAssertEqual(try DictationIntent.captureDuration(milliseconds: 600_023, maximumMs: 600_000), 600_000)
        XCTAssertEqual(try DictationIntent.captureDuration(milliseconds: 300_023, maximumMs: 300_000), 300_000)
        XCTAssertEqual(try DictationIntent.captureDuration(milliseconds: 1234, maximumMs: 600_000), 1234)
        XCTAssertThrowsError(try DictationIntent.captureDuration(milliseconds: 600_251, maximumMs: 600_000))
        XCTAssertThrowsError(try DictationIntent.captureDuration(milliseconds: 600_000, maximumMs: 300_000))
        XCTAssertThrowsError(try DictationIntent.captureDuration(milliseconds: 249, maximumMs: 600_000))
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
