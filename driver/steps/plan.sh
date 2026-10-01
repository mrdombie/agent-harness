#!/usr/bin/env bash
# steps/plan.sh — the AI writes the plan; the driver decides whether it is one it
# can enforce, and puts it where the next reader will find it.
#
#   driver_step_plan <ticket>
#
# Two checks, both from the approved design's guarantee table:
#
#   NO NEW TABLE WITHOUT AN APPROVED DESIGN SPEC. A plan that changes the schema
#   must name the reviewed data model it is changing it to. A database change
#   invented inside a ticket is the one kind of mistake a later ticket cannot
#   undo cheaply, so this refuses rather than asks.
#
#   A PLAN WITH NO TESTS IS NOT A PLAN THIS DRIVER CAN ENFORCE. Every guarantee
#   downstream is built on the build step proving a test red then green. A plan
#   that names none has removed the only thing the driver can check.
#
# And one piece of bookkeeping: the plan is posted as a comment on the ticket,
# never committed into the product repo as a per-ticket document. The comment
# outlives the worktree, which the document would not.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1

driver_step_plan() { # <ticket>
  local t="${1:?driver_step_plan: need a ticket}"
  local rc ans schema spec ntests
  export DRIVER_TICKET="$t"

  rc=0; driver_ai_step "$t" plan || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  ans="$(driver_state_dir "$t")/steps/plan.json"

  # THE KEYS ARE THE CONTRACT'S KEYS. This read four names briefs/schemas/plan.json
  # does not have — `.schema_change`, `.data_model_spec`, `.tests` and `.files` — and
  # the contract is `additionalProperties: false`, so an answer carrying them was
  # refused by the validator and an answer meeting the contract was refused here.
  # Measured on the 2026-09-27 trial: the kit's own valid example and both real
  # plans all validated, all read `.tests` as length 0, and all three parked on
  # "it names no test". Tests and files live under each task; the schema flag and
  # its model are declared properties, and the contract now carries the rule as
  # well, so the two cannot drift apart again.
  schema=$(jq -r '.schemaChange // false' "$ans")
  spec=$(jq -r '.dataModelSpec // ""' "$ans")
  if [ "$schema" = "true" ] && [ -z "$spec" ]; then
    driver_say "✋ plan: it changes the schema and names no approved data model. A database change comes from a reviewed model, never from inside a ticket."
    return "$DRIVER_E_REFUSED"
  fi

  ntests=$(jq -r '[.tasks[]?.tests[]?] | length' "$ans")
  if [ "${ntests:-0}" -eq 0 ]; then
    driver_say "✋ plan: it names no test. Every guarantee after this one is the build step proving a test red then green; a plan with no test has nothing to prove."
    return "$DRIVER_E_REFUSED"
  fi

  # Where the design goes. On the ticket, not into the repo: the comment outlives
  # the worktree and is what the next reader — or the next agent — opens.
  swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "$(
    printf '**Plan** (driver step 2 of 7)\n\n```json\n%s\n```\n' "$(cat "$ans")"
  )" >/dev/null 2>&1 || true

  # The ticket stood in for brainstorming — an unattended agent never calls it,
  # because it waits on a person. Say which, rather than leaving it to be guessed.
  # THE PLAN SAYS WHICH. `designSource` is a required property of the contract with
  # three values, and writing a constant here threw away the only one of the three
  # the driver cannot work out for itself — a bug ticket whose plan followed a
  # reproduction is `debugged`, and /finish cross-checks that against the spec gate.
  driver_state_set "$t" design_source "$(jq -r '.designSource // "ticket-body"' "$ans")"
  # AND WHAT IT POINTS AT. `approved-picture` is the value this project's process
  # turns on — a design a person approved before the build — and the compare step
  # holds the renders against exactly this reference. The contract requires the two
  # together, so reading one without the other is how they come apart.
  driver_state_set "$t" design_ref "$(jq -r '.designRef // ""' "$ans")"
  # The screen states the change shows in, for the renderer to capture exactly.
  driver_state_set "$t" screen_states "$(jq -c '.screenStates // []' "$ans")"
  driver_say "   plan: $(jq -r '[.tasks[]?] | length' "$ans") task(s), $(jq -r '[.tasks[]?.files[]?] | length' "$ans") file(s), $ntests test(s); posted on #$t"
  return "$DRIVER_OK"
}
