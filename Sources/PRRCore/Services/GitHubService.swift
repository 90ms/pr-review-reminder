import Foundation

public struct GitHubError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Extra per-PR details fetched on demand (not available from search).
public struct PRDetails: Sendable, Equatable, Codable {
    public let body: String
    public let headSha: String
    public let additions: Int
    public let deletions: Int
    public let diff: String

    public init(body: String, headSha: String, additions: Int, deletions: Int, diff: String) {
        self.body = body
        self.headSha = headSha
        self.additions = additions
        self.deletions = deletions
        self.diff = diff
    }
}

/// Wraps the `gh` CLI. Never authenticates or stores tokens itself.
public final class GitHubService: Sendable {
    private let runner: ProcessRunning
    private let gh: String
    private let readRetryDelays: [UInt64]

    public init(
        runner: ProcessRunning,
        ghPath: String,
        readRetryDelays: [UInt64] = [250_000_000, 500_000_000]
    ) {
        self.runner = runner
        self.gh = ghPath
        self.readRetryDelays = readRetryDelays
    }

    private func runRead(_ command: Command) async throws -> CommandResult {
        var lastResult: CommandResult?
        for attempt in 0...readRetryDelays.count {
            do {
                let result = try await runner.run(command)
                if result.succeeded { return result }
                lastResult = result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt == readRetryDelays.count { throw error }
            }
            guard attempt < readRetryDelays.count else { break }
            try await Task.sleep(nanoseconds: readRetryDelays[attempt])
        }
        if let lastResult { return lastResult }
        throw GitHubError("GitHub read failed without a result.")
    }

    // MARK: - Command builders (pure, testable)

    public static func currentLoginCommand(gh: String) -> Command {
        Command(executable: gh, arguments: ["api", "user", "--jq", ".login"])
    }

    public static func searchPRsCommand(gh: String, owner: String, repositories: [String], limit: Int = 100) -> Command {
        var args = ["search", "prs",
                    "--review-requested=@me",
                    "--state=open",
                    "--json", "number,title,url,updatedAt,author,repository",
                    "--limit", String(limit)]
        if repositories.isEmpty {
            args += ["--owner", owner]
        } else {
            for repo in repositories {
                let full = repo.contains("/") ? repo : "\(owner)/\(repo)"
                args += ["--repo", full]
            }
        }
        return Command(executable: gh, arguments: args)
    }

    public static func reviewsCommand(gh: String, repository: String, number: Int) -> Command {
        Command(executable: gh, arguments: ["api", "repos/\(repository)/pulls/\(number)/reviews", "--paginate"])
    }

    public static func detailsCommand(gh: String, repository: String, number: Int) -> Command {
        Command(executable: gh, arguments: ["pr", "view", String(number), "-R", repository,
                                            "--json", "body,headRefOid,additions,deletions"])
    }

    public static func diffCommand(gh: String, repository: String, number: Int) -> Command {
        Command(executable: gh, arguments: ["pr", "diff", String(number), "-R", repository])
    }

    public static func headShaCommand(gh: String, repository: String, number: Int) -> Command {
        Command(executable: gh, arguments: ["pr", "view", String(number), "-R", repository, "--json", "headRefOid", "--jq", ".headRefOid"])
    }

    public static func inlineCommentCommand(gh: String, repository: String, number: Int,
                                            comment: InlineComment, commitSha: String) -> Command {
        Command(executable: gh, arguments: [
            "api", "repos/\(repository)/pulls/\(number)/comments",
            "-f", "body=\(comment.body)",
            "-f", "path=\(comment.path)",
            "-F", "line=\(comment.line)",
            "-f", "side=\(comment.side)",
            "-f", "commit_id=\(commitSha)"
        ])
    }

    public static func reviewCommand(
        gh: String,
        repository: String,
        number: Int,
        comments: [InlineComment],
        commitSha: String,
        approve: Bool,
        body: String? = nil
    ) throws -> Command {
        struct Payload: Encodable {
            struct Comment: Encodable {
                let path: String
                let line: Int
                let side: String
                let body: String
            }
            let commit_id: String
            let event: String
            let body: String
            let comments: [Comment]
        }
        let payload = Payload(
            commit_id: commitSha,
            event: approve ? "APPROVE" : "COMMENT",
            body: body ?? "",
            comments: comments.map {
                Payload.Comment(path: $0.path, line: $0.line, side: $0.side, body: $0.body)
            }
        )
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw GitHubError("Could not encode the review payload.")
        }
        return Command(
            executable: gh,
            arguments: ["api", "repos/\(repository)/pulls/\(number)/reviews", "--input", "-"],
            stdin: json
        )
    }

    public static func summaryCommentCommand(gh: String, repository: String, number: Int, body: String) -> Command {
        Command(executable: gh, arguments: ["pr", "comment", String(number), "-R", repository, "--body", body])
    }

    public static func approveCommand(gh: String, repository: String, number: Int, body: String?) -> Command {
        var args = ["pr", "review", String(number), "-R", repository, "--approve"]
        if let body, !body.isEmpty { args += ["--body", body] }
        return Command(executable: gh, arguments: args)
    }

    // MARK: - Parsers (pure, testable)

    private struct SearchDTO: Decodable {
        struct Author: Decodable { let login: String }
        struct Repo: Decodable { let nameWithOwner: String }
        let number: Int
        let title: String
        let url: String
        let updatedAt: String?
        let author: Author?
        let repository: Repo
    }

    public static func parsePullRequests(_ data: Data) throws -> [PullRequest] {
        let dtos = try JSONDecoder().decode([SearchDTO].self, from: data)
        let iso = ISO8601DateFormatter()
        return dtos.map { dto in
            PullRequest(
                repository: dto.repository.nameWithOwner,
                number: dto.number,
                title: dto.title,
                author: dto.author?.login ?? "unknown",
                url: dto.url,
                updatedAt: dto.updatedAt.flatMap { iso.date(from: $0) }
            )
        }
    }

    private struct ReviewDTO: Decodable {
        struct User: Decodable { let login: String }
        let user: User?
    }

    /// True if `login` has already submitted a review among `data`.
    public static func hasReviewed(_ data: Data, login: String) throws -> Bool {
        let reviews = try JSONDecoder().decode([ReviewDTO].self, from: data)
        let target = login.lowercased()
        return reviews.contains { $0.user?.login.lowercased() == target }
    }

    private struct DetailsDTO: Decodable {
        let body: String?
        let headRefOid: String
        let additions: Int
        let deletions: Int
    }

    // MARK: - Async operations

    public func currentLogin() async throws -> String {
        let result = try await runRead(Self.currentLoginCommand(gh: gh))
        guard result.succeeded else {
            throw GitHubError("gh not authenticated: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let login = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else { throw GitHubError("could not determine gh login") }
        return login
    }

    /// Fetch open PRs where GitHub currently considers the user a requested
    /// reviewer. Do not filter this list using historical reviews: GitHub may
    /// request another review after new commits, and an older review must not
    /// hide that renewed request.
    public func fetchAwaitingReview(settings: AppSettings, login: String) async throws -> [PullRequest] {
        let search = try await runRead(Self.searchPRsCommand(gh: gh, owner: settings.owner, repositories: settings.repositories))
        guard search.succeeded else {
            throw GitHubError("gh search failed: \(search.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return try Self.parsePullRequests(Data(search.stdout.utf8))
    }

    /// Fetches only the head commit SHA (cheap, no AI cost) for cache lookups.
    public func fetchHeadSha(_ pr: PullRequest) async throws -> String {
        let result = try await runRead(Self.headShaCommand(gh: gh, repository: pr.repository, number: pr.number))
        guard result.succeeded else {
            throw GitHubError("gh pr view failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prevent publishing an analysis against a different revision than the one
    /// the user previewed.
    public func requireCurrentHead(_ expectedHeadSha: String, for pr: PullRequest) async throws {
        let current = try await fetchHeadSha(pr)
        guard current == expectedHeadSha else {
            throw GitHubError("This pull request changed after the review was generated. Run the review again before publishing.")
        }
    }

    public func fetchDetails(_ pr: PullRequest) async throws -> PRDetails {
        let meta = try await runRead(Self.detailsCommand(gh: gh, repository: pr.repository, number: pr.number))
        guard meta.succeeded else {
            throw GitHubError("gh pr view failed: \(meta.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let dto = try JSONDecoder().decode(DetailsDTO.self, from: Data(meta.stdout.utf8))
        let diff = try await runRead(Self.diffCommand(gh: gh, repository: pr.repository, number: pr.number))
        guard diff.succeeded else {
            throw GitHubError("gh pr diff failed: \(diff.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return PRDetails(
            body: dto.body ?? "",
            headSha: dto.headRefOid,
            additions: dto.additions,
            deletions: dto.deletions,
            diff: diff.stdout
        )
    }

    // MARK: - Publishing (only invoked by explicit user action)

    @discardableResult
    public func postInlineComment(_ comment: InlineComment, on pr: PullRequest, commitSha: String) async throws -> CommandResult {
        let result = try await runner.run(Self.inlineCommentCommand(gh: gh, repository: pr.repository, number: pr.number, comment: comment, commitSha: commitSha))
        guard result.succeeded else { throw GitHubError("post inline comment failed: \(result.stderr)") }
        return result
    }

    /// Posts all inline comments as one GitHub review, avoiding a partially
    /// published set when one comment is invalid.
    @discardableResult
    public func postReview(
        comments: [InlineComment],
        on pr: PullRequest,
        commitSha: String,
        approve: Bool = false,
        body: String? = nil
    ) async throws -> CommandResult {
        let command = try Self.reviewCommand(
            gh: gh, repository: pr.repository, number: pr.number,
            comments: comments, commitSha: commitSha, approve: approve, body: body)
        let result = try await runner.run(command)
        guard result.succeeded else {
            throw GitHubError("post review failed: \(result.stderr)")
        }
        return result
    }

    @discardableResult
    public func postSummaryComment(_ body: String, on pr: PullRequest) async throws -> CommandResult {
        let result = try await runner.run(Self.summaryCommentCommand(gh: gh, repository: pr.repository, number: pr.number, body: body))
        guard result.succeeded else { throw GitHubError("post comment failed: \(result.stderr)") }
        return result
    }

    @discardableResult
    public func createIssue(repository: String, title: String, body: String) async throws -> CommandResult {
        let result = try await runner.run(FeedbackService.createIssueCommand(gh: gh, repository: repository, title: title, body: body))
        guard result.succeeded else { throw GitHubError("create issue failed: \(result.stderr)") }
        return result
    }

    @discardableResult
    public func approve(_ pr: PullRequest, body: String?) async throws -> CommandResult {
        let result = try await runner.run(Self.approveCommand(gh: gh, repository: pr.repository, number: pr.number, body: body))
        guard result.succeeded else { throw GitHubError("approve failed: \(result.stderr)") }
        return result
    }
}
