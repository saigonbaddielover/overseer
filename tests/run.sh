#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LIB="$HERE/../overseer/skills/overseer/scripts/lib"
FIX="$HERE/fixtures"
export CLAUDE_HOME="$HERE/.home" CODEX_HOME="$HERE/.home"

# shellcheck source=../overseer/skills/overseer/scripts/lib/transcript.sh
. "$LIB/transcript.sh"
# shellcheck source=../overseer/skills/overseer/scripts/lib/tui.sh
. "$LIB/tui.sh"
# shellcheck source=../overseer/skills/overseer/scripts/lib/discovery.sh
. "$LIB/discovery.sh"
_die() { printf 'overseer: %s\n' "$1" >&2; exit 1; }
# shellcheck source=../overseer/skills/overseer/scripts/lib/windows.sh
. "$LIB/windows.sh"
# shellcheck source=../overseer/skills/overseer/scripts/lib/commands.sh
. "$LIB/commands.sh"

fail=0
eq() {
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"
    fail=$((fail + 1))
  fi
}

C="$FIX/claude-turn.jsonl"
eq "claude turn_count"     "2"                         "$(_turn_count "$C")"
eq "claude turns_after(0)" "2"                         "$(_turns_after claude "$C" 0)"
eq "claude not busy"       ""                          "$(_is_busy "$C" && echo busy)"
eq "claude last_reply"     $'final reply\nsecond line' "$(_last_reply "$C")"
eq "claude last_prompt"    "second prompt"             "$(_last_prompt "$C")"
eq "claude sid"            "test-sid-123"              "$(_sid_from_jsonl "$C")"

CB="$FIX/claude-busy.jsonl"
eq "claude busy"           "busy"                      "$(_is_busy "$CB" && echo busy)"
eq "claude busy turns"     "0"                         "$(_turn_count "$CB")"

RT="$FIX/claude-running-text.jsonl"
eq "running: text-only turn"        "running" "$(_running_claude "$RT" && echo running)"
eq "is_busy misses text-only turn"  ""        "$(_is_busy "$RT" && echo busy)"
eq "running: mid-tool turn"         "running" "$(_running_claude "$CB" && echo running)"
eq "running: answered turn is idle" ""        "$(_running_claude "$C" && echo running)"
eq "h_running claude dispatch"      "running" "$(_h_running claude "$CB" && echo running)"
eq "h_running codex dispatch"       "running" "$(_h_running codex "$FIX/codex-busy.jsonl" && echo running)"

RTN="$FIX/claude-reply-after-tasknotif.jsonl"
eq "reply for our prompt, not a later task-notif turn"     "ANS1"      "$(_reply_for_prompt "$RTN" "Q1")"
eq "last_reply mis-attributes to the later turn"           "TASK-DONE" "$(_last_reply "$RTN")"
eq "reply_for(last) == last real reply when no later turn" "$(_last_reply "$C")" "$(_reply_for_prompt "$C" "")"
eq "h_reply_for claude dispatch (keyed)"                   "ANS1"      "$(_h_reply_for claude "$RTN" "Q1")"

CXE="$FIX/codex-reply-after-extra.jsonl"
eq "codex reply for our prompt, not a later notify turn"     "PONG"               "$(_cx_reply_for_prompt "$CXE" "ping")"
eq "codex last_reply mis-attributes to the later turn"       "CHILD-NOTIFY-REPLY" "$(_cx_last_reply "$CXE")"
eq "codex reply_for skips trailing null turns"               "codex reply text"   "$(_cx_reply_for_prompt "$FIX/codex-turn.jsonl" "codex prompt here")"
eq "h_reply_for codex dispatch (keyed)"                      "PONG"               "$(_h_reply_for codex "$CXE" "ping")"

Q2="$FIX/claude-two-queued.jsonl"
eq "reply_for older prompt confirmed though a newer is last" "REPLY-A" "$(_reply_for_prompt "$Q2" "ASK-A")"
eq "reply_for the pending newer prompt is empty"             ""        "$(_reply_for_prompt "$Q2" "ASK-B")"
eq "answered: older prompt is answered"                      "yes"     "$(_answered "$Q2" "ASK-A" && echo yes || echo no)"
eq "answered: newer prompt still running is not"             "no"      "$(_answered "$Q2" "ASK-B" && echo yes || echo no)"
eq "answered: a prompt never sent is not"                    "no"      "$(_answered "$Q2" "ASK-C" && echo yes || echo no)"
eq "answered codex dispatch (our prompt)"                    "yes"     "$(_h_answered codex "$CXE" "ping" && echo yes || echo no)"
eq "answered codex: a prompt never sent is not"              "no"      "$(_h_answered codex "$CXE" "never" && echo yes || echo no)"

X="$FIX/codex-turn.jsonl"
eq "codex turn_count"      "1"                         "$(_cx_turn_count "$X")"
eq "codex turns_after(0)"  "1"                         "$(_turns_after codex "$X" 0)"
eq "codex not busy"        ""                          "$(_cx_is_busy "$X" && echo busy)"
eq "codex last_reply"      "codex reply text"          "$(_cx_last_reply "$X")"
eq "codex last_prompt"     "codex prompt here"         "$(_cx_last_prompt "$X")"

eq "codex busy"            "busy"                      "$(_cx_is_busy "$FIX/codex-busy.jsonl" && echo busy)"

eq "turn_advanced count: base below current" "adv" "$(_turn_advanced claude "$C" 0 "" && echo adv)"
eq "turn_advanced count: base at current"    ""    "$(_turn_advanced claude "$C" 2 "" && echo adv)"
eq "turn_advanced bytes: offset 0"           "adv" "$(_turn_advanced claude "$C" 0 0 && echo adv)"
eq "turn_advanced bytes: offset at EOF"      ""    "$(_turn_advanced claude "$C" 0 "$(_fsize "$C")" && echo adv)"
eq "turn_advanced codex count mode"          "adv" "$(_turn_advanced codex "$X" 0 "" && echo adv)"
eq "turn_advanced codex bytes at EOF"        ""    "$(_turn_advanced codex "$X" 0 "$(_fsize "$X")" && echo adv)"
eq "codex aborted!=busy"   ""                          "$(_cx_is_busy "$FIX/codex-aborted.jsonl" && echo busy)"

eq "awaiting claude"       "0"                         "$(_awaiting_text "$(cat "$FIX/awaiting-claude.txt")" >/dev/null 2>&1; echo $?)"
eq "awaiting codex"        "0"                         "$(_awaiting_text "$(cat "$FIX/awaiting-codex.txt")" >/dev/null 2>&1; echo $?)"
eq "awaiting none"         "1"                         "$(_awaiting_text "$(cat "$FIX/awaiting-none.txt")" >/dev/null 2>&1; echo $?)"
eq "compacting claude"     "0"  "$(_compacting_text "$(cat "$FIX/compacting-claude.txt")" >/dev/null 2>&1; echo $?)"
eq "compacting rejects prose mentions" "1"  "$(_compacting_text "$(cat "$FIX/compacting-none.txt")" >/dev/null 2>&1; echo $?)"
eq "queued detected"       "0"  "$(_queued_text "$(cat "$FIX/compacting-claude.txt")" >/dev/null 2>&1; echo $?)"
eq "queued absent"         "1"  "$(_queued_text "$(cat "$FIX/compacting-none.txt")" >/dev/null 2>&1; echo $?)"
eq "awaiting win console"  "0"                         "$(_awaiting_text "$(cat "$FIX/awaiting-windows-console.txt")" '❯›>' >/dev/null 2>&1; echo $?)"
eq "linux ignores ascii >"        "1"                  "$(_awaiting_text "$(cat "$FIX/awaiting-windows-console.txt")" >/dev/null 2>&1; echo $?)"
eq "markdown quote not awaiting"  "1"                  "$(_awaiting_text "$(cat "$FIX/awaiting-none-markdown-quote.txt")" >/dev/null 2>&1; echo $?)"
eq "markdown quote not awaiting on windows" "1"        "$(_awaiting_text "$(cat "$FIX/awaiting-none-markdown-quote.txt")" '❯›>' >/dev/null 2>&1; echo $?)"
eq "plain numbered list not awaiting" "1"              "$(_awaiting_text "$(cat "$FIX/awaiting-none-numbered-list.txt")" >/dev/null 2>&1; echo $?)"
eq "plain numbered list not awaiting on windows" "1"   "$(_awaiting_text "$(cat "$FIX/awaiting-none-numbered-list.txt")" '❯›>' >/dev/null 2>&1; echo $?)"
eq "all options marked is not a menu" "1"              "$(_awaiting_text "$(printf '> 1. yes\n> 2. no\n')" '❯›>' >/dev/null 2>&1; echo $?)"

_aw() { _awaiting_text "$1" "${2:-❯›}" >/dev/null 2>&1 && echo awaiting || echo no; }
eq "a numbered reply line + a numbered composer is not a menu" "no" \
   "$(_aw "$(printf 'here are the steps\n2. do the thing\n❯ 1. do X first\n')")"
eq "options must be consecutively numbered"   "no"       "$(_aw "$(printf '2. b\n❯ 1. a\n')")"
eq "a real menu under a numbered reply is found" "awaiting" \
   "$(_aw "$(printf '1. alpha\n2. beta\nProceed?\n❯ 1. Yes\n  2. No\n')")"
eq "a menu not starting at 1 still counts"    "awaiting" "$(_aw "$(printf 'Proceed?\n❯ 4. Yes\n  5. No\n')")"
eq "a lone marked option is not a menu"       "no"       "$(_aw "$(printf 'Proceed?\n❯ 1. Yes\n')")"

_ia() { _is_active_text "$1" "$2" && echo active || echo no; }
eq "menu: numbered highlighted item is active"      "active" \
   "$(_ia "$(printf '   \033[38;5;153m❯\033[39m \033[38;5;246m4. \033[38;5;153mSonnet\033[39m   Sonnet 5\n')" Sonnet)"
eq "menu: a different highlighted item is not active" "no" \
   "$(_ia "$(printf '   \033[38;5;153m❯\033[39m \033[38;5;246m5. \033[38;5;153mHaiku\033[39m\n')" Sonnet)"
eq "menu: a line without the cursor is not active"  "no" \
   "$(_ia "$(printf '     \033[38;5;246m4. Sonnet\033[39m\n')" Sonnet)"
eq "menu: cursor does not jump past another name"   "no" \
   "$(_ia "$(printf '\033[7m❯ Sonnet\033[27m  Haiku  Opus\n')" Haiku)"
eq "menu: reverse-video highlighted tab is active"  "active" \
   "$(_ia "$(printf 'Tab1  \033[7m Sonnet \033[27m  Haiku\n')" Sonnet)"
eq "menu: reverse-video tab, other tab not active"  "no" \
   "$(_ia "$(printf 'Tab1  \033[7m Sonnet \033[27m  Haiku\n')" Haiku)"

_wia() { _win_is_active_text "$1" "$2" && echo active || echo no; }
eq "win menu: cursor '>' row with the item is active"   "active" "$(_wia "$(printf '  4. Opus\n> 5. Sonnet\n')" Sonnet)"
eq "win menu: glyph cursor row is active"               "active" "$(_wia "$(printf '❯ 2. Codex\n')" Codex)"
eq "win menu: a row without a cursor is not active"     "no"     "$(_wia "$(printf '  5. Haiku\n')" Haiku)"
eq "win menu: the item on another row is not active"    "no"     "$(_wia "$(printf '> 4. Sonnet\n  5. Haiku\n')" Haiku)"
eq "win menu: cursor does not jump past another name"   "no"     "$(_wia "$(printf '> Sonnet  Haiku\n')" Haiku)"

eq "posix shell accepts bash"   "yes" "$(_is_posix_shell bash && echo yes || echo no)"
eq "posix shell accepts -zsh"   "yes" "$(_is_posix_shell -zsh && echo yes || echo no)"
eq "posix shell refuses fish"   "no"  "$(_is_posix_shell fish && echo yes || echo no)"
eq "posix shell refuses nu"     "no"  "$(_is_posix_shell nu && echo yes || echo no)"
eq "_is_shell still accepts fish" "yes" "$(_is_shell fish && echo yes || echo no)"

_shpane() {
  ( _need() { :; }
    _resolve_pane() { printf '%%9'; }
    _lock_pane() { printf 'LOCKED-BEFORE-GATE'; }
    _shell_under_test="$1"
    tmux() { case "$*" in *pane_current_command*) printf '%s' "$_shell_under_test" ;; *) return 0 ;; esac; }
    cmd_sh %9 'ls' 1 ) 2>&1
}
eq "sh refuses a fish pane before locking"  "yes" "$(case "$(_shpane fish)"  in *"cannot drive"*) echo yes ;; *) echo no ;; esac)"
eq "sh refuses a nu pane"                   "yes" "$(case "$(_shpane nu)"    in *"cannot drive"*) echo yes ;; *) echo no ;; esac)"
eq "sh names the shells it can drive"       "yes" "$(case "$(_shpane tcsh)"  in *"sh, bash, zsh, dash, ksh, mksh, ash"*) echo yes ;; *) echo no ;; esac)"
eq "sh does not refuse a bash pane"         "yes" "$(case "$(_shpane bash)"  in *"cannot drive"*) echo no ;; *) echo yes ;; esac)"

eq "ok session name 'work'"      "yes" "$(_ok_session_name work  && echo yes || echo no)"
eq "ok session name 'a_b-2'"     "yes" "$(_ok_session_name a_b-2 && echo yes || echo no)"
eq "reject empty session name"   "no"  "$(_ok_session_name ''    && echo yes || echo no)"
eq "reject dotted session name"  "no"  "$(_ok_session_name a.b   && echo yes || echo no)"
eq "reject coloned session name" "no"  "$(_ok_session_name a:b   && echo yes || echo no)"
eq "reject spaced session name"  "no"  "$(_ok_session_name 'a b' && echo yes || echo no)"
eq "reject slashed session name" "no"  "$(_ok_session_name a/b   && echo yes || echo no)"
eq "reject punct session name"   "no"  "$(_ok_session_name 'a!b' && echo yes || echo no)"

eq "hosts: parse strips comments + blanks, first token wins" "user@host-a
admin@host-b" "$(printf '# fleet\n\nuser@host-a  # linux box\n  admin@host-b win\n' | _hosts_parse)"
eq "ssh-config: non-wildcard Host tokens only" "sandbox
web1
web2" "$(printf 'Host *\n  User x\nHost sandbox\n  HostName 1.2.3.4\nHost web1 web2 !bad *.eg\n  User y\n' | _ssh_config_hosts)"
eq "ts-state: active peer"   "active"  "$(printf '100.0.0.1 sandbox u linux active; direct\n' | _ts_state sandbox)"
eq "ts-state: offline peer"  "offline" "$(printf '100.0.0.2 winbox u windows offline, last seen 3d ago\n' | _ts_state 100.0.0.2)"
eq "ts-state: idle peer"     "idle"    "$(printf '100.0.0.3 idlebox u linux idle, tx 1 rx 2\n' | _ts_state idlebox)"
eq "ts-state: known but no session" "-" "$(printf '100.0.0.4 seenbox u linux -\n' | _ts_state seenbox)"
eq "ts-state: unknown host"  "?"       "$(printf '100.0.0.1 sandbox u linux active\n' | _ts_state ghost)"
eq "ts-hosts: ips, all os" "100.0.0.1
100.0.0.2" "$(printf '# Health:\n100.0.0.1 sandbox u linux active\n100.0.0.2 winbox tag windows -\n' | _ts_hosts '')"
eq "ts-hosts: filter by os" "100.0.0.2" "$(printf '100.0.0.1 sandbox u linux active\n100.0.0.2 winbox tag windows -\n' | _ts_hosts windows)"
eq "ts-hosts: ignores non-peer lines" "100.0.0.1" "$(printf 'Health check:\n  - some warning\n100.0.0.1 sandbox u linux active\n' | _ts_hosts '')"
_inv() { ( export OVERSEER_HOSTS="$FIX/hosts"; _inventory "$1" '' "$2" ''
  printf 'SRC=%s\n' "$_INV_SRC"; printf '%s\n' "${_INV_TARGETS[@]}" ) ; }
eq "inventory: OVERSEER_HOSTS resolves + applies defuser to bare hosts" "SRC=$FIX/hosts
user@host-a
fleetuser@host-b" "$(_inv 0 fleetuser)"
eq "inventory: no defuser leaves bare hosts bare" "SRC=$FIX/hosts
user@host-a
host-b" "$(_inv 0 '')"
eq "inventory: --tailscale with empty status dies" "yes" \
  "$( ( _inventory 1 '' '' '' ) 2>&1 | grep -q 'tailscale needs' && echo yes || echo no)"

_gate() { ( _need() { :; }
  _fleet_survey() { printf 'local\t%%1\tclaude\tidle\nlocal\t%%2\tclaude\tbusy\nh\t%%0\tcodex\tidle(0-turn)\nh\t%%3\tclaude\tawaiting\n'; }
  _fleet_gate "msg" "$1" . h ) 2>&1; }
eq "fleet gate: idle (incl 0-turn) are the recipients" "yes" "$(case "$(_gate 1)" in *'will send to 2 idle'*) echo yes ;; *) echo no ;; esac)"
eq "fleet gate: busy + awaiting are skipped"           "yes" "$(case "$(_gate 1)" in *'skipping 2 pane(s)'*)  echo yes ;; *) echo no ;; esac)"
eq "fleet gate: --dry-run sends nothing"               "yes" "$(case "$(_gate 1)" in *'dry-run: nothing sent'*) echo yes ;; *) echo no ;; esac)"
eq "fleet gate: --dry-run stops the broadcast"         "1"   "$(_gate 1 >/dev/null 2>&1; echo $?)"
_gatenone() { ( _need() { :; }
  _fleet_survey() { printf 'local\t%%2\tclaude\tbusy\n'; }
  _fleet_gate "msg" 0 . h ) 2>&1; }
eq "fleet gate: no idle agent stops before any prompt" "yes" "$(case "$(_gatenone)" in *'no idle agent anywhere'*) echo yes ;; *) echo no ;; esac)"
eq "fleet gate: no idle agent returns stop"            "1"   "$(_gatenone >/dev/null 2>&1; echo $?)"

WAF="${TMPDIR:-/tmp}/ov-waitany-$$"
_waitany() { ( _need() { :; }
  _fleet_status() { case "$1" in
    %busy) if [ -f "$WAF" ]; then printf '%%busy\tclaude\tidle\n'; else : >"$WAF"; printf '%%busy\tclaude\tbusy\n'; fi ;;
    *) printf '%s\tclaude\tidle\n' "$1" ;;
  esac; }
  _fleet_wait_any 5 "$@" ) 2>/dev/null; }
rm -f "$WAF"
eq "fleet wait --any: first pane to leave in-flight wins"  "yes" "$(case "$(_waitany %busy %idle)" in *%busy*idle*) echo yes ;; *) echo no ;; esac)"
rm -f "$WAF"
eq "fleet wait --any: nothing in flight returns at once"   "yes" "$(case "$(_waitany %i1 %i2)" in *'nothing in flight'*) echo yes ;; *) echo no ;; esac)"
rm -f "$WAF"
eq "fleet: no-agent-panes uses a distinct sentinel (3, not the wait-timeout code)" "3" \
   "$( ( _panes() { :; }; _need() { :; }; _fleet_local status ) >/dev/null 2>&1; echo $? )"

_stubs() { _awaiting() { return 1; }
           _is_shell() { return 1; }
           _turn_advanced() { return 1; }
           _h_answered() { return 1; }
           _h_running() { return "$RUN"; }
           _file_sig() { printf 'sig%s' "$SECONDS-$RANDOM"; }
           _nap() { sleep 0.005; }
           tmux() { printf 'node'; }
           _screen_state() { case "$SCREEN" in
             busy)     printf 'busy' ;;
             still)    printf 'aaa' ;;
             changing) printf 'c%s' "$((RANDOM))" ;;
           esac; }; }
_drain() { ( export SCREEN="$1" RUN="$2"; _stubs
             _wait_drained "${3:-claude}" /nope 2 %9 ); printf '%s' "$?"; }
eq "wait: a running transcript on a frozen screen drains (interrupted, not stuck)" "0" "$(_drain still 0)"
eq "wait: a running transcript with a live spinner keeps waiting to timeout"       "1" "$(_drain busy 0)"
eq "wait: a running transcript streaming its reply keeps waiting to timeout"       "1" "$(_drain changing 0)"
eq "wait: a finished transcript drains regardless of the screen"                   "0" "$(_drain busy 1)"
eq "wait: codex is exempt from the screen veto and waits out its turn"             "1" "$(_drain still 0 codex)"

_wreply() { ( export SCREEN="$1" RUN="$2"; _stubs
              case "${4:-reply}" in
                reply)  _wait_reply "${3:-claude}" /nope 0 2 "" 0 %9 "" ;;
                queued) _wait_queued_reply "${3:-claude}" /nope 2 %9 'msg' ;;
              esac ); printf '%s' "$?"; }
eq "chat: an interrupted turn reports the no-reply code instead of hanging" "4" "$(_wreply still 0)"
eq "chat: a turn with a live spinner still waits out the timeout"           "1" "$(_wreply busy 0)"
eq "chat: a turn streaming its reply still waits out the timeout"           "1" "$(_wreply changing 0)"
eq "chat: a codex turn never uses the screen veto"                          "1" "$(_wreply still 0 codex)"
eq "chat: a queued message behind an interrupted turn reports it too"       "4" "$(_wreply still 0 claude queued)"
eq "chat: a queued message behind a live turn keeps waiting"                "1" "$(_wreply busy 0 claude queued)"
eq "chat: a queued message behind a streaming turn keeps waiting"           "1" "$(_wreply changing 0 claude queued)"

_sstate() { ( export CAP="$1" CY="${2:-9}"
              tmux() { case "$*" in *capture-pane*) printf '%s\n' "$CAP" ;; *cursor_y*) printf '%s' "$CY" ;; esac; }
              _screen_state %9 ); }
eq "screen state: a live spinner reads busy" "busy" "$(_sstate '✽ Booping… (1m 5s · thinking)')"
eq "screen state: a queued message reads busy" "busy" "$(_sstate 'Press up to edit queued messages')"
eq "screen state: a ticking statusline below the box does not count as movement" "same" \
   "$(a=$(_sstate "$(printf 'b1\nb2\n────\n❯ \n────\nram 0.4gb')" 3); b=$(_sstate "$(printf 'b1\nb2\n────\n❯ \n────\nram 0.9gb')" 3); [ "$a" = "$b" ] && echo same || echo differ)"
eq "screen state: a reply streaming into the body does count as movement" "differ" \
   "$(a=$(_sstate "$(printf 'b1\nb2\n────\n❯ \n────\nram 0.4gb')" 3); b=$(_sstate "$(printf 'b1\nb2 and more\n────\n❯ \n────\nram 0.4gb')" 3); [ "$a" = "$b" ] && echo same || echo differ)"

eq "thinking: a live spinner line is in-flight"        "0" "$(_thinking_text "$(cat "$FIX/thinking-claude.txt")" >/dev/null 2>&1; echo $?)"
eq "thinking: a completed turn shows none"             "1" "$(_thinking_text "$(cat "$FIX/thinking-none-done.txt")" >/dev/null 2>&1; echo $?)"
eq "thinking: an interrupted turn shows none"          "1" "$(_thinking_text "$(cat "$FIX/thinking-none-interrupted.txt")" >/dev/null 2>&1; echo $?)"
eq "thinking: the stale 'Brewed for' summary is not in-flight" "1" \
   "$(_thinking_text "$(printf 'Brewed for 12s · 3 shells still running\n')" >/dev/null 2>&1; echo $?)"
eq "thinking: a wrapped prose line is not in-flight"   "1" \
   "$(_thinking_text "$(printf '  the pipeline then hands the buffer to the next stage, and the reader keeps going until it sees…\n')" >/dev/null 2>&1; echo $?)"
eq "thinking: a bare gerund spinner counts"            "0" "$(_thinking_text "$(printf '✽ Recombobulating…\n')" >/dev/null 2>&1; echo $?)"
eq "thinking: a tool-run spinner counts"               "0" "$(_thinking_text "$(printf 'Running 1 shell command · 5s…\n')" >/dev/null 2>&1; echo $?)"
eq "thinking: a turn past 1 minute still counts"       "0" \
   "$(_thinking_text "$(printf '✽ Booping… (1m 5s · almost done thinking)\n')" >/dev/null 2>&1; echo $?)"
eq "thinking: a turn past 1 hour still counts"         "0" \
   "$(_thinking_text "$(printf '✻ Churning… (1h 2m 13s · ↓ 4.1k tokens)\n')" >/dev/null 2>&1; echo $?)"

_scr() { _nap() { :; }
         _screen_state() { case "${SCREEN:-busy}" in
           busy) printf 'busy' ;; still) printf 'aaa' ;; changing) printf 'c%s' "$RANDOM" ;;
         esac; }; }
_fstat() { ( _target_ctx() { printf '%%9\tclaude\t%s' "$1"; }
             _awaiting() { return 1; }
             _compacting() { return 1; }
             _scr
             _fleet_status "$1" ) | cut -f3; }
_fstatx() { ( _target_ctx() { printf '%%9\tcodex\t%s' "$1"; }
              _awaiting() { return 1; }
              _compacting() { return 1; }
              _scr
              _fleet_status "$1" ) | cut -f3; }
eq "fleet status: a text-only turn with a live spinner reads busy, not idle" "busy" "$(SCREEN=busy _fstat "$RT")"
eq "fleet status: a text-only turn streaming its reply reads busy, not idle" "busy" "$(SCREEN=changing _fstat "$RT")"
eq "fleet status: an interrupted text-only turn reads idle, not stuck busy"  "idle" "$(SCREEN=still _fstat "$RT")"
eq "fleet status: a mid-tool turn reads busy without needing the screen"     "busy" "$(SCREEN=still _fstat "$CB")"
eq "fleet status: a finished turn reads idle"                               "idle" "$(SCREEN=busy _fstat "$C")"
eq "fleet status: codex busy is unchanged"                                  "busy" "$(_fstatx "$FIX/codex-busy.jsonl")"
eq "fleet status: codex finished is idle"                                   "idle" "$(_fstatx "$X")"
eq "fleet status: codex aborted is idle, not stuck busy"                    "idle" "$(_fstatx "$FIX/codex-aborted.jsonl")"

NS=$(_notify_script)
eq "notify: the watcher waits on the worker"          "yes" "$(case "$NS" in *'wait "$OVS_TARGET" "$left"'*) echo yes ;; *) echo no ;; esac)"
eq "notify: the watcher waits inside the given budget" "yes" "$(case "$NS" in *'$(date +%s) + OVS_TIMEOUT'*) echo yes ;; *) echo no ;; esac)"
eq "notify: a confirmed turn skips the startup grace"  "yes" "$(case "$NS" in *'"$OVS_STARTED" = 1'*) echo yes ;; *) echo no ;; esac)"
eq "notify: an unconfirmed turn does not trust a stale idle" "yes" "$(case "$NS" in *'-ge "$grace"'*) echo yes ;; *) echo no ;; esac)"
eq "notify: the watcher wakes the dispatcher's pane"  "yes" "$(case "$NS" in *'send --yes "$OVS_BACK"'*) echo yes ;; *) echo no ;; esac)"
eq "notify: the wake-up quotes what wait reported"    "yes" "$(case "$NS" in *'overseer wait $OVS_TARGET reported'*) echo yes ;; *) echo no ;; esac)"
eq "notify: the wake-up orders a whole-fleet survey"  "yes" "$(case "$NS" in *'overseer fleet status'*) echo yes ;; *) echo no ;; esac)"
eq "notify: the quoted output is capped"              "yes" "$(case "$NS" in *'head -c 1200'*) echo yes ;; *) echo no ;; esac)"
eq "notify: the watcher re-waits while the worker has no transcript" "yes" "$(case "$NS" in *"no transcript yet"*) echo yes ;; *) echo no ;; esac)"

_ntfy() { ( export DEFAULT_TIMEOUT=600
            _need() { :; }
            _uint() { :; }
            _target_ctx() { printf '%%9\tclaude\t/x.jsonl'; }
            if [ -n "$1" ]; then TMUX_PANE="$1"; export TMUX_PANE; else unset TMUX_PANE; fi
            cmd_send --notify "$2" hi ) 2>&1; }
eq "notify: refuses when overseer is not in a tmux pane" "yes" \
   "$(case "$(_ntfy '' %9)" in *'nowhere to report back'*) echo yes ;; *) echo no ;; esac)"
eq "notify: refuses to wake the pane it dispatches to"   "yes" \
   "$(case "$(_ntfy %9 %9)" in *'would wake the pane it is dispatching to'*) echo yes ;; *) echo no ;; esac)"
eq "notify: send takes a timeout only with --notify"     "yes" \
   "$(case "$( ( _need() { :; }; cmd_send %9 hi 30 ) 2>&1 )" in *'only with --notify'*) echo yes ;; *) echo no ;; esac)"
eq "notify: fleet chat rejects --notify"                 "yes" \
   "$(case "$( ( _need() { :; }; _panes() { printf 'a\t%%1\t1\tclaude\t/x\n'; }; _fleet_local chat --notify hi ) 2>&1 )" in *'belongs to fleet send'*) echo yes ;; *) echo no ;; esac)"
eq "notify: a cross-host fleet send rejects --notify"    "yes" \
   "$(case "$( ( _need() { :; }; cmd_fleet --hosts send --notify hi ) 2>&1 )" in *'exists only on this machine'*) echo yes ;; *) echo no ;; esac)"

eq "provision: --dry-run threads DRY=1" "yes" "$(_provision_script 1 | grep -qx 'DRY=1' && echo yes || echo no)"
eq "provision: defaults to DRY=0"       "yes" "$(_provision_script | grep -qx 'DRY=0' && echo yes || echo no)"
eq "provision: targets tmux and jq"     "yes" "$(_provision_script 0 | grep -q 'for c in tmux jq' && echo yes || echo no)"
eq "provision: knows apt and dnf"       "2"   "$(_provision_script 0 | grep -cE 'apt-get install -y|dnf install -y')"
eq "provision: sudo -n when not root"   "yes" "$(_provision_script 0 | grep -q 'sudo -n' && echo yes || echo no)"
eq "provision: refuses non-Linux"       "yes" "$(_provision_script 0 | grep -q 'not Linux' && echo yes || echo no)"

_ensure() { ( _need() { :; }
  ssh() { return "$OVR_SSHRC"; }
  cmd_deploy() { printf 'DEPLOYED %s\n' "$1"; return "$OVR_DEPRC"; }
  OVR_SSHRC="$1"; OVR_DEPRC="${2:-0}"
  _on_ensure_deployed host "\$HOME/.overseer/scripts/overseer" /tmp/x ) 2>&1; }
eq "on: bin present skips auto-deploy"    "yes" "$(case "$(_ensure 0)" in *DEPLOYED*) echo no ;; *) echo yes ;; esac)"
eq "on: bin missing auto-deploys"         "yes" "$(case "$(_ensure 1)" in *'DEPLOYED host'*) echo yes ;; *) echo no ;; esac)"
eq "on: auto-deploy announces itself"     "yes" "$(case "$(_ensure 1)" in *'deploying it once'*) echo yes ;; *) echo no ;; esac)"
eq "on: a failed auto-deploy is fatal"    "yes" "$(case "$(_ensure 1 1)" in *'auto-deploy to host failed'*) echo yes ;; *) echo no ;; esac)"

_startgate() {
  ( _need() { :; }; _nap() { :; }
    _harness_of() { printf claude; }
    _hs="${4:-1}"
    tmux() { case "$1" in
        has-session)     return "$_hs" ;;
        new-session)     printf 'NEWSESSION\n'; return 0 ;;
        list-panes)      printf '%%9\n' ;;
        display-message) printf '1234\n' ;;
        *)               return 0 ;;
      esac }
    cmd_start "$1" "$2" "$3" ) 2>&1
}
_made() { case "$1" in *NEWSESSION*) echo yes ;; *) echo no ;; esac; }
eq "start refuses a dotted name"                "yes" "$(case "$(_startgate 'a.b' shell '')" in *'invalid session name'*) echo yes ;; *) echo no ;; esac)"
eq "start does not create for a bad name"       "no"  "$(_made "$(_startgate 'a.b' shell '')")"
eq "start refuses an unknown child"             "yes" "$(case "$(_startgate ok weird '')" in *'child must be'*) echo yes ;; *) echo no ;; esac)"
eq "start does not create for a bad child"      "no"  "$(_made "$(_startgate ok weird '')")"
eq "start refuses an existing session"          "yes" "$(case "$(_startgate ok shell '' 0)" in *'already exists'*) echo yes ;; *) echo no ;; esac)"
eq "start does not recreate an existing name"   "no"  "$(_made "$(_startgate ok shell '' 0)")"
eq "start creates a valid shell session"        "yes" "$(_made "$(_startgate ok shell '')")"
eq "start reports the shell session it made"    "yes" "$(case "$(_startgate ok shell '')" in *'started shell session ok'*) echo yes ;; *) echo no ;; esac)"
eq "start waits for the agent then reports it"  "yes" "$(case "$(_startgate c1 claude '')" in *'started claude session c1'*) echo yes ;; *) echo no ;; esac)"

_stopgate() {
  ( _need() { :; }
    _resolve_pane() { printf '%%9'; }
    TMUX_PANE="$2"; export TMUX_PANE; _ms="$3"
    tmux() { case "$1" in
        has-session)             return 0 ;;
        display-message)         printf '%s' "$_ms" ;;
        kill-pane|kill-session)  printf 'KILLED\n'; return 0 ;;
        *)                       return 0 ;;
      esac }
    cmd_stop "$1" ) 2>&1
}
_killed() { case "$1" in *KILLED*) echo yes ;; *) echo no ;; esac; }
eq "stop refuses to kill its own session" "yes" "$(case "$(_stopgate work %9 work)" in *'refusing to kill the session'*) echo yes ;; *) echo no ;; esac)"
eq "stop does not kill its own session"   "no"  "$(_killed "$(_stopgate work %9 work)")"
eq "stop kills another named session"     "yes" "$(_killed "$(_stopgate work %9 other)")"
eq "stop refuses to kill its own pane"    "yes" "$(case "$(_stopgate %9 %9 x)" in *'refusing to kill the pane'*) echo yes ;; *) echo no ;; esac)"
eq "stop does not kill its own pane"      "no"  "$(_killed "$(_stopgate %9 %9 x)")"
eq "stop kills another pane"              "yes" "$(_killed "$(_stopgate %9 %1 x)")"
eq "stop unguarded when not inside tmux"  "yes" "$(_killed "$(_stopgate work '' x)")"

_cxpid() { ( _want="$1"
             _p_comm() { [ "$1" = "$_want" ] && printf codex || printf node; }
             _p_children() { [ "$1" = 100 ] && printf '200\n'; }
             _codex_pid 100 ) }
eq "codex found when a descendant is codex" "200" "$(_cxpid 200)"
eq "codex found when the pane pid IS codex" "100" "$(_cxpid 100)"

_probe() { ( _rc="$1"
             _probe_contract() { printf 'x.jsonl'; return "$_rc"; }
             _h_turn_count() { printf 3; }
             _doctor_probe claude >/dev/null; echo "rc=$?" ) }
eq "doctor probe ok"                 "rc=0" "$(_probe 0)"
eq "doctor probe schema shift FAILS" "rc=1" "$(_probe 1)"
eq "doctor probe no-session is ok"   "rc=0" "$(_probe 2)"
eq "doctor probe schema shift is not a warn" "yes" \
   "$( ( _probe_contract() { printf 'x.jsonl'; return 1; }; case "$(_doctor_probe claude)" in *'[FAIL]'*) echo yes ;; *) echo no ;; esac ) )"

_delivered() { ( _paste_verified() { printf '%s' "$2"; }; _deliver pane "$1" "$2" ) }
eq "claude leading slash is space-guarded"  " /clear"  "$(_delivered claude '/clear')"
eq "claude leading bang is space-guarded"   " !ls"     "$(_delivered claude '!ls')"
eq "claude leading hash is space-guarded"   " #note"   "$(_delivered claude '#note')"
eq "claude leading at is space-guarded"     " @file"   "$(_delivered claude '@file')"
eq "claude plain text is untouched"         "hello"    "$(_delivered claude 'hello')"
eq "codex plain text is untouched"          "/clear"   "$(_delivered codex '/clear')"
eq "codex refuses a leading bang"           "refused"  "$( (_delivered codex '!rm -rf /') >/dev/null 2>&1 || echo refused)"
eq "codex refuses an indented bang"         "refused"  "$( (_delivered codex '   !rm -rf /') >/dev/null 2>&1 || echo refused)"

_undeliv() { ( _awaiting() { [ "$1" = menu ] && { printf 'proceed?\n❯ 1. yes\n  2. no'; return 0; }; return 1; }
              _win_awaiting() { _awaiting menu; }
              "$@" ) }
eq "undelivered names the question when a menu is up" "yes" \
   "$(case "$(_undeliv _undelivered menu %9)" in *'not sent'*'❯ 1. yes'*) echo yes ;; *) echo no ;; esac)"
eq "undelivered suggests answering it first"          "yes" \
   "$(case "$(_undeliv _undelivered menu %9)" in *'overseer keys %9 <n>'*) echo yes ;; *) echo no ;; esac)"
eq "undelivered keeps the plain error with no menu"   "could not place/verify message in input box" \
   "$(_undeliv _undelivered plain %9)"
eq "win undelivered names the question when a menu is up" "yes" \
   "$(case "$(_undeliv _win_undelivered win/two)" in *'not sent'*'win/two'*'❯ 1. yes'*) echo yes ;; *) echo no ;; esac)"
eq "win undelivered keeps the plain error with no menu"   "yes" \
   "$(_win_awaiting() { return 1; }; case "$(_win_undelivered win/two)" in *'could not place/verify the prompt'*'win win/two peek'*) echo yes ;; *) echo no ;; esac)"

eq "is_shell bash"         "0"                         "$(_is_shell bash; echo $?)"
eq "is_shell login -zsh"   "0"                         "$(_is_shell -zsh; echo $?)"
eq "is_shell fish"         "0"                         "$(_is_shell fish; echo $?)"
eq "is_shell nu"           "0"                         "$(_is_shell nu; echo $?)"
eq "is_shell reject node"  "1"                         "$(_is_shell node; echo $?)"
eq "is_shell reject claude" "1"                        "$(_is_shell claude; echo $?)"

_split() { ( _win_split "$1" >/dev/null 2>&1 && printf '%s %s' "$_WH" "$_WP" ) || printf 'rejected'; }
eq "win_split bare host"    "win1 overseer-broker"           "$(_split win1)"
eq "win_split user@ip"      "admin@10.0.0.9 overseer-broker" "$(_split admin@10.0.0.9)"
eq "win_split named broker" "win1 overseer-broker-v10"       "$(_split win1/v10)"
eq "win_split name w/ -_"   "win1 overseer-broker-a_b-2"     "$(_split win1/a_b-2)"
eq "win_split reject punct" "rejected"                       "$(_split 'win1/oops!')"
eq "win_split reject empty" "rejected"                       "$(_split 'win1/')"

_tx() { _win_txok "$1" && echo ok || echo reject; }
eq "txok normal claude path"  "ok"     "$(_tx 'C:/Users/user/.claude/projects/D--Workspace/a-1.jsonl')"
eq "txok normal codex path"   "ok"     "$(_tx 'C:/Users/user/.codex/sessions/2026/07/21/rollout-x.jsonl')"
eq "txok username with space" "ok"     "$(_tx 'C:/Users/John Doe/.claude/projects/x/y.jsonl')"
eq "txok rejects ampersand"   "reject" "$(_tx 'C:/Users/x/rollout-a & calc.jsonl')"
eq "txok rejects command sub" "reject" "$(_tx 'C:/Users/x/$(calc).jsonl')"
eq "txok rejects semicolon"   "reject" "$(_tx 'C:/Users/x/a;b.jsonl')"
eq "txok rejects backtick"    "reject" "$(_tx 'C:/Users/x/a`b`.jsonl')"
eq "txok rejects non-jsonl"   "reject" "$(_tx 'C:/Users/x/a.txt')"
eq "txok rejects unix path"   "reject" "$(_tx '/etc/passwd')"
eq "txok rejects empty"       "reject" "$(_tx '')"
eq "txok rejects backslash"   "reject" "$(_tx 'C:/Users/x/..\\evil.jsonl')"
eq "win_split reject nohost" "rejected"                      "$(_split '/v10')"

STAT='kind=claude alive=True size=48213 mtime=1753070000 transcript=C:/Users/u/.claude/projects/D--Workspace/abc-123.jsonl'
eq "win_field kind"        "claude"                          "$(_win_field "$STAT" kind)"
eq "win_field alive"       "True"                            "$(_win_field "$STAT" alive)"
eq "win_field size"        "48213"                           "$(_win_field "$STAT" size)"
eq "win_field mtime"       "1753070000"                      "$(_win_field "$STAT" mtime)"
eq "win_field transcript"  "C:/Users/u/.claude/projects/D--Workspace/abc-123.jsonl" "$(_win_field "$STAT" transcript)"
eq "win_sig gates on both" "1753070000:48213"                "$(_win_sig "$STAT")"
INFO='kind=shell workdir=D:\Workspace childPid=15272 alive=False transcript='
eq "win_field absent tx"   ""                                "$(_win_field "$INFO" transcript)"
eq "win_field alive False" "False"                           "$(_win_field "$INFO" alive)"
eq "win_sig no transcript" ":"                               "$(_win_sig "$INFO")"

ENTRY="$HERE/../overseer/skills/overseer/scripts/overseer"
README="$HERE/../README.md"
SKILL="$HERE/../overseer/skills/overseer/SKILL.md"

_dispatch_cmds() { sed -nE 's/^[[:space:]]+([a-z]+)\)[[:space:]]+cmd_.*/\1/p' "$ENTRY" | sort -u; }
_help_cmds()     { bash "$ENTRY" --help 2>/dev/null | sed -nE 's/^  ([a-z]+)[[:space:]]+[<[].*/\1/p' | sort -u; }
_table_cmds()    { sed -nE 's/^\| `([a-z]+)[ `].*/\1/p' "$1" | sort -u; }

DISPATCH=$(_dispatch_cmds)
eq "dispatch surface is non-empty" "yes" "$([ -n "$DISPATCH" ] && echo yes || echo no)"

for surface in help README SKILL; do
  case "$surface" in
    help)   documented=$(_help_cmds) ;;
    README) documented=$(_table_cmds "$README") ;;
    SKILL)  documented=$(_table_cmds "$SKILL") ;;
  esac
  missing=$(comm -23 <(printf '%s\n' "$DISPATCH") <(printf '%s\n' "$documented") | tr '\n' ' ')
  extra=$(comm -13 <(printf '%s\n' "$DISPATCH") <(printf '%s\n' "$documented") | tr '\n' ' ')
  eq "$surface documents every dispatched command" "" "$(printf '%s' "$missing" | sed 's/ *$//')"
  eq "$surface documents no command that does not exist" "" "$(printf '%s' "$extra" | sed 's/ *$//')"
done

WINLIB="$HERE/../overseer/skills/overseer/scripts/lib/windows.sh"
_win_verbs_dispatch() { sed -nE 's/^[[:space:]]+([a-z]+)\)[[:space:]]+_win_.*/\1/p' "$WINLIB" | sort -u; }
_win_verbs_help()     { bash "$ENTRY" --help 2>/dev/null | sed -nE 's/^[[:space:]]+win verbs:[[:space:]]*(.*)/\1/p' | tr ' ' '\n' | sed '/^$/d' | sort -u; }
eq "win dispatcher verbs are non-empty" "yes" "$([ -n "$(_win_verbs_dispatch)" ] && echo yes || echo no)"
eq "help win verbs match the cmd_win dispatcher" "" \
   "$(comm -3 <(_win_verbs_dispatch) <(_win_verbs_help) | tr -d '\t' | tr '\n' ' ' | sed 's/ *$//')"

WINDOC="$HERE/../docs/WINDOWS.md"
SECDOC="$HERE/../SECURITY.md"
CONTRIB="$HERE/../CONTRIBUTING.md"
PRTPL="$HERE/../.github/pull_request_template.md"

_has() { grep -qF "$2" "$1" && echo yes || echo no; }
_hasre() { grep -qE "$2" "$1" && echo yes || echo no; }

eq "README states the Linux controller / Windows target support model" "yes" "$(_hasre "$README" '^## Support model')"
eq "SKILL frontmatter names the Windows broker commands" "yes" "$(sed -n '2p' "$SKILL" | grep -qE 'win <host>.*(start|chat)' && echo yes || echo no)"
eq "SKILL scope section covers both target kinds" "yes" "$(_hasre "$SKILL" '^## Scope: what runs where')"
for v in OVERSEER_REMOTE_DIR OVERSEER_REMOTE_BIN OVERSEER_NO_AUTODEPLOY OVERSEER_SSH OVERSEER_SSH_OPTS OVERSEER_SCP OVERSEER_WIN_CLAUDE OVERSEER_WIN_CODEX OVERSEER_TIMEOUT OVERSEER_POLL_INTERVAL; do
  eq "README documents $v" "yes" "$(_has "$README" "$v")"
done

ENTRYLIB="$HERE/../overseer/skills/overseer/scripts/lib"
eq "README quotes the real no-agent-pane error" "yes" "$(_has "$README" 'no agent pane (claude/codex) for target')"
eq "that error string still exists in the code" "yes" "$(_has "$ENTRYLIB/commands.sh" 'no agent pane (claude/codex) for target')"
eq "README does not claim overseer opens panes" "no" "$(_hasre "$README" 'opens \(or attaches\) a tmux pane|launches an agent harness')"

eq "README describes the Windows poll as mtime:size gated" "yes" "$(_has "$README" 'mtime:size')"
eq "SKILL describes the Windows poll as mtime:size gated" "yes" "$(_has "$SKILL" 'mtime:size')"
eq "README links the Windows doc" "yes" "$(_has "$README" 'docs/WINDOWS.md')"
eq "SKILL links the Windows doc" "yes" "$(_has "$SKILL" 'docs/WINDOWS.md')"
eq "Windows doc has a prerequisites section" "yes" "$(_hasre "$WINDOC" '^## Prerequisites')"
eq "Windows doc has a security model section" "yes" "$(_hasre "$WINDOC" '^## Security model')"
eq "SECURITY covers the Windows commands" "yes" "$(_has "$SECDOC" 'win <host> start')"
eq "SKILL safety rules cover the win commands" "yes" "$(_hasre "$SKILL" '^## Safety rules for .*win <host>')"
eq "CONTRIBUTING has the Windows live-verification checklist" "yes" "$(_hasre "$CONTRIB" '^### Windows live verification')"
eq "CONTRIBUTING documents the Windows contract tests" "yes" "$(_has "$CONTRIB" 'tests/win-contracts.ps1')"
eq "CONTRIBUTING documents the local PowerShell runner" "yes" "$(_has "$CONTRIB" 'OVERSEER_PWSH')"
eq "Windows doc points at the local PowerShell runner" "yes" "$(_has "$WINDOC" 'tests/win-payloads.sh')"
eq "Windows doc names the CI parse script" "yes" "$(_has "$WINDOC" 'tests/win-parse.ps1')"
eq "CI runs the windows payload scripts natively" "yes" "$(_has "$HERE/../.github/workflows/validate.yml" './tests/win-parse.ps1')"
eq "PR template requires the Windows payload run" "yes" "$(_has "$PRTPL" 'tests/win-payloads.sh')"
eq "README walkthrough shows the broker lifecycle" "yes" "$(_hasre "$README" 'overseer win .* stop')"
eq "SKILL walkthrough shows the broker lifecycle" "yes" "$(_hasre "$SKILL" 'overseer win .* stop')"

_poll() { OVERSEER_POLL_INTERVAL="$1" bash "$ENTRY" --help >/dev/null 2>&1 && echo ok || echo rejected; }
for good in 0.25 1 1.0 .5 2.5; do
  eq "poll interval '$good' is accepted" "ok" "$(_poll "$good")"
done
eq "poll interval empty falls back to the default" "ok" "$(_poll '')"
for bad in . 1..2 0 0.0 .0 abc 1x -1 00 000 0. 0.000 0.0000 .00; do
  eq "poll interval '$bad' is rejected" "rejected" "$(_poll "$bad")"
done

if [ "$fail" = 0 ]; then
  printf 'PASS: all parser fixture tests\n'; exit 0
else
  printf 'FAIL: %s test(s) failed\n' "$fail"; exit 1
fi
