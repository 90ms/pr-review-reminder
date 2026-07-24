import XCTest
@testable import PRRCore

final class ModelTests: XCTestCase {
    func testPullRequestOwnerAndName() {
        let pr = PullRequest(repository: "fastlane-dev/beez", number: 12, title: "T", author: "a", url: "u")
        XCTAssertEqual(pr.owner, "fastlane-dev")
        XCTAssertEqual(pr.name, "beez")
        XCTAssertEqual(pr.id, "fastlane-dev/beez#12")
    }

    func testSeverityLenientDecoding() {
        XCTAssertEqual(Severity(lenient: "HIGH"), .high)
        XCTAssertEqual(Severity(lenient: "critical"), .high)
        XCTAssertEqual(Severity(lenient: "nit"), .low)
        XCTAssertEqual(Severity(lenient: "whatever"), .medium)
        XCTAssertEqual(Severity(lenient: nil), .medium)
    }

    func testAnalysisCodableRoundTrip() throws {
        let analysis = Analysis(
            summary: "does a thing",
            reviewPoints: [ReviewPoint(severity: .high, text: "risky")],
            inlineComments: [InlineComment(path: "a.swift", line: 3, body: "check nil")]
        )
        let data = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(Analysis.self, from: data)
        XCTAssertEqual(analysis, decoded)
    }

    func testAppSettingsCodableRoundTrip() throws {
        var settings = AppSettings()
        settings.owner = "acme"
        settings.repositories = ["x", "y"]
        settings.aiTool = .codex
        settings.scheduleMode = .everyNHours
        settings.intervalHours = 6
        settings.codexInputPricePerMillion = 2.5
        settings.codexOutputPricePerMillion = 10
        settings.reviewTokenBudget = 100_000
        settings.reviewBudgetWindowDays = 7
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings, decoded)
    }
}
