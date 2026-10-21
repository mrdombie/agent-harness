#!/usr/bin/env bash
# coordinator-fleet-pace.test.sh — the fleet's usage budget. Every host builds on one
# plan, so they share one five-hour and one seven-day window. On 2026-10-19 five builds
# hit the five-hour wall at once and every session died; on 2026-10-21 the window
# stood at 87% with 18 builds across two machines. The pacer now:
#   - starts a build only while use <= elapsed share of the window x target + headroom
#     (a straight line to the target at the reset), for both windows;
#   - refuses a start the measured burn projects past the target before the reset;
#   - has the sheet's owner split the fleet cap across the hosts by capacity, and
#     each host take its share;
#   - at 95%, stops nobody: the running builds hold before their next step.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"; [ -z "${SLEEPER:-}" ] || kill "$SLEEPER" 2>/dev/null' EXIT
T="$HERE/coordinator-tick.sh"
Q="$HERE/coordinator-queue.sh"
C="$STATE/coordinator"
NOWE=$(date +%s)
unset COORDINATOR_PACE_TARGET COORDINATOR_PACE_HEADROOM COORDINATOR_PACE_WEEK_TARGET COORDINATOR_PACE_WEEK_HEADROOM COORDINATOR_PACE_BURN

# <5h use> <5h reset> [7d use] [7d reset] — one stream-json limit event, as the CLI writes it.
win() {
  jq -nc --argjson u "$1" --argjson r "$2" --argjson u7 "${3:-0.10}" --argjson r7 "${4:-$(( NOWE + 518400 ))}" \
    '{type:"rate_limit_event", rate_limit_info:{status:"allowed",
      unifiedWindows:{five_hour:{utilization:$u, resetsAt:$r}, seven_day:{utilization:$u7, resetsAt:$r7}}}}'
}
clean() { rm -rf "$C" "$STATE/logs"/* "$STATE/driver"; mkdir -p "$C"; }
# pace <here> <claim rows> [machine ceiling] — coord_pace in a fresh shell, role from the env.
pace() {
  ( export SWARM_NOW="$NOWE"; . "$HERE/coordinator-env.sh" >/dev/null 2>&1 || exit 9
    . "$HERE/coordinator-sheet.sh" >/dev/null 2>&1 || exit 9
    coord_pace "$1" "$2" "${COORDINATOR_HOST:-here}" "${3:-}"; echo " rc=$?" )
}
EARLY=$(( NOWE + 16200 ))   # 4.5 h left: 10% of the five-hour window gone
LATE=$(( NOWE + 3600 ))     # 1 h left: 80% gone

echo "--- the straight line: early and low starts, ahead of it does not ---"
clean; win 0.05 "$EARLY" > "$STATE/logs/claim-1-a.log"
out=$(pace 0 "")
# line = 0.10 x 0.85 + 0.05 = 13.5%; projection (0.85 - 0.05) / (0.025 x 4.5 h) = 7.1
want "5% at 10% of the window: room, 7 by the projection" "7" "${out%%$'\t'*}"
want_in "the line is named, and not ahead" 'straight line: 5h 14% at 10% of the window · 7d' "$out"
want_not_in "and nothing is held" 'ahead of it' "$out"
clean; win 0.30 "$EARLY" > "$STATE/logs/claim-1-a.log"
out=$(pace 1 "")
want "30% at 10% of the window is ahead of the line: the cap is what runs, 1, so nothing new" "1" "${out%%$'\t'*}"
want_in "and says so" 'straight line: 5h 14% at 10% of the window \(ahead of it: no new starts\)' "$out"
want "the budget file says ahead" "true" "$(jq -r '.fiveHour.ahead' "$C/pace.json")"
clean; win 0.30 "$EARLY" > "$STATE/logs/claim-1-a.log"
want "ahead of the line with none running: none start" "0" "$(pace 0 "" | cut -f1)"

echo "--- the projection: a start the burn carries past the target is refused ---"
clean; win 0.70 "$LATE" > "$STATE/logs/claim-1-a.log"
out=$(COORDINATOR_PACE_BURN=0.1 pace 1 "")
# line = 0.80 x 0.85 + 0.05 = 73%, so 70% is on it; (0.85 - 0.70) / (0.1 x 1 h) = 1.5
want "on the line, but at 10%/builder-hour one more would pass 85% by the reset" "1" "${out%%$'\t'*}"
want_not_in "the line did not refuse it" 'ahead of it' "$out"
want "projection 1" "1" "$(jq -r '.projection' "$C/pace.json")"

echo "--- the seven-day window holds to its own line ---"
clean; win 0.05 "$EARLY" 0.60 $(( NOWE + 302400 )) > "$STATE/logs/claim-1-a.log"
out=$(pace 1 "")
# half the week gone: 0.5 x 0.9 + 0.05 = 50%, and the week stands at 60%
want "a five-hour window with room, a week ahead of its line: nothing new" "1" "${out%%$'\t'*}"
want_in "the week's line is named" '7d 60% against 50% \(ahead of it: no new starts\)' "$out"
clean; win 0.05 "$EARLY" 0.40 $(( NOWE + 302400 )) > "$STATE/logs/claim-1-a.log"
want "the same week at 40%: under its line, the projection's 7" "7" "$(pace 1 "" | cut -f1)"

echo "--- the fleet cap, split by capacity ---"
want "8 across capacity 6 and 14: 2 and 6" '{"mac":2,"yomato":6}' \
  "$(. "$HERE/coordinator-env.sh" >/dev/null 2>&1; coord_pace_split 8 '[{"host":"mac","capacity":6},{"host":"yomato","capacity":14}]' | jq -cS .)"
want "7 across 10 and 14: the remainder to the larger fraction" '{"here":3,"yomato":4}' \
  "$(. "$HERE/coordinator-env.sh" >/dev/null 2>&1; coord_pace_split 7 '[{"host":"here","capacity":10},{"host":"yomato","capacity":14}]' | jq -cS .)"
want "no capacity read anywhere: shared evenly" '{"a":2,"b":2}' \
  "$(. "$HERE/coordinator-env.sh" >/dev/null 2>&1; coord_pace_split 4 '[{"host":"a"},{"host":"b","capacity":0}]' | jq -cS .)"

# The owner: its own capacity and the reader's fresh heartbeat in fleet.json.
fleet() { # <yomato capacity> <yomato tick> [yomato 5h use]
  jq -nc --argjson c "$1" --argjson t "$2" --arg u "${3:-}" --argjson r "$EARLY" \
    '{hosts:[{host:"yomato", capacity:$c, builds:0, tick:$t}
             + (if $u == "" then {} else {usage:{five_hour:{u:($u|tonumber), reset:$r}}} end)]}' > "$C/fleet.json"
}
clean; win 0.05 "$EARLY" > "$STATE/logs/claim-1-a.log"; fleet 14 "$NOWE"
out=$(COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=here pace 1 "" 10)
want "the owner takes its split of 7: 3 of capacity 10 against 14" "3" "${out%%$'\t'*}"
want_in "and the line names the split" 'fleet cap 7: here 3, yomato 4' "$out"
want "pace.json carries the fleet cap" "7" "$(jq -r '.maxBuildsFleet' "$C/pace.json")"
want "and the shares" '{"here":3,"yomato":4}' "$(jq -cS '.shares' "$C/pace.json")"
clean; win 0.05 "$EARLY" > "$STATE/logs/claim-1-a.log"; fleet 14 $(( NOWE - 7200 ))
want "a reader silent for 2 h takes no share: all 7 here" "7" \
  "$(COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=here pace 1 "" 10 | cut -f1)"
clean; win 0.05 "$EARLY" > "$STATE/logs/claim-1-a.log"; fleet 14 "$NOWE"
want "the owner's share never passes the cap less what runs elsewhere: 5 on yomato leave 2" "2" \
  "$(COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=here pace 1 "$(printf '%s\tyomato\tbuild\n' 1 2 3 4 5)" 10 | cut -f1)"

# The reader: the owner's split, from the sheet it read this tick.
SP='{"maxBuildsFleet":7,"shares":{"here":3,"Yomato":4},"usage":{"five_hour":{"u":0.05,"reset":'"$EARLY"'}}}'
reader() { ( export SHEET_PACE="$SP" COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=yomato; pace "$@" ); }
clean; win 0.05 "$EARLY" > "$STATE/logs/claim-1-a.log"
want "the reader takes its share, 4, though the budget affords 7" "4" "$(reader 0 "" 14 | cut -f1)"
want "13 running on the reader with a share of 4: its ceiling is 4 (the tick never stops one)" "4" "$(reader 13 "" 14 | cut -f1)"
want "the owner over its own share: the reader keeps under the cap, 7 - 5 = 2" "2" \
  "$(reader 0 "$(printf '%s\there\tbuild\n' 1 2 3 4 5)" 14 | cut -f1)"
( export COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=yomato SHEET_PACE='{"maxBuildsFleet":7,"shares":{"here":3}}'; pace 0 "" 14 ) > "$FIX/out.txt"
want "a sheet that names no share for it: the reader takes the cap" "7" "$(cut -f1 "$FIX/out.txt")"

echo "--- the freshest reading wins, from either host ---"
clean; win 0.05 "$EARLY" > "$STATE/logs/claim-1-a.log"
out=$( export SHEET_FLEET='[{"host":"here","tick":'"$NOWE"',"usage":{"five_hour":{"u":0.40,"reset":'"$EARLY"'}}}]'; reader 0 "" 14 )
want_in "the owner's heartbeat at 40% outranks this host's 5%" '5h window 40%' "$out"
want_in "and puts it ahead of the line" 'ahead of it: no new starts' "$out"
clean; win 0.05 "$EARLY" > "$STATE/logs/claim-1-a.log"; fleet 14 "$NOWE" 0.50
want_in "the owner reads the reader's heartbeat in the fleet file" '5h window 50%' \
  "$(COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=here pace 0 "" 10)"
clean; fleet 14 "$NOWE" 0.50
want_in "a heartbeat alone is a reading: no log here at all" '5h window 50%' \
  "$(COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=here pace 0 "" 10)"

echo "--- the heartbeat publishes the reading and the capacity ---"
clean; win 0.33 "$EARLY" 0.20 > "$STATE/logs/claim-1-a.log"
pace 0 "" 6 >/dev/null
hb=$( export SWARM_NOW="$NOWE"; . "$HERE/coordinator-env.sh" >/dev/null 2>&1; . "$HERE/coordinator-sheet.sh" >/dev/null 2>&1
      coord_heartbeat 0 100 6 )
want "it carries the five-hour reading" "0.33 $EARLY" "$(jq -r '"\(.usage.five_hour.u) \(.usage.five_hour.reset)"' <<<"$hb")"
want "the seven-day one" "0.2" "$(jq -r '.usage.seven_day.u' <<<"$hb")"
want "and its capacity" "6" "$(jq -r '.capacity' <<<"$hb")"

echo "--- the sheet carries the fleet cap to the readers ---"
entries='{"order":[],"building":[],"pace":{"at":1,"usage":{"five_hour":{"u":0.4,"reset":2}},"fiveHour":{"line":0.5},"sevenDay":null,"maxBuildsFleet":8,"shares":{"mac":2,"yomato":6}}}'
body=$( . "$HERE/coordinator-env.sh" >/dev/null 2>&1; . "$HERE/coordinator-sheet.sh" >/dev/null 2>&1; coord_sheet_render "$entries" "$NOWE" )
want_in "a person reads it" 'at most 8 building across every machine: mac 2, yomato 6' "$body"
want "and a reader parses it back" '{"mac":2,"yomato":6}' \
  "$(printf '%s\n' "$body" | sed -nE 's/^<!-- sheet:pace (\{.*\}) -->$/\1/p' | jq -cS '.shares')"

echo "--- the tick: the owner starts only its share ---"
printf '#!/usr/bin/env bash\n:\n' > "$BIN/judge"; chmod +x "$BIN/judge"
for s in reconcile sweep wtsweep; do printf '#!/usr/bin/env bash\n:\n' > "$BIN/$s"; chmod +x "$BIN/$s"; done
export COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep" COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep"
export COORDINATOR_JUDGE="$BIN/judge" COORDINATOR_NOTIFY_CMD=true COORDINATOR_HOST=here
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
export COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0
unset COORDINATOR_SHADOW COORDINATOR_CAP COORDINATOR_HEALING_SHARE SWARM_NOW
export SWARM_FREE_MEM_GB=64 SWARM_IDLE=90 SWARM_CORES=10 COORDINATOR_RAMP_FREE_MEM_GB=1
cat > "$BIN/spawn-live" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SPAWNS"
SH
chmod +x "$BIN/spawn-live"
tickworld() { # <5h use> — one live builder here (a real process), five ready tickets
  clean; rm -rf "$STATE/runs"/*; : > "$SPAWNS"; printf '[]\n' > "$FIX/gh/prs-all.json"
  local now; now=$(date +%s)
  win "$1" $(( now + 16200 )) > "$STATE/logs/claim-500-live.log"
  [ -z "${SLEEPER:-}" ] || kill "$SLEEPER" 2>/dev/null
  sleep 600 & SLEEPER=$!; disown "$SLEEPER" 2>/dev/null
  printf '{"run_id":"claim-500-live","ticket":"500","child_pid":%s,"log":"%s"}\n' "$SLEEPER" "$STATE/logs/claim-500-live.log" \
    > "$STATE/runs/claim-500-live.json"
  printf '500\there\tbuild\n' > "$FIX/claims.txt"
  local t; for t in 601 602 603 604 605; do fix_issue "$t" OPEN "status:ready"; bash "$Q" add "$t" >/dev/null; done
}
live() { SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" 2>&1; }
tickworld 0.05; fleet 14 "$(date +%s)"
out=$(COORDINATOR_SHEET_OWNER=here live)
want "the owner's share is 3 with 1 running: 2 start, not the 5 its CPU fits" "2" "$(grep -c . "$SPAWNS")"
want_in "the tick log shows the fleet cap" 'pace: 5h window 5%.* → 7 across all hosts, 0 on other hosts → 3 here · straight line: 5h 14% at 10% of the window · 7d 10% against .* · fleet cap 7: here 3, yomato 4' "$(cat "$C/tick.log")"
want "the live view's capacity carries the share" "3 7" "$(jq -r '"\(.pace.share) \(.pace.maxBuildsFleet)"' "$C/capacity.json")"
tickworld 0.05; fleet 14 "$(date +%s)"
out=$(COORDINATOR_SHEET_OWNER=here COORDINATOR_PACE=0 live)
want "unpaced, the machine fills all five" "5" "$(grep -c . "$SPAWNS")"

echo "--- at 95%, nothing is stopped and nothing new starts ---"
tickworld 0.96
# The spawn hold at swarm.usageCeiling sits above it here, so the step hold is the one answering.
out=$(SWARM_USAGE_CEILING=0.99 live)
want "no start" "0" "$(grep -c . "$SPAWNS")"
want "the running builder is alive after the tick" "alive" "$(kill -0 "$SLEEPER" 2>/dev/null && echo alive || echo gone)"
want_in "the tick names the usage hold" 'spawn: usage hold — the five_hour window is at 96%.* none is stopped' "$out"
want "the live view's capacity carries it" "96 five_hour" "$(jq -r '"\(.usageHold.pct) \(.usageHold.window)"' "$C/capacity.json")"
hs=$(SWARM_USAGE_CEILING=0.99 bash "$HERE/../swarm/hold-status.sh")
want "and the live view's hold says usage, between steps" "usage true" "$(jq -r '"\(.kind) \(.step)"' <<<"$hs")"
want_in "in words" 'usage is at 96%: running builds finish the step they are on' "$(jq -r '.reason' <<<"$hs")"
tickworld 0.50
hs=$(SWARM_USAGE_CEILING=0.99 bash "$HERE/../swarm/hold-status.sh")
want "at 50% no usage hold" "false" "$(jq -r '.held' <<<"$hs")"

exit $FAILED
