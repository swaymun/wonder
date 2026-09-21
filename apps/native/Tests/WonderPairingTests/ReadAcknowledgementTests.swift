import XCTest
import CoreGraphics
@testable import WonderPairing

final class ReadAcknowledgementTests: XCTestCase {
    func testCoveringSheetInvalidatesInFlightReadEvenAfterDismissal() {
        var fence = ReadPresentationFence()
        let beforePresentation = fence.revision
        XCTAssertTrue(fence.acceptsReply(startedAt: beforePresentation))
        fence.setCovered(true)
        XCTAssertTrue(fence.isCovered)
        XCTAssertFalse(fence.acceptsReply(startedAt: beforePresentation))
        XCTAssertFalse(fence.acceptsReply(startedAt: fence.revision))
        fence.setCovered(false)
        XCTAssertFalse(fence.acceptsReply(startedAt: beforePresentation))
        let afterDismissal = fence.revision
        fence.setCovered(false)
        XCTAssertTrue(fence.acceptsReply(startedAt: afterDismissal))
    }
    private func snapshot(sequence: UInt64 = 4, epoch: String = "epoch") throws -> ConversationSnapshot {
        try JSONDecoder().decode(ConversationSnapshot.self, from: Data("{\"conversationId\":\"chat\",\"hostEpoch\":\"\(epoch)\",\"lastSequence\":\(sequence),\"messages\":[],\"assistantMessages\":[],\"thread\":{\"hydrated\":true}}".utf8))
    }
    private func summary(unread: Bool, title: String = "Ada") throws -> ChatSummary {
        try JSONDecoder().decode(ChatSummary.self, from: Data("{\"conversationId\":\"chat\",\"botId\":\"ada\",\"title\":\"\(title)\",\"messageCount\":0,\"hasUnread\":\(unread),\"isArchived\":false,\"isPinned\":false}".utf8))
    }
    func testOffscreenAndPartlySeenLatestMessageDoNotCountAsRead() {
        let viewport = CGRect(x: 0, y: 100, width: 400, height: 500)
        XCTAssertFalse(ReadVisibility.latestEndIsVisible(frame: CGRect(x: 0, y: 650, width: 400, height: 200), viewport: viewport))
        XCTAssertFalse(ReadVisibility.latestEndIsVisible(frame: CGRect(x: 0, y: 200, width: 400, height: 700), viewport: viewport))
        XCTAssertFalse(ReadVisibility.latestEndIsVisible(frame: CGRect(x: 450, y: 100, width: 300, height: 200), viewport: viewport))
        XCTAssertTrue(ReadVisibility.latestEndIsVisible(frame: CGRect(x: 0, y: -200, width: 400, height: 750), viewport: viewport))
        XCTAssertFalse(ReadVisibility.latestEndIsVisible(frame: .zero, viewport: viewport))
    }
    func testRequestUsesDisplayedSnapshotNotGlobalCursor() throws {
        let visible = VisibleReadReceipt(snapshot: try snapshot())
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: visible.requestBody()) as? [String:Any])
        XCTAssertEqual(Set(request.keys), ["markRead", "hostEpoch", "readThroughSequence"])
        XCTAssertEqual(request["readThroughSequence"] as? Int, 4)
    }
    func testLateReplyCannotClearUnreadAfterInvalidationOrNewSnapshot() throws {
        var projection = ProjectionState()
        let seen = try snapshot()
        projection.install(seen); projection.summaries = [try summary(unread: true)]
        let visible = VisibleReadReceipt(snapshot: seen)
        projection.lastSequence = 5; projection.dirty.insert("chat")
        XCTAssertFalse(projection.applyReadAcknowledgement(try summary(unread: false), visible: visible, startedAtSequence: 4))
        XCTAssertTrue(projection.summaries[0].hasUnread)
        projection.install(try snapshot(sequence: 5))
        XCTAssertFalse(projection.applyReadAcknowledgement(try summary(unread: false), visible: visible, startedAtSequence: 5))
        XCTAssertTrue(projection.summaries[0].hasUnread)
    }
    func testAcceptedReplyOnlyUpdatesUnreadAndRejectsWrongEpoch() throws {
        var projection = ProjectionState(); let seen = try snapshot()
        projection.install(seen); projection.summaries = [try summary(unread: true, title: "Renamed")]
        XCTAssertFalse(projection.applyReadAcknowledgement(try summary(unread: false), visible: VisibleReadReceipt(snapshot: try snapshot(epoch: "old")), startedAtSequence: 4))
        XCTAssertTrue(projection.applyReadAcknowledgement(try summary(unread: false), visible: VisibleReadReceipt(snapshot: seen), startedAtSequence: 4))
        XCTAssertFalse(projection.summaries[0].hasUnread)
        XCTAssertEqual(projection.summaries[0].title, "Renamed")
    }
    func testGroupsRequireDaemonWatermarkAndOnlyApplyMatchingVisibleRead() throws {
        let old = #"{"id":"group","conversationId":"chat","name":"Developers","isArchived":false,"messages":[]}"#
        let legacy = try JSONDecoder().decode(GroupRead.self, from: Data(old.utf8))
        XCTAssertNil(VisibleReadReceipt(group: legacy))
        let json = #"{"id":"group","conversationId":"chat","name":"Developers","isArchived":false,"hasUnread":true,"hostEpoch":"epoch","lastSequence":4,"messages":[]}"#
        let group = try JSONDecoder().decode(GroupRead.self, from: Data(json.utf8))
        let receipt = try XCTUnwrap(VisibleReadReceipt(group: group))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: receipt.requestBody(isGroup: true)) as? [String:Any])
        XCTAssertEqual(Set(request.keys), ["hostEpoch", "readThroughSequence"])
        var projection = ProjectionState()
        projection.hostEpoch = "epoch"; projection.lastSequence = 4
        projection.groups = ["chat":group]; projection.summaries = [group.summary]
        var reply = group; reply.hasUnread = false
        projection.dirty.insert("chat")
        XCTAssertFalse(projection.applyGroupReadAcknowledgement(reply, visible: receipt, startedAtSequence: 4))
        XCTAssertTrue(projection.summaries[0].hasUnread)
        projection.dirty.remove("chat")
        XCTAssertTrue(projection.applyGroupReadAcknowledgement(reply, visible: receipt, startedAtSequence: 4))
        XCTAssertFalse(projection.summaries[0].hasUnread)
        XCTAssertEqual(projection.groups["chat"]?.lastSequence, 4)
    }

}
