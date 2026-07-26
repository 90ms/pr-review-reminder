from __future__ import annotations

import time
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path

from .job_protocol import (
    JobProtocolError,
    RunnerProgress,
    RunnerRequest,
    RunnerResponse,
)


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
        progress_callback: Callable[[RunnerProgress], None] | None = None,
    ) -> RunnerResponse:
        self.assert_available()
        pending = self.queue_path / "pending" / f"{request.job_id}.json"
        progress = self.queue_path / "progress" / f"{request.job_id}.json"
        result = self.queue_path / "results" / f"{request.job_id}.json"
        if pending.exists() or result.exists():
            raise JobProtocolError(f"job already exists: {request.job_id}")
        request.write(pending)

        deadline = time.monotonic() + timeout_seconds
        last_progress: tuple[str, str] | None = None
        while time.monotonic() < deadline:
            if progress.exists():
                current = RunnerProgress.read(progress)
                if current.job_id != request.job_id:
                    raise JobProtocolError("runner progress job_id does not match")
                signature = (current.phase.value, current.updated_at)
                if signature != last_progress:
                    last_progress = signature
                    if progress_callback is not None:
                        progress_callback(current)
            if result.exists():
                response = RunnerResponse.read(result)
                if response.job_id != request.job_id:
                    raise JobProtocolError("runner response job_id does not match")
                result.unlink(missing_ok=True)
                progress.unlink(missing_ok=True)
                return response
            time.sleep(self.poll_seconds)
        raise RunnerTimedOut(
            f"runner did not return issue #{request.issue_number} within "
            f"{timeout_seconds} seconds"
        )

    def read_progress(self, job_id: str) -> RunnerProgress | None:
        progress = self.queue_path / "progress" / f"{job_id}.json"
        if not progress.exists():
            return None
        current = RunnerProgress.read(progress)
        if current.job_id != job_id:
            raise JobProtocolError("runner progress job_id does not match")
        return current

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
