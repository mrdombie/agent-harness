#!/usr/bin/env bash
# SessionStart (compact|resume) — a non-stop window keeps its place after compaction.
#
# WHY: compaction replaces the conversation with a summary, and a summary can drop
# "you are working this area until it is finished". The loop's state is on disk
# (scripts/nonstop.sh), so this puts the three lines that matter back in front of
# the model: the area, the agents in flight, and what to do next. Silent for a
# window with no armed loop.
set -u
IN=$(cat)
SRC=$(printf '%s' "$IN" | jq -r '.source // ""' 2>/dev/null)
case "$SRC" in compact|resume) ;; *) exit 0 ;; esac
NS="$(dirname "$0")/../scripts/nonstop.sh"
B=$(bash "$NS" wake 2>/dev/null) || exit 0
case "$B" in "NEXT: START"*|"NEXT: STOPPED"*|"") exit 0 ;; esac
CTX="You are a non-stop window (/agent-harness:work --nonstop). Your loop state survived ${SRC}; continue it — do not restart or re-read files you already summarised. Board:
$B"
jq -nc --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
