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
# The first red on a run goes to fix (30); see the repair cases below.
want "a red gate never passes" "30" "$rc"
want_in "naming the gate" 'test' "$out"
want_in "and its exit code" 'exit 3' "$out"
out=$(driver_step_self_check 101 2>&1); rc=$?
want "a second red refuses" "24" "$rc"

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

echo "--- a red gate the model can repair goes to fix ONCE, carrying its output ---"
# Measured 2026-10-17: two runs proved every test red then green, then parked at
# self-check on a type error in that same test file — a one-line repair nobody tried.
jq '.gates = {"lint":"exit 0","typecheck":"echo \"x.test.ts(82,5): error TS2769: No overload matches this call.\"; exit 2"}' \
  "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
driver_state_init 301 --worktree "$REPO"
F301="$(driver_state_dir 301)/steps/self-check.findings.json"
out=$(driver_step_self_check 301 2>&1); rc=$?
want "it goes back for a fix, not a park"     "30" "$rc"
want "one finding, for the red gate only"     "gate-typecheck" "$(jq -r '[.[].id] | join(",")' "$F301" 2>/dev/null)"
want_in "with the gate's own output"          'error TS2769' "$(jq -r '.[0].output' "$F301" 2>/dev/null)"
want "and its exit code"                      "2" "$(jq -r '.[0].exit' "$F301" 2>/dev/null)"
want "nothing is left to park on"             "" "$(driver_state_get 301 park_note)"
echo "--- the second red parks, and the reason travels with it (#199) ---"
out=$(driver_step_self_check 301 2>&1); rc=$?
want "a second red self-check refuses"        "24" "$rc"
want "and leaves no finding for fix"          "absent" "$([ -e "$F301" ] && echo present || echo absent)"
want_in "the park note names the gate"        'typecheck' "$(driver_state_get 301 park_note)"
want_in "its exit code"                       'exit 2' "$(driver_state_get 301 park_note)"
want_in "and the line that said no"           'error TS2769' "$(driver_state_get 301 park_note)"
# And it reaches the comment the park posts, the way build-ticket hands it over.
. "$HERE/../steps/park.sh" || exit 1
: > "$GH_LOG"
driver_park 301 "self-check refused (exit 24)" "$(driver_state_get 301 park_note)" driver >/dev/null 2>&1
want_in "the posted park comment names the red gate and its line" 'typecheck.*error TS2769' "$(tr '\n' ' ' < "$GH_LOG")"

echo "--- a gate that could not run at all is configuration: it parks, not fixes ---"
jq '.gates = {"lint":"no-such-command-xyz"}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
driver_state_init 302 --worktree "$REPO"
out=$(driver_step_self_check 302 2>&1); rc=$?
want "a 127 refuses"                          "24" "$rc"
want_in "and the note names it"               'lint' "$(driver_state_get 302 park_note)"

echo "--- with the fix rounds already used, a red parks ---"
jq '.gates = {"lint":"exit 1"}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
driver_state_init 303 --worktree "$REPO"
driver_state_bump 303 fix; driver_state_bump 303 fix
out=$(driver_step_self_check 303 2>&1); rc=$?
want "no fix round left: it refuses"          "24" "$rc"

echo "--- every refusal leaves its reason on the record (#199) ---"
# A park whose only reason is in a log on the host that ran it cannot be read anywhere
# else. One case per refusal path that returns 24.
note_after() { driver_state_init "$1" --worktree "$REPO"; driver_state_set "$1" park_note ""
  driver_step_self_check "$1" >/dev/null 2>&1; driver_state_get "$1" park_note; }
jq '.gates = ["npm test"]' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
want_in "gates in the wrong shape"   'object' "$(note_after 311)"
jq 'del(.gates)' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
want_in "no gates at all"            'no gate' "$(note_after 312)"
jq '.gates = {"lint":""}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
want_in "every gate empty"           'lint' "$(note_after 313)"
SAVED_KIT="$KIT_ROOT"; KIT_ROOT="$FIX/no-kit"
jq '.gates = {"lint":"exit 0"}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
want_in "the machine gate missing"   'machine-gate' "$(note_after 314 2>/dev/null)"
KIT_ROOT="$SAVED_KIT"

echo "--- a gate runs as CI runs it: without the kit's HARNESS_* pins ---"
# The launcher exports HARNESS_CFG_PATH so the kit reads the right config. A project
# test that builds its own fixture config reads that variable first, and on #13262
# eight toolkit-env tests failed on a change that was fine.
jq '.gates = {"env":"test -z \"${HARNESS_CFG_PATH:-}\""}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
driver_state_init 320 --worktree "$REPO"
rc=0; ( export HARNESS_CFG_PATH="$FIX/pinned.json"; driver_step_self_check 320 >/dev/null 2>&1 ) || rc=$?
want "the pin does not reach the gate"        "0" "$rc"

echo "--- the gates wait for the machine: cpu idle over the floor, then a gate slot ---"
# Heavy local work waits; it never parks the ticket. Run in the background, held,
# then let go — the gate must not have run while held, and must run after.
jq --arg m "$FIX/gate-ran" '.gates = {"g": ("touch " + $m)}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
echo 4 > "$FIX/idle"; rm -f "$FIX/gate-ran" "$FIX/sc.rc"
( SWARM_IDLE_FILE="$FIX/idle" SWARM_LOAD=1 driver_step_self_check 101 > "$FIX/sc.out" 2>&1; echo $? > "$FIX/sc.rc" ) &
sleep 2
if [ ! -e "$FIX/gate-ran" ]; then ok "under the idle floor the gate did not run"; else bad "the gate ran at 4% idle"; fi
want_in "and it said why" 'machine busy .cpu idle 4%, floor 15%' "$(cat "$FIX/sc.out")"
echo 60 > "$FIX/idle"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$FIX/sc.rc" ] && break; sleep 1; done
if [ -e "$FIX/gate-ran" ]; then ok "once idle rose, it ran"; else bad "never ran: $(cat "$FIX/sc.out")"; fi
want "and the step passed, not parked" "0" "$(cat "$FIX/sc.rc" 2>/dev/null)"

sleep 30 & holder=$!
mkdir -p "$HARNESS_GATE_SLOT_DIR/slot-1"; echo "$holder" > "$HARNESS_GATE_SLOT_DIR/slot-1/pid"
rm -f "$FIX/gate-ran" "$FIX/sc.rc"
( HARNESS_GATE_SLOTS=1 driver_step_self_check 101 > "$FIX/sc.out" 2>&1; echo $? > "$FIX/sc.rc" ) &
sleep 2
if [ ! -e "$FIX/gate-ran" ]; then ok "every gate slot taken: the gate did not run"; else bad "the gate ran with no slot free"; fi
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$FIX/sc.rc" ] && break; sleep 1; done
if [ -e "$FIX/gate-ran" ]; then ok "the holder gone, it ran"; else bad "never ran: $(cat "$FIX/sc.out")"; fi
want "and the slot was given back" "" "$(ls "$HARNESS_GATE_SLOT_DIR" 2>/dev/null)"

echo "--- LESSON: self-check runs the push's own checks, not only its gates (#236) ---"
# On 2026-10-17 self-check said "3 gate(s) green" and the project's pre-push refused
# on a check outside them; the ticket parked after review, the commits in a bundle.
# A tree whose pre-push refuses on a check no configured gate runs must not pass.
PP="$FIX/pp"; git clone -q "$REPO" "$PP"; git -C "$PP" checkout -q -b tkt-401
git -C "$PP" config user.email t@example.invalid; git -C "$PP" config user.name Tester
cat > "$PP/.git/hooks/pre-push" <<'SH'
#!/bin/sh
cat > "$(git rev-parse --git-dir)/pre-push.stdin"
printf '%s\n' "$@" > "$(git rev-parse --git-dir)/pre-push.args"
echo "✗ check:near-name-exports — a new export looks like one that already exists"
exit 1
SH
chmod +x "$PP/.git/hooks/pre-push"
jq '.gates = {"changed": ["true"]}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
driver_state_init 401 --worktree "$PP"
F401="$(driver_state_dir 401)/steps/self-check.findings.json"
out=$(driver_step_self_check 401 2>&1); rc=$?
want "a red pre-push is a red self-check, sent to fix" "30" "$rc"
want_in "named as the pre-push"                 'pre-push failed' "$out"
want "the finding is the pre-push"               "gate-pre-push" "$(jq -r '[.[].id] | join(",")' "$F401" 2>/dev/null)"
want_in "carrying the check that said no"        'near-name-exports' "$(jq -r '.[0].output' "$F401" 2>/dev/null)"
want_in "the hook got the ref line git sends"    "refs/heads/tkt-401 $(git -C "$PP" rev-parse HEAD) refs/heads/tkt-401 " "$(cat "$PP/.git/pre-push.stdin" 2>/dev/null)"
want "and the remote as its first argument"      "origin" "$(head -1 "$PP/.git/pre-push.args" 2>/dev/null)"
out=$(driver_step_self_check 401 2>&1); rc=$?
want "a second red pre-push parks"               "24" "$rc"
want_in "with the check in the park note"        'near-name-exports' "$(driver_state_get 401 park_note)"

echo "--- a green pre-push is a green gate ---"
printf '#!/bin/sh\nexit 0\n' > "$PP/.git/hooks/pre-push"
driver_state_init 402 --worktree "$PP"
out=$(driver_step_self_check 402 2>&1); rc=$?
want "green"                                     "0" "$rc"
want_in "and counted"                            'pre-push ok' "$out"
want_in "beside the configured gate"             '2 gate.s. green' "$out"

echo "--- a husky tree whose hooks were never wired still runs its pre-push ---"
# git resolves no hook in a worktree husky never ran in, which would read as "no
# pre-push to verify" while the push itself (after ensure-hooks) runs one.
git -C "$REPO" worktree add -q "$FIX/hk" -b tkt-408 develop
mkdir -p "$FIX/hk/.husky"; printf '#!/bin/sh\necho "✗ check:knip — unused deps"\nexit 1\n' > "$FIX/hk/.husky/pre-push"
driver_state_init 408 --worktree "$FIX/hk"
out=$(driver_step_self_check 408 2>&1); rc=$?
want "it runs the tree's own pre-push"          "30" "$rc"
want_in "and names what said no"                'check:knip' "$(jq -r '.[0].output' "$(driver_state_dir 408)/steps/self-check.findings.json" 2>/dev/null)"

echo "--- gates.prePush names the command, in place of the hook ---"
jq '.gates = {"changed": ["true"], "prePush": "echo ✗ check:knip; exit 4"}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
driver_state_init 403 --worktree "$PP"
out=$(driver_step_self_check 403 2>&1); rc=$?
want "its red is red although the hook is green" "30" "$rc"
want_in "with its exit code"                     'exit 4' "$out"

echo "--- gates.prePush false is off, and says so ---"
printf '#!/bin/sh\nexit 1\n' > "$PP/.git/hooks/pre-push"
jq '.gates = {"changed": ["true"], "prePush": false}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
driver_state_init 404 --worktree "$PP"
out=$(driver_step_self_check 404 2>&1); rc=$?
want "off: the red hook is not run"              "0" "$rc"
want_in "and the log says it is off"             'pre-push off' "$out"

echo "--- gates.prePush in a shape that is not a command is configuration: it parks ---"
jq '.gates = {"changed": ["true"], "prePush": ["npm run verify:push"]}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
driver_state_init 405 --worktree "$PP"
out=$(driver_step_self_check 405 2>&1); rc=$?
want "a list parks, not fixes"                   "24" "$rc"
want_in "naming the key"                         'gates.prePush' "$(driver_state_get 405 park_note)"

echo "--- a reviewer still owed defers the pre-push to the push, and says so ---"
# The review step records the verdict the push demands after this step runs, so a
# pre-push here is red on it whatever the change.
jq '.gates = {"changed": ["true"]} | .review = {"attest": {"ui-gate": {"owed": "exit 1"}}}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
driver_state_init 406 --worktree "$PP"
out=$(driver_step_self_check 406 2>&1); rc=$?
want "deferred, not red"                         "0" "$rc"
want_in "naming the owed reviewer"               'ui-gate is owed' "$out"
jq '.review.attest["ui-gate"].owed = "exit 0"' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
driver_state_init 407 --worktree "$PP"
out=$(driver_step_self_check 407 2>&1); rc=$?
want "attested: the pre-push runs, and is red"   "30" "$rc"
jq 'del(.review)' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"

exit $FAILED
