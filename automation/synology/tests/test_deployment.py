from __future__ import annotations

import unittest
from pathlib import Path


class ComposeConfigurationTests(unittest.TestCase):
    def test_github_config_uses_container_mount_path(self) -> None:
        compose_path = Path(__file__).resolve().parents[1] / "compose.yaml"
        contents = compose_path.read_text(encoding="utf-8")

        self.assertIn(
            "GH_CONFIG_DIR: /home/worker/.config/gh",
            contents,
        )
        self.assertIn(
            "${GH_CONFIG_DIR:?Set GH_CONFIG_DIR}:/home/worker/.config/gh:ro",
            contents,
        )


if __name__ == "__main__":
    unittest.main()
