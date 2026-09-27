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
# Pinned on the GATE'S OWN LINE, not on a letter. `want_in … 'c'` is satisfied by
# the "c" in "self-check", which every line of this step's output contains — so with
# a break added after the first failure, gate c never ran and that assertion still
# printed OK.
want_in "the gate behind the failure ran" 'self-check: b ok' "$out"
want_in "and the last one too"            'self-check: c failed' "$out"
want "all three were counted"             "3" \
  "$(printf '%s' "$out" | grep -cE 'self-check: [abc] (ok|failed)')"

echo "--- no gates configured is a refusal, not a pass ---"
jq 'del(.gates)' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
out=$(driver_step_self_check 101 2>&1); rc=$?
want "nothing to run refuses" "24" "$rc"
want_in "and says what to configure" 'gates' "$out"

echo "--- a gate that never returns is refused, not waited on ---"
jq '.gates = {"hang":"sleep 60"}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
t0=$(date +%s)
out=$(DRIVER_CMD_TIMEOUT=2 driver_step_self_check 101 2>&1); rc=$?
t1=$(date +%s)
want "it refuses"                   "24" "$rc"
want_in "naming it as a time limit" 'time' "$out"
if [ $((t1 - t0)) -lt 30 ]; then ok "it came back in $((t1-t0))s"; else bad "waited $((t1-t0))s — the bound did not hold"; fi

echo "--- a command that is only whitespace or a comment is not a gate that ran ---"
# One keystroke from the empty case, and operator-authored: a placeholder left in
# harness.json counted as a gate, printed "ok", and took the green count up with it.
jq '.gates = {"lint":"  ","test":"# TODO: wire this up"}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
out=$(driver_step_self_check 101 2>&1); rc=$?
want "it refuses"                  "24" "$rc"
want_not_in "and never says green" 'green' "$out"

echo "--- gates present but every command empty: nothing ran, so nothing passed ---"
# This is the same failure as no gates at all, wearing a configured shape. The loop
# skips an empty or null command, the counter stays at zero, and the step then
# reports "0 gate(s) green" and returns OK — so ship pushes and arms auto-merge on
# code nothing checked. A check that did not run has to look different from one that
# found nothing wrong; that is the step's whole reason for existing.
jq '.gates = {"lint":"","test":null}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
out=$(driver_step_self_check 101 2>&1); rc=$?
want "it refuses"                 "24" "$rc"
want_not_in "and never says green" 'green' "$out"
want_in "naming what is empty"     'lint' "$out"

echo "--- gates written as a list instead of an object ---"
# One typo in harness.json. Read as an object it yields no names at all, and the
# step's own "nothing configured" guard does not fire because the key IS there.
jq '.gates = ["npm test"]' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
out=$(driver_step_self_check 101 2>&1); rc=$?
want "it refuses"                  "24" "$rc"
want_in "and says what shape it wanted" 'name to command|object' "$out"

echo "--- the gates run in the ticket's worktree, not wherever the driver started ---"
jq '.gates = {"here":"test -f marker"}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
mkdir -p "$FIX/wt2"; : > "$FIX/wt2/marker"
driver_state_init 202 --worktree "$FIX/wt2"
rc=0; driver_step_self_check 202 >/dev/null 2>&1 || rc=$?
want "it ran where the work is" "0" "$rc"

exit $FAILED
