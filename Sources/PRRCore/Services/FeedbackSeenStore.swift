import Foundation

public protocol FeedbackSeenPersisting: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

public struct FeedbackSeenFilePersistence: FeedbackSeenPersisting {
    public let url: URL

    public init(url: URL = FeedbackSeenFilePersistence.defaultURL()) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("PRReviewReminder", isDirectory: true)
            .appendingPathComponent("feedback-seen.json")
    }

    public func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func write(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }
}

public final class FeedbackSeenStore: @unchecked Sendable {
    private let persistence: FeedbackSeenPersisting
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(persistence: FeedbackSeenPersisting = FeedbackSeenFilePersistence()) {
        self.persistence = persistence
    }

    public func load() -> [String: String] {
        guard let data = try? persistence.read() else { return [:] }
        return (try? decoder.decode([String: String].self, from: data)) ?? [:]
    }

    public func save(_ latestReviewIDsByPR: [String: String]) {
        guard let data = try? encoder.encode(latestReviewIDsByPR) else { return }
        try? persistence.write(data)
    }
}
