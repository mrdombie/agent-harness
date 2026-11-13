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
[ "$rc" = 0 ] && ok "the kit hands no GitHub list to jq on argv, and no state-folder glob to a command" || bad "the kit: $out"

# A glob over a state directory as arguments: the listing that went blind on 2026-11-11, and its kin.
cat > "$T/globs-bad.sh" <<'X'
ls $STATE_DIR/logs/*.log
newest=$(ls -t "$SWARM_LOGS"/claim-*.log 2>/dev/null | head -1)
files=$(ls -t "$SWARM_LOGS"/claim-*.log "${DRIVER_DIR:-$STATE_DIR/driver}"/*/steps/*.log 2>/dev/null | head -8)
cat "$RUNS_DIR"/*.json | jq -s .
grep -l wall "$d"/steps/*.log
jq -s . "$COORD_DIR/judges"/*.json
if [ -n "$x" ]; then rec=$(ls -t "$RUNS_DIR"/claim-"$1"-*.json | head -1); fi
wc -l \
  "$STATE"/runs/*.ended
X
cat > "$T/globs-good.sh" <<'X'
for rec in "$RUNS_DIR"/claim-*.json; do [ -f "$rec" ] && jq . "$rec"; done
newest=$(swarm_newest_logs 1 "$SWARM_LOGS"/claim-*.log "${DRIVER_DIR:-$STATE_DIR/driver}"/*/steps/*.log)
printf '%s\0' "$SWARM_LOGS"/*.log | xargs -0 cat
find "$RUNS_DIR" -maxdepth 1 -name 'claim-*.ended' -mmin -60
ls "$STATE_DIR/logs/*.log"
case "$f" in "$STATE_DIR"/*) echo in ;; esac
  "$SWARM_LOGS"/*) echo arm ;;
pat="$SWARM_LOGS"/claim-*.log
local pat="$SWARM_LOGS"/claim-*.log
[[ "$f" == "$RUNS_DIR"/* ]] && echo yes
rel="${f#"$STATE_DIR"/*}"
# ls "$SWARM_LOGS"/*.log   (a comment)
ls "$SWARM_LOGS"/claim-"$t"-*.log   # argv-bounded: one ticket's runs
rm -f "$tmp"/*.out
ls "$W/pictures"/*
X
out=$(bash "$C" "$T/globs-bad.sh"); rc=$?
[ "$rc" = 1 ] && ok "a state-folder glob handed to a command fails the check" || bad "the bad globs passed (rc=$rc)"
[ "$(printf '%s\n' "$out" | grep -c .)" = 8 ] && ok "all eight are named, a continued line by its first" || bad "named: $out"
printf '%s\n' "$out" | grep -q 'globs-bad.sh:1: .*ls \$STATE_DIR/logs/\*\.log' && ok "the planted ls \$STATE_DIR/logs/*.log is refused" || bad "the planted ls was not named: $out"
out=$(bash "$C" "$T/globs-good.sh"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "a for loop, the kit's listing, builtins, find, quoted and case patterns, assignments and marked lists pass" || bad "flagged correct code: $out"
out=$(bash "$C" --globs "$T/bad.sh"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "--globs checks the glob rule alone" || bad "--globs flagged a jq list: $out"
bash "$C" --globs "$T/globs-bad.sh" >/dev/null; [ "$?" = 1 ] && ok "and still refuses the globs" || bad "--globs passed the bad globs"
# Planted: the rule records no hit, and the same ls passes.
sed 's/push @hit, \$w if \$star/push @hit, $w if 0 \&\& $star/' "$C" > "$T/planted.sh"
if [ "$(grep -cF 'push @hit, $w if $star' "$C")" = 1 ] && [ "$(grep -cF 'push @hit, $w if 0 && $star' "$T/planted.sh")" = 1 ]; then
  bash "$T/planted.sh" "$T/globs-bad.sh" >/dev/null; [ "$?" = 0 ] && ok "planted: the glob rule removed → the bad globs pass" || bad "planted: the bad globs still fail with the rule removed"
else bad "the plant did not land"; fi

suite_end "$FAILED"
