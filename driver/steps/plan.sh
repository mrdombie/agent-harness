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

  schema=$(jq -r '.schema_change // false' "$ans")
  spec=$(jq -r '.data_model_spec // ""' "$ans")
  if [ "$schema" = "true" ] && [ -z "$spec" ]; then
    driver_say "✋ plan: it changes the schema and names no approved data model. A database change comes from a reviewed model, never from inside a ticket."
    return "$DRIVER_E_REFUSED"
  fi

  ntests=$(jq -r '(.tests // []) | length' "$ans")
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
  driver_state_set "$t" design_source "ticket-body"
  driver_say "   plan: $(jq -r '(.files // []) | length' "$ans") file(s), $ntests test(s); posted on #$t"
  return "$DRIVER_OK"
}
