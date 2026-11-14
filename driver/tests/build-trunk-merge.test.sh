#!/usr/bin/env bash
# build-trunk-merge.test.sh — a commit that only merges the trunk into the branch is
# not a change the task makes, and has no red to show: the build used to park asking
# whether it could go through. The driver now checks the commit itself: a merge whose
# second parent is on the trunk, whose tree is exactly the conflict-free merge, and
# which this task made and is all it committed. A "merge" carrying anything else is
# still a change, and a merge that was on the branch before the task started proves
# nothing was done.
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

printf 'one\n' > "$REPO/shared.txt"; printf 'base\n' > "$REPO/base.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm base
for b in clean edited conflict side more notmerge asked single found resolve marker neither redgate foundres; do branch "$b"; done
# The conflict branches and the trunk all change the same line.
for b in conflict resolve marker neither redgate foundres; do
  printf 'branch\n' > "$FIX/$b/shared.txt"; git -C "$FIX/$b" commit -qam "feat: the branch's line"
done
printf 'trunk\n' > "$REPO/shared.txt"; printf 'new\n' > "$REPO/trunk.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: the trunk moved"

# session <tree> — the next build session merges the trunk into <tree> before it answers.
cp "$BIN/claude" "$FIX/claude.keep"
session() {
  printf '#!/usr/bin/env bash\ngit -C "%s" merge -q --no-edit develop >/dev/null 2>&1\ncp "$FIX/claude.keep" "$BIN/claude"\nexec "$FIX/claude.keep" "$@"\n' "$1" > "$BIN/claude"
  chmod +x "$BIN/claude"
}
started() { jq -r '.head // ""' "$(driver_state_dir "$1")/steps/build-task-1.started" 2>/dev/null; }

echo "--- a task that makes the trunk merge itself passes without a question ---"
WT="$FIX/single"
G_P1=$(git -C "$WT" rev-parse HEAD)
driver_state_init 150 --worktree "$WT" --repo "$REPO"
fix_plan 150
fix_ai build "$(fix_merge refs/heads/tkt-single)" superpowers:subagent-driven-development
session "$WT"
out=$(DRIVER_TICKET=150 driver_step_build 150 2>&1); rc=$?
G_M=$(git -C "$WT" rev-parse HEAD)
want "the session made a merge commit"  "2 $G_P1" "$(git -C "$WT" rev-list --parents -n1 HEAD | awk '{print NF - 1, $2}')"
want "the step finishes"               "0" "$rc"
want_in "saying what it checked"       "a trunk merge and nothing more: $(printf '%s' "$G_M" | cut -c1-8) merges" "$out"
want "it is recorded as proved, on the merge" "$G_M" "$(jq -r '.commits[0]' "$(driver_state_dir 150)/steps/build-task-1.proved" 2>/dev/null)"
want "and its start is spent"          "" "$(started 150)"

echo "--- a merge the task made, then asked about, is still its own when the run resumes ---"
# The measured case: the session merged, parked on a question, and the next run answered.
WT="$FIX/asked"
A_P1=$(git -C "$WT" rev-parse HEAD)
driver_state_init 151 --worktree "$WT" --repo "$REPO"
fix_plan 151
fix_ai build '{"step":"build","skills":["superpowers:subagent-driven-development"],"status":"park","task":"task 1","question":"Can the merge go through without a proof?","questionFor":"pm"}' superpowers:subagent-driven-development
session "$WT"
rc=0; DRIVER_TICKET=151 driver_step_build 151 >/dev/null 2>&1 || rc=$?
A_M=$(git -C "$WT" rev-parse HEAD)
want "the first run stops on its question" "20" "$rc"
want "having merged"                   "$A_P1" "$(git -C "$WT" rev-parse "HEAD^1")"
want "the task's start is kept"        "$A_P1" "$(started 151)"
fix_ai build "$(fix_merge "$(printf '%s' "$A_M" | cut -c1-10)")" superpowers:subagent-driven-development
out=$(DRIVER_TICKET=151 driver_step_build 151 2>&1); rc=$?
want "the next run finishes"           "0" "$rc"
want_in "on the merge the task made"   "a trunk merge and nothing more: $(printf '%s' "$A_M" | cut -c1-8) merges" "$out"

echo "--- a trunk merge made before the task started is refused ---"
WT="$FIX/found"
git -C "$WT" merge -q --no-edit develop
F_M=$(git -C "$WT" rev-parse HEAD)
driver_state_init 153 --worktree "$WT" --repo "$REPO"
fix_plan 153
fix_ai build "$(fix_merge "$F_M")" superpowers:subagent-driven-development
rc=0; out=$(DRIVER_TICKET=153 driver_step_build 153 2>&1) || rc=$?
want "it asks for rework"              "30" "$rc"
want_in "naming the commit and the start" "$(printf '%s' "$F_M" | cut -c1-8) was on the branch before this task started \(at $(printf '%s' "$F_M" | cut -c1-8)\)" "$out"
want_in "the next try is told why"     'before this task started' "$(cat "$(driver_state_dir 153)/steps/build-task-1.refused" 2>/dev/null)"
want "and nothing is recorded as proved" "no" "$([ -e "$(driver_state_dir 153)/steps/build-task-1.proved" ] && echo yes || echo no)"
rc=0; DRIVER_TICKET=153 driver_step_build 153 >/dev/null 2>&1 || rc=$?
want "and a second try naming it is refused the same" "30" "$rc"

WT="$FIX/clean"
C_P1=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" merge -q --no-edit develop
C_M=$(git -C "$WT" rev-parse HEAD)
out=$(driver_prove_trunk_merge "$WT" "$C_P1" "$C_M" "$C_M" 2>&1); rc=$?
want "measured directly: the task's own one commit" "0" "$rc"
out=$(driver_prove_trunk_merge "$WT" "$C_M" "$C_M" "$C_M" 2>&1); rc=$?
want "and the same merge, found by a later task" "2" "$rc"

echo "--- a merge commit that carries extra edits is refused ---"
WT="$FIX/edited"
git -C "$WT" merge -q --no-commit --no-ff develop >/dev/null 2>&1
printf 'slipped in\n' >> "$WT/own-edited.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "Merge branch 'develop'"
E_M=$(git -C "$WT" rev-parse HEAD)
want "it is a merge commit too" "2" "$(git -C "$WT" rev-list --parents -n1 HEAD | awk '{print NF - 1}')"
E_P1=$(git -C "$WT" rev-parse "HEAD^1")
driver_state_init 152 --worktree "$WT" --repo "$REPO"
jq -n --arg h "$E_P1" '{task: {title:"task 1", files:[], tests:[]}, head: $h}' > "$(driver_state_dir 152)/steps/build-task-1.started"
fix_plan 152
fix_ai build "$(fix_merge "$E_M")" superpowers:subagent-driven-development
rc=0; out=$(DRIVER_TICKET=152 driver_step_build 152 2>&1) || rc=$?
want "it asks for rework"              "30" "$rc"
want_in "naming the edited file"       'carries edits beyond the clean merge \(own-edited\.txt\)' "$out"
want_in "the next try is told why"     'beyond the clean merge' "$(cat "$(driver_state_dir 152)/steps/build-task-1.refused" 2>/dev/null)"
want "and nothing is recorded as proved" "no" "$([ -e "$(driver_state_dir 152)/steps/build-task-1.proved" ] && echo yes || echo no)"

echo "--- a conflict resolved by hand is accepted, and no gate runs here: self-check's run next ---"
WT="$FIX/conflict"
X_P1=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" merge -q --no-edit develop >/dev/null 2>&1
want "the merge did conflict" "UU shared.txt" "$(git -C "$WT" status --porcelain --untracked-files=no | grep shared)"
printf 'resolved\n' > "$WT/shared.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "Merge branch 'develop'"
X_M=$(git -C "$WT" rev-parse HEAD)
# A gate that reads stdin, and one that would show it ran: the build must run neither.
jq --arg f "$FIX/x-ran" '.gates = {lint: ("cat >/dev/null; echo lint >> " + $f), test: ("echo test >> " + $f)}' "$HARNESS_CFG_PATH" > "$FIX/x-cfg.json"
out=$(HARNESS_CFG="$FIX/x-cfg.json" driver_prove_trunk_merge "$WT" "$X_P1" "$X_M" "$X_M" "$FIX/x-res.json" 2>&1); rc=$?
want "it is accepted"                  "0" "$rc"
want_in "naming the files resolved"    'resolves its conflicts by hand \(shared\.txt\)' "$out"
want_in "and who judges them"          "self-check's gates judge it on this head" "$out"
want "no gate ran in the build"        "" "$(cat "$FIX/x-ran" 2>/dev/null)"
want "the resolution is kept as the proof" "trunk-merge-resolved shared.txt" \
  "$(jq -r '"\(.kind) \(.files | join(","))"' "$FIX/x-res.json" 2>/dev/null)"

echo "--- under gates.localOnly with no local list, the changed list is not run either ---"
jq --arg f "$FIX/lo-ran" '.gates = {changed: [("echo changed >> " + $f)], localOnly: true}' "$HARNESS_CFG_PATH" > "$FIX/lo-cfg.json"
out=$(HARNESS_CFG="$FIX/lo-cfg.json" driver_prove_trunk_merge "$WT" "$X_P1" "$X_M" "$X_M" 2>&1); rc=$?
want "it is accepted"                  "0" "$rc"
want "and the changed list never ran"  "" "$(cat "$FIX/lo-ran" 2>/dev/null)"

# Through the step: the session merges, resolves the conflict and commits.
WT="$FIX/resolve"
R_P1=$(git -C "$WT" rev-parse HEAD)
driver_state_init 154 --worktree "$WT" --repo "$REPO"
fix_plan 154
fix_ai build "$(fix_merge refs/heads/tkt-resolve)" superpowers:subagent-driven-development
printf '#!/usr/bin/env bash\ngit -C "%s" merge -q --no-edit develop >/dev/null 2>&1\nprintf "resolved\\n" > "%s/shared.txt"; git -C "%s" add -A; git -C "%s" commit -qm "Merge branch develop" >/dev/null 2>&1\ncp "$FIX/claude.keep" "$BIN/claude"\nexec "$FIX/claude.keep" "$@"\n' \
  "$WT" "$WT" "$WT" "$WT" > "$BIN/claude"
chmod +x "$BIN/claude"
rc=0; out=$(DRIVER_TICKET=154 driver_step_build 154 2>&1) || rc=$?
R_M=$(git -C "$WT" rev-parse HEAD)
want "the session made a merge commit" "2 $R_P1" "$(git -C "$WT" rev-list --parents -n1 HEAD | awk '{print NF - 1, $2}')"
want "the step finishes"               "0" "$rc"
want "it is recorded as proved, on the merge" "$R_M" "$(jq -r '.commits[0]' "$(driver_state_dir 154)/steps/build-task-1.proved" 2>/dev/null)"
want "with the resolution as its proof" "trunk-merge-resolved shared.txt" \
  "$(jq -r '"\(.proof.kind) \(.proof.files | join(","))"' "$(driver_state_dir 154)/steps/build-task-1.proved" 2>/dev/null)"
want_in "the summary counts it as resolved by hand" '1 of 1 task\(s\) merged the trunk — 1 resolved by hand' "$out"
want_not_in "and does not call it a clean merge" 'clean merge' "$out"
want "and nothing refused"             "no" "$([ -e "$(driver_state_dir 154)/steps/build-task-1.refused" ] && echo yes || echo no)"

echo "--- a resolution that keeps a conflict marker is refused ---"
WT="$FIX/marker"
K_P1=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" merge -q --no-edit develop >/dev/null 2>&1
printf '<<<<<<< HEAD\nresolved\n' > "$WT/shared.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "Merge branch 'develop'"
K_M=$(git -C "$WT" rev-parse HEAD)
out=$(driver_prove_trunk_merge "$WT" "$K_P1" "$K_M" "$K_M" 2>&1); rc=$?
want "it is refused"                   "1" "$rc"
want_in "naming the file"              'conflict marker in shared\.txt' "$out"

echo "--- a resolution that edits a file neither side changed is refused ---"
WT="$FIX/neither"
B_P1=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" merge -q --no-edit develop >/dev/null 2>&1
printf 'resolved\n' > "$WT/shared.txt"; printf 'slipped in\n' >> "$WT/base.txt"
git -C "$WT" add -A; git -C "$WT" commit -qm "Merge branch 'develop'"
B_M=$(git -C "$WT" rev-parse HEAD)
out=$(driver_prove_trunk_merge "$WT" "$B_P1" "$B_M" "$B_M" 2>&1); rc=$?
want "it is refused"                   "1" "$rc"
want_in "naming that file"             'base\.txt, which neither side changed' "$out"

echo "--- a resolution is not refused here for a red gate: self-check owns that red ---"
WT="$FIX/redgate"
G2_P1=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" merge -q --no-edit develop >/dev/null 2>&1
printf 'resolved\n' > "$WT/shared.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "Merge branch 'develop'"
G2_M=$(git -C "$WT" rev-parse HEAD)
jq '.gates = {lint: "echo lint-ok", test: "false"}' "$HARNESS_CFG_PATH" > "$FIX/red-cfg.json"
out=$(HARNESS_CFG="$FIX/red-cfg.json" driver_prove_trunk_merge "$WT" "$G2_P1" "$G2_M" "$G2_M" 2>&1); rc=$?
want "it is accepted"                  "0" "$rc"
want_not_in "no gate exit is claimed"  'exit [0-9]' "$out"

echo "--- a resolved merge found on the branch before the task is still refused ---"
WT="$FIX/foundres"
git -C "$WT" merge -q --no-edit develop >/dev/null 2>&1
printf 'resolved\n' > "$WT/shared.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "Merge branch 'develop'"
FR_M=$(git -C "$WT" rev-parse HEAD)
out=$(driver_prove_trunk_merge "$WT" "$FR_M" "$FR_M" "$FR_M" 2>&1); rc=$?
want "it is refused"                   "2" "$rc"
want_in "as found before the task"     'was on the branch before this task started' "$out"

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
WT="$FIX/clean"
printf 'loose\n' >> "$WT/own-clean.txt"
out=$(driver_prove_trunk_merge "$WT" "$C_P1" "$C_M" "$C_M" 2>&1); rc=$?
want "uncommitted edits beside it are refused" "2" "$rc"
want_in "naming the file"              'uncommitted edits beside the trunk merge .*\(own-clean\.txt\)' "$out"
out=$(driver_prove_trunk_merge "$FIX/more" "$M_BEFORE" "$M_M" "$C_M" 2>&1); rc=$?
want "another branch's merge is not this task's" "2" "$rc"

suite_end "$FAILED"
