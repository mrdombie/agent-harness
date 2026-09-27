#!/usr/bin/env bash
# plan.test.sh — the plan step is an AI call with two driver checks around it.
# The checks are the design's guarantee "no new table without an approved design
# spec", and the rule that a plan is posted where the next reader can find it.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/plan.sh" || exit 1
fix_issue 101 OPEN "status:claimed"
driver_state_init 101 --worktree "$REPO"
fix_brief plan superpowers:writing-plans

echo "--- an ordinary plan ---"
fix_ai plan '{"files":["a.sh"],"tests":["a.test.sh"],"risks":[]}' superpowers:writing-plans
out=$(driver_step_plan 101 2>&1); rc=$?
want "it finishes" "0" "$rc"
want_in "the plan is posted on the ticket" 'issue comment 101' "$(cat "$GH_LOG")"
want_in "and the design source is recorded" 'ticket-body|brainstormed' "$(driver_state_get 101 design_source)"

echo "--- a schema change with no approved data model is refused ---"
: > "$GH_LOG"
fix_ai plan '{"files":["schema.prisma"],"tests":["x"],"schema_change":true}' superpowers:writing-plans
out=$(driver_step_plan 101 2>&1); rc=$?
want "it refuses"  "24" "$rc"
want_in "and says what is missing" 'data model' "$out"
want_not_in "nothing is posted for a refused plan" 'issue comment' "$(cat "$GH_LOG")"

echo "--- a schema change that names its approved spec goes ahead ---"
fix_ai plan '{"files":["schema.prisma"],"tests":["x"],"schema_change":true,"data_model_spec":"docs/design/model.md"}' superpowers:writing-plans
rc=0; driver_step_plan 101 >/dev/null 2>&1 || rc=$?
want "an approved model is enough" "0" "$rc"

echo "--- the plan step asking a question parks, it does not guess ---"
fix_ai plan '{"question":"is the org the tenant root here?"}' superpowers:writing-plans
rc=0; driver_step_plan 101 >/dev/null 2>&1 || rc=$?
want "a question parks" "20" "$rc"

echo "--- writing-plans not invoked ---"
fix_ai plan '{"files":["a.sh"],"tests":["a"]}'
rc=0; driver_step_plan 101 >/dev/null 2>&1 || rc=$?
want "a plan with no plan skill parks" "21" "$rc"

echo "--- a plan that names no test is not a plan this driver can enforce ---"
fix_ai plan '{"files":["a.sh"],"tests":[]}' superpowers:writing-plans
out=$(driver_step_plan 101 2>&1); rc=$?
want "it refuses"                 "24" "$rc"
want_in "and says test-first is the point" 'test' "$out"

exit $FAILED
