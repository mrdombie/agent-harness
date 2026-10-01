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
# 25, not 24. A hang says nothing about the change, and the park question a reader needs
# is "which command does not return", not "which check failed".
want "a hang is its own outcome"    "25" "$rc"
want_in "naming it as a time limit" 'time' "$out"
want_in "and it leaves the command for the handover" 'sleep 60' "$(driver_state_get 101 park_note)"
if [ $((t1 - t0)) -lt 30 ]; then ok "it came back in $((t1-t0))s"; else bad "waited $((t1-t0))s — the bound did not hold"; fi

echo "--- a time limit that is not a number bounds nothing, and says so ---"
# perl reads `alarm "15m"` as `alarm 0`, which CANCELS the alarm — so an operator writing
# "15m" or "900s" in the config silently removes every bound in the driver, and a
# watch-mode runner then hangs the run for ever with nothing printed. A bound nobody
# applied must not read like one that held.
jq '.gates = {"quick":"true"}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
out=$(DRIVER_CMD_TIMEOUT=15m driver_step_self_check 101 2>&1); rc=$?
want "the gate still runs"             "0" "$rc"
want_in "and it says the bound is not there" 'UNBOUNDED' "$out"
want_in "naming the value it could not use"  '15m' "$out"

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

echo "--- a project's changed-only gates run instead of its whole-app ones ---"
jq '.gates = {"changed":["echo ran-changed"], "local":["echo ran-whole-app; exit 1"]}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
out=$(driver_step_self_check 101 2>&1); rc=$?
want "the changed-only list passes"         "0" "$rc"
want_in "and it is the one that ran"        'changed 1' "$out"
want_not_in "the whole-app list did not run" 'local 1'  "$out"

echo "--- with no changed-only list, the whole-app one still runs ---"
jq '.gates = {"local":["exit 1"]}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
rc=0; driver_step_self_check 101 >/dev/null 2>&1 || rc=$?
want "it falls back and reads the red" "24" "$rc"

echo "--- the build's own 'no changelog' claim is said once for the branch, nothing rewritten (#11168) ---"
# The trial run: every build answer said changelog skipped, the commits did not carry
# the project's line, and the push was refused after review was paid for.
git -C "$REPO" worktree add -q "$FIX/wt140" -b tkt-140/work develop
cm() { git -C "$FIX/wt140" -c user.email=t@e.invalid -c user.name=T commit -q --allow-empty "$@"; }
cm -m "fix(gates): the first fix"
git -C "$REPO" -c user.email=t@e.invalid -c user.name=T commit -q --allow-empty -m "develop moves"
printf 'merged\n' > "$FIX/wt140/merged.txt"
git -C "$FIX/wt140" -c user.email=t@e.invalid -c user.name=T merge -q --no-edit develop
git -C "$FIX/wt140" add merged.txt && cm -m "fix(gates): after the merge"
BEFORE=$(git -C "$FIX/wt140" rev-parse HEAD); TREE=$(git -C "$FIX/wt140" rev-parse 'HEAD^{tree}')
driver_state_init 140 --worktree "$FIX/wt140"
mkdir -p "$(driver_state_dir 140)/steps"
printf '%s\n' '{"step":"build","changelog":{"skipped":"Internal gate tooling,\nnothing a user sees."}}' '{"step":"build","changelog":{"skipped":"Same tooling."}}' > "$(driver_state_dir 140)/steps/build.all.json"
jq '.gates = {"ok":"exit 0"} | .changelog = {"branchTrailer":"no-changelog-branch"}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
rc=0; out=$(driver_step_self_check 140 2>&1) || rc=$?
want "it finishes"                                 "0" "$rc"
want_in "saying it said so once for the branch"    'said once for the branch' "$out"
want_in "one new commit carries the line, on one line" 'no-changelog-branch: Internal gate tooling, nothing a user sees.' "$(git -C "$FIX/wt140" log -1 --format=%B)"
want "it sits on top of the branch, nothing rewritten" "$BEFORE" "$(git -C "$FIX/wt140" rev-parse HEAD~1)"
want "and the tree is byte-identical, merge and all" "$TREE" "$(git -C "$FIX/wt140" rev-parse 'HEAD^{tree}')"
driver_step_self_check 140 >/dev/null 2>&1
want "a second self-check does not say it twice"   "1" "$(git -C "$FIX/wt140" log --format=%B "$BEFORE"..HEAD | grep -c '^no-changelog-branch:')"

echo "--- staged work is never swept into the note; a mention mid-sentence is not the line ---"
git -C "$FIX/wt140" reset -q --hard "$BEFORE"
git -C "$FIX/wt140" -c user.email=t@e.invalid -c user.name=T commit -q --allow-empty -m "docs: note" -m "We could add no-changelog-branch: later."
MID=$(git -C "$FIX/wt140" rev-parse HEAD)
printf 'staged\n' > "$FIX/wt140/staged.txt"; git -C "$FIX/wt140" add staged.txt
driver_step_self_check 140 >/dev/null 2>&1
want "a mid-sentence mention does not count: the note is added" "$MID" "$(git -C "$FIX/wt140" rev-parse HEAD~1)"
want "and the note commit is empty — the staged file is not in it" "" "$(git -C "$FIX/wt140" show --name-only --format= HEAD)"
want_in "the staged file is still staged"      'staged.txt' "$(git -C "$FIX/wt140" diff --cached --name-only)"
git -C "$FIX/wt140" reset -q --hard "$BEFORE"

echo "--- not every build answer skipped, or no project trailer: nothing is added ---"
git -C "$FIX/wt140" reset -q --hard "$BEFORE"
printf '%s\n' '{"step":"build","changelog":{"skipped":"tooling"}}' '{"step":"build"}' > "$(driver_state_dir 140)/steps/build.all.json"
driver_step_self_check 140 >/dev/null 2>&1
want "an answer that did not say skipped: untouched" "$BEFORE" "$(git -C "$FIX/wt140" rev-parse HEAD)"
printf '%s\n' '{"step":"build","changelog":{"skipped":"tooling"}}' '{"step":"build","changelog":{"file":"changelog/140.md"}}' > "$(driver_state_dir 140)/steps/build.all.json"
driver_step_self_check 140 >/dev/null 2>&1
want "an entry written: untouched"                 "$BEFORE" "$(git -C "$FIX/wt140" rev-parse HEAD)"
printf '%s\n' '{"step":"build","changelog":{"skipped":"tooling"}}' > "$(driver_state_dir 140)/steps/build.all.json"
jq 'del(.changelog)' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
driver_step_self_check 140 >/dev/null 2>&1
want "no branchTrailer: untouched"                 "$BEFORE" "$(git -C "$FIX/wt140" rev-parse HEAD)"

exit $FAILED
