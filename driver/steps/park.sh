#!/usr/bin/env bash
# steps/park.sh — the refusal path, reachable from every step.
#
#   driver_park <ticket> <reason> [the question, answerable in a line]
#
# Parking has one job: leave the work recoverable by somebody who is not this
# process. The order is the whole design and it is not arbitrary:
#
#   1. PUSH. An unpushed branch is the only thing a park can actually lose. The
#      worktree may be swept the moment this returns; the branch is the handover.
#      Uncommitted work is committed first — half-finished and pushed beats
#      finished-looking and gone.
#   2. A DRAFT PULL REQUEST. This is what makes the work visible: a ticket with an
#      open PR is classified in-review and never released back to ready, so no
#      fresh agent rebuilds what is already built.
#   3. THE RESUME BRIEF, as an issue comment: built · stopped at · needs · resume.
#      "Needs" is phrased so a yes/no or a pick answers it, because a question
#      that needs an essay is a question nobody answers.
#   4. THE LABEL, so a person can see it on the board.
#   5. RELEASE THE CLAIM — LAST. A ref dropped before the rest is a ticket a peer
#      can claim in the middle of this, against a branch that is not yet pushed.
#
# It always parks. There is no failure path out of a park: a park that refused
# would leave the claim held and the work invisible, which is the state it exists
# to prevent.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state.sh" || exit 1

driver_park() { # <ticket> <reason> [question]
  local t="${1:?driver_park: need a ticket}" reason="${2:-a refusal}" question="${3:-}"
  local wt branch done_list pushed=0
  export DRIVER_TICKET="$t"
  wt=$(driver_state_get "$t" worktree)
  branch=$(driver_state_get "$t" branch)
  done_list=$(driver_state_get "$t" 'done|join(" · ")')

  if [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$branch" ]; then
    if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      git -C "$wt" add -A -- . >/dev/null 2>&1
      git -C "$wt" commit -q -m "wip(#$t): parked — $reason" >/dev/null 2>&1 || true
    fi
    if git -C "$wt" push -q -u origin "$branch" >/dev/null 2>&1; then
      pushed=1
    else
      driver_say "   park: the branch could not be pushed — say so rather than reporting a handover that does not exist"
    fi
  fi

  if [ "$pushed" -eq 1 ]; then
    swarm_gh pr create --repo "$REPO_SLUG" --draft \
      --base "$INTEGRATION_BRANCH" --head "$branch" \
      --title "#$t: parked — $reason" \
      --body "Parked mid-run. See the resume brief on #$t." >/dev/null 2>&1 || true
  fi

  swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "$(cat <<BRIEF
**Parked — $reason.**

**Built:** ${done_list:-nothing yet; it stopped before the first step finished}
**Stopped at:** $reason
**Needs:** ${question:-a person to say how to proceed}
**Resume:** clear \`$HOLD_LABEL\`, then run the driver again — it picks up from the last finished step.

${branch:+Branch \`$branch\`$([ "$pushed" -eq 1 ] && echo " is pushed; a draft pull request is open." || echo " could NOT be pushed — the work is only in $wt.")}
BRIEF
)" >/dev/null 2>&1 || true

  swarm_gh issue edit "$t" --repo "$REPO_SLUG" --add-label "$HOLD_LABEL" >/dev/null 2>&1 || true

  # Last. Everything above has to be true before the ticket is anyone else's.
  bash "$CL" release "$t" >/dev/null 2>&1 || true

  driver_say "⏸ #$t parked: $reason${question:+ — $question}"
  return "$DRIVER_E_QUESTION"
}
