import AppKit
import XCTest
@testable import WonderMenu

final class PairingMenuTests: XCTestCase {
    private func phone(expires: UInt64) -> PhoneEnrollment {
        PhoneEnrollment(deviceId: "test-phone", label: "Test iPhone",
            challenge: EnrollmentChallenge(deviceId: "test-phone", challengeId: "challenge", nonce: "nonce",
                origin: "https://test.invalid", hostInstallationId: "test-host", issuedAtMs: 0, expiresAtMs: expires))
    }

    func testRequestExpiresAtExactServerDeadline() {
        let request = phone(expires: 10_000)
        XCTAssertTrue(request.isValid(at: Date(timeIntervalSince1970: 9.999)))
        XCTAssertFalse(request.isValid(at: Date(timeIntervalSince1970: 10)))
        XCTAssertFalse(request.isValid(at: Date(timeIntervalSince1970: 11)))
    }

    @MainActor func testExpiredRequestCannotBeApproved() async {
        let model = PhonePairing()
        model.pending = [phone(expires: 1)]
        await model.decide(model.pending[0], approve: true)
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.error, "Connection request expired. Create a new pairing code.")
        XCTAssertNil(model.message)
        XCTAssertFalse(model.busy)
    }

    @MainActor func testPollingFindsRequestsWithoutOpeningAViewAndKeepsFailedDecision() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingResponse.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let model = PhonePairing(session: session)
        model.start()
        defer { model.stop() }
        for _ in 0..<50 where model.pending.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let request = try XCTUnwrap(model.pending.first)
        XCTAssertEqual(request.label, "Test iPhone")
        XCTAssertNil(model.refreshError)
        await model.decide(request, approve: true)
        XCTAssertEqual(model.pending.count, 1)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.message)
        XCTAssertFalse(model.busy)
    }


}

private final class PairingResponse: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let authorized = !(request.value(forHTTPHeaderField: "x-wonder-loopback-capability") ?? "").isEmpty
        let post = request.httpMethod == "POST"
        let status = authorized ? (post ? 503 : 200) : 401
        let body = request.url!.path.hasSuffix("pending") ? """
        [{"deviceId":"test-phone","label":"Test iPhone","challenge":{"deviceId":"test-phone","challengeId":"test","nonce":"nonce","origin":"https://test.invalid","hostInstallationId":"host","issuedAtMs":0,"expiresAtMs":9999999999999}}]
        """ : "[]"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
