# Claude session memories (archived)

Working knowledge accumulated by Claude Code sessions on this repo between 2026-07-20 and 2026-07-29,
flattened out of the per-project memory store into one document. Each section was one memory file.

**Identifiers here are placeholders.** This file is tracked in a public repo, so real fleet hosts,
logins, IPs and the maintainer's private wrapper command names are written as `admin@win-host`,
`fleetuser`, `host-a`, `claude-wrapper`, … per the rule in [Public repo — no real
credentials](#public-repo--no-real-credentials). The real values live only in `~/.ssh/config`, the local
`OVERSEER_HOSTS` file, and `.tmp/` (gitignored).

---

## 1. How to work on this repo

### Version bump rule

Pick the digit in `x.y.z` by **what changed for someone using the command surface**, not by the commit
type prefix:

- **z (patch)** — a behaviour fix inside an existing command. No new command/flag/subcommand, no new
  return code, no changed output shape, no changed default. *Most `fix:` commits land here.*
- **y (minor)** — the surface changes: a new command/subcommand/flag, a new return code or a changed
  output shape someone could script against, a new env tunable, a renamed/removed command, or anything
  needing a reinstall (hooks, manifest wiring). While the project is 0.x, breaking changes go here too.
- **x (major)** — only 0.x → 1.0, i.e. declaring the command surface stable. Never per-change.

Docs- or tests-only changes need **no bump at all** — CI only demands a CHANGELOG entry *if* the version
moved.

*Why:* raised on 2026-07-27 after four releases in a row went 0.34.0 → 0.35.0 → 0.36.0 → 0.37.0 when
three of them were pure behaviour fixes and should have been 0.34.1/.2/.3. Across the repo's whole
history only 0.17.1 and 0.17.2 were ever patches — every other release bumped minor regardless of what
it contained, which makes the version number carry no information.

*Applying it:* decide the digit *before* editing `plugin.json` + `marketplace.json` (they must stay
equal, and the `## [x.y.z]` CHANGELOG heading must match, or CI fails and `/plugin update` no-ops). If a
change both fixes behaviour and adds surface, minor wins.

### Public repo — no real credentials

`overseer` is a **public** GitHub repo. Every tracked file (docs, tests, code, CHANGELOG, commit
messages, PR bodies) is world-readable.

*Why:* on 2026-07-22 real values had crept into *examples* — the real Windows `user@Tailscale-IP` in
`winshow` docs plus the `windows.sh` usage string, the real shared fleet login user in the new `hosts`
docs/CHANGELOG, and a real Windows username in example transcript paths. Scrubbed in v0.19.1 (PR #54).

*Applying it:* in any tracked file use PLACEHOLDERS, never real fleet identifiers — `admin@win-host`,
`fleetuser`, `user@host-a`, `C:/Users/user/…`, synthetic IPs like `100.0.0.1` / `10.0.0.9`. Never write
the real host names, tailnet domain, IPs or login users into docs/tests/CHANGELOG **or commit messages /
PR descriptions** (those are public too and can't be scrubbed without a history rewrite).

The same ban covers the maintainer's **personal wrapper command names** for their private builds of
Claude Code / Codex (internal testing only): naming them in a public example makes readers think they are
real commands to install. On 2026-07-27 one of them was found in `README.md`, `SKILL.md`,
`docs/WINDOWS.md` and `CHANGELOG.md` and scrubbed to the neutral placeholder `claude-wrapper` — use that
(or `codex-wrapper`) whenever an example needs a renamed agent binary.

Audit with `git grep` over tracked files before shipping anything that adds examples. No actual secrets
are in the tree by design (the broker token is runtime-generated); keep it that way.

### Never touch the maintainer's Claude Code setup

When a feature needs data that Claude Code only exposes through one of its extension points, do **not**
solve it by writing into the maintainer's Claude config — `settings.json`, `statusLine`, hooks,
`settings.local.json`, any scope. The ask was "one separate command, called only when needed". Find a
route that reads the data directly.

*Why:* overseer's entire premise is observing another agent's state without changing it — installing into
the observed setup contradicts it. Practically it also broke: a project `.claude/settings.json` overrides
the user file, so the statusline collector shipped in 0.38.0 silently collected nothing in every other
project, and it only sampled while a session happened to be rendering. The maintainer already runs their
own statusline and does not want it displaced.

*Applying it:* before reaching for an extension point, look for a direct read — an API the CLI itself
calls, a file the harness already writes, `/proc`. For quota this turned out to be
`GET https://api.anthropic.com/api/oauth/usage` with the token in `~/.claude/.credentials.json`
(overseer v0.39.0, ADR-0009). If only an extension point can work, say so and let the maintainer choose
rather than installing.

### macOS / non-Linux porting is out of scope

Do not propose, mention, or list it as remaining work — not in "what's left" summaries, not in
residual-risk lists — unless explicitly requested.

*Why:* there is no Mac to test on, so raising it is noise.

*Applying it:* the `_p_*` seam in `discovery.sh` plus `docs/PORTING.md` already exist for whoever picks it
up later; leave them as the standing answer and say nothing about macOS otherwise.

### Picking up a new plugin release

`/plugin update <name>` is **not** a real Claude Code slash command. Updating an installed plugin is done
through the interactive `/plugin` menu in the TUI: type `/plugin`, pick the plugin, choose Update.
`/reload-plugins` afterward (or a restart) loads the new code — it only re-reads on-disk code, it does
not git-pull the marketplace clone, so it never bumps the version. Verify with
`jq -r .version ~/.claude/plugins/marketplaces/overseer/plugins/overseer/.claude-plugin/plugin.json`.

**`autoUpdate: true` does not help the session you are in.** The `overseer` marketplace entry in
`~/.claude/settings.json` has `"autoUpdate": true` and is configured correctly — but a *running* session
pins its plugin version: `~/.claude/plugins/cache/<mkt>/<plugin>/<ver>/.in_use/<PID>` holds the PID of
the live session and Claude Code will not hot-swap the version underneath it. Versions released *during*
a long-lived session therefore stay invisible to it no matter how many `/reload-plugins` runs. The real
active version is the cache dir carrying the `.in_use/<CLAUDE_PID>` marker — check that, not the
marketplace clone. Fix: `/plugin` → Update, **or** just restart Claude Code (a fresh session
auto-updates). Diagnose with `ls ~/.claude/plugins/cache/overseer/overseer/*/.in_use/ && echo $CLAUDE_PID`.

---

## 2. The development box

### Two tmux builds

The long-lived tmux server (running since 2026-07-21, socket `/tmp/tmux-<uid>/default`) was started from
`/usr/local/bin/tmux` (3.6a); `/usr/bin/tmux` is 3.4 and protocol-incompatible. A 3.4 client against that
server prints `server exited unexpectedly`, which reads exactly like "I killed the tmux server" — it is
not, and the sessions are provably untouched. PATH already resolves to 3.6a; never hardcode
`/usr/bin/tmux` in a test shim. `overseer doctor` names this mismatch since v0.41.3.

### `~/.claude.json` transiently loses `hasCompletedOnboarding`

Observed `false` at 01:56 on 2026-07-29 (numStartups 965), `true` again a few startups later with no
repair. Do not report this as "the onboarding flag is reset" — it is intermittent, not a standing state.
What is known: the only code path in the 2.1.220 bundle that sets the flag `false` is the
logout/credentials-clear path; the bundle also carries explicit repair logic
(`tengu_config_auto_repaired`, citing GH #3117) for a config write that *loses*
`hasCompletedOnboarding===true`, i.e. upstream expects concurrent writers to clobber it. This box runs
6-7 concurrent Claude sessions all writing that one file, and pre-existing `.claude.json.rename-bak-*` /
`.pre-rename.bak` backups (2026-07-09, 07-15, 07-26) show the repair path firing long before any of this
work started. `theme: null` is normal here — it is in every backup alongside
`hasCompletedOnboarding: true`. Never edit that file to "fix" it.

### Admin pane vs worker panes

In the fleet workflow the human types **only** into the admin (dispatching) agent's pane; worker panes are
driven exclusively by overseer, never by hand.

*Why:* decided 2026-07-26 while designing `send --notify` (v0.34.0). Delivery clears the target's input
box (`_paste_verified` → `_clear_box`), so a wake-up pasted into a pane destroys anything half-typed
there. That was ruled acceptable — nothing human is ever pending in a worker pane, and the dispatcher
pane only receives a wake-up while it is idle.

*Applying it:* do not add box-empty guards or "skip if the user is typing" logic to overseer's delivery
path for this fleet; clobbering is the accepted behaviour. Revisit only if the maintainer starts typing
directly into worker panes.

---

## 3. Live-testing techniques

### Holding a Claude worker genuinely busy

A `sleep N` prompt is unreliable: an Opus worker **backgrounds** the sleep (via the Bash tool's
`run_in_background`) and ends its turn in seconds, and quick tasks ("write 1..300") finish in <2s.

**Use a heavy text-only reasoning prompt** instead — e.g. "Without using ANY tool, write a detailed
1500-word technical essay on \<topic\>." That holds the worker running for ~30-60s, is model-bound (can't
be backgrounded), and doubles as a test of text-only turn detection (`_running_claude`, the case
`_is_busy` misses). Poll `_running_claude "$transcript"` in a 1s loop right after `send` to catch
RUNNING. Verified v0.27.0 (queue-by-default) this way — `chat` blocked 57s and returned its own reply,
`wait` blocked 44s.

### Resolving a pane's transcript when sourcing libs standalone

A bare `_target_ctx` returns empty without the entry script's config. Do it by hand: pane_pid →
`pgrep -P` child claude pid → `~/.claude/sessions/<cpid>.json` (`.sessionId` + `.cwd`) →
`~/.claude/projects/<cwd-with-slashes-as-dashes>/<sessionId>.jsonl`.

### A throwaway Claude for live testing, without touching the maintainer's setup

Copy `~/.claude/.credentials.json` plus a patched `~/.claude.json` (`hasCompletedOnboarding=true`) into a
scratch dir, launch with `CLAUDE_CONFIG_DIR=<dir> claude`, and drive it with `CLAUDE_HOME=<dir> overseer
…`. Delete the credentials copy when done. Sharing one OAuth account with an extra process is the one part
of this that cannot be proven harmless — prefer not to unless the test needs a real agent. For anything
touching `fleet`, isolate tmux too with a PATH shim that adds `-L <name>`, so the fan-out cannot reach
real worker panes.

---

## 4. Remote fleet control — direction and shipped state

### Command surface

**Unified in v0.21.0 (PR #56, 2026-07-22).** The ten fused Windows commands became one transport prefix,
symmetric with `on <host> <verb>`, sharing the Linux verb vocabulary: `win <host>[/name] <verb>` —
`winbroker`→`win <host> start`, `winchat`→`win <host> chat`, `winshow`→`win <host> show`, likewise
wait/read/peek/sh/keys/list/stop. `chat`'s `--yes`/`--force` go AFTER the verb
(`win <host> chat --yes '…'`). Pure rename, no behaviour change, no aliases. Rationale:
`docs/DECISIONS.md` ADR-0004. Any `winX` name in older notes is a pre-0.21.0 historical record.

### Model A2 (chosen and built)

Single control point = the admin box (sole operator) reaching out to fleet machines. Run the WHOLE
overseer program on the remote via ONE `ssh host overseer <cmd>` call — NOT per-primitive remoting.
Because overseer is self-contained bash assuming co-location, running it whole on the remote makes tmux +
`/proc` + transcript + hook markers + lock all co-located and correct. Avoids the 46-scattered-tmux-site
refactor entirely.

Decided design answers:

- **Events:** no new protocol. Blocking commands (chat/wait/sh) run whole remote-side; the 0.25s poll runs
  on the remote's own files (remote transcript + remote hook markers, unchanged), ssh just holds the pipe.
  Hook acceleration works with zero redesign. One-shots (list/read/peek/fleet status) reuse ssh via
  ControlMaster/ControlPersist.
- **Identity/creds:** no DB, no cred store. The SSH key IS the credential. Host id = tailnet MagicDNS or
  100.x address. Session id = composite `host:target` (`host-a:%3`), resolved live remote-side. Only a
  tiny host-list (ssh config `Host` entries or an `OVERSEER_HOSTS` file) is needed, and only for `fleet`
  fan-out.
- **Precondition to accept a remote target:** tmux present AND (claude OR codex) present AND ssh key
  works — reuse the existing `doctor` run remote-side plus a local ssh-connectivity check.
- **Deployment:** the overseer bundle must be present on each remote (rsync `scripts/` to `~/.overseer/`
  once).
- **Not changing:** the tech stack stays pure shell; **no MCP** (MCP is for external systems, and tool
  schemas are context-resident ~290-675 tok/req; skills load on demand).
- **MCP + SQLite (cred/health DB) was re-raised on 2026-07-22 and REJECTED again** — user and key already
  live in `~/.ssh/config`, health can't be cached (recompute each run), no cred store (`SECURITY.md`),
  stays stateless per ADR-0002. Decided twice; do not propose it.

### Shipped

- **v0.6.0 (PR #33, 2026-07-20)** — `overseer on <host> <cmd> [args]` and `overseer deploy <host>`, over
  Tailscale + plain SSH (NOT Tailscale SSH — keys are managed by hand). Verified live driving a real
  claude on the Linux sandbox (6×7→42 in 4.2s over ssh).
- **v0.17.0 remote `start`/`stop` e2e, proven live 2026-07-22** — `deploy` → `on <H> start rmt_s1 shell`
  → `on <H> sh` → `on <H> stop` → GONE (verified by independent ssh); `on <H> start rmt_c1 claude`
  readiness rode the REMOTE `/proc` seam (detected ~2s after clearing the trust gate); `on <H> chat
  --yes` ran the full deliver→turn-detect→read-reply path remotely; a pre-existing session on the host was
  untouched. Both self-kill guards fired live from inside tmux.
- **v0.18.0 `hosts` fleet survey (PR #52)** — the "tiny host-list for fan-out" the design wanted.
  `overseer hosts` prints `HOST ONLINE OS SSH DRIVE` per host, probing live and in parallel. Inventory =
  `$OVERSEER_HOSTS` file → `$XDG_CONFIG_HOME/overseer/hosts` → non-wildcard `~/.ssh/config` `Host`
  entries. DRIVE = `yes` (linux tmux+jq) / `no:tmux` / `win*` (reachable Windows) / `-`. ONLINE from
  `tailscale status`. `--list` = inventory only; `-t` = connect timeout (default 6).
- **v0.19.0 (PR #53) — the login-user gap.** The ssh config only had the fleet's IPs (a grouped
  `Host <IPs>` block with a key but **no `User`**), so `hosts`/ssh fell back to the local username and
  were denied. Added: the HOST column shows the effective `user@host` (resolved via `ssh -G`);
  `-u USER` / `$OVERSEER_HOSTS_USER` forces the login user for bare hosts; `--tailscale [--os
  windows|linux]` enumerates the tailnet by **IP** (a short MagicDNS name trips `Host key verification
  failed` because the ssh-config fleet block is IP-keyed with `accept-new`; the IP is `ok`); SSH state
  `hostkey` split from `unreach`.
- **v0.20.0 `provision` (PR #55)** — `overseer provision [--dry-run] <host>` installs missing Linux drive
  deps (tmux/jq) via the host's package manager (apt/dnf/yum/pacman/zypper/apk), idempotent, needs root
  or passwordless sudo. Fixes a `hosts` `DRIVE=no:tmux` / `no:jq`. Linux base deps only — agents and
  Windows prereqs stay manual. README/SKILL document remediation for every `hosts` SSH
  (`deny`/`hostkey`/`unreach`) and DRIVE (`no:tmux`/`no:jq`/`win*`/`no:macos`/`-`) value.

### Pending (asked for, not started)

The v0.21.0 rename was the prerequisite for three fleet improvements:

1. Windows `send`/`slash`/`menu`/`quit` parity — now a 1-line `cmd_win` dispatcher add plus a `_win_*`
   handler each (`win … keys` already covers the manual path).
2. **`fleet` fan-out ACROSS remote hosts** — today `fleet` is local panes only; it would read inventory
   from `hosts`/`on`. Picked as the most valuable of the three.
3. Auto-`deploy` when `on <host>` finds `~/.overseer` missing.

Confirm scope before building any of them.

### Fleet facts worth keeping

- The Windows **client** machines (about nine of them in the tailnet) log in as a **shared ssh user that
  is not the admin's own username**; the one Windows laptop used for overseer testing uses a different,
  personal login. Real values: `~/.ssh/config` and the local `OVERSEER_HOSTS` file.
- The Linux test sandbox: tmux/jq/tar present, **passwordless sudo** plus apt (Ubuntu noble) — used to
  live-e2e `provision` (removed jq → `hosts` `DRIVE=no:jq` → `provision` reinstalled jq 1.7.1 →
  `DRIVE=yes`; host restored). Its ssh login is **not** the admin box's username; host-key TOFU, so pass
  `OVERSEER_SSH_OPTS="-o StrictHostKeyChecking=accept-new"` on the first `on`/`deploy`. As of 2026-07-22
  claude there is installed but **only on the interactive-shell PATH** (`command -v claude` over a
  non-login ssh returns nothing, yet a tmux pane's shell can launch it) and **not logged in**; no codex. A
  fresh claude on an untrusted folder sits at the "trust this folder?" gate, so `start <name> claude` on a
  new dir correctly **times out at 30s and keeps the session** (proven non-bug — answer with
  `keys <t> Enter` and discovery detects claude ~2s later).

---

## 5. Windows control

`docs/WINDOWS.md` is the authority — read it first. What follows is the history and the host-specific
facts that sit outside it.

### The Windows test host

Reachable over plain SSH with existing key auth, default shell `cmd.exe`, Windows 11 (build 26200), and
the login account is an **elevated local admin** (High Mandatory). The ssh user is per-host and must never
be guessed; the real `user@ip` is in `~/.ssh/config` / `OVERSEER_HOSTS`.

There, Claude Code must be started with the maintainer's **wrapper command**, not plain `claude` — plain
`claude` is on `PATH` but answers every prompt with `Not logged in · Please run /login`. Other Windows
hosts in the tailnet use plain `claude`. The wrapper is **defined in the console user's PowerShell
profile**, not an executable on `PATH` — a Session-0 `Get-Command <wrapper> -NoProfile` reports it missing
while the broker launches it fine, because the broker starts its child through a profile-loading `pwsh`.
It is a Claude Code build pointed at a third-party API (API Usage Billing), running in a fixed workdir
with bypass-permissions on. `codex` is also installed there, on `PATH`.

Because the agent's command name is per-host, overseer must never hardcode it: drive that host with
`OVERSEER_WIN_CLAUDE=<wrapper> overseer win <user>@<host> start claude`. The env var was added in v0.13.0
for exactly this (`OVERSEER_WIN_CODEX` is its Codex twin); the broker's `kind` stays `claude`, so
transcript reading is unaffected.

**Where that host's agent config comes from (cost a long hunt, 2026-07-21):** claude/codex get their
third-party API config from the **pwsh 7 profile** at
`%USERPROFILE%\OneDrive\Documents\PowerShell\Microsoft.PowerShell_profile.ps1`, which dot-sources a
`…\.claude\.profiles\claude-code.ps1` under the workdir. It is NOT in env vars (User and Machine scope
have none), NOT in `~/.claude/settings.json` or the project `settings.json` (their `env` blocks hold only
`CLAUDE_CODE_*` tunables), NOT in `~/.claude.json`, NOT in `~/.claude/.credentials.json` (absent), NOT in
Windows Credential Manager (empty). So **anything launching claude/codex on that box must go through a
profile-loading pwsh** (`pwsh -NoLogo -Command claude`) or it falls back to oauth and replies "Not logged
in". Also: on a **Windows console, Claude Code draws the selection cursor as ASCII `>`**, not `❯` — any
screen parser keyed on `❯`/`›` silently never matches there.

### Forbidden approaches

**WSL2 is FORBIDDEN and rcp is FORBIDDEN for this work** (ruled out explicitly 2026-07-20): do not use or
recommend the WSL2-as-Linux-target path, and do not use the `mcp__rcp__*` tools for driving Windows.
Native Windows control is plain SSH only.

### Session 0 → 1 bridge (proven 2026-07-20)

Launching a visible GUI on the user's desktop from an SSH session, no extra tools: SSH lands in
**Session 0** (service, invisible); the user's desktop is **Session 1** (has `explorer.exe`). Bridge 0→1
with a PowerShell-created scheduled task. Three gotchas, all hit and solved:

1. Session isolation → `New-ScheduledTaskPrincipal -UserId '<DOMAIN>\<user>' -LogonType Interactive` so
   the action runs with the logged-on user's token in Session 1 (visible). SYSTEM/ServiceAccount runs in
   Session 0 (invisible).
2. **Laptop on battery** → schtasks/default tasks carry `DisallowStartIfOnBatteries=true`, so on battery
   the task sits `Status: Queued`, `Last Result: 0`, and spawns NO process (silent and very misleading —
   cost several debug rounds). Fix: `New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries
   -DontStopIfGoingOnBatteries`. Check power via `(Get-CimInstance Win32_Battery).BatteryStatus`
   (1 = on battery, 2 = AC).
3. `wt.exe` is an app-execution-alias stub → direct CreateProcess exits without activating. Launch the
   packaged app by AUMID: action `C:\Windows\explorer.exe
   shell:AppsFolder\Microsoft.WindowsTerminal_8wekyb3d8bbwe!App`. Register → Start → delete the task; the
   window stays.

**Shipped as `overseer winshow <host> [app]` in v0.7.0 (PR #34)** — the plugin's one Windows-facing
command (overseer itself can't run on Windows). Launcher payload =
`plugins/overseer/skills/overseer/scripts/win-show.ps1`; `cmd_winshow` pipes it over ssh stdin to a tiny
EncodedCommand bootstrap that writes it to a temp file and runs `powershell -File` (dodging the cmd
8191-char limit that killed the encode-whole-script approach), filters output to the one `OK`/`ERR` line,
and uses `ServerAliveInterval` + 3× retry for the flaky relay. Two more gotchas: `MainWindowHandle` is
**0 for any process when queried from Session 0**, so window-handle detection is useless cross-session —
success is instead a **new process in the console session** (token-preferred match); and Windows Terminal
on that laptop **opens a new window every call** (not single-instance), so it always reports `OK new`. The
Tailscale link to that laptop is relayed, not direct — wrap every ssh call in a retry.

### The broker (proven 2026-07-21)

Driving a Windows shell AND a native Claude Code TUI turn-based, from Linux over plain SSH, with no
tmux/install/rcp/WSL2. Approach (better than the ConPTY plan): a **cooperative "broker" pwsh** launched
*visibly in Session 1* via the `winshow` scheduled-task bridge, hosting a child (pwsh / claude.exe /
codex) that **shares the broker's console**. The broker exposes a **named pipe** (cross-session — a
Session-0 SSH client reaches the Session-1 server, verified `client_sid=0 ↔ server_sid=1`) speaking a
tiny line protocol: `TYPE <b64utf8>` → `WriteConsoleInput` (≡ tmux send-keys), `SNAP` →
`ReadConsoleOutputCharacter` framed `<<<SNAP`…`>>>SNAP` (≡ capture-pane — **gives the rendered grid for
free, so no VT emulator is needed and `peek` + `_awaiting` come free**), plus PING/BYE/QUIT. overseer runs
a one-shot client per turn over `ssh host powershell -File …`. Live results: shell `whoami;hostname` →
exit 0; Claude Code v2.1.209 TUI rendered (trust prompt plus a numbered `> 1.` captured — same shape as
Linux `_awaiting`), Enter injected → advanced to the main screen. Same broker, only `-Child` changes (like
tmux hosting any TUI).

Gotchas hit: pipe I/O must be **sync ReadLine/WriteLine with default pipe options and default encoding**
(adding `PipeOptions.Asynchronous` + `ReadLineAsync` deadlocked both ends; the proven pattern is plain
sync); `[Process]::Start($psi)` returns a *String* here (quirk), so get the child PID via `Win32_Process
ParentProcessId=$PID`, not the return value; box-drawing chars mangle over SSH→bash (force UTF-8 both
ends).

### The driving suite — v0.8.0 (PR #35, 2026-07-21)

Landed as six commands (pre-0.21.0 names) — `winbroker <host> [pwsh|claude|codex] [workdir]` `winpeek`
`winkeys` `winsh` `winchat` `winstop` — plus three payloads under
`plugins/overseer/skills/overseer/scripts/`:

- `win-broker.ps1` — the Session-1 broker: ConIO `Add-Type` + named pipe + child sharing the console.
  `Resolve-StartDir` reads Windows Terminal `settings.json`'s default `startingDirectory`, so the
  terminal opens at the host's configured default, overridable via `[workdir]`, never hardcoded.
- `win-client.ps1` — the one-shot per-turn client; forces `[Console]::OutputEncoding=UTF8`.
- `win-launch.ps1` — kills stale brokers, registers + starts + unregisters the Interactive scheduled
  task, polls the pipe for readiness.

`cmd_win*` scp the payloads to `%USERPROFILE%` and invoke via `powershell -File`. **`winchat` reuses the
EXISTING bash+jq `_h_turn_count`/`_h_last_reply` verbatim** on the Windows rollout/session jsonl scp'd
back (identical schema) — one seam, no PowerShell turn-detection. Codex quirks handled: paste text then a
SEPARATE Enter (a `\r` inside the keystroke burst is a paste-newline, not submit); codex boots on a "Press
enter to continue" update notice that must be cleared first. All six verified live end-to-end (a real-API
Codex turn, pwsh `whoami`, workdir; broker cleanly stopped `procs=0 pipes=0`).

**Documented in the repo from v0.10.1 (2026-07-21):** `docs/WINDOWS.md` carries the Session 0→1 bridge and
its silent battery trap, the tmux↔broker primitive mapping, and the console-injection facts (raw ESC is
never delivered, so bracketed paste is impossible; a `\r` with `wVirtualKeyCode=0` is swallowed; Ctrl+J is
the composer newline; the box must be cleared first; `Split-Path -Leaf` returns empty for
`\\.\pipe\<name>`). Same release: `lib/windows.sh` split out of `commands.sh`, the Windows parsers
(`_win_split`/`_win_field`/`_win_sig`) covered in `tests/run.sh`, and ADR-0002 recorded "stay a skill +
hooks, not MCP/subagent".
