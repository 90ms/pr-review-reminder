import Foundation
@testable import PRRCore

/// Records commands and returns queued/canned results. Never runs anything real.
/// Tests drive it sequentially (one awaited call at a time), so no locking is needed.
final class MockProcessRunner: ProcessRunning, @unchecked Sendable {
    private(set) var commands: [Command] = []
    /// Returns a canned result for a given command; first match wins.
    var responder: (@Sendable (Command) throws -> CommandResult)?
    var defaultResult = CommandResult(exitCode: 0, stdout: "", stderr: "")

    func run(_ command: Command) async throws -> CommandResult {
        commands.append(command)
        return try responder?(command) ?? defaultResult
    }
}

enum Fixtures {
    static func data(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }
    static func string(_ name: String) -> String {
        String(data: data(name), encoding: .utf8)!
    }
}
