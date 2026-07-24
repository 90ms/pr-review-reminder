import Foundation

/// Persistence abstraction so history is testable without touching the disk.
public protocol HistoryPersisting: Sendable {
    func read() -> Data?
    func write(_ data: Data)
}

/// Stores history as JSON in Application Support/PRReviewReminder/history.json.
public struct FileHistoryPersistence: HistoryPersisting {
    private let url: URL

    public init(fileManager: FileManager = .default) {
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("PRReviewReminder", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("history.json")
    }

    public func read() -> Data? { try? Data(contentsOf: url) }
    public func write(_ data: Data) {
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
        } catch {
            // Persistence remains best-effort; callers keep the in-memory copy.
        }
    }
}

/// Loads/saves review history and computes cumulative usage.
public final class HistoryStore: @unchecked Sendable {
    private let persistence: HistoryPersisting
    private var records: [ReviewRecord]

    public init(persistence: HistoryPersisting = FileHistoryPersistence()) {
        self.persistence = persistence
        if let data = persistence.read(),
           let decoded = try? Self.decoder.decode([ReviewRecord].self, from: data) {
            self.records = decoded
        } else {
            self.records = []
        }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()

    /// All records, newest first.
    public func all() -> [ReviewRecord] {
        records.sorted { $0.reviewedAt > $1.reviewedAt }
    }

    /// Cache lookup by (PR, head commit).
    public func record(repository: String, number: Int, headSha: String) -> ReviewRecord? {
        let id = ReviewRecord.id(repository: repository, number: number, headSha: headSha)
        return records.first { $0.id == id }
    }

    /// Insert or replace a record with the same id (same PR + head commit).
    public func upsert(_ record: ReviewRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        persist()
    }

    public func delete(id: String) {
        records.removeAll { $0.id == id }
        persist()
    }

    public func deleteAll() {
        records.removeAll()
        persist()
    }

    /// Removes records older than the configured number of days. A non-positive
    /// value means "keep until manually deleted".
    public func applyRetention(days: Int, now: Date = Date()) {
        guard days > 0,
              let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: now)
        else { return }
        records.removeAll { $0.reviewedAt < cutoff }
        persist()
    }

    /// Cumulative token and cost totals across all records.
    public func totals() -> (tokens: Int, costUSD: Double, count: Int) {
        var tokens = 0
        var cost = 0.0
        for r in records {
            tokens += r.usage?.tokens ?? 0
            cost += r.usage?.costUSD ?? 0
        }
        return (tokens, cost, records.count)
    }

    private func persist() {
        if let data = try? Self.encoder.encode(records) {
            persistence.write(data)
        }
    }
}
