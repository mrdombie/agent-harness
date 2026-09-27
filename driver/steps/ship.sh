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
  local wt branch dirty ahead verdict rounds sha head body trunk r title nblock blist
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

  # origin's ref FIRST, exactly as the start step resolves it. A clone whose only
  # develop is origin/develop has no local ref of that name, and then rev-list
  # errors, `ahead` comes back empty, and an empty string read as 0 says a finished
  # branch has no commits — which refuses, and refuses again on every resume,
  # because ship is by then the only unfinished step.
  trunk=""
  for r in "origin/$INTEGRATION_BRANCH" "$INTEGRATION_BRANCH"; do
    git -C "$wt" rev-parse --verify -q "$r" >/dev/null 2>&1 && { trunk="$r"; break; }
  done
  if [ -z "$trunk" ]; then
    driver_say "✋ ship: neither origin/$INTEGRATION_BRANCH nor $INTEGRATION_BRANCH resolves in $wt, so there is nothing to measure the branch against."
    return "$DRIVER_E_REFUSED"
  fi
  ahead=$(git -C "$wt" rev-list --count "$trunk..$branch" 2>/dev/null)
  case "$ahead" in ''|*[!0-9]*)
    driver_say "✋ ship: could not count $branch against $trunk. An unreadable count is not a count of zero."
    return "$DRIVER_E_REFUSED" ;;
  esac
  if [ "$ahead" -eq 0 ]; then
    driver_say "✋ ship: $branch has no commits on it against $trunk. There is nothing to ship."
    return "$DRIVER_E_REFUSED"
  fi

  git -C "$wt" push -q -u origin "$branch" >/dev/null 2>&1 || {
    driver_say "✋ ship: could not push $branch."
    return "$DRIVER_E_REFUSED"; }

  verdict=$(jq -r '.verdict // ""' "$(driver_state_dir "$t")/steps/review.json" 2>/dev/null | tr '[:lower:]' '[:upper:]')
  rounds=$(driver_state_count "$t" review)
  # The ticket's own subject. On the record when the start step put it there; asked
  # for otherwise, because a pull request titled with the number twice tells a
  # reader nothing, and the title is what a squash merge ships as its commit.
  title=$(driver_state_get "$t" title)
  [ -n "$title" ] || title=$(swarm_gh issue view "$t" --repo "$REPO_SLUG" --json title -q .title 2>/dev/null)
  [ -n "$title" ] || title="see the ticket"
  sha=$(driver_state_get "$t" claimed_at_sha)
  head=$(git -C "$wt" rev-parse HEAD)

  body=$(cat <<PRBODY
Closes #$t

Built by the driver: $(driver_state_get "$t" 'done|join(" → ")')

Review rounds: ${rounds:-0} of $DRIVER_MAX_REVIEW_ROUNDS
Claimed at: ${sha:-unknown}
Head: $head
PRBODY
)
  # `|| true` on the create alone is right: a park may already have opened the draft,
  # and a resume finds it there. What is NOT right is taking the create's silence as a
  # pull request existing — so the next line asks.
  swarm_gh pr create --repo "$REPO_SLUG" --draft \
    --base "$INTEGRATION_BRANCH" --head "$branch" \
    --title "#$t: $title" \
    --body "$body" >/dev/null 2>&1 || true
  if ! swarm_gh pr view "$branch" --repo "$REPO_SLUG" --json number >/dev/null 2>&1; then
    driver_say "✋ ship: $branch is pushed and there is no pull request for it. An expired token, a protected base or a rate limit all look like this, and every write here is wrapped — so this asks rather than announcing a hand-off that does not exist."
    return "$DRIVER_E_REFUSED"
  fi

  # Ready, and only then auto. A draft is the only state an automerge workflow
  # will not land, so the draft is what holds the pull request while the review
  # is unfinished — and an unreviewed ticket stops HERE, with the work visible.
  if [ "$verdict" != "SHIP" ]; then
    # NAME WHAT BLOCKS, not the code. review is recorded finished by the time this
    # runs, so every resume walks straight back to here and refuses identically —
    # and what blocks is every finding graded critical or major, none of which ship.
    # Minors left as a follow-up and Nits were dropped in the review step, so reading
    # the whole list here would hand the operator polish to "clear" before a merge.
    # The operator has to be handed the findings, or the ticket is simply stuck with
    # "exit 24" as its only explanation.
    nblock=$(jq -r '[.findings[]? | select(.grade == "critical" or .grade == "major")] | length' "$(driver_state_dir "$t")/steps/review.json" 2>/dev/null)
    driver_say "✋ ship: the review verdict is '${verdict:-none}' after ${rounds:-0} of $DRIVER_MAX_REVIEW_ROUNDS round(s), so the pull request stays a draft. The work is pushed and visible; it is not landing."
    if [ "${nblock:-0}" -gt 0 ]; then
      blist=$(jq -r '[.findings[]? | select(.grade == "critical" or .grade == "major") | "\(.grade) \(.file // "?"):\(.line // "?") \(.summary // "")"] | join("; ")' "$(driver_state_dir "$t")/steps/review.json" 2>/dev/null)
      driver_say "   ship: ${nblock} critical/major finding(s) to clear — $blist"
      # ON THE RECORD, not just on stdout. driver_say writes the terminal and a log
      # file inside the state directory — the one place a handover must not depend on,
      # because a park exists to be read by somebody who is not this process. The
      # orchestrator puts this note in the park brief.
      driver_state_set "$t" park_note "${nblock} critical/major finding(s) from the review to clear: $blist"
    fi
    return "$DRIVER_E_REFUSED"
  fi

  # THESE TWO ARE THE HAND-OFF, so their exit codes are read. A draft nobody marked
  # ready never lands, and an unarmed pull request waits for a person who was told the
  # run was finished — both of which read exactly like success when the call is wrapped.
  if ! swarm_gh pr ready "$branch" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    driver_say "✋ ship: the pull request for $branch could not be marked ready, so it is still a draft and cannot land. The work is pushed and reviewed; the hand-off is not done."
    return "$DRIVER_E_REFUSED"
  fi
  if ! swarm_gh pr merge "$branch" --repo "$REPO_SLUG" --auto --squash >/dev/null 2>&1; then
    driver_say "✋ ship: auto-merge would not arm on the pull request for $branch. It is ready and reviewed, and nothing will land it — so this says so rather than handing off."
    return "$DRIVER_E_REFUSED"
  fi
  swarm_gh issue comment "$t" --repo "$REPO_SLUG" \
    --body "Handed off at $head — pull request ready, auto-merge armed. Not waiting for CI: a watcher brings an agent back on red or a conflict." >/dev/null 2>&1 || true

  driver_say "   ship: $branch pushed, pull request ready, auto-merge armed at $(printf '%s' "$head" | cut -c1-8). Handing off."
  return "$DRIVER_OK"
}
