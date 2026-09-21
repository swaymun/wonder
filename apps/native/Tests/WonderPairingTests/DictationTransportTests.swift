import XCTest
@testable import WonderPairing

private final class DictationProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var uploads: [(String, String, Data)] = []
        var accepted: Set<String> = []
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "dictation.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        if request.httpMethod == "DELETE" {
            XCTAssertTrue(request.url!.path.contains("/by-request/"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "__Host-wonder_session=synthetic")
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/mp4")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "__Host-wonder_session=synthetic")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-wonder-csrf"), "synthetic-csrf")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Wonder-Model-ID"), "parakeet")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Wonder-Language"), "auto")
        let id = request.value(forHTTPHeaderField: "X-Wonder-Request-ID") ?? ""
        let duration = request.value(forHTTPHeaderField: "X-Wonder-Duration-Ms") ?? ""
        let first = Self.state.lock.withLock {
            Self.state.uploads.append((id, duration, bytes)); return Self.state.accepted.insert(id).inserted
        }
        if first { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        let response = #"{"id":"job","state":"completed","sourceDeviceId":"phone","durationMs":299995,"modelId":"parakeet","language":"auto","processingSource":"paired_mac","transcriptText":"Spoken result."}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DictationTransportTests: XCTestCase {
    func testCancellationCanAcknowledgeStableRequestBeforeJobIDIsKnown() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DictationProtocol.self]
        let api = PairingAPI(configuration: config)
        let connection = SavedConnection(origin: "https://dictation.invalid", credential: Credential(sessionToken: "synthetic", deviceId: "phone", csrfToken: "synthetic-csrf", hostInstallationId: "mac", expiresAtMs: nil))
        var pending = DictationIntent(hostID: "mac", deviceID: "phone", conversationID: "original", conversationTitle: "Ada", modelID: "parakeet")
        pending.finishCapture(durationMs: 180_000)
        pending.cancelled = true
        pending = try JSONDecoder().decode(DictationIntent.self, from: JSONEncoder().encode(pending))
        XCTAssertNil(pending.jobID)
        XCTAssertFalse(pending.canRetryAudio())
        struct Empty: Decodable, Sendable {}
        let _: Empty = try await api.asrRequest("/api/v1/asr/transcriptions/by-request/" + pending.requestID, connection: connection, method: "DELETE")
    }
    func testLostUploadReplyUsesIdenticalAudioAndMetadataThenAppendsOriginalDraftOnce() async throws {
        DictationProtocol.state.lock.withLock { DictationProtocol.state.uploads = []; DictationProtocol.state.accepted = [] }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DictationProtocol.self]
        let api = PairingAPI(configuration: config)
        let connection = SavedConnection(origin: "https://dictation.invalid", credential: Credential(sessionToken: "synthetic", deviceId: "phone", csrfToken: "synthetic-csrf", hostInstallationId: "mac", expiresAtMs: nil))
        var pending = DictationIntent(hostID: "mac", deviceID: "phone", conversationID: "original", conversationTitle: "Ada", modelID: "parakeet")
        pending.finishCapture(durationMs: 300_000)
        let audio = Data("synthetic-mp4-transport-bytes".utf8)
        do {
            let _: TranscriptionJob = try await api.asrRequest("/api/v1/asr/transcriptions", connection: connection, method: "POST", recording: audio, intent: pending)
            XCTFail("First response should be lost")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        let restarted = try JSONDecoder().decode(DictationIntent.self, from: JSONEncoder().encode(pending))
        let result: TranscriptionJob = try await api.asrRequest("/api/v1/asr/transcriptions", connection: connection, method: "POST", recording: audio, intent: restarted)
        XCTAssertTrue(restarted.accepts(result))
        XCTAssertEqual(restarted.durationMs, 300_000)
        XCTAssertEqual(result.durationMs, 299_995)
        var drafts = ["original":ComposerIntent(), "visible":ComposerIntent()]
        drafts["original"]?.draft = "Typed meanwhile."
        drafts["visible"]?.draft = "Another chat."
        try drafts[restarted.conversationID]?.appendDictation(result.transcriptText!, requestID: restarted.requestID)
        try drafts[restarted.conversationID]?.appendDictation(result.transcriptText!, requestID: restarted.requestID)
        XCTAssertEqual(drafts["original"]?.draft, "Typed meanwhile. Spoken result.")
        XCTAssertEqual(drafts["visible"]?.draft, "Another chat.")
        XCTAssertNil(drafts["original"]?.pending)
        let records = DictationProtocol.state.lock.withLock { (DictationProtocol.state.uploads, DictationProtocol.state.accepted.count) }
        XCTAssertEqual(records.1, 1)
        XCTAssertEqual(records.0.count, 2)
        XCTAssertEqual(records.0[0].0, records.0[1].0)
        XCTAssertEqual(records.0[0].1, records.0[1].1)
        XCTAssertEqual(records.0[0].2, records.0[1].2)
    }
}
