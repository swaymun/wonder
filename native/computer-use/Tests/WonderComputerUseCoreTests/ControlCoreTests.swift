import XCTest
@testable import WonderComputerUseCore

final class ControlCoreTests: XCTestCase {
    private func identity(
        leaseID: String = "lease",
        requestID: String = "request",
        sessionID: String = "session",
        generation: UInt64 = 1,
        geometryRevision: UInt64 = 2,
        sourceID: String? = "display:1"
    ) -> ControlLeaseIdentity {
        ControlLeaseIdentity(
            leaseID: leaseID,
            requestID: requestID,
            sessionID: sessionID,
            generation: generation,
            geometryRevision: geometryRevision,
            sourceID: sourceID
        )
    }

    func testAllowOnceIsIdempotentAndBoundToExactIdentity() {
        var prompts = 0
        let gate = ControlLeaseGate { _ in
            prompts += 1
            return .allowOnce
        }
        let first = gate.requestConsent(identity())
        let replay = gate.requestConsent(identity())
        let conflict = gate.requestConsent(identity(generation: 2))

        XCTAssertEqual(first, .allowOnce(replayed: false))
        XCTAssertEqual(replay, .allowOnce(replayed: true))
        XCTAssertEqual(conflict, .identityConflict)
        XCTAssertEqual(prompts, 1)
    }

    func testDeniedRequestIsTerminalAndNeverReprompts() {
        var prompts = 0
        let gate = ControlLeaseGate { _ in
            prompts += 1
            return .deny
        }
        XCTAssertEqual(gate.requestConsent(identity()), .denied(replayed: false))
        XCTAssertEqual(gate.requestConsent(identity()), .denied(replayed: true))
        XCTAssertEqual(gate.activate(identity(), now: Date(), lifetime: 10), .denied)
        XCTAssertEqual(prompts, 1)
    }

    func testActivationIsExactAndSingleOwner() {
        let gate = ControlLeaseGate { _ in .allowOnce }
        let first = identity()
        let other = identity(leaseID: "other", requestID: "other-request")
        _ = gate.requestConsent(first)
        XCTAssertEqual(gate.activate(first, now: Date(timeIntervalSince1970: 10), lifetime: 10), .activated(replayed: false))
        XCTAssertEqual(gate.activate(first, now: Date(timeIntervalSince1970: 11), lifetime: 10), .activated(replayed: true))
        _ = gate.requestConsent(other)
        XCTAssertEqual(gate.activate(other, now: Date(timeIntervalSince1970: 11), lifetime: 10), .busy)
    }

    func testNativeDeliveryAcknowledgementPrecedesSequenceAndReplayDoesNotRedeliver() {
        let gate = ControlLeaseGate { _ in .allowOnce }
        let lease = identity()
        _ = gate.requestConsent(lease)
        let activatedAt = Date()
        _ = gate.activate(lease, now: activatedAt, lifetime: 3_600)
        var deliveries = 0
        let payload = Data("pointer".utf8)
        XCTAssertEqual(gate.deliver(lease, sequence: 1, payload: payload) { deliveries += 1; return true }, .delivered)
        XCTAssertEqual(gate.deliver(lease, sequence: 1, payload: payload) { deliveries += 1; return true }, .duplicate)
        XCTAssertEqual(gate.deliver(lease, sequence: 1, payload: Data("different".utf8)) { deliveries += 1; return true }, .rejected("sequence_payload_conflict"))
        XCTAssertEqual(gate.deliver(lease, sequence: 3, payload: Data()) { deliveries += 1; return true }, .rejected("input_sequence_must_increase_by_one"))
        XCTAssertEqual(deliveries, 1)
    }

    func testFailedNativeDeliveryDoesNotAdvanceAndExpiryReleases() {
        let gate = ControlLeaseGate { _ in .allowOnce }
        let lease = identity()
        _ = gate.requestConsent(lease)
        let activatedAt = Date()
        _ = gate.activate(lease, now: activatedAt, lifetime: 3_600)
        XCTAssertEqual(gate.deliver(lease, sequence: 1, payload: Data()) { false }, .rejected("input_delivery_failed"))
        var deliveries = 0
        XCTAssertEqual(gate.deliver(lease, sequence: 1, payload: Data()) { deliveries += 1; return true }, .delivered)
        XCTAssertTrue(gate.expire(now: activatedAt.addingTimeInterval(3_601)))
        XCTAssertNil(gate.activeIdentity())
        XCTAssertEqual(deliveries, 1)
    }

    func testPointerAndKeyTranslationUseSelectedSourceBounds() {
        let source = CaptureSourceDescriptor(
            id: "display:1",
            kind: .display,
            title: "Display",
            width: 3_840,
            height: 2_160,
            scale: 2,
            contentRect: CaptureRect(x: 100, y: 50, width: 1_920, height: 1_080)
        )
        XCTAssertEqual(ControlInputTranslator.point(x: 0.25, y: 0.5, in: source), ControlPoint(x: 580, y: 590))
        XCTAssertEqual(ControlInputTranslator.keyCode(for: "return"), 36)
        XCTAssertNil(ControlInputTranslator.keyCode(for: "sh -c rm"))
        XCTAssertEqual(
            ControlInputTranslator.shiftModifier
                | ControlInputTranslator.controlModifier
                | ControlInputTranslator.optionModifier
                | ControlInputTranslator.commandModifier
                | ControlInputTranslator.capsLockModifier,
            0b1_1111
        )
    }

    func testNativeClipboardValidationMatchesScalarLimitsAndSafeWhitespace() {
        XCTAssertTrue(ControlInputTranslator.validText("first\nsecond\t🙂", maximum: 8_192))
        XCTAssertTrue(ControlInputTranslator.validText("", maximum: 8_192, allowEmpty: true))
        XCTAssertFalse(ControlInputTranslator.validText("", maximum: 4_096))
        for value in ["bad\0value", "bad\rvalue", "bad\u{1b}value", String(repeating: "e\u{301}", count: 4_097)] {
            XCTAssertFalse(ControlInputTranslator.validText(value, maximum: 8_192, allowEmpty: true))
        }
        XCTAssertTrue(ControlInputTranslator.validText(String(repeating: "e\u{301}", count: 4_096), maximum: 8_192))
    }

    func testNativeTextEventsKeepUnicodeSurrogatesTogetherAtTheLimit() {
        let text = String(repeating: "a", count: 63) + "🙂" + String(repeating: "b", count: 62) + "🌍"
        let chunks = ControlInputTranslator.unicodeEventChunks(text)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 64 })
        XCTAssertEqual(chunks.map { String(decoding: $0, as: UTF16.self) }.joined(), text)
        XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
        XCTAssertTrue(ControlInputTranslator.unicodeEventChunks("").isEmpty)
    }

    func testDeliveryExpiryUsesTheSuppliedClock() {
        let gate = ControlLeaseGate { _ in .allowOnce }
        let lease = identity()
        let activatedAt = Date(timeIntervalSince1970: 100)
        _ = gate.requestConsent(lease)
        _ = gate.activate(lease, now: activatedAt, lifetime: 10)

        var delivered = false
        XCTAssertEqual(
            gate.deliver(
                lease,
                sequence: 1,
                payload: Data(),
                now: activatedAt.addingTimeInterval(11)
            ) {
                delivered = true
                return true
            },
            .rejected("lease_expired")
        )
        XCTAssertFalse(delivered)
    }
}
