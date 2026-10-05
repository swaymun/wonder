import Foundation
import AVFoundation
import XCTest
@testable import WonderPairing

private final class MediaResponseProtocol: URLProtocol, @unchecked Sendable {
    private static let revision = String(repeating: "a", count: 64)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "media-test.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let mode = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "case" })?.value
        let range = request.value(forHTTPHeaderField: "Range")
        let authenticated = request.value(forHTTPHeaderField: "Origin") == "https://media-test.invalid"
            && request.value(forHTTPHeaderField: "Cookie") == "__Host-wonder_session=synthetic"
        let expectedRevision = range == "bytes=0-0" ? nil : Self.revision
        guard authenticated, request.value(forHTTPHeaderField: "X-Wonder-Revision") == expectedRevision else {
            reply(status: 403, body: Data(), headers: [:]); return
        }
        if mode == "asset", let fixture = ProcessInfo.processInfo.environment["WONDER_MEDIA_FIXTURE"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: fixture)),
           let range, range.hasPrefix("bytes=") {
            let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            guard bounds.count == 2, bounds[0] >= 0, bounds[0] < data.count else {
                reply(status: 416, body: Data(), headers: [:]); return
            }
            let end = min(bounds[1], data.count - 1)
            let body = data.subdata(in: bounds[0]..<(end + 1))
            reply(status: 206, body: body, headers: [
                "Content-Type": "video/mp4",
                "Content-Range": "bytes \(bounds[0])-\(end)/\(data.count)",
                "Content-Length": "\(body.count)",
                "X-Wonder-Revision": Self.revision
            ])
            return
        }
        if mode == "stale" && range != "bytes=0-0" {
            reply(status: 409, body: Data(), headers: [:]); return
        }
        let body = range == "bytes=0-0" ? Data("a".utf8) : Data("bcd".utf8)
        let actual = mode == "truncated" ? body.prefix(2) : body[...]
        let start = range == "bytes=0-0" ? 0 : 1
        let end = range == "bytes=0-0" ? 0 : 3
        reply(status: 206, body: Data(actual), headers: [
            "Content-Type": "video/mp4",
            "Content-Range": "bytes \(start)-\(end)/4",
            "Content-Length": "\(body.count)",
            "X-Wonder-Revision": mode == "changed-revision" ? String(repeating: "b", count: 64) : Self.revision
        ])
    }
    override func stopLoading() {}

    private func reply(status: Int, body: Data, headers: [String: String]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class WorkspaceMediaTransportTests: XCTestCase {
    private func fixture() -> (PairingAPI, SavedConnection) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaResponseProtocol.self]
        let api = PairingAPI(configuration: configuration)
        let credential = Credential(sessionToken: "synthetic", deviceId: "phone",
                                    csrfToken: "csrf", hostInstallationId: "host", expiresAtMs: nil)
        return (api, SavedConnection(origin: "https://media-test.invalid", credential: credential))
    }

    func testMediaRangesAuthenticateAndPinRevision() async throws {
        let (api, connection) = fixture()
        let path = "/api/v1/conversations/chat/workspace/media?root=workspace&path=clip.mp4"
        let first = try await api.downloadWorkspaceMediaRange(path, connection: connection,
                                                               start: 0, end: 0, revision: nil)
        XCTAssertEqual(first.bytes, Data("a".utf8))
        XCTAssertEqual(first.total, 4)
        XCTAssertEqual(first.mimeType, "video/mp4")
        let next = try await api.downloadWorkspaceMediaRange(path, connection: connection,
                                                              start: 1, end: 3, revision: first.revision)
        XCTAssertEqual(next.bytes, Data("bcd".utf8))
        XCTAssertEqual(next.revision, first.revision)
    }

    func testMediaRangeRejectsTruncationAndRevisionChange() async throws {
        let (api, connection) = fixture()
        let base = "/api/v1/conversations/chat/workspace/media?root=workspace&path=clip.mp4&case="
        let revision = String(repeating: "a", count: 64)
        do {
            _ = try await api.downloadWorkspaceMediaRange(base + "truncated", connection: connection,
                                                           start: 1, end: 3, revision: revision)
            XCTFail("Truncated media must not be accepted")
        } catch FileFailure.integrity { }
        do {
            _ = try await api.downloadWorkspaceMediaRange(base + "changed-revision", connection: connection,
                                                           start: 1, end: 3, revision: revision)
            XCTFail("A changed media revision must not be merged")
        } catch FileFailure.stale { }
        let probe = try await api.downloadWorkspaceMediaRange(base + "stale", connection: connection,
                                                               start: 0, end: 0, revision: nil)
        do {
            _ = try await api.downloadWorkspaceMediaRange(base + "stale", connection: connection,
                                                           start: 1, end: 3, revision: probe.revision)
            XCTFail("A 409 after the first probe must request a new preview")
        } catch FileFailure.stale { }
    }

    func testAssetLoaderReadsAuthenticatedRanges() async throws {
        guard ProcessInfo.processInfo.environment["WONDER_MEDIA_FIXTURE"] != nil else {
            throw XCTSkip("Run with a local synthetic MP4 fixture to probe AVFoundation on this host")
        }
        let (api, connection) = fixture()
        let loader = WorkspaceMediaResourceLoader(api: api, connection: connection,
            path: "/api/v1/conversations/chat/workspace/media?root=workspace&path=clip.mp4&case=asset")
        let asset = try loader.asset(filename: "clip.mp4")
        let isPlayable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        XCTAssertTrue(isPlayable)
        XCTAssertGreaterThan(duration.seconds, 0)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        let deadline = Date().addingTimeInterval(5)
        while player.currentItem?.status == .unknown && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(player.currentItem?.status, .readyToPlay)
        let didSeek = await withCheckedContinuation { continuation in
            player.seek(to: CMTime(seconds: 1, preferredTimescale: 600)) { finished in
                continuation.resume(returning: finished)
            }
        }
        XCTAssertTrue(didSeek)
        player.pause()
    }
}

private final class LargePreviewProtocol: URLProtocol, @unchecked Sendable {
    static let body: Data = {
        let count = 9 * 1024 * 1024 + 17
        var bytes = [UInt8](repeating: 0, count: count)
        for index in 0..<count { bytes[index] = UInt8(index % 251) }
        return Data(bytes)
    }()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "large-preview.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let large = request.url?.query?.contains("too-large") == true
        let status = large ? 413 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": large ? "0" : "\(Self.body.count)", "Content-Type": "application/pdf"])!,
            cacheStoragePolicy: .notAllowed)
        if !large { client?.urlProtocol(self, didLoad: Self.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class WorkspacePreviewDownloadTests: XCTestCase {
    func testLargePreviewDownloadsCompletelyWithProgressAndRefusesHostLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LargePreviewProtocol.self]
        let api = PairingAPI(configuration: configuration)
        let connection = SavedConnection(origin: "https://large-preview.invalid", credential: Credential(
            sessionToken: "synthetic", deviceId: "phone", csrfToken: "csrf", hostInstallationId: "host", expiresAtMs: nil))
        let reports = LockedReports()
        let body = LargePreviewProtocol.body
        let data = try await api.downloadWorkspaceBytes("/api/v1/conversations/c/workspace/file?path=a.bin", connection: connection,
            byteSize: body.count, sha256: nil, mimeType: nil) { received, expected in reports.add(received, expected) }
        XCTAssertEqual(data, body)
        let seen = reports.values
        XCTAssertEqual(seen.last?.0, body.count)
        XCTAssertTrue(seen.allSatisfy { $0.1 == body.count })
        XCTAssertGreaterThan(seen.count, 9, "Large files report progress while they load")
        do {
            _ = try await api.downloadWorkspaceBytes("/api/v1/conversations/c/workspace/file?path=too-large", connection: connection,
                                                     byteSize: nil, sha256: nil, mimeType: nil)
            XCTFail("A host size refusal must not look like a missing file")
        } catch FileFailure.tooLarge {}
        do {
            _ = try await api.downloadWorkspaceBytes("/x", connection: connection,
                byteSize: PairingAPI.workspacePreviewLimit + 1, sha256: nil, mimeType: nil)
            XCTFail("Oversized listings are refused before transfer")
        } catch FileFailure.tooLarge {}
    }
}

private final class LockedReports: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(Int, Int?)] = []
    func add(_ received: Int, _ expected: Int?) { lock.lock(); stored.append((received, expected)); lock.unlock() }
    var values: [(Int, Int?)] { lock.lock(); defer { lock.unlock() }; return stored }
}
