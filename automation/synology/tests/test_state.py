from __future__ import annotations

import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path

from pr_issue_worker.state import StateStore


class StateStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.store = StateStore(Path(self.temporary_directory.name) / "state.sqlite3")
        self.store.initialize()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_active_lease_prevents_duplicate_claim(self) -> None:
        self.assertTrue(self.store.claim(12, "U123", 300))
        self.assertFalse(self.store.claim(12, "U456", 300))

        state = self.store.get(12)
        self.assertIsNotNone(state)
        self.assertEqual(state.status, "running")
        self.assertEqual(state.attempts, 1)

    def test_failed_job_can_be_claimed_again(self) -> None:
        self.assertTrue(self.store.claim(13, "U123", 300))
        self.store.finish(13, "failed", error="timeout")

        self.assertTrue(self.store.claim(13, "U123", 300))
        state = self.store.get(13)
        self.assertEqual(state.attempts, 2)
        self.assertIsNone(state.last_error)

    def test_blocked_job_can_be_claimed_again(self) -> None:
        self.assertTrue(self.store.claim(16, "U123", 300))
        self.store.finish(16, "blocked", error="Runner is unavailable")

        self.assertTrue(self.store.claim(16, "U456", 300))

        state = self.store.get(16)
        self.assertEqual(state.status, "running")
        self.assertEqual(state.approved_by, "U456")
        self.assertEqual(state.attempts, 2)
        self.assertIsNone(state.last_error)

    def test_open_pr_is_terminal(self) -> None:
        self.assertTrue(self.store.claim(14, "U123", 300))
        self.store.finish(
            14,
            "pr_open",
            pr_number=20,
            pr_url="https://github.com/90ms/pr-review-reminder/pull/20",
        )

        self.assertFalse(self.store.claim(14, "U123", 300))

    def test_expired_lease_is_marked_failed(self) -> None:
        self.assertTrue(self.store.claim(15, "U123", 300))
        expired = (datetime.now(UTC) - timedelta(seconds=1)).isoformat()
        with self.store._connect() as connection:
            connection.execute(
                "UPDATE issue_jobs SET lease_until = ? WHERE issue_number = 15",
                (expired,),
            )

        self.assertEqual(self.store.expire_stale_leases(), [15])
        state = self.store.get(15)
        self.assertEqual(state.status, "failed")
        self.assertIn("lease expired", state.last_error)


if __name__ == "__main__":
    unittest.main()
