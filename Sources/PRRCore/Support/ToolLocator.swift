import Foundation

/// Resolves absolute paths to CLI tools. GUI apps launched from Finder inherit a
/// minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) and a login shell only sees what
/// the user's profile exports — which often omits `~/.local/bin` where tools like
/// the `claude` CLI install. So we try a login shell first, then fall back to a
/// list of well-known install locations.
public actor ToolLocator {
    private let runner: ProcessRunning
    private let shell: String
    private let fileManager: FileManager
    private var cache: [String: String] = [:]

    public init(runner: ProcessRunning, shell: String = "/bin/zsh", fileManager: FileManager = .default) {
        self.runner = runner
        self.shell = shell
        self.fileManager = fileManager
    }

    /// Builds the command that asks a login shell where a tool lives.
    public static func locateCommand(shell: String, tool: String) -> Command {
        Command(
            executable: shell,
            arguments: ["-lc", "command -v \(tool)"],
            timeout: 10
        )
    }

    /// Ordered, well-known absolute locations to probe when the login shell fails.
    /// Pure/testable; `home` is injected so tests don't depend on the real HOME.
    public static func candidatePaths(for tool: String, home: String) -> [String] {
        let dirs = [
            "\(home)/.local/bin",
            "\(home)/.claude/local",   // claude native installer launcher
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
            "/usr/bin"
        ]
        return dirs.map { "\($0)/\(tool)" }
    }

    /// Returns the absolute path to `tool`, or nil if it is not installed.
    public func path(for tool: String) async -> String? {
        if let cached = cache[tool] { return cached }

        // 1) Ask a login shell.
        if let result = try? await runner.run(Self.locateCommand(shell: shell, tool: tool)) {
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.succeeded, !path.isEmpty, fileManager.isExecutableFile(atPath: path) {
                cache[tool] = path
                return path
            }
        }

        // 2) Fall back to well-known install locations.
        let home = fileManager.homeDirectoryForCurrentUser.path
        for candidate in Self.candidatePaths(for: tool, home: home) where fileManager.isExecutableFile(atPath: candidate) {
            cache[tool] = candidate
            return candidate
        }

        return nil
    }
}
