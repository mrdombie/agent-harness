#!/usr/bin/env bash
# check-suite-ending.test.sh — the guard goes red on a bare EXIT trap or a suite with no
# suite_end, and stays green on the real repo.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/check-suite-ending.sh"
SB=$(mktemp -d "${TMPDIR:-/tmp}/suite-ending-XXXXXX")
on_exit_keep_status 'rm -rf "$SB"'
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }
HEAD='#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1'

# want <label> <rc wanted> <output regex> <suite body>
want() {
  # Plants spell it TRAP so this file is not itself a bare trap; written out, it is one.
  printf '%s\n%s\n' "$HEAD" "$4" | sed 's/TRAP /trap /' > "$SB/x.test.sh"
  out=$(bash "$SUT" "$SB/x.test.sh" 2>&1); rc=$?
  if [ "$rc" = "$2" ] && grep -qE -- "$3" <<<"$out"; then ok "$1"; else bad "$1 — rc=$rc: $out"; fi
}

echo "--- the real repo is clean ---"
out=$(bash "$SUT" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "every suite CI runs passes: ${out##*: }" || bad "the repo is not clean: $out"

echo "--- plants ---"
want "a bare rm cleanup is red"         1 "bare EXIT trap" 'F=$(mktemp -d); TRAP '"'"'rm -rf "$F"'"'"' EXIT
suite_end 0'
want "a named cleanup function is red"  1 "bare EXIT trap" 'cleanup() { :; }; TRAP cleanup EXIT
suite_end 0'
want "one after other code on the line is red" 1 "bare EXIT trap" 'fixture; TRAP "rm -rf x" EXIT
suite_end 0'
want "no suite_end is red"              1 "never calls suite_end" 'on_exit_keep_status true
exit 0'
want "a suite_end only in a comment is red" 1 "never calls suite_end" '# suite_end 0
exit 0'
printf '#!/usr/bin/env bash\nsuite_end 0\n' > "$SB/x.test.sh"
out=$(bash "$SUT" "$SB/x.test.sh" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "does not source tests/lib/suite.sh" <<<"$out" && ok "not sourcing the helper is red" || bad "no source line passed: rc=$rc $out"
want "the helper and suite_end are green" 0 "1 suites" 'on_exit_keep_status '"'"'rm -rf "$F"'"'"'
suite_end "$fail"'
want "a commented-out one is not counted" 0 "1 suites" '# TRAP '"'"'rm -rf x'"'"' EXIT
suite_end 0'
want "an INT-only handler is not an exit handler" 0 "1 suites" "TRAP 'kill 0' INT
suite_end 0"

suite_end "$fail"
