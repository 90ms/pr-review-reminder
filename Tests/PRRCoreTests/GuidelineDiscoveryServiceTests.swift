import XCTest
@testable import PRRCore

final class GuidelineDiscoveryServiceTests: XCTestCase {
    func testCandidatePathsPrioritizeAgentAndArchitectureDocuments() {
        let tree = [
            GitHubRepositoryTreeEntry(path: "README.md", type: "blob", size: 100),
            GitHubRepositoryTreeEntry(path: "AGENTS.md", type: "blob", size: 100),
            GitHubRepositoryTreeEntry(path: "docs/architecture.md", type: "blob", size: 100),
            GitHubRepositoryTreeEntry(path: "Sources/App.swift", type: "blob", size: 100),
            GitHubRepositoryTreeEntry(path: ".agents/skills/review/SKILL.md", type: "blob", size: 100),
        ]

        XCTAssertEqual(
            GuidelineDiscoveryService.candidatePaths(in: tree),
            ["AGENTS.md", ".agents/skills/review/SKILL.md", "docs/architecture.md"]
        )
    }

    func testSelectionParserRejectsInventedPathsAndDuplicates() throws {
        let selections = try GuidelineDiscoveryService.parseSelections(
            """
            {"selected":[
              {"path":"AGENTS.md","category":"review","reason":"Project rules"},
              {"path":"AGENTS.md","category":"review","reason":"Duplicate"},
              {"path":"invented.md","category":"architecture","reason":"Not a candidate"}
            ]}
            """,
            allowedPaths: ["AGENTS.md"]
        )

        XCTAssertEqual(selections.map(\.path), ["AGENTS.md"])
        XCTAssertEqual(selections.first?.category, .review)
    }

    func testDiscoveryFetchesCandidatesAndUsesSelectedAI() async throws {
        let mock = MockProcessRunner()
        mock.responder = { command in
            let args = command.arguments
            if args.contains("repos/acme/app"), args.contains(".default_branch") {
                return CommandResult(exitCode: 0, stdout: "main\n", stderr: "")
            }
            if args.contains("repos/acme/app/commits/main") {
                return CommandResult(exitCode: 0, stdout: "abc123\n", stderr: "")
            }
            if args.contains("repos/acme/app/git/trees/abc123") {
                return CommandResult(
                    exitCode: 0,
                    stdout: #"{"truncated":false,"tree":[{"path":"AGENTS.md","type":"blob","size":42}]}"#,
                    stderr: ""
                )
            }
            if args.contains("repos/acme/app/contents/AGENTS.md") {
                return CommandResult(
                    exitCode: 0,
                    stdout: "# Review rules\nCheck concurrency.",
                    stderr: ""
                )
            }
            if command.executable == "/bin/codex" {
                return CommandResult(
                    exitCode: 0,
                    stdout: #"{"selected":[{"path":"AGENTS.md","category":"review","reason":"Review rules"}]}"#,
                    stderr: ""
                )
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected command")
        }
        let service = GuidelineDiscoveryService(
            github: GitHubService(runner: mock, ghPath: "/bin/gh", readRetryDelays: []),
            ai: AIService(runner: mock, claudePath: nil, codexPath: "/bin/codex"),
            tool: .codex
        )

        let imported = try await service.discover(repository: "acme/app")

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.path, "AGENTS.md")
        XCTAssertEqual(imported.first?.revision, "abc123")
        XCTAssertEqual(imported.first?.content, "# Review rules\nCheck concurrency.")
        XCTAssertTrue(mock.commands.contains { $0.executable == "/bin/codex" })
    }

    func testNestedAgentsGuidelineOnlyAppliesToMatchingChanges() {
        let guideline = ImportedReviewGuideline(
            repository: "acme/app",
            path: "Sources/API/AGENTS.md",
            revision: "abc",
            category: .conventions,
            reason: "API rules",
            content: "Use Sendable."
        )

        XCTAssertTrue(guideline.applies(to: ["Sources/API/Client.swift"]))
        XCTAssertFalse(guideline.applies(to: ["Sources/UI/View.swift"]))
    }
}
