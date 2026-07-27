import Foundation

final class GitHubTransportPreference: @unchecked Sendable {
    static let shared = GitHubTransportPreference()

    private let lock = NSLock()
    private var requiresHTTP1 = false

    var shouldUseHTTP1: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requiresHTTP1
    }

    func preferHTTP1() {
        lock.lock()
        requiresHTTP1 = true
        lock.unlock()
    }
}

public struct GitHubError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public let attempts: Int
    public let isRateLimited: Bool
    public init(_ message: String, attempts: Int = 1, isRateLimited: Bool = false) {
        self.message = message
        self.attempts = attempts
        self.isRateLimited = isRateLimited
    }
    public var description: String { message }
}

public struct GitHubFetchResult: Sendable, Equatable {
    public let pullRequests: [PullRequest]
    public let retryCount: Int
    public let reachedSearchLimit: Bool
}

public struct GitHubFeedbackFetchResult: Sendable, Equatable {
    public let feedbackItems: [PRFeedbackItem]
    public let retryCount: Int
    public let reachedSearchLimit: Bool
}

public struct GitHubIssueCreationResult: Sendable, Equatable {
    public let commandResult: CommandResult
    public let omittedLabels: [String]

    public init(commandResult: CommandResult, omittedLabels: [String] = []) {
        self.commandResult = commandResult
        self.omittedLabels = omittedLabels
    }
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
    public static let loginTimeout: TimeInterval = 15
    public static let readTimeout: TimeInterval = 60
    public static let longReadTimeout: TimeInterval = 120
    public static let writeTimeout: TimeInterval = 120

    private let runner: ProcessRunning
    private let gh: String
    private let readRetryDelays: [UInt64]
    private let transportPreference: GitHubTransportPreference

    public init(
        runner: ProcessRunning,
        ghPath: String,
        readRetryDelays: [UInt64] = [250_000_000, 500_000_000]
    ) {
        self.runner = runner
        self.gh = ghPath
        self.readRetryDelays = readRetryDelays
        self.transportPreference = .shared
    }

    init(
        runner: ProcessRunning,
        ghPath: String,
        readRetryDelays: [UInt64] = [250_000_000, 500_000_000],
        transportPreference: GitHubTransportPreference
    ) {
        self.runner = runner
        self.gh = ghPath
        self.readRetryDelays = readRetryDelays
        self.transportPreference = transportPreference
    }

    private struct ReadExecution {
        let result: CommandResult
        let attempts: Int
    }

    private func commandForPreferredTransport(_ command: Command) -> Command {
        transportPreference.shouldUseHTTP1
            ? Self.http1FallbackCommand(command)
            : command
    }

    private func runOnce(_ command: Command) async throws -> CommandResult {
        try await runner.run(commandForPreferredTransport(command))
    }

    private func runRead(_ command: Command) async throws -> ReadExecution {
        var lastResult: CommandResult?
        var lastError: Error?
        var attempts = 0
        var retryIndex = 0
        var usingHTTP1Fallback = transportPreference.shouldUseHTTP1
        var currentCommand = commandForPreferredTransport(command)

        while true {
            attempts += 1
            do {
                let result = try await runner.run(currentCommand)
                if result.succeeded {
                    return ReadExecution(result: result, attempts: attempts)
                }
                lastResult = result
                lastError = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ProcessRunnerError {
                lastResult = nil
                lastError = error
                if case .timedOut = error, !usingHTTP1Fallback {
                    // Some VPN and network-filter combinations stall gh's Go
                    // HTTP/2 client even though the same API works over
                    // HTTP/1.1. Preserve the full process environment and retry
                    // immediately with HTTP/2 disabled.
                    transportPreference.preferHTTP1()
                    currentCommand = Self.http1FallbackCommand(command)
                    usingHTTP1Fallback = true
                    continue
                }
            } catch {
                lastResult = nil
                lastError = error
            }

            guard retryIndex < readRetryDelays.count else { break }
            try await Task.sleep(nanoseconds: readRetryDelays[retryIndex])
            retryIndex += 1
        }

        if let lastResult {
            let message = lastResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubError(
                message.isEmpty ? "GitHub read failed." : message,
                attempts: attempts,
                isRateLimited: Self.isRateLimitMessage(message)
            )
        }
        if let lastError {
            throw lastError
        }
        throw GitHubError("GitHub read failed without a result.")
    }

    static func http1FallbackCommand(
        _ command: Command,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Command {
        var environment = command.environment ?? processEnvironment
        var goDebug = environment["GODEBUG", default: ""]
            .split(separator: ",")
            .map(String.init)
            .filter { !$0.hasPrefix("http2client=") }
        goDebug.append("http2client=0")
        environment["GODEBUG"] = goDebug.joined(separator: ",")

        return Command(
            executable: command.executable,
            arguments: command.arguments,
            stdin: command.stdin,
            timeout: command.timeout,
            workingDirectory: command.workingDirectory,
            environment: environment
        )
    }

    public static func isRateLimitMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("rate limit") || lower.contains("api rate")
    }

    public static func isLabelFailureMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        guard lower.contains("label") else { return false }
        return lower.contains("not found")
            || lower.contains("does not exist")
            || lower.contains("could not add")
            || lower.contains("could not resolve")
            || lower.contains("unprocessable")
    }

    // MARK: - Command builders (pure, testable)

    public static func currentLoginCommand(gh: String) -> Command {
        Command(
            executable: gh,
            arguments: ["api", "user", "--hostname", "github.com", "--jq", ".login"],
            timeout: loginTimeout
        )
    }

    /// `gh search` paginates internally up to this limit. GitHub Search exposes
    /// at most 1,000 results for a query.
    public static func searchPRsCommand(gh: String, owner: String, repositories: [String], limit: Int = 1_000) -> Command {
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
        return Command(executable: gh, arguments: args, timeout: longReadTimeout)
    }

    public static func searchAuthoredPRsCommand(gh: String, owner: String, repositories: [String], limit: Int = 1_000) -> Command {
        var args = ["search", "prs",
                    "--author=@me",
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
        return Command(executable: gh, arguments: args, timeout: longReadTimeout)
    }

    public static func reviewsCommand(gh: String, repository: String, number: Int) -> Command {
        Command(
            executable: gh,
            arguments: ["api", "repos/\(repository)/pulls/\(number)/reviews", "--paginate"],
            timeout: longReadTimeout
        )
    }

    public static func feedbackDetailsCommand(gh: String, repository: String, number: Int) -> Command {
        Command(executable: gh, arguments: [
            "pr", "view", String(number), "-R", repository,
            "--json", "reviewDecision,reviews"
        ], timeout: readTimeout)
    }

    public static func detailsCommand(gh: String, repository: String, number: Int) -> Command {
        Command(executable: gh, arguments: ["pr", "view", String(number), "-R", repository,
                                            "--json", "body,headRefOid,additions,deletions"],
                timeout: readTimeout)
    }

    public static func diffCommand(gh: String, repository: String, number: Int) -> Command {
        Command(
            executable: gh,
            arguments: ["pr", "diff", String(number), "-R", repository],
            timeout: longReadTimeout
        )
    }

    public static func headShaCommand(gh: String, repository: String, number: Int) -> Command {
        Command(
            executable: gh,
            arguments: ["pr", "view", String(number), "-R", repository, "--json", "headRefOid", "--jq", ".headRefOid"],
            timeout: readTimeout
        )
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
        ], timeout: writeTimeout)
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
            stdin: json,
            timeout: writeTimeout
        )
    }

    public static func summaryCommentCommand(gh: String, repository: String, number: Int, body: String) -> Command {
        Command(
            executable: gh,
            arguments: ["pr", "comment", String(number), "-R", repository, "--body", body],
            timeout: writeTimeout
        )
    }

    public static func approveCommand(gh: String, repository: String, number: Int, body: String?) -> Command {
        var args = ["pr", "review", String(number), "-R", repository, "--approve"]
        if let body, !body.isEmpty { args += ["--body", body] }
        return Command(executable: gh, arguments: args, timeout: writeTimeout)
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

    private struct FeedbackDetailsDTO: Decodable {
        struct Review: Decodable {
            struct Author: Decodable { let login: String }
            let id: String?
            let author: Author?
            let state: String
            let submittedAt: String?
        }
        let reviewDecision: String?
        let reviews: [Review]
    }

    public static func parseFeedbackDetails(
        _ data: Data,
        for pr: PullRequest,
        seenReviewID: String?
    ) throws -> PRFeedbackItem? {
        let dto = try JSONDecoder().decode(FeedbackDetailsDTO.self, from: data)
        guard dto.reviewDecision != "APPROVED" else { return nil }

        let iso = ISO8601DateFormatter()
        let formalStates = Set(["COMMENTED", "CHANGES_REQUESTED", "APPROVED"])
        let reviews = dto.reviews.compactMap { review -> PRReviewFeedback? in
            guard formalStates.contains(review.state),
                  let submittedAt = review.submittedAt.flatMap({ iso.date(from: $0) }) else {
                return nil
            }
            let id = review.id ?? "\(review.author?.login ?? "unknown")-\(review.state)-\(review.submittedAt ?? "")"
            return PRReviewFeedback(
                id: id,
                reviewer: review.author?.login ?? "unknown",
                state: review.state,
                submittedAt: submittedAt
            )
        }
        .sorted { $0.submittedAt < $1.submittedAt }
        guard let latest = reviews.max(by: { $0.submittedAt < $1.submittedAt }) else { return nil }

        let status: PRFeedbackStatus
        if dto.reviewDecision == "CHANGES_REQUESTED" {
            status = .changesRequested
        } else if latest.state == "COMMENTED" {
            status = .commented
        } else {
            status = .awaitingApproval
        }

        let newFeedbackCount: Int
        if let seenReviewID {
            newFeedbackCount = reviews.suffix(fromLastMatchingID: seenReviewID).count
        } else {
            newFeedbackCount = reviews.count
        }

        return PRFeedbackItem(
            pr: pr,
            reviewDecision: dto.reviewDecision,
            status: status,
            latestReview: latest,
            feedbackCount: reviews.count,
            newFeedbackCount: newFeedbackCount
        )
    }

    // MARK: - Async operations

    public func currentLogin() async throws -> String {
        let result = try await runRead(Self.currentLoginCommand(gh: gh)).result
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
        try await fetchAwaitingReviewResult(settings: settings, login: login).pullRequests
    }

    public func fetchAwaitingReviewResult(
        settings: AppSettings,
        login: String
    ) async throws -> GitHubFetchResult {
        let execution = try await runRead(Self.searchPRsCommand(
            gh: gh,
            owner: settings.owner,
            repositories: settings.repositories
        ))
        let pullRequests = try Self.parsePullRequests(Data(execution.result.stdout.utf8))
        return GitHubFetchResult(
            pullRequests: pullRequests,
            retryCount: max(0, execution.attempts - 1),
            reachedSearchLimit: pullRequests.count >= 1_000
        )
    }

    public func fetchAuthoredFeedbackResult(
        settings: AppSettings,
        seenReviewIDsByPR: [String: String],
        maxConcurrent: Int = 4
    ) async throws -> GitHubFeedbackFetchResult {
        let execution = try await runRead(Self.searchAuthoredPRsCommand(
            gh: gh,
            owner: settings.owner,
            repositories: settings.repositories
        ))
        let pullRequests = try Self.parsePullRequests(Data(execution.result.stdout.utf8))
        let feedbackItems = try await fetchFeedbackDetails(
            pullRequests,
            seenReviewIDsByPR: seenReviewIDsByPR,
            maxConcurrent: maxConcurrent
        )
        return GitHubFeedbackFetchResult(
            feedbackItems: feedbackItems.sorted {
                $0.latestReview.submittedAt > $1.latestReview.submittedAt
            },
            retryCount: max(0, execution.attempts - 1),
            reachedSearchLimit: pullRequests.count >= 1_000
        )
    }

    public func fetchFeedbackDetails(
        _ pullRequests: [PullRequest],
        seenReviewIDsByPR: [String: String],
        maxConcurrent: Int = 4
    ) async throws -> [PRFeedbackItem] {
        guard !pullRequests.isEmpty else { return [] }
        let concurrency = max(1, min(maxConcurrent, pullRequests.count))
        return try await withThrowingTaskGroup(of: PRFeedbackItem?.self) { group in
            var iterator = pullRequests.makeIterator()
            for _ in 0..<concurrency {
                guard let pr = iterator.next() else { break }
                group.addTask { [self] in
                    try await fetchFeedbackDetail(
                        pr,
                        seenReviewID: seenReviewIDsByPR[pr.id]
                    )
                }
            }

            var result: [PRFeedbackItem] = []
            while let item = try await group.next() {
                if let item { result.append(item) }
                if let pr = iterator.next() {
                    group.addTask { [self] in
                        try await fetchFeedbackDetail(
                            pr,
                            seenReviewID: seenReviewIDsByPR[pr.id]
                        )
                    }
                }
            }
            return result
        }
    }

    public func fetchFeedbackDetail(_ pr: PullRequest, seenReviewID: String?) async throws -> PRFeedbackItem? {
        let result = try await runRead(Self.feedbackDetailsCommand(gh: gh, repository: pr.repository, number: pr.number)).result
        guard result.succeeded else {
            throw GitHubError("gh pr view failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return try Self.parseFeedbackDetails(
            Data(result.stdout.utf8),
            for: pr,
            seenReviewID: seenReviewID
        )
    }

    /// Fetches only the head commit SHA (cheap, no AI cost) for cache lookups.
    public func fetchHeadSha(_ pr: PullRequest) async throws -> String {
        let result = try await runRead(Self.headShaCommand(gh: gh, repository: pr.repository, number: pr.number)).result
        guard result.succeeded else {
            throw GitHubError("gh pr view failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fetches cache keys with bounded concurrency so large review queues do not
    /// perform a slow serial N+1 sequence or overwhelm the CLI/API.
    public func fetchHeadShas(
        _ pullRequests: [PullRequest],
        maxConcurrent: Int = 6
    ) async -> [String: String] {
        guard !pullRequests.isEmpty else { return [:] }
        let concurrency = max(1, min(maxConcurrent, pullRequests.count))
        return await withTaskGroup(of: (String, String?).self) { group in
            var iterator = pullRequests.makeIterator()
            for _ in 0..<concurrency {
                guard let pr = iterator.next() else { break }
                group.addTask { [self] in
                    (pr.id, try? await fetchHeadSha(pr))
                }
            }

            var result: [String: String] = [:]
            while let (id, sha) = await group.next() {
                if let sha, !sha.isEmpty { result[id] = sha }
                if let pr = iterator.next() {
                    group.addTask { [self] in
                        (pr.id, try? await fetchHeadSha(pr))
                    }
                }
            }
            return result
        }
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
        let meta = try await runRead(Self.detailsCommand(gh: gh, repository: pr.repository, number: pr.number)).result
        guard meta.succeeded else {
            throw GitHubError("gh pr view failed: \(meta.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let dto = try JSONDecoder().decode(DetailsDTO.self, from: Data(meta.stdout.utf8))
        let diff = try await runRead(Self.diffCommand(gh: gh, repository: pr.repository, number: pr.number)).result
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
        let result = try await runOnce(Self.inlineCommentCommand(
            gh: gh,
            repository: pr.repository,
            number: pr.number,
            comment: comment,
            commitSha: commitSha
        ))
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
        let result = try await runOnce(command)
        guard result.succeeded else {
            throw GitHubError("post review failed: \(result.stderr)")
        }
        return result
    }

    @discardableResult
    public func postSummaryComment(_ body: String, on pr: PullRequest) async throws -> CommandResult {
        let result = try await runOnce(Self.summaryCommentCommand(
            gh: gh,
            repository: pr.repository,
            number: pr.number,
            body: body
        ))
        guard result.succeeded else { throw GitHubError("post comment failed: \(result.stderr)") }
        return result
    }

    @discardableResult
    public func createIssue(
        repository: String,
        title: String,
        body: String,
        labels: [String] = []
    ) async throws -> GitHubIssueCreationResult {
        let result = try await runOnce(FeedbackService.createIssueCommand(
            gh: gh,
            repository: repository,
            title: title,
            body: body,
            labels: labels
        ))
        if result.succeeded {
            return GitHubIssueCreationResult(commandResult: result)
        }
        guard !labels.isEmpty, Self.isLabelFailureMessage(result.stderr) else {
            throw GitHubError("create issue failed: \(result.stderr)")
        }
        let fallback = try await runOnce(FeedbackService.createIssueCommand(
            gh: gh,
            repository: repository,
            title: title,
            body: body
        ))
        guard fallback.succeeded else {
            throw GitHubError("create issue failed: \(fallback.stderr)")
        }
        return GitHubIssueCreationResult(
            commandResult: fallback,
            omittedLabels: labels
        )
    }

    public func fetchIssueStatus(repository: String, number: Int) async throws -> FeedbackIssueStatus {
        let result = try await runOnce(FeedbackService.viewIssueCommand(
            gh: gh,
            repository: repository,
            number: number
        ))
        guard result.succeeded else { throw GitHubError("view issue failed: \(result.stderr)") }
        return try FeedbackService.parseIssueStatus(result.stdout)
    }

    @discardableResult
    public func approve(_ pr: PullRequest, body: String?) async throws -> CommandResult {
        let result = try await runOnce(Self.approveCommand(
            gh: gh,
            repository: pr.repository,
            number: pr.number,
            body: body
        ))
        guard result.succeeded else { throw GitHubError("approve failed: \(result.stderr)") }
        return result
    }
}

private extension Array where Element == PRReviewFeedback {
    func suffix(fromLastMatchingID seenReviewID: String) -> ArraySlice<PRReviewFeedback> {
        guard let index = lastIndex(where: { $0.id == seenReviewID }) else {
            return self[...]
        }
        return self[index...].dropFirst()
    }
}
