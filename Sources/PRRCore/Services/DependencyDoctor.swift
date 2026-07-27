import Foundation

public enum GitHubDependencyIssue: Sendable, Equatable {
    case authenticationFailed(String)
    case authenticationTimedOut
    case apiTimedOut
    case apiFailed(String)

    public var message: String {
        switch self {
        case let .authenticationFailed(detail):
            return detail.isEmpty
                ? "gh authentication failed (run: gh auth login)."
                : "gh authentication failed: \(detail)"
        case .authenticationTimedOut:
            return "GitHub authentication check timed out. Check network access and retry."
        case .apiTimedOut:
            return "GitHub API check timed out, including the HTTP/1.1 retry."
        case let .apiFailed(detail):
            return detail.isEmpty
                ? "GitHub API check failed."
                : "GitHub API check failed: \(detail)"
        }
    }
}

public struct DependencyStatus: Sendable, Equatable {
    public let ghInstalled: Bool
    public let ghAuthenticated: Bool
    public let ghLogin: String?
    public let ghIssue: GitHubDependencyIssue?
    public let claudeInstalled: Bool
    public let codexInstalled: Bool

    public var isUsable: Bool {
        ghInstalled && ghAuthenticated && ghLogin != nil && (claudeInstalled || codexInstalled)
    }

    public init(
        ghInstalled: Bool,
        ghAuthenticated: Bool,
        ghLogin: String?,
        ghIssue: GitHubDependencyIssue? = nil,
        claudeInstalled: Bool,
        codexInstalled: Bool
    ) {
        self.ghInstalled = ghInstalled
        self.ghAuthenticated = ghAuthenticated
        self.ghLogin = ghLogin
        self.ghIssue = ghIssue
        self.claudeInstalled = claudeInstalled
        self.codexInstalled = codexInstalled
    }

    /// Human-readable problems, empty when everything is ready.
    public var problems: [String] {
        var out: [String] = []
        if !ghInstalled { out.append("gh CLI is not installed (brew install gh).") }
        else if let ghIssue { out.append(ghIssue.message) }
        else if !ghAuthenticated { out.append("gh authentication could not be verified.") }
        else if ghLogin == nil { out.append("Could not determine the active GitHub login.") }
        if !claudeInstalled && !codexInstalled { out.append("Neither claude nor codex CLI was found.") }
        return out
    }
}

/// Diagnoses whether the required CLIs are present and gh is authenticated.
public struct DependencyDoctor: Sendable {
    private let runner: ProcessRunning
    private let locator: ToolLocator
    private let transportPreference: GitHubTransportPreference

    public init(runner: ProcessRunning, locator: ToolLocator) {
        self.runner = runner
        self.locator = locator
        self.transportPreference = .shared
    }

    init(
        runner: ProcessRunning,
        locator: ToolLocator,
        transportPreference: GitHubTransportPreference
    ) {
        self.runner = runner
        self.locator = locator
        self.transportPreference = transportPreference
    }

    public static func authStatusCommand(gh: String) -> Command {
        Command(
            executable: gh,
            arguments: ["auth", "status", "--active", "--hostname", "github.com"],
            timeout: 15
        )
    }

    public func diagnose() async -> DependencyStatus {
        let ghPath = await locator.path(for: "gh")
        let claudePath = await locator.path(for: "claude")
        let codexPath = await locator.path(for: "codex")

        var authenticated = false
        var login: String? = nil
        var ghIssue: GitHubDependencyIssue? = nil
        if let ghPath {
            do {
                let auth = try await runAuthStatus(Self.authStatusCommand(gh: ghPath))
                authenticated = auth.succeeded
                if !auth.succeeded {
                    ghIssue = .authenticationFailed(Self.errorDetail(auth.stderr))
                }
            } catch ProcessRunnerError.timedOut {
                ghIssue = .authenticationTimedOut
            } catch {
                ghIssue = .authenticationFailed(String(describing: error))
            }

            if authenticated {
                let service = GitHubService(
                    runner: runner,
                    ghPath: ghPath,
                    transportPreference: transportPreference
                )
                do {
                    login = try await service.currentLogin()
                } catch ProcessRunnerError.timedOut {
                    ghIssue = .apiTimedOut
                } catch let error as GitHubError {
                    if Self.isAuthenticationFailure(error.message) {
                        authenticated = false
                        ghIssue = .authenticationFailed(error.message)
                    } else {
                        ghIssue = .apiFailed(error.message)
                    }
                } catch {
                    ghIssue = .apiFailed(String(describing: error))
                }
            }
        }

        return DependencyStatus(
            ghInstalled: ghPath != nil,
            ghAuthenticated: authenticated,
            ghLogin: login,
            ghIssue: ghIssue,
            claudeInstalled: claudePath != nil,
            codexInstalled: codexPath != nil
        )
    }

    private func runAuthStatus(_ command: Command) async throws -> CommandResult {
        do {
            return try await runner.run(command)
        } catch ProcessRunnerError.timedOut {
            transportPreference.preferHTTP1()
            return try await runner.run(GitHubService.http1FallbackCommand(command))
        }
    }

    private static func errorDetail(_ stderr: String) -> String {
        stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAuthenticationFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("not authenticated")
            || lower.contains("authentication")
            || lower.contains("bad credentials")
            || lower.contains("http 401")
    }
}
