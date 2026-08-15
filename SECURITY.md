# Security

overseer drives *other* live sessions by injecting keystrokes into them. Target Claude Code sessions
typically run with `--dangerously-skip-permissions`, so anything `send` / `chat` / `sh` submits
**auto-executes** in that session with no confirmation gate. Only point it at sessions you own and
trust, and an agent using it must never send a message it was not explicitly asked to send.

## Linux targets (tmux)

Keystrokes go into a tmux pane on the controller host, or on another Linux host over ssh via
`deploy` + `on`. Identity is ssh's own — overseer stores no credentials, runs no daemon, and keeps no
token store. A remote `chat`/`send` has no tty, so it **fails closed** unless `--yes` is passed.

`start` and `stop` are local side effects, the tmux analogue of the Windows `win <host> start` /
`win <host> stop` pair: `start` spawns a new detached tmux session running a shell or agent (on the
controller, or via `on` the remote host), and `stop` destroys a `%N` pane or a whole named session,
SIGHUPping its child. `stop` is destructive — run it only when asked, prefer `quit` to merely leave an
agent's TUI, and note it refuses to kill the session (or, for a `%N` target, the pane) overseer itself
is running in.

## Reading the account quota (`usage`)

`usage` is the one command that talks to a network service and the one that reads a credential.
Claude publishes account quota only over its API, so overseer reads the OAuth **access token** from
`$CLAUDE_HOME/.credentials.json` (default `~/.claude/.credentials.json`, the file Claude Code already
keeps at mode 600) and makes a single read-only `GET https://api.anthropic.com/api/oauth/usage`.

The rules it holds to:

- The token is sent **only to `api.anthropic.com`**, the service that issued it. There is no
  third-party endpoint, no telemetry, and no configurable base URL that could redirect it.
- It is handed to `curl` on **stdin** (`curl --config -`), never on the command line, so it is not
  visible in `ps` to other users on the machine.
- It is **never written anywhere** — not logged, not echoed, not cached. Only the *response* (usage
  percentages and reset times, no credential) is cached, under
  `${XDG_CACHE_HOME:-~/.cache}/overseer/quota-claude.json` at mode 600, to bound how often
  `chat`/`send`/`wait` refetch for their warning line.
- overseer **never writes to the credentials file** and cannot refresh an expired token; it reports
  the expiry and stops.
- No other command reads it. If you do not run `usage` — and do not let `chat`/`send`/`wait` emit
  their quota warning — the file is never opened.

`usage` writes no Claude configuration. It installs nothing, and never modifies `settings.json`.

## Windows targets (the `win <host> <verb>` commands)

The native Windows controller (`overseer.ps1`) uses the same authenticated named-pipe protocol but does
not cross accounts or desktop sessions. It launches visible workers directly as the current user and
stores descriptors under that user's `%LOCALAPPDATA%\overseer`; no Administrator token or scheduled
task is involved. Its `chat`, `keys`, `sh`, `interrupt`, and `stop` commands still act on real local
processes and require the same explicit user authorization as their remote counterparts.

Its `on <host>` and `deploy <host>` commands are a separate SSH trust boundary: they use the current
user's OpenSSH configuration and credentials, store no keys, and execute the bundled Bash controller on
the selected Linux host. `deploy` writes `$HOME/<dir>/scripts`; `on ... sh` and agent-driving commands
can execute arbitrary remote work, so the same explicit-authorization rule applies.

These are remote execution on somebody's live desktop and deserve the same care as `sh`:

- `win <host> start` spawns a **visible** process in the console user's session; `win <host> keys`, `sh`
  and `chat` type into it; `win <host> stop` kills it and its descendants. All of it happens on a screen
  a person is looking at, under their credentials. Never run one unless the user explicitly asked.
- `win <host> sh` runs an arbitrary command line in a `pwsh` child. It refuses a broker hosting an agent,
  so a command can never be typed into a chat box — but it is otherwise unrestricted.
- The SSH login must be an **administrator** on the Windows host (registering the interactive
  scheduled task requires it), so a compromised controller key is an admin foothold there.
- **The broker runs as the console user**, so that user is *trusted*, not sandboxed — a fully-malicious
  console user can always spoof broker responses (the broker's process is theirs). What overseer
  protects is the admin SSH client and any third, unprivileged local account. The pipe name and 256-bit
  `AUTH` token live in `%ProgramData%\overseer\brokers\<broker>.json`, ACL'd to Administrators/SYSTEM
  and the console user **read-only**; the runtime transcript claim is a separate console-user-writable
  `<broker>.state.json`, so the console user cannot rewrite the pipe to hijack the control channel. No
  console-user-supplied value (transcript path, `win <host> show` app) is ever run as admin code or fed to
  `scp` unchecked; the shared tree is ACL-locked before staging. Tokens are never logged or printed.

See [docs/WINDOWS.md](docs/WINDOWS.md) for the full prerequisites and security model.

## Reporting a vulnerability

Please use GitHub's private **"Report a vulnerability"** advisory on this repository, or open a regular
issue for non-sensitive reports. Include the `overseer doctor` output and clear steps to reproduce.
