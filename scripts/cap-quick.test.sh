#!/usr/bin/env bash
# cap-quick.test.sh — over the open-work cap, the quick tickets start anyway.
#
# The owner, 2026-10-22: quick-sized new tickets bypass coordinator.openPrCap; bigger new
# tickets still wait. On the Mac at 05:10Z the tick said "open changes 22 / cap 10:
# finishing before starting" and "spawn: 2 slot(s), nothing spawnable in the queue" while
# 234 new tickets waited behind the cap. These cases run the real tick on the real size
# rules (driver/size-rules.sh): only GitHub and the spawner are stubbed.
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
unset COORDINATOR_OPEN_PR_CAP COORDINATOR_OPEN_PR_CAP_QUICK COORDINATOR_RELEASE_SCOPE_ONLY
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

CONFIG_BODY='In `config/app.json`, change `lint` from "loose" to "strict".'
WORDING='In src/screens/home.tsx change the heading "Hi" to "Hello".'
FEATURE='Recruiters want to save a search and be told when new candidates match it.'
ticket() { # <n> <labels-csv> <body>
  jq -n --argjson n "$1" --arg l "$2" --arg b "$3" \
    '{number:$n, state:"OPEN", title:"Ticket \($n)", body:$b, labels:($l|split(",")|map(select(length>0)|{name:.}))}' > "$FIX/gh/issue-$1.json"
  bash "$Q" add "$1" >/dev/null
}
repairs() { local t; for t in "$@"; do fix_issue "$t" OPEN "status:in-review"; bash "$Q" add "$t" --class repair >/dev/null; done; }
open_prs() {
  jq -n --argjson n "$1" '[range(0; $n) | {number: (9000 + .), headRefName: "tkt-\(9000 + .)-open", headRefOid: "h\(.)",
    isDraft: false, mergeStateStatus: "CLEAN", labels: [], statusCheckRollup: []}]' > "$FIX/gh/prs-all.json"
}
fresh() {
  rm -rf "$C" "$STATE/runs"/* "$STATE/swarm/HOLD" "$STATE/size-cache"
  : > "$SPAWNS"; : > "$FIX/claims.txt"; printf '[]\n' > "$FIX/gh/prs-all.json"; rm -f "$STATE/swarm/prs.json"
}
tick() { SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 SWARM_IDLE=90 COORDINATOR_CAP=6 bash "$T" 2>&1; }
spawned() { cut -f1 "$SPAWNS" | tr '\n' ' ' | sed 's/ $//'; }
bypassed() { awk -F'\t' '$3 == 1 { print $1 }' "$SPAWNS" | tr '\n' ' ' | sed 's/ $//'; }

echo "--- over the cap: a quick config ticket starts, a full-size feature does not ---"
fresh; open_prs 12; repairs 601 602; ticket 701 "status:ready" "$CONFIG_BODY"; ticket 702 "status:ready" "$FEATURE"
out=$(tick)
want "the repairs first, then the quick one; the feature waits" "601 602 701" "$(spawned)"
want "only the quick one is started as over the cap"            "701" "$(bypassed)"
want_in "the cap still says so"           'open changes 12 / cap 10: finishing before starting' "$out"
want_in "the tick says what it let through" 'cap: over \(12/10\) — 1 quick ticket\(s\) started anyway' "$out"
want_in "and what still waits"            'cap: 1 new ticket\(s\) wait' "$out"
want "the size is cached on the ticket"   quick "$(cut -f4 "$STATE/size-cache/701" 2>/dev/null)"

echo "--- over the cap: a small existing-screen wording ticket sizes quick and starts ---"
fresh; open_prs 22; ticket 703 "status:ready" "$WORDING"
out=$(tick)
want "the wording ticket starts"          "703" "$(spawned)"
want "as a quick start over the cap"      "703" "$(bypassed)"
want_in "said as 22/10"                   'cap: over \(22/10\) — 1 quick ticket\(s\) started anyway' "$out"

echo "--- over the cap: a screen:redesign ticket never does ---"
fresh; open_prs 22; ticket 704 "status:ready,screen:redesign" "$WORDING"; ticket 705 "status:ready,screen:new" "$WORDING"
out=$(tick)
want "neither starts"                     "" "$(spawned)"
want_not_in "and nothing is said as let through" 'started anyway' "$out"

echo "--- a slip: a body a run sized bigger after it started waits behind the cap ---"
fresh; open_prs 22; ticket 706 "status:ready" "$CONFIG_BODY"
mkdir -p "$STATE/size-cache"; printf '%s\tsized bigger\n' "$(printf '%s' "$CONFIG_BODY" | git hash-object --stdin)" > "$STATE/size-cache/706.slip"
out=$(tick)
want "the slipped ticket does not start over the cap" "" "$(spawned)"
fresh; open_prs 22; ticket 706 "status:ready" "$CONFIG_BODY Keep the comment above it."
mkdir -p "$STATE/size-cache"; printf '%s\tsized bigger\n' "$(printf '%s' "$CONFIG_BODY" | git hash-object --stdin)" > "$STATE/size-cache/706.slip"
tick >/dev/null
want "once its body changes it is sized again" "706" "$(spawned)"

echo "--- quick starts fill only the free places, after healing ---"
fresh; open_prs 22; repairs 601 602 603 604 605; ticket 707 "status:ready" "$CONFIG_BODY"; ticket 708 "status:ready" "$CONFIG_BODY"
tick >/dev/null
want "five repairs and one quick start fill the six places" "601 602 603 604 605 707" "$(spawned)"

echo "--- release scope still applies first ---"
fresh; open_prs 22; ticket 709 "status:ready,P2" "$CONFIG_BODY"; ticket 710 "status:ready,P0" "$CONFIG_BODY"
COORDINATOR_RELEASE_SCOPE_ONLY='{"priorities":["P0"]}' tick >/dev/null
want "a quick ticket outside the release scope stays held; one inside starts" "710" "$(spawned)"

echo "--- under the cap nothing changes; and the bypass can be turned off ---"
fresh; open_prs 3; ticket 711 "status:ready" "$FEATURE"
tick >/dev/null
want "under the cap a feature starts as before" "711" "$(spawned)"
want "not as an over-the-cap start"             "" "$(bypassed)"
fresh; open_prs 22; ticket 712 "status:ready" "$CONFIG_BODY"
COORDINATOR_OPEN_PR_CAP_QUICK=off tick >/dev/null
want "coordinator.openPrCapQuick off: nothing new over the cap" "" "$(spawned)"

suite_end "$FAILED"
