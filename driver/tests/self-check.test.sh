#!/usr/bin/env bash
# self-check.test.sh — the gates. Two rules carry everything here: each gate is
# its OWN command whose exit code is read, and a self-check with nothing to run
# is a refusal rather than a pass. A gate that never ran reports exactly like a
# gate that found nothing, which is why the second rule exists.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/self-check.sh" || exit 1
driver_state_init 101 --worktree "$REPO"

echo "--- every configured gate runs, and passes ---"
out=$(driver_step_self_check 101 2>&1); rc=$?
want "it finishes"     "0" "$rc"
want_in "lint ran"     'lint' "$out"
want_in "test ran"     'test' "$out"

echo "--- a red gate stops the step, and is named ---"
jq '.gates.test = "exit 3"' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
out=$(driver_step_self_check 101 2>&1); rc=$?
want "a red gate refuses" "24" "$rc"
want_in "naming the gate" 'test' "$out"
want_in "and its exit code" 'exit 3' "$out"

echo "--- a gate that prints a failure and exits 0 still passes: the code is the verdict ---"
jq '.gates.test = "echo ERROR: something; exit 0"' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
rc=0; driver_step_self_check 101 >/dev/null 2>&1 || rc=$?
want "the exit line is the reading" "0" "$rc"

echo "--- EVERY gate runs, even after one has failed ---"
# The group short-circuits nowhere: a gate behind a failing one is a gate nobody
# has run, and it reports green by never reporting at all.
jq '.gates = {"a":"exit 1","b":"exit 0","c":"exit 1"}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
out=$(driver_step_self_check 101 2>&1)
want_in "the gate behind the failure ran" 'b' "$out"
want_in "and the last one too"            'c' "$out"

echo "--- no gates configured is a refusal, not a pass ---"
jq 'del(.gates)' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
out=$(driver_step_self_check 101 2>&1); rc=$?
want "nothing to run refuses" "24" "$rc"
want_in "and says what to configure" 'gates' "$out"

echo "--- the gates run in the ticket's worktree, not wherever the driver started ---"
jq '.gates = {"here":"test -f marker"}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
mkdir -p "$FIX/wt2"; : > "$FIX/wt2/marker"
driver_state_init 202 --worktree "$FIX/wt2"
rc=0; driver_step_self_check 202 >/dev/null 2>&1 || rc=$?
want "it ran where the work is" "0" "$rc"

exit $FAILED
