#!/usr/bin/env bash
# build-merge-item.test.sh — a task that only merged the trunk is never sent back by the feature list.
# A plan gave a list item one task, a trunk merge. The merge was proved; the list check then deleted
# that proof to "send the task back", and every later round refused the merge as one it found: five
# tries, parked, with the last refusal and not the cause (2 of 388 runs in the week to 2026-11-18).
# A merge proves no test and cannot be made twice. So its proof stays; when an item has another task
# that one goes back; when merges are all it has, the build parks at once and names the item.
# Unless the branch already carries the item's test from an earlier round (a resume after the trunk
# moved): then self-check's changed-only tests run that file, and the item passes (#20579, 2026-11-21).
# Run: bash "$0"
# case-filter: SUITE_ONLY='<a case title, or a pattern over them>' bash driver/tests/build-merge-item.test.sh
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../state.sh" || exit 1
KIT="$FIX/kit"

N=800
state() { # <tasks json> — a ticket with one list item, F1, whose steps run in f1.test.sh, and this plan
  N=$((N + 1)); fix_issue "$N" OPEN "status:claimed"
  driver_state_init "$N" --worktree "$REPO" --branch develop
  D="$(driver_state_dir "$N")/steps"; mkdir -p "$D"
  jq -n '{ticket: 1, items: [{id: "F1", behaviour: "b", steps: ["s"], test: "f1.test.sh", passes: false, part: null}]}' > "$(driver_state_dir "$N")/features.json"
  jq -n --argjson tasks "$1" '{tasks: $tasks}' > "$D/plan.json"
}
proved() { # <task number> <pair> <test file it proved, or ""> — that task, proved
  jq -n --arg pair "$2" --arg f "$3" '{task: {}, answer: (if $f == "" then {trunkMerge: {commit: "abc"}} else {testFirst: {test: {file: $f}}} end), pair: $pair, title: "t", merged: false, commits: ["abc"]}' > "$D/build-task-$1.proved"
}
check() { # — the build's reading of the list from ${SUT_KIT:-the kit}; leaves B, B_OUT
  local kit="${SUT_KIT:-$ROOT}" rc=0
  B_OUT=$(bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT
    . "$1/driver/driver-env.sh" && . "$1/driver/steps/build.sh" && _driver_build_features "$2"' _ "$kit" "$N" 2>&1) || rc=$?
  B="rc=$rc"
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
}
MERGE='[{"item":"F1","title":"merge the trunk"}]'
BOTH='[{"item":"F1","title":"build it"},{"item":"F1","title":"merge the trunk"}]'

case_only_merge() { state "$MERGE"; proved 1 "merge:abc" ""; check; }
case_merge_last() { state "$BOTH"; proved 1 "a:b" "other.test.sh"; proved 2 "merge:abc" ""; check; }

if suite_case "an item whose only task merged the trunk: the merge keeps its proof and the build stops, naming the item"; then
  case_only_merge
  want "the list check says no try can pass"               "rc=2" "$B"
  want "the merge is still proved"                         "yes" "$([ -s "$D/build-task-1.proved" ] && echo yes || echo no)"
  want "and is told nothing to redo"                       "no" "$([ -e "$D/build-task-1.refused" ] && echo yes || echo no)"
  want_in "the reason names the item, its file and the remedy" 'F1 passes only when its steps pass in f1.test.sh, and its only task\(s\) merge the trunk, which proves no test: the plan needs a task for F1 that proves that file' "$(cat "$D/build-list.unbuildable" 2>/dev/null)"
  want_in "  and is said aloud"                            'its only task\(s\) merge the trunk' "$B_OUT"
  plant "a merge is never sent back" driver/steps/build.sh 'merge:*) ;; *) back="$i" ;; esac' 'merge:*) back="$i" ;; *) back="$i" ;; esac' \
    && { SUT_KIT="$KIT" case_only_merge; want "planted (a merge is sent back): its proof is deleted" "rc=1 no" "$B $([ -s "$D/build-task-1.proved" ] && echo yes || echo no)"; }
  plant "the stop is its own answer" driver/steps/build.sh '[ -z "$stuck" ] || return 2' ':' \
    && { SUT_KIT="$KIT" case_only_merge; want "planted (no stop): it reads as one more round" "rc=1" "$B"; }
fi

if suite_case "a resumed branch that already carries the item's test: its merge-only plan passes, and self-check proves the file"; then
  git -C "$REPO" checkout -q -b tkt-carry develop
  printf 'echo ok\n' > "$REPO/f1.test.sh"; git -C "$REPO" add f1.test.sh; git -C "$REPO" commit -qm "test: f1"
  case_only_merge
  want "the item passes"                                   "rc=0 true" "$B $(jq -r '.items[0].passes' "$(driver_state_dir "$N")/features.json")"
  want "nothing is left saying it cannot"                  "no" "$([ -e "$D/build-list.unbuildable" ] && echo yes || echo no)"
  want_in "  and says why"                                 "f1.test.sh is this branch's own" "$B_OUT"
  plant "the branch's own test is read" driver/steps/build.sh '! git -C "$wt" diff --quiet "$mb" HEAD -- "${2#./}" 2>/dev/null' 'false' \
    && { SUT_KIT="$KIT" case_only_merge; want "planted (never the branch's own): it parks as before" "rc=2" "$B"; }
  git -C "$REPO" checkout -q develop
fi

if suite_case "a merge-only plan on a branch whose test file the trunk already had still parks"; then
  printf 'echo ok\n' > "$REPO/f1.test.sh"; git -C "$REPO" add f1.test.sh; git -C "$REPO" commit -qm "test: f1 on the trunk"
  git -C "$REPO" checkout -q -b tkt-plain develop
  case_only_merge
  want "no try can pass it"                                "rc=2" "$B"
  git -C "$REPO" checkout -q develop
fi

if suite_case "an item with a built task and a merge after it: the built task goes back, never the merge"; then
  case_merge_last
  want "one more round, as before"                         "rc=1" "$B"
  want "the merge is still proved"                         "yes" "$([ -s "$D/build-task-2.proved" ] && echo yes || echo no)"
  want "the built task is the one sent back"               "no" "$([ -s "$D/build-task-1.proved" ] && echo yes || echo no)"
  want_in "  told which file to prove"                     'F1 passes only when its steps pass in f1.test.sh, and no task of it proved that file' "$(cat "$D/build-task-1.refused" 2>/dev/null)"
fi

if suite_case "a task that proved the item's file still passes it, with a merge beside it"; then
  state "$BOTH"; proved 1 "a:b" "f1.test.sh"; proved 2 "merge:abc" ""; check
  want "the item passes"                                   "rc=0 true" "$B $(jq -r '.items[0].passes' "$(driver_state_dir "$N")/features.json")"
  want "nothing is left saying it cannot"                  "no" "$([ -e "$D/build-list.unbuildable" ] && echo yes || echo no)"
fi

if suite_case "the build step parks on it at once, with that reason, and spends no builder"; then
  state "$MERGE"
  HEADSHA=$(git -C "$REPO" rev-parse HEAD)
  jq -n --arg c "$HEADSHA" --argjson task "$(jq -c '.tasks[0]' "$D/plan.json")" '{task: $task, answer: {task: "merge the trunk", trunkMerge: {commit: $c}}, pair: ("merge:" + $c), title: "merge the trunk", merged: false, commits: [$c]}' > "$D/build-task-1.proved"
  step() { local kit="${SUT_KIT:-$ROOT}"; : > "$CLAUDE_LOG"; S_RC=0
    S_OUT=$(DRIVER_BRIEFS="$kit/briefs" DRIVER_SCHEMAS="$kit/briefs/schemas" DRIVER_VALIDATE="$kit/briefs/validate.sh" \
      bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT
        . "$1/driver/driver-env.sh" && . "$1/driver/steps/build.sh" && driver_step_build "$2"' _ "$kit" "$N" 2>&1) || S_RC=$?; }
  step
  want "refused, not sent round again"                     "$DRIVER_E_REFUSED" "$S_RC"
  want "no builder was called"                             "0" "$(grep -c . "$CLAUDE_LOG")"
  want_in "the park note is the cause"                     'the plan cannot pass its feature list — F1 passes only when its steps pass in f1.test.sh, and its only task\(s\) merge the trunk' "$(driver_state_get "$N" park_note 2>/dev/null)"
  want "the merge is still proved"                         "yes" "$([ -s "$D/build-task-1.proved" ] && echo yes || echo no)"
  cp "$D/build-task-1.proved" "$FIX/keep.proved"
  plant "the step parks on an item no try can pass" driver/steps/build.sh 'if [ "$frc" -eq 2 ]; then' 'if false; then' \
    && { cp "$FIX/keep.proved" "$D/build-task-1.proved"; SUT_KIT="$KIT" step; want "planted (the step ignores it): it asks for another round" "$DRIVER_E_REWORK" "$S_RC"; }
fi

suite_end "$FAILED"
