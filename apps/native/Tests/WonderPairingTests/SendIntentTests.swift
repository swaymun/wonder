import XCTest
import CryptoKit
@testable import WonderPairing

final class SendIntentTests: XCTestCase {
    func receipt(_ intent: ComposerIntent, conversation: String = "chat", state: String = "accepted_by_wonder") -> SendReceipt {
        let request = intent.pending!.request
        return SendReceipt(clientMessageId: request.clientMessageId, wonderMessageId: "server-id",
            bodySha256: SHA256.hash(data: Data(request.body.utf8)).map { String(format: "%02x", $0) }.joined(),
            conversationId: conversation, deliveryState: state)
    }

    func testLostResponseAndRestartReuseExactRequestWhileNewDraftSurvives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadStore(root: root, host: "Mac", device: "phone")
        var intent = ComposerIntent(); intent.draft = "  Hello 🌍\nKeep my whitespace.  "
        try store.saveComposer(intent, conversation: "chat")
        XCTAssertEqual(try store.loadComposer(conversation: "chat").draft, intent.draft)
        try intent.begin(device: "phone")
        let original = intent.pending!.request
        try store.saveComposer(intent, conversation: "chat")
        // The Mac accepts, but the response is lost and iOS exits.
        var recovered = try store.loadComposer(conversation: "chat")
        XCTAssertEqual(recovered.pending?.request.clientMessageId, original.clientMessageId)
        XCTAssertEqual(recovered.pending?.request.body, original.body)
        recovered.draft = "A different follow-up"
        XCTAssertThrowsError(try recovered.begin(device: "phone"))
        XCTAssertEqual(recovered.draft, "A different follow-up")
        try recovered.accept(receipt(intent), conversation: "chat")
        try store.saveComposer(recovered, conversation: "chat")
        try store.save(ProjectionState())
        let restarted = try store.loadComposer(conversation: "chat")
        XCTAssertEqual(restarted.pending?.receipt?.wonderMessageId, "server-id")
        XCTAssertEqual(restarted.draft, "A different follow-up")
        XCTAssertNil(try ReadStore(root: root, host: "other", device: "phone").loadComposer(conversation: "chat").pending)
    }

    func testWrongReceiptCannotClearIntentAndSnapshotMustIncludeMessage() throws {
        var intent = ComposerIntent(); intent.draft = "hello"
        try intent.begin(device: "phone")
        XCTAssertThrowsError(try intent.accept(receipt(intent, conversation: "other"), conversation: "chat"))
        XCTAssertNil(intent.pending?.receipt)
        try intent.accept(receipt(intent, state: "uncertain"), conversation: "chat")
        let empty = ConversationSnapshot(conversationId: "chat", hostEpoch: "epoch", lastSequence: 1,
            messages: [], assistantMessages: [], thread: ThreadProjection(nextCursor: nil, hydrated: true))
        intent.reconcile(empty)
        XCTAssertNotNil(intent.pending)
        let snapshot = ConversationSnapshot(conversationId: "chat", hostEpoch: "epoch", lastSequence: 2,
            messages: [ConversationMessage(messageId: "server-id", body: "hello", state: "uncertain", createdAt: "1000", attachmentIds: [])],
            assistantMessages: [], thread: empty.thread)
        intent.reconcile(snapshot)
        XCTAssertNil(intent.pending)
        XCTAssertEqual(snapshot.messages.first?.state, "uncertain")
    }

    func testUTF8LimitsAndWhitespace() throws {
        var intent = ComposerIntent(); intent.draft = " \n "
        XCTAssertThrowsError(try intent.begin(device: "phone"))
        intent.draft = String(repeating: "🌍", count: 16385)
        XCTAssertThrowsError(try intent.begin(device: "phone"))
        XCTAssertFalse(intent.draft.isEmpty)
        intent.draft = String(repeating: "🌍", count: 16384)
        try intent.begin(device: "phone")
        XCTAssertEqual(intent.pending?.request.body.utf8.count, 65536)
    }

    func testSnapshotRecoversLostReceiptAndKeepsLocalRowIdentity() throws {
        var intent = ComposerIntent(); intent.draft = "One request"
        try intent.begin(device: "phone")
        let client = intent.pending!.request.clientMessageId
        intent.draft = "Next draft"
        let snapshot = ConversationSnapshot(conversationId: "chat", hostEpoch: "epoch", lastSequence: 2,
            messages: [ConversationMessage(clientMessageId: client, messageId: "server-id", body: "One request", state: "streaming", createdAt: "1000", attachmentIds: [])],
            assistantMessages: [], thread: ThreadProjection(nextCursor: nil, hydrated: true,
                turns: [ReadTurn(id: "turn", items: [ReadItem(id: "server-id", type: "userMessage", state: "streaming", text: "One request", createdAt: "1000")])]))
        intent.reconcile(snapshot)
        XCTAssertNil(intent.pending)
        XCTAssertEqual(intent.draft, "Next draft")
        XCTAssertEqual(snapshot.rows(author: "Ada").map(\.id), ["user-" + client])
    }

    func testLiveTextOverridesStaleThreadAndAcceptedMessageIsVisible() throws {
        let snapshot = ConversationSnapshot(conversationId: "chat", hostEpoch: "epoch", lastSequence: 2,
            messages: [ConversationMessage(messageId: "new", body: "New request", state: "accepted_by_wonder", createdAt: "3000", attachmentIds: [])],
            assistantMessages: [AssistantMessage(itemId: "item", messageId: "assistant:turn:item", text: "Hello world", state: "streaming", createdAt: "2000", updatedAt: "3000")],
            thread: ThreadProjection(nextCursor: nil, hydrated: true, turns: [ReadTurn(id: "turn", items: [ReadItem(id: "item", type: "agentMessage", state: "streaming", text: "Hello", createdAt: "2000")])]))
        let rows = snapshot.rows(author: "Ada")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.text, "Hello world")
        XCTAssertEqual(rows.first?.id, "turn/item")
        XCTAssertEqual(rows.last?.id, "user-new")
    }
    func testLostReceiptReconcilesAfterAnotherDeviceEditsAcceptedQueueItem() throws {
        var intent = ComposerIntent(); intent.draft = "Original"
        try intent.begin(device: "phone")
        let id = intent.pending!.request.clientMessageId
        let snapshot = ConversationSnapshot(conversationId: "chat",hostEpoch:"host",lastSequence:3,
            messages:[ConversationMessage(clientMessageId:id,originalBodySha256:ConversationFile.digest(Data("Original".utf8)),messageId:"server",body:"Edited on Mac",state:"accepted_by_wonder",createdAt:"1000",attachmentIds:[])],assistantMessages:[],thread:ThreadProjection(nextCursor:nil,hydrated:true))
        intent.reconcile(snapshot)
        XCTAssertNil(intent.pending)
    }

    func testRemovingOneRestoredAttachmentPersistsOtherAttachment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadStore(root: root, host: "Mac", device: "phone")
        var intent = ComposerIntent()
        intent.draft = "Review these files"
        intent.draftAttachmentIds = ["server-photo", "missing-file"]
        let localData = Data("local".utf8)
        let uploaded = ConversationFile(id: "uploaded-local", name: "local.txt", mimeType: "text/plain",
            byteSize: localData.count, sha256: ConversationFile.digest(localData), state: "available", updatedAt: "now")
        let local = try StagedFile(id: "local-file", name: "local.txt", mimeType: "text/plain", data: localData, uploaded: uploaded)
        intent.stagedFiles = [local]
        try store.saveComposer(intent, conversation: "chat")

        var restored = try store.loadComposer(conversation: "chat")
        XCTAssertEqual(restored.attachmentIDs, [local.id, "server-photo", "missing-file"])
        XCTAssertEqual(restored.stagedFiles?.first?.uploaded?.id, "uploaded-local")
        restored.removeAttachment(id: "server-photo")
        try store.saveComposer(restored, conversation: "chat")

        let persisted = try store.loadComposer(conversation: "chat")
        XCTAssertEqual(persisted.attachmentIDs, [local.id, "missing-file"])
        XCTAssertEqual(persisted.draft, "Review these files")
    }

    func testAttachmentIdentityIsUniqueAndTheFourthIsAllowedButFifthIsRejected() throws {
        var intent = ComposerIntent()
        intent.draftAttachmentIds = ["one", "two", "three", "four"]
        XCTAssertEqual(intent.attachmentIDs, ["one", "two", "three", "four"])
        XCTAssertEqual(intent.attachmentCount, 4)
        try intent.begin(device: "phone")
        XCTAssertEqual(intent.pending?.request.attachmentIds, ["one", "two", "three", "four"])

        var tooMany = ComposerIntent()
        tooMany.draftAttachmentIds = ["one", "two", "three", "four", "five"]
        XCTAssertEqual(tooMany.attachmentCount, 5)
        XCTAssertThrowsError(try tooMany.begin(device: "phone")) { error in
            XCTAssertTrue(error is FileFailure)
        }
        XCTAssertNil(tooMany.pending)
    }

    func testUploadedStagedAndRestoredAttachmentsKeepTheirDistinctSendIdentities() throws {
        let bytes = Data([255, 216, 255])
        let uploaded = ConversationFile(id: "server-photo", name: "photo.jpg", mimeType: "image/jpeg",
            byteSize: bytes.count, sha256: ConversationFile.digest(bytes), state: "available", updatedAt: "now")
        let staged = try StagedFile(id: "local-photo", name: "photo.jpg", mimeType: "image/jpeg", data: bytes, uploaded: uploaded)
        var intent = ComposerIntent()
        intent.draft = "Review both"
        intent.stagedFiles = [staged]
        intent.draftAttachmentIds = ["restored-document"]
        XCTAssertEqual(intent.attachmentIDs, ["local-photo", "restored-document"])
        XCTAssertEqual(intent.attachmentCount, 2)

        try intent.begin(device: "phone")
        XCTAssertEqual(intent.pending?.request.attachmentIds, ["server-photo", "restored-document"])
    }

    func testAcceptedPendingAttachmentSnapshotStaysImmutableWhileFollowUpDraftChanges() throws {
        var intent = ComposerIntent()
        intent.draft = "Send these photos"
        intent.draftAttachmentIds = ["photo-1", "photo-2"]
        try intent.begin(device: "phone")
        let pendingID = try XCTUnwrap(intent.pending?.request.clientMessageId)
        XCTAssertEqual(intent.pending?.request.attachmentIds, ["photo-1", "photo-2"])
        XCTAssertEqual(intent.attachmentCount, 0)

        intent.draft = "Follow up"
        intent.draftAttachmentIds = ["photo-3"]
        intent.removeAttachment(id: "photo-1")
        XCTAssertEqual(intent.pending?.request.clientMessageId, pendingID)
        XCTAssertEqual(intent.pending?.request.attachmentIds, ["photo-1", "photo-2"])
        XCTAssertEqual(intent.attachmentIDs, ["photo-3"])

        let snapshot = ConversationSnapshot(conversationId: "chat", hostEpoch: "epoch", lastSequence: 1,
            messages: [ConversationMessage(clientMessageId: pendingID, messageId: "server-id", body: "Send these photos",
                state: "accepted_by_wonder", createdAt: "1000", attachmentIds: ["photo-1", "photo-2"])],
            assistantMessages: [], thread: ThreadProjection(nextCursor: nil, hydrated: true))
        intent.reconcile(snapshot)
        XCTAssertNil(intent.pending)
        XCTAssertEqual(intent.draft, "Follow up")
        XCTAssertEqual(intent.attachmentIDs, ["photo-3"])
    }
}
