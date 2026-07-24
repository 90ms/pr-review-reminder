import XCTest
@testable import PRRCore

private final class SessionMemoryStore: KeyValueStore {
    var values: [String: Data] = [:]
    func data(forKey defaultName: String) -> Data? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value as? Data
    }
}

final class SessionHealthStoreTests: XCTestCase {
    func testReportsDeadPreviousSessionOnce() {
        let memory = SessionMemoryStore()
        let store = SessionHealthStore(store: memory)
        let started = Date(timeIntervalSince1970: 100)
        XCTAssertNil(store.beginSession(
            pid: 10,
            appVersion: "0.3.0",
            now: started,
            isProcessRunning: { _ in true }
        ))

        let report = store.beginSession(
            pid: 11,
            appVersion: "0.3.1",
            now: Date(timeIntervalSince1970: 200),
            isProcessRunning: { _ in false }
        )

        XCTAssertEqual(report?.appVersion, "0.3.0")
        XCTAssertEqual(report?.startedAt, started)
        XCTAssertNil(store.beginSession(
            pid: 11,
            appVersion: "0.3.1",
            isProcessRunning: { _ in true }
        ))
    }

    func testCleanExitAndLiveDuplicateDoNotReportCrash() {
        let memory = SessionMemoryStore()
        let store = SessionHealthStore(store: memory)
        _ = store.beginSession(pid: 20, appVersion: "0.3.1", isProcessRunning: { _ in true })
        XCTAssertNil(store.beginSession(
            pid: 21,
            appVersion: "0.3.1",
            isProcessRunning: { $0 == 20 }
        ))
        store.endSession(pid: 21)
        XCTAssertNil(store.beginSession(
            pid: 22,
            appVersion: "0.3.1",
            isProcessRunning: { _ in false }
        ))
    }
}
