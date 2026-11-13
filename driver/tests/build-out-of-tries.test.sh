#!/usr/bin/env bash
# build-out-of-tries.test.sh — a build parked out of tries says, on the ticket, why each
# unproved task's last try was refused. The .refused files stay on the building machine.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fixture_path REPO "$FIX"
. "$HERE/../steps/build.sh" || exit 1
. "$HERE/../ai-step.sh" || exit 1
. "$HERE/../push-requires.sh" || exit 1
. "$HERE/../steps/park.sh" || exit 1

printf 'no\n' > "$REPO/feature.txt"
git -C "$REPO" add feature.txt; git -C "$REPO" commit -qm base
fix_brief build superpowers:subagent-driven-development

fix_plan() { # <ticket> <title>...
  local t="$1"; shift
  jq -n --args '{step:"plan", skills:["superpowers:writing-plans"], status:"planned", designSource:"ticket-body",
          premise:{verdict:"still-true", evidence:"ci"},
          tasks:[$ARGS.positional[] | {title:., files:[], tests:[]}]}' "$@" > "$(driver_state_dir "$t")/steps/plan.json"
}
last_try() { local i=1; while [ $i -lt "$DRIVER_MAX_BUILD_TRIES" ]; do driver_state_bump "$1" build; i=$((i+1)); done; }

echo "--- the last try names no test: the park note says so, by task ---"
driver_state_init 161 --worktree "$REPO" --repo "$REPO"
last_try 161
fix_plan 161 "wire the widget"
fix_ai build '{"step":"build","skills":["superpowers:subagent-driven-development"],"status":"built","task":"wire the widget","changed":[{"path":"a.sh","action":"modify"}],"changelog":{"skipped":"none"}}' superpowers:subagent-driven-development
rc=0; out=$(DRIVER_TICKET=161 driver_step_build 161 2>&1) || rc=$?
want "out of tries refuses" "24" "$rc"
note=$(driver_state_get 161 park_note)
want_in "the note names the task"       'task 1 \(wire the widget\)' "$note"
want_in "and why it was refused"        'names no test to prove it' "$note"
want "and the try count is unchanged"   "$DRIVER_MAX_BUILD_TRIES" "$(driver_state_count 161 build)"

echo "--- a planted refusal reaches the ticket comment, cut to a readable length ---"
driver_state_init 162 --worktree "$REPO" --repo "$REPO"
fix_plan 162 "first task" "second task"
long="the test passes without the change: $(printf 'x%.0s' $(seq 1 600))"
printf '%s\n' "$long" > "$(driver_state_dir 162)/steps/build-task-1.refused"
printf 'proof ran red on both sides\n' > "$(driver_state_dir 162)/steps/build-task-2.refused"
_driver_build_out_of_tries 162 "$DRIVER_MAX_BUILD_TRIES" 2 >/dev/null 2>&1
note=$(driver_state_get 162 park_note)
want_in "task 1's reason is there"      'task 1 \(first task\): the test passes without the change' "$note"
want_in "task 2's reason is there"      'task 2 \(second task\): proof ran red on both sides' "$note"
want_not_in "a long reason is cut"      "$(printf 'x%.0s' $(seq 1 400))" "$note"
want_in "and says it was cut"           'xxx\.\.\.' "$note"

fix_issue 162 OPEN "status:claimed"
: > "$GH_LOG"
DRIVER_MAX_MACHINE_PARKS=0 driver_park 162 "build refused" "$note" driver >/dev/null 2>&1
want_in "the comment carries it under What stopped it" \
  'What stopped it:\*\* 5 of 5 tries used.*task 2 \(second task\): proof ran red on both sides' "$(cat "$GH_LOG")"

echo "--- the last try builds another plan task: that reason, not a stale one ---"
driver_state_init 165 --worktree "$REPO" --repo "$REPO"
last_try 165
fix_plan 165 "wire the widget" "paint the widget"
printf 'stale reason from an earlier try\n' > "$(driver_state_dir 165)/steps/build-task-1.refused"
fix_ai build '{"step":"build","skills":["superpowers:subagent-driven-development"],"status":"built","task":"paint the widget","changed":[{"path":"a.sh","action":"modify"}],"changelog":{"skipped":"none"}}' superpowers:subagent-driven-development
rc=0; DRIVER_TICKET=165 driver_step_build 165 >/dev/null 2>&1 || rc=$?
want "out of tries refuses" "24" "$rc"
note=$(driver_state_get 165 park_note)
want_in "the note gives the wrong-task reason" 'task 1 \(wire the widget\): .*another task in this plan' "$note"
want_not_in "and not the stale one"            'stale reason' "$note"

echo "--- a proved task is not reported as refused ---"
driver_state_init 163 --worktree "$REPO" --repo "$REPO"
fix_plan 163 "done task"
printf 'old reason\n' > "$(driver_state_dir 163)/steps/build-task-1.refused"
printf '{"title":"done task"}\n' > "$(driver_state_dir 163)/steps/build-task-1.proved"
_driver_build_out_of_tries 163 "$DRIVER_MAX_BUILD_TRIES" 1 >/dev/null 2>&1
want_not_in "no reason for a proved task" 'old reason' "$(driver_state_get 163 park_note)"

echo "--- not out of tries: no note ---"
driver_state_init 164 --worktree "$REPO" --repo "$REPO"
rc=0; _driver_build_out_of_tries 164 1 1 >/dev/null 2>&1 || rc=$?
want "an early try is not the last" "1" "$rc"
want "and leaves no note" "" "$(driver_state_get 164 park_note)"

suite_end "$FAILED"
