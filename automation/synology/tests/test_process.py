from __future__ import annotations

import sys
import unittest

from pr_issue_worker.process import CommandRunner, CommandTimeout, minimal_environment


class ProcessTests(unittest.TestCase):
    def test_minimal_environment_excludes_service_secrets(self) -> None:
        environment = minimal_environment(
            {
                "PATH": "/bin",
                "HOME": "/tmp/home",
                "SLACK_BOT_TOKEN": "secret",
                "GH_TOKEN": "github",
                "CODEX_ACCESS_TOKEN": "codex",
            },
            include_auth=True,
        )

        self.assertEqual(environment["GH_TOKEN"], "github")
        self.assertEqual(environment["CODEX_ACCESS_TOKEN"], "codex")
        self.assertNotIn("SLACK_BOT_TOKEN", environment)

    def test_timeout_terminates_process_group(self) -> None:
        with self.assertRaises(CommandTimeout):
            CommandRunner().run(
                [sys.executable, "-c", "import time; time.sleep(10)"],
                timeout=1,
            )


if __name__ == "__main__":
    unittest.main()
