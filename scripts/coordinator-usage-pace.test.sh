#!/usr/bin/env bash
# coordinator-usage-pace.test.sh — the usage pacer: every host on the account
# burns one five-hour window, so the ceiling here is the builders the window
# affords until it resets, less the other hosts' live claims (coord_pace).
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
T="$HERE/coordinator-tick.sh"
Q="$HERE/coordinator-queue.sh"
C="$STATE/coordinator"
NOWE=$(date +%s)
# The projection alone, as #302 built it: the straight line has its own suite
# (coordinator-fleet-pace.test.sh), so here it sits out of reach.
export COORDINATOR_PACE_TARGET=0.95 COORDINATOR_PACE_HEADROOM=1 COORDINATOR_PACE_WEEK_HEADROOM=1

# <utilization> <reset epoch> [window] — one stream-json limit event, as the CLI writes it.
win() {
  jq -nc --argjson u "$1" --argjson r "$2" --arg w "${3:-five_hour}" \
    '{type:"rate_limit_event", rate_limit_info:{status:"allowed",
      unifiedWindows:({($w):{utilization:$u, resetsAt:$r}} + {seven_day:{utilization:0.5, resetsAt:($r + 400000)}})}}'
}
clean() { rm -rf "$C" "$STATE/logs"/* "$STATE/driver"; mkdir -p "$C"; }
# pace <here> <claim rows> — coord_pace in a fresh shell at SWARM_NOW=$NOWE.
pace() {
  ( export SWARM_NOW="$NOWE"; . "$HERE/coordinator-env.sh" >/dev/null 2>&1 || exit 9
    coord_pace "$1" "$2" here; echo " rc=$?" )
}

echo "--- the window's room, at the default burn ---"
clean; win 0.81 $((NOWE + 7200)) > "$STATE/logs/claim-1-a.log"
out=$(pace 1 "")
want "81% with 2h left at 2.5%/builder-hour affords 2" \
  "2	pace: 5h window 81%, resets $(swarm_iso $((NOWE + 7200)) | cut -c12-16)Z, 2.5%/builder-hour (default) → 2 across all hosts, 0 on other hosts → 2 here" \
  "${out%% · *}"
want "and it is read as a share" "rc=0" "${out##* }"
want "and the tick's reading is kept as a sample" "$NOWE	0.81	$((NOWE + 7200))	1" "$(cat "$C/pace.tsv")"

echo "--- other hosts' live claims come off this host's share ---"
clean; win 0.55 $((NOWE + 7200)) > "$STATE/logs/claim-1-a.log"
rows=$'7\tYomato\tbuild\n8\tYomato\t\n9\there\tbuild\n10\t\t'
out=$(pace 1 "$rows")
want "8 afforded, 2 on Yomato: 6 here (no-host and own rows are not another host's)" "6" "${out%%$'\t'*}"
want_in "the line names both" '→ 8 across all hosts, 2 on other hosts → 6 here' "$out"
want "and the sample counts every host's builders" "3" "$(cut -f4 "$C/pace.tsv")"
want "more claims elsewhere than the window affords: none here, never negative" "0" \
  "$(pace 0 "$(printf '%s\tYomato\t\n' 1 2 3 4 5 6 7 8 9 10)" | cut -f1)"

echo "--- the burn is measured from the samples within the same window ---"
clean; R=$((NOWE + 7200)); win 0.60 "$R" > "$STATE/logs/claim-1-a.log"
printf '%s\t0.40\t%s\t10\n%s\t0.50\t%s\t10\n' $((NOWE - 3600)) "$R" $((NOWE - 1800)) "$R" > "$C/pace.tsv"
out=$(pace 10 "")
# 0.20 over 10 builder-hours is 2%/builder-hour; (0.95 - 0.60) / (0.02 x 2h) = 8.75.
want_in "0.2 of the window over 10 builder-hours is 2.0%, measured" '2\.0%/builder-hour →' "$out"
want "and affords 8" "8" "${out%%$'\t'*}"

echo "--- a reset uses the default burn ---"
clean; R0=$((NOWE - 600)); R=$((NOWE + 17400)); win 0.04 "$R" > "$STATE/logs/claim-1-a.log"
printf '%s\t0.70\t%s\t10\n%s\t0.90\t%s\t10\n' $((NOWE - 3600)) "$R0" $((NOWE - 1800)) "$R0" > "$C/pace.tsv"
want_in "samples from the window before the reset are not this window's burn" '2\.5%/builder-hour \(default\)' "$(pace 4 "")"
clean; R=$((NOWE + 7200)); win 0.30 "$R" > "$STATE/logs/claim-1-a.log"
printf '%s\t0.60\t%s\t10\n%s\t0.40\t%s\t10\n' $((NOWE - 3600)) "$R" $((NOWE - 1800)) "$R" > "$C/pace.tsv"
want_in "utilization that fell inside one window is no burn" '\(default\)' "$(pace 4 "")"
clean; R=$((NOWE + 7200)); win 0.30 "$R" > "$STATE/logs/claim-1-a.log"
printf '%s\t0.20\t%s\t10\n' $((NOWE - 600)) "$R" > "$C/pace.tsv"
want_in "ten minutes of samples is too short to measure" '\(default\)' "$(pace 4 "")"

echo "--- where the reading comes from ---"
clean; mkdir -p "$STATE/driver/5/steps"; win 0.50 $((NOWE + 3600)) > "$STATE/driver/5/steps/build.log"
want_in "a driver run's step log carries it" 'window 50%' "$(pace 0 "")"
clean; win 0.50 $((NOWE + 3600)) seven_day > "$STATE/logs/claim-1-a.log"
want_in "only the seven-day window: nothing to pace on" 'no five-hour reading .* rc=1' "$(pace 0 "")"
clean; win 0.99 $((NOWE - 60)) > "$STATE/logs/claim-1-a.log"
want_in "a window already reset: nothing to pace on" 'no five-hour reading .* rc=1' "$(pace 0 "")"
clean; printf '%s\t0.70\t%s\t3\n' $((NOWE - 300)) $((NOWE + 3600)) > "$C/pace.tsv"
want_in "no log reading: the last sample of the open window" 'window 70%' "$(pace 0 "")"
clean
want_in "no logs and no samples: nothing to pace on" 'no five-hour reading .* rc=1' "$(pace 0 "")"
clean; win 0.97 $((NOWE + 3600)) > "$STATE/logs/claim-1-a.log"
want "at or over the target: no room anywhere" "0" "$(pace 0 "" | cut -f1)"
clean; win 0.10 $((NOWE + 3600)) > "$STATE/logs/claim-1-a.log"
want_in "switched off, it paces nothing" '^pace: off rc=1' "$(COORDINATOR_PACE=0 pace 0 "")"

echo "--- the tick's ceiling takes this host's share ---"
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
tickworld() { # <other-host claims> — one live builder here at 81% with 2h left, three ready tickets
  clean; rm -rf "$STATE/runs"/*; : > "$SPAWNS"; printf '[]\n' > "$FIX/gh/prs-all.json"
  win 0.81 $(( $(date +%s) + 7200 )) > "$STATE/logs/claim-500-live.log"
  printf '{"run_id":"claim-500-live","ticket":"500","child_pid":%s,"log":"%s"}\n' "$$" "$STATE/logs/claim-500-live.log" \
    > "$STATE/runs/claim-500-live.json"
  { printf '500\there\tbuild\n'; local i=0; while [ "$i" -lt "$1" ]; do i=$((i+1)); printf '%s\tYomato\tbuild\n' $((700 + i)); done; } > "$FIX/claims.txt"
  local t; for t in 601 602 603; do fix_issue "$t" OPEN "status:ready"; bash "$Q" add "$t" >/dev/null; done
}
live() { SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" 2>&1; }
tickworld 1; out=$(live)
want "2 afforded, 1 on Yomato, 1 running here: nothing starts" "0" "$(grep -c . "$SPAWNS")"
want_in "and the tick log says why" 'pace: 5h window 81%.* → 2 across all hosts, 1 on other hosts → 1 here' "$(cat "$C/tick.log")"
tickworld 0; out=$(live)
want "nothing on other hosts: one more starts here" "1" "$(grep -c . "$SPAWNS")"
tickworld 1; out=$(COORDINATOR_PACE=0 live)
want "unpaced, the machine alone fills all three" "3" "$(grep -c . "$SPAWNS")"
tickworld 3; out=$(live)
want "other hosts over the share never stop the builder running here" "0" "$(grep -c . "$SPAWNS")"
want_in "the ceiling still counts it" 'ceiling: 1 running · no room for more' "$out"

exit $FAILED
