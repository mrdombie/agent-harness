#!/usr/bin/env bash
# coordinator-host-count.test.sh — the heavy jobs on this host that no tracked run owns,
# each counted once at its top-most process.
#
# On 2026-11-05 the live line said 4 runs while ~9 heavy jobs ran: build-ticket drivers,
# `claude -p --name fix|build` sessions and the develop-hook-red lint sweep, none of them
# a run the coordinator still tracked. host_heavy_untracked reads one ps snapshot.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
# Nor the operator's swarm: a tick run from a live session would read its real state dir.
for v in $(env | sed -nE 's/^((SWARM|COORDINATOR|COORD|HARNESS|CLAIM|DRIVER)_[A-Z_]*)=.*/\1/p'); do unset "$v"; done
unset RUNS_DIR STATE_DIR KIT_ROOT MAIN_REPO REPO_ROOT REPO_SLUG CL PR_RED_REQ_FILE
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'

# untracked [tracked pid…] — host_heavy_untracked as the coordinator sources it.
untracked() { ( . "$HERE/coordinator-env.sh" >/dev/null 2>&1 || exit 9; host_heavy_untracked "$@" ); }

echo "--- the fixture's host is empty: no suite sees the developer's real builds ---"
want "nothing on the fixture's host" "" "$(untracked)"

cat > "$FIX/ps.txt" <<'PS'
    1     0 /sbin/launchd
  501     1 bash /kit/driver/build-ticket 18295
  502   501 bash /kit/driver/build-ticket 18295 --step build
  503   501 claude -p --output-format stream-json --verbose --name build --permission-mode auto --add-dir /wt/sh-18295
  610     1 claude -p --output-format stream-json --verbose --name fix --permission-mode auto --add-dir /wt/sh-18178
  700     1 bash /kit/scripts/develop-hook-red.sh sweep
  701   700 npm run lint:all
  800     1 claude -p --output-format json --max-turns 4
  900     1 grep build-ticket
  901     1 vim /kit/driver/build-ticket
PS
printf '#!/usr/bin/env bash\ncat "%s"\n' "$FIX/ps.txt" > "$BIN/host-ps"; chmod +x "$BIN/host-ps"
export COORDINATOR_HOST_PS="$BIN/host-ps"

echo "--- nothing tracked: each heavy unit once, at its top-most process ---"
want "a build driver, a fix session, the lint sweep" \
  "$(printf '501\tbuild\t18295\n610\tfix\tsh-18178\n700\thook-sweep\t-')" "$(untracked)"

echo "--- a tracked run's whole tree is the coordinator's own count ---"
want "only the fix session and the lint sweep" \
  "$(printf '610\tfix\tsh-18178\n700\thook-sweep\t-')" "$(untracked 501)"

echo "--- a tracked ancestor drops its descendants too ---"
want "the sweep's tree tracked at its root" \
  "$(printf '501\tbuild\t18295\n610\tfix\tsh-18178')" "$(untracked 700 1234)"

echo "--- the tick: an untracked build on the real host is live and takes a place under the cap ---"
T="$HERE/coordinator-tick.sh"; Q="$HERE/coordinator-queue.sh"
for s in reconcile sweep wtsweep unblock featureclose polish notify claude; do
  printf '#!/usr/bin/env bash\n:\n' > "$BIN/$s"; chmod +x "$BIN/$s"
done
printf '%s\n' 'live_view_watchdog() { :; }' > "$FIX/watchdog-stub.sh"
cat > "$BIN/diskguard" <<'SH'
#!/usr/bin/env bash
case "$1" in tick) printf '500\tdisk: 500 GB free\n' ;; limits) echo "30 50" ;; free) echo 500 ;; esac
SH
chmod +x "$BIN/diskguard"
export COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep" COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep" \
  COORDINATOR_UNBLOCK="$BIN/unblock" COORDINATOR_FEATURE_CLOSE="$BIN/featureclose" COORDINATOR_POLISH_LIST="$BIN/polish" \
  COORDINATOR_CLAUDE="$BIN/claude" COORDINATOR_NOTIFY_CMD="$BIN/notify" COORDINATOR_DISK_GUARD="$BIN/diskguard" \
  COORDINATOR_LIVE_VIEW_WATCHDOG="$FIX/watchdog-stub.sh" COORDINATOR_MACHINE_PARKS=off \
  COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0 COORDINATOR_REFRESH=0 \
  COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt" COORDINATOR_FIX_ROUNDS=0 SWARM_FREE_MEM_GB=16
unset COORDINATOR_SHADOW COORDINATOR_START_CPU_IDLE COORDINATOR_MIN_FREE_MEM_GB
: > "$FIX/claims.txt"; printf '[]\n' > "$FIX/gh/prs-all.json"
fix_issue 501 OPEN "status:ready"; bash "$Q" add 501 >/dev/null

# Stand-ins the real ps lists. Each starts detached (its parent is gone), so a heavy
# unit running this suite — a proof under build-ticket — is not their ancestor.
mkdir -p "$FIX/proof-tree/driver" "$FIX/wt/sh-77777" "$FIX/wt/sh-98762"
cat > "$FIX/proof-tree/driver/build-ticket" <<'SH'
#!/usr/bin/env bash
kids=""; trap 'kill $kids 2>/dev/null; exit 0' TERM
if [ -n "${WITH_CLAUDE:-}" ]; then
  (exec -a claude perl -e 'sleep 300' -- -p --name build --add-dir "$WITH_CLAUDE") & kids="$kids $!"
fi
sleep 300 & kids="$kids $!"; wait
SH
STANDIN_PIDS="$FIX/standin.pids"; : > "$STANDIN_PIDS"
detach() { ( "$@" >/dev/null 2>&1 & echo $! >> "$STANDIN_PIDS" ); }
on_exit_keep_status 'kill $(cat "$STANDIN_PIDS" 2>/dev/null) 2>/dev/null; rm -rf "$FIX"'
detach bash "$FIX/proof-tree/driver/build-ticket" 98761
detach bash -c 'exec -a claude perl -e "sleep 300" -- -p --name fix --add-dir "$0"' "$FIX/wt/sh-77777"
WITH_CLAUDE="$FIX/wt/sh-98762" detach bash "$FIX/proof-tree/driver/build-ticket" 98762
sleep 0.5

out=$(env -u COORDINATOR_HOST_PS COORDINATOR_CAP=1 bash "$T" 2>&1)
live=$(printf '%s\n' "$out" | grep -E 'live: [0-9]+ run\(s\)' | head -1)
echo "  $live"
n=$(printf '%s' "$live" | sed -nE 's/.*live: ([0-9]+) run\(s\).*/\1/p')
want "the live line counts the untracked builds" "yes" "$([ "${n:-0}" -ge 1 ] && echo yes || echo no)"
want_in "it names the hand-run build under untracked" 'untracked: .*(^|[^0-9])98761([^0-9]|$)' "$live"
want_in "it names a fix session with its worktree" 'fix sh-77777' "$live"
want_in "a build-ticket with a claude child is named" '(^|[^0-9])98762([^0-9]|$)' "$live"
want_not_in "and its claude child is not a second unit" 'build sh-98762' "$live"
want_in "the untracked build fills the one place" 'spawn: [0-9]+ live, cap 1 — no slot' "$out"
want_not_in "nothing would start" 'would spawn' "$out"

echo "--- a run the coordinator stopped tracking still holds its place while its process lives ---"
# Its record has .ended (a requeue, a frozen judgement) but its build-ticket has not exited.
standin() { pgrep -f "$FIX/proof-tree/driver/build-ticket $1" | head -1; }
kill "$(standin 98761)" 2>/dev/null; pkill -f "sh-77777" 2>/dev/null; sleep 0.3
p98762=$(standin 98762)
jq -n --argjson p "$p98762" '{run_id:"claim-98762-x", ticket:"98762", pid:$p}' > "$STATE/runs/claim-98762-x.json"
printf '{"run_id":"claim-98762-x","exit_code":"requeued"}\n' > "$STATE/runs/claim-98762-x.ended"
out=$(env -u COORDINATOR_HOST_PS COORDINATOR_CAP=1 bash "$T" 2>&1)
live=$(printf '%s\n' "$out" | grep -E 'live: [0-9]+ run\(s\)' | head -1)
echo "  $live"
want_in "the ended run's live build is named untracked" 'untracked: .*(^|[^0-9])98762([^0-9]|$)' "$live"
want_in "and it fills the one place" 'spawn: [0-9]+ live, cap 1 — no slot' "$out"
n=$(printf '%s' "$live" | sed -nE 's/.*live: ([0-9]+) run\(s\).*/\1/p')
# Other heavy work on the real host (a proof's own driver) keeps its places: the cap is set to this count.
kill "$p98762" 2>/dev/null; sleep 0.3
out=$(env -u COORDINATOR_HOST_PS COORDINATOR_CAP="${n:-1}" bash "$T" 2>&1)
live=$(printf '%s\n' "$out" | grep -E 'live: [0-9]+ run\(s\)' | head -1)
echo "  $live"
want_not_in "once it exits it is no longer named" '(^|[^0-9])98762([^0-9]|$)' "$live"
want_in "and a slot opens" 'would spawn' "$out"

echo "--- housekeeping's hook sweep is a heavy job while it runs ---"
base=$(printf '%s' "$live" | sed -nE 's/.*live: ([0-9]+) run\(s\).*/\1/p')
mkdir -p "$FIX/proof-tree/scripts"
cat > "$FIX/proof-tree/scripts/develop-hook-red.sh" <<'SH'
#!/usr/bin/env bash
kids=""; trap 'kill $kids 2>/dev/null; exit 0' TERM
(exec -a npm perl -e 'sleep 300' -- run lint:all) & kids="$kids $!"
sleep 300 & kids="$kids $!"; wait
SH
detach bash "$FIX/proof-tree/scripts/develop-hook-red.sh" sweep abc1234
sleep 0.5
out=$(env -u COORDINATOR_HOST_PS COORDINATOR_CAP=$(( ${base:-0} + 1 )) bash "$T" 2>&1)
live=$(printf '%s\n' "$out" | grep -E 'live: [0-9]+ run\(s\)' | head -1)
echo "  $live"
want_in "the live line names the sweep" 'untracked: .*hook-sweep' "$live"
want "its lint:all child is not counted again" "$(( ${base:-0} + 1 ))" \
  "$(printf '%s' "$live" | sed -nE 's/.*live: ([0-9]+) run\(s\).*/\1/p')"
want_in "the sweep fills the last place" 'spawn: [0-9]+ live, cap [0-9]+ — no slot' "$out"
want_not_in "nothing would start" 'would spawn' "$out"

suite_end "$FAILED"
