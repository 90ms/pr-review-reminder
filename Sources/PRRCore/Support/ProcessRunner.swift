import Foundation

/// Result of running an external command.
public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// A single command invocation, captured so it can be asserted on in tests
/// without ever executing a side-effecting command.
public struct Command: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let stdin: String?

    public init(executable: String, arguments: [String], stdin: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
    }
}

public enum ProcessRunnerError: Error, Sendable {
    case launchFailed(String)
}

/// Abstraction over running external processes so services can be unit-tested
/// with a mock and so real side effects never run during tests.
public protocol ProcessRunning: Sendable {
    func run(_ command: Command) async throws -> CommandResult
}

public extension ProcessRunning {
    func run(_ executable: String, _ arguments: [String], stdin: String? = nil) async throws -> CommandResult {
        try await run(Command(executable: executable, arguments: arguments, stdin: stdin))
    }
}

/// Real implementation backed by `Foundation.Process`.
public final class SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ command: Command) async throws -> CommandResult {
        // Run the blocking process work off the calling executor (never the main
        // thread) and drain stdout/stderr concurrently to avoid a pipe deadlock
        // when a child writes a lot to both streams.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: command.executable)
                process.arguments = command.arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let stdinPipe = Pipe()
                if command.stdin != nil {
                    process.standardInput = stdinPipe
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                    return
                }

                if let stdin = command.stdin, let data = stdin.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                    try? stdinPipe.fileHandleForWriting.close()
                }

                var outData = Data()
                var errData = Data()
                let group = DispatchGroup()
                let queue = DispatchQueue.global(qos: .userInitiated)
                group.enter()
                queue.async { outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                queue.async { errData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.wait()
                process.waitUntilExit()

                continuation.resume(returning: CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}
