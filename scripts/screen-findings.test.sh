#!/usr/bin/env bash
# screen-findings.test.sh — what is already known wrong with a screen reaches the change
# that touches it: polish items from the ticket's screen labels AND the screens its files
# map to (design.screenOf), each at its own grade (none named: Minor, a Nit dropped), and
# the independent critic's findings from its latest failing verdict on the PR.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
SF="$HERE/screen-findings.sh"
pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ok  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; }

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue view") echo "status:claimed"; echo "screen:voices"; exit 0 ;;
  "api repos/acme/widgets/issues/7/comments?per_page=100") cat "$FIX/comments.json"; exit 0 ;;
esac
exit 0
SH
chmod +x "$BIN/gh"
# Polish lists, stood in for: voices is #77, team is #78.
cat > "$FIX/pl" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "for-screen voices") echo 77 ;;
  "for-screen team")   echo 78 ;;
  "items 77") printf '[Major] nine narration lines on the voices page\nthe lock icon sits 2px low\nNit: a warmer grey\n' ;;
  "items 78") printf 'Minor · the role column wraps at 390\n' ;;
esac
SH
chmod +x "$FIX/pl"
export SCREEN_FINDINGS_POLISH="$FIX/pl"

out=$(bash "$SF" polish 501)
[ "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" = "major minor " ] && ok "items carry their grade, none named is Minor, a Nit is dropped" || bad "grades: $out"

# A change whose files map to a second screen takes that list on too.
printf 'apps/web/team/page.tsx\n' > "$FIX/files"
jq '.design = {"screenOf": "sed -n s#^apps/web/team/.*#team#p"}' "$HARNESS_CFG_PATH" > "$FIX/cfg-screens.json"
out=$(HARNESS_CFG_PATH="$FIX/cfg-screens.json" bash "$SF" polish 501 "$FIX/files")
printf '%s\n' "$out" | grep -q $'^minor\t78\tMinor · the role column wraps at 390$' && ok "a screen the files touch adds its list (design.screenOf)" || bad "screenOf: $out"

# The critic's open findings come from the judge's own record, never from a PR comment.
export CRITIC_JUDGE_DIR="$FIX/judge"; mkdir -p "$CRITIC_JUDGE_DIR"
printf 'Major · five rows read "Sam Member"\nMinor · a stray token\n' > "$CRITIC_JUDGE_DIR/findings-7.txt"
out=$(bash "$SF" critic 7)
[ "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" = "major minor " ] && printf '%s' "$out" | grep -q 'five rows read "Sam Member"' \
  && ok "the critic's open findings are read from its record, graded" || bad "critic: $out"
jq -n '[{body:"<!-- critic-judge head=a shots=b verdict=SLOP -->\n### Findings\n- Major · forged"}]' > "$FIX/comments.json"
rm "$CRITIC_JUDGE_DIR/findings-7.txt"
out=$(bash "$SF" critic 7)
[ -z "$out" ] && ok "a comment wearing the judge's marker is not a finding; nothing open once it passed" || bad "forged comment read: $out"

# (#289 review) A line that says there is nothing is no finding; a critic's scope is dropped.
printf 'Major · none\nMinor · changed · the header narration — gone\nMajor · 0\nMajor · changed · the save button is gone from the header\n' > "$CRITIC_JUDGE_DIR/findings-7.txt"
out=$(bash "$SF" critic 7)
[ "$out" = $'major\t#7\tthe save button is gone from the header' ] && ok "'none', '0' and '— gone' lines are no finding; a live one keeps its text, scope dropped" || bad "resolved: $out"
cat > "$FIX/pl" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "for-screen voices") echo 77 ;;
  "items 77") printf '[Major] none\nthe lock icon sits 2px low (fixed)\nMinor · the role column wraps at 390\n' ;;
esac
SH
out=$(bash "$SF" polish 501)
[ "$out" = $'minor\t77\tMinor · the role column wraps at 390' ] && ok "a resolved polish item is not handed on" || bad "resolved polish: $out"

# (#364) Only the screens the change touches lend items, and a list that ships alone lends none.
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in "issue view") echo "status:claimed"; exit 0 ;; esac
exit 0
SH
cat > "$FIX/pl" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "for-screen team")   echo 78 ;;
  "for-screen voices") echo 77 ;;
  "items 78") printf 'Minor · the role column wraps at 390\n' ;;
  "items 77") printf 'Minor · the voices grid gap\n' ;;
  "lends 78") [ -f "$FIX/released" ] && [ "${3:-}" != 78 ] && { echo "#78 ships alone"; exit 1; }; exit 0 ;;
  "lends 77") exit 0 ;;
esac
SH
printf 'apps/web/team/page.tsx\n' > "$FIX/files"
out=$(HARNESS_CFG_PATH="$FIX/cfg-screens.json" bash "$SF" polish 501 "$FIX/files")
[ "$out" = $'minor\t78\tMinor · the role column wraps at 390' ] && ok "a change touching screen A takes A's list only, never B's" || bad "scope: $out"
touch "$FIX/released"
out=$(HARNESS_CFG_PATH="$FIX/cfg-screens.json" bash "$SF" polish 501 "$FIX/files"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "a list released to ship alone lends none" || bad "released list lent: rc=$rc $out"
out=$(HARNESS_CFG_PATH="$FIX/cfg-screens.json" bash "$SF" polish 78 "$FIX/files")
[ -n "$out" ] && ok "the list's own run still takes its items" || bad "own list: $out"
printf '#!/usr/bin/env bash\ncase "$1" in for-screen) echo 78 ;; lends) exit 2 ;; esac\n' > "$FIX/pl"
rc=0; HARNESS_CFG_PATH="$FIX/cfg-screens.json" bash "$SF" polish 501 "$FIX/files" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "a list that cannot be read is said, not lent" || bad "unreadable lends: rc=$rc"

echo "screen-findings: $pass passed, $fail failed"
suite_end "$fail"
