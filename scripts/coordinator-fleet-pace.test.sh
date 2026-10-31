#!/usr/bin/env bash
# coordinator-fleet-pace.test.sh — the fleet's shared readings. Every host builds on one
# plan, so they share one five-hour window and one GitHub allowance: each host reads the
# freshest of every host's readings, publishes its own in its heartbeat, and holds on
# either. The five-hour line itself has its own suite (coordinator-usage-pace.test.sh).
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
unset COORDINATOR_PACE COORDINATOR_PACE_FACTOR COORDINATOR_PACE_EXEMPT
# The pacer is off by default since Claude dropped the five-hour limit (2026-10-31);
# these cases test the pacer itself, so they switch it on.
COORDINATOR_PACE=true; export COORDINATOR_PACE
# Its hold cases read a five-hour reading, so the five-hour window holds here too.
SWARM_USAGE_WINDOWS="five_hour seven_day"; export SWARM_USAGE_WINDOWS

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

# The owner: the reader's fresh heartbeat in fleet.json.
fleet() { # <yomato capacity> <yomato tick> [yomato 5h use]
  jq -nc --argjson c "$1" --argjson t "$2" --arg u "${3:-}" --argjson r "$EARLY" \
    '{hosts:[{host:"yomato", capacity:$c, builds:0, tick:$t}
             + (if $u == "" then {} else {usage:{five_hour:{u:($u|tonumber), reset:$r}}} end)]}' > "$C/fleet.json"
}
reader() { ( export SHEET_PACE='{"settings":{"factor":0.95}}' COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=yomato; pace "$@" ); }

echo "--- the freshest reading wins, from either host ---"
clean; win 0.05 "$EARLY" > "$STATE/logs/claim-1-a.log"
out=$( export SHEET_FLEET='[{"host":"here","tick":'"$NOWE"',"usage":{"five_hour":{"u":0.40,"reset":'"$EARLY"'}}}]'; reader 0 "" 14 )
want_in "the owner's heartbeat at 40% outranks this host's 5%" '5h window 40%' "$out"
want_in "it is ahead of the line by the same rule" 'pacing: ahead' "$out"
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

echo "--- the sheet carries the reading and the factor to the readers ---"
entries='{"order":[],"building":[],"pace":{"at":1,"usage":{"five_hour":{"u":0.4,"reset":2}},"fiveHour":{"line":0.33},"pacing":"ahead","settings":{"factor":0.95,"exempt":["P0"]}}}'
body=$( . "$HERE/coordinator-env.sh" >/dev/null 2>&1; . "$HERE/coordinator-sheet.sh" >/dev/null 2>&1; coord_sheet_render "$entries" "$NOWE" )
want_in "a person reads it" 'Pacing ahead: five-hour window 40% against a target of 33% · no new builder starts on any machine but P0' "$body"
want "and a reader parses the factor back" '0.95' \
  "$(printf '%s\n' "$body" | sed -nE 's/^<!-- sheet:pace (\{.*\}) -->$/\1/p' | jq -c '.settings.factor')"

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

echo "--- the tick: the owner fills while behind the line ---"
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
want "behind the line, the owner fills all five its CPU fits" "5" "$(grep -c . "$SPAWNS")"
want_in "the tick log says behind" 'pacing: behind — 5h window 5% against a target of 10%' "$(cat "$C/tick.log")"
tickworld 0.05; fleet 14 "$(date +%s)" 0.40
out=$(COORDINATOR_SHEET_OWNER=here live)
want "the reader's fresher 40% puts the owner ahead: nothing new" "0" "$(grep -c . "$SPAWNS")"

echo "--- the other host's low GitHub reading holds starts and slows the sweeps here ---"
tickworld 0.05; ghfleet 100; GHR=$(( $(date +%s) + 1800 )); ghfleet 100
out=$(COORDINATOR_SHEET_OWNER=here COORDINATOR_REFRESH=1 live)
want "no start while Yomato reads 100 of 5000" "0" "$(grep -c . "$SPAWNS")"
want_in "the tick says why, and where it was read" "spawn: holding — GitHub's hourly API allowance is spent: GraphQL 100 of 5000 left until .*, as Yomato read it" "$out"
want_in "housekeeping waits for the reset" 'housekeeping: skipped until the allowance resets' "$out"
want_in "and the board refresh waits" 'queue: board refresh skipped' "$out"
tickworld 0.05; GHR=$(( $(date +%s) + 1800 )); ghfleet 4000
out=$(COORDINATOR_SHEET_OWNER=here live)
want "Yomato over the mark: places fill again" "5" "$(grep -c . "$SPAWNS")"
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
