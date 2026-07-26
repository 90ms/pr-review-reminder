from __future__ import annotations

import json
import os
import re
import shutil
import tempfile
from collections.abc import Callable
from pathlib import Path

from .config import Config
from .github import GitHubClient
from .job_protocol import RunnerPhase, RunnerProgress, RunnerRequest, new_job_id
from .job_queue import FileJobClient
from .models import Issue, JobPhase, JobResult, JobStatus, PullRequest
from .process import (
    CommandError,
    CommandRunner,
    CommandTimeout,
    minimal_environment,
)
from .state import JobState, StateStore

_TERMINAL_LABELS = ("codex-failed", "codex-blocked", "codex-pr-open")
_TOKEN_PATTERN = re.compile(
    rb"(?:gh[pousr]_[A-Za-z0-9_]{20,}|"
    rb"xox[baprs]-[A-Za-z0-9-]{20,}|"
    rb"sk-[A-Za-z0-9_-]{20,})"
)
_SECRET_KEY_PARTS = ("token", "secret", "password", "credential")


class IssueWorker:
    def __init__(
        self,
        config: Config,
        state: StateStore,
        github: GitHubClient,
        runner: CommandRunner,
        job_client: FileJobClient | None = None,
    ):
        self.config = config
        self.state = state
        self.github = github
        self.runner = runner
        self.job_client = job_client

    def run(
        self,
        issue_number: int,
        approved_by: str,
        *,
        already_claimed: bool = False,
        progress_callback: Callable[[JobState], None] | None = None,
    ) -> JobResult:
        if not already_claimed and not self.state.claim(
            issue_number, approved_by, self.config.lease_seconds
        ):
            return JobResult(
                JobStatus.BLOCKED,
                issue_number,
                "The issue is already running or already has an open PR.",
            )

        self._report_progress(
            issue_number,
            JobPhase.PREPARING,
            progress_callback,
        )
        workspace: Path | None = None
        try:
            issue = self.github.get_issue(issue_number)
            if self.config.ready_label not in issue.labels:
                return self._blocked(
                    issue_number,
                    f"Issue no longer has the {self.config.ready_label} label.",
                )

            branch = _branch_name(issue)
            existing = self.github.find_existing_pr(issue.number, branch)
            if existing:
                self.state.finish(
                    issue.number,
                    "pr_open",
                    pr_number=existing.number,
                    pr_url=existing.url,
                )
                self._set_terminal_label(issue.number, "codex-pr-open")
                return JobResult(
                    JobStatus.COMPLETED,
                    issue.number,
                    "An open pull request already covers this issue.",
                    branch=existing.head_ref,
                    pull_request=existing,
                )

            self._set_running_label(issue.number)
            workspace = self._prepare_workspace(issue, branch)
            base_sha = self._git(["rev-parse", "HEAD"], cwd=workspace).stdout.strip()
            codex_result = self._run_codex(
                issue,
                workspace,
                base_sha,
                branch,
                progress_callback,
            )
            status = JobStatus(codex_result["status"])
            if status is JobStatus.BLOCKED:
                return self._blocked(
                    issue.number,
                    str(codex_result["summary"]),
                    workspace=workspace,
                    branch=branch,
                    details=codex_result,
                )
            if status is JobStatus.FAILED:
                raise RuntimeError(str(codex_result["summary"]))

            self._report_progress(
                issue.number,
                JobPhase.VALIDATING,
                progress_callback,
            )
            self._restore_repository_boundary(workspace, branch, base_sha)
            changed_paths = self._changed_paths(workspace, base_sha)
            protected = self._protected_changes(changed_paths)
            if protected:
                return self._blocked(
                    issue.number,
                    "Protected paths require manual implementation: "
                    + ", ".join(protected),
                    workspace=workspace,
                    branch=branch,
                    details=codex_result,
                )
            leaked_paths = self._secret_leaks(workspace, changed_paths)
            if leaked_paths:
                return self._blocked(
                    issue.number,
                    "Generated changes contain credential material in: "
                    + ", ".join(leaked_paths),
                    workspace=workspace,
                    branch=branch,
                    details=codex_result,
                )
            if not changed_paths:
                return self._blocked(
                    issue.number,
                    "Codex completed without producing a repository change.",
                    workspace=workspace,
                    branch=branch,
                    details=codex_result,
                )

            self._commit_remaining_changes(issue, workspace)
            self._verify_branch(workspace, branch, base_sha)

            if self.config.dry_run:
                self.state.finish(issue.number, "blocked", error="dry-run")
                return _job_result(
                    JobStatus.BLOCKED,
                    issue,
                    "Dry run completed; branch was not pushed.",
                    workspace,
                    branch,
                    codex_result,
                )

            self._report_progress(
                issue.number,
                JobPhase.PUSHING,
                progress_callback,
            )
            self._git(
                [
                    "-c",
                    "credential.https://github.com.helper=!gh auth git-credential",
                    "push",
                    "--set-upstream",
                    "origin",
                    branch,
                ],
                cwd=workspace,
            )
            self._report_progress(
                issue.number,
                JobPhase.CREATING_PR,
                progress_callback,
            )
            pull_request = self.github.create_draft_pr(
                issue=issue,
                base_branch=self.config.base_branch,
                head_branch=branch,
                summary=str(codex_result["summary"]),
                cwd=workspace,
            )
            self.state.finish(
                issue.number,
                "pr_open",
                pr_number=pull_request.number,
                pr_url=pull_request.url,
            )
            self._set_terminal_label(issue.number, "codex-pr-open")
            result = _job_result(
                JobStatus.COMPLETED,
                issue,
                str(codex_result["summary"]),
                workspace,
                branch,
                codex_result,
                pull_request,
            )
            shutil.rmtree(workspace.parent, ignore_errors=True)
            return result
        except (
            CommandError,
            CommandTimeout,
            KeyError,
            OSError,
            RuntimeError,
            TypeError,
            ValueError,
        ) as error:
            self.state.finish(issue_number, "failed", error=str(error))
            self._try_set_terminal_label(issue_number, "codex-failed")
            return JobResult(
                JobStatus.FAILED,
                issue_number,
                str(error),
                workspace=str(workspace) if workspace else None,
            )

    def _prepare_workspace(self, issue: Issue, branch: str) -> Path:
        self.config.workspace_path.mkdir(parents=True, exist_ok=True)
        job_root = Path(
            tempfile.mkdtemp(
                prefix=f"issue-{issue.number}-", dir=self.config.workspace_path
            )
        )
        repository_path = job_root / "repository"
        self._git(
            [
                "clone",
                "--no-tags",
                "--single-branch",
                "--branch",
                self.config.base_branch,
                f"https://github.com/{self.config.repository}.git",
                str(repository_path),
            ],
            cwd=job_root,
            timeout=300,
        )
        self._git(["config", "core.fileMode", "false"], cwd=repository_path)
        self._git(["checkout", "-b", branch], cwd=repository_path)
        return repository_path

    def _run_codex(
        self,
        issue: Issue,
        workspace: Path,
        base_sha: str,
        branch: str,
        progress_callback: Callable[[JobState], None] | None,
    ) -> dict[str, object]:
        if self.job_client is None:
            raise RuntimeError("Codex runner queue is not configured")
        workspace_rel = (
            workspace.resolve()
            .relative_to(self.config.workspace_path.resolve())
            .as_posix()
        )
        request = RunnerRequest(
            job_id=new_job_id(),
            repository=self.config.repository,
            issue_number=issue.number,
            issue_title=issue.title,
            issue_body=issue.body,
            issue_url=issue.url,
            issue_author=issue.author,
            issue_labels=tuple(sorted(issue.labels)),
            approved_by=self.state.get(issue.number).approved_by or "unknown",
            base_sha=base_sha,
            branch=branch,
            workspace_rel=workspace_rel,
            timeout_seconds=self.config.job_timeout_seconds,
        )
        self._report_progress(
            issue.number,
            JobPhase.QUEUED,
            progress_callback,
            job_id=request.job_id,
        )
        response = self.job_client.submit_and_wait(
            request,
            timeout_seconds=self.config.job_timeout_seconds + 60,
            progress_callback=lambda progress: self._report_runner_progress(
                issue.number,
                progress,
                progress_callback,
            ),
        )
        return {
            "status": response.status.value,
            "summary": response.summary,
            "tests": list(response.tests),
            "docs": list(response.docs),
            "risks": list(response.risks),
        }

    def _report_runner_progress(
        self,
        issue_number: int,
        progress: RunnerProgress,
        callback: Callable[[JobState], None] | None,
    ) -> None:
        phases = {
            RunnerPhase.CLAIMED: JobPhase.RUNNER_CLAIMED,
            RunnerPhase.CODEX_RUNNING: JobPhase.CODEX_RUNNING,
            RunnerPhase.RESULT_READY: JobPhase.RESULT_READY,
        }
        self._report_progress(
            issue_number,
            phases[progress.phase],
            callback,
            job_id=progress.job_id,
            runner_updated_at=progress.updated_at,
        )

    def _report_progress(
        self,
        issue_number: int,
        phase: JobPhase,
        callback: Callable[[JobState], None] | None,
        *,
        job_id: str | None = None,
        runner_updated_at: str | None = None,
    ) -> None:
        state = self.state.update_progress(
            issue_number,
            phase,
            job_id=job_id,
            runner_updated_at=runner_updated_at,
        )
        if callback is not None and state is not None:
            callback(state)

    def _changed_paths(self, workspace: Path, base_sha: str) -> list[str]:
        committed = self._git(
            ["diff", "--no-ext-diff", "--name-only", f"{base_sha}...HEAD"],
            cwd=workspace,
        ).stdout.splitlines()
        unstaged = self._git(
            ["diff", "--no-ext-diff", "--name-only"], cwd=workspace
        ).stdout.splitlines()
        staged = self._git(
            ["diff", "--no-ext-diff", "--cached", "--name-only"], cwd=workspace
        ).stdout.splitlines()
        untracked = self._git(
            ["ls-files", "--others", "--exclude-standard"], cwd=workspace
        ).stdout.splitlines()
        return sorted(set(committed + unstaged + staged + untracked))

    def _protected_changes(self, paths: list[str]) -> list[str]:
        return [
            path
            for path in paths
            if any(
                path == protected.rstrip("/")
                or path.startswith(protected.rstrip("/") + "/")
                for protected in self.config.protected_paths
            )
        ]

    def _commit_remaining_changes(self, issue: Issue, workspace: Path) -> None:
        status = self._git(["status", "--porcelain=v1"], cwd=workspace).stdout.strip()
        if status:
            self._git(["add", "--all"], cwd=workspace)
            self._git(
                [
                    "commit",
                    "-m",
                    f"feat: implement issue #{issue.number}",
                    "-m",
                    f"Refs #{issue.number}",
                ],
                cwd=workspace,
            )

    def _verify_branch(self, workspace: Path, branch: str, base_sha: str) -> None:
        current = self._git(["branch", "--show-current"], cwd=workspace).stdout.strip()
        if current != branch:
            raise RuntimeError(f"unexpected branch after Codex run: {current}")
        dirty = self._git(["status", "--porcelain=v1"], cwd=workspace).stdout.strip()
        if dirty:
            raise RuntimeError("worktree is dirty after commit")
        commits = self._git(
            ["rev-list", "--count", f"{base_sha}..HEAD"],
            cwd=workspace,
        ).stdout.strip()
        if int(commits) < 1:
            raise RuntimeError("branch has no commits")
        ancestor = self._git(
            ["merge-base", "--is-ancestor", base_sha, "HEAD"],
            cwd=workspace,
            check=False,
        )
        if ancestor.returncode != 0:
            raise RuntimeError("branch no longer descends from the approved base SHA")

    def _restore_repository_boundary(
        self,
        workspace: Path,
        branch: str,
        base_sha: str,
    ) -> None:
        workspace_root = self.config.workspace_path.resolve()
        if workspace.is_symlink() or not workspace.resolve().is_relative_to(
            workspace_root
        ):
            raise RuntimeError("runner replaced the approved workspace path")
        git_directory = workspace / ".git"
        if git_directory.is_symlink() or not git_directory.is_dir():
            raise RuntimeError("runner replaced the Git metadata directory")
        if any(path.is_symlink() for path in git_directory.rglob("*")):
            raise RuntimeError("runner created a symlink inside Git metadata")
        hooks = git_directory / "hooks"
        if hooks.exists() and any(
            path.is_file() and not path.name.endswith(".sample")
            for path in hooks.iterdir()
        ):
            raise RuntimeError("runner created an executable Git hook")

        expected_remote = f"https://github.com/{self.config.repository}.git"
        (git_directory / "config").write_text(
            "[core]\n"
            "\trepositoryformatversion = 0\n"
            "\tfilemode = false\n"
            "\tbare = false\n"
            "\tlogallrefupdates = true\n"
            "\thooksPath = /dev/null\n"
            '[remote "origin"]\n'
            f"\turl = {expected_remote}\n"
            f"\tfetch = +refs/heads/{self.config.base_branch}:"
            f"refs/remotes/origin/{self.config.base_branch}\n",
            encoding="utf-8",
        )
        self._git(["cat-file", "-e", f"{base_sha}^{{commit}}"], cwd=workspace)
        current = self._git(["branch", "--show-current"], cwd=workspace).stdout.strip()
        if current != branch:
            raise RuntimeError("runner changed the approved branch")

    def _secret_leaks(self, workspace: Path, changed_paths: list[str]) -> list[str]:
        known_secrets = _known_secret_values(self.config.secret_scan_paths)
        leaked: list[str] = []
        workspace_root = workspace.resolve()
        for relative in changed_paths:
            path = workspace / relative
            if (
                path.is_symlink()
                or Path(relative).is_absolute()
                or ".." in Path(relative).parts
            ):
                leaked.append(relative)
                continue
            try:
                resolved = path.resolve()
            except OSError:
                leaked.append(relative)
                continue
            if not resolved.is_relative_to(workspace_root):
                leaked.append(relative)
                continue
            if not path.is_file():
                continue
            try:
                if path.stat().st_size > 10 * 1024 * 1024:
                    continue
                contents = path.read_bytes()
            except OSError:
                continue
            if _TOKEN_PATTERN.search(contents) or any(
                secret in contents for secret in known_secrets
            ):
                leaked.append(relative)
        return leaked

    def _git(
        self,
        arguments: list[str],
        *,
        cwd: Path,
        timeout: int = 120,
        check: bool = True,
    ):
        return self.runner.run(
            [self.config.git_bin, *arguments],
            cwd=cwd,
            timeout=timeout,
            environment=minimal_environment(include_auth=True),
            check=check,
        )

    def _set_running_label(self, issue_number: int) -> None:
        if self.config.dry_run:
            return
        self._try_remove_labels(issue_number, _TERMINAL_LABELS)
        self.github.add_labels(issue_number, ["codex-running"])

    def _set_terminal_label(self, issue_number: int, label: str) -> None:
        if self.config.dry_run:
            return
        self._try_remove_labels(issue_number, ("codex-running", *_TERMINAL_LABELS))
        self.github.add_labels(issue_number, [label])

    def _try_set_terminal_label(self, issue_number: int, label: str) -> None:
        try:
            self._set_terminal_label(issue_number, label)
        except (CommandError, CommandTimeout):
            pass

    def _try_remove_labels(self, issue_number: int, labels: tuple[str, ...]) -> None:
        try:
            self.github.remove_labels(issue_number, labels)
        except (CommandError, CommandTimeout):
            pass

    def _blocked(
        self,
        issue_number: int,
        summary: str,
        *,
        workspace: Path | None = None,
        branch: str | None = None,
        details: dict[str, object] | None = None,
    ) -> JobResult:
        self.state.finish(issue_number, "blocked", error=summary)
        self._try_set_terminal_label(issue_number, "codex-blocked")
        issue = Issue(issue_number, "", "", "", "")
        return _job_result(
            JobStatus.BLOCKED,
            issue,
            summary,
            workspace,
            branch,
            details or {},
        )


def _branch_name(issue: Issue) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", issue.title.lower()).strip("-")
    slug = slug[:48].rstrip("-") or "change"
    return f"codex/issue-{issue.number}-{slug}"


def _job_result(
    status: JobStatus,
    issue: Issue,
    summary: str,
    workspace: Path | None,
    branch: str | None,
    details: dict[str, object],
    pull_request: PullRequest | None = None,
) -> JobResult:
    return JobResult(
        status,
        issue.number,
        summary,
        workspace=str(workspace) if workspace else None,
        branch=branch,
        pull_request=pull_request,
        tests=tuple(str(item) for item in details.get("tests", [])),
        docs=tuple(str(item) for item in details.get("docs", [])),
        risks=tuple(str(item) for item in details.get("risks", [])),
    )


def _known_secret_values(paths: tuple[Path, ...]) -> set[bytes]:
    secrets: set[bytes] = set()
    for name, value in os.environ.items():
        if (
            any(part in name.upper() for part in ("TOKEN", "SECRET", "KEY"))
            and len(value) >= 16
        ):
            secrets.add(value.encode())
    for root in paths:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            try:
                if path.stat().st_size > 2 * 1024 * 1024:
                    continue
                contents = path.read_bytes()
            except OSError:
                continue
            secrets.update(_TOKEN_PATTERN.findall(contents))
            if path.suffix.lower() == ".json":
                try:
                    _collect_json_secrets(json.loads(contents), secrets)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    pass
    return {value for value in secrets if len(value) >= 16}


def _collect_json_secrets(
    value: object,
    secrets: set[bytes],
    key: str = "",
) -> None:
    if isinstance(value, dict):
        for child_key, child_value in value.items():
            _collect_json_secrets(child_value, secrets, str(child_key))
        return
    if isinstance(value, list):
        for child in value:
            _collect_json_secrets(child, secrets, key)
        return
    if (
        isinstance(value, str)
        and len(value) >= 16
        and any(part in key.lower() for part in _SECRET_KEY_PARTS)
    ):
        secrets.add(value.encode())
