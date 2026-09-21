import XCTest
@testable import WonderPairing

final class GroupTests: XCTestCase {
    func testLostGroupReceiptReconcilesCanonicalUserIdentity() throws {
        var intent = ComposerIntent(); intent.draft = "@ada hello"
        try intent.begin(device: "phone")
        let client = intent.pending!.request.clientMessageId
        let data = Data("""
        {"id":"group","conversationId":"chat","name":"Plans","isArchived":false,"members":[{"botId":"ada","botName":"Ada","role":"worker"}],"messages":[
          {"messageId":"one","clientMessageId":"\(client)","body":"@ada hello","createdAt":"1000","authorKind":"user","presentationKind":"message"},
          {"messageId":"two","body":"internal prompt","createdAt":"1001","authorKind":"member","authorBotName":"Ada","presentationKind":"activity"},
          {"messageId":"three","body":"Please try later","createdAt":"1002","authorKind":"member","authorBotName":"Ada","presentationKind":"status","outcome":"failed"}]}
        """.utf8)
        let group = try JSONDecoder().decode(GroupRead.self, from: data)
        XCTAssertEqual(group.rows.map(\.author), ["You", "Ada"])
        XCTAssertEqual(group.rows.first?.id, "user-" + client)
        intent.draft = "Keep this follow-up"
        intent.reconcile(group)
        XCTAssertNil(intent.pending)
        XCTAssertEqual(intent.draft, "Keep this follow-up")
        XCTAssertEqual(group.members?.first?.id, "ada")
    }
}

extension GroupTests {
    private func attachmentGroup(client: String, supported: Bool? = true, archived: Bool = false) throws -> GroupRead {
        var value: [String: Any] = [
            "id": "group", "conversationId": "group-chat", "name": "Plans", "isArchived": archived,
            "messages": [["messageId": "canonical-message", "clientMessageId": client,
                "body": "", "createdAt": "1000", "authorKind": "user", "presentationKind": "message",
                "attachmentIds": ["canonical-file"]]]]
        if let supported { value["attachmentsSupported"] = supported }
        return try JSONDecoder().decode(GroupRead.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testGroupAttachmentsRequireExplicitSupportAndKeepCanonicalReadLinks() throws {
        XCTAssertFalse(try attachmentGroup(client: "client", supported: nil).canAttachFiles)
        XCTAssertFalse(try attachmentGroup(client: "client", supported: false).canAttachFiles)
        XCTAssertFalse(try attachmentGroup(client: "client", archived: true).canAttachFiles)
        let group = try attachmentGroup(client: "client")
        XCTAssertTrue(group.canAttachFiles)
        XCTAssertEqual(group.rows.first?.id, "user-client")
        XCTAssertEqual(group.rows.first?.attachmentIds, ["canonical-file"])
        XCTAssertEqual(group.rows.first?.text, "")
        let cached = try JSONDecoder().decode(GroupRead.self, from: JSONEncoder().encode(group))
        XCTAssertTrue(cached.canAttachFiles)
        XCTAssertEqual(cached.rows.first?.attachmentIds, ["canonical-file"])
    }

    func testAttachmentOnlyGroupRetryRetainsUploadAndMessageIdentityAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadStore(root: root, host: "mac", device: "phone")
        let bytes = Data("Bounded Group attachment".utf8)
        var staged = try StagedFile(name: "notes.txt", mimeType: "text/plain", data: bytes)
        var draft = ComposerIntent(); draft.stagedFiles = [staged]
        try store.saveComposer(draft, conversation: "group-chat")
        var restored = try store.loadComposer(conversation: "group-chat")
        let restoredUpload = try JSONSerialization.jsonObject(with: XCTUnwrap(restored.stagedFiles?.first).uploadBody()) as? [String: String]
        let originalUpload = try JSONSerialization.jsonObject(with: staged.uploadBody()) as? [String: String]
        XCTAssertEqual(restoredUpload, originalUpload)
        XCTAssertThrowsError(try restored.begin(device: "phone"))
        staged.uploaded = ConversationFile(id: "canonical-file", name: "notes.txt", mimeType: "text/plain", byteSize: bytes.count, sha256: ConversationFile.digest(bytes), state: "available", updatedAt: "1000")
        try staged.uploaded?.verify(bytes, mime: staged.mimeType)
        restored.stagedFiles = [staged]
        try restored.begin(device: "phone")
        let request = restored.pending!.request
        XCTAssertEqual(request.body, "")
        XCTAssertEqual(request.attachmentIds, ["canonical-file"])
        try store.saveComposer(restored, conversation: "group-chat")
        var retry = try store.loadComposer(conversation: "group-chat")
        XCTAssertEqual(retry.pending?.request.clientMessageId, request.clientMessageId)
        XCTAssertEqual(retry.pending?.request.attachmentIds, request.attachmentIds)
        XCTAssertNil(try ReadStore(root: root, host: "other-mac", device: "phone").loadComposer(conversation: "group-chat").pending)
        XCTAssertNil(try ReadStore(root: root, host: "mac", device: "other-phone").loadComposer(conversation: "group-chat").pending)
        retry.draft = "Next message remains here"
        retry.reconcile(try attachmentGroup(client: request.clientMessageId))
        XCTAssertNil(retry.pending)
        XCTAssertEqual(retry.draft, "Next message remains here")
    }
}
