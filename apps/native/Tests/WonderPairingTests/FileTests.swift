import XCTest
@testable import WonderPairing
final class FileTests: XCTestCase {
    func testStagedBytesSurviveCacheReplacementAndSendRequiresVerifiedUpload() throws {
        let data = Data("Actual text file 🌍".utf8)
        let staged = try StagedFile(name: "notes.txt", mimeType: "text/plain", data: data)
        var intent = ComposerIntent(); intent.stagedFiles = [staged]
        XCTAssertThrowsError(try intent.begin(device: "phone"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadStore(root: root, host: "host", device: "phone")
        try store.saveComposer(intent, conversation: "chat"); try store.save(ProjectionState())
        var restored = try store.loadComposer(conversation: "chat")
        XCTAssertEqual(restored.stagedFiles?.first?.data, data)
        let file = ConversationFile(id: "file", name: "notes.txt", mimeType: "text/plain", byteSize: data.count, sha256: ConversationFile.digest(data), state: "available", updatedAt: "now")
        try file.verify(data, mime: "text/plain")
        XCTAssertThrowsError(try file.verify(Data("corrupt".utf8), mime: "text/plain"))
        XCTAssertThrowsError(try file.verify(data, mime: "text/html"))
        restored.stagedFiles?[0].uploaded = file
        try restored.begin(device: "phone")
        XCTAssertEqual(restored.pending?.request.attachmentIds, ["file"])
        XCTAssertNil(restored.stagedFiles)
    }
    func testSpoofedMIMEAndOversizeAreRejected() throws {
        XCTAssertThrowsError(try StagedFile(name: "fake.pdf", mimeType: "application/pdf", data: Data("not a PDF".utf8)))
        XCTAssertThrowsError(try StagedFile(name: "big", mimeType: "application/octet-stream", data: Data(count: 8 * 1024 * 1024 + 1)))
    }

    func testPhotoSignaturesAreValidatedBeforeStaging() throws {
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 0])
        let jpeg = Data([255, 216, 255, 224, 0])
        XCTAssertNoThrow(try StagedFile(name: "photo.png", mimeType: "image/png", data: png))
        XCTAssertNoThrow(try StagedFile(name: "photo.jpg", mimeType: "image/jpeg", data: jpeg))
        XCTAssertThrowsError(try StagedFile(name: "wrong.png", mimeType: "image/png", data: jpeg))
        XCTAssertThrowsError(try StagedFile(name: "wrong.jpg", mimeType: "image/jpeg", data: png))
    }
}
