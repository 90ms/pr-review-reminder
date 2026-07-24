import Foundation

/// Minimal key-value abstraction so persistence is testable without a real
/// UserDefaults suite. `UserDefaults` conforms to this out of the box.
public protocol KeyValueStore: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: KeyValueStore {}

/// Loads and saves `AppSettings`.
public final class SettingsStore: @unchecked Sendable {
    private let store: KeyValueStore
    private let key: String
    public private(set) var diagnostic = StorageDiagnostic(
        health: .empty,
        location: "UserDefaults: app.settings"
    )

    public init(store: KeyValueStore = UserDefaults.standard, key: String = "app.settings") {
        self.store = store
        self.key = key
    }

    public func load() -> AppSettings {
        guard let data = store.data(forKey: key) else {
            diagnostic = StorageDiagnostic(
                health: .empty,
                location: "UserDefaults: \(key)"
            )
            return AppSettings()
        }
        do {
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            diagnostic = StorageDiagnostic(
                health: .healthy,
                location: "UserDefaults: \(key)",
                byteCount: data.count
            )
            return settings
        } catch {
            diagnostic = StorageDiagnostic(
                health: .decodeFailed(error.localizedDescription),
                location: "UserDefaults: \(key)",
                byteCount: data.count
            )
            return AppSettings()
        }
    }

    public func save(_ settings: AppSettings) {
        do {
            let data = try JSONEncoder().encode(settings)
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
