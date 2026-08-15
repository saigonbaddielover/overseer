#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LIB="$HERE/../plugins/overseer/skills/overseer/scripts/lib"
FIX="$HERE/fixtures"
export CLAUDE_HOME="$HERE/.home" CODEX_HOME="$HERE/.home"

# shellcheck source=../plugins/overseer/skills/overseer/scripts/lib/transcript.sh
. "$LIB/transcript.sh"
# shellcheck source=../plugins/overseer/skills/overseer/scripts/lib/tui.sh
. "$LIB/tui.sh"
# shellcheck source=../plugins/overseer/skills/overseer/scripts/lib/discovery.sh
. "$LIB/discovery.sh"
_die() { printf 'overseer: %s\n' "$1" >&2; exit 1; }
# shellcheck source=../plugins/overseer/skills/overseer/scripts/lib/windows.sh
. "$LIB/windows.sh"
# shellcheck source=../plugins/overseer/skills/overseer/scripts/lib/commands.sh
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

TS="$FIX/claude-thinking-split.jsonl"
eq "claude split thinking+text is ONE turn, not two" "1"    "$(_turn_count "$TS")"
eq "claude split turns_after(0) is one turn"         "1"    "$(_turns_after claude "$TS" 0)"
eq "claude split reply is the text block"  "the essay itself" "$(_last_reply "$TS")"
eq "claude split reply_for_prompt matches" "the essay itself" "$(_reply_for_prompt "$TS" "write me an essay")"
eq "claude split reads as finished"        ""                 "$(_running_claude "$TS" && echo running)"

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

RAR="$FIX/claude-running-after-reply.jsonl"
SAE="$FIX/claude-stale-after-error.jsonl"
URP="$FIX/claude-unreadable-reply.jsonl"
_rr() { _read_reply "$1" "$2" "%9" "$(_h_last_prompt "$1" "$2")"; }
eq "read: an answered turn still prints its reply" $'final reply\nsecond line' "$(_rr claude "$C")"
eq "read: reply is paired, not the last one in the file"    "ANS1"      "$(_rr claude "$RTN")"
eq "read: a turn in flight is named, not answered with the previous reply" \
   "yes" "$(case "$(_rr claude "$RAR")" in '(NO REPLY YET'*) echo yes ;; *) echo no ;; esac)"
eq "read: the previous reply is not printed while in flight" \
   "no" "$(case "$(_rr claude "$RAR")" in *'first reply'*) echo yes ;; *) echo no ;; esac)"
eq "read: an old API error is not replayed onto a turn in flight" \
   "no" "$(case "$(_rr claude "$SAE")" in *'API Error'*) echo yes ;; *) echo no ;; esac)"
eq "read: a current API error is still reported" \
   "yes" "$(case "$(_rr claude "$FIX/claude-api-error.jsonl")" in '(NO REPLY — the turn ended in an API error)'*) echo yes ;; *) echo no ;; esac)"
eq "read: a completed turn with no readable reply says so" \
   "yes" "$(case "$(_rr claude "$URP")" in '(NO READABLE REPLY'*) echo yes ;; *) echo no ;; esac)"
eq "read: codex in flight is named too" \
   "yes" "$(case "$(_rr codex "$FIX/codex-busy.jsonl")" in '(NO REPLY YET'*) echo yes ;; *) echo no ;; esac)"

fleet_stdin=$(
  _panes() { printf 's1\t%%1\t111\tclaude\t/w\ns1\t%%2\t222\tclaude\t/w\ns1\t%%3\t333\tclaude\t/w\n'; }
  _fleet_status() { printf '%s\tclaude\tidle\n' "$1"; }
  _label_pane() { printf '%s' "$1"; }
  cmd_send() { while [ "${1#--}" != "$1" ]; do shift; done; printf 'SENT %s [%s]\n' "$1" "$2"; }
  _fleet_local send --yes - <<'MSG'
line 1
line 2
MSG
)
eq "fleet send -: every pane receives it, not just the first" "3" \
   "$(printf '%s\n' "$fleet_stdin" | grep -c '^SENT ')"
eq "fleet send -: each pane receives the whole message" "3" \
   "$(printf '%s\n' "$fleet_stdin" | grep -c 'line 1$')"

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

RO="/x/.codex/sessions/2026/08/14/rollout-2026-08-14T17-45-13-01a00160-c3b4-70d3-bc54-09f25f4086f0.jsonl"
eq "codex sid off the rollout name" "01a00160-c3b4-70d3-bc54-09f25f4086f0" "$(_cx_sid_from_rollout "$RO")"
eq "codex sid: a name with no timestamp yields nothing" "" "$(_cx_sid_from_rollout /x/rollout-nope.jsonl)"
eq "codex sid: an empty path yields nothing"            "" "$(_cx_sid_from_rollout "")"
eq "h_sid claude dispatch" "test-sid-123"                          "$(_h_sid claude "$C")"
eq "h_sid codex dispatch"  "01a00160-c3b4-70d3-bc54-09f25f4086f0"  "$(_h_sid codex "$RO")"
eq "h_sid never fails under set -e" "rc=0" "$(_h_sid codex ''; echo "rc=$?")"

_marker_probe() {
  local sub="$1" sid="$2" age="$3"
  local d="$CLAUDE_HOME/$sub"
  mkdir -p "$d"; : >"$d/$sid"
  [ "$age" = old ] && touch -d '@1' "$d/$sid"
  _marker_since "$sub" "$sid" "$(date +%s)" && echo hit || echo miss
}
eq "marker: a fresh turn-done counts for a codex sid" "hit" \
   "$(_marker_probe turn-done 01a00160-c3b4-70d3-bc54-09f25f4086f0 fresh)"
eq "marker: a stale turn-started does not"            "miss" \
   "$(_marker_probe turn-started 01a00160-c3b4-70d3-bc54-09f25f4086f0 old)"
eq "marker: no file at all does not"                  "miss" \
   "$(_marker_since turn-done never-existed-sid "$(date +%s)" && echo hit || echo miss)"
rm -rf "$CLAUDE_HOME/turn-done" "$CLAUDE_HOME/turn-started"

_kind_guard_count() { grep -c "$1" "$LIB/transcript.sh"; }
eq "wait_reply takes the hook signal for any harness" "0" \
   "$(_kind_guard_count '\[ "\$kind" = claude \] && \[ "\$woke" = 0 \]')"
eq "wait_started takes turn-started for any harness"  "0" \
   "$(_kind_guard_count '\[ "\$kind" = claude \] && \[ -n "\$sid" \] && _marker_since turn-started')"

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

QP="$FIX/claude-queue-pending.jsonl"; QR="$FIX/claude-queue-retracted.jsonl"; QD="$FIX/claude-queue-ran.jsonl"
eq "claude queue: pending message is readable"  "the queued follow-up" "$(_cl_queued "$QP")"
eq "claude queue: retracted reads empty"        ""                     "$(_cl_queued "$QR")"
eq "claude queue: a message that ran reads empty" ""                   "$(_cl_queued "$QD")"
eq "claude queue: no queue-operation record at all" ""                 "$(_cl_queued "$C")"
eq "claude queue: last op after a retract"      "popAll"               "$(_cl_queue_op "$QR")"
eq "claude queue: last op once it started running" "dequeue"           "$(_cl_queue_op "$QD")"
eq "h_queued claude dispatch"    "the queued follow-up" "$(_h_queued claude "$QP" %9)"
eq "h_unqueued: a retract counts" "0" "$(_h_unqueued claude "$QR" %9 >/dev/null 2>&1; echo $?)"
eq "h_unqueued: it running does NOT count as a retract" "1" "$(_h_unqueued claude "$QD" %9 >/dev/null 2>&1; echo $?)"
eq "h_popkey claude" "Up"     "$(_h_popkey claude)"
eq "h_popkey codex"  "S-Left" "$(_h_popkey codex)"
eq "self pane detected"          "0" "$(TMUX_PANE=%9 _self_pane %9 >/dev/null 2>&1; echo $?)"
eq "another pane is not self"    "1" "$(TMUX_PANE=%9 _self_pane %8 >/dev/null 2>&1; echo $?)"
eq "no TMUX_PANE means not self" "1" "$(TMUX_PANE='' _self_pane %9 >/dev/null 2>&1; echo $?)"
_self_refuses() {
  ( _need() { :; }; _target_ctx() { printf '%%9\tclaude\t%s' "$C"; }; _resolve_pane() { printf '%%9'; }
    TMUX_PANE=%9; DEFAULT_TIMEOUT=5; _lock_pane() { echo LOCKED; }
    "$@" 2>&1 )
}
has_txt() { case "$2" in *"$3"*) eq "$1" yes yes ;; *) eq "$1" "contains '$3'" "$2" ;; esac; }
has_txt "unsend refuses its own pane"    "$(_self_refuses cmd_unsend %9)"       'refusing to unsend'
has_txt "interrupt refuses its own pane" "$(_self_refuses cmd_interrupt %9)"    'refusing to interrupt'
has_txt "wait refuses its own pane"      "$(_self_refuses cmd_wait %9)"         'refusing to wait on'
has_txt "send refuses its own pane"      "$(_self_refuses cmd_send %9 hi)"      'refusing to send to'
has_txt "chat refuses its own pane"      "$(_self_refuses cmd_chat %9 hi)"      'refusing to chat with'
has_txt "keys refuses its own pane"      "$(_self_refuses cmd_keys %9 Escape)"  'refusing to send keys to'
has_txt "sh refuses its own pane"        "$(_self_refuses cmd_sh %9 'echo hi')" 'refusing to run a shell command in'
has_txt "quit refuses its own pane"      "$(_self_refuses cmd_quit %9)"         'refusing to quit'
has_txt "slash refuses its own pane"     "$(_self_refuses cmd_slash %9 /model)" 'refusing to run a slash command in'
has_txt "menu refuses its own pane"      "$(_self_refuses cmd_menu %9 Bash)"    'refusing to navigate a menu in'
has_txt "stop refuses its own pane"      "$(_self_refuses cmd_stop %9)"         'refusing to kill the pane'
eq "the self guard runs before any locking"  "" \
   "$(_self_refuses cmd_interrupt %9 | grep -c LOCKED | sed 's/^0$//')"
_fleet_self() {
  ( _need() { :; }; _panes() { printf 'sess\t%%9\t1\tclaude\t/w\n'; }
    TMUX_PANE=%9; DEFAULT_TIMEOUT=5
    cmd_unsend() { echo REACHED; }; cmd_interrupt() { echo REACHED; }
    cmd_wait() { echo REACHED; }; _fleet_wait_any() { echo REACHED; }
    _fleet_local "$@" 2>&1 )
}
has_txt  "fleet unsend skips the caller's own pane"    "$(_fleet_self unsend)"    '(skipped'
has_txt  "fleet interrupt skips the caller's own pane" "$(_fleet_self interrupt)" '(skipped'
has_txt  "fleet wait skips the caller's own pane"      "$(_fleet_self wait)"      '(skipped'
has_txt  "fleet wait says so when self was the only pane" "$(_fleet_self wait)"   'nothing to wait for'
has_txt  "fleet wait --any skips it too"               "$(_fleet_self wait --any)" '(skipped'
eq "fleet never reaches the per-pane command for self" "" \
   "$(_fleet_self interrupt | grep -c REACHED | sed 's/^0$//')"
eq "fleet wait never waits on self" "" \
   "$({ _fleet_self wait; _fleet_self wait --any; } | grep -c REACHED | sed 's/^0$//')"
_fleet_pair() {
  ( _need() { :; }; _panes() { printf 'sess\t%%9\t1\tclaude\t/w\nsess\t%%8\t2\tclaude\t/w\n'; }
    TMUX_PANE=%9; DEFAULT_TIMEOUT=5
    cmd_wait() { printf 'WAITED %s\n' "$1"; }
    _fleet_wait_any() { shift; printf 'WATCHED %s\n' "$*"; }
    _fleet_local "$@" 2>&1 | grep -E 'WAITED|WATCHED' )
}
eq "fleet wait still waits on the other panes" "# %8: WAITED %8" "$(_fleet_pair wait)"
eq "fleet wait --any watches only the other panes" "WATCHED %8" "$(_fleet_pair wait --any)"
eq "h_intkey claude"   "Escape" "$(_h_intkey claude)"
eq "h_intkey codex"    "Escape" "$(_h_intkey codex)"
eq "win_intkey claude is C-c, not Escape" "C-c" "$(_win_intkey claude)"
eq "win_intkey codex"  "Escape" "$(_win_intkey codex)"
eq "claude never steers" "1" "$(_h_steering claude "$QP" %9 >/dev/null 2>&1; echo $?)"

eq "codex queue: retractable follow-ups are read" $'the queued follow-up\na second queued line' \
   "$(_cx_queued_text "$(cat "$FIX/codex-queued.txt")")"
eq "codex queue: end-of-turn messages are retractable too" "retractable during a review" \
   "$(_cx_queued_text "$(cat "$FIX/codex-queued-end-of-turn.txt")")"
eq "codex queue: an in-flight steer is NOT retractable" "" \
   "$(_cx_queued_text "$(cat "$FIX/codex-steer.txt")")"
eq "codex steer detected"        "0" "$(_cx_steering_text "$(cat "$FIX/codex-steer.txt")"  >/dev/null 2>&1; echo $?)"
eq "codex steer absent on queue" "1" "$(_cx_steering_text "$(cat "$FIX/codex-queued.txt")" >/dev/null 2>&1; echo $?)"

eq "realtext: empty box reads empty"                  ""                  "$(_realtext_of "$(cat "$FIX/claude-box-empty.txt")")"
eq "realtext: a dim ghost split by an SGR reads empty" ""                 "$(_realtext_of "$(cat "$FIX/claude-ghost-queued.txt")")"
eq "realtext: real typed text survives"               "half typed draft"  "$(_realtext_of "$(cat "$FIX/claude-box-draft.txt")")"
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

WRAPBOX=$(cat "$FIX/win-snap-wrapped-box.txt")
LONGP='Write a 1200-word essay on the history of the semicolon in English prose. Answer entirely from your own knowledge in one message: do NOT use any tool, do NOT read or write any file, do NOT run any command.'
eq "win box: wrapped lines rejoin to the whole prompt" "$(_win_squash "$LONGP")" "$(_win_squash "$(_win_box_text "$WRAPBOX")")"
eq "win box: reads the composer, not the transcript echo" "" \
   "$(case "$(_win_box_text "$WRAPBOX")" in *OVERSEER-OK*) echo leaked ;; esac)"
CXBOX=$(cat "$FIX/win-snap-wrapped-box-codex.txt")
CXPROMPT='Write a 2000-word essay on the history of the em dash and the parenthesis in English prose, including a section on typesetting practice. Answer entirely from your own knowledge in a single message.'
eq "win box: the codex composer has no closing rule, only a blank line" "$(_win_squash "$CXPROMPT")" "$(_win_squash "$(_win_box_text "$CXBOX")")"
eq "win box: the codex status line stays out of the composer" "" \
   "$(case "$(_win_box_text "$CXBOX")" in *Context*) echo leaked ;; esac)"
eq "win box: a single-line box is unchanged"  "hello"    "$(_win_box_text '> hello')"
eq "win box: no composer yields nothing"      ""         "$(_win_box_text 'just some output')"
eq "win squash: a nbsp gutter matches a space" "ab"      "$(_win_squash "a$(printf '\302\240')b")"

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

_pbn() { _pane_by_peer_name() { case "$1" in cookie-importer) printf '%%7' ;; *) return 1 ;; esac; }; }
eq "resolve: a peer name beats a tmux target of the same name" "%7" \
   "$( ( _pbn; tmux() { printf '%%99'; }; _resolve_pane cookie-importer ) )"
eq "resolve: a target with no peer name still resolves via tmux" "%99" \
   "$( ( _pbn; tmux() { printf '%%99'; }; _resolve_pane work ) )"
eq "resolve: neither peer name nor tmux is a failure" "1" \
   "$( ( _pbn; tmux() { return 1; }; _resolve_pane ghost ) >/dev/null 2>&1; echo $? )"
eq "list: the peer name is the leading column" "PEER REACH
cookie-importer keys+peer" \
   "$( ( _need() { :; }; _panes() { printf 'sess\t%%1\t111\tclaude\t/x\n'; }
        _peer_name_of() { printf 'cookie-importer'; }; _peer_sessions() { :; }
        cmd_list ) | cut -f1,2 | tr '\t' ' ' )"
eq "list: a named pane with no peer socket shows its name, not a blank" "PEER REACH
old-build keys+name" \
   "$( ( _need() { :; }; _panes() { printf 'sess\t%%1\t111\tclaude\t/x\n'; }
        _peer_name_of() { return 1; }; _peer_name_any() { printf 'old-build'; }; _peer_sessions() { :; }
        cmd_list ) | cut -f1,2 | tr '\t' ' ' )"
eq "list: a genuinely unnamed pane still reads as unnamed" "PEER REACH
- keys" \
   "$( ( _need() { :; }; _panes() { printf 'sess\t%%1\t111\tcodex\t/x\n'; }
        _peer_name_of() { return 1; }; _peer_name_any() { return 1; }; _peer_sessions() { :; }
        cmd_list ) | cut -f1,2 | tr '\t' ' ' )"

PH="${TMPDIR:-/tmp}/ov-peers-$$"; mkdir -p "$PH/sessions"
printf '{"name":"twin","tmux":"s:@1.%%1","messagingSocketPath":"/x/a.sock"}\n' >"$PH/sessions/1.json"
printf '{"name":"twin","tmux":"s:@2.%%2","messagingSocketPath":"/x/b.sock"}\n' >"$PH/sessions/2.json"
printf '{"name":"solo","tmux":"s:@3.%%3","messagingSocketPath":"/x/c.sock"}\n' >"$PH/sessions/3.json"
printf '{"name":"gone","tmux":"s:@4.%%4","messagingSocketPath":""}\n'         >"$PH/sessions/4.json"
printf '{"name":"headless-old","tmux":"","messagingSocketPath":""}\n'        >"$PH/sessions/5.json"
_peers() { ( CLAUDE_HOME="$PH"; _peer_live() { [ -n "$1" ]; }; _p_comm() { :; }; _pane_by_peer_name "$1" ); }
eq "peer name: a unique live name resolves to its pane"        "%3" "$(_peers solo)"
eq "peer name: a duplicated name refuses instead of guessing"  "2"  "$(_peers twin >/dev/null 2>&1; echo $?)"
eq "peer name: a named pane with no peer socket is still a target (keys reach it)" \
   "%4" "$(_peers gone)"
eq "peer name: named, no pane and no socket is reachable by nothing" \
   "4"  "$(_peers headless-old >/dev/null 2>&1; echo $?)"
eq "peer name: a dead session's stale file is not a candidate" "1" \
   "$( ( CLAUDE_HOME="$PH"; _peer_live() { [ -n "$1" ]; }; _p_comm() { return 1; }; _pane_by_peer_name solo ) >/dev/null 2>&1; echo $?)"
rm -rf "$PH"

GH="${TMPDIR:-/tmp}/ov-ghost-$$"; mkdir -p "$GH/sessions" "$GH/projects/-x"
cp "$FIX/claude-turn.jsonl" "$GH/projects/-x/gsid.jsonl"
printf '{"name":"ghost","sessionId":"gsid","cwd":"/x"}\n'     >"$GH/sessions/1.json"
printf '{"name":"twinghost","sessionId":"gsid","cwd":"/x"}\n' >"$GH/sessions/2.json"
printf '{"name":"twinghost","sessionId":"gsid","cwd":"/x"}\n' >"$GH/sessions/3.json"
printf '{"name":"nosid","cwd":"/x"}\n'                        >"$GH/sessions/4.json"
_ghost() { ( CLAUDE_HOME="$GH"; _p_comm() { :; }; _paneless_ctx "$1" ); }
eq "paneless: a named session with no pane still resolves to its transcript" \
   "$GH/projects/-x/gsid.jsonl" "$(_ghost ghost | cut -f3)"
eq "paneless: it reports no pane and the claude harness" "- claude" \
   "$(_ghost ghost | cut -f1,2 | tr '\t' ' ')"
eq "paneless: a duplicated name refuses instead of guessing" "2" \
   "$(_ghost twinghost >/dev/null 2>&1; echo $?)"
eq "paneless: a session with no sessionId is no candidate" "1" \
   "$(_ghost nosid >/dev/null 2>&1; echo $?)"
eq "paneless: a dead session's stale file is not a candidate" "1" \
   "$( ( CLAUDE_HOME="$GH"; _p_comm() { return 1; }; _paneless_ctx ghost ) >/dev/null 2>&1; echo $?)"
rm -rf "$GH"
eq "resolve: an ambiguous peer name never falls through to tmux" "1" \
   "$( ( _pane_by_peer_name() { return 2; }; tmux() { printf '%%99'; }; _resolve_pane twin ) >/dev/null 2>&1; echo $?)"
eq "target error: an ambiguous name says so, not 'no tmux pane'" "yes" \
   "$( ( _pane_by_peer_name() { return 2; }; _die() { printf 'ERR %s\n' "$1"; exit 1; }
        _target_die twin 'no tmux pane for target: twin' ) 2>&1 | grep -q 'ERR.*more than one live' && echo yes || echo no)"
eq "target error: an unknown target keeps the plain message" "yes" \
   "$( ( _pane_by_peer_name() { return 1; }; _die() { printf 'ERR %s\n' "$1"; exit 1; }
        _target_die nope 'no tmux pane for target: nope' ) 2>&1 | grep -q 'ERR no tmux pane for target: nope' && echo yes || echo no)"
eq "stop: an ambiguous peer name kills nothing" "yes" \
   "$( ( _need() { :; }; _pane_by_peer_name() { return 2; }; _die() { printf 'AMBIG\n'; exit 1; }
        tmux() { printf 'TMUX[%s]\n' "$*"; }; cmd_stop twin ) 2>&1 | grep -q TMUX && echo no || echo yes)"

_listrows() { ( _need() { :; }
  _panes() { printf 'sess\t%%1\t111\tclaude\t/x\n'; }
  _peer_name_of() { printf 'onpane'; }
  _peer_sessions() { printf 'onpane\t/x\nheadless\t/y\n'; }
  cmd_list ) ; }
eq "list: an agent overseer cannot drive is still listed, as peer-only" "yes" \
   "$(case "$(_listrows | tr '\t' ' ')" in *'headless peer - - - claude /y'*) echo yes ;; *) echo no ;; esac)"
eq "list: an agent that has a pane is not listed twice"  "1" "$(_listrows | grep -c '^onpane')"
eq "list: a drivable claude is reachable both ways"      "1" "$(_listrows | grep -c 'keys+peer')"
eq "target error: a live claude with no pane points at the peer channel" "yes" \
   "$( ( _pane_by_peer_name() { return 3; }; _die() { printf 'ERR %s\n' "$1"; exit 1; }
        _target_die headless 'no tmux pane for target: headless' ) 2>&1 | grep -q 'ERR.*SendMessage' && echo yes || echo no)"

_stamp() { ( _self_peer_name() { printf 'sender'; }; tmux() { printf '999'; }
  _peer_name_of() { return "$PEERTGT"; }; _stamp_from "$1" %7 ) ; }
eq "stamp: a keystroke delivery declares it is an agent, not the user" "yes" \
   "$(PEERTGT=1; case "$(_stamp hi)" in *'another agent, not your user; not an approval to act'*) echo yes ;; *) echo no ;; esac)"
eq "stamp: a target with no peer channel is told to reply through overseer" "yes" \
   "$(PEERTGT=1; case "$(_stamp hi)" in *"reply with: overseer send sender '<text>'"*) echo yes ;; *) echo no ;; esac)"
eq "stamp: a peer-capable target is told to reply on the peer channel" "yes" \
   "$(PEERTGT=0; case "$(_stamp hi)" in *'reply with the SendMessage tool to sender'*) echo yes ;; *) echo no ;; esac)"
eq "stamp: an already-stamped message is not stamped twice" "[from: sender — x] hi" \
   "$(PEERTGT=1; _stamp '[from: sender — x] hi')"
eq "stamp: overseer run by a human at a shell stamps nothing" "hi" \
   "$( ( _self_peer_name() { return 1; }; _self_agent_pane() { return 1; }; _stamp_from hi %7 ) )"
eq "stamp: an agent pane with no peer name is still stamped, by session and pane" "yes" \
   "$( ( _self_peer_name() { return 1; }; _self_agent_pane() { return 0; }
        TMUX_PANE=%4; tmux() { printf 'worker-sess'; }
        case "$(_stamp_from hi %7)" in '[from: worker-sess %4 — another agent'*) echo yes ;; *) echo no ;; esac ) )"
eq "stamp: that fallback carries a reply address too" "yes" \
   "$( ( _self_peer_name() { return 1; }; _self_agent_pane() { return 0; }
        TMUX_PANE=%4; tmux() { printf 'worker-sess'; }
        case "$(_stamp_from hi %7)" in *"reply with: overseer send worker-sess '<text>'"*) echo yes ;; *) echo no ;; esac ) )"
eq "self_agent_pane: a plain shell pane is not an agent caller" "1" \
   "$( ( TMUX_PANE=%4; tmux() { printf '4242'; }; _harness_of() { return 1; }; _self_agent_pane ) >/dev/null 2>&1; echo $?)"
eq "self_agent_pane: outside tmux there is no agent caller" "1" \
   "$( ( unset TMUX_PANE; _self_agent_pane ) >/dev/null 2>&1; echo $?)"

_guarded() { ( _die() { printf 'REFUSED %s\n' "$1"; exit 1; }
  tmux() { printf '1234'; }; _peer_name_of() { printf 'cookie-importer'; }
  _peer_guard %7 target ) 2>&1; }
eq "peer guard: a peer-capable target is refused by name" "yes" \
   "$(case "$(_guarded)" in *REFUSED*cookie-importer*) echo yes ;; *) echo no ;; esac)"
eq "peer guard: a target reached through 'on <host>' is never refused" "" \
   "$( ( export OVS_VIA_ON=1; _guarded ) )"
eq "on: the remote command carries the cross-machine marker" "yes" \
   "$( ( _need() { :; }; export OVERSEER_REMOTE_BIN='ovbin' OVERSEER_SSH='echo'
        cmd_on host chat %1 hi ) 2>&1 | grep -q 'OVS_VIA_ON=1 ovbin' && echo yes || echo no)"

_fleetsend() { ( _need() { :; }
  _panes() { printf 'sess\t%%1\t111\tclaude\t/x\n'; }
  _fleet_status() { printf '%%1\tclaude\tidle\n'; }
  _label_pane() { printf '%s' "$1"; }
  cmd_send() { printf 'SEND[%s]\n' "$*"; }
  _fleet_local send "$@" ) 2>&1; }
eq "fleet send: --force-keys reaches the per-pane send" "yes" \
   "$(case "$(_fleetsend --yes --force-keys hi)" in *'SEND[--yes --force-keys %1 hi]'*) echo yes ;; *) echo no ;; esac)"
eq "fleet send: --force-keys is not broadcast as the message" "no" \
   "$(case "$(_fleetsend --yes --force-keys hi)" in *'%1 --force-keys'*) echo yes ;; *) echo no ;; esac)"
eq "fleet send: --as-user reaches the per-pane send" "yes" \
   "$(case "$(_fleetsend --yes --as-user hi)" in *'SEND[--yes --as-user %1 hi]'*) echo yes ;; *) echo no ;; esac)"
eq "fleet send: --as-user is not broadcast as the message" "no" \
   "$(case "$(_fleetsend --yes --as-user hi)" in *'%1 --as-user'*) echo yes ;; *) echo no ;; esac)"

_sent_msg() { ( _need() { :; }; _uint() { :; }; DEFAULT_TIMEOUT=5
  _target_ctx() { printf '%%7\tclaude\t/no/transcript'; }
  _no_self() { :; }; _lock_pane() { :; }; _unlock_pane() { :; }
  _queued() { return 1; }; _compacting() { return 1; }; _h_running() { return 1; }
  _h_turn_count() { printf '0'; }; _fsize() { printf '0'; }
  _peer_guard() { printf 'GUARD\n'; }
  _stamp_from() { printf 'STAMPED %s' "$1"; }
  _undelivered() { printf 'undelivered'; }
  _deliver() { printf 'DELIVER[%s]\n' "$3"; return 1; }
  "$@" ) 2>&1; }
eq "as-user: the message is delivered verbatim, with no sender prefix" "DELIVER[hi]" \
   "$(_sent_msg cmd_send --yes --as-user %7 hi | head -1)"
eq "as-user: the peer refusal stands down without --force-keys" "no" \
   "$(case "$(_sent_msg cmd_send --yes --as-user %7 hi)" in *GUARD*) echo yes ;; *) echo no ;; esac)"
eq "as-user: chat delivers verbatim too" "DELIVER[hi]" \
   "$(_sent_msg cmd_chat --yes --as-user %7 hi | head -1)"
eq "force-keys alone still declares the sender" "DELIVER[STAMPED hi]" \
   "$(_sent_msg cmd_send --yes --force-keys %7 hi | head -1)"
eq "a plain send is still refused for a peer-capable target" "yes" \
   "$(case "$(_sent_msg cmd_send --yes %7 hi)" in *GUARD*) echo yes ;; *) echo no ;; esac)"

eq "discover class: linux + tmux/jq is drivable"        "drivable"    "$(_discover_class ok linux yes)"
eq "discover class: linux missing a dep needs-deps"     "needs-deps"  "$(_discover_class ok linux no:jq)"
eq "discover class: a windows host is a win target"     "windows"     "$(_discover_class ok windows -)"
eq "discover class: ssh auth failure is a gap"          "gap"         "$(_discover_class deny '?' -)"
eq "discover class: no route is unreachable"            "unreachable" "$(_discover_class unreach '?' -)"

_discw() { ( _die() { printf 'ERR %s\n' "$1"; exit 1; }; _discover_write "$@" ) }
DHF=$(mktemp)
printf 'hand@kept.example\n' > "$DHF"
_discw "$DHF" 'a@1.1.1.1' 'b@2.2.2.2' >/dev/null
eq "discover write: keeps hand-written lines"      "1" "$(grep -c '^hand@kept.example$' "$DHF")"
eq "discover write: adds the discovered targets"   "yes" "$(grep -qx 'a@1.1.1.1' "$DHF" && grep -qx 'b@2.2.2.2' "$DHF" && echo yes || echo no)"
_discw "$DHF" 'c@3.3.3.3' >/dev/null
eq "discover write: replaces the managed block, not appends" "0" "$(grep -c '^a@1.1.1.1$' "$DHF")"
eq "discover write: the rewrite still keeps hand lines"      "1" "$(grep -c '^hand@kept.example$' "$DHF")"
eq "discover write: hosts inventory reads both hand + block" "$(printf 'hand@kept.example\nc@3.3.3.3')" "$(_hosts_parse < "$DHF")"
rm -f "$DHF"

eq "known_hosts: an unhashed name is extracted, [host]:port stripped, hashed skipped" \
   "$(printf 'a.example\nb.example')" \
   "$( TH=$(mktemp -d); mkdir -p "$TH/.ssh"
       printf '|1|abcd=|efgh= ssh-ed25519 AAAA\na.example ssh-ed25519 AAAA\n[b.example]:2222 ssh-rsa BBBB\n# comment\n' > "$TH/.ssh/known_hosts"
       ( _known_hosts_files() { printf '%s\n' "$TH/.ssh/known_hosts"; }; HOME="$TH" _known_hosts_names ); rm -rf "$TH" )"
eq "history: ssh targets are extracted, flags skipped" \
   "$(printf 'sandbox@1.2.3.4\nbox.example')" \
   "$( TH=$(mktemp -d)
       printf 'ls -la\nssh -p 22 -i ~/.ssh/id sandbox@1.2.3.4 uptime\nssh box.example\ncat file\n' > "$TH/.bash_history"
       ( HOME="$TH" _history_ssh_targets ); rm -rf "$TH" )"
eq "docker: an ssh:// context endpoint yields user@host" "deploy@dockerhost" \
   "$( ( docker() { printf 'ssh://deploy@dockerhost\nunix:///var/run/docker.sock\n'; }
        command() { case "$1 $2" in '-v docker') return 0 ;; *) builtin command "$@" ;; esac; }
        _docker_ssh_hosts ) )"
eq "etc-hosts: real hosts kept, localhost/adblock junk dropped" \
   "$(printf 'lab.internal\ngpu.box')" \
   "$( TH=$(mktemp)
       printf '127.0.0.1 localhost\n0.0.0.0 ads.tracker.com\n10.0.0.5 lab.internal gpu.box\n::1 ip6-localhost\n' > "$TH"
       _etc_hosts_names "$TH"; rm -f "$TH" )"

# shellcheck disable=SC2120
_discover() { ( _need() { :; }; _uint() { :; }
  _ts_inventory() { printf '100.0.0.9\tself-box\tlinux\tself\t\n100.0.0.1\tlinbox\tlinux\tonline\tlinbox.ts.net\n100.0.0.2\twinbox\twindows\tonline\t\n'; }
  _ssh_config_aliases() { return 0; }
  _known_hosts_names() { return 0; }; _history_ssh_targets() { return 0; }
  _docker_ssh_hosts() { return 0; }; _etc_hosts_names() { return 0; }; _khost_present() { return 1; }
  _ssh_resolve() { printf 'ruser\t%s\t\n' "$1"; }
  _host_probe() { case "$1" in ruser@100.0.0.1) printf 'ruser@100.0.0.1\tonline\tlinux\tok\tyes' ;; *) printf '%s\toffline\t?\tunreach\t-' "$1" ;; esac; }
  command() { case "$1" in -v) return 1 ;; *) builtin command "$@" ;; esac; }
  cmd_discover "$@" ) 2>&1; }
eq "discover: a windows peer is a win target, not probed" "yes" \
   "$(case "$(_discover)" in *winbox*windows*) echo yes ;; *) echo no ;; esac)"
eq "discover: self is excluded from the table" "no" \
   "$(case "$(_discover)" in *self-box*) echo yes ;; *) echo no ;; esac)"
eq "discover: a reachable linux is drivable"   "yes" \
   "$(case "$(_discover)" in *linbox*ruser@100.0.0.1*drivable*) echo yes ;; *) echo no ;; esac)"
eq "discover: the table carries a SOURCE column" "yes" \
   "$(case "$(_discover)" in *'SOURCE'*STATUS*) echo yes ;; *) echo no ;; esac)"

# shellcheck disable=SC2120
_discnoguess() { ( _need() { :; }; _uint() { :; }
  _ts_inventory() { printf '100.0.0.9\tself-box\tlinux\tself\t\n100.0.0.5\tmystery\tlinux\tonline\tmystery.ts.net\n'; }
  _ssh_config_aliases() { return 0; }
  _known_hosts_names() { return 0; }; _history_ssh_targets() { return 0; }
  _docker_ssh_hosts() { return 0; }; _etc_hosts_names() { return 0; }; _khost_present() { return 1; }
  _ssh_resolve() { printf '%s\t%s\t\n' "$(id -un)" "$1"; }
  _host_probe() { printf '%s\tonline\tlinux\tok\tyes' "$1"; }
  command() { case "$1" in -v) return 1 ;; *) builtin command "$@" ;; esac; }
  cmd_discover "$@" ) 2>&1; }
eq "discover: a bare ssh -G default user is unknown, never guessed" "yes" \
   "$(case "$(_discnoguess)" in *"$(id -un)@100.0.0.5"*) echo no ;; *'?@100.0.0.5'*unknown-user*) echo yes ;; *) echo no ;; esac)"

# shellcheck disable=SC2120
_dischint() { ( _need() { :; }; _uint() { :; }
  _ts_inventory() { return 0; }
  _ssh_config_aliases() { return 0; }
  _known_hosts_names() { return 0; }; _history_ssh_targets() { printf 'deploy@10.9.9.9\n'; }
  _docker_ssh_hosts() { return 0; }; _etc_hosts_names() { return 0; }; _khost_present() { return 1; }
  _ssh_resolve() { printf 'localfallback\t%s\t\n' "$1"; }
  _host_probe() { printf '%s\tonline\tlinux\tok\tyes' "$1"; }
  command() { case "$1" in -v) return 1 ;; *) builtin command "$@" ;; esac; }
  cmd_discover --no-tailscale "$@" ) 2>&1; }
eq "discover: a user@ from a source is the login hint, not the ssh -G fallback" "yes" \
   "$(case "$(_dischint)" in *deploy@10.9.9.9*) echo yes ;; *localfallback@10.9.9.9*) echo no ;; *) echo no ;; esac)"

_stoppeer() { ( _need() { :; }; _pbn; _resolve_pane() { printf '%%7'; }; _self_pane() { return 1; }
  tmux() { printf 'TMUX[%s]\n' "$*"; return 0; }
  cmd_stop "$1" ) 2>&1; }
eq "stop: a peer name kills that pane, not the whole session" "yes" \
   "$(case "$(_stoppeer cookie-importer)" in *'TMUX[kill-pane -t %7]'*) echo yes ;; *) echo no ;; esac)"
eq "stop: a session name still kills the session" "yes" \
   "$(case "$(_stoppeer work)" in *'TMUX[kill-session -t =work]'*) echo yes ;; *) echo no ;; esac)"

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
             _wait_drained "${3:-claude}" /nope "${4:-20}" %9 ); printf '%s' "$?"; }
eq "wait: a running transcript on a frozen screen drains (interrupted, not stuck)" "0" "$(_drain still 0)"
eq "wait: a running transcript with a live spinner keeps waiting to timeout"       "1" "$(_drain busy 0 claude 2)"
eq "wait: a running transcript streaming its reply keeps waiting to timeout"       "1" "$(_drain changing 0 claude 2)"
eq "wait: a finished transcript drains regardless of the screen"                   "0" "$(_drain busy 1)"
eq "wait: codex is exempt from the screen veto and waits out its turn"             "1" "$(_drain still 0 codex 2)"

_wreply() { ( export SCREEN="$1" RUN="$2"; _stubs
              case "${4:-reply}" in
                reply)  _wait_reply "${3:-claude}" /nope 0 "${5:-20}" "" 0 %9 "" ;;
                queued) _wait_queued_reply "${3:-claude}" /nope "${5:-20}" %9 'msg' ;;
              esac ); printf '%s' "$?"; }
eq "chat: an interrupted turn reports the no-reply code instead of hanging" "4" "$(_wreply still 0)"
eq "chat: a turn with a live spinner still waits out the timeout"           "1" "$(_wreply busy 0 claude reply 2)"
eq "chat: a turn streaming its reply still waits out the timeout"           "1" "$(_wreply changing 0 claude reply 2)"
eq "chat: a codex turn never uses the screen veto"                          "1" "$(_wreply still 0 codex reply 2)"
eq "chat: a queued message behind an interrupted turn reports it too"       "4" "$(_wreply still 0 claude queued)"
eq "chat: a queued message behind a live turn keeps waiting"                "1" "$(_wreply busy 0 claude queued 2)"
eq "chat: a queued message behind a streaming turn keeps waiting"           "1" "$(_wreply changing 0 claude queued 2)"

CXF="${TMPDIR:-/tmp}/ov-cxrun-$$"
_wreplycx() { ( export SCREEN=still RUN=1 CXF; printf '%s' "${1:-2}" >"$CXF"
                _stubs
                _h_running() { local n; n=$(cat "$CXF" 2>/dev/null || echo 0)
                               [ "$n" -le 0 ] && return 1
                               printf '%s' "$((n - 1))" >"$CXF"; return 0; }
                case "${3:-reply}" in
                  reply)  _wait_reply codex /nope 0 "${2:-20}" "" 0 %9 "" ;;
                  queued) _wait_queued_reply codex /nope "${2:-20}" %9 'msg' ;;
                esac ); printf '%s' "$?"; }
eq "chat: an aborted codex turn reports the no-reply code"                  "4" "$(_wreplycx 2)"
eq "chat: a queued message behind an aborted codex turn reports it too"     "4" "$(_wreplycx 2 20 queued)"
eq "chat: a codex turn not yet started is not read as aborted"              "1" "$(_wreplycx 0 2)"
rm -f "$CXF"

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
SF="${TMPDIR:-/tmp}/ov-latemove-$$"
_fstatlate() { rm -f "$SF"
  ( export LATE="$2"
    _target_ctx() { printf '%%9\tclaude\t%s' "$1"; }
    _awaiting() { return 1; }
    _compacting() { return 1; }
    _nap() { :; }
    _screen_state() { local n=0; [ -f "$SF" ] && n=$(cat "$SF"); n=$((n + 1)); printf '%s' "$n" >"$SF"
                      if [ "$n" -ge "$LATE" ]; then printf 'moved'; else printf 'frozen'; fi; }
    _fleet_status "$1" ) | cut -f3; }
eq "fleet status: a pane that only moves on the last sample still reads busy" "busy" "$(_fstatlate "$RT" 6)"
rm -f "$SF"

NS=$(_notify_script)
eq "notify: the watcher waits on the worker"          "yes" "$(case "$NS" in *'wait "$OVS_TARGET" "$left"'*) echo yes ;; *) echo no ;; esac)"
eq "notify: the watcher waits inside the given budget" "yes" "$(case "$NS" in *'$(date +%s) + OVS_TIMEOUT'*) echo yes ;; *) echo no ;; esac)"
eq "notify: a confirmed turn skips the startup grace"  "yes" "$(case "$NS" in *'"$OVS_STARTED" = 1'*) echo yes ;; *) echo no ;; esac)"
eq "notify: an unconfirmed turn does not trust a stale idle" "yes" "$(case "$NS" in *'-ge "$grace"'*) echo yes ;; *) echo no ;; esac)"
eq "notify: the watcher wakes the dispatcher's pane"  "yes" "$(case "$NS" in *'send --yes --force-keys "$OVS_BACK"'*) echo yes ;; *) echo no ;; esac)"
eq "notify: the wake-up clears the inherited TMUX_PANE" "yes" "$(case "$NS" in *'TMUX_PANE= "$OVS_SELF" send '*) echo yes ;; *) echo no ;; esac)"

_notify_wake_outcome() {
  local forcekeys="$1" inherited="$2"
  (
    export TMUX_PANE="$inherited"
    _die() { printf 'REFUSED'; exit 0; }
    tmux() { printf '4242'; }
    _peer_name_of() { printf 'dispatcher'; }
    _no_self %back "send to"
    [ "$forcekeys" = 1 ] || _peer_guard %back %back
    printf 'DELIVERED'
  )
}
eq "notify: a wake-up that keeps TMUX_PANE is refused as its own pane" "REFUSED" "$(_notify_wake_outcome 1 %back)"
eq "notify: a wake-up without --force-keys is refused by the peer guard" "REFUSED" "$(_notify_wake_outcome 0 '')"
eq "notify: the wake-up as the watcher now sends it is delivered" "DELIVERED" "$(_notify_wake_outcome 1 '')"
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
   "$(case "$(_ntfy %9 %9)" in *'refusing to send to'*) echo yes ;; *) echo no ;; esac)"
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
eq "tmux: one build is not a mismatch"   "1" "$(_tmux_mismatch /usr/bin/tmux /usr/bin/tmux; echo $?)"
eq "tmux: two builds are a mismatch"     "0" "$(_tmux_mismatch /usr/bin/tmux /usr/local/bin/tmux; echo $?)"
eq "tmux: an unreadable server binary is not a mismatch" "1" "$(_tmux_mismatch /usr/bin/tmux ''; echo $?)"
eq "tmux: no client binary is not a mismatch"           "1" "$(_tmux_mismatch '' /usr/local/bin/tmux; echo $?)"
eq "tmux: reachability is probed without needing a client" "0" \
   "$( ( tmux() { case "$1" in list-sessions) return 0 ;; *) return 1 ;; esac; }; _tmux_reachable; echo $? ) )"
eq "tmux: an unreachable server is still unreachable" "1" \
   "$( ( tmux() { return 1; }; _tmux_reachable; echo $? ) )"
eq "tmux: the server pid is read without needing a client" "4242" \
   "$( ( tmux() { case "$1" in list-sessions) printf '4242\n4242\n' ;; *) return 1 ;; esac; }; _tmux_server_pid ) )"
_tmm=$(_tmux_mismatch_text /usr/bin/tmux 'tmux 3.4' /usr/local/bin/tmux)
has_txt "the mismatch text names the PATH binary"   "$_tmm" '/usr/bin/tmux (tmux 3.4)'
has_txt "the mismatch text names the server binary" "$_tmm" '/usr/local/bin/tmux'
has_txt "the mismatch text names the misleading symptom" "$_tmm" 'server exited unexpectedly'

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

ENTRY="$HERE/../plugins/overseer/skills/overseer/scripts/overseer"
README="$HERE/../README.md"
SKILL="$HERE/../plugins/overseer/skills/overseer/SKILL.md"

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

WINLIB="$HERE/../plugins/overseer/skills/overseer/scripts/lib/windows.sh"
_win_verbs_dispatch() { sed -nE 's/^[[:space:]]+([a-z]+)\)[[:space:]]+_win_.*/\1/p' "$WINLIB" | sort -u; }
_win_verbs_help()     { bash "$ENTRY" --help 2>/dev/null | sed -nE 's/^[[:space:]]+win verbs:[[:space:]]*(.*)/\1/p' | tr ' ' '\n' | sed '/^$/d' | sort -u; }
eq "win dispatcher verbs are non-empty" "yes" "$([ -n "$(_win_verbs_dispatch)" ] && echo yes || echo no)"
eq "help win verbs match the cmd_win dispatcher" "" \
   "$(comm -3 <(_win_verbs_dispatch) <(_win_verbs_help) | tr -d '\t' | tr '\n' ' ' | sed 's/ *$//')"

CMDLIB="$HERE/../plugins/overseer/skills/overseer/scripts/lib/commands.sh"
_fleet_acts_dispatch() { sed -nE '/^_fleet_local\(\)/,/^\}/ s/^[[:space:]]{4}([a-z|]+)\).*/\1/p' "$CMDLIB" | tr '|' '\n' | sed '/^\*$/d;/^$/d' | sort -u; }
_fleet_acts_help()     { bash "$ENTRY" --help 2>/dev/null | sed -nE 's/^  fleet .*\[(status\|.*)\] \[args\].*/\1/p' | head -1 | sed -E 's/\[[^]]*\]//g' | tr '|' '\n' | sed -E 's/^ +| +$//g' | sed '/^$/d' | sort -u; }
eq "fleet dispatcher actions are non-empty" "yes" "$([ -n "$(_fleet_acts_dispatch)" ] && echo yes || echo no)"
eq "help fleet actions match the _fleet_local dispatcher" "" \
   "$(comm -3 <(_fleet_acts_dispatch) <(_fleet_acts_help) | tr -d '\t' | tr '\n' ' ' | sed 's/ *$//')"

WINDOC="$HERE/../docs/WINDOWS.md"
SECDOC="$HERE/../SECURITY.md"
CONTRIB="$HERE/../CONTRIBUTING.md"
PRTPL="$HERE/../.github/pull_request_template.md"

_has() { grep -qF "$2" "$1" && echo yes || echo no; }
_hasre() { grep -qE "$2" "$1" && echo yes || echo no; }

eq "README states the Linux controller / Windows target support model" "yes" "$(_hasre "$README" '^## Support model')"
eq "SKILL frontmatter has the Codex-required name" "yes" "$(sed -n '/^---$/,/^---$/p' "$SKILL" | grep -qF 'name: overseer' && echo yes || echo no)"
eq "SKILL frontmatter names the Windows broker commands" "yes" "$(sed -n '/^---$/,/^---$/p' "$SKILL" | grep -qE 'win HOST.*(start|chat)' && echo yes || echo no)"
eq "SKILL resolves one portable runner" "yes" "$(_has "$SKILL" 'bash "$OVERSEER_BIN" <command> [args]')"
eq "SKILL assigns OVERSEER_BIN from the Claude plugin root" "yes" \
   "$(_has "$SKILL" 'OVERSEER_BIN="${CLAUDE_PLUGIN_ROOT}/skills/overseer/scripts/overseer"')"
eq "SKILL tells Codex where to get the same absolute path" "yes" "$(_hasre "$SKILL" 'absolute path of')"

_md_blocks_using_bin_without_assigning() {
  awk '
    /^```/ { inb = !inb; if (inb) { buf = "" } else if (buf ~ /bash "\$OVERSEER_BIN"/ && buf !~ /OVERSEER_BIN=/) n++; next }
    inb { buf = buf $0 "\n" }
    END { print n + 0 }
  ' "$1"
}
eq "every SKILL code block calling OVERSEER_BIN assigns it first" "0" "$(_md_blocks_using_bin_without_assigning "$SKILL")"

_md_links_unreachable_from_an_install() {
  local pkg base link target n=0
  base=$(dirname "$1")
  pkg=$(cd "$base/../.." && pwd)
  for link in $(grep -oE '\]\([^)[:space:]]+\)' "$1" | sed -E 's/^\]\(//; s/\)$//'); do
    case "$link" in
      http://*|https://*|'#'*) continue ;;
    esac
    target=$(cd "$base" 2>/dev/null && realpath -m "${link%%#*}") || { n=$((n + 1)); continue; }
    case "$target" in
      "$pkg"/*) [ -e "$target" ] || n=$((n + 1)) ;;
      *) n=$((n + 1)) ;;
    esac
  done
  printf '%s' "$n"
}
eq "every SKILL link is absolute or inside the plugin package" "0" "$(_md_links_unreachable_from_an_install "$SKILL")"
eq "SKILL scope section covers both target kinds" "yes" "$(_hasre "$SKILL" '^## Scope: what runs where')"
for v in OVERSEER_REMOTE_DIR OVERSEER_REMOTE_BIN OVERSEER_NO_AUTODEPLOY OVERSEER_SSH OVERSEER_SSH_OPTS OVERSEER_SCP OVERSEER_WIN_CLAUDE OVERSEER_WIN_CODEX OVERSEER_TIMEOUT OVERSEER_POLL_INTERVAL; do
  eq "README documents $v" "yes" "$(_has "$README" "$v")"
done

ENTRYLIB="$HERE/../plugins/overseer/skills/overseer/scripts/lib"
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

AE="$FIX/claude-api-error.jsonl"
eq "claude: a synthetic API-error record still ENDS the turn"   "1" "$(_turn_count "$AE")"
eq "claude: the API error is reported, not handed back as a reply" \
   "429	API Error: Claude usage limit reached. Your limit will reset at 3pm." "$(_last_api_error "$AE")"
eq "claude: a normal turn reports no API error"                 ""  "$(_last_api_error "$C")"
eq "claude: last_reply alone would leak the error text as an answer" "yes" \
   "$(case "$(_last_reply "$AE")" in *'API Error'*) echo yes ;; *) echo no ;; esac)"

CQ="$FIX/codex-quota.jsonl"
eq "codex: a turn stopped by a usage limit is reported"         "429	codex stopped on a usage limit (rate_limit_reached)" "$(_cx_last_api_error "$CQ")"
eq "codex: a turn that produced a reply is not a quota failure" ""  "$(_cx_last_api_error "$FIX/codex-turn.jsonl")"
eq "codex: the rate-limit snapshot is the newest one"           "100.0" "$(_cx_rate_limits "$CQ" | jq -r '.primary.used_percent')"
eq "harness seam dispatches the error read"                     "429	codex stopped on a usage limit (rate_limit_reached)" "$(_h_last_error codex "$CQ")"

# shellcheck disable=SC2034
QUOTA_WARN=90
QAPI=$(cat "$FIX/claude-quota-api.json")
eq "usage: claude rows come from limits[], one per window, severity carried" \
   $'session\t18\t4102484400\tnormal\nweekly_all\t99\t4102603200\tcritical\nweekly_scoped:Fable\t16\t4102603200\tnormal' \
   "$(_usage_rows_claude "$QAPI" | _rows_epoch)"
eq "usage: a scoped window keeps the model it applies to" "weekly_scoped:Fable" \
   "$(_usage_rows_claude "$QAPI" | sed -n '3p' | cut -f1)"
eq "usage: an empty body yields no rows (nothing to report, not a crash)" "" "$(_usage_rows_claude '')"
eq "usage: codex rows humanise the rolling window" $'7d\t100.0\t4102444800\tnormal' "$(_usage_rows_codex "$CQ")"
eq "usage: context is read apart from quota, never mixed in" "168569/258400" "$(_ctx_tokens codex "$CQ")"
eq "usage: the claude context read is a plain token count" "0" "$(_ctx_tokens claude "$C")"

CROWS=$(_usage_rows_claude "$QAPI" | _rows_epoch)
eq "usage: the server severity flags a window even under the threshold" "weekly_all	99" "$(_quota_breached "$CROWS")"
eq "usage: a normal window under the threshold is not a breach" "" \
   "$(_quota_breached "$(printf 'session\t18\t0\tnormal\n')" || true)"
eq "usage: a normal window at the threshold is a breach"  "session	90" \
   "$(_quota_breached "$(printf 'session\t90\t0\tnormal\n')")"
eq "usage: a flagged window is marked in the printed row" "yes" \
   "$(case "$(_quota_rows_print "$CROWS")" in *'weekly_all'*'<-- CRITICAL'*) echo yes ;; *) echo no ;; esac)"
eq "usage: an unflagged window prints without a marker" "no" \
   "$(case "$(_quota_rows_print "$CROWS" | grep 'quota session')" in *'<--'*) echo yes ;; *) echo no ;; esac)"
eq "usage: every window prints its reset time" "3" "$(_quota_rows_print "$CROWS" | grep -c 'resets in')"

eq "epoch: an ISO8601 reset converts"          "4102484400" "$(_epoch_of '2100-01-01T11:00:00.316052+00:00')"
eq "epoch: a unix reset passes through"        "1785819010" "$(_epoch_of 1785819010)"
eq "epoch: an absent reset is zero"            "0"          "$(_epoch_of '')"
eq "epoch: an unparseable reset is zero"       "0"          "$(_epoch_of 'not a date')"
eq "pct threshold: 89 is under 90"  ""    "$(_pct_bad 89 && echo bad)"
eq "pct threshold: 90 is at the limit" "bad" "$(_pct_bad 90 && echo bad)"
eq "pct threshold: a float percent still compares" "bad" "$(_pct_bad 99.5 && echo bad)"
eq "pct threshold: a missing percent is not a breach" "" "$(_pct_bad '' && echo bad)"
eq "quota unavailable: no credentials reads as a third-party backend" "yes" \
   "$(case "$(_quota_why 2)" in *'third-party backend'*) echo yes ;; *) echo no ;; esac)"
eq "quota unavailable: an expired token says overseer cannot refresh it" "yes" \
   "$(case "$(_quota_why 3)" in *'cannot refresh'*) echo yes ;; *) echo no ;; esac)"
eq "quota unavailable: anything else names the endpoint" "yes" \
   "$(case "$(_quota_why 7)" in *'/api/oauth/usage'*) echo yes ;; *) echo no ;; esac)"
eq "quota: the cache lives outside CLAUDE_HOME" "no" \
   "$(case "$(_quota_cache)" in "$CLAUDE_HOME"*) echo yes ;; *) echo no ;; esac)"
eq "quota: the token is read from the claude credentials file" "yes" \
   "$(case "$(_creds_file)" in *'/.credentials.json') echo yes ;; *) echo no ;; esac)"

_rc_err() { ( _die() { exit 9; }; _die_code() { exit "$1"; }; _report_error_text "$1" tgt >/dev/null 2>&1 ); printf '%s' "$?"; }
eq "a usage-limit turn exits 5"                  "5" "$(_rc_err "$(printf '429\tAPI Error: Claude usage limit reached. Your limit will reset at 3pm.')")"
eq "a codex usage limit exits 5 too"             "5" "$(_rc_err "$(_cx_last_api_error "$CQ")")"
eq "a transient overload exits 9 (plain _die)"   "9" "$(_rc_err "$(printf '529\tAPI Error: 529 Overloaded. Try again in a moment.')")"
eq "no error at all neither dies nor exits 5"    "1" "$(_rc_err '')"
eq "the seam+reporter agree on the fixture"      "5" "$(_rc_err "$(_h_last_error claude "$AE")")"

_quotaw() { OVERSEER_QUOTA_WARN="$1" bash "$ENTRY" --help >/dev/null 2>&1 && echo ok || echo rejected; }
for good in 1 50 90 100; do
  eq "quota warn '$good' is accepted" "ok" "$(_quotaw "$good")"
done
eq "quota warn empty falls back to the default" "ok" "$(_quotaw '')"
for bad in 0 101 -1 abc 9.5; do
  eq "quota warn '$bad' is rejected" "rejected" "$(_quotaw "$bad")"
done
_quotattl() { OVERSEER_QUOTA_TTL="$1" bash "$ENTRY" --help >/dev/null 2>&1 && echo ok || echo rejected; }
for good in 1 60 300 86400; do
  eq "quota ttl '$good' is accepted" "ok" "$(_quotattl "$good")"
done
eq "quota ttl empty falls back to the default" "ok" "$(_quotattl '')"
for bad in 0 -1 abc 1.5; do
  eq "quota ttl '$bad' is rejected" "rejected" "$(_quotattl "$bad")"
done
eq "README documents OVERSEER_QUOTA_WARN" "yes" "$(_has "$README" 'OVERSEER_QUOTA_WARN')"
eq "README documents OVERSEER_QUOTA_TTL" "yes" "$(_has "$README" 'OVERSEER_QUOTA_TTL')"
eq "README names the endpoint usage reads" "yes" "$(_has "$README" '/api/oauth/usage')"
eq "SECURITY documents the credentials read" "yes" "$(_has "$SECDOC" '.credentials.json')"
eq "help says no claude config is touched" "yes" "$(bash "$ENTRY" --help 2>/dev/null | grep -q 'no claude config is touched' && echo yes || echo no)"
eq "README explains that context auto-compacts and quota is the real limit" "yes" "$(_hasre "$README" 'auto-compact')"
eq "the quota exit code is documented in help" "yes" "$(bash "$ENTRY" --help 2>/dev/null | grep -q 'EXIT CODE 5' && echo yes || echo no)"

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
