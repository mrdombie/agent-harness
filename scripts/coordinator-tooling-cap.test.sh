#!/usr/bin/env bash
# coordinator-tooling-cap.test.sh — tooling never takes every place. Owner call
# 2026-10-22: tooling builders capped at 2, so product builders get the usage back.
#   - coordinator.toolingCap: process and harness runs, on every host together, never over it.
# (The product floor that sat beside it went with the budget pacer, 2026-10-23: pacing is
# now one five-hour line, coordinator-usage-pace.test.sh.)
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
unset COORDINATOR_PACE COORDINATOR_PACE_FACTOR COORDINATOR_TOOLING_CAP SWARM_USAGE_CEILING

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

suite_end "$FAILED"
