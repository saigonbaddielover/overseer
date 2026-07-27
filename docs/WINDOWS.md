# Driving a remote Windows host

overseer runs on Linux only. Windows is reached as a **remote target over plain SSH** — no WSL, no
agent installed on the Windows box beyond three PowerShell files staged under `%ProgramData%\overseer`
on demand.

This document records *why* the Windows path looks the way it does. The scripts carry no prose
comments by project rule, and every fact below cost a live debugging round to establish — several of
them are invisible in any API documentation and only surfaced by reading back what the driven agent
actually recorded.

## Prerequisites

On the **Linux controller**: `ssh`, `scp`, `base64` and `iconv` on `PATH` (plus overseer's usual `jq`/`bash ≥ 4.1`).
Overrides: `OVERSEER_SSH`, `OVERSEER_SSH_OPTS`, `OVERSEER_SCP`.

On the **Windows target**:

| | |
|---|---|
| OpenSSH server | running and reachable; key-based auth recommended |
| SSH identity | must be an **administrator** — registering the interactive scheduled task requires it |
| PowerShell 7 (`pwsh.exe`) | on `PATH`; the broker is hosted by `pwsh`, not `powershell.exe` |
| A logged-in console user | somebody must be signed in at the physical/RDP console (Session 1). Locked is fine, logged off is not — `win <host> show`/`win <host> start` fail with a clear error |
| The agent itself | `claude` / `codex` installed **for the console user**, authenticated in *their* PowerShell profile (see [Host environment](#host-environment)) |

The SSH admin and the console user may be different accounts; that is the topology `%ProgramData%`
staging exists to serve.

## Security model

- **Everything runs as the console user, on their visible desktop.** `win <host> start`, `keys`, `sh`,
  `chat` and `stop` execute real commands on somebody's live machine, with their credentials, in
  a window they are looking at. Treat every one of them the way you would treat `sh` on the user's own
  box: never run one unless the user explicitly asked for it.
- **The broker *is* a console-user process, so the console user is trusted, not sandboxed.** The
  scheduled task launches the broker with the console user's own token — so anything the broker knows
  (the pipe name, the auth token), that user's own processes can learn too, and a *fully-malicious*
  console user can always stand up a look-alike broker and feed the admin SSH client forged responses.
  This is inherent: overseer drives that user's desktop on their behalf; it cannot also defend the
  machine against them. They already own their session. What the design **does** protect is the admin
  SSH client (and any *third*, unprivileged local account) — see the next three points.
- **The descriptor is split so the console user cannot redirect the control channel.** The pipe name
  and 256-bit `AUTH` token live in `%ProgramData%\overseer\brokers\<broker>.json`, ACL'd to
  Administrators/SYSTEM FullControl and the console user **`ReadAndExecute` only**. The per-broker
  transcript claim — the one thing the broker must write at runtime — lives in a separate
  `<broker>.state.json` the console user may modify. Because the secret file is read-only to them, a
  semi-trusted console user can no longer rewrite `Pipe` to point the admin client at a pipe of their
  own. The server pipe additionally demands `FirstPipeInstance` (a squatter and the real broker cannot
  coexist), the token is compared case-sensitively and length-first, and the client connects with
  `TokenImpersonationLevel.Anonymous` so a spoofed broker cannot impersonate the admin's token.
- **No console-user-supplied value is ever run as admin code or used as a path unchecked.** The
  transcript path the broker reports is resolved from the console user's own session dirs — an
  attacker-influenced *name* — so both the broker (`Test-TranscriptPath`) and the controller
  (`_win_txok`) require an absolute Windows `.jsonl` path free of shell metacharacters before it
  reaches `scp`. `win <host> show`'s app name is passed as base64, never interpolated into PowerShell source.
- **The shared tree is locked down before anything is staged into it.** `%ProgramData%\overseer` and
  its subdirs are created with an explicit ACL (Administrators/SYSTEM + console-user read, **no
  `Authenticated Users`**) before the payloads are copied, and each staged `.ps1` gets an
  inheritance-protected, owner-reset ACL on every launch — so a file a third account pre-planted
  cannot keep a foothold, and the token-bearing descriptor is never briefly world-readable.
- **The token never crosses the wire in the clear beyond ssh**, is never logged by the broker, and is
  never printed by any overseer command.
- `win <host> stop` removes both descriptor files and kills the child's whole descendant tree leaf-first,
  so a stopped broker leaves no live orphan and no reusable credential behind.

## The shape

```
Linux                         │ Windows host
overseer win host/name chat ── ssh ──▶ win-client.ps1  (Session 0, one-shot per turn)
                                          │ reads %ProgramData%\overseer\brokers\<broker>.json
                                          │ named pipe \\.\pipe\overseer-<guid>, after AUTH <token>
                                          ▼
                                      win-broker.ps1  (Session 1, VISIBLE on the desktop)
                                          │ shares its console with
                                          ▼
                                      pwsh / claude / codex
```

The broker is the Windows analogue of a tmux pane: it owns a console, a child TUI shares that console,
and the pipe protocol exposes the same two primitives tmux gives us on Linux.

| tmux (Linux) | broker verb (Windows) | Win32 call |
|---|---|---|
| `send-keys` | `TYPE` / `PASTE` / `KEY` | `WriteConsoleInput` |
| `capture-pane` | `SNAP` / `SNAPALL` | `ReadConsoleOutputCharacter` |
| `send-keys C-u` | `CLEAR` | `WriteConsoleInput`, verified against the grid |
| — | `STAT` / `INFO` | transcript path, size, mtime, liveness |

`SNAP` reads the visible window; `SNAPALL` reads the whole screen buffer, which the broker grows to
9999 rows at startup. Without that, the buffer is only as tall as the window and `win <host> sh` output longer
than a screenful **destroys** its opening sentinel rather than scrolling it — reported as a false
timeout.

`ReadConsoleOutputCharacter` returns the **already-rendered character grid**, so `win <host> peek` and the
awaiting-prompt detector work with no VT emulator on either side. That is the reason this approach was
chosen over a ConPTY relay.

**Turn detection never moved.** The Windows agent writes the same transcript JSON as on Linux, so
`STAT` reports its path/size/mtime, the file is fetched only when that signature changes, and the
existing `_h_turn_count` / `_h_is_busy` / `_h_last_reply` bash+jq readers decide when the turn ended.
One harness seam, no PowerShell turn logic to keep in sync.

## Session 0 vs Session 1

SSH lands in **Session 0**, which is a service session with no visible desktop. The logged-on user's
desktop is **Session 1**. A process started directly from SSH runs invisibly and cannot share a console
with anything the user can see.

The bridge is a Task Scheduler task registered with an **Interactive** principal for the console user,
started, then immediately unregistered — the launched process keeps running:

```powershell
New-ScheduledTaskPrincipal -UserId $consoleUser -LogonType Interactive
New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                             -ExecutionTimeLimit ([TimeSpan]::Zero)
```

Both settings flags are load-bearing:

- **On battery**, a default task silently sits at `Status: Queued` with `Last Result: 0` and spawns
  nothing. There is no error anywhere — this cost several debugging rounds. Check power state with
  `(Get-CimInstance Win32_Battery).BatteryStatus` (1 = battery, 2 = AC).
- Without `ExecutionTimeLimit 0`, the task manager eventually kills a long-lived broker.

Cross-session consequences worth knowing:

- A **named pipe is machine-wide**, which is why a Session-0 client can talk to a Session-1 server
  (verified `client_sid=0 ↔ server_sid=1`). This is the only part of the design that crosses the
  boundary, and it does so by construction rather than by privilege.
- `MainWindowHandle` is **0 for every process** when queried from Session 0, so window-handle detection
  is useless cross-session. `win <host> show` reports success by observing a new process in the console
  session instead.
- `wt.exe` is an app-execution-alias stub; launching it directly exits without activating anything.
  Packaged apps must be started by AUMID via
  `explorer.exe shell:AppsFolder\Microsoft.WindowsTerminal_8wekyb3d8bbwe!App`.

## Console input: what `WriteConsoleInput` will and will not deliver

These were established by driving a real agent and then reading back its transcript — the screen alone
is not evidence, because a mangled prompt can still *look* plausible in the grid.

- **A raw `ESC` byte is never delivered to the child.** Bracketed paste (`ESC[200~` … `ESC[201~`) is
  therefore impossible: the agent receives the literal text `[200~`. v0.9.0 shipped with exactly this
  bug and passed CI — only `win <host> read` exposed it.
- **A `\r`/`\n` char event with `wVirtualKeyCode = 0` is swallowed.** Newlines vanish and every line of
  a multi-line prompt runs together into one.
- **`Ctrl+J` (`vk=0x4A, uc=0x0A, ctrl=0x0008`) is what actually inserts a composer line break** — in
  both Claude Code and Codex. This is the mechanism `PASTE` uses for every newline.
- **The input box must be cleared first** (`Ctrl+U`, `vk=0x55, uc=0x15, ctrl=0x0008`), or leftover text
  is prepended to the prompt and the agent answers a question nobody asked.
- **Claude Code draws the composer gutter as `>` followed by U+00A0 NO-BREAK SPACE**, which POSIX
  `[[:space:]]` does not match. Verifying delivery by comparing the composer row to the sent text
  therefore never matched until `_win_snap` began normalizing U+00A0 as it reads the grid. Only the
  single-line path was affected — a multi-line prompt verifies through the paste chip, which is why
  this survived several rounds of live testing. **Codex is different**: its gutter is `›` (U+203A)
  followed by an ordinary ASCII space, so it never hit the bug. Confirmed by dumping the raw grid
  bytes of both (`342 200 272 040` for Codex, `076 302 240` for Claude).
- Large bursts must be **chunked** (256 records with a short pause between) or records are dropped.

## Rendering and parsing quirks

- On a Windows console, **Claude Code draws the selection cursor as ASCII `>`**, not `❯`. A screen
  parser keyed only on `❯`/`›` silently never matches, so an interactive prompt is invisible and the
  caller hangs to timeout. `_awaiting_text` therefore takes the accepted glyph set as an argument:
  `_win_awaiting` passes `❯›>`, and the Linux `_awaiting` keeps the strict `❯›`. Sharing one loose set
  was a bug — on Linux a reply containing a markdown blockquote of a numbered list (`> 1. …`) read as a
  menu and ended the wait early. Both paths additionally require that **not every** numbered line
  carries the glyph, since a real menu marks only the selected row.
  `tests/fixtures/awaiting-windows-console.txt` is a real capture guarding the positive case;
  `awaiting-none-markdown-quote.txt` and `awaiting-none-numbered-list.txt` guard the negatives.
- **The composer soft-wraps, and only its first line carries the `>` marker.** Overflow continues on
  gutter-indented lines until the box's closing rule, and a break that falls on a space swallows that
  space. Verifying a paste by comparing the message against the marker line alone therefore fails for
  anything wider than the console — the old behaviour was `could not place/verify the prompt` on every
  long single-line prompt, box cleared, nothing sent. `_win_box_text` joins the marker line with its
  continuations and `_win_squash` compares with all whitespace removed, which is exact in content and
  blind to where the wrap fell. `tests/fixtures/win-snap-wrapped-box.txt` is a real capture of a
  three-line wrap.
- `Split-Path -Leaf` returns **empty** for `\\.\pipe\<name>` — PowerShell treats it as a UNC root.
- `[System.Diagnostics.Process]::Start($psi)` can return a *String* in this context, and the child's
  "first descendant" may be `conhost`, not the agent. `Start-Process -PassThru` gives the exact pid.
- **`$pid` is a read-only automatic variable** — assigning it (e.g. as a loop variable) is a runtime
  error the parser will not catch. `tests/win-contracts.ps1` asserts no payload does.
- A `List[int]` returned from a PowerShell function is **unrolled to `Object[]`**, which has no
  `.Reverse()`. `win <host> stop` iterates by descending index instead; killing parent-first took the
  broker down before it reached the agent, orphaning it.
- PowerShell 7 lacks the 8-argument `NamedPipeServerStream` constructor. Use
  `NamedPipeServerStreamAcl::Create` when the type exists and fall back to the constructor otherwise.
- `GetFinalPathNameByHandle` **blocks forever** on a pipe handle. Any handle sweep must filter on
  `GetFileType == FileTypeDisk` first — which is why transcript ownership is now claimed through the
  descriptor rather than discovered by sweeping handles.
- Pipe I/O must be **synchronous** `ReadLine`/`WriteLine` with default options. Adding
  `PipeOptions.Asynchronous` + `ReadLineAsync` deadlocks both ends.
- Box-drawing characters mangle over SSH → bash unless UTF-8 is forced on both ends.

## Host environment

The child is launched through a **profile-loading** `pwsh` (`pwsh -NoLogo -Command claude`), never
`-NoProfile`. A user's API configuration commonly lives in the PowerShell profile rather than in
environment variables or any settings file; launching without the profile makes the agent fall back to
its default auth and reply `Not logged in`.

**The command name itself is per-host**, so it is injected, not hardcoded: `OVERSEER_WIN_CLAUDE` and
`OVERSEER_WIN_CODEX` on the controller (defaults `claude` / `codex`) name what `win <host> start` runs there.
A host whose users go through a wrapper — `claude-wrapper` rather than `claude`, say — needs
`OVERSEER_WIN_CLAUDE=claude-wrapper`, and gets the same `Not logged in` reply if it does not. The value is
restricted to a bare command name, travels base64-encoded, and is decoded into a parameter rather than
interpolated, for the same reason `workdir` is. The broker's `kind` stays `claude`/`codex`, so the
transcript readers and turn detection are untouched.

So when an agent authenticates in the user's own terminal but not under the broker, check two things:
the profile, and whether that host uses a differently-named command.

## Concurrency

Multiple brokers coexist on one host, addressed as `<host>/<name>` (descriptor
`overseer-broker-<name>.json`; the bare `<host>` form is `overseer-broker.json`). `win <host> list` enumerates
**descriptors**, not `\\.\pipe\` entries — the pipe names are random. Every box-mutating command takes
a per-broker `flock` on the Linux side, acquired *before* it reads `STAT`, so two overseer invocations
cannot interleave keystrokes into the same console or act on a stale busy-check.

Two brokers of the same kind would otherwise fight over the same transcript, so each **claims** one:
Claude resolves its session id from a descendant-owned `sessions\<pid>.json` (no newest-file fallback,
so no claim file is needed), and Codex records the `rollout-*.jsonl` it took so a sibling broker skips
it. That claim is written to the broker's **`<broker>.state.json`** — the console-user-`Modify` half of
the split descriptor — precisely so the secret `<broker>.json` can stay read-only to the console user
(see the security model). `win <host> list` skips `*.state.json` when it enumerates descriptors.

## Verification rule

`tests/win-parse.ps1` parses every `win-*.ps1` with
`System.Management.Automation.Language.Parser` (it caught two real defects on its first run that every
prior check had passed). `tests/win-contracts.ps1` **executes** the payloads' pure functions — it
AST-extracts each and calls it: `Test-TranscriptPath` against the scp-injection battery, `Get-ConfigPath`
broker-name accept/reject, `Read-Frame` on good/bad/truncated frames, the descriptor round-trip (the
secret carries no transcript claim), and — on Windows — the codex claim isolation through the split
state file. The Windows-runtime constructs a unit test cannot exercise (the pipe ACL, `FirstPipeInstance`,
the anonymous client, the scheduled task) stay as labeled `src:` source tripwires. CI runs both scripts
natively under `pwsh` on `windows-latest` — that job is the gate. But **PowerShell runs on Linux too**,
so you can run the same checks before pushing:
`bash tests/win-payloads.sh` (or `OVERSEER_PWSH=/path/to/pwsh …`), which is a thin wrapper over the
identical scripts.

`tests/win-flow.sh` covers the bash side with the two remote chokepoints mocked.

That is still not enough. Anything touching delivery, key encoding, or transcript resolution must also
be verified by driving a real Windows host **and reading back what the agent recorded** with `win <host> read`,
not by looking at the screen — the v0.9.0 regression rendered plausibly and was wrong.
