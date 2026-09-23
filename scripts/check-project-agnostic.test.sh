#!/usr/bin/env bash
# Fixture test for check-project-agnostic.sh.
#
# WHY THIS EXISTS
#   The guard shipped for weeks reporting 0 while the kit carried six
#   project-specific script names. It was not broken — it answered "does this
#   text contain the origin project's NAME", which is a narrower question than
#   "is this text specific to that project", and nothing said so out loud.
#
#   A guard proved only by planting a bad value still passes when the line that
#   catches it is deleted. So this asserts the SECOND probe is present and does
#   something, not merely that the script exits 0 today.
#
# Every case runs against a THROWAWAY CLONE. Nothing here can touch the working
# tree it was launched from.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SB="${TMPDIR:-/tmp}/project-agnostic-fixture-$$"
FAILURES=0

cleanup() { rm -rf "$SB"; }
trap cleanup EXIT

ok()   { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; FAILURES=$((FAILURES + 1)); }

REPO="$SB/kit"
mkdir -p "$SB"
# A CLONE would carry only what is committed, so an uncommitted fix to the guard
# would be tested as its old self and every case would report on the wrong file.
# Copy the working tree, then commit it inside the copy so `git checkout --` can
# undo each plant against the state actually under test.
cp -R "$ROOT" "$REPO" || { echo "could not copy $ROOT"; exit 2; }
rm -rf "$REPO/.git"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@fixture.local -c user.name=fixture add -A
git -C "$REPO" -c user.email=t@fixture.local -c user.name=fixture commit -qm fixture

LAST_RC=0
run() { # -> stdout of the guard, rc in LAST_RC
  LAST_RC=0
  bash "$REPO/scripts/check-project-agnostic.sh" 2>&1 || LAST_RC=$?
}

# A skill file that exists in the kit and is safe to append to.
VICTIM="$REPO/skills/queue/SKILL.md"
[ -f "$VICTIM" ] || { echo "fixture expects skills/queue/SKILL.md"; exit 2; }

echo "check-project-agnostic fixture  (clone of $ROOT)"

# --- 1. the clean tree passes -------------------------------------------------
run
[ "$LAST_RC" -eq 0 ] && ok "a clean kit passes" || fail "a clean kit passes (rc $LAST_RC)"

# --- 2. the control is real ---------------------------------------------------
# A zero from a strictness probe means clean, suppressed, or never ran. The guard
# must print a non-zero control proving it could see files at all.
out=$(bash "$REPO/scripts/check-project-agnostic.sh" 2>&1)
printf '%s' "$out" | grep -Eq 'control, probe can see files : [1-9]' \
  && ok "the run prints a non-zero control" \
  || fail "the run prints a non-zero control"

# --- 3. probe 2 exists and reports ---------------------------------------------
# Deleting the probe is the failure this case is here to catch: without this
# assertion the guard silently reverts to its old, narrower question.
printf '%s' "$out" | grep -q 'project-specific npm scripts' \
  && ok "the second probe reports a count of its own" \
  || fail "the second probe reports a count of its own — has it been removed?"

# --- 4. a NEW project-specific script is caught -------------------------------
# Built from a variable: a literal `npm run <name>` in THIS file would be a leak
# the guard correctly flags, and the test would fail on its own fixtures.
printf '\nRun `npm run %s` first.\n' "check:invented-thing" >> "$VICTIM"
out=$(bash "$REPO/scripts/check-project-agnostic.sh" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "a new project-specific script fails the guard" \
                || fail "a new project-specific script fails the guard (rc $rc)"
printf '%s' "$out" | grep -q 'check:invented-thing' \
  && ok "the guard names the identifier it caught" \
  || fail "the guard names the identifier it caught"
git -C "$REPO" checkout -q -- skills/queue/SKILL.md

# --- 5. a GENERIC script is not flagged ---------------------------------------
# The probe must not fire on the scripts every project is assumed to have,
# or it becomes noise and gets switched off.
printf '\nRun `npm run %s` and `npm run %s`.\n' "typecheck" "lint" >> "$VICTIM"
bash "$REPO/scripts/check-project-agnostic.sh" >/dev/null 2>&1
[ $? -eq 0 ] && ok "generic scripts are not flagged" || fail "generic scripts are not flagged"
git -C "$REPO" checkout -q -- skills/queue/SKILL.md

# --- 6. a colon in the identifier survives the split --------------------------
# `changelog:build` ends in `build`; a naive filter strips it as generic and the
# leak goes unrecorded. This case exists because that bug was written once.
printf '\nRun `npm run %s` to finish.\n' "release:build" >> "$VICTIM"
out=$(bash "$REPO/scripts/check-project-agnostic.sh" 2>&1)
printf '%s' "$out" | grep -q 'release:build' \
  && ok "a namespaced script ending in a generic word is still caught" \
  || fail "a namespaced script ending in a generic word is still caught"
git -C "$REPO" checkout -q -- skills/queue/SKILL.md

# --- 7. the baseline may only shrink ------------------------------------------
# If the probe ever stops seeing what it used to see — a broken pattern, a moved
# file — the run must go RED, not quietly green.
printf '%s\n' "nonexistent/file.md -> check:never-existed" >> "$REPO/scripts/project-agnostic-baseline.txt"
out=$(bash "$REPO/scripts/check-project-agnostic.sh" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "a stale baseline entry fails the guard" \
                || fail "a stale baseline entry fails the guard (rc $rc)"
printf '%s' "$out" | grep -q 'BASELINE is stale' \
  && ok "the guard says the baseline is stale" \
  || fail "the guard says the baseline is stale"
git -C "$REPO" checkout -q -- scripts/project-agnostic-baseline.txt

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "project-agnostic fixture: all checks hold"
else
  echo "project-agnostic fixture: $FAILURES check(s) failed"
fi
exit $([ "$FAILURES" -eq 0 ] && echo 0 || echo 1)
