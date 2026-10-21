#!/usr/bin/env bash
# check-pipe-grep-q.test.sh — a `producer | grep -q` under pipefail is flagged; a
# printf/echo or a here-string is not; the kit carries none outside the files
# another change owns.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
C="$HERE/check-pipe-grep-q.sh"
T=$(mktemp -d); on_exit_keep_status 'rm -rf "$T"'
FAILED=0
ok()  { echo "OK       $1"; }
bad() { echo "MISMATCH $1"; FAILED=1; }

cat > "$T/bad.sh" <<'X'
set -uo pipefail
gh label list | grep -qxF -- "$1"
if git log --oneline | grep -q fix; then :; fi
gh issue list \
  | grep -qF x
X
cat > "$T/good.sh" <<'X'
set -uo pipefail
printf '%s\n' "$x" | grep -qxF -- "$1"
names=$(gh label list); grep -qxF -- "$1" <<<"$names"
[ -n "$a" ] && echo "$a" | grep -qi yes
gh label list | grep -xF -- "$1" >/dev/null
# gh x | grep -q y   (a comment)
X
out=$(bash "$C" "$T/bad.sh"); rc=$?
[ "$rc" = 1 ] && ok "a producer piped into grep -q fails the check" || bad "the bad file passed (rc=$rc)"
[ "$(printf '%s\n' "$out" | grep -c .)" = 3 ] && ok "all three are named, the continued line too" || bad "named: $out"
out=$(bash "$C" "$T/good.sh"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "printf, echo, a here-string and grep >/dev/null pass" || bad "flagged correct code: $out"

# The kit itself. These three are left to the changes that own those files.
KNOWN='scripts/claim-lock.sh scripts/critic-judge.sh scripts/reconcile-claims.sh'
got=$(bash "$C" | sed "s#^$(cd "$HERE/.." && pwd)/##" | cut -d: -f1 | sort -u | tr '\n' ' ' | sed 's/ $//')
[ "$got" = "$KNOWN" ] && ok "the kit has none outside the known three" || bad "the kit: wanted '$KNOWN', got '$got'"
suite_end "$FAILED"
