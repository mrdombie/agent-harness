#!/usr/bin/env bash
# coordinator-tick.test.sh — the guards the tick exists to hold: one tick at a
# time, the machine-derived ceiling, an optional hard cap,
# never a claimed / gated / held ticket, shadow does nothing,
# a frozen run is noticed. Plus the events, the owner channel and the judge.
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

# Stand-ins for the housekeeping scripts and the judge's claude: each records its call.
cat > "$BIN/reconcile" <<'SH'
#!/usr/bin/env bash
echo "reconcile $*" >> "$FIX/house.log"
SH
cat > "$BIN/sweep" <<'SH'
#!/usr/bin/env bash
echo "sweep $*" >> "$FIX/house.log"
SH
cat > "$BIN/wtsweep" <<'SH'
#!/usr/bin/env bash
echo "wtsweep $*" >> "$FIX/house.log"
SH
chmod +x "$BIN/wtsweep"
export COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep"
cat > "$BIN/unblock" <<'SH'
#!/usr/bin/env bash
echo "unblock $*" >> "$FIX/house.log"
SH
chmod +x "$BIN/unblock"
export COORDINATOR_UNBLOCK="$BIN/unblock" COORDINATOR_MACHINE_PARKS=off
cat > "$BIN/featureclose" <<'SH'
#!/usr/bin/env bash
echo "featureclose $*" >> "$FIX/house.log"
SH
chmod +x "$BIN/featureclose"
export COORDINATOR_FEATURE_CLOSE="$BIN/featureclose"
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
{ printf 'ARGV'; printf ' [%s]' "$@"; printf '\n'
  echo "COMPACT=${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-unset}"; } >> "$FIX/claude.log"
SH
cat > "$BIN/notify" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$FIX/notify.log"
SH
cat > "$BIN/polish" <<'SH'
#!/usr/bin/env bash
case "$1" in sweep) echo "polish $*" >> "$FIX/house.log" ;; *) exec bash "$REAL_POLISH" "$@" ;; esac
SH
chmod +x "$BIN/polish"
export REAL_POLISH="$HERE/polish-list.sh" COORDINATOR_POLISH_LIST="$BIN/polish"
chmod +x "$BIN/reconcile" "$BIN/sweep" "$BIN/claude" "$BIN/notify"
export COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep"
export COORDINATOR_CLAUDE="$BIN/claude" COORDINATOR_NOTIFY_CMD="$BIN/notify"
# Housekeeping in line and every tick, so each case reads what it did when the tick returns.
export COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
# The fix rounds have their own cases (fix_tick, and swarm/tests/rebuild.test.sh); off for the rest.
export COORDINATOR_FIX_ROUNDS=0
unset COORDINATOR_SHADOW COORDINATOR_CAP COORDINATOR_START_CPU_IDLE COORDINATOR_MIN_FREE_MEM_GB
export SWARM_FREE_MEM_GB=16 TEST_PID=$$
# The disk guard has its own suite (disk-guard.test.sh); here it never holds and never cleans
# this machine's real temp dir, whatever free space a case plants for the housekeeping pass.
cat > "$BIN/diskguard" <<'SH'
#!/usr/bin/env bash
case "$1" in tick) printf '500\tdisk: 500 GB free\n' ;; limits) echo "30 50" ;; free) echo 500 ;; esac
SH
chmod +x "$BIN/diskguard"; export COORDINATOR_DISK_GUARD="$BIN/diskguard"
# A spawner that leaves a live run behind and, like an older spawner,
# writes no class: the coordinator's own record must carry it.
cat > "$BIN/spawn-live" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "${CLAIM_CLASS:-}" >> "$SPAWNS"
printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s}\n' "$1" "$1" "$TEST_PID" \
  > "$STATE/runs/claim-$1-live.json"
SH
chmod +x "$BIN/spawn-live"
# The live-view watchdog has its own suite (live-view-watchdog.test.sh); here it only records that it ran.
printf '%s\n' 'live_view_watchdog() { echo probe >> "$FIX/watchdog.log"; }' > "$FIX/watchdog-stub.sh"
export COORDINATOR_LIVE_VIEW_WATCHDOG="$FIX/watchdog-stub.sh"

fresh() {
  rm -rf "$C" "$STATE/runs"/* "$STATE/swarm/HOLD"
  : > "$SPAWNS"; : > "$FIX/house.log"; : > "$FIX/claude.log"; : > "$FIX/notify.log"; : > "$FIX/claims.txt"
  printf '[]\n' > "$FIX/gh/prs-all.json"; rm -f "$STATE/swarm/prs.json"
  unset SWARM_NOW
}
queue() { local t; for t in "$@"; do fix_issue "$t" OPEN "status:ready"; bash "$Q" add "$t" >/dev/null; done; }
tick() { bash "$T" 2>&1; }
live_run() { # <ticket> [log-age-from-now-in-min]
  local log="$STATE/logs/claim-$1-live.log"
  echo '{"type":"assistant"}' > "$log"
  printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s,"log":"%s"}\n' "$1" "$1" "$$" "$log" \
    > "$STATE/runs/claim-$1-live.json"
}
spawned() { cut -f1 "$SPAWNS" | tr '\n' ' ' | sed 's/ $//'; }
classes() { cut -f2 "$SPAWNS" | tr '\n' ' ' | sed 's/ $//'; }
live_as() { # <ticket> <class|-> — a live run whose record carries that class, or none
  local c=""; [ "$2" = - ] || c="$2"
  printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s%s}\n' "$1" "$1" "$$" "${c:+,\"class\":\"$c\"}" \
    > "$STATE/runs/claim-$1-live.json"
}
ticks() { local i out=""; for i in $(seq 1 "$1"); do out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick); done; printf '%s' "$out"; }

echo "--- shadow is the default, and it does nothing ---"
fresh; queue 501 502
out=$(tick)
want "nothing spawned"                     "" "$(spawned)"
want_in "it says what it would do"         'would spawn #501' "$out"
want_in "it names where the config came from" "config from $HARNESS_CFG_PATH" "$out"
want "the act is logged as would"          "would spawn 501" "$(awk -F'\t' '$3=="spawn"{print $2, $3, $4}' "$C/actions.log" | head -1)"
want_in "reconcile runs dry"               'reconcile --dry-run' "$(cat "$FIX/house.log")"
want_in "the server sweep runs dry"        'sweep --sweep --dry-run' "$(cat "$FIX/house.log")"
want_in "the stray sweep runs dry"         '^sweep --strays --dry-run$' "$(cat "$FIX/house.log")"
want_in "the polish-list sweep runs dry"   '^polish sweep --dry-run$' "$(cat "$FIX/house.log")"
want_in "the unblocker runs dry"           '^unblock --dry-run$' "$(cat "$FIX/house.log")"
want_in "split features are checked dry"   '^featureclose sweep --dry-run$' "$(cat "$FIX/house.log")"

echo "--- live spawns, and a set cap is a hard ceiling ---"
fresh; queue 501 502 503 504 505 506; live_run 900
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=4 tick)
want "room under the cap: it fills to the cap, in queue order" "501 502 503" "$(spawned)"
want_in "live housekeeping is not dry"     '^reconcile --quiet' "$(cat "$FIX/house.log")"
want_in "the unblocker runs live"          '^unblock $' "$(cat "$FIX/house.log")"
want_in "split features are checked live"  '^featureclose sweep$' "$(cat "$FIX/house.log")"
want_in "the stray sweep reaps for real"   '^sweep --strays$' "$(cat "$FIX/house.log")"
want_in "the polish-list sweep runs: merged items ticked, lists closed" '^polish sweep$' "$(cat "$FIX/house.log")"
fresh; queue 501 502; live_run 900; live_run 901
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=2 tick)
want "at the cap, nothing spawns"          "" "$(spawned)"
want_in "and it says why"                  '2 live, cap 2 — no slot' "$out"

echo "--- the ceiling follows the machine: room is what the spare CPU fits ---"
# 10 cores, 0.8 of a core an agent = 8% each; 40% idle keeping 15% fits 3.
fresh; queue 501 502 503 504; live_run 900; live_run 901; live_run 902
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=40 SWARM_CORES=10 SWARM_FREE_MEM_GB=16 tick)
want "idle 40%, memory over the floor: three more than the 3 running" "501 502 503" "$(spawned)"
want_in "the log names the ceiling and the reading" 'ceiling: 3 running · room for 3 more: cpu idle 40%, 16 GB free' "$out"
want "the live view's file holds the ceiling"  "6 true" "$(jq -r '"\(.ceiling) \(.room)"' "$C/capacity.json")"
want_in "and the reading behind it"        'cpu idle 40%, 16 GB free' "$(jq -r .reading "$C/capacity.json")"
fresh; queue 501
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=10 tick)
want "idle 10%: no start"                  "" "$(spawned)"
want_in "it is the hold floor"             'machine busy \(cpu idle 10%, floor 15%\) — holding' "$out"
fresh; queue 501; live_run 900
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=22 SWARM_CORES=10 tick)
want "spare idle under one agent's share: no start, nothing stopped" "" "$(spawned)"
want_in "and it names what is kept and what an agent needs" '1 live, no room for more \(cpu idle 22%, keeping 15% and an agent needs 0.8 of 10 cores\) — holding' "$out"
fresh; queue 501
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=90 SWARM_FREE_MEM_GB=2 tick)
want "memory under the floor: no start, even at 90% idle" "" "$(spawned)"
want_in "and it names the memory"          'no room for more \(2 GB free, floor 4 GB\)' "$out"
fresh; queue 501
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=90 COORDINATOR_MIN_FREE_MEM_GB=20 tick)
want "the memory floor is configurable"    "" "$(spawned)"

echo "--- room is decided on the recent CPU samples, never on the one just taken ---"
# One sample read 5%, 55%, 19%, 4%, 44% within minutes on a busy 10-core Mac.
H="$FIX/idle-history"
seed() { # <age-sec> <idle> … — samples already on record, oldest first
  local now; now=$(date +%s); : > "$H"
  while [ $# -gt 1 ]; do printf '%s %s\n' $(( now - $1 )) "$2" >> "$H"; shift 2; done
}
htick() { SWARM_IDLE_HISTORY="$H" SWARM_CORES=10 COORDINATOR_SHADOW=0 tick; }
fresh; queue 501; seed 1200 40 900 42 600 38 300 41
out=$(SWARM_IDLE=5 htick)
want "a steady 40% with one 5% dip: it starts" "501" "$(spawned)"
want_in "the log gives the median and its sample count" 'room for 3 more: cpu idle 40% \(median of 5\), 16 GB free' "$out"
want "one tick reads twice and records once" "5" "$(wc -l < "$H" | tr -d ' ')"
fresh; queue 501; live_run 900; seed 1200 5 900 8 600 4 300 6
out=$(SWARM_IDLE=55 htick)
want "a busy machine with one 55% spike: the hold floor holds" "" "$(spawned)"
want_in "and names the median"             'machine busy \(cpu idle 6% \(median of 5\), floor 15%\) — holding' "$out"
fresh; queue 501; live_run 900; seed 1200 20 900 22 600 25 300 21
out=$(SWARM_IDLE=90 htick)
want "a 90% spike over a 22% median: no agent's share spare" "" "$(spawned)"
want_in "and names what is kept"           'no room for more \(cpu idle 22% \(median of 5\), keeping 15% and an agent needs 0.8 of 10 cores\)' "$out"
fresh; queue 501; seed 4000 5 3900 5 3800 5 3700 5
out=$(SWARM_IDLE=40 htick)
want "samples past swarm.idleMaxAgeSec do not count" "501" "$(spawned)"
want_in "so the median is of one"          'cpu idle 40% \(median of 1\)' "$out"
fresh; queue 501; seed 1200 5 900 5 600 5 300 40
out=$(SWARM_IDLE=40 SWARM_IDLE_SAMPLES=3 htick)
want "swarm.idleSamples sets how many count" "501" "$(spawned)"


echo "--- it fills the spare room in one tick (Dom, 2026-10-16) ---"
fresh; queue 501 502 503 504 505 506
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=99 SWARM_CORES=10 tick)
want "an idle machine, six queued, nothing live: all six start" "501 502 503 504 505 506" "$(spawned)"
fresh; queue 501 502 503 504 505 506
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=31 SWARM_CORES=10 tick)
want "31% idle keeping 15%: room for two" "501 502" "$(spawned)"
fresh; queue 501 502 503 504 505 506
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=99 SWARM_CORES=10 COORDINATOR_AGENT_CPU_CORES=4 tick)
want "an agent's share is configurable: 4 cores each fits two" "501 502" "$(spawned)"
fresh; queue 501 502 503 504 505 506
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=99 SWARM_CORES=10 COORDINATOR_KEEP_CPU_IDLE=75 tick)
want "the kept idle is configurable: keeping 75% fits three" "501 502 503" "$(spawned)"
fresh; queue 501 502 503
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=99 SWARM_CORES=10 COORDINATOR_KEEP_CPU_IDLE=5 tick)
want "kept idle under the hold floor is raised to it, never lower" "501 502 503" "$(spawned)"

echo "--- a builder started inside the ramp window still owns its share ---"
ramp_run() { # <ticket> <seconds ago>
  printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s,"started_at":"%s"}\n' "$1" "$1" "$$" \
    "$(date -u -r $(( $(date +%s) - $2 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$(( $(date +%s) - $2 ))" +%Y-%m-%dT%H:%M:%SZ)" \
    > "$STATE/runs/claim-$1-live.json"
}
fresh; queue 501 502 503 504; ramp_run 900 60
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=40 SWARM_CORES=10 tick)
want "40% fits 3, one started a minute ago: two start" "501 502" "$(spawned)"
want_in "and the reading says why"         '1 started in the last 10 min' "$out"
fresh; queue 501 502 503 504; ramp_run 900 1200
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=40 SWARM_CORES=10 tick)
want "one started 20 minutes ago no longer counts" "501 502 503" "$(spawned)"
fresh; queue 501 502; ramp_run 900 60; ramp_run 901 60; ramp_run 902 60
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=40 SWARM_CORES=10 tick)
want "three ramping fill the three places: none start" "" "$(spawned)"

echo "--- a start that fails is not counted as running ---"
fresh; queue 501 502
out=$(COORDINATOR_SHADOW=0 SWARM_SPAWN=/usr/bin/false SWARM_IDLE=40 SWARM_CORES=10 tick)
want_in "it says the start failed"         'spawn of #501 failed' "$out"
want "the live view counts nothing running" "0" "$(jq -r '.new.live' "$C/capacity.json")"

echo "--- no fixed cap: with coordinator.cap unset, the machine alone decides ---"
fresh; queue 501; for t in 900 901 902 903; do live_run $t; done
out=$(COORDINATOR_SHADOW=0 tick)
want "4 running and room: a 5th starts"    "501" "$(spawned)"
want_in "the tick says there is no cap"    'cap none' "$out"
fresh; queue 501; for t in 900 901 902 903 904 905 906; do live_run $t; done
out=$(COORDINATOR_SHADOW=0 tick)
want "7 running and room: an 8th starts"   "501" "$(spawned)"
want "the live view's file has no cap"     "null" "$(jq -r '.cap' "$C/capacity.json")"

echo "--- priority alone decides: there is no repair class and no healing place ---"
# The 3/4 build, 1/4 heal split is gone (owner call 2026-10-24); a cap of 0 is no cap.
export COORDINATOR_OPEN_PR_CAP=0
# One agent's room per tick (23% idle keeping 15%, 8% each), so a ramp is visible.
export SWARM_IDLE=23 SWARM_CORES=10
fresh; queue 701 702 703 704 705
out=$(COORDINATOR_CAP=4 ticks 4)
want "5 new, ceiling 4: all 4 places take new work, in queue order" "701 702 703 704" "$(spawned)"
want_in "the tick log shows the live count by priority" 'split: 4 live \(of 4, by priority\)' "$out"
want_not_in "and names no cap"             'open changes' "$out"
want "the live view's file shows it too"   "4/4" "$(jq -r '"\(.new.live)/\(.new.slots)"' "$C/capacity.json")"
want "and carries no removed split field" "false false false" "$(jq -r '"\(has("healAll")) \(has("healing")) \(has("redsWaiting"))"' "$C/capacity.json")"
fresh; queue 701 702 703; echo 702 > "$FIX/claims.txt"
out=$(COORDINATOR_CAP=4 ticks 1)
want "next names the next spawnable entry" "703" "$(awk -F'\t' '$2=="plan"{n=$5; sub(/.*next=/,"",n); print n}' "$C/actions.log" | tail -1)"
want_in "  and the plan line has no healing field" 'new=1/[0-9]+ next=703' "$(awk -F'\t' '$2=="plan"' "$C/actions.log" | tail -1)"
# ready_as <priority> <tickets…> — new work whose tickets carry that priority
ready_as() { local p="$1" t; shift; for t in "$@"; do fix_issue "$t" OPEN "$p,status:ready"; bash "$Q" add "$t" >/dev/null; done; }
fresh; ready_as P2 601 602 603 604 605 606; fix_issue 701 OPEN "P1,status:ready"; bash "$Q" add 701 >/dev/null
SWARM_IDLE=90 COORDINATOR_CAP=2 ticks 1 >/dev/null
want "6 P2 tickets wait, one P1 ticket: it starts first" "701 601" "$(spawned)"
echo "--- which ticket starts first follows priority ---"
fresh; ready_as P3 601; ready_as P1 602; ready_as P0 603; queue 701
COORDINATOR_CAP=1 ticks 1 >/dev/null
want "the P0 takes the one place" "603" "$(spawned)"

unset COORDINATOR_OPEN_PR_CAP

echo "--- coordinator.openPrCap: over the cap nothing new starts ---"
# Hermetic: whether a person drafted a PR is read through a stand-in (no PR here is a person's),
# never the real forge. Without it these cases read GitHub on a laptop and failed on CI.
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/pstop-none"; chmod +x "$BIN/pstop-none"
export OPEN_WORK_PERSON_STOP="$BIN/pstop-none" OPEN_WORK_DRAFTED_CACHE="$FIX/pdrafted-none.tsv"
# open_prs <count> — that many open PRs, none a draft and none for a queued ticket (a draft
# nothing builds is not in flight, so drafts here would not count)
open_prs() {
  jq -n --argjson n "$1" '[range(0; $n) | {number: (9000 + .), headRefName: "tkt-\(9000 + .)-open", headRefOid: "h\(.)",
    isDraft: false, mergeStateStatus: "CLEAN", labels: [], statusCheckRollup: []}]' > "$FIX/gh/prs-all.json"
}
proc_q() { local l="$1" t; shift; for t in "$@"; do fix_issue "$t" OPEN "$l"; bash "$Q" add "$t" >/dev/null; done; }
cap_tick() { # <counted open PRs> — three new 701.., room for 6
  fresh; open_prs "$1"; queue 701 702 703
  SWARM_IDLE=90 COORDINATOR_CAP=6 ticks 1
}
out=$(cap_tick 12)
want "12 open, cap 10: nothing new starts" "" "$(spawned)"
want_in "the tick log shows the cap"       'open changes 12 / cap 10: finishing before starting' "$out"
want_in "and names what waits"             '3 new ticket\(s\) wait' "$out"
want "the live view's file carries it"     "12 10 true" "$(jq -r '"\(.openPrs.count) \(.openPrs.cap) \(.openPrs.over)"' "$C/capacity.json")"
out=$(cap_tick 9)
want "9 open, cap 10: new work starts"     "701 702 703" "$(spawned)"
want_in "the tick log says new may start"  'open changes 9 / cap 10: new work may start' "$out"
want "the live view's file: under"         "9 10 false" "$(jq -r '"\(.openPrs.count) \(.openPrs.cap) \(.openPrs.over)"' "$C/capacity.json")"
out=$(cap_tick 10)
want "exactly at the cap is not over it"    "701 702 703" "$(spawned)"
# A draft nothing is building is not in flight (2026-10-24: 10 of 13 open PRs were parked drafts
# and the cap held every start after the reset).
fresh; open_prs 12; jq 'map(.isDraft = true)' "$FIX/gh/prs-all.json" > "$FIX/drafts.json" && mv "$FIX/drafts.json" "$FIX/gh/prs-all.json"
for n in $(seq 9000 9011); do fix_issue "$n" OPEN "P1,status:in-review"; done
queue 701; out=$(SWARM_IDLE=90 COORDINATOR_CAP=6 ticks 1)
want_in "12 drafts nothing is building do not count: under the cap" 'open changes 0 / cap 10: new work may start' "$out"
want_in "  and the tick says why"           'not counted.*#9000 is a draft nothing is building' "$out"
fresh; open_prs 11; jq 'map(if .number == 9001 then .isDraft = false else .isDraft = true end)' "$FIX/gh/prs-all.json" > "$FIX/drafts.json" && mv "$FIX/drafts.json" "$FIX/gh/prs-all.json"
for n in $(seq 9000 9010); do fix_issue "$n" OPEN "P1,status:in-review"; done
queue 701; out=$(SWARM_IDLE=90 COORDINATOR_CAP=6 COORDINATOR_OPEN_PR_CAP=1 ticks 1)
want_not_in "10 parked drafts and 1 live PR, cap 1: not over" 'finishing before starting' "$out"
want_in "  only the live PR counts"         'open changes 1 / cap 1: new work may start' "$out"
fresh; open_prs 12; jq 'map(.isDraft = true)' "$FIX/gh/prs-all.json" > "$FIX/drafts.json" && mv "$FIX/drafts.json" "$FIX/gh/prs-all.json"
for n in $(seq 9000 9011); do fix_issue "$n" OPEN "P1,status:in-review"; done
seq 9000 9010 > "$FIX/claims.txt"; queue 701; out=$(SWARM_IDLE=90 COORDINATOR_CAP=6 ticks 1)
want_in "11 drafts a run holds still count: over the cap" 'open changes 11 / cap 10: finishing before starting' "$out"
want_not_in "  and nothing new starts"           '701' "$(spawned)"
fresh; open_prs 12; proc_q "P3,process,status:ready" 702; queue 701
out=$(SWARM_IDLE=90 COORDINATOR_CAP=6 ticks 1)
want "a process fix still starts over the cap" "702" "$(spawned)"
fresh; open_prs 12; queue 701
SWARM_IDLE=90 COORDINATOR_CAP=6 COORDINATOR_OPEN_PR_CAP=20 ticks 1 >/dev/null
want "coordinator.openPrCap sets N: 12 under 20 starts new" "701" "$(spawned)"
fresh; open_prs 30; queue 701
out=$(SWARM_IDLE=90 COORDINATOR_CAP=6 COORDINATOR_OPEN_PR_CAP=0 ticks 1)
want "a cap of 0 is off"                   "701" "$(spawned)"
want_not_in "and says nothing of a cap"     'open changes' "$out"
fresh; open_prs 3; ready_as P2 601; fix_issue 701 OPEN "P0,status:ready"; bash "$Q" add 701 >/dev/null
SWARM_IDLE=90 COORDINATOR_CAP=1 ticks 1 >/dev/null
want "under the cap, one place: a P0 ticket starts before a P2 one" "701" "$(spawned)"
fresh; open_prs 12; ready_as P2 601; fix_issue 701 OPEN "P0,status:ready"; bash "$Q" add 701 >/dev/null
SWARM_IDLE=90 COORDINATOR_CAP=1 ticks 1 >/dev/null
want "over the cap a P0 ticket still starts (capExemptPriorities); the P2 one waits" "701" "$(spawned)"
fresh; open_prs 12; ready_as P2 601; fix_issue 701 OPEN "P0,status:ready"; bash "$Q" add 701 >/dev/null
COORDINATOR_CAP_EXEMPT_PRIORITIES="" SWARM_IDLE=90 COORDINATOR_CAP=1 ticks 1 >/dev/null
want "with no exempt priority the P0 waits over the cap too" "" "$(spawned)"

echo "--- the cap waits only on work something is finishing; nothing is queued to repair (23 Oct: 19 open, 17 clashing, 0 builds) ---"
# A person's draft, read off a stand-in person-stop: PR 8005 and 8105 are a person's.
cat > "$BIN/pstop" <<'SH'
#!/usr/bin/env bash
echo "$2" >> "$FIX/pstop.log"
case "$2" in 8005|8105) echo "a person (pm) put PR #$2 back to draft on 2026-10-22"; exit 0 ;; esac
exit 1
SH
chmod +x "$BIN/pstop"; export OPEN_WORK_PERSON_STOP="$BIN/pstop" OPEN_WORK_DRAFTED_CACHE="$FIX/pdrafted.tsv"
# prs_of <first> <dirty> <green> [draft-every] — <dirty> clashing PRs then <green> green ones,
# numbered from <first>; every <draft-every>th one a draft (0: none). Ticket N for PR N.
prs_of() {
  jq -n --argjson f "$1" --argjson d "$2" --argjson g "$3" --argjson e "${4:-0}" '[range(0; $d + $g) | . as $i
    | {number: ($f + $i), headRefName: "tkt-\($f + $i)-x", headRefOid: "h\($f + $i)", updatedAt: "2026-10-23T08:00:00Z",
       isDraft: ($e > 0 and ($i % $e) == 0), mergeStateStatus: (if $i < $d then "DIRTY" else "CLEAN" end),
       labels: [], statusCheckRollup: []}]' > "$FIX/gh/prs-all.json"
}
tickets_of() { local l="$1" n; shift; for n in "$@"; do fix_issue "$n" OPEN "$l"; done; }

fresh; rm -f "$FIX/pdrafted.tsv"; : > "$FIX/pstop.log"; prs_of 8000 17 2 3
tickets_of "P1,status:in-review" $(seq 8000 8018); fix_issue 8003 OPEN "P1,status:parked"
queue 701
out=$(SWARM_IDLE=90 COORDINATOR_CAP=4 ticks 1)
want "19 open, 17 clashing: nothing is queued to repair them" "0" "$(grep -c 'finish: queued #' <<<"$out")"
want "  and nothing is spawned for them"      "" "$(spawned)"
want_in "  each clash is on its rebuild clock instead" 'rebuild: PR #8001 is stuck \(it conflicts with its base branch\) — 0 of 60 min' "$out"
want_in "  a parked ticket's clash is left as it is" 'rebuild: PR #8003 left as it is — #8003 waits on a person \(status:parked\)' "$out"
want_in "the 12 non-drafts count; the 7 drafts nothing builds do not: still over" 'open changes 12 / cap 10: finishing before starting' "$out"
want_not_in "and nothing new starts over the cap" '701' "$(spawned)"
out=$(SWARM_IDLE=90 COORDINATOR_CAP=4 ticks 1)
want "the next tick reads no unchanged draft's timeline twice" "$(sort -u "$FIX/pstop.log" | grep -c .)" "$(grep -c . "$FIX/pstop.log")"

echo "--- a PR a person drafted, or labelled do-not-merge, is neither counted nor queued ---"
fresh; rm -f "$FIX/pdrafted.tsv"; prs_of 8100 6 6 0
jq 'map(if .number == 8105 then .isDraft = true elif .number == 8104 then .labels = [{name: "do-not-merge"}] else . end)' "$FIX/gh/prs-all.json" > "$FIX/p.json" && mv "$FIX/p.json" "$FIX/gh/prs-all.json"
tickets_of "P1,status:in-review" $(seq 8100 8111)
out=$(SWARM_IDLE=90 COORDINATOR_CAP=4 COORDINATOR_OPEN_PR_CAP=11 ticks 1)
want_in "the person's draft is left as it is"  'rebuild: PR #8105 left as it is — a person put it back to draft' "$out"
want_in "nor the do-not-merge one"              'rebuild: PR #8104 left as it is — the PR carries do-not-merge' "$out"
want_in "neither counts: 10 of 12"               'open changes 10 / cap 11: new work may start' "$out"
want_in "and the tick names why"                 'finish: 2 of 12 open PR\(s\) not counted.*#8104 carries do-not-merge.*#8105 is a draft nothing is building' "$out"
fresh; prs_of 8200 0 1 0; jq '.[0].isDraft = true | .[0].number = 8005 | .[0].headRefName = "tkt-8005-x"' "$FIX/gh/prs-all.json" > "$FIX/p.json" && mv "$FIX/p.json" "$FIX/gh/prs-all.json"
fix_issue 8005 OPEN "P1"; out=$(SWARM_IDLE=90 COORDINATOR_CAP=4 COORDINATOR_OPEN_PR_CAP=11 ticks 1)
want "a person's draft is never spawned"        "" "$(spawned)"

echo "--- a polish list never ships alone while other work can start, full or not ---"
# list_issue <n> <items> — an open polish list holding that many unticked items
list_issue() {
  local body="## Items" i
  for i in $(seq 1 "$2"); do body="$body"$'\n'"- [ ] item $i"; done
  body="$body"$'\n'"- [x] done already"
  jq -n --argjson n "$1" --arg b "$body" '{number:$n, state:"OPEN", title:"Polish list: Inbox", body:$b,
    labels:([ "polish-list","screen:inbox","P3","status:ready","type:bug" ] | map({name:.}))}' > "$FIX/gh/issue-$1.json"
  bash "$Q" add "$1" >/dev/null
}
fresh; fix_issue 701 OPEN "P2,status:ready"; bash "$Q" add 701 >/dev/null; list_issue 801 3
out=$(SWARM_IDLE=90 COORDINATOR_CAP=6 ticks 1)
want "3 items while a P2 ticket can start: only the P2 starts" "701" "$(spawned)"
want_in "it says the list rides along"     'skip #801 \(polish list\): 3 free item\(s\) — rides along' "$out"
fresh; fix_issue 701 OPEN "P2,status:ready"; bash "$Q" add 701 >/dev/null; list_issue 801 8
out=$(SWARM_IDLE=90 COORDINATOR_CAP=6 ticks 1)
want "8 items: no batch build of the list, only the P2" "701" "$(spawned)"
want_in "it rides along instead"           'skip #801 \(polish list\): 8 free item\(s\) — rides along' "$out"
fresh; fix_issue 701 OPEN "P2,status:ready"; bash "$Q" add 701 >/dev/null; list_issue 801 12
SWARM_IDLE=90 COORDINATOR_CAP=6 ticks 1 >/dev/null
want "12 items: still no build of its own"  "701" "$(spawned)"
fresh; list_issue 801 3; fix_issue 802 OPEN "P3,status:ready"; bash "$Q" add 802 >/dev/null
SWARM_IDLE=90 COORDINATOR_CAP=6 ticks 1 >/dev/null
want "nothing else can start: polish starts, a short list and a P3 ticket" "801 802" "$(spawned)"
fresh; fix_issue 701 OPEN "P2,status:ready"; bash "$Q" add 701 >/dev/null; fix_issue 802 OPEN "P3,status:ready"; bash "$Q" add 802 >/dev/null
out=$(SWARM_IDLE=90 COORDINATOR_CAP=6 ticks 1)
want "a P3 ticket waits while a P2 can start" "701" "$(spawned)"
want_in "named once"                       'polish: 1 polish ticket\(s\) wait while other work can start' "$out"
echo "--- a polish list with nothing free on it is never work, even on an idle factory ---"
# list_body_issue <n> <body> — an open polish list with exactly that body
list_body_issue() {
  jq -n --argjson n "$1" --arg b "$2" '{number:$n, state:"OPEN", title:"Polish list: Inbox", body:$b,
    labels:([ "polish-list","screen:inbox","P3","status:ready","type:bug" ] | map({name:.}))}' > "$FIX/gh/issue-$1.json"
}
fresh; list_body_issue 804 $'## Items\n- [x] done\n- [ ] reserved (in PR #9)\n- [ ] taken (taken by #77)\n'; bash "$Q" add 804 >/dev/null
out=$(SWARM_IDLE=90 COORDINATOR_CAP=6 ticks 1)
want "nothing else queued, and still not started" "" "$(spawned)"
want_in "it says why"                      'skip #804 \(polish list\): nothing free on it' "$out"
fresh; list_body_issue 804 $'## Items\n- [x] done\n'; bash "$Q" add 804 --first --note "Resume: run cut off" >/dev/null
SWARM_IDLE=90 COORDINATOR_CAP=6 ticks 1 >/dev/null
want "not even put back at the front"      "" "$(spawned)"
fresh; list_body_issue 805 $'## Items\n- [ ] mine (taken by #805)\n'; bash "$Q" add 805 >/dev/null
SWARM_IDLE=90 COORDINATOR_CAP=6 ticks 1 >/dev/null
want "a list whose only items its own run took can resume" "805" "$(spawned)"

echo "--- the polish hold never parks a resume, an owner's answer or half-built work ---"
fresh; fix_issue 701 OPEN "P2,status:ready"; bash "$Q" add 701 >/dev/null
fix_issue 802 OPEN "P3,status:ready"; bash "$Q" add 802 --first --note "Resume: run cut off" >/dev/null
SWARM_IDLE=90 COORDINATOR_CAP=6 ticks 1 >/dev/null
want "a P3 resume starts beside the P2, after it" "701 802" "$(spawned)"
fresh; fix_issue 701 OPEN "P2,status:ready"; bash "$Q" add 701 >/dev/null
fix_issue 803 OPEN "P3,status:partial"; bash "$Q" add 803 >/dev/null
SWARM_IDLE=90 COORDINATOR_CAP=6 ticks 1 >/dev/null
want "a half-built P3 ticket starts beside the P2" "701 803" "$(spawned)"
echo "--- a full P3 list no longer jumps work with no priority ---"
fresh; fix_issue 702 OPEN "status:ready"; bash "$Q" add 702 >/dev/null; list_issue 801 8
SWARM_IDLE=90 COORDINATOR_CAP=1 ticks 1 >/dev/null
want "one place: the unprioritised ticket takes it, not the full list" "702" "$(spawned)"

# Back to the fixture's reading: later sections must never read the real machine.
export SWARM_IDLE=90; unset SWARM_CORES

echo "--- coordinator.cap: 0 spawns nothing; not a number holds, named ---"
fresh; queue 501
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=0 tick)
want "cap 0: no start"                     "" "$(spawned)"
want_in "and says so"                      '0 live, cap 0 — no slot' "$out"
fresh; queue 501
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=four tick)
want "cap 'four': no start"                "" "$(spawned)"
want_in "and names the bad value"          "coordinator.cap is 'four', not a whole number — holding" "$out"

echo "--- a missing reading never counts as room: every reading the spawn decision takes ---"
# Every machine reading in load.sh has a *_FILE seam; an empty file is a reading
# nobody could take. A new reading without a seam fails the first row.
LOADSH="$HERE/../swarm/load.sh"
for fn in swarm_cpu_idle swarm_load swarm_cores swarm_free_mem_gb; do
  body=$(sed -n "/^$fn() {/,/^}/p" "$LOADSH")
  want_in "$fn has a file seam"            'SWARM_[A-Z_]*_FILE' "$body"
done
seams=$(grep -o 'SWARM_[A-Z_]*_FILE' "$LOADSH" | sort -u)
want "the seams found"                     "SWARM_CORES_FILE SWARM_FREE_MEM_FILE SWARM_IDLE_FILE SWARM_LOAD_FILE" "$(echo $seams)"
: > "$FIX/unread"
for seam in $seams; do
  fresh; queue 501
  out=$(env -u SWARM_MAX_LOAD "$seam=$FIX/unread" COORDINATOR_SHADOW=0 bash "$T" 2>&1)
  want "$seam unread: no start"            "" "$(spawned)"
  want_in "$seam unread: the tick says unread" 'unread' "$out"
done
fresh; queue 501
out=$(env -u SWARM_MAX_LOAD COORDINATOR_SHADOW=0 bash "$T" 2>&1)
want "every reading taken: it starts (the guard flags nothing correct)" "501" "$(spawned)"

echo "--- the class survives a spawner that records none ---"
# The coordinator keeps its own record of each run's class, so a spawner whose run
# record carries no class (an older one) is still counted as what it was started for.
mkdir -p "$FIX/oldspawn"
cat > "$FIX/oldspawn/spawn-claim.sh" <<'SH'
#!/usr/bin/env bash
# An older spawner: a run record with no class and no operator field.
printf '%s\tno-class\n' "$1" >> "$SPAWNS"
printf '{"run_id":"claim-%s-old","ticket":"%s","child_pid":%s,"log":"/dev/null"}\n' "$1" "$1" "$TEST_PID" \
  > "$HARNESS_STATE_DIR/runs/claim-$1-old.json"
SH
chmod +x "$FIX/oldspawn/spawn-claim.sh"
# One agent of room a tick, so the second tick reads the class the first recorded.
oldspawn() { COORDINATOR_OPEN_PR_CAP=0 SWARM_SPAWN="$FIX/oldspawn/spawn-claim.sh" SWARM_IDLE=23 SWARM_CORES=10 COORDINATOR_SHADOW=0 COORDINATOR_CAP=4 bash "$T" 2>&1; }
fresh; queue 701 702
oldspawn >/dev/null
want "the older spawner ran"               "701	no-class" "$(head -1 "$SPAWNS")"
want "its record carries no class"         "" "$(jq -r '.class // empty' "$STATE/runs/claim-701-old.json")"
want "the coordinator recorded it"         "new" "$(awk -F'\t' '$1=="claim-701-old"{print $3}' "$C/run-classes.tsv")"
oldspawn >/dev/null
want "so the next tick builds the next one" "701 702" "$(cut -f1 "$SPAWNS" | tr '\n' ' ' | sed 's/ $//')"
want "the live view counts both"           "2" "$(jq -r '.new.live' "$C/capacity.json")"
rm -rf "$FIX/oldspawn"

echo "--- never a claimed, gated or held ticket ---"
fresh; queue 501 502 503 504
echo 501 > "$FIX/claims.txt"
fix_issue 502 OPEN "status:gated"
fix_issue 503 OPEN "status:ready,needs:human-approval"
out=$(COORDINATOR_SHADOW=0 tick)
want "only the free one spawns"            "504" "$(spawned)"
want_in "claimed is named"                 'skip #501 \(new\): claimed' "$out"
want_in "gated is named"                   'skip #502 \(new\): status:gated' "$out"
want_in "the hold label is named"          'skip #503 \(new\): needs:human-approval' "$out"
# A child of a batch ticket is built by the batch's one PR, never on its own.
fresh; queue 505 506; fix_issue 505 OPEN "status:ready,status:batched"
out=$(COORDINATOR_SHADOW=0 tick)
want "a batched child is never started alone" "506" "$(spawned)"
want_in "and the skip names the batch label" 'skip #505 \(new\): status:batched' "$out"
fresh; queue 501
printf 'owner said stop\n' > "$STATE/swarm/HOLD"
out=$(COORDINATOR_SHADOW=0 tick)
want "the swarm hold stops every spawn"    "" "$(spawned)"
want_in "and names the hold"               'held — owner said stop' "$out"

echo "--- process fixes trump everything: priority, kind and polish ---"
fresh; proc_q "P0,status:ready" 701; proc_q "P3,process,status:ready" 702
out=$(SWARM_IDLE=90 COORDINATOR_CAP=1 ticks 1)
want "a P3 process fix starts before a P0 that is not one" "702" "$(spawned)"
want_in "and the log says why"             'spawned #702 \(new\) in any free place, a process fix first' "$out"
fresh; proc_q "P0,status:ready" $(seq 601 612); proc_q "P3,process,status:ready" 702
SWARM_IDLE=90 COORDINATOR_CAP=1 ticks 1 >/dev/null
want "12 P0 tickets waiting: the process fix still takes the one place" "702" "$(spawned)"
fresh; proc_q "P0,status:ready" 601; proc_q "P2,status:ready" 701; proc_q "process,status:ready" 702 703
SWARM_IDLE=90 COORDINATOR_CAP=2 ticks 1 >/dev/null
want "both places go to process fixes, ahead of the P0" "702 703" "$(spawned | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
fresh; proc_q "P1,status:ready" 701; proc_q "P2,status:ready" 702
fix_issue 703 OPEN "P3,process,status:ready"; bash "$Q" add 703 >/dev/null
fix_issue 704 OPEN "P0,status:ready"; bash "$Q" add 704 --front >/dev/null
want "the queue order: the process fix ahead even of an entry put on top" "703 704 701 702" \
  "$(bash "$Q" list | awk '/^ *[0-9]+\./ { printf "%s%s", (n++ ? " " : ""), substr($2, 2) }')"

echo "--- a hold for process fixes lets them through and holds everything else ---"
fresh; proc_q "P0,status:ready" 501; proc_q "process,status:ready" 502
printf 'quiet night, for process fixes (held 2026-10-20T22:00Z by dom)\n' > "$STATE/swarm/HOLD"
out=$(SWARM_IDLE=90 ticks 1)
want "held for process fixes: only the process fix starts" "502" "$(spawned)"
want_in "and the log names the hold"       'held for everything but process fixes \(process\) — quiet night' "$out"
fresh; proc_q "P0,status:ready" 501; proc_q "process,status:ready" 502
printf 'owner said stop\nallow: process\n' > "$STATE/swarm/HOLD"
SWARM_IDLE=90 ticks 1 >/dev/null
want "an allow: process line does the same" "502" "$(spawned)"
fresh; proc_q "P0,status:ready" 501; proc_q "process,status:ready" 502
printf 'owner said stop\n' > "$STATE/swarm/HOLD"
out=$(SWARM_IDLE=90 ticks 1)
want "a plain hold holds the process fix too" "" "$(spawned)"
want_in "and names the hold"               'held — owner said stop' "$out"

echo "--- a busy machine spawns nothing: the same test as the gate ---"
fresh; queue 501
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=9 tick)
want "cpu idle under the floor: no spawn"  "" "$(spawned)"
want_in "and names the reading"            'machine busy \(cpu idle 9%, floor 15%\) — holding' "$out"
fresh; queue 501
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=90 SWARM_LOAD=99 SWARM_MAX_LOAD=80 tick)
want "load over the backstop: no spawn"    "" "$(spawned)"
want_in "and names the load"               'machine busy \(load 99, limit 80\) — holding' "$out"
want_in "the ceiling reads no room over the backstop" 'ceiling: 0 running · no room for more: load 99, limit 80' "$out"
fresh; queue 501
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=41 SWARM_LOAD=60 SWARM_CORES=10 tick)
want "41% idle at load 60 on 10 cores spawns" "501" "$(spawned)"

echo "--- one tick at a time ---"
fresh; queue 501
mkdir -p "$C/tick.lock"; echo "$$" > "$C/tick.lock/pid"
LC_ALL=C TZ=UTC ps -o lstart= -p "$$" | tr -s ' ' | sed 's/^ *//;s/ *$//' > "$C/tick.lock/started"
out=$(COORDINATOR_SHADOW=0 tick)
want "a running tick blocks a second one"  "" "$(spawned)"
want_in "and it says so"                   'another tick \(pid [0-9]+\) is running' "$out"
want "the holder's lock is left in place"  "$$" "$(cat "$C/tick.lock/pid")"
sh -c 'exit 0' & dead=$!; wait "$dead"
echo "$dead" > "$C/tick.lock/pid"
out=$(COORDINATOR_SHADOW=0 tick)
want "a dead holder's lock is taken over"  "501" "$(spawned)"
want "and released at the end"             "no" "$([ -d "$C/tick.lock" ] && echo yes || echo no)"

echo "--- a reused pid is not the holder; a lock being taken is ---"
fresh; queue 501
mkdir -p "$C/tick.lock"; echo "$$" > "$C/tick.lock/pid"; echo "Thu Jan  1 00:00:00 1970" > "$C/tick.lock/started"
COORDINATOR_SHADOW=0 tick >/dev/null
want "a live pid that started elsewhere is not the holder" "501" "$(spawned)"
fresh; queue 501
mkdir -p "$C/tick.lock"
out=$(COORDINATOR_SHADOW=0 tick)
want "a lock with no pid yet is being taken" "" "$(spawned)"
want_in "and it waits its turn"            'another tick is taking the lock' "$out"

echo "--- it fails closed: unreadable claims or pull requests spawn nothing ---"
fresh; queue 501
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CLAIMS_CMD=false tick)
want "an unreadable claim list spawns nothing" "" "$(spawned)"
want_in "and says so"                      'claim list could not be read' "$out"
want_in "and tells the owner"              'cannot read the claim list' "$(cat "$FIX/notify.log")"
fresh; queue 501; rm -f "$FIX/gh/prs-all.json" "$FIX/gh/empty.json"
printf '#!/usr/bin/env bash\ncase "$*" in *OpenPullRequests*) exit 1 ;; esac\nexec "%s" "$@"\n' "$BIN/gh" > "$FIX/gh-nopr"; chmod +x "$FIX/gh-nopr"
out=$(COORDINATOR_SHADOW=0 SWARM_GH="$FIX/gh-nopr" tick)
want "unreadable pull requests spawn nothing" "" "$(spawned)"
want_in "and says so"                      'pull requests could not be read' "$out"

echo "--- one ticket, one change: a queued ticket with an open PR waits, never built beside it ---"
fresh; queue 501 502
jq -n '[{number:9, headRefName:"tkt-501-x", headRefOid:"s", isDraft:true, mergeStateStatus:"CLEAN", labels:[], statusCheckRollup:[]}]' > "$FIX/gh/prs-all.json"
out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick)
want "the open draft PR's ticket is not spawned" "" "$(grep '^501	' "$SPAWNS")"
want "and the other new ticket is"         "502	new" "$(grep '^502	' "$SPAWNS")"
want_in "and the skip says why"            'skip #501 \(new\): has an open PR #9 — it merges, or is rebuilt fresh' "$out"
want "it stays queued for when the PR is gone" "501" "$(jq -r '.tickets[].n' "$C/queue.json" | tr '\n' ' ' | sed 's/ $//')"
fresh; queue 501; fix_required "Typecheck"
jq -n '[{number:9, headRefName:"tkt-501-x", headRefOid:"s", isDraft:false, mergeStateStatus:"BLOCKED", labels:[], statusCheckRollup:[{name:"Typecheck", status:"COMPLETED", conclusion:"FAILURE"}]}]' > "$FIX/gh/prs-all.json"
out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick)
want "a ready red PR's ticket waits too" "" "$(spawned)"
want_in "  its PR is on the rebuild clock"  'rebuild: PR #9 is stuck \(required check\(s\) failed: Typecheck\)' "$out"
fix_required
fresh; queue 501
jq -n '[{number:9, headRefName:"tkt-501-x", headRefOid:"s", isDraft:true, mergeStateStatus:"CLEAN", labels:[], statusCheckRollup:[]}]' > "$FIX/gh/prs-all.json"
mkdir -p "$STATE/driver/501"; jq -n '{ticket:"501", mode:"build", done:["start","size","plan"]}' > "$STATE/driver/501/state.json"
SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick >/dev/null
want "this host's own unshipped build of it resumes on its draft" "501	new" "$(grep '^501	' "$SPAWNS")"
rm -rf "$STATE/driver/501"

echo "--- no run without a change to make ---"
# About 16 runs in 3 days: repairs with no open PR, closed tickets, builds of tickets not ready.
fresh; fix_issue 501 OPEN "status:in-review"; bash "$Q" add 501 --class repair >/dev/null 2>&1
out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick)
want "an older repair row with no open PR, ticket in review: nothing spawned" "" "$(spawned)"
want_in "  it is new work, which waits while in review" 'skip #501 \(new\): status:in-review' "$out"
fresh; fix_issue 501 OPEN "status:drafting"; bash "$Q" add 501 >/dev/null
out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick)
want "a build of a ticket not ready: nothing spawned" "" "$(spawned)"
want_in "  and says why"                     'skip #501 \(new\): not status:ready \(status:drafting\)' "$out"
fresh; fix_issue 501 OPEN "status:claimed"; bash "$Q" add 501 --note "Resume: run claim-501-a was cut off by the wall." >/dev/null
SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick >/dev/null
want "a resume carries on whatever its status" "501" "$(spawned)"
fresh; fix_issue 501 CLOSED "status:ready"; bash "$Q" add 501 >/dev/null
out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick)
want "a closed ticket: nothing spawned"      "" "$(spawned)"

echo "--- a row an older version queued as repair or approved-merge is new work ---"
fresh; fix_issue 501 OPEN "status:ready"; bash "$Q" add 501 --class repair --first --note "Finish PR #9: a required check failed." >/dev/null 2>&1
SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick >/dev/null
want "a ready ticket queued as repair, no PR: started as new" "501	new" "$(cat "$SPAWNS")"
fresh; mkdir -p "$C"; fix_issue 501 OPEN "status:ready"
printf '{"scope":"x","tickets":[{"n":501,"class":"approved-merge","note":"","pinned":true}]}\n' > "$C/queue.json"
SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick >/dev/null
want "an approved-merge row written by an older version is new work too" "501	new" "$(cat "$SPAWNS")"
fresh; fix_issue 501 CLOSED "status:ready"; bash "$Q" add 501 --class repair >/dev/null 2>&1
SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick >/dev/null
want "a closed ticket: nothing spawned"     "" "$(spawned)"

echo "--- a cancelled required check is re-run, and its rebuild clock starts ---"
# Two required checks cancelled twice on one PR with no runner; each went to a builder.
rerun_world() { fresh; mkdir -p "$C"; fix_issue 501 OPEN "status:in-review"; fix_required "Typecheck"
  jq -n --arg h "$1" '[{number:9, headRefName:"tkt-501-x", headRefOid:$h, isDraft:false, mergeStateStatus:"BLOCKED", labels:[],
    statusCheckRollup:[{name:"Typecheck", status:"COMPLETED", conclusion:"CANCELLED", detailsUrl:"https://github.com/acme/widgets/actions/runs/777/job/1"}]}]' > "$FIX/gh/prs-all.json"; }
rerun_world s; : > "$GH_LOG"
out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick)
want "cancelled: nothing spawned, nothing closed" "0" "$(grep -c '^pr close' "$GH_LOG")"
want "  the run is re-run, its failed jobs" "1" "$(grep -c '^run rerun 777 --failed' "$GH_LOG")"
want "  and its rebuild clock starts"        "9" "$(cut -f1 "$C/rebuild-clock.did.tsv" 2>/dev/null)"
# fresh() clears the coordinator's dir, so the ledger is carried across it by hand.
cp "$C/reruns.tsv" "$FIX/reruns.keep"
rerun_world s; cp "$FIX/reruns.keep" "$C/reruns.tsv"; SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick >/dev/null
cp "$C/reruns.tsv" "$FIX/reruns.keep"; rerun_world s; cp "$FIX/reruns.keep" "$C/reruns.tsv"; : > "$GH_LOG"
out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick)
want "a third cancel on the head: no re-run" "0" "$(grep -c '^run rerun' "$GH_LOG")"
rerun_world s; : > "$GH_LOG"
out=$(SWARM_SPAWN="$BIN/spawn-live" tick)
want "shadow: nothing re-run"               "0" "$(grep -c '^run rerun' "$GH_LOG")"
fix_required

echo "--- rebuild, don't repair: a PR red past coordinator.rebuildAfterMin is closed and its ticket built fresh ---"
rb_world() { # <labels> — ticket 501's one open PR red on a required check, its plan on this host's record
  fresh; fix_issue 501 OPEN "${1:-P1,status:in-review}"; fix_required "Typecheck"; mkdir -p "$C"
  printf '{}\n' > "$FIX/gh/api-repos_acme_widgets_git_refs.json"
  printf '[{"sha":"dev1"}]\n' > "$FIX/gh/api-repos_acme_widgets_commits_sha_develop_per_page_5.json"
  printf '{"check_runs":[{"name":"Typecheck","id":1,"status":"completed","conclusion":"success","completed_at":"2026-11-01T09:00:00Z"}]}\n' \
    > "$FIX/gh/api-repos_acme_widgets_commits_dev1_check-runs_per_page_100_filter_all.json"
  jq -n '[{number:5501, headRefName:"tkt-501-x", headRefOid:"f501", baseRefName:"develop", isDraft:false, mergeStateStatus:"BLOCKED", labels:[],
    statusCheckRollup:[{name:"Typecheck", status:"COMPLETED", conclusion:"FAILURE"}]}]' > "$FIX/gh/prs-all.json"
  mkdir -p "$STATE/driver/501/steps"
  printf '{"step":"plan","tasks":[{"title":"Keep the scroll place","files":["src/feed.ts"]}]}\n' > "$STATE/driver/501/steps/plan.json"
  jq -n '{ticket:"501", mode:"build", step:"ship", done:["start","plan","build","self-check","review","record","ship"], counters:{}}' > "$STATE/driver/501/state.json"
  : > "$GH_LOG"
}
T0=$(date +%s)
rb_world
out=$(SWARM_NOW=$T0 COORDINATOR_REBUILD_AFTER_MIN=30 SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick)
want "first tick red: not closed"               "0" "$(grep -c '^pr close' "$GH_LOG")"
want_in "  its clock starts"                    'rebuild: PR #5501 is stuck \(required check\(s\) failed: Typecheck\) — 0 of 30 min' "$out"
want "  and no agent is sent to it"             "" "$(spawned)"
out=$(SWARM_NOW=$(( T0 + 31 * 60 )) COORDINATOR_REBUILD_AFTER_MIN=30 SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick)
want "31 minutes on: the head is kept on a stale ref" "1" "$(grep -c '^api repos/acme/widgets/git/refs -f ref=refs/stale/501/pr-5501 -f sha=f501' "$GH_LOG")"
want "  the PR is closed, its branch deleted"   "1" "$(grep -c '^pr close 5501 .*--delete-branch .*Closed to rebuild fresh' "$GH_LOG")"
want "  this host's driver record forgets every step (15735)" "0" "$(jq '.done | length' "$STATE/driver/501/state.json")"
want "  its answers are archived, not left to be resumed" "1" "$(ls "$STATE/driver/501/steps/archive/"*/plan.json 2>/dev/null | grep -c .)"
want_in "  the ticket is queued fresh with a Rebuild: brief" '^Rebuild: PR #5501 could not merge within 30 min' "$(jq -r '.tickets[]? | select(.n == 501) | .note' "$C/queue.json" 2>/dev/null; grep '^501' "$SPAWNS")"
want_in "  the brief carries the reviewed plan" 'Keep the scroll place \(src/feed.ts\)' "$(jq -r '.tickets[]? | select(.n == 501) | .note' "$C/queue.json" 2>/dev/null; grep '^501' "$SPAWNS")"
want_in "  and the tick says it"                'rebuild: closed PR #5501 .*head kept at refs/stale/501/pr-5501.* — #501 is queued to build fresh' "$out"
want "  the rebuild is on record"               "rebuild" "$(awk -F'\t' '$2 == 501 && $3 == "rebuild"' "$C/run-classes.tsv" | cut -f3 | tail -1)"
rm -rf "$STATE/driver/501"
rb_world "P1,status:in-review,needs:owner-decision"
SWARM_NOW=$T0 COORDINATOR_REBUILD_AFTER_MIN=30 COORDINATOR_SHADOW=0 tick >/dev/null
SWARM_NOW=$(( T0 + 300 * 60 )) COORDINATOR_REBUILD_AFTER_MIN=30 COORDINATOR_SHADOW=0 tick >/dev/null
want "a ticket waiting on the owner: never closed" "0" "$(grep -c '^pr close' "$GH_LOG")"
rb_world
SWARM_NOW=$T0 COORDINATOR_REBUILD_AFTER_MIN=30 tick >/dev/null
out=$(SWARM_NOW=$(( T0 + 31 * 60 )) COORDINATOR_REBUILD_AFTER_MIN=30 tick)
want_in "shadow says it would rebuild"          'rebuild: would close PR #5501' "$out"
want "  and closes nothing"                     "0" "$(grep -c '^pr close' "$GH_LOG")"
rb_world; rm -f "$FIX/gh/api-repos_acme_widgets_git_refs.json"
SWARM_NOW=$T0 COORDINATOR_REBUILD_AFTER_MIN=30 COORDINATOR_SHADOW=0 tick >/dev/null
out=$(SWARM_NOW=$(( T0 + 31 * 60 )) COORDINATOR_REBUILD_AFTER_MIN=30 COORDINATOR_SHADOW=0 tick)
want "the head could not be kept: nothing closed" "0" "$(grep -c '^pr close' "$GH_LOG")"
want_in "  the tick says so"                    "rebuild: #501 — PR #5501's head could not be kept" "$out"
rb_world; echo "garbage" > "$FIX/claims.txt"
COORDINATOR_CLAIMS_CMD=false SWARM_NOW=$T0 COORDINATOR_REBUILD_AFTER_MIN=0 COORDINATOR_SHADOW=0 tick >/dev/null
out=$(COORDINATOR_CLAIMS_CMD=false SWARM_NOW=$(( T0 + 600 * 60 )) COORDINATOR_REBUILD_AFTER_MIN=1 COORDINATOR_SHADOW=0 tick)
want "an unreadable claim list rebuilds nothing" "0" "$(grep -c '^pr close' "$GH_LOG")"
want_in "  and says so"                         'rebuild: the claim list could not be read' "$out"
rm -rf "$STATE/driver/501"; fix_required

echo "--- the fix rounds: a red PR's ticket goes back to its builder, on the PR it has ---"
# fix_tick — one live tick with the rebuild off and coordinator.fixRounds at its default (2).
# Label edits stick (gh-labels): the pass sets the ticket ready, and the next tick reads that.
fix_tick() { env -u COORDINATOR_FIX_ROUNDS COORDINATOR_REBUILD_AFTER_MIN=0 SWARM_IDLE=90 COORDINATOR_CAP="${FIX_CAP:-6}" SWARM_GH="$BIN/gh-labels" SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" 2>&1; }
note_of() { jq -r --argjson n "$1" '.tickets[]? | select(.n == $n) | .note' "$C/queue.json" 2>/dev/null; }
rb_world
out=$(fix_tick)
want "the PR is not closed"                     "0" "$(grep -c '^pr close' "$GH_LOG")"
want_in "  the pass says it goes back to its builder" 'rebuild: PR #5501 goes back to its builder on tkt-501-x — fix round 1 of 2' "$out"
want_in "  the ticket is set ready"             'status:ready' "$(jq -r '[.labels[].name] | join(",")' "$FIX/gh/issue-501.json")"
out="$out
$(fix_tick)"
want "  its ticket is spawned, open PR and all" "501" "$(spawned)"
want "  one round spent, however many ticks saw the head" "1" "$(cut -f2 "$C/fix-rounds.did.tsv" 2>/dev/null)"
want "  spent because its run started"          "started" "$(cut -f4 "$C/fix-rounds.did.tsv" 2>/dev/null)"
want_in "  with the Fix: brief on the act log"  'spawn	501	new — Fix: PR #5501 — required check\(s\) failed: Typecheck' "$(cat "$C/actions.log" 2>/dev/null)"
want_not_in "  never skipped for its open PR"   'skip #501' "$out"
echo "  queued and never started, the round is not spent"
rb_world
out=$(FIX_CAP=0 fix_tick)
want "  no place to start it: nothing spawned"  "" "$(spawned)"
want "  the round is queued, not spent"         "1 queued" "$(cut -f2,4 "$C/fix-rounds.did.tsv" 2>/dev/null | tr '\t' ' ')"
out=$(FIX_CAP=0 fix_tick)
want_in "  the next tick says it has not started" 'rebuild: PR #5501 is stuck .* — fix round 1 of 2 is queued for this head and has not started' "$out"
echo "  one free place and a P0 queued: the fix round takes it, ahead of the new build"
rb_world; fix_issue 601 OPEN "P0,status:ready"; bash "$Q" add 601 >/dev/null
out="$(FIX_CAP=1 fix_tick)
$(FIX_CAP=1 fix_tick)"
want "  the P1's fix round starts, the P0 waits" "501" "$(spawned)"
echo "  a started round whose run is gone is released: the next tick queues round 2"
rb_world; printf '5501\t1\tf501\tstarted\n' > "$C/fix-rounds.did.tsv"
out=$(FIX_CAP=0 fix_tick)
want_in "  it says the round is released"       'rebuild: PR #5501 — fix round 1 ended without a push; its run is gone, so it is released' "$out"
want "  round 2 is queued on the same head"     "2 f501 queued" "$(tr '\t' ' ' < "$C/fix-rounds.did.tsv" | cut -d' ' -f2-)"
want_in "  with its own brief"                  'Fix round 2 of 2' "$(note_of 501)"
echo "  a machine reading another's sheet sends no PR back: one ledger counts the rounds"
rb_world
out=$(COORDINATOR_SHEET_OWNER=some-other-host fix_tick)
want "  nothing is queued for a fix"            "" "$(note_of 501)"
want "  no round is spent here"                 "" "$(cat "$C"/fix-rounds.* 2>/dev/null)"
want "  the ticket's status is not touched"     "0" "$(grep -c '^issue edit 501' "$GH_LOG")"
want_in "  the PR waits as before"              'rebuild: PR #5501 is stuck \(required check\(s\) failed: Typecheck\)' "$out"
echo "  over the open-work cap a fix round still starts: it finishes a PR the cap counts"
rb_world
jq '. + [range(0; 12) | {number: (9000 + .), headRefName: "tkt-\(9000 + .)-open", headRefOid: "h\(.)", baseRefName: "develop", isDraft: false, mergeStateStatus: "CLEAN", labels: [], statusCheckRollup: []}]' \
  "$FIX/gh/prs-all.json" > "$FIX/p.json" && mv "$FIX/p.json" "$FIX/gh/prs-all.json"
for n in $(seq 9000 9011); do fix_issue "$n" OPEN "P1,status:in-review"; done
queue 701
out="$(fix_tick)
$(fix_tick)"
want_in "  the cap is over"                     'open changes 13 / cap 10: finishing before starting' "$out"
want "  the fix round starts, the new ticket waits" "501" "$(spawned)"
want_in "  and the tick says why"               'cap: over \(13/10\) — fix-round #501 starts anyway' "$out"
echo "  a draft part-way through its build is resumed by its own build: no fix round"
rb_world
jq '.[0].isDraft = true' "$FIX/gh/prs-all.json" > "$FIX/p.json" && mv "$FIX/p.json" "$FIX/gh/prs-all.json"
jq -n '{ticket:"501", mode:"build", step:"build", done:["start","plan"], counters:{}}' > "$STATE/driver/501/state.json"
out="$(OPEN_WORK_PERSON_STOP="$BIN/pstop-none" OPEN_WORK_DRAFTED_CACHE="$FIX/pdrafted-none.tsv" fix_tick)
$(OPEN_WORK_PERSON_STOP="$BIN/pstop-none" OPEN_WORK_DRAFTED_CACHE="$FIX/pdrafted-none.tsv" fix_tick)"
want "  its ticket is spawned on its open draft" "501" "$(spawned)"
want_in "  with the resume brief"               'spawn	501	new — Resume: PR #5501 is a draft part-way through its build' "$(cat "$C/actions.log" 2>/dev/null)"
want "  no fix round is queued or spent"        "" "$(cat "$C"/fix-rounds.* 2>/dev/null)"
want "  the ticket is never parked"             "0" "$(grep -c 'status:parked' "$GH_LOG")"
want_not_in "  nor said to be"  'parked #501' "$out"
echo "  its rounds spent: parked for the PM once per head, whatever the ticket wears afterwards"
rb_world; printf '5501\t2\told-head\tstarted\n' > "$C/fix-rounds.did.tsv"
out=$(fix_tick)
want_in "  the first tick parks it"             'rebuild: parked #501 for the PM — 2 fix round\(s\), PR #5501 left open' "$out"
want "  one note on the ticket"                 "1" "$(grep -c '^issue comment 501 ' "$GH_LOG")"
fix_issue 501 OPEN "P1,status:ready"; : > "$GH_LOG"
out="$(fix_tick)
$(fix_tick)"
want "  set ready again by a PM answer, two ticks on: no label written" "0" "$(grep -c '^issue edit 501' "$GH_LOG")"
want "  and no second note"                     "0" "$(grep -c '^issue comment 501 ' "$GH_LOG")"
want_in "  each tick says it once"              'rebuild: PR #5501 is stuck .* — already parked for the PM at this head' "$out"
echo "  a queued fix round whose PR is no longer red sends no builder"
rb_world "P1,status:ready"; bash "$Q" add 501 --first --note "Fix: PR #5501 — required check(s) failed: Typecheck" >/dev/null 2>&1
jq '.[0].statusCheckRollup[0].conclusion = "SUCCESS" | .[0].mergeStateStatus = "CLEAN"' "$FIX/gh/prs-all.json" > "$FIX/p.json" && mv "$FIX/p.json" "$FIX/gh/prs-all.json"
out=$(fix_tick)
want "  nothing is spawned"                     "" "$(spawned)"
want_in "  and the skip says why"               'skip #501 \(new\): its fix round waits — PR #5501 is not red or clashing now' "$out"
echo "  a queued fix round whose PR is gone is taken off the queue, never built from the trunk"
rb_world "P1,status:ready"; bash "$Q" add 501 --first --note "Fix: PR #5501 — required check(s) failed: Typecheck" >/dev/null 2>&1
printf '[]\n' > "$FIX/gh/prs-all.json"
out=$(fix_tick)
want "  nothing is spawned"                     "" "$(spawned)"
want "  and it is off the queue"                "" "$(note_of 501)"
want_in "  the skip says why"                   'skip #501 \(new\): its fix round was for PR #5501, which is not open any more' "$out"
echo "  a ticket parked for the PM after its rounds: its open PR is left, and not counted as open work"
rb_world "P1,status:parked,status:pm-decision"
jq '. + [range(0; 10) | {number: (9000 + .), headRefName: "tkt-\(9000 + .)-open", headRefOid: "h\(.)", baseRefName: "develop", isDraft: false, mergeStateStatus: "CLEAN", labels: [], statusCheckRollup: []}]' \
  "$FIX/gh/prs-all.json" > "$FIX/p.json" && mv "$FIX/p.json" "$FIX/gh/prs-all.json"
for n in $(seq 9000 9009); do fix_issue "$n" OPEN "P1,status:in-review"; done
queue 701
out=$(fix_tick)
want_in "  it is left as it is"                 'rebuild: PR #5501 left as it is — #501 waits on a person' "$out"
want_in "  10 of 11 count: new work may start"  'open changes 10 / cap 10: new work may start' "$out"
want_in "  the tick names why"                  '#5501 waits on a person \(status:pm-decision\)' "$out"
want "  the new ticket starts"                  "701" "$(spawned)"
rm -rf "$STATE/driver/501"; fix_required

echo "--- a frozen run is noticed; a busy one is not ---"
fresh; live_run 700
tick >/dev/null
want "a run writing its log is not frozen" "0" "$(grep -c '"kind":"frozen"' "$C/events.would.jsonl")"
export SWARM_NOW=$(( $(date +%s) + 25 * 60 ))
out=$(tick)
want "no growth for 25 min is frozen"      "1" "$(grep -c '"kind":"frozen"' "$C/events.would.jsonl")"
want_in "and it is a judgement event"      '"judge":true' "$(grep '"kind":"frozen"' "$C/events.would.jsonl")"
tick >/dev/null
want "written once, not every tick"        "1" "$(grep -c '"kind":"frozen"' "$C/events.would.jsonl")"
echo '{"type":"assistant"}' >> "$STATE/logs/claim-700-live.log"; touch "$STATE/logs/claim-700-live.log"
export SWARM_NOW=$(( $(date +%s) + 50 * 60 ))
tick >/dev/null
want "a run that recovers and freezes again is raised again" "2" "$(grep -c '"kind":"frozen"' "$C/events.would.jsonl")"
unset SWARM_NOW

echo "--- a driver run: its step logs are progress, not only its log ---"
# build-ticket prints at step boundaries only; a build step streams into the
# driver's per-ticket state dir for longer than frozenMin with the log quiet.
driver_run() { # <ticket> — a live driver run: a quiet log, a step log under its state dir
  local log="$STATE/logs/claim-$1-drv.log" d="$STATE/driver/$1"
  mkdir -p "$d/steps"; echo 'build-ticket: walking' > "$log"; echo 'step output' > "$d/steps/build.log"
  jq -cn --arg rid "claim-$1-drv" --arg t "$1" --argjson pid "$$" --arg log "$log" --arg d "$d" \
    '{run_id:$rid, ticket:$t, child_pid:$pid, log:$log, runner:"driver", progress_paths:[$d]}' > "$STATE/runs/claim-$1-drv.json"
}
set_mtime() { perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1] or die' "$1" "$2"; }   # <epoch> <file>, BSD and GNU alike
fresh; driver_run 710
NOW0=$(date +%s)
set_mtime $(( NOW0 + 24 * 60 )) "$STATE/driver/710/steps/build.log"
export SWARM_NOW=$(( NOW0 + 25 * 60 ))
tick >/dev/null
want "a quiet log with a growing step log is not frozen" "0" "$(grep -c '"kind":"frozen"' "$C/events.would.jsonl")"
fresh; driver_run 711
export SWARM_NOW=$(( NOW0 + 25 * 60 ))
tick >/dev/null
want "a quiet log and a quiet step log is frozen" "1" "$(grep -c '"kind":"frozen".*"ticket":"711"' "$C/events.would.jsonl")"
unset SWARM_NOW
rm -rf "$STATE/driver"

echo "--- a driver run's verdict is its own last line, not the reconcile after it ---"
fresh
printf '{"run_id":"claim-720-drv","ticket":"720","log":"%s","runner":"driver"}\n' "$STATE/logs/claim-720-drv.log" > "$STATE/runs/claim-720-drv.json"
# The shape spawn-claim.sh writes in driver mode: the driver's output, its last
# line as a result line, then the post-exit sections.
{ echo 'build-ticket: walking #720'; echo '⏸ #720 parked: the spec needs a decision'
  jq -cn '{type:"result",result:"⏸ #720 parked: the spec needs a decision"}'
  printf '\n--- post-exit reconcile (x) ---\n'; echo 'reconcile: released #720, nothing escalated'; } > "$STATE/logs/claim-720-drv.log"
printf '{"run_id":"claim-720-drv","exit_code":20}\n' > "$STATE/runs/claim-720-drv.ended"
tick >/dev/null
want_in "the driver's verdict is recorded"  'claim-720-drv.*exit=20 ⏸ #720 parked: the spec needs a decision' "$(cat "$C/runs.log")"
want_not_in "not the reconcile output"     'claim-720-drv.*reconcile' "$(cat "$C/runs.log")"
want_in "a parked driver run is a stand-down" '"kind":"stood-down".*"ticket":"720"' "$(cat "$C/events.would.jsonl")"

echo "--- a driver run that hit an API error twice is the machine's, not a stand-down ---"
fresh
printf '{"run_id":"claim-721-drv","ticket":"721","log":"%s","runner":"driver"}\n' "$STATE/logs/claim-721-drv.log" > "$STATE/runs/claim-721-drv.json"
{ echo '⏸ #721 parked (driver): machine fault: the review model call failed at the API twice'
  jq -cn '{type:"result",result:"⏸ #721 parked (driver): machine fault: the review model call failed at the API twice"}'; } > "$STATE/logs/claim-721-drv.log"
printf '{"run_id":"claim-721-drv","exit_code":33}\n' > "$STATE/runs/claim-721-drv.ended"
out=$(tick 2>&1)
want_in "the tick says machine"             'machine: run claim-721-drv' "$out"
want_not_in "and raises no stand-down"      '"kind":"stood-down".*"ticket":"721"' "$(cat "$C/events.would.jsonl" 2>/dev/null)"

echo "--- a spawn the spawner refuses raises an event naming why ---"
cat > "$BIN/spawn-refuse" <<'SH'
#!/usr/bin/env bash
echo "spawn-claim: refusing — a planted refusal for #$1" >&2
exit 3
SH
chmod +x "$BIN/spawn-refuse"
fresh; queue 730
out=$(COORDINATOR_SHADOW=0 SWARM_SPAWN="$BIN/spawn-refuse" SWARM_IDLE=40 SWARM_CORES=10 tick)
want_in "it says the start failed"         'spawn of #730 failed' "$out"
want_in "the refusal is an event, with its reason" '"kind":"spawn-failed".*"ticket":"730".*a planted refusal' "$(cat "$C/events.did.jsonl" 2>/dev/null)"
COORDINATOR_SHADOW=0 SWARM_SPAWN="$BIN/spawn-refuse" SWARM_IDLE=40 SWARM_CORES=10 tick >/dev/null
want "raised once a day, not every tick"   "1" "$(grep -c '"kind":"spawn-failed"' "$C/events.did.jsonl" 2>/dev/null)"

echo "--- a refused start does not use up the place: the next entry starts on the same tick ---"
cat > "$BIN/spawn-some" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "${REFUSE_T:-}" ]; then echo "spawn-claim: refusing — planted for #$1" >&2; exit 3; fi
printf '%s\t%s\n' "$1" "${CLAIM_CLASS:-}" >> "$SPAWNS"
printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s}\n' "$1" "$1" "$TEST_PID" > "$STATE/runs/claim-$1-live.json"
SH
chmod +x "$BIN/spawn-some"
fresh; queue 740 741
out=$(REFUSE_T=740 COORDINATOR_SHADOW=0 COORDINATOR_CAP=1 SWARM_SPAWN="$BIN/spawn-some" SWARM_IDLE=90 SWARM_CORES=10 tick)
want "one place, the first entry refused: the second starts this tick" "741" "$(spawned)"
want_in "and the refusal is still said"    'spawn of #740 failed' "$out"

echo "--- a note on any class spawns: spawn-claim carries it to the driver ---"
fresh; fix_issue 742 OPEN "status:ready"; bash "$Q" add 742 --note "The owner answered q1: yes." >/dev/null
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=1 SWARM_SPAWN="$BIN/spawn-some" SWARM_IDLE=90 SWARM_CORES=10 tick)
want "a noted new entry spawns"            "742" "$(spawned)"
fresh; fix_issue 744 OPEN "status:ready"
bash "$Q" add 744 --class repair --note "clashes" >/dev/null 2>&1
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=1 SWARM_SPAWN="$BIN/spawn-some" SWARM_IDLE=90 SWARM_CORES=10 tick)
want "a noted row an older caller queued as repair spawns, as new" "744" "$(spawned)"

echo "--- ended runs: recorded once, the failures raised ---"
fresh
printf '{"run_id":"claim-801-x","ticket":"801","log":"%s"}\n' "$STATE/logs/claim-801-x.log" > "$STATE/runs/claim-801-x.json"
printf '{"type":"result","result":"Handed off at abc123"}\n' > "$STATE/logs/claim-801-x.log"
printf '{"run_id":"claim-801-x","exit_code":0}\n' > "$STATE/runs/claim-801-x.ended"
printf '{"run_id":"claim-802-x","ticket":"802","log":"%s"}\n' "$STATE/logs/claim-802-x.log" > "$STATE/runs/claim-802-x.json"
printf '{"type":"result","result":"Parked: the spec contradicts itself"}\n' > "$STATE/logs/claim-802-x.log"
printf '{"run_id":"claim-802-x","exit_code":0}\n' > "$STATE/runs/claim-802-x.ended"
printf '{"run_id":"claim-803-x","ticket":"803","log":"%s"}\n' "$STATE/logs/claim-803-x.log" > "$STATE/runs/claim-803-x.json"
printf '{"type":"result","is_error":true,"result":"You have hit your session limit · resets 7pm"}\n' > "$STATE/logs/claim-803-x.log"
printf '{"run_id":"claim-803-x","exit_code":1}\n' > "$STATE/runs/claim-803-x.ended"
# A clean run that READ a CI log quoting someone else's limit, as claim-12554 did.
printf '{"run_id":"claim-804-x","ticket":"804","log":"%s"}\n' "$STATE/logs/claim-804-x.log" > "$STATE/runs/claim-804-x.json"
jq -nc '{type:"user",message:{content:[{type:"tool_result",content:"critic: You have hit your weekly limit · resets Oct 20 at 9pm"}]}}' > "$STATE/logs/claim-804-x.log"
printf '{"type":"result","is_error":false,"result":"Handed off at def456"}\n' >> "$STATE/logs/claim-804-x.log"
printf '{"run_id":"claim-804-x","exit_code":0}\n' > "$STATE/runs/claim-804-x.ended"
out=$(tick)
want_in "the final result line is recorded" 'claim-801-x.*exit=0 Handed off at abc123' "$(cat "$C/runs.log")"
want "a clean hand-off raises nothing"     "0" "$(grep -c 'claim-801-x' "$C/events.would.jsonl")"
want_in "a park is a stand-down"           '"kind":"stood-down".*"ticket":"802"' "$(cat "$C/events.would.jsonl")"
want_in "a limit stop is a usage-limit"    '"kind":"usage-limit".*"ticket":"803"' "$(cat "$C/events.would.jsonl")"
want "a quoted limit in a clean run raises nothing" "0" "$(grep -c 'claim-804-x' "$C/events.would.jsonl")"
tick >/dev/null
want "each ended run is read once"         "4" "$(grep -c 'ended' "$C/runs.log")"
rm -f "$STATE/logs/claim-803-x.log" "$STATE/logs/claim-804-x.log"

echo "--- a ticket whose last 3 runs ended fast with the same result is parked for the PM, not spawned again ---"
# 15735 (2026-10-31): "nothing left to do", exit 0, in a minute, 22 times in a day; 17008:
# requeued at the front over a missing picture 43 times in 4 hours.
short_run() { # <ticket> <i> <exit> <result> [secs] — a run that ended that long after it started
  local t="$1" i="$2" st="2026-10-31T06:2${2}:00Z" en
  en=$(jq -nr --arg s "$st" --argjson d "${5:-60}" '$s | fromdateiso8601 + $d | todate')
  printf '{"run_id":"claim-%s-r%s","ticket":"%s","log":"%s","started_at":"%s"}\n' "$t" "$i" "$t" "$STATE/logs/claim-$t-r$i.log" "$st" > "$STATE/runs/claim-$t-r$i.json"
  printf '%s\n' "$4" > "$STATE/logs/claim-$t-r$i.log"
  printf '{"run_id":"claim-%s-r%s","exit_code":%s,"ended_at":"%s"}\n' "$t" "$i" "$3" "$en" > "$STATE/runs/claim-$t-r$i.ended"
}
NOTHING="✓ #860 has nothing left to do — all 9 step(s) were already finished."
fresh; queue 860; : > "$GH_LOG"
short_run 860 1 0 "$NOTHING"; short_run 860 2 0 "$NOTHING"; short_run 860 3 0 "$NOTHING"
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=2 SWARM_SPAWN="$BIN/spawn-live" SWARM_IDLE=90 SWARM_CORES=10 tick)
want "it is not spawned a fourth time"          "" "$(spawned)"
want_in "it is parked with the PM's hold"       'issue edit 860 .*--add-label status:parked.*--add-label status:pm-decision|issue edit 860 .*--add-label status:pm-decision.*--add-label status:parked' "$(cat "$GH_LOG")"
want_in "the park says what kept repeating"     'issue comment 860 .*Parked — no progress' "$(tr '\n' ' ' < "$GH_LOG")"
want "it leaves the queue"                      "0" "$(jq '[.tickets[]? | select(.n == 860)] | length' "$C/queue.json" 2>/dev/null || echo 0)"
want_in "and it is reported"                    '"kind":"no-progress".*"ticket":"860"' "$(cat "$C/events.did.jsonl" 2>/dev/null)"

echo "--- three claims lost to another machine (exit 28, a peer took it) park nothing ---"
RACE="↻ #862 requeued for the next tick, at the front of its priority as new, not parked: a peer took the claim on #862 first"
fresh; queue 862; : > "$GH_LOG"
short_run 862 1 28 "$RACE"; short_run 862 2 28 "$RACE"; short_run 862 3 28 "$RACE"
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=2 SWARM_SPAWN="$BIN/spawn-live" SWARM_IDLE=90 SWARM_CORES=10 tick)
want_not_in "a lost race is not parked"         'issue edit 862 .*status:pm-decision' "$(cat "$GH_LOG")"
want_not_in "nor called no progress"            'no progress' "$out"

echo "--- three other requeues (exit 28, no race) still park ---"
REQ="↻ #863 requeued for the next tick, at the front of its priority as new, not parked: no approved picture yet"
fresh; queue 863; : > "$GH_LOG"
short_run 863 1 28 "$REQ"; short_run 863 2 28 "$REQ"; short_run 863 3 28 "$REQ"
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=2 SWARM_SPAWN="$BIN/spawn-live" SWARM_IDLE=90 SWARM_CORES=10 tick)
want_in "a repeating requeue is parked"         'issue edit 863 .*status:pm-decision' "$(cat "$GH_LOG")"

echo "--- the same three, one of them a real run of minutes: nothing parks ---"
fresh; queue 861; : > "$GH_LOG"
short_run 861 1 0 "$NOTHING"; short_run 861 2 0 "$NOTHING" 900; short_run 861 3 0 "$NOTHING"
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=2 SWARM_SPAWN="$BIN/spawn-live" SWARM_IDLE=90 SWARM_CORES=10 tick)
want "a long run between is progress: it spawns" "861" "$(spawned)"
want_not_in "nothing is parked"                  'issue edit 861 .*status:parked' "$(cat "$GH_LOG")"

echo "--- three fast runs with different results, or only two: nothing parks ---"
fresh; queue 862 863; : > "$GH_LOG"
short_run 862 1 28 "↻ #862 requeued for the next tick: a"; short_run 862 2 28 "↻ #862 requeued for the next tick: b"; short_run 862 3 28 "↻ #862 requeued for the next tick: a"
short_run 863 1 28 "↻ #863 requeued for the next tick: a"; short_run 863 2 28 "↻ #863 requeued for the next tick: a"
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=2 SWARM_SPAWN="$BIN/spawn-live" SWARM_IDLE=90 SWARM_CORES=10 tick)
want "both spawn"                                "862 863" "$(spawned)"
want_not_in "nothing is parked"                  'status:parked' "$(cat "$GH_LOG")"

echo "--- a stop that is the machine's is never the ticket's loop ---"
fresh; queue 864; : > "$GH_LOG"
short_run 864 1 33 "machine fault: x"; short_run 864 2 33 "machine fault: x"; short_run 864 3 33 "machine fault: x"
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=2 SWARM_SPAWN="$BIN/spawn-live" SWARM_IDLE=90 SWARM_CORES=10 tick)
want_not_in "an API fault three times parks nothing" 'issue edit 864 .*status:parked' "$(cat "$GH_LOG")"

echo "--- a run that could not push its claim says so on the sheet, with git's own error ---"
# 23 h of a corrupt clone read as 'hit an API error twice': the bad object stayed hidden.
CANT="⏸ #866 parked (driver): machine fault: cannot claim: fatal: bad object 6332dafe — machine fault, nothing to answer: the claim push for #866 failed (exit 1): fatal: bad object 6332dafe"
fresh; : > "$GH_LOG"
short_run 866 1 33 "$CANT"
out=$(tick)
want_in "the sheet names the claim and git's error" 'machine: run claim-866-r1 cannot claim #866: fatal: bad object 6332dafe' "$out"
want_not_in "never the API's"                   'claim-866-r1 hit an API error' "$out"

echo "--- three failed claim pushes in a row on this host: nothing more starts here, and the owner is told ---"
cant() { printf '⏸ #%s parked (driver): machine fault: cannot claim: fatal: bad object 6332dafe — machine fault, nothing to answer' "$1"; }
fresh; queue 870; : > "$GH_LOG"
short_run 867 1 33 "$(cant 867)"; short_run 868 2 33 "$(cant 868)"; short_run 869 3 33 "$(cant 869)"
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=2 SWARM_SPAWN="$BIN/spawn-live" SWARM_IDLE=90 SWARM_CORES=10 tick)
want "nothing is spawned on this host"          "" "$(spawned)"
want_in "the hold is said, with the error"      'spawn: starting nothing new — 3 claim pushes in a row failed on this host.*fatal: bad object 6332dafe' "$out"
want_in "it is an event"                        '"kind":"claim-push-fails"' "$(cat "$C/events.did.jsonl" 2>/dev/null)"
want_in "and the owner is told"                 'claim-push-fails:' "$(cat "$FIX/notify.log")"
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=2 SWARM_SPAWN="$BIN/spawn-live" SWARM_IDLE=90 SWARM_CORES=10 tick)
want "the next tick still holds"                "" "$(spawned)"
want "told once, not every tick"                "1" "$(grep -c 'claim-push-fails:' "$FIX/notify.log")"

echo "--- a claim that went through in between starts the count again ---"
fresh; queue 870; : > "$GH_LOG"
short_run 867 1 33 "$(cant 867)"; short_run 868 2 33 "$(cant 868)"
short_run 871 3 0 "Handed off at abc123"; short_run 869 4 33 "$(cant 869)"
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=2 SWARM_SPAWN="$BIN/spawn-live" SWARM_IDLE=90 SWARM_CORES=10 tick)
want "two, a claim, then one: it spawns"        "870" "$(spawned)"

echo "--- once a parked loop is put back, its count starts again ---"
fresh; queue 865
short_run 865 1 0 "$NOTHING"; short_run 865 2 0 "$NOTHING"; short_run 865 3 0 "$NOTHING"
COORDINATOR_SHADOW=0 SWARM_SPAWN="$BIN/spawn-live" SWARM_IDLE=90 SWARM_CORES=10 tick >/dev/null
fix_issue 865 OPEN "status:ready"; bash "$Q" add 865 >/dev/null; : > "$GH_LOG"; : > "$SPAWNS"
short_run 865 4 0 "$NOTHING"
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=2 SWARM_SPAWN="$BIN/spawn-live" SWARM_IDLE=90 SWARM_CORES=10 tick)
want "one more fast run after the PM's answer spawns again" "865" "$(spawned)"

echo "--- a run the wall cut off goes back to the front of the queue, judged by no model ---"
# claim-12987's shape (2026-10-15): cut at the session limit 11 minutes in, its
# ticket released to ready and never queued again, its worktree left behind.
cut_run() { # <ticket> <log line…> — a run that ended with these events
  local t="$1"; shift
  printf '{"run_id":"claim-%s-cut","ticket":"%s","log":"%s"}\n' "$t" "$t" "$STATE/logs/claim-$t-cut.log" > "$STATE/runs/claim-$t-cut.json"
  { printf '{"type":"system","subtype":"init","session_id":"sess-%s"}\n' "$t"; printf '%s\n' "$@"; } > "$STATE/logs/claim-$t-cut.log"
  printf '/wt/%s-branch\n' "$t" > "$STATE/runs/claim-$t-cut.worktrees"
  printf '{"run_id":"claim-%s-cut","exit_code":1}\n' "$t" > "$STATE/runs/claim-$t-cut.ended"
}
PAST=$(( $(date +%s) - 60 ))
wall="{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"rejected\",\"resetsAt\":$PAST,\"rateLimitType\":\"five_hour\"}}"
said='{"type":"result","is_error":true,"result":"You have hit your session limit · resets 7pm"}'
fresh
queue 900
bash "$Q" add 805 --note "judge: the unit test is not its own" >/dev/null
fix_issue 805 OPEN "status:ready"
cut_run 805 "$wall" "$said"
out=$(COORDINATOR_SHADOW=0 tick)
want "the cut run is the first start, ahead of work queued before it" "805" "$(spawned | cut -d' ' -f1)"
brief=$(grep '^805' "$SPAWNS")
want_in "its brief says resume, not start over" "Resume: run claim-805-cut was cut off by the plan's usage limit" "$brief"
want_in "it names the worktree"            "Its worktree: /wt/805-branch" "$brief"
want_in "and the session"                  "Its session: sess-805" "$brief"
want_in "an earlier note survives"         "Earlier note: judge: the unit test is not its own" "$brief"
want_in "the limit stop is still an event" '"kind":"usage-limit".*"judge":false.*"ticket":"805"' "$(cat "$C/events.did.jsonl")"
COORDINATOR_SHADOW=0 bash "$HERE/coordinator-judge.sh" >/dev/null 2>&1; sleep 0.3
want "and no model is started to judge it" "" "$(cat "$FIX/claude.log")"

fresh
fix_issue 806 OPEN "status:in-review"
jq -n '[{number:61, headRefName:"tkt-806-x", headRefOid:"sha61", isDraft:true, labels:[], mergeStateStatus:"CLEAN", statusCheckRollup:[]}]' > "$FIX/gh/prs-all.json"
cut_run 806 "$wall" "$said"
COORDINATOR_SHADOW=0 tick >/dev/null
want_in "a cut run with an open PR comes back as new, its note kept" "Resume: run claim-806-cut" "$(jq -r '.tickets[]? | select(.n==806) | .class + " " + .note' "$C/queue.json" 2>/dev/null; grep '^806' "$SPAWNS")"
want_not_in "  never as a repair"            'repair' "$(jq -r '.tickets[]? | select(.n==806) | .class' "$C/queue.json" 2>/dev/null; cut -f2 "$SPAWNS")"

fresh
fix_issue 807 CLOSED "status:done"
cut_run 807 "$wall" "$said"
out=$(COORDINATOR_SHADOW=0 tick)
want "a closed ticket is not re-queued"    "" "$(jq -r '.tickets[]? | select(.n==807) | .n' "$C/queue.json" 2>/dev/null)"
want_in "and the tick says so"             'cut: #807 is CLOSED' "$out"

fresh
cut_run 808 "$wall" "$said"
out=$(COORDINATOR_SHADOW=0 tick)
want_in "an unreadable ticket is tried again" 'cut: #808 could not be read' "$out"
fix_issue 808 OPEN "status:ready"
COORDINATOR_SHADOW=0 tick >/dev/null
want "next tick it is queued, or already started" "808" "$( { jq -r '.tickets[]? | select(.n==808) | .n' "$C/queue.json"; spawned; } | grep -m1 808)"

fresh
fix_issue 809 OPEN "status:ready"
cut_run 809 '{"type":"assistant","error":"authentication_failed","message":{"model":"<synthetic>","content":[{"type":"text","text":"Not logged in · Please run /login"}]}}' \
  '{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}'
out=$(COORDINATOR_SHADOW=0 tick)
want_in "a lost login is its own event"    '"kind":"login-lost".*"ticket":"809"' "$(cat "$C/events.did.jsonl")"
want_in "it goes back on the queue to resume" "cut off by a lost login" "$(grep '^809' "$SPAWNS"; jq -r '.tickets[]? | select(.n==809) | .note' "$C/queue.json")"
want_in "the owner hears that only a /login fixes it" "/login" "$(cat "$FIX/notify.log")"
want "a login stop is not a stand-down"    "0" "$(grep -c '"kind":"stood-down".*"809"' "$C/events.did.jsonl")"

fresh
fix_issue 810 OPEN "status:ready"
cut_run 810 "$wall" "$said"
out=$(tick)
want_in "shadow says what it would re-queue" 'would re-queue #810 \(new\) at the front' "$out"
want "and queues nothing"                  "" "$(jq -r '.tickets[]? | select(.n==810) | .n' "$C/queue.json" 2>/dev/null)"
rm -f "$STATE"/logs/claim-80?-cut.log "$STATE"/logs/claim-810-cut.log

echo "--- pull requests: red is on the red clock, never judged; green pixels go to the owner in batches ---"
# reds <mode> — the PRs this tick saw red (red-since.<mode>.tsv), sorted
reds() { cut -f1 "$C/red-since.$1.tsv" 2>/dev/null | sort -n | tr '\n' ' ' | sed 's/ $//'; }
is_red() { case " $(reds "${2:-would}") " in *" $1 "*) echo 1 ;; *) echo 0 ;; esac; }
pr() { # <n> <ticket> <label-or-> <conclusion> [mergeState] — the hold's own gate is red while held
  jq -n --argjson n "$1" --arg b "tkt-$2-x" --arg l "$3" --arg c "$4" --arg m "${5:-CLEAN}" \
    '{number:$n, headRefName:$b, headRefOid:("sha" + ($n|tostring) + "abcdef"), isDraft:false, mergeStateStatus:$m,
      labels:(if $l == "-" then [] else [{name:$l}] end),
      statusCheckRollup:([{name:"ci", status:"COMPLETED", conclusion:$c}]
        + (if $l == "-" then [] else [{name:"approval-gate", status:"COMPLETED", conclusion:"FAILURE"},
              {name:"approval-gate — waiting for sign-off", status:"COMPLETED", conclusion:"ACTION_REQUIRED"}] end))}'
}
held() { local n; for n in "$@"; do pr "$n" "$((n+560))" needs:human-approval SUCCESS; done; }
fresh
jq -s . <(pr 41 601 - FAILURE) <(held 42) <(pr 43 603 - SUCCESS DIRTY) <(pr 44 604 - SUCCESS) > "$FIX/gh/prs-all.json"
tick >/dev/null
want "a settled red PR is red"             "1" "$(is_red 41)"
want "a clash is red"                      "1" "$(is_red 43)"
want "no red PR raises a judge event"      "0" "$(grep -c '"kind":"red-pr"' "$C/events.would.jsonl")"
want "a healthy PR raises nothing"         "0" "$(grep -c '"id":"[a-z-]*:44:' "$C/events.would.jsonl")"
want "one green held PR is not a batch"    "0" "$(grep -c '"kind":"signoff"' "$C/events.would.jsonl")"
fresh
# A pending commit status (the design critic's verdict, waiting) never holds a real red back, and alone is not red.
withstatus() { jq --arg s "$1" '.statusCheckRollup += [{__typename:"StatusContext", context:"Design critic", state:$s}]'; }
jq -s . <(pr 46 606 - FAILURE | withstatus PENDING) <(pr 47 607 - SUCCESS | withstatus PENDING) <(pr 48 608 - SUCCESS | withstatus FAILURE) > "$FIX/gh/prs-all.json"
tick >/dev/null
want "a red PR waiting on a status is still red" "1" "$(is_red 46)"
want "a pending status alone is not red"   "0" "$(is_red 47)"
want "a failed status is red"              "1" "$(is_red 48)"

echo "--- a check that warns until the release is not a red (release.nonBlockingChecks) ---"
cp "$HARNESS_CFG_PATH" "$FIX/cfg.release.bak"
lesson() { jq '.statusCheckRollup += [{__typename:"CheckRun", name:"Every fix ships a lesson", workflowName:"Lesson", status:"COMPLETED", conclusion:"FAILURE"}]'; }
gates() { jq '.statusCheckRollup += [{__typename:"CheckRun", name:"Code gates", status:"COMPLETED", conclusion:"FAILURE"}]'; }
release_prs() {
  jq -s . <(pr 61 621 - SUCCESS | lesson | withstatus FAILURE) <(pr 62 622 - SUCCESS | lesson | gates) > "$FIX/gh/prs-all.json"
}
jq '.release = {nonBlockingChecks: ["Lesson / Every fix ships a lesson", "Design critic", "Approved picture", "Widths and contrast on changed routes"], done: false}' \
  "$FIX/cfg.release.bak" > "$HARNESS_CFG_PATH"
fresh; release_prs
out=$(tick)
want "red only on Lesson and Design critic is not red" "0" "$(is_red 61)"
want_in "a warning is noted instead"       'PR #61: red only on .*Design critic.*a warning until the release' "$out"
want "red on Code gates as well is still red" "1" "$(is_red 62)"
jq '.release.done = true' "$HARNESS_CFG_PATH" > "$FIX/cfg.release.t" && cp "$FIX/cfg.release.t" "$HARNESS_CFG_PATH"
fresh; release_prs
out=$(tick)
want "after the release the same PR is red again" "1" "$(is_red 61)"
want_not_in "and no warning is noted"      'a warning until the release' "$out"
cp "$FIX/cfg.release.bak" "$HARNESS_CFG_PATH"
fresh; release_prs
tick >/dev/null
want "with no release key it is red, as before" "1" "$(is_red 61)"

echo "--- merge first: a red only on the Evidence capture develop does not require is a note, never red ---"
evid() { jq '.statusCheckRollup += [{__typename:"CheckRun", name:"Capture and pin the evidence", status:"COMPLETED", conclusion:"FAILURE"}]'; }
ev_prs() { jq -s . <(pr 71 631 - SUCCESS | evid) <(pr 72 632 - FAILURE | evid) > "$FIX/gh/prs-all.json"; }
ev_case() { # <kit> — R: whether #71 (Evidence alone) and #72 (a required red too) were read red, and #71's note
  fresh; ev_prs; fix_required "ci"; : > "$GH_LOG"
  out=$(COORDINATOR_SHADOW=0 bash "$1/scripts/coordinator-tick.sh" 2>&1)
  R="71=$(is_red 71 did) 72=$(is_red 72 did) note=$(grep -c 'pr comment 71 .*Evidence: not captured' "$GH_LOG")"
}
jq '.release = {mergeFirst: true, done: false, nonBlockingChecks: []}' "$FIX/cfg.release.bak" > "$HARNESS_CFG_PATH"
ev_case "$HERE/.."
want "Evidence alone: not red, noted once; a required red still red" "71=0 72=1 note=1" "$R"
want_in "the note says it ships on its required checks" 'Evidence: not captured \(Capture and pin the evidence failed on sha71ab, a check develop does not require\); shots follow when the workflow recovers' "$(cat "$GH_LOG")"
COORDINATOR_SHADOW=0 bash "$T" >/dev/null 2>&1; want "a second tick on the same head notes nothing more" "1" "$(grep -c 'pr comment 71 .*Evidence: not captured' "$GH_LOG")"
EVKIT="$FIX/evkit"; rm -rf "$EVKIT"; mkdir -p "$EVKIT"; cp -R "$HERE/../scripts" "$HERE/../swarm" "$HERE/../driver" "$HERE/../shared" "$EVKIT/" 2>/dev/null
python3 -I -c 'import sys; p = sys.argv[1]; s = open(p).read(); o = " | select(needed))) as $c"; n = s.count(o); open(p, "w").write(s.replace(o, ")) as $c")); sys.exit(0 if n == 1 else 1)' "$EVKIT/scripts/coordinator-tick.sh" \
  && { ev_case "$EVKIT"; want "planted (every check a red): the Evidence-only PR is red again" "71=1 72=1 note=0" "$R"; } || bad "plant: the required-only filter did not land"
jq '.release = {mergeFirst: false, done: false, nonBlockingChecks: []}' "$FIX/cfg.release.bak" > "$HARNESS_CFG_PATH"
ev_case "$HERE/.."
want "merge first off: the Evidence red is red, as before" "71=1 72=1 note=0" "$R"
cp "$FIX/cfg.release.bak" "$HARNESS_CFG_PATH"

echo "--- a run that found its ticket's open PR (exit 31) is no stand-down ---"
fresh
printf '{"run_id":"claim-601-pr","ticket":"601","log":"%s","runner":"driver"}\n' "$STATE/logs/claim-601-pr.log" > "$STATE/runs/claim-601-pr.json"
jq -cn '{type:"result",result:"#601 already has an open pull request #41 on tkt-601-x — it merges, or the coordinator rebuilds it fresh once it cannot merge (coordinator.rebuildAfterMin); this run builds nothing"}' > "$STATE/logs/claim-601-pr.log"
printf '{"run_id":"claim-601-pr","exit_code":31}\n' > "$STATE/runs/claim-601-pr.ended"
out=$(tick)
want_in "the ended run is said"             'has a PR: run claim-601-pr found #601.s open pull request and built nothing' "$out"
want_not_in "and raises no stand-down"      '"kind":"stood-down".*"ticket":"601"' "$(cat "$C/events.would.jsonl" 2>/dev/null)"
want_not_in "nor a no-progress park"        'no progress' "$out"

echo "--- a PR red two hours with nothing fixing it reaches the owner, once (coordinator.redReportMin) ---"
red_at() { mkdir -p "$C"; printf '%s\t%s\t%s\n' "$2" "$3" "$(( $(date +%s) - $4 * 60 ))" >> "$C/red-since.$1.tsv"; } # <mode> <pr> <sha> <min-ago>
red2h_would() { grep -c "\"id\":\"red-2h:$1:" "$C/events.would.jsonl" 2>/dev/null; }
fresh
jq -s . <(pr 41 601 - FAILURE) <(pr 43 603 - SUCCESS DIRTY) <(pr 44 604 - FAILURE) > "$FIX/gh/prs-all.json"
tick >/dev/null
want "a PR first seen red has its head's clock started" "41 43 44" "$(cut -f1 "$C/red-since.would.tsv" | sort | tr '\n' ' ' | sed 's/ $//')"
want "and is not reported on its first tick" "0" "$(grep -c '"id":"red-2h:' "$C/events.would.jsonl")"
fresh
jq -s . <(pr 41 601 - FAILURE) <(pr 43 603 - SUCCESS DIRTY) <(pr 44 604 - FAILURE) > "$FIX/gh/prs-all.json"
red_at would 41 sha41abcdef 125; red_at would 43 sha43abcdef 130; red_at would 44 sha44abcdef 119
tick >/dev/null
want "red 125 min with nothing fixing it is reported" "1" "$(red2h_would 41)"
want "a clash red 130 min is reported too"  "1" "$(red2h_would 43)"
want "119 min is not yet"                   "0" "$(red2h_would 44)"
want_in "it goes to the owner's channel, not agent work" $'would\tnotify\tred-2h:41:sha41abcdef' "$(cat "$C/actions.log")"
tick >/dev/null
want "a second tick on the same head reports nothing more" "1" "$(red2h_would 41)"
fresh
jq -s . <(pr 41 601 - FAILURE) > "$FIX/gh/prs-all.json"
red_at would 41 sha41old 300
tick >/dev/null
want "a new head starts the clock again"    "0" "$(red2h_would 41)"
want "and the old head's row is dropped"    "sha41abcdef" "$(cut -f2 "$C/red-since.would.tsv" | tr '\n' ' ' | sed 's/ $//')"
fresh
jq -s . <(pr 41 601 - FAILURE) <(pr 43 603 - FAILURE) <(pr 44 604 - FAILURE) > "$FIX/gh/prs-all.json"
red_at would 41 sha41abcdef 200; red_at would 43 sha43abcdef 200; red_at would 44 sha44abcdef 200
live_run 603
tick >/dev/null
want "a live run on its ticket is something fixing it" "0" "$(red2h_would 43)"
want "with nothing working it, it is reported" "1" "$(red2h_would 41)"
fresh
jq -s . <(pr 41 601 - SUCCESS) > "$FIX/gh/prs-all.json"
red_at would 41 sha41abcdef 300
tick >/dev/null
want "a PR green again leaves the clock file" "" "$(cat "$C/red-since.would.tsv")"
fresh
jq -s . <(pr 41 601 - FAILURE | jq '.title = "Feed: keep the scroll place"') > "$FIX/gh/prs-all.json"
red_at did 41 sha41abcdef 150
COORDINATOR_SHADOW=0 tick >/dev/null
want "live, the owner is pinged with the PR's title and failing check" \
  "PR #41 (Feed: keep the scroll place) has been red for 2h 30m with nothing fixing it: failing ci" "$(grep '^PR #41 (' "$FIX/notify.log")"
want_in "and it is in needs-you.md"         '<!-- key:red-2h:41:sha41abcdef -->' "$(cat "$C/needs-you.md" 2>/dev/null)"
fresh
jq -s . <(pr 41 601 - FAILURE) > "$FIX/gh/prs-all.json"
red_at would 41 sha41abcdef 50
COORDINATOR_RED_REPORT_MIN=45 tick >/dev/null
want "coordinator.redReportMin sets the bar" "1" "$(red2h_would 41)"

echo "--- sign-off batches: five green held PRs, the moment the fifth goes green ---"
fresh
jq -s . <(held 51 52 53 54) <(pr 55 615 needs:human-approval SUCCESS DIRTY) > "$FIX/gh/prs-all.json"
COORDINATOR_SHADOW=0 tick >/dev/null
want "four green and one clashing is no batch" "" "$(cat "$FIX/notify.log"; cat "$C/needs-you.md" 2>/dev/null)"
jq -s . <(held 51 52 53 54 55 56) > "$FIX/gh/prs-all.json"
COORDINATOR_SHADOW=0 tick >/dev/null
want "the fifth green makes one batch"     "1" "$(grep -c . "$FIX/notify.log")"
want_in "the owner is told the five"       '^5 screens are ready for your sign-off: PR #51, #52, #53, #54, #55$' "$(cat "$FIX/notify.log")"
want_in "needs-you carries the batch, keyed on its set" \
  'PR #51, .*#55 <!-- key:signoff-batch:51@sha51ab,52@sha52ab,53@sha53ab,54@sha54ab,55@sha55ab -->' "$(cat "$C/needs-you.md")"
COORDINATOR_SHADOW=0 tick >/dev/null
want "a batch is sent once, not every tick" "1" "$(grep -c . "$FIX/notify.log")"
jq -s . <(held 51 52 53 54 55 56 57 58 59) > "$FIX/gh/prs-all.json"
COORDINATOR_SHADOW=0 tick >/dev/null
want "the sixth to ninth wait for a fifth" "1" "$(grep -c . "$FIX/notify.log")"
jq -s . <(held 51 52 53 54 55 56 57 58 59 60) > "$FIX/gh/prs-all.json"
COORDINATOR_SHADOW=0 tick >/dev/null
want_in "the tenth sends the second batch" 'PR #56, #57, #58, #59, #60' "$(sed -n 2p "$FIX/notify.log")"
fresh
jq -n '[{number:45, headRefName:"tkt-605-x", headRefOid:"s45", isDraft:false, mergeStateStatus:"CLEAN",
         labels:[{name:"needs:human-approval"}],
         statusCheckRollup:[{name:"ci", status:"COMPLETED", conclusion:"SUCCESS"}, {context:"deploy", state:"PENDING"}]}]' > "$FIX/gh/prs-all.json"
want "a pending status context is not green" "" "$(bash "$HERE/signoff-batch.sh" green < "$FIX/gh/prs-all.json")"
fresh
jq -s . <(held 51 52 53 54 55) > "$FIX/gh/prs-all.json"
tick >/dev/null
want "shadow tells the owner nothing"      "" "$(cat "$FIX/notify.log"; cat "$C/needs-you.md" 2>/dev/null)"
want_in "shadow logs that it would"        'would	notify	signoff-batch:51@' "$(cat "$C/actions.log")"
COORDINATOR_SHADOW=0 tick >/dev/null
want "going live still sends a batch shadow saw" "1" "$(grep -c . "$FIX/notify.log")"

echo "--- the owner channel carries decisions only ---"
fresh
jq -s . <(pr 41 601 - FAILURE) > "$FIX/gh/prs-all.json"
COORDINATOR_SHADOW=0 COORDINATOR_JUDGE=true tick >/dev/null
want "a red PR never reaches needs-you"    "" "$(cat "$FIX/notify.log"; cat "$C/needs-you.md" 2>/dev/null)"

echo "--- the worktree sweep: every coordinator.sweepEveryMin, live only out of shadow ---"
fresh
COORDINATOR_SHADOW=0 COORDINATOR_JUDGE=true tick >/dev/null
want "live: the worktree sweep removes"     "wtsweep --apply" "$(grep wtsweep "$FIX/house.log")"
: > "$FIX/house.log"
COORDINATOR_SHADOW=0 COORDINATOR_JUDGE=true tick >/dev/null
want "inside the interval it does not run again" "" "$(grep wtsweep "$FIX/house.log")"
touch -t 202001010000 "$C/worktree-sweep.stamp"
COORDINATOR_SHADOW=0 COORDINATOR_JUDGE=true tick >/dev/null
want "once the interval has passed it runs again" "wtsweep --apply" "$(grep wtsweep "$FIX/house.log")"
fresh
COORDINATOR_JUDGE=true tick >/dev/null
want "shadow: the worktree sweep runs dry"  "wtsweep " "$(grep wtsweep "$FIX/house.log")"

echo "--- disk ---"
# The cache pass stand-in frees what $FIX/frees says, so the re-measure sees it.
cat > "$BIN/cachepass" <<'SH'
#!/usr/bin/env bash
echo "cachepass $*" >> "$FIX/house.log"
[ -s "$FIX/frees" ] && cat "$FIX/frees" > "$FIX/free"
exit 0
SH
cat > "$BIN/df" <<'SH'
#!/usr/bin/env bash
cat "$FIX/free"
SH
chmod +x "$BIN/cachepass" "$BIN/df"
disk() { # <free-before> <free-after-pass> [env...]
  printf '%s\n' "$1" > "$FIX/free"; printf '%s' "$2" > "$FIX/frees"
  shift 2
  env COORDINATOR_DF="$BIN/df" COORDINATOR_CACHE="$BIN/cachepass" "$@" bash "$T" 2>&1
}
fresh
out=$(disk 300 "" COORDINATOR_SHADOW=0)
want "with room to spare, no cache pass"   "" "$(grep cachepass "$FIX/house.log")"
fresh
out=$(disk 5 50 COORDINATOR_SHADOW=0)
want_in "below the floor, the cache pass runs first, for real" '^cachepass --caches-only --apply$' "$(cat "$FIX/house.log")"
want "and freeing enough means no alarm"   "" "$(cat "$FIX/notify.log")"
want_in "the tick says what it freed"      '5 GB free.* 50 GB after the cache pass' "$out"
fresh
out=$(disk 5 8 COORDINATOR_SHADOW=0)
want_in "still below the floor after the pass is an alarm" 'Disk is low: 8 GB' "$(cat "$FIX/notify.log")"
want_in "once the pass has run"            'cachepass --caches-only --apply' "$(cat "$FIX/house.log")"
fresh
out=$(disk 5 "")
want_in "shadow: the cache pass runs dry"  '^cachepass --caches-only$' "$(cat "$FIX/house.log")"
fresh
COORDINATOR_SHADOW=0 COORDINATOR_FREE_GB=5 COORDINATOR_CACHE="$BIN/cachepass" tick >/dev/null
want_in "below the floor is an alarm"      'Disk is low: 5 GB' "$(cat "$FIX/notify.log")"

echo "--- the merge lane runs each tick, in its own mode, only where the project names a merge method ---"
cat > "$BIN/lane" <<'LN'
#!/usr/bin/env bash
echo "lane shadow=${MERGE_LANE_SHADOW:-unset}" >> "$FIX/lane.log"
LN
chmod +x "$BIN/lane"
fresh; : > "$FIX/lane.log"
out=$(COORDINATOR_LANE="$BIN/lane" tick)
want "no merge method: the lane does not run" "" "$(cat "$FIX/lane.log")"
want_in "and the tick says why"            'merge lane: off — [a-z]+\.json has no merge\.method' "$out"
cp "$HARNESS_CFG_PATH" "$FIX/cfg.bak"
jq '.merge = {method: "squash"}' "$FIX/cfg.bak" > "$HARNESS_CFG_PATH"
COORDINATOR_LANE="$BIN/lane" tick >/dev/null
want "with one, the lane runs once"        "lane shadow=unset" "$(cat "$FIX/lane.log")"
: > "$FIX/lane.log"
COORDINATOR_SHADOW=0 MERGE_LANE_SHADOW=0 COORDINATOR_LANE="$BIN/lane" tick >/dev/null
want "and in its own mode"                 "lane shadow=0" "$(cat "$FIX/lane.log")"
cp "$FIX/cfg.bak" "$HARNESS_CFG_PATH"

echo "--- the judge: a fresh claude per event, capped, with no history ---"
fresh
printf '{"run_id":"claim-802-y","ticket":"802","log":"%s"}\n' "$STATE/logs/claim-802-y.log" > "$STATE/runs/claim-802-y.json"
printf '{"type":"result","result":"Parked: blocked on a decision"}\n' > "$STATE/logs/claim-802-y.log"
printf '{"run_id":"claim-802-y","exit_code":0}\n' > "$STATE/runs/claim-802-y.ended"
tick >/dev/null
COORDINATOR_SHADOW=0 tick >/dev/null; sleep 0.5
want "going live does not replay the shadow night's events" "" "$(cat "$FIX/claude.log")"
# stood_down <ticket> <id> — a run that ended parked: the event a judge takes
stood_down() {
  printf '{"run_id":"claim-%s-%s","ticket":"%s","log":"%s"}\n' "$1" "$2" "$1" "$STATE/logs/claim-$1-$2.log" > "$STATE/runs/claim-$1-$2.json"
  printf '{"type":"result","result":"Parked: the spec contradicts itself"}\n' > "$STATE/logs/claim-$1-$2.log"
  printf '{"run_id":"claim-%s-%s","exit_code":0}\n' "$1" "$2" > "$STATE/runs/claim-$1-$2.ended"
}
fresh
stood_down 601 j
tick >/dev/null
want "shadow starts no judge"              "" "$(cat "$FIX/claude.log")"
want_in "shadow logs the judgement it would start" 'would	judge	stood-down:claim-601-j' "$(cat "$C/actions.log")"
rm -f "$STATE/runs/claim-601-j.ended"; rm -f "$C/ended.seen"; stood_down 601 k
COORDINATOR_SHADOW=0 tick >/dev/null
for _ in $(seq 1 50); do ls "$C"/judges/*.ended >/dev/null 2>&1 && break; sleep 0.1; done
argv=$(cat "$FIX/claude.log")
want "one judge for one event"             "1" "$(grep -c ^ARGV "$FIX/claude.log")"
want_in "it has a turn cap"                '\[--max-turns\] \[40\]' "$argv"
want_in "it has a budget"                  '\[--max-budget-usd\] \[5\]' "$argv"
want "its compact window is bounded"       "COMPACT=150000" "$(grep ^COMPACT "$FIX/claude.log")"
want_in "it loads only the builder's MCP servers" '\[--strict-mcp-config\] \[--mcp-config\] \[[^]]*builder-mcp\.json\]' "$argv"
want "and the builder list is empty unless set" "" "$(jq -r '.mcpServers | keys | join(",")' "$STATE/swarm/builder-mcp.json" 2>&1)"
want_in "the brief carries the one event"  'stood-down:claim-601-k' "$argv"
want_not_in "it never resumes a session"   '\[--(resume|continue)\]|\[-c\]|\[-r\]' "$argv"
COORDINATOR_SHADOW=0 tick >/dev/null
sleep 0.3
want "an event is judged once"             "1" "$(grep -c ^ARGV "$FIX/claude.log")"

echo "--- the judge launches from the tick every tick, never behind housekeeping's lock ---"
fresh; mkdir -p "$C"
# A housekeeping run held alive by a slow sweep, as a 20-30 min worktree sweep holds it.
cat > "$BIN/slowsweep" <<'SH'
#!/usr/bin/env bash
touch "$FIX/sweep.started"; sleep 60
SH
chmod +x "$BIN/slowsweep"; rm -f "$FIX/sweep.started"
COORDINATOR_SHADOW=0 COORDINATOR_SWEEP="$BIN/slowsweep" bash "$HERE/coordinator-housekeeping.sh" > /dev/null 2>&1 &
HK=$!
for _ in $(seq 1 100); do [ -f "$FIX/sweep.started" ] && break; sleep 0.1; done
want "the slow housekeeping holds its lock"  "yes" "$([ -d "$C/housekeeping.lock" ] && kill -0 "$HK" 2>/dev/null && echo yes)"
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
at12=$(iso $(( $(date +%s) - 12 * 60 )))
jq -cn --arg at "$at12" '{id:"red-pr:91:sha91", at:$at, kind:"red-pr", judge:true, ticket:"691", pr:"91", detail:"ci red"}' >> "$C/events.did.jsonl"
jq -cn --arg at "$(iso "$(date +%s)")" '{id:"stood-down:claim-692-q", at:$at, kind:"stood-down", judge:true, ticket:"692", pr:"", detail:"run claim-692-q ended exit 0: ⏸ #692 parked (pm): which repo — a or b?"}' >> "$C/events.did.jsonl"
out=$(COORDINATOR_SHADOW=0 COORDINATOR_JUDGES=1 tick)
for _ in $(seq 1 50); do grep -q ^ARGV "$FIX/claude.log" 2>/dev/null && break; sleep 0.1; done
want "a judge launches while housekeeping is still running" "1" "$(grep -c ^ARGV "$FIX/claude.log")"
want_in "the question park is judged before the older red PR" 'stood-down:claim-692-q' "$(cat "$FIX/claude.log")"
want_in "the tick says how many wait and how old the oldest is" 'judge: 2 waiting, oldest 1[23] min' "$out"
want_in "the red PR waits for a slot"        'judge: no slot for red-pr:91:sha91' "$out"
pkill -P "$HK" 2>/dev/null; kill "$HK" 2>/dev/null; wait "$HK" 2>/dev/null; rm -rf "$C/housekeeping.lock"
# Two launchers at once (a tick and a leftover one): the second is refused, never doubles an event.
fresh; mkdir -p "$C/judge.lock"
jq -cn --arg at "$(iso "$(date +%s)")" '{id:"red-pr:93:sha93", at:$at, kind:"red-pr", judge:true, ticket:"693", pr:"93", detail:"ci red"}' >> "$C/events.did.jsonl"
out=$(COORDINATOR_SHADOW=0 bash "$HERE/coordinator-judge.sh" 2>&1); sleep 0.3
want "a launcher that loses the lock starts nothing" "0" "$(grep -c "red-pr:93" "$C/judged.did.ids" 2>/dev/null || true)"
want_in "and says why"                       'judge: another judge launcher is taking the lock' "$out"
rm -rf "$C/judge.lock"
want "the default is two judges at once"      "2" "$(env -u COORDINATOR_JUDGES bash -c '. "$1/coordinator-env.sh" && echo "$COORD_JUDGES"' _ "$HERE")"


echo "--- a list of scopes: the tick works a ticket under any one of them ---"
fresh
cat > "$BIN/claimable" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "701	P1	A			one" "702	P2	B			two" "799	P0	C			elsewhere"
STUB
chmod +x "$BIN/claimable"
printf '[{"name":"project:alpha"},{"name":"area:BETA"}]\n' > "$FIX/gh/labels.json"
fix_issue_list "project:alpha" '[{"number":701}]'
fix_issue_list "area:BETA" '[{"number":702}]'
fix_issue 701 OPEN "project:alpha,status:ready"; fix_issue 702 OPEN "area:BETA,status:ready"
COORDINATOR_CLAIMABLE="$BIN/claimable" bash "$Q" seed "alpha,area:BETA" >/dev/null
echo 701 > "$FIX/claims.txt"
out=$(COORDINATOR_CLAIMABLE="$BIN/claimable" COORDINATOR_REFRESH=1 COORDINATOR_SHADOW=0 tick)
want "the refresh keeps both scopes, and the second scope's ticket spawns" "702" "$(spawned)"
want "a ticket under neither scope is not queued" "" "$(jq -r '.tickets[] | select(.n==799) | .n' "$C/queue.json")"
stood_down 702 s
COORDINATOR_SHADOW=0 tick >/dev/null
for _ in $(seq 1 50); do ls "$C"/judges/*.brief >/dev/null 2>&1 && break; sleep 0.1; done
want_in "the judge's brief names every scope" 'Scope \(a ticket under any one of these is in scope\): project:alpha, area:BETA' "$(cat "$C"/judges/*.brief)"

echo "--- a builder's owner question reaches the owner, and the ticket waits for the answer ---"
OQ="$HERE/owner-question.sh"; W="$HERE/needsme-watch.sh"
# The label is the waiting state, so these cases run on a gh whose label edits stick.
export SWARM_GH="$BIN/gh-labels"
labels_of() { jq -r '[.labels[].name] | join(",")' "$FIX/gh/issue-$1.json"; }
# A spawned builder that needs the owner's pick: it asks through the kit and ends with no branch.
cat > "$BIN/spawn-asks" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "${CLAIM_CLASS:-}" >> "$SPAWNS"
bash "$OQ" ask "$1" "fix-a-or-b" "Fix A (retry the call) or Fix B (drop the cache)?" >/dev/null
printf '{"run_id":"claim-%s-asks","ticket":"%s","child_pid":1,"log":"/dev/null"}\n' "$1" "$1" > "$STATE/runs/claim-$1-asks.json"
printf '{"exit_code":0}\n' > "$STATE/runs/claim-$1-asks.ended"
SH
chmod +x "$BIN/spawn-asks"; export OQ
fresh; : > "$GH_LOG"; queue 501
SWARM_SPAWN="$BIN/spawn-asks" COORDINATOR_SHADOW=0 tick >/dev/null
want "the builder ran"                     "501" "$(spawned)"
want_in "its question is in needs-you.md under a decision key" '^- \[ \] .*#501: Fix A \(retry the call\) or Fix B \(drop the cache\)\? <!-- key:decision:501:fix-a-or-b -->' "$(cat "$C/needs-you.md")"
want_in "the ticket wears the owner-decision label" 'needs:owner-decision' "$(labels_of 501)"
want_in "and the question is on the ticket" 'issue comment 501 .*Waiting on the owner' "$(cat "$GH_LOG")"
want_in "the watcher offers it as a decision" $'^decision:501:fix-a-or-b\tdecision\t#501: Fix A' "$(bash "$W" pending --no-forge)"
# Released back to ready, the way the reconciler leaves it, and queued again.
bash "$Q" add 501 >/dev/null; : > "$SPAWNS"
out=$(SWARM_SPAWN="$BIN/spawn-asks" COORDINATOR_SHADOW=0 tick)
want "the next tick does not respawn a ticket waiting on the owner" "" "$(spawned)"
want_in "and says why"                     'skip #501 \(new\): needs:owner-decision' "$out"
want_in "the line is still open"           '^- \[ \] .*key:decision:501:fix-a-or-b' "$(cat "$C/needs-you.md")"

fresh; queue 502; fix_issue 502 OPEN "status:ready,needs:owner-decision"
out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick)
want "the label alone keeps it from every spawner" "" "$(spawned)"
want_in "named"                            'skip #502 \(new\): needs:owner-decision' "$out"

# The judge's decision path: owner-question.sh ask, the same label.
fresh; queue 503
bash "$OQ" ask 503 scope "#503 is out of scope as written: narrow it, or widen the scope?" >/dev/null
out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick)
want "a judge's decision on a ticket also holds it" "" "$(spawned)"

echo "--- a driver park's question, answered, reaches a run (status:parked does not outlive it) ---"
# status:parked blocks every spawn; a park that asked left it beside the owner's label,
# and the answer removed only the owner's label, so the ticket never ran again.
fresh; : > "$GH_LOG"; fix_issue 601 OPEN "status:parked,status:needs-human"
bash "$OQ" ask 601 driver-park "Keep A or B?" >/dev/null
bash "$W" answer decision:601:driver-park "B" >/dev/null
want_not_in "the answer lifts status:parked" 'status:parked' "$(labels_of 601)"
want_not_in "and the park's needs-human" 'status:needs-human' "$(labels_of 601)"
: > "$SPAWNS"
SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 COORDINATOR_CAP=1 tick >/dev/null
want "the answered park spawns"            "601" "$(spawned)"
rm -f "$STATE/runs/claim-601-live.json"
# Answered on GitHub (the owner's label taken off by hand): the sync lifts it too.
fresh; : > "$GH_LOG"; fix_issue 602 OPEN "status:parked"
bash "$OQ" ask 602 driver-park "Keep A or B?" >/dev/null
fix_issue 602 OPEN "status:parked"
bash "$OQ" sync >/dev/null
want_not_in "answered on the ticket, the sync lifts it" 'status:parked' "$(labels_of 602)"
# Any other question's answer leaves a park alone.
fresh; fix_issue 603 OPEN "status:parked"
bash "$OQ" ask 603 scope "Narrow it?" >/dev/null
bash "$W" answer decision:603:scope "yes" >/dev/null
want_in "a question that is not the park's leaves status:parked" 'status:parked' "$(labels_of 603)"

echo "--- the owner's answer frees the ticket, wherever it is given ---"
fresh; : > "$GH_LOG"; queue 501
SWARM_SPAWN="$BIN/spawn-asks" COORDINATOR_SHADOW=0 tick >/dev/null
bash "$Q" add 777 >/dev/null; fix_issue 777 OPEN "status:ready"
out=$(bash "$W" answer decision:501:fix-a-or-b "Fix B, and keep the cache warm on start")
want_in "it says what it did"              'answered: decision:501:fix-a-or-b — #501 back on the queue \(new\)' "$out"
want "the label comes off"                 "status:ready" "$(labels_of 501)"
want_in "the answer is on the ticket"      'issue comment 501 .*The owner answered.*Fix B, and keep the cache warm' "$(cat "$GH_LOG")"
want "it goes back at the front of the queue" "501" "$(jq -r '.tickets[0].n' "$C/queue.json")"
want_in "with the answer in its note"      'Fix B, and keep the cache warm on start' "$(jq -r '.tickets[0].note' "$C/queue.json")"
want_in "its needs-you line is ticked"     '^- \[x\] .*key:decision:501:fix-a-or-b' "$(cat "$C/needs-you.md")"
want "and never offered again"             "" "$(bash "$W" pending --no-forge | cut -f1 | grep -x 'decision:501:fix-a-or-b')"
: > "$SPAWNS"
SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 COORDINATOR_CAP=1 tick >/dev/null
want "the next tick spawns it first"       "501" "$(spawned)"
want_in "the builder is handed the answer" 'spawn	501	new — The owner answered decision:501:fix-a-or-b: Fix B' "$(awk -F'\t' '$3=="spawn"' "$C/actions.log" | cut -f3-)"
rm -f "$STATE/runs/claim-501-live.json"
bash "$OQ" ask 501 fix-a-or-b "Now: keep the old cache file, or delete it?" >/dev/null
want_in "a second question on it takes a fresh key" 'key:decision:501:fix-a-or-b-2 -->' "$(grep '^- \[ \]' "$C/needs-you.md")"
want "a watcher answer needs a decision key" "2" "$(bash "$W" answer blind:x "y" >/dev/null 2>&1; echo $?)"

# Answered on GitHub: a reply and the label taken off by hand. The next tick frees it.
fresh; queue 501
SWARM_SPAWN="$BIN/spawn-asks" COORDINATOR_SHADOW=0 tick >/dev/null
fix_issue 501 OPEN "status:ready"; : > "$SPAWNS"
out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick)
want "the label taken off on the ticket: the next tick spawns it" "501" "$(spawned)"
want_in "and says it was answered there"   'owner: answered elsewhere: decision:501:fix-a-or-b' "$out"
want_in "the open line is ticked"          '^- \[x\] .*key:decision:501:fix-a-or-b' "$(cat "$C/needs-you.md")"
want_in "the builder is told where the answer is" 'answered decision:501:fix-a-or-b on the ticket itself' "$(awk -F'\t' '$3=="spawn"' "$C/actions.log" | cut -f5)"

# The forge refusing the label change: the line stays open, the answer pending, and a later sync lands it.
fresh; queue 501
SWARM_SPAWN="$BIN/spawn-asks" COORDINATOR_SHADOW=0 tick >/dev/null
cat > "$BIN/gh-down" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in "issue edit") exit 1 ;; esac
exec "$BIN/gh-labels" "$@"
SH
chmod +x "$BIN/gh-down"
SWARM_GH="$BIN/gh-down" bash "$W" answer decision:501:fix-a-or-b "Fix A" >/dev/null 2>&1
want "a failed answer exits non-zero"      "1" "$(SWARM_GH="$BIN/gh-down" bash "$OQ" answer decision:501:fix-a-or-b "Fix A" >/dev/null 2>&1; echo $?)"
want_in "the line stays open"              '^- \[ \] .*key:decision:501:fix-a-or-b' "$(cat "$C/needs-you.md")"
want "the ticket still waits"              "needs:owner-decision" "$(bash "$OQ" waiting 501)"
want "the owner is not asked again"        "" "$(bash "$W" pending --no-forge | cut -f1 | grep -x 'decision:501:fix-a-or-b')"
: > "$SPAWNS"
out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick)
want "the next tick replays it: the ticket is freed and spawned" "501" "$(spawned)"
want_in "with the answer it was given"     'The owner answered decision:501:fix-a-or-b: Fix A' "$(awk -F'\t' '$3=="spawn"' "$C/actions.log" | cut -f5)"
want_in "the line is ticked once it lands" '^- \[x\] .*key:decision:501:fix-a-or-b' "$(cat "$C/needs-you.md")"
export SWARM_GH="$BIN/gh"

echo "--- starts ramp to the headroom: the room re-read between starts, one a tick near the floor ---"
export SWARM_CORES=10
# A spawner that moves the machine's reading the moment it starts one, as a real start does.
cat > "$BIN/spawn-fills" <<'SH'
#!/usr/bin/env bash
"$BIN/spawn-live" "$1"
[ -n "${FILL_FILE:-}" ] && printf '%s\n' "$FILL_TO" > "$FILL_FILE"
exit 0
SH
chmod +x "$BIN/spawn-fills"
ramp_tick() { SWARM_SPAWN="$BIN/spawn-fills" COORDINATOR_SHADOW=0 tick; }
fresh; queue 501 502 503; printf '99\n' > "$FIX/idle"
out=$(SWARM_IDLE_FILE="$FIX/idle" FILL_FILE="$FIX/idle" FILL_TO=20 ramp_tick)
want "the CPU fills after the first start: the re-read stops the second" "501" "$(spawned)"
want_in "and says so"                      'spawn: 1 started, then no room: cpu idle 20%' "$out"
fresh; queue 501 502 503; printf '99\n' > "$FIX/idle"
out=$(SWARM_IDLE_FILE="$FIX/idle" FILL_FILE="$FIX/idle" FILL_TO=99 ramp_tick)
want "the reading holds: all three start (the guard flags nothing correct)" "501 502 503" "$(spawned)"
fresh; queue 501 502 503; printf '16\n' > "$FIX/mem"
out=$(SWARM_FREE_MEM_FILE="$FIX/mem" FILL_FILE="$FIX/mem" FILL_TO=5 ramp_tick)
want "memory drops under the ramp floor after one start: no second" "501" "$(spawned)"
want_in "and says so"                      'spawn: 1 started, then 3.5 GB free after 1.5 GB a start, under the 8 GB a second start in one tick needs' "$out"
fresh; queue 501 502 503
out=$(SWARM_FREE_MEM_GB=6 ramp_tick)
want "near the memory floor: one start a tick, though the CPU fits more" "501" "$(spawned)"
want_in "and says so"                      'spawn: 1 started, then 4.5 GB free after 1.5 GB a start, under the 8 GB a second start in one tick needs' "$out"
fresh; queue 501 502 503
SWARM_FREE_MEM_GB=6 COORDINATOR_RAMP_FREE_MEM_GB=3 ramp_tick >/dev/null
want "the ramp floor is configurable"     "501 502 503" "$(spawned)"
fresh; queue 501 502 503 504
out=$(COORDINATOR_RAMP_MAX=2 ramp_tick)
want "coordinator.rampMax caps the starts in one tick" "501 502" "$(spawned)"
want_in "and says so"                      'coordinator.rampMax is 2' "$out"
fresh; queue 501 502 503 504
out=$(SWARM_FREE_MEM_GB=10 ramp_tick)
want "each start this tick is charged 1.5 GB: 10 GB free starts two" "501 502" "$(spawned)"
want_in "and says so"                      'spawn: 2 started, then 7.0 GB free after 1.5 GB a start' "$out"
fresh; queue 501 502 503 504
SWARM_FREE_MEM_GB=10 COORDINATOR_AGENT_MEM_GB=0.5 ramp_tick >/dev/null
want "the charge is configurable"          "501 502 503 504" "$(spawned)"
# Through the real sample path: the 5s shared sample and the median, no fixed reading.
cat > "$BIN/sampler" <<'SH'
#!/usr/bin/env bash
cat "$FIX/sample"
SH
chmod +x "$BIN/sampler"
cache_tick() { # <cached idle> <what a new sample reads>
  printf '%s %s\n' "$(date +%s)" "$1" > "$FIX/cpu-cache"; : > "$FIX/cpu-hist"; printf '%s\n' "$2" > "$FIX/sample"
  env -u SWARM_IDLE -u SWARM_IDLE_FILE SWARM_IDLE_CACHE="$FIX/cpu-cache" SWARM_IDLE_HISTORY="$FIX/cpu-hist" \
    SWARM_IDLE_SAMPLER="$BIN/sampler" SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" 2>&1
}
fresh; queue 501 502 503
out=$(cache_tick 99 20)
want "the shared sample says 99%, a new one 20%: the re-read sees the 20" "501" "$(spawned)"
want_in "and says so"                      'spawn: 1 started, then no room: cpu idle 20%' "$out"
fresh; queue 501 502 503
cache_tick 99 99 >/dev/null
want "a new sample that agrees: all three (the guard flags nothing correct)" "501 502 503" "$(spawned)"
export SWARM_IDLE=90; unset SWARM_CORES

# The live view's finished list says where each ticket stands now from this read,
# so a run that ended inside its window is read with the queue, and an old one is not.
fresh; queue 501
fix_issue 9001 OPEN "status:parked"; fix_issue 9002 OPEN "status:parked"
for t in 9001 9002; do
  printf '{"run_id":"claim-%s-x","ticket":"%s"}\n' "$t" "$t" > "$STATE/runs/claim-$t-x.json"
  printf '{"run_id":"claim-%s-x","exit_code":20}\n' "$t" > "$STATE/runs/claim-$t-x.ended"
done
touch -t 202601010000 "$STATE/runs/claim-9002-x.ended"
printf '{"number":9003,"state":"CLOSED","stateReason":"COMPLETED","title":"x","labels":[{"name":"status:in-review"}]}\n' > "$FIX/gh/issue-9003.json"
printf '{"run_id":"claim-9003-x","ticket":"9003"}\n' > "$STATE/runs/claim-9003-x.json"
printf '{"run_id":"claim-9003-x","exit_code":0}\n' > "$STATE/runs/claim-9003-x.ended"
tick >/dev/null
want "a closed ticket keeps why it closed"  "COMPLETED" "$(jq -r '.["9003"].stateReason' "$C/snapshot/issues.json" 2>/dev/null)"
want "a run that just ended: its ticket is in the issue snapshot" "true" "$(jq 'has("9001")' "$C/snapshot/issues.json" 2>/dev/null)"
want "with its labels"                     "status:parked" "$(jq -r '.["9001"].labels | join(",")' "$C/snapshot/issues.json" 2>/dev/null)"
want "a run that ended long ago is not read" "false" "$(jq 'has("9002")' "$C/snapshot/issues.json" 2>/dev/null)"
want "and the queue is still read"         "true" "$(jq 'has("501")' "$C/snapshot/issues.json" 2>/dev/null)"

echo "--- under the disk floor nothing new starts, and it stays held until the resume mark ---"
# The real guard, its roots in the fixture: a fake free-space reader, empty clean roots,
# a sweep that only records it ran. Owner call 2026-10-20: stop below 30 GB, resume at 50.
mkdir -p "$FIX/dg/tmp" "$FIX/dg/wt" "$FIX/dg/scratch"
cat > "$BIN/dgsweep" <<'SH'
#!/usr/bin/env bash
echo "sweep $*" >> "$FIX/dg/sweep.log"
SH
cat > "$BIN/dgdf" <<'SH'
#!/usr/bin/env bash
cat "$FIX/dg/free"
SH
# The clean reads the claims before it removes anything; here none is held.
printf '#!/usr/bin/env bash\necho "[]"\n' > "$BIN/dgclaims"; printf '#!/usr/bin/env bash\n:\n' > "$BIN/dgclaimrefs"
chmod +x "$BIN/dgsweep" "$BIN/dgdf" "$BIN/dgclaims" "$BIN/dgclaimrefs"
export WT_CLAIM_LIST="$BIN/dgclaims" WT_CLAIM_REFS="$BIN/dgclaimrefs"
dtick() { # <free GB>
  printf '%s\n' "$1" > "$FIX/dg/free"
  COORDINATOR_DISK_GUARD="$HERE/disk-guard.sh" COORDINATOR_DF="$BIN/dgdf" \
  DISK_GUARD_SWEEP="$BIN/dgsweep" SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 tick
}
fresh; queue 501 502; : > "$FIX/dg/sweep.log"
out=$(dtick 29)
want "29 GB free: nothing starts"          "" "$(spawned)"
want_in "the hold names the disk"          'spawn: starting nothing new — disk low: 29 GB free, under 30 GB' "$out"
want "the tick cleans nothing itself: each run's exit and the idle sweep do" "" "$(cat "$FIX/dg/sweep.log")"
want "the live page's file says held, with the free space" "29 true 30 50" "$(jq -r '"\(.disk.freeGb) \(.disk.held) \(.disk.stopBelowGb) \(.disk.resumeAtGb)"' "$C/capacity.json")"
want "the act is logged"                   "disk-hold" "$(awk -F'\t' '$3=="disk-hold"{print $3}' "$C/actions.log" | head -1)"
out=$(dtick 31)
want "31 GB, one GB over the floor: still held" "" "$(spawned)"
want_in "and it says until when"           'disk low: 31 GB free, held since under 30 GB — nothing new starts until 50 GB is free' "$out"
out=$(dtick 49)
want "49 GB: still held"                   "" "$(spawned)"
out=$(dtick 50)
want_in "50 GB: starts resume"             'disk: 50 GB free, at or above 50 GB — starts resume' "$out"
want "and the queue starts"                "501 502" "$(spawned)"
want "the live page's file says not held"  "50 false" "$(jq -r '"\(.disk.freeGb) \(.disk.held)"' "$C/capacity.json")"
fresh; queue 501; : > "$FIX/dg/sweep.log"
out=$(dtick 40)
want "40 GB with no hold before: starts" "501" "$(spawned)"
fresh; queue 501; : > "$FIX/dg/sweep.log"
printf '29\n' > "$FIX/dg/free"
out=$(COORDINATOR_DISK_GUARD="$HERE/disk-guard.sh" COORDINATOR_DF="$BIN/dgdf" DISK_GUARD_SWEEP="$BIN/dgsweep" tick)
want_in "shadow: the hold is said"         'starting nothing new — disk low: 29 GB' "$out"
unset WT_CLAIM_LIST WT_CLAIM_REFS

echo "--- every tick probes the live view ---"
# launchd restarts the live view only when it exits; the tick is what notices one that hangs.
fresh; : > "$FIX/watchdog.log"
tick >/dev/null
want "one probe a tick" "probe" "$(cat "$FIX/watchdog.log")"
# Plant: the hook deleted from a copy of the kit. The tick must then probe nothing.
K="$FIX/kit"; mkdir -p "$K"; (cd "$HERE/.." && tar --exclude=.git -cf - .) | (cd "$K" && tar -xf -)
grep -v 'live_view_watchdog; }$' "$HERE/coordinator-tick.sh" > "$K/scripts/coordinator-tick.sh"
grep -q 'live_view_watchdog' "$K/scripts/coordinator-tick.sh" && bad "plant did not land"
fresh; : > "$FIX/watchdog.log"
bash "$K/scripts/coordinator-tick.sh" >/dev/null 2>&1
want_in "planted: the copy's tick ran" 'tick: ' "$(cat "$C/tick.log" 2>/dev/null)"
[ -s "$FIX/watchdog.log" ] && bad "planted: the hook removed and the tick still probed → the test cannot see it" \
  || ok "planted: the hook removed → no probe → red"

suite_end "$FAILED"
