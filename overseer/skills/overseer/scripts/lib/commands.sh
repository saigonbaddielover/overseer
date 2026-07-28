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
  printf 'SESSION\tPANE\tPANE_PID\tHARNESS\tCWD\n'
  _panes
}
cmd_read() {
  _need tmux; _need jq
  local target="${1:-}"; [ -n "$target" ] || _die "usage: overseer read <pane|session>"
  local ctx pane kind path; ctx=$(_target_ctx "$target") || _die "no agent pane (claude/codex) for target: $target (if the session is split, target the pane id %N — see: overseer list)"
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
  local pane; pane=$(_resolve_pane "$target") || _die "no tmux pane for target: $target"
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
  local pane; pane=$(_resolve_pane "$target") || _die "no tmux pane for target: $target"
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
  local confirm=1 notify=0
  while :; do case "${1:-}" in --yes) confirm=0; shift ;; --notify) notify=1; shift ;; *) break ;; esac; done
  local target="${1:-}" msg
  [ -n "$target" ] || _die "usage: overseer send [--yes] [--notify] <pane|session> <message|-> [notify_timeout_s]"
  msg=$(_read_msg "${2:-}")
  [ -n "$msg" ] || _die "usage: overseer send [--yes] [--notify] <pane|session> <message|-> [notify_timeout_s]  (empty message)"
  local ntimeout="${3:-$DEFAULT_TIMEOUT}" back=''
  if [ "$notify" = 1 ]; then _need setsid; _uint "$ntimeout"
    back=$(_notify_back) || _die "--notify has nowhere to report back to: overseer is not running inside a tmux pane (\$TMUX_PANE is unset), so the dispatching agent has no pane id — drop --notify, or run it from the agent pane that should be woken"
  elif [ -n "${3:-}" ]; then _die "send takes a [timeout] only with --notify (it never waits for the reply itself — use chat for that)"; fi
  local ctx pane kind path; ctx=$(_target_ctx "$target") || _die "no agent pane (claude/codex) for target: $target (if the session is split, target the pane id %N — see: overseer list)"
  IFS=$'\t' read -r pane kind path <<< "$ctx"
  [ "$back" = "$pane" ] && _die "--notify would wake the pane it is dispatching to ($pane) — send to a different agent, or drop --notify"
  _lock_pane "$pane"
  { _queued "$pane" && ! _compacting "$pane"; } && { _unlock_pane; _die "a message is already queued to $pane behind its running turn (the agent holds one queued message at a time) — wait for it to run first: overseer wait $target"; }
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
    printf 'sent to %s (QUEUED — the agent is %s):\n%s\naccepted and will run when the agent is free; await the reply: overseer wait %s [timeout]\n' "$pane" "$why" "$msg" "$target"
    if [ "$notify" = 1 ]; then _notify_spawn "$pane" "$kind" "$back" "$ntimeout" 1; fi
    return 0
  fi
  local rc=0; path=$(_wait_started "$target" "$kind" "$path" "$base" 10 "$pane" "$sid" "$since" "$bbytes" "$prequeue") || rc=$?
  _quota_warn_for "$kind" "$path"
  local started=0; case "$rc" in 0|4|5) started=1 ;; esac
  if [ "$notify" = 1 ] && [ "$rc" != 2 ]; then _notify_spawn "$pane" "$kind" "$back" "$ntimeout" "$started"; fi
  case "$rc" in
    5|4) local why="busy with its current turn"; _compacting "$pane" && why="compacting its context"
       printf 'sent to %s (QUEUED — the agent is %s):\n%s\naccepted and will run when the agent is free; await the reply: overseer wait %s [timeout]\n' "$pane" "$why" "$msg" "$target" ;;
    2) printf 'sent to %s:\n%s\n' "$pane" "$msg"; _report_awaiting "$pane" "$target" ;;
    1) printf 'sent to %s:\n%s\n' "$pane" "$msg"
       _die "could not confirm the turn started within 10s — the message may still be sitting in the input box; peek: overseer peek $target" ;;
    *) printf 'sent to %s (turn started):\n%s\n' "$pane" "$msg" ;;
  esac
}
# send + wait for the turn to finish + print the reply (the human round-trip).
cmd_chat() {
  _need tmux; _need jq
  local confirm=1
  while :; do case "${1:-}" in --yes) confirm=0; shift ;; *) break ;; esac; done
  local target="${1:-}" msg
  [ -n "$target" ] || _die "usage: overseer chat [--yes] <pane|session> <message|-> [timeout_s]"
  msg=$(_read_msg "${2:-}")
  [ -n "$msg" ] || _die "usage: overseer chat [--yes] <pane|session> <message|-> [timeout_s]  (empty message)"
  local timeout="${3:-$DEFAULT_TIMEOUT}"; _uint "$timeout"
  local ctx pane kind path; ctx=$(_target_ctx "$target") || _die "no agent pane (claude/codex) for target: $target (if the session is split, target the pane id %N — see: overseer list)"
  IFS=$'\t' read -r pane kind path <<< "$ctx"
  _lock_pane "$pane"
  { _queued "$pane" && ! _compacting "$pane"; } && { _unlock_pane; _die "a message is already queued to $pane behind its running turn (the agent holds one queued message at a time) — wait for it to run first: overseer wait $target"; }
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
  local ctx pane kind path; ctx=$(_target_ctx "$target") || _die "no agent pane (claude/codex) for target: $target (if the session is split, target the pane id %N — see: overseer list)"
  IFS=$'\t' read -r pane kind path <<< "$ctx"
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
    read)   _need jq; for p in "${targets[@]}"; do printf '===== %s =====\n' "$p"; ( cmd_read "$p" ) || printf '(unavailable)\n'; done ;;
    wait)
      _need jq
      while :; do case "${1:-}" in --any) any=1; shift ;; *) break ;; esac; done
      if [ "$any" = 1 ]; then _fleet_wait_any "${1:-$DEFAULT_TIMEOUT}" "${targets[@]}"
      else for p in "${targets[@]}"; do printf '# %s: ' "$p"; ( cmd_wait "$p" "$@" ) || true; done; fi ;;
    send|chat)
      [ "$action" = chat ] && _need jq
      while :; do case "${1:-}" in
        --yes) fl+=("$1"); shift ;;
        --notify) [ "$action" = send ] || _die "fleet chat already waits for every reply — --notify belongs to fleet send"
                  fl+=("$1"); shift ;;
        *) break ;; esac; done
      msg="${1:-}"; [ -n "$msg" ] || _die "usage: overseer fleet $action [--yes] <message>  (broadcasts to every agent pane)"
      local -a nt=(); { [ "$action" = send ] && [ -n "${2:-}" ]; } && nt=("$2")
      for p in "${targets[@]}"; do
        printf '===== %s =====\n' "$p"
        st=$(_fleet_status "$p" | cut -f3)
        case "$st" in
          idle|'idle(0-turn)') : ;;
          *) printf '(skipped — %s; a broadcast only messages idle agents, so it never queues onto a busy one)\n' "$st"; continue ;;
        esac
        if [ "$action" = send ]; then ( cmd_send ${fl[@]+"${fl[@]}"} "$p" "$msg" ${nt[@]+"${nt[@]}"} ) || true
        else ( cmd_chat ${fl[@]+"${fl[@]}"} "$p" "$msg" ) || true; fi
      done ;;
    *) _die "usage: overseer fleet [--hosts|--tailscale [--os NAME]] [-u USER] [status|read|wait [--any] [timeout]|send [--yes] [--notify] <msg> [notify_timeout]|chat [--yes] <msg>]  (no subcommand = status)" ;;
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
  local u='usage: overseer fleet [--hosts|--tailscale [--os NAME]] [-u USER] [status|read|wait [--any] [timeout]|send [--yes] [--dry-run] [--notify] <msg> [notify_timeout]|chat [--yes] [--dry-run] <msg>]'
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
  local yes=0 dry=0 msg=''
  case "$action" in
    send|chat)
      shift
      while :; do case "${1:-}" in
        --yes) yes=1; shift ;;
        --dry-run) dry=1; shift ;;
        --notify) _die "--notify wakes the dispatching agent's own tmux pane, which exists only on this machine — run it against the local fleet (overseer fleet send --notify <msg>), not with --hosts/--tailscale" ;;
        *) break ;;
      esac; done
      msg="${1:-}"
      [ -n "$msg" ] || _die "usage: overseer fleet --hosts $action [--yes] [--dry-run] <message>  (broadcasts to every idle agent in the fleet)"
      set -- "$action" --yes "$msg" ;;
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
  pane=$(_resolve_pane "$target") || _die "no tmux pane for target: $target"
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
  local pane pp kind; pane=$(_resolve_pane "$target") || _die "no tmux pane for target: $target"
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
  case "$target" in
    %[0-9]*)
      local pane; pane=$(_resolve_pane "$target") || _die "no tmux pane for target: $target"
      [ -n "${TMUX_PANE:-}" ] && [ "$TMUX_PANE" = "$pane" ] && _die "refusing to kill the pane overseer is running in ($pane) — run stop from outside it"
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
  local pane pp kind; pane=$(_resolve_pane "$target") || _die "no tmux pane for target: $target"
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
  local pane; pane=$(_resolve_pane "$target") || _die "no tmux pane for target: $target"
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
_usage_dir()      { printf '%s/usage' "$CLAUDE_HOME"; }
_usage_stub()     { printf '%s/overseer-statusline.sh' "$CLAUDE_HOME"; }
_usage_settings() { printf '%s/settings.json' "$CLAUDE_HOME"; }
_usage_newest()   { ls -t "$(_usage_dir)"/*.json 2>/dev/null | head -1; }
_usage_scopes()   { printf '.claude/settings.local.json\n.claude/settings.json\n%s\n' "$(_usage_settings)"; }
_usage_effective() {
  local f c
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    c=$(jq -r '.statusLine.command // empty' "$f" 2>/dev/null || true)
    [ -n "$c" ] && { printf '%s\t%s' "$f" "$c"; return 0; }
  done <<< "$(_usage_scopes)"
  return 1
}
_usage_prev_command() {
  local f c skip="${1:-0}" i=0
  while IFS= read -r f; do
    i=$((i + 1)); [ "$i" -le "$skip" ] && continue
    [ -f "$f" ] || continue
    c=$(jq -r '.statusLine.command // empty' "$f" 2>/dev/null || true)
    [ -n "$c" ] || continue
    case "$c" in "$(_usage_stub)"*) continue ;; esac
    printf '%s\t%s' "$f" "$c"; return 0
  done <<< "$(_usage_scopes)"
  return 1
}
_usage_wired() {
  local e
  [ -x "$(_usage_stub)" ] || return 1
  e=$(_usage_effective) || return 1
  case "${e#*$'\t'}" in "$(_usage_stub)"*) return 0 ;; esac
  return 1
}
_usage_file_for() {
  local f="$(_usage_dir)/${1:-}.json"
  [ -n "${1:-}" ] && [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  return 1
}
_dur_until() {
  local s d h m; s=$(( ${1:-0} - $(date +%s) ))
  [ "$s" -le 0 ] && { printf 'now'; return 0; }
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}
_pct_bad() { local p="${1:-0}"; p="${p%%.*}"; case "$p" in ''|*[!0-9]*) return 1 ;; esac; [ "$p" -ge "$QUOTA_WARN" ]; }
_usage_rows_claude() {
  jq -r '(.rate_limits // {}) as $r
    | ( if ($r.five_hour // null) != null then "5h\t\($r.five_hour.used_percentage)\t\($r.five_hour.resets_at // 0)\t" else empty end),
      ( if ($r.seven_day // null) != null then "7d\t\($r.seven_day.used_percentage)\t\($r.seven_day.resets_at // 0)\t" else empty end),
      ( (.context_window // {}) as $c
        | if ($c.used_percentage // null) != null
          then "context\t\($c.used_percentage)\t0\t\($c.total_input_tokens // 0)/\($c.context_window_size // 0) tokens"
          else empty end )' "$1" 2>/dev/null
}
_usage_rows_codex() {
  printf '%s\n%s\n' "$(_cx_rate_limits "$1")" "$(_cx_token_info "$1")" | jq -rn '
    def wlabel(m): if m == null then "quota" elif m % 1440 == 0 then "\(m/1440|floor)d" elif m % 60 == 0 then "\(m/60|floor)h" else "\(m)m" end;
    [inputs] as $x | ($x[0] // {}) as $r | ($x[1] // {}) as $i
    | ( if ($r.primary // null) != null then "\(wlabel($r.primary.window_minutes))\t\($r.primary.used_percent)\t\($r.primary.resets_at // 0)\t" else empty end),
      ( if ($r.secondary // null) != null then "\(wlabel($r.secondary.window_minutes))\t\($r.secondary.used_percent)\t\($r.secondary.resets_at // 0)\t" else empty end),
      ( if (($i.model_context_window // 0) > 0)
        then "context\t\((($i.last_token_usage.total_tokens // 0) * 100 / $i.model_context_window)|floor)\t0\t\($i.last_token_usage.total_tokens // 0)/\($i.model_context_window) tokens"
        else empty end )' 2>/dev/null
}
_usage_rows() { case "$1" in claude) _usage_rows_claude "$2" ;; codex) _usage_rows_codex "$2" ;; esac; }
_usage_report() {
  local kind="$1" pane="$2" src="$3" json="$4" rows hdr label pct rst detail when q=0
  rows=$(_usage_rows "$kind" "$src")
  if [ "$json" = 1 ]; then
    printf '%s\n' "$rows" | jq -Rn --arg k "$kind" --arg p "$pane" --arg s "$src" \
      '[inputs | select(length > 0) | split("\t")
        | {window:.[0], used_percent:((.[1]|tonumber?) // 0), resets_at:((.[2]|tonumber?) // 0), detail:.[3]}]
       | {harness:$k, pane:$p, source:$s,
          quota:[.[] | select(.window != "context")],
          context:((map(select(.window == "context")) | first) // null)}'
    return 0
  fi
  if [ "$kind" = claude ]; then
    hdr=$(jq -r '"model=\(.model.display_name // .model.id // "?") session=\((.session_id // "????????")[0:8]) sampled=\(((now - (.sampled_at // 0))|floor))s ago"' "$src" 2>/dev/null)
  else
    hdr=$(_cx_rate_limits "$src" | jq -r '"plan=\(.plan_type // "?") limit=\(.limit_id // "?")"' 2>/dev/null)
  fi
  printf '# %s%s  %s\n' "$kind" "${pane:+ $pane}" "$hdr"
  while IFS=$'\t' read -r label pct rst detail; do
    [ -n "$label" ] || continue
    if [ "$label" = context ]; then
      printf '  context %5s%%  %s (auto-compacts; informational, never a fault)\n' "${pct%%.*}" "$detail"
      continue
    fi
    q=1; when=''
    [ "${rst:-0}" -gt 0 ] 2>/dev/null && when="resets in $(_dur_until "$rst")"
    if _pct_bad "$pct"; then printf '  quota %-7s %5s%%  %s  <-- AT/NEAR THE LIMIT\n' "$label" "${pct%%.*}" "$when"
    else printf '  quota %-7s %5s%%  %s\n' "$label" "${pct%%.*}" "$when"; fi
  done <<< "$rows"
  [ "$q" = 0 ] && printf '  quota   n/a            no subscription window reported — normal on a third-party backend (Bedrock/Vertex/API key/proxy)\n'
  return 0
}
_quota_warn() {
  local kind="$1" src="$2" label pct
  [ -n "$src" ] && [ -f "$src" ] || return 0
  while IFS=$'\t' read -r label pct _ _; do
    { [ -n "$label" ] && [ "$label" != context ] && _pct_bad "$pct"; } &&
      printf 'overseer: WARNING %s quota %s at %s%% — see: overseer usage\n' "$kind" "$label" "${pct%%.*}" >&2
  done <<< "$(_usage_rows "$kind" "$src")"
  return 0
}
_quota_warn_for() {
  local kind="$1" path="$2" src=''
  case "$kind" in claude) src=$(_usage_newest) ;; codex) src="$path" ;; esac
  _quota_warn "$kind" "$src"
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
do NOT resend until it resets; check the account: overseer usage $target" ;;
  esac
  _die "$target failed with an API error — the turn ENDED WITH NO REPLY: $txt
usually transient (server-side); resend the same message once it clears: overseer peek $target"
}
_usage_hint() {
  if _usage_wired; then printf 'the collector is wired but has no sample yet: a claude session starts collecting on its next render, so restart the ones already open'
  else printf 'claude reports its account quota only to a statusline, so overseer has to be wired in once: overseer usage --install'; fi
}
cmd_usage() {
  _need jq
  local json=0
  while :; do case "${1:-}" in
    --json) json=1; shift ;;
    --install) _usage_install "${2:-}"; return 0 ;;
    --uninstall) _usage_uninstall "${2:-}"; return 0 ;;
    -*) _die "usage: overseer usage [--json] [pane|session]   (manage the claude collector: overseer usage --install [--here] | --uninstall [--here]; --here writes ./.claude/settings.local.json when a project statusLine overrides the user one)" ;;
    *) break ;;
  esac; done
  local target="${1:-}" ctx pane kind path uf sid any=0
  if [ -n "$target" ]; then
    _need tmux
    ctx=$(_target_ctx "$target") || _die "no agent pane (claude/codex) for target: $target (see: overseer list)"
    IFS=$'\t' read -r pane kind path <<< "$ctx"
    if [ "$kind" = claude ]; then
      sid=''; { [ -n "$path" ] && [ -f "$path" ]; } && sid=$(_sid_from_jsonl "$path")
      uf=$(_usage_file_for "$sid") || _die "no quota sample for $pane yet — $(_usage_hint)"
      _usage_report claude "$pane" "$uf" "$json"
    else
      { [ -n "$path" ] && [ -f "$path" ]; } || _die "no rollout for $pane yet (a 0-turn codex has none)"
      _usage_report codex "$pane" "$path" "$json"
    fi
    return 0
  fi
  uf=$(_usage_newest); [ -n "$uf" ] && { _usage_report claude '' "$uf" "$json"; any=1; }
  path=$(_newest_with_turns codex 2>/dev/null || true)
  [ -n "$path" ] && { _usage_report codex '' "$path" "$json"; any=1; }
  [ "$any" = 1 ] || _die "no quota data on this machine — $(_usage_hint)"
}
_usage_write_stub() {
  local f; f=$(_usage_stub)
  cat > "$f" <<'EOS'
#!/usr/bin/env bash
set -eu
H="${CLAUDE_HOME:-$HOME/.claude}"
in=$(cat)
sid=$(printf '%s' "$in" | jq -r '.session_id // empty' 2>/dev/null || true)
if [ -n "$sid" ]; then
  d="$H/usage"
  mkdir -p "$d" 2>/dev/null || true
  t=$(mktemp "$d/.tmp.XXXXXX" 2>/dev/null) || t=''
  if [ -n "$t" ]; then
    if printf '%s' "$in" | jq -c '{session_id, transcript_path, cwd, model, rate_limits, context_window, sampled_at: now}' >"$t" 2>/dev/null; then
      mv -f "$t" "$d/$sid.json" 2>/dev/null || rm -f "$t" 2>/dev/null || true
    else
      rm -f "$t" 2>/dev/null || true
    fi
  fi
fi
c="${1:-}"
if [ -n "$c" ] && [ -s "$c" ]; then
  CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(printf '%s' "$in" | jq -r '.workspace.project_dir // .cwd // empty' 2>/dev/null || true)}"
  export CLAUDE_PROJECT_DIR
  printf '%s' "$in" | sh -c "$(cat "$c")"
  exit 0
fi
printf '%s' "$in" | jq -r '(.rate_limits // {}) as $r
  | [ (if ($r.five_hour // null) != null then "5h \($r.five_hour.used_percentage)%" else empty end),
      (if ($r.seven_day // null) != null then "7d \($r.seven_day.used_percentage)%" else empty end),
      (if (.context_window.used_percentage // null) != null then "ctx \(.context_window.used_percentage)%" else empty end) ]
  | join(" · ")' 2>/dev/null || true
EOS
  chmod +x "$f"
}
_usage_scope_files() {
  if [ "${1:-0}" = 1 ]; then
    printf '.claude/settings.local.json\t.claude/overseer-statusline.chain\t${CLAUDE_PROJECT_DIR}/.claude/overseer-statusline.chain\t0'
  else
    printf '%s\t%s/overseer-statusline.chain\t%s/overseer-statusline.chain\t2' \
      "$(_usage_settings)" "$CLAUDE_HOME" "$CLAUDE_HOME"
  fi
}
_usage_install() {
  local here=0; [ "${1:-}" = --here ] && here=1
  _need jq
  local stub s chain cref skip cur tmp eff
  stub=$(_usage_stub)
  IFS=$'\t' read -r s chain cref skip <<< "$(_usage_scope_files "$here")"
  [ "$here" = 1 ] && { mkdir -p .claude 2>/dev/null || _die "could not create ./.claude in $PWD"; }
  mkdir -p "$(_usage_dir)" 2>/dev/null || _die "could not create $(_usage_dir)"
  local prev from; prev=$(_usage_prev_command "$skip" || true)
  from="${prev%%$'\t'*}"; cur=''; [ -n "$prev" ] && cur="${prev#*$'\t'}"
  _usage_write_stub
  if [ -n "$cur" ]; then printf '%s' "$cur" > "$chain"; printf '%s' "$from" > "$chain.from"
  else rm -f "$chain" "$chain.from" 2>/dev/null || true; fi
  tmp="$s.overseer.$$"
  if [ -f "$s" ]; then
    jq --arg c "$stub $cref" '.statusLine = {type:"command", command:$c}' "$s" > "$tmp" 2>/dev/null \
      || { rm -f "$tmp" 2>/dev/null || true; _die "could not parse $s as JSON — fix it, then rerun"; }
  else
    jq -n --arg c "$stub $cref" '{statusLine:{type:"command", command:$c}}' > "$tmp" 2>/dev/null \
      || { rm -f "$tmp" 2>/dev/null || true; _die "could not write $s"; }
  fi
  mv -f "$tmp" "$s" || { rm -f "$tmp" 2>/dev/null || true; _die "could not update $s"; }
  printf 'quota collector installed\n  statusLine -> %s   (in %s)\n  samples    -> %s/<session_id>.json\n' "$stub" "$s" "$(_usage_dir)"
  [ -n "$cur" ] && printf '  chained the statusline that was there: %s\n' "$cur"
  eff=$(_usage_effective || true)
  if [ -n "$eff" ] && [ "${eff%%$'\t'*}" != "$s" ]; then
    printf 'BUT %s defines a statusLine too and OVERRIDES what was just written — rerun inside that project: overseer usage --install --here\n' "${eff%%$'\t'*}"
    return 0
  fi
  printf 'a claude session starts collecting on its next render; restart the ones already open, then: overseer usage\n'
}
_usage_uninstall() {
  local here=0; [ "${1:-}" = --here ] && here=1
  _need jq
  local s chain cref skip tmp cur='' from=''
  IFS=$'\t' read -r s chain cref skip <<< "$(_usage_scope_files "$here")"
  [ -s "$chain" ] && cur=$(cat "$chain")
  [ -s "$chain.from" ] && from=$(cat "$chain.from")
  [ "$from" = "$s" ] || cur=''
  if [ -f "$s" ]; then
    tmp="$s.overseer.$$"
    if [ -n "$cur" ]; then jq --arg c "$cur" '.statusLine = {type:"command", command:$c}' "$s" > "$tmp" 2>/dev/null || true
    else jq 'del(.statusLine)' "$s" > "$tmp" 2>/dev/null || true; fi
    if [ -s "$tmp" ]; then mv -f "$tmp" "$s" || rm -f "$tmp" 2>/dev/null || true
    else rm -f "$tmp" 2>/dev/null || true; fi
  fi
  rm -f "$chain" "$chain.from" 2>/dev/null || true
  _usage_wired || rm -f "$(_usage_stub)" 2>/dev/null || true
  if [ -n "$cur" ]; then printf 'quota collector removed from %s (the statusline it replaced is restored)\n' "$s"
  else printf 'quota collector removed from %s (samples kept in %s)\n' "$s" "$(_usage_dir)"; fi
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
  if tmux info >/dev/null 2>&1; then printf '  [ok]   tmux server running\n'; else printf '  [warn] no tmux server yet (start a tmux session to drive)\n'; fi
  if [ -d "$CLAUDE_HOME/sessions" ] && ls "$CLAUDE_HOME"/sessions/*.json >/dev/null 2>&1; then
    n=$(ls "$CLAUDE_HOME"/sessions/*.json 2>/dev/null | wc -l)
    printf '  [ok]   Claude session state found (%s/sessions/*.json: %s)\n' "$CLAUDE_HOME" "$n"
  else
    printf '  [warn] no %s/sessions/*.json — no claude running, OR Claude Code changed its on-disk layout (would break discovery; see README caveats)\n' "$CLAUDE_HOME"
  fi
  _doctor_probe claude || bad=1
  if _usage_wired; then
    n=$(ls "$(_usage_dir)"/*.json 2>/dev/null | wc -l)
    printf '  [ok]   quota collector wired into statusLine (%s session sample(s) in %s)\n' "$n" "$(_usage_dir)"
  else
    printf '  [warn] quota collector not wired — "overseer usage" cannot read the claude ACCOUNT quota (claude reports it only to a statusline); install: overseer usage --install\n'
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
    -o ConnectTimeout=10 ${OVERSEER_SSH_OPTS:-} "$host" "$bin$rargs"
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
