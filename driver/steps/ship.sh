#!/usr/bin/env bash
# steps/ship.sh — push, pull request, hand off. Then stop.
#
#   driver_step_ship <ticket>
#
# THE PULL REQUEST IS OPENED AS A DRAFT and marked ready only once the review
# verdict is in. Not arming auto-merge is not enough on its own: an automerge
# workflow lands any green, non-draft, mergeable pull request, so draft is the
# only state that actually holds one. Auto is armed after ready, never before —
# it fires the instant CI goes green, whatever else is unfinished.
#
# THE RUN ENDS AT THE PUSH. It does not watch CI. Agents holding a slot while
# watching a run accounted for 36 of 123 agent-hours; a watcher brings one back
# if CI goes red or the pull request conflicts, which is work nobody has to be
# alive for.
#
# The body carries the review round count and the trunk SHA the ticket was
# claimed at, so both rules are checkable by a reader rather than promised by
# the agent that wrote them.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state.sh" || exit 1

driver_step_ship() { # <ticket>
  local t="${1:?driver_step_ship: need a ticket}"
  local wt branch dirty ahead verdict rounds sha head body
  export DRIVER_TICKET="$t"
  wt=$(driver_state_get "$t" worktree); branch=$(driver_state_get "$t" branch)

  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    driver_say "✋ ship: there is no worktree on the record for #$t."
    return "$DRIVER_E_REFUSED"
  fi
  [ -n "$branch" ] || branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ "$branch" = "$INTEGRATION_BRANCH" ] || [ "$branch" = "HEAD" ]; then
    driver_say "✋ ship: the worktree is on '$branch'. Nothing is ever pushed or merged straight to the trunk."
    return "$DRIVER_E_REFUSED"
  fi

  dirty=$(git -C "$wt" status --porcelain 2>/dev/null)
  if [ -n "$dirty" ]; then
    driver_say "✋ ship: uncommitted changes — $(printf '%s' "$dirty" | awk '{print $NF}' | tr '\n' ' '). A change that is not committed is a change the gates never read."
    return "$DRIVER_E_REFUSED"
  fi

  ahead=$(git -C "$wt" rev-list --count "$INTEGRATION_BRANCH..$branch" 2>/dev/null)
  if [ "${ahead:-0}" -eq 0 ]; then
    driver_say "✋ ship: $branch has no commits on it. There is nothing to ship."
    return "$DRIVER_E_REFUSED"
  fi

  git -C "$wt" push -q -u origin "$branch" >/dev/null 2>&1 || {
    driver_say "✋ ship: could not push $branch."
    return "$DRIVER_E_REFUSED"; }

  verdict=$(jq -r '.verdict // ""' "$(driver_state_dir "$t")/steps/review.json" 2>/dev/null | tr '[:lower:]' '[:upper:]')
  rounds=$(driver_state_count "$t" review)
  sha=$(driver_state_get "$t" claimed_at_sha)
  head=$(git -C "$wt" rev-parse HEAD)

  body=$(cat <<PRBODY
Closes #$t

Built by the driver: $(driver_state_get "$t" 'done|join(" → "))' 2>/dev/null || true)

Review rounds: ${rounds:-0} of $DRIVER_MAX_REVIEW_ROUNDS
Claimed at: ${sha:-unknown}
Head: $head
PRBODY
)
  swarm_gh pr create --repo "$REPO_SLUG" --draft \
    --base "$INTEGRATION_BRANCH" --head "$branch" \
    --title "#$t: $(driver_state_get "$t" 'ticket')" \
    --body "$body" >/dev/null 2>&1 || true

  # Ready, and only then auto. A draft is the only state an automerge workflow
  # will not land, so the draft is what holds the pull request while the review
  # is unfinished — and an unreviewed ticket stops HERE, with the work visible.
  if [ "$verdict" != "SHIP" ]; then
    driver_say "✋ ship: the review verdict is '${verdict:-none}', so the pull request stays a draft. The work is pushed and visible; it is not landing."
    return "$DRIVER_E_REFUSED"
  fi

  swarm_gh pr ready "$branch" --repo "$REPO_SLUG" >/dev/null 2>&1 || true
  swarm_gh pr merge "$branch" --repo "$REPO_SLUG" --auto --squash >/dev/null 2>&1 || true
  swarm_gh issue comment "$t" --repo "$REPO_SLUG" \
    --body "Handed off at $head — pull request ready, auto-merge armed. Not waiting for CI: a watcher brings an agent back on red or a conflict." >/dev/null 2>&1 || true

  driver_say "   ship: $branch pushed, pull request ready, auto-merge armed at $(printf '%s' "$head" | cut -c1-8). Handing off."
  return "$DRIVER_OK"
}
