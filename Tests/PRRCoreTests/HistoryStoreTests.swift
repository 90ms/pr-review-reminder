import XCTest
@testable import PRRCore

final class HistoryStoreTests: XCTestCase {
    final class MemPersistence: HistoryPersisting, @unchecked Sendable {
        var data: Data?
        func read() -> Data? { data }
        func write(_ d: Data) { data = d }
    }

    private func record(_ repo: String, _ num: Int, _ sha: String, tokens: Int, cost: Double, at: TimeInterval) -> ReviewRecord {
        ReviewRecord(
            repository: repo, number: num, title: "T\(num)", author: "a", url: "u",
            headSha: sha, tool: .claude, reviewedAt: Date(timeIntervalSince1970: at),
            analysis: Analysis(summary: "s"),
            usage: AIUsage(totalTokens: tokens, costUSD: cost),
            details: PRDetails(body: "b", headSha: sha, additions: 1, deletions: 0, diff: "d"))
    }

    func testTokenTotalUsesRollingWindow() {
        let persistence = MemPersistence()
        let store = HistoryStore(persistence: persistence)
        let now = Date(timeIntervalSince1970: 1_000_000)
        store.upsert(record("o/r", 1, "old", tokens: 100, cost: 0, at: now.addingTimeInterval(-40 * 86_400).timeIntervalSince1970))
        store.upsert(record("o/r", 2, "new", tokens: 250, cost: 0, at: now.addingTimeInterval(-2 * 86_400).timeIntervalSince1970))
        XCTAssertEqual(store.tokenTotal(windowDays: 30, now: now), 250)
        XCTAssertEqual(store.tokenTotal(windowDays: 0, now: now), 350)
    }

    // AC16 — same id replaces, different SHA adds.
    func testUpsertReplaceVsAdd() {
        let store = HistoryStore(persistence: MemPersistence())
        store.upsert(record("o/r", 1, "sha1", tokens: 10, cost: 0.1, at: 100))
        store.upsert(record("o/r", 1, "sha1", tokens: 20, cost: 0.2, at: 200)) // replace
        store.upsert(record("o/r", 1, "sha2", tokens: 30, cost: 0.3, at: 300)) // new SHA
        XCTAssertEqual(store.all().count, 2)
        XCTAssertEqual(store.record(repository: "o/r", number: 1, headSha: "sha1")?.usage?.tokens, 20)
    }

    // AC17 — cache lookup.
    func testRecordLookup() {
        let store = HistoryStore(persistence: MemPersistence())
        store.upsert(record("o/r", 5, "abc", tokens: 1, cost: 0, at: 1))
        XCTAssertNotNil(store.record(repository: "o/r", number: 5, headSha: "abc"))
        XCTAssertNil(store.record(repository: "o/r", number: 5, headSha: "different"))
        XCTAssertNil(store.record(repository: "o/r", number: 6, headSha: "abc"))
    }

    // AC18 — totals.
    func testTotals() {
        let store = HistoryStore(persistence: MemPersistence())
        store.upsert(record("o/r", 1, "s1", tokens: 100, cost: 0.5, at: 1))
        store.upsert(record("o/r", 2, "s2", tokens: 250, cost: 1.25, at: 2))
        let t = store.totals()
        XCTAssertEqual(t.tokens, 350)
        XCTAssertEqual(t.costUSD, 1.75, accuracy: 0.0001)
        XCTAssertEqual(t.count, 2)
    }

    // AC19 — persistence round trip + newest-first ordering.
    func testPersistenceRoundTripAndOrder() {
        let mem = MemPersistence()
        let store1 = HistoryStore(persistence: mem)
        store1.upsert(record("o/r", 1, "s1", tokens: 1, cost: 0, at: 100))
        store1.upsert(record("o/r", 2, "s2", tokens: 2, cost: 0, at: 300))
        store1.upsert(record("o/r", 3, "s3", tokens: 3, cost: 0, at: 200))
        // Reload from the same persisted data.
        let store2 = HistoryStore(persistence: mem)
        XCTAssertEqual(store2.all().count, 3)
        XCTAssertEqual(store2.all().map(\.number), [2, 3, 1]) // newest first by reviewedAt
    }

    func testRetentionAndDeleteAll() {
        let store = HistoryStore(persistence: MemPersistence())
        store.upsert(record("o/r", 1, "old", tokens: 1, cost: 0, at: 100))
        store.upsert(record("o/r", 2, "new", tokens: 1, cost: 0, at: 900_000))

        store.applyRetention(days: 5, now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(store.all().map(\.number), [2])

        store.deleteAll()
        XCTAssertTrue(store.all().isEmpty)
    }
}
