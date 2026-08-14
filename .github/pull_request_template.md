## What

<!-- What does this change, and why? -->

## Checklist

- [ ] `bash -n` and `shellcheck -S warning` pass on any changed scripts
- [ ] Claude and Codex plugin validators pass for `./plugins/overseer`
- [ ] For a releasable change: bumped `version` in both plugin manifests and the Claude marketplace entry (they must agree)
- [ ] Updated `CHANGELOG.md` (under `Unreleased`)
- [ ] `bash tests/run.sh` passes
- [ ] `overseer doctor` still passes on a Linux + tmux box
- [ ] **If `windows.sh` or any `win-*.ps1` changed:** ran `bash tests/win-payloads.sh` **and** the
      live Windows checklist in [CONTRIBUTING.md](../CONTRIBUTING.md#windows-live-verification) — CI
      cannot see that path
