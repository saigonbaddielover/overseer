# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and versions follow [SemVer](https://semver.org/).

## [Unreleased]

## [0.45.1] - 2026-08-12

### Fixed

- **`doctor` no longer fails a healthy remote host.** Its tmux reachability probe was `tmux info`,
  which needs a *client*: over a non-tty ssh it exits 1 with `no current client` even though the
  server is perfectly reachable. 0.41.3 turned that exit into a hard `[FAIL]`, so `on <host> doctor`
  reported every remote Linux host as broken. Reachability is now `tmux list-sessions`, which the
  server answers with no client attached, and the server pid is read the same way instead of through
  `display-message`. The genuine case 0.41.3 was built for — a server this tmux cannot speak to
  because the two builds disagree on the protocol — still FAILs, now for the right reason.

## [0.45.0] - 2026-08-12

### Added

- **`--as-user` on `chat`/`send`/`fleet send`/`fleet chat` — the user's authority, delegated for one
  dispatch.** The peer refusal and the sender prefix exist so a worker can tell an agent from its own
  user; the cost is that a worker asked to do something by another agent stops and waits for its user
  to approve. When the user has already delegated that dispatch — "send this to X as me" — that second
  approval is the user approving their own instruction. `--as-user` implies `--force-keys` and
  suppresses the prefix, so the message lands byte-identical to the user typing it and the worker acts
  on it directly. It is a flag rather than a mode because it spends the user's authority: it belongs to
  a dispatch the user explicitly delegated, never to an agent getting past a refusal of its own. The
  default path is unchanged — a peer-capable target is still refused, and `--force-keys` still names
  the sender.

## [0.44.0] - 2026-08-10

### Added

- **`list` is the whole picture, not just the drivable part.** It now also lists a live claude that
  has **no tmux pane** — one the harness can address but overseer cannot drive — and a **`REACH`**
  column saying which channels a row answers on: `keys+peer`, `keys` (Codex or an unnamed pane), or
  `peer`. Targeting a `peer`-only row no longer fails with "no tmux pane": it names the session and
  points at the `SendMessage` tool, so the harness listing and overseer's listing agree on who
  exists and differ only on who can be driven.
- **A keystroke delivery carries its own provenance and a reply address.** The prefix already named
  the sender; it now also states that the sender is another agent rather than the user and that the
  message is not an approval to act, and tells the receiver how to answer — `SendMessage` when the
  target has a PEER name of its own, `overseer send <sender>` when it does not (Codex, a shell, a
  Windows broker). This is the harness's own peer-message guardrail, reduced to one line, carried
  onto the one path that cannot have the real thing.

### Changed

- **A failed target resolution says what is actually wrong.** `_target_die` classifies the name
  before repeating the generic error, so an ambiguous name and a live-but-undrivable session each
  get their own message instead of "no tmux pane for target: …".

## [0.43.0] - 2026-08-10

### Changed

- **The harness peer name is now the primary target vocabulary.** `_resolve_pane` — the single choke
  point every command resolves a target through — tries the `PEER` name *before* asking tmux, so a
  claude's own harness name wins over a tmux session that happens to share it, for every verb rather
  than just the ones that mention it. `list` leads with the `PEER` column, `stop <peer-name>` kills
  that agent's pane (not the whole tmux session it sits in), and `fleet` labels each section with the
  peer name when the pane has one.

### Fixed

- **`fleet send`/`fleet chat` accept `--force-keys`.** They fan out to `cmd_send`/`cmd_chat`, so they
  inherited the peer refusal added in 0.42.0 with no way past it — and the flag, being unparsed, was
  broadcast as the message text. It is now parsed and forwarded, on the local and the `--hosts` path.
- **A duplicated peer name is refused, not silently resolved to whichever session was read first.**
  Names are not unique — the harness picks a fresh one per session — and now that a name outranks a
  tmux target, guessing would drive the wrong agent. A name is also only a candidate while its
  messaging socket is alive, so an exited session's leftover state file no longer matches.
- **A target driven through `on <host>` is no longer refused.** The peer channel is a unix socket
  under the caller's own user on the caller's own machine, so it cannot cross to another host: the
  keyboard is the only path there and the refusal was pointing at a tool that could not deliver.
  `cmd_on` marks the remote invocation and the guard stands down for it.

## [0.42.0] - 2026-08-10

### Added

- **`list` shows a `PEER` column, and a target may be given by that name.** Claude Code records each
  live session in `~/.claude/sessions/<pid>.json` with a `name` and a `messagingSocketPath`; that name
  is the address its own agent-to-agent channel uses. overseer already read that file for pane
  discovery, so it now surfaces the name (`-` when the session exposes none) and resolves a target by
  it, which means one vocabulary across `overseer`, `ListAgents` and `SendMessage`.

### Changed

- **`chat`/`send` refuse a target that is reachable on the harness peer channel.** A keystroke
  delivery is recorded on the receiving side as `origin.kind=human` with `promptSource=typed` — a
  message from another agent is indistinguishable from one the user typed, and none of the harness's
  peer guardrails attach to it. The two verbs now name the target's `PEER` name and point at the
  `SendMessage` tool, which the receiver records as an authenticated peer message (`origin.kind=peer`
  with a `verifiedPeerPid`). `--force-keys` takes the keystroke path anyway, for the cases that need
  the keyboard.
- **Every keystroke delivery carries the sender's own `PEER` name.** `chat`/`send` prefix the message
  with `[from: <name>]` when overseer runs inside a claude pane, so a Codex, shell, remote or
  peerless target still knows who wrote to it. The prefix is a convention, not proof — only the peer
  channel authenticates.

## [0.41.3] - 2026-07-29

### Added

- **`doctor` diagnoses a tmux client/server build mismatch.** A tmux client only speaks to a server of
  its own protocol version, so on a machine with two installs (e.g. `/usr/bin/tmux` 3.4 beside
  `/usr/local/bin/tmux` 3.6a) anything run through the wrong one fails with `server exited
  unexpectedly` — which reads like the server died, when it is fine and every session is still there.
  `doctor` now resolves the running server's binary from `/proc` and compares it with the `tmux` on
  `PATH`, naming both. It also separates "no tmux server yet" (a warning) from "a server is running but
  this tmux cannot reach it" (a failure). overseer itself pins no tmux version and never calls a fixed
  path, so it follows whichever tmux is on `PATH`; the README now says so.

## [0.41.2] - 2026-07-29

### Fixed

- **`fleet wait` waited on the pane overseer runs in, which can never finish** — the caller is busy by
  definition (it is running the command), so the fan-out burned the whole timeout on itself. `fleet
  wait` and `fleet wait --any` now skip that pane with a printed note. `--any` was unaffected in
  practice (it returns on the first pane to finish) but no longer counts the caller as in flight.
- **Every command that drives a pane now refuses the pane overseer runs in**, not just `stop`,
  `unsend` and `interrupt`: `send chat keys sh slash menu wait quit`. Each was guaranteed broken when
  self-targeted — a message pasted into your own composer wipes what was half-typed there and queues
  behind the turn that pasted it, `wait` can only return after the turn it waits for, `sh` types into
  the shell running it, `quit` kills the agent mid-command — so they now fail fast with the reason
  instead of hanging or clobbering. Read-only commands (`list`, `read`, `peek`, `fleet status`,
  `fleet read`) still include that pane.

### Changed

- `send --notify`'s separate "would wake the pane it is dispatching to" refusal is gone; the general
  self-target guard covers it and reports the same thing.

## [0.41.1] - 2026-07-29

### Fixed

- **`interrupt` and `unsend` refused to target the pane overseer is running in.** They did not, and
  `fleet interrupt` therefore reached the dispatching agent's own pane in the fan-out — an admin
  stopping its fleet would have stopped itself mid-turn. Both now refuse a self-target the way `stop`
  already did (comparing the *resolved* pane, so a session name cannot slip past it), and the `fleet`
  fan-out skips that pane with a printed note instead of acting on it.

## [0.41.0] - 2026-07-29

### Added

- **`interrupt [--run-queued] <target>` — stop the turn that is running right now.** `unsend` covers a
  message that has not started; this covers the one that has. The turn ends with **no reply**, and the
  command verifies the agent actually settled rather than assuming the keystroke landed.

  It **refuses while a message is queued** behind that turn, because interrupting hands control
  straight to the queued message and it starts immediately — measured, not assumed. To stop everything,
  `unsend` first and then `interrupt`; to interrupt and let the queued one take over, pass
  `--run-queued`, which then reports which message is now running. When Claude puts the interrupted
  prompt back into the input box, that is reported too instead of being left as a surprise.

- **`fleet unsend` and `fleet interrupt [--run-queued]`** — the per-pane commands fanned out over every
  local agent pane, and over the inventory hosts with `--hosts`/`--tailscale`, so clearing a broadcast
  that turned out wrong, or stopping a whole fleet mid-turn, is one call instead of a loop.

- **`win <host> unsend` and `win <host> interrupt [--run-queued]`** — the same two on a remote Windows
  console broker. `unsend` reads the queue from the scp'd transcript, so a draft in the console box
  cannot hide it and the retract is confirmed by a `popAll` record rather than by trusting the key.
  The interrupt key differs from Linux for Claude — the Windows console takes **`C-c`**, since a raw
  `ESC` byte never reaches the child, while Codex takes `Escape`. The `win send`/`chat` mid-turn
  refusal now points at `win <host> interrupt` instead of a raw `keys` invocation.

### Notes

- Codex accepts the interrupt while the model request is in flight; once it is streaming the final
  answer, Escape no longer stops it. `interrupt` reports that it could not confirm the agent settled
  rather than claiming a success it did not get.

## [0.40.0] - 2026-07-29

### Added

- **`unsend <target>` — retract a message queued behind a running turn, before it runs.** A `send` or
  `chat` onto a busy agent is queued, and until now nothing could take it back: a dispatcher whose
  plan changed mid-flight had to sit in a poll loop waiting for the queue to drain just to send a
  "stop", and meanwhile the stale task was still going to run. `unsend` pulls the message back out of
  the queue, prints what it dropped, and clears the input box; the running turn is untouched. It also
  frees the one queue slot, so the refusal on a second `send` is no longer a dead end — both that
  refusal and the `QUEUED` notice now point at it.

  Retracting is verified against the transcript, not the screen: Claude records every queue change as
  a `queue-operation` (`enqueue` / `dequeue` / `popAll`), so `unsend` knows a message is really queued
  even when a half-typed draft hides the on-screen hint, and it can tell "pulled it back" (`popAll`)
  from "too late, it started running" (`dequeue`) instead of reporting a false success.

  **Codex is refused, with the reason.** A message sent to a busy Codex is handed to the model
  immediately as a *steer* — it is already in flight and no keystroke pulls it back. `unsend` says so
  rather than pretending; only Codex's genuinely retractable queues (`Queued follow-up inputs`,
  `Messages to be submitted at end of turn`) are acted on.

### Fixed

- The input box read as non-empty when Claude drew a dim ghost placeholder that begins with an SGR
  reset (`ESC[2m ESC[39m Press up to edit queued messages`) — the ghost stripper assumed the text
  followed `ESC[2m` directly, so it left the placeholder behind. Every box-clearing path (`send`,
  `chat`, `unsend`) then failed on a box that was in fact empty.

## [0.39.0] - 2026-07-28

### Changed

- **BREAKING — `usage` no longer installs anything, and `usage --install`/`--uninstall` are gone.**
  0.38.0 read Claude's quota by installing a statusline into the user's `settings.json`. That was the
  wrong shape: overseer exists to observe another agent's state without changing it, a project
  `.claude/settings.json` silently overrode the user-level install (so it collected nothing in every
  other project until you reran `--install --here` there), and it only sampled while a session
  happened to be rendering. `usage` now makes a plain read-only `GET
  https://api.anthropic.com/api/oauth/usage` with the OAuth token Claude Code already keeps in
  `$CLAUDE_HOME/.credentials.json` — the same call `/usage` makes. No install, no config write,
  nothing per-project, and it works over `on <host> usage`. **If you ran `usage --install` on 0.38.0,
  run `overseer usage --uninstall` on 0.38.0 first, or delete the `statusLine` entry it added.**
  Rationale in `docs/DECISIONS.md` ADR-0009.
- The API response is richer than the statusline payload was: every window arrives as a `limits[]`
  entry with `kind`, `percent`, `resets_at`, a per-model `scope` and a **server-computed `severity`**,
  which overseer flags on ahead of its own `OVERSEER_QUOTA_WARN` threshold — so a window the server
  calls `critical` is marked even below it.
- Claude's context is now reported as a **plain token count** rather than a percentage:
  `context_window_size` only ever existed in the statusline payload, never in the transcript. Codex
  keeps its percentage (its rollout carries `model_context_window`). Context remains labelled
  informational — it is the number this design says not to act on.
- An account with **no OAuth credentials at all** (Bedrock/Vertex/API key/proxy) is now what
  identifies a third-party backend, and reports `quota n/a` — a cleaner signal than "no `rate_limits`
  field".
- `doctor` replaces its "collector wired" check with a live probe of the endpoint; it warns rather
  than failing, and distinguishes *no credentials*, *expired token* and *unreachable*.
- New `OVERSEER_QUOTA_TTL` (default `300`) bounds how long the `chat`/`send`/`wait` warning may reuse
  a cached reading, so the warning never costs a request per command. `usage` itself always fetches
  live. The cache holds only the response — never the token — at mode 600 under
  `${XDG_CACHE_HOME:-~/.cache}/overseer/`.

### Security

- overseer now reads `$CLAUDE_HOME/.credentials.json` — the first credential it has ever touched.
  The token is sent only to `api.anthropic.com`, passed to `curl` on **stdin** rather than argv so it
  never appears in `ps`, and is never logged or cached. `SECURITY.md` documents the full contract.

## [0.38.0] - 2026-07-28

### Added

- **`usage [--json] [target]` — the account quota an overseeing agent should actually watch.** Prints
  each usage window (`5h`/`7d` for Claude, the rolling window for Codex) with its spend and reset time,
  and — separately, labelled *informational, never a fault* — the session's context fill. No target
  reads this machine's account; a target reads that pane's session. Flags a window at
  `OVERSEER_QUOTA_WARN` (default 90), and `chat`/`send`/`wait` print the same warning to stderr past
  that threshold. A backend with no subscription window (Bedrock/Vertex/API key/proxy) reports
  `quota n/a` — a normal state, not an error.
- **`usage --install` / `--uninstall` wire the Claude collector.** Claude Code publishes `rate_limits`
  only to a statusline script — it is in no hook payload, not in the transcript, and `~/.claude.json`'s
  `cachedUsageUtilization` only refreshes when `/usage` is opened. So the collector is a statusline that
  **chains whatever statusline was already configured**, and is self-contained rather than an exec into
  the version-stamped plugin path. `--install --here` handles a project `statusLine` overriding the user
  one (the installer detects the shadowing and says so). Codex needs none of it — it already writes
  `rate_limits` into every rollout. `doctor` reports whether the collector is wired.
- `OVERSEER_QUOTA_WARN` (default `90`, validated at startup like the other tunables).

### Fixed

- **A turn killed by a usage limit was handed back as the agent's answer.** Claude records an API
  refusal as an ordinary terminal assistant message (`isApiErrorMessage`, `model: "<synthetic>"`,
  `stop_reason: "stop_sequence"`), so every reader keyed on "stop_reason present and not tool_use"
  counted it as a completed turn and `chat` printed `API Error: …` as the reply. A new `_h_last_error`
  seam catches it: `chat`/`wait` now exit **5** for a usage limit (with "do not resend until it
  resets") and 1 for a transient server error, `read` marks it `(NO REPLY — the turn ended in an API
  error)`, and `fleet status` shows `api-error` instead of `idle`. Codex persists no error event, so
  the same verdict comes from its rollout's `rate_limits.rate_limit_reached_type`, gated on an empty
  reply. `win read`/`win chat` share the seam and report identically.

## [0.37.2] - 2026-07-27

### Fixed

- **An interrupted Codex turn blocked `chat` to the full timeout.** The screen veto added in 0.37.0 is
  Claude-only, and a Codex turn that is interrupted (`Escape`) never writes the `task_complete` its turn
  count is keyed on — so `wait` correctly reported `idle` while `chat` kept polling for a turn that would
  never arrive. Measured live at the full 300s. Codex needs no screen heuristic: it records
  `turn_aborted`, so `_wait_reply`, `_wait_queued_reply` and `_win_wait_turn` now return **rc=4** when a
  turn they have already seen running stops running without advancing the count. The "already seen
  running" latch keeps the delivery-to-first-record window from reading as an abort.
- **A long prompt could not be delivered to Codex** — including on Windows, where 0.37.1 had just fixed
  the same class of bug for Claude. Claude's composer is closed by a box rule, Codex's by a blank line
  before its status row, so joining the wrapped composer lines ran on into the status row and never
  matched. `_win_box_text` now stops at either. `win-snap-wrapped-box-codex.txt` is a real capture.
- The `chat` no-reply error named only `Ctrl-C` as the interrupt; it now names `Ctrl-C` for Claude and
  `Escape` for Codex, both confirmed live on Linux and on a Windows console.

## [0.37.1] - 2026-07-27

### Fixed

- **The Windows path never got the busy-detection fixes Linux has had since 0.35.0.** `win wait` and the
  mid-turn guard on `win chat`/`win send` both asked `_h_is_busy`, so a remote turn that answers without
  calling a tool read **idle**: `win wait` returned immediately on a working agent, and a delivery could
  paste straight into a live turn. Both now use `_win_agent_busy` (`_h_is_busy`, else `_h_running`
  confirmed by the broker's `SNAP` grid still moving), and `_win_wait_turn` carries the same debounced
  veto, returning **rc=4** so `win wait` reports `idle` and `win chat` says the turn stopped without a
  reply instead of blocking to `[timeout]`. The Windows snapshot has no cursor position, so the whole
  grid is hashed rather than just the region above the input box — a host whose console has a ticking
  element simply never vetoes, which degrades to the old blocking behaviour rather than to a false idle.
- **A single-line prompt longer than the remote console was never deliverable.** `win chat`/`win send`
  verified the paste by comparing the whole message against the one composer line carrying the `>`
  marker, but the console soft-wraps the overflow onto gutter-indented continuation lines — so anything
  past roughly one screen width could not match, and every attempt ended in `could not place/verify the
  prompt` with the box cleared. The composer is now read whole (`_win_box_text` joins the marker line
  with its continuations, stopping at the closing rule) and compared with whitespace removed, since a
  wrap swallows the space it breaks on. A short prompt still takes the exact-match path, and a prompt
  that only partly landed still fails closed.
- **`fleet status` could call a streaming turn idle on a single slow frame.** `_agent_busy` compared two
  samples ~0.75s apart; now it samples up to six times, returning `busy` the moment the screen moves, so
  a frozen verdict needs ~3s of stillness. A streaming pane still costs one extra sample, an interrupted
  one costs the full window.
- **A turn with an extended-thinking block counted as two.** Claude writes the final assistant message as
  two transcript records — one for the `thinking` block, one for the `text` — sharing a `message.id` and
  both carrying `stop_reason: end_turn`, so `_turn_count`/`_turns_after` counted 2 per turn (visible in
  `doctor`'s "parsed N completed turns"). They now count **distinct `message.id`**, falling back to a
  per-record token when a record has none. A new `claude-thinking-split.jsonl` fixture pins the shape, so
  a future Claude that flushes the thinking record early — which would make `chat` return before the
  reply exists — fails the tests instead of shipping silently.
- A load-sensitive flake in `tests/run.sh` and `tests/win-flow.sh`: the waiter tests ran against a short
  deadline, which a busy machine could miss before the veto's sample count was reached. The cases that
  expect an early return now get a generous timeout; only the cases that *want* the deadline to expire
  keep a short one.
- The mid-turn refusal on `win chat`/`win send` suggested `keys Escape` to interrupt. Escape does not
  interrupt Claude Code — verified on a live Windows console, as on Linux — so the hint now names `C-c`
  for a Claude broker and keeps `Escape` for Codex.

## [0.37.0] - 2026-07-26

### Fixed

- **`wait` and `fleet status` could call a live turn idle, and `chat` could abandon one mid-reply.**
  0.35.0 and 0.36.0 read "is this turn in flight?" off Claude's spinner line. Two live measurements say
  that is the wrong thing to look at. Claude **stops drawing the status row once it starts rendering the
  reply text**: a 181s turn showed a spinner for ~87s and nothing for the ~94s it spent writing. And the
  elapsed field changes shape at one minute (`(47s · thinking)` → `(1m 5s · thinking)`), which
  `_thinking_text`'s `\([0-9]+s` did not match — so every turn past 60s read as spinner-free anyway.
  Together: `wait` returned `idle` on a running agent, `fleet status` showed it `idle`, and `chat` gave
  up while the reply was still streaming.
- The veto now keys on **screen movement** instead. `_screen_state` returns `busy` (spinner or queued
  hint on screen) or a checksum of the pane **above the input box** — the cursor row locates the box, so
  the ticking statusline below it is excluded. A turn is called interrupted only after four *consecutive*
  samples that are both not-`busy` and byte-identical: a thinking turn moves its spinner, a streaming
  turn moves its text, an interrupted turn moves nothing. `_agent_busy` uses the same evidence with a
  two-sample check.
- `_thinking_text` now matches the whole elapsed format (`(47s`, `(1m 5s`, `(1h 2m 13s`), with tests
  pinning the minute and hour forms.

### Added

- **`chat` stops instead of hanging when the turn it is waiting on is interrupted.** `_wait_reply` and
  `_wait_queued_reply` now return **rc=4** on the same evidence `wait` uses, and `chat` reports that the
  turn stopped without producing a reply and points at `peek`. It is a distinct code because there is no
  reply to print — that is neither the timeout (rc=1) nor a pane that dropped to a shell (rc=3).
- The screen veto is Claude-only. Codex writes `turn_aborted` into its rollout, so `_cx_is_busy` already
  reads an aborted turn as idle and never needs the screen; `wait`/`chat` on a Codex pane are unchanged.

## [0.36.0] - 2026-07-26

### Fixed

- **`wait` no longer blocks to its timeout on a pane whose turn was interrupted.** `_wait_drained` asked
  only `_h_running`, and Claude records an Escaped turn identically to one in flight (a human prompt, no
  terminal assistant message, no interrupt marker), so `overseer wait` on an interrupted agent sat there
  until `[timeout]` — and so did the `send --notify` watcher built on it, and `fleet wait`. The loop now
  applies the same screen veto v0.35.0 gave `fleet status`, **debounced**: it samples the pane on the
  existing every-8th-iteration cadence and requires **four consecutive** spinner-free samples (~8s, and
  neither queued nor awaiting) before calling the turn drained. Sustained silence while the transcript
  claims running means the turn was interrupted; a momentary render gap cannot cut a live turn short.
  Verified live: a real text-only turn still ran its full 33s with no early return, while an
  interrupted one returned `idle` in 10s instead of 180s.

## [0.35.0] - 2026-07-26

### Fixed

- **`fleet status` called a text-only turn `idle`, so `fleet wait --any` never watched it.** The state
  column was decided with `_h_is_busy`, which for Claude means "the last assistant message stopped at
  `tool_use`" — a turn that runs to completion without calling a single tool (any "write me an essay"
  answer) emits no `tool_use` and therefore read `idle` **while it was still generating**. The
  consequences were real: `fleet wait --any` excluded such a pane from its in-flight set and could
  report "nothing in flight" with a worker still writing, and a `fleet send`/`chat` broadcast treated it
  as a free agent and queued onto live work. `wait` never had the bug (it already used `_h_running`);
  `fleet status` was the odd one out.
- Busy is now decided by `_agent_busy`: `_h_is_busy`, **or** `_h_running` (which does catch the
  text-only turn) confirmed by the screen showing a live spinner. The screen check is needed because
  Claude's transcript records an **interrupted** turn identically to one still in flight — a human
  prompt with no terminal assistant message and no interrupt marker — so `_h_running` alone would have
  pinned an Escaped pane at `busy` **forever**, which is worse than the bug being fixed (it would also
  make a broadcast permanently skip that pane). The `Stop` hook does not fire on an interrupt either
  (verified live), so the screen is the only signal that separates the two. See ADR-0006 for why this
  does not contradict "never trust the spinner": the screen may only **veto** a transcript that already
  says running — it can never make an idle pane look busy.

## [0.34.0] - 2026-07-26

### Added

- **`send --notify` wakes the dispatching agent when the worker finishes — no polling.** Until now
  every way of learning that a worker was done required the dispatcher to *choose* to block: `chat`
  waits on the reply, `wait`/`fleet wait --any` wait on the pane. That is a structural dead end for a
  long job, not a discipline problem: a Claude Code session has no inbound channel, so once the
  dispatcher's turn ends nothing can reach it until a human types, and a plain `send` is simply never
  collected. `send [--yes] --notify <target> <msg> [notify_timeout]` does the normal send and then arms
  a **detached watcher** (`setsid`) that runs `wait` on the worker and then `send`s a wake-up back into
  `$TMUX_PANE` — the dispatcher's own pane — starting a fresh turn there. The dispatcher returns
  immediately and may go idle. Built entirely out of the existing `wait` + `send`: no daemon, no new
  state on disk, no new event protocol, and it works for **Codex** workers too (which have no hooks),
  while still riding the `Stop`-hook accelerator wherever `wait` already does.
  - The wake-up is a **doorbell, not a mailbox**: an agent holds only one queued message, so a second
    worker finishing while the dispatcher is mid-turn has its notice refused. The text therefore quotes
    what `wait` reported and then instructs the woken agent to survey the whole fleet (`fleet status`,
    then `read` each idle/awaiting pane) instead of acting on the pane that rang — a dropped duplicate
    costs nothing because the survey finds it.
  - Inherits `wait`'s answers, so a worker **blocked on a permission/menu prompt** wakes the dispatcher
    exactly like a finished turn does, as does one that died mid-turn. Bounded by `[notify_timeout]`
    (default `OVERSEER_TIMEOUT`); on expiry it wakes with that fact rather than disappearing.
  - Guards: refuses when overseer is not inside a tmux pane (`$TMUX_PANE` unset — there is no pane to
    wake), refuses to wake the very pane it is dispatching to, and refuses `[timeout]` without
    `--notify`. `fleet send --notify <msg> [notify_timeout]` arms one watcher per receiving pane;
    `fleet chat` rejects the flag (it already waits) and the cross-host `--hosts`/`--tailscale` path
    rejects it (the pane to wake exists only on the local machine).
  - The watcher does not trust a **stale idle**: a freshly `start`ed worker has no transcript for the
    first seconds and one whose turn overseer could not confirm within its 10s budget reads briefly as
    idle, so a naive watcher fired at once. It re-waits while the worker reports "no transcript yet",
    and when the turn start was **not** confirmed it also re-waits through a 30s startup grace before
    believing an `idle`; when `send` did confirm the start, it waits with no grace at all.

## [0.33.0] - 2026-07-24

### Added

- **`fleet wait --any` returns on the first in-flight pane to finish/await/exit.** Plain `fleet wait`
  fans a per-pane wait over every pane and only returns once each has been waited on in turn — fine for
  "block until the whole fleet is settled," but wrong for the dispatch-then-react loop (send work to N
  agents, then wake on whichever finishes first). `fleet wait --any` snapshots the panes that are
  **busy/compacting** at call time (the in-flight set — already-idle and awaiting panes are excluded so
  it never returns immediately on stale state) and returns as soon as the **first** of them leaves that
  state, printing the winning pane + its new status; a poll loop (`/loop`, cron) then reacts and calls
  again for the next. It returns `rc=0` with the winner, `rc=1` on timeout, and prints "nothing in
  flight" (rc 0) when no pane is busy. Local-fleet feature; the multi-host `--hosts`/`--tailscale` path
  still aggregates per host.

### Fixed

- **`fleet`'s "no agent panes found" no longer fires on a `wait`/`--any` timeout.** The no-panes guard
  and a wait timeout both used to surface as exit code 1, so `fleet wait --any` timing out was
  misreported as "no agent panes found (see: overseer list)" even with panes present. The no-panes
  condition now uses a distinct sentinel (rc 3); a timeout propagates its own rc 1 to the caller
  unchanged.

## [0.32.0] - 2026-07-24

### Fixed

- **A turn that completes just as its pane drops to a shell is no longer reported as a mid-turn
  death.** `chat`/`wait`'s wait loops fail fast with `rc=3` when the watched pane falls back to a shell
  (the agent died or was quit) instead of waiting out the timeout. But the reply is written to the
  transcript *before* the agent process exits, so an agent that answered and then quit left a tiny
  window where the loop could see the shell drop before reading the just-flushed turn — turning a real
  reply into "the agent exited mid-turn — no reply was produced." All three waiters (`_wait_reply`,
  `_wait_queued_reply`, `_wait_drained`) now re-read the transcript one last time before returning
  `rc=3`: if the turn actually completed, `chat` returns the reply and `wait` reports `idle`/drained;
  only a genuinely unfinished turn still yields `rc=3`. The turn-advanced check is factored into a
  shared `_turn_advanced` helper (unit-tested) and the invariant "a completed turn is never masked as
  `rc=3`" is asserted in the harness-free stress subset.

### Fixed

- **Windows `win <host> chat` reads its reply prompt-keyed too, matching Linux.** v0.28.0–v0.30.0 bound
  Linux `chat`'s printed reply to your own message, but `win chat` still read the *latest* assistant
  reply (`_h_last_reply`) — so a Windows agent that ran a `task-notification`/child-agent turn right
  after answering could shift the printed reply. `win chat` now uses the same `_h_reply_for` reader (the
  turn answering your prompt), falling back to the latest reply only if the prompt can't be matched in
  the fetched transcript — so it never regresses, only tightens. Covered by the shared reader unit
  tests; a live Windows round-trip is pending a reachable host.

## [0.30.0] - 2026-07-24

### Fixed

- **`chat` attribution is now bound to *your* message positionally, not by "is it the last prompt."**
  The queued-reply wait keyed on "my message is the LAST prompt and the agent is idle." If a *newer*
  message got queued behind mine (a second orchestrator, or a human typing at the pane), mine was no
  longer last, so my `chat` would wait out its whole timeout even though my message had already run and
  replied. `chat` now waits until *my message's own turn completes* (`_answered`: a completed turn after
  the prompt whose text matches mine) and prints *that* turn's reply (`_reply_for_prompt`) — independent
  of any newer prompt, and covering Codex with the same prompt-keyed reader. This also removes the last
  reliance on "latest reply", so a same-instant race between the pre-send idle check and the actual
  submit can no longer misattribute.

### Added

- **`send`/`chat` refuse cleanly when the pane already holds a queued message.** Claude's TUI queues
  exactly **one** message behind a running turn; a second can't be placed and used to fail with a
  cryptic "could not place/verify message in input box." `send`/`chat` now detect the queued-message
  state up front — only when *not* compacting, so the compaction-queue path (v0.26.0) is unchanged — and
  refuse with an actionable message ("a message is already queued … wait for it first: overseer wait
  <target>"). The already-queued message is never disturbed.

## [0.29.0] - 2026-07-24

### Fixed

- **`chat`'s prompt-bound reply now covers Codex too, not just Claude.** v0.28.0 bound `chat`'s printed
  reply to your own message for Claude; Codex kept the "last `task_complete`" reader. But Codex can also
  produce a completed turn *after* the one that answered your message — a null `task_complete` (observed
  in real rollouts) or, when the Codex agent is orchestrating child agents, a content-bearing
  completion-notification turn — either of which could shift the reply `chat` printed. Codex now uses the
  same prompt-bound reader (`_cx_reply_after_last_prompt`: the first non-empty `task_complete` after your
  `user_message`), verified against a real rollout with trailing null turns and live end-to-end. `read`'s
  `_cx_last_reply` already filtered the null turns, so it was unaffected; only `chat` is changed.

## [0.28.0] - 2026-07-24

### Fixed

- **`chat` binds the reply it prints to *your* message, not "the latest reply."** When the target agent
  is itself orchestrating — spawning background tasks — a `task-notification` turn can run *right after*
  the turn that answered a queued `chat` message. The old reader (`_last_reply`, "the most recent
  assistant text") would then print that notification turn's reply instead of the answer to your message
  (a real, timing-dependent mis-attribution: the exact `your-reply → task-notification → other-reply`
  sequence showed up in live testing and only poll timing avoided the wrong read). `chat` now reads the
  first completed assistant turn *after your prompt* (`_reply_after_last_prompt`), which is immune to any
  later `task-notification` or background turn. Affects only `chat` (the only command that prints a
  reply); `send`/`wait` never read reply text. Claude only — Codex has no task-notification injection, so
  its last-`task_complete` reader is already correct.

## [0.27.0] - 2026-07-24

### Changed

- **`send`/`chat` to a busy agent now QUEUE by default instead of refusing.** A running turn cannot be
  interrupted by a second message, so the harness holds the new one and runs it when the current turn
  ends. Previously overseer refused a mid-turn agent ("session looks mid-turn"); now it accepts the
  message and reports honestly:
  - `send` reports `sent … (QUEUED — the agent is busy with its current turn / compacting its context)`
    and **exits 0**, pointing at `wait` for the reply — the same shape the compaction case already used.
  - `chat` announces the queue and **waits for the reply to *its own* queued message**, tracking the
    last human prompt through the queue so the reply it prints is the answer to *your* message, never
    the running turn's reply.
  - `wait` **drains to idle** — it blocks until the current turn finishes *and* any queued message
    behind it has run, then reports `idle`.
- **Fleet broadcast only messages idle panes** (unchanged behaviour, now stated plainly): a
  busy/awaiting/compacting pane is **skipped**, never queued onto, so a broadcast never lands on
  unrelated running work.

### Fixed

- **A message sent during a text-only turn (no `tool_use`) is no longer mistaken for idle.** Turn
  detection used to key only on "the last assistant message is a `tool_use`" (`_is_busy`), which misses
  a turn that emits pure prose. A new transcript-based check (`_running_claude`: a human prompt with no
  completed assistant turn after it) catches both — so `send`/`chat`/`wait` see a prose-only turn as
  running and queue/wait correctly instead of racing onto it.

### Removed

- **The `--force` flag is gone from Linux `send`/`chat`/`fleet`.** Its only job was to bypass the
  mid-turn refuse guard, which no longer exists (busy agents queue instead). The Windows
  `win <host> chat`/`send --force` bypass (transcript-fetch failure / mid-turn) is unchanged.

## [0.26.0] - 2026-07-24

### Fixed

- **A message sent to an agent that is compacting is no longer reported as "not received."** When a
  claude worker is compacting its context (manual `/compact` or the auto window), the TUI **queues** an
  incoming message and runs it once compaction finishes — but the transcript shows no new turn and reads
  *idle*, so overseer used to (a) fail `send` at the submit step ("could not confirm the message
  submitted") even though the message was in fact queued, and (b) let `wait` return `idle` immediately,
  as if the turn were already done. An orchestrating admin agent therefore believed the worker never got
  the message. Now:
  - `_submit` recognizes Claude's queued-message state (`Press up to edit queued messages`) as a
    successful submit, so a queued message no longer looks like a stuck input box.
  - `send` reports `sent … (QUEUED — the agent is compacting its context / finishing its current turn)`
    and **exits 0** — the message was accepted and will run when the agent frees up. It points at
    `wait` for the reply.
  - `chat` announces the queue and **waits through** the compaction for the reply instead of racing.
  - `wait` treats a queued message as pending work and blocks until the queued turn actually completes,
    rather than returning `idle` during the compaction.

### Added

- **`fleet status` now shows a `compacting` state** (screen-detected: `Compacting conversation…` /
  `Compacting at auto window (`) so a compacting agent — which reads *idle* in the transcript — is no
  longer mislabeled `idle`. The fleet-wide broadcast preview consequently lists it under *skipped* (a
  message would only queue there), not as an idle recipient. New pure parsers `_compacting_text` /
  `_queued_text` are covered by `tests/run.sh` against a real captured `tests/fixtures/compacting-claude.txt`,
  including a negative fixture proving prose that merely mentions "compaction" is not matched.

## [0.25.0] - 2026-07-22

### Added

- **A fleet-wide broadcast now previews its blast radius and asks once.** `fleet --hosts send|chat` used
  to *require* `--yes` — a remote pane has no tty, so the per-pane confirm was simply dropped, which made
  the widest-reaching command in overseer the only one with no human gate. It now runs a **read-only
  status sweep first** (costs no agent turn, and warms the `ControlMaster` the real send then reuses),
  prints the message plus **exactly which idle agents would receive it** and which panes it will skip as
  `busy`/`awaiting`, and asks for **one confirmation** covering the whole batch. Local panes are included
  in the preview and the confirm, so you are asked once rather than once per pane.
  - `--dry-run` stops after the preview and sends nothing.
  - `--yes` skips the preview entirely (scripts/cron) — the previous behaviour, now opt-in instead of
    mandatory.
  - No idle agent anywhere → says so and exits without prompting.
  - No tty → fails closed ("aborted; nothing was sent").
  The preview is a snapshot: an agent that goes busy between preview and delivery is refused by its own
  mid-turn guard, so the list errs toward **skipping**, never toward sending wider than shown.
- Docs now state the risk plainly: every idle agent runs the broadcast in **its own** repo/cwd, so an
  imperative message hits N unrelated projects.

## [0.24.0] - 2026-07-22

### Added

- **`fleet` can span the whole fleet, not just local panes.** `fleet` still defaults to the local
  panes, but now takes the same inventory flags as `hosts` — **`--hosts`** (file / `~/.ssh/config`
  inventory), **`--tailscale [--os NAME]`** (tailnet), **`-u USER`** (login user for bare hosts). With
  one of them, every inventory host runs `on <host> fleet <sub>` — its *own* local sweep — in parallel,
  and the results are aggregated one section per host (`===== host =====`), local panes first under
  `===== local =====`. So `fleet --hosts status` surveys every agent on every machine in one command,
  and `on`'s first-touch auto-deploy means a never-provisioned host still answers. A cross-fleet
  broadcast has no tty to confirm at, so `fleet --hosts send`/`chat` **require `--yes`**. Local-only
  `fleet` (no inventory flag) is unchanged. The inventory resolution is now a shared `_inventory`
  helper used by both `fleet` and `hosts`; covered by new `tests/run.sh` unit tests against a
  `tests/fixtures/hosts` fixture.

### Fixed

- **`deploy` no longer hangs on an unreachable host.** `deploy`'s ssh was the one remote path without a
  `ConnectTimeout`, so a dead host blocked on TCP for the system default (~2 min) instead of failing
  fast. It now uses `-o ConnectTimeout=10` like every other remote call — which matters more now that
  `fleet --hosts` auto-deploys across a whole inventory, where one unreachable host would otherwise
  stall the batch.

## [0.23.0] - 2026-07-22

### Added

- **`on <host>` auto-deploys on first use.** You no longer have to `deploy <host>` before the first
  `on <host> …` — `on` runs a cheap `[ -f "$bin" ]` probe and, if `~/.overseer` isn't there yet, runs
  `deploy` once and then executes the command. The probe rides the same `ControlMaster` the real command
  then reuses, so it warms the connection rather than adding a round-trip. Scoped to the **default layout**:
  a custom `OVERSEER_REMOTE_BIN` (yours to manage) or `OVERSEER_NO_AUTODEPLOY=1` skips it, and a failed
  auto-deploy is fatal with a clear message. `deploy` stays the way to **update** a host after changing
  overseer. Covered by new `tests/run.sh` unit tests (`_on_ensure_deployed`, ssh + `cmd_deploy` mocked).

## [0.22.0] - 2026-07-22

### Added

- **Windows drive-surface parity — `send`, `slash`, `menu`, `quit` join the `win` verbs.** The Windows
  broker now has the same drive verbs as a Linux pane:
  - `win <host> send [--yes] [--force] <prompt|->` — place + submit + confirm the turn *started*, without
    waiting for the reply (the fire-and-continue peer of `chat`; shares `chat`'s placement + guards via a
    new `_win_place`, and confirms the start with `_win_wait_started`).
  - `win <host> slash </cmd>` — run a slash command (`/model`, …), pasted raw (no leading-`/` space
    guard) so the TUI actually enters command mode.
  - `win <host> menu <item> [nav-key]` — navigate a popup to a highlighted row. The console grid has **no
    colour**, so the new pure `_win_is_active_text` reads the highlight from the row's cursor glyph
    (`>`/`❯`/`›`) instead of ANSI SGR; default nav key `Down` (Windows popups are vertical).
  - `win <host> quit` — Ctrl-C the agent TUI (twice for Claude) to leave the broker's pwsh, the lighter
    peer of `stop`.
  Cheap to add now that the surface is unified (v0.21.0): each is one dispatcher entry + handler. Covered
  by new `tests/run.sh` (`_win_is_active_text`) and `tests/win-flow.sh` (send/slash/quit guards,
  `_win_wait_started` sig-gating) checks.

## [0.21.0] - 2026-07-22

### Changed

- **BREAKING — the Windows commands are unified under one prefix: `win <host>[/name] <verb>`.** The ten
  fused names are gone; `win` is now a transport prefix, exactly symmetric with `on <host> <verb>` for
  remote Linux, and the verb after it is the **same vocabulary as the Linux commands**. Mapping:
  `winbroker`→`win <host> start`, `winchat`→`win <host> chat`, `winwait`→`win <host> wait`,
  `winread`→`win <host> read`, `winpeek`→`win <host> peek`, `winsh`→`win <host> sh`,
  `winkeys`→`win <host> keys`, `winlist`→`win <host> list`, `winstop`→`win <host> stop`,
  `winshow`→`win <host> show`. `chat`'s `--yes`/`--force` now go **after** the verb
  (`win <host> chat --yes '…'`). No back-compat aliases (0.x, single user). A pure rename — no behaviour
  change; the delivery, guards, `mtime:size` gating and per-host lock are untouched.

### Internal

- `tests/run.sh` gains a win-verb tripwire: the `cmd_win` dispatcher's verb set must equal the
  `win verbs:` list in `--help`, so a verb can never drift undocumented. `tests/win-flow.sh` now drives
  the real `cmd_win` dispatcher. Rationale recorded in `docs/DECISIONS.md` (ADR-0004).

## [0.20.0] - 2026-07-22

### Added

- **`provision <host>` — install a Linux host's missing drive dependencies.** The fix for a `hosts`
  `DRIVE=no:tmux`/`no:jq`: it ssh's in, detects which of `tmux`/`jq` is absent, picks the package
  manager (`apt`/`dnf`/`yum`/`pacman`/`zypper`/`apk`), and installs only what's missing (idempotent — a
  host that already has both is a no-op). Runs non-interactively, so it needs **root or passwordless
  `sudo`** on the host and says so clearly when it has neither. `--dry-run` prints the exact command
  instead of running it. Scoped to the Linux base deps on purpose — Claude/Codex agents and every
  Windows prerequisite (admin login, a logged-in console user, the broker payloads) are still set up by
  hand, because they vary too much per host to script safely. The remote snippet is built by the pure
  `_provision_script`, fixture-tested in `tests/run.sh`.

### Documentation

- **How to handle every `hosts` `SSH` and `DRIVE` value.** README gains a "Surveying the fleet and
  fixing what's missing" section with a remediation table for each state — `SSH` `deny`/`hostkey`/
  `unreach` and `DRIVE` `no:tmux`/`no:jq`/`win*`/`no:macos`/`-` — and SKILL carries the compact version,
  so the survey → `provision` → re-survey loop is spelled out.

## [0.19.1] - 2026-07-22

### Changed

- **Docs and tests now use placeholder ssh targets** (`admin@win-host`, `fleetuser`, `user@host-a`,
  `C:/Users/user/…`) instead of real fleet host/user examples — this repository is public, and the
  examples were only ever meant to be illustrative. No behaviour change. (For the record, no secrets
  were ever committed: the Windows broker's auth token is generated at runtime and never written to a
  tracked file, and there are no keys, passwords or `.env` values in the tree.)

## [0.19.0] - 2026-07-22

### Added

- **`hosts`: the login user, and `--tailscale` enumeration.** The first `hosts` cut assumed every host's
  user + key lived in `~/.ssh/config`, but a Tailscale-native fleet is only *IPs* there — the shared
  login user (e.g. `fleetuser` across a rack of Windows boxes) lives nowhere, so probes silently fell back
  to the local username and reported a misleading `deny`. Now:
  - The `HOST` column shows the **effective `user@host`** — the user resolved from `ssh -G` (so an
    ssh-config `Host … User fleetuser` block is honoured *and visible*), so "it's about to log in as the
    wrong user" is something you can see rather than guess.
  - `-u USER` / `$OVERSEER_HOSTS_USER` forces the login user for any bare host, for the common
    "one user across the whole fleet" case where it isn't worth an ssh-config entry per machine.
  - `--tailscale` takes the inventory straight from `tailscale status` (filter with `--os windows` /
    `--os linux`) — so machines you never added to ssh config are still surveyed. It enumerates by
    **Tailscale IP** (not the MagicDNS short name): the IP is what an IP-keyed `~/.ssh/config` fleet
    block and `known_hosts` already cover, so it connects where the bare name trips host-key checking.
    Combine them: `overseer hosts --tailscale --os windows -u fleetuser`.
  - `SSH` now distinguishes **`hostkey`** (the host answered but its key isn't trusted yet — accept it
    or set `StrictHostKeyChecking accept-new`) from `unreach`, instead of mislabelling the former.
  - New pure enumerator `_ts_hosts` is fixture-tested in `tests/run.sh`.

## [0.18.0] - 2026-07-22

### Added

- **`hosts` — a fleet survey.** `overseer hosts` prints one line per host (`ONLINE OS SSH DRIVE`) so
  you can see which machines you can actually drive before an `on`/`win*`. The inventory of ssh targets
  comes from `$OVERSEER_HOSTS` if set, else `$XDG_CONFIG_HOME/overseer/hosts`, else the non-wildcard
  `Host` entries of `~/.ssh/config` — those carry the **user + key** a bare Tailscale IP lacks, which is
  the gap this fills. Each host is probed **live and in parallel**: `SSH` = `ok`/`deny`/`unreach`, `OS`
  = `linux`/`windows`/`macos`, `DRIVE` = `yes` (Linux with `tmux`+`jq`), `no:tmux`/`no:jq`, or `win*`
  for a reachable Windows host. `ONLINE` is filled from `tailscale status` when the CLI is present.
  Deliberately **stateless** — no credential or health database (ssh keys stay the credential;
  reachability is recomputed each run rather than cached, since a stored health value only goes stale),
  keeping [ADR-0002](docs/DECISIONS.md). `--list` prints the inventory without probing; `-t` sets the
  per-host ssh connect timeout (default 6s). Pure parsers (`_hosts_parse`, `_ssh_config_hosts`,
  `_ts_state`) are fixture-tested in `tests/run.sh`.

## [0.17.2] - 2026-07-22

### Fixed

- **`menu` could not make a numbered popup item active on current Claude Code (e.g. `/model`).**
  Claude 2.1.217 draws the selected row as `❯ 4. Sonnet` with the cursor, the number prefix and the
  label in separate 256-colour runs (`38;5;153`), so `_is_active`'s highlight match missed it on two
  counts: its colour list only knew the old cyan (`38;5;6`), and its cursor-glyph alternative required
  the label to sit *immediately* after the glyph (`❯ *label`), which the `N. ` prefix breaks. `menu`
  then cycled the whole list and gave up. The glyph alternative now tolerates a numbered prefix and
  inline SGR escapes between the cursor and the label — without jumping past another item's name on a
  single-line tab bar. The pure matcher was split out as `_is_active_text` and pinned by fixtures in
  `tests/run.sh` (the detector previously had **no** test coverage, which is why the drift went
  unnoticed).

## [0.17.1] - 2026-07-22

Documentation-accuracy pass — no code change. A three-agent audit against the code surfaced a handful
of stale claims (some predating 0.17.0).

### Fixed

- **Corrected the per-pane `flock` contention wording (README, SKILL).** Both stated a lock still
  contended after 30s "proceeds unlocked rather than failing." `_lock_pane` actually **aborts with an
  error** ("another overseer command has held the lock … retry when it finishes") in that case — only a
  *missing* `flock` proceeds unlocked. The docs had collapsed the two outcomes and assigned the wrong
  one to the timeout.
- **README requirements list: `tar` was missing and `scp`/`base64`/`iconv` were misattributed to `on`.**
  Per the actual `_need` map: `on` needs only `ssh`; `deploy` needs `ssh` + `tar`; `scp`/`base64`/`iconv`
  are used only by the Windows `win*` commands.
- **README "Compatibility" bumped to the live-verified Claude Code 2.1.217** (was 2.1.215; Codex 0.144.6
  unchanged).

### Documentation

- `start`/`stop`: documented the `%N`-pane arm of the self-kill guard and `start`'s non-existent-`workdir`
  refusal (README, SKILL, safety rule 8).
- **SECURITY.md** now covers `start`/`stop` as local side effects (the tmux analogue of
  `winbroker`/`winstop`).
- **CONTRIBUTING.md** lists the new `tests/stress.sh` start/stop lifecycle checks (F/F2/F3) and the
  `tests/run.sh` stubbed-`tmux` command-guard units.
- **docs/PORTING.md** notes that `start`'s agent-readiness poll rides the `/proc` discovery seam.
- **docs/DECISIONS.md** adds **ADR-0003** recording the attach-only → lifecycle decision and the
  detached-session / `start`-`stop` naming choices.

## [0.17.0] - 2026-07-22

Linux tmux lifecycle, to match what the Windows side already had: overseer can now **create and destroy**
its own tmux sessions — local and remote — instead of only attaching to ones someone else started.

### Added

- **`start <name> [shell|claude|codex] [workdir]`** opens a new **detached** tmux session named `<name>`
  running a shell (default), Claude Code or Codex. For an agent it blocks until the harness has actually
  come up (polls the same `_harness_of` discovery the rest of overseer uses) before returning, so a
  following `chat`/`wait` doesn't race the launch; for a shell it returns immediately. The user watches it
  with `tmux attach -t <name>`. It refuses a name outside `[A-Za-z0-9_-]` (tmux forbids `:`/`.`, and the
  restriction also keeps the name out of any injection surface) or one already in use, and a non-existent
  `workdir`. Because `on <host> …` runs the whole program remote-side, `on <host> start …` creates the
  session on the remote box with no extra machinery — the Linux create/reuse/delete story now works over
  the tailnet exactly as it does locally.
- **`stop <target>`** tears a session down: a `%N` pane → `kill-pane` (that one pane); a session name →
  `kill-session` (the whole session), which SIGHUPs the child agent/shell. It **refuses to kill the
  session overseer is itself running in** (comparing `$TMUX_PANE`), so it can't cut its own connection;
  that guard is inert under `on` (a remote ssh shell isn't in tmux), so remote `stop` is unrestricted.
  The Linux peer of `winstop`. Use `quit` when you only want to leave an agent's TUI but keep the pane.

## [0.16.0] - 2026-07-22

The documentation-and-test-honesty half of the audit: make the docs match the code and make the tests
prove what their names claim. No behavioural change beyond the `winpeek` fix.

### Changed

- **`tests/win-contracts.ps1` now executes the payloads instead of grepping their source.** It was
  entirely `Get-Content | -match` assertions — so a broker with authentication disabled behind
  `if ($false -and …)` still passed. It now AST-extracts each pure function and *calls* it:
  `Test-TranscriptPath` against the full scp-injection battery, `Get-ConfigPath` broker-name
  accept/reject, `Read-Frame` on good/bad/truncated frames, the descriptor JSON round-trip (the secret
  carries no transcript claim), and — on Windows — the codex claim isolation through the split state
  file. A smaller set of clearly-labeled `src:` tripwires still greps source for the Windows-runtime
  constructs a unit test cannot exercise (the pipe ACL, `FirstPipeInstance`, the anonymous client, the
  scheduled task, the ACL functions). Each executed check was mutation-verified to fail against broken
  code.
- **CI no longer gates on reader-performance timing.** The `stress` job set ceilings (`20s`/`8s`) with
  16–400× headroom over the real numbers, so a 10× regression shipped green — a decorative check. CI
  now runs the stress subset with `OVERSEER_STRESS_NO_PERF=1`, which measures the reader on an 18 MB
  rollout and *prints* the timing without asserting; run by hand the ceilings still gate.

### Fixed

- **`winpeek` normalizes the composer's U+00A0 to a space**, like every other Windows screen read —
  it was calling the raw client, so a Claude composer's non-breaking-space gutter showed through. This
  makes the v0.13.0 changelog's claim about `winpeek` actually true.

### Documentation

- Corrected drift the audit found across every surface: `CODEX_HOME` affects `doctor` only (live Codex
  discovery reads the open rollout off `/proc`), not `read`/`chat`/`wait`; `set -eu`, not `set -euo`,
  and no `pipefail`; CI runs on pushes to `main` and PRs, not "every push"; the Linux controller also
  needs `base64` and `iconv` for the remote/Windows commands; and removed the brittle "~25-command"
  counts from the design notes. The `win-contracts.ps1` and stress-perf descriptions in
  `CONTRIBUTING.md` and `docs/WINDOWS.md` now match what those tests actually do.

## [0.15.0] - 2026-07-22

The security half of the audit, for the remote-Windows transport. The broker runs **as the console
user**, so a fully-malicious console user can always spoof broker responses — that is inherent to the
architecture and is now stated plainly in [docs/WINDOWS.md](docs/WINDOWS.md) and `SECURITY.md`. What
these changes actually close is the path from a *semi-trusted* console user (or a third unprivileged
local account) to **running code as, or feeding forged paths to, the admin SSH client**. Verified
live against a real host in both same-account and admin≠console arrangements.

### Security

- **The broker descriptor is split, and its secret half is read-only to the console user.** The
  descriptor held the pipe name and the auth token in one file that the console user could *write*
  (it needed write access to record its transcript claim). A console user could therefore rewrite
  `Pipe` to point the admin client at a pipe of its own and spoof every response — fake `kind=shell`
  (so `winsh` types into an agent's chat box), fake screen, fake transcript path. The pipe/token now
  live in `<broker>.json` (Administrators/SYSTEM FullControl, console user **ReadAndExecute** only),
  and the transcript claim moved to a separate `<broker>.state.json` the console user may write. The
  console user can no longer redirect the control channel.
- **A crafted transcript path can no longer reach `scp`.** The broker resolves the transcript from the
  console user's own session dirs, so its *name* is attacker-influenced by design — a rollout file
  named `rollout-x' & calc & '.jsonl` used to flow straight into `scp`'s remote-source argument
  (command execution under legacy scp; arbitrary file read otherwise). Both the controller
  (`_win_txok`) and the broker (`Test-TranscriptPath`) now require an absolute Windows `.jsonl` path
  with no shell metacharacters before it is fetched; a spaced username stays valid.
- **`winshow` no longer interpolates the app name into PowerShell source.** The single-quote escaping
  was bypassable with a Unicode smart quote (`U+2019`), giving code execution as the SSH admin — the
  one overseer verb that runs admin-level code. The app name is passed as base64 and decoded in the
  payload; base64 cannot contain a quote of any kind.
- **The shared dirs and payload files are locked down before and after staging.** `%ProgramData%\
  overseer` and its subdirs are created with an explicit ACL (Administrators/SYSTEM + console-user
  read, **no `Authenticated Users`**) *before* the payloads are copied in, and each staged `.ps1` gets
  an owner-reset, inheritance-protected ACL on every launch — so a pre-planted file's DACL cannot
  persist. This also closes the brief window where the token-bearing descriptor inherited a
  world-readable ACL.
- **Hardening of the auth and pipe layer:** the token is compared length-first and case-sensitively
  (`[string]::Equals(..., Ordinal)`, no `-ne`'s case-insensitive base64 collision), the server pipe
  demands `FirstPipeInstance` (a squatter and the real broker can no longer coexist silently), the
  client connects with `TokenImpersonationLevel.Anonymous` (a spoofed broker cannot impersonate the
  admin client's token), broker-name anchors are `\z` not `$` (no trailing-newline match), and every
  `ssh`/`scp` invocation gained a `--` guard so a host beginning with `-` is not read as an option.
- **`winstop` and `winlist` account for the split file.** `quit` removes both `<broker>.json` and
  `<broker>.state.json`; `winlist` skips `*.state.json` so it does not show a phantom broker.

## [0.14.0] - 2026-07-21

This is the correctness half of a full audit (four independent review passes plus live runs against
real tmux panes and a real Windows host). Everything here was reproduced before it was fixed, and
every fix is pinned by a test that was proven to fail against the old code.

### Changed — these alter exit codes and may break scripts

- **`send` now fails when it cannot confirm the turn started.** It printed the "could not confirm"
  note and exited **0**, so `overseer send … || handle` treated a message still sitting unsent in the
  input box as success. `chat` already died on the same condition; `send` now matches it.
- **A lock timeout is fatal.** `_lock_pane` waits 30s for the per-pane `flock`, and on timeout used to
  `return 0` and carry on **unlocked** — interleaving keystrokes into a pane another invocation was
  already driving, which is the exact thing the lock exists to prevent. Only a missing or unusable
  `flock` still degrades to a no-op.
- **`doctor` fails on a broken contract probe or a broken awaiting detector.** Both were `[warn]`s
  that still exited 0, so a transcript schema shift or a non-UTF-8 locale — either of which stops
  `wait`/`chat` from working at all — reported `doctor: OK`. Environment gaps (no `codex` installed,
  no tmux server yet, no sessions on disk) stay `[warn]` and still exit 0.
- **`sh` refuses fish, tcsh, csh, nu, xonsh and elvish.** Its wrapper is POSIX-only (`VAR=x cmd …`),
  so those shells never echoed the sentinel and the command hung for the whole `OVERSEER_TIMEOUT`
  (default **600s**) before firing `C-c` at the pane. `_is_shell` still accepts them — it is right for
  its other two callers — and `sh` now gates on the narrower `_is_posix_shell`.

### Fixed

- **`win*` commands no longer die silently when the broker is unreachable.** `winsh`, `winchat`,
  `winwait`, `winread` and `winkeys` exited **3 with no output at all** against a stopped or missing
  broker: the remote client's nonzero exit propagated out of `st=$(_win_client stat)` and `set -e`
  killed the process before any of the carefully worded errors below it could run — including
  `winsh`'s whole "print the `ERR` line and the screen grid" branch, which was unreachable. Failed
  broker calls now report the verb, the broker, the host and the client's own output.
- **The awaiting-prompt detector no longer fires on a reply that contains a numbered line.** Counting
  marked-vs-total numbered lines anywhere on screen meant any `N.` line in the visible reply, plus a
  composer holding text that starts with a number, satisfied it — so `chat` announced "the agent is
  asking" instead of returning the reply. Detection is now a *run* of consecutively-numbered adjacent
  option lines, at least one marked and not all marked, which is what a menu actually looks like.
  Verified live on Claude and Codex menus and on a real markdown-list reply.
- **`winsh` reported a stale exit code.** `$LASTEXITCODE` is session-global in the broker's
  long-lived pwsh and is only written by *native* commands, so after any failing native command every
  later cmdlet-only command inherited its code — `winsh host 'Get-Date'` returning `exit=7`. It is
  reset immediately before the command runs.
- **`winchat` is interruptible again.** Its `INT`/`TERM` trap cleaned up but never re-raised, so bash
  resumed the wait loop: with the default 600s timeout only `SIGKILL` stopped it, and the trap had
  already deleted the temp file the still-running transcript fetch was writing into.
- **Codex is found when the pane's own process is `codex`.** Discovery scanned descendants only, so a
  standalone binary or an `exec`'d codex (rather than the npm `node` shim) reported "no agent pane".
  The Claude path already checked the pane pid itself.
- **`OVERSEER_POLL_INTERVAL` rejects every spelling of zero.** The hand-enumerated reject list missed
  `00`, `000`, `0.000` and friends, each of which turned the poll loop into a 100%-CPU spin.
- **`slash` reports a vanished pane** instead of exiting silently, matching `quit`.

## [0.13.2] - 2026-07-21

### Fixed
- **A message that can't be delivered because the agent is blocked on a question now says so.**
  `chat`/`send` (and `winchat`) failed with `could not place/verify message in input box` whenever the
  target had no usable composer — but the most common reason for that is an agent sitting on its own
  startup prompt (Codex's *"Do you trust the contents of this directory?"*, a permission menu), where
  there is no input box to paste into *yet*. The message named the symptom and hid the cause, so the
  obvious next step — answer the question, then resend — was the one thing the error didn't suggest.
  overseer could already read that question: `_awaiting` detects it, and `wait`/`fleet status` report
  it. The delivery path just never asked. It now does, and reports the pending question plus the
  `keys`/`send` follow-ups, falling back to the original wording when the pane genuinely isn't
  awaiting anything. Delivery still fails (nonzero exit, nothing submitted) — only the diagnosis
  changed.

## [0.13.1] - 2026-07-21

### Documentation
- **Corrected two false claims in `README.md`.** The intro said overseer *"opens (or attaches) a tmux
  pane, launches an agent harness in its shell"* — it does neither: on Linux it only discovers and
  drives a pane somebody else already started (the sole `tmux new-session` in the tree is `doctor
  --live`'s throwaway self-test), and `winbroker` is the one command that starts a child, because a
  Windows host has no pane to find. The troubleshooting section also quoted an error string,
  `"no claude pane for target"`, that no longer exists — it became
  `"no agent pane (claude/codex) for target"` when Codex support landed.
- **`SKILL.md` no longer claims `CLAUDE_HOME`/`CODEX_HOME` are validated at startup.** Only
  `OVERSEER_TIMEOUT` and `OVERSEER_POLL_INTERVAL` are; the home paths are plain `${VAR:-default}`
  substitutions.
- **`OVERSEER_REMOTE_DIR` is documented** in README and `SKILL.md`, with the constraint that it and
  `OVERSEER_REMOTE_BIN` must be changed together — `deploy` writes to one and `on` executes the other,
  so setting just one silently breaks every remote command.
- **`CONTRIBUTING.md` describes CI job-by-job in a table.** The prose omitted the `windows flow tests`
  step entirely and said the Windows job runs `tests/win-payloads.sh`, when it runs `win-parse.ps1` and
  `win-contracts.ps1` natively.
- **Brittle counts removed rather than corrected** — `tests/win-flow.sh`'s assertion count, an older
  entry's `win-contracts.ps1` count, and `docs/DECISIONS.md`'s `SKILL.md` size. All three had already
  rotted, the same way a line count in the 0.10.1 notes did; the numbers carried no information a
  reader could act on.
- **GitHub repository metadata refreshed** (About, topics) plus the manifest keywords, which still
  described a Claude-only, tmux-only tool.
- **`docs/WINDOWS.md`** records that Claude's console composer gutter is `>` + U+00A0 while Codex's is
  `›` + a plain space — verified live by dumping the raw grid bytes of both. That difference is why the
  U+00A0 delivery bug hit Claude only.

### Added
- **`tests/win-parse.ps1`** — the payload parse check, lifted out of the workflow's inline script so
  CI and a local run execute the same file. It is also stricter than the inline version it replaces:
  it resolves paths from `$PSScriptRoot` instead of the working directory, and it **fails when the
  glob matches nothing** (the inline loop would have reported success if the payloads were ever moved
  or renamed).
- **`tests/win-payloads.sh`** — runs `win-parse.ps1` and `win-contracts.ps1` locally in one command.
  PowerShell runs on Linux, so the Windows payloads are checkable **before** pushing rather than only
  by the `windows-latest` job; `OVERSEER_PWSH` points it at a non-`PATH` install. Exit 1 = a payload
  failed, 2 = no PowerShell found. It is a convenience only — the `windows-latest` job remains the
  gate, and still runs both `.ps1` files natively under `pwsh`. Verified it fails (rc=1) on a
  deliberately broken payload; the last two red CI runs were PowerShell-only defects it catches.

## [0.13.0] - 2026-07-21

### Fixed
- **A single-line `winchat` could never verify its prompt against Claude Code on a Windows console.**
  Claude renders the composer gutter as `>` followed by **U+00A0 NO-BREAK SPACE**, which POSIX
  `[[:space:]]` does not match, so the captured text kept a leading NBSP, the equality check against
  the sent message always failed, and `winchat` aborted with "could not place/verify the prompt" after
  clearing the box. A *multi-line* prompt was unaffected because it verifies through the paste chip
  instead — which is why the bug survived every earlier live test. `_win_snap` now normalizes U+00A0 to
  a plain space as it reads the grid, so delivery verification, the awaiting-prompt detector and
  `winpeek` all see the same text a human does. Found and fixed live; the reply now round-trips.
- **`winstop` can now clean up after a broker that already died.** Stopping went through the pipe, so a
  broker whose console had closed (its child exited) left its descriptor behind: `winstop` reported
  `ERR connect failed`, `winlist` showed `state=offline` forever, and only a manual delete cleared it.
  `quit` now removes the descriptor whether or not the pipe answers, and says which happened.
- **`winstop` exits non-zero when the broker refuses or is missing**, instead of swallowing the `ERR`
  line and reporting success.

### Added
- **`OVERSEER_WIN_CLAUDE` / `OVERSEER_WIN_CODEX`** (defaults `claude` / `codex`) name the command
  `winbroker` launches on a Windows host. The agent's command name is host-specific — a machine whose
  users go through a renamed wrapper previously got a broker running the wrong binary, which
  starts, paints, and answers every prompt with `Not logged in`. The value must be a bare command name,
  travels base64-encoded, and is decoded into a parameter rather than interpolated, like `workdir`. The
  broker's `kind` stays `claude`/`codex`, so transcript reading and turn detection are untouched.
- **`tests/win-flow.sh`** — mocks the two remote chokepoints (`_win_client`,
  `_win_fetch`) and run the real `win*` bash orchestration against a recorded call log: the scp-failure
  and mid-turn guards fail closed and never submit, `--force` bypasses each, a `pwsh`/dead-child/Codex-`!`
  target is refused before anything is pasted, a failed submit or unverified delivery clears the box
  after pasting, `mtime:size` gating refetches on an mtime-only change but not on an unchanged
  signature, a child that exits mid-turn fails fast with rc=3, and broker-target parsing rejects
  traversal. Runs in CI with no ssh and no host.

## [0.12.1] - 2026-07-21

### Fixed
- **A markdown blockquote of a numbered list no longer reads as an interactive menu.** v0.10.1 added the
  ASCII `>` cursor for Claude Code on a Windows console to the *shared* `_awaiting_text` parser, so on
  **Linux** an ordinary reply containing

  ```
  > 1. read the file
  > 2. patch it
  ```

  matched the awaiting-prompt detector: `chat`/`wait` returned "awaiting input" and stopped waiting for
  the real turn, and `fleet status` reported the pane as `awaiting`. Two fixes, both covered by
  fixtures: the accepted glyph set is now a parameter — `_win_awaiting` passes `❯›>`, Linux `_awaiting`
  keeps the strict `❯›` — and both paths now require that **not every** numbered line carries the
  glyph, since a real menu marks only the selected row. That second rule also protects the Windows
  path, where `>` legitimately is a cursor.

## [0.12.0] - 2026-07-21

### Fixed
- **`on <host>` no longer requires the remote login shell to be bash.** Argv was serialized with
  `printf %q`, which emits bash-only `$'…'` for anything with a newline, tab, or quote; a `dash`/`ash`
  login shell passed that through literally and the remote overseer received mangled arguments. It is
  now POSIX single-quote quoting, which every POSIX shell parses identically. `stdin` stays free, so
  `on <host> chat %0 -` still reads the prompt body from the pipe.
- **`doctor`'s contract probe handles session paths containing spaces.** The scan word-split `ls`
  output, so a project directory with a space in its name silently probed a nonexistent file and the
  probe reported a false schema shift.
- **`OVERSEER_POLL_INTERVAL` rejects values that are not a positive number.** `.`, `1..2`, `0`, and
  `0.0` all passed validation; the first two made every `sleep` fail and zero spun the poll loop at
  100% CPU. Covered by fixture tests for both the accepted and the rejected forms.
- **`_win_cp` honours `OVERSEER_SSH`**, passing it to `scp -S` so a custom ssh binary applies to the
  transcript fetch as it already did to every other Windows call.

### Changed
- **Release recovery is no longer manual.** If `autotag` finds the version tag already present it now
  checks whether the matching GitHub Release exists and publishes it if not, instead of standing down
  and leaving a tag with no release. `release.yml` (the human-pushed-tag path) first validates that the
  tag version equals both manifests and has a `## [x.y.z]` CHANGELOG heading, and is idempotent.
- **The support model is stated consistently everywhere** — README, `SKILL.md` frontmatter and scope
  section, both manifest descriptions, and the entry-script header: overseer is a **Linux controller**
  driving **local/remote Linux tmux panes** and **remote native Windows console brokers over SSH**;
  local pane discovery stays Linux + tmux only. The skill previously advertised itself as tmux-only, so
  a request to drive a Windows machine could fail to activate it.
- **The Windows walkthroughs show the whole broker lifecycle** (`winbroker` → `winchat`/`winwait`/
  `winread` or `winsh` → `winstop`) rather than only `winshow`, and describe the turn poll as gated on
  the broker's `mtime:size` signature rather than "when it grew".

### Documentation
- **`docs/WINDOWS.md` is the canonical Windows reference**, now covering the v0.11.0 descriptor/auth
  design, a prerequisites table, a security model section, `SNAPALL` and the screen-buffer growth, the
  descriptor-based transcript claiming (and why its ACL must grant `Modify`), and the PowerShell traps
  found live — read-only `$pid`, `List[int]` unrolling, the missing pipe constructor overload,
  `GetFinalPathNameByHandle` blocking on pipes. README and `SKILL.md` link to it.
- **`SECURITY.md` and the skill's safety rules cover the `win*` commands** — remote execution as the
  console user, visible-desktop side effects, the named-pipe trust boundary, and never relaying a
  broker descriptor.
- **CONTRIBUTING is current**: Claude *and* Codex are documented as supported with the real `_h_*`
  seam described, the Windows parser/contract CI job is listed, the comment policy is stated
  (preserve existing ones, add none), and a conditional Windows live-verification checklist is added —
  mirrored in the PR template. The bug template gained a target dropdown and sanitized Windows fields.
- `tests/run.sh` asserts these doc contracts, so the support-model wording, `mtime:size` wording,
  Windows links and live-test checklist cannot silently disappear.

## [0.11.0] - 2026-07-21

### Security
- **The Windows broker pipe is now unguessable and authenticated.** It was named `overseer-broker[-name]`
  — predictable and machine-wide — and accepted `TYPE`/`PASTE`/`KEY`/`QUIT` from any local caller, so
  anything able to reach it could type into the driven agent. Each launch now mints a random pipe name
  plus a 256-bit capability token, records both in an ACL-protected descriptor under
  `%ProgramData%\overseer\brokers`, applies an explicit `PipeSecurity` allowing only the console user
  and Administrators, and requires an `AUTH` handshake before any verb. Verified live: connecting by the
  old predictable name fails, and a wrong token is refused with `ERR auth`.
- **`workdir` is no longer interpolated into a remote PowerShell command line.** PowerShell expands
  `$(...)` inside double quotes, so a crafted workdir could execute under the SSH identity. It now
  travels base64-encoded and is decoded into a parameter value.
- **Payloads are staged in `%ProgramData%\overseer`, not the SSH user's profile**, so the documented
  setup where the SSH admin differs from the console user actually works instead of silently failing.

### Fixed
- **Two Codex brokers no longer share one transcript.** Resolution picked the newest rollout written
  after the child started and cached it forever, so a second broker could bind to the first one's file
  and report its replies. Each broker now claims a rollout in its own descriptor and skips rollouts
  claimed by siblings. Verified live: two concurrent Codex brokers produced distinct rollouts, and
  `winread` returned `ALPHAWIN` and `BETAWIN` to the right broker.
- **Claude transcript resolution no longer falls back to "newest jsonl on the box"** — it resolves the
  session id from a descendant-owned `sessions/<pid>.json` and reports no transcript until its own file
  exists.
- **`winstop` no longer orphans the agent.** Teardown walked the tree but killed it parent-first (a
  `List[int]` returned from a function is unrolled to `Object[]`, whose missing `.Reverse()` silently
  reordered the kill), so killing the console-sharing shell took the broker down before it reached the
  agent. Kills are now leaf-first by index, retried, and verified. Verified live: `codex=0 brokers=0`.
- **`winsh` no longer times out on output taller than the window.** The console screen buffer is the
  window height by default, so the opening sentinel was destroyed rather than scrolled. The broker now
  enlarges the buffer at startup and serves scrollback via `SNAPALL`. Verified live: all 200 lines of a
  200-line command captured with `exit=0`.
- **Delivery is verified against the composer, not the whole screen.** A 24-character substring probe
  anywhere on screen counted as success; a single-line prompt is now matched for equality on the input
  row, and a multi-line prompt against its paste chip.
- **An aborted `winchat` clears the remote input box** instead of leaving the prompt staged where a
  later `Enter` would submit it.
- **A failed transcript fetch no longer silently bypasses the mid-turn guard** — `winchat` fails closed
  unless `--force` is given.
- **`winsh`/`winchat` check broker kind, liveness and busy state under the per-broker lock**, closing a
  window where a concurrent `winbroker` could swap the child between the check and the keystrokes.
- **The client fails loudly.** Protocol errors, missing descriptors, failed authentication, malformed
  frames and a failed submit now exit non-zero instead of returning success, and `winbroker` fails
  unless the child actually paints.

### Added
- **Windows payloads are covered in CI.** A `windows-latest` job parses every `win-*.ps1` with the
  PowerShell parser and runs `tests/win-contracts.ps1` (assertions over the auth handshake, pipe ACL,
  descriptor handling, argument encoding, teardown order and error exits). The parser check immediately
  caught two real defects — a `$line:` scope-qualified variable and a `.Reverse()` on an unrolled array
  — that had shipped past every existing check.
- `OVERSEER_SCP` overrides the `scp` binary, matching `OVERSEER_SSH`.

### Changed
- The broker records the exact child pid from `Start-Process -PassThru` rather than guessing "first
  child", which is what made the descendant walk unreliable.
- Broker terminating errors are logged; a broker that dies during startup or teardown is no longer
  silent.

## [0.10.1] - 2026-07-21

### Added
- **Windows parsers are now covered by CI.** `tests/run.sh` asserts `_win_split` (bare host, `user@ip`,
  `<host>/<name>`, and the three rejection cases) and `_win_field`/`_win_sig` against real `STAT`/`INFO`
  lines. Until now the whole Windows path had zero automated coverage, even though its parsers are
  exactly the kind that shipped broken in 0.9.0 and passed CI.
- **`docs/WINDOWS.md`** — the mechanism and its constraints in one place: the Session 0 → Session 1
  scheduled-task bridge and its battery/time-limit traps, the tmux↔broker primitive mapping, and the
  console-input facts that no documentation states (a raw `ESC` is never delivered, so bracketed paste
  is impossible; a `\r`/`\n` with `wVirtualKeyCode = 0` is swallowed; `Ctrl+J` is what inserts a
  composer newline; the box must be cleared first). The no-prose-comments rule keeps these out of the
  scripts, and until now they lived only in commit messages.
- **ADR-0002** records why overseer stays a Claude Code *skill + hooks* rather than becoming an MCP
  server or a subagent.

### Changed
- **`lib/windows.sh` split out of `lib/commands.sh`.** `commands.sh` had grown past 650 lines mixing
  four concerns; it now holds only the local/ssh commands, with the `win*` surface in its own lib.
  No behaviour change from the move.
- **The Windows turn poll gates on `mtime:size`, not size alone**, matching `_file_sig` on Linux. The
  broker already reported `mtime` over `STAT` and nothing read it; a same-size rewrite of the transcript
  could previously be missed.
- **ADR-0001's "revisit if Windows support is wanted" trigger is marked as fired and resolved** — it
  predicted a rewrite would be the honest path, and 0.8.0 showed a native broker plus the unchanged bash
  seam was enough. Recording the outcome keeps the decision log from arguing against shipped reality.

### Fixed
- `winbroker` and `winstop` now take the same per-broker lock as `winkeys`/`winsh`/`winchat`, so
  restarting or stopping a broker cannot interleave with an in-flight command on that broker.

## [0.10.0] - 2026-07-21

### Added
- **`winread <host>[/name]`** — the Windows peer of `read`: the last user prompt + last assistant
  reply from the broker's agent, off its transcript, through the same `transcript.sh` readers. Until
  now the only way to see a Windows agent's last exchange was `winpeek`, a noisy TUI screenshot.
- **`winwait <host>[/name] [timeout]`** — the Windows peer of `wait`: block until the current turn
  ends, return the **question** if the agent is stopped at an interactive prompt, print `idle` if it
  was not busy. This is what a `winchat` timeout now points at, so a long turn is resumed instead of
  re-sending the prompt.
- **Several brokers per Windows host.** Every `win*` command takes `<host>[/name]`; the name selects
  the broker's pipe (`overseer-broker-<name>`, default `overseer-broker`), so a Claude and a Codex —
  or two agents on different repos — can run side by side in their own console windows:
  `winbroker win-host/codex2 codex` then `winchat win-host/codex2 '...'`. Starting a broker now only
  replaces the one with the same name (and kills its whole process tree, not just its direct child),
  and its scheduled task is named per broker so two launches cannot collide.
- **`winlist <host>`** — the Windows peer of `list`: every overseer broker on the host with its
  child kind, working directory and whether the child is alive.

### Fixed
- **A multi-line prompt to a Windows agent now arrives verbatim.** 0.9.0 wrapped it in
  bracketed-paste markers, but `WriteConsoleInput` never delivers the `ESC` of those markers — the
  agent recorded the literal `[200~`/`[201~` around the prompt, and the newlines were swallowed
  entirely, so the lines ran together. Newlines are now injected as the composer's own newline key
  (Ctrl+J), which both Claude Code and Codex accept as a line break rather than a submit. Verified by
  reading back what each agent actually recorded.
- **The input box is cleared before the prompt is placed**, as `_paste_verified` has always done on
  Linux. Without it, whatever the box already held was prepended to the prompt and submitted with it
  — observed live as a stray fragment glued to the first line.

### Changed
- `winchat`'s wait, `winwait`'s wait, and their awaiting/liveness handling are one shared helper, so
  the two commands cannot drift.

## [0.9.0] - 2026-07-21

### Added
- **`winchat` now carries the same guards as `chat`.** It previously had none, so driving a Windows
  agent was materially less safe than driving a Linux one:
  - **Refuses a Codex prompt starting with `!`** — Codex runs such a message as a *shell command* by
    its design, so `winchat <host> '!<cmd>'` silently executed on the Windows box. This is the same
    refusal `_deliver` has always applied on Linux.
  - **Prepends a space for Claude's `/ ! # @`**, so a prompt leading with one of those arrives as
    chat instead of opening command/bash/memory/file mode.
  - **Strips C0 control bytes** from the prompt.
  - **Refuses a mid-turn agent** (`_h_is_busy` on the fetched transcript); `--force` bypasses.
  - **`--yes`** — without it, the prompt is placed, verified, and shown for confirmation before it is
    submitted (matching `chat`/`send`).
  - **Returns the question** when the agent stops at an interactive permission/menu prompt, instead
    of hanging to timeout. The broker's `SNAP` is an already-rendered console grid, so the existing
    `_awaiting_text` screen parser reads it unchanged — no second implementation.
  - **Fails fast when the agent exits mid-turn** rather than waiting out the timeout.
  - **Per-host lock** (`_lock_pane`) around delivery in `winchat`/`winkeys`/`winsh`, so two overseer
    invocations can no longer interleave keystrokes into the same broker.
- **Multi-line prompts to a Windows agent** (`winchat <host> -` reads stdin). A new broker `PASTE`
  verb wraps the text in bracketed-paste markers and emits newlines as characters; the old `TYPE`
  path sent a newline as a real `VK_RETURN`, which submitted a multi-line prompt at its first line.
  Delivery is verified on screen before Enter, mirroring `_paste_verified`.
- **`winsh` refuses a broker that is hosting an agent.** It previously typed the command line into
  whatever child was running — including a Claude/Codex chat box, which then submitted it as a
  message.

### Fixed
- **A Windows broker child now runs through the user's PowerShell profile**, so it behaves exactly
  like the user opening their terminal and typing `claude` / `codex` / `pwsh`. The launcher started
  `claude.exe` directly and passed `-NoProfile` to the pwsh wrappers, so any environment the user
  sets in their profile was missing — on the test host that profile dot-sources the file configuring
  a third-party API, so the broker's Claude fell back to "Not logged in · Please run /login" while
  the same command in the user's own terminal worked.
- **An interactive prompt is now detected on a Windows console.** Claude Code draws the selection
  cursor as an ASCII `>` there rather than `❯`, so `_awaiting_text` never matched a Windows grid and
  `winchat` would have waited out its whole timeout at a permission/menu prompt. The cursor class now
  accepts `>` as well, still gated on two or more numbered options. A real Windows-console capture is
  now a fixture (`awaiting-windows-console.txt`) so this cannot regress.
- **`winbroker` waits for the child to actually paint** before returning, not merely for the pipe to
  appear. A `winsh`/`winchat` issued immediately after could otherwise race the child's startup and
  time out looking for its sentinels.
- **`scp` is retried like `ssh`.** Payload upload and transcript fetch had no retry, so a single
  dropped packet on a relayed tailnet link failed the whole command.
- **`winsh` always reports a numeric exit code.** PowerShell only sets `$LASTEXITCODE` for native
  commands, so a cmdlet-only line reported an empty exit; it now falls back to the command's success
  status.

### Changed
- **`winchat`'s wait no longer copies the whole transcript every poll.** A new broker `STAT` verb
  reports `alive`/`size`/`mtime`/`transcript`, and the transcript is refetched only when its size
  changed — the same size-gated poll the Linux reader uses. A long Codex rollout is multiple MB, so
  the old loop re-copied it over the network every 0.5s.
- **The broker resolves the transcript of *its own* child**, not the newest file on the machine:
  Claude via the `sessions/<pid>.json` → `sessionId` chain over the child's descendant pids (the
  Windows twin of `_agent_pid`/`_sid_of`), Codex by restricting rollouts to those written since the
  child started. Another agent running on the same Windows box no longer shadows it.
- Broker input is written in bounded chunks, so a long paste cannot overflow the console input
  buffer.

## [0.8.0] - 2026-07-21

### Added
- **Drive a shell / Claude Code / Codex on a remote Windows host, turn-based, over plain ssh
  (`winbroker` + `winpeek`/`winkeys`/`winsh`/`winchat`/`winstop`).** A plain-SSH Windows host has no
  tmux, and an ssh login lands in the invisible **Session 0**, so the existing `on`/tmux path can't
  reach it. `overseer winbroker <host> [pwsh|claude|codex] [workdir]` launches a small cooperative
  PowerShell **broker** on the host's logged-in **console** (Session 1, via the same interactive
  scheduled-task bridge as `winshow`), hosting the chosen child in a window the user watches. The broker
  is the tmux stand-in: it shares the child's console and exposes a **machine-wide named pipe**
  (reachable from Session 0) whose protocol maps `WriteConsoleInput` → tmux `send-keys` and
  `ReadConsoleOutputCharacter` → `capture-pane`, so the rendered screen grid comes back for free (no VT
  emulator). It opens in the host's Windows Terminal default directory unless `[workdir]` is given.
  - `winpeek <host>` snapshots the broker screen; `winkeys <host> <key|text>…` injects named keys
    (`Enter` `Escape` `Up` `C-c` …) or literal text (a TUI needs a **separate** `Enter` to submit a
    pasted burst); `winsh <host> <command>` runs one command line in a pwsh child with a sentinel and
    returns output + exit code; `winstop <host>` stops the broker.
  - `winchat <host> <prompt>` sends a prompt to a claude/codex child, submits it, and waits for the turn
    by reading the agent's on-disk transcript with the **same `transcript.sh` readers** overseer uses
    locally — run on the rollout/session `.jsonl` fetched back over ssh — so completion detection is one
    seam across Linux and Windows, not a reimplementation. Prints the reply.
  - Payloads: `scripts/win-broker.ps1` (console-API host + pipe server), `scripts/win-client.ps1` (the
    one-shot `info|snap|type|key|sh|quit` client), `scripts/win-launch.ps1` (the Session-1 launcher).
    Requires an **admin** ssh login and PowerShell 7 on the Windows host.

## [0.7.0] - 2026-07-20

### Added
- **Open a GUI on a remote Windows host's visible desktop (`winshow`).** `overseer winshow <host> [app]`
  opens a GUI app — default Windows Terminal, or any Start-menu name / AUMID / full exe path — on the
  **console session** of a remote Windows machine over plain ssh. overseer itself can't run on Windows
  (no `/proc`, no native tmux); it only ssh-executes a small PowerShell launcher. An ssh login on
  Windows lands in the non-interactive **Session 0**, so a naive GUI launch is invisible — `winshow`
  bridges to the logged-in desktop with a throwaway interactive scheduled task (`-LogonType Interactive`
  as the live-resolved console user) and clears two silent traps: a laptop **on battery** (default tasks
  carry `DisallowStartIfOnBatteries`, so they sit `Queued` and never launch) and Windows Terminal's
  **app-execution-alias** stub (launched by AUMID via `explorer.exe shell:AppsFolder\…`, not a direct
  `CreateProcess`). It confirms a new top-level window appeared and errors clearly when nobody is at the
  console. Needs an admin ssh login on the Windows host. This supersedes the earlier "run the agent in
  WSL2" guidance — a Windows machine's desktop is now reachable directly.

## [0.6.0] - 2026-07-20

### Added
- **Drive panes on remote Linux hosts over SSH (`on`, `deploy`).** `overseer on <host> <command> [args]`
  runs any command on a remote ssh host and streams the result back; `overseer deploy <host>` copies the
  scripts to `~/.overseer` there first. The *whole* program executes remote-side, so its tmux / `/proc` /
  transcript reads stay co-located and discovery + completion detection work unchanged — only the
  invocation and result cross the wire. A blocking `chat`/`wait`/`sh` runs its poll loop on the remote
  (reading that host's own transcript and hook markers — no new event channel); one-shots reuse one
  multiplexed connection via `ControlMaster`+`ControlPersist`. `<host>` is any ssh target (`user@host`, a
  `~/.ssh/config` alias, or a Tailscale MagicDNS name); credentials are ssh's own, so overseer keeps no
  daemon, DB, or token store. `overseer on <host> doctor` is the remote preflight. New overrides:
  `OVERSEER_REMOTE_BIN`, `OVERSEER_SSH`, `OVERSEER_SSH_OPTS`. Native Windows stays out of scope (no
  `/proc`, no native tmux); run the agent in WSL2 and target that as ordinary Linux.

## [0.5.17] - 2026-07-20

### Docs
- **Every documented behaviour now matches the code.** A three-axis audit (command surface · documented
  behaviour vs code · release hygiene) found ~20 statements that had drifted as the plugin gained
  commands; all are corrected across the built-in help, `README.md`, `SKILL.md` and `docs/`. The ones
  that actively misled:
  - **`menu` was described three different ways** — the built-in help said "claude only", the docs said
    "Agent (Claude/Codex)", and the code gates on neither: it drives *any* pane off what is highlighted
    on screen. Now stated as "any pane" everywhere, with the `Right`-vs-`Down` nav-key guidance kept.
  - **`doctor` was missing from `SKILL.md` entirely**, so the agent-facing surface listed 12 of 13
    commands.
  - **`--yes` and `--force` were written `[--yes|--force]`** as if mutually exclusive; they are
    independent and combinable, which the code's own usage strings already said. Both `fleet` usage
    strings also disagreed with each other about `--force`.
  - **The awaiting detector needs *two or more* numbered options** — a single-option or unnumbered y/n
    prompt is not matched and `chat`/`wait` run to timeout. Previously only the searchable-picker
    exclusion was documented.
  - **`sh` brackets the command with two sentinels, not one**, and reports (rather than silently drops)
    output whose opening sentinel outran the pane scrollback.
  - **Busy/idle comes from the transcript, not the "dim ghost suggestion"** — the ghost only
    distinguishes an empty input box from a full one. The old wording contradicted this file's own
    completion-detection section.
  - **Copy-mode is cancelled before *writes* and before the awaiting check**, not before "any
    read/write": `peek`/`read` deliberately leave a scrolled pane alone.
  - **Marker pruning runs at most once every 24h**, not "on the next turn".
- Also newly documented: per-pane `flock` serialization (including that it proceeds unlocked when
  contended past 30s), `CODEX_HOME`, the `bash >= 4.1` requirement and the real `jq` scope in
  `SKILL.md`, the `list`/`fleet` foreground-command pre-filter, `fleet`'s `idle(0-turn)` /
  `(not an agent)` states and its bare-`fleet` default, and the `doctor live` / `peek -e|--raw` /
  bare-name `slash` aliases. `docs/PORTING.md` no longer presents the bash-version question as open (it
  is decided and enforced), and `docs/DECISIONS.md` drops a line count that had already rotted.
- **CHANGELOG: 0.5.5, 0.5.6 and 0.5.7 got their own headings.** Their notes had been folded under
  `[0.5.8]`, leaving one version block with `### Changed` three times and no record of what each
  release actually contained.

## [0.5.16] - 2026-07-20

### Fixed
- **`doctor --live` reported `doctor: OK` (exit 0) even when its own self-test printed `[FAIL]`.**
  `_doctor_live` never fed its result back into the `bad` flag, so the one check that exercises the real
  send-keys/capture-pane path could fail while `doctor` still declared the runtime healthy — a false
  green, the worst outcome for a preflight. It now returns non-zero on `[FAIL]` and `doctor` exits 1.
  `[skip]` outcomes (no tmux, no throwaway session) stay non-fatal, as before.
- **`chat`/`wait` read a frozen screen when the pane was scrolled up.** A pane in tmux copy-mode serves
  the *scrolled* view to `capture-pane`, so `_awaiting` could miss a permission/select prompt the agent
  was actually blocked on and hang to timeout instead of returning the question. `_awaiting` now cancels
  copy-mode first (`_wake_pane`), so the awaiting detector always reads the live screen. `fleet status`
  goes through the same detector and therefore also reports live state rather than a frozen one. The
  read-only `peek`/`read` paths are deliberately left alone — they never cancel a scroll you set up.

Both bugs were found by a three-axis audit (command surface, documented behaviour vs code, release
hygiene) rather than by use; the doc drift the same audit turned up is addressed separately.

## [0.5.15] - 2026-07-20

### Changed
- **CI now *runs* the harness-free stress subset, not just lint-checks it.** A new `stress` job installs
  tmux and executes `tests/stress.sh`, which — with no `OVERSEER_STRESS_CODEX_PANE` set — covers
  multi-pane concurrency, per-pane lock serialization, large-rollout (~18 MB) reader perf, and mid-turn
  crash liveness against throwaway shell panes (no Claude/Codex needed). This turns four core properties
  from *manual-only* into *automated regression gates*. Only the Codex `!`-refuse check (needs a real
  Codex pane) stays manual. The reader-perf ceilings are env-tunable (`OVERSEER_STRESS_PERF_LASTREPLY`,
  `OVERSEER_STRESS_PERF_TURNS`) and set generously in CI so a genuine O(n²)-style regression still fails
  while normal runner variance doesn't.

## [0.5.14] - 2026-07-20

### Fixed
- **Error output was being swallowed by every box-mutating command since v0.5.9.** The per-pane lock
  helpers opened their fd with `exec {fd}>"$f" 2>/dev/null` — but `exec` *with no command* applies both
  redirections to the **current shell permanently**, so `2>/dev/null` silenced stderr for the rest of the
  process. Any later `_die`/warning from `chat`/`send`/`sh`/`slash`/`menu`/`keys` printed nothing (a
  command could fail with an empty message). Scoping the redirect to a group (`{ exec {fd}>"$f"; }
  2>/dev/null`) keeps the fd open while restoring stderr. Caught by the new stress harness.
- **Codex now refuses a message starting with `!` instead of running it as a shell command.** Codex
  treats a submitted `!…` as a Shell-mode command (its design) — trimming or space-guarding doesn't stop
  it — so `chat`/`send` on such a message could execute arbitrary shell in the watched session. `_deliver`
  now refuses it with a clear message pointing at `sh <target> '<cmd>'` (or rewording).

### Added
- **`tests/stress.sh`** — a manual (non-CI, tmux-required) verification harness for the live paths the
  fixture tests can't reach: 8-pane concurrent `sh` isolation, 5-way same-pane lock serialization,
  large-rollout (~18 MB) reader perf, mid-turn crash liveness (`rc=3`, not timeout), and — with
  `OVERSEER_STRESS_CODEX_PANE=%N` — the Codex `!`-refuse safety against a real pane. CI lint-checks it
  (`bash -n` + shellcheck); it is run by hand. This capstone run is what surfaced the two fixes above.

## [0.5.13] - 2026-07-20

### Added
- **`overseer doctor --live`** — an opt-in end-to-end self-test. Plain `doctor` stays static (no side
  effects); with `--live` it spins up a *throwaway* tmux session, runs one `sh` round-trip through it
  (send-keys → sentinel → capture-pane), reports ok/FAIL, and tears the session down. This exercises the
  whole shell-driving path — tmux plumbing, the sentinel protocol, `_is_shell`, wake/env-neutralization
  — against a real pane, catching a broken tmux or locale that the static checks can't. Verified live:
  plain `doctor` spawns nothing; `--live` reports ok and leaves no session behind.

### Docs
- **Clarified why searchable pickers aren't auto-detected as "awaiting" — it is intentional, not a gap.**
  Live investigation (Codex's `@`-mention list) confirmed these are input-box UI the user opens by typing
  (`@`, a slash command), never a state a turn ends in, and their on-screen chrome (a leading `>`/`›`, an
  "esc to cancel" footer) overlaps a normal reply's markdown — so auto-detecting them would risk
  false-positives on real answers on the core `chat`/`wait` path. They stay driven by `peek` + `keys`, as
  documented. (No detector change shipped, by design.)

## [0.5.12] - 2026-07-20

### Added
- **`fleet` — one command over every agent pane at once.** A thin fan-out on top of the existing
  per-pane commands (not a scheduler): `fleet status` prints one line per discovered Claude/Codex pane
  (harness + idle/busy/awaiting); `fleet read` and `fleet wait [timeout]` fan those out; `fleet send` /
  `fleet chat [--yes] <msg>` **broadcast** the same message to all agent panes. Each pane is handled in
  its own subshell, so one pane erroring (mid-turn, timed out, exited) never aborts the batch, and every
  pane keeps its own guards (confirm-unless-`--yes`, mid-turn refuse, per-pane lock). Verified live:
  `status`/`read`/`wait` across 4 mixed panes, and `send`/`chat` argument threading (`flags → pane →
  msg`) in isolation without broadcasting to live sessions.

## [0.5.11] - 2026-07-20

### Added
- **`chat`/`wait` fail fast when the agent exits mid-turn.** The wait loop watched only the transcript,
  so if the driven Claude/Codex crashed (or was `quit`) mid-turn it would wait out the entire
  `[timeout]` (default 600s) for a reply that would never come. It now also checks, a few times a
  second's worth of ticks apart, whether the pane has dropped back to a shell (the harness process
  gone); if so it returns immediately with "agent exited mid-turn — peek …". A hung-but-alive turn is
  still bounded by the timeout, as before. Verified live (rc in ~3s on a shell pane vs. the full
  timeout; a real turn on a live agent is unaffected).

### Changed
- **Idle turn-marker files are swept automatically.** The `Stop`/`UserPromptSubmit`/`Notification`
  hooks write one mtime marker per session id; across many sessions over time those accumulated
  forever. The hook now prunes markers untouched for over a week, gated to run at most once a day (via
  a `.overseer-pruned` stamp), so a heavy user's `~/.claude/{turn-done,turn-started,awaiting}/` no
  longer grows without bound. Deleting a stale marker only costs a poll-fallback on that session's next
  turn (the hook recreates it), never a wrong read.

### Fixed
- **A too-old bash now fails loudly at startup.** The script relies on named file descriptors
  (`exec {fd}>…`, bash ≥4.1) and associative arrays (bash ≥4.0); under stock macOS bash 3.2 those are
  parse/runtime errors surfacing cryptically deep in a sourced lib. The entry now checks
  `BASH_VERSINFO` up front and exits with a clear "needs bash >= 4.1" message before sourcing anything.

## [0.5.10] - 2026-07-20

### Changed
- **All `/proc` access now sits behind a four-function OS seam** (`_p_children`, `_p_comm`, `_p_cwd`,
  `_p_fds` in `discovery.sh`), dispatched on `$OVERSEER_OS`. The Linux branch is unchanged (verified
  live: `list`/`read`/discovery identical to before); any other platform returns cleanly so discovery
  reports "no agent pane" instead of reading a `/proc` that isn't there. This turns a future macOS port
  from a rewrite into implementing four functions. `doctor`'s non-Linux message now names the OS and
  points at the porting spec.

### Docs
- **`docs/PORTING.md`** — exact macOS (`ps`/`lsof`) mapping for each seam function, plus the other
  Linux/GNU-isms a port must bridge (`stat -c` vs `-f`, `date +%N`, `flock`, macOS's stock bash 3.2) and
  how to exercise the non-Linux path (`OVERSEER_OS=Darwin`). Runtime stays Linux-only; nothing is
  claimed as supported that hasn't been live-verified.
- **`docs/DECISIONS.md` (ADR-0001)** — records why overseer stays a single bash program rather than a
  Rust/Go/Python rewrite (the work is tmux/`jq`/`/proc` orchestration, not computation; ships as source
  with no build), and the concrete triggers that would reopen the question (Windows support, persistent
  state / a real API, a third harness straining the dispatch seams).

## [0.5.9] - 2026-07-20

### Fixed
- **`clear-box` no longer declares a multi-row input box empty while a row above the cursor still holds
  text.** Emptiness was read from the cursor row only (`_realtext`), so after `C-u` cleared the last
  line — leaving the cursor on a blank row with earlier lines still filled — the box read as empty and a
  stale first line survived into the next paste. It now treats the box as empty only when the cursor row
  is blank **and** still carries the prompt glyph (`❯`/`›`); a blank row without the glyph means content
  remains above, so it keeps clearing. Falls through to the old cursor-row test if the glyph can't be
  seen (broken UTF-8 locale), never stricter than before. Reproduced and verified live on Codex.

### Added
- **Two env tunables, validated at startup:** `OVERSEER_TIMEOUT` (default `600`) sets the fallback
  `[timeout]` for `chat`/`wait`/`sh`; `OVERSEER_POLL_INTERVAL` (default `0.25`s) sets the poll cadence.
  A non-numeric value fails loudly at launch instead of being silently read as `0`. Replaces the
  scattered hard-coded `600`/`0.25` literals with one config layer.
- **Per-pane advisory lock** so two concurrent `overseer` box-mutating commands (`send`/`chat`/`sh`/
  `slash`/`quit`/`menu`) on the *same* pane serialize instead of interleaving keystrokes and corrupting
  each other's input box. Best-effort `flock` (held only for the box-mutation critical section, released
  before the read-only reply wait); if `flock` is absent, the lock dir is unwritable, or the wait times
  out, the command proceeds unlocked — never blocked. Different panes never contend.

### Changed
- **Broadened the "idle shell" allowlist** (`sh`/`quit`) behind one `_is_shell` helper: adds `mksh`,
  `ash`, `tcsh`, `csh`, `nu`, `xonsh`, `elvish` and their login-shell (`-`-prefixed) forms to the
  existing `sh`/`bash`/`zsh`/`fish`/`dash`/`ksh`. `sh` on a non-Bourne interactive shell (and `quit`
  confirming the pane returned to one) no longer wrongly refuses. Covered by new fixture tests.

### Docs
- Spelled out the fast-path's `CLAUDE_HOME` dependency (README + skill): the event hooks accelerate a
  driven Claude session only when it shares overseer's `~/.claude`; a session under another user, a
  custom `CLAUDE_HOME`, or started before the plugin was installed falls back to polling (~2s), never
  blocked.

## [0.5.8] - 2026-07-20

### Fixed
- **`sh` no longer returns silently-empty output when a command outprints the pane scrollback.** If the
  output was long enough that its start (the begin sentinel) scrolled out of tmux history, `sh` now says so
  and suggests re-running with the output redirected to a file, instead of printing just the exit code with
  an empty body that reads like "no output".

### Changed
- **`doctor`'s contract probe targets the newest session that actually has a completed turn** (scanning up
  to the 20 newest), instead of the single newest file. A brand-new 0-turn session no longer masks a real
  schema break in a slightly older session — the probe now always has something meaningful to read when any
  recent session does.
- **`doctor` self-checks the awaiting-input detector** against a built-in sample menu, warning if it fails
  to match — which catches a broken/non-UTF-8 locale where `grep` can't see the `❯`/`›` cursor glyphs (that
  would otherwise make `wait`/`chat` silently miss permission prompts).

### Docs
- README caveat: awaiting-input detection covers numbered menus (`❯`/`›` + numbered options), not
  type-to-filter searchable pickers — `peek` + `keys` those.

## [0.5.7] - 2026-07-20

### Added
- **Parser regression tests** (`tests/run.sh` + `tests/fixtures/`), run in CI. They assert the pure
  transcript/screen parsers against hand-built fixtures — turn counting, busy detection, last
  reply/prompt (incl. multi-line and injected-wrapper exclusion), `sessionId` extraction, incremental
  `_turns_after`, and awaiting-prompt detection for **both** Claude (`❯`) and Codex (`›`) menus plus a
  negative case. This is the drift signal that was missing: an upstream on-disk/TUI change now fails CI
  instead of surfacing at runtime. No live tmux needed.

### Changed
- **`last reply` / `last prompt` readers stream the transcript** (`jq -n 'last(inputs | …)'`) instead of
  slurping the whole file into an array (`jq -s`), so a large session is read in near-constant memory.
  Verified byte-identical to the old readers across 16 real Claude + Codex transcripts and the fixtures.
- **`_awaiting` split into a pure `_awaiting_text`** (screen text in, verdict out) plus a thin
  `capture-pane` wrapper, so the awaiting-prompt logic is unit-testable. No behavior change; confirms the
  existing regex already covers Codex's `›`-cursor numbered menus.

## [0.5.6] - 2026-07-20

### Changed
- **Turn detection in the wait loops now reads only the bytes appended since the send**, not the whole
  transcript. While waiting, overseer re-scanned the entire `.jsonl`/rollout on every change to recount
  turns; it now records the file size at send time and `tail`s from that offset to spot the new terminal
  marker (`stop_reason ≠ tool_use` for Claude, `task_complete` for Codex). Equivalent to the old
  count-vs-baseline while the file only grows; the full-count reader is kept for `doctor`'s display and as
  the fallback. Pairs with the size/mtime gate from 0.5.4, so a `wait` on a multi-megabyte session does
  near-constant work per tick instead of re-parsing megabytes.
- **`/proc` discovery walks every thread's `children`, not just the pane's main thread.** `_agent_pid` /
  `_descendants` read `task/<pid>/children` only; they now read `task/*/children`, so an agent a harness
  spawns from a non-main thread is still discovered. No effect on today's Claude/Codex (both spawn from
  the main thread) — a robustness fix against future layouts.

## [0.5.5] - 2026-07-20

### Added
- **Event-driven turn-start and awaiting-input signals for Claude**, closing the last polling gap. Two
  more Stop-hook-style markers now ride the same bundled hook script: `UserPromptSubmit` touches
  `turn-started/<sid>` and `Notification` touches `awaiting/<sid>`. `send` records the submit time and
  confirms the turn started the instant the marker lands — removing the sub-second race where the
  transcript has no turn-start entry until the first token — and `chat`/`wait` surface an interactive
  prompt as soon as the notification fires. Both are pure accelerators: when the target session does not
  carry the hook (or on Codex, which has none), the readers fall back to the same size/mtime-gated
  transcript poll, so behavior is unchanged, never worse. The reader uses one `_marker_since` helper for
  all three markers, and the hook honors `${CLAUDE_HOME:-$HOME/.claude}`.

## [0.5.4] - 2026-07-20

### Fixed
- **Event-mode wake now survives a custom `CLAUDE_HOME`.** The bundled `Stop` hook wrote the turn-done
  marker to a hardcoded `$HOME/.claude/turn-done/`, while the reader looked under `$CLAUDE_HOME/turn-done/`.
  When `CLAUDE_HOME` was overridden the two diverged, silently disabling the ~0.25s event wake and
  dropping `chat`/`wait` back to ~2s polling. The hook now honors `${CLAUDE_HOME:-$HOME/.claude}`.
- **The Claude turn-done signal id is now read from the transcript's `sessionId`**, not parsed from the
  `.jsonl` filename. `basename` matched the session id only as long as the on-disk filename stayed exactly
  `<sessionId>.jsonl`; deriving it from the canonical field keeps the event wake working if that ever gains
  a suffix.

### Changed
- **Codex busy-check does one streaming `jq` pass instead of three**, and both wait loops re-scan the
  transcript only when its size/mtime actually changed. A Codex `wait` (no Stop hook, so it polls every
  ~0.25s) was re-parsing the whole rollout up to four times per tick; on a multi-megabyte session that is
  now skipped whenever the file is unchanged. No behavior change — turn counts only grow when the file does.

## [0.5.3] - 2026-07-19

### Changed
- Marketplace manifest hygiene: added the `$schema` reference for editor validation and dropped the
  non-standard `displayName` field (absent from the marketplace schema, silently ignored at load).
- `doctor` now **probes the transcript contract** instead of pinning exact CLI versions. It runs
  overseer's own readers against the newest on-disk session and warns only on a real parse failure
  (turns present but the reply is unreadable), so a harmless patch bump is silent while an actual
  layout change is caught — on any version, even one previously "tested". Removed the
  `TESTED_CLAUDE_VERSION` / `TESTED_CODEX_VERSION` baselines and the every-release bump they forced;
  `doctor` still prints the running versions for reference.

### Fixed
- **`send` now confirms the turn actually started before returning**, closing a race where a following
  `wait`/`read` read stale state. `send` submitted and returned in the sub-second window before the
  harness wrote the turn's first transcript marker, so an immediate `wait` reported `idle` and `read`
  showed the previous reply (reproduced on both Claude and Codex). `send` now polls until the turn is
  observable — mid-flight, already advanced, or stopped at an interactive prompt — bounded to 10s.
- **`chat` handles the first message to a 0-turn session** instead of refusing it. A brand-new Claude or
  Codex session has no transcript to baseline against; `chat` now sends, resolves the transcript once the
  turn begins, then waits for the reply — so the first turn no longer requires a separate `send`.

## [0.5.2] - 2026-07-19

Fixes from a full live + static audit of the interaction surface.

### Fixed
- **Interrupting a Codex turn (Escape) no longer wedges the session as permanently "busy".** Codex
  writes a `turn_aborted` event on interrupt but no `task_complete`, so the started>completed count
  stayed unbalanced forever — `wait` then hung to timeout and `send`/`chat` refused every future turn
  (even completed ones) until `--force`. Busy is now `task_started > task_complete + turn_aborted`.
- **`wait`/`chat` no longer mis-report "awaiting input" on a normal reply** that happens to contain a
  line like `▶ 1. …`. `_awaiting` now requires a real prompt cursor (`❯`/`›`) on a numbered row **and**
  at least two numbered options — a menu/permission prompt, not one stray glyph line in the answer.
- **`read`/`chat` no longer show a STALE prompt when your actual message starts with `<`, `{` (Claude)
  or `<`, `#`, `{` (Codex).** The prompt readers filtered those as injected-wrapper lines. They now read
  the harness's real user-input signal instead: Claude's `origin.kind == "human"` records, and Codex's
  `user_message` events — neither of which the AGENTS.md / `<INSTRUCTIONS>` / notification wrappers set.
- **Concurrent `overseer` invocations on different panes no longer clobber each other's paste.** The
  tmux paste buffer was a shared constant; it is now per-process (`overseer_paste_$$`).
- **A non-numeric `timeout` is rejected up front** (`chat/wait/sh … 30s`) instead of being read as 0 —
  which sent the message and then died "timeout", tempting a double-send.
- Claude pane detection now requires the session-owning process to actually be `claude` (guards against a
  stale `sessions/<pid>.json` + PID reuse) and also matches an `exec`-launched claude (pane pid itself).
- `menu` cycle-detection ignores the volatile bottom status lines (token/context counters) so a live
  counter no longer defeats the "screen repeated → stop" check.
- `sh`/`quit` fail with a message instead of a bare `set -e` abort if the pane vanishes mid-lookup.
- Multi-line paste verification accepts either chip convention (`+M` = newline count or line count).

### Known / not fixed (documented)
- Concurrent human-and-agent driving of the same pane has a sub-second window where a turn already in
  flight is not yet visible as "busy"; prefer `read`/`wait` over `chat` on a pane a human is actively
  typing in.
- The leading-`/ ! # @` space-guard can leave one leading space in the delivered message (Claude does not
  always trim it); the message still arrives as text. `menu` on a numbered popup (e.g. Claude `/model`)
  can't bridge the `N.` prefix — use `keys <n>` for numbered prompts.

## [0.5.1] - 2026-07-19

### Fixed
- **Multi-line replies and prompts are no longer truncated to their last line.** `read`/`chat`/`wait`
  read the reply and the echoed prompt whole again. The readers selected the last transcript entry with
  `... | tail -1`, which operates on physical lines, so a reply spanning several lines collapsed to only
  its final line. They now slurp the entries and take the last one intact (Claude and Codex, reply and
  prompt paths). This was the common case — most agent replies are multi-line.
- **`send`/`chat` now confirm the message actually submitted.** After the paste they fired a single
  `Enter`; one arriving mid-paste-render is dropped by the TUI, leaving the message sitting unsent in the
  box — most reliably reproduced on the first (long, wrapping) message to a just-launched agent, where
  `chat` would then wait out its whole timeout for a reply that was never requested. Submission is now
  verify-driven (`_submit`): press `Enter`, confirm the box emptied, retry until it does, matching how
  every other step self-verifies.

### Changed
- `TESTED_CLAUDE_VERSION` bumped to `2.1.215` (re-verified live against it); the 0-turn `chat` error no
  longer hard-codes "claude" for what may be a Codex session.

## [0.5.0] - 2026-07-19

### Added
- **Awaiting-input detection.** `wait` and `chat` now notice when the agent is blocked on an
  interactive prompt — a permission dialog, a plan approval, a select menu — instead of treating it as
  a still-running turn and hanging until timeout. They return immediately with the question, its
  options, and how to answer (`keys`/`menu` to pick, `send` to type free-text, then `read`). Detection
  is on-screen: a cursor (`❯`/`›`/`▶`) on a numbered option row, so it covers both Claude and Codex.
  Answering a prompt can reveal the next one (plan approval → per-edit permission → shell approval);
  each `wait` surfaces the next, so the whole approve-as-you-go loop is drivable from outside.

### Fixed
- `wait`/`chat` no longer abort silently under `set -e` when the wait returns a non-zero status
  (the awaiting/timeout codes are now captured with `|| rc=$?`).

## [0.4.1] - 2026-07-18

### Added
- **`menu` now works on Codex too**, completing harness parity — every command except the
  shell-only `sh` drives both agents. Codex marks its active popup row with a bold cyan pointer
  (`ESC[1m ESC[38;5;6m ›`) rather than Claude's reverse-video, so `_is_active` now also recognizes that
  style. Codex popups (`/model`, `/approvals`, ...) are vertical: pass `Down` as the nav key.

## [0.4.0] - 2026-07-18

### Added
- **Codex parity for `quit` and `slash`.** Both now auto-detect the harness and adapt: `quit` sends the
  right number of Ctrl-C taps (Claude two, Codex one) and confirms the pane returned to a shell; `slash`
  types a slash command into either TUI. Only `menu` stays Claude-only.
- Codex is now detected by a descendant process named `codex` (not by an open rollout fd), so a **0-turn
  Codex** — still at `Context 0%`, before it has opened a rollout file — is discovered by `list`, and
  driven by `send`/`slash`/`quit`. `read`/`chat`/`wait` still need one turn (no transcript before that),
  matching Claude's 0-turn behavior.

### Changed
- Docs (README + skill) note Codex specifics: quitting takes a single Ctrl-C; **interrupt a running
  Codex turn with `Escape`, not Ctrl-C** (Ctrl-C quits Codex when idle); a Codex approval prompt is
  answered with a letter key (`y`/`a`/`d`) via `keys`.

## [0.3.1] - 2026-07-18

### Changed
- Internal: split the `overseer` script into a thin entry point that sources `scripts/lib/`
  (`discovery.sh`, `transcript.sh`, `tui.sh`, `commands.sh`). No behavior change; the largest file
  drops from ~620 to ~270 lines. CI shellchecks the entry with `-x` to follow the sources.

## [0.3.0] - 2026-07-18

### Added
- **Codex support.** `list`, `read`, `chat`, `send`, `wait` now auto-detect whether a pane runs
  Claude Code or Codex and read the right transcript — the same commands drive both. Codex discovery
  reads the rollout jsonl the codex process holds open (`/proc/<pid>/fd` →
  `~/.codex/sessions/**/rollout-*.jsonl`); turn completion is the rollout's `task_complete` event, and
  the reply its `last_agent_message`. `quit`/`slash`/`menu` stay Claude-only for now.
- `list` gained a **HARNESS** column (claude/codex).
- `overseer doctor` also checks the running Codex version + `~/.codex/sessions`, warning when Codex
  drifts from its tested baseline (`0.144.5`).
- `overseer doctor` checks the running Claude Code version and warns when it drifts from the tested
  baseline (`2.1.214`) — surfaces upstream layout-change risk without hard-blocking.
- README: `Updating` (apply with `/reload-plugins`, no restart), `Compatibility`, and a
  `Useful Claude Code commands` list.

### Changed
- Docs: apply overseer updates with `/reload-plugins` instead of restarting Claude Code (it re-wires
  the bundled `Stop` hook and reloads the skill in the current session).

## [0.2.0] - 2026-07-18

### Added
- `overseer doctor` — preflight check (Linux/`/proc`, `tmux`, `jq`, tmux server, and whether Claude
  Code's `~/.claude/sessions/*.json` layout is where discovery expects it). Run it first when a pane
  "can't be found".
- Contributor scaffolding: GitHub Actions validation workflow, issue/PR templates, `CONTRIBUTING.md`,
  `SECURITY.md`, `.gitattributes`.

### Fixed
- Shellcheck-clean: split two `local` + command-substitution assignments (SC2318/SC2155) so a
  just-assigned value and command exit codes are not masked.

## [0.1.0] - 2026-07-18

Initial release as a Claude Code plugin distributed via the `sgbl` marketplace.

### Added
- `overseer` script with 11 commands: `list`, `read`, `peek`, `chat`, `send`, `wait`,
  `quit`, `slash`, `menu`, `sh`, `keys`.
- Bundled Claude Code skill (`skills/overseer/SKILL.md`) so an agent can drive/read another
  session or a shell in a tmux pane.
- Bundled `Stop` hook (`hooks/turn-done.sh`, wired via `hooks/hooks.json`) for event mode — wakes
  `chat`/`wait` the instant a turn ends. Wired automatically on install.
- Plugin manifest (`.claude-plugin/plugin.json`) and single-plugin marketplace
  (`.claude-plugin/marketplace.json`, name `sgbl`).

### Notes
- Linux only (agent discovery reads `/proc`). Requires `tmux` and `jq`.
- Reads Claude Code's on-disk session/transcript layout, which is internal and may change
  between Claude Code releases.
