#!/usr/bin/env bash
# coordinator-tooling-cap.test.sh — overhead never takes the shared budget to zero for the
# work it serves. Owner call 2026-10-22: tooling builders capped at 2, so product
# builders get the usage back. At 13:53Z that day the pacer read 20% used, overhead
# 15.3%/h and 4h17m to the reset, and computed 0 builders on every host.
#   - coordinator.productFloor: under swarm.usageCeiling, the fleet cap is never under it;
#   - coordinator.toolingCap: process and harness runs, on every host together, never over it.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
T="$HERE/coordinator-tick.sh"
Q="$HERE/coordinator-queue.sh"
C="$STATE/coordinator"
NOWE=$(date +%s)
unset COORDINATOR_PACE_TARGET COORDINATOR_PACE_HEADROOM COORDINATOR_PACE_WEEK_TARGET COORDINATOR_PACE_WEEK_HEADROOM \
      COORDINATOR_PACE_BURN COORDINATOR_PRODUCT_FLOOR COORDINATOR_TOOLING_CAP SWARM_USAGE_CEILING
# As the owner runs it: no weekly line.
export COORDINATOR_PACE_WEEK_HEADROOM=1

# <5h use> <5h reset> [7d use] — one stream-json limit event, as the CLI writes it.
win() {
  jq -nc --argjson u "$1" --argjson r "$2" --argjson u7 "${3:-0.18}" --argjson r7 "$(( NOWE + 400000 ))" \
    '{type:"rate_limit_event", rate_limit_info:{status:"allowed",
      unifiedWindows:{five_hour:{utilization:$u, resetsAt:$r}, seven_day:{utilization:$u7, resetsAt:$r7}}}}'
}
clean() { rm -rf "$C" "$STATE/logs"/* "$STATE/driver"; mkdir -p "$C"; }
# overhead <now use> <reset> — the last hour of samples, no builders, the account
# rising 15.3% an hour to <now use>: all of it overhead.
overhead() {
  awk -v now="$NOWE" -v u="$1" -v r="$2" 'BEGIN { for (i = 6; i >= 1; i--) printf "%d\t%.4f\t%d\t0\n", now - i * 600, u - i * 0.0255, r }' > "$C/pace.tsv"
}
pace() { # <here> <claim rows> [tooling live] — coord_pace in a fresh shell at SWARM_NOW=$NOWE
  ( export SWARM_NOW="$NOWE"; . "$HERE/coordinator-env.sh" >/dev/null 2>&1 || exit 9
    coord_pace "$1" "$2" here "" "${3:-0}"; echo " rc=$?" )
}
R=$(( NOWE + 15363 ))   # 18:10Z less 13:53:57Z: 4h16m to the reset

echo "--- the 13:53Z reading: overhead would leave 0, the floor keeps 2 ---"
clean; win 0.20 "$R" > "$STATE/logs/claim-1-a.log"; overhead 0.20 "$R"
out=$(pace 0 "")
want_in "the fixture is the reading: 20%, overhead 15.3%/h, 65% of overhead to the reset" \
  'window 20%.*overhead 15\.3%/h, budget 65% to the target − 65% overhead = 0%' "$out"
want_in "and ahead of the five-hour line, as it was" 'straight line: 5h 17% .*ahead of it' "$out"
want "the floor, not 0" "2" "${out%%$'\t'*}"
want_in "the line says so plainly" 'overhead would leave 0, product floor keeps 2 \(2 here\)' "$out"
want "the budget file records it" "true 0 2" "$(jq -r '"\(.productFloor.applied) \(.productFloor.wouldLeave) \(.maxBuildsFleet)"' "$C/pace.json")"
out=$(COORDINATOR_PRODUCT_FLOOR=0 pace 0 "")
want "with the floor off, the old 0" "0" "${out%%$'\t'*}"
want_in "and it says it is off" 'product floor 0 off' "$out"
out=$(pace 0 "" 2)
want "two tooling runs live: the floor is product work's, on top of them" "4" "${out%%$'\t'*}"
want_in "and names them" 'product floor keeps 2 \+ 2 tooling' "$out"
out=$(pace 0 "$(printf '%s\tYomato\tbuild\n' 701 702)")
want "two builders already on another host meet the floor: none here" "0" "${out%%$'\t'*}"
want_in "the floor is fleet-wide" 'product floor keeps 2 \(0 here\)' "$out"

echo "--- over the usage ceiling the existing hold wins ---"
clean; win 0.92 "$R" > "$STATE/logs/claim-1-a.log"; overhead 0.92 "$R"
out=$(SWARM_USAGE_CEILING=0.9 pace 0 "")
want "the same overhead at 92% over a 0.9 ceiling: 0" "0" "${out%%$'\t'*}"
want_in "and the floor says why it is off" 'product floor 2 off: 5h 92% is at or over the 90% usage ceiling' "$out"
clean; win 0.20 "$R" 0.93 > "$STATE/logs/claim-1-a.log"; overhead 0.20 "$R"
want "the seven-day window over the ceiling: 0" "0" "$(SWARM_USAGE_CEILING=0.9 pace 0 "" | cut -f1)"
clean; win 0.20 "$R" 0.80 > "$STATE/logs/claim-1-a.log"; overhead 0.20 "$R"
out=$(COORDINATOR_PACE_WEEK_HEADROOM=0.05 pace 0 "")
want "a weekly line on and ahead: the floor does not spend the week" "0" "${out%%$'\t'*}"
want_in "and names the week" 'off: 7d 80% is ahead of the weekly line' "$out"
clean; win 0.20 "$R" 0.92 > "$STATE/logs/claim-1-a.log"; overhead 0.20 "$R"
want_in "the weekly line spent" 'off: the weekly line is spent, 7d 92% of 90%' "$(COORDINATOR_PACE_WEEK_HEADROOM=0.05 pace 0 "")"
clean; win 0.10 "$R" > "$STATE/logs/claim-1-a.log"
out=$(pace 0 "")
want_in "a budget that affords more than the floor is left alone" 'product floor 2: the budget already affords [3-9]' "$out"

echo "--- the floor, split by the host weights ---"
clean; win 0.20 "$R" > "$STATE/logs/claim-1-a.log"; overhead 0.20 "$R"
printf '{"hosts":[{"host":"Yomato","capacity":4,"builds":0,"tick":%s}]}\n' "$NOWE" > "$C/fleet.json"
cat > "$FIX/sheet-owner.sh" <<'SH'
coord_sheet_role() { echo owner; }
SH
out=$( export SWARM_NOW="$NOWE"; . "$HERE/coordinator-env.sh" >/dev/null 2>&1; . "$FIX/sheet-owner.sh"; coord_pace 0 "" here 4 0 )
want "two hosts of the same weight: 1 here" "1" "${out%%$'\t'*}"
want_in "the fleet cap is split" 'fleet cap 2: Yomato 1, here 1' "$out"
want_in "and the floor names this host's share" 'product floor keeps 2 \(1 here\)' "$out"

echo "--- the tick: tooling capped across every host ---"
printf '#!/usr/bin/env bash\n:\n' > "$BIN/judge"; chmod +x "$BIN/judge"
for s in reconcile sweep wtsweep; do printf '#!/usr/bin/env bash\n:\n' > "$BIN/$s"; chmod +x "$BIN/$s"; done
export COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep" COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep"
export COORDINATOR_JUDGE="$BIN/judge" COORDINATOR_NOTIFY_CMD=true COORDINATOR_HOST=here
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
export COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0
unset COORDINATOR_SHADOW COORDINATOR_CAP COORDINATOR_HEALING_SHARE SWARM_NOW
export SWARM_FREE_MEM_GB=16 SWARM_IDLE=90 SWARM_CORES=10
cat > "$BIN/spawn-live" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SPAWNS"
SH
chmod +x "$BIN/spawn-live"
world() { # no pacing reading: the machine alone sizes the ceiling
  clean; rm -rf "$STATE/runs"/*; : > "$SPAWNS"; : > "$FIX/claims.txt"; printf '[]\n' > "$FIX/gh/prs-all.json"
}
run_here() { # <ticket> <labels> — a live builder on this host
  fix_issue "$1" OPEN "$2"
  printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s}\n' "$1" "$1" "$$" > "$STATE/runs/claim-$1-live.json"
  printf '%s\there\tbuild\n' "$1" >> "$FIX/claims.txt"
}
ready() { local l="$1" t; shift; for t in "$@"; do fix_issue "$t" OPEN "$l"; bash "$Q" add "$t" >/dev/null; done; }
live() { SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" 2>&1; }
spawned() { sort -n "$SPAWNS" | tr '\n' ' ' | sed 's/ $//'; }

world; run_here 600 "process,status:in-progress"; ready "process,status:ready" 601 602 603
out=$(COORDINATOR_CAP=6 live)
want "3 process tickets ready, 1 live, cap 2: only 1 more starts" "601" "$(spawned)"
want_in "the tick says how many are live" 'tooling: 1 live of the cap of 2 on every host \(#600\)' "$out"
want_in "and that the rest wait" 'tooling: 2 tooling ticket\(s\) wait' "$out"
want "the live view's file carries it" "2 1 2" "$(jq -r '"\(.tooling.cap) \(.tooling.live) \(.tooling.waiting)"' "$C/capacity.json")"

world; run_here 600 "process,status:in-progress"; run_here 610 "repo:agent-harness,status:in-progress"
ready "process,status:ready" 601 602; ready "P2,status:ready" 701
out=$(COORDINATOR_CAP=6 live)
want "2 process runs live: the product ticket starts, no process fix does" "701" "$(spawned)"
want_in "a harness-project run counts toward the cap" 'tooling: 2 live of the cap of 2' "$out"

world; run_here 600 "P2,status:in-progress"; printf '%s\tYomato\tbuild\n' 620 621 >> "$FIX/claims.txt"
fix_issue 620 OPEN "process,status:in-progress"; fix_issue 621 OPEN "project:harness-kit,status:in-progress"
ready "process,status:ready" 601; ready "P2,status:ready" 701
out=$(COORDINATOR_CAP=6 live)
want "two tooling runs on another host fill the cap here too" "701" "$(spawned)"
want_in "counted from its claims" 'tooling: 2 live of the cap of 2 on every host \(#620 #621\)' "$out"

world; ready "process,status:ready" 601 602 603; ready "P2,status:ready" 701
out=$(COORDINATOR_CAP=6 live)
want "none live: two process fixes first, then product work" "601 602 701" "$(spawned)"
world; ready "process,status:ready" 601 602 603
out=$(COORDINATOR_CAP=6 COORDINATOR_TOOLING_CAP=3 live)
want "the cap is a setting" "601 602 603" "$(spawned)"

echo "--- the floor's places are product work's ---"
world; win 0.20 "$R" > "$STATE/logs/claim-1-a.log"; overhead 0.20 "$R"
ready "process,status:ready" 601; ready "P2,status:ready" 701 702 703
out=$(COORDINATOR_CAP=6 SWARM_NOW="$NOWE" live)
want "overhead would leave 0: the floor starts 2 product tickets, not the process fix" "701 702" "$(spawned)"
want_in "the tick log shows the floor" 'overhead would leave 0, product floor keeps 2 \(2 here\)' "$out"
want_in "and the tooling line says why the process fix waits" 'the places now are the product floor' "$out"
want "the live view's file carries the floor" "true 0 2" "$(jq -r '"\(.pace.productFloor.applied) \(.pace.productFloor.wouldLeave) \(.pace.productFloor.floor)"' "$C/capacity.json")"

suite_end "$FAILED"
