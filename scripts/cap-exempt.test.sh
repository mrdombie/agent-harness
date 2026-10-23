#!/usr/bin/env bash
# cap-exempt.test.sh — over the open-work cap, a P0 starts anyway, whatever its size.
#
# The owner, 2026-10-23: urgent tickets always start, even over coordinator.openPrCap,
# like process fixes, repairs and quick work (coordinator.capExemptPriorities, default
# ["P0"]). The live #13818, a P0 sized project, waited all night behind the cap while
# quick tickets started past it. The host cap, the tooling cap, release scope and the
# machine's room still apply. These cases run the real tick on the real size rules:
# only GitHub and the spawner are stubbed.
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

# The housekeeping, the judge and the disk guard are other suites' cases: here each is a no-op.
for s in reconcile sweep wtsweep claude notify; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$s"; chmod +x "$BIN/$s"; done
printf '#!/usr/bin/env bash\necho "[]"\n' > "$BIN/fixlock"; chmod +x "$BIN/fixlock"
cat > "$BIN/diskguard" <<'SH'
#!/usr/bin/env bash
case "$1" in tick) printf '500\tdisk: 500 GB free\n' ;; limits) echo "30 50" ;; free) echo 500 ;; esac
SH
chmod +x "$BIN/diskguard"
printf '%s\n' 'live_view_watchdog() { :; }' > "$FIX/watchdog-stub.sh"
export COORDINATOR_DISK_GUARD="$BIN/diskguard" COORDINATOR_LIVE_VIEW_WATCHDOG="$FIX/watchdog-stub.sh"
export COORDINATOR_FIX_LOCK="$BIN/fixlock" COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep"
export COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep" COORDINATOR_CLAUDE="$BIN/claude" COORDINATOR_NOTIFY_CMD="$BIN/notify"
export COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
unset COORDINATOR_SHADOW COORDINATOR_CAP COORDINATOR_HEALING_SHARE COORDINATOR_HEAL_ALL_AT COORDINATOR_START_CPU_IDLE COORDINATOR_MIN_FREE_MEM_GB
unset COORDINATOR_OPEN_PR_CAP COORDINATOR_OPEN_PR_CAP_QUICK COORDINATOR_RELEASE_SCOPE_ONLY COORDINATOR_CAP_EXEMPT_PRIORITIES COORDINATOR_TOOLING_CAP
export SWARM_FREE_MEM_GB=16 TEST_PID=$$
# The spawner records the class and whether the run was started over the cap.
cat > "$BIN/spawn-live" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "${CLAIM_CLASS:-}" "${DRIVER_CAP_BYPASS:-}" >> "$SPAWNS"
printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s}\n' "$1" "$1" "$TEST_PID" > "$STATE/runs/claim-$1-live.json"
SH
chmod +x "$BIN/spawn-live"

# A project whose screens are named, on the baseline route, with one screen on its trunk.
jq '.design = {"surfacePaths": ["src/screens/*"], "baselineRoute": {"enabled": true}}' "$HARNESS_CFG_PATH" > "$FIX/h-base.json"
export HARNESS_CFG_PATH="$FIX/h-base.json"
mkdir -p "$REPO/src/screens" "$REPO/config"
printf 'export const Home = () => "Hi"\n' > "$REPO/src/screens/home.tsx"
printf '{ "lint": "loose" }\n' > "$REPO/config/app.json"
git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm "trunk" && git -C "$REPO" branch -qM develop

SCHEMA='Add a `saved_searches` table to the database schema, with a migration, so a recruiter can save a search.'
CONFIG_BODY='In `config/app.json`, change `lint` from "loose" to "strict".'
ticket() { # <n> <labels-csv> <body>
  jq -n --argjson n "$1" --arg l "$2" --arg b "$3" \
    '{number:$n, state:"OPEN", title:"Ticket \($n)", body:$b, labels:($l|split(",")|map(select(length>0)|{name:.}))}' > "$FIX/gh/issue-$1.json"
  bash "$Q" add "$1" >/dev/null
}
open_prs() {
  jq -n --argjson n "$1" '[range(0; $n) | {number: (9000 + .), headRefName: "tkt-\(9000 + .)-open", headRefOid: "h\(.)",
    isDraft: false, mergeStateStatus: "CLEAN", labels: [], statusCheckRollup: []}]' > "$FIX/gh/prs-all.json"
}
fresh() {
  rm -rf "$C" "$STATE/runs"/* "$STATE/swarm/HOLD" "$STATE/size-cache"
  : > "$SPAWNS"; : > "$FIX/claims.txt"; printf '[]\n' > "$FIX/gh/prs-all.json"; rm -f "$STATE/swarm/prs.json"
}
tick() { SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 SWARM_IDLE=90 SWARM_CORES=10 COORDINATOR_CAP="${HOST_CAP:-6}" bash "$T" 2>&1; }
spawned() { cut -f1 "$SPAWNS" | tr '\n' ' ' | sed 's/ $//'; }
bypassed() { awk -F'\t' '$3 == 1 { print $1 }' "$SPAWNS" | tr '\n' ' ' | sed 's/ $//'; }

echo "--- over the cap: a P0 sized project starts; a P1 sized project waits and is named ---"
fresh; open_prs 12; ticket 801 "status:ready,P0" "$SCHEMA"; ticket 802 "status:ready,P1" "$SCHEMA"
out=$(tick)
want "the P0 starts, the P1 does not"              "801" "$(spawned)"
want "not as a quick start the driver would stop"  "" "$(bypassed)"
want_in "the tick says the P0 went past the cap"   'cap: over \(12/10\) — P0 #801 starts anyway' "$out"
want_in "the P1 keeps its skip line"               'skip #802 \(new\): over the open-work cap \(12/10\) and sized project' "$out"
want_not_in "the P0 has no skip line"              'skip #801' "$out"

echo "--- over the cap: a P0 ranks with healing by priority; quick work comes after ---"
fresh; open_prs 12; fix_issue 803 OPEN "status:in-review,P1"; bash "$Q" add 803 --class repair >/dev/null
ticket 804 "status:ready,P2" "$CONFIG_BODY"; ticket 805 "status:ready,P0" "$SCHEMA"
out=$(tick)
want "the P0 first, then the P1 repair, then the quick one" "805 803 804" "$(spawned)"
want "only the quick one is a quick start"                  "804" "$(bypassed)"

echo "--- the host cap still limits P0 starts ---"
fresh; open_prs 12; ticket 806 "status:ready,P0" "$SCHEMA"; ticket 807 "status:ready,P0" "$SCHEMA"
out=$(HOST_CAP=1 tick)
want "one place, one P0"                           "806" "$(spawned)"
fresh; open_prs 12; ticket 808 "status:ready,P0" "$SCHEMA"
printf '{"run_id":"claim-1-live","ticket":"1","child_pid":%s}\n' "$TEST_PID" > "$STATE/runs/claim-1-live.json"
out=$(HOST_CAP=1 tick)
want "a full host starts no P0"                    "" "$(spawned)"

echo "--- the tooling cap and release scope still hold a P0 ---"
fresh; open_prs 12; ticket 809 "status:ready,P0,project:harness-kit" "$SCHEMA"
out=$(COORDINATOR_TOOLING_CAP=0 tick)
want "a tooling P0 waits on the tooling cap"       "" "$(spawned)"
want_in "named as the tooling cap's"               'skip #809 \(new\): the tooling cap' "$out"
fresh; open_prs 12; ticket 810 "status:ready,P0,after-launch" "$SCHEMA"
out=$(COORDINATOR_RELEASE_SCOPE_ONLY='{"priorities":["P0"],"excludeLabels":["after-launch"]}' tick)
want "a P0 outside the release scope waits"        "" "$(spawned)"

echo "--- capExemptPriorities: [] turns it off; P1 can be added ---"
fresh; open_prs 12; ticket 811 "status:ready,P0" "$SCHEMA"
out=$(COORDINATOR_CAP_EXEMPT_PRIORITIES="" tick)
want "with no exempt priority the P0 waits"        "" "$(spawned)"
fresh; open_prs 12; ticket 812 "status:ready,P1" "$SCHEMA"
out=$(COORDINATOR_CAP_EXEMPT_PRIORITIES="P0,P1" tick)
want "with P1 exempt the P1 starts"                "812" "$(spawned)"
want_in "said with its own priority"               'cap: over \(12/10\) — P1 #812 starts anyway' "$out"

echo "--- under the cap nothing changes ---"
fresh; open_prs 3; ticket 813 "status:ready,P0" "$SCHEMA"
out=$(tick)
want "under the cap the P0 starts as before"       "813" "$(spawned)"
want_not_in "and no over-the-cap line"             'starts anyway' "$out"

suite_end "$FAILED"
