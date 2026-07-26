from __future__ import annotations

import unittest
from pathlib import Path


class ComposeConfigurationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.compose_path = Path(__file__).resolve().parents[1] / "compose.yaml"
        self.contents = self.compose_path.read_text(encoding="utf-8")

    def test_github_config_uses_container_mount_path(self) -> None:
        self.assertIn(
            "GH_CONFIG_DIR: /home/worker/.config/gh",
            self.contents,
        )
        self.assertIn(
            "${GH_CONFIG_DIR:?Set GH_CONFIG_DIR}:/home/worker/.config/gh:ro",
            self.contents,
        )

    def test_runner_does_not_receive_controller_secrets_or_docker_socket(self) -> None:
        runner = self.contents.split("  codex-runner:", 1)[1].split(
            "  codex-egress:", 1
        )[0]

        self.assertNotIn("env_file:", runner)
        self.assertNotIn("GH_CONFIG_DIR", runner)
        self.assertNotIn("SLACK_", runner)
        self.assertNotIn("/var/run/docker.sock", self.contents)
        self.assertNotIn("privileged:", self.contents)
        self.assertNotIn("SYS_ADMIN", self.contents)
        self.assertNotIn("seccomp=unconfined", self.contents)

    def test_default_compose_avoids_unsupported_synology_cgroup_limits(self) -> None:
        self.assertNotIn("pids_limit:", self.contents)
        self.assertNotIn("mem_limit:", self.contents)
        self.assertNotIn("cpus:", self.contents)

    def test_runner_uses_internal_network_and_allowlisted_proxy(self) -> None:
        proxy_path = Path(__file__).resolve().parents[1] / "proxy" / "squid.conf"
        proxy = proxy_path.read_text(encoding="utf-8")

        self.assertIn("runner:\n    internal: true", self.contents)
        self.assertIn("HTTPS_PROXY: http://codex-egress:3128", self.contents)
        self.assertIn(".openai.com .chatgpt.com", proxy)
        self.assertIn("http_access deny all", proxy)


if __name__ == "__main__":
    unittest.main()
