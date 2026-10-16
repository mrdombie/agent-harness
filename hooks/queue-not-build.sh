#!/usr/bin/env bash
# PreToolUse(Agent|Task): while this project's coordinator is live, a chat does
# not start a builder agent — it queues the ticket for the coordinator.
#
# 2026-10-16: a /loop /work session built 4 tickets with in-chat agents. They
# ran outside the coordinator's cap of 4 and its usage hold, retried into the
# same usage wall it was holding for, and wrote no run record, so the live view
# showed an empty swarm while 4 agents ran.
#
# A builder is an agent asked to claim, build or finish a ticket (the claim, bug
# and finish flows, or claim-lock.sh acquire), or one given its own worktree
# while a /work or /auto loop runs. Reviewers, explorers and PM help pass.
#
# exit 2 refuses with the reason on stderr. Anything this cannot read passes.
# Self-test: hooks/queue-not-build.test.sh
set -uo pipefail
IN=$(cat)
prompt=$(printf '%s' "$IN" | jq -r '.tool_input.prompt // empty' 2>/dev/null)
iso=$(printf '%s' "$IN" | jq -r '.tool_input.isolation // empty' 2>/dev/null)
HERE="$(cd "$(dirname "$0")" && pwd)"

builder=0
printf '%s' "$prompt" | grep -qiE 'agent-harness:(claim|bug|finish)|(^|[^a-z0-9_.-])/(claim|bug|finish)([^a-z0-9_-]|$)|claim-lock\.sh +acquire|spawn-claim\.sh|build (ticket|issue) #?[0-9]+' \
  && builder=1
if [ "$builder" = 0 ] && [ "$iso" = worktree ]; then
  sd="${HARNESS_STATE_DIR:-$(cat "$HOME/.claude/.harness-last-state-dir" 2>/dev/null)}"; sd="${sd/#\~/$HOME}"
  [ -n "$sd" ] && [ -f "$sd/.loop-active" ] && builder=1
fi
[ "$builder" = 1 ] || exit 0

mode=$(bash "${QUEUE_NOT_BUILD_SERVICE:-$HERE/../scripts/coordinator-service.sh}" 2>/dev/null)
[ "$mode" = live ] || exit 0

cat >&2 <<EOF
Not started: the coordinator builds tickets on this machine, so a chat does not
start builder agents (they would run outside its cap and usage hold, and the
live view could not see them).

Queue the work instead, then carry on with PM work in this chat:
  bash "$HERE/../scripts/coordinator-queue.sh" seed <area>            # every ready ticket in an area
  bash "$HERE/../scripts/coordinator-queue.sh" add <n> --note "<what the builder needs>"
EOF
exit 2
