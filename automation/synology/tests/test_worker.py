from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from pr_issue_worker.config import Config
from pr_issue_worker.models import Issue
from pr_issue_worker.process import CommandRunner
from pr_issue_worker.state import StateStore
from pr_issue_worker.worker import IssueWorker, _branch_name


class _GitHubStub:
    def __init__(self, issue: Issue):
        self.issue = issue
        self.added_labels: list[str] = []

    def get_issue(self, issue_number: int) -> Issue:
        return self.issue

    def find_existing_pr(self, issue_number: int, branch_prefix: str):
        return None

    def add_labels(self, issue_number: int, labels) -> None:
        self.added_labels.extend(labels)

    def remove_labels(self, issue_number: int, labels) -> None:
        pass


class WorkerTests(unittest.TestCase):
    def test_branch_name_is_stable_and_bounded(self) -> None:
        issue = Issue(
            42,
            "Fix 설정 / update button!! " + ("long " * 30),
            "",
            "",
            "maintainer",
        )

        branch = _branch_name(issue)

        self.assertTrue(branch.startswith("codex/issue-42-fix-update-button"))
        self.assertLessEqual(len(branch.split("issue-42-", 1)[1]), 48)

    def test_dry_run_blocks_protected_change_without_github_write(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            issue = Issue(
                7,
                "Change CI",
                "Update the workflow",
                "https://example.test/issues/7",
                "maintainer",
                frozenset({"codex-ready"}),
            )
            config = Config.from_env(
                {
                    "GITHUB_REPOSITORY": "90ms/pr-review-reminder",
                    "DATA_PATH": str(root / "data"),
                    "DRY_RUN": "true",
                }
            )
            state = StateStore(config.state_path)
            state.initialize()
            github = _GitHubStub(issue)
            worker = _PreparedWorker(config, state, github, CommandRunner(), root)

            result = worker.run(issue.number, "U123")

        self.assertEqual(result.status, "blocked")
        self.assertIn("Protected paths", result.summary)
        self.assertEqual(github.added_labels, [])


class _PreparedWorker(IssueWorker):
    def __init__(self, config, state, github, runner, root: Path):
        super().__init__(config, state, github, runner)
        self.root = root

    def _prepare_workspace(self, issue: Issue, branch: str) -> Path:
        repository = self.root / "job" / "repository"
        (repository / ".github" / "workflows").mkdir(parents=True)
        (repository / ".github" / "workflows" / "ci.yml").write_text(
            "changed: true\n", encoding="utf-8"
        )
        return repository

    def _run_codex(self, issue: Issue, workspace: Path) -> dict[str, object]:
        return {
            "status": "completed",
            "summary": "Changed CI",
            "tests": [],
            "docs": [],
            "risks": [],
        }

    def _changed_paths(self, workspace: Path) -> list[str]:
        return [".github/workflows/ci.yml"]


if __name__ == "__main__":
    unittest.main()
