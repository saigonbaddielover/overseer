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

## ADR-0006 — The screen may veto a "running" transcript, never assert one

**Status:** Accepted (2026-07-26); the veto's *evidence* is superseded by ADR-0007 (2026-07-26). The
rule below — screen downgrades only, never upgrades — still holds; what changed is that "a live
spinner" turned out to be the wrong thing to look for.

### Context

`fleet status` decided busy/idle from `_h_is_busy`, which for Claude means "the last assistant message
stopped at `tool_use`". A turn that answers without calling a tool emits no `tool_use`, so a worker
writing a long text-only reply read `idle` while still generating — which made `fleet wait --any`
exclude it from the in-flight set and let a broadcast queue onto live work.

The obvious fix is `_h_running` (the predicate `wait` already uses: a human prompt with no terminal
assistant message after it). Live testing showed why it is not enough on its own: when a turn is
**interrupted** with Escape, Claude writes *nothing* — no terminal assistant message, no interrupt
record — so the transcript of an interrupted turn is byte-for-byte the same shape as one still in
flight. `_h_running` alone therefore pins an Escaped pane at `busy` permanently, which is worse than the
original bug: it is sticky, and a broadcast would skip that pane forever. The bundled `Stop` hook does
not fire on an interrupt either (verified: the marker mtime never advanced), so no transcript- or
hook-based signal separates the two states.

### Decision

Busy = `_h_is_busy` **or** (`_h_running` **and** the screen shows a live spinner), via `_agent_busy`.
The screen is used strictly as a **veto**: it can only downgrade a transcript that already claims
running, never upgrade an idle transcript to busy.

That is what keeps this consistent with the project's standing rule that a finished turn leaves a stale
`Brewed for Ns` line, so the spinner must never be trusted to judge **completion**. Nothing here judges
completion — the transcript still does. The screen only breaks a tie the transcript cannot express, the
same way `_awaiting` and `_compacting` (already screen-based) answer questions the transcript does not
record.

### Consequences

- `_thinking_text` is a pure function over captured text, fixture-tested against real captures of all
  three states (in-flight, completed, interrupted) plus the stale `Brewed for` line and a wrapped prose
  line ending in an ellipsis.
- The failure modes are **bounded by the two options it sits between**: a missed spinner degrades to the
  old `_h_is_busy` behaviour for that pane, and a spurious match degrades to plain `_h_running`. Neither
  is worse than shipping either predicate alone.
- One extra `capture-pane` per pane, and only when the transcript says running but no tool is in flight.
- `cmd_wait` used bare `_h_running`, so `wait` on a pane whose turn was interrupted blocked until its
  timeout. Deferred in 0.35.0 and **closed in 0.36.0** by putting the same veto inside `_wait_drained`,
  debounced: the screen is sampled on the loop's existing every-8th-iteration cadence and four
  *consecutive* spinner-free samples (~8s) are required before the turn is called drained. `wait` returns
  early only on sustained silence, so a momentary render gap cannot cut a live turn short.

### Revisit this decision if

- Claude Code starts recording an interrupt in the transcript (or fires `Stop` on one), which would make
  the screen check unnecessary.
- The spinner's rendering changes enough that `_thinking_text` needs more than a fixture refresh — that
  is the tripwire the fixtures exist for.

## ADR-0007 — Liveness is screen *movement*, not the spinner

**Status:** Accepted (2026-07-26). Supersedes the evidence ADR-0006 used, not its rule.

### Context

ADR-0006 read "is a turn in flight?" off the spinner line. Driving a real Claude pane through long
turns showed that premise is false twice over.

**The spinner is not drawn for the whole turn.** Once Claude starts rendering the assistant's final
text, the status row disappears and only the streaming prose is on screen. A 181s turn showed a
spinner for its first ~87s and none for the remaining ~94s while it was still writing. `wait` and
`chat` both called that turn interrupted and returned mid-reply.

**The spinner's elapsed field is not one format.** It reads `(47s · thinking)` under a minute and
`(1m 5s · thinking)` over one, so `_thinking_text`'s `\([0-9]+s` went blind on every turn that crossed
60 seconds — the exact turns long enough for anyone to run `wait` on.

Both were invisible to the earlier live checks because `tmux send-keys Escape` does **not** interrupt
Claude Code (verified: five Escapes over a running turn changed nothing), so the "interrupted" pane
those checks measured was in fact a still-running one past the 60s formatting cliff. `Ctrl-C` does
interrupt, and that is what the state was finally reproduced with: no terminal assistant record, no
`turn_duration`, no `Stop` marker — the transcript stays "running" forever, exactly as ADR-0006 said.

### Decision

Keep the veto, change what it looks at. `_screen_state <pane>` returns either `busy` (a spinner or a
queued-message hint is on screen) or a checksum of the pane **above the input box** — the cursor row
locates the box, so the always-ticking custom statusline underneath it is excluded.

A turn is called interrupted only when that value is **not `busy` and byte-identical to the previous
sample**, four consecutive times on the loop's existing every-8th-iteration cadence. Movement is the
signal: a thinking turn moves its spinner, a streaming turn moves its text, an interrupted turn moves
nothing. `_agent_busy` (`fleet status`) uses the same evidence with a two-sample check, since it has no
poll loop to debounce over.

### Consequences

- `chat` gains rc=4 from `_wait_reply`/`_wait_queued_reply`: the turn stopped with no reply to print,
  which is neither the timeout (rc=1) nor a dead pane (rc=3), so it needs its own exit and message.
- The veto stays Claude-only. Codex records `turn_aborted` in its rollout, so `_cx_is_busy` already
  reads an aborted turn as idle and has no reason to consult the screen.
- The failure mode is now bounded by movement rather than by a string: a spinner-format change costs a
  slower veto, not a false one, because streamed text keeps the checksum moving. A false "interrupted"
  needs a pane that is byte-frozen for ~8s while genuinely working.
- Cost is one `capture-pane` plus one `display-message` every ~2s, replacing the previous capture.

### Revisit this decision if

- A turn can render nothing at all for ~8s while alive (a long silent tool with the status row hidden
  would do it) — then the debounce, not the evidence, is what needs raising. Measured on 2026-07-27
  against a ~75s foreground CPU-bound Bash call: the spinner stayed up for **every** sample, so the
  status row is only dropped while streaming *text*, and the veto cannot fire during a tool.
- Claude Code starts recording interrupts, which retires the whole screen path.

### Applied to the Windows path (0.37.1)

`win wait` and the `win chat`/`send` mid-turn guard carried the pre-0.35.0 `_h_is_busy` and so had the
same text-only blind spot. They now use the same shape — `_win_agent_busy` and a debounced veto inside
`_win_wait_turn` — over the broker's `SNAP` grid. Two deliberate differences:

- **The whole grid is hashed.** `SNAP` reports characters, not a cursor position, so there is no way to
  locate the input box and exclude what sits below it. A console with a ticking element therefore always
  looks like it is moving and the veto never fires — degrading to the pre-0.36.0 blocking behaviour,
  never to a false idle. That is the right direction to fail in.
- **Samples are ssh round trips**, so the veto samples on the loop's every-8th iteration (~4s) rather
  than Linux's ~2s, and `_win_agent_busy` caps at four extra snapshots.

Live-verified against a real Windows broker. A 1200-word text-only turn ran with **no status row at the
bottom of the console at any point** — the same blind spot measured on Linux — and `win wait` reported
`still running` throughout, then `idle` at the end while `win chat` returned the full reply. Interrupting
a second turn mid-stream with `win <host> keys C-c` froze the grid; `win wait` reported `idle` at once and
the in-flight `win chat` returned the "stopped without producing a reply" error **60–90s** later, bounded
by the round-trip sampling rather than by `[timeout]`. The idle grid on that host hashed identically
across repeated snapshots, so the ticking-element caveat above did not apply to it.

### Codex needs none of this (0.37.2)

The screen veto exists only because an interrupted Claude turn leaves **no trace in the transcript**.
Codex records `turn_aborted`, which is a fact rather than a heuristic — so the waiters take a direct
route for it: a turn they have already observed running that stops running without advancing the turn
count returns the same rc=4. No sampling, no debounce, no screen. The "already observed running" latch
is what keeps the window between delivery and the first record from reading as an abort. This closes the
matching hang — `wait` said `idle` while `chat` polled for a `task_complete` that an aborted turn never
writes, measured at the full 300s timeout — on both the Linux and Windows paths.

## ADR-0008 — Report **account quota**, not context; a quota-killed turn is an error, never a reply

Two "the agent is running out of something" signals look alike from outside and are not alike at all.
A watching agent that treats them the same raises a false alarm on the harmless one and misses the
real one.

**Context is not a health signal.** Both harnesses auto-compact, so a session at 95% context keeps
working — it summarises and continues. `overseer usage` therefore prints context labelled
*informational, never a fault*, it is not a `fleet status` state, and it never raises a warning.

**Account quota is the one that stops work.** At 100% of a usage window the API stops answering and
nothing inside the turn helps until it resets. `usage` flags a window at `OVERSEER_QUOTA_WARN`
(default 90%), and `chat`/`send`/`wait` print a one-line stderr warning past that threshold.

### The turn that dies on quota

Claude records the refusal as an ordinary **terminal assistant message** —
`isApiErrorMessage: true`, `apiErrorStatus`, `model: "<synthetic>"`, `stop_reason: "stop_sequence"`,
with the error text in a normal text block. Every reader keyed on "stop_reason present and not
tool_use" therefore counts it as a completed turn and hands `API Error: …` back **as the answer**.
That is what overseer did before 0.38.0.

The fix is a fourth reader on the harness seam, `_h_last_error`. When the record that ended the last
turn is an API error, `chat`/`wait` fail with the error instead of printing it as a reply — **exit
code 5** for a usage limit, with "do not resend until it resets"; exit 1 for a transient server error
(a 529 overload), which *is* worth resending. `read` marks the reply `(NO REPLY — the turn ended in an
API error)` and `fleet status` shows `api-error` rather than `idle`. Exit 5 is the only distinguished
code; every other failure keeps exiting 1, because retry-after-reset is the one branch a dispatcher
must take differently.

Codex writes no such record — `EventMsg::Error` is not in its rollout persistence whitelist, so the
turn simply completes with an empty reply. The equivalent verdict comes from the rollout's own
`rate_limits.rate_limit_reached_type`, gated on that empty reply so a limit already hit does not
re-flag turns that later succeed.

### Why the Claude collector is a statusline

Claude Code publishes `rate_limits` (5-hour and 7-day windows, `used_percentage` + `resets_at`) to
**statusline scripts only**. Measured, not assumed: it is absent from the `Stop` and
`UserPromptSubmit` hook payloads, absent from the transcript, and `~/.claude.json`'s
`cachedUsageUtilization` is refreshed only when `/usage` is opened (four days stale on the machine
this was designed on). The statusline is the sole live tap, and it carries `context_window` too.

So `usage --install` writes a small collector and points `statusLine` at it. Three consequences shape
the design:

- **It chains.** Whatever statusline was configured is preserved and run, so installing the collector
  never costs the user their status bar. `CLAUDE_PROJECT_DIR` is re-exported from the payload's
  `workspace.project_dir` so a chained command using it still resolves.
- **It is self-contained, not an exec into the plugin.** Plugin install paths are version-stamped
  (`…/overseer/0.37.2`), so a settings entry pointing into one breaks on every update. The stub writes
  the harness's *own* field names verbatim, so there is no format of ours to drift.
- **Scope is explicit.** A project `.claude/settings.json` overrides the user file, so `--install`
  detects that it was shadowed and says to rerun `--install --here`, which writes the git-ignored
  `.claude/settings.local.json`.

A backend with no subscription window at all — Bedrock, Vertex, a raw API key, a proxy — reports no
`rate_limits`. That is a normal steady state, so it prints `quota n/a` and never warns; only a missing
*sample* is treated as "not wired yet".

Windows is deliberately out of scope for the *pull*: a collector there would need a PowerShell peer,
and quota is per-account, so a Windows worker signed in to the same account is already covered by
reading it on the controller. The *push* half needs nothing extra — `win read`/`win chat` run the same
transcript seam, so a quota-killed turn on a Windows broker reports identically.

## ADR-0009 — Read the account quota from the API, not by installing a statusline (supersedes ADR-0008's collector)

ADR-0008 shipped the Claude quota collector as a **statusline** overseer installs into the user's
`settings.json`. The context/quota split and the API-error seam it describes stand; the collector does
not, and 0.39.0 replaces it.

Why it was wrong, in the order it became obvious:

1. **It mutates the thing overseer is supposed to only observe.** overseer's whole design is to read
   another agent's state from outside without changing it. Writing `statusLine` into the user's Claude
   config is the opposite of that, and it is not what "a command that reports quota" needs to be.
2. **Settings precedence made it unreliable.** A project `.claude/settings.json` overrides the user
   file, so on a machine with per-project statuslines the collector silently collected nothing in
   every project but the one it was installed into. The `--install --here` escape hatch turned a
   one-time setup into a per-repository chore.
3. **It only worked where a session happened to be rendering.** No open Claude in that project, no
   sample.

The replacement is a plain read: `GET https://api.anthropic.com/api/oauth/usage`, authenticated with
the OAuth access token Claude Code already keeps in `$CLAUDE_HOME/.credentials.json` — the same call
`/usage` makes (`fetchUtilization: GET /api/oauth/usage` in the CLI bundle). It needs no install, no
config write, and no per-project anything; it works over `on <host> usage`; and its response is
**richer** than the statusline payload — every window as a `limits[]` entry with `kind`, `percent`,
`resets_at`, per-model `scope`, and a server-computed `severity` that overseer flags on ahead of its
own `OVERSEER_QUOTA_WARN` threshold.

What it costs, and how each cost is bounded:

- **overseer now reads a credential.** The token goes only to the service that issued it, is passed to
  `curl` on stdin rather than argv so it never appears in `ps`, and is never logged or cached — only
  the usage response is, at mode 600 under `${XDG_CACHE_HOME:-~/.cache}/overseer/`, bounded by
  `OVERSEER_QUOTA_TTL` so the `chat`/`send`/`wait` warning never adds a request per command. `usage`
  itself always fetches live. Documented in SECURITY.md.
- **overseer cannot refresh an expired token** — that needs the refresh flow, which is Claude Code's
  job. The token rotates roughly hourly, so an expired one is a normal state and gets its own message
  ("run any claude session once to renew it") rather than a generic failure.
- **The endpoint is undocumented.** So is every on-disk layout overseer reads; the house answer
  applies — `doctor` probes it and reports, and a failure degrades to `quota n/a` rather than
  breaking a command.

**Context is the one thing lost.** `context_window_size` came from the statusline payload and is in no
transcript, so Claude's context is now reported as a plain token count instead of a percentage. That
is an acceptable trade: context is the number this whole design says *not* to act on. Codex keeps its
percentage because its rollout carries `model_context_window`.

An account with no OAuth credentials at all — a third-party backend, Bedrock/Vertex/an API key/a
proxy — is detected by that absence and reported as `quota n/a`, which is a cleaner signal than the
statusline route's "no `rate_limits` field" ever was.

## ADR-0010 — A queued message stays retractable, and the transcript says whether it is

**Context.** `send`/`chat` onto a busy agent queue the message, and overseer caps that at one queued
message per agent. A dispatcher whose plan changes mid-flight — a worker turns out to be doing the
same work, an instruction was wrong — had no way to take it back. The observed workaround was a
background loop that retried a "stop" message every 20s until the slot freed, which wastes the minutes
that matter and still lets the stale task start.

**Decision.** Add `unsend <target>`: pull the queued message back out of the queue, print it, clear the
input box, leave the running turn alone. Both the `QUEUED` notice and the one-slot refusal point at it,
so the dead end becomes a two-command fix.

**Why the transcript decides, not the screen.** Claude records every queue change as a
`queue-operation` record — `enqueue` with the text, `dequeue` when it starts running, `popAll` when it
is pulled back into the composer. That gives two things the screen cannot:

- The on-screen hint (`Press up to edit queued messages`) is a *placeholder*, so it vanishes the moment
  anything is typed into the box. A queued message behind a half-typed draft is invisible to the screen
  check and plainly visible in the transcript.
- After pressing the pop key, `popAll` means "retracted" and `dequeue` means "too late, it started
  running". Without that, an `Up` arriving a moment late pulls *prompt history* into the box and looks
  exactly like a successful retract. Reporting a false success here is worse than failing.

**Why Codex is refused rather than approximated.** Codex does not queue a mid-turn message; it hands it
to the model as a *steer* the moment it is submitted (`pending_steers`, rendered as "Messages to be
submitted after next tool call"). `pop_latest_queued_composer_state` only pops `queued_user_messages`
and `rejected_steers_queue`, so no keystroke pulls a steer back — verified live against codex-cli
0.145.0. `unsend` therefore acts only on Codex's genuinely retractable sections and refuses the steer
with that explanation. Pretending would be the same false success the transcript check exists to avoid.

**Cost.** Two harness-specific screen strings for Codex, and a `_realtext` fix that the queued
placeholder exposed: Claude emits the ghost as `ESC[2m ESC[39m text`, and the stripper had assumed the
text followed `ESC[2m` directly, so every box-clearing path failed on an empty box in that state.

## ADR-0011 — Interrupting is a separate verb from retracting, and it refuses to guess

**Context.** ADR-0010 made a *queued* message retractable. The message that has already started running
was still unreachable: the only lever was `keys <t> Escape` by hand, with no verification that anything
stopped. A dispatcher that spots duplicated work seconds too late needs the second lever, and needs it
to be as self-verifying as the first.

**Decision.** Add `interrupt [--run-queued]`, fan it and `unsend` out through `fleet`, and give both to
the Windows broker as `win <host> unsend` / `win <host> interrupt`.

**The queue interaction is the whole design.** Measured on Claude: pressing Escape while a message sits
in the queue does *not* just abort the turn — it aborts it and the queued message starts running
immediately (the transcript shows `dequeue`, not `popAll`). An `interrupt` that quietly did that would
be the opposite of what "stop" means to the caller. So it **refuses by default** and names both ways
out: `unsend` then `interrupt` to stop everything, or `--run-queued` to accept the handover — in which
case it reports *which* message is now running. Codex's in-flight steer is treated the same way, since
it has the same effect.

**Per-platform interrupt keys, kept in one seam.** Linux Claude and Codex both interrupt on `Escape`.
The Windows console does not: a raw `ESC` byte never reaches the child there, so Claude needs `C-c`
while Codex's `Escape` still works because the broker sends it as a key *event*. That is two functions
(`_h_intkey`, `_win_intkey`), pinned by tests, rather than a conditional at each call site.

**Verify, never assume.** Every path polls until the agent actually settles and fails loudly if it does
not. That matters because the guarantee is not uniform: Codex accepts the interrupt while the model
request is in flight, but once it is streaming the final answer Escape stops working — measured against
codex-cli 0.145.0. The command reports "sent the interrupt but it is still running" instead of a
success it did not get. Claude also puts the interrupted prompt back into its input box; that is
reported rather than left as a surprise for whoever peeks next.

**What was deliberately not changed.** A first pass loosened `_agent_busy` so a Codex transcript that
claims to be running could be vetoed by a still screen, on the theory that Codex had stopped recording
`turn_aborted`. That was a misdiagnosis — the pane was genuinely still generating. Codex does record
`turn_aborted` on a real interrupt, and the change was reverted: the fast path stays, and the screen
veto stays Claude-only where ADR-0006 put it.
