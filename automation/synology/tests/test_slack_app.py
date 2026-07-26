from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from pr_issue_worker.config import ConfigError
from pr_issue_worker.models import Issue
from pr_issue_worker.slack_app import SlackAutomation, SlackSettings
from pr_issue_worker.state import StateStore


class _ClientStub:
    def __init__(self):
        self.posts: list[dict] = []
        self.updates: list[dict] = []

    def chat_postMessage(self, **arguments):
        self.posts.append(arguments)
        return {"ts": "123.456"}

    def chat_update(self, **arguments):
        self.updates.append(arguments)


class _GitHubStub:
    def __init__(self, issue: Issue):
        self.issue = issue
        self.added_labels: list[str] = []

    def list_issues(self, label: str):
        return [self.issue]

    def get_issue(self, issue_number: int):
        return self.issue

    def add_labels(self, issue_number: int, labels):
        self.added_labels.extend(labels)


class _WorkerStub:
    def __init__(self):
        self.config = type(
            "Config",
            (),
            {"ready_label": "codex-ready", "lease_seconds": 300},
        )()
        self.calls: list[tuple[int, str, bool]] = []

    def run(self, issue_number: int, approved_by: str, *, already_claimed=False):
        self.calls.append((issue_number, approved_by, already_claimed))
        raise AssertionError("worker should not run in this test")


class SlackSettingsTests(unittest.TestCase):
    def test_requires_allowed_users(self) -> None:
        with self.assertRaisesRegex(ConfigError, "must not be empty"):
            SlackSettings.from_env(
                {
                    "SLACK_APP_TOKEN": "xapp-test",
                    "SLACK_BOT_TOKEN": "xoxb-test",
                    "SLACK_CHANNEL_ID": "C123",
                    "SLACK_ALLOWED_USER_IDS": ",",
                }
            )

    def test_rejects_fast_scan_interval(self) -> None:
        with self.assertRaisesRegex(ConfigError, "at least 30"):
            _settings(SCAN_INTERVAL_SECONDS="10")


class SlackAutomationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.state = StateStore(Path(self.temp.name) / "state.sqlite3")
        self.state.initialize()
        self.issue = Issue(
            8,
            "Implement approval flow",
            "",
            "https://github.com/90ms/pr-review-reminder/issues/8",
            "maintainer",
            frozenset({"codex-ready"}),
        )
        self.client = _ClientStub()
        self.github = _GitHubStub(self.issue)
        self.worker = _WorkerStub()
        self.automation = SlackAutomation(
            settings=_settings(),
            client=self.client,
            github=self.github,
            state=self.state,
            worker=self.worker,
            ci_timeout_seconds=60,
        )

    def tearDown(self) -> None:
        self.automation.close()
        self.temp.cleanup()

    def test_scan_posts_only_once_and_records_label(self) -> None:
        self.assertEqual(self.automation.scan_once(), 1)
        self.assertEqual(self.automation.scan_once(), 0)

        self.assertEqual(len(self.client.posts), 1)
        self.assertIn("codex-notified", self.github.added_labels)
        self.assertEqual(self.state.get(8).message_ts, "123.456")

    def test_unauthorized_action_is_acknowledged_and_rejected(self) -> None:
        acknowledgements: list[bool] = []
        responses: list[dict] = []

        self.automation.handle_implementation(
            {
                "user": {"id": "U-NOT-ALLOWED"},
                "actions": [{"value": "8"}],
            },
            lambda: acknowledgements.append(True),
            lambda **value: responses.append(value),
        )

        self.assertEqual(acknowledgements, [True])
        self.assertIn("권한", responses[0]["text"])
        self.assertIsNone(self.state.get(8))

    def test_duplicate_action_is_rejected_by_lease(self) -> None:
        self.state.record_notification(8, "123.456")
        self.assertTrue(self.state.claim(8, "U123", 300))
        responses: list[dict] = []

        self.automation.handle_implementation(
            {"user": {"id": "U123"}, "actions": [{"value": "8"}]},
            lambda: None,
            lambda **value: responses.append(value),
        )

        self.assertIn("이미 실행 중", responses[0]["text"])


def _settings(**overrides: str) -> SlackSettings:
    values = {
        "SLACK_APP_TOKEN": "xapp-test",
        "SLACK_BOT_TOKEN": "xoxb-test",
        "SLACK_CHANNEL_ID": "C123",
        "SLACK_ALLOWED_USER_IDS": "U123,U456",
        "SCAN_INTERVAL_SECONDS": "300",
    }
    values.update(overrides)
    return SlackSettings.from_env(values)


if __name__ == "__main__":
    unittest.main()
