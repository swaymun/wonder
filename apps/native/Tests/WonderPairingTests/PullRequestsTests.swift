import XCTest
@testable import WonderPairing

// Contract: the app decodes the same pull request fixture the Mac's schema
// test validates, shows the pill only for a signed-in, understood, non-empty
// list, and opens only github.com pull request pages.
final class PullRequestsTests: XCTestCase {
    private func fixture() throws -> Data {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try Data(contentsOf: root.appendingPathComponent("packages/protocol/fixtures/project-pull-requests-v1.json"))
    }

    func testSharedFixtureDecodes() throws {
        let list = try JSONDecoder().decode(ThreadPullRequests.self, from: fixture())
        XCTAssertTrue(list.showsPill)
        XCTAssertEqual(list.pullRequests.map(\.number), [12, 9, 3])
        XCTAssertEqual(list.pullRequests.map(\.state), [.draft, .merged, .closed])
        XCTAssertEqual(list.pullRequests.map(\.checks.summary), ["2 of 5 checks running", "1 of 5 checks failed", nil])
        XCTAssertEqual(list.detail, "Some pull requests could not be loaded.")
    }

    func testPillHidesWhenGitHubIsUnavailableEmptyOrNewer() throws {
        let pr = ThreadPullRequests.PullRequest(number: 1, repository: "o/r", title: "T", state: .open,
            checks: .init(state: .passing, passed: 1), url: URL(string: "https://github.com/o/r/pull/1")!)
        XCTAssertTrue(ThreadPullRequests(available: true, pullRequests: [pr]).showsPill)
        XCTAssertFalse(ThreadPullRequests(available: false, pullRequests: [pr]).showsPill)
        XCTAssertFalse(ThreadPullRequests(available: true, pullRequests: []).showsPill)
        XCTAssertFalse(ThreadPullRequests(version: 2, available: true, pullRequests: [pr]).showsPill)
    }

    func testUnknownStatesAndForeignLinksAreContained() throws {
        let json = #"{"version":1,"available":true,"detail":null,"pullRequests":[{"number":1,"repository":"o/r","title":"A","state":"queued","checks":{"state":"later","passed":0,"failed":0,"pending":0},"url":"https://github.com/o/r/pull/1"},{"number":2,"repository":"o/r","title":"B","state":"open","checks":{"state":"none","passed":0,"failed":0,"pending":0},"url":"https://evil.example/o/r/pull/2"}]}"#
        let list = try JSONDecoder().decode(ThreadPullRequests.self, from: Data(json.utf8))
        XCTAssertEqual(list.pullRequests.map(\.number), [1])
        XCTAssertEqual(list.pullRequests.first?.state, .unknown)
        XCTAssertEqual(list.pullRequests.first?.checks.state, ThreadPullRequests.PullRequest.Checks.State.none)
    }

    func testPathEscapesTheConversation() throws {
        XCTAssertEqual(try ThreadPullRequests.path(conversationId: "a/b"), "/api/v1/project-conversations/a%2Fb/pull-requests")
        XCTAssertEqual(try ThreadPullRequests.path(conversationId: "c", refresh: true), "/api/v1/project-conversations/c/pull-requests?refresh=true")
        XCTAssertThrowsError(try ThreadPullRequests.path(conversationId: ""))
    }
}
