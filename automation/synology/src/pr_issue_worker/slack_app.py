from __future__ import annotations

import html
import logging
import os
import threading
import time
from collections.abc import Callable, Mapping
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from .config import ConfigError
from .github import GitHubClient
from .models import Issue, JobPhase, JobResult, JobStatus
from .state import JobState, StateStore
from .worker import IssueWorker

_IMPLEMENT_ACTION = "implement_github_issue"
_STATUS_ACTION = "refresh_github_issue_status"
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
    status_update_interval_seconds: int
    job_heartbeat_stale_seconds: int
    timeout_warning_seconds: int

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
        interval = _integer(values, "SCAN_INTERVAL_SECONDS", 300)
        if interval < 30:
            raise ConfigError("SCAN_INTERVAL_SECONDS must be at least 30")
        status_interval = _integer(
            values, "STATUS_UPDATE_INTERVAL_SECONDS", 60
        )
        if status_interval < 15:
            raise ConfigError(
                "STATUS_UPDATE_INTERVAL_SECONDS must be at least 15"
            )
        stale_seconds = _integer(
            values, "JOB_HEARTBEAT_STALE_SECONDS", 45
        )
        if stale_seconds < 10:
            raise ConfigError(
                "JOB_HEARTBEAT_STALE_SECONDS must be at least 10"
            )
        timeout_warning = _integer(
            values, "JOB_TIMEOUT_WARNING_SECONDS", 300
        )
        if timeout_warning <= 0:
            raise ConfigError("JOB_TIMEOUT_WARNING_SECONDS must be positive")
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
            status_interval,
            stale_seconds,
            timeout_warning,
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
        self._progress_lock = threading.Lock()
        self._last_progress_update: dict[int, tuple[float, str | None]] = {}
        self._stale_warnings: set[int] = set()
        self._timeout_warnings: set[int] = set()

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

        with self._progress_lock:
            self._stale_warnings.discard(issue.number)
            self._timeout_warnings.discard(issue.number)
            self._last_progress_update.pop(issue.number, None)
        self._update_message(
            issue,
            f"승인됨 · <@{user_id}> · 구현 작업 대기 중",
            include_button=False,
            include_status_button=True,
        )
        self.work_executor.submit(self._run_job, issue, user_id)

    def handle_status_refresh(
        self,
        body: dict[str, Any],
        ack: Callable[[], None],
        respond: Callable[..., Any],
    ) -> None:
        ack()
        user_id = str(body.get("user", {}).get("id", ""))
        if user_id not in self.settings.allowed_user_ids:
            respond(
                text="작업 상태를 확인할 권한이 없습니다.",
                response_type="ephemeral",
                replace_original=False,
            )
            return
        try:
            issue_number = int(body["actions"][0]["value"])
            issue = self.github.get_issue(issue_number)
        except (KeyError, IndexError, RuntimeError, TypeError, ValueError) as error:
            respond(
                text=f"작업 상태를 확인하지 못했습니다: {error}",
                response_type="ephemeral",
                replace_original=False,
            )
            return
        state = self.state.get(issue_number)
        if (
            state is None
            or state.phase is None
            or state.status not in {"running", "pr_open"}
        ):
            respond(
                text="현재 실행 중이거나 CI 확인 중인 작업이 없습니다.",
                response_type="ephemeral",
                replace_original=False,
            )
            return
        self._update_progress_message(issue, state, force=True)
        respond(
            text="최신 작업 상태로 갱신했습니다.",
            response_type="ephemeral",
            replace_original=False,
        )

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
            include_status_button=True,
        )
        self._post_lifecycle_notification(
            issue,
            f"🚀 <@{approved_by}> · Issue #{issue.number} 구현을 시작했습니다.",
        )
        monitor_stop = threading.Event()
        monitor = self._start_progress_monitor(issue, monitor_stop)
        result: JobResult | None = None
        worker_error: Exception | None = None
        try:
            result = self.worker.run(
                issue.number,
                approved_by,
                already_claimed=True,
                progress_callback=lambda state: self._update_progress_message(
                    issue, state
                ),
            )
        except Exception as error:
            worker_error = error
        finally:
            monitor_stop.set()
            monitor.join(timeout=1)

        if worker_error is not None:
            self._handle_unexpected_worker_error(issue, approved_by, worker_error)
            return
        if result is None:
            self._handle_unexpected_worker_error(
                issue,
                approved_by,
                RuntimeError("worker returned no result"),
            )
            return

        if result.status is JobStatus.COMPLETED and result.pull_request:
            self._update_message(
                issue,
                f"Draft PR 생성 완료: <{result.pull_request.url}|"
                f"#{result.pull_request.number}> · CI 확인 중",
                include_button=False,
                include_status_button=True,
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
            include_button=result.status in {JobStatus.FAILED, JobStatus.BLOCKED},
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
                f"⚠️ <@{approved_by}> · Issue #{issue.number} 구현이 차단되었습니다. "
                "원본 메시지에서 원인을 확인하고 조치한 뒤 재시도하세요.",
            )

    def _monitor_checks(self, issue: Issue, result: JobResult) -> None:
        pull_request = result.pull_request
        if pull_request is None:
            return
        state = self.state.update_progress(issue.number, JobPhase.MONITORING_CI)
        if state is not None:
            self._update_progress_message(issue, state, force=True)
        monitor_stop = threading.Event()
        monitor = self._start_progress_monitor(issue, monitor_stop)
        try:
            check_result = self.github.wait_for_pr_checks(
                pull_request.number, self.ci_timeout_seconds
            )
        finally:
            monitor_stop.set()
            monitor.join(timeout=1)
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

    def _start_progress_monitor(
        self,
        issue: Issue,
        stop: threading.Event,
    ) -> threading.Thread:
        thread = threading.Thread(
            target=self._progress_monitor_loop,
            args=(issue, stop),
            name=f"slack-progress-{issue.number}",
            daemon=True,
        )
        thread.start()
        return thread

    def _progress_monitor_loop(
        self,
        issue: Issue,
        stop: threading.Event,
    ) -> None:
        while not stop.wait(self.settings.status_update_interval_seconds):
            state = self.state.get(issue.number)
            if state is None or state.status not in {"running", "pr_open"}:
                return
            self._update_progress_message(issue, state, force=True)

    def _update_progress_message(
        self,
        issue: Issue,
        state: JobState,
        *,
        force: bool = False,
    ) -> None:
        now_monotonic = time.monotonic()
        with self._progress_lock:
            previous = self._last_progress_update.get(issue.number)
            phase_changed = previous is None or previous[1] != state.phase
            interval_elapsed = (
                previous is None
                or now_monotonic - previous[0]
                >= self.settings.status_update_interval_seconds
            )
            should_update = force or phase_changed or interval_elapsed
            if should_update:
                self._last_progress_update[issue.number] = (
                    now_monotonic,
                    state.phase,
                )
        if should_update:
            self._update_message(
                issue,
                _progress_status(state, self.settings.job_heartbeat_stale_seconds),
                include_button=False,
                include_status_button=True,
            )
        self._warn_if_progress_is_stale(issue, state)
        self._warn_if_timeout_is_near(issue, state)

    def _warn_if_progress_is_stale(
        self,
        issue: Issue,
        state: JobState,
    ) -> None:
        if state.phase not in {
            JobPhase.RUNNER_CLAIMED.value,
            JobPhase.CODEX_RUNNING.value,
        }:
            return
        age = _age_seconds(state.runner_updated_at)
        if age is None or age <= self.settings.job_heartbeat_stale_seconds:
            return
        with self._progress_lock:
            if issue.number in self._stale_warnings:
                return
            self._stale_warnings.add(issue.number)
        self._post_lifecycle_notification(
            issue,
            f"⚠️ Issue #{issue.number} Runner heartbeat가 "
            f"{_duration(age)} 동안 갱신되지 않았습니다. "
            "작업은 자동 종료하지 않으며 상태를 다시 확인합니다.",
        )

    def _warn_if_timeout_is_near(
        self,
        issue: Issue,
        state: JobState,
    ) -> None:
        if state.phase != JobPhase.CODEX_RUNNING.value:
            return
        elapsed = _age_seconds(state.started_at)
        if elapsed is None:
            return
        remaining = self.worker.config.job_timeout_seconds - elapsed
        if remaining > self.settings.timeout_warning_seconds or remaining <= 0:
            return
        with self._progress_lock:
            if issue.number in self._timeout_warnings:
                return
            self._timeout_warnings.add(issue.number)
        self._post_lifecycle_notification(
            issue,
            f"⚠️ Issue #{issue.number} Codex timeout까지 약 "
            f"{_duration(remaining)} 남았습니다.",
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
        include_status_button: bool = False,
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
                    include_status_button=include_status_button,
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
    app.action(_STATUS_ACTION)(automation.handle_status_refresh)
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
    include_status_button: bool = False,
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
    actions: list[dict[str, Any]] = []
    if include_button:
        actions.append(
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
                        "text": "브랜치를 push하고 Draft PR을 만들 수 있습니다.",
                    },
                    "confirm": {"type": "plain_text", "text": "시작"},
                    "deny": {"type": "plain_text", "text": "취소"},
                },
            }
        )
    if include_status_button:
        actions.append(
            {
                "type": "button",
                "text": {"type": "plain_text", "text": "상태 새로고침"},
                "action_id": _STATUS_ACTION,
                "value": str(issue.number),
            }
        )
    if actions:
        blocks.append(
            {
                "type": "actions",
                "elements": actions,
            }
        )
    return blocks


def _required(values: Mapping[str, str], name: str) -> str:
    value = values.get(name, "").strip()
    if not value:
        raise ConfigError(f"{name} is required")
    return value


def _integer(
    values: Mapping[str, str],
    name: str,
    default: int,
) -> int:
    try:
        return int(values.get(name, str(default)))
    except ValueError as error:
        raise ConfigError(f"{name} must be an integer") from error


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


def _progress_status(state: JobState, stale_seconds: int) -> str:
    labels = {
        JobPhase.PREPARING.value: "저장소 준비 중",
        JobPhase.QUEUED.value: "Runner 대기 중",
        JobPhase.RUNNER_CLAIMED.value: "Runner가 작업을 수신함",
        JobPhase.CODEX_RUNNING.value: "Codex 구현 중",
        JobPhase.RESULT_READY.value: "Runner 결과 수신",
        JobPhase.VALIDATING.value: "변경사항 검증 중",
        JobPhase.PUSHING.value: "브랜치 push 중",
        JobPhase.CREATING_PR.value: "Draft PR 생성 중",
        JobPhase.MONITORING_CI.value: "GitHub Actions 확인 중",
    }
    phase = labels.get(state.phase or "", "작업 상태 확인 중")
    elapsed = _age_seconds(state.started_at)
    activity_at = (
        state.runner_updated_at
        if state.phase
        in {JobPhase.RUNNER_CLAIMED.value, JobPhase.CODEX_RUNNING.value}
        else state.progress_updated_at
    )
    activity_age = _age_seconds(activity_at)
    if state.phase in {
        JobPhase.RUNNER_CLAIMED.value,
        JobPhase.CODEX_RUNNING.value,
    }:
        if activity_age is None:
            health = "Runner 확인 중"
        elif activity_age > stale_seconds:
            health = f"Runner 응답 지연 · 마지막 활동 {_duration(activity_age)} 전"
        else:
            health = f"Runner 정상 · 마지막 활동 {_duration(activity_age)} 전"
    else:
        health = (
            f"Controller 정상 · 마지막 활동 {_duration(activity_age)} 전"
            if activity_age is not None
            else "Controller 상태 확인 중"
        )
    lines = [
        f"{phase} · 승인자 <@{state.approved_by or 'unknown'}>",
        f"경과 {_duration(elapsed or 0)} · {health}",
    ]
    if state.phase == JobPhase.MONITORING_CI.value and state.pr_url:
        lines.append(f"Draft PR <{state.pr_url}|#{state.pr_number}>")
    return "\n".join(lines)


def _age_seconds(value: str | None) -> float | None:
    if not value:
        return None
    try:
        timestamp = datetime.fromisoformat(value)
    except ValueError:
        return None
    if timestamp.tzinfo is None or timestamp.utcoffset() is None:
        return None
    return max(0.0, (datetime.now(UTC) - timestamp).total_seconds())


def _duration(seconds: float) -> str:
    total = max(0, int(seconds))
    hours, remainder = divmod(total, 3600)
    minutes, seconds = divmod(remainder, 60)
    if hours:
        return f"{hours}시간 {minutes}분"
    if minutes:
        return f"{minutes}분 {seconds}초"
    return f"{seconds}초"
