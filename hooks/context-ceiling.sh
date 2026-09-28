#!/usr/bin/env bash
# PostToolUse — a spawned run parks with a resume brief once its context passes
# a ceiling, instead of running on until the budget or the turn runs out.
#
# WHY: a spawned run stops only on its budget or at the end of its turn, and
# nothing reacts to context size. Runs were measured at ~380k tokens per turn,
# where every turn re-reads the whole prompt and deep instructions are followed
# less reliably. A context window cannot clear itself — no hook can do that — but
# the claim skill already has the thing that buys the context back: park (push,
# draft PR, resume brief) and let a fresh spawn resume from the brief. Nothing
# triggered it on context. This does.
#
# SCOPE: only inside a spawned run. scripts/spawn-claim.sh exports CLAIM_RUN_ID
# into the agent; an interactive session has none, and this hook exits before it
# reads anything. A person at the keyboard can see the context and decide.
#
# THE MEASUREMENT, NAMED: "context size" is read as the LAST assistant message's
# input side — input_tokens + cache_read_input_tokens + cache_creation_input_tokens
# — which is what that turn re-read. It is the turn before the tool that just ran,
# so it lags by one tool result; one call late is fine for a once-per-run nudge.
#
# COST: it runs on every tool call of a spawned run. Once it has fired, the marker
# ends it after one stat. Before that it reads only the transcript's TAIL (never
# the whole file — a long run's transcript is megabytes) and runs jq only on the
# lines that carry a usage block.
#
# CONTRACT: never blocks a tool, never fails the call. Every unknown — no
# transcript, a garbled one, no usage in the tail, no jq — is silence and exit 0.
# The instruction goes in as additionalContext, which is how a PostToolUse hook
# puts text in front of the model.
#
# Ceiling: $CLAIM_CONTEXT_CEILING, else `contextCeiling` in .claude/harness.json,
# else 250000. Self-test: hooks/context-ceiling.test.sh
set -uo pipefail

RUN="${CLAIM_RUN_ID:-}"
[ -n "$RUN" ] || exit 0                       # not a spawned run: the common path, zero cost
command -v jq >/dev/null 2>&1 || exit 0

LOG="${TMPDIR:-/tmp}/claude-context-ceiling.log"
say() { echo "$(date -u +%FT%TZ) $*" >> "$LOG" 2>/dev/null || true; }

# Once per run. The run id is a filename we did not choose, so keep it to a safe
# alphabet before it names a file.
MDIR="${TMPDIR:-/tmp}/claude-context-ceiling"
MARK="$MDIR/$(printf '%s' "$RUN" | tr -c 'A-Za-z0-9._-' '_')"
[ -f "$MARK" ] && exit 0

IN=$(cat)
TP=$(printf '%s' "$IN" | jq -r '.transcript_path // ""' 2>/dev/null | tr -d '\r')
[ -n "$TP" ] && [ -r "$TP" ] || { say "exit0 no-transcript run=$RUN"; exit 0; }

# The ceiling. The env wins; the config is read with one jq, not the resolver —
# sourcing toolkit-env.sh costs hundreds of ms and this runs on every tool call.
CEIL="${CLAIM_CONTEXT_CEILING:-}"
if [ -z "$CEIL" ]; then
  _cfg="${HARNESS_CFG_PATH:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}/.claude/harness.json}"
  [ -f "$_cfg" ] && CEIL=$(jq -r '.contextCeiling // empty' "$_cfg" 2>/dev/null | tr -d '\r')
fi
case "$CEIL" in ''|*[!0-9]*) CEIL=250000 ;; esac

# The last assistant turn's input side. Lines are read with fromjson? because the
# first line of a byte tail is almost always cut mid-object. A subagent's turns
# (isSidechain) are not this run's context, and a synthetic message carries a
# zero usage, so both are skipped. A tool result can be large enough to push
# every assistant line out of a small tail, so a miss widens once.
USAGE_JQ='fromjson? | select(.type == "assistant" and (.isSidechain | not))
  | .message.usage // empty
  | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))
  | select(. > 0)'
N=""
for BYTES in 262144 4194304; do
  N=$(tail -c "$BYTES" "$TP" 2>/dev/null | grep -F '"usage"' | jq -R "$USAGE_JQ" 2>/dev/null | tail -n 1 | tr -d '\r')
  [ -n "$N" ] && break
done
case "$N" in ''|*[!0-9]*) say "exit0 no-usage run=$RUN"; exit 0 ;; esac

[ "$N" -gt "$CEIL" ] || exit 0

mkdir -p "$MDIR" 2>/dev/null && touch "$MARK" 2>/dev/null || { say "exit0 no-marker run=$RUN"; exit 0; }
say "fired run=$RUN tokens=$N ceiling=$CEIL"

MSG="CONTEXT CEILING — this spawned run ($RUN) is at $N input tokens, over its ceiling of $CEIL (CLAIM_CONTEXT_CEILING). Past this point every turn re-reads the whole context and deep instructions are followed less reliably, so this run hands over to a fresh one.

Finish the step in hand, then PARK per /agent-harness:claim's park procedure so a fresh run resumes from the brief. Do not start new work — no next plan task, no new file, no new investigation.
  1. Commit and push the branch. An unpushed branch is the only thing a park can lose.
  2. Open a draft PR if there is none; that is what lets the next run find the work as a [RESUME PR].
  3. Comment the resume brief on the issue — Built / Stopped at / Resume, plus anything the next run would otherwise have to rediscover (decisions made, dead ends, the exact next step).
  4. Release the claim.
Do NOT add the human-hold label: nothing here waits on a person, and a held ticket is never offered for resume. If you are already inside /agent-harness:finish with the gates green, finishing IS the step in hand — ship it instead of parking.

This message is sent once per run."

jq -nc --arg c "$MSG" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
exit 0
