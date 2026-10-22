#!/usr/bin/env bash
# check-argv-json.test.sh — a GitHub list handed to jq on argv is flagged; one bound
# through a file, stdin, or marked bounded is not; the kit carries none.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
C="$HERE/check-argv-json.sh"
T=$(mktemp -d); on_exit_keep_status 'rm -rf "$T"'
FAILED=0
ok()  { echo "OK       $1"; }
bad() { echo "MISMATCH $1"; FAILED=1; }

# The shapes that shipped: keep-fresh's prune, the lane's order, the tick's snapshot, the queue's rows.
cat > "$T/bad.sh" <<'X'
st --argjson prs "$PRS" '.tried |= with_entries(.)'
ORDER=$(coord_jq -c --argjson c "$CANDS" --argjson prs "${PRS:-[]}" '.')
ISSUES=$(jq -cn --argjson old "$snap" --argjson new "$ISSUES" '$old + $new')
jq --arg rows "$rows" '.'
jq --argjson c "$open_checks" '.'
jq --arg c "$CLAIM_ROWS" '.'
X
cat > "$T/good.sh" <<'X'
ST=$(jq_slurp prs "$PRS" -- jq -c '$prs[0] as $prs | .' <<<"$ST")
jq -r --arg repo "$REPO_SLUG" '.[]' <<<"$PRS"
jq --arg l "$COORD_SHEET_LABEL" --arg t "$COORD_SHEET_TITLE" --arg n "$OPEN_PRS" '.'
jq -cn --argjson n "$HEAD_PR" '.'
# jq --argjson prs "$PRS"   (a comment)
jq --argjson nb "$NB_CHECKS" '.'   # argv-bounded: config names
# argv-bounded: the check names config lists
jq --argjson nb "$NB_CHECKS" '.'
X
out=$(bash "$C" "$T/bad.sh"); rc=$?
[ "$rc" = 1 ] && ok "a GitHub list on argv fails the check" || bad "the bad file passed (rc=$rc)"
[ "$(printf '%s\n' "$out" | grep -c .)" = 6 ] && ok "all six are named" || bad "named: $out"
out=$(bash "$C" "$T/good.sh"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "jq_slurp, stdin, scalars, comments and marked bounded values pass" || bad "flagged correct code: $out"

# A marker covers only the line right below it.
printf '# argv-bounded: x\n\njq --argjson prs "$PRS" .\n' > "$T/far.sh"
bash "$C" "$T/far.sh" >/dev/null; [ "$?" = 1 ] && ok "a marker two lines up excuses nothing" || bad "a distant marker excused a list"

# The kit itself.
out=$(bash "$C"); rc=$?
[ "$rc" = 0 ] && ok "the kit hands no GitHub list to jq on argv" || bad "the kit: $out"

suite_end "$FAILED"
