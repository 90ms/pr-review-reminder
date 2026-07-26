import Foundation

public final class FeedbackHistoryStore: @unchecked Sendable {
    private let store: KeyValueStore
    private let key: String
    private var records: [FeedbackRecord]
    public private(set) var diagnostic: StorageDiagnostic

    public init(store: KeyValueStore = UserDefaults.standard, key: String = "feedback.history") {
        self.store = store
        self.key = key
        self.diagnostic = StorageDiagnostic(
            health: .empty,
            location: "UserDefaults: \(key)"
        )
        guard let data = store.data(forKey: key) else {
            self.records = []
            return
        }
        do {
            self.records = try Self.decoder.decode([FeedbackRecord].self, from: data)
            self.diagnostic = StorageDiagnostic(
                health: .healthy,
                location: "UserDefaults: \(key)",
                byteCount: data.count
            )
        } catch {
            self.records = []
            self.diagnostic = StorageDiagnostic(
                health: .decodeFailed(error.localizedDescription),
                location: "UserDefaults: \(key)",
                byteCount: data.count
            )
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public func all() -> [FeedbackRecord] {
        records.sorted { $0.createdAt > $1.createdAt }
    }

    public func upsert(_ record: FeedbackRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        persist()
    }

    private func persist() {
        do {
            let data = try Self.encoder.encode(records)
            store.set(data, forKey: key)
            diagnostic = StorageDiagnostic(
                health: .healthy,
                location: "UserDefaults: \(key)",
                byteCount: data.count,
                lastSavedAt: Date()
            )
        } catch {
            diagnostic = StorageDiagnostic(
                health: .writeFailed(error.localizedDescription),
                location: "UserDefaults: \(key)",
                byteCount: diagnostic.byteCount,
                lastSavedAt: diagnostic.lastSavedAt
            )
        }
    }
}
