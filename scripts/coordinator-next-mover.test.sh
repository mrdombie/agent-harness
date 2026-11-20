#!/usr/bin/env bash
# coordinator-next-mover.test.sh — a tick whose counted PRs are all green-but-UNSTABLE or
# base-red ends with a mover on each: the merge lane merges the green ones (one a pass),
# and the rebuild pass updates each base-red one from develop once develop is green again.
# Self-proof: the same case on a copy of the kit with the lane's required-only reading,
# or the rebuild's update, deleted must name the PRs left without a mover.
# case-filter: SUITE_ONLY='<a case title, or a pattern over them>' bash scripts/coordinator-next-mover.test.sh
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
for v in RUNS_DIR STATE_DIR DRIVER_DIR CLAIM_RUN_LOG PR_RED_REQ_FILE PR_RED_REQ_CACHE $(env | sed -nE 's/^((SWARM|COORDINATOR|COORD|HARNESS|MERGE_LANE)_[A-Z_]*)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
. "$KIT/swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
C="$STATE/coordinator"
jq '.merge = {method: "squash"} | .release = {mergeFirst: true} | .gates = {requiredChecks: ["build", "lint"]}
    | .coordinator = {openPrCap: 2}' "$HARNESS_CFG_PATH" > "$FIX/h.json" && mv "$FIX/h.json" "$HARNESS_CFG_PATH"

# The forge: the fixture's stub, except a merge closes the PR (it leaves the open list).
mv "$BIN/gh" "$BIN/gh-base"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr merge")
    printf '%s\n' "$*" >> "$GH_LOG"
    case "$*" in *--disable-auto*) exit 0 ;; esac
    jq --argjson n "$3" 'map(select(.number != $n))' "$FIX/gh/prs-all.json" > "$FIX/gh/m.json" && mv "$FIX/gh/m.json" "$FIX/gh/prs-all.json"
    exit 0 ;;
esac
exec "$BIN/gh-base" "$@"
GH
chmod +x "$BIN/gh"

# Every housekeeping step but the lane records its call and does nothing.
cat > "$BIN/noop" <<'SH'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$FIX/house.log"
SH
chmod +x "$BIN/noop"
for s in reconcile sweep wtsweep unblock featureclose polish keepfresh critic closemerged followup notify claude judge developred; do
  ln -sf "$BIN/noop" "$BIN/$s"
done
printf '#!/usr/bin/env bash\ncase "$1" in tick) printf "500\\tdisk: 500 GB free\\n" ;; limits) echo "30 50" ;; free) echo 500 ;; esac\n' > "$BIN/diskguard"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/person-stop"
chmod +x "$BIN/diskguard" "$BIN/person-stop"
printf '%s\n' 'live_view_watchdog() { :; }' > "$FIX/watchdog-stub.sh"
export COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep" COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep"
export COORDINATOR_UNBLOCK="$BIN/unblock" COORDINATOR_MACHINE_PARKS=off COORDINATOR_FEATURE_CLOSE="$BIN/featureclose"
export COORDINATOR_POLISH_LIST="$BIN/polish" COORDINATOR_KEEP_FRESH="$BIN/keepfresh" COORDINATOR_CRITIC_JUDGE="$BIN/critic"
export COORDINATOR_CLOSE_MERGED="$BIN/closemerged" COORDINATOR_FOLLOW_UP="$BIN/followup" COORDINATOR_DEVELOP_RED="$BIN/developred"
export COORDINATOR_CLAUDE="$BIN/claude" COORDINATOR_NOTIFY_CMD="$BIN/notify" COORDINATOR_JUDGE="$BIN/judge"
export COORDINATOR_DISK_GUARD="$BIN/diskguard" COORDINATOR_LIVE_VIEW_WATCHDOG="$FIX/watchdog-stub.sh"
export MERGE_LANE_PERSON_STOP="$BIN/person-stop" COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
export COORDINATOR_SHADOW=0 MERGE_LANE_SHADOW=0 SWARM_FREE_MEM_GB=16
unset COORDINATOR_FIX_ROUNDS COORDINATOR_CAP

# The world: PRs 1-2 green on build and lint but UNSTABLE on a non-required red; PRs 3-4 red
# on build at a head first recorded base-red, and develop's newest run passes build again.
plant_world() {
  rm -rf "$C" "$STATE/runs"/* "$STATE/swarm/HOLD"; mkdir -p "$C"
  : > "$GH_LOG"; : > "$FIX/house.log"; : > "$FIX/claims.txt"; rm -f "$STATE/swarm/prs.json"
  printf '[{"name":"queue:merge"}]\n' > "$FIX/gh/labels.json"
  local n
  for n in 1 2 3 4; do fix_issue "10$n" OPEN "status:in-review"; done
  jq -n '
    def run($n; $c; $r): {__typename: "CheckRun", name: $n, status: "COMPLETED", conclusion: $c,
      completedAt: "2026-11-20T10:00:00Z", detailsUrl: "https://github.com/acme/widgets/actions/runs/\($r)/job/1"};
    def pr($n; $ms; $labels; $checks): {number: $n, title: "the change", headRefName: "tkt-10\($n)/work",
      headRefOid: "s\($n)", baseRefName: "develop", isDraft: false, mergeable: "MERGEABLE",
      mergeStateStatus: $ms, labels: $labels, autoMergeRequest: null, updatedAt: "2026-11-20T10:00:00Z",
      statusCheckRollup: $checks};
    [ pr(1; "UNSTABLE"; [{name: "queue:merge"}]; [run("build"; "SUCCESS"; 71), run("lint"; "SUCCESS"; 71), run("Does this diff need pixels?"; "FAILURE"; 71)]),
      pr(2; "UNSTABLE"; [{name: "queue:merge"}]; [run("build"; "SUCCESS"; 72), run("lint"; "SUCCESS"; 72), run("Does this diff need pixels?"; "FAILURE"; 72)]),
      pr(3; "BLOCKED"; []; [run("build"; "FAILURE"; 73), run("lint"; "SUCCESS"; 73)]),
      pr(4; "BLOCKED"; []; [run("build"; "FAILURE"; 74), run("lint"; "SUCCESS"; 74)]) ]' > "$FIX/gh/prs-all.json"
  fix_required build lint
  for n in 1 2 3 4; do printf '{"behind_by":0}\n' > "$FIX/gh/api-repos_acme_widgets_compare_develop...s$n.json"; done
  for n in 3 4; do printf '{"message":"Updating pull request branch."}\n' > "$FIX/gh/api-repos_acme_widgets_pulls_${n}_update-branch.json"; done
  # Develop was red on build when 3 and 4 waited; its newest run passes build now.
  printf '%s\t%s\t%s\t%s\n' 3 s3 build 1763600000 4 s4 build 1763600000 > "$C/base-red.did.tsv"
  printf '[{"sha":"dev1"}]\n' > "$FIX/gh/api-repos_acme_widgets_commits_sha_develop_per_page_5.json"
  printf '{"check_runs":[{"name":"build","id":1,"status":"completed","conclusion":"success","completed_at":"2026-11-20T09:00:00Z"},{"name":"lint","id":2,"status":"completed","conclusion":"success","completed_at":"2026-11-20T09:00:00Z"}]}\n' \
    > "$FIX/gh/api-repos_acme_widgets_commits_dev1_check-runs_per_page_100_filter_all.json"
}
merges() { grep -c "^pr merge $1 .*--squash" "$GH_LOG"; }
updates() { grep -c "^api repos/acme/widgets/pulls/$1/update-branch -X PUT" "$GH_LOG"; }
# without_mover — the counted PRs this far with neither a merge nor an update, by number.
without_mover() {
  local n out=""
  for n in 1 2 3 4; do [ "$(merges "$n")" -gt 0 ] || [ "$(updates "$n")" -gt 0 ] || out="$out${out:+ }#$n"; done
  printf '%s' "$out"
}
# run_case <kit> — two ticks of that kit's coordinator on the planted world; sets OUT1, OUT2, AFTER1.
run_case() {
  plant_world
  OUT1=$(cd "$REPO" && bash "$1/scripts/coordinator-tick.sh" 2>&1)
  AFTER1=$(without_mover)
  M1=$(( $(merges 1) + $(merges 2) )); U3=$(updates 3); U4=$(updates 4)
  OUT2=$(cd "$REPO" && bash "$1/scripts/coordinator-tick.sh" 2>&1)
}

if suite_case "every counted PR, green-unstable or base-red, gets a merge or an update"; then
run_case "$KIT"
want_in "tick 1 ran to its end"                      'tick: done' "$OUT1"
want "tick 1 merges at least one green-unstable PR"   1 "$([ "$M1" -ge 1 ] && echo 1 || echo "0 (merges: $M1)")"
want "tick 1 updates base-red PR 3 from develop once" 1 "$U3"
want "tick 1 updates base-red PR 4 from develop once" 1 "$U4"
want "PR 1 merged once"                               1 "$(merges 1)"
want "PR 2 merged once, by the second tick"           1 "$(merges 2)"
want "tick 2 sends PR 3 no second update"             1 "$(updates 3)"
want "tick 2 sends PR 4 no second update"             1 "$(updates 4)"
want "no counted PR is left without a mover"          "" "$(without_mover)"
[ "$FAILED" = 0 ] || { echo "$OUT1" | tail -40; echo "--- gh ---"; cat "$GH_LOG" | grep -E 'merge|update-branch'; }
fi

if suite_case "self-proof: deleting the lane's UNSTABLE merge or the rebuild's update leaves PRs without a mover"; then
copy_kit() { rm -rf "$FIX/kit"; mkdir -p "$FIX/kit"; (cd "$KIT" && tar cf - --exclude=.git .) | (cd "$FIX/kit" && tar xf -); }
# (a) the lane reads every check, not only the required ones: a non-required red holds it.
copy_kit
perl -0pi -e 's/\| \$req\[\] as \$r\n/| ([\$req[], (\$c[] | .name \/\/ .context \/\/ empty)] | unique)[] as \$r\n/' "$FIX/kit/scripts/merge-lane.sh"
if cmp -s "$KIT/scripts/merge-lane.sh" "$FIX/kit/scripts/merge-lane.sh"; then bad "plant (a) did not apply"
else
  run_case "$FIX/kit"
  want "plant (a): the guard names the green-unstable PRs" "#1 #2" "$(without_mover)"
fi
# (b) the rebuild never updates a base-red PR once develop is green.
copy_kit
perl -0pi -e 's/  if rebuild_stale_update "\$n" [^\n]*\n/  if false; then\n/' "$FIX/kit/scripts/rebuild.sh"
if cmp -s "$KIT/scripts/rebuild.sh" "$FIX/kit/scripts/rebuild.sh"; then bad "plant (b) did not apply"
else
  run_case "$FIX/kit"
  want "plant (b): the guard names the base-red PRs"   "#3 #4" "$(without_mover)"
fi
fi

suite_end "$FAILED"
