#!/usr/bin/env bash
# Stop — tell the operator when this window's context is big enough to restart.
#
# WHY: every reply re-reads the whole window. Measured 2026-11-12: 21% of five
# hours' usage was PM-window replies made on over 400k of context, most of them
# woken by a watcher, and nothing said which windows had grown that far.
#
# THE PROXY, NAMED: "input + cache-read + cache-write tokens of the newest
# main-thread reply in the transcript's tail" stands in for "what the next reply
# will re-read". A reply not yet written to the transcript reads one call stale.
#
# It says so twice: `systemMessage` (the one Stop output the operator sees) in
# the window itself, and a desktop ping naming the window for when it is not in
# front. Once at the limit and once per step above it, never every turn.
# Never refuses the stop: exit 0 always, so it cannot loop a turn.
#
#   HARNESS_CONTEXT_WARN_TOKENS   the limit (default 300000)
#   HARNESS_CONTEXT_WARN_STEP     warn again each time it grows this much (100000)
#   HARNESS_CONTEXT_NOTIFY_CMD    replaces the desktop ping; gets title and line
set -uo pipefail

IN=$(cat)
LOG=/tmp/claude-context-size.log
say() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

# No operator reads a driver step or a headless run.
[ -n "${HARNESS_DRIVER_RUN:-}" ] && exit 0
[ -n "${HARNESS_HEADLESS:-}" ] && exit 0

WARN=${HARNESS_CONTEXT_WARN_TOKENS:-300000}
STEP=${HARNESS_CONTEXT_WARN_STEP:-100000}
case "$WARN$STEP" in '' | *[!0-9]*) say "exit0 bad-limits"; exit 0 ;; esac
[ "$STEP" -gt 0 ] || exit 0

TP=$(printf '%s' "$IN" | jq -r '.transcript_path // ""')
SID=$(printf '%s' "$IN" | jq -r '.session_id // "nosession"')
[ -n "$TP" ] && [ -r "$TP" ] || exit 0

# A helper's reply (isSidechain) is its own context, not this window's.
TAIL=$(tail -n 400 "$TP" 2>/dev/null)
CTX=$(jq -R -r 'fromjson? | select(.type == "assistant" and (.isSidechain | not)) | .message.usage
  | select(.) | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
  | select(. > 0)' <<<"$TAIL" 2>/dev/null | tail -1)
case "$CTX" in '' | *[!0-9]*) exit 0 ;; esac

NDIR="${TMPDIR:-/tmp}/claude-context-size"
SEEN="$NDIR/$SID"
if [ "$CTX" -lt "$WARN" ]; then rm -f "$SEEN"; exit 0; fi

LEVEL=$(( (CTX - WARN) / STEP ))
LAST=$(cat "$SEEN" 2>/dev/null); case "$LAST" in '' | *[!0-9]*) LAST=-1 ;; esac
mkdir -p "$NDIR" && printf '%s\n' "$LEVEL" > "$SEEN"
# Shrunk since the last warning (a compaction): remember the lower level, say nothing.
[ "$LEVEL" -gt "$LAST" ] || exit 0

K=$(( CTX / 1000 ))
TITLE=$(jq -R -r 'fromjson? | select(.type == "ai-title") | .aiTitle // empty' <<<"$TAIL" 2>/dev/null | tail -1)
[ -n "$TITLE" ] || TITLE="A Claude window"
MSG="This window is carrying ${K}k of context, and every reply re-reads all of it. Ask it for a handover note, then carry on in a new window."
PING="$TITLE: ${K}k of context. Restart it."
say "warn $SID ctx=$CTX level=$LEVEL"

if [ -n "${HARNESS_CONTEXT_NOTIFY_CMD:-}" ]; then
  "$HARNESS_CONTEXT_NOTIFY_CMD" "Restart a window" "$PING" >/dev/null 2>&1 || true
elif command -v osascript >/dev/null 2>&1; then
  # osascript string literals take no escapes we control, so strip quote characters.
  SAFE=$(printf '%s' "$PING" | tr -d '"\\')
  osascript -e "display notification \"$SAFE\" with title \"Restart a window\"" >/dev/null 2>&1 || true
elif command -v notify-send >/dev/null 2>&1; then
  notify-send "Restart a window" "$PING" >/dev/null 2>&1 || true
fi

jq -nc --arg m "$MSG" '{systemMessage:$m}'
exit 0
