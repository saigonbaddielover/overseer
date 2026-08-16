# Contributing

## Layout

- `plugins/overseer/` — the shared Claude Code/Codex plugin: both manifests,
  `skills/overseer/` (the skill + `scripts/`), and Claude Code `hooks/`.
- `skills/overseer/scripts/overseer` — the entry point (config, `main`, help); it sources `scripts/lib/`:
  `discovery.sh` (pane → harness → transcript path), `transcript.sh` (Claude + Codex readers, turn-done),
  `tui.sh` (screen read + keyboard/paste delivery), `commands.sh` (the local + ssh `cmd_*` surface),
  `windows.sh` (the `win*` surface: broker payload transfer, pipe client, remote turn wait).
- `skills/overseer/scripts/overseer.ps1` — the native Windows controller. It drives local visible
  brokers without SSH and carries PowerShell equivalents of the transcript/turn orchestration seam.
- `skills/overseer/scripts/win-*.ps1` — the PowerShell payloads copied to a Windows host on demand;
  see [docs/WINDOWS.md](docs/WINDOWS.md) for the mechanism and its non-obvious constraints.
- `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json` — the Claude Code and Codex
  `sgbl` marketplaces that list the same plugin directory.

## Test locally (no publish)

Add this repo as a **local** marketplace and install from your working tree:

```
/plugin marketplace add ./sgbl-overseer --scope local
/plugin install overseer@sgbl --scope local
```

After editing, refresh with `/plugin marketplace update sgbl` then `/plugin update overseer`, then
`/reload-plugins` to apply it in the current session — no restart. (A plain `SKILL.md` text edit is
picked up automatically or with `/reload-skills`; changes under `hooks/` need `/reload-plugins`.)
Remove with `/plugin uninstall overseer@sgbl --scope local` and
`/plugin marketplace remove sgbl --scope local`.

For Codex:

```
codex plugin marketplace add .
codex plugin add overseer@sgbl
```

Open a new thread after install or reinstall so Codex loads the skill. Remove it with
`codex plugin remove overseer@sgbl` and `codex plugin marketplace remove sgbl`.

## Validate before you push

```
claude plugin validate --strict ./plugins/overseer   # the plugin
claude plugin validate --strict .             # the marketplace
python3 "${CODEX_HOME:-$HOME/.codex}/skills/.system/plugin-creator/scripts/validate_plugin.py" plugins/overseer
python3 "${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py" plugins/overseer/skills/overseer
bash -n plugins/overseer/skills/overseer/scripts/overseer plugins/overseer/skills/overseer/scripts/lib/*.sh
shellcheck -x -S warning plugins/overseer/skills/overseer/scripts/overseer   # -x follows the sourced lib/*.sh
shellcheck -S warning plugins/overseer/hooks/turn-done.sh
bash tests/run.sh                                  # parser fixture tests (no tmux needed)
bash tests/win-flow.sh                             # win* orchestration, mocked ssh
bash tests/win-payloads.sh                         # the same two .ps1 files CI's windows job runs (needs pwsh)
plugins/overseer/skills/overseer/scripts/overseer doctor --live   # runtime preflight + throwaway-pane round trip
pwsh plugins/overseer/skills/overseer/scripts/overseer.ps1 doctor --live  # native Windows broker round trip
```

## Tests

- **`tests/run.sh`** — asserts the pure transcript/screen parsers against fixtures in `tests/fixtures/`,
  for both harnesses. No tmux, no agent, fast. This is the drift tripwire; add a fixture + assertion
  whenever you touch a parser. It also unit-drives the command guards through stubbed `tmux` — the `sh`
  POSIX-shell gate and the `start`/`stop` name/child/existing-session refusals plus the self-kill guard
  (`_ok_session_name`, `_startgate`, `_stopgate`) — and asserts command-surface parity + the doc
  contracts, so a new command or a broken guard fails CI here.
- **`tests/fixtures/awaiting-*.txt`** — screen fixtures for the awaiting detector, which has **two**
  implementations (`_awaiting_text` in `scripts/lib/tui.sh`, `Test-Awaiting` in `scripts/overseer.ps1`).
  Both suites discover these fixtures by glob and derive the expected verdict from the name — a file
  named `awaiting-none*` must be rejected, any other `awaiting-*` must be detected — so **dropping a new
  screen recording into that directory asserts it against both parsers at once**, with no assertion to
  write and none to forget. Both are run with the permissive `❯›>` glyph set, since that is what the
  native controller and the remote-Windows path use; the Linux-strict `❯›` behaviour keeps its own
  explicit assertions in `tests/run.sh`.
- **`tests/stress.sh`** — exercises the live paths fixtures can't: multi-pane concurrency, per-pane lock
  serialization, large-rollout reader perf, mid-turn crash liveness, and the `start`/`stop` session
  lifecycle (create → drive via `sh` → destroy, plus `stop %N` killing one pane of a multi-pane session;
  a real-codex readiness check self-skips when `codex` isn't on `PATH`). Needs tmux; the checks above use
  throwaway *shell* panes, so no Claude/Codex is required. Set `OVERSEER_STRESS_CODEX_PANE=%N` to also
  assert the Codex `!`-refuse safety against a real Codex pane. Run it by hand when touching the
  delivery, lock, or reader paths. The reader-perf section (C) measures on an 18 MB rollout; run by
  hand it *asserts* against ceilings tunable via `OVERSEER_STRESS_PERF_LASTREPLY` /
  `OVERSEER_STRESS_PERF_TURNS`, but **CI sets `OVERSEER_STRESS_NO_PERF=1` so it only prints the timing
  and never gates** — a shared runner's numbers are too noisy to fail on honestly.
- **`tests/win-flow.sh`** — mocks the two remote chokepoints (`_win_client`, `_win_fetch`) and runs the
  real `win*` bash orchestration against a recorded call log: the mid-turn and scp-failure guards, the
  `pwsh`/dead-child/Codex-`!` refusals, box cleanup after a failed submit or unverified delivery, the
  `mtime:size` gating, and broker-target parsing. No ssh, no host, runs in CI.
- **`tests/win-payloads.sh`** — parses every shipped `win-*.ps1` with
  `System.Management.Automation.Language.Parser` and then runs **`tests/win-contracts.ps1`**. That file
  now **executes** the payloads' pure functions rather than grepping their source: it AST-extracts each
  one and calls it with real inputs — the transcript-path validator (`Test-TranscriptPath`) against the
  injection battery, broker-name validation (`Get-ConfigPath`) accept/reject, the snapshot frame reader
  (`Read-Frame`) on good/bad/truncated frames, the descriptor JSON round-trip (secret carries no
  transcript claim), and — on Windows only — the codex claim isolation through the split state file. A
  smaller set of labeled `src:` tripwires still greps source for the Windows-runtime constructs a unit
  test can't exercise (the pipe ACL, `FirstPipeInstance`, the anonymous client, the scheduled task, the
  ACL functions). **CI is the authority**: the `windows-latest` job runs `tests/win-parse.ps1` and
  `tests/win-contracts.ps1` natively under `pwsh`. `win-payloads.sh` just runs those same two scripts
  for you locally — it is a convenience, not the gate.

  **PowerShell runs on Linux**, so run it before pushing rather than waiting for CI — it has caught
  defects (an unterminated string, a `$line:` scope parse) that every other check passed:

  ```
  bash tests/win-payloads.sh                       # pwsh on PATH
  OVERSEER_PWSH=/path/to/pwsh bash tests/win-payloads.sh   # or point it at one
  ```

  Exit 1 means a payload failed, 2 means no PowerShell was found.

CI (`.github/workflows/validate.yml`) runs three jobs on every push to `main` and every pull request:

| job | runner | steps |
|---|---|---|
| **validate** | ubuntu | `jq empty` on marketplace, plugin, and hook JSON · plugin/marketplace version agreement · a CHANGELOG entry for a version bump (PRs only) · `bash -n` + shellcheck over the entry, `lib/*.sh`, the hook and every `tests/*.sh` · `tests/run.sh` · `tests/win-flow.sh` |
| **powershell** | windows | `tests/win-parse.ps1` · `tests/win-contracts.ps1`, both natively under `pwsh` |
| **stress** | ubuntu | installs tmux, runs the harness-free subset of `tests/stress.sh` |

Only the Codex `!`-refuse check in `tests/stress.sh` and the Windows live checklist below stay manual.

### Windows live verification

Static checks and the Linux jobs cannot see the Windows path — see the verification rule in
[docs/WINDOWS.md](docs/WINDOWS.md). **If your change touches `windows.sh` or any `win-*.ps1`**, run
against a real Windows host and tick these in the PR:

- [ ] `win <host> start claude` and `win <host>/two start codex` — both paint, both appear in `win <host> list`
- [ ] a **multi-line** `win <host> chat`, then `win <host> read` — the transcript shows the exact prompt,
      not a run-together one line
- [ ] two brokers of the same kind own **different** transcripts
- [ ] abort a confirmation and prove the composer is left clear
- [ ] `win <host> sh` with output **taller than the window** returns output + exit code, not a timeout
- [ ] `win <host> stop` leaves no descendant process and no descriptor behind

## Contribution flow

`main` is protected: land changes through a branch → pull request → green CI → merge, not by pushing
to `main` directly.

```
git switch -c my-change
# ... edit + validate ...
git push -u origin my-change
gh pr create --fill
```

## Release

1. On a branch, bump `version` in both `plugins/overseer` manifests and the
   `.claude-plugin/marketplace.json` entry (they must match — CI and release automation enforce it).
2. Move the `Unreleased` notes in `CHANGELOG.md` under the new version + date. CI **fails the PR** if the
   version changed without a matching `## [x.y.z]` heading.
3. Open the PR, get CI green, merge to `main`.

That is the whole flow — **tagging and releasing are automatic**. On every push to `main` the `autotag`
workflow reads the plugin version and, if `overseer--v<version>` does not already exist, creates the tag
and publishes the GitHub Release. It is idempotent: a merge that doesn't bump the version is a no-op.

You can still cut a tag by hand (`claude plugin tag ./plugins/overseer --push`) — `autotag` sees the tag already
exists and stands down, and the `release` workflow handles that path. Note `autotag` publishes the
release itself rather than leaning on `release.yml`, because a tag pushed by a workflow using the default
`GITHUB_TOKEN` deliberately does not trigger further workflows.

Claude Code users update with `/plugin marketplace update sgbl` + `/plugin update overseer` +
`/reload-plugins`. Codex users run `codex plugin marketplace upgrade sgbl` followed by
`codex plugin add overseer@sgbl`, then open a new thread.

## Style

The existing comments in `scripts/lib/*.sh` explain non-obvious tmux / TUI gotchas — **preserve them
verbatim** when you touch the surrounding logic. The project convention is otherwise *no prose
comments*: write self-documenting code and put new rationale in the commit, the PR, or `docs/`.
Functional comments (shebangs, `# shellcheck …` directives, license headers) are the exception.
Keep the Linux controller POSIX-ish Bash targeting tmux + jq. Keep the native Windows controller and
`win-*.ps1` payloads PowerShell 7-compatible; their rationale lives in
[docs/WINDOWS.md](docs/WINDOWS.md).

## Adding an agent harness

**Claude Code and Codex are both supported today.** Turn detection lives behind one seam in
`transcript.sh`: per-harness `_turn_count` / `_is_busy` / `_last_reply` / `_last_prompt`, dispatched by
`kind` through the `_h_*` wrappers. Supporting a third harness (OpenCode, …) means implementing those
four functions for it and adding its pane detection to `discovery.sh` — the whole command surface,
Linux and Windows alike, then works unchanged. Open an issue to discuss the seam before opening a PR.
