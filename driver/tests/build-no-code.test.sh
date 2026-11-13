#!/usr/bin/env bash
# build-no-code.test.sh — a plan task that changes no code ("re-run the failed CI
# job") has no commit pair to prove, and used to park the build on a question whose
# answer was always yes. The driver now measures it: no diff since the task started,
# and the run it names concluded success on the branch's head, read from GitHub.
#
# Real git, a stubbed gh: the diff is made of a tree, the run of an API answer.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fixture_path REPO "$FIX"
. "$HERE/../steps/build.sh" || exit 1

printf 'no\n' > "$REPO/feature.txt"
git -C "$REPO" add feature.txt; git -C "$REPO" commit -qm base
fix_brief build superpowers:subagent-driven-development

fix_plan() { # <ticket> — one task
  jq -n '{step:"plan", skills:["superpowers:writing-plans"], status:"planned", designSource:"ticket-body",
          premise:{verdict:"still-true", evidence:"ci"},
          tasks:[{title:"task 1", files:[], tests:[]}]}' > "$(driver_state_dir "$1")/steps/plan.json"
}

echo "--- a task that changes no code is accepted on a green run of the head ---"
# "Re-run the failed CI job" commits nothing, so there is no pair to prove. The driver
# measures the tree itself and reads the run itself; the answer's word is neither.
fix_no_code() { # <run> [task]
  jq -nc --arg r "$1" --arg k "${2:-task 1}" \
    '{step:"build", skills:["superpowers:subagent-driven-development"], status:"built", task:$k,
      noCode:{reason:"the job failed on a runner fault and is re-run", run:$r},
      changed:[], changelog:{skipped:"no code changed"}}'
}
fix_run() { # <id> <conclusion> <head-sha> [status]
  jq -n --argjson id "$1" --arg c "$2" --arg s "$3" --arg st "${4:-completed}" \
    '{id:$id, status:$st, conclusion:(if $c == "" then null else $c end), head_sha:$s, head_branch:"tkt-1"}' \
    > "$FIX/gh/api-repos_acme_widgets_actions_runs_$1.json"
}
want "the tree starts clean" "" "$(git -C "$REPO" status --porcelain --untracked-files=no)"
NC_HEAD=$(git -C "$REPO" rev-parse HEAD)
fix_run 555 success "$NC_HEAD"
driver_state_init 141 --worktree "$REPO" --repo "$REPO"
fix_plan 141
fix_ai build "$(fix_no_code https://github.com/acme/widgets/actions/runs/555/attempts/2)" superpowers:subagent-driven-development
: > "$GH_LOG"
out=$(DRIVER_TICKET=141 driver_step_build 141 2>&1); rc=$?
want "the step finishes"                 "0" "$rc"
want_in "naming the run and the head"    "CI run 555 concluded success on the head $(printf '%s' "$NC_HEAD" | cut -c1-8)" "$out"
want_in "the run was read from this repo" 'api repos/acme/widgets/actions/runs/555' "$(cat "$GH_LOG")"
want "it is recorded as proved, on the head" "$NC_HEAD" "$(jq -r '.commits[0]' "$(driver_state_dir 141)/steps/build-task-1.proved" 2>/dev/null)"
want "the head did not move"             "$NC_HEAD" "$(git -C "$REPO" rev-parse HEAD)"
out=$(DRIVER_TICKET=141 driver_step_build 141 2>&1); rc=$?
want_in "a later pass keeps it"          'task 1 — kept' "$out"

echo "--- a bare run id is read the same way ---"
driver_state_init 142 --worktree "$REPO" --repo "$REPO"
fix_plan 142
fix_ai build "$(fix_no_code 555)" superpowers:subagent-driven-development
rc=0; DRIVER_TICKET=142 driver_step_build 142 >/dev/null 2>&1 || rc=$?
want "the step finishes" "0" "$rc"

echo "--- a noCode claim with a diff is refused ---"
# The session edits a tracked file and says it changed nothing: the run is green on
# the head, so only the driver's own diff check can refuse it.
cp "$BIN/claude" "$FIX/claude.keep"; cp "$REPO/feature.txt" "$FIX/feature.keep"
{ printf '#!/usr/bin/env bash\nprintf "edited\\n" >> "$REPO/feature.txt"\nexec "$FIX/claude.keep" "$@"\n'; } > "$BIN/claude"; chmod +x "$BIN/claude"
driver_state_init 143 --worktree "$REPO" --repo "$REPO"
fix_plan 143
fix_ai build "$(fix_no_code 555)" superpowers:subagent-driven-development
rc=0; out=$(DRIVER_TICKET=143 driver_step_build 143 2>&1) || rc=$?
cp "$FIX/claude.keep" "$BIN/claude"
want "the session did edit the tree"   " M feature.txt" "$(git -C "$REPO" status --porcelain --untracked-files=no)"
cp "$FIX/feature.keep" "$REPO/feature.txt"
want "it asks for rework"              "30" "$rc"
want_in "naming the diff"              'declared noCode and changed the tree since .*feature\.txt' "$out"
want_in "the next try is told why"     'changed the tree' "$(cat "$(driver_state_dir 143)/steps/build-task-1.refused" 2>/dev/null)"
want "and nothing is recorded as proved" "no" "$([ -e "$(driver_state_dir 143)/steps/build-task-1.proved" ] && echo yes || echo no)"
# A committed change is a diff too: the head moved, the run is green on the new head.
printf 'committed\n' >> "$REPO/feature.txt"; git -C "$REPO" commit -qam "feat: not nothing"
NC_NEXT=$(git -C "$REPO" rev-parse HEAD)
fix_run 556 success "$NC_NEXT"
out=$(driver_prove_no_code "$REPO" "$NC_HEAD" 556 2>&1); rc=$?
want "a committed change is refused"   "1" "$rc"
out=$(driver_prove_no_code "$REPO" "$NC_NEXT" 556 2>&1); rc=$?
want "and from the new head, with its own green run, nothing changed" "0" "$rc"

echo "--- a change an earlier try of the task committed is still its diff on the next try ---"
# Try 1 commits a change and says noCode; try 2 says it again, with a green run on the
# new head. Measured from the try's own start there would be no diff left to see.
cp "$BIN/claude" "$FIX/claude.keep"
printf '#!/usr/bin/env bash\nprintf "sneaked\\n" >> "$REPO/feature.txt"; git -C "$REPO" commit -qam "feat: sneaked"\ncp "$FIX/claude.keep" "$BIN/claude"\nexec "$FIX/claude.keep" "$@"\n' > "$BIN/claude"; chmod +x "$BIN/claude"
R_START=$(git -C "$REPO" rev-parse HEAD)
driver_state_init 146 --worktree "$REPO" --repo "$REPO"
fix_plan 146
fix_ai build "$(fix_no_code 560)" superpowers:subagent-driven-development
rc=0; DRIVER_TICKET=146 driver_step_build 146 >/dev/null 2>&1 || rc=$?
want "try 1 is sent back"              "30" "$rc"
want "having committed"                "$R_START" "$(git -C "$REPO" rev-parse "HEAD^")"
fix_run 560 success "$(git -C "$REPO" rev-parse HEAD)"
rc=0; out=$(DRIVER_TICKET=146 driver_step_build 146 2>&1) || rc=$?
want "try 2, green on the new head, is sent back too" "30" "$rc"
want_in "measured from where the task started" "changed the tree since $(printf '%s' "$R_START" | cut -c1-8) \(feature\.txt\)" "$out"
NC_NEXT=$(git -C "$REPO" rev-parse HEAD)
fix_run 556 success "$NC_NEXT"

echo "--- a noCode claim whose run is not green on the head is refused ---"
fix_run 557 failure "$NC_NEXT"
driver_state_init 144 --worktree "$REPO" --repo "$REPO"
fix_plan 144
fix_ai build "$(fix_no_code 557)" superpowers:subagent-driven-development
rc=0; out=$(DRIVER_TICKET=144 driver_step_build 144 2>&1) || rc=$?
want "a red run asks for rework"       "30" "$rc"
want_in "naming its conclusion"        'CI run 557 is not green: status completed, conclusion failure' "$out"
fix_run 558 "" "$NC_NEXT" in_progress
out=$(driver_prove_no_code "$REPO" "$NC_NEXT" 558 2>&1); rc=$?
want "a run still going is refused"    "2" "$rc"
want_in "naming its status"            'status in_progress' "$out"
# 555 is green, on the commit before this head.
driver_state_init 145 --worktree "$REPO" --repo "$REPO"
fix_plan 145
fix_ai build "$(fix_no_code 555)" superpowers:subagent-driven-development
rc=0; out=$(DRIVER_TICKET=145 driver_step_build 145 2>&1) || rc=$?
want "a green run on another commit asks for rework" "30" "$rc"
want_in "naming both commits"          "CI run 555 concluded success on $(printf '%s' "$NC_HEAD" | cut -c1-8), not on the branch's head $(printf '%s' "$NC_NEXT" | cut -c1-8)" "$out"
out=$(driver_prove_no_code "$REPO" "$NC_NEXT" 999 2>&1); rc=$?
want "a run GitHub does not have is refused" "2" "$rc"
want_in "and said"                     'CI run 999 could not be read in acme/widgets' "$out"
fix_gh_fail "api repos/acme/widgets/actions/runs/556"
out=$(driver_prove_no_code "$REPO" "$NC_NEXT" 556 2>&1); rc=$?
fix_gh_ok
want "a read GitHub refused is not a green run" "2" "$rc"
: > "$GH_LOG"
out=$(driver_prove_no_code "$REPO" "$NC_NEXT" https://github.com/other/place/actions/runs/556 2>&1); rc=$?
want "another repo's run is refused"   "2" "$rc"
want_in "naming the repo"              'a run of other/place, not of this repo \(acme/widgets\)' "$out"
want "and is never fetched"            "" "$(cat "$GH_LOG")"
out=$(driver_prove_no_code "$REPO" "$NC_NEXT" "the re-run passed" 2>&1); rc=$?
want "evidence that names no run cannot be checked" "3" "$rc"

suite_end "$FAILED"
