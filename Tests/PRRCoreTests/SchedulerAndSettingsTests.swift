import XCTest
@testable import PRRCore

final class SchedulerAndSettingsTests: XCTestCase {
    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: iso)!
    }

    // AC9 — interval scheduling.
    func testEveryNHours() {
        var s = AppSettings(); s.scheduleMode = .everyNHours; s.intervalHours = 3
        let now = date("2026-07-24T10:00:00Z")
        let next = Scheduler.nextRunDate(after: now, settings: s, calendar: utcCalendar())
        XCTAssertEqual(next, now.addingTimeInterval(3 * 3600))
    }

    // AC9 — daily time later today.
    func testDailyLaterToday() {
        var s = AppSettings(); s.scheduleMode = .dailyAt; s.dailyHour = 18; s.dailyMinute = 30
        let now = date("2026-07-24T10:00:00Z")
        let next = Scheduler.nextRunDate(after: now, settings: s, calendar: utcCalendar())
        XCTAssertEqual(next, date("2026-07-24T18:30:00Z"))
    }

    // AC9 — daily time already passed rolls to tomorrow.
    func testDailyRollsToTomorrow() {
        var s = AppSettings(); s.scheduleMode = .dailyAt; s.dailyHour = 9; s.dailyMinute = 0
        let now = date("2026-07-24T10:00:00Z")
        let next = Scheduler.nextRunDate(after: now, settings: s, calendar: utcCalendar())
        XCTAssertEqual(next, date("2026-07-25T09:00:00Z"))
    }

    // AC1 — settings persist and restore.
    func testSettingsRoundTrip() {
        final class MemStore: KeyValueStore {
            var storage: [String: Data] = [:]
            func data(forKey k: String) -> Data? { storage[k] }
            func set(_ value: Any?, forKey k: String) { storage[k] = value as? Data }
        }
        let mem = MemStore()
        let store = SettingsStore(store: mem, key: "k")
        // default when empty
        XCTAssertEqual(store.load().owner, "fastlane-dev")

        var s = AppSettings(); s.owner = "acme"; s.aiTool = .codex; s.intervalHours = 12
        store.save(s)
        let loaded = store.load()
        XCTAssertEqual(loaded.owner, "acme")
        XCTAssertEqual(loaded.aiTool, .codex)
        XCTAssertEqual(loaded.intervalHours, 12)
    }

    func testCorruptSettingsAreReportedBeforeFallingBackToDefaults() {
        final class MemStore: KeyValueStore {
            var data = Data("{bad-json".utf8)
            func data(forKey key: String) -> Data? { data }
            func set(_ value: Any?, forKey key: String) { data = value as? Data ?? data }
        }
        let store = SettingsStore(store: MemStore(), key: "corrupt")

        let settings = store.load()

        XCTAssertEqual(settings, AppSettings())
        guard case .decodeFailed = store.diagnostic.health else {
            return XCTFail("Expected a decode failure diagnostic")
        }
        XCTAssertGreaterThan(store.diagnostic.byteCount, 0)
    }
}
