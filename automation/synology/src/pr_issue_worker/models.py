from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum


class JobStatus(StrEnum):
    COMPLETED = "completed"
    BLOCKED = "blocked"
    FAILED = "failed"


@dataclass(frozen=True)
class Issue:
    number: int
    title: str
    body: str
    url: str
    author: str
    labels: frozenset[str] = field(default_factory=frozenset)


@dataclass(frozen=True)
class PullRequest:
    number: int
    url: str
    head_ref: str


@dataclass(frozen=True)
class JobResult:
    status: JobStatus
    issue_number: int
    summary: str
    workspace: str | None = None
    branch: str | None = None
    pull_request: PullRequest | None = None
    tests: tuple[str, ...] = ()
    docs: tuple[str, ...] = ()
    risks: tuple[str, ...] = ()
