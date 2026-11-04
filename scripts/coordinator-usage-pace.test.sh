#!/usr/bin/env bash
# coordinator-usage-pace.test.sh — pacing to the five-hour window (coord_pace): every host
# burns the same window, so each tick draws a straight line to factor x 100% at its reset.
# Ahead (u > elapsed x factor) no new builder starts but process fixes and an exempt
# priority — the focus tier waits too; behind, or with no reading, places fill. The weekly
# line paces only with coordinator.paceToWindow.week (owner, 2026-11-04: "usage is only
# important if i have the 5 hour session"). A window with no reading is not paced on.
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
unset COORDINATOR_PACE COORDINATOR_PACE_FACTOR COORDINATOR_PACE_WEEK COORDINATOR_PACE_WEEK_FACTOR COORDINATOR_PACE_EXEMPT
# The pacer is off by default since Claude dropped the five-hour limit (2026-10-31);
# these cases test the pacer itself, so they switch it on.
COORDINATOR_PACE=true; export COORDINATOR_PACE

# <5h use> <5h reset> [7d use] [7d reset] — one stream-json limit event, as the CLI writes it.
win() {
  jq -nc --argjson u "$1" --argjson r "$2" --argjson u7 "${3:-0.10}" --argjson r7 "${4:-$(( $2 + 400000 ))}" \
    '{type:"rate_limit_event", rate_limit_info:{status:"allowed",
      unifiedWindows:{five_hour:{utilization:$u, resetsAt:$r}, seven_day:{utilization:$u7, resetsAt:$r7}}}}'
}
# <7d use> <7d reset> — a limit event that carries the seven-day window alone.
win7() {
  jq -nc --argjson u7 "$1" --argjson r7 "$2" \
    '{type:"rate_limit_event", rate_limit_info:{status:"allowed", unifiedWindows:{seven_day:{utilization:$u7, resetsAt:$r7}}}}'
}
WEEK58=$(( NOWE + 254016 ))  # 42% of the week left: 58% gone, the weekly line at 58% x 0.95 = 55%
clean() { rm -rf "$C" "$STATE/logs"/* "$STATE/driver"; mkdir -p "$C"; }
# pace <here> <claim rows> — coord_pace in a fresh shell at SWARM_NOW=$NOWE.
pace() {
  ( export SWARM_NOW="$NOWE"; . "$HERE/coordinator-env.sh" >/dev/null 2>&1 || exit 9
    . "$HERE/coordinator-sheet.sh" >/dev/null 2>&1 || exit 9
    coord_pace "$1" "$2" "${COORDINATOR_HOST:-here}"; echo " rc=$?" )
}

echo "--- the line: elapsed share of the window x 0.95 ---"
# Measured 2026-10-23: 49% used 1 h 45 min into the window. 35% gone x 0.95 = 33%: ahead.
clean; win 0.49 $((NOWE + 11700)) > "$STATE/logs/claim-1-a.log"
out=$(pace 2 "")
want "49% at 35% of the window is ahead"     "1" "${out%%$'\t'*}"
want_in "and the line says so, with u and the target" 'pacing: ahead — 5h window 49% against a target of 33% \(35% of the window gone x 0.95' "$out"
want_in "and that only process fixes start"  'no new builder starts but process fixes; the running ones carry on' "$out"
want "pace.json names the five-hour window"  "five_hour" "$(jq -r '.window' "$C/pace.json")"
want "pace.json says ahead"                  "ahead true 0.3325" "$(jq -r '"\(.pacing) \(.fiveHour.ahead) \(.fiveHour.line)"' "$C/pace.json")"
want "and keeps the sample"                  "$NOWE	0.49	$((NOWE + 11700))	2" "$(cat "$C/pace.tsv")"
clean; win 0.30 $((NOWE + 11700)) > "$STATE/logs/claim-1-a.log"
out=$(pace 2 "")
want "30% at the same point is behind"       "0" "${out%%$'\t'*}"
want_in "and places fill"                    'pacing: behind — 5h window 30% against a target of 33%.*: places fill' "$out"
want "pace.json says behind"                 "behind" "$(jq -r '.pacing' "$C/pace.json")"
clean; win 0.90 $((NOWE + 60)) > "$STATE/logs/claim-1-a.log"
want "90% a minute from the reset: behind (the line is at 95%)" "0" "$(pace 0 "" | cut -f1)"
clean; win 0.33 $((NOWE + 11700)) > "$STATE/logs/claim-1-a.log"
want "exactly on the line is behind"         "0" "$(pace 0 "" | cut -f1)"
clean; win 0.34 $((NOWE + 11700)) > "$STATE/logs/claim-1-a.log"
want "34% against 0.95's 33%: ahead"         "1" "$(pace 0 "" | cut -f1)"
want "a factor of 1 draws the line at 35%: behind" "0" "$(COORDINATOR_PACE_FACTOR=1 pace 0 "" | cut -f1)"
want "a factor out of range falls back to 0.95: ahead" "1" "$(COORDINATOR_PACE_FACTOR=7 pace 0 "" | cut -f1)"

echo "--- the week paces nothing by default: only the five-hour window (owner, 2026-11-04) ---"
clean; win 0.10 $((NOWE + 11700)) 0.62 "$WEEK58" > "$STATE/logs/claim-1-a.log"
out=$(pace 0 "")
want "the week ahead, the five hours behind, week unset: behind" "0" "${out%%$'\t'*}"
want_in "  and the line names only the five hours" '^0	pacing: behind — 5h window 10% against a target of 33%[^;]*: places fill rc=0' "$out"
want "  pace.json carries no week verdict, but keeps the week's reading" "behind null 0.62 false" \
  "$(jq -r '"\(.pacing) \(.week) \(.usage.seven_day.u) \(.settings.week)"' "$C/pace.json")"
want "week=false says the same" "0" "$(COORDINATOR_PACE_WEEK=false pace 0 "" | cut -f1)"
clean; win 0.49 $((NOWE + 11700)) 0.10 "$WEEK58" > "$STATE/logs/claim-1-a.log"
want "the five hours ahead, week unset: ahead, as before" "1" "$(pace 0 "" | cut -f1)"
clean; win7 0.62 "$WEEK58" > "$STATE/logs/claim-1-a.log"
out=$(pace 0 "")
want_in "no five-hour reading, the week ahead, week unset: places fill (fail open)" 'pacing: no five-hour usage reading — places fill.* rc=1' "$out"
want "  and the week's reading still rides in pace.json, with no verdict" "0.62 null" "$(jq -r '"\(.usage.seven_day.u) \(.pacing)"' "$C/pace.json")"

echo "--- with paceToWindow.week the seven-day window paces on the same line ---"
COORDINATOR_PACE_WEEK=true; export COORDINATOR_PACE_WEEK
clean; win 0.10 $((NOWE + 11700)) 0.62 "$WEEK58" > "$STATE/logs/claim-1-a.log"
out=$(pace 0 "")
want "the week ahead, the five hours behind: ahead" "1" "${out%%$'\t'*}"
want_in "and the line leads with the week" 'pacing: ahead — week 62% against a target of 55% \(58% of the week gone x 0.95, resets [0-9-]+ [0-9:]+Z\); 5h window 10% against a target of 33%.*: no new builder starts but process fixes' "$out"
want "pace.json names the week, its line and the factor" "week true 551 0.95" "$(jq -r '"\(.window) \(.week.ahead) \(.week.line * 1000 | round) \(.settings.weekFactor)"' "$C/pace.json")"
want "and keeps the week's reading for the heartbeat" "0.62" "$(jq -r '.usage.seven_day.u' "$C/pace.json")"
clean; win 0.10 $((NOWE + 11700)) 0.50 "$WEEK58" > "$STATE/logs/claim-1-a.log"
out=$(pace 0 "")
want "the week behind and the five hours behind: behind" "0" "${out%%$'\t'*}"
want_in "and places fill"                    'pacing: behind — 5h window 10% against a target of 33%.*; week 50% against a target of 55%.*: places fill' "$out"
want "a weekFactor of 0.8 draws the week's line at 46%: 50% is ahead" "1" "$(COORDINATOR_PACE_WEEK_FACTOR=0.8 pace 0 "" | cut -f1)"
want "a weekFactor out of range falls back to 0.95: behind" "0" "$(COORDINATOR_PACE_WEEK_FACTOR=2 pace 0 "" | cut -f1)"
clean; win 0.49 $((NOWE + 11700)) 0.62 "$WEEK58" > "$STATE/logs/claim-1-a.log"
out=$(pace 0 "")
want "both ahead: pace.json says both" "both" "$(jq -r '.window' "$C/pace.json")"
want_in "and the five hours lead the line" 'pacing: ahead — 5h window 49%.*; week 62%' "$out"
clean; win7 0.62 "$WEEK58" > "$STATE/logs/claim-1-a.log"
out=$(pace 0 "")
want_in "no five-hour reading: the week alone paces" 'pacing: ahead — week 62% against a target of 55%.* rc=0' "$out"
want "  with no five-hour verdict written" "null" "$(jq -c '.fiveHour' "$C/pace.json")"
clean; win 0.99 $((NOWE - 60)) 0.10 "$WEEK58" > "$STATE/logs/claim-1-a.log"
out=$(pace 0 "")
want_in "the five hours reset: not paced on, the week alone (behind)" '^0	pacing: behind — week 10% against a target of 55%[^;]*: places fill rc=0' "$out"
clean; win 0.05 $((NOWE + 11700)) 0.50 "$WEEK58" > "$STATE/logs/claim-1-a.log"
out=$( export COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=yomato SHEET_PACE='{"settings":{"factor":0.95,"weekFactor":0.8}}'; pace 0 "" )
want "the reader paces the week by the owner's weekFactor: 50% over 58% x 0.8" "1" "${out%%$'\t'*}"
clean
want_in "no reading at all, week on: the old words" 'pacing: no usage reading \(five-hour or week\) — places fill.* rc=1' "$(pace 0 "")"
unset COORDINATOR_PACE_WEEK

echo "--- no reading fails open: places fill ---"
clean
out=$(pace 0 "")
want_in "no logs and no samples"             'pacing: no five-hour usage reading — places fill.* rc=1' "$out"
want "and no verdict is left for the tick"   "absent" "$([ -f "$C/pace.json" ] && echo present || echo absent)"
clean; win 0.50 $((NOWE + 3600)) > "$STATE/logs/claim-1-a.log"
want_in "switched off, it paces nothing"     'pacing: off .* rc=1' "$(COORDINATOR_PACE=false pace 0 "")"
want_in "unset, it is on (not every plan dropped the five-hour limit)" 'pacing: behind .* rc=0' "$(unset COORDINATOR_PACE; pace 0 "")"

echo "--- a reset rolls the line over ---"
clean; win 0.99 $((NOWE - 60)) 0.99 $((NOWE - 30)) > "$STATE/logs/claim-1-a.log"
want_in "both windows already reset are no reading: fail open" 'no five-hour usage reading .* rc=1' "$(pace 0 "")"
clean; { win 0.99 $((NOWE - 60)); win 0.03 $((NOWE + 17400)); } > "$STATE/logs/claim-1-a.log"
out=$(pace 0 "")
want_in "the new window's reading is the one read" '5h window 3% against a target of 3% \(3% of the window gone' "$out"
want "3% used 10 minutes in is on the line: behind" "0" "${out%%$'\t'*}"
clean; printf '%s\t0.97\t%s\t3\n%s\t0.10\t%s\t3\n' $((NOWE - 900)) $((NOWE - 60)) $((NOWE - 300)) $((NOWE + 7200)) > "$C/pace.tsv"
out=$(pace 0 "")
want_in "no log: the last sample of the open window, not the one that reset" '5h window 10%' "$out"

echo "--- no seven-day reading paces on the five-hour window alone ---"
clean; jq -nc --argjson r $((NOWE + 11700)) '{type:"rate_limit_event", rate_limit_info:{status:"allowed", unifiedWindows:{five_hour:{utilization:0.49, resetsAt:$r}}}}' > "$STATE/logs/claim-1-a.log"
out=$(pace 0 "")
want_in "five hours ahead, no week read: ahead, the line names only the five hours" '^1	pacing: ahead — 5h window 49% against a target of 33%[^;]*: no new builder' "$out"
want "  and pace.json carries no week" "null null" "$(jq -c '[.week, .usage.seven_day] | map(tostring) | join(" ")' -r "$C/pace.json")"
clean; jq -nc --argjson r $((NOWE + 11700)) '{type:"rate_limit_event", rate_limit_info:{status:"allowed", unifiedWindows:{five_hour:{utilization:0.20, resetsAt:$r}}}}' > "$STATE/logs/claim-1-a.log"
want "five hours behind, no week read: behind" "0" "$(pace 0 "" | cut -f1)"

echo "--- every host draws the same line ---"
clean; win 0.05 $((NOWE + 11700)) > "$STATE/logs/claim-1-a.log"
out=$( export SHEET_FLEET='[{"host":"here","tick":'"$NOWE"',"usage":{"five_hour":{"u":0.40,"reset":'"$((NOWE + 11700))"',"at":'"$NOWE"'}}}]' \
              COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=yomato SHEET_PACE='{"settings":{"factor":0.95}}'; pace 0 "" )
want_in "the reader takes the owner's fresher 40%" '5h window 40%' "$out"
want "and is ahead by the same rule"         "1" "${out%%$'\t'*}"
clean; win 0.30 $((NOWE + 11700)) > "$STATE/logs/claim-1-a.log"
out=$( export COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=yomato SHEET_PACE='{"settings":{"factor":0.5}}'; pace 0 "" )
want "the reader paces by the owner's factor: 30% over 35% x 0.5" "1" "${out%%$'\t'*}"

echo "--- the tick: ahead of either window holds, behind both fills, process fixes start ---"
printf '#!/usr/bin/env bash\n:\n' > "$BIN/judge"; chmod +x "$BIN/judge"
for s in reconcile sweep wtsweep; do printf '#!/usr/bin/env bash\n:\n' > "$BIN/$s"; chmod +x "$BIN/$s"; done
export COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep" COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep"
export COORDINATOR_JUDGE="$BIN/judge" COORDINATOR_NOTIFY_CMD=true COORDINATOR_HOST=here
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
export COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0
unset COORDINATOR_SHADOW COORDINATOR_CAP SWARM_NOW
export SWARM_FREE_MEM_GB=16 SWARM_IDLE=90 SWARM_CORES=10
cat > "$BIN/spawn-live" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SPAWNS"
SH
chmod +x "$BIN/spawn-live"
tickworld() { # <5h use or -> [P0 ticket] — 1 h 45 min into the window, three ready tickets; TW_WEEK=<7d use> sets the week, 58% gone
  clean; rm -rf "$STATE/runs"/*; : > "$SPAWNS"; printf '[]\n' > "$FIX/gh/prs-all.json"; : > "$FIX/claims.txt"
  [ "$1" = - ] || win "$1" $(( $(date +%s) + 11700 )) "${TW_WEEK:-0.10}" $(( $(date +%s) + 254016 )) > "$STATE/logs/claim-1-a.log"
  local t; for t in 601 602 603; do fix_issue "$t" OPEN "status:ready,P2"; bash "$Q" add "$t" >/dev/null; done
  [ -z "${2:-}" ] || { fix_issue "$2" OPEN "status:ready,P0"; bash "$Q" add "$2" >/dev/null; }
}
live() { SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" 2>&1; }
tickworld 0.49; out=$(live)
want "ahead: nothing new starts"             "0" "$(grep -c . "$SPAWNS")"
want_in "the tick log says pacing ahead, with u and the target" 'pacing: ahead — 5h window 49% against a target of 3[23]%' "$(cat "$C/tick.log")"
want_in "and names who waits"                'skip #601 #602 #603: pacing ahead of the five-hour line — no new builder starts but process fixes$' "$(printf '%s\n' "$out" | grep 'skip #601')"
want "the live view's capacity carries it"   "ahead true" "$(jq -r '"\(.pace.pacing) \(.pace.fiveHour.ahead)"' "$C/capacity.json")"
# Ahead, the focus-area tier waits like the rest (owner, 2026-11-03): it is where the work is,
# so exempting it paced nothing.
FOCUS='[{"name":"Voices","labels":["area:VOICES"]}]'
tickworld 0.49 604; fix_issue 606 OPEN "status:ready,P1,area:VOICES"; bash "$Q" add 606 >/dev/null
out=$(COORDINATOR_SCREENS_FIRST=true COORDINATOR_FOCUS_AREAS="$FOCUS" live)
want "ahead: neither a focus-area P1 nor a non-focus P0 starts" "" "$(tr '\n' ' ' < "$SPAWNS" | sed 's/ $//')"
want_in "  and both are named as waiting"      'skip [#0-9 ]*#60[46][#0-9 ]*#60[46][#0-9 ]*: pacing ahead' "$out"
TW_WEEK=0.62 tickworld 0.10; out=$(live)
want "the week ahead, the five hours behind, week unset: places fill, all three" "3" "$(grep -c . "$SPAWNS")"
want "  and the live view says behind" "behind" "$(jq -r '.pace.pacing' "$C/capacity.json")"
TW_WEEK=0.62 tickworld 0.10; out=$(COORDINATOR_PACE_WEEK=true live)
want "the same with week=true: nothing new starts" "0" "$(grep -c . "$SPAWNS")"
want_in "  and the skip names the weekly line" 'skip #601 #602 #603: pacing ahead of the weekly line — no new builder starts but process fixes' "$out"
want "  and the live view carries the week" "ahead week true" "$(jq -r '"\(.pace.pacing) \(.pace.window) \(.pace.week.ahead)"' "$C/capacity.json")"
TW_WEEK=0.62 tickworld 0.10; fix_issue 605 OPEN "status:ready,P2,process"; bash "$Q" add 605 >/dev/null; out=$(COORDINATOR_PACE_WEEK=true live)
want "the week ahead: a process fix still starts, alone" "605" "$(tr '\n' ' ' < "$SPAWNS" | sed 's/ $//')"
TW_WEEK=0.50 tickworld 0.10; out=$(COORDINATOR_PACE_WEEK=true live)
want "both behind: places fill, all three" "3" "$(grep -c . "$SPAWNS")"
tickworld 0.49 604; out=$(COORDINATOR_PACE_EXEMPT=P0 live)
want "a priority in paceToWindow.exempt still starts" "604" "$(tr '\n' ' ' < "$SPAWNS" | sed 's/ $//')"
tickworld 0.49; fix_issue 605 OPEN "status:ready,P2,process"; bash "$Q" add 605 >/dev/null; out=$(live)
want "ahead: a process fix still starts, alone, though it is P2" "605" "$(tr '\n' ' ' < "$SPAWNS" | sed 's/ $//')"
tickworld 0.49; out=$(COORDINATOR_PACE_EXEMPT="" live)
want "with nothing exempt, not even P0 waits — none queued, none start" "0" "$(grep -c . "$SPAWNS")"
tickworld 0.20; out=$(live)
want "behind: places fill, all three"        "3" "$(grep -c . "$SPAWNS")"
want "the live view says behind"             "behind" "$(jq -r '.pace.pacing' "$C/capacity.json")"
tickworld -; out=$(live)
want "no usage reading: fail open, all three" "3" "$(grep -c . "$SPAWNS")"
want_in "and says why"                       'pacing: no five-hour usage reading — places fill' "$out"
tickworld 0.49; out=$(COORDINATOR_PACE=0 live)
want "pacing off: the machine fills all three" "3" "$(grep -c . "$SPAWNS")"

suite_end "$FAILED"
