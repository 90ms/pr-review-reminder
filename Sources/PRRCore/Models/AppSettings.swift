import Foundation

public enum AITool: String, Sendable, Codable, CaseIterable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// How often collection runs.
public enum ScheduleMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case dailyAt      // once per day at `dailyHour:dailyMinute`
    case everyNHours  // every `intervalHours`

    public var id: String { rawValue }
}

public struct AppSettings: Sendable, Codable, Equatable {
    /// GitHub org/owner to scan (e.g. "fastlane-dev"). Required.
    public var owner: String
    /// Optional explicit repo names to restrict to (empty = all repos in org).
    public var repositories: [String]
    public var aiTool: AITool
    public var scheduleMode: ScheduleMode
    public var dailyHour: Int
    public var dailyMinute: Int
    public var intervalHours: Int
    public var notificationsEnabled: Bool
    /// User-editable prompt template. `{{DIFF}}`, `{{TITLE}}`, `{{BODY}}`, `{{SKILL}}` are substituted.
    public var promptTemplate: String
    /// UI language of the app. `.system` follows the OS locale.
    public var appLanguage: AppLanguage
    /// Language the AI should write the review in. `.system` follows the OS locale.
    public var reviewLanguage: AppLanguage
    /// Extra reviewer guidelines / "skill" injected into the prompt via `{{SKILL}}`.
    public var reviewSkill: String
    /// Repository to file user feedback into as GitHub issues ("owner/repo"). Empty = hold.
    public var feedbackRepository: String
    /// When true, code review runs automatically for every fetched PR. When false
    /// (default), collection only fetches PRs and review is triggered per-PR by the user.
    public var autoReview: Bool

    public init(
        owner: String = "fastlane-dev",
        repositories: [String] = [],
        aiTool: AITool = .claude,
        scheduleMode: ScheduleMode = .dailyAt,
        dailyHour: Int = 10,
        dailyMinute: Int = 0,
        intervalHours: Int = 4,
        notificationsEnabled: Bool = true,
        promptTemplate: String = AppSettings.defaultPromptTemplate,
        appLanguage: AppLanguage = .system,
        reviewLanguage: AppLanguage = .system,
        reviewSkill: String = "",
        feedbackRepository: String = "",
        autoReview: Bool = false
    ) {
        self.owner = owner
        self.repositories = repositories
        self.aiTool = aiTool
        self.scheduleMode = scheduleMode
        self.dailyHour = dailyHour
        self.dailyMinute = dailyMinute
        self.intervalHours = intervalHours
        self.notificationsEnabled = notificationsEnabled
        self.promptTemplate = promptTemplate
        self.appLanguage = appLanguage
        self.reviewLanguage = reviewLanguage
        self.reviewSkill = reviewSkill
        self.feedbackRepository = feedbackRepository
        self.autoReview = autoReview
    }

    // Tolerant decoding: missing keys (e.g. from an older saved schema) fall back
    // to defaults instead of failing the whole decode and wiping user settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? d.owner
        repositories = try c.decodeIfPresent([String].self, forKey: .repositories) ?? d.repositories
        aiTool = try c.decodeIfPresent(AITool.self, forKey: .aiTool) ?? d.aiTool
        scheduleMode = try c.decodeIfPresent(ScheduleMode.self, forKey: .scheduleMode) ?? d.scheduleMode
        dailyHour = try c.decodeIfPresent(Int.self, forKey: .dailyHour) ?? d.dailyHour
        dailyMinute = try c.decodeIfPresent(Int.self, forKey: .dailyMinute) ?? d.dailyMinute
        intervalHours = try c.decodeIfPresent(Int.self, forKey: .intervalHours) ?? d.intervalHours
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        promptTemplate = try c.decodeIfPresent(String.self, forKey: .promptTemplate) ?? d.promptTemplate
        appLanguage = try c.decodeIfPresent(AppLanguage.self, forKey: .appLanguage) ?? d.appLanguage
        reviewLanguage = try c.decodeIfPresent(AppLanguage.self, forKey: .reviewLanguage) ?? d.reviewLanguage
        reviewSkill = try c.decodeIfPresent(String.self, forKey: .reviewSkill) ?? d.reviewSkill
        feedbackRepository = try c.decodeIfPresent(String.self, forKey: .feedbackRepository) ?? d.feedbackRepository
        autoReview = try c.decodeIfPresent(Bool.self, forKey: .autoReview) ?? d.autoReview
    }

    public static let defaultPromptTemplate = """
    You are a senior code reviewer. Review the following pull request diff.
    {{SKILL}}
    Title: {{TITLE}}
    Description:
    {{BODY}}

    Diff:
    {{DIFF}}

    Respond with ONLY a JSON object, no prose, no code fences, matching:
    {
      "summary": "2-3 sentences on what this PR does",
      "reviewPoints": [{ "severity": "high|medium|low", "text": "..." }],
      "inlineComments": [{ "path": "file", "line": 42, "side": "RIGHT", "body": "..." }]
    }
    Only include inlineComments you are confident about. Use paths and line numbers from the diff.
    """
}
