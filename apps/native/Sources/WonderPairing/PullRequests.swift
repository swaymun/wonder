import Foundation

/// Pull requests a Project thread worked with, as the Mac reads them through
/// its own GitHub CLI sign-in. No GitHub credential reaches the phone.
public struct ThreadPullRequests: Decodable, Equatable, Sendable {
    public static let supportedVersion = 1

    public struct PullRequest: Decodable, Equatable, Identifiable, Sendable {
        public enum State: String, Decodable, Sendable {
            case open, draft, merged, closed, unknown
            public init(from decoder: Decoder) throws {
                self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
            public var title: String {
                switch self {
                case .open: "Open"
                case .draft: "Draft"
                case .merged: "Merged"
                case .closed: "Closed"
                case .unknown: "Unknown"
                }
            }
        }

        public struct Checks: Decodable, Equatable, Sendable {
            public enum State: String, Decodable, Sendable {
                case passing, failing, pending, none
                public init(from decoder: Decoder) throws {
                    self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none
                }
            }
            public var state: State
            public var passed: Int
            public var failed: Int
            public var pending: Int
            public init(state: State, passed: Int = 0, failed: Int = 0, pending: Int = 0) {
                self.state = state; self.passed = passed; self.failed = failed; self.pending = pending
            }

            /// "2 of 5 checks failed", or nil when the pull request has no checks.
            public var summary: String? {
                let total = passed + failed + pending
                guard total > 0 else { return nil }
                let noun = total == 1 ? "check" : "checks"
                switch state {
                case .failing: return "\(failed) of \(total) \(noun) failed"
                case .pending: return "\(pending) of \(total) \(noun) running"
                case .passing: return total == 1 ? "Check passed" : "All \(total) checks passed"
                case .none: return nil
                }
            }
        }

        public var number: Int
        public var repository: String
        public var title: String
        public var state: State
        public var checks: Checks
        public var url: URL
        public var id: String { url.absoluteString }

        public init(number: Int, repository: String, title: String, state: State, checks: Checks, url: URL) {
            self.number = number; self.repository = repository; self.title = title
            self.state = state; self.checks = checks; self.url = url
        }
    }

    public var version: Int
    public var available: Bool
    public var detail: String?
    public var pullRequests: [PullRequest]

    public init(version: Int = supportedVersion, available: Bool, detail: String? = nil, pullRequests: [PullRequest]) {
        self.version = version; self.available = available; self.detail = detail; self.pullRequests = pullRequests
    }

    private enum CodingKeys: String, CodingKey { case version, available, detail, pullRequests }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        available = try container.decode(Bool.self, forKey: .available)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        // Only github.com pull request pages open from the sheet.
        pullRequests = try container.decode([PullRequest].self, forKey: .pullRequests).filter {
            $0.url.scheme == "https" && $0.url.host == "github.com" && $0.url.path.contains("/pull/")
        }
    }

    /// Whether the pill appears: GitHub is signed in on the Mac, the response is
    /// a version this app understands, and the thread has pull requests.
    public var showsPill: Bool {
        version == Self.supportedVersion && available && !pullRequests.isEmpty
    }

    public static func path(conversationId: String, refresh: Bool = false) throws -> String {
        guard !conversationId.isEmpty,
              let escaped = conversationId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw PairingFailure.invalidLink
        }
        return "/api/v1/project-conversations/\(escaped)/pull-requests" + (refresh ? "?refresh=true" : "")
    }
}
