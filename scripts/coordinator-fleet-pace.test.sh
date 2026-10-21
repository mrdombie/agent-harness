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
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"; [ -z "${SLEEPER:-}" ] || kill "$SLEEPER" 2>/dev/null'
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

echo "--- the pacing settings are the fleet's: the reader paces by the owner's ---"
clean; win 0.05 "$EARLY" 0.53 $(( NOWE + 518400 )) > "$STATE/logs/claim-1-a.log"
# The owner: weekly line off (weekHeadroom 1). The reader keeps the default 0.05.
fleet 14 "$NOWE"
( export COORDINATOR_PACE_WEEK_HEADROOM=1 COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=here; pace 0 "" 10 ) > "$FIX/owner.txt"
want_in "the owner, weekly line off, says so" '7d 53% \(no weekly line\)' "$(cat "$FIX/owner.txt")"
want "and publishes the settings it paced by" "1 false" "$(jq -r '"\(.settings.weekHeadroom) \(.settings.week)"' "$C/pace.json")"
OWNER_PACE=$(jq -c '{at, usage, fiveHour, sevenDay, maxBuildsFleet, shares, settings}' "$C/pace.json")
OWNER_SHARES=$(jq -c '.shares' "$C/pace.json")
( export SHEET_PACE="$OWNER_PACE" COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=yomato; pace 0 "" 14 ) > "$FIX/reader.txt"
want "the owner names the reader a share" "4" "$(jq -r '.yomato' <<<"$OWNER_SHARES")"
want "a reader on its own default (weekly line on, the week ahead of it) still takes that share" "4" "$(cut -f1 "$FIX/reader.txt")"
want_in "it applied the owner's weekly setting" '7d 53% \(no weekly line\)' "$(cat "$FIX/reader.txt")"
want "and records it" "1" "$(jq -r '.settings.weekHeadroom' "$C/pace.json")"
( export SHEET_PACE='{"maxBuildsFleet":6,"shares":{"yomato":4},"settings":{"target":0.85,"headroom":0.05,"weekTarget":0.9,"weekHeadroom":0.05}}' \
         COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=yomato; pace 0 "" 14 ) > "$FIX/reader2.txt"
want "the owner's share stands in for the reader's own line, weekly line on" "4" "$(cut -f1 "$FIX/reader2.txt")"
want_in "and the log says the share decides" "ahead of it: the share from the owner decides" "$(cat "$FIX/reader2.txt")"
( export SHEET_PACE='{"maxBuildsFleet":6}' COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=yomato; pace 1 "" 14 ) > "$FIX/reader3.txt"
want "no share named for it: the reader's own line holds" "1" "$(cut -f1 "$FIX/reader3.txt")"

echo "--- the freshest reading wins, from either host ---"
clean; win 0.05 "$EARLY" > "$STATE/logs/claim-1-a.log"
out=$( export SHEET_FLEET='[{"host":"here","tick":'"$NOWE"',"usage":{"five_hour":{"u":0.40,"reset":'"$EARLY"'}}}]'; reader 0 "" 14 )
want_in "the owner's heartbeat at 40% outranks this host's 5%" '5h window 40%' "$out"
want_in "it is ahead of the line, and the share the owner named it decides" 'ahead of it: the share from the owner decides' "$out"
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

echo "--- the GitHub allowance is the fleet's too: the freshest reading on any host ---"
GHR=$(( NOWE + 1800 ))
ghfleet() { # <yomato graphql remaining> [reset] — Yomato's heartbeat with its allowance reading
  jq -nc --argjson g "$1" --argjson r "${2:-$GHR}" --argjson t "$(date +%s)" \
    '{hosts:[{host:"Yomato", tick:$t, builds:3, capacity:14, gh:[{resource:"graphql", remaining:$g, limit:5000, reset:$r},
                                                   {resource:"core", remaining:4900, limit:5000, reset:$r}]}]}' > "$C/fleet.json"
}
gh_here() { printf 'graphql\t%s\t5000\t%s\ncore\t4800\t5000\t%s\n' "$1" "$GHR" "$GHR" > "$STATE/swarm/gh-allowance"; }
ghlow() { ( export SWARM_NOW="$NOWE"; . "$HERE/coordinator-env.sh" >/dev/null 2>&1 || exit 9; gh_allowance_low; echo " rc=$?" ); }
clean; mkdir -p "$STATE/swarm"; gh_here 4000; ghfleet 100
want_in "4000 left here, 100 as Yomato read it: low, and named" '^graphql	100	5000	[0-9]+	Yomato' "$(ghlow)"
want_in "the reason says where it was read" "GraphQL 100 of 5000 left until .*, as Yomato read it" \
  "$( export SWARM_NOW="$NOWE"; . "$HERE/coordinator-env.sh" >/dev/null 2>&1; gh_limit_why )"
clean; mkdir -p "$STATE/swarm"; gh_here 4000; ghfleet 100 $(( NOWE - 60 ))
want_in "Yomato's low reading from a window already reset: not low" 'rc=1' "$(ghlow)"
clean; mkdir -p "$STATE/swarm"; gh_here 4000; ghfleet 4500
want_in "both hosts well over the mark: not low" 'rc=1' "$(ghlow)"
clean; mkdir -p "$STATE/swarm"; gh_here 200; rm -f "$C/fleet.json"
out=$(ghlow)
want_in "this host's own low reading, with no fleet file at all, still holds" '^graphql	200	5000	[0-9]+	here' "$out"
want_in "as low" 'rc=0$' "$out"
clean; mkdir -p "$STATE/swarm"; gh_here 1234
hb=$( export SWARM_NOW="$NOWE"; . "$HERE/coordinator-env.sh" >/dev/null 2>&1; . "$HERE/coordinator-sheet.sh" >/dev/null 2>&1; coord_heartbeat 0 100 6 )
want "the heartbeat publishes this host's allowance reading" "graphql 1234 5000 $GHR" \
  "$(jq -r '.gh[] | select(.resource == "graphql") | "\(.resource) \(.remaining) \(.limit) \(.reset)"' <<<"$hb")"

echo "--- GraphQL spent, REST not: the batched ticket read goes through REST ---"
cat > "$BIN/gh-rest" <<'SH'
#!/usr/bin/env bash
# REST's issue read answered from the fixture's issue file; everything else to the fixture's gh.
case "$1 $2" in "api repos/"*/issues/[0-9]*)
  n=${2##*/}; printf 'api %s\n' "$2" >> "$GH_LOG"
  [ -f "$FIX/gh/issue-$n.json" ] || exit 1
  jq '{number, state: (.state | ascii_downcase), title, updated_at: .updatedAt, labels}' "$FIX/gh/issue-$n.json"; exit 0 ;;
esac
exec "$BIN/gh" "$@"
SH
chmod +x "$BIN/gh-rest"
batch() { ( export SWARM_GH="$BIN/gh-rest" SWARM_NOW="$NOWE"; . "$HERE/coordinator-env.sh" >/dev/null 2>&1 || exit 9; gh_issues_batch 611 612 ) }
clean; mkdir -p "$STATE/swarm"; gh_here 4000; ghfleet 100
fix_issue 611 OPEN "status:ready"; fix_issue 612 CLOSED "P1"; : > "$GH_LOG"
out=$(batch)
want "both tickets read, in the batch's own shape" "611 OPEN status:ready|612 CLOSED P1" \
  "$(jq -r '[.[] | "\(.number) \(.state) \(.labels | join(","))"] | join("|")' <<<"$out")"
want "through REST, one read a ticket" "2" "$(grep -c '^api repos/acme/widgets/issues/61[12]$' "$GH_LOG")"
want "and no GraphQL request" "0" "$(grep -c '^api graphql' "$GH_LOG")"
clean; mkdir -p "$STATE/swarm"; gh_here 4000; ghfleet 4000; : > "$GH_LOG"
batch >/dev/null
want "with GraphQL to spare, one batched GraphQL request as before" "1" "$(grep -c '^api graphql' "$GH_LOG")"
want "and no REST reads" "0" "$(grep -c '^api repos/' "$GH_LOG")"

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

echo "--- the other host's low GitHub reading holds starts and slows the sweeps here ---"
tickworld 0.05; ghfleet 100; GHR=$(( $(date +%s) + 1800 )); ghfleet 100
out=$(COORDINATOR_SHEET_OWNER=here COORDINATOR_REFRESH=1 live)
want "no start while Yomato reads 100 of 5000" "0" "$(grep -c . "$SPAWNS")"
want_in "the tick says why, and where it was read" "spawn: holding — GitHub's hourly API allowance is spent: GraphQL 100 of 5000 left until .*, as Yomato read it" "$out"
want_in "housekeeping waits for the reset" 'housekeeping: skipped until the allowance resets' "$out"
want_in "and the board refresh waits" 'queue: board refresh skipped' "$out"
tickworld 0.05; GHR=$(( $(date +%s) + 1800 )); ghfleet 4000
out=$(COORDINATOR_SHEET_OWNER=here live)
want "Yomato over the mark: the share starts again" "2" "$(grep -c . "$SPAWNS")"
want_not_in "and nothing waits" 'housekeeping: skipped' "$out"

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

suite_end "$FAILED"
