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
#
# THE COMMIT'S OWN EXIT CODE IS READ, AND THE TYPE IS A PROJECT FACT. It committed
# `wip(#<n>): parked — …` with `|| true` and then reported on the PUSH. Measured on
# the 2026-09-27 trial:
#
#   ✖ type must be one of [feat, fix, refactor, chore, docs, test, perf, style,
#     revert, ci, build] [type-enum]
#   husky - commit-msg script failed (code 1)
#
# `wip` is not in that project's enum, the `|| true` swallowed it, the push then had
# nothing new to push, and the brief told the reader the work was "only in
# /var/folders/…". A park exists so nothing is lost; that one lost the work and
# misnamed the cause. The type comes from harness.json (`commit.parkType`, default
# `chore` — the one type in every conventional-commits enum), and a commit that
# fails is reported as a commit that failed, with the hook's own output.
#
# AND WHAT IT STAGED IS NAMED. `git add -A -- .` swept an unrelated file of the
# operator's into the parked commit. Staging less would lose a new file the build
# had just written, which is the one thing this function exists to prevent — so it
# still stages everything and puts the list in the brief, where a stray file is
# visible to the person reading it.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state.sh" || exit 1

driver_park() { # <ticket> <reason> [question]
  local t="${1:?driver_park: need a ticket}" reason="${2:-a refusal}" question="${3:-}"
  local wt branch done_list pushed=0 staged="" ctype cout crc=0 commit_note=""
  export DRIVER_TICKET="$t"
  wt=$(driver_state_get "$t" worktree)
  branch=$(driver_state_get "$t" branch)
  done_list=$(driver_state_get "$t" 'done|join(" · ")')

  if [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$branch" ]; then
    if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      staged=$(git -C "$wt" status --porcelain 2>/dev/null | sed 's/^...//' | tr '\n' ' ')
      git -C "$wt" add -A -- . >/dev/null 2>&1
      ctype=$(driver_opt commit.parkType chore)
      cout=$(git -C "$wt" commit -m "$ctype(#$t): parked — $reason" 2>&1); crc=$?
      if [ "$crc" -ne 0 ]; then
        # NOT swallowed. The staged work is still only in this worktree, and the
        # worktree may be swept the moment this returns — so the reason the commit
        # was refused is the single most useful thing the brief can carry.
        commit_note="the parked work could NOT be committed ($ctype(#$t): …) — $(printf '%s' "$cout" | tr '\n' ' ' | cut -c1-300)"
        driver_say "   park: $commit_note"
      else
        driver_say "   park: committed as $ctype(#$t), staging $staged"
      fi
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
${staged:+Staged into the parked commit: $staged}
${commit_note:+⚠ $commit_note}
BRIEF
)" >/dev/null 2>&1 || true

  # The hold label goes on AND status:claimed comes off. Left on, a parked ticket
  # reads as in flight on the board while holding no claim at all — which is the
  # one state the reconciler's evidence rules cannot describe.
  swarm_gh issue edit "$t" --repo "$REPO_SLUG" \
    --add-label "$HOLD_LABEL" --remove-label "$LBL_CLAIMED" >/dev/null 2>&1 || true

  # Last. Everything above has to be true before the ticket is anyone else's.
  bash "$CL" release "$t" >/dev/null 2>&1 || true

  driver_say "⏸ #$t parked: $reason${question:+ — $question}"
  return "$DRIVER_E_QUESTION"
}
