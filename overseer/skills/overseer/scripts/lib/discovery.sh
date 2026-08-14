# shellcheck shell=bash

: "${OVERSEER_OS:=$(uname -s 2>/dev/null || echo unknown)}"
_p_children() { case "$OVERSEER_OS" in Linux) cat /proc/"$1"/task/*/children 2>/dev/null ;; *) return 1 ;; esac; }
_p_comm()     { case "$OVERSEER_OS" in Linux) cat "/proc/$1/comm" 2>/dev/null ;; *) return 1 ;; esac; }
_p_cwd()      { case "$OVERSEER_OS" in Linux) readlink "/proc/$1/cwd" 2>/dev/null ;; *) return 1 ;; esac; }
_p_fds()      { local fd; case "$OVERSEER_OS" in Linux) for fd in /proc/"$1"/fd/*; do readlink "$fd" 2>/dev/null; done ;; *) return 1 ;; esac; }
# ---- pane discovery ---------------------------------------------------------
# For a pane shell pid, return the child pid that owns a ~/.claude/sessions/<pid>.json
_agent_pid() {
  local pane_pid="$1" c
  for c in "$pane_pid" $(_p_children "$pane_pid"); do
    [ -f "$CLAUDE_HOME/sessions/$c.json" ] || continue
    [ "$(_p_comm "$c")" = claude ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}
# every descendant pid of a pid (recursive /proc children walk), one per line.
_descendants() {
  local p="$1" c
  for c in $(_p_children "$p"); do
    printf '%s\n' "$c"; _descendants "$c"
  done
}
# Codex has no pid-named session file; instead the running codex process holds its rollout jsonl
# OPEN, so read it straight off /proc/<pid>/fd. codex sits a level below the pane's node launcher, so
# scan all descendants. echoes the rollout path (the transcript), returns 1 if the pane runs no codex.
_codex_rollout() {
  local pane_pid="$1" pid tgt
  for pid in "$pane_pid" $(_descendants "$pane_pid"); do
    while IFS= read -r tgt; do
      case "$tgt" in */.codex/sessions/*rollout-*.jsonl) printf '%s' "$tgt"; return 0 ;; esac
    done < <(_p_fds "$pid")
  done
  return 1
}
_codex_pid() {
  local pane_pid="$1" p
  for p in "$pane_pid" $(_descendants "$pane_pid"); do
    [ "$(_p_comm "$p")" = codex ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}
# which agent harness runs in a pane (by pane_pid): claude | codex, or return 1 for neither.
_harness_of() {
  _agent_pid "$1" >/dev/null 2>&1 && { printf claude; return 0; }
  _codex_pid "$1" >/dev/null 2>&1 && { printf codex; return 0; }
  return 1
}
_peer_field() {
  command -v jq >/dev/null 2>&1 || return 1
  jq -r --arg f "$2" '.[$f] // empty' "$CLAUDE_HOME/sessions/$1.json" 2>/dev/null
}
_peer_live() { [ -n "$1" ] && [ -S "$1" ]; }
_peer_name_of() {
  local apid name sock
  apid=$(_agent_pid "$1") || return 1
  name=$(_peer_field "$apid" name) || return 1
  sock=$(_peer_field "$apid" messagingSocketPath) || return 1
  [ -n "$name" ] && _peer_live "$sock" || return 1
  printf '%s' "$name"
}
_peer_name_any() {
  local apid name
  apid=$(_agent_pid "$1") || return 1
  name=$(_peer_field "$apid" name) || return 1
  [ -n "$name" ] || return 1
  printf '%s' "$name"
}
_peer_ambiguous() {
  _die "'$1' names more than one live claude session — target the one you mean by its pane id %N (see: overseer list)"
}
_peer_no_pane() {
  _die "'$1' is a live claude session with no tmux pane, so overseer cannot drive it — reach it on the harness peer channel with the SendMessage tool ({\"to\": \"$1\", ...}); see: overseer list"
}
_peer_unreachable() {
  _die "'$1' is a live claude session with no tmux pane AND no messagingSocketPath, so neither overseer nor the SendMessage tool can reach it — start it inside a tmux pane to make it drivable; see: overseer list"
}
_pane_by_peer_name() {
  local f pid name sock tgt hit='' n=0 nopane=0 nodrive=0
  command -v jq >/dev/null 2>&1 || return 1
  for f in "$CLAUDE_HOME"/sessions/*.json; do
    [ -f "$f" ] || continue
    pid=$(basename "$f" .json)
    _p_comm "$pid" >/dev/null 2>&1 || continue
    name=$(jq -r '.name // empty' "$f" 2>/dev/null) || continue
    [ "$name" = "$1" ] || continue
    sock=$(jq -r '.messagingSocketPath // empty' "$f" 2>/dev/null)
    tgt=$(jq -r '.tmux // empty' "$f" 2>/dev/null)
    if [ -z "$tgt" ]; then
      if _peer_live "$sock"; then nopane=$((nopane + 1)); else nodrive=$((nodrive + 1)); fi
      continue
    fi
    hit="${tgt##*.}"; n=$((n + 1))
  done
  [ "$n" -le 1 ] || return 2
  [ -n "$hit" ] && { printf '%s' "$hit"; return 0; }
  [ "$nopane" = 0 ] || return 3
  [ "$nodrive" = 0 ] || return 4
  return 1
}
_target_die() {
  local target="$1" generic="$2" rc=0
  _pane_by_peer_name "$target" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 2 ]; then _peer_ambiguous "$target"; fi
  if [ "$rc" = 3 ]; then _peer_no_pane "$target"; fi
  if [ "$rc" = 4 ]; then _peer_unreachable "$target"; fi
  _die "$generic"
}
_peer_sessions() {
  local f name sock cwd
  command -v jq >/dev/null 2>&1 || return 0
  for f in "$CLAUDE_HOME"/sessions/*.json; do
    [ -f "$f" ] || continue
    name=$(jq -r '.name // empty' "$f" 2>/dev/null) || continue
    [ -n "$name" ] || continue
    sock=$(jq -r '.messagingSocketPath // empty' "$f" 2>/dev/null)
    _peer_live "$sock" || continue
    cwd=$(jq -r '.cwd // empty' "$f" 2>/dev/null)
    printf '%s\t%s\n' "$name" "${cwd:-?}"
  done
}
_is_shell() {
  case "$1" in
    sh|bash|zsh|fish|dash|ksh|mksh|ash|tcsh|csh|nu|xonsh|elvish) return 0 ;;
    -sh|-bash|-zsh|-fish|-dash|-ksh|-mksh|-ash|-tcsh|-csh) return 0 ;;
    *) return 1 ;;
  esac
}
_is_posix_shell() {
  case "$1" in
    sh|bash|zsh|dash|ksh|mksh|ash) return 0 ;;
    -sh|-bash|-zsh|-dash|-ksh|-mksh|-ash) return 0 ;;
    *) return 1 ;;
  esac
}
_ok_session_name() { case "${1:-}" in ''|*[!A-Za-z0-9_-]*) return 1 ;; *) return 0 ;; esac; }
_hosts_parse() { awk '{sub(/#.*/, ""); if ($1 != "") print $1}'; }
_ssh_config_hosts() {
  awk 'tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i !~ /[*?!]/) print $i }'
}
_ssh_include_files() {
  local f="$1" base="$2" line g ff
  [ -r "$f" ] || return 0
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      [Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]]*)
        # shellcheck disable=SC2086
        set -- ${line#* }
        for g in "$@"; do
          case "$g" in
            /*) : ;;
            "~/"*) g="$HOME/${g#\~/}" ;;
            *) g="$base/$g" ;;
          esac
          # shellcheck disable=SC2086
          for ff in $g; do
            [ -f "$ff" ] || continue
            printf '%s\n' "$ff"; _ssh_include_files "$ff" "${ff%/*}"
          done
        done ;;
    esac
  done < "$f"
}
_ssh_config_files() {
  local main="$HOME/.ssh/config" sys="/etc/ssh/ssh_config"
  [ -r "$main" ] && { printf '%s\n' "$main"; _ssh_include_files "$main" "$HOME/.ssh"; }
  [ -r "$sys" ] && { printf '%s\n' "$sys"; _ssh_include_files "$sys" /etc/ssh; }
}
_ssh_config_aliases() {
  local f
  _ssh_config_files | while IFS= read -r f; do
    [ -r "$f" ] && _ssh_config_hosts < "$f"
  done | awk 'NF && !seen[$0]++'
}
_known_hosts_files() {
  printf '%s\n' "$HOME/.ssh/known_hosts" "$HOME/.ssh/known_hosts.old" "$HOME/.ssh/known_hosts2" /etc/ssh/ssh_known_hosts
}
_khost_present() {
  local name="$1" f
  command -v ssh-keygen >/dev/null 2>&1 || return 1
  while IFS= read -r f; do
    [ -r "$f" ] || continue
    ssh-keygen -F "$name" -f "$f" >/dev/null 2>&1 && return 0
  done < <(_known_hosts_files)
  return 1
}
_known_hosts_names() {
  local f
  while IFS= read -r f; do
    [ -r "$f" ] || continue
    awk '/^[|@#]/ { next }
      { n = split($1, a, ",")
        for (i = 1; i <= n; i++) {
          h = a[i]; sub(/^\[/, "", h); sub(/\](:[0-9]+)?$/, "", h)
          if (h != "" && h != "localhost") print h
        } }' "$f"
  done < <(_known_hosts_files) | awk 'NF && !seen[$0]++'
}
_history_ssh_targets() {
  local f
  for f in "$HOME/.bash_history" "$HOME/.zsh_history" "$HOME/.local/share/fish/fish_history"; do
    [ -r "$f" ] || continue
    tr ';&|' '\n\n\n' < "$f" | awk '
      { for (i = 1; i <= NF; i++) if ($i == "ssh") {
          j = i + 1
          while (j <= NF) {
            if ($j ~ /^-/) { if ($j ~ /^-[piloFbceDLRWJQm]$/) j++; j++; continue }
            print $j; break
          }
        } }' 2>/dev/null
  done | awk 'NF && $0 !~ /[*?${}]/ && !seen[$0]++'
}
_docker_ssh_hosts() {
  command -v docker >/dev/null 2>&1 || return 0
  docker context ls --format '{{.DockerEndpoint}}' 2>/dev/null | sed -n 's#^ssh://##p' | awk 'NF && !seen[$0]++'
}
_etc_hosts_names() {
  local hf="${1:-/etc/hosts}"
  [ -r "$hf" ] || return 0
  awk '!/^[[:space:]]*#/ && NF >= 2 {
    ip = $1
    if (ip ~ /^127\./ || ip == "::1" || ip ~ /^0\.0\.0\.0/ || ip ~ /^255\./ || ip ~ /^(fe00|ff00|ff02):/ || ip == "::") next
    for (i = 2; i <= NF; i++) if ($i !~ /^(localhost|ip6-)/) print $i
  }' "$hf" | awk 'NF && !seen[$0]++'
}
_ssh_resolve() {
  ${OVERSEER_SSH:-ssh} -G "$1" 2>/dev/null | awk '
    tolower($1) == "user" && u == "" { u = $2 }
    tolower($1) == "hostname" && h == "" { h = $2 }
    tolower($1) == "identityfile" && idf == "" { idf = $2 }
    END { printf "%s\t%s\t%s\n", u, h, idf }'
}
_ssh_explicit_user() {
  local u
  IFS=$'\t' read -r u _ _ < <(_ssh_resolve "$1") || true
  [ -n "$u" ] && [ "$u" != "$(id -un)" ] && printf '%s' "$u"
  return 0
}
_ts_inventory() {
  command -v jq >/dev/null 2>&1 || return 0
  ${OVERSEER_TS:-tailscale} status --json 2>/dev/null | jq -r '
    def dnsfull: ((.DNSName // "") | rtrimstr("."));
    def nm: (dnsfull | split(".")[0]) as $d | (if $d == "" then (.HostName // "?") else $d end);
    (.Self | [ (.TailscaleIPs[0] // ""), nm, (.OS // "?"), "self", dnsfull ] | @tsv),
    ((.Peer // {} | .[]) | [ (.TailscaleIPs[0] // ""), nm, (.OS // "?"),
      (if .Online then "online" else "offline" end), dnsfull ] | @tsv)' 2>/dev/null
}
_ts_state() {
  awk -v hp="$1" '
    $1 == hp || $2 == hp {
      s = "-"
      if (index($0, "offline")) s = "offline"
      else if (index($0, "active")) s = "active"
      else if (index($0, "idle")) s = "idle"
      print s; found = 1; exit
    }
    END { if (!found) print "?" }
  '
}
_ts_hosts() {
  awk -v osf="$1" '$1 ~ /^100\./ && NF >= 4 {
    if (osf != "" && $4 != osf) next
    print $1
  }'
}
_provision_script() {
  printf 'DRY=%s\n' "${1:-0}"
  cat <<'PSCRIPT'
set -e
os=$(uname -s 2>/dev/null || echo unknown)
[ "$os" = Linux ] || { echo "not Linux ($os) - provision installs Linux tmux/jq only; Windows/macOS deps are set up manually"; exit 3; }
miss=''
for c in tmux jq; do command -v "$c" >/dev/null 2>&1 || miss="$miss $c"; done
miss=${miss# }
[ -n "$miss" ] || { echo "already has tmux + jq - nothing to install"; exit 0; }
if command -v apt-get >/dev/null 2>&1; then pm="export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y $miss"
elif command -v dnf >/dev/null 2>&1; then pm="dnf install -y $miss"
elif command -v yum >/dev/null 2>&1; then pm="yum install -y $miss"
elif command -v pacman >/dev/null 2>&1; then pm="pacman -Sy --noconfirm $miss"
elif command -v zypper >/dev/null 2>&1; then pm="zypper --non-interactive install $miss"
elif command -v apk >/dev/null 2>&1; then pm="apk add $miss"
else echo "missing:$miss but no known package manager (apt/dnf/yum/pacman/zypper/apk) - install manually"; exit 4; fi
if [ "$(id -u)" = 0 ]; then pre=''
elif command -v sudo >/dev/null 2>&1; then pre='sudo -n '
else echo "missing:$miss and cannot install (not root, no sudo)"; exit 5; fi
if [ "$DRY" = 1 ]; then echo "would install:$miss via: ${pre}sh -c \"$pm\""; exit 0; fi
echo "installing:$miss ..."
${pre}sh -c "$pm" || { echo "install failed for:$miss (needs root or passwordless sudo)"; exit 6; }
still=''
for c in tmux jq; do command -v "$c" >/dev/null 2>&1 || still="$still $c"; done
still=${still# }
[ -z "$still" ] && echo "installed:$miss - now drivable" || { echo "still missing:$still after install"; exit 7; }
PSCRIPT
}
# emit: <session>\t<pane_id>\t<pane_pid>\t<harness>\t<cwd> for each agent pane (claude or codex).
# prune by pane command first (claude runs as `claude`, codex as `node`) so the fd scan only runs
# on plausible panes.
_panes() {
  local s pid_id pp cmd kind cwd
  while IFS=$'\t' read -r s pid_id pp cmd; do
    case "$cmd" in
      claude) _agent_pid "$pp" >/dev/null 2>&1 && kind=claude || continue ;;
      node)   _codex_pid "$pp" >/dev/null 2>&1 && kind=codex || continue ;;
      *) continue ;;
    esac
    cwd=$(_p_cwd "$pp" || echo '?')
    printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$pid_id" "$pp" "$kind" "$cwd"
  done < <(tmux list-panes -a -F '#{session_name}	#{pane_id}	#{pane_pid}	#{pane_current_command}' 2>/dev/null)
}
# ---- session-id + transcript resolution ------------------------------------
_encode_cwd() { local p="$1"; p="${p//\//-}"; p="${p//./-}"; p="${p//_/-}"; printf '%s' "$p"; }
_sid_of() {
  local sid
  sid=$(jq -r '.sessionId // empty' "$CLAUDE_HOME/sessions/$1.json" 2>/dev/null || true)
  [ -n "$sid" ] && printf '%s' "$sid"
}
_jsonl_of() {
  local sid="$1" cwd="$2" enc f
  enc=$(_encode_cwd "$cwd")
  f=$(ls "$CLAUDE_HOME/projects/$enc/$sid"*.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] || f=$(ls "$CLAUDE_HOME"/projects/*/"$sid"*.jsonl 2>/dev/null | head -1)
  printf '%s' "$f"
}
# resolve target -> "pane_id<TAB>harness<TAB>transcript_path". uses the SAME pane resolution as
# peek/keys/sh (the pane tmux would act on: a %N as-is, a session/window name -> its ACTIVE pane), so
# every command targets one pane — no split-window divergence where chat drives one pane and peek
# reads another. requires that pane to run a claude OR codex agent; returns 1 otherwise (target the
# agent pane by %N if it is split). transcript_path may be empty for a 0-turn claude session.
_target_ctx() {
  local pane pp apid cwd sid jl rf
  pane=$(_resolve_pane "$1") || return 1
  pp=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null) || return 1
  if apid=$(_agent_pid "$pp"); then
    cwd=$(_p_cwd "$pp" || echo '?')
    sid=$(_sid_of "$apid") || true
    if [ -n "$sid" ]; then jl=$(_jsonl_of "$sid" "$cwd"); else jl=''; fi
    printf '%s\t%s\t%s' "$pane" claude "$jl"; return 0
  fi
  if _codex_pid "$pp" >/dev/null 2>&1; then
    rf=$(_codex_rollout "$pp" 2>/dev/null || true)
    printf '%s\t%s\t%s' "$pane" codex "$rf"; return 0
  fi
  return 1
}
# ---- commands ---------------------------------------------------------------
# resolve any target (pane id %N, or a session/window name) to the pane id tmux would act on.
# unlike _resolve, not restricted to claude panes — used by peek/keys/sh.
_resolve_pane() {
  local p rc=0; p=$(_pane_by_peer_name "$1") || rc=$?
  case "$rc" in 2|3) return 1 ;; esac
  [ -n "$p" ] || p=$(tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null) || return 1
  [ -n "$p" ] && printf '%s' "$p"
}
