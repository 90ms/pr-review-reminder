from __future__ import annotations

import json
import os
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from pr_issue_worker.codex_runner import (
    CodexJobRunner,
    CodexRunnerSettings,
)
from pr_issue_worker.config import ConfigError
from pr_issue_worker.job_protocol import (
    RunnerPhase,
    RunnerProgress,
    RunnerRequest,
    RunnerResponse,
    new_job_id,
)
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


class _BlockingCommandRunnerStub(_CommandRunnerStub):
    def __init__(self):
        super().__init__()
        self.started = threading.Event()
        self.release = threading.Event()

    def run(self, command, *, environment=None, **kwargs):
        self.started.set()
        self.release.wait(timeout=2)
        return super().run(command, environment=environment, **kwargs)


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

    def test_refreshes_progress_and_runner_heartbeat_during_codex(self) -> None:
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
                    "RUNNER_HEARTBEAT_SECONDS": "0.1",
                }
            )
            command_runner = _BlockingCommandRunnerStub()
            job_runner = CodexJobRunner(settings, command_runner)
            job_runner.prepare()
            request = _request()
            request.write(queue / "pending" / f"{request.job_id}.json")
            thread = threading.Thread(target=job_runner.run_once)
            thread.start()
            self.assertTrue(command_runner.started.wait(timeout=1))
            progress_path = queue / "progress" / f"{request.job_id}.json"
            first = RunnerProgress.read(progress_path)
            heartbeat = queue / "runner-heartbeat"
            first_heartbeat = heartbeat.stat().st_mtime_ns

            time.sleep(0.25)

            second = RunnerProgress.read(progress_path)
            second_heartbeat = heartbeat.stat().st_mtime_ns
            command_runner.release.set()
            thread.join(timeout=2)
            final = RunnerProgress.read(progress_path)

        self.assertEqual(first.phase, RunnerPhase.CODEX_RUNNING)
        self.assertEqual(second.phase, RunnerPhase.CODEX_RUNNING)
        self.assertGreater(second.updated_at, first.updated_at)
        self.assertGreater(second_heartbeat, first_heartbeat)
        self.assertEqual(final.phase, RunnerPhase.RESULT_READY)


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
