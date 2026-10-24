#!/usr/bin/env bash
# selfcheck-db-flake.test.sh — a database or transaction timeout in a test file the change
# did not touch is the database's load, not a red. On 2026-10-24 a calendar change was
# refused at self-check twice, and the retry gave up, on two agent test files it never
# touched ("Transaction API error: timed out"). Now each such file is run once more, alone:
# green, the red is not counted and nothing parks; still red, it is read as before
# (base-red, else the branch's). A timeout in a file the branch changed, or a plain red
# outside it, still blocks.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fix_real_briefs
. "$HERE/../state.sh" || exit 1
ROOT="$(cd "$HERE/../.." && pwd)"
mkdir -p "$STATE/swarm"
CFG0="$HARNESS_CFG_PATH"

# t/agent.test.sh fails while $FIX/busy holds a count above 0 (each run takes one off): on a
# database timeout, or with $FIX/plain on an assertion. Alone, after that, it passes.
mkdir -p "$REPO/t"
cat > "$REPO/t/agent.test.sh" <<SH
n=\$(cat "$FIX/busy" 2>/dev/null || echo 0)
if [ "\$n" -gt 0 ]; then echo \$((n - 1)) > "$FIX/busy"
  [ -f "$FIX/plain" ] && { echo "expected 2, got 3"; exit 1; }
  echo '{"orgId":"org1","error":"Transaction API error: timed out","level":"error"}'; exit 1; fi
exit 0
SH
printf 'exit 0\n' > "$REPO/t/other.test.sh"
printf 'rc=0\nfor f in t/*.test.sh; do bash "$f" || { echo "FAIL $f"; rc=1; }; done\nexit $rc\n' > "$REPO/run-tests.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "chore: the tests"
git init -q --bare "$FIX/origin"; git -C "$REPO" remote add origin "$FIX/origin"; git -C "$REPO" push -q origin develop
jq '.gates = {local: ["sh run-tests.sh"]}' "$CFG0" > "$FIX/cfg.json"

branch() { # <ticket> [file to touch] — a branch off the trunk with one commit
  git -C "$REPO" worktree add -q "$FIX/t$1" -b "tkt-$1/work" develop
  printf 'a\n' > "$FIX/t$1/a$1.txt"; [ -z "${2:-}" ] || printf '\n# touched\n' >> "$FIX/t$1/$2"
  git -C "$FIX/t$1" add -A; git -C "$FIX/t$1" -c user.email=t@e.invalid -c user.name=T commit -qm "feat: a"
  driver_state_init "$1" --worktree "$FIX/t$1" --branch "tkt-$1/work"
  fix_issue "$1" OPEN "status:claimed"
}
step() { # <ticket> — self-check from ${SUT_KIT:-the kit}; R_RC its exit, R_OUT its output
  R_RC=0
  R_OUT=$(HARNESS_CFG="$FIX/cfg.json" HARNESS_CFG_PATH="$FIX/cfg.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT
    . "$1/driver/driver-env.sh" && . "$1/driver/ai-step.sh" && . "$1/driver/steps/self-check.sh" && driver_step_self_check "$2"' \
    _ "${SUT_KIT:-$ROOT}" "$1" 2>&1) || R_RC=$?
}
reset() { rm -f "$FIX/busy" "$FIX/plain" "$STATE/swarm/base-checks.tsv"; : > "$STATE/swarm/develop-red.tsv"; }
findings() { [ -e "$(driver_state_dir "$1")/steps/self-check.findings.json" ] && echo present || echo absent; }

N=800
case_flake() { N=$((N + 1)); reset; echo 1 > "$FIX/busy"; branch "$N"; step "$N"; R="rc=$R_RC findings=$(findings "$N")"; }
case_touched() { N=$((N + 1)); reset; echo 9 > "$FIX/busy"; branch "$N" t/agent.test.sh; step "$N"; R="rc=$R_RC"; }
case_plain() { N=$((N + 1)); reset; echo 1 > "$FIX/busy"; : > "$FIX/plain"; branch "$N"; step "$N"; R="rc=$R_RC"; }

echo "--- a database timeout outside the change, green alone: not counted, never parked ---"
case_flake
want "self-check is green"                    "rc=0 findings=absent" "$R"
want_in "and says why"                        'a database timeout in t/agent.test.sh, outside this change; each passed run again alone' "$R_OUT"
want "the files are on the record"            "t/agent.test.sh" "$(driver_state_get "$N" db_flake)"
want "never parked"                           "" "$(driver_state_get "$N" park_note)"

echo "--- a database timeout in a file the change touched still blocks ---"
case_touched
want "it goes to fix"                         "rc=$DRIVER_E_REWORK" "$R"
want_not_in "and is not called the load's"    'database timeout in' "$R_OUT"

echo "--- a plain red outside the change, not a timeout, still blocks ---"
case_plain
want "it goes to fix"                         "rc=$DRIVER_E_REWORK" "$R"

KIT="$FIX/kit"
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$ROOT/briefs" "$KIT/"; }
plant() { # <label> <file under the kit> <exact text to delete>
  kit_copy
  python3 - "$KIT/$2" "$3" <<'PY' || { bad "plant ($1) did not land"; return 1; }
import sys
p, old = sys.argv[1], sys.argv[2]
s = open(p).read()
if s.count(old) != 1: sys.exit(1)
open(p, "w").write(s.replace(old, ""))
PY
  return 0
}
kit_copy
SUT_KIT="$KIT" case_flake; want "the unplanted kit: the load's red is not counted" "rc=0 findings=absent" "$R"
plant "the timeout is run again alone" driver/steps/self-check.sh '    elif [ "$rc" -ne 126 ] && [ "$rc" -ne 127 ] \
         && _driver_gate_db_flake "$wt" "$(driver_state_dir "$t")/steps/gate-$safe.out" "$gsecs"; then
' && { SUT_KIT="$KIT" case_flake; want "planted (no run alone): the load's red goes to fix" "rc=$DRIVER_E_REWORK findings=present" "$R"; }
plant "only a database timeout" driver/steps/self-check.sh '  perl -pe '"'"'s/\e\[[0-9;]*[A-Za-z]//g'"'"' "$out" 2>/dev/null | grep -Eq -- "$DRIVER_DB_TIMEOUT_RE" || return 1
' && { SUT_KIT="$KIT" case_plain; want "planted (any red outside): a plain red passes" "rc=0" "$R"; }

suite_end "$FAILED"
