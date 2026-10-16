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
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
unset COORDINATOR_SHADOW COORDINATOR_CAP COORDINATOR_HEALING_SHARE COORDINATOR_START_CPU_IDLE COORDINATOR_MIN_FREE_MEM_GB
export SWARM_FREE_MEM_GB=16 TEST_PID=$$
# A spawner that leaves a live run behind and, like the project copy production
# hands over to, writes no class: the coordinator's own record must carry it.
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

echo "--- live spawns: one per tick, and a set cap is a hard ceiling ---"
fresh; queue 501 502 503 504 505 506; live_run 900
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=4 tick)
want "room under the cap: one start, the first in queue order" "501" "$(spawned)"
want_in "live housekeeping is not dry"     '^reconcile --quiet' "$(cat "$FIX/house.log")"
fresh; queue 501 502; live_run 900; live_run 901
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=2 tick)
want "at the cap, nothing spawns"          "" "$(spawned)"
want_in "and it says why"                  '2 live, cap 2 — no slot' "$out"

echo "--- the ceiling follows the machine: room is one more than is running ---"
fresh; queue 501 502 503; live_run 900; live_run 901; live_run 902
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=40 SWARM_FREE_MEM_GB=16 tick)
want "idle 40%, memory over the floor: one more than the 3 running" "501" "$(spawned)"
want_in "the log names the ceiling and the reading" 'ceiling: 3 running · room for 1 more: cpu idle 40%, 16 GB free' "$out"
want "the live view's file holds the ceiling"  "4 true" "$(jq -r '"\(.ceiling) \(.room)"' "$C/capacity.json")"
want_in "and the reading behind it"        'cpu idle 40%, 16 GB free' "$(jq -r .reading "$C/capacity.json")"
fresh; queue 501
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=10 tick)
want "idle 10%: no start"                  "" "$(spawned)"
want_in "it is the hold floor"             'machine busy \(cpu idle 10%, floor 15%\) — holding' "$out"
fresh; queue 501; live_run 900
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=22 tick)
want "between the hold and start floors: no start, nothing stopped" "" "$(spawned)"
want_in "and it names the start floor"     '1 live, no room for more \(cpu idle 22%, start floor 30%\) — holding' "$out"
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
htick() { SWARM_IDLE_HISTORY="$H" COORDINATOR_SHADOW=0 tick; }
fresh; queue 501; seed 1200 40 900 42 600 38 300 41
out=$(SWARM_IDLE=5 htick)
want "a steady 40% with one 5% dip: it starts" "501" "$(spawned)"
want_in "the log gives the median and its sample count" 'room for 1 more: cpu idle 40% \(median of 5\), 16 GB free' "$out"
want "one tick reads twice and records once" "5" "$(wc -l < "$H" | tr -d ' ')"
fresh; queue 501; live_run 900; seed 1200 5 900 8 600 4 300 6
out=$(SWARM_IDLE=55 htick)
want "a busy machine with one 55% spike: the hold floor holds" "" "$(spawned)"
want_in "and names the median"             'machine busy \(cpu idle 6% \(median of 5\), floor 15%\) — holding' "$out"
fresh; queue 501; live_run 900; seed 1200 20 900 22 600 25 300 21
out=$(SWARM_IDLE=90 htick)
want "a 90% spike over a 22% median: under the start floor" "" "$(spawned)"
want_in "and names the start floor"        'no room for more \(cpu idle 22% \(median of 5\), start floor 30%\)' "$out"
fresh; queue 501; seed 4000 5 3900 5 3800 5 3700 5
out=$(SWARM_IDLE=40 htick)
want "samples past swarm.idleMaxAgeSec do not count" "501" "$(spawned)"
want_in "so the median is of one"          'cpu idle 40% \(median of 1\)' "$out"
fresh; queue 501; seed 1200 5 900 5 600 5 300 40
out=$(SWARM_IDLE=40 SWARM_IDLE_SAMPLES=3 htick)
want "swarm.idleSamples sets how many count" "501" "$(spawned)"

echo "--- exactly one start per tick, however much room ---"
fresh; queue 501 502 503 504 505 506
out=$(COORDINATOR_SHADOW=0 SWARM_IDLE=99 tick)
want "an idle machine, six queued, nothing live: one start" "501" "$(spawned)"

echo "--- no fixed cap: with coordinator.cap unset, the machine alone decides ---"
fresh; queue 501; for t in 900 901 902 903; do live_run $t; done
out=$(COORDINATOR_SHADOW=0 tick)
want "4 running and room: a 5th starts"    "501" "$(spawned)"
want_in "the tick says there is no cap"    'cap none' "$out"
fresh; queue 501; for t in 900 901 902 903 904 905 906; do live_run $t; done
out=$(COORDINATOR_SHADOW=0 tick)
want "7 running and room: an 8th starts"   "501" "$(spawned)"
want "the live view's file has no cap"     "null 8" "$(jq -r '"\(.cap) \(.ceiling)"' "$C/capacity.json")"

echo "--- of the ceiling, a quarter heals and the rest builds new ---"
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

echo "--- the class survives the hand-over to the project's own spawner ---"
# Production: the plugin's spawn-claim.sh execs the integration branch's copy, and
# that copy writes no class. The tick runs through the real hand-over here.
mkdir -p "$REPO/scripts"
cat > "$REPO/scripts/spawn-claim.sh" <<'SH'
#!/usr/bin/env bash
# The project's older copy: a run record with no class and no operator field.
. "$(dirname "$0")/toolkit-env.sh" 2>/dev/null
printf '%s\thanded-over\n' "$1" >> "$SPAWNS"
printf '{"run_id":"claim-%s-proj","ticket":"%s","child_pid":%s,"log":"/dev/null"}\n' "$1" "$1" "$TEST_PID" \
  > "$HARNESS_STATE_DIR/runs/claim-$1-proj.json"
SH
cp "$HERE/toolkit-env.sh" "$REPO/scripts/toolkit-env.sh"
git -C "$REPO" -c user.name=t -c user.email=t@t checkout -q -b develop 2>/dev/null
git -C "$REPO" add scripts .claude && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm project
git init -q --bare "$FIX/origin.git"; git -C "$REPO" remote add origin "$FIX/origin.git" 2>/dev/null
git -C "$REPO" push -q origin develop && git -C "$REPO" fetch -q origin
handover() { TMPDIR="$FIX" SWARM_SPAWN="$HERE/spawn-claim.sh" COORDINATOR_SHADOW=0 COORDINATOR_CAP=4 bash "$T" 2>&1; }
fresh; queue_as repair 601 602; queue 701 702
handover >/dev/null
want "the real spawner handed over"        "601	handed-over" "$(head -1 "$SPAWNS")"
want "its record carries no class"         "" "$(jq -r '.class // empty' "$STATE/runs/claim-601-proj.json")"
want "the coordinator recorded it"         "repair" "$(awk -F'\t' '$1=="claim-601-proj"{print $3}' "$C/run-classes.tsv")"
handover >/dev/null
want "so the next tick counts it as healing and builds new" "601 701" "$(cut -f1 "$SPAWNS" | tr '\n' ' ' | sed 's/ $//')"
want "the live view agrees"                "1 1" "$(jq -r '"\(.healing.live) \(.new.live)"' "$C/capacity.json")"
git -C "$REPO" remote remove origin; rm -rf "$FIX/origin.git" "$REPO/scripts"

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
want "the cut run is the next start, ahead of work queued before it" "805" "$(spawned)"
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

exit $FAILED
