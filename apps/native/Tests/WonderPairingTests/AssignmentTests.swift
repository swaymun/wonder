import XCTest
@testable import WonderPairing

final class AssignmentTests: XCTestCase {
    func testIntegrationConflictRecoveryRequiresRejectedAndUnstartedWork() throws {
        var draft = ManagementDraft()
        _ = try AssignmentIntent.actionBody(&draft, action: "integrate", revision: "result", expectedHead: "old-head", validation: nil)
        let original = draft.values["_body"]
        XCTAssertFalse(AssignmentIntent.canReconsiderIntegration(draft, authoritativeState: "reviewed"))
        draft.values["_rejected"] = "true"
        XCTAssertTrue(AssignmentIntent.canReconsiderIntegration(draft, authoritativeState: "reviewed"))
        XCTAssertTrue(AssignmentIntent.canReconsiderIntegration(draft, authoritativeState: "submitted"))
        for state in ["integrating", "integrated", "uncertain", "failed", "cancelled"] {
            XCTAssertFalse(AssignmentIntent.canReconsiderIntegration(draft, authoritativeState: state))
        }
        XCTAssertEqual(draft.values["_body"], original)
        draft.values["_action"] = "review"
        XCTAssertFalse(AssignmentIntent.canReconsiderIntegration(draft, authoritativeState: "reviewed"))
    }

    func testCreationRetrySurvivesReloadWithIdenticalBodyAndIdentity() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ManagementDraftStore(host: "host", defaults: defaults)
        var draft = ManagementDraft()
        draft.values = ["title":"Fix unread", "instruction":"Only edit unread state; run its tests.", "botId":"ada", "baseRevision":"abc", "dependencies":"one\ntwo"]
        let first = try AssignmentIntent.creationBody(&draft)
        try store.save(draft, key: "device.create.group")
        var restored = try XCTUnwrap(store.load("device.create.group"))
        restored.values["title"] = "Accidental different title"
        XCTAssertEqual(try AssignmentIntent.creationBody(&restored), first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String:Any])
        XCTAssertEqual(json["clientRequestId"] as? String, draft.requestId)
        XCTAssertEqual(json["dependencyIds"] as? [String], ["one", "two"])
        store.removeAll()
    }
    func testReviewRetryNeverChangesReviewedRevision() throws {
        var draft = ManagementDraft()
        let first = try AssignmentIntent.actionBody(&draft, action: "review", revision: "reviewed", expectedHead: nil, validation: "Tests passed")
        let retry = try AssignmentIntent.actionBody(&draft, action: "review", revision: "changed", expectedHead: nil, validation: "Different")
        XCTAssertEqual(first, retry)
    }
    func testIntegrationPinsExactHeadAndResult() throws {
        var draft = ManagementDraft()
        let body = try AssignmentIntent.actionBody(&draft, action: "integrate", revision: "result", expectedHead: "base", validation: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String:String])
        XCTAssertNil(json["clientRequestId"]) // Mutation schema denies unknown fields.
        XCTAssertEqual(json["expectedHead"], "base")
        XCTAssertEqual(json["resultRevision"], "result")
        XCTAssertEqual(draft.values["_action"], "integrate")
    }
}
