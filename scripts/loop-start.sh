#!/usr/bin/env bash
# loop-start.sh — a /work or /auto loop says it is running.
#
#   loop-start.sh <scope>    the resolved label, or "auto" for the whole board
#
# Writes three files under $STATE_DIR, in this order:
#   .session-label        <scope>\t<local time with offset> — /standup and the sign-off read it
#   .session-label.owner  this Claude session's pid — so a peer's loop is not ours
#   .loop-active          the keep-working Stop hook's "a loop is running" marker
#
# WHY: keep-working.sh stands down unless .loop-active exists, and nothing wrote
# it — the skills only wrote .session-label — so the hook that holds a loop open
# while its scope has ready tickets had never fired from /work or /auto. The owner
# is written after the label: an owner file older than its label reads as
# "unclaimed" (hooks/lib/claude-session.sh) and silences the hook.
set -uo pipefail
_LS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_LS_HOME/toolkit-env.sh" >/dev/null 2>&1 || true
. "$_LS_HOME/../hooks/lib/claude-session.sh" || exit 1

SCOPE="${1:-}"
[ -n "$SCOPE" ] || { echo "usage: loop-start.sh <scope>" >&2; exit 1; }
SD="${STATE_DIR:-${HARNESS_STATE_DIR:-}}"; SD="${SD/#\~/$HOME}"
[ -n "$SD" ] || { echo "loop-start: no state dir (set stateDir in .claude/harness.json)" >&2; exit 1; }
mkdir -p "$SD" || exit 1

printf '%s\t%s\n' "$SCOPE" "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$SD/.session-label" || exit 1
# An unresolvable session writes an empty owner, which the hook reads as "not a peer's".
printf '%s\n' "$(claude_session_pid 2>/dev/null || true)" > "$SD/.session-label.owner" || exit 1
touch "$SD/.loop-active" || exit 1
echo "loop running: $SCOPE"
