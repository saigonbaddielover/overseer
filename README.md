# overseer

[![validate](https://github.com/saigonbaddielover/sgbl-overseer/actions/workflows/validate.yml/badge.svg)](https://github.com/saigonbaddielover/sgbl-overseer/actions/workflows/validate.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**One agent that oversees others.** Drive and read other agent sessions — and plain shells —
turn-based, from outside them: in **Linux tmux panes** (local or over ssh) and in **native Windows
console windows** on a remote machine's visible desktop. Packaged as a
[Claude Code plugin](https://code.claude.com/docs/en/plugins).

On Linux, overseer both **drives sessions someone else started** and **starts/stops its own**: `list`
discovers a tmux pane already running Claude Code, Codex or a shell and reads/drives it turn-based, while
`start` opens a fresh **detached** tmux session running a shell or agent and `stop` tears one down. (On a
Windows host — which has no tmux pane to find — `win <host> start`/`win <host> stop` are the equivalent
pair.) Today it
speaks **Claude Code** and **Codex** (plus any shell); `read`/`chat`/`send`/`wait`/`list` auto-detect
which harness a pane runs. It's built so more harnesses can be added behind the same commands.

A running agent TUI has no API — its only input channel is the keyboard. `overseer` wraps a
deterministic, self-verifying `tmux send-keys` / `capture-pane` procedure (plus transcript reading) so
an agent can read and drive another session the user is watching. Because tmux is client/server, it
works the same whether the pane is local or displayed over VSCode Remote-SSH — the driving happens
server-side.

> [!WARNING]
> **This executes actions in other sessions.** Target Claude sessions usually run with
> `--dangerously-skip-permissions`, so anything sent auto-runs with no confirmation gate, and `sh`
> runs a command in the user's shell the instant it's called. Treat every send as running a command on
> a machine you don't fully control. The skill's own rules say: never send unless explicitly asked.

## Support model

| | |
|---|---|
| **Controller** (where overseer runs) | **Linux** only — pane discovery reads `/proc`. Needs `tmux`, `jq`, `bash ≥ 4.1`, plus `ssh`/`scp` for any remote target. |
| **Targets** | **Linux tmux panes**, local or on another Linux host over ssh (`deploy` + `on`); **remote native Windows consoles** over plain ssh (the `win <host> <verb>` commands, via a PowerShell broker on the visible desktop — no tmux and no WSL there). |
| **Not supported** | A macOS controller (specced in [docs/PORTING.md](docs/PORTING.md), unbuilt); local pane discovery anywhere but Linux + tmux; a plain non-tmux Linux terminal as a target. |

## Requirements

- **Linux** controller — agent discovery reads `/proc` (a macOS `ps`/`lsof` backend sits behind a
  small OS seam and is fully specced in [docs/PORTING.md](docs/PORTING.md), unbuilt).
- **tmux** — a Linux target must run inside tmux (a plain PTY can't be driven; the kernel blocks
  keystroke injection and the screen buffer lives client-side). Windows targets use the broker
  instead — see [docs/WINDOWS.md](docs/WINDOWS.md) for its prerequisites and security model.
  No version is pinned: overseer always calls whichever `tmux` is on `PATH` and never a fixed path, so
  it follows yours. What *does* matter is that a tmux client can only talk to a server started from a
  build of the same protocol version — so if a machine has two tmux installs (say `/usr/bin/tmux` 3.4
  and `/usr/local/bin/tmux` 3.6a), commands run through the wrong one fail with `server exited
  unexpectedly`, which reads like the server died when it is fine. `overseer doctor` compares the two
  and names them.
- **jq** — for transcript reading.
- **ssh** — required by the remote `on`/`deploy` commands and all `win <host> <verb>`. **tar** — by
  `deploy` only (it ships `scripts/` over ssh + tar). **scp, base64, iconv** — by the Windows `win`
  commands only.
  The local tmux commands need none of these.
- **bash ≥ 4.1** — the script uses named file descriptors and associative arrays; stock macOS bash 3.2
  is too old (install a newer bash and run overseer under it).
- **Claude Code** — this is a plugin for it.
- **Codex** *(optional)* — to drive Codex panes as well; Claude-only setups need nothing extra.

## Install

From inside Claude Code:

```
/plugin marketplace add saigonbaddielover/sgbl-overseer
/plugin install overseer@sgbl
```

That installs the skill, the `overseer` script, and the turn-done hook together (make sure the
requirements above are present). Then just ask Claude things like *"read the latest from the claude in
my other tmux pane"* or *"reply to it with X"* — the skill triggers on its own.

## Updating

```
/plugin marketplace update sgbl   # re-fetch the marketplace from GitHub
/plugin update overseer           # pull the new version into the plugin cache
/reload-plugins                   # activate it in the current session — no restart
```

## Commands

All work goes through one script; the agent calls it as
`bash "${CLAUDE_PLUGIN_ROOT}/skills/overseer/scripts/overseer" <command> [args]`.
`<target>` is a tmux pane id (`%3`) or a session/window name (its active pane).

| Command | Effect |
|---|---|
| `list [--all]` | **Every agent the harness knows**, led by **PEER** — the name Claude Code itself addresses a session by (`-` when it has none) — and **REACH**: `keys+peer` (a drivable tmux pane that also answers on the peer channel), `keys` (a Codex/unnamed pane), or `peer` (a live claude with **no tmux pane** — overseer cannot drive it, only `SendMessage` reaches it). Then session, pane, pids, **HARNESS** (claude/codex) and cwd. Every command takes that PEER name as its target, ahead of `%N` or a session name, and targeting a `peer`-only row tells you to use `SendMessage` instead of failing with "no tmux pane". `--all`: every pane + its foreground command. |
| `read <target>` | Print the last user prompt + last assistant reply from the agent's transcript (Claude or Codex, auto-detected). |
| `peek [raw\|-e] <target> [lines]` | Dump the pane's current screen. `raw` (also `-e`/`--raw`) keeps ANSI colors (see the active tab/selection) and prints the whole screen; plain mode drops blank lines and honours `[lines]`. |
| `chat [--yes] [--force-keys|--as-user] <target> <msg\|-> [timeout]` | **Agent (Claude/Codex).** Send, wait for the turn to finish, print the reply. If the agent is **busy or compacting**, the message is **queued** and `chat` waits for *its own* turn to complete (not the running one) before printing that reply. If the agent stops at a prompt, returns its question + how to answer instead; if the turn is **interrupted** it says so instead of waiting out the timeout (the message was delivered, so `peek` before resending). |
| `send [--yes] [--notify] [--force-keys|--as-user] <target> <msg\|-> [notify_timeout]` | **Agent (Claude/Codex).** Place + submit, confirm the turn started (so a following `wait` doesn't race), don't wait for the reply. If the agent is **busy or compacting**, the message is **queued** — `send` says so and exits 0; it was accepted and runs when the agent frees up, so `wait` for it. **`--notify`** additionally arms a detached watcher on that worker: when its turn ends (or it stops at a prompt, or it dies) the watcher **pastes a wake-up into the tmux pane you ran `send` from**, so the dispatcher can go idle instead of sitting in a poll loop — see [Getting told instead of polling](#getting-told-instead-of-polling). |
| `unsend <target>` | **Agent (Claude).** **Retract** the message queued behind the running turn, before it runs: pull it back out of the queue, print it, and clear the input box — the turn itself is untouched and keeps running. Nothing queued is not an error. **Codex is refused**, and says why: a message sent to a busy Codex is handed to the model immediately as a *steer*, so it is already in flight and no keystroke pulls it back. |
| `interrupt [--run-queued] <target>` | **Agent (Claude/Codex).** Stop the turn that is running right now — Escape in the pane, then confirm the agent actually settled. The turn **ends with no reply**, so nothing it was writing is kept. If a message is queued behind that turn it **refuses**, because interrupting hands control straight to the queued message and it starts immediately: `unsend` it first to stop everything, or pass `--run-queued` to accept that and let it run. |
| `wait <target> [timeout]` | **Agent (Claude/Codex).** Block until the current turn finishes — or return early if the agent stops at a prompt awaiting input. Correctly waits through a **compaction** with a queued message (which reads idle in the transcript) instead of returning early, and returns `idle` in seconds if the turn was **interrupted** (a Claude interrupt leaves no trace in the transcript, so what ends the wait is the pane's screen not moving at all across several consecutive samples — a live turn always moves, either its spinner or the reply text it is writing; Codex records `turn_aborted` and needs no such heuristic) rather than blocking to the timeout. |
| `fleet [--hosts\|--tailscale [--os NAME]] [-u USER] [status\|read\|unsend\|interrupt\|wait\|send [--force-keys|--as-user]\|chat [--force-keys|--as-user]] [args]` | **Every agent pane at once** (no subcommand = `status`). `status` = one line each (harness + `idle`/`busy`/`awaiting`/`compacting`, plus `idle(0-turn)` for a started-but-unused agent; **`busy` covers a turn that calls no tool at all** — a long text-only answer — which is decided from the transcript and confirmed by the pane's screen still moving, so an interrupted turn reads `idle` rather than sticking at `busy` and `(not an agent)` for a pane that stopped being one; `compacting` is a claude summarizing its context — the transcript reads idle but a message sent to it would only **queue**); `read`; `wait [--any] [timeout]` — plain `wait` fans a per-pane wait over every pane, while `wait --any` returns as soon as the **first** in-flight pane finishes/awaits/exits (built for a poll loop: dispatch to N agents, then `fleet wait --any` to react to whichever pings first); `send`/`chat [--yes] <msg>` **broadcast** the same message to all agent panes, and `send --notify <msg> [notify_timeout]` arms one watcher per receiving pane so the dispatcher is woken instead of polling at all. A thin fan-out over the per-pane commands — a broadcast only messages **idle** panes (busy/awaiting/compacting ones are skipped, never queued onto), and one failing pane never aborts the batch. Add **`--hosts`** (or `--tailscale [--os NAME]`, `-u USER`) to also fan out **across the whole fleet**: each inventory host — resolved exactly like [`hosts`](#surveying-the-fleet-and-fixing-whats-missing), auto-deployed on first touch — runs `on <host> fleet <sub>` (its own local sweep, in parallel, one section per host under `===== host =====`). Local panes come first under `===== local =====`. A fleet-wide `send`/`chat` is a **blind broadcast into unrelated projects**, so it is gated: overseer first runs a read-only status sweep, **previews exactly which idle agents would receive it** (and which panes it will skip as busy/awaiting), and asks for **one confirmation** — `--dry-run` stops after the preview, `--yes` skips it for scripts. Only `idle` agents can receive: a busy one is skipped so a broadcast never queues onto unrelated work, so the preview errs toward *skipping*, never toward sending wider than shown. `unsend` and `interrupt [--run-queued]` fan the per-pane command over every pane, so one call clears a stale broadcast or stops a whole fleet mid-turn. A broadcast inherits the per-pane peer refusal, so a claude pane with a **PEER** name is skipped unless `--force-keys` (or `--as-user`) is passed. |
| `quit <target>` | **Agent (Claude/Codex).** Exit the TUI (Claude: two Ctrl-C; Codex: one), revealing the shell, keeping tmux/pane alive. |
| `start <name> [shell\|claude\|codex] [workdir]` | **Create (Linux tmux).** Open a new **detached** tmux session named `<name>` running a shell (default), Claude Code or Codex; for an agent it waits until the harness has actually come up before returning. Watch it with `tmux attach -t <name>`, then drive it with `chat`/`send`/`sh`/… Runs identically locally and via `on <host> start …`. Refuses a name that isn't `[A-Za-z0-9_-]`, one already in use, or a `workdir` that does not exist. |
| `stop <target>` | **Delete (Linux tmux).** Tear down what `start` made (or any tmux target): a **PEER** name or a `%N` pane → `kill-pane` (that one pane); a session name → `kill-session` (the whole session), which SIGHUPs its child agent/shell. Refuses to kill the session — or, for a `%N` target, the pane — overseer itself is running in. The Linux peer of `win <host> stop`. |
| `slash <target> </cmd>` | **Agent (Claude/Codex).** Run a slash command (`/model`, `/status`, ...; Claude also `/resume`, `/clear`) that `send`/`chat` can't. The leading `/` is optional — `slash <target> resume` works too. |
| `menu <target> <item> [nav-key]` | **Any pane.** Navigate a tab bar / list until `<item>` is highlighted (verify-driven). Default nav key `Right` suits a Claude tab bar; Codex popups are vertical — pass `Down`. |
| `sh <target> <command> [timeout]` | **Shell.** Run one command line, wait, print output + exit code. |
| `keys <target> <key>...` | Send raw tmux keys (`Enter`, `Escape`, `Up`, `C-c`, ...). Any pane. |
| `usage [--json] [target]` | **Account quota + context.** Print every **usage window** the account has, with how much is spent and when it resets — and, separately and clearly labelled, the session's **context** size. Only quota can stop work: context [auto-compacts](#context-is-not-a-health-signal) and is informational. Claude's windows are read **live** from `https://api.anthropic.com/api/oauth/usage` using the OAuth token already in `$CLAUDE_HOME/.credentials.json` (needs `curl`), carrying the server's own `severity` — so a window it calls `critical` is flagged even below `OVERSEER_QUOTA_WARN`. Codex's come from its rollout. **Nothing is installed and no Claude config is touched.** No target = this machine's account; a target adds that pane's context. `--json` for scripts. An account with no subscription window — Bedrock/Vertex/an API key/a proxy, i.e. no OAuth credentials at all — reports `quota n/a`, which is normal, not a failure. |
| `doctor [--live]` | Preflight: check Linux/`/proc`, `tmux`, `jq`, `codex`, and that Claude/Codex session state is where discovery expects it. `--live` (also plain `live`) additionally drives a throwaway pane through a `sh` round-trip to verify the send/capture path end to end; a failing `--live` check makes `doctor` exit non-zero. |
| `hosts [--list] [--tailscale] [--os NAME] [-u USER] [-t secs]` | **Remote (SSH), fleet survey.** Print one line per host — `HOST ONLINE OS SSH DRIVE`, where `HOST` is the **effective `user@host`** — so you can see which machines you can actually drive, *and as which user*, before an `on`/`win`. The inventory (ssh targets to probe) comes from `$OVERSEER_HOSTS` if set, else `$XDG_CONFIG_HOME/overseer/hosts`, else the non-wildcard `Host` entries of `~/.ssh/config`; or pass `--tailscale` to enumerate the tailnet directly (`--os windows`/`linux` filters it) for machines you never added to ssh config. **The login user** for a bare host (no `user@`) is resolved from `ssh -G` — so an ssh-config `Host … User fleetuser` block is honoured and shown — or forced with `-u USER` / `$OVERSEER_HOSTS_USER` when it lives nowhere (the common "same user across the whole fleet" case). Each host is probed **live and in parallel**: `SSH` is `ok`/`deny`/`unreach`, `OS` is `linux`/`windows`/`macos`, `DRIVE` is `yes` (Linux with `tmux`+`jq`), `no:tmux`/`no:jq`, or `win*` (a Windows broker target). `ONLINE` is filled from `tailscale status` when the CLI is present. Nothing is stored — reachability is computed each run (a cached health value would just be stale). `--list` prints the inventory without probing; `-t` sets the per-host ssh connect timeout (default 6s). |
| `provision [--dry-run] <host>` | **Remote (SSH).** Install the missing Linux **drive** dependencies (`tmux` + `jq`) on a reachable host — the fix for a `hosts` `DRIVE=no:tmux`/`no:jq`. Detects the package manager (`apt`/`dnf`/`yum`/`pacman`/`zypper`/`apk`), installs only what's absent (idempotent), and needs **root or passwordless `sudo`** on the host (it runs non-interactively). `--dry-run` prints the exact command instead of running it. Linux only, and only the base deps — Claude/Codex agents (and every Windows prerequisite) are still set up by hand. |
| `deploy <host>` | **Remote (SSH).** Copy overseer's `scripts/` to `~/.overseer` on a remote ssh host (via `ssh`+`tar`) so `on` can run there. `<host>` is any ssh target — a `user@host`, a `~/.ssh/config` alias, or a Tailscale MagicDNS name. Usually you don't call this by hand — `on` auto-deploys on first use; run `deploy` explicitly to **update** a host after changing overseer, or to pre-stage before a blocking command. |
| `on <host> <command> [args]` | **Remote (SSH).** Run any overseer command on a remote host over ssh and stream the result back — the *whole* program runs remote-side, where its tmux/`/proc`/transcript reads are all co-located, so discovery and completion detection work unchanged. **Auto-deploys on first use**: a quick `[ -f ]` probe (over the same multiplexed master the real command then reuses, so it costs nothing extra) runs `deploy` once if `~/.overseer` isn't there yet — so `on <host> …` just works without a prior `deploy`. Blocking `chat`/`wait`/`sh` hold one ssh connection while they poll remote-side; one-shots reuse a multiplexed master (`ControlPersist`). Pass `--yes` for remote auto-submit (the confirm gate has no tty over ssh). e.g. `on sandbox chat %0 'hi'`, `on sandbox doctor`. |
| `win <host>[/name] <verb>` | **Remote (SSH), Windows target.** Drive a remote Windows **console broker** over plain ssh — the `win` prefix is to a Windows host what `on <host>` is to a remote Linux one. `<host>[/name]` picks the broker (add `/name` to run several side by side); `<verb>` is one of the shared verbs in the table below (the same vocabulary as the Linux commands). The broker is a **visible** console child (pwsh / Claude Code / Codex) exposing a machine-wide named pipe that speaks `WriteConsoleInput`/`ReadConsoleOutputCharacter` — the Windows analogue of tmux `send-keys`/`capture-pane`, so a plain-SSH host with no tmux is still drivable. Full rationale in [docs/WINDOWS.md](docs/WINDOWS.md). |

`--yes` auto-submits (skips the confirm gate). A `send`/`chat` to a **busy or compacting** agent is
**queued** behind its running turn, not refused — `send` reports `QUEUED` and exits 0, `chat` waits for
the reply to *its own* queued message (bound to your message positionally, so a newer queued prompt can't
steal it). Only **one** message queues at a time: a second `send`/`chat` while one is already queued is
refused, pointing you at `wait`. Pass `-` as the message to read a long, multi-line prompt from stdin.

### Windows verbs (`win <host>[/name] <verb>`)

The Windows surface uses the **same verb vocabulary as Linux** behind the `win` prefix — `win <host>
start` is `start`, `win <host> chat` is `chat`, and so on. (The old fused names `winbroker`, `winchat`,
`winstop`, … were folded into these verbs.)

| verb | what it does |
|---|---|
| **start** `[pwsh\|claude\|codex] [workdir]` | Start/switch a **visible broker** child on the host's console (Session 1, via the scheduled-task bridge). Opens in the host's Windows Terminal default directory unless `[workdir]` is given, and starts the child **through the user's PowerShell profile** (inheriting API config, aliases, PATH). Returns once the child has painted its first screen. Re-run to switch the child. The Windows peer of `start`. |
| **show** `[app]` | Open a GUI app — default Windows Terminal, or any Start-menu name / AUMID / full exe path — on the host's **visible console session**. Windows-only (no Linux peer). e.g. `win admin@win-host show`, `win win-host show 'Notepad'`. |
| **list** | List the overseer brokers on the host — one line per named broker with its child kind, working directory and whether the child is alive. The Windows peer of `list`. |
| **peek** | Snapshot the broker window's current screen grid. The Windows peer of `peek`. |
| **keys** `<key\|text>...` | Inject named keys (`Enter`, `Escape`, `Up`, `Down`, `Tab`, `Backspace`, `C-c`, …) or literal text into the broker child. Text lands as one keystroke burst; submit with a separate `Enter`. The Windows peer of `keys`. |
| **sh** `<command> [timeout]` | Run one command line in the broker's **pwsh** child, wait via a unique sentinel, print output + exit code. Needs `win <host> start pwsh`; refuses a broker hosting an agent. The Windows peer of `sh`. |
| **read** | Print the last user prompt + last assistant reply from the broker's **claude/codex** child, read from its on-disk transcript with the *same* `transcript.sh` readers (fetched back over ssh). The Windows peer of `read`. |
| **chat** `[--yes] [--force] <prompt\|-> [timeout]` | Send a prompt to the broker's **claude/codex** child, submit it, wait for the turn via the transcript, print the reply. Needs `win <host> start claude\|codex`. Carries the same guards as Linux `chat` — refuses a mid-turn agent (`--force` bypasses), refuses a Codex `!` message, prepends a space for Claude's `/ ! # @`, verifies the pasted prompt on screen before submitting, holds a per-host lock, returns the **question** if the agent stops at a prompt, fails fast if it dies mid-turn, and says so instead of waiting out the timeout if the turn is **interrupted**. The poll is signature-gated on the broker's reported `mtime:size` (the Windows analogue of the local `_file_sig`). The Windows peer of `chat`. |
| **send** `[--yes] [--force] <prompt\|->` | Like `chat`, but **do not wait for the reply** — place + submit, then confirm the turn *started* (so a following `wait` doesn't race), and return. Read the reply later with `win <host> read` or block with `win <host> wait`. Same guards as `chat`. The Windows peer of `send`. |
| **unsend** | **Retract** the message queued behind the broker agent's running turn, before it runs — pulled back out of the queue over the same fetched transcript the Linux `unsend` reads, then the box is cleared. Claude brokers only; a Codex broker is refused, because a mid-turn message there is already an in-flight steer. |
| **interrupt** `[--run-queued]` | Stop the broker agent's running turn; the turn ends with **no reply**. Refuses while a message is queued behind it (interrupting would start that message immediately) unless `--run-queued` is passed. Claude on the Windows console interrupts on **`C-c`**, not Escape — a raw `ESC` byte never reaches the child; Codex takes `Escape` as a key event. |
| **wait** `[timeout]` | Block until the broker's agent finishes its current turn, or return the **question** if it stops at an interactive prompt (`idle` if it was not busy). Busy covers a **text-only** turn that calls no tool, confirmed by the broker's `SNAP` grid still moving, so an interrupted turn returns `idle` in seconds rather than blocking. Use it to resume after a `win <host> chat`/`send` timeout instead of re-sending. The Windows peer of `wait`. |
| **slash** `</cmd>` | Run a slash command (`/model`, `/status`, …) in the broker's **claude/codex** — which `chat`/`send` can't, since they keep a leading `/` literal. The leading `/` is optional. A menu it opens is then navigated with `menu`/`keys`. The Windows peer of `slash`. |
| **menu** `<item> [nav-key]` | Navigate the child's popup until `<item>` is the highlighted row, then confirm with `win <host> keys Enter`. Because the console grid carries **no colour**, the highlight is read from the row's cursor glyph (`>`/`❯`/`›`), so it works on the vertical popups (`/model`, approvals) that matter on Windows. Default nav key `Down`. The Windows peer of `menu`. |
| **quit** | Gracefully exit the broker's agent TUI with Ctrl-C (twice for Claude) so it can flush on the way out. The broker **closes with it** if the agent was its only child (as on a `start claude` broker) — `stop` is the force-kill alternative. The Windows peer of `quit`. |
| **stop** | Stop the broker and its child on the host. The Windows peer of `stop`. |

Four environment variables tune the defaults (all validated at startup, so a bad value fails loudly):
`OVERSEER_TIMEOUT` (default `600`) is the fallback `[timeout]` seconds for `chat`/`wait`/`sh`,
`OVERSEER_POLL_INTERVAL` (default `0.25`) is the poll cadence in seconds, `OVERSEER_QUOTA_WARN`
(default `90`) is the percentage at which `usage` flags a quota window and `chat`/`send`/`wait` print
a one-line warning to stderr, and `OVERSEER_QUOTA_TTL` (default `300`) is how long that warning may
reuse a cached quota reading before refetching — `usage` itself always fetches live. Two more point overseer at
non-default state directories: `CLAUDE_HOME` (default `~/.claude`), used to find Claude's session
files, transcripts and the hook markers. `CODEX_HOME` (default `~/.codex`) is read only by `doctor` —
live Codex discovery finds the rollout the running process holds open via `/proc`, so it is unaffected.

For a Windows target, `OVERSEER_WIN_CLAUDE` (default `claude`) and `OVERSEER_WIN_CODEX` (default
`codex`) name the command `win <host> start` launches on that host — set them when the agent is
installed under another name there, e.g. a wrapper:

```
OVERSEER_WIN_CLAUDE=claude-wrapper overseer win win-host start claude
```

The broker's `kind` stays `claude`/`codex`, so turn detection is unaffected. The value must be a bare
command name (letters, digits, `.`, `_`, `-`); it travels base64-encoded and is never interpolated
into a command line.

## Remote (SSH / Tailscale)

To drive a pane on another Linux box — e.g. across a Tailscale tailnet — run the whole overseer program
on that host over ssh, so its tmux/`/proc`/transcript reads stay co-located and every command behaves as
it does locally. Just prefix any command with `on <host>` — the first `on` **auto-deploys** overseer to
the host, so no separate step is needed:

```
overseer on sandbox doctor               # first use auto-deploys, then runs remote preflight
overseer on sandbox start work codex     # create a detached codex session ON the remote box
overseer on sandbox chat --yes work 'hi' # drive it; the reply streams back
overseer on sandbox stop work            # tear it down when done
overseer deploy sandbox                  # only needed to UPDATE the host after changing overseer
```

`<host>` is any ssh target (a `user@host`, a `~/.ssh/config` alias, or a Tailscale MagicDNS name);
credentials are ssh's own — no daemon, DB, or token store. overseer adds `ControlMaster`+`ControlPersist`
so bursts of one-shot commands reuse one connection. A blocking `chat`/`wait`/`sh` polls remote-side and
ssh just holds the pipe, so no separate event channel is needed. Pass `--yes` for a remote `chat`/`send`:
without a tty the confirm gate can't prompt, so it fails closed. Auto-deploy runs only for the default
layout; set `OVERSEER_NO_AUTODEPLOY=1` to turn it off (then `deploy` by hand). Overrides:
`OVERSEER_REMOTE_DIR` (where `deploy` writes, default `.overseer` under the remote `$HOME`) and
`OVERSEER_REMOTE_BIN` (what `on` then executes, default `$HOME/.overseer/scripts/overseer`; setting it
also disables auto-deploy, since a custom bin is yours to manage) — **change one and you must change the
other to match** — plus `OVERSEER_SSH`, `OVERSEER_SSH_OPTS`, and `OVERSEER_SCP` for the Windows transcript
fetch.

The `on`/`deploy` model targets **Linux** (it runs overseer, which needs `/proc` + tmux). A **Windows**
host in the tailnet is reached differently: overseer can't run there, so the `win <host> <verb>` commands
ssh-execute PowerShell payloads that put a driveable console on its **visible desktop**. The lifecycle is
start → drive → stop:

```
overseer win win-host start claude C:\repo    # start a VISIBLE claude on the user's desktop
overseer win win-host list                    # which brokers exist, their child, alive?
overseer win win-host chat --yes 'run the tests' 900   # prompt it, wait the turn, print the reply
overseer win win-host read                    # last prompt + last reply, any time
overseer win win-host wait 900                # resume waiting after a timeout instead of re-sending
overseer win win-host stop                    # stop the broker and its child

overseer win win-host start pwsh              # …or a shell instead of an agent
overseer win win-host sh 'git pull'           # run one line in it, wait, print output + exit code

overseer win admin@win-host show              # one-shot cousin: just open a GUI app and return
overseer win win-host show 'Notepad'          # any Start-menu name, an AUMID, or a full exe path
```

Prerequisites, the pipe trust boundary and the security notes for all of this are in
[docs/WINDOWS.md](docs/WINDOWS.md).

An ssh session on Windows lands in the non-interactive **Session 0**, so a naively launched GUI is
invisible. `win <host> show` bridges to the logged-in **console session** with a throwaway interactive
scheduled task (`-LogonType Interactive` as the console user, resolved live), which also clears the two
silent traps: a laptop **on battery** (default tasks carry `DisallowStartIfOnBatteries`, so they sit
`Queued` and never launch — `win <host> show` disables that) and Windows Terminal's **app-execution-alias**
stub (launched
by AUMID via `explorer.exe shell:AppsFolder\…`, not a direct `CreateProcess`). It errors clearly if no
user is at the console (locked / logged off). Needs an admin ssh login on the Windows host.

### Surveying the fleet and fixing what's missing

`overseer hosts` prints one line per host — `HOST ONLINE OS SSH DRIVE`, where `HOST` is the effective
`user@host` (the login user resolved from `ssh -G`, or forced with `-u`). It answers two separate
questions — *can I reach it* (`SSH`) and *can I drive it* (`DRIVE`) — and each value tells you what to do:

**`SSH`** — reaching the host over ssh:

| Value | Means | Fix |
|---|---|---|
| **ok** | connected and ran a command | — |
| **deny** | reached sshd, auth rejected | wrong user or key. Set the right `User`/`IdentityFile` in `~/.ssh/config`, or pass `-u USER` / `user@host`; make sure your key is authorized on the host. |
| **hostkey** | reached, host key not trusted yet | accept it once (`ssh <host>` interactively, or add `StrictHostKeyChecking accept-new` to the host's ssh-config block). |
| **unreach** | no answer within the timeout | check the host is up and on the tailnet/LAN, that `sshd` is running, and the address is right; raise `-t` if the link is slow. |

**`DRIVE`** — what overseer can actually do once `SSH=ok`:

| Value | Means | Fix |
|---|---|---|
| **yes** | Linux with `tmux`+`jq` — fully driveable (shell + agents) | — |
| **no:tmux** / **no:jq** | Linux missing a base dependency | **`overseer provision <host>`** installs them (needs root/passwordless sudo); then re-survey. |
| **win\*** | a reachable Windows host | drive it with `win <host> <verb>` (start/chat/…); needs an **admin** login, a **logged-in console user**, and the broker prerequisites in [docs/WINDOWS.md](docs/WINDOWS.md). |
| **no:macos** | a Mac | not a controller (see [docs/PORTING.md](docs/PORTING.md)); not a tmux drive target. |
| **-** | `SSH` wasn't `ok` | fix the `SSH` column first. |

So the usual loop is: `hosts` → see a `no:tmux`/`no:jq` → `provision <host>` → `hosts` again. `provision`
only handles the Linux base deps; Claude/Codex agents and every Windows prerequisite are still installed
by hand (agents vary too much per host to script safely).

## How it works

- **Delivery** is one atomic **bracketed paste**, verified before submit — uniform for one line, many
  lines, or a line wider than the pane, and a ghost autocomplete can never interleave. A Claude message
  whose first char is `/ ! # @` gets one leading space (Claude trims it back off) so it stays literal;
  for Codex a message starting with `!` is **refused** — Codex runs `!…` as a shell command by design,
  so use `sh <target> '<cmd>'` (or reword) — and an `@`-mention token can pop its file picker (`peek` +
  `keys` to recover).
- **Turn completion** (`chat`/`wait`) comes from the transcript, never the on-screen spinner (a
  finished turn leaves a stale spinner line): for Claude, an assistant message whose `stop_reason`
  isn't `tool_use`; for Codex, a `task_complete` event in the rollout jsonl.
- **Blocked on a prompt** is detected from the screen: if the agent stops at a permission / plan /
  select prompt (a cursor `❯`/`›` on a line of **two or more** numbered options), `chat`/`wait` return
  its question + options rather than hanging to timeout — you answer with `keys`/`menu` (pick) or `send`
  (free-text). The detector first cancels tmux copy-mode, so a pane you scrolled up still reports its
  live state. A single-option or unnumbered y/n prompt is **not** matched — see the limits below.
- **Agent exits mid-turn** (a crash, a `quit`, or the pane being killed): `chat`/`wait` notice the pane
  is no longer running an agent and fail fast with a clear message, instead of waiting out the whole
  timeout for a reply that will never come. (A hung-but-alive turn is still bounded by the timeout.)
- **Concurrent invocations are serialized per pane.** Every command that types into a pane
  (`send`/`chat`/`sh`/`quit`/`slash`/`menu`) takes a `flock` on that pane first, so two overseer runs
  can't interleave keystrokes into the same box; the lock is released before the reply wait, so a long
  `chat` doesn't block a `read`. Where `flock` is missing it proceeds unlocked; if `flock` is present
  but the lock is still held after 30s it aborts with an error rather than risk interleaving keystrokes.
- **Harness detection** is by pane process: a Claude pane owns `~/.claude/sessions/<pid>.json`; a Codex
  pane has a descendant process named `codex` (so a 0-turn Codex is detected before it opens a rollout).
  Codex's transcript is the `~/.codex/sessions/**/rollout-*.jsonl` the process holds open, read straight
  off `/proc/<pid>/fd`. Note `list` and `fleet` additionally pre-filter panes on their foreground command
  (`claude`/`node`) for speed, so an agent launched under some other wrapper can be missing from those
  listings while still being fully drivable by its `%N`.
- **`sh` completion** is a pair of unique sentinel lines bracketing the command — prompt-agnostic, no
  `PS1` assumption, and the leading sentinel keeps the shell's own echo of the command out of the
  output. Pagers are neutralized and stdin is `/dev/null`, so `git log`/`man`/`cat` won't hang. If the
  output was long enough that the *opening* sentinel scrolled out of the pane's history, `sh` says so
  and prints the exit code without the (unreconstructable) output — re-run redirecting to a file.

### Event mode (bundled)

The plugin ships three hooks (one shared script, `hooks/turn-done.sh`) so overseer wakes on events
instead of polling: `Stop` touches `~/.claude/turn-done/<session_id>` (turn ended → `chat`/`wait` wake
in ~0.25s not ~2s), `UserPromptSubmit` touches `turn-started/<session_id>` (so a `send` confirms the
turn started with no sub-second race), and `Notification` touches `awaiting/<session_id>` (so `chat`/`wait`
surface a permission/menu prompt the moment it appears). They are wired **automatically** on install — no
`settings.json` editing. Every signal is only an accelerator: the transcript stays the source of truth
(an answer is never read half-written) and the on-screen prompt stays the arbiter for awaiting, so a
session the hooks do not cover — or a Codex pane, which has none — just falls back to polling, never
worse. The fast path assumes the driven Claude session shares overseer's `~/.claude` (`CLAUDE_HOME`);
one running as another user, under a custom `CLAUDE_HOME`, or started before the plugin was installed
simply polls (~2s slower), never blocked.

### Getting told instead of polling

Every other way of learning that a worker finished is something the **dispatcher has to choose to do**:
`chat` blocks its own turn on the reply, `wait`/`fleet wait --any` block on the worker's. That is fine
for a short round-trip and wrong for a long one — a dispatching agent that ends its turn goes idle, and
an idle agent has no inbound channel: nothing can tell it anything until a human types. Fire off a
`send` and the result is simply never collected.

`send --notify` inverts that. It does the normal `send`, then arms a **detached watcher** —
`wait` on the worker, then `send` back into the tmux pane the dispatch was run from (`$TMUX_PANE`,
which is why `--notify` refuses to run outside tmux and refuses to target its own pane):

```
overseer send --notify %5 'run the full test suite and report failures' 3600
# -> notify: watching %5; %227 will be woken when its turn ends (or after 3600s)
#    the dispatcher returns immediately and can end its turn
```

The wake-up is a **doorbell, not a mailbox**. An agent holds only one queued message, so a second
worker finishing while the dispatcher is mid-turn has its notice refused — therefore the text quotes
what `wait` reported and then tells the woken agent to survey the whole fleet (`fleet status`, then
`read` each idle/awaiting pane) rather than act on the one pane that rang. A dropped duplicate costs
nothing, because the survey finds it anyway.

The watcher inherits `wait`'s answers: a finished turn, the **question** if the worker stopped at a
permission/menu prompt, or the error if it died mid-turn — so being blocked on a prompt wakes the
dispatcher just like finishing does. It is bounded by `[notify_timeout]` (default `OVERSEER_TIMEOUT`)
and wakes with that fact rather than disappearing silently. `fleet send --notify <msg>` arms one per
receiving pane. Local only: the pane to wake exists on this machine, so `--hosts`/`--tailscale` refuse
the flag.

### Context is not a health signal

A watching agent reliably raises the wrong alarm here, so overseer separates the two numbers by
design:

- **Context filling up is routine.** Both harnesses auto-compact, so a session at 95% context keeps
  working — it summarises and carries on. `usage` prints context labelled *informational, never a
  fault*; it is never a `fleet status` state and never triggers a warning.
- **Account quota is what actually stops work.** When a usage window reaches 100% the API stops
  answering, and no amount of waiting inside the turn helps until it resets. That is the number worth
  watching, and the one `usage` flags at `OVERSEER_QUOTA_WARN` (default 90%).

When a turn *is* killed by a usage limit, overseer says so instead of handing the error back as an
answer. Claude records the refusal as an ordinary terminal assistant message, so the naive read — the
one overseer used to do — returns `API Error: …` as if the agent had replied it. `chat`/`wait` now
detect that record and fail with **exit code 5** and the reset time; `read` marks it `(NO REPLY — the
turn ended in an API error)`; `fleet status` shows the pane as `api-error` rather than `idle`. A
transient server error (a 529 overload) is separated out and exits 1, because that one *is* worth
resending. Codex has no such record — it simply completes the turn with an empty reply — so the same
verdict comes from its rollout's `rate_limits.rate_limit_reached_type`.

Claude's quota is read **live from the same endpoint `/usage` uses** — `GET
https://api.anthropic.com/api/oauth/usage`, authenticated with the OAuth access token already sitting
in `$CLAUDE_HOME/.credentials.json`. Nothing is installed, no Claude setting is written, and it works
from any directory and over `on <host> usage`. The response carries every window the account has
(session, weekly, and per-model weekly) with a server-computed `severity`, which overseer trusts
ahead of its own threshold.

Three consequences worth knowing:

- **overseer reads your Claude credentials file.** The token goes only to `api.anthropic.com`, is
  passed to `curl` over stdin rather than argv (so it never shows up in `ps`), and is never logged or
  cached — see [SECURITY.md](SECURITY.md).
- **overseer cannot refresh an expired token.** Claude Code rotates it roughly hourly; if it has
  expired, `usage` says so and the fix is to run any Claude session once.
- **The endpoint is undocumented**, like the on-disk layouts overseer already depends on, so `doctor`
  probes it and reports rather than assuming.

Codex needs none of this: it writes `rate_limits` into every rollout already.

## Caveats

- **The controller is Linux only** (`/proc`), and so is direct pane discovery. Remote Windows consoles
  are drivable as *targets* (`win <host> <verb>`), but overseer never runs on Windows.
- **Depends on each agent's internal on-disk layout** — Claude (`~/.claude/sessions/*.json`,
  `~/.claude/projects/*/*.jsonl`) and Codex (`~/.codex/sessions/**/rollout-*.jsonl`) — undocumented and
  may change between releases. If a release breaks discovery, open an issue.
- The target program must run **inside tmux**.
- **overseer never drives the pane it is running in.** `send chat keys sh slash menu wait quit stop
  unsend interrupt` all refuse `$TMUX_PANE` (compared against the *resolved* pane, so a session name
  cannot slip past), and `fleet` skips it with a printed note instead of failing on it. Read-only
  commands (`list`, `read`, `peek`, `fleet status`, `fleet read`) still include it. Every refused case is
  guaranteed broken, not merely odd: a message pasted into your own composer wipes what was half-typed
  there and then queues behind the turn that pasted it, `wait` on yourself can only end after it returns,
  and `fleet interrupt` would otherwise stop the dispatcher itself.
- **A keystroke is not a peer message, and `--as-user` deliberately erases the difference.** Typing into
  a Claude pane is recorded on the far side as `origin.kind=human` — indistinguishable from its own user
  at the keyboard — so `chat`/`send` **refuse** a target that has a **PEER** name and point at the
  `SendMessage` tool, which the receiver records as an authenticated peer message. `--force-keys` takes
  the keyboard anyway and prefixes the message with the sender's PEER name, that it comes from an agent
  rather than the user, and how to reply; that prefix is a convention, not proof. **`--as-user`** implies
  `--force-keys` and drops the prefix, so the worker reads the message as its own user typing it and acts
  without stopping to confirm — which is the point when the user has delegated a dispatch ("send this as
  me") and does not want to re-approve it in every worker, and is why it is scoped to that case rather
  than to any message an agent finds inconvenient to get accepted. A target reached through `on <host>`
  is never refused at all: the peer socket lives under the caller's own user on the caller's own machine,
  so it cannot cross to another host and the keyboard is the only path there.
- **Awaiting-input detection covers numbered menus** — a cursor (`❯`/`›`) on **one** of **two or more**
  numbered options, which is how Claude and Codex render permission/approval and most select prompts.
  The cursor must sit on exactly *some* of the options, not all: a real menu marks only the selected
  row, so a block where every numbered line is prefixed (a markdown blockquote of a list) is rejected
  as prose. The ASCII `>` cursor is accepted **only** on the Windows broker path, where Claude Code
  draws it that way; on Linux `>` is always prose. Two shapes are therefore not auto-detected. A prompt
  with a *single* numbered option, or a bare y/n prompt with no
  numbering at all, falls below the two-option floor that keeps the detector off ordinary prose. And a
  *searchable* picker that drops the numbers (e.g. a type-to-filter list, or Codex's `@`-mention list) is
  **intentionally** excluded: those are input-box UI you open by typing (`@`, a slash command), not a state a
  turn ends in, and their chrome (a leading `>`/`›`, an "esc to cancel" footer) overlaps a normal reply's
  markdown, so auto-detecting them would risk false-positives on real answers. In both cases `chat`/`wait`
  run to timeout instead of returning early — `peek` the pane and drive it with `keys`.
- **`overseer doctor` self-checks** the awaiting detector against a sample menu (catches a broken UTF-8
  locale); **`overseer doctor --live`** additionally spins up a throwaway pane and runs a `sh` round-trip
  through it, verifying the send-keys/capture-pane path end to end.

## Compatibility

Last verified live against **Claude Code 2.1.217** and **Codex 0.144.6**. Because overseer reads each
agent's internal on-disk layout (above), an upstream update *could* change that layout and break
discovery. Rather than pin exact versions, `overseer doctor` prints the running versions and then
*probes the contract directly*: it runs overseer's own transcript readers against the newest on-disk
session and warns only when a session that has completed turns can't be read — a real schema shift, not
a version-number bump. Run it after an update, and if it warns, open an issue with its output. There is
no plugin manifest field to pin an agent version, so compatibility is tracked here + in `doctor`, not
enforced — the plugin never hard-blocks on version.

## Troubleshooting

Run the preflight first:

```
overseer doctor        # or: bash "$CLAUDE_PLUGIN_ROOT/skills/overseer/scripts/overseer" doctor
```

- **"no agent pane (claude/codex) for target"** → the pane isn't running Claude Code or Codex, or you
  targeted the wrong one. `overseer list --all` shows every pane and its command; target a specific
  pane by its `%N`.
- **`doctor` warns about `~/.claude/sessions/*.json`** → either no Claude session is running, or a
  Claude Code update changed its on-disk layout (which breaks discovery). Open an issue with the
  `doctor` output and your `claude --version`.
- **Nothing gets driven** → the target must run **inside tmux** (a plain terminal can't be driven), and
  you must run overseer from **outside** that pane's tmux client.

## Uninstall

```
/plugin uninstall overseer@sgbl
```

## Development

Clone and add as a **local marketplace**:

```
git clone https://github.com/saigonbaddielover/sgbl-overseer
/plugin marketplace add ./sgbl-overseer
/plugin install overseer@sgbl
```

Validate locally (CI can't run `claude plugin validate` — the CLI isn't on the runner):

```
claude plugin validate --strict ./overseer
bash tests/run.sh
```

Releasing is automatic: bump the version in **both** manifests, land the PR, and the `autotag` workflow
tags `overseer--v<version>` on `main` and publishes the GitHub Release. On a **pull request** CI fails a
version bump that arrives without a matching `CHANGELOG.md` heading (the check compares against the base
branch, so it only runs there).

See [CONTRIBUTING.md](CONTRIBUTING.md) for the branch → PR → merge flow (`main` is protected). Design
notes: [why overseer stays one bash program](docs/DECISIONS.md) · [driving a remote Windows
console](docs/WINDOWS.md) · [porting beyond Linux](docs/PORTING.md).

### Useful Claude Code commands

- `/reload-plugins` — apply an overseer update or a local `hooks/`/skill edit in the current session, no restart.
- `/reload-skills` — pick up a `SKILL.md` text edit on disk.
- `/hooks` — confirm the bundled `Stop` hook (`turn-done.sh`) is wired.
- `/plugin` — enable / disable / inspect / update overseer interactively.
- `/release-notes` — see what changed when Claude Code itself updates (the upstream this reads).

## License

[MIT](LICENSE) © saigonbaddielover
