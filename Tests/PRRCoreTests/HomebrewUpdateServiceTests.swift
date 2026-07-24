import XCTest
@testable import PRRCore

final class HomebrewUpdateServiceTests: XCTestCase {
    private let outdatedJSON = """
    [{
      "name": "pr-review-reminder",
      "full_name": "90ms/tap/pr-review-reminder",
      "versions": { "stable": "0.2.2" },
      "installed": [{ "version": "0.2.1" }]
    }]
    """

    func testParseInfoFindsAvailableUpdate() throws {
        let info = try HomebrewUpdateService.parseInfo(
            outdatedJSON,
            bundleVersion: "0.2.1"
        )
        XCTAssertEqual(
            info,
            AppUpdateInfo(
                currentVersion: "0.2.1",
                latestVersion: "0.2.2",
                updateAvailable: true
            )
        )
    }

    func testParseInfoUsesInstalledVersionForDevelopmentBundle() throws {
        let info = try HomebrewUpdateService.parseInfo(
            outdatedJSON,
            bundleVersion: nil
        )
        XCTAssertEqual(info.currentVersion, "0.2.1")
    }

    func testCommandsTargetOnlyProjectFormula() {
        XCTAssertEqual(
            HomebrewUpdateService.infoCommand(brew: "/opt/homebrew/bin/brew").arguments,
            ["info", "--json=v1", "90ms/tap/pr-review-reminder"]
        )
        XCTAssertEqual(
            HomebrewUpdateService.upgradeCommand(brew: "/opt/homebrew/bin/brew").arguments,
            ["upgrade", "90ms/tap/pr-review-reminder"]
        )
        XCTAssertEqual(
            HomebrewUpdateService.launcherPath(for: "/opt/homebrew/bin/brew"),
            "/opt/homebrew/bin/pr-review-reminder"
        )
        XCTAssertEqual(
            HomebrewUpdateService.restartCommand(home: "/Users/test").arguments,
            ["-n", "/Users/test/Applications/PR Review Reminder.app"]
        )
    }

    func testCheckUpdatesDefinitionsThenReadsInfo() async throws {
        let mock = MockProcessRunner()
        let json = outdatedJSON
        mock.responder = { command in
            if command.arguments.first == "info" {
                return CommandResult(exitCode: 0, stdout: json, stderr: "")
            }
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let service = HomebrewUpdateService(runner: mock)

        let info = try await service.check(
            brew: "/opt/homebrew/bin/brew",
            bundleVersion: "0.2.1"
        )

        XCTAssertTrue(info.updateAvailable)
        XCTAssertEqual(mock.commands.map(\.arguments), [
            ["update"],
            ["info", "--json=v1", "90ms/tap/pr-review-reminder"],
        ])
    }

    func testUpgradeRelinksApplicationAfterFormulaUpgrade() async throws {
        let mock = MockProcessRunner()
        let service = HomebrewUpdateService(runner: mock)

        try await service.upgrade(brew: "/opt/homebrew/bin/brew")

        XCTAssertEqual(mock.commands.map(\.executable), [
            "/opt/homebrew/bin/brew",
            "/opt/homebrew/bin/pr-review-reminder",
        ])
        XCTAssertEqual(mock.commands[1].arguments, ["--install-app"])
    }

    func testRefreshFailureIdentifiesItsOperation() async {
        let mock = MockProcessRunner()
        mock.defaultResult = CommandResult(
            exitCode: 1,
            stdout: "",
            stderr: "network unavailable"
        )
        let service = HomebrewUpdateService(runner: mock)

        do {
            try await service.refreshDefinitions(brew: "/opt/homebrew/bin/brew")
            XCTFail("Expected refresh to fail")
        } catch {
            XCTAssertEqual(
                error as? HomebrewUpdateError,
                .commandFailed(operation: .refreshTap, message: "network unavailable")
            )
        }
    }

    func testRelinkFailureIdentifiesPartialUpdate() async {
        let mock = MockProcessRunner()
        mock.defaultResult = CommandResult(
            exitCode: 1,
            stdout: "",
            stderr: "link conflict"
        )
        let service = HomebrewUpdateService(runner: mock)

        do {
            try await service.relinkApplication(brew: "/opt/homebrew/bin/brew")
            XCTFail("Expected relink to fail")
        } catch {
            XCTAssertEqual(
                error as? HomebrewUpdateError,
                .commandFailed(operation: .relinkApplication, message: "link conflict")
            )
        }
    }

    func testRestartFailureIdentifiesInstalledButNotRestartedState() async {
        let mock = MockProcessRunner()
        mock.defaultResult = CommandResult(
            exitCode: 1,
            stdout: "",
            stderr: "could not open app"
        )
        let service = HomebrewUpdateService(runner: mock)

        do {
            try await service.launchUpdatedApplication(home: "/Users/test")
            XCTFail("Expected restart to fail")
        } catch {
            XCTAssertEqual(
                error as? HomebrewUpdateError,
                .commandFailed(
                    operation: .restartApplication,
                    message: "could not open app"
                )
            )
        }
    }
}
