import CryptoKit
import XCTest
@testable import WonderNativeRelay

final class RelayInteropTests: XCTestCase {
    func testPinnedStaticKeysAndContextRoundTrip() throws {
        let host = Curve25519.KeyAgreement.PrivateKey()
        let device = Curve25519.KeyAgreement.PrivateKey()
        let context = try RelayContext(hostIdentity: "host-a", deviceIdentity: "device-b", routingIdentity: "route-c")
        let (initiator, first) = try RelayInitiator.start(localPrivateKey: device.rawRepresentation, peerPublicKey: host.publicKey.rawRepresentation, context: context)
        let (second, responder) = try RelayResponder.accept(localPrivateKey: host.rawRepresentation, peerPublicKey: device.publicKey.rawRepresentation, context: context, message: first)
        let initiatorSession = try initiator.finish(second)

        let payload = Data("native relay interoperability".utf8)
        XCTAssertEqual(try responder.openFrame(try initiatorSession.sealFrame(payload)), payload)
        XCTAssertEqual(try initiatorSession.openFrame(try responder.sealFrame(payload)), payload)
    }

    func testContextMismatchFailsClosed() throws {
        let host = Curve25519.KeyAgreement.PrivateKey()
        let device = Curve25519.KeyAgreement.PrivateKey()
        let initiatorContext = try RelayContext(hostIdentity: "host-a", deviceIdentity: "device-b", routingIdentity: "route-a")
        let responderContext = try RelayContext(hostIdentity: "host-a", deviceIdentity: "device-b", routingIdentity: "route-b")
        let (_, first) = try RelayInitiator.start(localPrivateKey: device.rawRepresentation, peerPublicKey: host.publicKey.rawRepresentation, context: initiatorContext)
        XCTAssertThrowsError(try RelayResponder.accept(localPrivateKey: host.rawRepresentation, peerPublicKey: device.publicKey.rawRepresentation, context: responderContext, message: first))
    }

    func testOversizedOpenPoisonsSession() throws {
        let host = Curve25519.KeyAgreement.PrivateKey()
        let device = Curve25519.KeyAgreement.PrivateKey()
        let context = try RelayContext(hostIdentity: "host-a", deviceIdentity: "device-b", routingIdentity: "route-c")
        let (initiator, first) = try RelayInitiator.start(localPrivateKey: device.rawRepresentation, peerPublicKey: host.publicKey.rawRepresentation, context: context)
        let (second, responder) = try RelayResponder.accept(localPrivateKey: host.rawRepresentation, peerPublicKey: device.publicKey.rawRepresentation, context: context, message: first)
        let initiatorSession = try initiator.finish(second)
        let validFrame = try initiatorSession.sealFrame(Data("valid".utf8))

        XCTAssertThrowsError(try responder.openFrame(Data(repeating: 0, count: 65536))) { error in
            XCTAssertEqual(error as? RelayError, .messageTooLarge)
        }
        XCTAssertThrowsError(try responder.openFrame(validFrame)) { error in
            XCTAssertEqual(error as? RelayError, .invalidState)
        }
    }
}
