#!/usr/bin/env bash
# state.test.sh — the run record is what makes a stop survivable, so this asserts
# the two things that depend on it: a finished step is remembered, and a step
# that has not finished is not.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../state.sh" || exit 1

echo "--- init ---"
driver_state_init 101 --branch tkt-101/work --worktree "$FIX/wt"
want "the ticket is recorded"   "101"            "$(driver_state_get 101 ticket)"
want "the branch is recorded"   "tkt-101/work"   "$(driver_state_get 101 branch)"
want "nothing has finished yet" ""               "$(driver_state_get 101 'done|join(",")')"
want "the state dir exists"     "1"              "$([ -d "$(driver_state_dir 101)" ] && echo 1)"

echo "--- a second init keeps what is already there ---"
driver_state_set 101 step build
driver_state_init 101 --branch tkt-101/work --worktree "$FIX/wt"
want "the step survived re-init" "build" "$(driver_state_get 101 step)"

echo "--- finished steps ---"
driver_state_done 101 start
driver_state_done 101 plan
want "both are recorded"  "start,plan" "$(driver_state_get 101 'done|join(",")')"
driver_state_is_done 101 start && ok "start reads as done" || bad "start should read as done"
driver_state_is_done 101 build && bad "build must NOT read as done" || ok "build does not read as done"

echo "--- done is idempotent: a resumed run must not double-record ---"
driver_state_done 101 start
want "start is listed once" "start,plan" "$(driver_state_get 101 'done|join(",")')"

echo "--- counters ---"
want "a fresh counter is 0" "0" "$(driver_state_count 101 build)"
driver_state_bump 101 build
driver_state_bump 101 build
want "two bumps read as 2"  "2" "$(driver_state_count 101 build)"
want "another counter is untouched" "0" "$(driver_state_count 101 review)"

echo "--- step output ---"
driver_state_put 101 review '{"verdict":"SHIP"}'
want "the step's answer is readable" "SHIP" "$(jq -r .verdict "$(driver_state_dir 101)/steps/review.json")"

echo "--- a ticket nobody started ---"
driver_state_is_done 999 start && bad "an unknown ticket must not report a finished step" || ok "an unknown ticket has finished nothing"

exit $FAILED
