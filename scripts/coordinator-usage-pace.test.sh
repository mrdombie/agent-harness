#!/usr/bin/env bash
# coordinator-usage-pace.test.sh — pacing to the five-hour window (coord_pace): every host
# burns one window, so each tick draws a straight line to factor x 100% at the reset.
# Ahead of it (u > elapsed x factor) no new builder starts but an exempt priority (P0);
# behind it, or with no reading, places fill. The seven-day window is never paced on.
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
unset COORDINATOR_PACE COORDINATOR_PACE_FACTOR COORDINATOR_PACE_EXEMPT

# <5h use> <5h reset> [7d use] — one stream-json limit event, as the CLI writes it.
win() {
  jq -nc --argjson u "$1" --argjson r "$2" --argjson u7 "${3:-0.10}" \
    '{type:"rate_limit_event", rate_limit_info:{status:"allowed",
      unifiedWindows:{five_hour:{utilization:$u, resetsAt:$r}, seven_day:{utilization:$u7, resetsAt:($r + 400000)}}}}'
}
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
want_in "and that only the exempt start"     'no new builder starts but P0; the running ones carry on' "$out"
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

echo "--- the seven-day window never paces ---"
clean; win 0.20 $((NOWE + 11700)) 0.99 > "$STATE/logs/claim-1-a.log"
want "the week at 99%, the five hours behind: behind" "0" "$(pace 0 "" | cut -f1)"
want "the week is still read for the heartbeat" "0.99" "$(jq -r '.usage.seven_day.u' "$C/pace.json")"

echo "--- no reading fails open: places fill ---"
clean
out=$(pace 0 "")
want_in "no logs and no samples"             'pacing: no five-hour reading — places fill.* rc=1' "$out"
want "and no verdict is left for the tick"   "absent" "$([ -f "$C/pace.json" ] && echo present || echo absent)"
clean; win 0.50 $((NOWE + 3600)) > "$STATE/logs/claim-1-a.log"
want_in "switched off, it paces nothing"     'pacing: off .* rc=1' "$(COORDINATOR_PACE=false pace 0 "")"

echo "--- a reset rolls the line over ---"
clean; win 0.99 $((NOWE - 60)) > "$STATE/logs/claim-1-a.log"
want_in "a window already reset is no reading: fail open" 'no five-hour reading .* rc=1' "$(pace 0 "")"
clean; { win 0.99 $((NOWE - 60)); win 0.03 $((NOWE + 17400)); } > "$STATE/logs/claim-1-a.log"
out=$(pace 0 "")
want_in "the new window's reading is the one read" '5h window 3% against a target of 3% \(3% of the window gone' "$out"
want "3% used 10 minutes in is on the line: behind" "0" "${out%%$'\t'*}"
clean; printf '%s\t0.97\t%s\t3\n%s\t0.10\t%s\t3\n' $((NOWE - 900)) $((NOWE - 60)) $((NOWE - 300)) $((NOWE + 7200)) > "$C/pace.tsv"
out=$(pace 0 "")
want_in "no log: the last sample of the open window, not the one that reset" '5h window 10%' "$out"

echo "--- every host draws the same line ---"
clean; win 0.05 $((NOWE + 11700)) > "$STATE/logs/claim-1-a.log"
out=$( export SHEET_FLEET='[{"host":"here","tick":'"$NOWE"',"usage":{"five_hour":{"u":0.40,"reset":'"$((NOWE + 11700))"',"at":'"$NOWE"'}}}]' \
              COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=yomato SHEET_PACE='{"settings":{"factor":0.95}}'; pace 0 "" )
want_in "the reader takes the owner's fresher 40%" '5h window 40%' "$out"
want "and is ahead by the same rule"         "1" "${out%%$'\t'*}"
clean; win 0.30 $((NOWE + 11700)) > "$STATE/logs/claim-1-a.log"
out=$( export COORDINATOR_SHEET_OWNER=here COORDINATOR_HOST=yomato SHEET_PACE='{"settings":{"factor":0.5}}'; pace 0 "" )
want "the reader paces by the owner's factor: 30% over 35% x 0.5" "1" "${out%%$'\t'*}"

echo "--- the tick: ahead holds, behind fills, P0 is exempt ---"
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
tickworld() { # <5h use or -> [P0 ticket] — 1 h 45 min into the window, three ready tickets
  clean; rm -rf "$STATE/runs"/*; : > "$SPAWNS"; printf '[]\n' > "$FIX/gh/prs-all.json"; : > "$FIX/claims.txt"
  [ "$1" = - ] || win "$1" $(( $(date +%s) + 11700 )) > "$STATE/logs/claim-1-a.log"
  local t; for t in 601 602 603; do fix_issue "$t" OPEN "status:ready,P2"; bash "$Q" add "$t" >/dev/null; done
  [ -z "${2:-}" ] || { fix_issue "$2" OPEN "status:ready,P0"; bash "$Q" add "$2" >/dev/null; }
}
live() { SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" 2>&1; }
tickworld 0.49; out=$(live)
want "ahead: nothing new starts"             "0" "$(grep -c . "$SPAWNS")"
want_in "the tick log says pacing ahead, with u and the target" 'pacing: ahead — 5h window 49% against a target of 3[23]%' "$(cat "$C/tick.log")"
want_in "and names who waits"                'skip #601 #602 #603: pacing ahead of the five-hour line — no new builder starts but P0' "$out"
want "the live view's capacity carries it"   "ahead true" "$(jq -r '"\(.pace.pacing) \(.pace.fiveHour.ahead)"' "$C/capacity.json")"
tickworld 0.49 604; out=$(live)
want "ahead: a P0 still starts, alone"       "604" "$(tr '\n' ' ' < "$SPAWNS" | sed 's/ $//')"
tickworld 0.49; out=$(COORDINATOR_PACE_EXEMPT="" live)
want "with nothing exempt, not even P0 waits — none queued, none start" "0" "$(grep -c . "$SPAWNS")"
tickworld 0.20; out=$(live)
want "behind: places fill, all three"        "3" "$(grep -c . "$SPAWNS")"
want "the live view says behind"             "behind" "$(jq -r '.pace.pacing' "$C/capacity.json")"
tickworld -; out=$(live)
want "no usage reading: fail open, all three" "3" "$(grep -c . "$SPAWNS")"
want_in "and says why"                       'pacing: no five-hour reading — places fill' "$out"
tickworld 0.49; out=$(COORDINATOR_PACE=0 live)
want "pacing off: the machine fills all three" "3" "$(grep -c . "$SPAWNS")"

suite_end "$FAILED"
