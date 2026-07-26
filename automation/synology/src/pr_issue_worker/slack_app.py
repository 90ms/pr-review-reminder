from __future__ import annotations

import html
import logging
import os
import threading
from collections.abc import Callable, Mapping
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Any

from .config import ConfigError
from .github import GitHubClient
from .models import Issue, JobResult, JobStatus
from .state import StateStore
from .worker import IssueWorker

_IMPLEMENT_ACTION = "implement_github_issue"
_NOTIFIED_LABEL = "codex-notified"
_LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class SlackSettings:
    app_token: str
    bot_token: str
    channel_id: str
    allowed_user_ids: frozenset[str]
    scan_interval_seconds: int
    internal_scanner_enabled: bool

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> SlackSettings:
        values = os.environ if env is None else env
        app_token = _required(values, "SLACK_APP_TOKEN")
        bot_token = _required(values, "SLACK_BOT_TOKEN")
        channel_id = _required(values, "SLACK_CHANNEL_ID")
        allowed_users = frozenset(
            value.strip()
            for value in _required(values, "SLACK_ALLOWED_USER_IDS").split(",")
            if value.strip()
        )
        if not app_token.startswith("xapp-"):
            raise ConfigError("SLACK_APP_TOKEN must start with xapp-")
        if not bot_token.startswith("xoxb-"):
            raise ConfigError("SLACK_BOT_TOKEN must start with xoxb-")
        if not allowed_users:
            raise ConfigError("SLACK_ALLOWED_USER_IDS must not be empty")
        try:
            interval = int(values.get("SCAN_INTERVAL_SECONDS", "300"))
        except ValueError as error:
            raise ConfigError("SCAN_INTERVAL_SECONDS must be an integer") from error
        if interval < 30:
            raise ConfigError("SCAN_INTERVAL_SECONDS must be at least 30")
        return cls(
            app_token,
            bot_token,
            channel_id,
            allowed_users,
            interval,
            _boolean(
                values.get("ENABLE_INTERNAL_SCANNER", "true"),
                "ENABLE_INTERNAL_SCANNER",
            ),
        )


class SlackAutomation:
    def __init__(
        self,
        *,
        settings: SlackSettings,
        client: Any,
        github: GitHubClient,
        state: StateStore,
        worker: IssueWorker,
        ci_timeout_seconds: int,
    ):
        self.settings = settings
        self.client = client
        self.github = github
        self.state = state
        self.worker = worker
        self.ci_timeout_seconds = ci_timeout_seconds
        self.work_executor = ThreadPoolExecutor(
            max_workers=1, thread_name_prefix="issue-worker"
        )
        self.monitor_executor = ThreadPoolExecutor(
            max_workers=2, thread_name_prefix="ci-monitor"
        )
        self._stop_event = threading.Event()

    def scan_once(self) -> int:
        self._recover_stale_jobs()
        notified = 0
        for issue in self.github.list_issues(self.worker.config.ready_label):
            if _NOTIFIED_LABEL in issue.labels or not self.state.needs_notification(
                issue.number
            ):
                continue
            response = self.client.chat_postMessage(
                channel=self.settings.channel_id,
                text=f"Implementation approval requested for #{issue.number}",
                blocks=_approval_blocks(issue),
                unfurl_links=False,
                unfurl_media=False,
            )
            message_ts = str(response["ts"])
            if self.state.record_notification(issue.number, message_ts):
                self.github.add_labels(issue.number, [_NOTIFIED_LABEL])
                notified += 1
        return notified

    def _recover_stale_jobs(self) -> None:
        for issue_number in self.state.expire_stale_leases():
            try:
                issue = self.github.get_issue(issue_number)
                self.github.remove_labels(issue_number, ["codex-running"])
                self.github.add_labels(issue_number, ["codex-failed"])
                self._update_message(
                    issue,
                    "이전 작업 lease가 만료되었습니다. 로그를 확인한 뒤 다시 승인하세요.",
                    include_button=True,
                    button_text="재시도",
                )
                self._post_lifecycle_notification(
                    issue,
                    "❌ 이전 구현 작업의 lease가 만료되어 실패로 처리했습니다. "
                    "원본 메시지에서 로그를 확인한 뒤 재시도하세요.",
                )
            except Exception:
                _LOGGER.exception("Failed to recover stale issue #%s", issue_number)

    def handle_implementation(
        self,
        body: dict[str, Any],
        ack: Callable[[], None],
        respond: Callable[..., Any],
    ) -> None:
        ack()
        user_id = str(body.get("user", {}).get("id", ""))
        if user_id not in self.settings.allowed_user_ids:
            respond(
                text="이 작업을 승인할 권한이 없습니다.",
                response_type="ephemeral",
                replace_original=False,
            )
            return

        try:
            issue_number = int(body["actions"][0]["value"])
        except (KeyError, IndexError, TypeError, ValueError):
            respond(
                text="이슈 번호를 확인할 수 없습니다.",
                response_type="ephemeral",
                replace_original=False,
            )
            return

        try:
            issue = self.github.get_issue(issue_number)
        except (KeyError, RuntimeError, TypeError, ValueError) as error:
            respond(
                text=f"이슈를 다시 확인하지 못했습니다: {error}",
                response_type="ephemeral",
                replace_original=False,
            )
            return

        if self.worker.config.ready_label not in issue.labels:
            respond(
                text=f"`{self.worker.config.ready_label}` 라벨이 없어 실행하지 않았습니다.",
                response_type="ephemeral",
                replace_original=False,
            )
            return
        if not self.state.claim(
            issue.number, user_id, self.worker.config.lease_seconds
        ):
            respond(
                text="이미 실행 중이거나 Draft PR이 생성된 이슈입니다.",
                response_type="ephemeral",
                replace_original=False,
            )
            return

        self._update_message(
            issue,
            f"승인됨 · <@{user_id}> · 구현 작업 대기 중",
            include_button=False,
        )
        self.work_executor.submit(self._run_job, issue, user_id)

    def start_scanner(self) -> threading.Thread:
        thread = threading.Thread(
            target=self._scan_loop,
            name="issue-scanner",
            daemon=True,
        )
        thread.start()
        return thread

    def close(self) -> None:
        self._stop_event.set()
        self.work_executor.shutdown(wait=False, cancel_futures=True)
        self.monitor_executor.shutdown(wait=False, cancel_futures=True)

    def _scan_loop(self) -> None:
        while not self._stop_event.is_set():
            try:
                self.scan_once()
            except Exception:
                _LOGGER.exception("Slack issue scan failed")
            self._stop_event.wait(self.settings.scan_interval_seconds)

    def _run_job(self, issue: Issue, approved_by: str) -> None:
        self._update_message(
            issue,
            f"구현 중 · 승인자 <@{approved_by}>",
            include_button=False,
        )
        self._post_lifecycle_notification(
            issue,
            f"🚀 <@{approved_by}> · Issue #{issue.number} 구현을 시작했습니다.",
        )
        try:
            result = self.worker.run(issue.number, approved_by, already_claimed=True)
        except Exception as error:
            self._handle_unexpected_worker_error(issue, approved_by, error)
            return

        if result.status is JobStatus.COMPLETED and result.pull_request:
            self._update_message(
                issue,
                f"Draft PR 생성 완료: <{result.pull_request.url}|"
                f"#{result.pull_request.number}> · CI 확인 중",
                include_button=False,
            )
            self._post_lifecycle_notification(
                issue,
                f"✅ <@{approved_by}> · Issue #{issue.number} 구현과 Draft PR "
                f"<{result.pull_request.url}|#{result.pull_request.number}> 생성이 "
                "완료되었습니다. CI를 확인하고 있습니다.",
            )
            self.monitor_executor.submit(self._monitor_checks, issue, result)
            return
        if result.status is JobStatus.COMPLETED:
            self._update_message(
                issue,
                _escape_message(result.summary),
                include_button=False,
            )
            self._post_lifecycle_notification(
                issue,
                f"✅ <@{approved_by}> · Issue #{issue.number} 구현이 완료되었습니다.",
            )
            return

        self._update_message(
            issue,
            _escape_message(result.summary),
            include_button=result.status is JobStatus.FAILED,
            button_text="재시도",
        )
        if result.status is JobStatus.FAILED:
            self._post_lifecycle_notification(
                issue,
                f"❌ <@{approved_by}> · Issue #{issue.number} 구현에 실패했습니다. "
                "원본 메시지에서 오류와 재시도 버튼을 확인하세요.",
            )
        else:
            self._post_lifecycle_notification(
                issue,
                f"⚠️ <@{approved_by}> · Issue #{issue.number} 구현이 중단되었습니다. "
                "원본 메시지에서 필요한 조치를 확인하세요.",
            )

    def _monitor_checks(self, issue: Issue, result: JobResult) -> None:
        pull_request = result.pull_request
        if pull_request is None:
            return
        check_result = self.github.wait_for_pr_checks(
            pull_request.number, self.ci_timeout_seconds
        )
        status = "CI 통과" if check_result.passed else "CI 실패 또는 미완료"
        self._update_message(
            issue,
            f"Draft PR <{pull_request.url}|#{pull_request.number}> · {status}\n"
            f"```{_code_block(check_result.summary, 1200)}```",
            include_button=False,
        )
        icon = "✅" if check_result.passed else "⚠️"
        self._post_lifecycle_notification(
            issue,
            f"{icon} Issue #{issue.number} Draft PR "
            f"<{pull_request.url}|#{pull_request.number}>의 {status} 결과가 "
            "도착했습니다.",
        )

    def _handle_unexpected_worker_error(
        self,
        issue: Issue,
        approved_by: str,
        error: Exception,
    ) -> None:
        _LOGGER.exception(
            "Unexpected worker error for issue #%s: %s",
            issue.number,
            error,
        )
        self.state.finish(issue.number, "failed", error=str(error))
        if not self.worker.config.dry_run:
            try:
                self.github.remove_labels(issue.number, ["codex-running"])
                self.github.add_labels(issue.number, ["codex-failed"])
            except Exception:
                _LOGGER.exception(
                    "Failed to mark unexpected issue #%s failure",
                    issue.number,
                )
        self._update_message(
            issue,
            "예상하지 못한 워커 오류가 발생했습니다. 운영 로그를 확인한 뒤 "
            "재시도하세요.",
            include_button=True,
            button_text="재시도",
        )
        self._post_lifecycle_notification(
            issue,
            f"❌ <@{approved_by}> · Issue #{issue.number} 구현 중 예상하지 못한 "
            "오류가 발생했습니다. 운영 로그를 확인하세요.",
        )

    def _update_message(
        self,
        issue: Issue,
        status: str,
        *,
        include_button: bool,
        button_text: str = "구현 시작",
    ) -> None:
        state = self.state.get(issue.number)
        if state is None or not state.message_ts:
            _LOGGER.error("No Slack message recorded for issue #%s", issue.number)
            return
        try:
            self.client.chat_update(
                channel=self.settings.channel_id,
                ts=state.message_ts,
                text=f"Issue #{issue.number}: {status}",
                blocks=_status_blocks(
                    issue,
                    status,
                    include_button=include_button,
                    button_text=button_text,
                ),
            )
        except Exception:
            _LOGGER.exception(
                "Failed to update Slack message for issue #%s",
                issue.number,
            )

    def _post_lifecycle_notification(self, issue: Issue, text: str) -> None:
        state = self.state.get(issue.number)
        if state is None or not state.message_ts:
            _LOGGER.error("No Slack thread recorded for issue #%s", issue.number)
            return
        try:
            self.client.chat_postMessage(
                channel=self.settings.channel_id,
                thread_ts=state.message_ts,
                reply_broadcast=True,
                text=text,
                unfurl_links=False,
                unfurl_media=False,
            )
        except Exception:
            _LOGGER.exception(
                "Failed to post Slack lifecycle notification for issue #%s",
                issue.number,
            )


def run_socket_service(
    *,
    settings: SlackSettings,
    github: GitHubClient,
    state: StateStore,
    worker: IssueWorker,
    ci_timeout_seconds: int,
) -> None:
    from slack_bolt import App
    from slack_bolt.adapter.socket_mode import SocketModeHandler

    app = App(token=settings.bot_token)
    automation = SlackAutomation(
        settings=settings,
        client=app.client,
        github=github,
        state=state,
        worker=worker,
        ci_timeout_seconds=ci_timeout_seconds,
    )
    app.action(_IMPLEMENT_ACTION)(automation.handle_implementation)
    if settings.internal_scanner_enabled:
        automation.start_scanner()
    try:
        SocketModeHandler(app, settings.app_token).start()
    finally:
        automation.close()


def notify_once(
    *,
    settings: SlackSettings,
    github: GitHubClient,
    state: StateStore,
    worker: IssueWorker,
    ci_timeout_seconds: int,
) -> int:
    from slack_sdk import WebClient

    automation = SlackAutomation(
        settings=settings,
        client=WebClient(token=settings.bot_token),
        github=github,
        state=state,
        worker=worker,
        ci_timeout_seconds=ci_timeout_seconds,
    )
    try:
        return automation.scan_once()
    finally:
        automation.close()


def _approval_blocks(issue: Issue) -> list[dict[str, Any]]:
    return _status_blocks(
        issue,
        "승인 대기 중",
        include_button=True,
        button_text="구현 시작",
    )


def _status_blocks(
    issue: Issue,
    status: str,
    *,
    include_button: bool,
    button_text: str,
) -> list[dict[str, Any]]:
    title = html.escape(_truncate(issue.title, 220))
    author = html.escape(issue.author)
    blocks: list[dict[str, Any]] = [
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*<{issue.url}|#{issue.number} {title}>*\n작성자: `{author}`",
            },
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*상태*\n{_truncate(status, 1800)}",
            },
        },
    ]
    if include_button:
        blocks.append(
            {
                "type": "actions",
                "elements": [
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": button_text},
                        "style": "primary",
                        "action_id": _IMPLEMENT_ACTION,
                        "value": str(issue.number),
                        "confirm": {
                            "title": {
                                "type": "plain_text",
                                "text": "Codex 구현을 시작할까요?",
                            },
                            "text": {
                                "type": "mrkdwn",
                                "text": (
                                    "브랜치를 push하고 Draft PR을 만들 수 있습니다."
                                ),
                            },
                            "confirm": {"type": "plain_text", "text": "시작"},
                            "deny": {"type": "plain_text", "text": "취소"},
                        },
                    }
                ],
            }
        )
    return blocks


def _required(values: Mapping[str, str], name: str) -> str:
    value = values.get(name, "").strip()
    if not value:
        raise ConfigError(f"{name} is required")
    return value


def _boolean(raw: str, name: str) -> bool:
    normalized = raw.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ConfigError(f"{name} must be a boolean")


def _truncate(value: str, limit: int) -> str:
    return value if len(value) <= limit else value[: limit - 1] + "…"


def _escape_message(value: str) -> str:
    return html.escape(_truncate(value, 1600))


def _code_block(value: str, limit: int) -> str:
    return _truncate(value.replace("```", "'''"), limit)
