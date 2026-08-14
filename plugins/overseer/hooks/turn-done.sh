#!/usr/bin/env bash
input="$(cat)"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"

[ -z "$sid" ] && exit 0
base="${CLAUDE_HOME:-$HOME/.claude}"
dir="$base/${1:-turn-done}"
mkdir -p "$dir"
touch "$dir/$sid"

stamp="$base/.overseer-pruned"
if [ ! -e "$stamp" ] || [ -n "$(find "$stamp" -maxdepth 0 -mmin +1440 2>/dev/null)" ]; then
  touch "$stamp"
  find "$base/turn-done" "$base/turn-started" "$base/awaiting" -maxdepth 1 -type f -mmin +10080 -delete 2>/dev/null || true
fi
