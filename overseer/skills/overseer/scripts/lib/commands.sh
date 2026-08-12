# shellcheck shell=bash

cmd_list() {
  _need tmux
  if [ "${1:-}" = --all ]; then
    printf 'SESSION\tPANE\tPANE_PID\tCOMMAND\tCWD\n'
    while IFS=$'\t' read -r s pid_id pp cmd; do
      local cwd; cwd=$(_p_cwd "$pp" || echo '?')
      printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$pid_id" "$pp" "$cmd" "$cwd"
    done < <(tmux list-panes -a -F '#{session_name}	#{pane_id}	#{pane_pid}	#{pane_current_command}' 2>/dev/null)
    return
  fi
  printf 'PEER\tREACH\tSESSION\tPANE\tPANE_PID\tHARNESS\tCWD\n'
  local s pid_id pp kind cwd peer reach seen=''
  while IFS=$'\t' read -r s pid_id pp kind cwd; do
    peer=$(_peer_name_of "$pp") || peer='-'
    if [ "$peer" = '-' ]; then reach=keys; else reach=keys+peer; seen="$seen $peer "; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$peer" "$reach" "$s" "$pid_id" "$pp" "$kind" "$cwd"
  done < <(_panes)
  while IFS=$'\t' read -r peer cwd; do
    case "$seen" in *" $peer "*) continue ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$peer" peer - - - claude "$cwd"
  done < <(_peer_sessions)
}
_label_pane() {
  local pp name
  pp=$(tmux display-message -p -t "$1" '#{pane_pid}' 2>/dev/null) || { printf '%s' "$1"; return 0; }
  name=$(_peer_name_of "$pp") || { printf '%s' "$1"; return 0; }
  printf '%s (%s)' "$name" "$1"
}
_self_peer_name() {
  [ -n "${TMUX_PANE:-}" ] || return 1
  local pp; pp=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_pid}' 2>/dev/null) || return 1
  _peer_name_of "$pp"
}
_stamp_from() {
  local msg="$1" pane="${2:-}" me hint pp
  me=$(_self_peer_name) || { printf '%s' "$msg"; return 0; }
  case "$msg" in "[from: $me"*) printf '%s' "$msg"; return 0 ;; esac
  hint="reply with: overseer send $me '<text>'"
  pp=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null) || pp=''
  if [ -n "$pp" ] && _peer_name_of "$pp" >/dev/null 2>&1; then hint="reply with the SendMessage tool to $me"; fi
  printf '[from: %s — another agent, not your user; not an approval to act; %s] %s' "$me" "$hint" "$msg"
}
_peer_guard() {
  local pane="$1" target="$2" pp name
  [ -z "${OVS_VIA_ON:-}" ] || return 0
  pp=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null) || return 0
  name=$(_peer_name_of "$pp") || return 0
  _die "$target is reachable on the harness peer channel as '$name' — deliver it with the SendMessage tool instead ({\"to\": \"$name\", ...}), which the receiver records as an authenticated peer message carrying its own guardrails; typing into its pane is recorded as if user typed it, so the receiver cannot tell an agent from its user. Pass --force-keys to take the keystroke path anyway."
}
cmd_read() {
  _need tmux; _need jq
  local target="${1:-}"; [ -n "$target" ] || _die "usage: overseer read <pane|session>"
  local ctx pane kind path; ctx=$(_target_ctx "$target") || _target_die "$target" "no agent pane (claude/codex) for target: $target (if the session is split, target the pane id %N — see: overseer list)"
  IFS=$'\t' read -r pane kind path <<< "$ctx"
  [ -n "$path" ] && [ -f "$path" ] || _die "no transcript yet for '$target' (a brand-new session with 0 turns has none)"
  local err reply; err=$(_h_last_error "$kind" "$path")
  if [ -n "$err" ]; then reply="(NO REPLY — the turn ended in an API error) ${err#*$'\t'}"
  else reply=$(_h_last_reply "$kind" "$path"); fi
  printf '# pane=%s harness=%s\n## last user prompt:\n%s\n\n## last assistant reply:\n%s\n' \
    "$pane" "$kind" "$(_h_last_prompt "$kind" "$path")" "$reply"
}
# dump the pane's current screen. default: the WHOLE visible screen (features like /status fill it;
# truncating loses the top). `raw` keeps ANSI colors so an active tab / selected row — shown by a
# background highlight, invisible in plain text — can be read, which menu navigation needs. an
# optional trailing line count caps plain output to the last N lines.
cmd_peek() {
  _need tmux
  local raw=0
  case "${1:-}" in raw|-e|--raw) raw=1; shift ;; esac
  local target="${1:-}" n="${2:-0}"
  [ -n "$target" ] || _die "usage: overseer peek [raw] <pane|session> [lines]"
  local pane; pane=$(_resolve_pane "$target") || _target_die "$target" "no tmux pane for target: $target"
  if [ "$raw" = 1 ]; then
    tmux capture-pane -e -p -t "$pane" 2>/dev/null
  elif [ "$n" -gt 0 ] 2>/dev/null; then
    tmux capture-pane -p -t "$pane" 2>/dev/null | grep -vE '^\s*$' | tail -n "$n"
  else
    tmux capture-pane -p -t "$pane" 2>/dev/null | grep -vE '^\s*$'
  fi
}
# send raw tmux keys (Enter, Escape, y, Up, Down, C-c, ...) — for answering prompts / menus.
cmd_keys() {
  _need tmux
  local target="${1:-}"; shift || true
  [ -n "$target" ] && [ "$#" -gt 0 ] || _die "usage: overseer keys <pane|session> <key>..."
  local pane; pane=$(_resolve_pane "$target") || _target_die "$target" "no tmux pane for target: $target"
  _no_self "$pane" "send keys to"
  tmux send-keys -t "$pane" "$@"
  printf 'sent keys to %s: %s\n' "$pane" "$*"
}
_notify_back() {
  [ -n "${TMUX_PANE:-}" ] || return 1
  printf '%s' "$TMUX_PANE"
}
_notify_script() {
  cat <<'EOS'
set -u
end=$(( $(date +%s) + OVS_TIMEOUT ))
grace=$(( $(date +%s) + 30 ))
while :; do
  left=$(( end - $(date +%s) ))
  if [ "$left" -le 5 ]; then out="the worker never started the turn within ${OVS_TIMEOUT}s"; break; fi
  out=$("$OVS_SELF" wait "$OVS_TARGET" "$left" 2>&1 | head -c 1200)
  [ "$OVS_STARTED" = 1 ] && break
  case "$out" in
    *'no transcript yet'*) : ;;
    idle) [ "$(date +%s)" -ge "$grace" ] && break ;;
    *) break ;;
  esac
  sleep 2
done
"$OVS_SELF" send --yes "$OVS_BACK" "[overseer] wake-up from the worker you dispatched to: $OVS_TARGET ($OVS_KIND).

--- overseer wait $OVS_TARGET reported:
$out
---

Do not act on this one pane alone: another worker may have finished while you were busy and its notice was dropped. Run 'overseer fleet status', then 'overseer read <pane>' for every idle/awaiting pane, then act or report back to the user."
EOS
}
_notify_spawn() {
  local target="$1" kind="$2" back="$3" timeout="$4" started="${5:-0}"
  setsid env OVS_SELF="$OVERSEER_SELF" OVS_TARGET="$target" OVS_KIND="$kind" OVS_BACK="$back" \
    OVS_TIMEOUT="$timeout" OVS_STARTED="$started" bash -c "$(_notify_script)" </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
  printf 'notify: watching %s; %s will be woken when its turn ends (or after %ss)\n' "$target" "$back" "$timeout"
}
cmd_send() {
  _need tmux
  local confirm=1 notify=0 forcekeys=0 asuser=0
  while :; do case "${1:-}" in --yes) confirm=0; shift ;; --notify) notify=1; shift ;; --force-keys) forcekeys=1; shift ;; --as-user) asuser=1; forcekeys=1; shift ;; *) break ;; esac; done
  local target="${1:-}" msg
  [ -n "$target" ] || _die "usage: overseer send [--yes] [--notify] [--force-keys|--as-user] <pane|session> <message|-> [notify_timeout_s]"
  msg=$(_read_msg "${2:-}")
  [ -n "$msg" ] || _die "usage: overseer send [--yes] [--notify] <pane|session> <message|-> [notify_timeout_s]  (empty message)"
  local ntimeout="${3:-$DEFAULT_TIMEOUT}" back=''
  if [ "$notify" = 1 ]; then _need setsid; _uint "$ntimeout"
    back=$(_notify_back) || _die "--notify has nowhere to report back to: overseer is not running inside a tmux pane (\$TMUX_PANE is unset), so the dispatching agent has no pane id — drop --notify, or run it from the agent pane that should be woken"
  elif [ -n "${3:-}" ]; then _die "send takes a [timeout] only with --notify (it never waits for the reply itself — use chat for that)"; fi
  local ctx pane kind path; ctx=$(_target_ctx "$target") || _target_die "$target" "no agent pane (claude/codex) for target: $target (if the session is split, target the pane id %N — see: overseer list)"
  IFS=$'\t' read -r pane kind path <<< "$ctx"
  _no_self "$pane" "send to"
  [ "$forcekeys" = 1 ] || _peer_guard "$pane" "$target"
  [ "$asuser" = 1 ] || msg=$(_stamp_from "$msg" "$pane")
  _lock_pane "$pane"
  { _queued "$pane" && ! _compacting "$pane"; } && { _unlock_pane; _die "a message is already queued to $pane behind its running turn (the agent holds one queued message at a time) — wait for it to run first: overseer wait $target, or drop it and free the slot: overseer unsend $target"; }
  local base; base=$(_h_turn_count "$kind" "$path" 2>/dev/null); base="${base:-0}"
  local bbytes; bbytes=$(_fsize "$path")
  local prequeue=0; { { [ -n "$path" ] && [ -f "$path" ] && _h_running "$kind" "$path"; } || _compacting "$pane"; } && prequeue=1
  local sid=''; [ "$kind" = claude ] && [ -n "$path" ] && [ -f "$path" ] && sid=$(_sid_from_jsonl "$path")

  _deliver "$pane" "$kind" "$msg" || _die "$(_undelivered "$pane" "$target")"
  if [ "$confirm" = 1 ]; then
    printf 'verified in box:\n%s\n--- press Enter to send, Ctrl-C to abort: ' "$msg"
    read -r _ </dev/tty || { _clear_box "$pane"; _die "aborted"; }
  fi
  local since; since=$(date +%s)
  _submit "$pane" || _die "could not confirm the message submitted (it may still be in the input box) — peek: overseer peek $target"
  _unlock_pane
  if [ "$prequeue" = 1 ]; then
    local why="busy with its current turn"; _compacting "$pane" && why="compacting its context"
    printf 'sent to %s (QUEUED — the agent is %s):\n%s\naccepted and will run when the agent is free; await the reply: overseer wait %s [timeout] — or drop it before it runs: overseer unsend %s\n' "$pane" "$why" "$msg" "$target" "$target"
    if [ "$notify" = 1 ]; then _notify_spawn "$pane" "$kind" "$back" "$ntimeout" 1; fi
    return 0
  fi
  local rc=0; path=$(_wait_started "$target" "$kind" "$path" "$base" 10 "$pane" "$sid" "$since" "$bbytes" "$prequeue") || rc=$?
  _quota_warn_for "$kind" "$path"
  local started=0; case "$rc" in 0|4|5) started=1 ;; esac
  if [ "$notify" = 1 ] && [ "$rc" != 2 ]; then _notify_spawn "$pane" "$kind" "$back" "$ntimeout" "$started"; fi
  case "$rc" in
    5|4) local why="busy with its current turn"; _compacting "$pane" && why="compacting its context"
       printf 'sent to %s (QUEUED — the agent is %s):\n%s\naccepted and will run when the agent is free; await the reply: overseer wait %s [timeout] — or drop it before it runs: overseer unsend %s\n' "$pane" "$why" "$msg" "$target" "$target" ;;
    2) printf 'sent to %s:\n%s\n' "$pane" "$msg"; _report_awaiting "$pane" "$target" ;;
    1) printf 'sent to %s:\n%s\n' "$pane" "$msg"
       _die "could not confirm the turn started within 10s — the message may still be sitting in the input box; peek: overseer peek $target" ;;
    *) printf 'sent to %s (turn started):\n%s\n' "$pane" "$msg" ;;
  esac
}
_self_pane() { [ -n "${TMUX_PANE:-}" ] && [ "$TMUX_PANE" = "$1" ]; }
_no_self() {
  _self_pane "$1" || return 0
  _die "refusing to $2 $1 — that is the pane overseer is running in, so it would drive this agent's own TUI; target a worker instead (see: overseer list)"
}
cmd_unsend() {
  _need tmux; _need jq
  local target="${1:-}"
  [ -n "$target" ] || _die "usage: overseer unsend <pane|session>"
  local ctx pane kind path; ctx=$(_target_ctx "$target") || _target_die "$target" "no agent pane (claude/codex) for target: $target (if the session is split, target the pane id %N — see: overseer list)"
  IFS=$'\t' read -r pane kind path <<< "$ctx"
  _self_pane "$pane" && _die "refusing to unsend on $pane — that is the pane overseer is running in, so the queue it would empty is this agent's own; target a worker instead (see: overseer list)"
  _lock_pane "$pane"
  local q; q=$(_h_queued "$kind" "$path" "$pane")
  if [ -z "$q" ]; then
    _h_steering "$kind" "$path" "$pane" && { _unlock_pane; _die "nothing retractable on $pane — codex hands a message sent mid-turn straight to the model as a steer, so it is already in flight and no key pulls it back; let the turn finish and correct it in the next message: overseer wait $target"; }
    _unlock_pane
    printf 'nothing queued on %s — nothing to retract\n' "$pane"
    return 0
  fi
  _awaiting "$pane" >/dev/null && { _unlock_pane; _die "$pane is stopped at an interactive prompt, and unsend drives the same keys that move its selection — answer it first: overseer peek $target"; }
  local draft; draft=$(_realtext "$pane")
  _clear_box "$pane" || { _unlock_pane; _die "could not empty the input box on $pane before retracting — peek: overseer peek $target"; }
  tmux send-keys -t "$pane" "$(_h_popkey "$kind")"
  local i
  for i in $(seq 1 40); do
    _h_unqueued "$kind" "$path" "$pane" && break
    _nap
  done
  _h_unqueued "$kind" "$path" "$pane" || {
    _clear_box "$pane" || true; _unlock_pane
    _die "could not pull the queued message back out of $pane — the agent may have finished its turn and started running it already; check it: overseer peek $target"
  }
  _clear_box "$pane" || { _unlock_pane; _die "pulled the message off the queue but could not clear it out of the input box on $pane — it is unsubmitted, clear it yourself: overseer peek $target"; }
  _unlock_pane
  printf 'retracted from %s (never ran):\n%s\n' "$pane" "$q"
  [ -n "$draft" ] && printf 'also discarded the unsent draft that was sitting in the input box:\n%s\n' "$draft"
  return 0
}
cmd_interrupt() {
  _need tmux; _need jq
  local runq=0
  while :; do case "${1:-}" in
    --run-queued) runq=1; shift ;;
    -*) _die "usage: overseer interrupt [--run-queued] <pane|session>" ;;
    *) break ;;
  esac; done
  local target="${1:-}"
  [ -n "$target" ] || _die "usage: overseer interrupt [--run-queued] <pane|session>"
  local ctx pane kind path; ctx=$(_target_ctx "$target") || _target_die "$target" "no agent pane (claude/codex) for target: $target (if the session is split, target the pane id %N — see: overseer list)"
  IFS=$'\t' read -r pane kind path <<< "$ctx"
  _self_pane "$pane" && _die "refusing to interrupt $pane — that is the pane overseer is running in, so the turn it would stop is this agent's own; target a worker instead (see: overseer list)"
  _lock_pane "$pane"
  _awaiting "$pane" >/dev/null && { _unlock_pane; _die "$pane is not running a turn — it is stopped at an interactive prompt waiting to be answered: overseer peek $target"; }
  { [ -n "$path" ] && [ -f "$path" ] && _agent_busy "$kind" "$path" "$pane"; } || {
    _unlock_pane; printf '%s is not running a turn — nothing to interrupt\n' "$pane"; return 0
  }
  local q; q=$(_h_queued "$kind" "$path" "$pane")
  { [ -z "$q" ] && _h_steering "$kind" "$path" "$pane"; } && q='(a message already handed to the model as a steer)'
  if [ -n "$q" ] && [ "$runq" = 0 ]; then
    _unlock_pane
    _die "$pane has a message queued behind this turn, and interrupting hands control straight to it — it starts running immediately:
$q
to stop everything, drop it first: overseer unsend $target, then overseer interrupt $target
to interrupt and let it run: overseer interrupt --run-queued $target"
  fi
  tmux send-keys -t "$pane" "$(_h_intkey "$kind")"
  local i settled=0
  if [ -n "$q" ]; then
    for i in $(seq 1 40); do
      [ -z "$(_h_queued "$kind" "$path" "$pane")" ] && { settled=1; break; }
      _nap
    done
    _unlock_pane
    [ "$settled" = 1 ] || _die "sent the interrupt to $pane but its queued message never left the queue — check it: overseer peek $target"
    printf 'interrupted the running turn on %s; the message that was queued behind it is now running:\n%s\n' "$pane" "$q"
    return 0
  fi
  for i in $(seq 1 20); do
    _agent_busy "$kind" "$path" "$pane" || { settled=1; break; }
    _nap
  done
  _unlock_pane
  [ "$settled" = 1 ] || _die "sent the interrupt to $pane but it is still running — it may be finishing a tool call; check it: overseer peek $target"
  printf 'interrupted %s — the turn ENDED WITH NO REPLY, so nothing it was writing was saved; resend a corrected message when you are ready: overseer send %s "<text>"\n' "$pane" "$target"
  local back; back=$(_realtext "$pane")
  [ -n "$back" ] && printf 'the agent put the interrupted prompt back in its input box (unsubmitted, and any send/chat clears it first):\n%s\n' "$back"
  return 0
}
# send + wait for the turn to finish + print the reply (the human round-trip).
cmd_chat() {
  _need tmux; _need jq
  local confirm=1 forcekeys=0 asuser=0
  while :; do case "${1:-}" in --yes) confirm=0; shift ;; --force-keys) forcekeys=1; shift ;; --as-user) asuser=1; forcekeys=1; shift ;; *) break ;; esac; done
  local target="${1:-}" msg
  [ -n "$target" ] || _die "usage: overseer chat [--yes] [--force-keys|--as-user] <pane|session> <message|-> [timeout_s]"
  msg=$(_read_msg "${2:-}")
  [ -n "$msg" ] || _die "usage: overseer chat [--yes] [--force-keys|--as-user] <pane|session> <message|-> [timeout_s]  (empty message)"
  local timeout="${3:-$DEFAULT_TIMEOUT}"; _uint "$timeout"
  local ctx pane kind path; ctx=$(_target_ctx "$target") || _target_die "$target" "no agent pane (claude/codex) for target: $target (if the session is split, target the pane id %N — see: overseer list)"
  IFS=$'\t' read -r pane kind path <<< "$ctx"
  _no_self "$pane" "chat with"
  [ "$forcekeys" = 1 ] || _peer_guard "$pane" "$target"
  [ "$asuser" = 1 ] || msg=$(_stamp_from "$msg" "$pane")
  _lock_pane "$pane"
  { _queued "$pane" && ! _compacting "$pane"; } && { _unlock_pane; _die "a message is already queued to $pane behind its running turn (the agent holds one queued message at a time) — wait for it to run first: overseer wait $target, or drop it and free the slot: overseer unsend $target"; }
  local has_tx=0; { [ -n "$path" ] && [ -f "$path" ]; } && has_tx=1

  local sid='' base=0 since bbytes='' prequeue=0
  if [ "$has_tx" = 1 ]; then
    [ "$kind" = claude ] && sid=$(_sid_from_jsonl "$path"); base=$(_h_turn_count "$kind" "$path"); bbytes=$(_fsize "$path")
  fi
  { { [ "$has_tx" = 1 ] && _h_running "$kind" "$path"; } || _compacting "$pane"; } && prequeue=1
  _deliver "$pane" "$kind" "$msg" || _die "$(_undelivered "$pane" "$target")"
  if [ "$confirm" = 1 ]; then
    printf 'verified in box:\n%s\n--- press Enter to send, Ctrl-C to abort: ' "$msg"
    read -r _ </dev/tty || { _clear_box "$pane"; _die "aborted"; }
  fi
  since=$(date +%s)
  _submit "$pane" || _die "could not confirm the message submitted (it may still be in the input box) — peek: overseer peek $target"
  _unlock_pane
  local rc=0
  if [ "$has_tx" = 0 ]; then
    path=$(_wait_started "$target" "$kind" "$path" 0 30 "$pane") || true
    { [ -z "$path" ] || [ ! -f "$path" ]; } && _die "sent, but no transcript appeared for '$target' within 30s — check it with: overseer peek $target ; then resume: overseer wait $target"
    [ "$kind" = claude ] && sid=$(_sid_from_jsonl "$path")
    printf '# sent to %s (waiting for reply...)\n' "$pane" >&2
    _wait_reply "$kind" "$path" "$base" "$timeout" "$sid" "$since" "$pane" "$bbytes" || rc=$?
  elif [ "$prequeue" = 1 ]; then
    if _compacting "$pane"; then printf '# %s is compacting — your message is QUEUED behind it; waiting for ITS reply...\n' "$pane" >&2
    else printf '# %s is busy — your message is QUEUED behind the running turn; waiting for ITS reply...\n' "$pane" >&2; fi
    _wait_queued_reply "$kind" "$path" "$timeout" "$pane" "$msg" || rc=$?
  else
    printf '# sent to %s (waiting for reply...)\n' "$pane" >&2
    _wait_reply "$kind" "$path" "$base" "$timeout" "$sid" "$since" "$pane" "$bbytes" || rc=$?
  fi
  _quota_warn_for "$kind" "$path"
  case "$rc" in
    0) if _awaiting "$pane" >/dev/null 2>&1; then _report_awaiting "$pane" "$target"
       else _report_turn_error "$kind" "$path" "$target" || printf '## reply:\n%s\n' "$(_h_reply_for "$kind" "$path" "$msg")"; fi ;;
    2) _report_awaiting "$pane" "$target" ;;
    3) _die "the agent in $pane exited mid-turn (its pane dropped to a shell) — no reply was produced; peek: overseer peek $target" ;;
    4) _die "the turn in $pane stopped without producing a reply — it was interrupted (Ctrl-C for claude, Escape for codex, in that pane), or the agent is blocked on something overseer cannot read; the message WAS delivered, so do not blindly resend: peek: overseer peek $target" ;;
    *) _die "timeout after ${timeout}s — the turn is still running. Do NOT rerun chat (it would send the message again); resume waiting instead: overseer wait $target   then   overseer read $target" ;;
  esac
}
cmd_wait() {
  _need tmux; _need jq
  local target="${1:-}" timeout="${2:-$DEFAULT_TIMEOUT}"; [ -n "$target" ] || _die "usage: overseer wait <pane|session> [timeout_s]"
  _uint "$timeout"
  local ctx pane kind path; ctx=$(_target_ctx "$target") || _target_die "$target" "no agent pane (claude/codex) for target: $target (if the session is split, target the pane id %N — see: overseer list)"
  IFS=$'\t' read -r pane kind path <<< "$ctx"
  _self_pane "$pane" && _die "refusing to wait on $pane — that is the pane overseer is running in, so the turn it would wait for cannot end until this command returns; it would only burn the timeout (see: overseer list)"
  if _awaiting "$pane" >/dev/null 2>&1; then _report_awaiting "$pane" "$target"; return 0; fi
  [ -n "$path" ] && [ -f "$path" ] || _die "no transcript yet for '$target' (a brand-new session with 0 turns has none)"
  # already ended a turn -> idle; mid-turn -> wait for the turn to end
  local rc=0
  if _queued "$pane" || _h_running "$kind" "$path"; then
    _wait_drained "$kind" "$path" "$timeout" "$pane" || rc=$?
  else
    _quota_warn_for "$kind" "$path"
    _report_turn_error "$kind" "$path" "$target" || true
    echo "idle"; return 0
  fi
  _quota_warn_for "$kind" "$path"
  case "$rc" in
    0) if _awaiting "$pane" >/dev/null 2>&1; then _report_awaiting "$pane" "$target"
       else _report_turn_error "$kind" "$path" "$target" || echo "idle"; fi ;;
    2) _report_awaiting "$pane" "$target" ;;
    3) _die "the agent in $pane exited mid-turn (its pane dropped to a shell); peek: overseer peek $target" ;;
    *) _die "timeout after ${timeout}s" ;;
  esac
}
_agent_busy() {
  local kind="$1" path="$2" pane="$3" a b
  _h_is_busy "$kind" "$path" && return 0
  _h_running "$kind" "$path" || return 1
  [ "$kind" = claude ] || return 0
  a=$(_screen_state "$pane"); [ "$a" = busy ] && return 0
  local i
  for i in $(seq 1 6); do
    _nap; _nap
    b=$(_screen_state "$pane")
    { [ "$b" = busy ] || [ "$b" != "$a" ]; } && return 0
    a="$b"
  done
  return 1
}
_fleet_status() {
  local pane="$1" ctx kind path state
  ctx=$(_target_ctx "$pane") || { printf '%s\t?\t(not an agent)\n' "$pane"; return 0; }
  IFS=$'\t' read -r pane kind path <<< "$ctx"
  if _awaiting "$pane" >/dev/null 2>&1; then state=awaiting
  elif _compacting "$pane"; then state=compacting
  elif [ -n "$path" ] && [ -f "$path" ] && _agent_busy "$kind" "$path" "$pane"; then state=busy
  elif [ -n "$path" ] && [ -f "$path" ] && [ -n "$(_h_last_error "$kind" "$path")" ]; then state=api-error
  elif [ -n "$path" ] && [ -f "$path" ]; then state=idle
  else state='idle(0-turn)'; fi
  printf '%s\t%s\t%s\n' "$pane" "$kind" "$state"
}
_fleet_wait_any() {
  local timeout="$1"; shift
  _uint "$timeout"
  local -a inflight=(); local p st row
  for p in "$@"; do
    st=$(_fleet_status "$p" | cut -f3)
    case "$st" in busy|compacting) inflight+=("$p") ;; esac
  done
  if [ "${#inflight[@]}" -eq 0 ]; then
    echo "no pane is busy — nothing in flight to wait for (see: overseer fleet status)"; return 0
  fi
  printf '# watching %s in-flight pane(s); returns on the FIRST to finish/await/exit...\n' "${#inflight[@]}" >&2
  local deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    for p in "${inflight[@]}"; do
      row=$(_fleet_status "$p"); st=$(printf '%s' "$row" | cut -f3)
      case "$st" in busy|compacting) : ;; *) printf 'PANE\tHARNESS\tSTATE\n%s\n' "$row"; return 0 ;; esac
    done
    _nap
  done
  printf 'timeout after %ss — all %s pane(s) still in flight\n' "$timeout" "${#inflight[@]}" >&2
  return 1
}
_fleet_local() {
  local action="${1:-status}"; shift || true
  local -a targets=(); local sess pane pid kind cwd p msg st any=0
  local -a fl=()
  while IFS=$'\t' read -r sess pane pid kind cwd; do targets+=("$pane"); done < <(_panes)
  [ "${#targets[@]}" -gt 0 ] || return 3
  case "$action" in
    status) _need jq; printf 'PANE\tHARNESS\tSTATE\n'; for p in "${targets[@]}"; do ( _fleet_status "$p" ) || true; done ;;
    read)   _need jq; for p in "${targets[@]}"; do printf '===== %s =====\n' "$(_label_pane "$p")"; ( cmd_read "$p" ) || printf '(unavailable)\n'; done ;;
    unsend) _need jq
      for p in "${targets[@]}"; do
        printf '===== %s =====\n' "$(_label_pane "$p")"
        _self_pane "$p" && { printf '(skipped — this is the pane overseer is running in)\n'; continue; }
        ( cmd_unsend "$p" ) || true
      done ;;
    interrupt)
      _need jq
      local -a ifl=(); while :; do case "${1:-}" in --run-queued) ifl+=("$1"); shift ;; *) break ;; esac; done
      for p in "${targets[@]}"; do
        printf '===== %s =====\n' "$(_label_pane "$p")"
        _self_pane "$p" && { printf '(skipped — this is the pane overseer is running in)\n'; continue; }
        ( cmd_interrupt ${ifl[@]+"${ifl[@]}"} "$p" ) || true
      done ;;
    wait)
      _need jq
      while :; do case "${1:-}" in --any) any=1; shift ;; *) break ;; esac; done
      local -a wt=()
      for p in "${targets[@]}"; do
        _self_pane "$p" && { printf '# %s: (skipped — this is the pane overseer is running in)\n' "$(_label_pane "$p")"; continue; }
        wt+=("$p")
      done
      [ "${#wt[@]}" -gt 0 ] || { printf 'nothing to wait for — the only agent pane is the one overseer is running in\n'; return 0; }
      if [ "$any" = 1 ]; then _fleet_wait_any "${1:-$DEFAULT_TIMEOUT}" "${wt[@]}"
      else for p in "${wt[@]}"; do printf '# %s: ' "$(_label_pane "$p")"; ( cmd_wait "$p" "$@" ) || true; done; fi ;;
    send|chat)
      [ "$action" = chat ] && _need jq
      while :; do case "${1:-}" in
        --yes|--force-keys|--as-user) fl+=("$1"); shift ;;
        --notify) [ "$action" = send ] || _die "fleet chat already waits for every reply — --notify belongs to fleet send"
                  fl+=("$1"); shift ;;
        *) break ;; esac; done
      msg="${1:-}"; [ -n "$msg" ] || _die "usage: overseer fleet $action [--yes] [--force-keys|--as-user] <message>  (broadcasts to every agent pane)"
      local -a nt=(); { [ "$action" = send ] && [ -n "${2:-}" ]; } && nt=("$2")
      for p in "${targets[@]}"; do
        printf '===== %s =====\n' "$(_label_pane "$p")"
        st=$(_fleet_status "$p" | cut -f3)
        case "$st" in
          idle|'idle(0-turn)') : ;;
          *) printf '(skipped — %s; a broadcast only messages idle agents, so it never queues onto a busy one)\n' "$st"; continue ;;
        esac
        if [ "$action" = send ]; then ( cmd_send ${fl[@]+"${fl[@]}"} "$p" "$msg" ${nt[@]+"${nt[@]}"} ) || true
        else ( cmd_chat ${fl[@]+"${fl[@]}"} "$p" "$msg" ) || true; fi
      done ;;
    *) _die "usage: overseer fleet [--hosts|--tailscale [--os NAME]] [-u USER] [status|read|unsend|interrupt [--run-queued]|wait [--any] [timeout]|send [--yes] [--force-keys|--as-user] [--notify] <msg> [notify_timeout]|chat [--yes] [--force-keys|--as-user] <msg>]  (no subcommand = status)" ;;
  esac
}
_fleet_survey() {
  local tmp="$1"; shift
  local i=0 h
  ( _fleet_local status 2>/dev/null | awk 'NR>1 { print "local\t" $0 }' >"$tmp/s0" ) &
  for h in "$@"; do
    i=$((i + 1))
    ( cmd_on "$h" fleet status 2>/dev/null | awk -v h="$h" 'NR>1 { print h "\t" $0 }' >"$tmp/s$i" ) &
  done
  wait
  i=0
  while [ "$i" -le "$#" ]; do cat "$tmp/s$i" 2>/dev/null; i=$((i + 1)); done
}
_fleet_gate() {
  local msg="$1" dry="$2" tmp="$3"; shift 3
  local surv; surv=$(_fleet_survey "$tmp" "$@")
  local -a recv=() skip=()
  local host pane kind state
  while IFS=$'\t' read -r host pane kind state; do
    [ -n "$pane" ] || continue
    case "$state" in
      idle*) recv+=("$(printf '%-26s %-6s %s' "$host" "$pane" "$kind")") ;;
      *)     skip+=("$(printf '%-26s %-6s %s' "$host" "$pane" "$state")") ;;
    esac
  done <<< "$surv"
  printf 'message:\n  %s\n\n' "$msg"
  if [ "${#recv[@]}" -eq 0 ]; then
    printf 'no idle agent anywhere in the fleet — nothing sent\n'
    [ "${#skip[@]}" -gt 0 ] && { printf 'not idle:\n'; printf '  %s\n' "${skip[@]}"; }
    return 1
  fi
  printf 'will send to %s idle agent(s):\n' "${#recv[@]}"
  printf '  %s\n' "${recv[@]}"
  [ "${#skip[@]}" -gt 0 ] && { printf 'skipping %s pane(s) not idle:\n' "${#skip[@]}"; printf '  %s\n' "${skip[@]}"; }
  [ "$dry" = 1 ] && { printf '\n--dry-run: nothing sent\n'; return 1; }
  printf '\n--- press Enter to send to all %s, Ctrl-C to abort: ' "${#recv[@]}"
  read -r _ </dev/tty 2>/dev/null || _die "aborted (no confirmation received; nothing was sent)"
  printf '\n'
  return 0
}
cmd_fleet() {
  _need tmux
  local remote=0 usetail=0 osfilter='' defuser="${OVERSEER_HOSTS_USER:-}"
  local u='usage: overseer fleet [--hosts|--tailscale [--os NAME]] [-u USER] [status|read|unsend|interrupt [--run-queued]|wait [--any] [timeout]|send [--yes] [--force-keys|--as-user] [--dry-run] [--notify] <msg> [notify_timeout]|chat [--yes] [--force-keys|--as-user] [--dry-run] <msg>]'
  while :; do case "${1:-}" in
    --hosts) remote=1; shift ;;
    --tailscale) remote=1; usetail=1; shift ;;
    --os) [ -n "${2:-}" ] || _die "$u"; osfilter="$2"; remote=1; shift 2 ;;
    -u) [ -n "${2:-}" ] || _die "$u"; defuser="$2"; shift 2 ;;
    *) break ;;
  esac; done
  [ -n "$osfilter" ] && [ "$usetail" = 0 ] && _die "--os only applies with --tailscale"
  local action="${1:-status}"
  if [ "$remote" = 0 ]; then
    local frc=0; _fleet_local "$@" || frc=$?
    [ "$frc" = 3 ] && _die "no agent panes found (see: overseer list)"
    return "$frc"
  fi
  _need ssh
  local yes=0 dry=0 msg='' fk=0 au=0
  case "$action" in
    send|chat)
      shift
      while :; do case "${1:-}" in
        --yes) yes=1; shift ;;
        --force-keys) fk=1; shift ;;
        --as-user) au=1; shift ;;
        --dry-run) dry=1; shift ;;
        --notify) _die "--notify wakes the dispatching agent's own tmux pane, which exists only on this machine — run it against the local fleet (overseer fleet send --notify <msg>), not with --hosts/--tailscale" ;;
        *) break ;;
      esac; done
      msg="${1:-}"
      [ -n "$msg" ] || _die "usage: overseer fleet --hosts $action [--yes] [--force-keys|--as-user] [--dry-run] <message>  (broadcasts to every idle agent in the fleet)"
      local -a fka=(); [ "$fk" = 1 ] && fka=(--force-keys); [ "$au" = 1 ] && fka=(--as-user)
      set -- "$action" --yes ${fka[@]+"${fka[@]}"} "$msg" ;;
  esac
  local ts=''
  [ "$usetail" = 1 ] && { command -v tailscale >/dev/null 2>&1 && ts=$(tailscale status 2>/dev/null || true); }
  _inventory "$usetail" "$osfilter" "$defuser" "$ts"
  local -a hosts=("${_INV_TARGETS[@]}")
  local tmp="${TMPDIR:-/tmp}/overseer-fleet-$UID-$$"
  mkdir -p "$tmp" 2>/dev/null || _die "could not create temp dir: $tmp"
  if [ -n "$msg" ] && { [ "$yes" = 0 ] || [ "$dry" = 1 ]; }; then
    _fleet_gate "$msg" "$dry" "$tmp" "${hosts[@]}" || { rm -rf "$tmp" 2>/dev/null || true; return 0; }
  fi
  printf '===== local =====\n'
  local lrc=0; ( _fleet_local "$@" ) || lrc=$?; [ "$lrc" = 3 ] && printf '(no local agent panes)\n'
  local i=0 h
  for h in "${hosts[@]}"; do
    ( cmd_on "$h" fleet "$@" >"$tmp/$i" 2>&1 ) &
    i=$((i + 1))
  done
  wait
  i=0
  for h in "${hosts[@]}"; do
    printf '===== %s =====\n' "$h"
    cat "$tmp/$i" 2>/dev/null || printf '(unavailable)\n'
    i=$((i + 1))
  done
  rm -rf "$tmp" 2>/dev/null || true
}
# turn-based interaction with a PLAIN shell pane (not a claude TUI): run one command line, wait for
# it to finish, print its output + exit code. completion is a unique sentinel line the wrapped
# command prints last (prompt-agnostic, unlike watching for PS1). the user watches it run live.
cmd_sh() {
  _need tmux
  local target="${1:-}" cmd="${2:-}" timeout="${3:-$DEFAULT_TIMEOUT}"
  [ -n "$target" ] && [ -n "$cmd" ] || _die "usage: overseer sh <pane|session> <command> [timeout_s]"
  _uint "$timeout"
  case "$cmd" in *$'\n'*) _die "one command line only (chain with ; or &&)" ;; esac
  local pane cur
  pane=$(_resolve_pane "$target") || _target_die "$target" "no tmux pane for target: $target"
  _self_pane "$pane" && _die "refusing to run a shell command in $pane — that is the pane overseer is running in, so the shell it would type into is busy running this command; target a worker instead (see: overseer list)"
  cur=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null) || _die "pane $pane vanished"
  _is_posix_shell "$cur" || _die "pane $pane is running '$cur', which overseer sh cannot drive (it needs a POSIX-ish shell: sh, bash, zsh, dash, ksh, mksh, ash); use keys/peek, or chat for an agent pane"
  _lock_pane "$pane"
  local tok; tok="TMC_$$_$(date +%s%N | tail -c 7)"
  local esc; esc=$(printf '%s' "$cmd" | sed "s/'/'\\\\''/g")   # for a single-quoted eval arg
  # BEGIN/END sentinels (each printf on its own line) delimit the output so the command echo can't
  # leak in. run the command via `eval` under a TEMPORARY env: pagers -> cat (git log / man / less
  # won't seize the pane), NO_COLOR for clean capture, and stdin from /dev/null (cat / python / ssh
  # get EOF instead of hanging). the env prefix does not persist and eval runs in the CURRENT shell,
  # so cd/export in the command still take effect. $? is the command's exit (BEGIN printf ran first).
  local wrapped="printf '\n%s\n' ${tok}B ; PAGER=cat GIT_PAGER=cat SYSTEMD_PAGER=cat NO_COLOR=1 eval '$esc' </dev/null ; printf '\n%s:%s\n' $tok \"\$?\""
  _wake_pane "$pane"
  tmux send-keys -t "$pane" C-u
  tmux send-keys -t "$pane" -l "$wrapped"
  tmux send-keys -t "$pane" Enter
  local deadline=$((SECONDS + timeout)) found=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    tmux capture-pane -p -t "$pane" 2>/dev/null | grep -qE "^${tok}:[0-9]+$" && { found=1; break; }
    _nap
  done
  # a non-terminating command (infinite loop) still runs past the timeout; Ctrl-C it so the pane is
  # left at a usable prompt instead of stuck, then fail.
  [ -n "$found" ] || { tmux send-keys -t "$pane" C-c; _die "timeout after ${timeout}s (sent Ctrl-C to stop it; peek: overseer peek $target)"; }
  local cap out rc
  cap=$(tmux capture-pane -p -S - -t "$pane" 2>/dev/null)
  rc=$(printf '%s\n' "$cap" | grep -E "^${tok}:[0-9]+$" | tail -1); rc=${rc##*:}
  if ! printf '%s\n' "$cap" | grep -qF "${tok}B"; then
    printf '# pane=%s exit=%s\n(the output was longer than the pane scrollback, so its start scrolled out of tmux history and cannot be captured whole; re-run redirecting to a file — append " > out.txt 2>&1" — then read the file)\n' "$pane" "$rc"
    return 0
  fi
  out=$(printf '%s\n' "$cap" | awk -v b="${tok}B" -v e="^${tok}:[0-9]+$" '
    $0 == b { s=1; next }
    s && $0 ~ e { exit }
    s { print }
  ')
  printf '# pane=%s exit=%s\n%s\n' "$pane" "$rc" "$out"
}
# quit the Claude Code TUI in a pane WITHOUT killing tmux, revealing the shell underneath. exit is
# two Ctrl-C within a short window ("Press Ctrl-C again to exit"), so the taps must go together —
# across separate calls the second arrives after the window closes. clears the box first (so C-c
# triggers exit, not a text-clear), then confirms the pane actually left claude.
cmd_quit() {
  _need tmux
  local target="${1:-}"; [ -n "$target" ] || _die "usage: overseer quit <pane|session>"
  local pane pp kind; pane=$(_resolve_pane "$target") || _target_die "$target" "no tmux pane for target: $target"
  _self_pane "$pane" && _die "refusing to quit $pane — that is the pane overseer is running in, so it would kill this agent mid-turn; target a worker instead (see: overseer list)"
  pp=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null) || _die "pane $pane vanished"
  kind=$(_harness_of "$pp") || _die "pane $pane is running '$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)', not a claude/codex agent; nothing to quit"
  _lock_pane "$pane"
  _clear_box "$pane" || true
  tmux send-keys -t "$pane" C-c
  [ "$kind" = claude ] && { _nap; tmux send-keys -t "$pane" C-c; }
  local i now
  for i in $(seq 1 20); do
    now=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
    _is_shell "$now" && { printf '%s exited; pane %s is now: %s\n' "$kind" "$pane" "$now"; return 0; }
    [ "$i" = 8 ] && { tmux send-keys -t "$pane" C-c; [ "$kind" = claude ] && { _nap; tmux send-keys -t "$pane" C-c; }; }
    _nap
  done
  _die "sent Ctrl-C but pane $pane still shows '$now' (peek it — maybe mid-turn or a dialog is open)"
}
cmd_start() {
  _need tmux
  local name="${1:-}" child="${2:-shell}" workdir="${3:-}"
  [ -n "$name" ] || _die "usage: overseer start <name> [shell|claude|codex] [workdir]"
  _ok_session_name "$name" || _die "invalid session name '$name' (letters, digits, '_' or '-' only; tmux forbids ':' and '.')"
  case "$child" in shell|claude|codex) : ;; *) _die "child must be shell, claude or codex (got '$child')" ;; esac
  tmux has-session -t "=$name" 2>/dev/null && _die "session '$name' already exists — stop it first (overseer stop $name) or pick another name"
  [ -n "$workdir" ] && [ ! -d "$workdir" ] && _die "workdir does not exist: $workdir"
  local -a nsargs=(new-session -d -s "$name" -x 200 -y 50)
  [ -n "$workdir" ] && nsargs+=(-c "$workdir")
  tmux "${nsargs[@]}" 2>/dev/null || _die "could not create tmux session '$name'"
  local pane; pane=$(tmux list-panes -t "=$name" -F '#{pane_id}' 2>/dev/null | head -1)
  [ -n "$pane" ] || _die "session '$name' created but has no pane"
  if [ "$child" = shell ]; then
    printf 'started shell session %s (%s)%s\nwatch: tmux attach -t %s   drive: overseer sh %s <command>\n' \
      "$name" "$pane" "${workdir:+ in $workdir}" "$name" "$name"
    return 0
  fi
  tmux send-keys -t "$pane" -l "$child"
  tmux send-keys -t "$pane" Enter
  local pp deadline ready=''
  pp=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)
  deadline=$((SECONDS + 30))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(_harness_of "$pp" 2>/dev/null)" = "$child" ] && { ready=1; break; }
    _nap
  done
  [ -n "$ready" ] || _die "session '$name' ($pane) is up but $child has not appeared after 30s — peek it (overseer peek $name); is $child installed / did it error?"
  printf 'started %s session %s (%s)%s\nwatch: tmux attach -t %s   drive: overseer chat %s <message>\n' \
    "$child" "$name" "$pane" "${workdir:+ in $workdir}" "$name" "$name"
}
cmd_stop() {
  _need tmux
  local target="${1:-}"; [ -n "$target" ] || _die "usage: overseer stop <pane|session>"
  local peerpane rc=0; peerpane=$(_pane_by_peer_name "$target") || rc=$?
  if [ "$rc" = 2 ]; then _peer_ambiguous "$target"; fi
  if [ "$rc" = 3 ]; then _peer_no_pane "$target"; fi
  [ -z "$peerpane" ] || target="$peerpane"
  case "$target" in
    %[0-9]*)
      local pane; pane=$(_resolve_pane "$target") || _target_die "$target" "no tmux pane for target: $target"
      _self_pane "$pane" && _die "refusing to kill the pane overseer is running in ($pane) — run stop from outside it"
      tmux kill-pane -t "$pane" 2>/dev/null || _die "could not kill pane $pane"
      printf 'stopped pane %s\n' "$pane"
      ;;
    *)
      tmux has-session -t "=$target" 2>/dev/null || _die "no tmux session named '$target' (see: overseer list --all; to kill one pane target its %N)"
      if [ -n "${TMUX_PANE:-}" ]; then
        local mysess; mysess=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
        [ "$mysess" = "$target" ] && _die "refusing to kill the session '$target' — overseer is running inside it (would cut this session); run stop from outside, or target a specific pane %N"
      fi
      tmux kill-session -t "=$target" 2>/dev/null || _die "could not kill session '$target'"
      printf 'stopped session %s\n' "$target"
      ;;
  esac
}
# invoke a Claude slash command in a pane (/resume, /clear, /model, ...). send/chat can't: they
# prepend a space so a leading / stays literal text; this types it AS a command and submits. commands
# that open a menu (/resume, /model) then need keys + peek to navigate (Up/Down, Enter, Esc).
cmd_slash() {
  _need tmux
  local target="${1:-}" slash="${2:-}"
  [ -n "$target" ] && [ -n "$slash" ] || _die "usage: overseer slash <pane|session> </command>"
  case "$slash" in /*) : ;; *) slash="/$slash" ;; esac   # accept 'resume' or '/resume'
  case "$slash" in *$'\n'*) _die "one slash command line only" ;; esac
  local pane pp kind; pane=$(_resolve_pane "$target") || _target_die "$target" "no tmux pane for target: $target"
  _no_self "$pane" "run a slash command in"
  pp=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null) || _die "pane $pane vanished"
  kind=$(_harness_of "$pp") || _die "pane $pane is not a claude/codex agent; slash commands need an agent TUI"
  _lock_pane "$pane"
  _clear_box "$pane" || _die "could not clear the input box"
  tmux send-keys -t "$pane" -l "$slash"
  local i got; for i in $(seq 1 40); do [ "$(_realtext "$pane")" = "$slash" ] && break; _nap; done
  got=$(_realtext "$pane")
  [ "$got" = "$slash" ] || { _clear_box "$pane"; _die "input shows '$got', expected '$slash'"; }
  tmux send-keys -t "$pane" Enter
  printf 'ran %s in %s (harness=%s) — peek it (a menu needs keys to navigate: Up/Down, Enter, Esc)\n' "$slash" "$pane" "$kind"
}
# navigate a tab bar / highlighted list so <name> becomes the active item, then stop. verify-driven:
# press ONE nav key, re-read the highlight, repeat until <name> is active or we have cycled — never
# counts keystrokes (a key can double-register and a tab bar wraps, so counting is unreliable).
# nav-key defaults to Right (a tab bar); pass Down (or Up) for a vertical list. does NOT select —
# follow with `keys <t> Enter` to pick, or `peek` to read the tab you landed on.
cmd_menu() {
  _need tmux
  local target="${1:-}" name="${2:-}" navkey="${3:-Right}"
  [ -n "$target" ] && [ -n "$name" ] || _die "usage: overseer menu <pane|session> <item-name> [nav-key]"
  local pane; pane=$(_resolve_pane "$target") || _target_die "$target" "no tmux pane for target: $target"
  _no_self "$pane" "navigate a menu in"
  _lock_pane "$pane"
  _wake_pane "$pane"
  local i sig
  local -A seen=()
  for i in $(seq 1 60); do
    _is_active "$pane" "$name" && { printf 'active: %s (pane %s)\n' "$name" "$pane"; return 0; }
    # stop when the screen repeats a state already seen: the menu has wrapped a full cycle without
    # the item appearing. handles a short tab bar and a long scrolling list alike, no magic count.
    sig=$(tmux capture-pane -e -p -t "$pane" 2>/dev/null | head -n -3 | cksum | cut -d' ' -f1)
    [ -n "${seen[$sig]:-}" ] && break
    seen[$sig]=1
    tmux send-keys -t "$pane" "$navkey"
    _nap; _nap   # let the highlight settle before re-reading
  done
  _is_active "$pane" "$name" && { printf 'active: %s (pane %s)\n' "$name" "$pane"; return 0; }
  _die "could not make '$name' active (cycled the whole view without it becoming highlighted — is it an item here? try: overseer peek raw $target)"
}
_tmux_server_pid() {
  local p
  p=$(tmux list-sessions -F '#{pid}' 2>/dev/null | head -1) && [ -n "$p" ] && { printf '%s' "$p"; return 0; }
  pgrep -u "$(id -u)" -x 'tmux: server' 2>/dev/null | head -1
}
_tmux_reachable() { tmux list-sessions >/dev/null 2>&1; }
_tmux_mismatch() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ]; }
_tmux_mismatch_text() {
  printf 'two tmux builds on this machine: PATH resolves to %s (%s), the running server was started from %s. A tmux client only speaks to a server of its own protocol version, so calling the other path fails with "server exited unexpectedly" — which reads like the server died. overseer always uses whichever tmux is on PATH; keep scripts and shells on that one' \
    "$1" "$2" "$3"
}
_doctor_probe() {
  local kind="$1" jl rc n
  jl=$(_probe_contract "$kind") && rc=0 || rc=$?
  case "$rc" in
    0) n=$(_h_turn_count "$kind" "$jl"); printf '  [ok]   %s transcript readable (overseer parsed %s completed turns from the newest session)\n' "$kind" "$n" ;;
    1) printf '  [FAIL] %s transcript has completed turns but overseer cannot read the reply — its on-disk schema may have changed (see README caveats): %s\n' "$kind" "$jl"; return 1 ;;
    2) printf '  [ok]   no %s session with a completed turn yet — nothing to probe\n' "$kind" ;;
  esac
}
_doctor_live() {
  command -v tmux >/dev/null 2>&1 || { printf '  [skip] live self-test: tmux not available\n'; return 0; }
  local sess="overseer-doctor-$$" pane out rc=0
  tmux new-session -d -s "$sess" -x 80 -y 24 2>/dev/null || { printf '  [skip] live self-test: could not open a throwaway tmux session\n'; return 0; }
  pane=$(tmux list-panes -t "$sess" -F '#{pane_id}' 2>/dev/null | head -1)
  if [ -n "$pane" ]; then
    out=$( ( cmd_sh "$pane" 'echo overseer-live-uptest' 15 ) 2>/dev/null ) || true
    if printf '%s' "$out" | grep -q overseer-live-uptest; then
      printf '  [ok]   live self-test: sh round-trip on a throwaway pane (send -> sentinel -> capture works end to end)\n'
    else
      printf '  [FAIL] live self-test: sh round-trip returned no marker — the tmux send-keys/capture-pane path may be broken\n'
      rc=1
    fi
  else
    printf '  [skip] live self-test: no pane in the throwaway session\n'
  fi
  tmux kill-session -t "$sess" 2>/dev/null || true
  return "$rc"
}
_quota_cache() { printf '%s/overseer/quota-claude.json' "${XDG_CACHE_HOME:-$HOME/.cache}"; }
_creds_file()  { printf '%s/.credentials.json' "$CLAUDE_HOME"; }
_epoch_of() {
  case "${1:-}" in
    ''|0) printf '0' ;;
    *[!0-9]*) date -d "$1" +%s 2>/dev/null || printf '0' ;;
    *) printf '%s' "$1" ;;
  esac
}
_dur_until() {
  local s d h m; s=$(( $(_epoch_of "${1:-0}") - $(date +%s) ))
  [ "$s" -le 0 ] && { printf 'now'; return 0; }
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}
_pct_bad() { local p="${1:-0}"; p="${p%%.*}"; case "$p" in ''|*[!0-9]*) return 1 ;; esac; [ "$p" -ge "$QUOTA_WARN" ]; }
_claude_quota_fetch() {
  local f exp now
  f=$(_creds_file)
  [ -f "$f" ] || return 2
  exp=$(jq -r '.claudeAiOauth.expiresAt // 0' "$f" 2>/dev/null || echo 0)
  now=$(date +%s)
  [ "${exp%%.*}" -gt "$((now * 1000))" ] 2>/dev/null || return 3
  jq -r '"header = \"Authorization: Bearer \(.claudeAiOauth.accessToken)\""' "$f" 2>/dev/null |
    curl -sS --fail --max-time 15 --config - \
      -H 'anthropic-beta: oauth-2025-04-20' -H 'Accept: application/json' \
      https://api.anthropic.com/api/oauth/usage 2>/dev/null
}
_claude_quota_cached() {
  local c age; c=$(_quota_cache)
  if [ -f "$c" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$c" 2>/dev/null || echo 0) ))
    [ "$age" -lt "$QUOTA_TTL" ] && { cat "$c"; return 0; }
  fi
  local body rc=0; body=$(_claude_quota_fetch) || rc=$?
  [ "$rc" = 0 ] && [ -n "$body" ] || return "$rc"
  mkdir -p "$(dirname "$c")" 2>/dev/null || true
  ( umask 077; printf '%s' "$body" > "$c.$$" ) 2>/dev/null && mv -f "$c.$$" "$c" 2>/dev/null || rm -f "$c.$$" 2>/dev/null
  printf '%s' "$body"
}
_quota_why() {
  case "${1:-}" in
    2) printf 'no OAuth credentials in %s — normal on a third-party backend (Bedrock/Vertex/API key/proxy), which has no subscription window' "$(_creds_file)" ;;
    3) printf 'the OAuth token in %s has expired — overseer cannot refresh it; run any claude session once to renew it' "$(_creds_file)" ;;
    *) printf 'could not reach https://api.anthropic.com/api/oauth/usage (network, or the endpoint changed)' ;;
  esac
}
_usage_rows_claude() {
  printf '%s' "$1" | jq -r '(.limits // []) | .[]
    | ((.kind // "quota") + (if (.scope.model.display_name // "") != "" then ":" + .scope.model.display_name else "" end)) as $l
    | "\($l)\t\(.percent // 0)\t\(.resets_at // 0)\t\(.severity // "normal")"' 2>/dev/null
}
_usage_rows_codex() {
  printf '%s\n%s\n' "$(_cx_rate_limits "$1")" "$(_cx_token_info "$1")" | jq -rn '
    def wlabel(m): if m == null then "quota" elif m % 1440 == 0 then "\(m/1440|floor)d" elif m % 60 == 0 then "\(m/60|floor)h" else "\(m)m" end;
    [inputs] as $x | ($x[0] // {}) as $r | ($x[1] // {}) as $i
    | ( if ($r.primary // null) != null then "\(wlabel($r.primary.window_minutes))\t\($r.primary.used_percent)\t\($r.primary.resets_at // 0)\tnormal" else empty end),
      ( if ($r.secondary // null) != null then "\(wlabel($r.secondary.window_minutes))\t\($r.secondary.used_percent)\t\($r.secondary.resets_at // 0)\tnormal" else empty end)' 2>/dev/null
}
_ctx_tokens() {
  case "$1" in
    claude) jq -rn 'last(inputs | select(.type=="assistant") | (.message.usage // {})
              | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))) // 0' "$2" 2>/dev/null ;;
    codex)  _cx_token_info "$2" | jq -r '"\(.last_token_usage.total_tokens // 0)/\(.model_context_window // 0)"' 2>/dev/null ;;
  esac
}
_rows_epoch() {
  local a b c d
  while IFS=$'\t' read -r a b c d; do
    [ -n "$a" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$a" "$b" "$(_epoch_of "$c")" "$d"
  done
}
_quota_rows_print() {
  local rows label pct rst sev when
  while IFS=$'\t' read -r label pct rst sev; do
    [ -n "$label" ] || continue
    when=''; [ "$(_epoch_of "$rst")" -gt 0 ] && when="resets in $(_dur_until "$rst")"
    if [ "$sev" != normal ] || _pct_bad "$pct"; then
      printf '  quota %-20s %5s%%  %-16s <-- %s\n' "$label" "${pct%%.*}" "$when" "$(printf '%s' "${sev}" | tr '[:lower:]' '[:upper:]')"
    else
      printf '  quota %-20s %5s%%  %s\n' "$label" "${pct%%.*}" "$when"
    fi
  done <<< "$1"
}
_quota_breached() {
  local label pct sev
  while IFS=$'\t' read -r label pct _ sev; do
    [ -n "$label" ] || continue
    { [ "$sev" != normal ] || _pct_bad "$pct"; } && { printf '%s\t%s' "$label" "${pct%%.*}"; return 0; }
  done <<< "$1"
  return 1
}
_quota_warn_for() {
  local kind="$1" path="$2" rows b
  case "$kind" in
    claude) command -v curl >/dev/null 2>&1 || return 0
            rows=$(_usage_rows_claude "$(_claude_quota_cached 2>/dev/null || true)" | _rows_epoch) ;;
    codex)  { [ -n "$path" ] && [ -f "$path" ]; } || return 0
            rows=$(_usage_rows_codex "$path" | _rows_epoch) ;;
  esac
  [ -n "$rows" ] || return 0
  b=$(_quota_breached "$rows") || return 0
  printf 'overseer: WARNING %s quota %s at %s%% — see: overseer usage\n' "$kind" "${b%%$'\t'*}" "${b#*$'\t'}" >&2
  return 0
}
_report_turn_error() {
  local kind="$1" path="$2" target="$3" e
  { [ -n "$path" ] && [ -f "$path" ]; } || return 1
  e=$(_h_last_error "$kind" "$path") || return 1
  _report_error_text "$e" "$target"
}
_report_error_text() {
  local e="$1" target="$2" st txt
  [ -n "$e" ] || return 1
  st="${e%%$'\t'*}"; txt="${e#*$'\t'}"
  case "$st$txt" in
    429*|*[Uu]sage\ limit*|*[Rr]ate\ limit*|*[Qq]uota*|*credit*|*_limit_reached*)
      _die_code 5 "$target hit an API usage limit — the turn ENDED WITH NO REPLY: $txt
do NOT resend until it resets; check the account: overseer usage" ;;
  esac
  _die "$target failed with an API error — the turn ENDED WITH NO REPLY: $txt
usually transient (server-side); resend the same message once it clears: overseer peek $target"
}
_usage_claude() {
  local pane="$1" path="$2" json="$3" body rc=0 rows t
  _need curl
  body=$(_claude_quota_fetch) || rc=$?
  if [ "$rc" != 0 ]; then
    [ "$json" = 1 ] && { jq -nc --arg r "$(_quota_why "$rc")" '{harness:"claude", quota:null, unavailable:$r}'; return 0; }
    printf '# claude%s  account quota\n  quota   n/a            %s\n' "${pane:+ $pane}" "$(_quota_why "$rc")"
  else
    mkdir -p "$(dirname "$(_quota_cache)")" 2>/dev/null || true
    ( umask 077; printf '%s' "$body" > "$(_quota_cache)" ) 2>/dev/null || true
    rows=$(_usage_rows_claude "$body" | _rows_epoch)
    if [ "$json" = 1 ]; then
      printf '%s\n' "$rows" | jq -Rn --arg p "$pane" '{harness:"claude", pane:$p,
        quota:[inputs | select(length > 0) | split("\t")
               | {window:.[0], used_percent:((.[1]|tonumber?) // 0), resets_at:((.[2]|tonumber?) // 0), severity:.[3]}]}'
      return 0
    fi
    printf '# claude%s  account quota (live)\n' "${pane:+ $pane}"
    _quota_rows_print "$rows"
  fi
  { [ -n "$path" ] && [ -f "$path" ]; } || return 0
  t=$(_ctx_tokens claude "$path")
  printf '  context %16s tokens in this session (auto-compacts; informational, never a fault)\n' "$t"
}
_usage_codex() {
  local pane="$1" path="$2" json="$3" rows t
  rows=$(_usage_rows_codex "$path" | _rows_epoch); t=$(_ctx_tokens codex "$path")
  if [ "$json" = 1 ]; then
    printf '%s\n' "$rows" | jq -Rn --arg p "$pane" --arg t "$t" '{harness:"codex", pane:$p,
      quota:[inputs | select(length > 0) | split("\t")
             | {window:.[0], used_percent:((.[1]|tonumber?) // 0), resets_at:((.[2]|tonumber?) // 0), severity:.[3]}],
      context:$t}'
    return 0
  fi
  printf '# codex%s  %s\n' "${pane:+ $pane}" "$(_cx_rate_limits "$path" | jq -r '"plan=\(.plan_type // "?") limit=\(.limit_id // "?")"' 2>/dev/null)"
  if [ -n "$rows" ]; then _quota_rows_print "$rows"
  else printf '  quota   n/a            no subscription window in the rollout — normal on a third-party backend\n'; fi
  printf '  context %16s tokens (auto-compacts; informational, never a fault)\n' "$t"
}
cmd_usage() {
  _need jq
  local json=0
  while :; do case "${1:-}" in
    --json) json=1; shift ;;
    -*) _die "usage: overseer usage [--json] [pane|session]   (account quota + context; no target = this machine)" ;;
    *) break ;;
  esac; done
  local target="${1:-}" ctx pane kind path
  if [ -n "$target" ]; then
    _need tmux
    ctx=$(_target_ctx "$target") || _target_die "$target" "no agent pane (claude/codex) for target: $target (see: overseer list)"
    IFS=$'\t' read -r pane kind path <<< "$ctx"
    case "$kind" in
      claude) _usage_claude "$pane" "$path" "$json" ;;
      codex)  { [ -n "$path" ] && [ -f "$path" ]; } || _die "no rollout for $pane yet (a 0-turn codex has none)"
              _usage_codex "$pane" "$path" "$json" ;;
    esac
    return 0
  fi
  _usage_claude '' '' "$json"
  path=$(_newest_with_turns codex 2>/dev/null || true)
  [ -n "$path" ] && _usage_codex '' "$path" "$json"
  return 0
}
# preflight the runtime: the requirements (Linux/proc, tmux, jq) and — crucially — whether Claude
# Code's on-disk session state is where discovery expects it. Run this first when a pane "can't be
# found": a missing sessions dir usually means no claude is running OR Claude Code changed its layout.
cmd_doctor() {
  local bad=0 n cver cxv live=0
  case "${1:-}" in --live|live) live=1 ;; esac
  printf 'overseer doctor (CLAUDE_HOME=%s)\n' "$CLAUDE_HOME"
  if [ "$OVERSEER_OS" = Linux ]; then printf '  [ok]   Linux\n'; else printf '  [FAIL] not Linux (%s) — /proc discovery is unimplemented here; the macOS ps/lsof backend is specified in docs/PORTING.md but not built\n' "$OVERSEER_OS"; bad=1; fi
  [ -d /proc ] && printf '  [ok]   /proc present\n' || { printf '  [FAIL] /proc missing\n'; bad=1; }
  if command -v tmux >/dev/null 2>&1; then printf '  [ok]   tmux (%s)\n' "$(tmux -V 2>/dev/null)"; else printf '  [FAIL] tmux not found\n'; bad=1; fi
  if command -v jq >/dev/null 2>&1; then printf '  [ok]   jq (%s)\n' "$(jq --version 2>/dev/null)"; else printf '  [FAIL] jq not found — needed by read/chat/wait\n'; bad=1; fi
  if command -v claude >/dev/null 2>&1; then
    cver=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    printf '  [ok]   claude %s\n' "${cver:-unknown}"
  else
    printf '  [warn] claude CLI not on PATH — cannot drive claude panes\n'
  fi
  local spid sexe cexe
  spid=$(_tmux_server_pid) || spid=''
  if _tmux_reachable; then printf '  [ok]   tmux server running\n'
  elif [ -n "$spid" ]; then
    printf '  [FAIL] a tmux server is running (pid %s) but this tmux cannot reach it\n' "$spid"; bad=1
  else printf '  [warn] no tmux server yet (start a tmux session to drive)\n'; fi
  if [ -n "$spid" ]; then
    sexe=$(readlink -f "/proc/$spid/exe" 2>/dev/null) || sexe=''
    cexe=$(readlink -f "$(command -v tmux 2>/dev/null)" 2>/dev/null) || cexe=''
    _tmux_mismatch "$cexe" "$sexe" && printf '  [warn] %s\n' "$(_tmux_mismatch_text "$cexe" "$(tmux -V 2>/dev/null)" "$sexe")"
  fi
  if [ -d "$CLAUDE_HOME/sessions" ] && ls "$CLAUDE_HOME"/sessions/*.json >/dev/null 2>&1; then
    n=$(ls "$CLAUDE_HOME"/sessions/*.json 2>/dev/null | wc -l)
    printf '  [ok]   Claude session state found (%s/sessions/*.json: %s)\n' "$CLAUDE_HOME" "$n"
  else
    printf '  [warn] no %s/sessions/*.json — no claude running, OR Claude Code changed its on-disk layout (would break discovery; see README caveats)\n' "$CLAUDE_HOME"
  fi
  _doctor_probe claude || bad=1
  if ! command -v curl >/dev/null 2>&1; then
    printf '  [warn] curl not found — "overseer usage" cannot read the claude account quota (codex still works)\n'
  else
    local qrc=0 qbody; qbody=$(_claude_quota_fetch) || qrc=$?
    if [ "$qrc" = 0 ] && [ -n "$(_usage_rows_claude "$qbody")" ]; then
      printf '  [ok]   claude account quota readable (%s window(s) from /api/oauth/usage)\n' "$(_usage_rows_claude "$qbody" | wc -l)"
    else
      printf '  [warn] claude account quota unavailable — %s\n' "$(_quota_why "$qrc")"
    fi
  fi
  if command -v codex >/dev/null 2>&1; then
    cxv=$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    printf '  [ok]   codex %s\n' "${cxv:-unknown}"
  else
    printf '  [warn] codex CLI not on PATH — codex panes cannot be driven (claude still works)\n'
  fi
  [ -d "$CODEX_HOME/sessions" ] && printf '  [ok]   Codex session state dir present (%s/sessions)\n' "$CODEX_HOME" \
    || printf '  [warn] no %s/sessions — no codex has run yet, or Codex changed its layout\n' "$CODEX_HOME"
  _doctor_probe codex || bad=1
  if _awaiting_text "$(printf 'proceed?\n❯ 1. yes\n  2. no\n')" >/dev/null 2>&1; then
    printf '  [ok]   awaiting-prompt detector matches a sample menu (glyph + locale OK)\n'
  else
    printf '  [FAIL] awaiting-prompt detector failed on a sample menu — check the UTF-8 locale (awk may not match ❯/›); wait/chat would miss permission prompts\n'; bad=1
  fi
  [ "$live" = 1 ] && { _doctor_live || bad=1; }
  [ "$bad" = 0 ] && printf 'doctor: OK\n' || { printf 'doctor: failed checks above — overseer will not work correctly until they are fixed\n'; return 1; }
}
_on_ensure_deployed() {
  local host="$1" bin="$2" cmdir="$3"
  # shellcheck disable=SC2086
  ${OVERSEER_SSH:-ssh} -o ControlMaster=auto -o "ControlPath=$cmdir/%C" -o ControlPersist=60s \
    -o ConnectTimeout=10 ${OVERSEER_SSH_OPTS:-} "$host" "[ -f \"$bin\" ]" >/dev/null 2>&1 && return 0
  printf 'overseer: %s has no overseer yet — deploying it once...\n' "$host" >&2
  cmd_deploy "$host" >&2 || _die "auto-deploy to $host failed — deploy it manually (overseer deploy $host), or set OVERSEER_NO_AUTODEPLOY=1 to skip this"
}
cmd_on() {
  _need ssh
  local host="${1:-}"; shift || true
  [ -n "$host" ] && [ "$#" -gt 0 ] || _die "usage: overseer on <host> <command> [args]   (run any overseer command on a remote ssh host, e.g. overseer on sandbox chat %0 'hi')"
  local bin="${OVERSEER_REMOTE_BIN:-\$HOME/.overseer/scripts/overseer}"
  local cmdir="${TMPDIR:-/tmp}/overseer-ssh-$UID"
  mkdir -p "$cmdir" 2>/dev/null || true
  local rargs='' a
  for a in "$@"; do rargs="$rargs '${a//\'/\'\\\'\'}'"; done
  [ -z "${OVERSEER_REMOTE_BIN:-}" ] && [ -z "${OVERSEER_NO_AUTODEPLOY:-}" ] && _on_ensure_deployed "$host" "$bin" "$cmdir"
  # shellcheck disable=SC2086
  exec ${OVERSEER_SSH:-ssh} -o ControlMaster=auto -o "ControlPath=$cmdir/%C" -o ControlPersist=60s \
    -o ConnectTimeout=10 ${OVERSEER_SSH_OPTS:-} "$host" "OVS_VIA_ON=1 $bin$rargs"
}
cmd_deploy() {
  _need ssh; _need tar
  local host="${1:-}"; shift || true
  [ -n "$host" ] || _die "usage: overseer deploy <host>   (copy overseer's scripts to ~/.overseer on a remote ssh host, do this once before 'overseer on <host> ...')"
  local dest="${OVERSEER_REMOTE_DIR:-.overseer}"
  # shellcheck disable=SC2086
  tar -C "$_dir/.." -cf - scripts | ${OVERSEER_SSH:-ssh} -o ConnectTimeout=10 ${OVERSEER_SSH_OPTS:-} "$host" "mkdir -p \"\$HOME/$dest\" && exec tar -C \"\$HOME/$dest\" -xf -" \
    && printf 'overseer: deployed scripts to %s:~/%s/\n' "$host" "$dest"
}
_host_probe() {
  local target="$1" timeout="$2" ts="$3"
  local hp="${target##*@}" out rc os ssh drive online duser
  hp="${hp%%:*}"
  case "$target" in
    *@*) duser="${target%@*}" ;;
    # shellcheck disable=SC2086
    *)   duser=$(${OVERSEER_SSH:-ssh} -G "$hp" 2>/dev/null | awk 'tolower($1) == "user" { print $2; exit }') ;;
  esac
  [ -n "$duser" ] || duser='?'
  online=$(printf '%s\n' "$ts" | _ts_state "$hp") || online='?'
  # shellcheck disable=SC2086
  if out=$(${OVERSEER_SSH:-ssh} -o BatchMode=yes -o ConnectTimeout="$timeout" ${OVERSEER_SSH_OPTS:-} "$target" 'uname -s; command -v tmux; command -v jq' 2>&1); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" = 255 ]; then
    case "$out" in
      *"Permission denied"*|*publickey*|*password*) ssh=deny ;;
      *"Host key verification failed"*|*"IDENTIFICATION HAS CHANGED"*) ssh=hostkey ;;
      *) ssh=unreach ;;
    esac
    os='?'; drive='-'
  else
    ssh=ok
    case "$out" in
      *"is not recognized"*|*"not recognized as"*) os=windows; drive='win*' ;;
      *Linux*)
        os=linux
        case "$out" in
          *tmux*) case "$out" in *jq*) drive=yes ;; *) drive='no:jq' ;; esac ;;
          *)      case "$out" in *jq*) drive='no:tmux' ;; *) drive='no:tmux,jq' ;; esac ;;
        esac ;;
      *Darwin*) os=macos; drive='no:macos' ;;
      *) os='?'; drive='?' ;;
    esac
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$duser@$hp" "$online" "$os" "$ssh" "$drive"
}
_inventory() {
  local usetail="$1" osfilter="$2" defuser="$3" ts="$4"
  local src content cfg="$HOME/.ssh/config" xdg="${XDG_CONFIG_HOME:-$HOME/.config}/overseer/hosts"
  if [ "$usetail" = 1 ]; then
    [ -n "$ts" ] || _die "--tailscale needs the tailscale CLI and a running tailnet (tailscale status returned nothing)"
    src="tailscale status${osfilter:+ (os=$osfilter)}"; content=$(printf '%s\n' "$ts" | _ts_hosts "$osfilter")
  elif [ -n "${OVERSEER_HOSTS:-}" ]; then
    [ -r "$OVERSEER_HOSTS" ] || _die "OVERSEER_HOSTS is set but not readable: $OVERSEER_HOSTS"
    src="$OVERSEER_HOSTS"; content=$(_hosts_parse < "$OVERSEER_HOSTS")
  elif [ -r "$xdg" ]; then
    src="$xdg"; content=$(_hosts_parse < "$xdg")
  elif [ -r "$cfg" ]; then
    src="$cfg (Host entries)"; content=$(_ssh_config_hosts < "$cfg")
  else
    _die "no fleet inventory found. Set OVERSEER_HOSTS to a file of ssh targets (one 'user@host' or ssh-config alias per line), create $xdg, or add Host entries to $cfg"
  fi
  _INV_SRC="$src"; _INV_TARGETS=()
  local t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$t" in *@*) : ;; *) [ -n "$defuser" ] && t="$defuser@$t" ;; esac
    _INV_TARGETS+=("$t")
  done <<< "$content"
  [ "${#_INV_TARGETS[@]}" -gt 0 ] || _die "no hosts in $src"
}
cmd_hosts() {
  _need ssh
  local listonly=0 timeout=6 usetail=0 osfilter='' defuser="${OVERSEER_HOSTS_USER:-}"
  local u='usage: overseer hosts [--list] [--tailscale] [--os NAME] [-u USER] [-t seconds]'
  while :; do case "${1:-}" in
    --list) listonly=1; shift ;;
    --tailscale) usetail=1; shift ;;
    --os) [ -n "${2:-}" ] || _die "$u"; osfilter="$2"; shift 2 ;;
    -u) [ -n "${2:-}" ] || _die "$u"; defuser="$2"; shift 2 ;;
    -t) [ -n "${2:-}" ] || _die "$u"; timeout="$2"; shift 2 ;;
    -*) _die "unknown flag '$1' ($u)" ;;
    *) break ;;
  esac; done
  _uint "$timeout"
  [ -n "$osfilter" ] && [ "$usetail" = 0 ] && _die "--os only applies with --tailscale"
  local ts=''
  command -v tailscale >/dev/null 2>&1 && ts=$(tailscale status 2>/dev/null || true)
  _inventory "$usetail" "$osfilter" "$defuser" "$ts"
  local src="$_INV_SRC"; local -a targets=("${_INV_TARGETS[@]}"); local t
  if [ "$listonly" = 1 ]; then
    printf 'source: %s\n' "$src"
    printf '%s\n' "${targets[@]}"
    return 0
  fi
  local tmp="${TMPDIR:-/tmp}/overseer-hosts-$UID-$$"
  mkdir -p "$tmp" 2>/dev/null || _die "could not create temp dir: $tmp"
  local i=0
  for t in "${targets[@]}"; do
    ( _host_probe "$t" "$timeout" "$ts" >"$tmp/$i" 2>/dev/null ) &
    i=$((i + 1))
  done
  wait
  printf 'source: %s\n\n' "$src"
  printf 'HOST\tONLINE\tOS\tSSH\tDRIVE\n'
  i=0
  for t in "${targets[@]}"; do cat "$tmp/$i" 2>/dev/null; i=$((i + 1)); done
  rm -rf "$tmp" 2>/dev/null || true
}
cmd_provision() {
  _need ssh
  local dry=0
  while :; do case "${1:-}" in
    --dry-run) dry=1; shift ;;
    -*) _die "unknown flag '$1' (usage: overseer provision [--dry-run] <host>)" ;;
    *) break ;;
  esac; done
  local host="${1:-}"
  [ -n "$host" ] || _die "usage: overseer provision [--dry-run] <host>   (install the missing Linux drive deps tmux+jq on a remote ssh host; needs root or passwordless sudo. Agents/Windows deps are set up manually)"
  local out rc
  # shellcheck disable=SC2086
  if out=$(_provision_script "$dry" | ${OVERSEER_SSH:-ssh} -o ConnectTimeout=10 ${OVERSEER_SSH_OPTS:-} "$host" 'sh -s' 2>&1); then rc=0; else rc=$?; fi
  printf '%s: %s\n' "$host" "$out"
  return "$rc"
}
