#!/usr/bin/env bash
# coordinator-tick.test.sh — the guards the tick exists to hold: one tick at a
# time, the machine-derived ceiling and its healing share, an optional hard cap,
# never a claimed / gated / held ticket, shadow does nothing,
# a frozen run is noticed. Plus the events, the owner channel and the judge.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
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
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
{ printf 'ARGV'; printf ' [%s]' "$@"; printf '\n'
  echo "COMPACT=${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-unset}"; } >> "$FIX/claude.log"
SH
cat > "$BIN/notify" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$FIX/notify.log"
SH
# fix-lock.sh list --json, read from a planted file.
cat > "$BIN/fixlock" <<'SH'
#!/usr/bin/env bash
cat "$FIX/fixing.json"
SH
chmod +x "$BIN/reconcile" "$BIN/sweep" "$BIN/claude" "$BIN/notify" "$BIN/fixlock"
export COORDINATOR_FIX_LOCK="$BIN/fixlock"
export COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep"
export COORDINATOR_CLAUDE="$BIN/claude" COORDINATOR_NOTIFY_CMD="$BIN/notify"
# Housekeeping in line and every tick, so each case reads what it did when the tick returns.
export COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
unset COORDINATOR_SHADOW COORDINATOR_CAP COORDINATOR_HEALING_SHARE COORDINATOR_START_CPU_IDLE COORDINATOR_MIN_FREE_MEM_GB
export SWARM_FREE_MEM_GB=16 TEST_PID=$$
# A spawner that leaves a live run behind and, like an older spawner,
# writes no class: the coordinator's own record must carry it.
cat > "$BIN/spawn-live" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "${CLAIM_CLASS:-}" >> "$SPAWNS"
printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s}\n' "$1" "$1" "$TEST_PID" \
  > "$STATE/runs/claim-$1-live.json"
SH
chmod +x "$BIN/spawn-live"

fresh() {
  rm -rf "$C" "$STATE/runs"/* "$STATE/swarm/HOLD"
  : > "$SPAWNS"; : > "$FIX/house.log"; : > "$FIX/claude.log"; : > "$FIX/notify.log"; : > "$FIX/claims.txt"
  printf '[]\n' > "$FIX/gh/prs-all.json"; printf '[]\n' > "$FIX/fixing.json"
  unset SWARM_NOW
}
queue() { local t; for t in "$@"; do fix_issue "$t" OPEN "status:ready"; bash "$Q" add "$t" >/dev/null; done; }
queue_as() { local c="$1" t; shift; for t in "$@"; do fix_issue "$t" OPEN "status:in-review"; bash "$Q" add "$t" --class "$c" >/dev/null; done; }
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

echo "--- live spawns, and a set cap is a hard ceiling ---"
fresh; queue 501 502 503 504 505 506; live_run 900
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=4 tick)
want "room under the cap: it fills to the cap, in queue order" "501 502 503" "$(spawned)"
want_in "live housekeeping is not dry"     '^reconcile --quiet' "$(cat "$FIX/house.log")"
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
want "the live view counts nothing running" "0 0" "$(jq -r '"\(.healing.live) \(.new.live)"' "$C/capacity.json")"

echo "--- no fixed cap: with coordinator.cap unset, the machine alone decides ---"
fresh; queue 501; for t in 900 901 902 903; do live_run $t; done
out=$(COORDINATOR_SHADOW=0 tick)
want "4 running and room: a 5th starts"    "501" "$(spawned)"
want_in "the tick says there is no cap"    'cap none' "$out"
fresh; queue 501; for t in 900 901 902 903 904 905 906; do live_run $t; done
out=$(COORDINATOR_SHADOW=0 tick)
want "7 running and room: an 8th starts"   "501" "$(spawned)"
want "the live view's file has no cap"     "null" "$(jq -r '.cap' "$C/capacity.json")"

echo "--- of the ceiling, a quarter heals and the rest builds new ---"
# One agent's room per tick (23% idle keeping 15%, 8% each), so a ramp is visible.
export SWARM_IDLE=23 SWARM_CORES=10
fresh; queue_as repair 601 602 603 604 605; queue 701 702 703 704 705
out=$(COORDINATOR_CAP=4 ticks 1)
want "the first tick takes the one healing place" "601" "$(spawned)"
out=$(COORDINATOR_CAP=4 ticks 4)
want "5 repairs + 5 new, ceiling 4: 1 repair and 3 new" "601 701 702 703" "$(spawned)"
want "by class"                            "repair new new new" "$(classes)"
want_in "the tick log shows the split"     'split: 3 new · 1 healing · 4 reds waiting' "$out"
want "the live view's file shows it too"   "1/1 3/3 4" "$(jq -r '"\(.healing.live)/\(.healing.slots) \(.new.live)/\(.new.slots) \(.redsWaiting)"' "$C/capacity.json")"
fresh; queue 701 702 703 704 705
COORDINATOR_CAP=4 ticks 4 >/dev/null
want "no repairs queued: all 4 places take new work" "701 702 703 704" "$(spawned)"
fresh; queue_as repair 604; queue 701; live_as 601 repair; live_as 602 repair; live_as 603 repair
COORDINATOR_CAP=4 ticks 1 >/dev/null
want "3 repairs live, 1 place free: it takes new work" "701" "$(spawned)"
fresh; queue_as repair 604; queue 701; live_as 601 -; live_as 602 -; live_as 603 -
printf '[{"number":61,"headRefName":"tkt-601-a","isDraft":false,"labels":[]},{"number":62,"headRefName":"tkt-602-a","isDraft":false,"labels":[]},{"number":63,"headRefName":"tkt-603-a","isDraft":false,"labels":[]}]\n' > "$FIX/gh/prs-all.json"
COORDINATOR_CAP=4 ticks 1 >/dev/null
want "runs from before classes, with open PRs, count as healing" "701" "$(spawned)"
fresh; queue_as repair 602 603; queue 701; live_as 601 repair
out=$(COORDINATOR_CAP=4 ticks 1)
want "with new work queued, a new place never takes healing" "701" "$(spawned)"
want_in "and the reds wait their turn"     'healing has its 1 place\(s\) — 2 red\(s\) wait their turn' "$out"
fresh; queue_as repair 601 602 603 604 605 606
ticks 4 >/dev/null
want "6 repairs, no new work, an idle Mac: healing ramps past 1" "601 602 603 604" "$(spawned)"
fresh; queue_as repair 601 602 603 604 605 606
out=$(ticks 2)
want_in "it says the place was lent"       'spawned #602 \(repair\) in a new place, nothing else spawnable' "$out"
fresh; queue_as repair 601 602 603; queue 701; echo 602 > "$FIX/claims.txt"
out=$(COORDINATOR_CAP=4 ticks 1)
want "only spawnable reds count as waiting" "1" "$(jq -r .redsWaiting "$C/capacity.json")"
want "next names the next spawnable entry, of either class" "603" "$(awk -F'\t' '$2=="plan"{n=$5; sub(/.*next=/,"",n); print n}' "$C/actions.log" | tail -1)"
fresh; queue_as repair 601 602 603; queue 701 702 703
COORDINATOR_CAP=4 COORDINATOR_HEALING_SHARE=0.5 ticks 4 >/dev/null
want "healingShare 0.5 of 4: 2 heal, 2 new" "2 2" "$(classes | tr ' ' '\n' | awk '/repair/{h++} /new/{n++} END{print h+0, n+0}')"
fresh; queue_as repair 601 602 603; queue 701 702 703 704 705 706
for t in 801 802 803 804; do live_as $t new; done
out=$(ticks 1)
want "ceiling 5 keeps 2 healing places"    "601" "$(spawned)"
want_in "the split is of whatever the ceiling is" 'of 5: 3 new, 2 healing' "$out"

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
oldspawn() { SWARM_SPAWN="$FIX/oldspawn/spawn-claim.sh" SWARM_IDLE=23 SWARM_CORES=10 COORDINATOR_SHADOW=0 COORDINATOR_CAP=4 bash "$T" 2>&1; }
fresh; queue_as repair 601 602; queue 701 702
oldspawn >/dev/null
want "the older spawner ran"               "601	no-class" "$(head -1 "$SPAWNS")"
want "its record carries no class"         "" "$(jq -r '.class // empty' "$STATE/runs/claim-601-old.json")"
want "the coordinator recorded it"         "repair" "$(awk -F'\t' '$1=="claim-601-old"{print $3}' "$C/run-classes.tsv")"
oldspawn >/dev/null
want "so the next tick counts it as healing and builds new" "601 701" "$(cut -f1 "$SPAWNS" | tr '\n' ' ' | sed 's/ $//')"
want "the live view agrees"                "1 1" "$(jq -r '"\(.healing.live) \(.new.live)"' "$C/capacity.json")"
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
printf '#!/usr/bin/env bash\ncase "$1 $2" in "pr list") exit 1 ;; esac\nexec "%s" "$@"\n' "$BIN/gh" > "$FIX/gh-nopr"; chmod +x "$FIX/gh-nopr"
out=$(COORDINATOR_SHADOW=0 SWARM_GH="$FIX/gh-nopr" tick)
want "unreadable pull requests spawn nothing" "" "$(spawned)"
want_in "and says so"                      'pull requests could not be read' "$out"

echo "--- fresh work never goes to a ticket whose PR is open; a spawned entry leaves the queue ---"
fresh; queue 501 502
jq -n '[{number:9, headRefName:"tkt-501-x", headRefOid:"s", isDraft:true, mergeStateStatus:"CLEAN", labels:[], statusCheckRollup:[]}]' > "$FIX/gh/prs-all.json"
out=$(COORDINATOR_SHADOW=0 tick)
want "the open PR's ticket is skipped"     "502" "$(spawned)"
want_in "and named"                        'skip #501 \(new\): has an open PR' "$out"
want "the spawned ticket left the queue"   "501" "$(jq -r '.tickets[].n' "$C/queue.json" | tr '\n' ' ' | sed 's/ $//')"

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
want_in "a cut run with an open PR comes back as a repair" "Coordinator note \(repair\): Resume: run claim-806-cut" "$(grep '^806' "$SPAWNS")"

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

echo "--- pull requests: red is judged, green pixels go to the owner in batches ---"
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
want "a settled red PR is judged"          "1" "$(grep -c '"id":"red-pr:41:sha41a' "$C/events.would.jsonl")"
want "a clash is judged"                   "1" "$(grep -c '"id":"red-pr:43:sha43a' "$C/events.would.jsonl")"
want "a healthy PR raises nothing"         "0" "$(grep -c '"id":"[a-z-]*:44:' "$C/events.would.jsonl")"
want "one green held PR is not a batch"    "0" "$(grep -c '"kind":"signoff"' "$C/events.would.jsonl")"
fresh
# A pending commit status (the design critic's verdict, waiting) never holds a real red back, and alone is not red.
withstatus() { jq --arg s "$1" '.statusCheckRollup += [{__typename:"StatusContext", context:"Design critic", state:$s}]'; }
jq -s . <(pr 46 606 - FAILURE | withstatus PENDING) <(pr 47 607 - SUCCESS | withstatus PENDING) <(pr 48 608 - SUCCESS | withstatus FAILURE) > "$FIX/gh/prs-all.json"
tick >/dev/null
want "a red PR waiting on a status is still judged" "1" "$(grep -c '"id":"red-pr:46:sha46a' "$C/events.would.jsonl")"
want "a pending status alone is not red"   "0" "$(grep -c '"id":"red-pr:47:' "$C/events.would.jsonl")"
want "a failed status is red"              "1" "$(grep -c '"id":"red-pr:48:sha48a' "$C/events.would.jsonl")"
fresh
jq -s . <(pr 41 601 - FAILURE) <(pr 43 603 - SUCCESS DIRTY) > "$FIX/gh/prs-all.json"
printf '[{"pr":41,"window":"mac:4242","expired":false},{"pr":43,"window":"mac:77","expired":true}]\n' > "$FIX/fixing.json"
out=$(tick)
want "a red PR a session is fixing is not judged" "0" "$(grep -c '"id":"[a-z-]*:41:' "$C/events.would.jsonl")"
want_in "and the tick says who has it"     'PR #41: .*being fixed by mac:4242' "$out"
want "an expired fix lock fixes nothing"   "1" "$(grep -c '"id":"red-pr:43:sha43a' "$C/events.would.jsonl")"

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
fresh
jq -s . <(pr 41 601 - FAILURE) > "$FIX/gh/prs-all.json"
tick >/dev/null
want "shadow starts no judge"              "" "$(cat "$FIX/claude.log")"
want_in "shadow logs the judgement it would start" 'would	judge	red-pr:41:sha41' "$(cat "$C/actions.log")"
COORDINATOR_SHADOW=0 tick >/dev/null
for _ in $(seq 1 50); do ls "$C"/judges/*.ended >/dev/null 2>&1 && break; sleep 0.1; done
argv=$(cat "$FIX/claude.log")
want "one judge for one event"             "1" "$(grep -c ^ARGV "$FIX/claude.log")"
want_in "it has a turn cap"                '\[--max-turns\] \[40\]' "$argv"
want_in "it has a budget"                  '\[--max-budget-usd\] \[5\]' "$argv"
want "its compact window is bounded"       "COMPACT=150000" "$(grep ^COMPACT "$FIX/claude.log")"
want_in "it loads only the builder's MCP servers" '\[--strict-mcp-config\] \[--mcp-config\] \[[^]]*builder-mcp\.json\]' "$argv"
want "and the builder list is empty unless set" "" "$(jq -r '.mcpServers | keys | join(",")' "$STATE/swarm/builder-mcp.json" 2>&1)"
want_in "the brief carries the one event"  'red-pr:41:sha41' "$argv"
want_not_in "it never resumes a session"   '\[--(resume|continue)\]|\[-c\]|\[-r\]' "$argv"
COORDINATOR_SHADOW=0 tick >/dev/null
sleep 0.3
want "an event is judged once"             "1" "$(grep -c ^ARGV "$FIX/claude.log")"


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
jq -s . <(pr 44 702 - FAILURE) > "$FIX/gh/prs-all.json"
tick >/dev/null
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

exit $FAILED
