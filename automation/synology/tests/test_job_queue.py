from __future__ import annotations

import tempfile
import threading
import time
import unittest
from datetime import UTC, datetime
from pathlib import Path

from pr_issue_worker.job_protocol import (
    RunnerPhase,
    RunnerProgress,
    RunnerRequest,
    RunnerResponse,
    new_job_id,
)
from pr_issue_worker.job_queue import FileJobClient, RunnerUnavailable
from pr_issue_worker.models import JobStatus


class FileJobClientTests(unittest.TestCase):
    def test_submits_request_and_waits_for_matching_result(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            queue = Path(directory)
            (queue / "runner-heartbeat").touch()
            client = FileJobClient(
                queue,
                heartbeat_max_age_seconds=30,
                poll_seconds=0.01,
            )
            request = _request()
            phases = []

            def complete() -> None:
                pending = queue / "pending" / f"{request.job_id}.json"
                while not pending.exists():
                    time.sleep(0.005)
                now = datetime.now(UTC).isoformat()
                RunnerProgress(
                    request.job_id,
                    request.issue_number,
                    RunnerPhase.RESULT_READY,
                    now,
                    now,
                ).write(queue / "progress" / f"{request.job_id}.json")
                RunnerResponse(
                    request.job_id,
                    JobStatus.COMPLETED,
                    "done",
                ).write(queue / "results" / f"{request.job_id}.json")

            thread = threading.Thread(target=complete)
            thread.start()
            response = client.submit_and_wait(
                request,
                timeout_seconds=2,
                progress_callback=lambda progress: phases.append(progress.phase),
            )
            thread.join()

        self.assertEqual(response.status, JobStatus.COMPLETED)
        self.assertEqual(response.summary, "done")
        self.assertEqual(phases, [RunnerPhase.RESULT_READY])
        self.assertFalse(
            (queue / "progress" / f"{request.job_id}.json").exists()
        )

    def test_rejects_missing_runner_heartbeat(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            client = FileJobClient(
                Path(directory),
                heartbeat_max_age_seconds=30,
            )

            with self.assertRaisesRegex(RunnerUnavailable, "heartbeat is missing"):
                client.assert_available()


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
