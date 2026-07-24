import Foundation

/// A pull request awaiting the current user's review.
public struct PullRequest: Identifiable, Sendable, Equatable, Codable {
    public let repository: String   // "owner/name"
    public let number: Int
    public let title: String
    public let author: String
    public let additions: Int
    public let deletions: Int
    public let url: String
    public let updatedAt: Date?

    public var id: String { "\(repository)#\(number)" }

    public var owner: String { repository.split(separator: "/").first.map(String.init) ?? "" }
    public var name: String { repository.split(separator: "/").last.map(String.init) ?? "" }

    public init(
        repository: String,
        number: Int,
        title: String,
        author: String,
        additions: Int = 0,
        deletions: Int = 0,
        url: String,
        updatedAt: Date? = nil
    ) {
        self.repository = repository
        self.number = number
        self.title = title
        self.author = author
        self.additions = additions
        self.deletions = deletions
        self.url = url
        self.updatedAt = updatedAt
    }
}
