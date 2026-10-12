#!/usr/bin/env bash
# announce-shipped.sh: the banner names the ticket and title, a notification is
# sent where osascript exists, and a machine without it still exits 0.
set -uo pipefail

SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/announce-shipped.sh"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
cat > "$T/bin/osascript" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$OSA_LOG"
STUB
chmod +x "$T/bin/osascript"
printf '#!/usr/bin/env bash\necho "$1" >> "$AF_LOG"\n' > "$T/bin/afplay"; chmod +x "$T/bin/afplay"
BASE="/usr/bin:/bin"

out=$(AF_LOG="$T/af.log" OSA_LOG="$T/osa.log" PATH="$T/bin:$BASE" bash "$SUT" '#123' 'Fix the "login" page' https://x/pr/9); rc=$?
[ $rc -eq 0 ] && ok "exits 0" || fail "exit $rc"
grep -q '██████╗' <<<"$out" && ok "big banner printed" || fail "no banner"
grep -q 'TICKET #123 COMPLETED' <<<"$out" && ok "names the ticket, one #" || fail "ticket line wrong: $(grep TICKET <<<"$out")"
grep -q 'Fix the "login" page' <<<"$out" && ok "names the title" || fail "title missing"
grep -q 'https://x/pr/9' <<<"$out" && ok "shows the PR link" || fail "link missing"
grep -q 'display notification "Fix the login page" with title "✅ Ticket #123 completed"' "$T/osa.log" 2>/dev/null \
  && ok "desktop notification sent, quotes stripped" || fail "notification: $(cat "$T/osa.log" 2>/dev/null)"
sleep 0.3; grep -q 'Glass.aiff' "$T/af.log" 2>/dev/null && ok "sound played directly" || fail "no sound played"

out=$(PATH="$BASE" bash "$SUT" 7 'No mac'); rc=$?
[ $rc -eq 0 ] && grep -q 'TICKET #7 COMPLETED' <<<"$out" && ok "no osascript: banner still printed, exit 0" || fail "no-osascript case rc=$rc"

PATH="$BASE" bash "$SUT" 7 >/dev/null 2>&1 && fail "missing title accepted" || ok "missing title refused"

echo "$PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
