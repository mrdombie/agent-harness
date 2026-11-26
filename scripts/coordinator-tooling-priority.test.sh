#!/usr/bin/env bash
# coordinator-tooling-priority.test.sh — a P0 harness fix is never held behind P1 product
# builds by a tooling cap that has room. Only a tooling row that takes a free place spends
# the cap; with every place full the skip line says the places are held, and by what.
# At one priority product still goes before tooling.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
# A live coordinator's env points the tick at the real runs dir.
for v in RUNS_DIR STATE_DIR DRIVER_DIR CLAIM_RUN_LOG PR_RED_REQ_FILE $(env | sed -nE 's/^((SWARM|COORDINATOR|COORD|HARNESS)_[A-Z_]*)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
T="$HERE/coordinator-tick.sh"
Q="$HERE/coordinator-queue.sh"
C="$STATE/coordinator"

for s in reconcile sweep wtsweep claude notify; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$s"; chmod +x "$BIN/$s"; done
cat > "$BIN/diskguard" <<'SH'
#!/usr/bin/env bash
case "$1" in tick) printf '500\tdisk: 500 GB free\n' ;; limits) echo "30 50" ;; free) echo 500 ;; esac
SH
chmod +x "$BIN/diskguard"
printf '%s\n' 'live_view_watchdog() { :; }' > "$FIX/watchdog-stub.sh"
export COORDINATOR_DISK_GUARD="$BIN/diskguard" COORDINATOR_LIVE_VIEW_WATCHDOG="$FIX/watchdog-stub.sh"
export COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep"
export COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep" COORDINATOR_CLAUDE="$BIN/claude" COORDINATOR_NOTIFY_CMD="$BIN/notify"
export COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0 COORDINATOR_HOST=here
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
unset COORDINATOR_SHADOW COORDINATOR_CAP COORDINATOR_START_CPU_IDLE COORDINATOR_MIN_FREE_MEM_GB COORDINATOR_PACE
unset COORDINATOR_OPEN_PR_CAP COORDINATOR_RELEASE_SCOPE_ONLY COORDINATOR_TOOLING_CAP COORDINATOR_TOOLING_CAP_LABELS
export SWARM_FREE_MEM_GB=16 TEST_PID=$$
cat > "$BIN/spawn-live" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SPAWNS"
SH
chmod +x "$BIN/spawn-live"

fresh() { rm -rf "$C" "$STATE/runs"/* "$STATE/swarm/HOLD"; : > "$SPAWNS"; : > "$FIX/claims.txt"; printf '[]\n' > "$FIX/gh/prs-all.json"; }
run_here() { # <ticket> <labels> — a live builder on this host
  fix_issue "$1" OPEN "$2"
  printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s}\n' "$1" "$1" "$TEST_PID" > "$STATE/runs/claim-$1-live.json"
  printf '%s\there\tbuild\n' "$1" >> "$FIX/claims.txt"
}
ready() { local l="$1" t; shift; for t in "$@"; do fix_issue "$t" OPEN "$l"; bash "$Q" add "$t" >/dev/null; done; }
tick() { SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 SWARM_IDLE=90 SWARM_CORES=10 COORDINATOR_TOOLING_CAP=4 COORDINATOR_CAP="$1" bash "$T" 2>&1; }
spawned() { tr '\n' ' ' < "$SPAWNS" | sed 's/ $//'; }

echo "--- cap 2, two P1 product builds live, one tooling run elsewhere, process fixes and P0 harness fixes ready ---"
fresh; run_here 600 "P1,status:in-progress"; run_here 601 "P1,status:in-progress"
fix_issue 700 OPEN "process,status:in-progress"; printf '700\tYomato\tbuild\n' >> "$FIX/claims.txt"
ready "process,status:ready" 901 902 903
ready "P0,project:harness-kit,status:ready" 801 802 803 804; ready "P1,status:ready" 701
out=$(tick 2)
want "both places are full: nothing starts" "" "$(spawned)"
want_in "1 of the 4 tooling places is used" 'tooling: 1 live of the cap of 4 on every host \(#700\)' "$out"
want_not_in "no skip line cites a tooling cap with room" 'the tooling cap|places go to product work' "$out"
want_in "the skip line says the places are held, and by what" \
  'skip #803 #804 #701: all 2 place\(s\) are held — 2 by product work, 0 by tooling \(#600 #601\)' "$out"

echo "--- a place frees: the P0 harness fix takes it, ahead of the queued P1 ---"
fresh; run_here 600 "P1,status:in-progress"
ready "P0,project:harness-kit,status:ready" 801 802 803 804; ready "P1,status:ready" 701
out=$(tick 2)
want "the P0 harness fix starts" "801" "$(spawned)"

echo "--- at one priority product still goes before tooling ---"
fresh; ready "P1,project:harness-kit,status:ready" 811; ready "P1,status:ready" 711
out=$(tick 1)
want "the P1 product ticket starts, the P1 harness one waits" "711" "$(spawned)"

suite_end "$FAILED"
