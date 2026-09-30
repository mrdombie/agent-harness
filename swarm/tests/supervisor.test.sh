#!/usr/bin/env bash
# supervisor.sh — the one long-running process Windows runs the swarm's jobs in.
#
# What it must get right is timing, not work: the jobs themselves have their own
# suites. A due job runs, a job that ran a moment ago does not, a supervisor that
# comes back after a restart does not fire every job at once, and a second
# supervisor on the same state directory refuses rather than doubling every pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
SUP="$HERE/../supervisor.sh"
fix_ready widgets 301 302
fix_live widgets 0

T0=$(date +%s)

echo "--- a due job runs ---"
SWARM_NOW=$T0 bash "$SUP" --once
want "the scheduler ran and wrote its log"  "yes" "$([ -s "$STATE/logs/scheduler.out.log" ] && echo yes || echo no)"
want "its run is stamped"                "$T0" "$(cat "$STATE/swarm/supervisor.scheduler.last" 2>/dev/null)"
want "the repair watch ran too"          "$T0" "$(cat "$STATE/swarm/supervisor.repair-watch.last" 2>/dev/null)"

echo "--- a job that just ran is not due ---"
before=$(wc -l < "$STATE/logs/scheduler.out.log")
SWARM_NOW=$((T0 + 60)) bash "$SUP" --once
want "sixty seconds on, nothing re-ran"  "$before" "$(wc -l < "$STATE/logs/scheduler.out.log")"
want "and the stamp did not move"        "$T0" "$(cat "$STATE/swarm/supervisor.scheduler.last")"

echo "--- the scheduler is due again after its interval, repair is not ---"
SWARM_NOW=$((T0 + 300)) bash "$SUP" --once
want "the scheduler re-stamped"          "$((T0 + 300))" "$(cat "$STATE/swarm/supervisor.scheduler.last")"
want "the repair watch waited its 600s"  "$T0" "$(cat "$STATE/swarm/supervisor.repair-watch.last")"

echo "--- a second supervisor refuses ---"
sleep 300 & holder=$!
printf '%s\n' "$holder" > "$STATE/swarm/supervisor.pid"
out=$(SWARM_NOW=$((T0 + 900)) timeout 20 bash "$SUP" 2>&1; cat "$STATE/logs/supervisor.log")
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
want_in "it names the one already running" "another supervisor \\($holder\\) is running" "$out"
want "and it ran nothing"                "$((T0 + 300))" "$(cat "$STATE/swarm/supervisor.scheduler.last")"

echo "--- a stale pid file does not block ---"
( exit 0 ) & dead=$!; wait "$dead"
printf '%s\n' "$dead" > "$STATE/swarm/supervisor.pid"
SWARM_SUPERVISOR_TICK=1 SWARM_NOW=$((T0 + 1200)) timeout 8 bash "$SUP" >/dev/null 2>&1
want "it took over and ran the due job"  "$((T0 + 1200))" "$(cat "$STATE/swarm/supervisor.scheduler.last")"

echo "--- a machine taking a SHARE schedules only its programmes ---"
rm -f "$STATE/swarm/supervisor."*.last "$STATE/swarm/supervisor.pid"
: > "$SPAWNS"; : > "$STATE/swarm/queue.tsv"
fix_ready gadgets 401 402
fix_live widgets 0
out=$(SWARM_PROGRAMMES=gadgets SWARM_REPAIR_ONLY=infra SWARM_NOW=$(date +%s) bash "$SUP" --once 2>&1; cat "$STATE/logs/scheduler.out.log")
want_in    "its programme is scheduled"      '^40[12]'  "$(cat "$SPAWNS")"
want_not_in "the other programme is left alone" '^30[12]' "$(cat "$SPAWNS")"

exit $FAILED
