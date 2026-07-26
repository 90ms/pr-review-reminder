import Foundation

public enum PRFeedbackStatus: String, Sendable, Equatable, Codable {
    case changesRequested
    case commented
    case awaitingApproval
}

public struct PRReviewFeedback: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let reviewer: String
    public let state: String
    public let submittedAt: Date

    public init(id: String, reviewer: String, state: String, submittedAt: Date) {
        self.id = id
        self.reviewer = reviewer
        self.state = state
        self.submittedAt = submittedAt
    }
}

public struct PRFeedbackItem: Identifiable, Sendable, Equatable, Codable {
    public let pr: PullRequest
    public let reviewDecision: String?
    public let status: PRFeedbackStatus
    public let latestReview: PRReviewFeedback
    public let feedbackCount: Int
    public let newFeedbackCount: Int

    public var id: String { pr.id }

    public init(
        pr: PullRequest,
        reviewDecision: String?,
        status: PRFeedbackStatus,
        latestReview: PRReviewFeedback,
        feedbackCount: Int,
        newFeedbackCount: Int
    ) {
        self.pr = pr
        self.reviewDecision = reviewDecision
        self.status = status
        self.latestReview = latestReview
        self.feedbackCount = feedbackCount
        self.newFeedbackCount = newFeedbackCount
    }
}
