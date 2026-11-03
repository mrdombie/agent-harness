#!/usr/bin/env bash
# steps/record.sh — write the facts onto the claim, from the places that produced
# them.
#
#   driver_step_record <ticket>
#
# THE VERDICT COMES OFF THE REVIEWER'S OWN FILE AND FROM NOWHERE ELSE. Not from
# an argument, not from anything the build step said. A trailer an agent writes
# for itself is indistinguishable from one a reviewer earned, and the whole
# reason this is a separate step is that the two must not share a hand.
#
# It takes further arguments and ignores them, on purpose. A caller that tries to
# hand a verdict in gets the reviewer's, and a test proves it.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state.sh" || exit 1

driver_step_record() { # <ticket> [anything else — ignored]
  local t="${1:?driver_step_record: need a ticket}"
  local f verdict rounds sha
  export DRIVER_TICKET="$t"
  f="$(driver_state_dir "$t")/steps/review.json"

  if [ ! -f "$f" ]; then
    driver_say "✋ record: no review answer to record. A verdict with no reviewer behind it is the thing this step exists to make impossible."
    return "$DRIVER_E_REFUSED"
  fi
  verdict=$(jq -r '.verdict // ""' "$f" | tr '[:lower:]' '[:upper:]')
  if [ -z "$verdict" ]; then
    driver_say "✋ record: the review answer carries no verdict."
    return "$DRIVER_E_REFUSED"
  fi
  rounds=$(driver_state_count "$t" review)
  sha=$(driver_state_get "$t" claimed_at_sha)

  driver_state_set "$t" review_verdict "$verdict"
  bash "$CL" update "$t" \
    "review_verdict=$verdict" \
    "review_rounds=$rounds" \
    "claimed_at_sha=$sha" \
    "design_source=$(driver_state_get "$t" design_source)" \
    "design_ref=$(driver_state_get "$t" design_ref)" >/dev/null 2>&1 || true

  driver_say "   record: $verdict after $rounds round(s), claimed at ${sha:-unknown}"

  # EVERY FINDING HAS A CLASS (scripts/finding-class.sh): each one this change was handed
  # goes on the class ledger, and a class seen a second time anywhere is the PM's, once.
  # No model call, nothing back to the builder, and it never fails the step.
  local posted pr out l
  posted="$(driver_state_dir "$t")/steps/review.posted.jsonl"
  if [ -s "$posted" ]; then
    pr=$(driver_state_get "$t" pr); [ -n "$pr" ] || pr=$(driver_state_get "$t" repair_pr)
    out=$(bash "${DRIVER_FINDING_CLASS:-$KIT_ROOT/scripts/finding-class.sh}" record "$t" "$posted" "$pr" 2>&1) \
      || driver_say "⚠ record: the finding classes could not be recorded (it does not stop the ship)"
    while IFS= read -r l; do [ -z "$l" ] || driver_say "   record: ${l#finding-class: }"; done <<<"$out"
  fi
  return "$DRIVER_OK"
}
