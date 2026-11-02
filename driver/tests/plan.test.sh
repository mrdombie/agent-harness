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

echo "--- the old trigger is gone: many tasks and many files build as one change ---"
# Owner, 2026-11-02: split by behaviour, never by task or file count (it was >3 tasks / >20 files).
plan_of() { # <tasks> — a valid plan answer with that many build tasks and no feature list
  jq -nc --argjson n "$1" '{step:"plan",skills:["superpowers:writing-plans"],status:"planned",designSource:"ticket-body",
    premise:{verdict:"still-true",evidence:"a.sh:1"},
    tasks:[range($n) | {title:"task \(. + 1)",files:([range(6) as $k | {path:"f\(. + 1)-\($k).sh",action:"modify"}]),tests:[{file:"f\(. + 1).test.sh",behaviour:"b",redWhen:"r"}]}]}'
}
printf '#!/usr/bin/env bash\necho "$*" >> "$FIX/repoint.log"\n' > "$BIN/repoint"; chmod +x "$BIN/repoint"; export DRIVER_REPOINT="$BIN/repoint"
# Each issue create answers the next number, so a part's wait names the part it waits on.
mv "$BIN/gh" "$BIN/gh-base"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = "issue create" ]; then
  printf '%s\n' "$*" >> "$GH_LOG"
  n=$(( $(cat "$FIX/next-issue" 2>/dev/null || echo 800) + 1 )); echo "$n" > "$FIX/next-issue"
  printf '%s\n' "$*" | tr '\n' ' ' > "$FIX/created-$n.txt"
  echo "https://github.com/acme/widgets/issues/$n"; exit 0
fi
exec "$FIX/bin/gh-base" "$@"
SH
chmod +x "$BIN/gh"
fresh() { : > "$GH_LOG"; : > "$FIX/repoint.log"; echo 800 > "$FIX/next-issue"; rm -f "$FIX"/created-*.txt; }
created() { cat "$FIX/created-$1.txt" 2>/dev/null; } # <n> — the whole create call, one line
fix_issue 150 OPEN "status:claimed,P1"; driver_state_init 150 --worktree "$REPO"
fix_ai plan "$(plan_of 6)" superpowers:writing-plans
fresh; out=$(driver_step_plan 150 2>&1); rc=$?
want "6 tasks over 36 files: it builds, nothing filed"  "0 0" "$rc $(grep -c '^issue create' "$GH_LOG")"

echo "--- a feature list of several behaviours: one part each, side by side ---"
EXF="$HERE/../../briefs/examples/plan.valid-feature-list.json"
fix_issue 151 OPEN "status:claimed,P1,area:inbox,screen:inbox,needs:human-approval"; driver_state_init 151 --worktree "$REPO"
fix_ai plan "$(jq -c . "$EXF")" superpowers:writing-plans
fresh; out=$(driver_step_plan 151 2>&1); rc=$?
log=$(tr '\n' ' ' < "$GH_LOG")
want "the run ends clean, nothing built"           "$DRIVER_E_NOOP" "$rc"
want "  foundation, F1, F2 and the clean-up: four parts" "4" "$(grep -c '^issue create' "$GH_LOG")"
c1=$(created 801); c2=$(created 802); c3=$(created 803); c4=$(created 804)
want_in "  the foundation goes first, naming its reason" 'part 1 of 4: foundation .*expand-contract' "$c1"
want_in "  and is ready"                           '--label status:ready --label P1 --label area:inbox --label screen:inbox' "$c1"
want_in "  F1 builds on it, so it waits for it"    'part 2 of 4: F1 A person saves.*--label status:gated' "$c2"
want_in "  on the foundation part, as the unblocker reads it" 'Blocked until #801 merges' "$c2"
want_in "  F2 does not need it: ready from the start" 'part 3 of 4: F2 An empty filter list.*--label status:ready' "$c3"
want_not_in "  and waits on nothing"                'Blocked until' "$c3"
want_in "  each item part carries its steps and its test" 'Test steps.*1\. open the list with nothing saved.*src/inbox/filter-list.test.tsx' "$c3"
want_in "  and says which item of which list it is" '<!-- harness:feature-item parent=151 id=F2 test=src/inbox/filter-list.test.tsx -->' "$c3"
want_in "  only its own tasks' files, not the whole plan's" 'Files:\*\* src/inbox/FilterList.tsx' "$c3"
want_in "  the clean-up goes last, once every behaviour has landed" 'part 4 of 4: clean-up.*Blocked until #802, #803 merge.*--label status:gated' "$c4"
want_not_in "  a person's hold is not inherited"        'label needs:human-approval' "$log"
want_in "  the parent carries the list, every item failing, each with its part" 'issue comment 151 .*\*\*Feature list\*\*.*F1\*\* .*#802 \(failing\).*F2\*\* .*#803 \(failing\)' "$log"
want_in "  the parent is told how it was split"     'issue comment 151 .*Split by behaviour.* into #801 #802 #803 #804' "$log"
want_in "  and why it stays not-done until the list passes" 'every item passes and its clean-up part #804 has merged' "$log"
want_in "  closed as split, so nothing claims it again" 'issue close 151 --repo acme/widgets --reason not planned' "$log"
want "  the waits naming it are re-pointed at its parts" "--repoint 151 801 802 803 804" "$(cat "$FIX/repoint.log")"
want "  kept in the driver state with its parts"   "802 803 804" "$(jq -r '[.items[].part, .cleanup.part] | map(tostring) | join(" ")' "$(driver_state_dir 151)/features.json")"
want_in "  the run says why"                       'split by behaviour into 4 parts' "$out"

echo "--- no foundation: every item ready at once, none chained ---"
plan_feats() { # <items> — a valid plan with that many behaviours, one task each
  jq -nc --argjson n "$1" '{step:"plan",skills:["superpowers:writing-plans"],status:"planned",designSource:"ticket-body",
    premise:{verdict:"still-true",evidence:"a.sh:1"},
    features:[range($n) | {id:"F\(. + 1)",behaviour:"behaviour \(. + 1)",steps:["step \(. + 1)"],test:"f\(. + 1).test.sh",passes:false}],
    tasks:[range($n) | {item:"F\(. + 1)",title:"task \(. + 1)",files:[{path:"f\(. + 1).sh",action:"modify"}],tests:[{file:"f\(. + 1).test.sh",behaviour:"b",redWhen:"r"}]}]}'
}
fix_issue 152 OPEN "status:claimed,P1"; driver_state_init 152 --worktree "$REPO"
fix_ai plan "$(plan_feats 3)" superpowers:writing-plans
fresh; out=$(driver_step_plan 152 2>&1); rc=$?
want "three behaviours: three parts"               "$DRIVER_E_NOOP 3" "$rc $(grep -c '^issue create' "$GH_LOG")"
want "  all three ready"                           "3" "$(cat "$FIX"/created-*.txt | tr ' ' '\n' | grep -c -x 'status:ready')"
want "  none waits on another"                     "0" "$(grep -c 'Blocked until' "$GH_LOG")"

echo "--- one behaviour: built here, its list kept and posted ---"
fix_issue 153 OPEN "status:claimed,P1"; driver_state_init 153 --worktree "$REPO"
fix_ai plan "$(plan_feats 1)" superpowers:writing-plans
fresh; out=$(driver_step_plan 153 2>&1); rc=$?
want "it builds, nothing filed"                    "0 0" "$rc $(grep -c '^issue create' "$GH_LOG")"
want "  its list is in the driver state"           "F1 false" "$(jq -r '.items[0] | "\(.id) \(.passes)"' "$(driver_state_dir 153)/features.json")"
want_in "  and on the ticket"                      'issue comment 153 .*\*\*Feature list\*\*' "$(tr '\n' ' ' < "$GH_LOG")"

echo "--- a re-plan may not edit or remove an item's steps ---"
jq -c '.features[0].steps = ["something easier"]' <<<"$(plan_feats 1)" > "$FIX/edited.json"
fix_ai plan "$(cat "$FIX/edited.json")" superpowers:writing-plans
fresh; out=$(driver_step_plan 153 2>&1); rc=$?
want "an edited step is refused"                   "$DRIVER_E_REFUSED" "$rc"
want_in "  saying which item"                      'F1 was edited' "$out"
want "  the kept list is untouched"                "step 1" "$(jq -r '.items[0].steps[0]' "$(driver_state_dir 153)/features.json")"
fix_ai plan "$(plan_feats 2 | jq -c '.features |= .[1:] | .features[0].id = "F1" | .tasks |= .[1:] | .tasks[0].item = "F1"')" superpowers:writing-plans
fresh; out=$(driver_step_plan 153 2>&1); rc=$?
want "an item swapped for another is refused"      "$DRIVER_E_REFUSED" "$rc"

echo "--- a feature ticket writes its list: asked once, then refused ---"
fix_issue 154 OPEN "status:claimed,type:feature"; driver_state_init 154 --worktree "$REPO"
fix_ai plan "$(plan_of 1)" superpowers:writing-plans
fix_ai plan "$(plan_feats 1)" superpowers:writing-plans; mv "$FIX/ai/plan.jsonl" "$FIX/ai/plan.then.jsonl"
fix_ai plan "$(plan_of 1)" superpowers:writing-plans
fresh; : > "$CLAUDE_LOG"; out=$(driver_step_plan 154 2>&1); rc=$?
want "no list: asked once more, and the second answer has one" "0 2" "$rc $(grep -c '^plan$' "$CLAUDE_LOG")"
want_in "  told what is missing"                   'no feature list' "$(cat "$FIX/claude-stdin-plan.txt")"
fix_issue 155 OPEN "status:claimed,type:feature"; driver_state_init 155 --worktree "$REPO"
fix_ai plan "$(plan_of 1)" superpowers:writing-plans
fresh; out=$(driver_step_plan 155 2>&1); rc=$?
want "still no list: refused"                      "$DRIVER_E_REFUSED" "$rc"
want_in "  saying so"                              'feature ticket .* no feature list' "$out"

echo "--- a list built by layer, not by item: asked once, then refused ---"
fix_issue 157 OPEN "status:claimed"; driver_state_init 157 --worktree "$REPO"
fix_ai plan "$(plan_feats 2 | jq -c 'del(.tasks[1].item)')" superpowers:writing-plans
fresh; out=$(driver_step_plan 157 2>&1); rc=$?
want "a task naming no item, twice: refused"       "$DRIVER_E_REFUSED" "$rc"
want_in "  naming the problem"                     'task 2 .* names no item' "$out"
want "  nothing filed"                             "0" "$(grep -c '^issue create' "$GH_LOG")"

echo "--- a mechanical change fans out like /batch: one part a unit, all at once, no list ---"
EXM="$HERE/../../briefs/examples/plan.valid-mechanical.json"
fix_issue 158 OPEN "status:claimed,P2,area:inbox"; driver_state_init 158 --worktree "$REPO"
fix_ai plan "$(jq -c . "$EXM")" superpowers:writing-plans
fresh; out=$(driver_step_plan 158 2>&1); rc=$?
log=$(tr '\n' ' ' < "$GH_LOG")
want "five units: five parts"                      "$DRIVER_E_NOOP 5" "$rc $(grep -c '^issue create' "$GH_LOG")"
want "  every one ready"                           "5" "$(cat "$FIX"/created-*.txt | grep -o -- '--label status:ready --label P2 --label area:inbox' | grep -c .)"
want "  none waits"                                "0" "$(grep -c 'Blocked until' "$GH_LOG")"
want_in "  each carries the recipe and its own unit" 'part 3 of 5: people.*Replace oldLog.*src/people/index.ts' "$(created 803)"
want_not_in "  no feature list"                     'Feature list' "$log"
want_in "  the parent is told"                     'issue comment 158 .*fanned out like /batch.* into #801 #802 #803 #804 #805' "$log"
want_in "  and closed as split"                    'issue close 158' "$log"

echo "--- a part of a split is never split again, and runs its item's steps ---"
fix_issue 159 OPEN "status:claimed"; jq '.title = "Big — part 2 of 4: F1 save a filter" | .body = "Part 2 of 4, split from #151.\n<!-- harness:feature-item parent=151 id=F1 test=f1.test.sh -->"' "$FIX/gh/issue-159.json" > "$FIX/i159" && mv "$FIX/i159" "$FIX/gh/issue-159.json"
driver_state_init 159 --worktree "$REPO"
fix_ai plan "$(plan_feats 3)" superpowers:writing-plans
fresh; out=$(driver_step_plan 159 2>&1); rc=$?
want "a part builds"                               "0 0" "$rc $(grep -c '^issue create' "$GH_LOG")"
fix_ai plan "$(plan_feats 2 | jq -c '.tasks[0].tests[0].file = "other.test.sh" | del(.features) | .tasks |= map(del(.item))')" superpowers:writing-plans
fresh; out=$(driver_step_plan 159 2>&1); rc=$?
want "a part whose plan drops its item's test, twice: refused" "$DRIVER_E_REFUSED" "$rc"
want_in "  naming the test its steps run in"       'F1 .*f1.test.sh' "$out"
fix_issue 160 OPEN "status:claimed"; driver_state_init 160 --worktree "$REPO"; driver_state_set 160 mode repair
fix_ai plan "$(plan_feats 3)" superpowers:writing-plans
fresh; out=$(driver_step_plan 160 2>&1); rc=$?
want "a repair is never split"                    "0 0" "$rc $(grep -c '^issue create' "$GH_LOG")"

echo "--- a part carries the parent's approved picture and its answers, by link ---"
jq -n '{number:156, state:"OPEN", title:"Ticket 156", labels:[{name:"status:claimed"},{name:"screen:redesign"}], body:"spec",
  comments:[{url:"https://github.com/acme/widgets/issues/156#issuecomment-1", body:"**Picture for any machine** — `desk-mock.html`, approved for #156\n\n<!-- picture-approve: sha256=aaaaaaaaaaaabbbbbbbbbbbbccccccccccccddddddddddddeeeeeeeeeeeeffff file=desk-mock.html gist=abc -->"},
            {url:"https://github.com/acme/widgets/issues/156#issuecomment-2", body:"**The owner answered** (`decision:156:scope`): keep the old filter"},
            {url:"https://github.com/acme/widgets/issues/156#issuecomment-3", body:"an unrelated note"}]}' > "$FIX/gh/issue-156.json"
driver_state_init 156 --worktree "$REPO"
fix_ai plan "$(plan_feats 2)" superpowers:writing-plans
fresh; out=$(driver_step_plan 156 2>&1); rc=$?
log=$(tr '\n' ' ' < "$GH_LOG")
want "it splits"                                   "$DRIVER_E_NOOP" "$rc"
want_in "  each part links the parent's approval"  'Approved picture — the parent.s, by link:\*\* the approval is #156.s comment \(https://github.com/acme/widgets/issues/156#issuecomment-1\), `desk-mock.html`, sha256 `aaaaaaaaaaaa…`' "$log"
want_in "  and records where it was split from"   'split from #156' "$log"
want_in "  the owner's answer rides quoted, linked" '> \*\*The owner answered\*\* \(`decision:156:scope`\): keep the old filter > — https://github.com/acme/widgets/issues/156#issuecomment-2' "$log"
want_not_in "  an unrelated comment does not"      'an unrelated note' "$log"
want_not_in "  no approval is re-posted as a comment" '^issue comment [0-9]+ .*Picture for any machine' "$(grep '^issue comment' "$GH_LOG")"
mv "$BIN/gh-base" "$BIN/gh"

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
