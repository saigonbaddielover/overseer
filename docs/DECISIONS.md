# Decision records

## ADR-0001 — Stay a single bash program; do not rewrite in a compiled/scripting language

**Status:** Accepted (2026-07-20). Revisit on the triggers below.

### Context

overseer is one bash program (`scripts/overseer` + the sourced `lib/*.sh`) that
drives and reads another live agent in a tmux pane. During the optimization audit the question was
raised directly: is bash the right implementation, or should this be rewritten in Rust / Go / Python?

What the tool actually does: shell out to `tmux` (`send-keys`, `capture-pane`, `display-message`,
`load-buffer`/`paste-buffer`), read a few JSON transcripts with `jq`, read `/proc`, and poll with
`sleep`. It is **I/O orchestration of external processes**, not computation. There is no hot loop, no
data structure heavier than a list of panes, no algorithm more complex than "poll a file until a marker
appears."

### Options considered

1. **Keep bash (chosen).** Zero build, single file the user already trusts, `tmux`/`jq`/`/proc` are all
   shell-native. Distribution is "copy the script"; the Claude Code plugin ships it verbatim.
2. **Rewrite in Rust or Go.** Buys static typing, real error handling, and a single binary. But every
   operation is still `Command::new("tmux")…` — the binary would be a thin shell-out wrapper around the
   exact same commands, trading the shell's native ergonomics for subprocess plumbing. Adds a
   compile/CI/release toolchain and per-platform binaries to a plugin that today needs none.
3. **Rewrite in Python.** Better string handling and `subprocess`, still interpreted. Adds an interpreter
   dependency and a packaging story (venv/pip) heavier than the current `jq`-only requirement, for a
   program whose logic is 90% invoking `tmux`.

### Decision

Keep the single bash program. The cost/benefit does not favor a rewrite:

- **The work is shelling out.** The dominant operations are tmux commands and `jq` reads; a rewrite
  reimplements the orchestration in another language while still driving tmux as a subprocess. The core
  contracts (transcript JSON shape, screen rendering) live *outside* the language choice.
- **Distribution is simpler as source.** A Claude Code plugin ships files; a script needs no build, no
  release binaries, no per-arch artifacts. `doctor` is the only preflight.
- **The audit closed the real gaps in bash.** Turn detection, event-mode wakes, streaming readers,
  incremental byte-offset scans, the paste/verify/submit path, per-pane locking, and a portability seam
  were all achievable and *live-verified* in bash. The problems were correctness and TUI edge cases, not
  language limits.
- **Testability is adequate.** The pure parsers (turn/busy/reply/prompt/awaiting/shell) are factored out
  and covered by fixture tests in CI; the rest is inherently live-verified against a real tmux pane, which
  a rewrite would not change.
- **`set -eu` discipline + shellcheck + `-x` cross-file linting** catch the classic shell footguns, and
  the code stays within a strict style (self-documenting, no prose comments, size limits).

### Consequences

- Portability is manual: Linux-isms (`/proc`, GNU `stat`/`date`) must be bridged by hand. Mitigated by
  the OS seam and [PORTING.md](PORTING.md), which turn "port it" into a bounded task.
- No compile-time type checking; correctness rests on shellcheck + fixture tests + live verification.
- Large refactors are riskier in shell than in a typed language — accepted, given the small size and the
  test/lint safety net.

### Revisit this decision if

- ~~**Windows support** is wanted (no POSIX shell, no `/proc`, no tmux) — that is a different tool, and a
  rewrite would be the honest path.~~ **This trigger fired in v0.8.0 and did not require a rewrite.**
  Windows is driven as a *remote* target over plain SSH: a PowerShell broker runs on the Windows console
  and speaks a line protocol, while every decision (turn detection, awaiting detection, delivery
  guards) stays in the same bash + jq seam. See [WINDOWS.md](WINDOWS.md). The lesson generalises —
  a non-POSIX target needs a small native agent, not a new language for overseer itself.
- The tool grows **persistent state or a real API** (a daemon, concurrent multi-pane scheduling, a
  network protocol) — orchestration logic heavy enough that a typed language's error handling and data
  structures start to earn their keep.
- A **third+ harness** and the branching it brings make the `_h_*` dispatch seams unwieldy in shell.
- Startup/parse latency ever becomes user-visible (it is not today: each command is a handful of tmux
  calls plus one `jq` pass).

Until one of those holds, the simplest thing that fully works is the single bash program.

## ADR-0002 — Ship as a Claude Code **Skill + hooks** inside a plugin; not an MCP server, not a subagent

**Status:** Accepted (2026-07-21).

### Context

overseer is packaged as a single-skill plugin: `SKILL.md` (procedure + command table), the bash program
under `skills/overseer/scripts/`, and three session hooks. The question raised: is a skill the right
Claude Code extension surface, or should this be "upgraded" to an MCP server or a dedicated subagent?

The product here is not only the executable — the script runs fine from a terminal with no Claude at
all. The product is the **procedure knowledge**: which commands mutate state, that a running Codex turn
is interrupted with `Escape` and never `Ctrl-C`, that `menu` needs `Down` for a vertical popup, that
`win <host> sh` aimed at an agent broker would type the command into a chat box. That knowledge has to
reach the model at the moment it drives a pane, and nowhere else.

### Options considered

1. **Skill + hooks (chosen).** `SKILL.md` is read only when the task is relevant, so the whole command
   surface costs nothing on unrelated turns. The hooks are pure accelerators — three per-session mtime
   markers; a session without them falls back to polling, so nothing breaks when they are absent.
2. **MCP server.** Tool schemas are context-resident on *every* request, so the whole surface would be paid
   for continuously whether or not any pane is being driven. It also implies a long-lived server, while
   every overseer command is one-shot and stateless — state lives in tmux, `/proc` and the transcripts,
   which is precisely why the tool needs no store of its own. Rejected.
3. **Dedicated subagent.** A subagent is an isolated context, not a capability: it would still shell out
   to this same script, while paying a fresh context each spawn. Worth revisiting only if `fleet` across
   many hosts floods the main context — as a thin layer *over* the skill, never a replacement for it.
4. **Slash commands.** Complementary, not an alternative: cheap to add for muscle memory, but they
   deliver no procedure knowledge to the model.

### Consequences

- `SKILL.md` is loaded whole on activation, so its size is a running cost — tens of KB, and it has only
  grown (check with `wc -c` rather than trusting a number written here). When it grows past comfortable,
  split the per-harness quirk tables into a reference file the skill points at, rather than letting the
  entry document sprawl.
- Distribution rides the plugin marketplace: version bumps must stay in lockstep across
  `plugin.json` and `marketplace.json`, which CI enforces.

### Revisit this decision if

- Another tool (not Claude Code) needs to call overseer programmatically — an MCP surface would then buy
  interoperability the skill cannot.
- The tool grows genuinely long-lived state that must outlive a single command.

## ADR-0003 — Linux `start`/`stop`: overseer creates and destroys its own tmux sessions

**Status:** Accepted (2026-07-22).

### Context

overseer began **attach-only** on Linux — it drove panes someone else opened, and the docs said it
"never opens a pane." The Windows side always had a lifecycle (`winbroker` creates a broker, `winstop`
destroys it) because a plain-SSH Windows host has no pane to find. That asymmetry meant a throwaway
Linux session had to be hand-created before overseer could drive it, with no teardown — awkward for the
tailnet create/reuse/destroy use-case. v0.17.0 closes the gap.

### Options considered

1. **Detached session (chosen).** `start <name>` runs `tmux new-session -d`; the user attaches to
   watch. Behaves identically local and via `on`, and stays one-shot/stateless — the session lives in
   tmux, not in overseer.
2. **New window inside an already-attached session** (visible immediately). Rejected as the default: it
   needs a pre-existing attached session and doesn't translate to remote `on`, where there is usually
   no session to inject into.
3. **Do nothing / keep attach-only.** Rejected: leaves Linux behind Windows for the lifecycle the
   tailnet use-case wants.

Naming: `stop` is the peer of the existing `winstop` (matching `winpeek↔peek`, `winsh↔sh`); `start`
fills `winbroker`'s create role. Not `spawn`/`kill`, to keep the `win*` symmetry.

### Consequences

- Still stateless/one-shot (ADR-0002 holds): no new store — the session is tmux state.
- `start <name> claude|codex` rides the `/proc` discovery seam (`_harness_of`) for readiness, so it is
  Linux-only like the rest; `start <name> shell` and `stop` are pure tmux (see `docs/PORTING.md`).
- `stop` refuses to kill the session (or `%N` pane) overseer runs in; the guard is inert under `on`.

### Revisit this decision if

- A use-case needs overseer to manage sessions with richer lifecycle (persistence, reconnection,
  supervision) — that would push state out of tmux and reopen ADR-0002.

## ADR-0004 — Unifying the Windows surface under `win <host>[/name] <verb>`

**Status:** Accepted (2026-07-22). Supersedes the naming note in ADR-0003.

### Context

The Windows commands were ten fused names — `winbroker`, `winchat`, `winstop`, … — a vocabulary
parallel to but disjoint from the Linux verbs (`start`, `chat`, `stop`, …). A user had to learn two
spellings for one concept (`start` vs `winbroker`, `chat` vs `winchat`), and every new Windows
capability meant a new top-level command. The goal: **one verb vocabulary across both OSes.**

### Options considered

1. **`win` as a transport prefix (chosen).** `win <host>[/name] <verb>` — exactly symmetric with the
   existing `on <host> <verb>` for remote Linux. `winbroker`→`win … start`, `winchat`→`win … chat`, and
   so on; `winshow`→`win … show` (a Windows-only verb with no Linux peer). The verb set is now shared,
   so adding a Windows capability that already exists on Linux (`send`/`slash`/`menu`/`quit`) is a
   one-line dispatcher entry rather than a new command.
2. **Auto-route from the target, no prefix** (`overseer chat <winhost>` figures out it is Windows).
   Rejected: a bare target is ambiguously a local tmux session or a remote host, and distinguishing them
   needs per-host OS state (config tag or a live probe on every call) — which breaks the stateless design
   (ADR-0002) that `hosts` deliberately preserves.
3. **Keep `win*`, add aliases.** Rejected: that is *two* names per concept, the opposite of the ask, and
   doubles the command-surface parity surface.

### Consequences

- **Breaking rename, no back-compat aliases** — overseer is 0.x with a single user, so "one name only"
  wins over migration smoothness. A one-line note in `README.md`/`SKILL.md` records the old→new mapping.
- The command-surface parity gate now sees `win` as one command; a **new tripwire** in `tests/run.sh`
  asserts the `cmd_win` dispatcher's verb set matches the `win verbs:` line in `--help`, so a verb can't
  drift undocumented (the role the old per-command rows played).
- Windows verb docs use **bold** names (`**start**`) in a sub-table, so the parity regex does not mistake
  them for top-level commands — the same convention the `hosts` remediation tables use.
- ADR-0003's "keep the `win*` symmetry" naming note is moot: the verbs are now literally shared, not
  mirrored.

## ADR-0005 — Push completion back to the dispatcher with a detached watcher, not a daemon or a hook

**Status:** Accepted (2026-07-26).

### Context

Every mechanism overseer had for learning that a worker finished is **pull**: `chat` blocks the
dispatcher's turn on the reply, `wait` and `fleet wait --any` block it on the worker. That works for a
short round-trip and fails for a long one — and not because an agent "forgets to look". A Claude Code
session has **no inbound channel**: the only way in is keystrokes into its pane. Once the dispatching
agent's turn ends it is unreachable until a human types, so a `send` for a long job is never collected
and the user is left believing someone is watching. The ask was to invert this: the worker should cause
the dispatcher to be told.

### Options considered

1. **Detached watcher armed by `send --notify` (chosen).** `setsid` a child that runs `wait <worker>`
   and then `send <dispatcher-pane>`. Pure composition of two existing commands; the dispatcher's pane
   comes free from `$TMUX_PANE`.
2. **A `Stop` hook on the worker that notifies.** Event-driven with no poll, but Claude-only (Codex has
   no hooks), and it needs a "return address" persisted per worker session — new on-disk state that
   ADR-0002 names as a trigger to revisit the whole packaging decision.
3. **A supervisor daemon** tracking dispatches and fanning out notifications. Rejected outright: a
   long-lived process and a state store, in a tool whose entire design is one-shot and stateless
   (ADR-0001/0002).
4. **Block the dispatcher's own `Stop` hook** while any dispatched worker is in flight, forcing it to
   keep waiting. Unforgettable by construction, but it holds the user's session hostage for the whole
   job — the opposite of "go idle and be woken", which is what was actually wanted.

### Decision

Option 1. The watcher is not a daemon: it is one short-lived process per dispatch, bounded by
`[notify_timeout]`, that exits after a single wake-up. It adds **no state, no protocol, and no hook** —
and because it drives `wait`, it inherits everything `wait` already knows: the `Stop`-hook accelerator
where present, the awaiting-prompt and died-mid-turn results, and Codex support that a hook-based design
could not have.

### Consequences

- The wake-up is a **doorbell, not a mailbox**. An agent holds one queued message, so a second worker
  finishing while the dispatcher is busy has its notice refused. The text therefore carries an
  instruction to survey the whole fleet rather than the payload of one pane, which makes a dropped
  duplicate harmless. This is a deliberate reliability trade, not an oversight.
- **A stale `idle` cannot be trusted.** A freshly `start`ed worker has no transcript for its first
  seconds, and a turn whose start `send` could not confirm inside its 10s budget also reads idle — both
  made a naive watcher fire immediately (found in live testing, not by the unit tests). The watcher
  re-waits through "no transcript yet", and when the start was unconfirmed it re-waits through a 30s
  startup grace before believing `idle`; a confirmed start skips the grace entirely.
- Delivery clears the target's input box, so a wake-up destroys anything half-typed in the dispatcher's
  pane. Accepted: that pane belongs to the driving agent, and the user types to the dispatcher only
  while it is idle.
- Local only. The pane to wake is identified by `$TMUX_PANE` on this machine, so the flag is refused
  outside tmux, refused when it would wake its own target, and refused on the `--hosts`/`--tailscale`
  fan-out.
- Each wake-up costs a real turn in the dispatcher's session — the price of push, and the reason the
  flag is opt-in per dispatch rather than the default for `send`.

### Revisit this decision if

- Dispatch volume makes one watcher process per job wasteful (a single multiplexing watcher would then
  be worth its state).
- Claude Code grows a real inbound channel (an API, a "resume with this message" primitive), which would
  make the keystroke round-trip unnecessary.
