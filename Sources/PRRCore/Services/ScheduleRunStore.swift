import Foundation

public struct ScheduleRunRecord: Codable, Identifiable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case success
        case failure
    }

    public let id: UUID
    public let date: Date
    public let outcome: Outcome
    public let itemCount: Int
    public let message: String?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        outcome: Outcome,
        itemCount: Int,
        message: String? = nil
    ) {
        self.id = id
        self.date = date
        self.outcome = outcome
        self.itemCount = itemCount
        self.message = message
    }
}

public final class ScheduleRunStore: @unchecked Sendable {
    private let store: KeyValueStore
    private let key: String
    private let limit: Int

    public init(
        store: KeyValueStore = UserDefaults.standard,
        key: String = "schedule.runs",
        limit: Int = 20
    ) {
        self.store = store
        self.key = key
        self.limit = max(1, limit)
    }

    public func all() -> [ScheduleRunRecord] {
        guard let data = store.data(forKey: key),
              let records = try? JSONDecoder().decode([ScheduleRunRecord].self, from: data)
        else { return [] }
        return Array(records.sorted { $0.date > $1.date }.prefix(limit))
    }

    public func append(_ record: ScheduleRunRecord) {
        let records = Array(([record] + all()).prefix(limit))
        guard let data = try? JSONEncoder().encode(records) else { return }
        store.set(data, forKey: key)
    }
}
