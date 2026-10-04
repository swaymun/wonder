import XCTest
import CryptoKit
@testable import WonderPairing

// An independent host boundary checks wire requests and real ECDSA signatures.
// It never calls the client's signing or validation helpers.
private final class GitHubHostProtocol: URLProtocol, @unchecked Sendable {
    static let key = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
    static let sha = String(repeating: "a", count: 40)
    static let started = XCTestExpectation(description: "Held GitHub response started")
    static let stopped = XCTestExpectation(description: "Held GitHub response cancelled")
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "github-review.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {
        if request.url?.path.contains("/held/") == true { Self.stopped.fulfill() }
    }
    override func startLoading() {
        guard let url = request.url, request.timeoutInterval == 90,
              request.value(forHTTPHeaderField: "Origin") == "https://github-review.invalid",
              request.value(forHTTPHeaderField: "Cookie") == "__Host-wonder_session=session",
              request.value(forHTTPHeaderField: "x-wonder-csrf") == "csrf" else { reply(403); return }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 6, parts[0...2] == ["api", "v1", "projects"], parts[4] == "github-review" else { reply(404); return }
        let project = parts[3], root = parts[5]
        if project == "held" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{".utf8))
            Self.started.fulfill()
            return
        }
        if project == "denied" { reply(403, object: ["private": "Never display upstream errors"]); return }
        if project == "oversized" {
            reply(200, raw: Data(repeating: 32, count: 64 * 1024 + 1)); return
        }
        if project == "advertised-large" {
            reply(200, raw: Data("{}".utf8), headers: ["Content-Length": "65537"]); return
        }
        let scope: [String: Any] = ["hostInstallationId": project == "wrong-host" ? "other" : "host",
            "projectId": project, "rootId": root, "rootsRevision": 2, "authorizationRevision": 3]
        let identity: [String: Any] = ["accountId": 10, "accountLogin": "owner", "repositoryId": 20, "repository": "owner/repo"]
        if parts.last == "prepare", request.httpMethod == "POST" {
            reply(200, object: scope.merging(["identity": identity]) { _, new in new }); return
        }
        if request.httpMethod == "PUT" || request.httpMethod == "DELETE" {
            guard let body = requestBody(), let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let nonce = fields["actionNonce"] as? String, UUID(uuidString: nonce) != nil,
                  let timestamp = fields["issuedAtMs"] as? UInt64,
                  abs(Date().timeIntervalSince1970 * 1000 - Double(timestamp)) < 30_000,
                  let revision = fields["authorizationRevision"] as? Int, revision == 3,
                  let signature = fields["signature"] as? String else { reply(403); return }
            let authorize = request.httpMethod == "PUT"
            let expected: [Any] = authorize ? [2, 3, 10, 20, "owner/repo", true] : [3]
            guard !authorize || (fields["rootsRevision"] as? Int == 2 && fields["accountId"] as? Int == 10 &&
                fields["repositoryId"] as? Int == 20 && fields["repository"] as? String == "owner/repo" &&
                fields["confirmReadAccess"] as? Bool == true) else { reply(403); return }
            let canonical = try! JSONSerialization.data(withJSONObject: expected, options: [.withoutEscapingSlashes])
            let hash = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
            let transcript = Data(["wonder-action-v1", authorize ? "github.review.authorize" : "github.review.revoke",
                "/api/v1/projects/\(project)/github-review/\(root)", hash, nonce, "csrf", "phone", "host", String(timestamp), "3"].joined(separator: "\n").utf8)
            let base64 = signature.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            guard let data = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)),
                  let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: data),
                  Self.key.publicKey.isValidSignature(ecdsa, for: transcript) else { reply(403); return }
            reply(204); return
        }
        if parts.count == 8, parts[6] == "pulls", request.httpMethod == "GET" {
            var file: [String: Any] = ["path": "Sources/new.swift", "previousPath": "Sources/old.swift", "sha": Self.sha,
                "status": "renamed", "additions": 1, "deletions": 1, "patchState": "suppliedCountsMatch", "patch": "@@ -1 +1 @@\n-old\n+new\n"]
            switch project {
            case "unsafe-path": file["path"] = "../secret"
            case "partial-bytes": file["patchState"] = "partial"
            case "unknown-state": file["patchState"] = "invented"
            case "missing-rename": file["previousPath"] = NSNull()
            default: break
            }
            let unavailable: [String: Any] = ["path": "image.png", "previousPath": NSNull(), "sha": Self.sha,
                "status": "modified", "additions": 0, "deletions": 0, "patchState": "unavailable", "patch": NSNull()]
            let files = project == "duplicates" ? [file, file] : [file, unavailable]
            let snapshot: [String: Any] = ["projectId": project, "rootId": root, "rootsRevision": 2,
                "accountId": project == "wrong-account" ? 11 : 10, "identity": ["apiHost": "api.github.com", "repositoryId": 20,
                "repository": "owner/repo", "headRepositoryId": 21, "headRepository": "contributor/fork", "number": project == "wrong-pr" ? 99 : 42,
                "base": Self.sha, "head": String(repeating: "b", count: 40)], "mergeBase": Self.sha, "title": "A change", "state": "open",
                "fetchedAt": "2026-10-04T00:00:00Z", "enumerationComplete": project != "incomplete", "files": files]
            reply(200, object: ["hostInstallationId": project == "snapshot-host" ? "other" : "host",
                "authorizationRevision": project == "snapshot-epoch" ? 4 : 3, "snapshot": snapshot]); return
        }
        reply(200, object: scope.merging(["connected": true, "repository": "owner/repo", "repositoryId": 20, "accountId": 10]) { _, new in new })
    }
    private func requestBody() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    private func reply(_ status: Int, object: [String: Any]? = nil, raw: Data? = nil, headers: [String: String] = [:]) {
        let body = raw ?? object.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers.merging(["Content-Type": "application/json"]) { old, _ in old })!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class GitHubReviewTests: XCTestCase {
    private func connection(session: String = "session", csrf: String = "csrf", host: String = "host", device: String = "phone",
                            origin: String = "https://github-review.invalid") -> SavedConnection {
        SavedConnection(origin: origin, credential: Credential(sessionToken: session, deviceId: device, csrfToken: csrf,
                                                               hostInstallationId: host, expiresAtMs: nil))
    }
    private func scope(_ projectId: String = "project space", revision: Int = 2, included: Bool = true, version: Int? = 1) throws -> GitHubReviewScope {
        try GitHubReviewScope(project: ProjectSummary(id: projectId, name: "Project", isIncluded: included, rootsRevision: revision,
            folders: [ProjectFolder(id: "stored-folder", path: "/work", name: "Work", isPrimary: true, isAvailable: false)]),
            folderId: "stored-folder", hostVersion: version)
    }
    private func client(_ project: String = "project space", missingKey: Bool = false) throws -> GitHubReviewClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GitHubHostProtocol.self]
        let identity = SigningIdentity(read: { missingKey ? nil : GitHubHostProtocol.key.rawRepresentation },
            save: { _ in XCTFail("Review cannot save an identity") },
            restore: { data in
                let key = try P256.Signing.PrivateKey(rawRepresentation: data)
                return EnrollmentSigningIdentity(publicKey: key.publicKey, representation: data, sign: { try key.signature(for: $0) })
            }, create: { fatalError("Review cannot create an identity") })
        return try GitHubReviewClient(api: PairingAPI(configuration: configuration), connection: connection(), scope: scope(project), signer: identity)
    }
    func testSignedConsentDisconnectAndPinnedSnapshotAuthenticate() async throws {
        let review = try client()
        let preparation = try await review.prepare()
        XCTAssertEqual(preparation.identity.accountLogin, "owner")
        try await review.authorize(preparation)
        let status = try await review.status()
        let snapshot = try await review.snapshot(number: 42, connected: status)
        XCTAssertEqual(snapshot.identity.headRepository, "contributor/fork")
        XCTAssertEqual(snapshot.files.first?.previousPath, "Sources/old.swift")
        XCTAssertEqual(snapshot.files.last?.patchState, .unavailable)
        XCTAssertNil(snapshot.files.last?.patch)
        try await review.disconnect(status)
    }
    func testMalformedAndChangedSnapshotsAreRejected() async throws {
        for project in ["unsafe-path", "partial-bytes", "unknown-state", "missing-rename", "duplicates", "wrong-account", "wrong-pr", "incomplete", "snapshot-host", "snapshot-epoch"] {
            let review = try client(project)
            let status = try await review.status()
            do { _ = try await review.snapshot(number: 42, connected: status); XCTFail("Accepted \(project)") }
            catch is GitHubReviewFailure { }
        }
    }
    func testBoundsHostAndAccessFailuresRemainTyped() async throws {
        for project in ["oversized", "advertised-large", "wrong-host", "denied"] {
            do { _ = try await client(project).status(); XCTFail("Accepted \(project)") }
            catch let error as GitHubReviewFailure {
                switch (project, error) {
                case ("oversized", .oversized), ("advertised-large", .oversized), ("wrong-host", .scopeChanged), ("denied", .response(403)): break
                default: XCTFail("Wrong failure for \(project): \(error)")
                }
            }
        }
    }
    func testUnsupportedAndNonmemberScopesFailBeforeNetwork() throws {
        XCTAssertThrowsError(try scope(version: nil))
        XCTAssertThrowsError(try scope(version: 2))
        XCTAssertThrowsError(try scope(included: false))
        XCTAssertThrowsError(try scope(revision: 0))
        for id in ["", "..", "wrong/root", "wrong\nroot"] { XCTAssertThrowsError(try scope(id)) }
        let project = ProjectSummary(id: "p", name: "P", folders: [])
        XCTAssertThrowsError(try GitHubReviewScope(project: project, folderId: "workspace", hostVersion: 1))
    }
    func testMissingSigningKeyNeverCreatesIdentityOrGrants() async throws {
        let review = try client(missingKey: true)
        let prepared = try await review.prepare()
        do { try await review.authorize(prepared); XCTFail("Missing key signed consent") }
        catch SigningIdentityFailure.missing { }
    }
    func testOwnerFenceIncludesActualSessionAndOrigin() async throws {
        let review = try client()
        let currentScope = try scope()
        let same = review.matches(connection: connection(), scope: currentScope)
        XCTAssertTrue(same)
        for current in [connection(session: "renewed"), connection(csrf: "new-csrf"), connection(host: "other"),
                        connection(device: "other"), connection(origin: "https://other.invalid")] {
            let matches = review.matches(connection: current, scope: currentScope)
            XCTAssertFalse(matches)
        }
        let changed = review.matches(connection: connection(), scope: try scope(revision: 3))
        XCTAssertFalse(changed)
        XCTAssertFalse(review.matches(connection: nil, scope: currentScope))
        var unpaired = connection(); unpaired.requiresPairing = true
        XCTAssertFalse(review.matches(connection: unpaired, scope: currentScope))
        let expired = SavedConnection(origin: "https://github-review.invalid", credential: Credential(
            sessionToken: "session", deviceId: "phone", csrfToken: "csrf", hostInstallationId: "host", expiresAtMs: 1))
        XCTAssertFalse(review.matches(connection: expired, scope: currentScope))
    }
    func testAlreadyCancelledOwnerDoesNotReadOrSign() async throws {
        let review = try client()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await review.prepare()
        }
        do { _ = try await task.value; XCTFail("Cancelled owner read") }
        catch is CancellationError { }
    }
    func testCancelledStreamingReadStopsUnderlyingRequest() async throws {
        let review = try client("held")
        let task = Task { try await review.status() }
        await fulfillment(of: [GitHubHostProtocol.started], timeout: 3)
        task.cancel()
        await fulfillment(of: [GitHubHostProtocol.stopped], timeout: 3)
        do { _ = try await task.value; XCTFail("Cancelled read returned a result") }
        catch is CancellationError { }
        catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
    }
}
