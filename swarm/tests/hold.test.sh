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

echo "--- held: repair-watch spends no attempt, and repairs after release ---"
# Recording an attempt and THEN being refused marked a red PR "tried" at its SHA
# for good, so it was never repaired once released (#44 review).
W="$HERE/../repair-watch.sh"; TRIED="$STATE/swarm/repair-attempts.tsv"
fix_issue 102 OPEN "status:in-review,project:widgets"
fix_prs "12 102 cccccccccc1 CLEAN 0 typecheck"
: > "$SPAWNS"
bash "$I" hold "repair test" >/dev/null 2>&1
out=$(bash "$W" --only repair 2>&1)
want "held: no repair spawned"        "0" "$(grep -c . "$SPAWNS")"
want "held: no attempt recorded"      "0" "$(cat "$TRIED" 2>/dev/null | grep -c .)"
want_in "held: it says why"           'held — not repairing' "$out"
bash "$I" release >/dev/null 2>&1
bash "$W" --only repair >/dev/null 2>&1
want_in "released: the red PR is repaired" '^102' "$(cat "$SPAWNS")"

echo "--- a hold placed MID-PASS still stops the attempt (#45) ---"
# The top-of-pass check has already passed when this hold lands: the gh stand-in
# places it the moment repair-watch lists the pull requests.
fix_prs "13 103 dddddddddd1 CLEAN 0 typecheck"; fix_issue 103 OPEN "status:in-review,project:widgets"
: > "$SPAWNS"; : > "$TRIED"
printf '#!/usr/bin/env bash\n[ "$1 $2" = "pr list" ] && printf "mid-pass (held by the test)\\n" > "%s"\nexec "%s" "$@"\n' \
  "$STATE/swarm/HOLD" "$BIN/gh" > "$FIX/gh-holds"; chmod +x "$FIX/gh-holds"
out=$(SWARM_GH="$FIX/gh-holds" bash "$W" --only repair 2>&1)
want "mid-pass: no repair spawned"    "0" "$(grep -c . "$SPAWNS")"
want "mid-pass: no attempt recorded"  "0" "$(cat "$TRIED" 2>/dev/null | grep -c .)"
want_in "mid-pass: it says so"        'held mid-pass' "$out"
bash "$I" release >/dev/null 2>&1

echo "--- a typo is not written down as an action (#45) ---"
bash "$I" stauts >/dev/null 2>&1
if grep -q 'stauts' "$AUDIT"; then bad "a mistyped command was audited as an action"; else ok "a mistyped command is not audited"; fi
# Held, a typo is still a typo — not a refused restart (#54 review).
bash "$I" hold "typo test" >/dev/null 2>&1
err=$(bash "$I" stauts 2>&1 >/dev/null)
if grep -q 'stauts' "$AUDIT"; then bad "held: a typo was audited as refused-held"; else ok "held: a typo is not audited"; fi
if printf '%s' "$err" | grep -q 'is held'; then bad "held: a typo got the hold message"; else ok "held: a typo is rejected as a typo"; fi
bash "$I" release >/dev/null 2>&1

echo "--- every change is in the audit log, in order ---"
want "hold, two refusals, release ×4" "hold refused-held refused-held release hold release release hold release" \
     "$(cut -f2 "$AUDIT" | tr '\n' ' ' | sed 's/ $//')"
want_in "who and which kit are recorded" 'session=.*parent=.*kit=' "$(head -1 "$AUDIT")"
want_in "audit prints the log"        'release' "$(bash "$I" audit 1)"

exit $FAILED
