#!/usr/bin/env bash
# coordinator-notify.sh — tell the owner something needs them: one line in
# needs-you.md (what /agent-harness:needsme reads first) and a desktop ping.
#
#   coordinator-notify.sh <key> "<line>"
#
# <key> makes it idempotent: a key already written is not written or pinged
# again, so a tick every five minutes cannot ping every five minutes.
# In shadow (the default) it writes nothing and pings nothing; it logs "would".
# COORDINATOR_NOTIFY_CMD replaces the desktop ping (a phone push, say); it gets
# the line as $1.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coordinator-env.sh" || exit 1

KEY="${1:?usage: coordinator-notify.sh <key> \"<line>\"}"
LINE="${2:?usage: coordinator-notify.sh <key> \"<line>\"}"
# Per mode: a key seen in shadow must still reach the owner once live.
SEEN="$COORD_DIR/notified.$(coord_mode).keys"
touch "$SEEN"

grep -qxF -- "$KEY" "$SEEN" && exit 0

if coord_shadow; then
  coord_act_log notify "$KEY" "$LINE"
  printf '%s\n' "$KEY" >> "$SEEN"
  exit 0
fi

printf -- '- [ ] %s — %s\n' "$(swarm_stamp)" "$LINE" >> "$COORD_NEEDS_YOU"
printf '%s\n' "$KEY" >> "$SEEN"
coord_act_log notify "$KEY" "$LINE"

if [ -n "${COORDINATOR_NOTIFY_CMD:-}" ]; then
  "$COORDINATOR_NOTIFY_CMD" "$LINE" >/dev/null 2>&1 || true
elif command -v osascript >/dev/null 2>&1; then
  # osascript string literals take no escapes we control, so strip quote characters.
  SAFE=$(printf '%s' "$LINE" | tr -d '"\\')
  osascript -e "display notification \"$SAFE\" with title \"Needs you\"" >/dev/null 2>&1 || true
elif command -v notify-send >/dev/null 2>&1; then
  notify-send "Needs you" "$LINE" >/dev/null 2>&1 || true
fi
exit 0
