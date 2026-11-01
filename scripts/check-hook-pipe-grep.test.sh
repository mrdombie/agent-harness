#!/usr/bin/env bash
# check-hook-pipe-grep.test.sh — a hook under pipefail that pipes text into an
# early-exit grep is flagged, printf and echo included; a here-string is not; the
# kit's hooks carry none.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
C="$HERE/check-hook-pipe-grep.sh"
T=$(mktemp -d); on_exit_keep_status 'rm -rf "$T"'
FAILED=0
ok()  { echo "OK       $1"; }
bad() { echo "MISMATCH $1"; FAILED=1; }

mkdir -p "$T/lib"
cat > "$T/bad.sh" <<'X'
set -uo pipefail
printf '%s' "$cmd" | grep -qE "record-verdict"
if echo "$cmd" | grep -m1 -E x >/dev/null; then :; fi
printf '%s' "$cmd" \
  | grep --quiet x
printf '%s\n' "$REST" | grep -oE '[^.!?]*\?([[:space:]"'"'"')*_]|$)' | grep -qE 'you'
jq -r .x <<<"$in" | grep -iqF -- y && :
X
cat > "$T/lib/bad.sh" <<'X'
f() { printf '%s' "$1" | grep -qE '^orgs/'; }
X
cat > "$T/good.sh" <<'X'
set -euo pipefail
grep -qE "record-verdict" <<<"$cmd"
n=$(printf '%s\n' "$cmd" | grep -cE x)
printf '%s\n' "$cmd" | grep -oE x | wc -l
[ -n "$a" ] || grep -q x <<<"$a"
echo "pipe text: printf x | grep -q y"
# printf '%s' "$cmd" | grep -q y   (a comment)
X
cat > "$T/nopipefail.sh" <<'X'
printf '%s' "$cmd" | grep -qE x || exit 0
X
out=$(bash "$C" "$T/bad.sh" "$T/lib/bad.sh"); rc=$?
[ "$rc" = 1 ] && ok "a pipe into an early-exit grep under pipefail fails the check" || bad "the bad files passed (rc=$rc)"
n=$(printf '%s\n' "$out" | grep -c '^/')
[ "$n" = 6 ] && ok "all six are named: printf, echo -m, a continued line, mixed quoting, -iq, a lib" || bad "named $n: $out"
out=$(bash "$C" "$T/good.sh" "$T/nopipefail.sh"); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | grep -c '^/')" = 0 ] && ok "here-strings, -c, -o, quoted text, comments and a file without pipefail pass" \
  || bad "flagged correct code (rc=$rc): $out"

# The kit's own hooks.
out=$(bash "$C"); rc=$?
[ "$rc" = 0 ] && ok "no hook in the kit pipes into an early-exit grep under pipefail" || bad "the kit: $out"
suite_end "$FAILED"
