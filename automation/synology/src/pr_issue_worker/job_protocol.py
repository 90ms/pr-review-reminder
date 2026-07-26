from __future__ import annotations

import json
import os
import re
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath
from typing import Any

from .models import JobStatus

SCHEMA_VERSION = 1
_JOB_ID_PATTERN = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
)
_REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")


class JobProtocolError(ValueError):
    pass


@dataclass(frozen=True)
class RunnerRequest:
    job_id: str
    repository: str
    issue_number: int
    issue_title: str
    issue_body: str
    issue_url: str
    issue_author: str
    issue_labels: tuple[str, ...]
    approved_by: str
    base_sha: str
    branch: str
    workspace_rel: str
    timeout_seconds: int
    schema_version: int = SCHEMA_VERSION

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> RunnerRequest:
        try:
            request = cls(
                job_id=str(value["job_id"]),
                repository=str(value["repository"]),
                issue_number=int(value["issue_number"]),
                issue_title=str(value["issue_title"]),
                issue_body=str(value["issue_body"]),
                issue_url=str(value["issue_url"]),
                issue_author=str(value["issue_author"]),
                issue_labels=tuple(str(item) for item in value["issue_labels"]),
                approved_by=str(value["approved_by"]),
                base_sha=str(value["base_sha"]),
                branch=str(value["branch"]),
                workspace_rel=str(value["workspace_rel"]),
                timeout_seconds=int(value["timeout_seconds"]),
                schema_version=int(value["schema_version"]),
            )
        except (KeyError, TypeError, ValueError) as error:
            raise JobProtocolError(f"invalid runner request: {error}") from error
        request.validate()
        return request

    @classmethod
    def read(cls, path: Path) -> RunnerRequest:
        return cls.from_dict(_read_object(path))

    def validate(self) -> None:
        if self.schema_version != SCHEMA_VERSION:
            raise JobProtocolError(
                f"unsupported job schema version: {self.schema_version}"
            )
        if not _JOB_ID_PATTERN.fullmatch(self.job_id):
            raise JobProtocolError("job_id must be a lowercase UUID")
        if not _REPOSITORY_PATTERN.fullmatch(self.repository):
            raise JobProtocolError("repository must use owner/repository")
        if self.issue_number <= 0:
            raise JobProtocolError("issue_number must be positive")
        if not self.issue_title.strip():
            raise JobProtocolError("issue_title must not be empty")
        if not self.approved_by.strip():
            raise JobProtocolError("approved_by must not be empty")
        if not _SHA_PATTERN.fullmatch(self.base_sha):
            raise JobProtocolError("base_sha must be a lowercase full SHA")
        if (
            not self.branch.startswith(f"codex/issue-{self.issue_number}-")
            or self.branch.startswith("-")
            or ".." in self.branch
        ):
            raise JobProtocolError("branch does not match the approved issue")
        _validate_relative_path(self.workspace_rel)
        if self.timeout_seconds <= 0:
            raise JobProtocolError("timeout_seconds must be positive")

    def write(self, path: Path) -> None:
        self.validate()
        _write_object_atomic(path, asdict(self))


@dataclass(frozen=True)
class RunnerResponse:
    job_id: str
    status: JobStatus
    summary: str
    tests: tuple[str, ...] = ()
    docs: tuple[str, ...] = ()
    risks: tuple[str, ...] = ()
    schema_version: int = SCHEMA_VERSION

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> RunnerResponse:
        try:
            response = cls(
                job_id=str(value["job_id"]),
                status=JobStatus(str(value["status"])),
                summary=str(value["summary"]),
                tests=tuple(str(item) for item in value.get("tests", [])),
                docs=tuple(str(item) for item in value.get("docs", [])),
                risks=tuple(str(item) for item in value.get("risks", [])),
                schema_version=int(value["schema_version"]),
            )
        except (KeyError, TypeError, ValueError) as error:
            raise JobProtocolError(f"invalid runner response: {error}") from error
        response.validate()
        return response

    @classmethod
    def read(cls, path: Path) -> RunnerResponse:
        return cls.from_dict(_read_object(path))

    def validate(self) -> None:
        if self.schema_version != SCHEMA_VERSION:
            raise JobProtocolError(
                f"unsupported job schema version: {self.schema_version}"
            )
        if not _JOB_ID_PATTERN.fullmatch(self.job_id):
            raise JobProtocolError("job_id must be a lowercase UUID")
        if not self.summary.strip():
            raise JobProtocolError("summary must not be empty")

    def write(self, path: Path) -> None:
        self.validate()
        value = asdict(self)
        value["status"] = self.status.value
        _write_object_atomic(path, value)


def new_job_id() -> str:
    return str(uuid.uuid4())


def resolve_workspace(root: Path, relative: str) -> Path:
    _validate_relative_path(relative)
    candidate = root.joinpath(*PurePosixPath(relative).parts)
    resolved_root = root.resolve()
    resolved_candidate = candidate.resolve()
    if not resolved_candidate.is_relative_to(resolved_root):
        raise JobProtocolError("workspace escapes the configured root")
    return resolved_candidate


def _validate_relative_path(value: str) -> None:
    path = PurePosixPath(value)
    if (
        not value
        or path.is_absolute()
        or value != path.as_posix()
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise JobProtocolError("workspace_rel must be a normalized relative path")


def _read_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise JobProtocolError(f"could not read {path.name}: {error}") from error
    if not isinstance(value, dict):
        raise JobProtocolError(f"{path.name} must contain a JSON object")
    return value


def _write_object_atomic(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        temporary.write_text(
            json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
