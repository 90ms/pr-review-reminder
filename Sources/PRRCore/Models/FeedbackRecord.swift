import Foundation

public enum FeedbackIssueState: String, Codable, Sendable, Equatable {
    case open
    case closed
    case unknown

    public init(githubState: String?) {
        switch githubState?.lowercased() {
        case "open":
            self = .open
        case "closed":
            self = .closed
        default:
            self = .unknown
        }
    }
}

public struct FeedbackIssueStatus: Sendable, Equatable {
    public let title: String?
    public let url: String?
    public let state: FeedbackIssueState
    public let stateReason: String?
    public let updatedAt: Date?
    public let closedAt: Date?

    public init(
        title: String? = nil,
        url: String? = nil,
        state: FeedbackIssueState,
        stateReason: String? = nil,
        updatedAt: Date? = nil,
        closedAt: Date? = nil
    ) {
        self.title = title
        self.url = url
        self.state = state
        self.stateReason = stateReason
        self.updatedAt = updatedAt
        self.closedAt = closedAt
    }
}

public struct FeedbackRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let repository: String
    public let number: Int
    public var title: String
    public let body: String
    public var url: String
    public let createdAt: Date
    public var lastCheckedAt: Date?
    public var updatedAt: Date?
    public var closedAt: Date?
    public var state: FeedbackIssueState
    public var stateReason: String?

    public init(
        repository: String,
        number: Int,
        title: String,
        body: String,
        url: String,
        createdAt: Date = Date(),
        lastCheckedAt: Date? = nil,
        updatedAt: Date? = nil,
        closedAt: Date? = nil,
        state: FeedbackIssueState = .open,
        stateReason: String? = nil
    ) {
        self.id = Self.id(repository: repository, number: number)
        self.repository = repository
        self.number = number
        self.title = title
        self.body = body
        self.url = url
        self.createdAt = createdAt
        self.lastCheckedAt = lastCheckedAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.state = state
        self.stateReason = stateReason
    }

    public static func id(repository: String, number: Int) -> String {
        "\(repository)#\(number)"
    }

    public mutating func apply(_ status: FeedbackIssueStatus, checkedAt: Date = Date()) {
        if let title = status.title, !title.isEmpty {
            self.title = title
        }
        if let url = status.url, !url.isEmpty {
            self.url = url
        }
        state = status.state
        stateReason = status.stateReason
        updatedAt = status.updatedAt
        closedAt = status.closedAt
        lastCheckedAt = checkedAt
    }
}
