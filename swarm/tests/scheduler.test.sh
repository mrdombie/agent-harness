#!/usr/bin/env bash
# scheduler.test.sh — the four reasons to hold, and the one reason to spawn.
#
# The cap and "a missing live-view answer counts as busy" are the two properties
# that cost real money when they are wrong: the first sent eight agents at one
# programme's files, the second filled every slot on a machine that was already
# full because a down live view read as zero agents running.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
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

echo "--- the machine: busy is cpu idle under the floor, load is only a backstop ---"
reset_state; fix_live widgets 0
out=$(SWARM_IDLE=9 sched --programme widgets)
want "nothing spawned under the idle floor" "0" "$(grep -c . "$SPAWNS")"
want_in "the hold names the idle"         'machine busy \(cpu idle 9%, floor 15%\) — holding' "$out"
out=$(SWARM_IDLE=15 sched --programme widgets)
want_not_in "at the floor it still runs"  'machine busy' "$out"
reset_state; fix_live widgets 0
out=$(SWARM_LOAD=60 SWARM_IDLE=41 SWARM_CORES=10 sched --programme widgets)
want_not_in "load 60 at 41% idle on 10 cores is not busy" 'machine busy' "$out"
reset_state; fix_live widgets 0
out=$(SWARM_LOAD=140 SWARM_IDLE=41 SWARM_CORES=10 sched --programme widgets)
want_not_in "load 140 at 41% idle on 10 cores is not busy" 'machine busy' "$out"
reset_state; fix_live widgets 0
out=$(SWARM_LOAD=201 SWARM_IDLE=90 SWARM_CORES=10 sched --programme widgets)
want "nothing spawned over the runaway guard" "0" "$(grep -c . "$SPAWNS")"
want_in "the runaway guard is 20 x cores" 'machine busy \(load 201, limit 200\) — holding' "$out"

echo "--- the plan's usage limit ---"
# The CLI's own failure: the final result event of a run the wall stopped.
cli_error() { jq -nc --arg r "$1" '{type:"result",is_error:true,result:$r}'; }
reset_state; fix_live widgets 0
cli_error 'You have hit your session limit · resets 11:30pm' > "$STATE/logs/claim-301-x.log"
NINE=$(date '+%H %M %S' | awk -v n="$(date +%s)" '{print n - ($1*3600 + $2*60 + $3) + 9*3600}')
out=$(SWARM_NOW=$NINE sched --programme widgets)
want "nothing spawned while the limit holds" "0" "$(grep -c . "$SPAWNS")"
want_in "the hold names the reset time"      'usage limit — holding until 11:30pm' "$out"
# Past the reset time the hold lifts. "resets 8am" read at 09:00 is yesterday's.
cli_error 'You have hit your weekly limit · resets 8am' > "$STATE/logs/claim-301-x.log"
out=$(SWARM_NOW=$NINE sched --programme widgets)
want_not_in "a reset time already past does not hold" 'usage limit' "$out"

# The WEEKLY wall names a date, and the session one does not. Both wordings are
# real: across 245 logs carrying a limit line, 432 said "resets 7:20pm
# (Europe/London)" and 4 said "resets Sep 29 at 9pm (Europe/London)". A regex
# that requires a digit straight after "resets " matches the first and not the
# second, so the weekly wall set no hold at all and the scheduler kept spawning
# into it (2026-09-27).
reset_state; fix_live widgets 0
# The wording is built from a time two hours ahead, so the case does not turn
# green or red depending on when the suite runs.
AHEAD=$(date -r $(( $(date +%s) + 7200 )) '+%b %-d at %-I%p' 2>/dev/null \
        || date -d "@$(( $(date +%s) + 7200 ))" '+%b %-d at %-I%p')
AHEAD=$(printf '%s' "$AHEAD" | tr 'APM' 'apm')
cli_error "You have hit your weekly limit · resets $AHEAD (Europe/London)" > "$STATE/logs/claim-301-x.log"
out=$(sched --programme widgets)
want "nothing spawned on the weekly wall's wording" "0" "$(grep -c . "$SPAWNS")"
want_in "and the hold says so"                       'usage limit' "$out"

# The structured event is the primary reading: rate_limit_event carries an EPOCH
# and names its window, so it needs no wording at all. Present in all 245 of the
# limit-carrying logs measured on 2026-09-27; undocumented.
reset_state; fix_live widgets 0
SOON=$(( $(date +%s) + 7200 ))
printf '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":%s,"rateLimitType":"seven_day"}}\n' "$SOON" \
  > "$STATE/logs/claim-301-x.log"
out=$(sched --programme widgets)
want "nothing spawned on a rejected rate-limit event" "0" "$(grep -c . "$SPAWNS")"
want_in "the hold names the window"                   'seven_day' "$out"

# status is on EVERY event, and is "allowed" or "allowed_warning" 6,352 times
# against 238 "rejected". Only the rejection is a wall.
reset_state; fix_live widgets 0
printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":%s,"rateLimitType":"seven_day"}}\n' "$SOON" \
  > "$STATE/logs/claim-301-x.log"
out=$(sched --programme widgets)
want_not_in "a warning is not a wall" 'usage limit' "$out"
want "and the wave still runs"        "3" "$(grep -c . "$SPAWNS")"

# A rejection whose reset has already passed is history.
reset_state; fix_live widgets 0
PAST=$(( $(date +%s) - 7200 ))
printf '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":%s,"rateLimitType":"five_hour"}}\n' "$PAST" \
  > "$STATE/logs/claim-301-x.log"
out=$(sched --programme widgets)
want_not_in "a reset that has passed does not hold" 'usage limit' "$out"

rm -f "$STATE/logs/claim-301-x.log"

# A wall an interactive window hit: no swarm log carries it, only the StopFailure
# hook saw it. The limit is the account's, so the timers hold on it too.
reset_state; fix_live widgets 0
jq -nc --arg d "You have hit your session limit · \"resetsAt\":$SOON" '{error:"rate_limit",error_details:$d}' \
  | bash "$HERE/../../hooks/usage-limit.sh"
want "the hook recorded the window's wall"   "$SOON" "$(cut -f1 "$STATE/usage-hold" 2>/dev/null)"
out=$(sched --programme widgets)
want "nothing spawned on a window's wall"    "0" "$(grep -c . "$SPAWNS")"
want_in "and the hold says where it came from" 'recorded by a window' "$out"
printf '%s\told wall\n' "$PAST" > "$STATE/usage-hold"
reset_state; out=$(sched --programme widgets)
want_not_in "a window's wall that has passed does not hold" 'usage limit' "$out"
rm -f "$STATE/usage-hold"

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
fix_live widgets 0 "$(swarm_iso $(( $(date +%s) - 3600 )))"
out=$(sched --programme widgets)
want "nothing spawned on a stale snapshot" "0" "$(grep -c . "$SPAWNS")"
want_in "and the hold says it was stale"   '99 agent\(s\) running' "$out"
# A fresh snapshot of the same shape does spawn, so the case above is staleness
# and not simply "the file was unreadable".
reset_state; fix_live widgets 0
sched --programme widgets >/dev/null
want "a fresh snapshot spawns"             "3" "$(grep -c . "$SPAWNS")"

suite_end "$FAILED"
