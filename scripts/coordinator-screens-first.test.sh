#!/usr/bin/env bash
# coordinator-screens-first.test.sh — coordinator.screensFirst, and a queue that names
# every ticket it passes over.
#
# Owner call 2026-10-23: until the release every screen reaches its final form first.
# With the setting on, the order is process fixes, then every P0 (owner, 2026-10-30:
# urgent first), then focus-area and screen work at P1, then the rest by priority.
#
# A live P0 data-model ticket (#13818 below) sat in the queue from 22 Oct 20:17Z
# and never started, and tick.log never named it: over the open-work cap only quick work
# starts and it was sized project ("a schema ticket is never quick"), counted in
# "cap: N new ticket(s) wait"; under the cap it sat behind the free places, cut without
# a word. These cases run the real tick on the real size rules; GitHub and the spawner
# are stubbed.
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
unset COORDINATOR_OPEN_PR_CAP COORDINATOR_OPEN_PR_CAP_QUICK COORDINATOR_RELEASE_SCOPE_ONLY COORDINATOR_SCREENS_FIRST COORDINATOR_CAP_EXEMPT_PRIORITIES
export SWARM_FREE_MEM_GB=16 TEST_PID=$$
cat > "$BIN/spawn-live" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "${CLAIM_CLASS:-}" >> "$SPAWNS"
printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s}\n' "$1" "$1" "$TEST_PID" > "$STATE/runs/claim-$1-live.json"
SH
chmod +x "$BIN/spawn-live"

SCHEMA='Person-facts data model: change the Prisma schema so a colleague is keyed by member id, with a migration.'
WORDING='In src/screens/home.tsx change the heading "Hi" to "Hello".'
ticket() { # <n> <labels-csv> <title> [body] [add flags…]
  local n="$1" l="$2" ti="$3" b="${4:-$WORDING}"; shift 4 2>/dev/null || shift $#
  jq -n --argjson n "$n" --arg l "$l" --arg t "$ti" --arg b "$b" \
    '{number:$n, state:"OPEN", title:$t, body:$b, labels:($l|split(",")|map(select(length>0)|{name:.}))}' > "$FIX/gh/issue-$n.json"
  bash "$Q" add "$n" "$@" >/dev/null
}
open_prs() {
  jq -n --argjson n "$1" '[range(0; $n) | {number: (9000 + .), headRefName: "tkt-\(9000 + .)-open", headRefOid: "h\(.)",
    isDraft: false, mergeStateStatus: "CLEAN", labels: [], statusCheckRollup: []}]' > "$FIX/gh/prs-all.json"
}
fresh() {
  rm -rf "$C" "$STATE/runs"/* "$STATE/swarm/HOLD" "$STATE/size-cache"
  : > "$SPAWNS"; : > "$FIX/claims.txt"; printf '[]\n' > "$FIX/gh/prs-all.json"; rm -f "$STATE/swarm/prs.json"
}
tick() { SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 SWARM_IDLE=90 SWARM_CORES=10 COORDINATOR_CAP="${CAP:-6}" bash "$T" 2>&1; }
spawned() { cut -f1 "$SPAWNS" | tr '\n' ' ' | sed 's/ $//'; }
order() { bash "$Q" list | awk '/^ *[0-9]+\. #/ { sub(/^#/, "", $2); printf "%s ", $2 }' | sed 's/ $//'; }
pics() { mkdir -p "$C"; jq -nc '{at: "x", tickets: $ARGS.positional | map(tonumber)}' --args "$@" > "$C/screen-pictures.json"; }

# The queue, one ticket each:
#   901 P1 new, not screen work                       last with the setting on
#   902 P2 new, screen:feed                           normal-priority screen work
#   903 P0 new, not screen work                       ahead of every screen ticket
#   904 P3 "Polish list: Feed"                        screen work at polish priority
#   905 P2 new, an approved picture on the ticket     screen work by its picture
#   906 P1 new, "the Templates card shows its count"  screen work by its title
#   907 P2 process fix                                first of all, as now
seed_queue() {
  fresh; pics 905
  ticket 901 "status:ready,P1"                 "fix(api): the import retries twice"
  ticket 902 "status:ready,P2,screen:feed"     "Feed: the empty state names the next step"
  ticket 903 "status:ready,P0"                 "Person-facts data model: keyed by member"
  ticket 904 "status:ready,P3"                 "Polish list: Feed"
  ticket 905 "status:ready,P2"                 "Calendar month grid to the approved picture"
  ticket 906 "status:ready,P1"                 "The Templates card shows its count"
  ticket 907 "status:ready,P2,process"         "fix(gates): the lesson check reads the PR body"
}

echo "--- off: the order is priority, as before ---"
seed_queue
want "process, then P0, P1s, P2s, P3" "907 903 901 906 902 905 904" "$(order)"

echo "--- on: process, the non-screen P0, every screen ticket by priority, then the rest ---"
export COORDINATOR_SCREENS_FIRST=true
seed_queue
got=$(order)
want "the screens-first order: the P0 first, then screens" "907 903 906 901 902 905 904" "$got"
pos() { printf '%s\n' $got | grep -nx "$1" | cut -d: -f1; }
# Owner, 2026-10-30: urgent first, then focus areas and screens within each priority
# (10 P0s sat at 36-45 behind focus-area and pinned P1/P2 work).
want "a P0 non-screen ticket ranks above a P1 screen one" "yes" "$([ "$(pos 903)" -lt "$(pos 906)" ] && echo yes)"
want "a process fix stays above both"                     "yes" "$([ "$(pos 907)" -lt "$(pos 906)" ] && echo yes)"
want "a P2 screen ticket ranks among the rest by priority: after the P1, before the P3" "yes" \
  "$([ "$(pos 902)" -gt "$(pos 901)" ] && [ "$(pos 902)" -lt "$(pos 904)" ] && echo yes)"

fresh
ticket 931 "status:ready,P0"                 "fix(api): the publish double-posts"
ticket 932 "status:ready,P1,screen:voices"   "Voices: the setup interview, part 1"
ticket 933 "status:ready,P0,process"         "develop is red: scripts/check-schema-design"
want "develop-red (a P0 process fix) above a P0 non-screen one above a P1 screen ticket" "933 931 932" "$(order)"

echo "--- on: an entry the PM put on top stays inside its tier ---"
seed_queue; bash "$Q" add 901 --front >/dev/null
want "a non-screen P1 put on top leads its tier, below the P0 and the P1 screens" "907 903 906 901 902 905 904" "$(order)"
bash "$Q" add 905 --front >/dev/null
want "a P2 screen ticket put on top leads that tier too, still below the P0 and the P1 screens" "907 903 906 905 901 902 904" "$(order)"

echo "--- on: the tick works the same order, and says so ---"
seed_queue
out=$(CAP=3 tick)
want "three places: the process fix, the P0, the P1 screen ticket" "907 903 906" "$(spawned)"
want_in "one line on the order, with every tier counted" \
  'order: screens first — tiers: process 1 · focus areas P0/P1 0 · screens P0/P1 1 · rest by priority 5 · last in the release 0' "$out"

echo "--- on: screenMatch replaces the defaults ---"
export COORDINATOR_SCREENS_FIRST='{"on":true,"screenMatch":{"labels":["surface:*"],"titlePatterns":[],"pictures":false}}'
seed_queue
want "only surface:* and the Polish list: prefix count now (a P3 list, at its priority)" "907 903 901 906 902 905 904" "$(order)"
unset COORDINATOR_SCREENS_FIRST

echo "--- on: release:last builds after the rest of the release; a P0 never goes last ---"
# Owner, 2026-10-23: release:last tickets stay in the release (P1) but build last.
#   921 P1 screen:pulse, release:last   after the normal non-screen ticket
#   922 P2 not screen work              the rest of the release
#   923 P0 release:last (mislabelled)   stays in the P0 tier
#   924 P1 screen:feed                  screen work
export COORDINATOR_SCREENS_FIRST=true
fresh
ticket 921 "status:ready,P1,screen:pulse,release:last" "Pulse: the archive view"
ticket 922 "status:ready,P2"                           "fix(api): the export names the file"
ticket 923 "status:ready,P0,release:last"              "fix(api): the publish double-posts"
ticket 924 "status:ready,P1,screen:feed"               "Feed: the header"
want "the P0, P1 screen work, the rest, then release:last" "923 924 922 921" "$(order)"
for t in 921 922 923 924; do COORDINATOR_LAST_IN_RELEASE_LABEL=release:later bash "$Q" add "$t" >/dev/null; done
want "with the label set to another name, release:last is plain work" "923 921 924 922" "$(order)"
fresh; for t in 921 922 923 924; do bash "$Q" add "$t" >/dev/null; done
out=$(CAP=1 tick)
want_in "the order line counts the last tier" 'tiers: process 0 · focus areas P0/P1 0 · screens P0/P1 1 · rest by priority 2 · last in the release 1' "$out"
unset COORDINATOR_SCREENS_FIRST

echo "--- coordinator.focusAreas: P0/P1 work in a focus area ranks above other P0/P1 screen work ---"
# Owner, 2026-10-24: the focus areas, in their order, then other screen work, then the rest.
export COORDINATOR_SCREENS_FIRST=true
export COORDINATOR_FOCUS_AREAS='[{"name":"Voices","labels":["area:VOICES","screen:voices"]},{"name":"One Desk","labels":["project:one-desk","screen:one-desk-*"]}]'
fresh
ticket 941 "status:ready,P0"                    "fix(api): the publish double-posts"
ticket 942 "status:ready,P0,screen:feed"        "Feed: the empty state"
ticket 943 "status:ready,P1,area:VOICES"        "Voices: the interview's API"
ticket 944 "status:ready,P1,screen:one-desk-rail" "One Desk: the rail"
ticket 945 "status:ready,P2,area:VOICES"        "Voices: a later pass"
ticket 946 "status:ready,P1,screen:voices"      "Voices: the setup screen"
ticket 947 "status:ready,P0,process"            "develop is red: the schema check"
ticket 948 "status:ready,P1,screen:feed"        "Feed: the header"
got=$(order)
want "process; the P0s (screen first); Voices (its screen first), One Desk; the rest by priority" "947 942 941 946 943 944 948 945" "$got"
want "a P0 non-focus screen ranks above a P0 non-screen, which ranks above a P1 Voices ticket" "yes" \
  "$([ "$(pos 942)" -lt "$(pos 941)" ] && [ "$(pos 941)" -lt "$(pos 943)" ] && echo yes)"
want "One Desk ranks after Voices"            "yes" "$([ "$(pos 944)" -gt "$(pos 943)" ] && echo yes)"
want "a glob matches screen:one-desk-rail"    "yes" "$([ "$(pos 944)" -lt "$(pos 948)" ] && echo yes)"
want "a P2 Voices ticket is not in the focus tier: it ranks among the rest" "8" "$(pos 945)"
out=$(CAP=1 tick)
want_in "the order line names the focus areas' counts" 'tiers: process 1 · focus areas P0/P1 3 \(Voices 2, One Desk 1\) · screens P0/P1 2 · rest by priority 2' "$out"
fresh; for t in 941 942 943 944 945 946 947 948; do bash "$Q" add "$t" >/dev/null; done
CAP=3 tick >/dev/null
want "the tick starts the process fix, then the P0s, before any focus-area P1" "947 942 941" "$(spawned)"
unset COORDINATOR_FOCUS_AREAS COORDINATOR_SCREENS_FIRST

echo "--- #13818: over the cap, a P0 sized big starts anyway (capExemptPriorities) ---"
export COORDINATOR_RELEASE_SCOPE_ONLY=true
fresh; open_prs 12
ticket 13818 "status:ready,P0,area:AI-INFRA,type:chore,project:person-facts" \
  "Person-facts data model: a colleague is keyed by member, not by name, and uses orgId" "$SCHEMA"
out=$(tick)
want "it starts over the cap" "13818" "$(spawned)"
want_in "and says so" 'cap: over \(12/10\) — P0 #13818 starts anyway' "$out"
echo "--- #13818: with no exempt priority, a P0 sized big is named with why ---"
fresh; open_prs 12
ticket 13818 "status:ready,P0,area:AI-INFRA,type:chore,project:person-facts" \
  "Person-facts data model: a colleague is keyed by member, not by name, and uses orgId" "$SCHEMA"
out=$(COORDINATOR_CAP_EXEMPT_PRIORITIES="" tick)
want "it does not start over the cap" "" "$(spawned)"
want_in "but its skip line says why" '^[0-9:]+ skip #13818 \(new\): over the open-work cap \(12/10\) and sized project — .*(schema|data-model|migration)' "$out"

echo "--- #13818: under the cap, behind the free places, it is named ---"
fresh
for n in 801 802 803; do ticket "$n" "status:ready,P0" "fix(api): one more P0 $n" "$WORDING" --front; done
ticket 13818 "status:ready,P0,area:AI-INFRA,type:chore,project:person-facts" \
  "Person-facts data model: a colleague is keyed by member, not by name, and uses orgId" "$SCHEMA"
out=$(CAP=1 tick)
want "one place: the first entry starts (the last put on top)" "803" "$(spawned)"
want_in "the ones behind are each named" '^[0-9:]+ skip( #[0-9]+)* #13818( #[0-9]+)*: behind the 1 free place' "$out"

echo "--- #13818: with a place, it spawns ---"
fresh
ticket 13818 "status:ready,P0,area:AI-INFRA,type:chore,project:person-facts" \
  "Person-facts data model: a colleague is keyed by member, not by name, and uses orgId" "$SCHEMA"
tick >/dev/null
want "a P0 data-model ticket under the cap starts" "13818" "$(spawned)"

echo "--- every passed-over entry is named: release scope and the tooling cap ---"
fresh
ticket 811 "status:ready,P2" "fix(api): outside the release" "$WORDING"
ticket 812 "status:ready,P1,process" "fix(gates): one" "$WORDING"
printf '%s\there\tbuild\n' 5001 5002 >> "$FIX/claims.txt"
jq -n '{number:5001, state:"OPEN", title:"a", labels:[{name:"process"},{name:"status:in-progress"}]}' > "$FIX/gh/issue-5001.json"
jq -n '{number:5002, state:"OPEN", title:"b", labels:[{name:"process"},{name:"status:in-progress"}]}' > "$FIX/gh/issue-5002.json"
out=$(tick)
want "neither starts" "" "$(spawned)"
want_in "the release-held one is named" '^[0-9:]+ skip #811: outside the release scope' "$out"
want_in "the tooling-capped one is named" '^[0-9:]+ skip #812 \(new\): the tooling cap — 2 live of 2' "$out"
unset COORDINATOR_RELEASE_SCOPE_ONLY

echo "--- the picture markers are the picture code's own ---"
want_in "picture-fetch.sh heads its comment with the first" 'HEAD_LINE="\*\*Picture for any machine\*\*"' "$(cat "$HERE/picture-fetch.sh")"
want_in "critic-judge.sh dates a picture by the second" 'test\("picture approved"; "i"\)' "$(cat "$HERE/critic-judge.sh")"
want "and the coordinator searches for exactly those" "Picture for any machine|Picture approved" \
  "$( . "$HERE/coordinator-env.sh" >/dev/null 2>&1; IFS='|'; printf '%s' "${COORD_PICTURE_MARKERS[*]}")"

suite_end "$FAILED"
