from __future__ import annotations

import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path

from pr_issue_worker.config import ConfigError
from pr_issue_worker.models import (
    CheckResult,
    Issue,
    JobPhase,
    JobResult,
    JobStatus,
    PullRequest,
)
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
        self.removed_labels: list[str] = []
        self.check_result = CheckResult(True, "All checks passed")

    def list_issues(self, label: str):
        return [self.issue]

    def get_issue(self, issue_number: int):
        return self.issue

    def add_labels(self, issue_number: int, labels):
        self.added_labels.extend(labels)

    def remove_labels(self, issue_number: int, labels):
        self.removed_labels.extend(labels)

    def wait_for_pr_checks(self, pull_request_number: int, timeout_seconds: int):
        return self.check_result


class _WorkerStub:
    def __init__(self):
        self.config = type(
            "Config",
            (),
            {
                "ready_label": "codex-ready",
                "lease_seconds": 300,
                "job_timeout_seconds": 3600,
                "dry_run": False,
            },
        )()
        self.calls: list[tuple[int, str, bool]] = []
        self.result: JobResult | None = None
        self.error: Exception | None = None

    def run(
        self,
        issue_number: int,
        approved_by: str,
        *,
        already_claimed=False,
        progress_callback=None,
    ):
        self.calls.append((issue_number, approved_by, already_claimed))
        if self.error:
            raise self.error
        if self.result:
            return self.result
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

    def test_can_disable_internal_scanner_for_nas_scheduler(self) -> None:
        settings = _settings(ENABLE_INTERNAL_SCANNER="false")

        self.assertFalse(settings.internal_scanner_enabled)

    def test_rejects_fast_status_update_interval(self) -> None:
        with self.assertRaisesRegex(ConfigError, "at least 15"):
            _settings(STATUS_UPDATE_INTERVAL_SECONDS="10")


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

    def test_scan_recovers_expired_job_with_retry_button(self) -> None:
        self.state.record_notification(8, "123.456")
        self.assertTrue(self.state.claim(8, "U123", 300))
        with self.state._connect() as connection:
            connection.execute(
                """
                UPDATE issue_jobs
                SET lease_until = '2000-01-01T00:00:00+00:00'
                WHERE issue_number = 8
                """
            )

        self.assertEqual(self.automation.scan_once(), 0)

        self.assertIn("codex-running", self.github.removed_labels)
        self.assertIn("codex-failed", self.github.added_labels)
        self.assertEqual(self.state.get(8).status, "failed")
        actions = [
            block
            for block in self.client.updates[-1]["blocks"]
            if block["type"] == "actions"
        ]
        self.assertEqual(actions[0]["elements"][0]["text"]["text"], "재시도")
        self.assertEqual(self.client.posts[-1]["thread_ts"], "123.456")
        self.assertTrue(self.client.posts[-1]["reply_broadcast"])
        self.assertIn("lease", self.client.posts[-1]["text"])

    def test_job_broadcasts_started_and_completed_notifications(self) -> None:
        self._claim_issue()
        self.worker.result = JobResult(
            JobStatus.COMPLETED,
            self.issue.number,
            "Implemented successfully",
        )

        self.automation._run_job(self.issue, "U123")

        self.assertEqual(len(self.client.posts), 2)
        self.assertIn("시작", self.client.posts[0]["text"])
        self.assertIn("완료", self.client.posts[1]["text"])
        for post in self.client.posts:
            self.assertEqual(post["thread_ts"], "123.456")
            self.assertTrue(post["reply_broadcast"])

    def test_job_broadcasts_failure_with_retry_status(self) -> None:
        self._claim_issue()
        self.worker.result = JobResult(
            JobStatus.FAILED,
            self.issue.number,
            "Codex timed out",
        )

        self.automation._run_job(self.issue, "U123")

        self.assertIn("실패", self.client.posts[-1]["text"])
        actions = [
            block
            for block in self.client.updates[-1]["blocks"]
            if block["type"] == "actions"
        ]
        self.assertEqual(actions[0]["elements"][0]["text"]["text"], "재시도")

    def test_job_broadcasts_blocked_status_with_retry_button(self) -> None:
        self._claim_issue()
        self.worker.result = JobResult(
            JobStatus.BLOCKED,
            self.issue.number,
            "Runner heartbeat is stale",
        )

        self.automation._run_job(self.issue, "U123")

        self.assertIn("차단", self.client.posts[-1]["text"])
        self.assertIn("재시도", self.client.posts[-1]["text"])
        actions = [
            block
            for block in self.client.updates[-1]["blocks"]
            if block["type"] == "actions"
        ]
        self.assertEqual(actions[0]["elements"][0]["text"]["text"], "재시도")

    def test_unexpected_worker_error_is_recorded_and_notified(self) -> None:
        self._claim_issue()
        self.worker.error = RuntimeError("unexpected failure")

        with self.assertLogs("pr_issue_worker.slack_app", level="ERROR"):
            self.automation._run_job(self.issue, "U123")

        self.assertEqual(self.state.get(8).status, "failed")
        self.assertIn("codex-running", self.github.removed_labels)
        self.assertIn("codex-failed", self.github.added_labels)
        self.assertIn("예상하지 못한", self.client.posts[-1]["text"])

    def test_ci_result_is_broadcast_to_the_issue_thread(self) -> None:
        self._claim_issue()
        result = JobResult(
            JobStatus.COMPLETED,
            self.issue.number,
            "Implemented successfully",
            pull_request=PullRequest(
                42,
                "https://github.com/90ms/pr-review-reminder/pull/42",
                "codex/issue-8",
            ),
        )

        self.automation._monitor_checks(self.issue, result)

        self.assertIn("CI 통과", self.client.posts[-1]["text"])
        self.assertEqual(self.client.posts[-1]["thread_ts"], "123.456")

    def test_running_status_shows_phase_health_and_refresh_button(self) -> None:
        self._claim_issue()
        now = datetime.now(UTC).isoformat()
        state = self.state.update_progress(
            8,
            JobPhase.CODEX_RUNNING,
            job_id="00000000-0000-0000-0000-000000000008",
            runner_updated_at=now,
        )

        self.automation._update_progress_message(self.issue, state, force=True)

        blocks = self.client.updates[-1]["blocks"]
        status = blocks[1]["text"]["text"]
        actions = [block for block in blocks if block["type"] == "actions"]
        self.assertIn("Codex 구현 중", status)
        self.assertIn("Runner 정상", status)
        self.assertEqual(
            actions[0]["elements"][0]["text"]["text"],
            "상태 새로고침",
        )

    def test_authorized_user_can_refresh_running_status(self) -> None:
        self._claim_issue()
        self.state.update_progress(8, JobPhase.PREPARING)
        responses: list[dict] = []

        self.automation.handle_status_refresh(
            {"user": {"id": "U123"}, "actions": [{"value": "8"}]},
            lambda: None,
            lambda **value: responses.append(value),
        )

        self.assertIn("갱신", responses[0]["text"])
        self.assertIn("저장소 준비 중", self.client.updates[-1]["text"])

    def test_unauthorized_user_cannot_refresh_running_status(self) -> None:
        self._claim_issue()
        self.state.update_progress(8, JobPhase.PREPARING)
        responses: list[dict] = []

        self.automation.handle_status_refresh(
            {"user": {"id": "U-NOT-ALLOWED"}, "actions": [{"value": "8"}]},
            lambda: None,
            lambda **value: responses.append(value),
        )

        self.assertIn("권한", responses[0]["text"])
        self.assertEqual(self.client.updates, [])

    def test_same_progress_phase_is_throttled(self) -> None:
        self._claim_issue()
        state = self.state.update_progress(8, JobPhase.PREPARING)

        self.automation._update_progress_message(self.issue, state)
        self.automation._update_progress_message(self.issue, state)

        self.assertEqual(len(self.client.updates), 1)

    def test_stale_runner_warning_is_broadcast_only_once(self) -> None:
        self._claim_issue()
        stale = (datetime.now(UTC) - timedelta(minutes=2)).isoformat()
        state = self.state.update_progress(
            8,
            JobPhase.CODEX_RUNNING,
            runner_updated_at=stale,
        )

        self.automation._update_progress_message(self.issue, state, force=True)
        self.automation._update_progress_message(self.issue, state, force=True)

        warnings = [
            post for post in self.client.posts if "heartbeat" in post["text"]
        ]
        self.assertEqual(len(warnings), 1)

    def test_timeout_warning_is_broadcast_only_once(self) -> None:
        self._claim_issue()
        started = (datetime.now(UTC) - timedelta(seconds=3350)).isoformat()
        with self.state._connect() as connection:
            connection.execute(
                "UPDATE issue_jobs SET started_at = ? WHERE issue_number = 8",
                (started,),
            )
        state = self.state.update_progress(
            8,
            JobPhase.CODEX_RUNNING,
            runner_updated_at=datetime.now(UTC).isoformat(),
        )

        self.automation._update_progress_message(self.issue, state, force=True)
        self.automation._update_progress_message(self.issue, state, force=True)

        warnings = [
            post for post in self.client.posts if "timeout" in post["text"]
        ]
        self.assertEqual(len(warnings), 1)

    def _claim_issue(self) -> None:
        self.state.record_notification(8, "123.456")
        self.assertTrue(self.state.claim(8, "U123", 300))


def _settings(**overrides: str) -> SlackSettings:
    values = {
        "SLACK_APP_TOKEN": "xapp-test",
        "SLACK_BOT_TOKEN": "xoxb-test",
        "SLACK_CHANNEL_ID": "C123",
        "SLACK_ALLOWED_USER_IDS": "U123,U456",
        "SCAN_INTERVAL_SECONDS": "300",
        "ENABLE_INTERNAL_SCANNER": "true",
        "STATUS_UPDATE_INTERVAL_SECONDS": "60",
        "JOB_HEARTBEAT_STALE_SECONDS": "45",
        "JOB_TIMEOUT_WARNING_SECONDS": "300",
    }
    values.update(overrides)
    return SlackSettings.from_env(values)


if __name__ == "__main__":
    unittest.main()
