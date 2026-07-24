import XCTest
@testable import PRRCore

final class ToolLocatorTests: XCTestCase {
    func testLocateCommand() {
        let cmd = ToolLocator.locateCommand(shell: "/bin/zsh", tool: "claude")
        XCTAssertEqual(cmd.executable, "/bin/zsh")
        XCTAssertEqual(cmd.arguments, ["-lc", "command -v claude"])
    }

    // The fallback list must include ~/.local/bin, where the claude CLI installs
    // and which is commonly absent from a GUI login shell's PATH.
    func testCandidatePathsIncludeLocalBin() {
        let candidates = ToolLocator.candidatePaths(for: "claude", home: "/Users/kms")
        XCTAssertTrue(candidates.contains("/Users/kms/.local/bin/claude"))
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/claude"))
        // ~/.local/bin should be probed before Homebrew.
        let localIdx = candidates.firstIndex(of: "/Users/kms/.local/bin/claude")!
        let brewIdx = candidates.firstIndex(of: "/opt/homebrew/bin/claude")!
        XCTAssertLessThan(localIdx, brewIdx)
    }
}
