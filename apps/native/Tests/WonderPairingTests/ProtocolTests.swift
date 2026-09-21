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
        XCTAssertEqual(session.state, .unavailable)
    }

    func testTeachingUnavailableAndPrivateSkillFixturesDecodeWithoutReplayClaim() throws {
        let sessionData = Data(#"{"id":"session","clientRequestId":"request","ownerDeviceId":"phone","hostInstallationId":"mac","botId":"bot","conversationId":"chat","state":"unavailable","captureScope":"foreground-window","captureProvider":"none","outcome":"Create a preview","name":null,"description":null,"goal":null,"inputSchema":null,"prerequisites":null,"steps":null,"resultChecks":null,"failureReason":"Capture unavailable","revision":1,"eventCount":0,"evidenceBytes":0,"contentHash":null,"createdAt":"now","updatedAt":"now","startedAt":null,"endedAt":"now","expiresAt":"later","capability":{"available":false,"action":"update-host","reason":"Capture unavailable","provider":"none","maxDurationSeconds":600,"maxEvents":20000,"maxEvidenceBytes":52428800}}"#.utf8)
        let session = try JSONDecoder().decode(TeachingSession.self, from: sessionData)
        XCTAssertEqual(session.state, "unavailable")
        XCTAssertFalse(session.capability.available)
        XCTAssertEqual(session.eventCount, 0)

        let skillData = Data(#"{"id":"skill","botId":"bot","slug":"preview-file","name":"Preview file","description":"Create a preview","state":"active","activeVersion":1,"discoverability":"bot-private","versions":[{"id":"version","version":1,"sourceSessionId":"session","contentHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","inputSchema":{"title":{"type":"string"}},"verificationState":"structurallyVerified","createdAt":"now"}]}"#.utf8)
        let skill = try JSONDecoder().decode(BotSkill.self, from: skillData)
        XCTAssertEqual(skill.discoverability, "bot-private")
        XCTAssertEqual(skill.versions?.first?.verificationState, "structurallyVerified")
        XCTAssertNotEqual(skill.versions?.first?.verificationState, "replayVerified")
    }

    func testAuthenticatedTeachingBindingAndRedactedEventFixtureRoundTrip() throws {
        let request = StartTeachingSessionRequest(
            clientRequestId: "request",
            conversationId: "chat",
            computerSessionId: "computer-session",
            controlLeaseId: "control-lease",
            captureScope: "authenticated-remote-control",
            outcome: "Open the preview"
        )
        let requestObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)
        ) as! [String: Any]
        XCTAssertEqual(requestObject["computerSessionId"] as? String, "computer-session")
        XCTAssertEqual(requestObject["controlLeaseId"] as? String, "control-lease")

        let fixture = Data(#"{"id":"session","clientRequestId":"request","ownerDeviceId":"phone","hostInstallationId":"mac","botId":"bot","conversationId":"chat","computerSessionId":"computer-session","controlLeaseId":"control-lease","state":"reviewing","captureScope":"authenticated-remote-control","captureProvider":"authenticated-remote-control-v1","outcome":"Open the preview","name":null,"description":null,"goal":null,"inputSchema":null,"prerequisites":null,"steps":null,"resultChecks":null,"failureReason":null,"revision":2,"eventCount":1,"evidenceBytes":54,"contentHash":null,"createdAt":"now","updatedAt":"later","startedAt":"now","endedAt":"later","expiresAt":"later","events":[{"sequence":4,"actionIndex":0,"kind":"text","payload":{"characterCount":11,"redacted":true},"createdAt":"later"}],"capability":{"available":true,"action":"none","reason":"Capture available","provider":"authenticated-remote-control-v1","maxDurationSeconds":600,"maxEvents":20000,"maxEvidenceBytes":52428800}}"#.utf8)
        let session = try JSONDecoder().decode(TeachingSession.self, from: fixture)
        XCTAssertEqual(session.computerSessionId, "computer-session")
        XCTAssertEqual(session.controlLeaseId, "control-lease")
        XCTAssertEqual(session.events.count, 1)
        XCTAssertEqual(session.events[0].kind, "text")
        XCTAssertEqual(session.events[0].payload["redacted"], .bool(true))
        XCTAssertEqual(session.events[0].payload["characterCount"], .number(11))
        XCTAssertNil(session.events[0].payload["text"])
    }

    func testFixtureReceiptIsDistinctFromSupervisedReplay() throws {
        let data = Data(#"{"id":"run","clientRequestId":"11111111-1111-4111-8111-111111111111","ownerDeviceId":"phone","botId":"bot","skillId":"skill","version":2,"contentHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","inputSchemaHash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","inputSchema":{"date":{"format":"date","type":"string"},"title":{"type":"string"}},"inputs":{"date":"2026-09-12","title":"Changed"},"workingDirectory":"fixtures/changed-cwd","provider":"deterministic-local","executionKind":"deterministicFixture","status":"succeeded","verificationState":"fixtureVerified","artifactPath":".wonder/fixture-runs/bot/run/preview.json","artifactHash":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","artifactBytes":256,"evidence":{"kind":"deterministicFixture","verified":true,"checks":["title","date","artifact contents"]},"failureReason":null,"createdAt":"now","completedAt":"later"}"#.utf8)
        let receipt = try JSONDecoder().decode(BotSkillFixtureTestReceipt.self, from: data)
        XCTAssertEqual(receipt.executionKind, "deterministicFixture")
        XCTAssertEqual(receipt.verificationState, "fixtureVerified")
        XCTAssertEqual(receipt.inputs["title"], .string("Changed"))
        XCTAssertNotEqual(receipt.verificationState, "replayVerified")
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
