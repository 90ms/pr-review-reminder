import XCTest
@testable import PRRCore

final class LocalizationAndFeedbackTests: XCTestCase {
    final class FeedbackMemoryStore: KeyValueStore {
        var values: [String: Data] = [:]
        func data(forKey defaultName: String) -> Data? { values[defaultName] }
        func set(_ value: Any?, forKey defaultName: String) {
            values[defaultName] = value as? Data
        }
    }

    // AC11 — language resolution.
    func testAppLanguageResolution() {
        let ko = Locale(identifier: "ko_KR")
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(AppLanguage.system.resolved(locale: ko), "ko")
        XCTAssertEqual(AppLanguage.system.resolved(locale: en), "en")
        XCTAssertEqual(AppLanguage.korean.resolved(locale: en), "ko")
        XCTAssertEqual(AppLanguage.english.resolved(locale: ko), "en")
    }

    func testPromptDirectiveLanguage() {
        XCTAssertTrue(AppLanguage.korean.promptDirective().contains("Korean"))
        XCTAssertTrue(AppLanguage.english.promptDirective().contains("English"))
    }

    // AC12 — localization lookup + fallback.
    func testL10n() {
        let ko = L10n(language: .korean)
        let en = L10n(language: .english)
        XCTAssertEqual(ko("approve"), "승인")
        XCTAssertEqual(en("approve"), "Approve")
        XCTAssertEqual(ko("approve_no_issues"), "문제 없음 · 승인")
        XCTAssertEqual(
            en("approve_no_issues_body"),
            "I found no issues requiring inline comments. Approving."
        )
        XCTAssertEqual(ko("diff_split"), "분할")
        XCTAssertEqual(ko("tokens_unit"), "토큰")
        XCTAssertEqual(en("diff_unified"), "Unified")
        XCTAssertEqual(ko("detail_review"), "리뷰")
        XCTAssertEqual(en("detail_side_by_side"), "Side by side")
        // missing key returns the key itself
        XCTAssertEqual(ko("__no_such_key__"), "__no_such_key__")
    }

    // AC13 — prompt injects skill and language directive; {{SKILL}} is replaced.
    func testBuildPromptInjectsSkillAndLanguage() {
        let prompt = AIService.buildPrompt(
            template: "HEAD {{SKILL}} T:{{TITLE}} D:{{DIFF}}",
            title: "x", body: "", diff: "d",
            skill: "Focus on concurrency.",
            languageDirective: "Write the summary, reviewPoints, and inlineComments in Korean.",
            maxDiffChars: 1000
        )
        XCTAssertFalse(prompt.contains("{{SKILL}}"))
        XCTAssertTrue(prompt.contains("Focus on concurrency."))
        XCTAssertTrue(prompt.contains("Korean"))
    }

    func testBuildPromptEmptySkill() {
        let prompt = AIService.buildPrompt(template: "A {{SKILL}} B", title: "t", body: "b", diff: "d", maxDiffChars: 10)
        XCTAssertFalse(prompt.contains("{{SKILL}}"))
        XCTAssertFalse(prompt.contains("guidelines"))
    }

    // AC14 — issue command construction.
    func testCreateIssueCommand() {
        let cmd = FeedbackService.createIssueCommand(
            gh: "/usr/bin/gh",
            repository: "acme/app",
            title: "Bug",
            body: "It broke",
            labels: ["codex-ready", "bug"]
        )
        XCTAssertEqual(
            cmd.arguments,
            [
                "issue", "create", "-R", "acme/app", "--title", "Bug", "--body", "It broke",
                "--label", "codex-ready", "--label", "bug",
            ]
        )
        let view = FeedbackService.viewIssueCommand(gh: "/usr/bin/gh", repository: "acme/app", number: 42)
        XCTAssertEqual(
            view.arguments,
            [
                "issue", "view", "42", "-R", "acme/app", "--json",
                "number,title,state,stateReason,url,updatedAt,closedAt",
            ]
        )
        let preview = FeedbackService.previewString(
            gh: "gh",
            repository: "acme/app",
            title: "A B",
            body: "line1\nline2",
            labels: ["codex-ready", "question"]
        )
        XCTAssertTrue(preview.contains("issue create"))
        XCTAssertTrue(preview.contains("\"A B\""))
        XCTAssertTrue(preview.contains("--label codex-ready"))
    }

    func testFeedbackLabelsAlwaysIncludeCodexReadyAndClassification() {
        XCTAssertEqual(FeedbackService.labels(for: .bug), ["codex-ready", "bug"])
        XCTAssertEqual(FeedbackService.labels(for: .enhancement), ["codex-ready", "enhancement"])
        XCTAssertEqual(FeedbackService.labels(for: .question), ["codex-ready", "question"])
    }

    // AC15 — tidy JSON parse + fallback.
    func testParseTidy() {
        let ok = FeedbackService.parseTidy(#"{"title":"Clean title","body":"Clean body"}"#, fallbackTitle: "ft", fallbackBody: "fb")
        XCTAssertEqual(ok.title, "Clean title")
        XCTAssertEqual(ok.body, "Clean body")
        let bad = FeedbackService.parseTidy("not json", fallbackTitle: "ft", fallbackBody: "fb")
        XCTAssertEqual(bad.title, "ft")
        XCTAssertEqual(bad.body, "fb")
    }

    func testParseCreatedIssueRecord() {
        let record = FeedbackService.parseCreatedIssue(
            "https://github.com/90ms/pr-review-reminder/issues/123",
            repository: "90ms/pr-review-reminder",
            title: "Bug",
            body: "It broke",
            createdAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(record?.id, "90ms/pr-review-reminder#123")
        XCTAssertEqual(record?.number, 123)
        XCTAssertEqual(record?.state, .open)
        XCTAssertEqual(record?.createdAt, Date(timeIntervalSince1970: 100))
        XCTAssertNil(FeedbackService.parseCreatedIssue("no url", repository: "90ms/pr-review-reminder", title: "Bug", body: "Body"))
    }

    func testParseIssueStatus() throws {
        let status = try FeedbackService.parseIssueStatus(
            """
            {"title":"Done","state":"CLOSED","stateReason":"COMPLETED","url":"https://github.com/acme/app/issues/4","updatedAt":"2026-07-26T10:00:00Z","closedAt":"2026-07-26T11:00:00Z"}
            """
        )

        XCTAssertEqual(status.title, "Done")
        XCTAssertEqual(status.state, .closed)
        XCTAssertEqual(status.stateReason, "COMPLETED")
        XCTAssertNotNil(status.updatedAt)
        XCTAssertNotNil(status.closedAt)
    }

    func testFeedbackHistoryPersistsNewestFirstAndReplacesIssue() {
        let memory = FeedbackMemoryStore()
        let store = FeedbackHistoryStore(store: memory, key: "feedback.test")
        store.upsert(FeedbackRecord(
            repository: "90ms/pr-review-reminder",
            number: 1,
            title: "Older",
            body: "Body",
            url: "https://github.com/90ms/pr-review-reminder/issues/1",
            createdAt: Date(timeIntervalSince1970: 100)
        ))
        store.upsert(FeedbackRecord(
            repository: "90ms/pr-review-reminder",
            number: 2,
            title: "Newer",
            body: "Body",
            url: "https://github.com/90ms/pr-review-reminder/issues/2",
            createdAt: Date(timeIntervalSince1970: 200)
        ))
        store.upsert(FeedbackRecord(
            repository: "90ms/pr-review-reminder",
            number: 1,
            title: "Updated",
            body: "Body",
            url: "https://github.com/90ms/pr-review-reminder/issues/1",
            createdAt: Date(timeIntervalSince1970: 100),
            state: .closed,
            stateReason: "COMPLETED"
        ))

        let reloaded = FeedbackHistoryStore(store: memory, key: "feedback.test")

        XCTAssertEqual(reloaded.all().map(\.number), [2, 1])
        XCTAssertEqual(reloaded.all().last?.title, "Updated")
        XCTAssertEqual(reloaded.all().last?.state, .closed)
    }


    // Tolerant decoding: an older saved schema (missing new keys) keeps its values
    // and fills new keys with defaults instead of wiping everything.
    func testTolerantDecodingOfOldSchema() throws {
        let oldJSON = """
        {"owner":"acme","repositories":["x"],"aiTool":"codex","scheduleMode":"dailyAt",
         "dailyHour":9,"dailyMinute":30,"intervalHours":4,"notificationsEnabled":true,
         "promptTemplate":"T"}
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(oldJSON.utf8))
        XCTAssertEqual(settings.owner, "acme")           // preserved
        XCTAssertEqual(settings.aiTool, .codex)          // preserved
        XCTAssertEqual(settings.appLanguage, .system)    // new key defaulted
        XCTAssertEqual(settings.reviewLanguage, .system) // new key defaulted
        XCTAssertEqual(settings.reviewSkill, "")         // new key defaulted
        XCTAssertEqual(settings.promptCompositionMode, .unified)
        XCTAssertEqual(settings.reviewSkillFilePaths, [])
    }

    // Without gh, submission builds a project-repository preview and executes nothing.
    func testSubmitHeldWhenGitHubUnavailable() async {
        let mock = MockProcessRunner()
        let ai = AIService(runner: mock, claudePath: "/bin/claude", codexPath: nil)
        let feedback = FeedbackService(github: nil, ai: ai)
        let result = try? await feedback.submit(title: "Hi", body: "there", classification: .question, ghPath: "/usr/bin/gh")
        guard case .held(let preview) = result else { return XCTFail("expected held") }
        XCTAssertTrue(preview.contains("90ms/pr-review-reminder"))
        XCTAssertTrue(preview.contains("--label codex-ready"))
        XCTAssertTrue(preview.contains("--label question"))
        XCTAssertTrue(mock.commands.isEmpty, "nothing should be executed when held")
    }

    func testSubmitCreatesIssueInProjectRepository() async {
        let mock = MockProcessRunner()
        mock.defaultResult = CommandResult(
            exitCode: 0,
            stdout: "https://github.com/90ms/pr-review-reminder/issues/123\n",
            stderr: ""
        )
        let github = GitHubService(runner: mock, ghPath: "/usr/bin/gh")
        let ai = AIService(runner: mock, claudePath: "/bin/claude", codexPath: nil)
        let feedback = FeedbackService(github: github, ai: ai)

        let result = try? await feedback.submit(title: "Bug", body: "It broke", classification: .bug, ghPath: "/usr/bin/gh")

        guard case .created(let output, let record?, let omittedLabels) = result else {
            return XCTFail("expected created")
        }
        XCTAssertEqual(output, "https://github.com/90ms/pr-review-reminder/issues/123")
        XCTAssertEqual(record.repository, "90ms/pr-review-reminder")
        XCTAssertEqual(record.number, 123)
        XCTAssertEqual(record.title, "Bug")
        XCTAssertEqual(record.body, "It broke")
        XCTAssertEqual(record.url, "https://github.com/90ms/pr-review-reminder/issues/123")
        XCTAssertTrue(omittedLabels.isEmpty)
        XCTAssertEqual(mock.commands.last?.timeout, GitHubService.writeTimeout)
        XCTAssertEqual(
            mock.commands.last?.arguments,
            [
                "issue", "create", "-R", "90ms/pr-review-reminder",
                "--title", "Bug", "--body", "It broke",
                "--label", "codex-ready", "--label", "bug",
            ]
        )
    }

    func testSubmitRetriesWithoutLabelsWhenLabelCreateFails() async {
        let mock = MockProcessRunner()
        mock.responder = { command in
            if command.arguments.contains("--label") {
                return CommandResult(exitCode: 1, stdout: "", stderr: "could not add label")
            }
            return CommandResult(
                exitCode: 0,
                stdout: "https://github.com/90ms/pr-review-reminder/issues/124\n",
                stderr: ""
            )
        }
        let github = GitHubService(runner: mock, ghPath: "/usr/bin/gh")
        let ai = AIService(runner: mock, claudePath: "/bin/claude", codexPath: nil)
        let feedback = FeedbackService(github: github, ai: ai)

        let result = try? await feedback.submit(title: "Question", body: "How?", classification: .question, ghPath: "/usr/bin/gh")

        guard case .created(let output, let record?, let omittedLabels) = result else {
            return XCTFail("expected created")
        }
        XCTAssertEqual(output, "https://github.com/90ms/pr-review-reminder/issues/124")
        XCTAssertEqual(record.number, 124)
        XCTAssertEqual(omittedLabels, ["codex-ready", "question"])
        XCTAssertEqual(mock.commands.count, 2)
        XCTAssertTrue(mock.commands[0].arguments.contains("--label"))
        XCTAssertFalse(mock.commands[1].arguments.contains("--label"))
    }

    func testSubmitDoesNotRetryWithoutLabelsForUnrelatedFailures() async {
        let mock = MockProcessRunner()
        mock.defaultResult = CommandResult(
            exitCode: 1,
            stdout: "",
            stderr: "network connection failed"
        )
        let github = GitHubService(runner: mock, ghPath: "/usr/bin/gh")
        let ai = AIService(runner: mock, claudePath: "/bin/claude", codexPath: nil)
        let feedback = FeedbackService(github: github, ai: ai)

        do {
            _ = try await feedback.submit(
                title: "Question",
                body: "How?",
                classification: .question,
                ghPath: "/usr/bin/gh"
            )
            XCTFail("Expected issue creation to fail")
        } catch {
            XCTAssertTrue("\(error)".contains("network connection failed"))
        }
        XCTAssertEqual(mock.commands.count, 1)
        XCTAssertTrue(mock.commands[0].arguments.contains("--label"))
    }
}
