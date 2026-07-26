from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from pr_issue_worker.codex_runner import (
    CodexJobRunner,
    CodexRunnerSettings,
)
from pr_issue_worker.config import ConfigError
from pr_issue_worker.job_protocol import RunnerRequest, RunnerResponse, new_job_id
from pr_issue_worker.process import CommandResult


class _CommandRunnerStub:
    def __init__(self):
        self.command: list[str] = []
        self.environment: dict[str, str] = {}

    def run(self, command, *, environment=None, **kwargs):
        self.command = list(command)
        self.environment = dict(environment or {})
        output = Path(self.command[self.command.index("--output-last-message") + 1])
        output.write_text(
            json.dumps(
                {
                    "status": "completed",
                    "summary": "Implemented",
                    "tests": ["python -m unittest"],
                    "docs": ["docs/ISSUE_AUTOMATION.md"],
                    "risks": [],
                }
            ),
            encoding="utf-8",
        )
        return CommandResult("", "", 0)


class CodexRunnerTests(unittest.TestCase):
    def test_requires_explicit_outer_container_mode(self) -> None:
        with self.assertRaisesRegex(ConfigError, "outer-container"):
            CodexRunnerSettings.from_env({})

    def test_consumes_job_with_container_as_the_execution_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            queue = root / "queue"
            workspaces = root / "workspaces"
            repository = workspaces / "issue-2-test" / "repository"
            (repository / ".git").mkdir(parents=True)
            settings = CodexRunnerSettings.from_env(
                {
                    "CODEX_RUNNER_MODE": "outer-container",
                    "RUNNER_QUEUE_PATH": str(queue),
                    "WORKSPACE_PATH": str(workspaces),
                }
            )
            command_runner = _CommandRunnerStub()
            job_runner = CodexJobRunner(settings, command_runner)
            job_runner.prepare()
            request = _request()
            request.write(queue / "pending" / f"{request.job_id}.json")

            with patch.dict(
                os.environ,
                {
                    "HTTPS_PROXY": "http://codex-egress:3128",
                    "SLACK_BOT_TOKEN": "xoxb-secret",
                    "GH_CONFIG_DIR": "/private/gh",
                },
                clear=False,
            ):
                self.assertTrue(job_runner.run_once())

            response = RunnerResponse.read(
                queue / "results" / f"{request.job_id}.json"
            )

        self.assertEqual(response.summary, "Implemented")
        self.assertIn(
            "--dangerously-bypass-approvals-and-sandbox",
            command_runner.command,
        )
        self.assertNotIn("--sandbox", command_runner.command)
        self.assertEqual(
            command_runner.environment["HTTPS_PROXY"],
            "http://codex-egress:3128",
        )
        self.assertNotIn("SLACK_BOT_TOKEN", command_runner.environment)
        self.assertNotIn("GH_CONFIG_DIR", command_runner.environment)


def _request() -> RunnerRequest:
    return RunnerRequest(
        job_id=new_job_id(),
        repository="90ms/pr-review-reminder",
        issue_number=2,
        issue_title="Improve settings",
        issue_body="Implement the approved scope.",
        issue_url="https://github.com/90ms/pr-review-reminder/issues/2",
        issue_author="maintainer",
        issue_labels=("codex-ready",),
        approved_by="U123",
        base_sha="a" * 40,
        branch="codex/issue-2-improve-settings",
        workspace_rel="issue-2-test/repository",
        timeout_seconds=3600,
    )


if __name__ == "__main__":
    unittest.main()
