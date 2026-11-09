#!/usr/bin/env bash
# build-whole.test.sh — a ticket whose plan has several behaviours builds here as one
# change, working through its feature list in order (the owner, 2026-11-05). The plan step
# then the build step, on real commits: each item red then green, and its `passes` set.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/plan.sh" || exit 1
. "$HERE/../steps/build.sh" || exit 1
fix_brief plan superpowers:writing-plans
fix_brief build superpowers:subagent-driven-development 'The task: {{PLAN_TASK}} Last try: {{LAST_TRY}}'
nth_claude

feats() { # <items> — a plan with that many behaviours, one task each, item Fn running fn.test.sh
  jq -nc --argjson n "$1" '{step:"plan",skills:["superpowers:writing-plans"],status:"planned",designSource:"ticket-body",
    premise:{verdict:"still-true",evidence:"a.sh:1"},
    features:[range($n) | {id:"F\(. + 1)",behaviour:"behaviour \(. + 1)",steps:["step \(. + 1)"],test:"f\(. + 1).test.sh",passes:false}],
    tasks:[range($n) | {item:"F\(. + 1)",title:"task F\(. + 1)",files:[{path:"f\(. + 1).txt",action:"modify"}],tests:[{file:"f\(. + 1).test.sh",behaviour:"b",redWhen:"r"}]}]}'
}
COMMITS=0
commits() { # <test file> — a test commit then the change it proves; sets TS and IS. Each its own file to change.
  COMMITS=$((COMMITS+1))
  printf '#!/usr/bin/env bash\ngrep -q yes c%s.txt\n' "$COMMITS" > "$REPO/$1"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: $1"; TS=$(git -C "$REPO" rev-parse HEAD)
  printf 'yes\n' > "$REPO/c$COMMITS.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: $1"; IS=$(git -C "$REPO" rev-parse HEAD)
}
answer() { # <call> <title> <test-file> <test-sha> <impl-sha> — the nth build call's answer
  fix_ai build "$(jq -nc --arg f "$3" --arg t "$4" --arg i "$5" --arg k "$2" '{step:"build",skills:["superpowers:subagent-driven-development"],status:"built",task:$k,
      testFirst:{test:{file:$f,behaviour:"b",redWhen:"r"},command:("bash " + $f),testCommit:$t,implCommit:$i,failedBefore:true,redOutput:"FAIL",passedAfter:true,greenOutput:"PASS"},
      changed:[{path:"a.txt",action:"modify"}],changelog:{skipped:"a test change"}}')" superpowers:subagent-driven-development
  mv "$FIX/ai/build.jsonl" "$FIX/ai/build.$1.jsonl"
}
start() { # <ticket> <plan json> [labels] — a fresh ticket planned; rc in RC, output in OUT
  fix_issue "$1" OPEN "status:claimed${3:+,$3}"; driver_state_init "$1" --worktree "$REPO" --repo "$REPO"
  fix_ai plan "$2" superpowers:writing-plans
  : > "$GH_LOG"; rm -f "$FIX"/nth.* "$FIX"/ai/build.[0-9]*.jsonl
  RC=0; OUT=$(driver_step_plan "$1" 2>&1) || RC=$?
}
build() { export DRIVER_TICKET="$1"; RC=0; : > "$CLAUDE_LOG"; OUT=$(driver_step_build "$1" 2>&1) || RC=$?; }
list() { printf '%s' "$(driver_state_dir "$1")/features.json"; }
passes() { jq -r '[.items[].passes | tostring] | join(" ")' "$(list "$1")"; }

echo "--- three behaviours under the limit: built here, every item red then green ---"
start 201 "$(feats 3)"
want "the plan goes on to build"                 "0" "$RC"
want "no child ticket is filed"                  "0" "$(grep -c '^issue create' "$GH_LOG")"
want "the parent stays open"                     "0" "$(grep -c '^issue close' "$GH_LOG")"
want "nothing says it was split"                 "" "$(driver_state_get 201 noop_note)"
want_in "the list is on the ticket"              'issue comment 201 .*\*\*Feature list\*\*.*built here as one change' "$(tr '\n' ' ' < "$GH_LOG")"
want_not_in "  and names no part"                'clean-up part' "$(tr '\n' ' ' < "$GH_LOG")"
want "every item starts failing"                 "false false false" "$(passes 201)"
for n in 1 2 3; do commits "f$n.test.sh"; answer "$n" "task F$n" "f$n.test.sh" "$TS" "$IS"; done
: > "$GH_LOG"; build 201
want "the build finishes"                        "0" "$RC"
want "one session per task, in order"            "3" "$(grep -c . "$CLAUDE_LOG")"
want "every item's passes ends true"             "true true true" "$(passes 201)"
want_in "  and it says so"                       'all 3 feature list item' "$OUT"
want_in "the list goes back on the ticket, passing" 'issue comment 201 .*F3\*\* behaviour 3 \(passes\)' "$(tr '\n' ' ' < "$GH_LOG")"
want "  once"                                    "1" "$(grep -c '^issue comment 201' "$GH_LOG")"
want "still no child ticket"                     "0" "$(grep -c '^issue create\|^issue close' "$GH_LOG")"
want_in "  and which file it must prove" 'passes only when a task of it proves' "$(cat "$FIX/claude-stdin-build.txt")"
want_in "a task is told its item's steps and test" '"behaviour": "behaviour 3".*"step 3".*"test": "f3.test.sh"' "$(tr '\n' ' ' < "$FIX/claude-stdin-build.txt")"
: > "$GH_LOG"; build 201
want "a pass with nothing new starts no session" "0 0" "$RC $(grep -c . "$CLAUDE_LOG")"
want "  and posts nothing"                       "0" "$(grep -c '^issue comment' "$GH_LOG")"

echo "--- a foundation and a clean-up ship in the same change, in their place ---"
plan_fc=$(feats 2 | jq -c '.foundation = {reason:"hidden-backend", why:"both behaviours read the store"}
  | .features[0].needsFoundation = true
  | .tasks = [{item:"cleanup",title:"remove the old path",files:[{path:"old.txt",action:"delete"}],tests:[{file:"cl.test.sh",behaviour:"b",redWhen:"r"}]}] + (.tasks | reverse)
             + [{item:"foundation",title:"the store",files:[{path:"store.txt",action:"create"}],tests:[{file:"fd.test.sh",behaviour:"b",redWhen:"r"}]}]')
start 202 "$plan_fc"
want "it builds here"                            "0 0" "$RC $(grep -c '^issue create' "$GH_LOG")"
want "foundation first, the list in order, clean-up last" "foundation F1 F2 cleanup" "$(jq -r '[.tasks[].item] | join(" ")' "$(driver_state_dir 202)/steps/plan.json")"
commits fd.test.sh; answer 1 "the store" fd.test.sh "$TS" "$IS"
commits f1.test.sh; answer 2 "task F1" f1.test.sh "$TS" "$IS"
commits f2.test.sh; answer 3 "task F2" f2.test.sh "$TS" "$IS"
commits cl.test.sh; answer 4 "remove the old path" cl.test.sh "$TS" "$IS"
build 202
want "all four are proved"                       "0 4" "$RC $(grep -c . "$CLAUDE_LOG")"
want "and the list passes"                       "true true" "$(passes 202)"

echo "--- a refactor foundation stays in one change too ---"
start 207 "$(printf '%s' "$plan_fc" | jq -c '.foundation.reason = "refactor"')"
want "it builds here"                            "0 0" "$RC $(grep -c '^issue create' "$GH_LOG")"

echo "--- an expand-contract foundation splits in two, merge-first off: the change, then its clean-up ---"
contract() { # <items> — small, an expand-contract foundation and its clean-up
  feats "$1" | jq -c '.foundation = {reason:"expand-contract", why:"the new store sits beside the old"}
    | .tasks = [{item:"foundation",title:"the store",files:[{path:"store.txt",action:"create"}],tests:[{file:"fd.test.sh",behaviour:"b",redWhen:"r"}]}] + .tasks
             + [{item:"cleanup",title:"remove the old path",files:[{path:"old.txt",action:"delete"}],tests:[{file:"cl.test.sh",behaviour:"b",redWhen:"r"}]}]'
}
start 208 "$(contract 2)"
want "4 files, far under the limit: it splits"   "$DRIVER_E_NOOP 2" "$RC $(grep -c '^issue create' "$GH_LOG")"
want_in "  the foundation first"                 'part 1 of 2: the change' "$(grep '^issue create' "$GH_LOG" | head -1)"
want_in "  the clean-up last"                    'part 2 of 2: clean-up' "$(grep '^issue create' "$GH_LOG" | tail -1)"
want_in "  and it says why"                      'new shape deploys before the old is removed' "$OUT"
want "  the build keeps no passes here"          "" "$(driver_state_get 208 build_whole)"
start 209 "$(contract 1)"
want "one behaviour: it splits as well"          "$DRIVER_E_NOOP 2" "$RC $(grep -c '^issue create' "$GH_LOG")"
BASE_CFG="$HARNESS_CFG_PATH"
jq '.driver.split.planMaxFiles = 0' "$BASE_CFG" > "$FIX/cfg-never.json"; export HARNESS_CFG="$FIX/cfg-never.json" HARNESS_CFG_PATH="$FIX/cfg-never.json"
start 210 "$(contract 2)"
want "planMaxFiles 0 does not turn it off"       "$DRIVER_E_NOOP 2" "$RC $(grep -c '^issue create' "$GH_LOG")"
export HARNESS_CFG="$BASE_CFG" HARNESS_CFG_PATH="$BASE_CFG"

echo "--- one change proving two items runs each item's own test, never merges them away ---"
start 203 "$(feats 2 | jq -c '.tasks[0].tests[0].file = "j1.test.sh" | .features[0].test = "j1.test.sh" | .tasks[1].tests[0].file = "j2.test.sh" | .features[1].test = "j2.test.sh"')"
printf '#!/usr/bin/env bash\ngrep -q yes j.txt\n' | tee "$REPO/j1.test.sh" > "$REPO/j2.test.sh"; printf 'no\n' > "$REPO/j.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: j"; TS=$(git -C "$REPO" rev-parse HEAD)
printf 'yes\n' > "$REPO/j.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: j"; IS=$(git -C "$REPO" rev-parse HEAD)
answer 1 "task F1" j1.test.sh "$TS" "$IS"; answer 2 "task F2" j2.test.sh "$TS" "$IS"
build 203
want "both proved"                               "0" "$RC"
want_not_in "  not merged"                       'merged, and proved once' "$OUT"
want_in "  the second by its own test"           'j2.test.sh: red' "$OUT"
want "  both pass"                               "true true" "$(passes 203)"

echo "--- an item whose own test never ran does not pass, and its task is told ---"
start 204 "$(feats 2)"
commits k1.test.sh; answer 1 "task F1" k1.test.sh "$TS" "$IS"   # proves another file, not f1.test.sh
commits f2.test.sh; answer 2 "task F2" f2.test.sh "$TS" "$IS"
build 204
want "sent back, as an unproved task is"         "$DRIVER_E_REWORK" "$RC"
want "  F1 fails, F2 passes"                     "false true" "$(passes 204)"
want_in "  naming the file"                      'F1 passes only when its steps pass in f1.test.sh' "$OUT"
want "  nothing posted while it fails"           "0" "$(grep -c 'issue comment 204 .*passes)' "$GH_LOG")"
commits f1.test.sh; answer 3 "task F1" f1.test.sh "$TS" "$IS"
build 204
want "the next pass builds that task alone"      "0 1" "$RC $(grep -c . "$CLAUDE_LOG")"
want_in "  told why"                             'F1 passes only when its steps pass in f1.test.sh' "$(cat "$FIX/claude-stdin-build.txt")"
want "  and every item passes"                   "true true" "$(passes 204)"

echo "--- a branch already in flight builds here, and keeps its list's passes as a fresh plan does ---"
git -C "$REPO" update-ref refs/remotes/origin/develop "$(git -C "$REPO" rev-parse HEAD~1)"
start 205 "$(feats 3)"
want "it builds here"                            "0 0" "$RC $(grep -c '^issue create' "$GH_LOG")"
want_in "  saying so"                            'already in flight' "$OUT"
want "  the build keeps passes"                  "1" "$(driver_state_get 205 build_whole)"
want "  and the list goes on the ticket"         "1" "$(grep -c 'issue comment 205 .*Feature list' "$GH_LOG")"
start 211 "$(contract 2)"
want "  an expand-contract branch in flight is not split either" "0 0" "$RC $(grep -c '^issue create' "$GH_LOG")"
git -C "$REPO" update-ref -d refs/remotes/origin/develop

echo "--- a part of an earlier split builds as a part ---"
fix_issue 206 OPEN "status:claimed"
jq '.title = "Big — part 2 of 4: F1 save a filter" | .body = "Part 2 of 4, split from #151.\n<!-- harness:feature-item parent=151 id=F1 test=m.test.sh -->"' "$FIX/gh/issue-206.json" > "$FIX/i206" && mv "$FIX/i206" "$FIX/gh/issue-206.json"
driver_state_init 206 --worktree "$REPO" --repo "$REPO"
fix_ai plan "$(feats 1 | jq -c 'del(.features) | .tasks[0] |= (del(.item) | .tests[0].file = "m.test.sh" | .title = "the part")')" superpowers:writing-plans
: > "$GH_LOG"; rm -f "$FIX"/nth.* "$FIX"/ai/build.[0-9]*.jsonl
RC=0; OUT=$(driver_step_plan 206 2>&1) || RC=$?
want "it plans"                                  "0 0" "$RC $(grep -c '^issue create' "$GH_LOG")"
commits m.test.sh; answer 1 "the part" m.test.sh "$TS" "$IS"
: > "$GH_LOG"; build 206
want "it builds"                                 "0" "$RC"
want "  with no list of its own"                 "no" "$([ -e "$(list 206)" ] && echo yes || echo no)"
want "  and nothing posted about one"            "0" "$(grep -c 'Feature list' "$GH_LOG")"

echo "--- after build, a proved item passes even on a record with no build_whole ---"
start 212 "$(feats 2)"
driver_state_set 212 build_whole ""
for n in 1 2; do commits "g$n.test.sh"; done
jq '.features |= map(.test = ("g" + (.id[1:]) + ".test.sh")) | .tasks |= map(.tests[0].file = ("g" + (.item[1:]) + ".test.sh"))' \
  "$(driver_state_dir 212)/steps/plan.json" > "$FIX/p212" && mv "$FIX/p212" "$(driver_state_dir 212)/steps/plan.json"
jq '.items |= map(.test = ("g" + (.id[1:]) + ".test.sh"))' "$(list 212)" > "$FIX/l212" && mv "$FIX/l212" "$(list 212)"
TS1=$(git -C "$REPO" log --format=%H -n1 --grep '^test: g1'); IS1=$(git -C "$REPO" log --format=%H -n1 --grep '^feat: g1')
TS2=$(git -C "$REPO" log --format=%H -n1 --grep '^test: g2'); IS2=$(git -C "$REPO" log --format=%H -n1 --grep '^feat: g2')
answer 1 "task F1" g1.test.sh "$TS1" "$IS1"; answer 2 "task F2" g2.test.sh "$TS2" "$IS2"
build 212
want "the build finishes"                        "0" "$RC"
want "each proved item reads passes: true"       "true true" "$(passes 212)"

suite_end "$FAILED"
