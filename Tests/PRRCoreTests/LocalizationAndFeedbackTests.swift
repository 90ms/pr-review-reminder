import XCTest
@testable import PRRCore

final class LocalizationAndFeedbackTests: XCTestCase {
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
        let cmd = FeedbackService.createIssueCommand(gh: "/usr/bin/gh", repository: "acme/app", title: "Bug", body: "It broke")
        XCTAssertEqual(cmd.arguments, ["issue", "create", "-R", "acme/app", "--title", "Bug", "--body", "It broke"])
        let preview = FeedbackService.previewString(gh: "gh", repository: "acme/app", title: "A B", body: "line1\nline2")
        XCTAssertTrue(preview.contains("issue create"))
        XCTAssertTrue(preview.contains("\"A B\""))
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
    }

    // Without gh, submission builds a project-repository preview and executes nothing.
    func testSubmitHeldWhenGitHubUnavailable() async {
        let mock = MockProcessRunner()
        let ai = AIService(runner: mock, claudePath: "/bin/claude", codexPath: nil)
        let feedback = FeedbackService(github: nil, ai: ai)
        let result = try? await feedback.submit(title: "Hi", body: "there", ghPath: "/usr/bin/gh")
        guard case .held(let preview) = result else { return XCTFail("expected held") }
        XCTAssertTrue(preview.contains("90ms/pr-review-reminder"))
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

        let result = try? await feedback.submit(title: "Bug", body: "It broke", ghPath: "/usr/bin/gh")

        XCTAssertEqual(
            result,
            .created(output: "https://github.com/90ms/pr-review-reminder/issues/123")
        )
        XCTAssertEqual(
            mock.commands.last?.arguments,
            [
                "issue", "create", "-R", "90ms/pr-review-reminder",
                "--title", "Bug", "--body", "It broke",
            ]
        )
    }
}
