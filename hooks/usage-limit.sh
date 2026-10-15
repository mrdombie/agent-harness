#!/usr/bin/env bash
# StopFailure (matcher rate_limit) — write down when the plan's usage limit resets.
#
# WHY: on 2026-10-14 agents died at "You've hit your session limit · resets
# 2:40am" and nothing resumed them; the window that owned them had hit the same
# wall, so its turn ended and no reply could record anything. Claude Code fires
# StopFailure INSTEAD of Stop when an API error ended the turn — fire-and-forget,
# output and exit code ignored — so a hook is the only thing still running. It
# records the reset in the shared hold file; the loop's next wake reads the hold,
# and the first wake after it resumes every agent the wall cut off.
#
# Always exits 0: it can change nothing about the turn, only leave a note.
set -u
IN=$(cat)
LOG=/tmp/claude-usage-limit.log
say() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
ERR=$(printf '%s' "$IN" | jq -r '.error // ""' 2>/dev/null)
case "$ERR" in rate_limit|"") ;; *) say "skip error=$ERR"; exit 0 ;; esac
TEXT=$(printf '%s' "$IN" | jq -r '[.error_details // "", .last_assistant_message // ""] | map(tostring) | join(" ")' 2>/dev/null)
[ -n "$TEXT" ] || TEXT="hit your usage limit"
OUT=$(bash "$(dirname "$0")/../scripts/nonstop.sh" hold-set "$TEXT" 2>&1)
say "error=$ERR $OUT"
exit 0
