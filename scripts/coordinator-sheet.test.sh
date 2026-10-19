#!/usr/bin/env bash
# coordinator-sheet.test.sh — two machines that each own a copy of the work order
# will pick against each other; the order lives in one shared place.
#
# Two coordinators ("mac", the owner, and "box", a reader) run real ticks against
# one stand-in GitHub. Each has its own state dir and a DIFFERENT local queue with
# the same head, and a spawner whose claim lands later (as the driver's start step
# does), so the only thing that can keep them apart is the shared sheet.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
T="$HERE/coordinator-tick.sh"
Q="$HERE/coordinator-queue.sh"

# ---- the world -----------------------------------------------------------------
for s in reconcile sweep notify; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$s"; chmod +x "$BIN/$s"; done
printf '#!/usr/bin/env bash\nprintf "[]\\n"\n' > "$BIN/fixlock"; chmod +x "$BIN/fixlock"
export COORDINATOR_FIX_LOCK="$BIN/fixlock" COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep"
export COORDINATOR_NOTIFY_CMD="$BIN/notify" COORDINATOR_HOUSEKEEPING_CMD="$BIN/sweep" COORDINATOR_HOUSEKEEPING=inline
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 SWARM_FREE_MEM_GB=16 TEST_PID=$$
export COORDINATOR_CLAIMS_CMD="cat $FIX/claims.tsv"
unset COORDINATOR_SHADOW COORDINATOR_CAP COORDINATOR_SHEET_OWNER COORDINATOR_HOST

# The sheet on the stand-in GitHub: $FIX/sheet/number and body. Every write is a line in writes.log.
SH="$FIX/sheet"; mkdir -p "$SH"
cat > "$BIN/gh-sheet" <<'STUB'
#!/usr/bin/env bash
SH="$FIX/sheet"; q=""; prev=""
for a in "$@"; do case "$prev" in --jq|-q) q="$a" ;; esac; prev="$a"; done
out() { if [ -n "$q" ]; then jq -r "$q"; else cat; fi; }
case "$*" in
  "api repos/acme/widgets/issues?labels="*)
    printf '%s\n' "$*" >> "$GH_LOG"; [ -f "$SH/down" ] && exit 1
    if [ -s "$SH/number" ]; then printf '[{"number":%s}]\n' "$(cat "$SH/number")" | out; else echo '[]' | out; fi ;;
  "api repos/acme/widgets/labels "*) printf '%s\n' "$*" >> "$GH_LOG" ;;
  "api repos/acme/widgets/issues -f title="*)
    printf '%s\n' "$*" >> "$GH_LOG"; echo 777 > "$SH/number"; echo "create" >> "$SH/writes.log"
    echo '{"number":777}' | out ;;
  "issue pin "*) printf '%s\n' "$*" >> "$GH_LOG"; echo "pin $3" >> "$SH/writes.log" ;;
  "api -X PATCH repos/acme/widgets/issues/"*)
    printf '%s\n' "$*" >> "$GH_LOG"; jq -r .body > "$SH/body"; echo "patch" >> "$SH/writes.log" ;;
  "api repos/acme/widgets/issues/"*)
    printf '%s\n' "$*" >> "$GH_LOG"; [ -f "$SH/down" ] && exit 1
    jq -n --rawfile b "$SH/body" '{number: 777, state: "open", body: $b}' | out ;;
  *) exec "$BIN/gh" "$@" ;;
esac
STUB
chmod +x "$BIN/gh-sheet"; export SWARM_GH="$BIN/gh-sheet"

# A spawner that leaves a live run on its own machine and records which host took
# what. It writes no claim: on a real machine the claim lands minutes later.
cat > "$BIN/spawn-host" <<'STUB'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "$COORDINATOR_HOST" >> "$SPAWNS"
printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s}\n' "$1" "$1" "$TEST_PID" \
  > "$HARNESS_STATE_DIR/runs/claim-$1-live.json"
STUB
chmod +x "$BIN/spawn-host"

world() {
  rm -rf "$FIX/m-mac" "$FIX/m-box" "$SH"/*; mkdir -p "$FIX/m-mac/runs" "$FIX/m-box/runs"
  : > "$SPAWNS"; : > "$FIX/claims.tsv"; : > "$GH_LOG"; : > "$SH/writes.log"; unset SWARM_NOW
}
# on <host> <command…> — the command as that machine: its own state, its own name.
on() { local h="$1"; shift; HARNESS_STATE_DIR="$FIX/m-$h" COORDINATOR_HOST="$h" "$@"; }
tick_on() { # <host> <cap> — one live tick on that machine, the sheet owned by mac
  on "$1" env COORDINATOR_SHEET_OWNER="${OWNER-mac}" COORDINATOR_CAP="$2" COORDINATOR_SHADOW=0 \
    SWARM_SPAWN="$BIN/spawn-host" bash "$T" 2>&1
}
queue_on() { local h="$1" t; shift; for t in "$@"; do on "$h" bash "$Q" add "$t" >/dev/null; done; }
by() { awk -F'\t' -v h="$1" '$2 == h { print $1 }' "$SPAWNS" | tr '\n' ' ' | sed 's/ $//'; }
writes() { grep -c patch "$SH/writes.log" | tr -d ' '; }
sheet_json() { awk '/^```json/{s=1;next} /^```/{s=0} s' "$SH/body"; }

for t in 501 502 503 504 505; do fix_issue "$t" OPEN "status:ready,P1"; done

echo "--- two machines, two local queues with the same head: both work the owner's order ---"
world
queue_on mac 501 502 503 504
queue_on box 501 505 504 503
out=$(tick_on mac 1)
want "the owner takes the head of its order"        "501" "$(by mac)"
want_in "it writes the sheet"                       'sheet: wrote #777 \(changed\)' "$out"
want "the sheet is made once and pinned"            "create pin 777 patch" "$(tr '\n' ' ' < "$SH/writes.log" | sed 's/ $//')"
want "the sheet names the owner's start as building there" \
  '[{"n":501,"class":"new","prin":1,"host":"mac"},{"n":502,"class":"new","prin":1},{"n":503,"class":"new","prin":1},{"n":504,"class":"new","prin":1}]' "$(sheet_json)"
want_in "in plain words, numbered in run order"     '^1\. #501 · High · Fix · Ticket 501 — building on mac$' "$(cat "$SH/body")"
want_in "and the next one ready"                    '^2\. #502 · High · Fix · Ticket 502 — ready$' "$(cat "$SH/body")"
want_in "the header counts by priority"             '4 in the queue: High 4' "$(cat "$SH/body")"
want_in "building now names the host"               '^- #501 · Ticket 501 — on mac, step: starting$' "$(cat "$SH/body")"
out=$(tick_on box 1)
want "the reader takes the sheet's next ticket, not its own queue's head" "502" "$(by box)"
want_in "and says whose order it works"             "sheet: working mac's order" "$out"
want "nothing was started twice"                    "" "$(cut -f1 "$SPAWNS" | sort | uniq -d)"
# The claims land: each host's run holds its ticket on the shared refs.
printf '501\tmac\tbuild\n502\tbox\tplan\n' > "$FIX/claims.tsv"
out=$(tick_on mac 2)
want "the owner skips what the other host holds"    "501 503" "$(by mac)"
want_in "the sheet shows the other host's build and its step" '^- #502 · Ticket 502 — on box, step: plan$' "$(cat "$SH/body")"
out=$(tick_on box 2)
want "the reader takes the next one after that"     "502 504" "$(by box)"
want "across four ticks, no ticket started twice"   "" "$(cut -f1 "$SPAWNS" | sort | uniq -d)"
want "and nothing outside the owner's order started" "" "$(cut -f1 "$SPAWNS" | grep -x 505)"
want "the reader's queue is the sheet's, its own order gone" "sheet" "$(jq -r .source "$FIX/m-box/coordinator/queue.json")"

echo "--- the reader keeps the sheet's order even where its own sort would differ ---"
world
fix_issue 701 OPEN "status:ready,P1"; fix_issue 702 OPEN "status:ready"
queue_on mac 701; on mac bash "$Q" add 702 --front >/dev/null
tick_on mac 0 >/dev/null
want "the owner put its answer first"               "702 701" "$(sheet_json | jq -r '.[].n' | tr '\n' ' ' | sed 's/ $//')"
tick_on box 1 >/dev/null
want "the reader takes 702, though by priority alone 701 comes first" "702" "$(by box)"

echo "--- unchanged order: zero writes; a change or the heartbeat: one ---"
world
queue_on mac 501 502
tick_on mac 0 >/dev/null
want "the first tick writes"                        "1" "$(writes)"
out=$(tick_on mac 0)
want "the same order the next tick: no write"       "1" "$(writes)"
want_in "and it says so"                            'sheet: unchanged — not written' "$out"
want "nor any call to find the sheet"               "1" "$(grep -c 'issues?labels=' "$GH_LOG" | tr -d ' ')"
fix_issue 503 OPEN "status:ready,P0"; queue_on mac 503
tick_on mac 0 >/dev/null
want "a new ticket in the order: one write"         "2" "$(writes)"
want_in "in its place: priority first"              '^1\. #503 · Urgent' "$(cat "$SH/body")"
SWARM_NOW=$(( $(date +%s) + 6 * 60 )) tick_on mac 0 >/dev/null
want "quiet for a third of staleMin: one heartbeat write" "3" "$(writes)"

echo "--- a stale or unreadable sheet: the reader starts nothing new ---"
world
queue_on mac 501 502; queue_on box 501 502
tick_on mac 0 >/dev/null
out=$(SWARM_NOW=$(( $(date +%s) + 20 * 60 )) tick_on box 2)
want "a sheet 20 minutes old: nothing starts"       "" "$(by box)"
want_in "and the tick says why"                     'starting nothing new — the sheet is 20 min old .*over the 15 min limit' "$out"
out=$(SWARM_NOW=$(( $(date +%s) + 20 * 60 )) COORDINATOR_SHEET_STALE_MIN=30 tick_on box 1)
want "coordinator.sheet.staleMin moves the limit"   "501" "$(by box)"
world
queue_on box 501 502
out=$(tick_on box 2)
want "no sheet at all: nothing starts, its own queue unused" "" "$(by box)"
want_in "and it names that"                         'starting nothing new — the sheet could not be read' "$out"
world
queue_on mac 501; tick_on mac 0 >/dev/null
tick_on box 0 >/dev/null
touch "$SH/down"
out=$(tick_on box 1)
want "GitHub refusing, a fresh copy on hand: it works the copy" "501" "$(by box)"
want_in "and says it is the copy"                   'the last copy read' "$out"
out=$(SWARM_NOW=$(( $(date +%s) + 20 * 60 )) tick_on box 2)
want "GitHub refusing and the copy old: nothing more starts" "501" "$(by box)"
rm -f "$SH/down"

echo "--- only startable work is on the sheet; a repair is ---"
world
fix_issue 601 OPEN "status:ready,P1,after-launch"
fix_issue 602 OPEN "status:ready,P1,needs:owner-decision"
fix_issue 603 OPEN "status:ready,P1,needs:human-approval"
fix_issue 604 OPEN "status:claimed,P1"
fix_issue 605 OPEN "status:ready,status:parked"
fix_issue 606 OPEN "P1"
fix_issue 607 OPEN "status:in-review,P1"
fix_issue 608 OPEN "status:ready,status:batched"
fix_issue 609 CLOSED "status:ready,P1"
queue_on mac 501 601 602 603 604 605 606 607 608 609
on mac bash "$Q" add 610 --class repair >/dev/null; fix_issue 610 OPEN "status:in-review,P1"
on mac bash "$Q" add 610 --class repair >/dev/null
tick_on mac 0 >/dev/null
want "after-launch, owner decision, held, claimed, parked, unready, in review, batched and closed stay off" \
  "610:repair 501:new" "$(sheet_json | jq -r '.[] | "\(.n):\(.class)"' | tr '\n' ' ' | sed 's/ $//')"
want_in "the repair reads as one"                   '#610 · High · Red PR to fix' "$(cat "$SH/body")"

echo "--- no owner set: no sheet, no calls, each queue as before ---"
world
queue_on mac 501; queue_on box 502
out=$(OWNER= tick_on box 1)
want "the machine works its own queue"              "502" "$(by box)"
want "and asks GitHub nothing about a sheet"        "0" "$(grep -c 'repos/acme/widgets/issues' "$GH_LOG" | tr -d ' ')"
want_not_in "and says nothing of one"               'sheet:' "$out"

echo "--- the host names compare without case ---"
world
queue_on mac 501
out=$(OWNER=MAC tick_on mac 0)
want_in "MAC owns it on mac"                        'sheet: wrote' "$out"

exit $FAILED
