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

    public init(store: KeyValueStore = UserDefaults.standard, key: String = "app.settings") {
        self.store = store
        self.key = key
    }

    public func load() -> AppSettings {
        guard let data = store.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        store.set(data, forKey: key)
    }
}
