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

    // A renewed review request must remain visible even if the user reviewed an
    // earlier commit. GitHub's review-requested search result is authoritative.
    func testFetchAwaitingReviewKeepsRenewedRequestsWithoutNPlusOneCalls() async throws {
        let mock = MockProcessRunner()
        mock.responder = { command in
            let args = command.arguments
            if args.first == "search" {
                return CommandResult(exitCode: 0, stdout: Fixtures.string("search-prs"), stderr: "")
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected command")
        }
        let service = GitHubService(runner: mock, ghPath: "/usr/bin/gh")
        let awaiting = try await service.fetchAwaitingReview(settings: AppSettings(), login: "kms-yeoshin")
        XCTAssertEqual(awaiting.map(\.number), [42, 7])
        XCTAssertEqual(mock.commands.count, 1)
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

        let batch = try! GitHubService.reviewCommand(
            gh: gh, repository: "fastlane-dev/beez", number: 42,
            comments: [comment], commitSha: "abc123", approve: true, body: "LGTM")
        XCTAssertEqual(batch.arguments, [
            "api", "repos/fastlane-dev/beez/pulls/42/reviews", "--input", "-"
        ])
        let payload = try! JSONSerialization.jsonObject(with: Data(batch.stdin!.utf8)) as! [String: Any]
        XCTAssertEqual(payload["commit_id"] as? String, "abc123")
        XCTAssertEqual(payload["event"] as? String, "APPROVE")
        XCTAssertEqual((payload["comments"] as? [[String: Any]])?.count, 1)
    }

    func testRequireCurrentHeadRejectsStaleReview() async throws {
        let mock = MockProcessRunner()
        mock.defaultResult = CommandResult(exitCode: 0, stdout: "new-sha\n", stderr: "")
        let service = GitHubService(runner: mock, ghPath: "/usr/bin/gh")
        let pr = PullRequest(
            repository: "fastlane-dev/beez", number: 42, title: "Title",
            author: "octocat", url: "https://example.com/pr/42")

        do {
            try await service.requireCurrentHead("old-sha", for: pr)
            XCTFail("Expected a stale review to be rejected")
        } catch let error as GitHubError {
            XCTAssertTrue(error.message.contains("changed"))
        }
    }

    func testRequireCurrentHeadAcceptsMatchingReview() async throws {
        let mock = MockProcessRunner()
        mock.defaultResult = CommandResult(exitCode: 0, stdout: "same-sha\n", stderr: "")
        let service = GitHubService(runner: mock, ghPath: "/usr/bin/gh")
        let pr = PullRequest(
            repository: "fastlane-dev/beez", number: 42, title: "Title",
            author: "octocat", url: "https://example.com/pr/42")

        try await service.requireCurrentHead("same-sha", for: pr)
    }

    func testReadRetriesAfterTransientFailure() async throws {
        let mock = MockProcessRunner()
        var attempts = 0
        mock.responder = { _ in
            attempts += 1
            return attempts == 1
                ? CommandResult(exitCode: 1, stdout: "", stderr: "temporary")
                : CommandResult(exitCode: 0, stdout: "sha\n", stderr: "")
        }
        let service = GitHubService(
            runner: mock,
            ghPath: "/usr/bin/gh",
            readRetryDelays: [0]
        )
        let pr = PullRequest(
            repository: "fastlane-dev/beez", number: 42, title: "Title",
            author: "octocat", url: "https://example.com/pr/42")

        XCTAssertEqual(try await service.fetchHeadSha(pr), "sha")
        XCTAssertEqual(attempts, 2)
    }

    func testDiffFailureIsNotReturnedAsEmptyDiff() async throws {
        let mock = MockProcessRunner()
        mock.responder = { command in
            if command.arguments.prefix(2) == ["pr", "view"] {
                return CommandResult(
                    exitCode: 0,
                    stdout: #"{"body":"","headRefOid":"sha","additions":1,"deletions":0}"#,
                    stderr: ""
                )
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "diff unavailable")
        }
        let service = GitHubService(
            runner: mock,
            ghPath: "/usr/bin/gh",
            readRetryDelays: []
        )
        let pr = PullRequest(
            repository: "fastlane-dev/beez", number: 42, title: "Title",
            author: "octocat", url: "https://example.com/pr/42")

        do {
            _ = try await service.fetchDetails(pr)
            XCTFail("Expected diff failure")
        } catch let error as GitHubError {
            XCTAssertTrue(error.message.contains("diff unavailable"))
        }
    }
}
