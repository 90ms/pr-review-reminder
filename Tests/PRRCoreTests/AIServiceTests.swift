import XCTest
@testable import PRRCore

final class AIServiceTests: XCTestCase {
    func testAICommandsHaveFiniteTimeouts() {
        let claude = AIService.claudeCommand(claude: "/claude")
        XCTAssertEqual(claude.timeout, AIService.defaultAnalysisTimeout)
        XCTAssertTrue(claude.arguments.contains("--disallowedTools"))
        XCTAssertTrue(claude.arguments.contains("--permission-mode"))
        XCTAssertTrue(claude.arguments.contains("--max-turns"))

        let codex = AIService.codexCommand(codex: "/codex")
        XCTAssertEqual(codex.timeout, AIService.defaultAnalysisTimeout)
        XCTAssertTrue(codex.arguments.contains("--ephemeral"))
        XCTAssertTrue(codex.arguments.contains("--ignore-user-config"))
        XCTAssertTrue(codex.arguments.contains("--ignore-rules"))
        XCTAssertTrue(codex.arguments.contains("read-only"))
    }

    func testRestrictedEnvironmentDropsExportedTokens() {
        let environment = AIService.restrictedEnvironment(from: [
            "HOME": "/Users/test",
            "PATH": "/usr/bin",
            "CODEX_HOME": "/Users/test/.codex",
            "GH_TOKEN": "github-secret",
            "OPENAI_API_KEY": "openai-secret",
            "ANTHROPIC_API_KEY": "anthropic-secret",
            "UNRELATED_SECRET": "other-secret",
        ])

        XCTAssertEqual(environment["HOME"], "/Users/test")
        XCTAssertEqual(environment["CODEX_HOME"], "/Users/test/.codex")
        XCTAssertNil(environment["GH_TOKEN"])
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["UNRELATED_SECRET"])
    }

    func testCompletePreservesTimeoutAndUsesEphemeralWorkingDirectory() async throws {
        let runner = MockProcessRunner()
        runner.defaultResult = CommandResult(exitCode: 0, stdout: "{}", stderr: "")
        let service = AIService(
            runner: runner,
            claudePath: "/claude",
            codexPath: "/codex"
        )

        _ = try await service.complete(prompt: "review", tool: .codex)

        let command = try XCTUnwrap(runner.commands.first)
        XCTAssertEqual(command.timeout, AIService.defaultAnalysisTimeout)
        XCTAssertEqual(command.stdin, "review")
        let workingDirectory = try XCTUnwrap(command.workingDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory))
        XCTAssertNil(command.environment?["GH_TOKEN"])
    }

    func testSkillPromptFilesFailClosedWhenAnySelectionIsUnreadable() throws {
        XCTAssertThrowsError(
            try AIService.loadSkillPromptFiles([
                "/path/that/does/not/exist/review-skill.md"
            ])
        ) { error in
            XCTAssertTrue("\(error)".contains("review-skill.md"))
        }
    }

    func testAnalyzeRequiresSkillPlaceholderWhenGuidelinesAreConfigured() async {
        let runner = MockProcessRunner()
        let service = AIService(
            runner: runner,
            claudePath: "/claude",
            codexPath: "/codex"
        )
        var settings = AppSettings()
        settings.promptTemplate = "Title: {{TITLE}}\nDiff: {{DIFF}}"
        settings.reviewSkill = "Check concurrency."

        do {
            _ = try await service.analyze(
                title: "Title",
                body: "",
                diff: "diff",
                settings: settings
            )
            XCTFail("Expected a missing {{SKILL}} placeholder error")
        } catch {
            XCTAssertTrue("\(error)".contains("{{SKILL}}"))
            XCTAssertTrue(runner.commands.isEmpty)
        }
    }

    func testDiffTruncationIndicatorUsesPromptLimit() {
        XCTAssertFalse(AIService.isDiffTruncated(String(repeating: "a", count: 60_000)))
        XCTAssertTrue(AIService.isDiffTruncated(String(repeating: "a", count: 60_001)))
    }
    // AC4 — parse clean JSON.
    func testParseCleanJSON() {
        let raw = """
        {"summary":"Adds retry","reviewPoints":[{"severity":"high","text":"no backoff"}],
         "inlineComments":[{"path":"a.swift","line":5,"side":"RIGHT","body":"guard nil"}]}
        """
        let a = AIService.parseAnalysis(raw)
        XCTAssertEqual(a.summary, "Adds retry")
        XCTAssertEqual(a.reviewPoints.count, 1)
        XCTAssertEqual(a.reviewPoints[0].severity, .high)
        XCTAssertEqual(a.inlineComments.count, 1)
        XCTAssertEqual(a.inlineComments[0].line, 5)
    }

    // AC5 — tolerate code fences and surrounding prose.
    func testParseFencedJSON() {
        let raw = """
        Sure, here is the review:
        ```json
        { "summary": "Fixes a crash", "reviewPoints": [], "inlineComments": [] }
        ```
        Hope that helps!
        """
        let a = AIService.parseAnalysis(raw)
        XCTAssertEqual(a.summary, "Fixes a crash")
        XCTAssertTrue(a.reviewPoints.isEmpty)
    }

    // AC5 — non-JSON falls back to raw text as summary.
    func testParseFallback() {
        let a = AIService.parseAnalysis("I could not analyze this.")
        XCTAssertEqual(a.summary, "I could not analyze this.")
        XCTAssertTrue(a.inlineComments.isEmpty)
    }

    // AC5 — nested braces inside strings don't break extraction.
    func testExtractJSONWithBracesInStrings() {
        let raw = #"prefix {"summary":"use {token} here","reviewPoints":[],"inlineComments":[]} suffix"#
        let a = AIService.parseAnalysis(raw)
        XCTAssertEqual(a.summary, "use {token} here")
    }

    func testBuildPromptSubstitutesAndClips() {
        let template = "T:{{TITLE}} B:{{BODY}} D:{{DIFF}}"
        let prompt = AIService.buildPrompt(template: template, title: "hi", body: "", diff: String(repeating: "x", count: 100), maxDiffChars: 10)
        XCTAssertTrue(prompt.contains("T:hi"))
        XCTAssertTrue(prompt.contains("B:(none)"))
        XCTAssertTrue(prompt.contains("[diff truncated]"))
    }

    func testBuildPromptUsesChildSkillPromptsInBaseFileMode() {
        let prompt = AIService.buildPrompt(
            template: "Base\n{{SKILL}}\nD:{{DIFF}}",
            title: "title",
            body: "body",
            diff: "diff",
            skill: "Base guideline",
            skillPrompts: ["Security checks", "Accessibility checks"],
            maxDiffChars: 1000
        )

        XCTAssertTrue(prompt.contains("Base guideline"))
        XCTAssertTrue(prompt.contains("Security checks"))
        XCTAssertTrue(prompt.contains("Accessibility checks"))
        XCTAssertTrue(prompt.contains("---"))
    }

    func testBuildPromptAlwaysIncludesGuidelineFiles() {
        let prompt = AIService.buildPrompt(
            template: "{{SKILL}}",
            title: "title",
            body: "body",
            diff: "diff",
            skill: "Inline guideline",
            skillPrompts: ["External file guideline"],
            maxDiffChars: 1000
        )

        XCTAssertTrue(prompt.contains("Inline guideline"))
        XCTAssertTrue(prompt.contains("External file guideline"))
    }

    func testImportedGuidelinesAreFilteredByRepositoryAndChangedPath() {
        var settings = AppSettings()
        settings.importedReviewGuidelines = [
            ImportedReviewGuideline(
                repository: "acme/app",
                path: "AGENTS.md",
                revision: "root",
                category: .review,
                reason: "",
                content: "Root rule"
            ),
            ImportedReviewGuideline(
                repository: "acme/app",
                path: "Sources/API/AGENTS.md",
                revision: "api",
                category: .conventions,
                reason: "",
                content: "API rule"
            ),
            ImportedReviewGuideline(
                repository: "other/app",
                path: "AGENTS.md",
                revision: "other",
                category: .review,
                reason: "",
                content: "Other rule"
            ),
        ]

        let prompts = AIService.importedGuidelinePrompts(
            repository: "acme/app",
            diff: "diff --git a/Sources/UI/View.swift b/Sources/UI/View.swift",
            settings: settings
        )

        XCTAssertTrue(prompts.contains { $0.contains("Root rule") })
        XCTAssertFalse(prompts.contains { $0.contains("API rule") })
        XCTAssertFalse(prompts.contains { $0.contains("Other rule") })
    }

    // Usage: parse claude JSON wrapper for text + tokens + cost.
    func testParseClaudeJSONUsage() {
        let raw = """
        {"type":"result","result":"{\\"summary\\":\\"ok\\"}","total_cost_usd":0.0123,
         "usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":50,"cache_creation_input_tokens":0}}
        """
        let (text, usage) = AIService.parseClaudeJSON(raw)
        XCTAssertEqual(text, "{\"summary\":\"ok\"}")
        XCTAssertEqual(usage?.costUSD, 0.0123)
        XCTAssertEqual(usage?.tokens, 1250) // 1000 + 50 cache + 200 output
    }

    func testParseClaudeJSONFallback() {
        let (text, usage) = AIService.parseClaudeJSON("plain text not json")
        XCTAssertEqual(text, "plain text not json")
        XCTAssertNil(usage)
    }

    // Usage: parse codex "tokens used" from stderr (no cost).
    func testParseCodexUsage() {
        XCTAssertEqual(AIService.parseCodexUsage("hook: Stop\ntokens used\n34,772\n")?.totalTokens, 34772)
        XCTAssertEqual(AIService.parseCodexUsage("tokens used 5123")?.totalTokens, 5123)
        XCTAssertNil(AIService.parseCodexUsage("no usage here"))
    }

    func testEstimateCodexCostUsesPromptApproximationAndConfiguredPrices() {
        let usage = AIService.estimateCodexCost(
            usage: AIUsage(totalTokens: 1_000),
            prompt: String(repeating: "a", count: 400),
            inputPricePerMillion: 2,
            outputPricePerMillion: 10
        )
        XCTAssertEqual(usage?.inputTokens, 100)
        XCTAssertEqual(usage?.outputTokens, 900)
        XCTAssertEqual(usage?.costUSD ?? -1, 0.0092, accuracy: 0.000_001)
    }

    func testEstimateCodexCostLeavesCostUnknownWhenPricesUnset() {
        let usage = AIService.estimateCodexCost(
            usage: AIUsage(totalTokens: 10),
            prompt: "abcd",
            inputPricePerMillion: -1,
            outputPricePerMillion: -1
        )
        XCTAssertNil(usage?.costUSD)
    }

    func testUsageLabel() {
        XCTAssertEqual(AIUsage(totalTokens: 1234, costUSD: 0.05).label(), "1,234 tokens · $0.0500")
        XCTAssertEqual(AIUsage(totalTokens: 34772).label(), "34,772 tokens")
    }

    // AC6 — correct CLI command per tool, prompt sent on stdin.
    func testAnalyzeUsesCorrectCommand() async throws {
        let mock = MockProcessRunner()
        mock.defaultResult = CommandResult(exitCode: 0, stdout: #"{"summary":"ok"}"#, stderr: "")
        let service = AIService(runner: mock, claudePath: "/bin/claude", codexPath: "/bin/codex")

        var claudeSettings = AppSettings(); claudeSettings.aiTool = .claude
        _ = try await service.analyze(title: "t", body: "b", diff: "d", settings: claudeSettings)
        XCTAssertEqual(mock.commands.last?.executable, "/bin/claude")
        XCTAssertTrue(mock.commands.last?.arguments.contains("-p") ?? false)
        XCTAssertNotNil(mock.commands.last?.stdin)

        var codexSettings = AppSettings(); codexSettings.aiTool = .codex
        _ = try await service.analyze(title: "t", body: "b", diff: "d", settings: codexSettings)
        XCTAssertEqual(mock.commands.last?.executable, "/bin/codex")
        XCTAssertEqual(mock.commands.last?.arguments.first, "exec")
        // Must run from a non-git CWD and not execute shell commands.
        XCTAssertTrue(mock.commands.last?.arguments.contains("--skip-git-repo-check") ?? false)
        XCTAssertTrue(mock.commands.last?.arguments.contains("read-only") ?? false)
    }
}
