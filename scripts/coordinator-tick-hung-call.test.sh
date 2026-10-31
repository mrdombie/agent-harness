#!/usr/bin/env bash
# coordinator-tick-hung-call.test.sh — one hung outside call never stops the tick. The
# account check (`claude auth status`) and the usage probe (`claude -p`) each run under a
# time limit, and a tick that has run past coordinator.tickMaxMin is stopped by the next
# one, which takes the lock and carries on. On 2026-10-31 an account check hung for
# 1 h 57 min and both machines started nothing.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture
HOLDERS=""
on_exit_keep_status 'for p in $HOLDERS; do kill -KILL -- "-$p" 2>/dev/null; done; rm -rf "$FIX"'
T="${TICK_SUT:-$HERE/coordinator-tick.sh}"
C="$STATE/coordinator"

for s in reconcile sweep wtsweep unblock notify; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$s"; chmod +x "$BIN/$s"; done
export COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep" COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep"
export COORDINATOR_UNBLOCK="$BIN/unblock" COORDINATOR_NOTIFY_CMD="$BIN/notify" COORDINATOR_MACHINE_PARKS=off
export COORDINATOR_HOUSEKEEPING=off COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 SWARM_FREE_MEM_GB=16
printf '#!/usr/bin/env bash\nprintf "[]"\n' > "$BIN/fixlock"; chmod +x "$BIN/fixlock"; export COORDINATOR_FIX_LOCK="$BIN/fixlock"
printf '#!/usr/bin/env bash\ncase "$1" in tick) printf "500\\tdisk: 500 GB free\\n" ;; limits) echo "30 50" ;; free) echo 500 ;; esac\n' > "$BIN/diskguard"
chmod +x "$BIN/diskguard"; export COORDINATOR_DISK_GUARD="$BIN/diskguard"
printf '%s\n' 'live_view_watchdog() { :; }' > "$FIX/watchdog-stub.sh"; export COORDINATOR_LIVE_VIEW_WATCHDOG="$FIX/watchdog-stub.sh"
: > "$FIX/claims.txt"; export COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
printf '[]\n' > "$FIX/gh/prs-all.json"

# Stand-ins that never return, and one that answers at once.
printf '#!/usr/bin/env bash\necho "$*" >> "$FIX/hang.calls"\nexec sleep 600\n' > "$BIN/claude-hang"
cat > "$BIN/claude-b" <<'SH'
#!/usr/bin/env bash
echo '{"orgId":"acct-b"}'
SH
chmod +x "$BIN/claude-hang" "$BIN/claude-b"
export SWARM_ACCOUNT_TIMEOUT=2 SWARM_USAGE_PROBE_TIMEOUT=2

DEADLINE=60
# run_tick — the tick in a process group of its own, stopped at DEADLINE: RC is its exit, or
# 124 when it was still running; SECS how long it took; OUT what it said.
run_tick() {
  local p t0 i=0
  t0=$(date +%s)
  perl -e 'setpgrp(0, 0); exec @ARGV or exit 127' bash "$T" > "$FIX/tick.out" 2>&1 < /dev/null &
  p=$!
  while kill -0 "$p" 2>/dev/null && [ "$i" -lt $(( DEADLINE * 10 )) ]; do sleep 0.1; i=$(( i + 1 )); done
  if kill -0 "$p" 2>/dev/null; then kill -KILL -- "-$p" 2>/dev/null; wait "$p" 2>/dev/null; RC=124
  else wait "$p"; RC=$?; fi
  SECS=$(( $(date +%s) - t0 )); OUT=$(cat "$FIX/tick.out")
}
fresh() { : > "$FIX/hang.calls"; rm -rf "$C" "$STATE/swarm/.account" "$STATE/swarm/.account.hung" "$STATE/logs"/claim-usage-probe-* "$STATE/logs/.usage-probe.at"; mkdir -p "$C"; unset COORDINATOR_TICK_MAX_MIN; }
started_of() { LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//'; }

echo "--- the account check never returns: the tick bounds it and carries on with the last known account ---"
fresh; printf 'acct-a\t0\t0\n' > "$STATE/swarm/.account"
SWARM_CLAUDE_BIN="$BIN/claude-hang" COORDINATOR_SHADOW=0 run_tick
want "the tick finished" 0 "$RC"
want_in "it reached its end" 'tick: done' "$OUT"
[ "$SECS" -lt 30 ] && ok "inside the bound ($SECS s)" || bad "took $SECS s"
want "the last known account stands" acct-a "$(cat "$C/usage.account" 2>/dev/null)"
want "a hung check is asked once a tick, not at every read" 1 "$(grep -c "auth status" "$FIX/hang.calls")"

echo "--- the account changed and the probe call never returns: the tick bounds it and carries on ---"
fresh; printf 'acct-a\n' > "$C/usage.account"
SWARM_CLAUDE_BIN="$BIN/claude-b" SWARM_USAGE_PROBE_CMD="$BIN/claude-hang" COORDINATOR_SHADOW=0 run_tick
want "the tick finished" 0 "$RC"
want_in "it reached its end" 'tick: done' "$OUT"
want_in "it says the probe failed, to try again" 'probe call to read the new account failed' "$OUT"
[ "$SECS" -lt 30 ] && ok "inside the bound ($SECS s)" || bad "took $SECS s"

# hold_lock <age-min> — a live tick, its own process group with a child, holding the lock
# taken <age-min> ago. HOLDER is its pid, CHILD its child's.
hold_lock() {
  perl -e 'setpgrp(0, 0); exec @ARGV or exit 127' bash -c 'sleep 600 & echo $! > "$0"; wait' "$FIX/child.pid" < /dev/null > /dev/null 2>&1 &
  HOLDER=$!; HOLDERS="$HOLDERS $HOLDER"
  local i=0; while [ ! -s "$FIX/child.pid" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$(( i + 1 )); done
  CHILD=$(cat "$FIX/child.pid"); rm -f "$FIX/child.pid"
  mkdir -p "$C/tick.lock"; started_of "$HOLDER" > "$C/tick.lock/started"; echo "$HOLDER" > "$C/tick.lock/pid"
  # perl, not touch -t with date -r: GNU date -r reads a file, not an epoch.
  perl -e '$t = time - shift() * 60; utime $t, $t, @ARGV or exit 1' "$1" "$C/tick.lock/pid" "$C/tick.lock" || bad "could not age the lock"
}

echo "--- a tick that ran past coordinator.tickMaxMin is stopped, and this one takes the lock ---"
fresh; hold_lock 120
SWARM_CLAUDE_BIN="$BIN/claude-b" run_tick
want_in "it reached its end" 'tick: done' "$OUT"
want_in "it names the tick it stopped" "pid $HOLDER\\).*stopped it" "$OUT"
sleep 0.5
kill -0 "$HOLDER" 2>/dev/null && bad "the hung tick still runs" || ok "the hung tick is gone"
kill -0 "$CHILD" 2>/dev/null && bad "the hung tick's child still runs" || ok "its child is gone too"

echo "--- a tick inside its limit is left alone (nothing correct is stopped) ---"
fresh; hold_lock 1
SWARM_CLAUDE_BIN="$BIN/claude-b" run_tick
want_in "this tick exits" 'another tick \(pid [0-9]+\) is running' "$OUT"
want_not_in "it does not run the tick" 'tick: done' "$OUT"
kill -0 "$HOLDER" 2>/dev/null && ok "the running tick still runs" || bad "a tick inside its limit was stopped"
kill -KILL -- "-$HOLDER" 2>/dev/null

suite_end "$FAILED"
