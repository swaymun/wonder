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
