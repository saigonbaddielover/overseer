from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

PLUGIN_ROOT = Path("plugins/overseer")
MANIFESTS = {
    Path(".claude-plugin/plugin.json"),
    Path(".codex-plugin/plugin.json"),
}


def git_bytes(ref: str, path: Path) -> bytes:
    return subprocess.check_output(["git", "show", f"{ref}:{PLUGIN_ROOT / path}"])


def normalized(path: Path, data: bytes) -> bytes:
    if path not in MANIFESTS:
        return data
    value = json.loads(data)
    value.pop("version", None)
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def tree_digest(ref: str | None) -> str:
    digest = hashlib.sha256()
    if ref is None:
        paths = sorted(path.relative_to(PLUGIN_ROOT) for path in PLUGIN_ROOT.rglob("*") if path.is_file())
        loader = lambda path: (PLUGIN_ROOT / path).read_bytes()
    else:
        output = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", ref, str(PLUGIN_ROOT)], text=True)
        paths = sorted(Path(line).relative_to(PLUGIN_ROOT) for line in output.splitlines() if line)
        loader = lambda path: git_bytes(ref, path)
    for path in paths:
        digest.update(path.as_posix().encode() + b"\0")
        digest.update(normalized(path, loader(path)) + b"\0")
    return digest.hexdigest()


def version(ref: str | None) -> str:
    path = Path(".claude-plugin/plugin.json")
    data = (PLUGIN_ROOT / path).read_bytes() if ref is None else git_bytes(ref, path)
    return json.loads(data)["version"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-ref", required=True)
    args = parser.parse_args()
    base_version = version(args.base_ref)
    current_version = version(None)
    artifact_changed = tree_digest(args.base_ref) != tree_digest(None)
    version_changed = base_version != current_version
    if artifact_changed != version_changed:
        state = "changed" if artifact_changed else "unchanged"
        raise SystemExit(f"Overseer artifact is {state}, but version changed={version_changed}: {base_version} -> {current_version}")
    print(f"Overseer release isolation OK: artifact_changed={artifact_changed} version_changed={version_changed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
