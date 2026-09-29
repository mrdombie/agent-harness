#!/usr/bin/env bash
# hold.test.sh — a stopped swarm must stay stopped, and say who moved it (#42).
#
# On 2026-09-29 a swarm whose task had been disabled was re-installed by someone
# nobody could name, waited out the plan's usage limit, and spent ~110M tokens in
# two hours. So: while held, nothing spawns (whichever job asks) and install
# refuses; every change is written to the audit log first.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
I="$HERE/../install.sh"; Q="$HERE/../queue.sh"
q() { bash "$Q" "$@" 2>&1; }
SYS="$FIX/system.log"; : > "$SYS"
# Anything that would install or start a job for real records itself instead.
for s in launchctl powershell.exe; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "$s" "$SYS" > "$BIN/$s"; chmod +x "$BIN/$s"
done
AUDIT="$STATE/logs/install-audit.log"

fix_issue 101 OPEN "status:ready,project:widgets"
q add 101 --programme widgets >/dev/null
fix_live widgets 0                       # free slots, so only the hold can stop a spawn

echo "--- held: nothing spawns ---"
out=$(bash "$I" hold "usage leak under investigation" 2>&1)
want_in "hold says what it does"      'nothing spawns' "$out"
want_in "the reason is kept"          'usage leak under investigation' "$(cat "$STATE/swarm/HOLD")"
out=$(q drain --programme widgets)
want "the drain spawned nothing"      "0" "$(grep -c . "$SPAWNS")"
want_in "the refusal names the hold"  'held' "$out"

echo "--- held: install refuses and touches nothing ---"
bash "$I" >/dev/null 2>&1; rc=$?
want "install exits 3 while held"     "3" "$rc"
err=$(bash "$I" restart scheduler 2>&1 >/dev/null)
want_in "restart refuses by name"     'held — usage leak' "$err"
want "no job was loaded or started"   "0" "$(grep -c . "$SYS")"

echo "--- released on purpose: it spawns again ---"
out=$(bash "$I" release 2>&1)
want_in "release says so"             'released' "$out"
if [ -e "$STATE/swarm/HOLD" ]; then bad "the hold file is gone"; else ok "the hold file is gone"; fi
q drain --programme widgets >/dev/null
want_in "the queued ticket spawned"   '^101' "$(head -1 "$SPAWNS")"

echo "--- every change is in the audit log, in order ---"
want "hold, two refusals, release"    "hold refused-held refused-held release" \
     "$(cut -f2 "$AUDIT" | tr '\n' ' ' | sed 's/ $//')"
want_in "who and which kit are recorded" 'session=.*parent=.*kit=' "$(head -1 "$AUDIT")"
want_in "audit prints the log"        'release' "$(bash "$I" audit 1)"

exit $FAILED
