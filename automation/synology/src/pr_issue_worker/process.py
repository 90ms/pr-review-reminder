from __future__ import annotations

import os
import signal
import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path


class CommandError(RuntimeError):
    def __init__(self, command: Sequence[str], returncode: int, stderr: str):
        executable = Path(command[0]).name if command else "command"
        detail = _last_nonempty_line(stderr) or f"exit code {returncode}"
        super().__init__(f"{executable} failed: {detail}")
        self.command = tuple(command)
        self.returncode = returncode
        self.stderr = stderr


class CommandTimeout(RuntimeError):
    pass


@dataclass(frozen=True)
class CommandResult:
    stdout: str
    stderr: str
    returncode: int


class CommandRunner:
    def run(
        self,
        command: Sequence[str],
        *,
        cwd: Path | None = None,
        input_text: str | None = None,
        timeout: int = 60,
        environment: Mapping[str, str] | None = None,
        check: bool = True,
    ) -> CommandResult:
        process = subprocess.Popen(
            list(command),
            cwd=cwd,
            env=dict(environment) if environment is not None else None,
            stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(input_text, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
            raise CommandTimeout(
                f"{Path(command[0]).name} exceeded {timeout} seconds"
            ) from error

        result = CommandResult(stdout, stderr, process.returncode)
        if check and process.returncode != 0:
            raise CommandError(command, process.returncode, stderr)
        return result


def minimal_environment(
    source: Mapping[str, str] | None = None,
    *,
    include_auth: bool = False,
    include_proxy: bool = False,
) -> dict[str, str]:
    values = os.environ if source is None else source
    allowed = {
        "PATH",
        "HOME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "TERM",
        "TMPDIR",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "CODEX_HOME",
    }
    if include_auth:
        allowed.update(
            {
                "GH_TOKEN",
                "GITHUB_TOKEN",
                "CODEX_ACCESS_TOKEN",
            }
        )
    if include_proxy:
        allowed.update(
            {
                "HTTP_PROXY",
                "HTTPS_PROXY",
                "NO_PROXY",
                "http_proxy",
                "https_proxy",
                "no_proxy",
            }
        )
    return {key: value for key, value in values.items() if key in allowed}


def _last_nonempty_line(value: str) -> str:
    lines = [line.strip() for line in value.splitlines() if line.strip()]
    return lines[-1][:400] if lines else ""
