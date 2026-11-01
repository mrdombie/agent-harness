#!/usr/bin/env bash
# pid-identity.test.sh — a recorded pid is the recorded process only while that
# process started by the time the record was made. macOS reuses pids, and on
# 2026-10-30 a run closed 18 days earlier held a build place because its pid had
# become siriactionsd: `kill -0` said yes. Here a stand-in `sleep` started now plays
# the stranger behind an old record. Every reader of a run record or a pid file must
# count it dead, still count a real live process as live, and the tick must end the
# ghost run with exit_code "ghost".
# KIT=<a kit checkout> runs the cases against that kit's code.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done
unset KIT_ROOT HARNESS_KIT_ROOT
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture
KIT="${KIT:-$(cd "$HERE/.." && pwd)}"
RUNS="$STATE/runs"
SLEEPERS=""
on_exit_keep_status 'for p in $SLEEPERS; do kill "$p" 2>/dev/null; done; rm -rf "$FIX"'

sleeper() { sleep 300 & LAST=$!; SLEEPERS="$SLEEPERS $LAST"; disown "$LAST" 2>/dev/null; }
NOW=$(date +%s)
LONG_AGO=$(swarm_iso $(( NOW - 86400 )))
JUST_NOW=$(swarm_iso "$NOW")
record() { # <name> <pid> [started_at] — a run record with no .ended
  if [ -n "${3:-}" ]; then
    printf '{"run_id":"%s","ticket":"%s","pid":%s,"child_pid":%s,"started_at":"%s","spawn_root":"%s"}\n' "$1" "${1#claim-}" "$2" "$2" "$3" "$FIX/tree-$1" > "$RUNS/$1.json"
  else
    printf '{"run_id":"%s","ticket":"%s","pid":%s,"child_pid":%s,"spawn_root":"%s"}\n' "$1" "${1#claim-}" "$2" "$2" "$FIX/tree-$1" > "$RUNS/$1.json"
  fi
  mkdir -p "$FIX/tree-$1"; printf '%s\n' "$FIX/tree-$1" > "$RUNS/$1.worktrees"
}
in_kit() { # <bash snippet> — run with the kit's swarm-env and worktree-lib sourced
  RUNS_DIR="$RUNS" bash -c '. "$1/swarm/swarm-env.sh" >/dev/null 2>&1 || exit 9; . "$1/scripts/worktree-lib.sh" || exit 9; eval "$2"' _ "$KIT" "$1"
}
alive() { in_kit "swarm_record_alive '$RUNS/$1.json'" && echo live || echo dead; }

sleeper; GHOST=$LAST          # started now, named by a record from a day ago
sleeper; REAL=$LAST           # started now, named by a record made now
sleeper; BARE=$LAST           # a record that never carried its start
DEAD=$(sh -c 'echo $$')       # a pid that has exited
sleep 1
record claim-901-ghost "$GHOST" "$LONG_AGO"
record claim-902-real "$REAL" "$JUST_NOW"
record claim-903-bare "$BARE"
record claim-904-dead "$DEAD" "$JUST_NOW"

echo "--- the guard's own premise: kill -0 answers for the stranger ---"
want "kill -0 says the ghost's pid answers" "yes" "$(kill -0 "$GHOST" 2>/dev/null && echo yes || echo no)"

echo "--- swarm_record_alive: the coordinator's count ---"
want "a record whose pid is now a stranger is dead"   dead "$(alive claim-901-ghost)"
want "a real live run is live"                        live "$(alive claim-902-real)"
want "a record with no start is live (safe side)"     live "$(alive claim-903-bare)"
want "a record whose pid exited is dead"              dead "$(alive claim-904-dead)"
want "swarm_running_total counts the real ones only"  2 "$(in_kit swarm_running_total)"

echo "--- wt_live_runs and wt_run_holder: what the cleaners keep ---"
LIVE_RUNS=$(in_kit wt_live_runs | sed 's#.*/##' | sort | tr '\n' ' ')
want "wt_live_runs lists the real runs, not the ghost" "claim-902-real.json claim-903-bare.json " "$LIVE_RUNS"
want "the ghost's tree is not held"   "none" "$(in_kit "wt_run_holder \"\$(wt_real '$FIX/tree-claim-901-ghost')\"" || echo none)"
want "the real run's tree is held"    "claim-902-real" "$(in_kit "wt_run_holder \"\$(wt_real '$FIX/tree-claim-902-real')\"" || echo none)"

echo "--- pid files: a lock holder's pid is checked against when it was written ---"
printf '%s\n' "$GHOST" > "$FIX/old.pid"; touch -t 202601010000 "$FIX/old.pid"
printf '%s\n' "$REAL" > "$FIX/new.pid"
pf() { in_kit "pid_file_alive '$1'" && echo live || echo dead; }
want "a pid file from January naming a process started now is dead" dead "$(pf "$FIX/old.pid")"
want "a pid file written after its process started is live"         live "$(pf "$FIX/new.pid")"

echo "--- the tick ends a ghost run, once, without a stood-down event ---"
for s in reconcile sweep wtsweep claude notify; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$s"; chmod +x "$BIN/$s"; done
printf '#!/usr/bin/env bash\necho "[]"\n' > "$BIN/fixlock"; chmod +x "$BIN/fixlock"
printf '#!/usr/bin/env bash\ncase "$1" in tick) printf "500\\tdisk: 500 GB free\\n" ;; limits) echo "30 50" ;; free) echo 500 ;; esac\n' > "$BIN/diskguard"; chmod +x "$BIN/diskguard"
printf '%s\n' 'live_view_watchdog() { :; }' > "$FIX/watchdog-stub.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/spawn-none"; chmod +x "$BIN/spawn-none"
: > "$FIX/claims.txt"
export COORDINATOR_DISK_GUARD="$BIN/diskguard" COORDINATOR_LIVE_VIEW_WATCHDOG="$FIX/watchdog-stub.sh"
export COORDINATOR_FIX_LOCK="$BIN/fixlock" COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep"
export COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep" COORDINATOR_CLAUDE="$BIN/claude" COORDINATOR_NOTIFY_CMD="$BIN/notify"
export COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt" SWARM_FREE_MEM_GB=16
unset COORDINATOR_SHADOW COORDINATOR_CAP
rm -f "$RUNS/claim-903-bare.json" "$RUNS/claim-904-dead.json"
tick() { SWARM_SPAWN="$BIN/spawn-none" COORDINATOR_SHADOW=0 SWARM_IDLE=90 SWARM_CORES=10 bash "$KIT/scripts/coordinator-tick.sh" >/dev/null 2>&1; }
tick
TL="$STATE/coordinator/tick.log"
want "the ghost run has its .ended"          ghost "$(jq -r '.exit_code' "$RUNS/claim-901-ghost.ended" 2>/dev/null)"
want_in "the tick says it ended the ghost"   "ghost: ended claim-901-ghost — its pid $GHOST now belongs to another process" "$(cat "$TL" 2>/dev/null)"
want_in "the tick counts the real run only"  "live: 1 run\(s\) \[902-real\]" "$(cat "$TL" 2>/dev/null)"
want "the real run has no .ended"            no "$([ -e "$RUNS/claim-902-real.ended" ] && echo yes || echo no)"
tick
want_in "the next tick reads the ended ghost" "ended: claim-901-ghost exit ghost" "$(cat "$TL" 2>/dev/null)"
want "no stood-down event for a ghost"       0 "$(cat "$STATE"/coordinator/events* 2>/dev/null | grep -c 'stood-down:claim-901-ghost')"

suite_end "$FAILED"
