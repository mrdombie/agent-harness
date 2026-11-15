#!/usr/bin/env bash
# coordinator-auth-hold.test.sh — a host whose Claude login expired starts builds that die
# at their first call, and nobody looking at the sheet can tell which host or why.
#
# The driver writes the auth hold (<state>/auth-hold) when a call reads as a lost login.
#   a tick on that host   → 'spawn: paused for auth', nothing spawned, one owner notice
#   its heartbeat         → carries auth: the error and since when
#   the Machines line     → ' — **paused for auth**: <error>'; without a hold, as today
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
for v in RUNS_DIR STATE_DIR DRIVER_DIR $(env | sed -nE 's/^((SWARM|COORDINATOR|COORD|HARNESS)_[A-Z_]*)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
T="$HERE/coordinator-tick.sh"
Q="$HERE/coordinator-queue.sh"
C="$STATE/coordinator"

for s in reconcile sweep; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$s"; chmod +x "$BIN/$s"; done
printf '#!/usr/bin/env bash\necho "$*" >> "$FIX/notify.log"\n' > "$BIN/notify"; chmod +x "$BIN/notify"
cat > "$BIN/diskguard" <<'SH'
#!/usr/bin/env bash
case "$1" in tick) printf '500\tdisk: 500 GB free\n' ;; limits) echo "30 50" ;; free) echo 500 ;; esac
SH
chmod +x "$BIN/diskguard"
export COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep" COORDINATOR_HOUSEKEEPING_CMD="$BIN/sweep"
export COORDINATOR_NOTIFY_CMD="$BIN/notify" COORDINATOR_HOUSEKEEPING=inline COORDINATOR_DISK_GUARD="$BIN/diskguard"
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 SWARM_FREE_MEM_GB=16 TEST_PID=$$
export COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt" COORDINATOR_LIVE_VIEW_WATCHDOG=off COORDINATOR_FIX_ROUNDS=0
export COORDINATOR_HOST=yomato SWARM_HOST=yomato
unset COORDINATOR_SHADOW COORDINATOR_CAP

ERR="Failed to authenticate: OAuth session expired"
fresh() { rm -rf "$C" "$STATE/auth-hold"; : > "$SPAWNS"; : > "$FIX/claims.txt"; : > "$FIX/notify.log"; printf '[]\n' > "$FIX/gh/prs-all.json"; }
hold() { printf '%s\t%s\t%s\t%s\n' "$1" "$ERR" yomato acct-test > "$STATE/auth-hold"; }
render() { # <host json> — the owner's sheet as it renders that heartbeat
  ( . "$HERE/coordinator-env.sh" >/dev/null 2>&1; . "$HERE/coordinator-sheet.sh" >/dev/null 2>&1
    coord_sheet_render "$(jq -nc --argjson h "$1" '{order: [], building: [], fleet: [$h + {behind: false}]}')" "$(date +%s)" )
}
own_beat() { jq -c '.hosts[0]' "$C/fleet.json" 2>/dev/null; }

fix_issue 501 OPEN "status:ready"

echo "--- an auth hold: the shadow tick pauses, spawns nothing, and says so ---"
fresh; bash "$Q" add 501 >/dev/null; hold 1763100000
out=$(bash "$T" 2>&1)
want_in "the tick says it is paused for auth"         'spawn: paused for auth — Failed to authenticate: OAuth session expired' "$out"
want_not_in "it would spawn nothing"                   'would spawn #501' "$out"
want "nothing spawned"                                 "" "$(cat "$SPAWNS")"
want_in "one event names the host and the error"       'event: auth-hold — yomato is paused for auth: Failed to authenticate' "$out"
beat=$(own_beat)
want_in "the heartbeat carries auth naming the error"  '^Failed to authenticate: OAuth session expired \(since ' "$(jq -r '.auth // ""' <<<"$beat")"
out=$(bash "$T" 2>&1)
want_not_in "the next tick raises no second event"     'event: auth-hold' "$out"
want_in "and still pauses"                             'spawn: paused for auth' "$out"
line=$(render "$beat" | grep '^- yomato ')
want_in "the Machines line names the pause and the error" '^- yomato · harness .* — \*\*paused for auth\*\*: Failed to authenticate: OAuth session expired' "$line"

echo "--- no hold: the tick spawns as today and the line has no pause ---"
fresh; bash "$Q" add 501 >/dev/null
out=$(bash "$T" 2>&1)
want_in "the tick would spawn the ready ticket"        'would spawn #501' "$out"
want_not_in "no pause"                                 'paused for auth' "$out"
beat=$(own_beat)
want "the heartbeat has no auth field"                 "" "$(jq -r '.auth // ""' <<<"$beat")"
line=$(render "$beat" | grep '^- yomato ')
want_in "the line renders as today"                    '^- yomato · harness ' "$line"
want_not_in "with no pause in it"                      'paused for auth' "$line"

echo "--- a shadow tick never probes the login and never moves the real hold ---"
cat > "$FIX/probe" <<SH
#!/usr/bin/env bash
echo x >> "$FIX/probes"
echo '{"type":"result","is_error":false,"num_turns":1,"result":"ok"}'
SH
chmod +x "$FIX/probe"; export SWARM_AUTH_PROBE_CMD="$FIX/probe"
fresh; rm -f "$FIX/probes"; rm -rf "$STATE/logs"; bash "$Q" add 501 >/dev/null
bash "$T" >/dev/null 2>&1
want "with no hold, the shadow tick makes no probe call" "no" "$([ -s "$FIX/probes" ] && echo yes || echo no)"
fresh; rm -f "$FIX/probes"; rm -rf "$STATE/logs"; bash "$Q" add 501 >/dev/null; hold 1763100000
touch -t 202001010000 "$STATE/auth-hold"
out=$(bash "$T" 2>&1)
want "with an old hold, no probe call either" "no" "$([ -s "$FIX/probes" ] && echo yes || echo no)"
want "and the real hold stays where it is" "yes" "$([ -f "$STATE/auth-hold" ] && echo yes || echo no)"
want_in "it still reads the hold and pauses" 'spawn: paused for auth' "$out"
unset SWARM_AUTH_PROBE_CMD

echo "--- a disk hold over an auth hold: the auth event and its notice still fire ---"
cat > "$BIN/diskguard" <<'SH'
#!/usr/bin/env bash
case "$1" in tick) printf '5\tdisk: 5 GB free, under the 30 GB floor\n'; exit 1 ;; limits) echo "30 50" ;; free) echo 5 ;; esac
SH
fresh; bash "$Q" add 501 >/dev/null; hold 1763100000
out=$(COORDINATOR_SHADOW=0 bash "$T" 2>&1)
want_in "the disk hold decides the spawn"          'spawn: starting nothing new — disk: 5 GB free' "$out"
want_in "the auth event is raised beside it"        'event: auth-hold — yomato is paused for auth' "$out"
want_in "and the owner hears of the lost login"      'yomato lost its Claude login' "$(cat "$FIX/notify.log")"
cat > "$BIN/diskguard" <<'SH'
#!/usr/bin/env bash
case "$1" in tick) printf '500\tdisk: 500 GB free\n' ;; limits) echo "30 50" ;; free) echo 500 ;; esac
SH

echo "--- a run requeued for a lost login is the machine's: never counted toward no-progress ---"
lost_run() { # <ticket> <n> — a driver run that requeued in seconds on a lost login
  local rid="claim-$1-auth$2" s e
  s=$(date -u -r $(( $(date +%s) - 20 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$(( $(date +%s) - 20 )) +%Y-%m-%dT%H:%M:%SZ)
  e=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$STATE/runs" "$STATE/logs"
  jq -nc --arg r "$rid" --arg t "$1" --arg l "$STATE/logs/$rid.log" --arg s "$s" '{run_id:$r, ticket:$t, log:$l, started_at:$s}' > "$STATE/runs/$rid.json"
  printf '%s\n' "✋ plan: this host's Claude login is gone — $ERR. The host's, not the ticket's: yomato is held for auth until someone logs in again." \
    "↻ #$1 requeued for the next tick, not parked: plan: this host's Claude login is gone — $ERR" > "$STATE/logs/$rid.log"
  jq -nc --arg r "$rid" --arg e "$e" '{run_id:$r, exit_code:28, ended_at:$e}' > "$STATE/runs/$rid.ended"
}
fresh; rm -f "$C/run-lengths.tsv"
for n in 1 2 3; do lost_run 501 "$n"; COORDINATOR_SHADOW=0 bash "$T" >/dev/null 2>&1; done
want "no run is counted toward no-progress" "0" "$(grep -c '^501	' "$C/run-lengths.tsv" 2>/dev/null || echo 0)"
want "the ticket is not parked for the PM" "" "$(grep 'no-progress' "$C"/events.*.jsonl 2>/dev/null)"

echo "--- one outage, one owner notice: a run's lost login and the auth hold are told once ---"
fresh; rm -f "$C/run-lengths.tsv"; rm -rf "$STATE/runs" "$STATE/logs"
mkdir -p "$STATE/runs" "$STATE/logs"
printf '{"run_id":"claim-501-cli","ticket":"501","log":"%s"}\n' "$STATE/logs/claim-501-cli.log" > "$STATE/runs/claim-501-cli.json"
{ printf '{"type":"system","subtype":"init","session_id":"s"}\n'
  printf '{"type":"assistant","error":"authentication_failed","message":{"model":"<synthetic>","content":[{"type":"text","text":"Not logged in"}]}}\n'
  printf '{"type":"result","is_error":true,"result":"Failed to authenticate: OAuth session expired"}\n'; } > "$STATE/logs/claim-501-cli.log"
printf '{"run_id":"claim-501-cli","exit_code":1}\n' > "$STATE/runs/claim-501-cli.ended"
COORDINATOR_SHADOW=0 bash "$T" >/dev/null 2>&1
want "the run's lost login puts the host under the auth hold" "yes" "$([ -f "$STATE/auth-hold" ] && echo yes || echo no)"
want "the owner is told once" "1" "$(grep -ciE 'login' "$FIX/notify.log")"
want_in "by the auth hold's notice, naming /login" '^yomato lost its Claude login .*/login' "$(cat "$FIX/notify.log")"

suite_end "$FAILED"
