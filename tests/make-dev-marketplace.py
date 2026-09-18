from __future__ import annotations

import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / ".tmp" / "dev-marketplace"
PLUGIN_SOURCE = ROOT / "plugins" / "overseer"
PLUGIN_COPY = OUTPUT / "plugins" / "overseer"


def write(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    shutil.copytree(PLUGIN_SOURCE, PLUGIN_COPY)
    write(
        OUTPUT / ".claude-plugin" / "marketplace.json",
        {
            "name": "overseer-dev",
            "description": "Disposable local Overseer development marketplace.",
            "owner": {"name": "local"},
            "plugins": [{"name": "overseer", "source": "./plugins/overseer"}],
        },
    )
    write(
        OUTPUT / ".agents" / "plugins" / "marketplace.json",
        {
            "name": "overseer-dev",
            "plugins": [
                {
                    "name": "overseer",
                    "source": {"source": "local", "path": "./plugins/overseer"},
                    "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
                }
            ],
        },
    )
    print(OUTPUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
