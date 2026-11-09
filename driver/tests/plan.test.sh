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

echo "--- past driver.split.planMaxFiles: one part each, side by side ---"
EXF="$HERE/../../briefs/examples/plan.valid-feature-list.json"
# The example names 4 files, the small lists below 2 or 3. Over this limit they split as they always did.
BASE_CFG="$HARNESS_CFG_PATH"
limit() { jq --argjson n "$1" '.driver.split.planMaxFiles = $n' "$BASE_CFG" > "$FIX/cfg-limit.json"; export HARNESS_CFG="$FIX/cfg-limit.json" HARNESS_CFG_PATH="$FIX/cfg-limit.json"; }
limit 1
plan_feats() { # <items> — a valid plan with that many behaviours, one task each
  jq -nc --argjson n "$1" '{step:"plan",skills:["superpowers:writing-plans"],status:"planned",designSource:"ticket-body",
    premise:{verdict:"still-true",evidence:"a.sh:1"},
    features:[range($n) | {id:"F\(. + 1)",behaviour:"behaviour \(. + 1)",steps:["step \(. + 1)"],test:"f\(. + 1).test.sh",passes:false}],
    tasks:[range($n) | {item:"F\(. + 1)",title:"task \(. + 1)",files:[{path:"f\(. + 1).sh",action:"modify"}],tests:[{file:"f\(. + 1).test.sh",behaviour:"b",redWhen:"r"}]}]}'
}
echo "    an expand-contract plan, merge-first off: the change, then its clean-up — two parts, never one per behaviour"
release_merge_first() { return 1; }
fix_issue 151 OPEN "status:claimed,P1,area:inbox,screen:inbox,needs:human-approval"; driver_state_init 151 --worktree "$REPO"
fix_ai plan "$(jq -c '.tasks[1].files += [{path:"src/content/changelog/151.md",action:"create"}]' "$EXF")" superpowers:writing-plans
fresh; out=$(driver_step_plan 151 2>&1); rc=$?
log=$(tr '\n' ' ' < "$GH_LOG")
want "the run ends clean, nothing built"           "$DRIVER_E_NOOP" "$rc"
want "  the change and its clean-up: two parts"    "2" "$(grep -c '^issue create' "$GH_LOG")"
c1=$(created 801); c2=$(created 802)
want_in "  the change goes first, whole"           'part 1 of 2: the change' "$c1"
want_in "  and is ready, labels inherited"         '--label status:ready --label P1 --label area:inbox --label screen:inbox' "$c1"
want_in "  it names the foundation's reason"       'expand-contract' "$c1"
want_in "  and every behaviour, in list order, with its steps" 'F1: A person saves.*apply two filters.*F2: An empty filter list.*open the list with nothing saved' "$c1"
want_in "  and every task's files but the clean-up's" 'Files:\*\* src/inbox/FilterList.tsx, src/inbox/SaveFilter.tsx, src/inbox/filter-store.ts' "$c1"
want_not_in "  not the parent's changelog: it is not the last part" 'changelog/151.md' "$c1"
want_not_in "  nor the clean-up's files"                'query-filters.ts' "$c1"
want_not_in "  no per-behaviour marker: it builds as one change" 'harness:feature-item' "$c1"
want_in "  the clean-up goes last, once the change has landed" 'part 2 of 2: clean-up.*Blocked until #801 merges.*--label status:gated' "$c2"
want_in "  it carries its own files and the parent's changelog" 'Files:\*\* src/content/changelog/151.md, src/inbox/query-filters.ts' "$c2"
want_not_in "  a person's hold is not inherited"        'label needs:human-approval' "$log"
want_in "  the parent carries the list, each item on the change part" 'issue comment 151 .*\*\*Feature list\*\*.*F1\*\* .*#801 \(failing\).*F2\*\* .*#801 \(failing\)' "$log"
want_in "  the parent is told how it was split"     'issue comment 151 .*Split in two.* into #801 #802' "$log"
want_in "  and why it stays not-done until the list passes" 'every item passes and its clean-up part #802 has merged' "$log"
want_in "  closed as split, so nothing claims it again" 'issue close 151 --repo acme/widgets --reason not planned' "$log"
want "  the waits naming it are re-pointed at its parts" "--repoint 151 801 802" "$(cat "$FIX/repoint.log")"
want "  kept in the driver state with its parts"   "801 801 801 802" "$(jq -r '[.items[].part, .foundation.part, .cleanup.part] | map(tostring) | join(" ")' "$(driver_state_dir 151)/features.json")"
want_in "  the run says why"                       'split in two' "$out"

echo "    six behaviours and an expand-contract foundation: 1 change merge-first, 2 without, never 6"
plan_contract() { # <items> — plan_feats with an expand-contract foundation and its clean-up
  plan_feats "$1" | jq -c '.foundation = {reason:"expand-contract", why:"the new store deploys before the old is removed"}
    | .tasks = [{item:"foundation",title:"new store",files:[{path:"store.sh",action:"create"}],tests:[{file:"store.test.sh",behaviour:"b",redWhen:"r"}]}] + .tasks
      + [{item:"cleanup",title:"remove the old",files:[{path:"old.sh",action:"delete"}],tests:[{file:"store.test.sh",behaviour:"b",redWhen:"r"}]}]'
}
limit 1
release_merge_first() { return 0; }
fix_issue 181 OPEN "status:claimed,P1"; driver_state_init 181 --worktree "$REPO"
fix_ai plan "$(plan_contract 6)" superpowers:writing-plans
fresh; out=$(driver_step_plan 181 2>&1); rc=$?
want "merge-first: it builds here as one change, nothing filed" "0 0" "$rc $(grep -c '^issue create' "$GH_LOG")"
want "  built whole, in list order"                "1" "$(driver_state_get 181 build_whole)"
want "  the clean-up task last, in the same change" "cleanup" "$(jq -r '.tasks[-1].item' "$(driver_state_dir 181)/steps/plan.json")"
want_in "  the run says why"                       'merge-first.*same change' "$out"
release_merge_first() { return 1; }
fix_issue 182 OPEN "status:claimed,P1"; driver_state_init 182 --worktree "$REPO"
fix_ai plan "$(plan_contract 6)" superpowers:writing-plans
fresh; out=$(driver_step_plan 182 2>&1); rc=$?
want "merge-first off: two parts, not six"         "$DRIVER_E_NOOP 2" "$rc $(grep -c '^issue create' "$GH_LOG")"
export HARNESS_CFG="$BASE_CFG" HARNESS_CFG_PATH="$BASE_CFG"
fix_issue 183 OPEN "status:claimed,P1"; driver_state_init 183 --worktree "$REPO"
fix_ai plan "$(plan_contract 6)" superpowers:writing-plans
fresh; out=$(driver_step_plan 183 2>&1); rc=$?
want "  under the file limit too: still two parts"  "$DRIVER_E_NOOP 2" "$rc $(grep -c '^issue create' "$GH_LOG")"
limit 1
unset -f release_merge_first

echo "--- no foundation: every item ready at once, none chained ---"
fix_issue 152 OPEN "status:claimed,P1"; driver_state_init 152 --worktree "$REPO"
fix_ai plan "$(plan_feats 3)" superpowers:writing-plans
fresh; out=$(driver_step_plan 152 2>&1); rc=$?
want "three behaviours past the limit: three parts" "$DRIVER_E_NOOP 3" "$rc $(grep -c '^issue create' "$GH_LOG")"
want "  all three ready"                           "3" "$(cat "$FIX"/created-*.txt | tr ' ' '\n' | grep -c -x 'status:ready')"
want "  none waits on another"                     "0" "$(grep -c 'Blocked until' "$GH_LOG")"
want_in "  the run says the limit"                 'over driver.split.planMaxFiles \(1\)' "$out"

echo "--- a per-behaviour split keeps the parent's changelog for its last part only ---"
fix_issue 184 OPEN "status:claimed,P1"; driver_state_init 184 --worktree "$REPO"
fix_ai plan "$(plan_feats 3 | jq -c '.tasks[0].files += [{path:"changelog/184.md",action:"create"},{path:"changelog/1840.md",action:"create"}]')" superpowers:writing-plans
fresh; out=$(driver_step_plan 184 2>&1); rc=$?
want "three parts" "$DRIVER_E_NOOP 3" "$rc $(grep -c '^issue create' "$GH_LOG")"
want_not_in "  part 1 leaves the parent's changelog out" 'changelog/184\.md' "$(created 801)"
want_in "  another ticket's changelog is not the parent's" 'changelog/1840\.md' "$(created 801)"
want_in "  the last part carries it" 'Files:\*\* changelog/184\.md, f3\.sh' "$(created 803)"

echo "--- the limit counts distinct files: at it builds here, one over it splits ---"
plan_wide() { # <distinct files> — two behaviours, the first task naming them all and the second one again
  plan_feats 2 | jq -c --argjson n "$1" '.tasks[0].files = [range($n) | {path:"w\(.).sh",action:"modify"}] | .tasks[1].files = [{path:"w0.sh",action:"modify"}]'
}
export HARNESS_CFG="$BASE_CFG" HARNESS_CFG_PATH="$BASE_CFG"
fix_issue 170 OPEN "status:claimed"; driver_state_init 170 --worktree "$REPO"
fix_ai plan "$(plan_wide 50)" superpowers:writing-plans
fresh; out=$(driver_step_plan 170 2>&1); rc=$?
want "50 files, the default limit: it builds, nothing filed" "0 0" "$rc $(grep -c '^issue create' "$GH_LOG")"
fix_issue 171 OPEN "status:claimed"; driver_state_init 171 --worktree "$REPO"
fix_ai plan "$(plan_wide 51)" superpowers:writing-plans
fresh; out=$(driver_step_plan 171 2>&1); rc=$?
want "51 files: it splits"                         "$DRIVER_E_NOOP 2" "$rc $(grep -c '^issue create' "$GH_LOG")"
limit 0
fix_issue 172 OPEN "status:claimed"; driver_state_init 172 --worktree "$REPO"
fix_ai plan "$(plan_wide 51)" superpowers:writing-plans
fresh; out=$(driver_step_plan 172 2>&1); rc=$?
want "planMaxFiles 0 never splits"                 "0 0" "$rc $(grep -c '^issue create' "$GH_LOG")"
limit 1

echo "--- a limit that reads as nothing is the default ---"
jq '.driver.split.planMaxFiles = "many"' "$BASE_CFG" > "$FIX/cfg-bad.json"
want "not a number: 50"                            "50" "$(HARNESS_CFG="$FIX/cfg-bad.json" driver_split_plan_max)"

echo "--- one behaviour: built here, its list kept and posted ---"
fix_issue 153 OPEN "status:claimed,P1"; driver_state_init 153 --worktree "$REPO"
fix_ai plan "$(plan_feats 1)" superpowers:writing-plans
fresh; out=$(driver_step_plan 153 2>&1); rc=$?
want "it builds, nothing filed"                    "0 0" "$rc $(grep -c '^issue create' "$GH_LOG")"
want "  its list is in the driver state"           "F1 false" "$(jq -r '.items[0] | "\(.id) \(.passes)"' "$(driver_state_dir 153)/features.json")"
want_in "  and on the ticket"                      'issue comment 153 .*\*\*Feature list\*\*' "$(tr '\n' ' ' < "$GH_LOG")"

echo "--- a re-plan replaces a list with nothing passed; once an item passes it may not edit it ---"
jq -c '.features[0].steps = ["something easier"]' <<<"$(plan_feats 1)" > "$FIX/edited.json"
fix_ai plan "$(cat "$FIX/edited.json")" superpowers:writing-plans
fresh; out=$(driver_step_plan 153 2>&1); rc=$?
want "nothing passed: the re-plan moves past plan" "0" "$rc"
want "  its steps are the list now"                "something easier" "$(jq -r '.items[0].steps[0]' "$(driver_state_dir 153)/features.json")"
want "  the old one kept"                          "step 1" "$(jq -r '.items[0].steps[0]' "$(driver_state_dir 153)/features.prev.json")"
jq '.items[0].passes = true' "$(driver_state_dir 153)/features.prev.json" > "$FIX/passed.json"
cp "$FIX/passed.json" "$(driver_state_dir 153)/features.json"
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
want "  as a part: it keeps no list of its own"    "no" "$([ -e "$(driver_state_dir 159)/features.json" ] && echo yes || echo no)"
want "  and the build keeps no passes for it"      "" "$(driver_state_get 159 build_whole)"
fix_ai plan "$(plan_feats 2 | jq -c '.tasks[0].tests[0].file = "other.test.sh" | del(.features) | .tasks |= map(del(.item))')" superpowers:writing-plans
fresh; out=$(driver_step_plan 159 2>&1); rc=$?
want "a part whose plan drops its item's test, twice: refused" "$DRIVER_E_REFUSED" "$rc"
want_in "  naming the test its steps run in"       'F1 .*f1.test.sh' "$out"

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
export HARNESS_CFG="$BASE_CFG" HARNESS_CFG_PATH="$BASE_CFG"

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

echo "--- an approved picture not byte-identical in .design/ refuses the plan by name, on the picture route only ---"
CFG="$REPO/.claude/harness.json"
jq '.design = ((.design // {}) + {"baselineRoute": {"enabled": true}})' "$CFG" > "$FIX/cfg.t" && mv "$FIX/cfg.t" "$CFG"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "the baseline route is on" >/dev/null
HSHA=$(printf '<html>the holly live picture</html>\n' | shasum -a 256 | awk '{print $1}')
holly_ticket() { # <n> <labels-csv> — an approval of holly-live-mock.html, and a tree holding only holly-mock.html
  local labels; labels=$(jq -nc --arg l "status:claimed${2:+,$2}" '$l | split(",") | map({name:.})')
  jq -n --argjson n "$1" --argjson l "$labels" --arg c "**Picture for any machine** — \`holly-live-mock.html\`, approved for #$1

<!-- picture-approve: sha256=$HSHA file=holly-live-mock.html gist= -->" \
    '{number:$n, state:"OPEN", title:"Ticket \($n)", labels:$l, body:"spec", comments:[{body:$c}]}' > "$FIX/gh/issue-$1.json"
  git -C "$REPO" worktree add -q -b "tkt-$1" "$FIX/wt-$1" develop 2>/dev/null
  mkdir -p "$FIX/wt-$1/.design"; printf 'an older holly\n' > "$FIX/wt-$1/.design/holly-mock.html"
  git -C "$FIX/wt-$1" add .design && git -C "$FIX/wt-$1" commit -qm "an older holly" >/dev/null
  driver_state_init "$1" --worktree "$FIX/wt-$1"
  fix_ai plan "$(jq -nc '{step:"plan",skills:["superpowers:writing-plans"],status:"planned",designSource:"approved-picture",designRef:".design/holly-mock.html",premise:{verdict:"still-true",evidence:"a.sh:1"},tasks:[{title:"t",files:[{path:"a.sh",action:"modify"}],tests:[{file:"a.test.sh",behaviour:"b",redWhen:"r"}]}]}')" superpowers:writing-plans
}
holly_ticket 171 screen:redesign; : > "$GH_LOG"
rc=0; out=$(driver_step_plan 171 2>&1) || rc=$?
want "a redesign bound to a picture .design/ lacks is refused" "$DRIVER_E_REFUSED" "$rc"
want_in "  by name"                                   "✋ plan: approved picture ${HSHA:0:12} is not in .design/" "$out"
want_in "  the park note names the file"              'holly-live-mock.html' "$(driver_state_get 171 park_note)"
want_not_in "  no plan is posted"                     'issue comment 171' "$(cat "$GH_LOG")"
want_not_in "  and the same-named mock is not recorded" 'holly-mock' "$(driver_state_get 171 design_ref)"
holly_ticket 172 ""
rc=0; out=$(driver_step_plan 172 2>&1) || rc=$?
want "an existing screen binds no picture, so it is not refused" "0" "$rc"

suite_end "$FAILED"
