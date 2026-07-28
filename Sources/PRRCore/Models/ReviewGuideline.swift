import Foundation

public enum ReviewGuidelineCategory: String, Sendable, Codable, CaseIterable {
    case review
    case conventions
    case architecture
}

/// A repository document selected by the configured AI as relevant review context.
public struct ImportedReviewGuideline: Sendable, Codable, Equatable, Identifiable {
    public let repository: String
    public let path: String
    public let revision: String
    public let category: ReviewGuidelineCategory
    public let reason: String
    public let content: String
    public let importedAt: Date

    public var id: String { "\(repository):\(path)" }

    public init(
        repository: String,
        path: String,
        revision: String,
        category: ReviewGuidelineCategory,
        reason: String,
        content: String,
        importedAt: Date = Date()
    ) {
        self.repository = repository
        self.path = path
        self.revision = revision
        self.category = category
        self.reason = reason
        self.content = content
        self.importedAt = importedAt
    }

    /// AGENTS.md files are scoped to their containing directory. Other imported
    /// project documents are treated as repository-wide guidance.
    public func applies(to changedPaths: [String]) -> Bool {
        guard (path as NSString).lastPathComponent.caseInsensitiveCompare("AGENTS.md") == .orderedSame else {
            return true
        }
        let directory = (path as NSString).deletingLastPathComponent
        guard !directory.isEmpty, directory != "." else { return true }
        return changedPaths.contains { $0 == directory || $0.hasPrefix("\(directory)/") }
    }
}

public struct ReviewGuidelineCandidate: Sendable, Equatable {
    public let repository: String
    public let path: String
    public let revision: String
    public let content: String

    public init(repository: String, path: String, revision: String, content: String) {
        self.repository = repository
        self.path = path
        self.revision = revision
        self.content = content
    }
}
