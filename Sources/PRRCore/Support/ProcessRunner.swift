import Darwin
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
    public let timeout: TimeInterval?
    public let workingDirectory: String?
    public let environment: [String: String]?

    public init(
        executable: String,
        arguments: [String],
        stdin: String? = nil,
        timeout: TimeInterval? = nil,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.timeout = timeout
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public enum ProcessRunnerError: Error, Sendable, Equatable {
    case launchFailed(String)
    case timedOut(TimeInterval)
}

/// Abstraction over running external processes so services can be unit-tested
/// with a mock and so real side effects never run during tests.
public protocol ProcessRunning: Sendable {
    func run(_ command: Command) async throws -> CommandResult
}

public extension ProcessRunning {
    func run(_ executable: String, _ arguments: [String], stdin: String? = nil,
             timeout: TimeInterval? = nil) async throws -> CommandResult {
        try await run(Command(executable: executable, arguments: arguments, stdin: stdin, timeout: timeout))
    }
}

/// Real implementation backed by `Foundation.Process`.
public final class SystemProcessRunner: ProcessRunning {
    private let terminationGracePeriod: TimeInterval

    public init(terminationGracePeriod: TimeInterval = 0.5) {
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func run(_ command: Command) async throws -> CommandResult {
        let controller = ProcessController(terminationGracePeriod: terminationGracePeriod)

        // Run the blocking process work off the calling executor (never the main
        // thread) and drain stdout/stderr concurrently to avoid a pipe deadlock
        // when a child writes a lot to both streams.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: command.executable)
                    process.arguments = command.arguments
                    process.currentDirectoryURL = command.workingDirectory.map {
                        URL(fileURLWithPath: $0, isDirectory: true)
                    }
                    // Foundation only inherits the parent environment when the
                    // environment setter is not used. Assigning nil explicitly
                    // launches the child with an empty environment on macOS,
                    // which hides HOME and breaks gh's keychain-backed auth.
                    if let environment = command.environment {
                        process.environment = environment
                    }

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
                        controller.didLaunch(process)
                    } catch {
                        continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                        return
                    }

                    if let timeout = command.timeout {
                        controller.scheduleTimeout(after: timeout)
                    }

                    if let stdin = command.stdin, let data = stdin.data(using: .utf8) {
                        stdinPipe.fileHandleForWriting.write(data)
                        try? stdinPipe.fileHandleForWriting.close()
                    }

                    let outData = SendableData()
                    let errData = SendableData()
                    let group = DispatchGroup()
                    let queue = DispatchQueue.global(qos: .userInitiated)
                    group.enter()
                    queue.async {
                        outData.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    group.enter()
                    queue.async {
                        errData.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    group.wait()
                    process.waitUntilExit()

                    switch controller.finish() {
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case let .timedOut(timeout):
                        continuation.resume(throwing: ProcessRunnerError.timedOut(timeout))
                    case nil:
                        continuation.resume(returning: CommandResult(
                            exitCode: process.terminationStatus,
                            stdout: String(data: outData.value, encoding: .utf8) ?? "",
                            stderr: String(data: errData.value, encoding: .utf8) ?? ""
                        ))
                    }
                }
            }
        } onCancel: {
            controller.cancel()
        }
    }

}

private final class SendableData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private final class ProcessController: @unchecked Sendable {
    enum StopReason {
        case cancelled
        case timedOut(TimeInterval)
    }

    private let lock = NSLock()
    private let terminationGracePeriod: TimeInterval
    private var process: Process?
    private var stopReason: StopReason?
    private var finished = false

    init(terminationGracePeriod: TimeInterval) {
        self.terminationGracePeriod = terminationGracePeriod
    }

    func didLaunch(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldStop = stopReason != nil
        lock.unlock()

        if shouldStop {
            stop(process)
        }
    }

    func scheduleTimeout(after timeout: TimeInterval) {
        guard timeout >= 0 else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.requestStop(.timedOut(timeout))
        }
    }

    func cancel() {
        requestStop(.cancelled)
    }

    func finish() -> StopReason? {
        lock.lock()
        finished = true
        let reason = stopReason
        process = nil
        lock.unlock()
        return reason
    }

    private func requestStop(_ reason: StopReason) {
        lock.lock()
        guard !finished, stopReason == nil else {
            lock.unlock()
            return
        }
        if let process, !process.isRunning {
            lock.unlock()
            return
        }
        stopReason = reason
        let runningProcess = process
        lock.unlock()

        if let runningProcess {
            stop(runningProcess)
        }
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        let processIdentifier = process.processIdentifier
        process.terminate()

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + terminationGracePeriod) {
            if process.isRunning {
                Darwin.kill(processIdentifier, SIGKILL)
            }
        }
    }
}
