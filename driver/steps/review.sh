#!/usr/bin/env bash
# steps/review.sh — one review call per round, at most two rounds, and then it
# ends.
#
#   driver_step_review <ticket>
#     0  ship
#     30 blockers, and a round left — go back to the build step
#     24 the answer was not a verdict this driver understands
#
# WHY A CEILING. The median screen fix took seven rejections and six hours from
# open to merge, against twenty-five minutes for everything else. A review loop
# with no end is not thoroughness; it is one late problem holding up six fixes.
# Two rounds, and then the loop ends — the ceiling is on the ROUNDS, not on the
# outcome.
#
# What happens to the findings after it depends on what kind they are. NON-BLOCKING
# ones leave as their own ticket, carrying the finding VERBATIM with the parent's
# programme label, so nothing is lost by ending the loop. A BLOCKER — a dead
# control, a broken flow, a data-honesty failure — does not ship and does not leave:
# the ship step refuses and names it. Filing it as a follow-up as well would put the
# same finding in two places with nobody owning either.
#
# ONE CALL, NOT SEVERAL AGENTS. The driver runs one review brief per round. What
# that brief does inside itself — how many reviewers it asks, in what order — is
# Superpowers' business. Inside a ticket, splitting the work belongs to the
# skill; the driver never starts several agents on one ticket.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1

driver_step_review() { # <ticket>
  local t="${1:?driver_step_review: need a ticket}"
  local rc round ans verdict nblock ans_file programme
  export DRIVER_TICKET="$t"

  round=$(driver_state_count "$t" review)
  rc=0; driver_ai_step "$t" review "$(driver_state_dir "$t")/steps/build.json" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  driver_state_bump "$t" review
  round=$((round + 1))
  ans_file="$(driver_state_dir "$t")/steps/review.json"

  verdict=$(jq -r '.verdict // ""' "$ans_file" | tr '[:lower:]' '[:upper:]')
  case "$verdict" in
    SHIP|BLOCKED) : ;;
    *)
      driver_say "✋ review: '$(jq -r '.verdict // "(none)"' "$ans_file")' is not a verdict. It is SHIP or BLOCKED; anything else is a reviewer that did not decide."
      return "$DRIVER_E_REFUSED" ;;
  esac

  nblock=$(jq -r '(.blockers // []) | length' "$ans_file")
  # `-le`, not `-lt`: the design's flowchart sends blockers back on round 1 OR 2,
  # so two rounds means two chances to fix, and the pass after them ships.
  if [ "$verdict" = "BLOCKED" ] && [ "${nblock:-0}" -gt 0 ] && [ "$round" -le "$DRIVER_MAX_REVIEW_ROUNDS" ]; then
    driver_say "✋ review round $round of $DRIVER_MAX_REVIEW_ROUNDS: $nblock blocker(s) — $(jq -r '[.blockers[] | "\(.file // "?"):\(.line // "?") \(.finding // .summary // "")"] | join("; ")' "$ans_file")"
    return "$DRIVER_E_REWORK"
  fi

  # Past the last rework round. What leaves as its own ticket is what is NON-BLOCKING:
  # a blocker is a dead control, a broken flow or a data-honesty failure, and none of
  # those ship — the ship step refuses and names them, so filing one as a follow-up
  # too would record the same finding in two places with nobody owning either.
  _driver_file_leftovers "$t" "$ans_file" "$round"
  driver_say "   review: $verdict after $round round(s)"
  return "$DRIVER_OK"
}

_driver_file_leftovers() { # <ticket> <review.json> <round>
  local t="$1" f="$2" round="$3" n programme i finding body
  n=$(jq -r '(.nonblocking // []) | length' "$f")
  [ "${n:-0}" -gt 0 ] || return 0
  programme=$(swarm_gh issue view "$t" --repo "$REPO_SLUG" --json labels \
    -q "[.labels[].name | select(startswith(\"$SWARM_PROGRAMME_PREFIX\"))] | first // \"\"" 2>/dev/null)

  i=0
  while [ "$i" -lt "$n" ]; do
    finding=$(jq -r --argjson i "$i" '(.nonblocking // [])[$i]
                | "\(.file // "?"):\(.line // "?") — \(.finding // .summary // "")"' "$f")
    body=$(printf 'Left over from the review of #%s after round %s of %s.\n\nThe finding, verbatim:\n\n> %s\n' \
             "$t" "$round" "$DRIVER_MAX_REVIEW_ROUNDS" "$finding")
    swarm_gh issue create --repo "$REPO_SLUG" \
      --title "review leftover from #$t: $(printf '%s' "$finding" | cut -c1-60)" \
      --body "$body" ${programme:+--label "$programme"} >/dev/null 2>&1 || true
    i=$((i+1))
  done
  driver_say "   review: $n finding(s) filed as follow-up ticket(s), each carrying the finding verbatim"
}
