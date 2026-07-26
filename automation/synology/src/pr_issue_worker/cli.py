from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict

from .config import Config, ConfigError
from .github import GitHubClient
from .process import CommandError, CommandRunner, CommandTimeout
from .state import StateStore
from .worker import IssueWorker


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run approved GitHub issue automation")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("doctor", help="validate configuration and CLI access")
    subparsers.add_parser(
        "serve", help="run Slack Socket Mode and the scheduled scanner"
    )
    subparsers.add_parser("notify", help="send approval messages for ready issues once")
    scan_parser = subparsers.add_parser(
        "scan", help="list ready issues without changing GitHub"
    )
    scan_parser.add_argument("--json", action="store_true")
    run_parser = subparsers.add_parser(
        "run", help="implement one explicitly approved issue"
    )
    run_parser.add_argument("--issue", type=int, required=True)
    run_parser.add_argument("--approved-by", required=True)
    arguments = parser.parse_args(argv)

    try:
        config = Config.from_env()
        runner = CommandRunner()
        state = StateStore(config.state_path)
        state.initialize()
        github = GitHubClient(config.repository, runner, gh_bin=config.gh_bin)
        worker = IssueWorker(config, state, github, runner)

        if arguments.command == "doctor":
            return _doctor(config, runner)
        if arguments.command in {"serve", "notify"}:
            from .slack_app import (
                SlackSettings,
                notify_once,
                run_socket_service,
            )

            settings = SlackSettings.from_env()
            if arguments.command == "serve":
                run_socket_service(
                    settings=settings,
                    github=github,
                    state=state,
                    worker=worker,
                    ci_timeout_seconds=config.ci_timeout_seconds,
                )
                return 0
            count = notify_once(
                settings=settings,
                github=github,
                state=state,
                worker=worker,
                ci_timeout_seconds=config.ci_timeout_seconds,
            )
            print(f"sent {count} approval message(s)")
            return 0
        if arguments.command == "scan":
            issues = github.list_issues(config.ready_label)
            if arguments.json:
                print(json.dumps([asdict(issue) for issue in issues], default=list))
            else:
                for issue in issues:
                    print(f"#{issue.number}\t{issue.title}\t{issue.url}")
            return 0

        result = worker.run(arguments.issue, arguments.approved_by)
        print(json.dumps(asdict(result), default=str))
        return 0 if result.status == "completed" else 1
    except (ConfigError, CommandError, CommandTimeout) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


def _doctor(config: Config, runner: CommandRunner) -> int:
    environment = None
    checks = (
        ([config.gh_bin, "auth", "status"], "GitHub CLI"),
        ([config.codex_bin, "--version"], "Codex CLI"),
        ([config.git_bin, "--version"], "Git"),
    )
    for command, label in checks:
        runner.run(command, environment=environment)
        print(f"ok: {label}")
    config.state_path.parent.mkdir(parents=True, exist_ok=True)
    config.workspace_path.mkdir(parents=True, exist_ok=True)
    print(f"ok: state path {config.state_path}")
    print(f"ok: workspace path {config.workspace_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
