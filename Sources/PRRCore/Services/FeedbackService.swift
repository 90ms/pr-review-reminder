import Foundation

/// Constructs (and, only on explicit user action, would run) a GitHub issue for
/// user feedback, and can tidy the draft via the AI CLI. While no feedback repo
/// is configured, `submit` only returns a command preview — nothing is executed.
public struct FeedbackService: Sendable {
    private let github: GitHubService?
    private let ai: AIService

    public init(github: GitHubService?, ai: AIService) {
        self.github = github
        self.ai = ai
    }

    // MARK: - Command builder (pure, testable)

    public static func createIssueCommand(gh: String, repository: String, title: String, body: String) -> Command {
        Command(executable: gh, arguments: [
            "issue", "create", "-R", repository, "--title", title, "--body", body
        ])
    }

    /// Human-readable rendering of the command (for the preview box).
    public static func previewString(gh: String, repository: String, title: String, body: String) -> String {
        let cmd = createIssueCommand(gh: gh, repository: repository, title: title, body: body)
        func quote(_ s: String) -> String {
            s.contains(" ") || s.contains("\n") ? "\"\(s.replacingOccurrences(of: "\n", with: "\\n"))\"" : s
        }
        return ([cmd.executable] + cmd.arguments.map(quote)).joined(separator: " ")
    }

    // MARK: - AI tidy

    private struct TidyDTO: Decodable { let title: String?; let body: String? }

    public static func parseTidy(_ raw: String, fallbackTitle: String, fallbackBody: String) -> (title: String, body: String) {
        guard let json = AIService.extractJSONObject(raw),
              let data = json.data(using: .utf8),
              let dto = try? JSONDecoder().decode(TidyDTO.self, from: data) else {
            return (fallbackTitle, fallbackBody)
        }
        return (dto.title?.isEmpty == false ? dto.title! : fallbackTitle,
                dto.body?.isEmpty == false ? dto.body! : fallbackBody)
    }

    public static func tidyPrompt(title: String, body: String, languageDirective: String) -> String {
        """
        Rewrite the following user feedback into a clear, well-structured GitHub issue.
        Keep the user's intent. Produce a concise title and a Markdown body with context,
        steps, and expected behavior where applicable. \(languageDirective)

        User title: \(title)
        User details:
        \(body)

        Respond with ONLY a JSON object, no prose, no code fences:
        { "title": "...", "body": "..." }
        """
    }

    public func tidy(title: String, body: String, settings: AppSettings) async throws -> (title: String, body: String) {
        let prompt = Self.tidyPrompt(title: title, body: body,
                                     languageDirective: settings.reviewLanguage.promptDirective())
        let (text, _) = try await ai.completeText(prompt: prompt, tool: settings.aiTool)
        return Self.parseTidy(text, fallbackTitle: title, fallbackBody: body)
    }

    // MARK: - Submit (guarded)

    public enum SubmitResult: Sendable, Equatable {
        /// No feedback repo set → registration held; carries the command preview.
        case held(preview: String)
        /// Issue created; carries stdout (e.g. the issue URL).
        case created(output: String)
    }

    /// Submits the feedback as a GitHub issue. If no repository is configured,
    /// returns `.held` with a command preview and does NOT execute anything.
    public func submit(title: String, body: String, settings: AppSettings, ghPath: String?) async throws -> SubmitResult {
        let repo = settings.feedbackRepository.trimmingCharacters(in: .whitespacesAndNewlines)
        let gh = ghPath ?? "gh"
        guard !repo.isEmpty, let github else {
            return .held(preview: Self.previewString(gh: gh, repository: repo.isEmpty ? "<owner/repo>" : repo, title: title, body: body))
        }
        let result = try await github.createIssue(repository: repo, title: title, body: body)
        return .created(output: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
