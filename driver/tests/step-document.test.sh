#!/usr/bin/env bash
# step-document.test.sh — a document a step's own tooling leaves in a scratch folder
# the project keeps in git is committed by name as that step ends, so the tree is
# clean before the next step. Ship's refusal of any other uncommitted file stands.
#
# The step here is the real driver_ai_step on the briefs that ship; only the agent is
# a recorder, so the document is planted where the planning skill would leave it.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'

# A project that keeps its plans in git.
mkdir -p "$REPO/docs/superpowers/plans"
printf 'kept\n' > "$REPO/docs/superpowers/plans/older.md"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "docs: an older plan the project keeps"
git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop

fix_real_briefs
. "$HERE/../ai-step.sh" || exit 1
. "$HERE/../steps/ship.sh" || exit 1
PLAN_OK=$(jq -c . "$KIT/briefs/examples/plan.valid.json")
PLAN_SKILLS=$(jq -r '.skills | join(" ")' "$KIT/briefs/examples/plan.valid.json")

setup_wt() { # <ticket> [base] — a claimed ticket in a worktree of its own
  local t=$1 wt="$FIX/wt$1"
  git -C "$REPO" worktree add -q "$wt" -b "tkt-$t/work" "${2:-develop}"
  driver_state_init "$t" --worktree "$wt" --branch "tkt-$t/work"; fix_gates_kept "$t"
  driver_state_set "$t" claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
  fix_issue "$t" OPEN "status:claimed"
}
run_plan() { # <ticket> — one plan step, as the driver runs it
  export DRIVER_TICKET=$1
  fix_ai plan "$PLAN_OK" "$PLAN_SKILLS"
  driver_ai_step "$1" plan 2>&1
}
last_files() { git -C "$1" show --name-only --format= HEAD | tr '\n' ' '; }
PLAN=docs/superpowers/plans/2026-11-11-a-plan.md

echo "--- a NEW plan document in a tracked folder is committed by the step ---"
setup_wt 501
printf '# the plan for 501\n' > "$FIX/wt501/$PLAN"
out=$(run_plan 501)
want "the tree is clean when the step ends" "" "$(git -C "$FIX/wt501" status --porcelain)"
want "the commit holds the document and nothing else" "$PLAN " "$(last_files "$FIX/wt501")"
want "as the step wrote it" "# the plan for 501" "$(git -C "$FIX/wt501" show "HEAD:$PLAN")"
want_in "and the step says so by name" "plan: committed the document its own tooling wrote under docs/superpowers — $PLAN" "$out"

echo "--- one the step STAGED, its own commit refused by a hook, is committed too ---"
# The real case: the session ran `git add <plan> && git commit`, the project's
# commit-msg hook refused, and the document sat staged — not untracked, not committed.
setup_wt 502
printf '# the plan for 502\n' > "$FIX/wt502/$PLAN"
git -C "$FIX/wt502" add "$PLAN"
want "it starts staged, which is not untracked" "" \
  "$(git -C "$FIX/wt502" ls-files --others --exclude-standard)"
out=$(run_plan 502)
want "the tree is clean when the step ends" "" "$(git -C "$FIX/wt502" status --porcelain)"
want "the commit holds the document and nothing else" "$PLAN " "$(last_files "$FIX/wt502")"

echo "--- a later step that EDITS the committed document commits the edit ---"
printf '# the plan for 502, planned again\n' > "$FIX/wt502/$PLAN"
out=$(run_plan 502)
want "the tree is clean when the step ends" "" "$(git -C "$FIX/wt502" status --porcelain)"
want "the edit is what is committed" "# the plan for 502, planned again" "$(git -C "$FIX/wt502" show "HEAD:$PLAN")"
want "in a commit of the document alone" "$PLAN " "$(last_files "$FIX/wt502")"

echo "--- a file no step owns is left exactly as it was, staged or not ---"
setup_wt 503
printf '# the plan for 503\n' > "$FIX/wt503/$PLAN"
printf 'half a change\n' > "$FIX/wt503/stray.txt"
printf 'staged, never committed\n' > "$FIX/wt503/staged.txt"
git -C "$FIX/wt503" add staged.txt
out=$(run_plan 503)
want "the commit holds the document and nothing else" "$PLAN " "$(last_files "$FIX/wt503")"
want "the other two are still uncommitted" "A  staged.txt ?? stray.txt " \
  "$(git -C "$FIX/wt503" status --porcelain | tr '\n' ' ')"

echo "--- and ship still refuses it ---"
driver_state_put 503 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 503 review
for st in start plan build self-check review record; do driver_state_done 503 "$st"; done
: > "$GH_LOG"
rc=0; out=$(driver_step_ship 503 2>&1) || rc=$?
want "ship refuses" "24" "$rc"
want_in "naming the files" 'ship: uncommitted changes — staged.txt stray.txt' "$out"
want_not_in "and nothing is pushed" 'pr create' "$(cat "$GH_LOG")"
want "origin has no such branch" "" "$(git -C "$FIX/origin" rev-parse -q --verify tkt-503/work)"

echo "--- a deleted document is not the step's to commit ---"
setup_wt 504
rm "$FIX/wt504/docs/superpowers/plans/older.md"
H504=$(git -C "$FIX/wt504" rev-parse HEAD)
out=$(run_plan 504)
want "nothing is committed" "$H504" "$(git -C "$FIX/wt504" rev-parse HEAD)"
want "the deletion is still there for ship to refuse" " D docs/superpowers/plans/older.md" \
  "$(git -C "$FIX/wt504" status --porcelain)"

echo "--- ship commits one a run from before this left staged, and ships ---"
setup_wt 505
printf 'change for 505\n' > "$FIX/wt505/f505.txt"
git -C "$FIX/wt505" add f505.txt; git -C "$FIX/wt505" commit -qm "feat: thing 505"
printf '# the plan for 505\n' > "$FIX/wt505/$PLAN"
git -C "$FIX/wt505" add "$PLAN"
driver_state_put 505 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 505 review
for st in start plan build self-check review record; do driver_state_done 505 "$st"; done
rc=0; out=$(driver_step_ship 505 2>&1) || rc=$?
want "it ships" "0" "$rc"
want "the pushed branch holds the plan" "# the plan for 505" \
  "$(git -C "$FIX/origin" show "tkt-505/work:$PLAN" 2>/dev/null)"
want "and the tree is clean" "" "$(git -C "$FIX/wt505" status --porcelain)"

echo "--- a project that does NOT keep the folder gets no such commit ---"
git -C "$REPO" branch -q bare-trunk "$(git -C "$REPO" rev-list --max-parents=0 HEAD | tail -1)"
setup_wt 506 bare-trunk
want "the folder is not in this project's history" "" \
  "$(git -C "$FIX/wt506" ls-tree -r --name-only HEAD -- docs/superpowers)"
mkdir -p "$FIX/wt506/docs/superpowers/plans"
printf '# the plan for 506\n' > "$FIX/wt506/$PLAN"
H506=$(git -C "$FIX/wt506" rev-parse HEAD)
out=$(run_plan 506)
want "nothing is committed" "$H506" "$(git -C "$FIX/wt506" rev-parse HEAD)"
want "the plan is moved out of the tree, as before" "" "$(ls "$FIX/wt506/docs/superpowers" 2>/dev/null)"
want "and kept where a person can read it" "1" \
  "$(grep -rl 'the plan for 506' "$(driver_state_dir 506)/scratch" 2>/dev/null | grep -c .)"

suite_end "$FAILED"
