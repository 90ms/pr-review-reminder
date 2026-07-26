from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from pr_issue_worker.config import Config, ConfigError


class ConfigTests(unittest.TestCase):
    def test_loads_safe_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = Config.from_env(
                {
                    "GITHUB_REPOSITORY": "90ms/pr-review-reminder",
                    "DATA_PATH": directory,
                }
            )

        self.assertEqual(config.base_branch, "main")
        self.assertEqual(config.ready_label, "codex-ready")
        self.assertEqual(config.state_path, Path(directory) / "state.sqlite3")
        self.assertIn(".github/workflows/", config.protected_paths)
        self.assertFalse(config.dry_run)

    def test_rejects_invalid_repository(self) -> None:
        with self.assertRaisesRegex(ConfigError, "owner/repository"):
            Config.from_env({"GITHUB_REPOSITORY": "not a repository"})

    def test_rejects_non_positive_timeout(self) -> None:
        with self.assertRaisesRegex(ConfigError, "must be positive"):
            Config.from_env(
                {
                    "GITHUB_REPOSITORY": "90ms/pr-review-reminder",
                    "JOB_TIMEOUT_SECONDS": "0",
                }
            )

    def test_lease_must_outlive_job_timeout(self) -> None:
        with self.assertRaisesRegex(ConfigError, "must be greater"):
            Config.from_env(
                {
                    "GITHUB_REPOSITORY": "90ms/pr-review-reminder",
                    "JOB_TIMEOUT_SECONDS": "600",
                    "LEASE_SECONDS": "600",
                }
            )


if __name__ == "__main__":
    unittest.main()
