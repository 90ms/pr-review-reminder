import Foundation

/// Persistence abstraction so history is testable without touching the disk.
public protocol HistoryPersisting: Sendable {
    var location: String { get }
    func read() throws -> Data?
    func write(_ data: Data) throws
    func backupCorruptData(_ data: Data) throws -> String?
}

public extension HistoryPersisting {
    var location: String { "In-memory history" }
    func backupCorruptData(_ data: Data) throws -> String? { nil }
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

    public var location: String { url.path }

    public func read() throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    public func write(_ data: Data) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    public func backupCorruptData(_ data: Data) throws -> String? {
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp).json")
        try data.write(to: backup, options: .atomic)
        return backup.path
    }
}

/// Loads/saves review history and computes cumulative usage.
public final class HistoryStore: @unchecked Sendable {
    private let persistence: HistoryPersisting
    private var records: [ReviewRecord]
    public private(set) var diagnostic: StorageDiagnostic

    public init(persistence: HistoryPersisting = FileHistoryPersistence()) {
        self.persistence = persistence
        self.diagnostic = StorageDiagnostic(
            health: .empty,
            location: persistence.location
        )
        do {
            guard let data = try persistence.read() else {
                self.records = []
                return
            }
            do {
                self.records = try Self.decoder.decode([ReviewRecord].self, from: data)
                self.diagnostic = StorageDiagnostic(
                    health: .healthy,
                    location: persistence.location,
                    byteCount: data.count
                )
            } catch {
                let backup = try? persistence.backupCorruptData(data)
                self.records = []
                self.diagnostic = StorageDiagnostic(
                    health: .decodeFailed(error.localizedDescription),
                    location: persistence.location,
                    byteCount: data.count,
                    backupLocation: backup
                )
            }
        } catch {
            self.records = []
            self.diagnostic = StorageDiagnostic(
                health: .readFailed(error.localizedDescription),
                location: persistence.location
            )
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

    /// Tokens recorded in a rolling local window. Records without usage do not
    /// count; a non-positive window includes all retained history.
    public func tokenTotal(windowDays: Int, now: Date = Date()) -> Int {
        let cutoff = windowDays > 0
            ? Calendar(identifier: .gregorian).date(byAdding: .day, value: -windowDays, to: now)
            : nil
        return records.reduce(into: 0) { total, record in
            if cutoff == nil || record.reviewedAt >= cutoff! {
                total += record.usage?.tokens ?? 0
            }
        }
    }

    private func persist() {
        do {
            let data = try Self.encoder.encode(records)
            try persistence.write(data)
            diagnostic = StorageDiagnostic(
                health: .healthy,
                location: persistence.location,
                byteCount: data.count,
                lastSavedAt: Date()
            )
        } catch {
            diagnostic = StorageDiagnostic(
                health: .writeFailed(error.localizedDescription),
                location: persistence.location,
                byteCount: diagnostic.byteCount,
                lastSavedAt: diagnostic.lastSavedAt,
                backupLocation: diagnostic.backupLocation
            )
        }
    }
}
