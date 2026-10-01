#!/usr/bin/env bash
# plan.test.sh — the plan step is an AI call with two driver checks around it.
# The checks are the design's guarantee "no new table without an approved design
# spec", and the rule that a plan is posted where the next reader can find it.
#
# THE ANSWERS HERE ARE THE CONTRACT'S SHAPE. They were `{"files":…,"tests":…}` with
# `schema_change` beside them — four names briefs/schemas/plan.json does not have —
# so this suite passed while the shipped plan step refused every contract-valid
# answer on the 2026-09-27 trial. driver/tests/real-briefs.test.sh runs the same
# step against the shipped brief and the shipped example; this one keeps the
# per-branch cases, in the shape the validator enforces.
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
fix_ai plan '{"step":"plan","skills":["superpowers:writing-plans"],"status":"planned","designSource":"ticket-body","premise":{"verdict":"still-true","evidence":"a.sh:1 still does the old thing"},"tasks":[{"title":"t","files":[{"path":"a.sh","action":"modify"}],"tests":[{"file":"a.test.sh","behaviour":"it does the thing","redWhen":"the fix is deleted"}]}]}' superpowers:writing-plans
out=$(driver_step_plan 101 2>&1); rc=$?
want "it finishes" "0" "$rc"
want_in "the plan is posted on the ticket" 'issue comment 101' "$(cat "$GH_LOG")"
want_in "and the design source is recorded" 'ticket-body|brainstormed' "$(driver_state_get 101 design_source)"
want "no screen states named, none recorded" "[]" "$(driver_state_get 101 screen_states)"

echo "--- a schema change with no approved data model is refused ---"
: > "$GH_LOG"
fix_ai plan '{"step":"plan","skills":["superpowers:writing-plans"],"status":"planned","designSource":"ticket-body","premise":{"verdict":"still-true","evidence":"a.sh:1 still does the old thing"},"tasks":[{"title":"t","files":[{"path":"a.sh","action":"modify"}],"tests":[{"file":"a.test.sh","behaviour":"it does the thing","redWhen":"the fix is deleted"}]}],"schemaChange":true}' superpowers:writing-plans
out=$(driver_step_plan 101 2>&1); rc=$?
want "it refuses"  "24" "$rc"
want_in "and says what is missing" 'data model' "$out"
want_not_in "nothing is posted for a refused plan" 'issue comment' "$(cat "$GH_LOG")"

echo "--- a schema change that names its approved spec goes ahead ---"
fix_ai plan '{"step":"plan","skills":["superpowers:writing-plans"],"status":"planned","designSource":"ticket-body","premise":{"verdict":"still-true","evidence":"a.sh:1 still does the old thing"},"tasks":[{"title":"t","files":[{"path":"a.sh","action":"modify"}],"tests":[{"file":"a.test.sh","behaviour":"it does the thing","redWhen":"the fix is deleted"}]}],"schemaChange":true,"dataModelSpec":"docs/design/model.md"}' superpowers:writing-plans
rc=0; driver_step_plan 101 >/dev/null 2>&1 || rc=$?
want "an approved model is enough" "0" "$rc"

echo "--- the plan step asking a question parks, it does not guess ---"
fix_ai plan '{"step":"plan","skills":["superpowers:writing-plans"],"status":"park","designSource":"ticket-body","premise":{"verdict":"changed-shape","evidence":"the area was rewritten"},"question":"is the org the tenant root here?"}' superpowers:writing-plans
rc=0; driver_step_plan 101 >/dev/null 2>&1 || rc=$?
want "a question parks" "20" "$rc"

echo "--- writing-plans not invoked ---"
fix_ai plan '{"step":"plan","skills":["superpowers:writing-plans"],"status":"planned","designSource":"ticket-body","premise":{"verdict":"still-true","evidence":"a.sh:1 still does the old thing"},"tasks":[{"title":"t","files":[{"path":"a.sh","action":"modify"}],"tests":[{"file":"a.test.sh","behaviour":"it does the thing","redWhen":"the fix is deleted"}]}]}'
rc=0; driver_step_plan 101 >/dev/null 2>&1 || rc=$?
want "a plan with no plan skill parks" "21" "$rc"

echo "--- a plan that names no test is not a plan this driver can enforce ---"
# 24: this fixture writes no contract into DRIVER_SCHEMAS, so nothing validates the
# answer and the refusal is the STEP'S OWN count of tests under the tasks. That is
# exactly the reading the trial found broken, and real-briefs.test.sh runs the same
# step with the real contract in place.
# A task with no test cannot be expressed in the contract (tests is minItems 1), so
# the plan with NO TASKS is what a driver-enforceable plan is missing. The refusal is
# the driver's, not the validator's: status `planned` with an empty tasks array is
# what the contract's own if/then refuses, and a plan whose tasks carry no test at
# all is what this step has nothing to prove.
fix_ai plan '{"step":"plan","skills":["superpowers:writing-plans"],"status":"planned","designSource":"ticket-body","premise":{"verdict":"still-true","evidence":"a.sh:1 still does the old thing"},"tasks":[{"title":"t","files":[{"path":"a.sh","action":"modify"}],"tests":[]}]}' superpowers:writing-plans
out=$(driver_step_plan 101 2>&1); rc=$?
want "it refuses"                 "24" "$rc"
want_in "and says test-first is the point" 'test' "$out"

echo "--- the plan's screen states are recorded for the renderer (#11208) ---"
driver_state_init 120
fix_issue 120 OPEN "status:claimed"
fix_ai plan '{"step":"plan","skills":["superpowers:writing-plans"],"status":"planned","designSource":"debugged","premise":{"verdict":"still-true","evidence":"a.sh:1"},"tasks":[{"title":"t","files":[{"path":"a.sh","action":"modify"}],"tests":[{"file":"a.test.sh","behaviour":"b","redWhen":"r"}]}],"screenStates":[{"route":"/x","setup":["open the X tab"],"shows":"280 once"}]}' superpowers:writing-plans
driver_step_plan 120 >/dev/null 2>&1
want "they are on the record" "/x" "$(driver_state_get 120 screen_states | jq -r '.[0].route')"

exit $FAILED
