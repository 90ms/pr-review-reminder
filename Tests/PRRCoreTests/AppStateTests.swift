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
                return CommandResult(exitCode: 0, stdout: Self.searchJSON(), stderr: "")
            }
            if command.arguments.contains("--jq") {
                return CommandResult(exitCode: 0, stdout: "uncached-sha\n", stderr: "")
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }

        await state.refresh()

        XCTAssertEqual(state.items.map(\.id), ["acme/widgets#42"])
        XCTAssertEqual(state.items.first?.state, .idle)
        XCTAssertNil(state.lastError)
        XCTAssertNotNil(state.lastRun)
        XCTAssertFalse(state.isRefreshing)
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
