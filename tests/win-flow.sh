#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LIB="$HERE/../overseer/skills/overseer/scripts/lib"
FIX="$HERE/fixtures"
export CLAUDE_HOME="$HERE/.home" CODEX_HOME="$HERE/.home"
# shellcheck disable=SC2034
POLL_INTERVAL=0.01
# shellcheck disable=SC2034
DEFAULT_TIMEOUT=5
_die() { printf 'overseer: %s\n' "$1" >&2; exit 1; }
_uint() { :; }
_nap() { :; }

# shellcheck source=../overseer/skills/overseer/scripts/lib/transcript.sh
. "$LIB/transcript.sh"
# shellcheck source=../overseer/skills/overseer/scripts/lib/tui.sh
. "$LIB/tui.sh"
# shellcheck source=../overseer/skills/overseer/scripts/lib/discovery.sh
. "$LIB/discovery.sh"
# shellcheck source=../overseer/skills/overseer/scripts/lib/windows.sh
. "$LIB/windows.sh"

fail=0
eq() {
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"
    fail=$((fail + 1))
  fi
}
has()   { case "$2" in *"$3"*) eq "$1" yes yes ;; *) eq "$1" "contains '$3'" "$2" ;; esac; }
lacks() { case "$2" in *"$3"*) eq "$1" "no '$3'" "$2" ;; *) eq "$1" yes yes ;; esac; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/overseer-winflow.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

_mock() {
  MOCK_LOG="$TMP/calls"; : > "$MOCK_LOG"
  MOCK_KIND=claude MOCK_ALIVE=True MOCK_MTIME=100 MOCK_SIZE=200 MOCK_TX='C:/tx.jsonl'
  MOCK_FETCH_OK=1 MOCK_KEY_OK=1 MOCK_TXFILE="$FIX/claude-turn.jsonl"
  MOCK_SNAP='> hello'; MOCK_SNAP_MOVE=0; rm -f "$TMP/snapn"
  _WH=host _WP=overseer-broker
  _win_client() {
    printf '%s %s\n' "$1" "${2:-}" >> "$MOCK_LOG"
    case "$1" in
      stat) printf 'OK kind=%s alive=%s mtime=%s size=%s transcript=%s\n' \
              "$MOCK_KIND" "$MOCK_ALIVE" "$MOCK_MTIME" "$MOCK_SIZE" "$MOCK_TX" ;;
      snap) if [ "${MOCK_SNAP_MOVE:-0}" = 1 ]; then
              _sn=$(cat "$TMP/snapn" 2>/dev/null || echo 0); _sn=$((_sn + 1)); printf '%s' "$_sn" >"$TMP/snapn"
              printf '%s %s\n' "$MOCK_SNAP" "$_sn"
            else printf '%s\n' "$MOCK_SNAP"; fi ;;
      key)  [ "$MOCK_KEY_OK" = 1 ] || return 1; printf 'OK key\n' ;;
      *)    printf 'OK %s\n' "$1" ;;
    esac
  }
  _win_fetch() {
    printf 'fetch %s\n' "$2" >> "$MOCK_LOG"
    [ "$MOCK_FETCH_OK" = 1 ] || return 1
    cp "$MOCK_TXFILE" "$3"
  }
  _lock_pane()   { printf 'lock\n'   >> "$MOCK_LOG"; }
  _unlock_pane() { printf 'unlock\n' >> "$MOCK_LOG"; }
  _need() { :; }
}
calls() { cat "$TMP/calls" 2>/dev/null; }
cleared_after_paste() {
  awk '/^paste /{seen=1; found=0; next} seen && /^clear/{found=1} END{print (seen && found) ? "yes" : "no"}' "$TMP/calls"
}
_stat_only() {
  _win_client() {
    printf '%s\n' "$1" >> "$MOCK_LOG"
    case "$1" in
      stat) printf 'OK kind=claude alive=%s mtime=%s size=%s transcript=%s\n' \
              "$MOCK_ALIVE" "$MOCK_MTIME" "$MOCK_SIZE" "$MOCK_TX" ;;
      *) printf 'OK\n' ;;
    esac
  }
}

printf -- '-- win chat guards\n'

out=$( _mock; MOCK_FETCH_OK=0; cmd_win host chat --yes 'hello' 2>&1 )
has   "scp failure aborts win chat"           "$out" 'could not fetch the transcript'
has   "scp failure names the --force bypass"  "$out" '--force'
lacks "scp failure never submits"             "$(calls)" 'key '
lacks "scp failure never pastes"              "$(calls)" 'paste '
has   "scp failure releases the lock"         "$(calls)" 'unlock'

out=$( _mock; MOCK_FETCH_OK=0; cmd_win host chat --yes --force 'hello' 2>&1 )
has   "--force proceeds past a scp failure"   "$(calls)" 'key -Name Enter'

out=$( _mock; MOCK_TXFILE="$FIX/claude-busy.jsonl"; cmd_win host chat --yes 'hello' 2>&1 )
has   "mid-turn agent refuses the send"       "$out" 'looks mid-turn'
lacks "mid-turn refusal never submits"        "$(calls)" 'key '

out=$( _mock; MOCK_TXFILE="$FIX/claude-busy.jsonl"; cmd_win host chat --yes --force 'hello' 2>&1 )
has   "--force bypasses the mid-turn guard"   "$(calls)" 'key -Name Enter'

RTX="$FIX/claude-running-text.jsonl"
out=$( _mock; MOCK_TXFILE="$RTX"; MOCK_SNAP_MOVE=1; cmd_win host chat --yes 'hello' 2>&1 )
has   "a text-only turn with a moving screen is mid-turn"  "$out" 'looks mid-turn'
lacks "text-only mid-turn never submits"                   "$(calls)" 'key '

out=$( _mock; MOCK_TXFILE="$RTX"; MOCK_SNAP='✻ Booping… (1m 5s · thinking)'; cmd_win host chat --yes 'hello' 2>&1 )
has   "a text-only turn with a live spinner is mid-turn"   "$out" 'looks mid-turn'

out=$( _mock; MOCK_TXFILE="$RTX"; cmd_win host chat --yes 'hello' 2>&1 )
has   "an interrupted (frozen) agent is not blocked from receiving" "$(calls)" 'key -Name Enter'

out=$( _mock; MOCK_TXFILE="$RTX"; MOCK_SNAP_MOVE=1; cmd_win host wait 2>&1 )
lacks "win wait does not call a text-only turn idle"       "$out" 'idle'
has   "win wait keeps waiting on a text-only turn"         "$out" 'timeout after'

out=$( _mock; MOCK_TXFILE="$RTX"; cmd_win host wait 60 2>&1 )
has   "win wait reports an interrupted turn as idle"       "$out" 'idle'

out=$( _mock; MOCK_TXFILE="$RTX"; cmd_win host chat --yes --force 'hello' 60 2>&1 )
has   "win chat reports an interrupted turn, not a timeout" "$out" 'stopped without producing a reply'

out=$( _mock; MOCK_KIND=codex; MOCK_TXFILE="$FIX/codex-busy.jsonl"; cmd_win host wait 2>&1 )
lacks "codex on windows never uses the screen veto"        "$out" 'idle'

out=$( _mock; MOCK_KIND=pwsh; cmd_win host chat --yes 'hello' 2>&1 )
has   "win chat refuses a pwsh broker"        "$out" 'not an agent'
lacks "pwsh refusal never pastes"             "$(calls)" 'paste '

out=$( _mock; MOCK_ALIVE=False; cmd_win host chat --yes 'hello' 2>&1 )
has   "win chat refuses a dead child"         "$out" 'has exited'

out=$( _mock; MOCK_KIND=codex; cmd_win host chat --yes '!rm -rf /' 2>&1 )
has   "codex refuses a leading exclamation"   "$out" 'shell command'
lacks "codex refusal never pastes"            "$(calls)" 'paste '

printf -- '-- win chat cleanup\n'

out=$( _mock; MOCK_KEY_OK=0; cmd_win host chat --yes 'hello' 2>&1 )
has   "failed submit is reported"             "$out" 'could not submit'
has   "failed submit releases the lock"       "$(calls)" 'unlock'
( _mock; MOCK_KEY_OK=0; cmd_win host chat --yes 'hello' ) >/dev/null 2>&1
eq    "failed submit clears the box"          "yes" "$(cleared_after_paste)"

out=$( _mock; MOCK_SNAP='> something else entirely'; cmd_win host chat --yes 'hello' 2>&1 )
has   "unverified delivery aborts"            "$out" 'could not place/verify'
lacks "unverified delivery never submits"     "$(calls)" 'key '
( _mock; MOCK_SNAP='> something else entirely'; cmd_win host chat --yes 'hello' ) >/dev/null 2>&1
eq    "unverified delivery clears the box"    "yes" "$(cleared_after_paste)"

WRAPBOX=$(cat "$FIX/win-snap-wrapped-box.txt")
LONGP='Write a 1200-word essay on the history of the semicolon in English prose. Answer entirely from your own knowledge in one message: do NOT use any tool, do NOT read or write any file, do NOT run any command.'
out=$( _mock; MOCK_SNAP="$WRAPBOX"; cmd_win host chat --yes "$LONGP" 2>&1 )
lacks "a prompt wrapped across box lines verifies" "$out" 'could not place/verify'
has   "a wrapped prompt is submitted"              "$(calls)" 'key -Name Enter'

out=$( _mock; MOCK_SNAP="$WRAPBOX"; cmd_win host chat --yes "$LONGP and one more clause that never landed" 2>&1 )
has   "a partly-landed wrapped prompt aborts"      "$out" 'could not place/verify'
lacks "a partly-landed wrapped prompt never submits" "$(calls)" 'key '

printf -- '-- win send (fire-and-confirm, no reply wait)\n'

out=$( _mock; MOCK_KIND=pwsh; cmd_win host send --yes 'hello' 2>&1 )
has   "win send refuses a pwsh broker"        "$out" 'not an agent'
lacks "win send pwsh refusal never pastes"    "$(calls)" 'paste '

out=$( _mock; MOCK_TXFILE="$FIX/claude-busy.jsonl"; cmd_win host send --yes 'hello' 2>&1 )
has   "win send refuses a mid-turn agent"     "$out" 'looks mid-turn'
lacks "win send mid-turn never submits"       "$(calls)" 'key '

_mock; _stat_only; MOCK_TXFILE="$FIX/claude-busy.jsonl"; MOCK_MTIME=101; MOCK_SIZE=200
rc=0; _win_wait_started claude 0 '100:200' 3 "$TMP/tx" || rc=$?
eq  "win send confirms a started (busy) turn" "0" "$rc"

_mock; _stat_only; MOCK_ALIVE=False
rc=0; _win_wait_started claude 0 '1:1' 3 "$TMP/tx" || rc=$?
eq  "win send fails fast on a dead child"     "3" "$rc"

_mock; _stat_only
rc=0; _win_wait_started claude 0 '100:200' 1 "$TMP/tx" || rc=$?
eq  "win send keeps waiting on no change"     "1" "$rc"

printf -- '-- win slash / quit refuse a non-agent broker\n'

out=$( _mock; MOCK_KIND=pwsh; cmd_win host slash model 2>&1 )
has   "win slash refuses a pwsh broker"       "$out" 'not an agent'
lacks "win slash pwsh refusal never pastes"   "$(calls)" 'paste '

out=$( _mock; MOCK_KIND=pwsh; cmd_win host quit 2>&1 )
has   "win quit refuses a pwsh broker"        "$out" 'nothing to quit'

printf -- '-- an unreachable broker is reported, never silent\n'

_dead() { _mock; _win_client() { printf '%s %s\n' "$1" "${2:-}" >> "$MOCK_LOG"; printf 'ERR connect failed\n'; return 3; }; }
for c in "host/x sh 'echo hi' 5" "host/x chat --yes hi" "host/x wait 5" "host/x read" "host/x keys Enter"; do
  verb=$(printf '%s' "$c" | awk '{print $2}')
  out=$( _dead; eval "cmd_win $c" 2>&1 )
  has "win $verb reports an unreachable broker" "$out" 'did not answer'
  has "win $verb names the broker and host"     "$out" "on host"
done

printf -- '-- a tampered transcript path is refused before any fetch\n'

out=$( _mock; MOCK_TX='C:/Users/x/rollout-a & calc.jsonl'; cmd_win host/x read 2>&1 )
has   "win read refuses a metachar transcript path" "$out" 'unexpected transcript path'
lacks "win read never fetches a bad path"           "$(calls)" 'fetch '

out=$( _mock; MOCK_TX='C:/Users/x/rollout-a & calc.jsonl'; cmd_win host/x wait 5 2>&1 )
has   "win wait refuses a metachar transcript path" "$out" 'unexpected transcript path'

out=$( _mock; MOCK_TX='C:/Users/John Doe/.claude/projects/x/y.jsonl'; cmd_win host/x read 2>&1 )
has   "win read accepts a spaced-username path"     "$(calls)" 'fetch '

out=$( _mock; MOCK_KIND=shell; cmd_win host/x sh 'Get-Date' 5 2>&1 )
sh_payload=$(awk '/^sh -B64 /{print $3}' "$TMP/calls" | head -1 | base64 -d 2>/dev/null)
has "win sh resets LASTEXITCODE before the command" "$sh_payload" 'global:LASTEXITCODE = $null'
has "win sh still runs the command after the reset" "$sh_payload" '$null; Get-Date;'

out=$( _mock; MOCK_SNAP=$'Do you want to proceed?\n> 1. Yes\n  2. No'; cmd_win host chat --yes 'hello' 2>&1 )
has   "a blocking menu is named, not a generic failure" "$out" 'not sent'
has   "the blocking question itself is shown"           "$out" '1. Yes'
lacks "a blocking menu never submits"                   "$(calls)" 'key '

printf -- '-- transcript signature gating\n'

_mock; _stat_only; MOCK_MTIME=101; MOCK_SIZE=200
rc=0; _win_wait_turn claude 0 '100:200' 3 "$TMP/tx" || rc=$?
eq  "mtime-only change refetches and completes" "0" "$rc"
has "mtime-only change did fetch"               "$(calls)" 'fetch'

_mock; _stat_only
rc=0; _win_wait_turn claude 0 '100:200' 1 "$TMP/tx" || rc=$?
eq    "unchanged signature keeps waiting"     "1" "$rc"
lacks "unchanged signature never refetches"   "$(calls)" 'fetch'

_mock; _stat_only; MOCK_ALIVE=False
rc=0; _win_wait_turn claude 0 '1:1' 3 "$TMP/tx" || rc=$?
eq "a child that exits mid-turn fails fast"   "3" "$rc"

_mock; _stat_only; MOCK_TX=''; MOCK_MTIME=999
rc=0; _win_wait_turn claude 0 '100:200' 1 "$TMP/tx" || rc=$?
eq    "no transcript yet never refetches"     "1" "$rc"
lacks "no transcript yet did not fetch"       "$(calls)" 'fetch'

printf -- '-- console grid normalization\n'

NBSP=$(printf '\302\240')
raw=$(cat "$FIX/win-composer-nbsp.txt")
_mock
_win_client() { printf '%s\n' "$raw"; }
snap=$(_win_snap)
eq    "the grid reader strips U+00A0" "0" "$(printf '%s' "$snap" | grep -c "$NBSP")"
got=$(printf '%s\n' "$snap" | sed -nE 's/^[[:space:]]*[>❯›][[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' | tail -1)
eq    "an NBSP composer verifies against the sent text" "Reply with exactly: OVERSEER-OK" "$got"
got=$(printf '%s\n' "$raw" | sed -nE 's/^[[:space:]]*[>❯›][[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' | tail -1)
eq    "an unnormalized grid would not have verified" "yes" "$([ "$got" != 'Reply with exactly: OVERSEER-OK' ] && echo yes || echo no)"

printf -- '-- target parsing\n'

eq "bare host uses the default broker" "overseer-broker"     "$(_win_split host; printf '%s' "$_WP")"
eq "named broker maps to its pipe"     "overseer-broker-two" "$(_win_split host/two; printf '%s' "$_WP")"
eq "named broker keeps the host"       "host"                "$(_win_split host/two; printf '%s' "$_WH")"
out=$( _win_split 'host/../evil' 2>&1 ); rc=$?
eq  "a traversing broker name is refused"   "1" "$rc"
has "traversing name explains the rule"     "$out" 'letters, digits'
out=$( _win_split '/two' 2>&1 ); rc=$?
eq  "an empty host is refused"              "1" "$rc"

if [ "$fail" = 0 ]; then
  printf 'PASS: all windows flow tests\n'; exit 0
else
  printf 'FAIL: %s test(s) failed\n' "$fail"; exit 1
fi
