import XCTest
@testable import PRRCore

final class DependencyDoctorTests: XCTestCase {
    func testDiagnoseUsesScopedAuthAndHTTP1LoginFallback() async {
        let mock = MockProcessRunner()
        mock.responder = { command in
            if command.executable == "/bin/zsh" {
                return CommandResult(exitCode: 0, stdout: "/bin/sh\n", stderr: "")
            }
            if command.arguments.first == "auth" {
                return CommandResult(exitCode: 0, stdout: "", stderr: "")
            }
            if command.arguments.first == "api" {
                guard command.environment?["GODEBUG"]?.contains("http2client=0") == true else {
                    throw ProcessRunnerError.timedOut(GitHubService.loginTimeout)
                }
                return CommandResult(exitCode: 0, stdout: "kms-yeoshin\n", stderr: "")
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected command")
        }
        let locator = ToolLocator(runner: mock)
        let doctor = DependencyDoctor(
            runner: mock,
            locator: locator,
            transportPreference: GitHubTransportPreference()
        )

        let status = await doctor.diagnose()

        XCTAssertTrue(status.ghAuthenticated)
        XCTAssertEqual(status.ghLogin, "kms-yeoshin")
        XCTAssertNil(status.ghIssue)
        XCTAssertTrue(status.isUsable)
        let auth = mock.commands.first { $0.arguments.first == "auth" }
        XCTAssertEqual(auth?.arguments, [
            "auth", "status", "--active", "--hostname", "github.com"
        ])
    }

    func testDiagnoseReportsAuthTimeoutInsteadOfSuggestingLogin() async {
        let mock = MockProcessRunner()
        mock.responder = { command in
            if command.executable == "/bin/zsh" {
                return CommandResult(exitCode: 0, stdout: "/bin/sh\n", stderr: "")
            }
            if command.arguments.first == "auth" {
                throw ProcessRunnerError.timedOut(15)
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected command")
        }
        let locator = ToolLocator(runner: mock)
        let doctor = DependencyDoctor(
            runner: mock,
            locator: locator,
            transportPreference: GitHubTransportPreference()
        )

        let status = await doctor.diagnose()

        XCTAssertFalse(status.ghAuthenticated)
        XCTAssertEqual(status.ghIssue, .authenticationTimedOut)
        XCTAssertTrue(status.problems.contains { $0.contains("timed out") })
        XCTAssertFalse(status.problems.contains { $0.contains("gh auth login") })
        let authCommands = mock.commands.filter { $0.arguments.first == "auth" }
        XCTAssertEqual(authCommands.count, 2)
        XCTAssertNil(authCommands[0].environment)
        XCTAssertTrue(
            authCommands[1].environment?["GODEBUG"]?.contains("http2client=0") == true
        )
    }
}
