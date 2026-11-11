#!/usr/bin/env bash
# build-trunk-merge.test.sh — a commit that only merges the trunk into the branch is
# not a change the task makes, and has no red to show: the build used to park asking
# whether it could go through. The driver now checks the commit itself: a merge whose
# second parent is on the trunk, whose tree is exactly the conflict-free merge, and
# which is all the task committed. A "merge" carrying anything else is still a change.
#
# Real git throughout: the proof is made of parents and trees.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fixture_path REPO "$FIX"
. "$HERE/../steps/build.sh" || exit 1
fix_brief build superpowers:subagent-driven-development

fix_plan() { # <ticket> — one task
  jq -n '{step:"plan", skills:["superpowers:writing-plans"], status:"planned", designSource:"ticket-body",
          premise:{verdict:"still-true", evidence:"ci"},
          tasks:[{title:"task 1", files:[], tests:[]}]}' > "$(driver_state_dir "$1")/steps/plan.json"
}
fix_merge() { # <commit>
  jq -nc --arg c "$1" \
    '{step:"build", skills:["superpowers:subagent-driven-development"], status:"built", task:"task 1",
      trunkMerge:{commit:$c}, changed:[], changelog:{skipped:"a trunk merge"}}'
}
# branch <name> — a ticket branch cut from the trunk as it is now, with one commit of its own.
branch() {
  local wt="$FIX/$1"; fixture_path wt "$FIX"
  git -C "$REPO" worktree add -q -b "tkt-$1" "$wt" develop
  printf 'own\n' > "$wt/own-$1.txt"; git -C "$wt" add -A; git -C "$wt" commit -qm "feat: $1"
}

printf 'one\n' > "$REPO/shared.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm base
for b in clean edited conflict side more notmerge; do branch "$b"; done
# The conflict branch and the trunk both change the same line.
printf 'branch\n' > "$FIX/conflict/shared.txt"; git -C "$FIX/conflict" commit -qam "feat: the branch's line"
printf 'trunk\n' > "$REPO/shared.txt"; printf 'new\n' > "$REPO/trunk.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: the trunk moved"

echo "--- a clean trunk merge already on the branch is accepted without a question ---"
WT="$FIX/clean"
C_P1=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" merge -q --no-edit develop
C_M=$(git -C "$WT" rev-parse HEAD)
want "it is a merge commit" "2" "$(git -C "$WT" rev-list --parents -n1 HEAD | awk '{print NF - 1}')"
driver_state_init 151 --worktree "$WT" --repo "$REPO"
fix_plan 151
fix_ai build "$(fix_merge "$(printf '%s' "$C_M" | cut -c1-10)")" superpowers:subagent-driven-development
out=$(DRIVER_TICKET=151 driver_step_build 151 2>&1); rc=$?
want "the step finishes"               "0" "$rc"
want_in "saying what it checked"       "a trunk merge and nothing more: $(printf '%s' "$C_M" | cut -c1-8) merges" "$out"
want "it is recorded as proved, on the merge" "$C_M" "$(jq -r '.commits[0]' "$(driver_state_dir 151)/steps/build-task-1.proved" 2>/dev/null)"
out=$(driver_prove_trunk_merge "$WT" "$C_P1" "$C_M" "$C_M" 2>&1); rc=$?
want "and as the task's own one commit" "0" "$rc"

echo "--- a merge commit that carries extra edits is refused ---"
WT="$FIX/edited"
git -C "$WT" merge -q --no-commit --no-ff develop >/dev/null 2>&1
printf 'slipped in\n' >> "$WT/own-edited.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "Merge branch 'develop'"
E_M=$(git -C "$WT" rev-parse HEAD)
want "it is a merge commit too" "2" "$(git -C "$WT" rev-list --parents -n1 HEAD | awk '{print NF - 1}')"
driver_state_init 152 --worktree "$WT" --repo "$REPO"
fix_plan 152
fix_ai build "$(fix_merge "$E_M")" superpowers:subagent-driven-development
rc=0; out=$(DRIVER_TICKET=152 driver_step_build 152 2>&1) || rc=$?
want "it asks for rework"              "30" "$rc"
want_in "naming the edited file"       'carries edits beyond the clean merge \(own-edited\.txt\)' "$out"
want_in "the next try is told why"     'beyond the clean merge' "$(cat "$(driver_state_dir 152)/steps/build-task-1.refused" 2>/dev/null)"
want "and nothing is recorded as proved" "no" "$([ -e "$(driver_state_dir 152)/steps/build-task-1.proved" ] && echo yes || echo no)"

echo "--- a conflict resolved by hand is a change ---"
WT="$FIX/conflict"
X_P1=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" merge -q --no-edit develop >/dev/null 2>&1
want "the merge did conflict" "UU shared.txt" "$(git -C "$WT" status --porcelain --untracked-files=no | grep shared)"
printf 'resolved\n' > "$WT/shared.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "Merge branch 'develop'"
X_M=$(git -C "$WT" rev-parse HEAD)
out=$(driver_prove_trunk_merge "$WT" "$X_P1" "$X_M" "$X_M" 2>&1); rc=$?
want "it is refused"                   "1" "$rc"
want_in "as a resolution by hand"      'with conflicts, so its resolution is a change by hand' "$out"

echo "--- a merge of something that is not the trunk is refused ---"
WT="$FIX/side"
S_P1=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" merge -q --no-edit tkt-notmerge
S_M=$(git -C "$WT" rev-parse HEAD)
out=$(driver_prove_trunk_merge "$WT" "$S_P1" "$S_M" "$S_M" 2>&1); rc=$?
want "it is refused"                   "1" "$rc"
want_in "naming the trunk"             'which is not on the trunk \(develop\)' "$out"

echo "--- a commit that is not a merge is refused ---"
WT="$FIX/notmerge"
N_H=$(git -C "$WT" rev-parse HEAD)
out=$(driver_prove_trunk_merge "$WT" "$N_H" "$N_H" "$N_H" 2>&1); rc=$?
want "it is refused"                   "1" "$rc"
want_in "and said"                     'is not a merge of two commits' "$out"

echo "--- a task that commits a change and then merges has not only merged ---"
WT="$FIX/more"
M_BEFORE=$(git -C "$WT" rev-parse HEAD)
printf 'unproved\n' > "$WT/code.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "feat: unproved"
git -C "$WT" merge -q --no-edit develop
M_M=$(git -C "$WT" rev-parse HEAD)
out=$(driver_prove_trunk_merge "$WT" "$M_BEFORE" "$M_M" "$M_M" 2>&1); rc=$?
want "it is refused"                   "2" "$rc"
want_in "naming the other commit"      "committed more than the trunk merge .*\($(git -C "$WT" rev-parse --short "$M_M^1")\)" "$out"
printf 'loose\n' >> "$WT/code.txt"
out=$(driver_prove_trunk_merge "$WT" "$M_M" "$M_M" "$M_M" 2>&1); rc=$?
want "uncommitted edits beside it are refused" "2" "$rc"
want_in "naming the file"              'uncommitted edits beside the trunk merge .*\(code\.txt\)' "$out"
out=$(driver_prove_trunk_merge "$WT" "$M_M" "$M_M" "$C_M" 2>&1); rc=$?
want "another branch's merge cannot be checked here" "3" "$rc"

suite_end "$FAILED"
