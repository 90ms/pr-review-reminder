import XCTest
@testable import PRRCore

private final class ScheduleMemoryStore: KeyValueStore {
    var values: [String: Data] = [:]
    func data(forKey defaultName: String) -> Data? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value as? Data }
}

final class ScheduleRunStoreTests: XCTestCase {
    func testPersistsNewestRecordsWithinLimit() {
        let memory = ScheduleMemoryStore()
        let store = ScheduleRunStore(store: memory, limit: 2)

        store.append(ScheduleRunRecord(
            date: Date(timeIntervalSince1970: 1),
            outcome: .success,
            itemCount: 1
        ))
        store.append(ScheduleRunRecord(
            date: Date(timeIntervalSince1970: 2),
            outcome: .failure,
            itemCount: 1,
            message: "offline"
        ))
        store.append(ScheduleRunRecord(
            date: Date(timeIntervalSince1970: 3),
            outcome: .success,
            itemCount: 3
        ))

        let reloaded = ScheduleRunStore(store: memory, limit: 2).all()
        XCTAssertEqual(reloaded.map(\.itemCount), [3, 1])
        XCTAssertEqual(reloaded.last?.outcome, .failure)
        XCTAssertEqual(reloaded.last?.message, "offline")
    }
}
