import Foundation

/// Constructs and, only on explicit user action, creates a GitHub issue in this
/// project's repository. It can also tidy the draft via the AI CLI.
public struct FeedbackService: Sendable {
    public static let repository = "90ms/pr-review-reminder"

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

    public static func viewIssueCommand(gh: String, repository: String, number: Int) -> Command {
        Command(executable: gh, arguments: [
            "issue", "view", "\(number)", "-R", repository, "--json",
            "number,title,state,stateReason,url,updatedAt,closedAt"
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
    private struct IssueStatusDTO: Decodable {
        let title: String?
        let state: String?
        let stateReason: String?
        let url: String?
        let updatedAt: Date?
        let closedAt: Date?
    }

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
        /// GitHub CLI is unavailable, so nothing was executed.
        case held(preview: String)
        /// Issue created; carries stdout (e.g. the issue URL) and local tracking metadata.
        case created(output: String, record: FeedbackRecord?)
    }

    /// Submits feedback to the project repository. Without an available GitHub
    /// service, returns `.held` with a preview and does not execute anything.
    public func submit(title: String, body: String, ghPath: String?) async throws -> SubmitResult {
        let gh = ghPath ?? "gh"
        guard let github else {
            return .held(preview: Self.previewString(
                gh: gh,
                repository: Self.repository,
                title: title,
                body: body
            ))
        }
        let result = try await github.createIssue(
            repository: Self.repository,
            title: title,
            body: body
        )
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return .created(
            output: output,
            record: Self.parseCreatedIssue(
                output,
                repository: Self.repository,
                title: title,
                body: body
            )
        )
    }

    public static func parseCreatedIssue(
        _ output: String,
        repository: String,
        title: String,
        body: String,
        createdAt: Date = Date()
    ) -> FeedbackRecord? {
        let pattern = #"https://github\.com/\#(NSRegularExpression.escapedPattern(for: repository))/issues/([0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let numberRange = Range(match.range(at: 1), in: output),
              let number = Int(output[numberRange]) else {
            return nil
        }
        return FeedbackRecord(
            repository: repository,
            number: number,
            title: title,
            body: body,
            url: "https://github.com/\(repository)/issues/\(number)",
            createdAt: createdAt
        )
    }

    public static func parseIssueStatus(_ raw: String) throws -> FeedbackIssueStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dto = try decoder.decode(IssueStatusDTO.self, from: Data(raw.utf8))
        return FeedbackIssueStatus(
            title: dto.title,
            url: dto.url,
            state: FeedbackIssueState(githubState: dto.state),
            stateReason: dto.stateReason,
            updatedAt: dto.updatedAt,
            closedAt: dto.closedAt
        )
    }
}
