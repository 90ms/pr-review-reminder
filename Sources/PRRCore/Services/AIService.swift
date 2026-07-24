import Foundation

public struct AIError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Wraps the `claude` / `codex` CLIs to analyze a PR. Uses the user's existing
/// CLI subscription; never handles API keys.
public final class AIService: Sendable {
    private let runner: ProcessRunning
    private let claudePath: String?
    private let codexPath: String?
    private let maxDiffChars: Int

    public init(runner: ProcessRunning, claudePath: String?, codexPath: String?, maxDiffChars: Int = 60_000) {
        self.runner = runner
        self.claudePath = claudePath
        self.codexPath = codexPath
        self.maxDiffChars = maxDiffChars
    }

    // MARK: - Prompt (pure, testable)

    public static func buildPrompt(template: String, title: String, body: String, diff: String,
                                   skill: String = "", languageDirective: String = "", maxDiffChars: Int) -> String {
        let clippedDiff = diff.count > maxDiffChars
            ? String(diff.prefix(maxDiffChars)) + "\n… [diff truncated]"
            : diff
        let skillBlock = skill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : "Reviewer guidelines / skill:\n\(skill)\n"
        var prompt = template
            .replacingOccurrences(of: "{{TITLE}}", with: title)
            .replacingOccurrences(of: "{{BODY}}", with: body.isEmpty ? "(none)" : body)
            .replacingOccurrences(of: "{{DIFF}}", with: clippedDiff)
            .replacingOccurrences(of: "{{SKILL}}", with: skillBlock)
        if !languageDirective.isEmpty {
            prompt += "\n\(languageDirective)"
        }
        return prompt
    }

    // MARK: - Command builders (pure, testable)

    /// claude reads the prompt from stdin in print mode. JSON output carries token
    /// usage and cost alongside the result text.
    public static func claudeCommand(claude: String) -> Command {
        Command(executable: claude, arguments: ["-p", "--output-format", "json"])
    }

    /// codex executes a one-shot prompt from stdin. `--skip-git-repo-check` lets it
    /// run from an arbitrary working directory (the app's CWD is not a git repo), and
    /// `-s read-only` keeps it from executing model-generated shell commands.
    public static func codexCommand(codex: String) -> Command {
        Command(executable: codex, arguments: ["exec", "--skip-git-repo-check", "-s", "read-only", "-"])
    }

    // MARK: - Lenient JSON parsing (pure, testable)

    /// Extracts the first balanced JSON object from arbitrary model output
    /// (strips code fences / surrounding prose).
    public static func extractJSONObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if escape { escape = false }
            else if ch == "\\" { escape = true }
            else if ch == "\"" { inString.toggle() }
            else if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...idx])
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    private struct AnalysisDTO: Decodable {
        struct Point: Decodable { let severity: String?; let text: String? }
        struct Inline: Decodable { let path: String?; let line: Int?; let side: String?; let body: String? }
        let summary: String?
        let reviewPoints: [Point]?
        let inlineComments: [Inline]?
    }

    /// Parses model output into `Analysis`, tolerating fences/prose. Falls back to
    /// putting the raw text in `summary` when no valid JSON is present.
    public static func parseAnalysis(_ raw: String) -> Analysis {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonString = extractJSONObject(trimmed),
              let data = jsonString.data(using: .utf8),
              let dto = try? JSONDecoder().decode(AnalysisDTO.self, from: data) else {
            return Analysis(summary: trimmed.isEmpty ? "(no analysis produced)" : trimmed)
        }
        let points = (dto.reviewPoints ?? []).compactMap { p -> ReviewPoint? in
            guard let text = p.text, !text.isEmpty else { return nil }
            return ReviewPoint(severity: Severity(lenient: p.severity), text: text)
        }
        let inline = (dto.inlineComments ?? []).compactMap { c -> InlineComment? in
            guard let path = c.path, let line = c.line, let body = c.body, !body.isEmpty else { return nil }
            let side = (c.side?.uppercased() == "LEFT") ? "LEFT" : "RIGHT"
            return InlineComment(path: path, line: line, side: side, body: body)
        }
        return Analysis(
            summary: dto.summary?.isEmpty == false ? dto.summary! : "(no summary)",
            reviewPoints: points,
            inlineComments: inline
        )
    }

    // MARK: - Usage parsing (pure, testable)

    private struct ClaudeResultDTO: Decodable {
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_read_input_tokens: Int?
            let cache_creation_input_tokens: Int?
        }
        let result: String?
        let total_cost_usd: Double?
        let usage: Usage?
    }

    /// Parses claude's `--output-format json` wrapper into (result text, usage).
    /// Falls back to (raw, nil) when the output isn't the expected JSON.
    public static func parseClaudeJSON(_ stdout: String) -> (text: String, usage: AIUsage?) {
        guard let json = extractJSONObject(stdout),
              let data = json.data(using: .utf8),
              let dto = try? JSONDecoder().decode(ClaudeResultDTO.self, from: data),
              dto.result != nil || dto.usage != nil || dto.total_cost_usd != nil else {
            return (stdout, nil)
        }
        let input = (dto.usage?.input_tokens ?? 0)
            + (dto.usage?.cache_read_input_tokens ?? 0)
            + (dto.usage?.cache_creation_input_tokens ?? 0)
        let output = dto.usage?.output_tokens ?? 0
        let usage = AIUsage(
            inputTokens: dto.usage != nil ? input : nil,
            outputTokens: dto.usage?.output_tokens,
            totalTokens: dto.usage != nil ? input + output : nil,
            costUSD: dto.total_cost_usd
        )
        return (dto.result ?? stdout, usage)
    }

    /// Parses codex's "tokens used <N>" line from stderr (cost not reported).
    public static func parseCodexUsage(_ stderr: String) -> AIUsage? {
        guard let range = stderr.range(of: "tokens used") else { return nil }
        let tail = stderr[range.upperBound...]
        let grabbed = tail.prefix { $0.isWhitespace || $0.isNumber || $0 == "," }
        let digits = grabbed.filter { $0.isNumber }
        guard let total = Int(digits) else { return nil }
        return AIUsage(totalTokens: total)
    }

    // MARK: - Async operation

    public func analyze(title: String, body: String, diff: String, settings: AppSettings) async throws -> (analysis: Analysis, usage: AIUsage?) {
        let prompt = Self.buildPrompt(
            template: settings.promptTemplate,
            title: title, body: body, diff: diff,
            skill: settings.reviewSkill,
            languageDirective: settings.reviewLanguage.promptDirective(),
            maxDiffChars: maxDiffChars
        )
        let (text, usage) = try await completeText(prompt: prompt, tool: settings.aiTool)
        return (Self.parseAnalysis(text), usage)
    }

    /// Runs a prompt and returns the model's text plus token/cost usage.
    public func completeText(prompt: String, tool: AITool) async throws -> (text: String, usage: AIUsage?) {
        let result = try await complete(prompt: prompt, tool: tool)
        switch tool {
        case .claude:
            return Self.parseClaudeJSON(result.stdout)
        case .codex:
            return (result.stdout, Self.parseCodexUsage(result.stderr))
        }
    }

    /// Runs an arbitrary prompt through the selected CLI and returns the full result.
    public func complete(prompt: String, tool: AITool) async throws -> CommandResult {
        let command: Command
        switch tool {
        case .claude:
            guard let claude = claudePath else { throw AIError("claude CLI not found") }
            command = Self.claudeCommand(claude: claude)
        case .codex:
            guard let codex = codexPath else { throw AIError("codex CLI not found") }
            command = Self.codexCommand(codex: codex)
        }
        let withStdin = Command(executable: command.executable, arguments: command.arguments, stdin: prompt)
        let result = try await runner.run(withStdin)
        guard result.succeeded else {
            throw AIError("\(tool.displayName) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result
    }
}
