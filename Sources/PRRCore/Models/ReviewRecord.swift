import Foundation

/// A persisted record of one completed AI review, used for history, cumulative
/// usage, and token-free cache restore.
public struct ReviewRecord: Sendable, Codable, Equatable, Identifiable {
    public let repository: String
    public let number: Int
    public let title: String
    public let author: String
    public let url: String
    public let headSha: String
    public let tool: AITool
    public let reviewedAt: Date
    public let analysis: Analysis
    public let usage: AIUsage?
    public let details: PRDetails

    /// Unique per (PR, head commit) so a re-review of new commits is a new record.
    public var id: String { "\(repository)#\(number)@\(headSha)" }

    public init(repository: String, number: Int, title: String, author: String, url: String,
                headSha: String, tool: AITool, reviewedAt: Date,
                analysis: Analysis, usage: AIUsage?, details: PRDetails) {
        self.repository = repository
        self.number = number
        self.title = title
        self.author = author
        self.url = url
        self.headSha = headSha
        self.tool = tool
        self.reviewedAt = reviewedAt
        self.analysis = analysis
        self.usage = usage
        self.details = details
    }

    public static func id(repository: String, number: Int, headSha: String) -> String {
        "\(repository)#\(number)@\(headSha)"
    }
}
