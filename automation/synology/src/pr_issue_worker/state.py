from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path


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
                    updated_at TEXT NOT NULL
                )
                """
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
                        last_error = NULL, updated_at = ?
                    WHERE issue_number = ?
                    """,
                    (approved_by, lease_until, now.isoformat(), issue_number),
                )
            else:
                connection.execute(
                    """
                    INSERT INTO issue_jobs (
                        issue_number, status, approved_by, attempts,
                        lease_until, updated_at
                    ) VALUES (?, 'running', ?, 1, ?, ?)
                    """,
                    (issue_number, approved_by, lease_until, now.isoformat()),
                )
            return True

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

    def get(self, issue_number: int) -> JobState | None:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT issue_number, status, approved_by, attempts, message_ts,
                       lease_until, last_error, pr_number, pr_url
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
