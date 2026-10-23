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
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
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

echo "--- more than driver.split.maxTasks build tasks: split before anything is built ---"
# Builds of 6-8 planned tasks ran about two hours a ticket; "no batch tickets".
plan_of() { # <tasks> — a valid plan answer with that many build tasks
  jq -nc --argjson n "$1" '{step:"plan",skills:["superpowers:writing-plans"],status:"planned",designSource:"ticket-body",
    premise:{verdict:"still-true",evidence:"a.sh:1"},
    tasks:[range($n) | {title:"task \(. + 1)",files:[{path:"f\(. + 1).sh",action:"modify"}],tests:[{file:"f\(. + 1).test.sh",behaviour:"b",redWhen:"r"}]}]}'
}
fix_issue 151 OPEN "status:claimed,P1,area:inbox,screen:inbox,needs:human-approval"; driver_state_init 151 --worktree "$REPO"
fix_ai plan "$(plan_of 4)" superpowers:writing-plans
: > "$GH_LOG"; out=$(driver_step_plan 151 2>&1); rc=$?
want "4 tasks: the run ends clean, nothing built" "$DRIVER_E_NOOP" "$rc"
want "  one ticket a task"                      "4" "$(grep -c '^issue create' "$GH_LOG")"
want_in "  each ready, with the parent's priority, area and screen" 'issue create .*--label status:ready --label P1 --label area:inbox --label screen:inbox' "$(tr '\n' ' ' < "$GH_LOG")"
want_not_in "  a person's hold is not inherited"   'label needs:human-approval' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "  each names its part and the parent"    'Ticket 151 — part 2 of 4: task 2' "$(grep '^issue create' "$GH_LOG" | sed -n 2p)"
want_in "  the parent is told"                     'issue comment 151 .*Split.* into #999' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "  and closed as split"                    'issue close 151' "$(cat "$GH_LOG")"
want_in "  the run says why"                       'split into .* the parent closed as split' "$out"
fix_issue 152 OPEN "status:claimed,P1"; driver_state_init 152 --worktree "$REPO"
fix_ai plan "$(plan_of 3)" superpowers:writing-plans
: > "$GH_LOG"; out=$(driver_step_plan 152 2>&1); rc=$?
want "3 tasks: it builds"                         "0" "$rc"
want "  nothing is filed"                         "0" "$(grep -c '^issue create' "$GH_LOG")"
jq '.title = "Big — part 2 of 4: task 2"' "$FIX/gh/issue-152.json" > "$FIX/gh/i152" && mv "$FIX/gh/i152" "$FIX/gh/issue-152.json"
fix_ai plan "$(plan_of 5)" superpowers:writing-plans
: > "$GH_LOG"; out=$(driver_step_plan 152 2>&1); rc=$?
want "a part of a split is never split again"     "0 0" "$rc $(grep -c '^issue create' "$GH_LOG")"
fix_issue 153 OPEN "status:claimed"; driver_state_init 153 --worktree "$REPO"; driver_state_set 153 mode repair
fix_ai plan "$(plan_of 6)" superpowers:writing-plans
: > "$GH_LOG"; out=$(driver_step_plan 153 2>&1); rc=$?
want "a repair is never split"                    "0 0" "$rc $(grep -c '^issue create' "$GH_LOG")"
fix_issue 154 OPEN "status:claimed"; driver_state_init 154 --worktree "$REPO"
jq '.driver.split.maxTasks = 0' "$HARNESS_CFG" > "$FIX/cfg-t0.json"
fix_ai plan "$(plan_of 6)" superpowers:writing-plans
: > "$GH_LOG"; out=$(HARNESS_CFG="$FIX/cfg-t0.json" driver_step_plan 154 2>&1); rc=$?
want "maxTasks 0 turns it off"                    "0 0" "$rc $(grep -c '^issue create' "$GH_LOG")"

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
fix_ai plan '{"step":"plan","skills":["superpowers:writing-plans"],"status":"planned","designSource":"debugged","premise":{"verdict":"still-true","evidence":"a.sh:1"},"tasks":[{"title":"t","files":[{"path":"a.sh","action":"modify"}],"tests":[{"file":"a.test.sh","behaviour":"b","redWhen":"r"}]}],"screenChange":"visible","screenStates":[{"route":"/x","setup":["open the X tab"],"shows":"280 once"}]}' superpowers:writing-plans
driver_step_plan 120 >/dev/null 2>&1
want "they are on the record" "/x" "$(driver_state_get 120 screen_states | jq -r '.[0].route')"
want "and so is whether the change is visible" "visible" "$(driver_state_get 120 screen_change)"

echo "--- a repo-settings change is the PM's, after the merge, never a task ---"
driver_state_init 130
fix_issue 130 OPEN "status:claimed"
: > "$GH_LOG"
fix_ai plan '{"step":"plan","skills":["superpowers:writing-plans"],"status":"planned","designSource":"ticket-body","premise":{"verdict":"still-true","evidence":"a.sh:1"},"tasks":[{"title":"t","files":[{"path":"a.sh","action":"modify"}],"tests":[{"file":"a.test.sh","behaviour":"b","redWhen":"r"}]}],"pmAfterMerge":["add Lesson as a required check on the develop ruleset: gh api -X PUT repos/o/r/rulesets/1 --input r.json"]}' superpowers:writing-plans
out=$(driver_step_plan 130 2>&1); rc=$?
want "the plan goes ahead" "0" "$rc"
want_in "the change is posted on the ticket as a PM step" 'PM step after merge' "$(cat "$GH_LOG")"
want_in "and kept for the PR body" 'required check' "$(driver_state_get 130 pm_after_merge)"
want_in "and the run says so" 'handed to the PM' "$out"

suite_end "$FAILED"
