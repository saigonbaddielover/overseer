# shellcheck shell=bash

_OVERSEER_LOCK_FD=''
_lock_pane() {
  command -v flock >/dev/null 2>&1 || return 0
  local pane="$1" d="${TMPDIR:-/tmp}/overseer-$UID" f
  mkdir -p "$d" 2>/dev/null || return 0
  f="$d/pane-${pane//[!0-9A-Za-z]/_}.lock"
  { exec {_OVERSEER_LOCK_FD}>"$f"; } 2>/dev/null || { _OVERSEER_LOCK_FD=''; return 0; }
  flock -w 30 "$_OVERSEER_LOCK_FD" 2>/dev/null \
    || { _OVERSEER_LOCK_FD=''; _die "another overseer command has held the lock on $pane for 30s and is still running — retry when it finishes (or check it: overseer peek $pane)"; }
}
_unlock_pane() {
  [ -n "$_OVERSEER_LOCK_FD" ] || return 0
  { exec {_OVERSEER_LOCK_FD}>&-; } 2>/dev/null || true
  _OVERSEER_LOCK_FD=''
}
# a pane in tmux copy-mode (user scrolled up) freezes capture on the scrolled view and routes keys
# to copy-mode instead of the app; cancel it so every read/write acts on the live prompt. no-op
# when the pane is not in a mode.
_wake_pane() {
  [ "$(tmux display-message -p -t "$1" '#{pane_in_mode}' 2>/dev/null)" = 1 ] \
    && tmux send-keys -X -t "$1" cancel 2>/dev/null || true
}
# is <name> the HIGHLIGHTED (active) item on screen? true if a reverse-video or background-color
# SGR sits just before the name in the colored capture — how a TUI marks the active tab / selected
# row. lets menu navigation be verify-driven instead of counting keystrokes.
_is_active_text() {
  local cap="$1" ne="$2" e; e=$(printf '\033')
  printf '%s\n' "$cap" \
    | grep -qE "${e}\[([0-9;]*;)?7m *${ne}|${e}\[[0-9;]*48;[0-9;]+m *${ne}|${e}\[[0-9;]*38;5;6m.*${ne}|[❯▶►●➤›]((${e}\[[0-9;]*m)|[^A-Za-z${e}])*${ne}"
}
_is_active() {
  local pane="$1" name="$2" ne
  ne=$(printf '%s' "$name" | sed 's/[][(){}.^$*+?|\\]/\\&/g')   # match the label literally
  _is_active_text "$(tmux capture-pane -e -p -t "$pane" 2>/dev/null)" "$ne"
}
_awaiting_text() {
  local cap="$1" g="${2:-❯›}" galt='' i out
  for ((i = 0; i < ${#g}; i++)); do galt="${galt:+$galt|}${g:i:1}"; done
  out=$(printf '%s\n' "$cap" | awk -v galt="$galt" '
    { line[NR] = $0
      s = $0; sub(/^[ \t]+/, "", s)
      m = (s ~ "^(" galt ")[ \t]*[0-9]+[.)][ \t]")
      t = s; if (m) sub("^(" galt ")[ \t]*", "", t)
      if (t ~ /^[0-9]+[.)][ \t]/) { opt[NR] = 1; mark[NR] = m; num[NR] = t + 0 }
    }
    END {
      for (i = 1; i <= NR; i++) {
        if (!opt[i]) continue
        j = i; n = 0; k = 0
        while (opt[j] && (j == i || num[j] == num[j - 1] + 1)) { n++; k += mark[j]; j++ }
        if (n >= 2 && k >= 1 && k < n) {
          lo = i - 2; if (lo < 1) lo = 1
          for (p = lo; p < j; p++) if (line[p] ~ /[^ \t]/) print line[p]
          exit 0
        }
        i = j - 1
      }
      exit 1
    }') || return 1
  printf '%s\n' "$out" | tail -10
}
_awaiting() {
  local pane="$1" cap
  _wake_pane "$pane"
  cap=$(tmux capture-pane -p -t "$pane" 2>/dev/null) || return 1
  _awaiting_text "$cap"
}
_compacting_text() {
  printf '%s\n' "$1" | grep -qE 'Compacting conversation…|Compacting conversation\.\.\.|Compacting at auto window \('
}
_compacting() {
  local pane="$1" cap
  cap=$(tmux capture-pane -p -t "$pane" 2>/dev/null) || return 1
  _compacting_text "$cap"
}
_thinking_text() {
  printf '%s\n' "$1" | grep -qE '…[[:space:]]*\([0-9]+[hms]|^[[:space:]]*[^[:space:]].{0,58}…[[:space:]]*$'
}
_queued_text() {
  printf '%s\n' "$1" | grep -qF 'Press up to edit queued messages'
}
_queued() {
  local pane="$1" cap
  cap=$(tmux capture-pane -p -t "$pane" 2>/dev/null) || return 1
  _queued_text "$cap"
}
_screen_state() {
  local pane="$1" cap cy
  cap=$(tmux capture-pane -p -t "$pane" 2>/dev/null) || { printf 'busy'; return 0; }
  { _thinking_text "$cap" || _queued_text "$cap"; } && { printf 'busy'; return 0; }
  cy=$(tmux display-message -p -t "$pane" '#{cursor_y}' 2>/dev/null)
  case "$cy" in ''|*[!0-9]*) cy=0 ;; esac
  [ "$cy" -gt 1 ] && cap=$(printf '%s\n' "$cap" | head -n "$((cy - 1))")
  printf '%s' "$cap" | cksum | tr -d ' '
}
_undelivered() {
  local pane="$1" target="$2" q
  q=$(_awaiting "$pane") || { printf 'could not place/verify message in input box'; return 0; }
  printf 'not sent — the agent is asking:\n%s\n\nanswer it first, then resend, e.g.:\n  overseer keys %s <n>        (choose a numbered option)\n  overseer send %s "<text>"   (type free-text into the prompt)' \
    "$q" "$target" "$target"
}
_report_awaiting() {
  local pane="$1" target="$2"
  printf 'awaiting input — the agent is asking:\n%s\n\nanswer it, then read the reply, e.g.:\n  overseer keys %s <n>        (choose a numbered option; add "overseer keys %s Enter" if it needs confirming)\n  overseer send %s "<text>"   (type free-text into the prompt)\n  overseer read %s\n' \
    "$(_awaiting "$pane")" "$target" "$target" "$target" "$target"
}
# ---- live input line inspection (send path) --------------------------------
# the live input line. prefer the row under the cursor (#{cursor_y}) so a menu/autocomplete that
# also draws a ❯ below the box can't be mistaken for the prompt; fall back to the bottom-most ❯ line.
_inline() {
  local pane="$1" cy
  cy=$(tmux display-message -p -t "$pane" '#{cursor_y}' 2>/dev/null)
  if [ -n "$cy" ]; then
    tmux capture-pane -e -p -t "$pane" 2>/dev/null | sed -n "$((cy + 1))p"
  else
    tmux capture-pane -e -p -t "$pane" 2>/dev/null | grep -E '❯|›' | tail -1
  fi
}
# real (non-ghost) typed text: drop dim ghost spans, color codes, prompt glyph (claude ❯ or codex ›),
# NBSP; trim
_realtext() {
  _inline "$1" | sed -E $'s/\x1b\\[2m[^\x1b]*//g; s/\x1b\\[[0-9;]*m//g; s/^[^❯›]*[❯›]//; s/\xc2\xa0/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//'
}
# strip leading/trailing whitespace, matching what _realtext does to the rendered box, so a
# delivery-only leading space (added to dodge command mode) never fails the equality check.
_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
_box_empty() {
  local pane="$1"
  [ -n "$(_realtext "$pane")" ] && return 1
  _inline "$pane" | grep -qE '❯|›'
}
# fully empty the input box. C-u kills one line at a time, so a multi-line box (or an
# uncollapsed inline paste) needs several; loop until it reads empty (dim ghost only).
# deterministic on line count, unlike a fixed number of C-u.
_clear_box() {
  local pane="$1" i
  _wake_pane "$pane"
  for i in $(seq 1 40); do
    _box_empty "$pane" && return 0
    tmux send-keys -t "$pane" C-u
    _nap
  done
  [ -z "$(_realtext "$pane")" ]
}
# place + verify a message in the box via bracketed paste; leaves it UNSUBMITTED. paste is atomic
# (tmux delivers the exact bytes, and it inserts newlines as content instead of submitting), so it
# handles one line, many lines, and lines wider than the pane uniformly — and a ghost suggestion can
# never interleave. verification, strongest first: exact match when the message fits on one row;
# else a "[Pasted text #N +M lines]" chip with M == newline count (multi-line); else just non-empty
# real text (a single long line that wrapped). returns non-zero on failure.
_paste_verified() {
  local pane="$1" msg="$2" want nl i cap chip got buf="overseer_paste_$$"
  want=$(_trim "$msg"); nl=$(printf '%s' "$msg" | tr -cd '\n' | wc -c)
  _clear_box "$pane" || return 2
  printf '%s' "$msg" | tmux load-buffer -b "$buf" - 2>/dev/null || return 3
  tmux paste-buffer -d -p -b "$buf" -t "$pane" 2>/dev/null || return 3
  for i in $(seq 1 40); do
    [ "$(_realtext "$pane")" = "$want" ] && return 0
    cap=$(tmux capture-pane -p -t "$pane" 2>/dev/null)
    chip=$(printf '%s\n' "$cap" | grep -oE 'Pasted text #[0-9]+ \+[0-9]+ lines' | tail -1)
    if [ -n "$chip" ]; then
      if [ "$nl" -gt 0 ]; then
        got=$(printf '%s' "$chip" | grep -oE '\+[0-9]+' | tr -cd '0-9')
        { [ "$got" = "$nl" ] || [ "$got" = "$((nl + 1))" ]; } && return 0
      else
        return 0
      fi
    elif [ -n "$(_realtext "$pane")" ]; then
      return 0
    fi
    _nap
  done
  _clear_box "$pane"; return 4
}
# read the message: '-' means consume all of stdin (pipe in long multi-line prompts);
# otherwise use the literal argument.
_read_msg() { if [ "${1:-}" = '-' ]; then cat; else printf '%s' "${1:-}"; fi; }
# place a message in the box, verified and UNSUBMITTED. everything goes through bracketed paste
# (atomic, uniform for one/many/wide lines).
_deliver() {
  local pane="$1" kind="$2" msg="$3"
  # strip C0 control bytes except tab/newline: a raw ESC or an embedded paste-end marker (\e[201~)
  # would otherwise end the bracketed paste early and let the tail run as keystrokes. LC_ALL=C makes
  # tr operate byte-wise, so UTF-8 (e.g. Vietnamese) text is preserved.
  msg=$(printf '%s' "$msg" | LC_ALL=C tr -d '\000-\010\013-\037\177')
  # a leading / ! # @ opens Claude Code's command/bash/memory/file mode even inside a paste, so
  # prepend one space: the first char is no longer special and Claude trims it back off, so the
  # message arrives unchanged. codex does NOT trim a leading space and a pasted command does not open
  # its menu, so a codex message is left exactly as typed.
  if [ "$kind" = claude ]; then
    case "$msg" in /*|'!'*|'#'*|'@'*) msg=" $msg" ;; esac
  else
    case "$(_trim "$msg")" in '!'*) _die "Codex runs a message starting with '!' as a shell command (by its design), not chat — reword it (e.g. lead with a word), or run a command with: overseer sh <target> '<cmd>'" ;; esac
  fi
  _paste_verified "$pane" "$msg"
}
_submit() {
  local pane="$1" i
  for i in $(seq 1 8); do
    tmux send-keys -t "$pane" Enter
    _nap
    { [ -z "$(_realtext "$pane")" ] || _queued "$pane"; } && return 0
  done
  { [ -z "$(_realtext "$pane")" ] || _queued "$pane"; }
}
