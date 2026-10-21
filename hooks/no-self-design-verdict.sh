#!/usr/bin/env bash
# no-self-design-verdict.sh — no agent session records a design verdict.
#
# The design status is set only by the independent critic (scripts/critic-judge.sh),
# which the coordinator starts outside any agent session. On one PR the build's own
# repair run ran the critic, committed `Design-Critic: SHIP` and the project's CI
# turned that trailer into a green status; an independent critic on CI's shots of the
# same fingerprint said SLOP with four Majors. So, from any session, this denies:
#   - running the project's recorder for the design critic (`record-verdict.sh design-critic`)
#   - a git commit whose message carries the design-verdict trailer (review.judge.trailer,
#     default Design-Critic), however the message is passed — -m, -F, or a heredoc
#   - starting the judge itself (`critic-judge.sh run|sweep`): it belongs to the coordinator
#   - a repository dispatch (`repos/<o>/<r>/dispatches`): the judge's verdict reaches the
#     project's relay that way, and the relay can only check the sender is the owner,
#     which every session on this machine is
#   - posting the design status (review.judge.context, default "Design critic") by hand
# Self-test: hooks/no-self-design-verdict.test.sh
_cfg="${HARNESS_CFG_PATH:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}/.claude/harness.json}"
TRAILER=""; CONTEXT=""
[ -f "$_cfg" ] && TRAILER=$(jq -r '.review.judge.trailer // empty' "$_cfg" 2>/dev/null)
[ -f "$_cfg" ] && CONTEXT=$(jq -r '.review.judge.context // empty' "$_cfg" 2>/dev/null)
TRAILER="${TRAILER:-Design-Critic}"; CONTEXT="${CONTEXT:-Design critic}"
set -uo pipefail
cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null)
[ -n "$cmd" ] || exit 0
deny() { jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
S='[[:space:]]'
WHY="Only the independent critic sets the design status, on CI's pinned shots after the push (scripts/critic-judge.sh, started by the coordinator). A verdict a build writes is the build clearing its own sign-off, and it counts for nothing. Push the change; read the critic's comment on the PR for what to fix."
printf '%s' "$cmd" | grep -qE "record-verdict(\.sh)?[\"']?$S+[\"']?design-critic" \
  && deny "Recording a design-critic verdict from a session. $WHY"
printf '%s' "$cmd" | grep -qE "critic-judge\.sh[\"']?$S+(run|sweep)" \
  && deny "The independent critic is started by the coordinator, never from a session that builds. $WHY"
printf '%s' "$cmd" | grep -qE "repos/[^/[:space:]\"']+/[^/[:space:]\"']+/dispatches" \
  && deny "A repository dispatch from a session: that is how the independent critic's verdict reaches the design status. $WHY"
if printf '%s' "$cmd" | grep -qE "statuses/[0-9a-fA-F\$]" \
   && { printf '%s' "$cmd" | grep -qE "context=[\"']?$CONTEXT" || printf '%s' "$cmd" | grep -qE -- "--input"; }; then
  deny "Posting the '$CONTEXT' status by hand. $WHY"
fi
if printf '%s' "$cmd" | grep -qE "(^|[^A-Za-z0-9_-])git($S+-[^[:space:]]+($S+[^-[:space:]][^[:space:]]*)?)*$S+commit" \
   && printf '%s' "$cmd" | grep -qiE "(^|[^A-Za-z0-9-])$TRAILER:"; then
  deny "A commit carrying a '$TRAILER:' trailer. $WHY"
fi
exit 0
