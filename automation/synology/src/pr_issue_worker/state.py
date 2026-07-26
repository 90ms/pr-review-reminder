from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

from .models import JobPhase


@dataclass(frozen=True)
class JobState:
    issue_number: int
    status: str
    approved_by: str | None
    attempts: int
    message_ts: str | None
    lease_until: str | None
    last_error: str | None
    pr_number: int | None
    pr_url: str | None
    phase: str | None
    started_at: str | None
    progress_updated_at: str | None
    job_id: str | None
    runner_updated_at: str | None


class StateStore:
    def __init__(self, path: Path):
        self.path = path

    def initialize(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS issue_jobs (
                    issue_number INTEGER PRIMARY KEY,
                    status TEXT NOT NULL,
                    approved_by TEXT,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    message_ts TEXT,
                    lease_until TEXT,
                    last_error TEXT,
                    pr_number INTEGER,
                    pr_url TEXT,
                    phase TEXT,
                    started_at TEXT,
                    progress_updated_at TEXT,
                    job_id TEXT,
                    runner_updated_at TEXT,
                    updated_at TEXT NOT NULL
                )
                """
            )
            columns = {
                str(row[1])
                for row in connection.execute("PRAGMA table_info(issue_jobs)")
            }
            migrations = {
                "phase": "TEXT",
                "started_at": "TEXT",
                "progress_updated_at": "TEXT",
                "job_id": "TEXT",
                "runner_updated_at": "TEXT",
            }
            for name, definition in migrations.items():
                if name not in columns:
                    connection.execute(
                        f"ALTER TABLE issue_jobs ADD COLUMN {name} {definition}"
                    )

    def record_notification(self, issue_number: int, message_ts: str) -> bool:
        now = _now()
        with self._connect() as connection:
            cursor = connection.execute(
                """
                INSERT INTO issue_jobs (
                    issue_number, status, message_ts, updated_at
                ) VALUES (?, 'notified', ?, ?)
                ON CONFLICT(issue_number) DO UPDATE SET
                    status = CASE
                        WHEN issue_jobs.status IN ('running', 'pr_open')
                        THEN issue_jobs.status ELSE 'notified'
                    END,
                    message_ts = CASE
                        WHEN issue_jobs.status IN ('running', 'pr_open')
                        THEN issue_jobs.message_ts ELSE excluded.message_ts
                    END,
                    updated_at = excluded.updated_at
                WHERE issue_jobs.status NOT IN ('running', 'pr_open')
                """,
                (issue_number, message_ts, now),
            )
            return cursor.rowcount == 1

    def needs_notification(self, issue_number: int) -> bool:
        return self.get(issue_number) is None

    def claim(self, issue_number: int, approved_by: str, lease_seconds: int) -> bool:
        now = datetime.now(UTC)
        lease_until = (now + timedelta(seconds=lease_seconds)).isoformat()
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT status, lease_until FROM issue_jobs WHERE issue_number = ?",
                (issue_number,),
            ).fetchone()
            if row is not None:
                status, current_lease = row
                if status == "pr_open":
                    return False
                if (
                    status == "running"
                    and current_lease
                    and datetime.fromisoformat(current_lease) > now
                ):
                    return False
                connection.execute(
                    """
                    UPDATE issue_jobs
                    SET status = 'running', approved_by = ?,
                        attempts = attempts + 1, lease_until = ?,
                        last_error = NULL, phase = 'preparing',
                        started_at = ?, progress_updated_at = ?,
                        job_id = NULL, runner_updated_at = NULL,
                        updated_at = ?
                    WHERE issue_number = ?
                    """,
                    (
                        approved_by,
                        lease_until,
                        now.isoformat(),
                        now.isoformat(),
                        now.isoformat(),
                        issue_number,
                    ),
                )
            else:
                connection.execute(
                    """
                    INSERT INTO issue_jobs (
                        issue_number, status, approved_by, attempts,
                        lease_until, phase, started_at,
                        progress_updated_at, updated_at
                    ) VALUES (?, 'running', ?, 1, ?, 'preparing', ?, ?, ?)
                    """,
                    (
                        issue_number,
                        approved_by,
                        lease_until,
                        now.isoformat(),
                        now.isoformat(),
                        now.isoformat(),
                    ),
                )
            return True

    def update_progress(
        self,
        issue_number: int,
        phase: JobPhase,
        *,
        job_id: str | None = None,
        runner_updated_at: str | None = None,
    ) -> JobState | None:
        now = _now()
        with self._connect() as connection:
            connection.execute(
                """
                UPDATE issue_jobs
                SET phase = ?, progress_updated_at = ?,
                    job_id = COALESCE(?, job_id),
                    runner_updated_at = COALESCE(?, runner_updated_at),
                    updated_at = ?
                WHERE issue_number = ? AND status = 'running'
                """,
                (
                    phase.value,
                    now,
                    job_id,
                    runner_updated_at,
                    now,
                    issue_number,
                ),
            )
        return self.get(issue_number)

    def finish(
        self,
        issue_number: int,
        status: str,
        *,
        error: str | None = None,
        pr_number: int | None = None,
        pr_url: str | None = None,
    ) -> None:
        if status not in {"pr_open", "failed", "blocked"}:
            raise ValueError(f"unsupported terminal status: {status}")
        with self._connect() as connection:
            connection.execute(
                """
                UPDATE issue_jobs
                SET status = ?, lease_until = NULL, last_error = ?,
                    pr_number = ?, pr_url = ?, updated_at = ?
                WHERE issue_number = ?
                """,
                (status, error, pr_number, pr_url, _now(), issue_number),
            )

    def expire_stale_leases(self) -> list[int]:
        now = datetime.now(UTC)
        expired: list[int] = []
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            rows = connection.execute(
                """
                SELECT issue_number FROM issue_jobs
                WHERE status = 'running'
                  AND lease_until IS NOT NULL
                  AND lease_until <= ?
                """,
                (now.isoformat(),),
            ).fetchall()
            expired = [int(row[0]) for row in rows]
            if expired:
                placeholders = ",".join("?" for _ in expired)
                connection.execute(
                    f"""
                    UPDATE issue_jobs
                    SET status = 'failed', lease_until = NULL,
                        last_error = 'Worker lease expired before completion',
                        updated_at = ?
                    WHERE issue_number IN ({placeholders})
                    """,
                    (now.isoformat(), *expired),
                )
        return expired

    def get(self, issue_number: int) -> JobState | None:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT issue_number, status, approved_by, attempts, message_ts,
                       lease_until, last_error, pr_number, pr_url, phase,
                       started_at, progress_updated_at, job_id, runner_updated_at
                FROM issue_jobs WHERE issue_number = ?
                """,
                (issue_number,),
            ).fetchone()
        return JobState(*row) if row else None

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=30)
        connection.execute("PRAGMA journal_mode = WAL")
        return connection


def _now() -> str:
    return datetime.now(UTC).isoformat()
