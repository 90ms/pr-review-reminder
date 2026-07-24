import XCTest
@testable import PRRCore

final class GitHubServiceTests: XCTestCase {
    // AC2 — parse gh search JSON into PullRequest values.
    func testParsePullRequests() throws {
        let prs = try GitHubService.parsePullRequests(Fixtures.data("search-prs"))
        XCTAssertEqual(prs.count, 2)
        XCTAssertEqual(prs[0].repository, "fastlane-dev/beez")
        XCTAssertEqual(prs[0].number, 42)
        XCTAssertEqual(prs[0].title, "Add retry to uploader")
        XCTAssertEqual(prs[0].author, "octocat")
        XCTAssertEqual(prs[0].owner, "fastlane-dev")
        XCTAssertNotNil(prs[0].updatedAt)
        XCTAssertEqual(prs[1].repository, "fastlane-dev/webapp")
    }

    // AC3 — determine whether the current user has reviewed.
    func testHasReviewed() throws {
        XCTAssertTrue(try GitHubService.hasReviewed(Fixtures.data("reviews-reviewed"), login: "kms-yeoshin"))
        XCTAssertTrue(try GitHubService.hasReviewed(Fixtures.data("reviews-reviewed"), login: "KMS-Yeoshin")) // case-insensitive
        XCTAssertFalse(try GitHubService.hasReviewed(Fixtures.data("reviews-not-reviewed"), login: "kms-yeoshin"))
    }

    // AC2 — end-to-end fetch filters out already-reviewed PRs using the mock runner.
    func testFetchAwaitingReviewFiltersReviewed() async throws {
        let mock = MockProcessRunner()
        mock.responder = { command in
            let args = command.arguments
            if args.first == "search" {
                return CommandResult(exitCode: 0, stdout: Fixtures.string("search-prs"), stderr: "")
            }
            // reviews endpoint: PR 42 already reviewed, PR 7 not.
            if let api = args.first(where: { $0.contains("/pulls/") }) {
                let json = api.contains("/42/") ? Fixtures.string("reviews-reviewed")
                                                : Fixtures.string("reviews-not-reviewed")
                return CommandResult(exitCode: 0, stdout: json, stderr: "")
            }
            return CommandResult(exitCode: 0, stdout: "[]", stderr: "")
        }
        let service = GitHubService(runner: mock, ghPath: "/usr/bin/gh")
        let awaiting = try await service.fetchAwaitingReview(settings: AppSettings(), login: "kms-yeoshin")
        XCTAssertEqual(awaiting.map(\.number), [7])
    }

    // AC7 — publishing commands are constructed correctly (no real posting).
    func testCommandConstruction() {
        let gh = "/usr/bin/gh"
        let search = GitHubService.searchPRsCommand(gh: gh, owner: "fastlane-dev", repositories: [])
        XCTAssertTrue(search.arguments.contains("--review-requested=@me"))
        XCTAssertTrue(search.arguments.contains("--owner"))
        XCTAssertTrue(search.arguments.contains("fastlane-dev"))

        let scoped = GitHubService.searchPRsCommand(gh: gh, owner: "fastlane-dev", repositories: ["beez", "acme/web"])
        XCTAssertTrue(scoped.arguments.contains("fastlane-dev/beez"))
        XCTAssertTrue(scoped.arguments.contains("acme/web"))
        XCTAssertFalse(scoped.arguments.contains("--owner"))

        let comment = InlineComment(path: "src/a.swift", line: 10, side: "RIGHT", body: "nil check")
        let inline = GitHubService.inlineCommentCommand(gh: gh, repository: "fastlane-dev/beez", number: 42, comment: comment, commitSha: "abc123")
        XCTAssertEqual(inline.arguments.first, "api")
        XCTAssertTrue(inline.arguments.contains("repos/fastlane-dev/beez/pulls/42/comments"))
        XCTAssertTrue(inline.arguments.contains("path=src/a.swift"))
        XCTAssertTrue(inline.arguments.contains("line=10"))
        XCTAssertTrue(inline.arguments.contains("commit_id=abc123"))

        let approve = GitHubService.approveCommand(gh: gh, repository: "fastlane-dev/beez", number: 42, body: "LGTM")
        XCTAssertTrue(approve.arguments.contains("--approve"))
        XCTAssertTrue(approve.arguments.contains("LGTM"))

        let approveNoBody = GitHubService.approveCommand(gh: gh, repository: "fastlane-dev/beez", number: 42, body: nil)
        XCTAssertFalse(approveNoBody.arguments.contains("--body"))
    }
}
