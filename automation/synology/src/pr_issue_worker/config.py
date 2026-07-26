from __future__ import annotations

import os
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

_REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_LABEL_PATTERN = re.compile(r"^[^\x00-\x1f,]+$")


class ConfigError(ValueError):
    pass


@dataclass(frozen=True)
class Config:
    repository: str
    base_branch: str
    ready_label: str
    state_path: Path
    workspace_path: Path
    runner_queue_path: Path
    runner_heartbeat_max_age_seconds: int
    job_timeout_seconds: int
    ci_timeout_seconds: int
    lease_seconds: int
    codex_bin: str
    gh_bin: str
    git_bin: str
    dry_run: bool
    protected_paths: tuple[str, ...]

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Config:
        values = os.environ if env is None else env
        repository = _required(values, "GITHUB_REPOSITORY")
        if not _REPOSITORY_PATTERN.fullmatch(repository):
            raise ConfigError("GITHUB_REPOSITORY must use the owner/repository form")

        base_branch = values.get("GITHUB_BASE_BRANCH", "main").strip()
        if not base_branch or base_branch.startswith("-") or ".." in base_branch:
            raise ConfigError("GITHUB_BASE_BRANCH is invalid")

        ready_label = values.get("GITHUB_READY_LABEL", "codex-ready").strip()
        if not ready_label or not _LABEL_PATTERN.fullmatch(ready_label):
            raise ConfigError("GITHUB_READY_LABEL is invalid")

        data_path = Path(values.get("DATA_PATH", "./data")).expanduser()
        workspace_path = Path(
            values.get("WORKSPACE_PATH", str(data_path / "workspaces"))
        ).expanduser()
        protected = tuple(
            item.strip()
            for item in values.get(
                "PROTECTED_PATHS",
                ".github/workflows/,.agents/,.harness/,SECURITY.md",
            ).split(",")
            if item.strip()
        )
        job_timeout_seconds = _positive_int(values, "JOB_TIMEOUT_SECONDS", default=3600)
        lease_seconds = _positive_int(values, "LEASE_SECONDS", default=3900)
        if lease_seconds <= job_timeout_seconds:
            raise ConfigError("LEASE_SECONDS must be greater than JOB_TIMEOUT_SECONDS")

        return cls(
            repository=repository,
            base_branch=base_branch,
            ready_label=ready_label,
            state_path=Path(
                values.get("STATE_PATH", str(data_path / "state.sqlite3"))
            ).expanduser(),
            workspace_path=workspace_path,
            runner_queue_path=Path(
                values.get("RUNNER_QUEUE_PATH", str(data_path / "runner-queue"))
            ).expanduser(),
            runner_heartbeat_max_age_seconds=_positive_int(
                values, "RUNNER_HEARTBEAT_MAX_AGE_SECONDS", default=30
            ),
            job_timeout_seconds=job_timeout_seconds,
            ci_timeout_seconds=_positive_int(
                values, "CI_TIMEOUT_SECONDS", default=1800
            ),
            lease_seconds=lease_seconds,
            codex_bin=values.get("CODEX_BIN", "codex"),
            gh_bin=values.get("GH_BIN", "gh"),
            git_bin=values.get("GIT_BIN", "git"),
            dry_run=_boolean(values.get("DRY_RUN", "false"), "DRY_RUN"),
            protected_paths=protected,
        )


def _required(values: Mapping[str, str], name: str) -> str:
    value = values.get(name, "").strip()
    if not value:
        raise ConfigError(f"{name} is required")
    return value


def _positive_int(values: Mapping[str, str], name: str, *, default: int) -> int:
    raw = values.get(name, str(default))
    try:
        result = int(raw)
    except ValueError as error:
        raise ConfigError(f"{name} must be an integer") from error
    if result <= 0:
        raise ConfigError(f"{name} must be positive")
    return result


def _boolean(raw: str, name: str) -> bool:
    normalized = raw.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ConfigError(f"{name} must be a boolean")
