#!/usr/bin/env bash
# coordinator-why.test.sh — a remote host that can't explain its own idleness stays idle,
# because nobody can read its tick log.
#
# On 2026-10-22 the build VM (a reader, capacity 16) posted 0 builds, runs [] for hours,
# and its heartbeat said nothing about why. Two things here:
#   - the heartbeat carries `why`: this tick's last pace, ceiling, spawn, open-changes and
#     sheet lines, the first 5 skips and the skips by reason, and a plain-words line on
#     the comment and the sheet's machine list;
#   - a reader that paces while the sheet carries no budget (the owner's pacing is off)
#     counted every owner build against a fleet cap nobody keeps, and started nothing.
#     The sheet's order over the open-work cap starts its process fixes and repairs.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
T="$HERE/coordinator-tick.sh"

for s in reconcile sweep notify; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$s"; chmod +x "$BIN/$s"; done
printf '#!/usr/bin/env bash\nprintf "[]\\n"\n' > "$BIN/fixlock"; chmod +x "$BIN/fixlock"
export COORDINATOR_FIX_LOCK="$BIN/fixlock" COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep"
export COORDINATOR_NOTIFY_CMD="$BIN/notify" COORDINATOR_HOUSEKEEPING_CMD="$BIN/sweep" COORDINATOR_HOUSEKEEPING=inline
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 SWARM_FREE_MEM_GB=64 SWARM_IDLE=90 SWARM_CORES=32 TEST_PID=$$
export COORDINATOR_CLAIMS_CMD="cat $FIX/claims.tsv" COORDINATOR_LIVE_VIEW_WATCHDOG=off
unset COORDINATOR_SHADOW COORDINATOR_CAP COORDINATOR_SHEET_OWNER COORDINATOR_HOST COORDINATOR_MIN_HARNESS \
      COORDINATOR_OPEN_PR_CAP COORDINATOR_TOOLING_CAP COORDINATOR_PRODUCT_FLOOR SWARM_NOW \
      COORDINATOR_PACE_TARGET COORDINATOR_PACE_HEADROOM COORDINATOR_PACE_BURN
export COORDINATOR_PACE_WEEK_HEADROOM=1

# ---- the stand-in GitHub: the sheet (#777) and its comments ------------------------
SH="$FIX/sheet"; mkdir -p "$SH"
cat > "$BIN/gh-why" <<'STUB'
#!/usr/bin/env bash
SH="$FIX/sheet"; q=""; prev=""
for a in "$@"; do case "$prev" in --jq|-q) q="$a" ;; esac; prev="$a"; done
out() { if [ -n "$q" ]; then jq -r "$q"; else cat; fi; }
case "$*" in
  "api repos/acme/widgets/issues?labels="*) printf '[{"number":777}]\n' | out ;;
  "api repos/acme/widgets/issues/777/comments?per_page=100") out < "$SH/comments.json" ;;
  "api --method POST repos/acme/widgets/issues/777/comments --input -")
    b=$(jq -r .body); id=$(( 9000 + $(jq length "$SH/comments.json") ))
    jq --arg b "$b" --argjson id "$id" '. + [{id: $id, body: $b}]' "$SH/comments.json" > "$SH/c.tmp" && mv "$SH/c.tmp" "$SH/comments.json"
    jq -n --argjson id "$id" '{id: $id}' | out ;;
  "api --method PATCH repos/acme/widgets/issues/comments/"*)
    id=${4##*/}; b=$(jq -r .body)
    jq --arg b "$b" --argjson id "$id" 'map(if .id == $id then .body = $b else . end)' "$SH/comments.json" > "$SH/c.tmp" && mv "$SH/c.tmp" "$SH/comments.json"
    jq -n --argjson id "$id" '{id: $id}' | out ;;
  "api repos/acme/widgets/issues/777")
    jq -n --rawfile b "$SH/body" '{number: 777, state: "open", labels: [{name: "build-sheet"}], body: $b}' | out ;;
  *) exec "$BIN/gh" "$@" ;;
esac
STUB
chmod +x "$BIN/gh-why"; export SWARM_GH="$BIN/gh-why"

cat > "$BIN/spawn-host" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SPAWNS"
printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s}\n' "$1" "$1" "$TEST_PID" \
  > "$HARNESS_STATE_DIR/runs/claim-$1-live.json"
STUB
chmod +x "$BIN/spawn-host"

NOWE=$(date +%s)
M="$FIX/m-vm"
# The sheet as the owner wrote it on 22 Oct: process fixes first, then reds to fix, then new
# tickets. Optionally with a budget (`<!-- sheet:pace … -->`), as an owner that paces writes it.
sheet() { # [pace json]
  { printf 'The order every machine builds in.\n\n<!-- sheet:v1 updated=%s owner=mac -->\n```json\n' "$NOWE"
    printf '%s' '[{"n":13621,"class":"new","prin":1,"process":true},{"n":13788,"class":"new","prin":2,"process":true},{"n":13625,"class":"repair","prin":1},{"n":13044,"class":"repair","prin":2},{"n":13447,"class":"repair","prin":2},{"n":13900,"class":"new","prin":1},{"n":13901,"class":"new","prin":2}'"${EXTRA:-}"']'
    printf '\n'
    printf '```\n'
    [ -z "${1:-}" ] || printf '<!-- sheet:pace %s -->\n' "$1"; } > "$SH/body"
}
world() { # [five-hour use]
  rm -rf "$M"; mkdir -p "$M/runs" "$M/logs"; : > "$SPAWNS"; printf '[]\n' > "$SH/comments.json"
  # The owner is building 8, none of them tooling.
  printf '%s\tmac\tbuild\n' 13001 13002 13003 13004 13005 13006 13007 13008 > "$FIX/claims.tsv"
  for t in 13001 13002 13003 13004 13005 13006 13007 13008; do fix_issue "$t" OPEN "status:in-progress,P2"; done
  fix_issue 13621 OPEN "status:ready,P1,process"; fix_issue 13788 OPEN "status:ready,P2,process"
  fix_issue 13625 OPEN "status:in-review,P1"; fix_issue 13044 OPEN "status:in-review,P2"; fix_issue 13447 OPEN "status:in-review,P2"
  fix_issue 13900 OPEN "status:ready,P1"; fix_issue 13901 OPEN "status:ready,P2"
  # 87 open changes, over the cap of 10: the three repairs' PRs among them.
  jq -n '[range(0; 84) | {number: (20000 + .), headRefName: "tkt-\(20000 + .)-open", headRefOid: "h\(.)", isDraft: false,
          mergeStateStatus: "CLEAN", labels: [], statusCheckRollup: []}]
         + [13625, 13044, 13447 | {number: (. + 100000), headRefName: "tkt-\(.)-fix", headRefOid: "r\(.)", isDraft: false,
          mergeStateStatus: "DIRTY", labels: [], statusCheckRollup: []}]' > "$FIX/gh/prs-all.json"
  # The account's five-hour window at 39%, 2h50m to the reset, as the VM's own last log read it.
  jq -nc --argjson u "${1:-0.39}" --argjson r "$(( NOWE + 10166 ))" --argjson r7 "$(( NOWE + 445166 ))" \
    '{type:"rate_limit_event", rate_limit_info:{status:"allowed",
      unifiedWindows:{five_hour:{utilization:$u, resetsAt:$r}, seven_day:{utilization:0.21, resetsAt:$r7}}}}' > "$M/logs/claim-1-a.log"
}
vm_tick() { # one live tick on the VM, a reader of mac's sheet, pacing on as its own config says
  HARNESS_STATE_DIR="$M" COORDINATOR_HOST=Yomato COORDINATOR_SHEET_OWNER=mac COORDINATOR_PACE=1 \
    COORDINATOR_SHADOW=0 SWARM_SPAWN="$BIN/spawn-host" bash "$T" 2>&1
}
spawned() { sort -n "$SPAWNS" | tr '\n' ' ' | sed 's/ $//'; }
hb_json() { jq -r '.[0].body' "$SH/comments.json" | sed -nE 's/^<!-- sheet:heartbeat-json (\{.*\}) -->$/\1/p'; }

echo "--- a reader over the cap, the sheet with no budget: it starts its process fixes and repairs ---"
world; sheet
out=$(vm_tick)
want "the two process fixes and the three repairs start; no new ticket" "13044 13447 13621 13625 13788" "$(spawned)"
want_in "the tick says the cap holds new work" 'open changes 87 / cap 10: finishing before starting' "$out"
want_in "and that the pace is not applied, and why" 'pace: not applied — the sheet carries no budget from mac' "$out"

echo "--- a budget this tick did not apply never takes the tooling places ---"
cp "$SH/comments.json" "$FIX/comments.first.json"
world 0.80; sheet
out=$(vm_tick)
want "the floor the unapplied budget computed holds nothing back" "true" "$(jq -r '.productFloor.applied' "$M/coordinator/pace.json")"
want "the process fixes and repairs still start"      "13044 13447 13621 13625 13788" "$(spawned)"
want_not_in "no tooling hold from it"                 'the places now are the product floor' "$out"
cp "$FIX/comments.first.json" "$SH/comments.json"

echo "--- the heartbeat says why, from this tick's own lines ---"
hb=$(hb_json)
want "the heartbeat carries a why"                    "object" "$(jq -r '.why | type' <<<"$hb")"
want_in "its pace line"                               '^pace: not applied' "$(jq -r '.why.pace' <<<"$hb")"
want_in "its ceiling line"                            '^ceiling: 0 running · room for [0-9]+ more' "$(jq -r '.why.ceiling' <<<"$hb")"
want_in "its open-changes line"                       '^open changes 87 / cap 10: finishing before starting$' "$(jq -r '.why.openChanges' <<<"$hb")"
want_in "its sheet line"                              "^sheet: working mac's order, 0 min old — 7 on it$" "$(jq -r '.why.sheet' <<<"$hb")"
want_in "the cap line names what waits"               '^cap: 2 new ticket\(s\) wait' "$(jq -r '.why.cap' <<<"$hb")"
want "no skips this tick"                             "0 0" "$(jq -r '"\(.why.skips | length) \(.why.skipsBy | length)"' <<<"$hb")"
want "every line at most 200 characters"              "true" "$(jq '[.why | .. | strings | length <= 200] | all' <<<"$hb")"
want_in "the comment says it in plain words"          '^why: .*pace|^why: .*new ticket\(s\) wait' "$(jq -r '.[0].body' "$SH/comments.json")"

echo "--- an idle tick: the spawn line and the skips by reason ---"
world; for t in 13450 13451 13452; do fix_issue "$t" OPEN "status:in-review,P2"; done
EXTRA=',{"n":13450,"class":"repair","prin":2},{"n":13451,"class":"repair","prin":2},{"n":13452,"class":"repair","prin":2}' sheet
# The claims landed after the owner wrote the order: six repairs claimed, one with a stop label.
printf '%s\tmac\tbuild\n' 13625 13044 13447 13450 13451 >> "$FIX/claims.tsv"
fix_issue 13452 OPEN "status:in-review,P2,status:blocked"
# Both process fixes are claimed on mac too: the tooling cap is full, and says so.
printf '%s\tmac\tbuild\n' 13621 13788 >> "$FIX/claims.tsv"
out=$(vm_tick)
want "nothing is startable: nothing starts"           "" "$(spawned)"
hb=$(hb_json)
want "the first 5 skips, in order"                    "5" "$(jq -r '.why.skips | length' <<<"$hb")"
want_in "a skip line as the tick said it: the process fix the tooling cap holds" \
  '^skip #13621 \(new\): the tooling cap — 2 live of 2$' "$(jq -r '.why.skips[0]' <<<"$hb")"
want_in "and the second one"                         '^skip #13788 \(new\): the tooling cap' "$(jq -r '.why.skips[1]' <<<"$hb")"
want "every skip counted by reason, the tooling-capped ones named too" \
  '{"claimed":5,"status:blocked":1,"the tooling cap — 2 live of 2":2}' "$(jq -c '.why.skipsBy' <<<"$hb")"
want_in "the tooling line says the process fixes wait" '^tooling: 2 tooling ticket\(s\) wait' "$(jq -r '.why.tooling // ""' <<<"$hb")"
want_in "and the spawn line"                          '^spawn: ' "$(jq -r '.why.spawn // ""' <<<"$hb")"
want_in "the plain-words line names the skips"        '^why: .*skipped 5 claimed, 1 status:blocked' "$(jq -r '.[0].body' "$SH/comments.json")"

echo "--- the owner's sheet lists each machine's why ---"
out=$( . "$HERE/coordinator-env.sh" >/dev/null 2>&1; . "$HERE/coordinator-sheet.sh" >/dev/null 2>&1
       coord_sheet_render "$(jq -nc --argjson h "$hb" '{order: [], building: [], fleet: [$h + {behind: false}]}')" "$NOWE" )
want_in "a why line under the machine"                '^  - why: .*skipped 5 claimed' "$out"
want_not_in "no < or > inside the heartbeat comment"  '[<>]' "$(jq -r '.why | .. | strings' <<<"$hb")"

echo "--- with a budget on the sheet, the reader still paces by the owner's share ---"
world; printf '%s\tmac\tbuild\n' 13001 13002 13003 > "$FIX/claims.tsv"
sheet '{"maxBuildsFleet":9,"shares":{"mac":8,"Yomato":1},"usage":{"five_hour":{"u":0.39,"reset":'"$(( NOWE + 10166 ))"'}}}'
out=$(vm_tick)
want "its share of 1: one start, the first process fix" "13621" "$(spawned)"
want_in "the pace line is the owner's split"          'pace: 5h window 39%' "$out"

suite_end "$FAILED"
