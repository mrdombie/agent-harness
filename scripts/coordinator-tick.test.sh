#!/usr/bin/env bash
# coordinator-tick.test.sh — the guards the tick exists to hold: one tick at a
# time, the cap, never a claimed / gated / held ticket, shadow does nothing,
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
unset COORDINATOR_SHADOW

fresh() {
  rm -rf "$C" "$STATE/runs"/* "$STATE/swarm/HOLD"
  : > "$SPAWNS"; : > "$FIX/house.log"; : > "$FIX/claude.log"; : > "$FIX/notify.log"; : > "$FIX/claims.txt"
  printf '[]\n' > "$FIX/gh/prs-all.json"; printf '[]\n' > "$FIX/fixing.json"
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

echo "--- shadow is the default, and it does nothing ---"
fresh; queue 501 502
out=$(tick)
want "nothing spawned"                     "" "$(spawned)"
want_in "it says what it would do"         'would spawn #501' "$out"
want_in "it names where the config came from" "config from $HARNESS_CFG_PATH" "$out"
want "the act is logged as would"          "would spawn 501" "$(awk -F'\t' '$3=="spawn"{print $2, $3, $4}' "$C/actions.log" | head -1)"
want_in "reconcile runs dry"               'reconcile --dry-run' "$(cat "$FIX/house.log")"
want_in "the server sweep runs dry"        'sweep --sweep --dry-run' "$(cat "$FIX/house.log")"

echo "--- live spawns, up to the cap and no further ---"
fresh; queue 501 502 503 504 505 506; live_run 900
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=4 tick)
want "three slots, three spawns, in queue order" "501 502 503" "$(spawned)"
want_in "live housekeeping is not dry"     '^reconcile --quiet' "$(cat "$FIX/house.log")"
fresh; queue 501 502; live_run 900; live_run 901
out=$(COORDINATOR_SHADOW=0 COORDINATOR_CAP=2 tick)
want "at the cap, nothing spawns"          "" "$(spawned)"
want_in "and it says why"                  '2 live, cap 2 — no slot' "$out"

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
printf 'You have hit your session limit · resets 7pm\n' > "$STATE/logs/claim-803-x.log"
printf '{"run_id":"claim-803-x","exit_code":1}\n' > "$STATE/runs/claim-803-x.ended"
out=$(tick)
want_in "the final result line is recorded" 'claim-801-x.*exit=0 Handed off at abc123' "$(cat "$C/runs.log")"
want "a clean hand-off raises nothing"     "0" "$(grep -c 'claim-801-x' "$C/events.would.jsonl")"
want_in "a park is a stand-down"           '"kind":"stood-down".*"ticket":"802"' "$(cat "$C/events.would.jsonl")"
want_in "a limit stop is a usage-limit"    '"kind":"usage-limit".*"ticket":"803"' "$(cat "$C/events.would.jsonl")"
tick >/dev/null
want "each ended run is read once"         "3" "$(grep -c 'ended' "$C/runs.log")"
rm -f "$STATE/logs/claim-803-x.log"

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
want "a healthy PR raises nothing"         "0" "$(grep -c ':44' "$C/events.would.jsonl")"
want "one green held PR is not a batch"    "0" "$(grep -c '"kind":"signoff"' "$C/events.would.jsonl")"
fresh
jq -s . <(pr 41 601 - FAILURE) <(pr 43 603 - SUCCESS DIRTY) > "$FIX/gh/prs-all.json"
printf '[{"pr":41,"window":"mac:4242","expired":false},{"pr":43,"window":"mac:77","expired":true}]\n' > "$FIX/fixing.json"
out=$(tick)
want "a red PR a session is fixing is not judged" "0" "$(grep -c ':41:' "$C/events.would.jsonl")"
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

exit $FAILED
