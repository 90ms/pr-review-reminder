import XCTest
@testable import PRRCore

final class AIServiceTests: XCTestCase {
    func testAICommandsHaveFiniteTimeouts() {
        XCTAssertEqual(
            AIService.claudeCommand(claude: "/claude").timeout,
            AIService.defaultAnalysisTimeout
        )
        XCTAssertEqual(
            AIService.codexCommand(codex: "/codex").timeout,
            AIService.defaultAnalysisTimeout
        )
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
