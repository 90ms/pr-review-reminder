import XCTest
@testable import PRRCore

final class ReviewRecordTests: XCTestCase {
    func testPullRequestPreservesLiveIdentityWithoutPersistedDiff() {
        let record = ReviewRecord(
            repository: "owner/repo",
            number: 42,
            title: "Current review",
            author: "octocat",
            url: "https://github.com/owner/repo/pull/42",
            headSha: "stale-head",
            tool: .codex,
            reviewedAt: Date(),
            analysis: Analysis(summary: "Stored analysis"),
            usage: nil,
            details: PRDetails(
                body: "stale body",
                headSha: "stale-head",
                additions: 1,
                deletions: 2,
                diff: "stale diff"
            )
        )

        let pr = record.pullRequest
        XCTAssertEqual(pr.repository, "owner/repo")
        XCTAssertEqual(pr.number, 42)
        XCTAssertEqual(pr.title, "Current review")
        XCTAssertEqual(pr.author, "octocat")
        XCTAssertEqual(pr.url, "https://github.com/owner/repo/pull/42")
        XCTAssertEqual(pr.additions, 0)
        XCTAssertEqual(pr.deletions, 0)
    }
}
