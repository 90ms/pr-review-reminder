from __future__ import annotations

import json
from collections.abc import Iterable
from pathlib import Path

from .models import Issue, PullRequest
from .process import CommandRunner, minimal_environment


class GitHubClient:
    def __init__(
        self,
        repository: str,
        runner: CommandRunner,
        *,
        gh_bin: str = "gh",
    ):
        self.repository = repository
        self.runner = runner
        self.gh_bin = gh_bin

    def list_issues(self, label: str) -> list[Issue]:
        result = self._run(
            [
                "issue",
                "list",
                "--state",
                "open",
                "--label",
                label,
                "--limit",
                "100",
                "--json",
                "number,title,body,url,author,labels",
            ]
        )
        return [_parse_issue(item) for item in json.loads(result)]

    def get_issue(self, issue_number: int) -> Issue:
        result = self._run(
            [
                "issue",
                "view",
                str(issue_number),
                "--json",
                "number,title,body,url,author,labels,state",
            ]
        )
        value = json.loads(result)
        if value.get("state") != "OPEN":
            raise ValueError(f"issue #{issue_number} is not open")
        return _parse_issue(value)

    def find_existing_pr(
        self, issue_number: int, branch_prefix: str
    ) -> PullRequest | None:
        result = self._run(
            [
                "pr",
                "list",
                "--state",
                "open",
                "--limit",
                "100",
                "--json",
                "number,url,headRefName,body",
            ]
        )
        issue_markers = (
            f"#{issue_number}",
            f"/issues/{issue_number}",
        )
        for value in json.loads(result):
            head_ref = value.get("headRefName", "")
            body = value.get("body") or ""
            if head_ref.startswith(branch_prefix) or any(
                marker in body for marker in issue_markers
            ):
                return PullRequest(
                    number=int(value["number"]),
                    url=value["url"],
                    head_ref=head_ref,
                )
        return None

    def add_labels(self, issue_number: int, labels: Iterable[str]) -> None:
        command = ["issue", "edit", str(issue_number)]
        for label in labels:
            command.extend(["--add-label", label])
        self._run(command)

    def remove_labels(self, issue_number: int, labels: Iterable[str]) -> None:
        command = ["issue", "edit", str(issue_number)]
        for label in labels:
            command.extend(["--remove-label", label])
        self._run(command)

    def create_draft_pr(
        self,
        *,
        issue: Issue,
        base_branch: str,
        head_branch: str,
        summary: str,
        cwd: Path,
    ) -> PullRequest:
        body = (
            f"Closes #{issue.number}\n\n"
            "## Summary\n\n"
            f"{summary}\n\n"
            "## Validation\n\n"
            "- Local validation was performed by the approved NAS worker.\n"
            "- macOS build and tests are delegated to GitHub Actions.\n\n"
            "_Created after explicit approval in Slack._"
        )
        result = self._run(
            [
                "pr",
                "create",
                "--draft",
                "--base",
                base_branch,
                "--head",
                head_branch,
                "--title",
                issue.title,
                "--body",
                body,
            ],
            cwd=cwd,
        ).strip()
        number_result = self._run(
            ["pr", "view", result, "--json", "number,url,headRefName"],
            cwd=cwd,
        )
        value = json.loads(number_result)
        return PullRequest(
            number=int(value["number"]),
            url=value["url"],
            head_ref=value["headRefName"],
        )

    def _run(self, arguments: list[str], cwd: Path | None = None) -> str:
        result = self.runner.run(
            [self.gh_bin, *arguments, "--repo", self.repository],
            cwd=cwd,
            environment=minimal_environment(include_auth=True),
        )
        return result.stdout


def _parse_issue(value: dict[str, object]) -> Issue:
    author_value = value.get("author") or {}
    labels_value = value.get("labels") or []
    return Issue(
        number=int(value["number"]),
        title=str(value["title"]),
        body=str(value.get("body") or ""),
        url=str(value["url"]),
        author=str(author_value.get("login", "unknown")),  # type: ignore[union-attr]
        labels=frozenset(
            str(label["name"])
            for label in labels_value  # type: ignore[index]
        ),
    )
