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

    func testTimeoutTerminatesProcess() async {
        let runner = SystemProcessRunner(terminationGracePeriod: 0.05)

        do {
            _ = try await runner.run("/bin/sleep", ["10"], timeout: 0.05)
            XCTFail("Expected the command to time out")
        } catch let error as ProcessRunnerError {
            XCTAssertEqual(error, .timedOut(0.05))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTaskCancellationTerminatesProcess() async {
        let runner = SystemProcessRunner(terminationGracePeriod: 0.05)
        let task = Task {
            try await runner.run("/bin/sleep", ["10"])
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCommandDefaultsToNoTimeout() {
        let command = Command(executable: "/bin/true", arguments: [])
        XCTAssertNil(command.timeout)
    }
}
