import XCTest
@testable import WonderNativeRelay

final class RelayFramingTests: XCTestCase {
    func testHandshakeUsesOneBigEndianLengthPrefix() throws {
        let message = Data([1, 2, 3])
        let framed = try RelayHandshakeFraming.encode(message)
        XCTAssertEqual(framed, Data([0, 0, 0, 3, 1, 2, 3]))
        XCTAssertEqual(try RelayHandshakeFraming.decode(framed), message)
        XCTAssertEqual(try RelayHandshakeFraming.decode(Data([0, 0, 0, 3, 1, 2, 3])), message)
    }

    func testHandshakeRejectsTrailingOrOversizedData() throws {
        XCTAssertThrowsError(try RelayHandshakeFraming.decode(Data([0, 0, 0, 1, 9, 8])))
        XCTAssertThrowsError(try RelayHandshakeFraming.encode(Data(repeating: 0, count: 1025)))
    }

    func testRequestAndResponseRoundTrip() throws {
        let request = try RelayRequest(requestId: "request-1", method: "GET", path: "/api/v1/events", sessionToken: "session", csrfToken: "csrf")
        let decodedRequest = try RelayJSONCodec.decode(RelayRequest.self, from: RelayJSONCodec.encode(request))
        XCTAssertEqual(decodedRequest, request)
        let response = try RelayResponse(requestId: "request-1", status: 200, body: "{}")
        let decodedResponse = try RelayJSONCodec.decode(RelayResponse.self, from: RelayJSONCodec.encode(response))
        XCTAssertEqual(decodedResponse, response)
    }
}
