#!/usr/bin/env bash
# suite.test.sh — a suite that stops partway never passes CI, however its cleanup exits.
# Fixture suites crash mid-way, mask their status, skip, and finish; each is run
# bare (what bash reports) and through .github/ci/run-suite.sh (what CI reports).
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$KIT/.github/ci/run-suite.sh"
LIB="$KIT/tests/lib/suite.sh"
SB=$(mktemp -d "${TMPDIR:-/tmp}/suite-test-XXXXXX")
on_exit_keep_status 'rm -rf "$SB"'
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

# mk <name> <body…> — a fixture suite that sources the real helper
mk() { local n=$1; shift; { echo '#!/usr/bin/env bash'; echo "set -uo pipefail"; echo ". \"$LIB\""; printf '%s\n' "$@"; } > "$SB/$n.test.sh"; }
bare() { bash "$SB/$1.test.sh" >/dev/null 2>&1; echo $?; }
ci()   { bash "$RUN" "$SB/$1.test.sh" > "$SB/$1.ci.out" 2>&1; echo $?; }

echo "--- the defect: a cleanup that calls exit turns a mid-suite crash into 0 ---"
# Spelt TRAP so this file is not itself a bare trap; written out, it is one.
sed 's/TRAP /trap /' > "$SB/masked.test.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
F=$(mktemp -d); cleanup() { rm -rf "$F"; exit $?; }; TRAP cleanup EXIT
echo "$UNSET_ON_PURPOSE"
echo "SUITE-END masked.test.sh: PASS"
SH
r=$(bare masked); [ "$r" = 0 ] && ok "bash alone reports the crashed suite as exit 0 (the hole)" || bad "the masking fixture exited $r, so it proves nothing"
r=$(ci masked); [ "$r" != 0 ] && ok "run-suite fails it: it never printed its summary line" || bad "run-suite passed a suite that crashed before its end"
grep -q "stopped before its summary line" "$SB/masked.ci.out" && ok "and says it stopped early" || bad "run-suite gave no reason: $(cat "$SB/masked.ci.out")"

echo "--- on_exit_keep_status keeps the status and still cleans up ---"
mk crash 'D=$(mktemp -d); echo "$D" > "'"$SB"'/crash.dir"; on_exit_keep_status '"'"'rm -rf "$D"; true'"'"'' 'echo "$UNSET_ON_PURPOSE"' 'suite_end 0'
r=$(bare crash); [ "$r" != 0 ] && ok "a set -u crash exits $r through a cleanup ending in true" || bad "a crash exited 0 through the helper"
[ ! -d "$(cat "$SB/crash.dir")" ] && ok "and the cleanup ran" || bad "the cleanup did not run"
r=$(ci crash); [ "$r" != 0 ] && ok "run-suite fails the crashed suite" || bad "run-suite passed the crashed suite"
mk exit3 'on_exit_keep_status true' 'exit 3'
r=$(bare exit3); [ "$r" = 3 ] && ok "an exit 3 stays 3" || bad "exit 3 became $r"
mk exit3b 'on_exit_keep_status "rm -rf /nonexistent-$$"' 'false || exit 3'
r=$(bare exit3b); [ "$r" = 3 ] && ok "a cleanup whose last command succeeds does not reset it" || bad "exit 3 became $r"

echo "--- suite_end is the only green ending ---"
mk pass 'on_exit_keep_status true' 'suite_end 0'
r=$(ci pass); [ "$r" = 0 ] && ok "a finished suite with 0 failures passes" || bad "a finished passing suite failed: $(cat "$SB/pass.ci.out")"
grep -q "^SUITE-END pass.test.sh: PASS$" "$SB/pass.ci.out" && ok "and prints its summary line" || bad "no summary line in: $(cat "$SB/pass.ci.out")"
mk wrap 'suite_end 256'
r=$(bare wrap); [ "$r" = 1 ] && ok "256 failures exit 1 (exit 256 would wrap to 0)" || bad "256 failures exited $r"
mk failing 'suite_end 2'
r=$(ci failing); [ "$r" != 0 ] && ok "a finished suite with failures fails" || bad "a failing suite passed"
mk notnum 'suite_end ""'
r=$(bare notnum); [ "$r" = 1 ] && ok "an empty failure count fails, never reads as 0" || bad "an empty count exited $r"
mk early 'echo "half way"' 'exit 0' 'suite_end 0'
r=$(ci early); [ "$r" != 0 ] && ok "an early exit 0 fails CI: it skipped the rest" || bad "an early exit 0 passed CI"
mk skip 'command -v no-such-tool-xyz >/dev/null || suite_skip "no-such-tool-xyz is not on PATH"' 'suite_end 1'
r=$(ci skip); [ "$r" = 0 ] && ok "a deliberate suite_skip passes and says so" || bad "suite_skip failed CI: $(cat "$SB/skip.ci.out")"
grep -q "SKIP (no-such-tool-xyz is not on PATH)" "$SB/skip.ci.out" && ok "with its reason" || bad "no skip reason in output"
mk liar 'on_exit_keep_status "exit 0"' 'echo "SUITE-END liar.test.sh: FAIL (1)"' 'exit 0'
r=$(ci liar); [ "$r" != 0 ] && ok "a FAIL summary fails even when the status says 0" || bad "a FAIL summary passed on exit 0"
mk other 'echo "SUITE-END someone-else.test.sh: PASS"' 'exit 0'
r=$(ci other); [ "$r" != 0 ] && ok "another suite's summary line does not count as this one's" || bad "a nested suite's PASS was taken as this suite's"

suite_end "$fail"
