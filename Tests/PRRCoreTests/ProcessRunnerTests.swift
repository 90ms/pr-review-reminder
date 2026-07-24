import XCTest
@testable import PRRCore

final class ProcessRunnerTests: XCTestCase {
    // Both stdout and stderr get large concurrent output. The old "read stdout
    // fully, then stderr" code could deadlock when a stream exceeds the pipe
    // buffer (~64KB). This must complete and capture both streams.
    func testConcurrentPipeDrainNoDeadlock() async throws {
        let runner = SystemProcessRunner()
        let script = "for i in $(seq 1 8000); do echo out-$i; echo err-$i 1>&2; done"
        let result = try await withThrowingTaskGroup(of: CommandResult.self) { group -> CommandResult in
            group.addTask { try await runner.run("/bin/sh", ["-c", script]) }
            // Guard: fail fast if it hangs instead of blocking the whole suite.
            group.addTask {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                throw NSError(domain: "timeout", code: 1)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("out-8000"))
        XCTAssertTrue(result.stderr.contains("err-8000"))
    }

    func testStdinIsDelivered() async throws {
        let runner = SystemProcessRunner()
        let result = try await runner.run("/bin/cat", [], stdin: "hello-stdin")
        XCTAssertEqual(result.stdout, "hello-stdin")
    }
}
