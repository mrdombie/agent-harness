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

driver_park() { # <ticket> <reason> [question] [cause: person|driver]
  local t="${1:?driver_park: need a ticket}" reason="${2:-a refusal}" question="${3:-}"
  # WHOSE PARK IT IS. `person` means a question only somebody can answer; `driver`
  # means this kit, a gate or the project's own config stopped — and a person has
  # nothing to decide. The default is `person` so a caller that says nothing gets
  # the cautious label rather than the quiet one.
  local cause="${4:-person}"
  local wt branch done_list pushed=0 staged="" ctype cout crc=0 commit_note="" bundle_note=""
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
    if driver_push "$t" "$wt" "$branch" park; then
      pushed=1
    else
      driver_say "   park: the branch could not be pushed — say so rather than reporting a handover that does not exist: $DRIVER_PUSH_WHY"
      # AND THEN MAKE IT DURABLE ANYWAY. A push is what a park normally hands over
      # with, and a project's own pre-push can refuse one — on 2026-09-28 the UI
      # attestation gate did, and 9 commits stayed inside a worktree under
      # /var/folders that the system prunes. A bundle is a single file holding those
      # commits, restorable with `git fetch <file> <branch>`, and it costs a second.
      bundle_note=$(_driver_park_bundle "$t" "$wt" "$branch")
      [ -z "$bundle_note" ] || driver_say "   park: $bundle_note"
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
$(if [ "$cause" = "person" ]; then
    printf '**Needs:** %s\n**Resume:** answer that, clear `%s`, then run the driver again — it picks up from the last finished step.' \
      "${question:-a person to say how to proceed}" "$HOLD_LABEL"
  else
    # NOT UNDER "Needs:". A driver-caused park has nothing for a person to decide,
    # and printing its diagnostic there — "is the brief naming the wrong Skill, or
    # is it not installed?" — reads as a question somebody must answer, one line
    # above a Resume line saying nobody has to. The two said opposite things.
    printf '**Needs:** nothing from you. This is the driver, a gate or this project\x27s own configuration, so no hold label is on it.\n**What stopped it:** %s\n**Resume:** fix the cause above, then run the driver again — it picks up from the last finished step. Re-running it unchanged will stop here again.' \
      "${question:-see the step output on the run log}"
  fi)

${branch:+Branch \`$branch\`$([ "$pushed" -eq 1 ] && echo " is pushed; a draft pull request is open." || echo " could NOT be pushed — the work is only in $wt. The pre-push said: ${DRIVER_PUSH_WHY:-nothing it kept}")}
${staged:+Staged into the parked commit: $staged}
${commit_note:+⚠ $commit_note}
${bundle_note:+💾 $bundle_note}
BRIEF
)" >/dev/null 2>&1 || true

  # EVERY PARK GETS A STATUS, AND ONLY A QUESTION GETS THE HOLD.
  #
  # Measured on #10867's timeline at 2026-09-28T10:29:58Z: status:claimed came off,
  # the hold went on, and status:parked was never applied — so the ticket carried no
  # status label at all and dropped out of every status-keyed board.
  #
  # The hold is a person's label. #10907's park was caused by the kit's own defect
  # and put the hold on anyway; the next trial then refused at `start` in 40 seconds
  # because an agent clearing an approval label to unblock itself is the one thing
  # AGENTS forbids. So a park with nothing for a person to answer leaves the ticket
  # parked and nothing else, and the driver can pick it up again itself.
  if [ "$cause" = "person" ]; then
    swarm_gh issue edit "$t" --repo "$REPO_SLUG" \
      --add-label "$LBL_PARKED" --add-label "$HOLD_LABEL" \
      --remove-label "$LBL_CLAIMED" >/dev/null 2>&1 || true
  else
    swarm_gh issue edit "$t" --repo "$REPO_SLUG" \
      --add-label "$LBL_PARKED" \
      --remove-label "$LBL_CLAIMED" >/dev/null 2>&1 || true
  fi

  # Last. Everything above has to be true before the ticket is anyone else's.
  bash "$CL" release "$t" >/dev/null 2>&1 || true

  driver_say "⏸ #$t parked ($cause): $reason${question:+ — $question}"
  return "$DRIVER_E_QUESTION"
}

# _driver_park_bundle <ticket> <tree> <branch> — one file holding the commits the
# push could not hand over, under <worktreeRoot>/backups. Prints a sentence for the
# resume brief, or nothing when there was nothing to bundle.
#
# `$trunk..$branch` rather than the whole branch: the bundle then carries this
# ticket's commits with the trunk as a prerequisite, which is kilobytes instead of
# the repository. Restoring is `git fetch <file> <branch>` from a clone that has the
# trunk — which every clone does.
_driver_park_bundle() { # <ticket> <tree> <branch>
  local t="$1" wt="$2" branch="$3" dir f trunk r n
  trunk=""
  for r in "origin/$INTEGRATION_BRANCH" "$INTEGRATION_BRANCH"; do
    git -C "$wt" rev-parse --verify -q "$r" >/dev/null 2>&1 && { trunk="$r"; break; }
  done
  [ -n "$trunk" ] || return 0
  n=$(git -C "$wt" rev-list --count "$trunk..HEAD" 2>/dev/null)
  case "${n:-0}" in ''|*[!0-9]*|0) return 0 ;; esac
  dir="$(driver_worktree_root)" || return 0   # no root: no backup, never a bundle at /backups
  dir="$dir/backups"
  mkdir -p "$dir" 2>/dev/null || return 0
  f="$dir/$(printf '%s' "${BRANCH_PREFIX}$t" | tr '/' '-')-$(date +%Y%m%d-%H%M%S).bundle"
  if git -C "$wt" bundle create "$f" "$trunk..$branch" >/dev/null 2>&1; then
    printf 'the %s commit(s) the push could not hand over are bundled at %s — restore with `git fetch %s %s`' \
      "$n" "$f" "$f" "$branch"
  else
    rm -f "$f" 2>/dev/null
    printf 'the %s commit(s) could NOT be bundled either, so they exist only in %s' "$n" "$wt"
  fi
}
