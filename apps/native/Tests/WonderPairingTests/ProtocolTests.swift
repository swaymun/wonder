import XCTest
@testable import WonderPairing

private final class ComputerControlResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "computer-control-test.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Data(#"{"granted":false,"acknowledged":true,"status":"rejected","reason":"Control was not allowed.","lease":null,"control":{"available":true,"action":"none","reason":"Control is available.","heartbeatIntervalSeconds":3,"leaseExpirySeconds":10}}"#.utf8)
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!,
                statusCode: 409,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ProtocolTests: XCTestCase {
    func testComputerSignalingFixturesRoundTripAndKeepIceServerShape() throws {
        let binding = ComputerSignalingBinding(
            generation: 7,
            conversationId: "conversation",
            hostInstallationId: "host",
            peerRevision: "peer-1"
        )
        let encoder = JSONEncoder()
        let poll = try JSONSerialization.jsonObject(
            with: encoder.encode(ComputerSignalingPollRequest(binding: binding, cursor: 4))
        ) as! [String: Any]
        XCTAssertEqual(poll["generation"] as? Int, 7)
        XCTAssertEqual(poll["cursor"] as? Int, 4)
        XCTAssertEqual(poll["conversationId"] as? String, "conversation")
        XCTAssertEqual(poll["peerRevision"] as? String, "peer-1")

        let candidate = try XCTUnwrap(ComputerSignalingCandidateRequest(
            binding: binding,
            sequence: 3,
            candidate: "candidate:1 1 udp 1 192.0.2.1 9 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0,
            usernameFragment: "ufrag"
        ))
        let candidateData = try encoder.encode(candidate)
        let decodedCandidate = try JSONDecoder().decode(
            ComputerSignalingCandidateRequestFixture.self,
            from: candidateData
        )
        XCTAssertEqual(decodedCandidate.sequence, 3)
        XCTAssertEqual(decodedCandidate.sdpMLineIndex, 0)
        XCTAssertEqual(decodedCandidate.usernameFragment, "ufrag")
        XCTAssertEqual(decodedCandidate.peerRevision, "peer-1")
        let unbound = ComputerSignalingBinding(
            generation: 7,
            conversationId: "conversation",
            hostInstallationId: "host"
        )
        XCTAssertNil(ComputerSignalingAnswerRequest(binding: unbound, sdp: "v=0\na=x"))
        XCTAssertNil(ComputerSignalingCloseRequest(binding: unbound))

        let responseData = Data(#"{"sessionId":"session","generation":7,"peerRevision":"peer-1","state":"offerReady","captureState":"ready","peerState":"new","offer":{"type":"offer","sdp":"v=0\na=group:BUNDLE 0"},"candidates":[{"sequence":1,"candidate":"candidate:1","sdpMid":"0","sdpMLineIndex":0,"usernameFragment":null}],"cursor":0,"nextCursor":1,"failureReason":null,"iceServers":[]}"#.utf8)
        let response = try JSONDecoder().decode(ComputerSignalingResponse.self, from: responseData)
        XCTAssertEqual(response.sessionId, "session")
        XCTAssertEqual(response.peerRevision, "peer-1")
        XCTAssertEqual(response.nextCursor, 1)
        XCTAssertTrue(response.iceServers.isEmpty)
    }

    func testComputerControlModelsRoundTripClipboardTextAndSequencedBatch() throws {
        let actions: [ComputerInputAction] = [
            .pointer(x: 0.25, y: 0.5, phase: "down", button: "left"),
            .pointer(x: 0.25, y: 0.5, phase: "up", button: "left")
        ]
        let request = ComputerInputBatchRequest(
            leaseId: "lease",
            generation: 4,
            geometryRevision: 9,
            sourceId: "display:1",
            sequence: 12,
            actions: actions
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        XCTAssertEqual(object["leaseId"] as? String, "lease")
        XCTAssertEqual(object["generation"] as? Int, 4)
        XCTAssertEqual(object["geometryRevision"] as? Int, 9)
        XCTAssertEqual(object["sequence"] as? Int, 12)
        XCTAssertEqual((object["actions"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((object["actions"] as? [[String: Any]])?.first?["phase"] as? String, "down")

        let responseData = Data(#"{"granted":false,"acknowledged":true,"status":"active","reason":"Input accepted.","lease":{"id":"lease","sessionId":"session","ownerDeviceId":"phone","hostInstallationId":"mac","conversationId":"chat","generation":4,"sourceId":"display:1","geometryRevision":9,"status":"active","lastSequence":12,"acquiredAt":"now","updatedAt":"later","expiresAt":"later","releasedAt":null},"control":{"available":true,"action":"none","reason":"Control is active.","heartbeatIntervalSeconds":3,"leaseExpirySeconds":10},"clipboardText":"copied from Mac"}"#.utf8)
        let response = try JSONDecoder().decode(ComputerControlActionResponse.self, from: responseData)
        XCTAssertTrue(response.acknowledged)
        XCTAssertEqual(response.lease?.lastSequence, 12)
        XCTAssertEqual(response.clipboardText, "copied from Mac")

        let paste = ComputerInputBatchRequest(
            leaseId: "lease", generation: 4, geometryRevision: 9, sourceId: "display:1", sequence: 13,
            actions: [.clipboard(operation: "pasteFromPhone", text: "hello")]
        )
        let pasteObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(paste)) as! [String: Any]
        let pasteAction = try XCTUnwrap((pasteObject["actions"] as? [[String: Any]])?.first)
        XCTAssertEqual(pasteAction["operation"] as? String, "pasteFromPhone")
        XCTAssertEqual(pasteAction["text"] as? String, "hello")
    }

    func testControlConsentUsesItsFullLocalApprovalWindow() {
        XCTAssertEqual(
            PairingAPI.timeoutInterval(for: "/api/v1/computer/sessions/session/control/acquire"),
            135
        )
        XCTAssertEqual(PairingAPI.timeoutInterval(for: "/api/v1/computer/sessions/session/control/input"), 15)
    }

    func testControlRequestCanDecodeAnExplicitStructuredConflict() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ComputerControlResponseProtocol.self]
        let api = PairingAPI(configuration: configuration)
        let response: ComputerControlActionResponse = try await api.request(
            "/api/v1/computer/sessions/session/control/acquire",
            origin: "https://computer-control-test.invalid",
            decodingStatuses: [409]
        )
        XCTAssertEqual(response.status, "rejected")
        XCTAssertTrue(response.acknowledged)
        XCTAssertEqual(response.reason, "Control was not allowed.")

        do {
            let _: ComputerControlActionResponse = try await api.request(
                "/api/v1/computer/sessions/session/control/acquire",
                origin: "https://computer-control-test.invalid"
            )
            XCTFail("A conflict must not decode unless its status is explicitly allowed.")
        } catch PairingFailure.response(let status) {
            XCTAssertEqual(status, 409)
        }
    }

    private struct ComputerSignalingCandidateRequestFixture: Decodable {
        let peerRevision: String?
        let sequence: UInt64
        let sdpMLineIndex: UInt32
        let usernameFragment: String?
    }
    func testSavedConnectionNameSurvivesOfflineAndOlderConnectionsDecode() throws {
        let legacy = Data(#"{"origin":"https://mac.example","credential":{"sessionToken":"test","deviceId":"phone","csrfToken":"test","hostInstallationId":"mac"}}"#.utf8)
        let saved = try JSONDecoder().decode(SavedConnection.self, from: legacy)
        XCTAssertNil(saved.hostName)
        let named = SavedConnection(origin: saved.origin, credential: saved.credential, hostName: "Studio Mac")
        let restored = try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(named))
        XCTAssertEqual(restored.hostName, "Studio Mac")
        XCTAssertEqual(restored.credential.hostInstallationId, "mac")
    }

    func testOlderComputerSessionWithoutControlCapabilityStillDecodes() throws {
        let legacy = Data(#"{"id":"session","clientRequestId":"request","ownerDeviceId":"phone","hostInstallationId":"mac","conversationId":"chat","generation":1,"state":"unavailable","source":{"id":null,"name":null,"kind":null,"width":null,"height":null,"scale":null,"crop":null},"geometryRevision":0,"failureReason":"Unavailable","createdAt":"now","updatedAt":"now","lastStateAt":"now","endedAt":null,"capability":{"available":false,"action":"update-host","reason":"Unavailable"}}"#.utf8)
        let session = try JSONDecoder().decode(ComputerSession.self, from: legacy)
        XCTAssertNil(session.control)
        XCTAssertNil(session.videoQuality)
        XCTAssertNil(session.supportsLiveQualityChange)
        XCTAssertEqual(session.state, .unavailable)
    }

    func testComputerVideoQualityRequestAndResponseRoundTrip() throws {
        let request = StartComputerSessionRequest(
            clientRequestId: "request", conversationId: "chat", hostInstallationId: "mac",
            source: ComputerSource(id: "display:1"), videoQuality: .medium
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(body["videoQuality"] as? String, "auto")
        XCTAssertEqual(body["videoMaxHeight"] as? Int, 1_080)
        XCTAssertEqual((body["source"] as? [String: Any])?["id"] as? String, "display:1")
        let response = Data(#"{"id":"session","clientRequestId":"request","ownerDeviceId":"phone","hostInstallationId":"mac","conversationId":"chat","generation":1,"state":"live","source":{"id":null,"name":null,"kind":null,"width":null,"height":null,"scale":null,"crop":null},"geometryRevision":0,"failureReason":null,"createdAt":"now","updatedAt":"now","lastStateAt":"now","endedAt":null,"capability":{"available":true,"action":"none","reason":"Available"},"videoQuality":"medium"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ComputerSession.self, from: response).videoQuality, .medium)
        let quality = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            ComputerSessionQualityRequest(generation: 1, videoQuality: .medium)
        )) as? [String: Any])
        XCTAssertEqual(quality["videoQuality"] as? String, "auto")
        XCTAssertEqual(quality["videoMaxHeight"] as? Int, 1_080)
    }

    func testRejectsUntrustedLinks() throws {
        for value in ["http://example.com", "https://user@example.com", "https://example.com/path", "https://example.com?secret=x", "https://example.com#secret=x"] {
            XCTAssertThrowsError(try PairingLink.origin(value))
        }
        let link = try PairingLink("https://example.com/pair#secret=abc&offerId=00000000-0000-0000-0000-000000000001&hostInstallationId=mac-1")
        XCTAssertEqual(link.origin, "https://example.com")
        XCTAssertEqual(link.hostID, "mac-1")
        XCTAssertThrowsError(try PairingLink("https://example.com/pair#secret=abc&offerId=00000000-0000-0000-0000-000000000001"))
    }
    func testRustTranscriptAndHostBinding() throws {
        let data = Data(#"{"challengeId":"challenge-01","deviceId":"device-01","nonce":"nonce-01","origin":"https://wonder.example.ts.net","hostInstallationId":"install-1","offerId":"offer-1","issuedAtMs":1000,"expiresAtMs":61000}"#.utf8)
        let challenge = try JSONDecoder().decode(Challenge.self, from: data)
        XCTAssertEqual(String(decoding: challenge.transcript, as: UTF8.self), "wonder-session-v1\ndevice-01\nchallenge-01\nnonce-01\nhttps://wonder.example.ts.net\ninstall-1\n1000\n61000")
        try challenge.validate(origin: challenge.origin, hostID: "install-1", deviceID: "device-01", now: 2000)
        XCTAssertThrowsError(try challenge.validate(origin: "https://wrong.example", hostID: "install-1", deviceID: "device-01", now: 2000))
        XCTAssertThrowsError(try challenge.validate(origin: challenge.origin, hostID: "wrong-mac", deviceID: "device-01", now: 2000))
        XCTAssertThrowsError(try challenge.validate(origin: challenge.origin, hostID: "install-1", deviceID: "wrong-phone", now: 2000))
        XCTAssertThrowsError(try challenge.validate(origin: challenge.origin, hostID: "install-1", deviceID: "device-01", now: 61000))
    }
}
