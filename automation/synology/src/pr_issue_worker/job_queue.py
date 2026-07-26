from __future__ import annotations

import time
from datetime import UTC, datetime
from pathlib import Path

from .job_protocol import JobProtocolError, RunnerRequest, RunnerResponse


class RunnerUnavailable(RuntimeError):
    pass


class RunnerTimedOut(RuntimeError):
    pass


class FileJobClient:
    def __init__(
        self,
        queue_path: Path,
        *,
        heartbeat_max_age_seconds: int,
        poll_seconds: float = 0.25,
    ):
        self.queue_path = queue_path
        self.heartbeat_max_age_seconds = heartbeat_max_age_seconds
        self.poll_seconds = poll_seconds

    def submit_and_wait(
        self,
        request: RunnerRequest,
        *,
        timeout_seconds: int,
    ) -> RunnerResponse:
        self.assert_available()
        pending = self.queue_path / "pending" / f"{request.job_id}.json"
        result = self.queue_path / "results" / f"{request.job_id}.json"
        if pending.exists() or result.exists():
            raise JobProtocolError(f"job already exists: {request.job_id}")
        request.write(pending)

        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            if result.exists():
                response = RunnerResponse.read(result)
                if response.job_id != request.job_id:
                    raise JobProtocolError("runner response job_id does not match")
                result.unlink(missing_ok=True)
                return response
            time.sleep(self.poll_seconds)
        raise RunnerTimedOut(
            f"runner did not return issue #{request.issue_number} within "
            f"{timeout_seconds} seconds"
        )

    def assert_available(self) -> None:
        heartbeat = self.queue_path / "runner-heartbeat"
        try:
            age = datetime.now(UTC).timestamp() - heartbeat.stat().st_mtime
        except OSError as error:
            raise RunnerUnavailable("runner heartbeat is missing") from error
        if age > self.heartbeat_max_age_seconds:
            raise RunnerUnavailable(
                f"runner heartbeat is stale ({int(age)} seconds old)"
            )
