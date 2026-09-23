#!/usr/bin/env bash
# Fixture test for harness-update.sh.
#
# WHY THIS EXISTS
#   The duplicate detector's healthy answer is "none", which is also what a
#   broken detector prints. On the machine this was written for it printed
#   "none" ten minutes after a real duplicate had been reconciled — correct, but
#   indistinguishable from a detector that never looked. So every case below
#   plants the condition and asserts the command STOPS, rather than asserting
#   that a clean estate looks clean.
#
#   Each run uses a throwaway config directory. Nothing here reads or writes the
#   real one.
set -uo pipefail

SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness-update.sh"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }

SB="${TMPDIR:-/tmp}/harness-update-fixture-$$"
mkdir -p "$SB"
trap 'rm -rf "$SB"' EXIT
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

# Build a config dir. $1 = name, $2 = enabledPlugins JSON, $3 = installed JSON.
make_cfg() {
  local d="$SB/$1"; mkdir -p "$d/plugins/marketplaces"
  printf '{ "enabledPlugins": %s }\n' "$2" > "$d/settings.json"
  printf '{ "plugins": %s }\n' "$3" > "$d/plugins/installed_plugins.json"
  printf '%s' "$d"
}

INST='{ "superpowers@a": [{"version":"6.3.0","lastUpdated":"2026-09-07"}],
        "superpowers@b": [{"version":"6.4.1","lastUpdated":"2026-09-22"}],
        "other@c":       [{"version":"1.0.0","lastUpdated":"2026-09-01"}] }'

run() { # <config dir> [args...] -> stdout; rc in RC
  local d=$1; shift
  RC=0
  CLAUDE_CONFIG_DIR="$d" bash "$SUT" "$@" 2>&1 || RC=$?
}

echo "harness-update fixture"

# --- 1. THE PLANT: two enabled copies of one plugin ---------------------------
d=$(make_cfg dup '{ "superpowers@a": true, "superpowers@b": true, "other@c": true }' "$INST")
out=$(run "$d" --check; :); run "$d" --check >/dev/null 2>&1
[ "$RC" -ne 0 ] && ok "a duplicate stops the run" || bad "a duplicate stops the run (rc $RC)"
out=$(CLAUDE_CONFIG_DIR="$d" bash "$SUT" --check 2>&1)
printf '%s' "$out" | grep -q 'ENABLED TWICE  superpowers@a' \
  && ok "it names the first copy" || bad "it names the first copy"
printf '%s' "$out" | grep -q 'ENABLED TWICE  superpowers@b' \
  && ok "it names the second copy" || bad "it names the second copy"
printf '%s' "$out" | grep -q '6.3.0' && printf '%s' "$out" | grep -q '6.4.1' \
  && ok "it gives both versions, so the operator can choose" \
  || bad "it gives both versions"
printf '%s' "$out" | grep -q 'Nothing was changed' \
  && ok "it says nothing was changed" || bad "it says nothing was changed"

# --- 2. The reconciled estate is NOT a duplicate ------------------------------
# One copy disabled is the fix. If this still reported a duplicate, the command
# would refuse to run for ever after a correct reconciliation.
d=$(make_cfg fixed '{ "superpowers@a": false, "superpowers@b": true, "other@c": true }' "$INST")
out=$(CLAUDE_CONFIG_DIR="$d" bash "$SUT" --check 2>&1)
printf '%s' "$out" | grep -qE 'DUPLICATES' && printf '%s' "$out" | grep -A1 'DUPLICATES' | grep -q 'none' \
  && ok "a disabled second copy is not a duplicate" \
  || bad "a disabled second copy is not a duplicate"
printf '%s' "$out" | grep -q 'Nothing was changed' \
  && bad "the reconciled estate does not stop the run" \
  || ok "the reconciled estate does not stop the run"

# --- 3. It stops BEFORE acting ------------------------------------------------
# A duplicate must stop the run in apply mode too, not only under --check.
d=$(make_cfg dup2 '{ "superpowers@a": true, "superpowers@b": true }' "$INST")
out=$(CLAUDE_CONFIG_DIR="$d" bash "$SUT" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "apply mode stops on a duplicate too" || bad "apply mode stops on a duplicate too (rc $rc)"
printf '%s' "$out" | grep -q 'Applying' \
  && bad "it does not reach the applying step" \
  || ok "it does not reach the applying step"

# --- 4. A clean, level estate exits 0 -----------------------------------------
# Without this the command could satisfy every case above by always failing.
d=$(make_cfg clean '{ "other@c": true }' '{ "other@c": [{"version":"1.0.0","lastUpdated":"2026-09-01"}] }')
out=$(CLAUDE_CONFIG_DIR="$d" bash "$SUT" --check 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "a level estate exits 0" || bad "a level estate exits 0 (rc $rc, out: $(printf '%s' "$out" | tail -2 | tr '\n' ' '))"

# --- 5. It reports before it decides ------------------------------------------
# The operator reads what is about to change; a command that acts first is the
# thing this replaces.
d=$(make_cfg order '{ "superpowers@a": true, "superpowers@b": true }' "$INST")
out=$(CLAUDE_CONFIG_DIR="$d" bash "$SUT" 2>&1)
first=$(printf '%s' "$out" | grep -nE 'MARKETPLACES|STOP' | head -1 | cut -d: -f2)
[ "$first" = "MARKETPLACES" ] && ok "the report comes before the verdict" \
                              || bad "the report comes before the verdict (saw '$first')"

echo
[ "$fail" -eq 0 ] && echo "harness-update fixture: all checks hold" \
                  || echo "harness-update fixture: FAILURES"
exit "$fail"
