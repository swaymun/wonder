import Foundation
import CryptoKit

public enum GitHubReviewFailure: LocalizedError {
    case unsupported, scopeChanged, invalidResponse, oversized, response(Int)
    public var errorDescription: String? {
        switch self {
        case .unsupported: "Update Wonder on your Mac to review GitHub pull requests."
        case .scopeChanged: "This connection or Project folder changed. Reopen the review."
        case .invalidResponse: "This review was incomplete or changed. Reload it before continuing."
        case .oversized: "This review exceeds the preview size limit. Open it on GitHub."
        case .response(let status):
            switch status {
            case 401: "Reconnect your device before reviewing GitHub."
            case 403: "GitHub review access is unavailable. Check the connection and repository on your Mac."
            case 404: "This Project or review is no longer available."
            case 409: "The folder, account, repository or review connection changed. Reload before continuing."
            case 422: "Choose a Project folder that is a GitHub repository with an origin remote."
            case 429: "Another review is loading or GitHub is limiting requests. Try again shortly."
            default: "GitHub review could not be loaded. Check GitHub CLI sign-in on your Mac and try again."
            }
        }
    }
}

/// Folder identity is supplied by the host, never inferred from a Files alias.
public struct GitHubReviewScope: Sendable, Equatable {
    public let projectId: String
    public let rootId: String
    public let rootsRevision: Int64
    public init(project: ProjectSummary, folderId: String, hostVersion: Int?) throws {
        guard hostVersion == 1 else { throw GitHubReviewFailure.unsupported }
        guard project.isIncluded, project.folders.contains(where: { $0.id == folderId }),
              project.rootsRevision > 0,
              Self.validID(project.id), Self.validID(folderId) else { throw GitHubReviewFailure.scopeChanged }
        projectId = project.id; rootId = folderId; rootsRevision = Int64(project.rootsRevision)
    }
    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && value != "." && value != ".." &&
        !value.contains("/") && !value.contains("\\") && !value.contains(where: { $0.isNewline }) &&
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    var path: String {
        "/api/v1/projects/" + projectId.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! +
        "/github-review/" + rootId.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    }
    // The host constructs the signed target from decoded route parameters.
    var target: String { "/api/v1/projects/\(projectId)/github-review/\(rootId)" }
}

public struct GitHubReviewStatus: Codable, Sendable {
    public let hostInstallationId: String
    public let projectId: String
    public let rootId: String
    public let rootsRevision: Int64
    public let authorizationRevision: Int64
    public let connected: Bool
    public let repository: String?
    public let repositoryId: Int64?
    public let accountId: Int64?
}
public struct GitHubConnectionIdentity: Codable, Sendable {
    public let accountId: Int64
    public let accountLogin: String
    public let repositoryId: Int64
    public let repository: String
}
public struct GitHubReviewPreparation: Codable, Sendable {
    public let hostInstallationId: String
    public let projectId: String
    public let rootId: String
    public let rootsRevision: Int64
    public let authorizationRevision: Int64
    public let identity: GitHubConnectionIdentity
}
public struct GitHubPullRequestIdentity: Codable, Sendable {
    public let apiHost: String
    public let repositoryId: Int64
    public let repository: String
    public let headRepositoryId: Int64
    public let headRepository: String
    public let number: UInt64
    public let base: String
    public let head: String
}
public enum GitHubPatchState: String, Codable, Sendable {
    case suppliedCountsMatch, empty, unavailable, partial, oversized
}
public enum GitHubFileStatus: String, Codable, Sendable {
    case added, removed, modified, renamed, copied, changed, unchanged
}
public struct GitHubReviewFile: Codable, Identifiable, Sendable {
    public let path: String
    public let previousPath: String?
    public let sha: String
    public let status: GitHubFileStatus
    public let additions: UInt64
    public let deletions: UInt64
    public let patchState: GitHubPatchState
    public let patch: String?
    public var id: String { path }
}
public struct GitHubPullRequestSnapshot: Codable, Sendable {
    public let projectId: String
    public let rootId: String
    public let rootsRevision: Int64
    public let accountId: Int64
    public let identity: GitHubPullRequestIdentity
    public let mergeBase: String
    public let title: String
    public let state: String
    public let fetchedAt: String
    public let enumerationComplete: Bool
    public let files: [GitHubReviewFile]
}
private struct GitHubReviewResponse: Decodable, Sendable {
    let hostInstallationId: String
    let authorizationRevision: Int64
    let snapshot: GitHubPullRequestSnapshot
}

/// One immutable pairing/folder scope. Owners must discard its results when
/// `matches` becomes false, and cancel their task on navigation/background.
/// Nothing here starts model work, grants local-file authority or retries consent.
public actor GitHubReviewClient {
    public nonisolated let scope: GitHubReviewScope
    private let api: PairingAPI
    private let connection: SavedConnection
    private let signer: SigningIdentity
    public init(api: PairingAPI, connection: SavedConnection, scope: GitHubReviewScope, signer: SigningIdentity) throws {
        guard !connection.requiresPairing else { throw GitHubReviewFailure.scopeChanged }
        _ = try PairingLink.origin(connection.origin)
        self.api = api; self.connection = connection; self.scope = scope; self.signer = signer
    }
    public nonisolated func matches(connection current: SavedConnection?, scope currentScope: GitHubReviewScope) -> Bool {
        guard let current, !current.requiresPairing, currentScope == scope,
              current.credential.expiresAtMs.map({ $0 > UInt64(Date().timeIntervalSince1970 * 1000) }) ?? true
        else { return false }
        return current.origin == connection.origin &&
            current.credential.hostInstallationId == connection.credential.hostInstallationId &&
            current.credential.deviceId == connection.credential.deviceId &&
            current.credential.sessionToken == connection.credential.sessionToken &&
            current.credential.csrfToken == connection.credential.csrfToken
    }
    private func check(host: String, project: String, root: String, revision: Int64) throws {
        guard host == connection.credential.hostInstallationId, project == scope.projectId,
              root == scope.rootId, revision == scope.rootsRevision else { throw GitHubReviewFailure.scopeChanged }
    }
    private func check(_ status: GitHubReviewStatus) throws {
        try check(host: status.hostInstallationId, project: status.projectId, root: status.rootId, revision: status.rootsRevision)
        guard status.authorizationRevision >= 0 else { throw GitHubReviewFailure.invalidResponse }
        if status.connected {
            guard let repo = status.repository, validRepository(repo),
                  let repoID = status.repositoryId, repoID > 0,
                  let accountID = status.accountId, accountID > 0 else { throw GitHubReviewFailure.invalidResponse }
        } else if status.repository != nil || status.repositoryId != nil || status.accountId != nil {
            throw GitHubReviewFailure.invalidResponse
        }
    }
    private func check(_ preparation: GitHubReviewPreparation) throws {
        try check(host: preparation.hostInstallationId, project: preparation.projectId,
                  root: preparation.rootId, revision: preparation.rootsRevision)
        guard preparation.authorizationRevision >= 0, preparation.identity.accountId > 0,
              preparation.identity.repositoryId > 0, validRepository(preparation.identity.repository),
              !preparation.identity.accountLogin.isEmpty, preparation.identity.accountLogin.utf8.count <= 100,
              !preparation.identity.accountLogin.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw GitHubReviewFailure.invalidResponse }
    }
    public func status() async throws -> GitHubReviewStatus {
        let result: GitHubReviewStatus = try await api.githubReviewRequest(scope.path, connection: connection)
        try check(result); return result
    }
    /// Called only after the owner chooses Connect. This creates no grant.
    public func prepare() async throws -> GitHubReviewPreparation {
        let result: GitHubReviewPreparation = try await api.githubReviewRequest(scope.path + "/prepare", connection: connection, method: "POST")
        try check(result); return result
    }
    /// Called only after the owner confirms read access to the displayed identity.
    public func authorize(_ preparation: GitHubReviewPreparation) async throws {
        try check(preparation)
        let identity = preparation.identity
        let body = try await signedBody(action: "github.review.authorize", revision: preparation.authorizationRevision,
            semantic: [preparation.rootsRevision, preparation.authorizationRevision, identity.accountId, identity.repositoryId, identity.repository, true],
            fields: ["rootsRevision": preparation.rootsRevision, "authorizationRevision": preparation.authorizationRevision,
                     "accountId": identity.accountId, "repositoryId": identity.repositoryId,
                     "repository": identity.repository, "confirmReadAccess": true])
        let _: EmptyGitHubResponse = try await api.githubReviewRequest(scope.path, connection: connection, method: "PUT", body: body)
    }
    public func disconnect(_ status: GitHubReviewStatus) async throws {
        try check(status)
        let body = try await signedBody(action: "github.review.revoke", revision: status.authorizationRevision,
                                       semantic: [status.authorizationRevision], fields: ["authorizationRevision": status.authorizationRevision])
        let _: EmptyGitHubResponse = try await api.githubReviewRequest(scope.path, connection: connection, method: "DELETE", body: body)
    }
    private func signedBody(action: String, revision: Int64, semantic: [Any], fields: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        let nonce = UUID().uuidString
        let issuedAt = UInt64(Date().timeIntervalSince1970 * 1000)
        let canonical = try JSONSerialization.data(withJSONObject: semantic, options: [.withoutEscapingSlashes, .sortedKeys])
        let hash = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        let transcript = Data(["wonder-action-v1", action, scope.target, hash, nonce,
            connection.credential.csrfToken, connection.credential.deviceId, connection.credential.hostInstallationId,
            String(issuedAt), String(revision)].joined(separator: "\n").utf8)
        let signature = try await signer.sign(transcript)
        try Task.checkCancellation()
        var body = fields
        body["actionNonce"] = nonce; body["issuedAtMs"] = issuedAt; body["signature"] = signature
        return try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes, .sortedKeys])
    }
    public func snapshot(number: UInt64, connected status: GitHubReviewStatus) async throws -> GitHubPullRequestSnapshot {
        try check(status)
        guard status.connected, number > 0 else { throw GitHubReviewFailure.scopeChanged }
        let response: GitHubReviewResponse = try await api.githubReviewRequest(scope.path + "/pulls/\(number)",
            connection: connection, snapshot: true)
        guard response.hostInstallationId == connection.credential.hostInstallationId,
              response.authorizationRevision == status.authorizationRevision else { throw GitHubReviewFailure.scopeChanged }
        let result = response.snapshot
        guard result.projectId == scope.projectId, result.rootId == scope.rootId,
              result.rootsRevision == scope.rootsRevision, result.accountId == status.accountId,
              result.identity.repositoryId == status.repositoryId, result.identity.repository == status.repository,
              result.identity.number == number else { throw GitHubReviewFailure.scopeChanged }
        try result.validate()
        try Task.checkCancellation()
        return result
    }
}
private struct EmptyGitHubResponse: Decodable, Sendable {}

private func validRepository(_ value: String) -> Bool {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 2 && parts.allSatisfy { part in
        !part.isEmpty && part.utf8.count <= 100 && part != "." && part != ".." &&
        part.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }
    }
}
private func validSHA(_ value: String) -> Bool { value.utf8.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }
private func validReviewPath(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 4096 && !value.hasPrefix("/") && !value.contains("\\") &&
    !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
    value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}
private extension GitHubPullRequestSnapshot {
    func validate() throws {
        guard identity.apiHost == "api.github.com", identity.headRepositoryId > 0,
              validRepository(identity.headRepository), validSHA(identity.base), validSHA(identity.head), validSHA(mergeBase),
              enumerationComplete, files.count <= 3000, Set(files.map(\.path)).count == files.count,
              ["open", "closed"].contains(state), title.utf8.count <= 1024,
              !fetchedAt.isEmpty, fetchedAt.utf8.count <= 64 else { throw GitHubReviewFailure.invalidResponse }
        var patchBytes = 0
        for file in files {
            guard validReviewPath(file.path), validSHA(file.sha),
                  file.previousPath.map(validReviewPath) ?? true,
                  ![.renamed, .copied].contains(file.status) || file.previousPath != nil else { throw GitHubReviewFailure.invalidResponse }
            switch file.patchState {
            case .suppliedCountsMatch:
                guard let patch = file.patch, !patch.isEmpty, patch.utf8.count <= 1024 * 1024 else { throw GitHubReviewFailure.invalidResponse }
            case .empty:
                guard file.patch == "", file.additions == 0, file.deletions == 0 else { throw GitHubReviewFailure.invalidResponse }
            case .unavailable, .partial, .oversized:
                guard file.patch == nil else { throw GitHubReviewFailure.invalidResponse }
            }
            patchBytes += file.patch?.utf8.count ?? 0
            guard patchBytes <= 8 * 1024 * 1024 else { throw GitHubReviewFailure.oversized }
        }
    }
}
