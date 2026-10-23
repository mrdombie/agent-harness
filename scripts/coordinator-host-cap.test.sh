#!/usr/bin/env bash
# coordinator-host-cap.test.sh — a fleet-wide limit set in one host's config that the other
# hosts never read.
#
# On 2026-10-23 the owner's config said coordinator.cap 4, and the build VM (a reader) still
# ran 10 to 12: its own config or env set its cap, and it never read the owner's. The owner
# now publishes its cap on the sheet (`<!-- sheet:cap {"perHost":N} -->`) and every reader
# takes the smaller of its own and the sheet's, whatever its env says. The cap stops new
# starts only: running builds finish. The heartbeat says where the config came from and
# whether COORDINATOR_CAP was set in the env.
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
export COORDINATOR_CLAIMS_CMD="cat $FIX/claims.tsv" COORDINATOR_LIVE_VIEW_WATCHDOG=off COORDINATOR_SHARED_INSTALL="$BIN/sweep"
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
  "api -X PATCH repos/acme/widgets/issues/777 --input -")
    jq -r .body > "$SH/body"; jq -n '{number: 777, state: "open", labels: [{name: "build-sheet"}]}' | out ;;
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
sheet() { # [perHost]
  { printf 'The order every machine builds in.\n\n<!-- sheet:v1 updated=%s owner=mac -->\n```json\n' "$NOWE"
    printf '%s\n' '[{"n":13621,"class":"new","prin":1,"process":true},{"n":13788,"class":"new","prin":2,"process":true},{"n":13625,"class":"repair","prin":1},{"n":13044,"class":"repair","prin":2},{"n":13447,"class":"repair","prin":2}]'
    printf '```\n'
    [ -z "${1:-}" ] || printf '<!-- sheet:cap {"perHost":%s} -->\n' "$1"; } > "$SH/body"
}
world() { # <builds already live on this host>
  rm -rf "$M"; mkdir -p "$M/runs" "$M/logs"; : > "$SPAWNS"; printf '[]\n' > "$SH/comments.json"
  : > "$FIX/claims.tsv"
  local i
  for i in $(seq 1 "$1"); do
    printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s,"started_at":"2026-10-01T00:00:00Z"}\n' $((14000+i)) $((14000+i)) "$TEST_PID" \
      > "$M/runs/claim-$((14000+i))-live.json"
    printf '%s\tYomato\tbuild\n' $((14000+i)) >> "$FIX/claims.tsv"
    fix_issue $((14000+i)) OPEN "status:in-progress,P2"
  done
  fix_issue 13621 OPEN "status:ready,P1,process"; fix_issue 13788 OPEN "status:ready,P2,process"
  fix_issue 13625 OPEN "status:in-review,P1"; fix_issue 13044 OPEN "status:in-review,P2"; fix_issue 13447 OPEN "status:in-review,P2"
  jq -n '[13625, 13044, 13447 | {number: (. + 100000), headRefName: "tkt-\(.)-fix", headRefOid: "r\(.)", isDraft: false,
          mergeStateStatus: "DIRTY", labels: [], statusCheckRollup: []}]' > "$FIX/gh/prs-all.json"
}
vm_tick() { # one live tick on the VM, a reader of mac's sheet, its env saying COORDINATOR_CAP=16
  HARNESS_STATE_DIR="$M" COORDINATOR_HOST=Yomato COORDINATOR_SHEET_OWNER=mac COORDINATOR_PACE=0 \
    COORDINATOR_CAP=16 COORDINATOR_SHADOW=0 SWARM_SPAWN="$BIN/spawn-host" bash "$T" 2>&1
}
spawned() { wc -l < "$SPAWNS" | tr -d ' '; }
hb_json() { jq -r '.[0].body' "$SH/comments.json" | sed -nE 's/^<!-- sheet:heartbeat-json (\{.*\}) -->$/\1/p'; }

echo "--- env cap 16, the sheet says 4 per host, 10 live: nothing starts ---"
world 10; sheet 4
out=$(vm_tick)
want "no start over the sheet's cap"                  "0" "$(spawned)"
want_in "the tick names the sheet's cap"              'host cap: 4 per host \(from the sheet; this machine.s own was 16\)' "$out"
want "no running build is stopped"                    "10" "$(ls "$M/runs" | grep -c "^claim-140")"
hb=$(hb_json)
want_in "the heartbeat why carries the host cap"      '^host cap: 4 per host \(from the sheet' "$(jq -r '.why.hostCap // ""' <<<"$hb")"
want_in "and where the config came from, and the env" "^config: from .* · COORDINATOR_CAP set to '16' in the env$" "$(jq -r '.why.config // ""' <<<"$hb")"

echo "--- the same, 2 live: at most 2 start ---"
world 2; sheet 4
out=$(vm_tick)
want "two start, up to the sheet's cap of 4"          "2" "$(spawned)"

echo "--- no cap on the sheet: today's behaviour, the machine's own cap ---"
world 2; sheet
out=$(vm_tick)
want "all five candidates start under its own 16"     "5" "$(spawned)"
want_in "the tick says the cap is its own"            'host cap: 16 per host \(this machine.s own\)' "$out"

echo "--- the owner publishes its cap on the sheet, and a reader reads it back ---"
out=$( . "$HERE/coordinator-env.sh" >/dev/null 2>&1; . "$HERE/coordinator-sheet.sh" >/dev/null 2>&1
       coord_sheet_render '{"order":[],"building":[],"fleet":[],"hostCap":{"perHost":4}}' "$NOWE" )
want_in "the sheet carries the per-host cap"          '^<!-- sheet:cap \{"perHost":4\} -->$' "$out"
printf '%s\n' "$out" > "$SH/body"
got=$( export HARNESS_STATE_DIR="$M" COORDINATOR_SHEET_OWNER=mac COORDINATOR_HOST=Yomato
       . "$HERE/coordinator-env.sh" >/dev/null 2>&1; . "$HERE/coordinator-sheet.sh" >/dev/null 2>&1
       coord_sheet_read >/dev/null 2>&1; printf '%s' "${SHEET_HOST_CAP:-}" )
want "a reader reads back what the owner wrote"       "4" "$got"

echo "--- the owner's own tick writes its cap on the sheet; a cap of 0 stops only the owner ---"
owner_tick() { # <cap>
  HARNESS_STATE_DIR="$FIX/m-mac" COORDINATOR_HOST=mac COORDINATOR_SHEET_OWNER=mac COORDINATOR_PACE=0 \
    COORDINATOR_CAP="$1" COORDINATOR_SHADOW=0 SWARM_SPAWN="$BIN/spawn-host" bash "$T" 2>&1
}
world 0; : > "$SH/body"; rm -rf "$FIX/m-mac"; mkdir -p "$FIX/m-mac/runs"
out=$(owner_tick 4)
want_in "the owner's sheet carries its cap of 4"      '^<!-- sheet:cap \{"perHost":4\} -->$' "$(cat "$SH/body")"
world 0; : > "$SH/body"; rm -rf "$FIX/m-mac"; mkdir -p "$FIX/m-mac/runs"
out=$(owner_tick 0)
want_in "the owner wrote the sheet"                   '<!-- sheet:v1 updated=' "$(cat "$SH/body")"
want_not_in "a cap of 0 is not the fleet's"           'sheet:cap' "$(cat "$SH/body")"

suite_end "$FAILED"
