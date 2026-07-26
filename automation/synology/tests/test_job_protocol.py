from __future__ import annotations

import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from pr_issue_worker.job_protocol import (
    JobProtocolError,
    RunnerRequest,
    RunnerResponse,
    new_job_id,
    resolve_workspace,
)
from pr_issue_worker.models import JobStatus


class JobProtocolTests(unittest.TestCase):
    def test_request_and_response_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request = _request()
            response = RunnerResponse(
                request.job_id,
                JobStatus.COMPLETED,
                "Implemented the approved issue",
                tests=("python -m unittest",),
                docs=("docs/ISSUE_AUTOMATION.md",),
            )

            request.write(root / "pending" / f"{request.job_id}.json")
            response.write(root / "results" / f"{request.job_id}.json")

            self.assertEqual(
                RunnerRequest.read(root / "pending" / f"{request.job_id}.json"),
                request,
            )
            self.assertEqual(
                RunnerResponse.read(root / "results" / f"{request.job_id}.json"),
                response,
            )

    def test_rejects_workspace_traversal(self) -> None:
        request = replace(_request(), workspace_rel="../state.sqlite3")

        with self.assertRaisesRegex(JobProtocolError, "normalized relative"):
            request.validate()

    def test_resolved_workspace_must_stay_below_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / "issue-2" / "repository"
            workspace.mkdir(parents=True)

            self.assertEqual(
                resolve_workspace(root, "issue-2/repository"),
                workspace.resolve(),
            )


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
