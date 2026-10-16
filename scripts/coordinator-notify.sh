#!/usr/bin/env bash
# coordinator-notify.sh — route something the coordinator found to whoever acts
# on it. The owner channel (needs-you.md, a desktop ping, the --watch prompt)
# carries only the owner's own decisions; agent work goes to agent-work.log,
# which the judge and the queue read, and never pings anyone.
#
#   coordinator-notify.sh [--class owner|agent] <key> "<line>"
#
# --class owner is honoured only for a key whose kind (the text before the first
# ":") is in OWNER_KINDS; any other key is agent work whatever the caller said.
# A red PR, a frozen or stood-down run, a usage stop: an agent can clear each, so
# none can reach the owner by a caller choosing the wrong class.
# No --class means agent: an unsorted line costs a log row, never the owner's time.
#
# <key> makes it idempotent: a key already written is not written or pinged
# again, so a tick every five minutes cannot ping every five minutes.
# In shadow (the default) it writes nothing and pings nothing; it logs "would".
# COORDINATOR_NOTIFY_CMD replaces the desktop ping (a phone push, say); it gets
# the line as $1.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coordinator-env.sh" || exit 1

CLASS=agent
case "${1:-}" in
  --class) CLASS="${2:?--class needs owner or agent}"; shift 2 ;;
  --class=*) CLASS="${1#--class=}"; shift ;;
esac
case "$CLASS" in owner|agent) ;; *) echo "coordinator-notify: unknown class '$CLASS' (owner|agent)" >&2; exit 2 ;; esac
KEY="${1:?usage: coordinator-notify.sh [--class owner|agent] <key> \"<line>\"}"
LINE="${2:?usage: coordinator-notify.sh [--class owner|agent] <key> \"<line>\"}"
# One entry is one line: a newline in it would split it into an unkeyed second entry.
LINE=$(printf '%s' "$LINE" | tr '\n\t' '  ')

# The owner's decisions: a batch of screens to sign off, the forge unreadable (only
# the owner can log in), the disk still low after the cache pass, and a judgement
# that names a choice only the owner can make.
OWNER_KINDS="signoff-batch blind disk-low login-lost decision"
KIND="${KEY%%:*}"
case " $OWNER_KINDS " in *" $KIND "*) ;; *) CLASS=agent ;; esac
AGENT_WORK="$COORD_DIR/agent-work.log"
# Per mode: a key seen in shadow must still reach the owner once live.
SEEN="$COORD_DIR/notified.$(coord_mode).keys"
touch "$SEEN"

grep -qxF -- "$KEY" "$SEEN" && exit 0

if [ "$CLASS" = agent ]; then
  coord_act_log notify-agent "$KEY" "$LINE"
  coord_shadow || printf '%s\t%s\t%s\n' "$(swarm_stamp)" "$KEY" "$LINE" >> "$AGENT_WORK"
  printf '%s\n' "$KEY" >> "$SEEN"
  exit 0
fi

if coord_shadow; then
  coord_act_log notify "$KEY" "$LINE"
  printf '%s\n' "$KEY" >> "$SEEN"
  exit 0
fi

# The key rides on the line so a watcher can tell a new entry from one it asked.
printf -- '- [ ] %s — %s <!-- key:%s -->\n' "$(swarm_stamp)" "$LINE" "$KEY" >> "$COORD_NEEDS_YOU"
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
