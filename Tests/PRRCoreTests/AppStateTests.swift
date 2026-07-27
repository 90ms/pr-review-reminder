import XCTest
@testable import PRRCore

private final class AppStateMemoryKeyValueStore: KeyValueStore {
    var values: [String: Data] = [:]
    func data(forKey defaultName: String) -> Data? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value as? Data
    }
}

private final class AppStateMemoryHistoryPersistence: HistoryPersisting, @unchecked Sendable {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

private final class AppStateMemoryFeedbackSeenPersistence: FeedbackSeenPersisting, @unchecked Sendable {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

private final class DetailAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class ReReviewScript: @unchecked Sendable {
    private let lock = NSLock()
    private var detailCount = 0
    private var analysisCount = 0

    func nextDetailsJSON() -> String {
        lock.lock()
        defer { lock.unlock() }
        detailCount += 1
        return AppStateTests.detailsJSON(sha: detailCount == 1 ? "old-sha" : "fresh-sha")
    }

    func nextDiff() -> String {
        lock.lock()
        defer { lock.unlock() }
        return detailCount <= 1 ? "old diff" : "fresh diff"
    }

    func nextAnalysisJSON() -> String {
        lock.lock()
        defer { lock.unlock() }
        analysisCount += 1
        let summary = analysisCount == 1 ? "old analysis" : "fresh analysis"
        return #"{"result":"{\"summary\":\"\#(summary)\",\"reviewPoints\":[],\"inlineComments\":[]}","total_cost_usd":0.01,"usage":{"input_tokens":10,"output_tokens":5}}"#
    }
}

private final class CancellableAppStateRunner: ProcessRunning, @unchecked Sendable {
    func run(_ command: Command) async throws -> CommandResult {
        if command.executable == "/bin/zsh", command.arguments.first == "-lc" {
            return CommandResult(exitCode: 0, stdout: "/usr/bin/true\n", stderr: "")
        }
        if command.arguments == ["auth", "status"] {
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        if command.arguments == ["api", "user", "--jq", ".login"] {
            return CommandResult(exitCode: 0, stdout: "reviewer\n", stderr: "")
        }
        if command.arguments.first == "search" {
            return CommandResult(exitCode: 0, stdout: AppStateTests.searchJSON(), stderr: "")
        }
        if command.arguments.contains("--jq") {
            return CommandResult(exitCode: 0, stdout: "sha\n", stderr: "")
        }
        if command.arguments.prefix(2) == ["pr", "view"] {
            return CommandResult(exitCode: 0, stdout: AppStateTests.detailsJSON(sha: "sha"), stderr: "")
        }
        if command.arguments.prefix(2) == ["pr", "diff"] {
            return CommandResult(exitCode: 0, stdout: "diff", stderr: "")
        }
        if command.arguments.first == "-p" {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
    }
}

@MainActor
final class AppStateTests: XCTestCase {
    private let executable = "/usr/bin/true"

    private func makeState(
        settings: AppSettings = AppSettings(notificationsEnabled: false),
        history: HistoryStore = HistoryStore(persistence: AppStateMemoryHistoryPersistence()),
        feedbackSeenStore: FeedbackSeenStore = FeedbackSeenStore(
            persistence: AppStateMemoryFeedbackSeenPersistence()
        ),
        scheduleRunStore: ScheduleRunStore = ScheduleRunStore(
            store: AppStateMemoryKeyValueStore(),
            key: "test.schedule"
        ),
        feedbackHistory: FeedbackHistoryStore = FeedbackHistoryStore(
            store: AppStateMemoryKeyValueStore(),
            key: "test.feedback"
        ),
        responder: @escaping @Sendable (Command) -> CommandResult
    ) async -> (AppState, MockProcessRunner) {
        let keyValues = AppStateMemoryKeyValueStore()
        let settingsStore = SettingsStore(store: keyValues, key: "test.settings")
        settingsStore.save(settings)
        let runner = MockProcessRunner()
        runner.responder = { [executable] command in
            if command.executable == "/bin/zsh", command.arguments.first == "-lc" {
                return CommandResult(exitCode: 0, stdout: "\(executable)\n", stderr: "")
            }
            if command.arguments == ["auth", "status"] {
                return CommandResult(exitCode: 0, stdout: "", stderr: "")
            }
            if command.arguments == ["api", "user", "--jq", ".login"] {
                return CommandResult(exitCode: 0, stdout: "reviewer\n", stderr: "")
            }
            return responder(command)
        }
        let state = AppState(
            runner: runner,
            settingsStore: settingsStore,
            history: history,
            feedbackSeenStore: feedbackSeenStore,
            scheduleRunStore: scheduleRunStore,
            feedbackHistory: feedbackHistory,
            autoBootstrap: false
        )
        await state.diagnose()
        return (state, runner)
    }

    nonisolated fileprivate static func searchJSON(title: String = "Test PR") -> String {
        """
        [{
          "number": 42,
          "title": "\(title)",
          "url": "https://example.test/pull/42",
          "updatedAt": "2026-07-24T00:00:00Z",
          "author": {"login": "author"},
          "repository": {"nameWithOwner": "acme/widgets"}
        }]
        """
    }

    nonisolated fileprivate static func detailsJSON(sha: String) -> String {
        """
        {"body":"PR body","headRefOid":"\(sha)","additions":2,"deletions":1}
        """
    }

    nonisolated fileprivate static func feedbackDetailsJSON(reviewID: String = "r1") -> String {
        """
        {
          "reviewDecision": "CHANGES_REQUESTED",
          "reviews": [
            {
              "id": "\(reviewID)",
              "state": "CHANGES_REQUESTED",
              "submittedAt": "2026-07-25T00:00:00Z",
              "author": {"login": "reviewer-two"}
            }
          ]
        }
        """
    }

    private func record(sha: String, tokens: Int = 20) -> ReviewRecord {
        ReviewRecord(
            repository: "acme/widgets",
            number: 42,
            title: "Cached PR",
            author: "author",
            url: "https://example.test/pull/42",
            headSha: sha,
            tool: .claude,
            reviewedAt: Date(),
            analysis: Analysis(summary: "cached analysis"),
            usage: AIUsage(totalTokens: tokens),
            details: PRDetails(
                body: "cached body",
                headSha: sha,
                additions: 2,
                deletions: 1,
                diff: "cached diff"
            )
        )
    }

    func testRefreshPopulatesAwaitingPullRequests() async {
        let (state, _) = await makeState { command in
            if command.arguments.first == "search" {
                if command.arguments.contains("--author=@me") {
                    return CommandResult(exitCode: 0, stdout: Self.searchJSON(title: "My PR"), stderr: "")
                }
                return CommandResult(exitCode: 0, stdout: Self.searchJSON(), stderr: "")
            }
            if command.arguments.prefix(2) == ["pr", "view"] {
                return CommandResult(exitCode: 0, stdout: Self.feedbackDetailsJSON(), stderr: "")
            }
            if command.arguments.contains("--jq") {
                return CommandResult(exitCode: 0, stdout: "uncached-sha\n", stderr: "")
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }

        await state.refresh()

        XCTAssertEqual(state.items.map(\.id), ["acme/widgets#42"])
        XCTAssertEqual(state.feedbackItems.map(\.id), ["acme/widgets#42"])
        XCTAssertEqual(state.feedbackItems.first?.status, .changesRequested)
        XCTAssertNil(state.feedbackError)
        XCTAssertEqual(state.items.first?.state, .idle)
        XCTAssertNil(state.lastError)
        XCTAssertNotNil(state.lastRun)
        XCTAssertFalse(state.isRefreshing)
    }

    func testFeedbackRefreshFailurePreservesExistingFeedbackAndReviewList() async {
        let (state, runner) = await makeState { command in
            if command.arguments.first == "search" {
                return CommandResult(exitCode: 0, stdout: Self.searchJSON(), stderr: "")
            }
            if command.arguments.prefix(2) == ["pr", "view"] {
                return CommandResult(exitCode: 0, stdout: Self.feedbackDetailsJSON(), stderr: "")
            }
            if command.arguments.contains("--jq") {
                return CommandResult(exitCode: 0, stdout: "uncached-sha\n", stderr: "")
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }
        await state.refresh()
        XCTAssertEqual(state.feedbackItems.count, 1)

        runner.responder = { command in
            if command.arguments.first == "search" {
                return CommandResult(exitCode: 0, stdout: Self.searchJSON(title: "Still visible"), stderr: "")
            }
            if command.arguments.prefix(2) == ["pr", "view"] {
                return CommandResult(exitCode: 1, stdout: "", stderr: "feedback failed")
            }
            if command.arguments.contains("--jq") {
                return CommandResult(exitCode: 0, stdout: "uncached-sha\n", stderr: "")
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }
        await state.refresh()

        XCTAssertEqual(state.items.first?.pr.title, "Still visible")
        XCTAssertEqual(state.feedbackItems.count, 1)
        XCTAssertTrue(state.feedbackError?.contains("feedback failed") == true)
    }

    func testFeedbackSeenStoreSuppressesDuplicateNewFeedbackCount() async {
        let persistence = AppStateMemoryFeedbackSeenPersistence()
        let seen = FeedbackSeenStore(persistence: persistence)
        let (state, _) = await makeState(feedbackSeenStore: seen) { command in
            if command.arguments.first == "search" {
                return CommandResult(exitCode: 0, stdout: Self.searchJSON(), stderr: "")
            }
            if command.arguments.prefix(2) == ["pr", "view"] {
                return CommandResult(exitCode: 0, stdout: Self.feedbackDetailsJSON(reviewID: "r-stable"), stderr: "")
            }
            if command.arguments.contains("--jq") {
                return CommandResult(exitCode: 0, stdout: "uncached-sha\n", stderr: "")
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }

        await state.refresh()
        XCTAssertEqual(state.feedbackItems.first?.newFeedbackCount, 1)

        await state.refresh()
        XCTAssertEqual(state.feedbackItems.first?.newFeedbackCount, 0)
    }

    func testFeedbackSeenStoreLoadsEmptyAndPersistsValues() {
        let persistence = AppStateMemoryFeedbackSeenPersistence()
        let seen = FeedbackSeenStore(persistence: persistence)

        XCTAssertEqual(seen.load(), [:])

        seen.save(["acme/widgets#42": "review-1"])

        XCTAssertEqual(seen.load(), ["acme/widgets#42": "review-1"])
    }

    func testScheduledRefreshPersistsSuccessfulRun() async {
        let memory = AppStateMemoryKeyValueStore()
        let runs = ScheduleRunStore(store: memory, key: "test.schedule")
        let (state, _) = await makeState(scheduleRunStore: runs) { command in
            if command.arguments.first == "search" {
                return CommandResult(exitCode: 0, stdout: Self.searchJSON(), stderr: "")
            }
            if command.arguments.contains("--jq") {
                return CommandResult(exitCode: 0, stdout: "uncached-sha\n", stderr: "")
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }

        await state.refresh(trigger: .scheduled)

        XCTAssertEqual(state.scheduleRuns.first?.outcome, .success)
        XCTAssertEqual(state.scheduleRuns.first?.itemCount, 1)
        XCTAssertEqual(runs.all(), state.scheduleRuns)
    }

    func testRefreshRestoresMatchingHistoryWithoutRunningAI() async {
        let history = HistoryStore(persistence: AppStateMemoryHistoryPersistence())
        history.upsert(record(sha: "cached-sha"))
        let (state, runner) = await makeState(history: history) { command in
            if command.arguments.first == "search" {
                return CommandResult(exitCode: 0, stdout: Self.searchJSON(), stderr: "")
            }
            if command.arguments.contains("--jq") {
                return CommandResult(exitCode: 0, stdout: "cached-sha\n", stderr: "")
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }

        await state.refresh()

        XCTAssertEqual(state.items.first?.analysis?.summary, "cached analysis")
        XCTAssertEqual(state.items.first?.details?.diff, "cached diff")
        XCTAssertEqual(state.items.first?.state, .done)
        XCTAssertFalse(runner.commands.contains { $0.arguments.first == "-p" })
    }

    func testReviewSuccessUpdatesItemAndHistory() async {
        let history = HistoryStore(persistence: AppStateMemoryHistoryPersistence())
        let (state, runner) = await makeState(history: history) { command in
            if command.arguments.first == "search" {
                return CommandResult(exitCode: 0, stdout: Self.searchJSON(), stderr: "")
            }
            if command.arguments.contains("--jq") {
                return CommandResult(exitCode: 0, stdout: "new-sha\n", stderr: "")
            }
            if command.arguments.prefix(2) == ["pr", "view"] {
                return CommandResult(exitCode: 0, stdout: Self.detailsJSON(sha: "new-sha"), stderr: "")
            }
            if command.arguments.prefix(2) == ["pr", "diff"] {
                return CommandResult(exitCode: 0, stdout: "diff --git a/a b/a", stderr: "")
            }
            if command.arguments.first == "-p" {
                let wrapper = #"{"result":"{\"summary\":\"looks good\",\"reviewPoints\":[],\"inlineComments\":[]}","total_cost_usd":0.01,"usage":{"input_tokens":10,"output_tokens":5}}"#
                return CommandResult(exitCode: 0, stdout: wrapper, stderr: "")
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }

        await state.refresh()
        await state.review("acme/widgets#42", notifyOnComplete: false)

        XCTAssertEqual(state.items.first?.state, .done)
        XCTAssertEqual(state.items.first?.analysis?.summary, "looks good")
        XCTAssertEqual(state.items.first?.usage?.tokens, 15)
        XCTAssertEqual(history.all().first?.headSha, "new-sha")
        XCTAssertTrue(runner.commands.contains { $0.arguments.first == "-p" })
    }

    func testStartReReviewDiscardsCompletedResultAndFetchesFreshDetails() async {
        let script = ReReviewScript()
        let history = HistoryStore(persistence: AppStateMemoryHistoryPersistence())
        let (state, _) = await makeState(history: history) { command in
            if command.arguments.first == "search" {
                if command.arguments.contains("--author=@me") {
                    return CommandResult(exitCode: 0, stdout: "[]", stderr: "")
                }
                return CommandResult(exitCode: 0, stdout: Self.searchJSON(), stderr: "")
            }
            if command.arguments.contains("--jq") {
                return CommandResult(exitCode: 0, stdout: "uncached-sha\n", stderr: "")
            }
            if command.arguments.prefix(2) == ["pr", "view"] {
                return CommandResult(exitCode: 0, stdout: script.nextDetailsJSON(), stderr: "")
            }
            if command.arguments.prefix(2) == ["pr", "diff"] {
                return CommandResult(exitCode: 0, stdout: script.nextDiff(), stderr: "")
            }
            if command.arguments.first == "-p" {
                return CommandResult(exitCode: 0, stdout: script.nextAnalysisJSON(), stderr: "")
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }

        await state.refresh()
        await state.review("acme/widgets#42", notifyOnComplete: false)
        XCTAssertEqual(state.items.first?.analysis?.summary, "old analysis")
        XCTAssertEqual(state.items.first?.details?.headSha, "old-sha")

        state.startReReview("acme/widgets#42", notifyOnComplete: false)
        for _ in 0..<100 where state.items.first?.analysis?.summary != "fresh analysis" {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(state.items.first?.state, .done)
        XCTAssertEqual(state.items.first?.analysis?.summary, "fresh analysis")
        XCTAssertEqual(state.items.first?.details?.headSha, "fresh-sha")
        XCTAssertEqual(history.all().first?.headSha, "fresh-sha")
    }

    func testEnsureDetailsExposesFailureAndCanRetry() async {
        let attempts = DetailAttemptCounter()
        let (state, _) = await makeState { command in
            if command.arguments.first == "search" {
                return CommandResult(exitCode: 0, stdout: Self.searchJSON(), stderr: "")
            }
            if command.arguments.contains("--jq") {
                return CommandResult(exitCode: 0, stdout: "new-sha\n", stderr: "")
            }
            if command.arguments.prefix(2) == ["pr", "view"] {
                return CommandResult(
                    exitCode: 0,
                    stdout: Self.detailsJSON(sha: "new-sha"),
                    stderr: ""
                )
            }
            if command.arguments.prefix(2) == ["pr", "diff"] {
                return attempts.increment() <= 3
                    ? CommandResult(exitCode: 1, stdout: "", stderr: "rate limited")
                    : CommandResult(exitCode: 0, stdout: "diff --git a/a b/a", stderr: "")
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }
        await state.refresh()

        await state.ensureDetails("acme/widgets#42")
        guard case let .failed(message) = state.items.first?.detailsState else {
            return XCTFail("Expected detail loading to expose the failure")
        }
        XCTAssertTrue(message.contains("rate limited"))
        XCTAssertNil(state.items.first?.details)

        await state.ensureDetails("acme/widgets#42")
        XCTAssertEqual(state.items.first?.detailsState, .loaded)
        XCTAssertEqual(state.items.first?.details?.diff, "diff --git a/a b/a")
    }

    func testReviewBudgetBlockFailsBeforeInvokingAI() async {
        var settings = AppSettings(notificationsEnabled: false)
        settings.reviewTokenBudget = 20
        settings.reviewBudgetWindowDays = 30
        let history = HistoryStore(persistence: AppStateMemoryHistoryPersistence())
        history.upsert(record(sha: "old-sha", tokens: 20))
        let (state, runner) = await makeState(settings: settings, history: history) { command in
            if command.arguments.first == "search" {
                return CommandResult(exitCode: 0, stdout: Self.searchJSON(), stderr: "")
            }
            if command.arguments.contains("--jq") {
                return CommandResult(exitCode: 0, stdout: "new-sha\n", stderr: "")
            }
            if command.arguments.prefix(2) == ["pr", "view"] {
                return CommandResult(exitCode: 0, stdout: Self.detailsJSON(sha: "new-sha"), stderr: "")
            }
            if command.arguments.prefix(2) == ["pr", "diff"] {
                return CommandResult(exitCode: 0, stdout: "diff", stderr: "")
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }

        await state.refresh()
        await state.review("acme/widgets#42", notifyOnComplete: false)

        guard case let .failed(message) = state.items.first?.state else {
            return XCTFail("Expected review to fail when the local budget is exhausted")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(runner.commands.contains { $0.arguments.first == "-p" })
        XCTAssertEqual(history.all().count, 1)
    }

    func testSummaryPublishRejectsStaleHeadBeforePosting() async {
        let (state, runner) = await makeState { command in
            if command.arguments.first == "search" {
                return CommandResult(exitCode: 0, stdout: Self.searchJSON(), stderr: "")
            }
            if command.arguments.contains("--jq") {
                return CommandResult(exitCode: 0, stdout: "newer-sha\n", stderr: "")
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }
        await state.refresh()
        var item = state.items[0]
        item.details = PRDetails(
            body: "", headSha: "reviewed-sha", additions: 1, deletions: 0, diff: "diff")
        item.analysis = Analysis(summary: "summary")

        await state.postSummaryComment(for: item)

        XCTAssertTrue(state.lastError?.contains("changed") == true)
        XCTAssertFalse(runner.commands.contains { $0.arguments.prefix(2) == ["pr", "comment"] })
    }

    func testInlinePublishUsesEditedCommentList() async throws {
        let (state, runner) = await makeState { command in
            if command.arguments.contains("--jq") {
                return CommandResult(exitCode: 0, stdout: "reviewed-sha\n", stderr: "")
            }
            if command.arguments.prefix(2) == ["api", "repos/acme/widgets/pulls/42/reviews"] {
                return CommandResult(exitCode: 0, stdout: "{}", stderr: "")
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }
        var item = PRItem(pr: PullRequest(
            repository: "acme/widgets",
            number: 42,
            title: "Edit comments",
            author: "author",
            url: "https://example.test/pull/42"
        ))
        item.details = PRDetails(
            body: "",
            headSha: "reviewed-sha",
            additions: 1,
            deletions: 0,
            diff: "diff"
        )
        let comments = [
            InlineComment(path: "a.swift", line: 10, body: "edited body")
        ]

        await state.postInlineComments(for: item, comments: comments)

        let reviewCommand = runner.commands.last {
            $0.arguments.prefix(2) == ["api", "repos/acme/widgets/pulls/42/reviews"]
        }
        let payload = try XCTUnwrap(reviewCommand?.stdin?.data(using: .utf8))
        let decoded = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let postedComments = decoded?["comments"] as? [[String: Any]]
        XCTAssertEqual(postedComments?.count, 1)
        XCTAssertEqual(postedComments?.first?["body"] as? String, "edited body")
    }

    func testFeedbackSubmissionIsTracked() async {
        let feedbackHistory = FeedbackHistoryStore(
            store: AppStateMemoryKeyValueStore(),
            key: "feedback.submit"
        )
        let (state, _) = await makeState(feedbackHistory: feedbackHistory) { command in
            if command.arguments.prefix(2) == ["issue", "create"] {
                return CommandResult(
                    exitCode: 0,
                    stdout: "https://github.com/90ms/pr-review-reminder/issues/123\n",
                    stderr: ""
                )
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }

        let result = await state.submitFeedback(title: "Bug", body: "It broke")

        guard case .created = result else {
            return XCTFail("expected created result")
        }
        XCTAssertEqual(state.feedbackRecords.map(\.number), [123])
        XCTAssertEqual(feedbackHistory.all().first?.title, "Bug")
    }

    func testFeedbackHistoryRefreshUpdatesIssueStatus() async {
        let feedbackHistory = FeedbackHistoryStore(
            store: AppStateMemoryKeyValueStore(),
            key: "feedback.refresh"
        )
        feedbackHistory.upsert(FeedbackRecord(
            repository: "90ms/pr-review-reminder",
            number: 123,
            title: "Bug",
            body: "It broke",
            url: "https://github.com/90ms/pr-review-reminder/issues/123"
        ))
        let (state, _) = await makeState(feedbackHistory: feedbackHistory) { command in
            if command.arguments.prefix(2) == ["issue", "view"] {
                return CommandResult(
                    exitCode: 0,
                    stdout: #"{"title":"Fixed","state":"CLOSED","stateReason":"COMPLETED","url":"https://github.com/90ms/pr-review-reminder/issues/123","updatedAt":"2026-07-26T10:00:00Z","closedAt":"2026-07-26T10:30:00Z"}"#,
                    stderr: ""
                )
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }

        await state.refreshFeedbackHistory()

        XCTAssertEqual(state.feedbackRecords.first?.title, "Fixed")
        XCTAssertEqual(state.feedbackRecords.first?.state, .closed)
        XCTAssertEqual(state.feedbackRecords.first?.stateReason, "COMPLETED")
        XCTAssertNotNil(state.feedbackRecords.first?.lastCheckedAt)
    }

    func testFeedbackHistoryRefreshContinuesAfterIndividualFailure() async {
        let feedbackHistory = FeedbackHistoryStore(
            store: AppStateMemoryKeyValueStore(),
            key: "feedback.partial-refresh"
        )
        feedbackHistory.upsert(FeedbackRecord(
            repository: "90ms/pr-review-reminder",
            number: 1,
            title: "Refresh succeeds",
            body: "Body",
            url: "https://github.com/90ms/pr-review-reminder/issues/1",
            createdAt: Date(timeIntervalSince1970: 100)
        ))
        feedbackHistory.upsert(FeedbackRecord(
            repository: "90ms/pr-review-reminder",
            number: 2,
            title: "Refresh fails",
            body: "Body",
            url: "https://github.com/90ms/pr-review-reminder/issues/2",
            createdAt: Date(timeIntervalSince1970: 200)
        ))
        let (state, _) = await makeState(feedbackHistory: feedbackHistory) { command in
            guard command.arguments.prefix(2) == ["issue", "view"] else {
                return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
            }
            if command.arguments.contains("2") {
                return CommandResult(exitCode: 1, stdout: "", stderr: "not found")
            }
            return CommandResult(
                exitCode: 0,
                stdout: #"{"title":"Refreshed","state":"CLOSED","stateReason":"COMPLETED","url":"https://github.com/90ms/pr-review-reminder/issues/1","updatedAt":"2026-07-26T10:00:00Z","closedAt":"2026-07-26T10:30:00Z"}"#,
                stderr: ""
            )
        }

        await state.refreshFeedbackHistory()

        XCTAssertEqual(
            state.feedbackRecords.first(where: { $0.number == 1 })?.state,
            .closed
        )
        XCTAssertEqual(
            state.feedbackRecords.first(where: { $0.number == 2 })?.state,
            .open
        )
        XCTAssertTrue(state.lastError?.contains("not found") == true)
    }

    func testUserCancellationTransitionsReviewState() async {
        let settingsStore = SettingsStore(
            store: AppStateMemoryKeyValueStore(),
            key: "cancel.settings"
        )
        settingsStore.save(AppSettings(notificationsEnabled: false))
        let state = AppState(
            runner: CancellableAppStateRunner(),
            settingsStore: settingsStore,
            history: HistoryStore(persistence: AppStateMemoryHistoryPersistence()),
            autoBootstrap: false
        )
        await state.diagnose()
        await state.refresh()

        state.startReview("acme/widgets#42", notifyOnComplete: false)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(state.items.first?.state, .loading)

        state.cancelReview("acme/widgets#42")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(state.items.first?.state, .cancelled)
    }
}
