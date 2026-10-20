#!/usr/bin/env bash
# load-fault.test.sh — a gate that failed on the machine is run again by the driver,
# never handed to fix as a finding and never asked about. #13044 (2026-10-20): the
# changed-tests gate was killed under load, then failed on one test outside the change
# that passes alone, and the fix step asked the PM "re-run it, yes or no?".
# Run: bash "$0"
set -uo pipefail
export DRIVER_MAX_GATE_FIXES=1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/self-check.sh" || exit 1

cfg() { jq "$1" "$REPO/.claude/harness.json" > "$FIX/hc" && mv "$FIX/hc" "$REPO/.claude/harness.json"; }

WT="$FIX/wt"
git -C "$REPO" worktree add -q -b tkt-1 "$WT" develop
mkdir -p "$WT/src"
printf 'mine\n' > "$WT/src/mine.ts"; printf 'test\n' > "$WT/src/mine.test.ts"
git -C "$WT" add src; git -C "$WT" commit -qm "feat: mine"
export DRIVER_TICKET=1

# gate <first-run> — a gate that does <first-run> once, then passes.
gate() { printf 'if [ -f "%s/ran" ]; then echo all green; exit 0; fi; touch "%s/ran"; %s' "$FIX" "$FIX" "$1"; }

echo "--- a gate killed under load is run again, not sent to fix ---"
driver_state_init 1 --worktree "$WT"
rm -f "$FIX/ran"
cfg ".gates = {\"tests\": $(jq -Rn --arg c "$(gate 'kill -TERM $$')" '$c'), \"prePush\": false}"
rc=0; out=$(driver_step_self_check 1 2>&1) || rc=$?
want "the second run is green"           "0" "$rc"
want_in "and the reason is said"         'killed \(exit 143\)' "$out"
want "nothing went to fix"               "0" "$(driver_state_count 1 selfcheck_red)"

echo "--- a failing test outside the change is run again, not sent to fix ---"
driver_state_init 2 --worktree "$WT"
rm -f "$FIX/ran"
cfg ".gates = {\"tests\": $(jq -Rn --arg c "$(gate 'printf "\033[31m FAIL \033[39m src/other.test.ts > it times out\n"; exit 1')" '$c'), \"prePush\": false}"
rc=0; out=$(driver_step_self_check 2 2>&1) || rc=$?
want "the second run is green"           "0" "$rc"
want_in "naming the test outside it"     'src/other.test.ts.*outside this change' "$out"
want "nothing went to fix"               "0" "$(driver_state_count 2 selfcheck_red)"

echo "--- a failing test the change touched is the change's: it goes to fix ---"
driver_state_init 3 --worktree "$WT"
rm -f "$FIX/ran"
cfg ".gates = {\"tests\": $(jq -Rn --arg c "$(gate 'echo " FAIL  src/mine.test.ts > does the thing"; exit 1')" '$c'), \"prePush\": false}"
rc=0; out=$(driver_step_self_check 3 2>&1) || rc=$?
want "it is sent to fix"                 "30" "$rc"
want_not_in "and not run again"          'on the machine, not the change' "$out"

echo "--- a red gate that names no test is the change's too ---"
driver_state_init 4 --worktree "$WT"
rm -f "$FIX/ran"
cfg ".gates = {\"tests\": $(jq -Rn --arg c "$(gate 'echo "error TS2769: No overload"; exit 2')" '$c'), \"prePush\": false}"
rc=0; out=$(driver_step_self_check 4 2>&1) || rc=$?
want "it is sent to fix"                 "30" "$rc"
want_not_in "and not run again"          'on the machine, not the change' "$out"

git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
exit $FAILED
