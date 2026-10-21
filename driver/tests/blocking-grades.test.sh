#!/usr/bin/env bash
# blocking-grades.test.sh — what blocks a merge is decided in ONE place, and a Minor
# is in it. A review that filed its Minors as follow-ups made every passing merge
# open new tickets (110 of 339 bugs in one week), and the grades that block were
# written out by hand in four steps, so changing the rule meant finding all four.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }

# The two definitions only, read out of driver-env.sh, which needs a whole project to
# load. A missing definition leaves the selector unset and fails the first check.
eval "$(grep -E '^DRIVER_BLOCKING_GRADES(_LATER)?=' "$ROOT/driver-env.sh")"
eval "$(sed -n '/^driver_blocking_grades()/,/^}/p' "$ROOT/driver-env.sh")"
eval "$(sed -n '/^driver_blocking_select()/,/^}/p' "$ROOT/driver-env.sh")"
type driver_blocking_select >/dev/null 2>&1 || driver_blocking_select() { printf 'select(false)'; }

echo "--- the selector blocks Critical, Major and Minor, and never a Nit ---"
f='{"findings":[{"grade":"critical"},{"grade":"major"},{"grade":"minor"},{"grade":"nit"},{}]}'
got=$(printf '%s' "$f" | jq -r "[.findings[] | $(driver_blocking_select) | .grade] | join(\" \")")
[ "$got" = "critical major minor" ] && ok "blocks exactly critical, major, minor" || bad "blocks '$got'"
got=$(printf '%s' "$f" | jq -r "[.findings[] | $(driver_blocking_select 1) | .grade] | join(\" \")")
[ "$got" = "critical major minor" ] && ok "round 1 blocks critical, major, minor" || bad "round 1 blocks '$got'"

echo "--- from round 2 only Critical and Major block (the owner, 2026-10-20) ---"
for r in 2 3; do
  got=$(printf '%s' "$f" | jq -r "[.findings[] | $(driver_blocking_select $r) | .grade] | join(\" \")")
  [ "$got" = "critical major" ] && ok "round $r blocks critical, major" || bad "round $r blocks '$got'"
done
# Unset, the later set is the first round's: an absent line fails strict, never open.
got=$(DRIVER_BLOCKING_GRADES_LATER=''; printf '%s' "$f" | jq -r "[.findings[] | $(driver_blocking_select 2) | .grade] | join(\" \")")
[ "$got" = "critical major minor" ] && ok "an unset later set blocks as round 1 does" || bad "an unset later set blocks '$got'"

echo "--- no step writes its own copy of the grades that block ---"
# A literal `.grade == "<grade>"` in a step is a second definition of what blocks.
hits=$(grep -rn -E '\.grade *== *\\?"(critical|major|minor)' "$ROOT/steps" "$ROOT/build-ticket" 2>/dev/null)
[ -z "$hits" ] && ok "every step reads driver_blocking_select" || bad "a step defines its own blocking grades: $hits"

echo "--- no review step files a follow-up ticket ---"
hits=$(grep -n 'issue create' "$ROOT/steps/review.sh" 2>/dev/null)
[ -z "$hits" ] && ok "review.sh opens no issues" || bad "review.sh still files tickets: $hits"

echo "pass=$pass fail=$fail"
suite_end "$fail"
