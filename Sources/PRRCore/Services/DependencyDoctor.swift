import Foundation

public struct DependencyStatus: Sendable, Equatable {
    public let ghInstalled: Bool
    public let ghAuthenticated: Bool
    public let ghLogin: String?
    public let claudeInstalled: Bool
    public let codexInstalled: Bool

    public var isUsable: Bool { ghInstalled && ghAuthenticated && (claudeInstalled || codexInstalled) }

    public init(ghInstalled: Bool, ghAuthenticated: Bool, ghLogin: String?, claudeInstalled: Bool, codexInstalled: Bool) {
        self.ghInstalled = ghInstalled
        self.ghAuthenticated = ghAuthenticated
        self.ghLogin = ghLogin
        self.claudeInstalled = claudeInstalled
        self.codexInstalled = codexInstalled
    }

    /// Human-readable problems, empty when everything is ready.
    public var problems: [String] {
        var out: [String] = []
        if !ghInstalled { out.append("gh CLI is not installed (brew install gh).") }
        else if !ghAuthenticated { out.append("gh is not authenticated (run: gh auth login).") }
        if !claudeInstalled && !codexInstalled { out.append("Neither claude nor codex CLI was found.") }
        return out
    }
}

/// Diagnoses whether the required CLIs are present and gh is authenticated.
public struct DependencyDoctor: Sendable {
    private let runner: ProcessRunning
    private let locator: ToolLocator

    public init(runner: ProcessRunning, locator: ToolLocator) {
        self.runner = runner
        self.locator = locator
    }

    public static func authStatusCommand(gh: String) -> Command {
        Command(executable: gh, arguments: ["auth", "status"])
    }

    public func diagnose() async -> DependencyStatus {
        let ghPath = await locator.path(for: "gh")
        let claudePath = await locator.path(for: "claude")
        let codexPath = await locator.path(for: "codex")

        var authenticated = false
        var login: String? = nil
        if let ghPath {
            if let auth = try? await runner.run(Self.authStatusCommand(gh: ghPath)) {
                authenticated = auth.succeeded
            }
            if authenticated {
                let service = GitHubService(runner: runner, ghPath: ghPath)
                login = try? await service.currentLogin()
            }
        }

        return DependencyStatus(
            ghInstalled: ghPath != nil,
            ghAuthenticated: authenticated,
            ghLogin: login,
            claudeInstalled: claudePath != nil,
            codexInstalled: codexPath != nil
        )
    }
}
