#!/usr/bin/env bash
# scheduler.test.sh — the four reasons to hold, and the one reason to spawn.
#
# The cap and "a missing live-view answer counts as busy" are the two properties
# that cost real money when they are wrong: the first sent eight agents at one
# programme's files, the second filled every slot on a machine that was already
# full because a down live view read as zero agents running.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
S="$HERE/../scheduler.sh"
sched() { bash "$S" "$@" 2>&1; }
reset_state() { : > "$SPAWNS"; : > "$STATE/swarm/queue.tsv" 2>/dev/null || true; rm -f "$STATE/logs/scheduler.log"; }

fix_ready widgets 301 302 303 304

echo "--- it spawns up to the cap, and no further ---"
reset_state; fix_live widgets 0
out=$(sched --programme widgets)
want "three spawned on an idle programme" "3" "$(grep -c . "$SPAWNS")"
want_in "and it says so"                  'launched 3' "$out"

echo "--- the cap is per programme ---"
reset_state; fix_live widgets 3
out=$(sched --programme widgets)
want "nothing spawned at the cap"         "0" "$(grep -c . "$SPAWNS")"
want_in "the hold names the cap"          '3 agent\(s\) running \(cap 3\) — holding' "$out"
want_in "the hold is logged"              'cap 3' "$(cat "$STATE/logs/scheduler.log")"

reset_state; fix_live widgets 2
sched --programme widgets >/dev/null
want "one slot, one spawn"                "1" "$(grep -c . "$SPAWNS")"

echo "--- a missing live-view answer counts as BUSY, never as room ---"
reset_state; fix_live_down
out=$(sched --programme widgets)
want "nothing spawned when it cannot see" "0" "$(grep -c . "$SPAWNS")"
want_in "and it holds rather than guessing" '99 agent\(s\) running' "$out"

echo "--- the machine's load ---"
reset_state; fix_live widgets 0
out=$(SWARM_LOAD=40 sched --programme widgets)
want "nothing spawned above the ceiling"  "0" "$(grep -c . "$SPAWNS")"
want_in "the hold names the load"         'load 40 above 32 — holding' "$out"
out=$(SWARM_LOAD=32 sched --programme widgets)
want_not_in "at the ceiling it still runs" 'above 32' "$out"

echo "--- the plan's usage limit ---"
reset_state; fix_live widgets 0
printf 'You have hit your session limit · resets 11:30pm\n' > "$STATE/logs/claim-301-x.log"
out=$(SWARM_NOW=$(date -j -f '%H:%M' '09:00' +%s 2>/dev/null || date -d 'today 09:00' +%s) sched --programme widgets)
want "nothing spawned while the limit holds" "0" "$(grep -c . "$SPAWNS")"
want_in "the hold names the reset time"      'usage limit — holding until 11:30pm' "$out"
# Past the reset time the hold lifts. "resets 8am" read at 09:00 is yesterday's.
printf 'You have hit your weekly limit · resets 8am\n' > "$STATE/logs/claim-301-x.log"
out=$(SWARM_NOW=$(date -j -f '%H:%M' '09:00' +%s 2>/dev/null || date -d 'today 09:00' +%s) sched --programme widgets)
want_not_in "a reset time already past does not hold" 'usage limit' "$out"
rm -f "$STATE/logs/claim-301-x.log"

echo "--- waves: only the current wave runs, and it advances when spent ---"
reset_state; fix_live widgets 0
mkdir -p "$STATE/swarm/widgets"
printf '[[301,302],[303,304]]\n' > "$STATE/swarm/widgets/waves.json"
echo 1 > "$STATE/swarm/widgets/wave.current"
sched --programme widgets >/dev/null
want "only wave 1 was started"      "2" "$(grep -c . "$SPAWNS")"
want_not_in "no ticket from wave 2" '^303|^304' "$(cat "$SPAWNS")"
want "the wave did not advance yet" "1" "$(cat "$STATE/swarm/widgets/wave.current")"

# Wave 1 is spent once both its tickets are closed.
fix_issue 301 CLOSED ""; fix_issue 302 CLOSED ""
reset_state; fix_live widgets 0
out=$(sched --programme widgets)
want_in "it says the wave is spent" 'wave 1 exhausted → wave 2' "$out"
want "and moves to wave 2"          "2" "$(cat "$STATE/swarm/widgets/wave.current")"
reset_state; fix_live widgets 0
sched --programme widgets >/dev/null
want_in "now wave 2 runs" '^303' "$(head -1 "$SPAWNS")"
rm -rf "$STATE/swarm/widgets"

echo "--- --explain spawns nothing ---"
reset_state; fix_live widgets 0
out=$(sched --programme widgets --explain)
want "explain never spawns"     "0" "$(grep -c . "$SPAWNS")"
want_in "explain names what is next" 'free slot\(s\); next up: 30' "$out"
want "explain writes no log"    "0" "$([ -f "$STATE/logs/scheduler.log" ] && grep -c . "$STATE/logs/scheduler.log" || echo 0)"

echo "--- programmes are discovered, never enumerated ---"
reset_state; fix_live widgets 0
out=$(sched)
want_in "the ready tickets' own labels are the list" 'widgets:' "$out"

echo "--- STALE data is not an answer either ---"
# A live view still serving a page from an hour ago is describing a machine that
# no longer exists. That has to read as busy, exactly like silence.
fix_ready widgets 301 302 303 304          # the wave case closed two of them
reset_state
fix_live widgets 0 "$(date -u -r $(( $(date +%s) - 3600 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
out=$(sched --programme widgets)
want "nothing spawned on a stale snapshot" "0" "$(grep -c . "$SPAWNS")"
want_in "and the hold says it was stale"   '99 agent\(s\) running' "$out"
# A fresh snapshot of the same shape does spawn, so the case above is staleness
# and not simply "the file was unreadable".
reset_state; fix_live widgets 0
sched --programme widgets >/dev/null
want "a fresh snapshot spawns"             "3" "$(grep -c . "$SPAWNS")"

exit $FAILED
