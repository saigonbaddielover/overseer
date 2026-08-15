# shellcheck shell=bash

# count of assistant messages that ENDED a turn (stop_reason present and not tool_use).
# a turn = zero or more tool_use messages then exactly one terminal message, so this counts turns.
_ended_ids() {
  jq -r 'select(.type=="assistant" and .message.stop_reason!=null and .message.stop_reason!="tool_use")
         | .message.id // "rec-\(input_line_number)"' 2>/dev/null | awk '!seen[$0]++'
}
_turn_count() {
  local n; n=$(_ended_ids <"$1" | wc -l)
  echo "${n:-0}"
}
_last_stop() { jq -r 'select(.type=="assistant") | .message.stop_reason // empty' "$1" 2>/dev/null | tail -1; }
# busy = the last turn ended in a tool_use (the session is mid-turn, running a tool). arg: jsonl.
_is_busy() { [ "$(_last_stop "$1")" = tool_use ]; }
_running_claude() {
  [ "$(jq -rn 'reduce inputs as $e (false;
    if ($e.type=="user" and ($e.origin.kind? == "human") and (($e.message.content|type)=="string")) then true
    elif ($e.type=="assistant" and (($e.message.stop_reason // "") as $s | $s != "" and $s != "tool_use")) then false
    else . end)' "$1" 2>/dev/null)" = true ]
}
_last_prompt() {
  local jl="$1" p
  p=$(jq -rn 'last(inputs | select(.type=="user" and (.origin.kind? == "human") and (.message.content|type=="string")) | .message.content) // empty' "$jl" 2>/dev/null)
  if [ -z "$p" ] || [ "$p" = null ]; then
    p=$(jq -rn 'last(inputs | select(.type=="last-prompt") | .lastPrompt) // empty' "$jl" 2>/dev/null)
  fi
  printf '%s' "$p"
}
_last_reply() {
  jq -rn 'last(inputs | select(.type=="assistant") | (.message.content // []) as $c | select($c | map(.type) | index("text")) | ($c | map(select(.type=="text") | .text) | join("\n"))) // ""' "$1" 2>/dev/null
}
_reply_for_prompt() {
  jq -rn --arg want "$(_trim "${2:-}")" 'reduce inputs as $e ({armed:false, reply:null};
    if ($e.type=="user" and ($e.origin.kind? == "human") and (($e.message.content|type)=="string"))
      then (if ($want=="" or (($e.message.content|gsub("^\\s+|\\s+$";"")) == $want)) then {armed:true, reply:null} else .armed=false end)
    elif ($e.type=="assistant"
          and (($e.message.stop_reason // "") as $s | $s != "" and $s != "tool_use")
          and (($e.message.content // []) | map(.type) | index("text")))
      then (if (.armed and .reply==null)
            then .reply = (($e.message.content) | map(select(.type=="text") | .text) | join("\n"))
            else . end)
    else . end) | .reply // ""' "$1" 2>/dev/null
}
_answered() {
  [ "$(jq -rn --arg want "$(_trim "${2:-}")" 'reduce inputs as $e ({armed:false, done:false};
    if ($e.type=="user" and ($e.origin.kind? == "human") and (($e.message.content|type)=="string"))
      then (if ($want=="" or (($e.message.content|gsub("^\\s+|\\s+$";"")) == $want)) then {armed:true, done:false} else .armed=false end)
    elif ($e.type=="assistant" and (($e.message.stop_reason // "") as $s | $s != "" and $s != "tool_use"))
      then (if .armed then .done=true else . end)
    else . end) | .done' "$1" 2>/dev/null)" = true ]
}
_last_api_error() {
  jq -rn 'last(inputs | select(.type=="assistant")
      | select((.message.stop_reason // "") != "" and (.message.stop_reason // "") != "tool_use")
      | { e: (.isApiErrorMessage == true), s: (.apiErrorStatus // 0),
          t: ((.message.content // []) | map(select(.type=="text") | .text) | join("\n")) })
    | if .e then "\(.s)\t\(.t)" else "" end' "$1" 2>/dev/null
}
_cl_queued() {
  jq -rn '[inputs | select(.type=="queue-operation")]
    | reduce .[] as $o ([];
        if $o.operation == "enqueue" then . + [$o.content // ""]
        elif $o.operation == "popAll" then []
        else (if length > 0 then .[1:] else . end) end)
    | .[]' "$1" 2>/dev/null
}
_cl_queue_op() { jq -rn 'last(inputs | select(.type=="queue-operation") | .operation) // ""' "$1" 2>/dev/null; }
_sid_from_jsonl() { jq -r 'select(.sessionId != null and .sessionId != "") | .sessionId' "$1" 2>/dev/null | head -1; }
# ---- Codex rollout readers (~/.codex/sessions/**/rollout-*.jsonl) ----------
# a Codex turn is an `event_msg` task_started ... task_complete pair; task_complete even carries the
# reply verbatim as last_agent_message. so turns = completed count, busy = a start with no matching
# complete, reply = the last complete's message, prompt = the last real user input_text (skip the
# injected AGENTS.md `#...` / `<environment_context>` wrappers, like the claude reader does).
_cx_turn_count() { local n; n=$(jq -c 'select(.type=="event_msg" and .payload.type=="task_complete")' "$1" 2>/dev/null | wc -l); echo "${n:-0}"; }
_cx_sid_from_rollout() {
  local b="${1##*/}"
  b="${b%.jsonl}"; b="${b##*T[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-}"
  case "$b" in
    [0-9a-f]*-[0-9a-f]*-[0-9a-f]*-[0-9a-f]*-[0-9a-f]*) printf '%s' "$b" ;;
  esac
  return 0
}
_cx_is_busy() {
  local counts st ct ab
  counts=$(jq -rn 'reduce inputs as $e ([0,0,0];
    if $e.type=="event_msg" then ($e.payload.type) as $t |
      if $t=="task_started" then .[0]+=1
      elif $t=="task_complete" then .[1]+=1
      elif $t=="turn_aborted" then .[2]+=1 else . end
    else . end) | "\(.[0]) \(.[1]) \(.[2])"' "$1" 2>/dev/null || true)
  read -r st ct ab <<< "$counts" || true
  [ "${st:-0}" -gt "$(( ${ct:-0} + ${ab:-0} ))" ]
}
_cx_last_reply() { jq -rn 'last(inputs | select(.type=="event_msg" and .payload.type=="task_complete") | .payload.last_agent_message // empty) // ""' "$1" 2>/dev/null; }
_cx_reply_for_prompt() {
  jq -rn --arg want "$(_trim "${2:-}")" 'reduce inputs as $e ({armed:false, reply:null};
    if ($e.type=="event_msg" and $e.payload.type=="user_message")
      then (if ($want=="" or (($e.payload.message|gsub("^\\s+|\\s+$";"")) == $want)) then {armed:true, reply:null} else .armed=false end)
    elif ($e.type=="event_msg" and $e.payload.type=="task_complete" and (($e.payload.last_agent_message // "") != ""))
      then (if (.armed and .reply==null) then .reply = $e.payload.last_agent_message else . end)
    else . end) | .reply // ""' "$1" 2>/dev/null
}
_cx_answered() {
  [ "$(jq -rn --arg want "$(_trim "${2:-}")" 'reduce inputs as $e ({armed:false, done:false};
    if ($e.type=="event_msg" and $e.payload.type=="user_message")
      then (if ($want=="" or (($e.payload.message|gsub("^\\s+|\\s+$";"")) == $want)) then {armed:true, done:false} else .armed=false end)
    elif ($e.type=="event_msg" and $e.payload.type=="task_complete")
      then (if .armed then .done=true else . end)
    else . end) | .done' "$1" 2>/dev/null)" = true ]
}
_cx_last_prompt() {
  local p
  p=$(jq -rn 'last(inputs | select(.type=="event_msg" and .payload.type=="user_message") | .payload.message) // empty' "$1" 2>/dev/null)
  if [ -z "$p" ] || [ "$p" = null ]; then
    p=$(jq -rn 'last(inputs | select(.type=="response_item" and .payload.type=="message" and .payload.role=="user")
           | .payload.content[]? | select(.type=="input_text") | .text
           | select(test("^\\s*[<#{]")|not)) // empty' "$1" 2>/dev/null)
  fi
  printf '%s' "$p"
}
_cx_rate_limits() {
  jq -cn 'last(inputs | select(.type=="event_msg" and .payload.type=="token_count") | .payload.rate_limits // empty) // {}' "$1" 2>/dev/null
}
_cx_token_info() {
  jq -cn 'last(inputs | select(.type=="event_msg" and .payload.type=="token_count") | .payload.info // empty) // {}' "$1" 2>/dev/null
}
_cx_last_api_error() {
  local reached
  reached=$(_cx_rate_limits "$1" | jq -r '.rate_limit_reached_type // empty' 2>/dev/null)
  [ -n "$reached" ] || return 0
  [ -n "$(_cx_last_reply "$1")" ] && return 0
  printf '429\tcodex stopped on a usage limit (%s)' "$reached"
}
# ---- harness-dispatched reads (kind, transcript_path) ----------------------
_h_turn_count() { case "$1" in claude) _turn_count "$2" ;; codex) _cx_turn_count "$2" ;; esac; }
_h_is_busy()    { case "$1" in claude) _is_busy "$2" ;;    codex) _cx_is_busy "$2" ;;    esac; }
_h_running()    { case "$1" in claude) _running_claude "$2" ;; codex) _cx_is_busy "$2" ;; esac; }
_h_last_reply() { case "$1" in claude) _last_reply "$2" ;; codex) _cx_last_reply "$2" ;; esac; }
_h_reply_for()  { case "$1" in claude) _reply_for_prompt "$2" "$3" ;; codex) _cx_reply_for_prompt "$2" "$3" ;; esac; }
_h_answered()   { case "$1" in claude) _answered "$2" "$3" ;; codex) _cx_answered "$2" "$3" ;; esac; }
_h_last_prompt(){ case "$1" in claude) _last_prompt "$2" ;; codex) _cx_last_prompt "$2" ;; esac; }
_h_last_error() { case "$1" in claude) _last_api_error "$2" ;; codex) _cx_last_api_error "$2" ;; esac; }
_h_sid()        { case "$1" in claude) _sid_from_jsonl "$2" ;; codex) _cx_sid_from_rollout "$2" ;; esac; return 0; }
_h_queued()     { case "$1" in claude) _cl_queued "$2" ;; codex) _cx_queued "$3" ;; esac; }
_h_unqueued()   { case "$1" in claude) [ "$(_cl_queue_op "$2")" = popAll ] ;; codex) [ -z "$(_cx_queued "$3")" ] ;; esac; }
_h_steering()   { case "$1" in claude) return 1 ;; codex) _cx_steering "$3" ;; esac; }
_h_popkey()     { case "$1" in claude) printf 'Up' ;; codex) printf 'S-Left' ;; esac; }
_h_intkey()     { case "$1" in claude|codex) printf 'Escape' ;; esac; }
_win_intkey()   { case "$1" in claude) printf 'C-c' ;; codex) printf 'Escape' ;; esac; }
_file_sig() { stat -c '%Y:%s' "$1" 2>/dev/null || true; }
_marker_since() {
  local f="$CLAUDE_HOME/$1/$2" m
  [ -f "$f" ] || return 1
  m=$(stat -c %Y "$f" 2>/dev/null) || return 1
  [ "$m" -ge "$3" ]
}
_fsize() { stat -c %s "$1" 2>/dev/null || echo 0; }
_turns_after() {
  local kind="$1" path="$2" off="$3"
  case "$kind" in
    claude) tail -c "+$((off + 1))" "$path" 2>/dev/null | _ended_ids | wc -l ;;
    codex)  tail -c "+$((off + 1))" "$path" 2>/dev/null | jq -c 'select(.type=="event_msg" and .payload.type=="task_complete")' 2>/dev/null | wc -l ;;
  esac
}
# a turn-done signal for this session at or after `since`: the Stop hook touches
# ~/.claude/turn-done/<session_id> at each turn end, so its mtime is the last turn-end time.
_signal_since() {   # sid since_epoch
  _marker_since turn-done "$1" "$2"
}
_turn_advanced() {   # kind path base bbytes
  if [ -n "$4" ]; then [ "$(_turns_after "$1" "$2" "$4")" -gt 0 ]
  else [ "$(_h_turn_count "$1" "$2")" -gt "$3" ]; fi
}
# block until the turn started by our send has ended, i.e. the turn count passes the baseline.
# claude: prefer the Stop-hook signal (event-driven, ~0.25s), fall back to polling the transcript
# every ~2s so a session the hook does not cover still resolves. codex: no hook, so poll the rollout
# every tick. args: kind, transcript_path, baseline_turn_count, timeout_s, [claude sid], [since_epoch].
_wait_reply() {
  local kind="$1" path="$2" base="$3" timeout="${4:-600}" sid="${5:-}" since="${6:-0}" pane="${7:-}" bbytes="${8:-}" i=0 woke=0 cur quiet=0 st lastst='' seen=0
  local deadline=$((SECONDS + timeout)) sig last=''
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$woke" = 0 ] && [ -n "$sid" ] && _signal_since "$sid" "$since" && woke=1
    # the signal only says "look now"; correctness is the transcript actually showing the new turn,
    # so a reply is never read before it is flushed. codex has no signal -> check every tick.
    sig=$(_file_sig "$path")
    if { [ "$woke" = 1 ] || [ "$kind" = codex ] || [ $((i % 8)) -eq 0 ]; } && [ "$sig" != "$last" ]; then
      last="$sig"
      _turn_advanced "$kind" "$path" "$base" "$bbytes" && return 0
      if [ "$kind" = codex ]; then
        if _h_running "$kind" "$path"; then seen=1
        elif [ "$seen" = 1 ]; then return 4; fi
      fi
    fi
    if [ -n "$pane" ] && { { [ "$i" -gt 0 ] && [ $((i % 4)) -eq 0 ]; } || { [ "$kind" = claude ] && [ -n "$sid" ] && _marker_since awaiting "$sid" "$since"; }; } && _awaiting "$pane" >/dev/null 2>&1; then return 2; fi
    if [ -n "$pane" ] && [ "$i" -gt 0 ] && [ $((i % 8)) -eq 0 ]; then
      if ! cur=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null) || _is_shell "$cur"; then
        _turn_advanced "$kind" "$path" "$base" "$bbytes" && return 0
        return 3
      fi
      st=$(_screen_state "$pane")
      if [ "$st" != busy ] && [ "$st" = "$lastst" ] && [ "$kind" = claude ] && _h_running "$kind" "$path"; then
        quiet=$((quiet + 1)); [ "$quiet" -ge 4 ] && return 4
      else quiet=0; fi
      lastst="$st"
    fi
    i=$((i + 1)); _nap
  done
  return 1
}
_wait_queued_reply() {
  local kind="$1" path="$2" timeout="${3:-600}" pane="$4" msg="$5" i=0 cur sig last='' quiet=0 st lastst='' seen=0
  local deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -n "$pane" ]; then
      _awaiting "$pane" >/dev/null 2>&1 && return 2
      if [ "$i" -gt 0 ] && [ $((i % 8)) -eq 0 ]; then
        if ! cur=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null) || _is_shell "$cur"; then
          _h_answered "$kind" "$path" "$msg" && return 0
          return 3
        fi
        st=$(_screen_state "$pane")
        if [ "$st" != busy ] && [ "$st" = "$lastst" ] && [ "$kind" = claude ] && _h_running "$kind" "$path"; then
          quiet=$((quiet + 1)); [ "$quiet" -ge 4 ] && return 4
        else quiet=0; fi
        lastst="$st"
      fi
    fi
    sig=$(_file_sig "$path")
    if [ "$sig" != "$last" ]; then
      last="$sig"
      _h_answered "$kind" "$path" "$msg" && return 0
      if [ "$kind" = codex ]; then
        if _h_running "$kind" "$path"; then seen=1
        elif [ "$seen" = 1 ]; then return 4; fi
      fi
    fi
    i=$((i + 1)); _nap
  done
  return 1
}
_wait_drained() {
  local kind="$1" path="$2" timeout="${3:-600}" pane="$4" i=0 cur sig last='' stable=0 running=1 quiet=0 st lastst=''
  local deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -n "$pane" ]; then
      _awaiting "$pane" >/dev/null 2>&1 && return 2
      if [ "$i" -gt 0 ] && [ $((i % 8)) -eq 0 ]; then
        if ! cur=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null) || _is_shell "$cur"; then
          _h_running "$kind" "$path" || return 0
          return 3
        fi
        st=$(_screen_state "$pane")
        if [ "$st" != busy ] && [ "$st" = "$lastst" ] && [ "$running" = 1 ] && [ "$kind" = claude ]; then
          quiet=$((quiet + 1)); [ "$quiet" -ge 4 ] && return 0
        else quiet=0; fi
        lastst="$st"
      fi
    fi
    sig=$(_file_sig "$path")
    if [ "$sig" != "$last" ]; then last="$sig"; if _h_running "$kind" "$path"; then running=1; else running=0; fi; fi
    if [ "$running" = 0 ] && ! _queued "$pane"; then
      stable=$((stable + 1)); [ "$stable" -ge 3 ] && return 0
    else stable=0; fi
    i=$((i + 1)); _nap
  done
  return 1
}
_wait_started() {
  local target="$1" kind="$2" path="$3" base="${4:-0}" timeout="${5:-10}" pane="${6:-}" sid="${7:-}" since="${8:-0}" bbytes="${9:-}" pre_busy="${10:-0}" ctx
  local deadline=$((SECONDS + timeout)) sig last=''
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -n "$pane" ] && _queued "$pane" && { printf '%s' "$path"; return 5; }
    [ -n "$sid" ] && _marker_since turn-started "$sid" "$since" && { printf '%s' "$path"; return 0; }
    if [ -z "$path" ] || [ ! -f "$path" ]; then
      ctx=$(_target_ctx "$target" 2>/dev/null) && IFS=$'\t' read -r _ _ path <<< "$ctx" || true
    fi
    if [ -n "$path" ] && [ -f "$path" ]; then
      sig=$(_file_sig "$path")
      if [ "$sig" != "$last" ]; then
        last="$sig"
        [ "$pre_busy" != 1 ] && _h_is_busy "$kind" "$path" && { printf '%s' "$path"; return 0; }
        if [ -n "$bbytes" ]; then [ "$(_turns_after "$kind" "$path" "$bbytes")" -gt 0 ] && { printf '%s' "$path"; return 0; }
        else [ "$(_h_turn_count "$kind" "$path")" -gt "$base" ] && { printf '%s' "$path"; return 0; }; fi
      fi
    fi
    [ -n "$pane" ] && _awaiting "$pane" >/dev/null 2>&1 && { printf '%s' "$path"; return 2; }
    [ -n "$pane" ] && _compacting "$pane" && { printf '%s' "$path"; return 4; }
    _nap
  done
  printf '%s' "$path"; return 1
}
_newest_with_turns() {
  local kind="$1" f
  case "$kind" in
    claude) while IFS= read -r f; do [ -n "$f" ] && [ "$(_turn_count "$f")" -gt 0 ] && { printf '%s' "$f"; return 0; }; done < <(ls -t "$CLAUDE_HOME"/projects/*/*.jsonl 2>/dev/null | head -20) ;;
    codex)  while IFS= read -r f; do [ -n "$f" ] && [ "$(_cx_turn_count "$f")" -gt 0 ] && { printf '%s' "$f"; return 0; }; done < <(ls -t "$CODEX_HOME"/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -20) ;;
  esac
  return 1
}
_probe_contract() {
  local kind="$1" jl
  jl=$(_newest_with_turns "$kind") || return 2
  [ -n "$jl" ] || return 2
  printf '%s' "$jl"
  [ -n "$(_h_last_reply "$kind" "$jl")" ] || return 1
}
