#!/usr/bin/env bash
# coordinator-release-scope.test.sh — coordinator.releaseScopeOnly: with it on, new
# work outside the release scope is never seeded, never started and never on the
# sheet's order; repairs and process fixes always run. With it off, nothing changes.
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
QF="$C/queue.json"
unset COORDINATOR_RELEASE_SCOPE_ONLY

# The tick's housekeeping and outside calls, each a stand-in that does nothing.
for s in reconcile sweep wtsweep claude notify fixlock diskguard; do printf '#!/usr/bin/env bash\n' > "$BIN/$s"; done
printf 'cat "$FIX/fixing.json"\n' >> "$BIN/fixlock"
printf 'case "$1" in tick) printf "500\\tdisk: 500 GB free\\n" ;; limits) echo "30 50" ;; free) echo 500 ;; esac\n' >> "$BIN/diskguard"
cat > "$BIN/polish" <<'SH'
#!/usr/bin/env bash
case "$1" in sweep) ;; *) exec bash "$REAL_POLISH" "$@" ;; esac
SH
chmod +x "$BIN"/reconcile "$BIN"/sweep "$BIN"/wtsweep "$BIN"/claude "$BIN"/notify "$BIN"/fixlock "$BIN"/diskguard "$BIN"/polish
export REAL_POLISH="$HERE/polish-list.sh" COORDINATOR_POLISH_LIST="$BIN/polish" COORDINATOR_FIX_LOCK="$BIN/fixlock"
export COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep" COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep"
export COORDINATOR_CLAUDE="$BIN/claude" COORDINATOR_NOTIFY_CMD="$BIN/notify" COORDINATOR_DISK_GUARD="$BIN/diskguard"
export COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
unset COORDINATOR_SHADOW COORDINATOR_CAP COORDINATOR_HEALING_SHARE COORDINATOR_HEAL_ALL_AT COORDINATOR_MIN_FREE_MEM_GB
export SWARM_FREE_MEM_GB=16 SWARM_IDLE=90 SWARM_CORES=10 TEST_PID=$$
printf '%s\n' 'live_view_watchdog() { :; }' > "$FIX/watchdog-stub.sh"
export COORDINATOR_LIVE_VIEW_WATCHDOG="$FIX/watchdog-stub.sh"
cat > "$BIN/spawn-live" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "${CLAIM_CLASS:-}" >> "$SPAWNS"
printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s}\n' "$1" "$1" "$TEST_PID" > "$STATE/runs/claim-$1-live.json"
SH
chmod +x "$BIN/spawn-live"

fresh() {
  rm -rf "$C" "$STATE/runs"/* "$STATE/swarm/HOLD"
  : > "$SPAWNS"; : > "$FIX/claims.txt"
  printf '[]\n' > "$FIX/gh/prs-all.json"; printf '[]\n' > "$FIX/fixing.json"; rm -f "$STATE/swarm/prs.json"
  fix_pr_for 804   # the repair's open PR
}
# issue <n> <labels> [milestone] — a ticket the stand-in GitHub answers for.
issue() {
  fix_issue "$1" OPEN "$2"
  if [ -n "${3:-}" ]; then
    jq --arg m "$3" '.milestone = {title: $m}' "$FIX/gh/issue-$1.json" > "$FIX/gh/issue-$1.tmp" \
      && mv "$FIX/gh/issue-$1.tmp" "$FIX/gh/issue-$1.json"
  fi
}
spawned() { cut -f1 "$SPAWNS" | sort -n | tr '\n' ' ' | sed 's/ $//'; }
ticks() { local i out=""; for i in 1 2 3; do out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 COORDINATOR_CAP=10 bash "$T" 2>&1); done; printf '%s' "$out"; }

# The cases, one ticket each:
#   801 P2 new                     outside: priority
#   802 P1 new, Post-launch        outside: an excluded milestone beats the priority
#   803 P1 new                     inside
#   804 P3 repair                  a repair is never held
#   805 P2 new, process            a process fix is never held
#   806 P3 new, screen:fix         inside: screen work at any priority
#   807 P1 new, after-launch       outside: an excluded label beats the priority
cat > "$BIN/claimable" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' \
  "801	P2	A	-	-	two	P2,status:ready,project:rel	-" \
  "802	P1	A	-	-	later	P1,status:ready,project:rel	Post-launch" \
  "803	P1	A	-	-	now	P1,status:ready,project:rel	-" \
  "804	P3	A	-	[FINISH PR]	red	P3,status:in-review,project:rel	-" \
  "805	P2	A	-	-	process	P2,status:ready,process,project:rel	-" \
  "806	P3	A	-	-	screen	P3,status:ready,screen:fix,project:rel	-" \
  "807	P1	A	-	-	after	P1,status:ready,after-launch,project:rel	-" \
  | sed 's/	-	-	/			/; s/	-	\[/		[/'
STUB
chmod +x "$BIN/claimable"; export COORDINATOR_CLAIMABLE="$BIN/claimable"
printf '[{"name":"project:rel"}]\n' > "$FIX/gh/labels.json"
issue 801 "P2,status:ready,project:rel"
issue 802 "P1,status:ready,project:rel" "Post-launch"
issue 803 "P1,status:ready,project:rel"
issue 804 "P3,status:in-review,project:rel"
issue 805 "P2,status:ready,process,project:rel"
issue 806 "P3,status:ready,screen:fix,project:rel"
issue 807 "P1,status:ready,after-launch,project:rel"
seeded() { jq -r '[.tickets[].n] | sort | map(tostring) | join(" ")' "$QF"; }

echo "--- off: today's behaviour — every candidate is seeded and starts ---"
fresh
bash "$Q" seed rel >/dev/null
want "every candidate seeded"              "801 802 803 804 805 806 807" "$(seeded)"
out=$(ticks)
want "every one starts"                    "801 802 803 804 805 806 807" "$(spawned)"
want_not_in "and no scope line"            'scope: release only' "$out"

echo "--- on: a new ticket outside the release scope is never seeded ---"
export COORDINATOR_RELEASE_SCOPE_ONLY=true
fresh
bash "$Q" seed rel >/dev/null
want "P2 new, P1 in an excluded milestone and P1 after-launch are not seeded" "803 804 805 806" "$(seeded)"
want "the seed keeps the count it held back" "3" "$(jq -r '.release_held' "$QF")"
out=$(ticks)
want "a P1 ready, a P3 repair, a process P2 and a P3 screen:fix start" "803 804 805 806" "$(spawned)"
want_in "the tick says what it held back"  'scope: release only — 3 new outside scope held back' "$out"

echo "--- on: the tick is the backstop — a pinned entry outside scope never starts ---"
fresh
for n in 801 802 807; do bash "$Q" add "$n" >/dev/null; done
bash "$Q" add 803 >/dev/null
bash "$Q" add 805 >/dev/null
bash "$Q" add 806 >/dev/null
bash "$Q" add 804 --class repair >/dev/null
out=$(ticks)
want "P2 new and P1 in the milestone do not start; the rest do" "803 804 805 806" "$(spawned)"
want_in "and the tick counts them"         'scope: release only — 3 new outside scope held back' "$out"

echo "--- on, as an object: its keys replace the defaults, the rest stay ---"
export COORDINATOR_RELEASE_SCOPE_ONLY='{"on":true,"priorities":["P0","P1","P2"],"excludeMilestones":["^Post-launch$"]}'
fresh
bash "$Q" seed rel >/dev/null
want "P2 now in; the milestone and after-launch still out" "801 803 804 805 806" "$(seeded)"
export COORDINATOR_RELEASE_SCOPE_ONLY='{"on":false}'
fresh
bash "$Q" seed rel >/dev/null
want "on:false is off"                     "801 802 803 804 805 806 807" "$(seeded)"

echo "--- the seed's candidates carry each ticket's milestone (claimable-issues.sh, 8th column) ---"
fix_issue_list "status:ready" '[{"number":802,"title":"later","labels":[{"name":"P1"},{"name":"status:ready"}],"milestone":{"title":"Post-launch"}},
                                {"number":803,"title":"now","labels":[{"name":"P1"},{"name":"status:ready"}],"milestone":null}]'
fix_issue_list "status:in-review" '[]'
rows=$(CLAIMABLE_WITH_LABELS=1 bash "$HERE/claimable-issues.sh" 2>/dev/null)
want "a milestone is the 8th column"       "802:Post-launch" "$(awk -F'\t' '$1 == 802 { print $1 ":" $8 }' <<<"$rows")"
want "none reads as -"                     "803:-" "$(awk -F'\t' '$1 == 803 { print $1 ":" $8 }' <<<"$rows")"
want "without the flag the rows are as before" "6" "$(CLAIMABLE_WITH_LABELS=0 bash "$HERE/claimable-issues.sh" 2>/dev/null | awk -F'\t' '{ print NF; exit }')"

echo "--- on: the sheet's order carries the same filter ---"
export COORDINATOR_RELEASE_SCOPE_ONLY=true
order=$(
  . "$HERE/coordinator-env.sh" >/dev/null 2>&1
  . "$HERE/coordinator-sheet.sh" >/dev/null 2>&1
  . "$HERE/gh-batch.sh" >/dev/null 2>&1
  iss=$(gh_issues_batch 801 802 803 804 805 806 807 2>/dev/null)
  wide=$(printf '%s\n' "801	new	2" "802	new	1" "803	new	1" "804	repair	3" "805	new	2" "806	new	3" "807	new	1")
  coord_sheet_entries "$wide" "$iss" "" "" | jq -r '[.order[].n] | sort | map(tostring) | join(" ")')
want "the sheet lists only what may start" "803 804 805 806" "$order"
unset COORDINATOR_RELEASE_SCOPE_ONLY

# alsoIn.titlePatterns: card work carries no screen label and no title prefix, so only a
# title regex can bring it in. 808 is card work; 809 only contains the letters.
#   808 P3 new  "polish(pulse): Templates card shows its count"  in only with the pattern
#   809 P3 new  "Cardinal sort order"                             out: \b is a word edge
cat > "$BIN/claimable" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' \
  "808	P3	A			polish(pulse): Templates CARD shows its count	P3,status:ready,project:rel	-" \
  "809	P3	A			Cardinal sort order	P3,status:ready,project:rel	-"
STUB
chmod +x "$BIN/claimable"
titled() { issue "$1" "$2"; jq --arg t "$3" '.title = $t' "$FIX/gh/issue-$1.json" > "$FIX/gh/issue-$1.tmp" && mv "$FIX/gh/issue-$1.tmp" "$FIX/gh/issue-$1.json"; }
titled 808 "P3,status:ready,project:rel" "polish(pulse): Templates CARD shows its count"
titled 809 "P3,status:ready,project:rel" "Cardinal sort order"
queued() { jq -r '[.tickets[].n] | sort | map(tostring) | join(" ")' "$QF"; }
sheet_order() (
  . "$HERE/coordinator-env.sh" >/dev/null 2>&1
  . "$HERE/coordinator-sheet.sh" >/dev/null 2>&1
  . "$HERE/gh-batch.sh" >/dev/null 2>&1
  iss=$(gh_issues_batch 808 809 2>/dev/null)
  coord_sheet_entries "$(printf '%s\n' "808	new	3" "809	new	3")" "$iss" "" "" | jq -r '[.order[].n] | sort | map(tostring) | join(" ")')

echo "--- on, no titlePatterns: a P3 card ticket with no screen label is held, and stays queued ---"
export COORDINATOR_RELEASE_SCOPE_ONLY=true
fresh
bash "$Q" seed rel >/dev/null
want "neither is seeded"                   "" "$(seeded)"
fresh
bash "$Q" add 808 >/dev/null; bash "$Q" add 809 >/dev/null
out=$(ticks)
want "a pinned card ticket does not start" "" "$(spawned)"
want_in "the tick counts both as held"     'scope: release only — 2 new outside scope held back' "$out"
want "a held entry stays in the queue"     "808 809" "$(queued)"
COORDINATOR_REFRESH=1 SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 COORDINATOR_CAP=10 bash "$T" >/dev/null 2>&1
want "and through a refresh too"           "808 809" "$(queued)"
want "the sheet leaves both off"           "" "$(sheet_order)"

echo "--- on, titlePatterns [\\bcard\\b]: the card ticket is in at seed, tick and sheet; the near miss is not ---"
export COORDINATOR_RELEASE_SCOPE_ONLY='{"alsoIn":{"titlePatterns":["\\bcard\\b","(?i)never-matches","("]}}'
fresh
bash "$Q" seed rel >/dev/null
want "the seed takes the card ticket, case-insensitively" "808" "$(seeded)"
want "a pattern that does not compile is dropped, not fatal" '["\\bcard\\b","(?i)never-matches"]' \
  "$( . "$HERE/coordinator-env.sh" >/dev/null 2>&1; jq -c '.alsoIn.titlePatterns' <<<"$COORD_RELEASE_SCOPE")"
want "the default alsoIn keys stay"        '["Batch:","Polish list:"]' \
  "$( . "$HERE/coordinator-env.sh" >/dev/null 2>&1; jq -c '.alsoIn.titlePrefixes' <<<"$COORD_RELEASE_SCOPE")"
fresh
bash "$Q" add 808 >/dev/null; bash "$Q" add 809 >/dev/null
out=$(ticks)
want "the tick starts the card ticket only" "808" "$(spawned)"
want_in "and holds the near miss"          'scope: release only — 1 new outside scope held back' "$out"
want "the held one is still queued"        "809" "$(queued)"
want "the sheet lists the card ticket"     "808" "$(sheet_order)"
unset COORDINATOR_RELEASE_SCOPE_ONLY

suite_end "$FAILED"
