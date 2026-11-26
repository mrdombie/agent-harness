#!/usr/bin/env bash
# plan-kept-items.test.sh — a feature list item that is already built needs no task.
# A fix round of an open pull request plans tasks only for the red checks handed to it; the
# items of its list were built by the run that shipped the pull request. The plan check
# refused every such plan ("F2 has no task: each item is built by its own tasks", "no task of
# F1 writes it"), asked again, got the same shape and parked: 47 in five days to 2026-11-12.
# Now an item whose test is on the branch (or the trunk) and on record as passing is kept;
# one whose test is missing, named red, or on no record still needs its task, and the second
# ask names the item, the file and the remedy. No test is run to tell: the record decides.
# The briefs, the contract and the validator are the ones that ship; only the model is stubbed.
# Run: bash "$0"
# case-filter: SUITE_ONLY='<a case title, or a pattern over them>' bash driver/tests/plan-kept-items.test.sh
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fix_real_briefs
. "$HERE/../state.sh" || exit 1
KIT="$FIX/kit"

# The branch a pull request shipped: four tests on it, and on origin. One more only here.
git -C "$REPO" update-ref refs/remotes/origin/develop develop
git -C "$REPO" checkout -q -b tkt-kept
for f in f1 f2 s1 s2; do echo "echo ok" > "$REPO/$f.test.sh"; done
git -C "$REPO" add -A && git -C "$REPO" commit -qm "the build that shipped"
git -C "$REPO" update-ref refs/remotes/origin/tkt-kept HEAD
echo "echo ok" > "$REPO/local.test.sh"; git -C "$REPO" add -A && git -C "$REPO" commit -qm "not pushed"

N=700
ticket() { # [branch] — the next ticket, in the tree, with no record yet
  N=$((N + 1)); fix_issue "$N" OPEN "status:claimed"
  jq '.body = "No list here, only a paragraph."' "$FIX/gh/issue-$N.json" > "$FIX/i.json" && mv "$FIX/i.json" "$FIX/gh/issue-$N.json"
  driver_state_init "$N" --worktree "$REPO" --branch "${1:-tkt-kept}"
}
fix_round() { # <what is red> — this run is a fix of the open pull request
  printf 'Coordinator note (new): Fix: PR #77 — %s\n\nFix round 1 of 2. The pull request is open and this run continues on its branch.\n' "$1" > "$FIX/brief-$N.md"
  driver_state_set "$N" run_brief "$FIX/brief-$N.md"
}
shipped_record() { # <item test that passed> <test a task proved> — the record the fix set aside
  local d; d="$(driver_state_dir "$N").set-aside-100"; mkdir -p "$d/steps"
  jq -n --arg t "$1" '{ticket: 1, items: [{id: "F1", behaviour: "b", steps: ["s"], test: $t, passes: true, part: null}]}' > "$d/features.json"
  jq -n --arg t "$2" '{task: {}, answer: {testFirst: {test: {file: $t}}}, pair: "a:b", title: "t", merged: false, commits: ["a"]}' > "$d/steps/build-task-3.proved"
}
plan() { # <F1 test> <F2 test> — two behaviours, and one task, for the red check: F2 has none, and F1's writes another file
  jq -nc --arg a "$1" --arg b "$2" '{step:"plan",skills:["superpowers:writing-plans"],status:"planned",designSource:"ticket-body",
    premise:{verdict:"still-true",evidence:"a.sh:1"},
    features:[{id:"F1",behaviour:"a person saves a filter",steps:["press Save"],test:$a,passes:false,covers:[]},
              {id:"F2",behaviour:"a person sees the list",steps:["open the page"],test:$b,passes:false,covers:[]}],
    tasks:[{item:"F1",title:"merge the trunk and keep both kinds",files:[{path:"a.sh",action:"modify"}],tests:[{file:"merge.test.sh",behaviour:"b",redWhen:"r"}]}]}'
}
step() { # <answer> — the plan step from ${SUT_KIT:-the kit}; leaves R, R_OUT
  local kit="${SUT_KIT:-$ROOT}"
  fix_ai plan "$1" superpowers:writing-plans
  : > "$CLAUDE_LOG"; : > "$GH_LOG"; R_RC=0
  R_OUT=$(DRIVER_BRIEFS="$kit/briefs" DRIVER_SCHEMAS="$kit/briefs/schemas" DRIVER_VALIDATE="$kit/briefs/validate.sh" \
    bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT
      . "$1/driver/driver-env.sh" && . "$1/driver/steps/plan.sh" && driver_step_plan "$2"' _ "$kit" "$N" 2>&1) || R_RC=$?
  R="rc=$R_RC calls=$(grep -c '^plan$' "$CLAUDE_LOG")"
}
build_list() { # — the build's reading of the list, with the plan's one task proved; leaves B
  local kit="${SUT_KIT:-$ROOT}" d rc=0; d="$(driver_state_dir "$N")/steps"
  jq -n '{task: {}, answer: {testFirst: {test: {file: "merge.test.sh"}}}, pair: "a:b", title: "t", merged: false, commits: ["a"]}' > "$d/build-task-1.proved"
  bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT
    . "$1/driver/driver-env.sh" && . "$1/driver/steps/build.sh" && _driver_build_features "$2"' _ "$kit" "$N" >/dev/null 2>&1 || rc=$?
  B="rc=$rc $(jq -r '[.items[].passes | tostring] | join(" ")' "$(driver_state_dir "$N")/features.json")"
}
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$ROOT/briefs" "$KIT/"; }
plant() { # <label> <file under the kit> <exact text> <what it becomes> — in a copy of the kit, never the tree
  kit_copy
  python3 - "$KIT/$2" "$3" "$4" <<'PY' || { bad "plant ($1) did not land"; return 1; }
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if s.count(old) != 1: sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
  return 0
}

# Each case leaves R (the exit and the number of model calls), R_OUT and N.
case_fix_round()  { ticket; fix_round "the lint check is red"; shipped_record f1.test.sh f2.test.sh; step "$(plan f1.test.sh f2.test.sh)"; }
case_record()     { ticket tkt-unpushed; shipped_record f1.test.sh f2.test.sh; step "$(plan f1.test.sh f2.test.sh)"; }
case_other_host() { ticket; fix_round "it conflicts with its base branch"; step "$(plan s1.test.sh s2.test.sh)"; }
case_missing()    { ticket; fix_round "the lint check is red"; shipped_record f1.test.sh gone.test.sh; step "$(plan f1.test.sh gone.test.sh)"; }
case_red()        { ticket; fix_round "the test check is red: FAIL f2.test.sh > it lists"; shipped_record f1.test.sh f2.test.sh; step "$(plan f1.test.sh f2.test.sh)"; }
case_unproved()   { ticket; fix_round "the lint check is red"; step "$(plan s1.test.sh local.test.sh)"; }

if suite_case "a fix round whose items are all built, with one task for a red check: accepted"; then
  case_fix_round
  want "the plan is accepted on the first answer"         "rc=0 calls=1" "$R"
  want_in "  the log says which items it kept, and why"   'plan: 2 item\(s\) kept as already built, needing no task — F1 \(f1.test.sh exists and passes: .*earlier pass\); F2 \(f2.test.sh exists and passes' "$R_OUT"
  want "  the list kept for the build marks them"         "true true" "$(jq -r '[.items[].kept | tostring] | join(" ")' "$(driver_state_dir "$N")/features.json")"
  want "  nothing is left to park on"                     "" "$(driver_state_get "$N" park_note)"
  build_list
  want "  the build passes both once its one task is proved" "rc=0 true true" "$B"
  case_record
  want "a resume with the record and no fix note: kept"   "rc=0 calls=1" "$R"
  case_other_host
  want "another machine's fix round, no record here: the shipped head is the record" "rc=0 calls=1" "$R"
  want_in "  and the log says so"                         's2.test.sh exists and passes: it is at the head the open pull request shipped' "$R_OUT"
  plant "an item already built is kept" driver/feature-list.sh 'if $b.state == "passes" then empty' 'if false then empty' \
    && { SUT_KIT="$KIT" case_fix_round; want "planted (nothing is kept): refused after a second ask" "rc=$DRIVER_E_REFUSED calls=2" "$R"; }
  plant "a proved task's test is on record" driver/feature-list.sh '.answer.testFirst.test.file // .answer.testOnly.test.file // empty' 'empty' \
    && { SUT_KIT="$KIT" case_record; want "planted (proved tasks unread): F2 has no record and is refused" "rc=$DRIVER_E_REFUSED calls=2" "$R"; }
  plant "the shipped head is a record" driver/steps/plan.sh '[ -z "$br" ] || shipped="origin/$br"' ':' \
    && { SUT_KIT="$KIT" case_other_host; want "planted (shipped head unread): refused" "rc=$DRIVER_E_REFUSED calls=2" "$R"; }
  SUT_KIT="" case_fix_round
  plant "the build passes a kept item" driver/steps/build.sh 'if [ -z "$last" ] && [ "$kept" = true ]; then pass=true' 'if false; then pass=true' \
    && { SUT_KIT="$KIT" build_list; want "planted (the build ignores kept): F2 never passes" "rc=1 true false" "$B"; }
fi

if suite_case "an item whose test file does not exist, and no task writes it: refused by name"; then
  case_missing
  want "refused after one more ask"                       "rc=$DRIVER_E_REFUSED calls=2" "$R"
  want_in "  naming the item, the file and the remedy"    'F2 runs its steps in gone.test.sh, which is not on the branch or on develop, and no task of F2 writes it: add a task with item F2 whose tests name gone.test.sh' "$R_OUT"
  want_not_in "  F1, whose test is there, is not in it"   'F1 runs its steps' "$R_OUT"
  want_in "  and the park note carries the same"          'F2 runs its steps in gone.test.sh, which is not on the branch' "$(driver_state_get "$N" park_note)"
  plant "a missing test is not built" driver/feature-list.sh 'state=missing;' 'state=passes;' \
    && { SUT_KIT="$KIT" case_missing; want "planted (missing reads as built): accepted" "rc=0 calls=1" "$R"; }
fi

if suite_case "an item whose test exists but fails at head, with no task: refused"; then
  case_red
  want "named in the red checks handed to the run: refused" "rc=$DRIVER_E_REFUSED calls=2" "$R"
  want_in "  saying it is red, and what to add"           'F2 runs its steps in f2.test.sh, which is on the branch and named in the red checks and findings handed to this run, and no task of F2 writes it: add a task with item F2' "$R_OUT"
  plant "a test named red is not built" driver/feature-list.sh 'state=fails;' 'state=passes;' \
    && { SUT_KIT="$KIT" case_red; want "planted (red reads as built): accepted" "rc=0 calls=1" "$R"; }
  case_unproved
  want "on the branch with no record of passing: refused" "rc=$DRIVER_E_REFUSED calls=2" "$R"
  want_in "  saying so"                                   'F2 runs its steps in local.test.sh, which is on the branch with no record of its steps passing' "$R_OUT"
  plant "no record is not a pass" driver/feature-list.sh 'state=unproved;' 'state=passes;' \
    && { SUT_KIT="$KIT" case_unproved; want "planted (no record reads as built): accepted" "rc=0 calls=1" "$R"; }
fi

if suite_case "the second ask names the item, the file and the remedy"; then
  case_missing
  SENT=$(cat "$FIX/claude-stdin-plan.txt")
  want_in "the retry prompt names the item and its file"  '^- F2 runs its steps in gone.test.sh, which is not on the branch' "$SENT"
  want_in "  and what would satisfy the check"            'add a task with item F2 whose tests name gone.test.sh' "$SENT"
  want_in "  and the item that needs nothing"             '^- F1 \(f1.test.sh exists and passes: ' "$SENT"
  want_not_in "  never the bare rule"                     'each item is built by its own tasks' "$SENT"
  plant "a refusal names its remedy" driver/feature-list.sh ': add a task with item \($i.id) whose tests name \($i.test)' '' \
    && { SUT_KIT="$KIT" case_missing; want "planted (no remedy): the prompt has none" "0" "$(grep -c 'add a task with item F2' "$FIX/claude-stdin-plan.txt")"; }
  plant "the second ask lists what is kept" driver/steps/plan.sh '"$probs" "$(_driver_plan_kept "$t" "$ans")"' '"$probs"' \
    && { SUT_KIT="$KIT" case_missing; want "planted (kept items unsaid): the prompt has none" "0" "$(grep -c 'f1.test.sh exists and passes' "$FIX/claude-stdin-plan.txt")"; }
fi

if suite_case "with no tree to read, every item needs its task, as before"; then
  . "$HERE/../feature-list.sh" || exit 1
  plan f1.test.sh f2.test.sh > "$FIX/p.json"
  want_in "no record given: the old refusal"              'F2 has no task' "$(feature_list_problems "$FIX/p.json" 2>&1)"
  want_in "  for a test no task writes too"               'F1 runs its steps in f1.test.sh, and no task of F1 writes it' "$(feature_list_problems "$FIX/p.json" 2>&1)"
  want "a tree that is not one: nothing reads as built"   "missing missing" "$(feature_list_built "$FIX/p.json" "$FIX/no-tree" "" "" | jq -r '[.[].state] | join(" ")')"
fi

suite_end "$FAILED"
