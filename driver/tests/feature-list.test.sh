#!/usr/bin/env bash
# feature-list.test.sh — the feature list a plan writes (Anthropic's long-running harness):
# one user-visible behaviour per item, each with test steps, all failing; only `passes`
# ever changes, and editing or removing an item's steps is refused.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../feature-list.sh" || exit 1
EX="$HERE/../../briefs/examples/plan.valid-feature-list.json"

plan_with() { # <jq filter> — the shipped example, changed
  jq "$1" "$EX" > "$FIX/plan.json"; printf '%s' "$FIX/plan.json"
}
problems() { feature_list_problems "$1" 2>&1; }

echo "--- a plan's list is checked against how it is built ---"
want "the shipped example has no problem"                 "" "$(problems "$EX")"
want_in "a task naming no item: which part builds it?"    'task 2 .* names no item' "$(problems "$(plan_with 'del(.tasks[1].item)')")"
want_in "an item no task builds"                          'F2 has no task' "$(problems "$(plan_with 'del(.tasks[2])')")"
want_in "a task naming an item the list does not have"    'task 2 .* names F9' "$(problems "$(plan_with '.tasks[1].item = "F9"')")"
want_in "the ids run F1, F2, … in order"                  'ids run F1, F2' "$(problems "$(plan_with '.features[1].id = "F3" | .tasks[2].item = "F3"')")"
want_in "a browser check is not a test step"              'F1 .*browser' "$(problems "$(plan_with '.features[0].test = "e2e/saved.spec.ts" | .tasks[1].tests[0].file = "e2e/saved.spec.ts"')")"
want_in "  playwright too"                                'F2 .*browser' "$(problems "$(plan_with '.features[1].test = "tests/playwright/list.test.ts" | .tasks[2].tests[0].file = "tests/playwright/list.test.ts"')")"
want_in "the item's steps run in a test its part writes"  'F2 .*filter-list.test.tsx.* no task of F2' "$(problems "$(plan_with '.tasks[2].tests[0].file = "src/inbox/other.test.tsx"')")"
want_in "a foundation names its reason"                   'foundation tasks and no `foundation`' "$(problems "$(plan_with 'del(.foundation)')")"
want_in "a reason with no foundation task"                '`foundation` .* no task' "$(problems "$(plan_with 'del(.tasks[0]) | .features[0].needsFoundation = false')")"
want_in "an item cannot wait on a foundation there is not" 'F1 needs a foundation' "$(problems "$(plan_with 'del(.tasks[0]) | del(.foundation)')")"
want_in "expand/contract has a clean-up part to contract" 'expand-contract .* clean-up' "$(problems "$(plan_with 'del(.tasks[3])')")"
want "a refactor needs no clean-up"                       "" "$(problems "$(plan_with 'del(.tasks[3]) | .foundation.reason = "refactor"')")"
want_in "a mechanical change has no feature list"         'units .* no feature list' "$(problems "$(plan_with '.units = [range(5) as $i | {title:"u\($i)", files:[{path:"u\($i).ts",action:"modify"}], tests:[{file:"u\($i).test.ts",behaviour:"b"}]}]')")"
want "a plan with no list has nothing to check"          "" "$(problems "$(plan_with 'del(.features) | del(.foundation) | .tasks |= map(del(.item))')")"

echo "--- the list itself: every item failing, its parts not yet filed ---"
feature_list_of "$EX" 501 > "$FIX/list.json"
want "two items"                                          "F1 F2" "$(jq -r '[.items[].id] | join(" ")' "$FIX/list.json")"
want "  both failing"                                     "false false" "$(jq -r '[.items[].passes | tostring] | join(" ")' "$FIX/list.json")"
want "  the steps carried whole"                          "3" "$(jq '.items[0].steps | length' "$FIX/list.json")"
want "  which waits on the foundation"                    "true false" "$(jq -r '[.items[].needsFoundation | tostring] | join(" ")' "$FIX/list.json")"
want "  the foundation's reason kept"                     "expand-contract" "$(jq -r '.foundation.reason' "$FIX/list.json")"
want "  and the ticket"                                   "501" "$(jq -r '.ticket' "$FIX/list.json")"

echo "--- only passes may change ---"
cp "$FIX/list.json" "$FIX/old.json"
edit() { jq "$1" "$FIX/old.json" > "$FIX/new.json"; feature_list_guard "$FIX/old.json" "$FIX/new.json"; }
out=$(edit '.items[0].passes = true'); rc=$?
want "an item passing is the one change allowed"          "0" "$rc"
out=$(edit '.items[0].part = 811 | .items[1].part = 812 | .cleanup = {part: 813}'); rc=$?
want "  and naming its part, once filed"                  "0" "$rc"
out=$(edit '.items[1].steps[1] = "it reads anything at all"'); rc=$?
want "an item's steps edited: refused"                    "3" "$rc"
want_in "  saying which"                                  'F2' "$out"
out=$(edit '.items[0].steps |= .[0:1]'); rc=$?
want "a step removed: refused"                            "3" "$rc"
out=$(edit 'del(.items[1])'); rc=$?
want "an item removed: refused"                           "3" "$rc"
want_in "  saying which"                                  'F2 .*removed' "$out"
out=$(edit '.items += [{id:"F3",behaviour:"b",steps:["s"],test:"t.test.ts",passes:false}]'); rc=$?
want "an item added later: refused"                       "3" "$rc"
out=$(edit '.items[0].behaviour = "something easier"'); rc=$?
want "an item's behaviour edited: refused"                "3" "$rc"
out=$(edit '.items[0].test = "src/other.test.ts"'); rc=$?
want "its test moved: refused"                            "3" "$rc"
jq '.items[0].part = 811' "$FIX/old.json" > "$FIX/old2.json"; jq '.items[0].part = 900' "$FIX/old2.json" > "$FIX/new.json"
out=$(feature_list_guard "$FIX/old2.json" "$FIX/new.json"); rc=$?
want "a part once named does not move"                    "3" "$rc"

echo "--- kept in the ticket's driver state; a later list that edits it is refused ---"
driver_state_init 501
rc=0; feature_list_store 501 "$FIX/list.json" || rc=$?
want "the first list is stored"                           "0" "$rc"
want "  in the run record"                                "F1 F2" "$(jq -r '[.items[].id] | join(" ")' "$(driver_state_dir 501)/features.json")"
rc=0; feature_list_store 501 "$FIX/list.json" || rc=$?
want "the same list again: fine"                          "0" "$rc"
jq '.items[0].steps = ["press Save"]' "$FIX/list.json" > "$FIX/edited.json"
out=$(feature_list_store 501 "$FIX/edited.json" 2>&1); rc=$?
want "a re-plan that edits a step is refused"             "3" "$rc"
want "  and the stored list is untouched"                 "3" "$(jq '.items[0].steps | length' "$(driver_state_dir 501)/features.json")"

echo "--- an item passes; nothing else moves ---"
feature_list_set_pass "$FIX/list.json" F2 > "$FIX/passed.json"; rc=$?
want "F2 passes"                                          "0 false true" "$rc $(jq -r '[.items[].passes | tostring] | join(" ")' "$FIX/passed.json")"
rc=0; feature_list_guard "$FIX/list.json" "$FIX/passed.json" >/dev/null || rc=$?
want "  which the guard allows"                           "0" "$rc"
rc=0; feature_list_set_pass "$FIX/list.json" F7 >/dev/null 2>&1 || rc=$?
want "an item the list does not have"                     "1" "$rc"

echo "--- on the parent: a comment that reads back as the same list ---"
body=$(feature_list_comment "$FIX/passed.json")
want_in "it says what it is"                              '\*\*Feature list\*\*' "$body"
want_in "  item by item, passing or not"                  'F1\*\* .*\(failing\).*F2\*\* .*\(passes\)' "$(printf '%s' "$body" | tr '\n' ' ')"
want_in "  with its machine marker"                       '<!-- harness:feature-list -->' "$body"
jq -n --arg a "$(feature_list_comment "$FIX/list.json")" --arg b "an unrelated note" --arg c "$body" '[{body:$a},{body:$b},{body:$c}]' > "$FIX/comments.json"
want "every list on the ticket, oldest first"             "2" "$(feature_list_from_comments < "$FIX/comments.json" | grep -c .)"
want "  the newest is the one with F2 passing"            "true" "$(feature_list_from_comments < "$FIX/comments.json" | tail -1 | jq -r '.items[1].passes')"

suite_end "$FAILED"
