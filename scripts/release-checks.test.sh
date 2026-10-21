#!/usr/bin/env bash
# release-checks.test.sh — until a project's release, a check it lists in
# release.nonBlockingChecks warns and never blocks: no repair is sent for it, it does
# not count a PR red, the driver's repair does not answer it, the critic's findings
# are no step's blockers, and the sign-off batch does not wait on it. release.done
# true, or no key, is exactly as before; a red on a check not listed is red either way.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
CFG="$HARNESS_CFG_PATH"; cp "$CFG" "$FIX/cfg.base"
LISTED='["Lesson / Every fix ships a lesson", "Design critic", "Approved picture", "Widths and contrast on changed routes"]'
cfg_on()   { jq --argjson l "$LISTED" '.release = {nonBlockingChecks: $l, done: false}' "$FIX/cfg.base" > "$CFG"; }
cfg_done() { jq --argjson l "$LISTED" '.release = {nonBlockingChecks: $l, done: true}' "$FIX/cfg.base" > "$CFG"; }
cfg_off()  { cp "$FIX/cfg.base" "$CFG"; }
lib() { HARNESS_CFG="$CFG" bash -c '. "$1"; shift; "$@"' _ "$HERE/release-checks.sh" "$@"; }

# A PR red on <names…> (Lesson and the critic as GitHub returns them), green otherwise.
red_pr() { # <pr> <ticket> <sha> <red…>
  local n=$1 t=$2 sha=$3; shift 3
  local reds; reds=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
  jq -n --argjson n "$n" --arg br "tkt-$t/work" --arg sha "$sha" --argjson r "$reds" '{
    number:$n, headRefName:$br, headRefOid:$sha, isDraft:false, mergeStateStatus:"CLEAN", mergeable:"MERGEABLE",
    labels:[], autoMergeRequest:{enabledAt:"x"},
    statusCheckRollup: ([
      {__typename:"CheckRun", name:"Every fix ships a lesson", workflowName:"Lesson", status:"COMPLETED",
       conclusion:(if ($r | index("Lesson")) then "FAILURE" else "SUCCESS" end), startedAt:"2026-10-21T10:00:00Z"},
      {__typename:"CheckRun", name:"Code gates", workflowName:"CI", status:"COMPLETED",
       conclusion:(if ($r | index("Code gates")) then "FAILURE" else "SUCCESS" end), startedAt:"2026-10-21T10:00:00Z"},
      {__typename:"StatusContext", context:"Design critic",
       state:(if ($r | index("Design critic")) then "FAILURE" else "SUCCESS" end), createdAt:"2026-10-21T10:00:00Z"}])}'
}

echo "--- the switch ---"
cfg_off;  want "no release key: nothing is non-blocking" "[]" "$(lib release_nonblocking_json)"
cfg_done; want "release done: nothing is non-blocking"   "[]" "$(lib release_nonblocking_json)"
cfg_on
want "while on: the listed names, any case" '["lesson / every fix ships a lesson","design critic","approved picture","widths and contrast on changed routes"]' "$(lib release_nonblocking_json)"
lib release_check_nonblocking "design CRITIC"; want "a listed check is non-blocking, ignoring case" "0" "$?"
lib release_check_nonblocking "Code gates";    want "a check not listed blocks"                    "1" "$?"
want "the workflow / job form of a check run matches" "Design critic, Every fix ships a lesson" \
  "$(lib release_warn_reds "$(red_pr 1 1 a Lesson "Design critic" | jq -c .statusCheckRollup)")"
want "a red not listed is no warning" "" "$(lib release_warn_reds "$(red_pr 1 1 a "Code gates" | jq -c .statusCheckRollup)")"
rerun() { # <rollup json> <name> <conclusion> <at> — one more run of <name>, a re-run
  printf '%s' "$1" | jq -c --arg n "$2" --arg c "$3" --arg at "$4" \
    '. + [{__typename:"CheckRun", name:$n, workflowName:"Lesson", status:"COMPLETED", conclusion:$c, startedAt:$at, completedAt:$at}]'
}
want "a listed red cleared by a re-run is no warning" "" \
  "$(lib release_warn_reds "$(rerun "$(red_pr 1 1 a Lesson | jq -c .statusCheckRollup)" "Every fix ships a lesson" SUCCESS 2026-10-21T11:00:00Z)")"
newest() { HARNESS_CFG="$CFG" bash -c '. "$1"; jq -c "$CHECK_NEWEST_JQ"'"'"'newest_runs | map(.conclusion // .state)'"'" _ "$HERE/release-checks.sh"; }
want "newest_runs: a failure passed on re-run reads as its pass" '["SUCCESS"]' \
  "$(newest <<<'[{"name":"t","status":"COMPLETED","conclusion":"FAILURE","completedAt":"2026-10-21T08:00:00Z"},{"name":"t","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-10-21T10:00:00Z"}]')"
want "newest_runs: order in the rollup does not decide it" '["FAILURE"]' \
  "$(newest <<<'[{"name":"t","status":"COMPLETED","conclusion":"FAILURE","completedAt":"2026-10-21T10:00:00Z"},{"name":"t","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-10-21T08:00:00Z"}]')"
want "newest_runs: a run still going is the newest" '[null]' \
  "$(newest <<<'[{"name":"t","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-10-21T09:00:00Z","completedAt":"0001-01-01T00:00:00Z"},{"name":"t","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-10-21T10:00:00Z"}]')"
want "newest_runs: different checks stay apart" '["FAILURE","SUCCESS"]' \
  "$(newest <<<'[{"name":"a","status":"COMPLETED","conclusion":"FAILURE"},{"name":"b","status":"COMPLETED","conclusion":"SUCCESS"}]')"
want "the required list loses the listed checks" '["Code gates"]' \
  "$(lib release_blocking_required '["Code gates","Design critic","Lesson / Every fix ships a lesson"]')"
cfg_done
want "after the release the required list is whole" '["Code gates","Design critic"]' "$(lib release_blocking_required '["Code gates","Design critic"]')"

echo "--- repair-watch: red only on Lesson and Design critic ---"
W="$HERE/../swarm/repair-watch.sh"
TRIED="$STATE/swarm/repair-attempts.tsv"
fix_issue 101 OPEN "status:in-review,project:widgets"
fix_issue 102 OPEN "status:in-review,project:widgets"
fix_live widgets 0; fix_at "$(date -u +%s)"
printf '{"id":1}\n' > "$FIX/gh/api-repos_acme_widgets_issues_11_comments.json"
pass() { : > "$SPAWNS"; : > "$GH_LOG"; : > "$TRIED"; rm -f "$STATE/swarm/release-warnings.tsv"; bash "$W" --only repair 2>&1; }
cfg_on
jq -s . <(red_pr 11 101 aaaaaaaaa1 Lesson "Design critic") > "$FIX/gh/prs-all.json"
out=$(pass)
want "no repair is sent"                    "0" "$(grep -c . "$SPAWNS")"
want_in "a warning is noted in the log"     'warning, not blocking: PR #11 is red on Design critic, Every fix ships a lesson' "$out"
want "and on the pull request, once"        "1" "$(grep -c 'api repos/acme/widgets/issues/11/comments -X POST' "$GH_LOG")"
: > "$GH_LOG"; out=$(bash "$W" --only repair 2>&1)
want "not again on the same head"           "0" "$(grep -c 'issues/11/comments' "$GH_LOG")"
cfg_done
out=$(pass)
want "release done: the same PR is repaired, as before" "1" "$(grep -c '^101' "$SPAWNS")"
want_not_in "and nothing is called a warning" 'warning, not blocking' "$out"
want "and nothing is posted as one"         "0" "$(grep -c 'issues/11/comments' "$GH_LOG")"
cfg_off
out=$(pass)
want "no release key: repaired, as before"  "1" "$(grep -c '^101' "$SPAWNS")"
cfg_on
jq -s . <(red_pr 12 102 bbbbbbbbb1 Lesson "Code gates") > "$FIX/gh/prs-all.json"
out=$(pass)
want "red on Code gates as well: repaired, as before" "1" "$(grep -c '^102' "$SPAWNS")"
want_in "on the check that blocks alone"    'CI went red on: Code gates$' "$(grep -o 'CI went red on: [^.]*' "$STATE/swarm/briefs/repair-102.md" | head -1)"
TRUNK="$FIX/gh/api-repos_acme_widgets_commits_develop_check-runs_per_page_100.json"
printf '{"check_runs":[{"name":"Approved picture","conclusion":"failure"},{"name":"build","conclusion":"success"}]}\n' > "$TRUNK"
out=$(pass)
want "a trunk red only on a listed check holds no repair" "1" "$(grep -c '^102' "$SPAWNS")"
cfg_done
out=$(pass)
want "release done: that trunk red holds CI repairs, as before" "0" "$(grep -c '^102' "$SPAWNS")"
cfg_on; fix_trunk green

echo "--- the driver's repair: what it answers, and what it calls owed ---"
cfg_on
owed() { # → the repair's "nothing owed" verdict on the fixture PR, at a tree whose head is the PR's
  local wt="$FIX/wt"; rm -rf "$wt"; git init -q "$wt"
  git -C "$wt" -c user.name=f -c user.email=f@x commit -q --allow-empty -m base
  git -C "$wt" branch -q -f develop HEAD
  local h; h=$(git -C "$wt" rev-parse HEAD)
  jq --arg h "$h" '.[0] | .headRefOid = $h' "$FIX/gh/prs-all.json" > "$FIX/gh/pr-view.json"
  KIT="$HERE/.." FIX="$FIX" WT="$wt" bash -c '
    . "$KIT/driver/driver-env.sh" >/dev/null 2>&1 || exit 9
    . "$KIT/driver/steps/repair.sh" || exit 9
    swarm_gh() { cat "$FIX/gh/pr-view.json"; }
    _driver_repair_nothing_owed "$WT" develop 11 && echo "nothing owed"' 2>&1
}
jq -s . <(red_pr 11 101 aaaaaaaaa1 Lesson "Design critic") > "$FIX/gh/prs-all.json"
want "red only on listed checks: nothing is owed" "nothing owed" "$(owed)"
cfg_done
want_in "release done: the same reds are owed, as before" 'red on the head: .*Design critic' "$(owed)"
cfg_on
jq -s . <(red_pr 11 101 aaaaaaaaa1 "Code gates" "Design critic") > "$FIX/gh/prs-all.json"
want "red on Code gates: owed, on Code gates alone" "red on the head: Code gates" "$(owed)"

echo "--- the critic's findings are no step's blockers while its check warns ---"
cat > "$FIX/findings.sh" <<'SH'
#!/usr/bin/env bash
printf 'major\t1\tThe header narrates\n'
SH
chmod +x "$FIX/findings.sh"
crit() {
  KIT="$HERE/.." bash -c '
    . "$KIT/driver/driver-env.sh" >/dev/null 2>&1 || exit 9
    . "$KIT/driver/facts.sh" || exit 9
    driver_state_get() { case "$2" in pr) echo 11 ;; *) echo "" ;; esac; }
    DRIVER_SCREEN_FINDINGS="$1" driver_fact_critic_findings 101' _ "$FIX/findings.sh" 2>&1
}
cfg_on
want_in "listed: the findings are advisory, not blockers" '^\(none — the independent critic failed PR #11 on 1 finding\(s\), and until the release its check warns' "$(crit)"
cfg_done
want_in "release done: they block at their grade, as before" '^The independent design critic failed PR #11 on these' "$(crit)"
cfg_off
want_in "no release key: as before" '^The independent design critic failed PR #11 on these' "$(crit)"

echo "--- the sign-off batch does not wait on a listed check ---"
cfg_on
jq '.gates = {requiredChecks: ["Code gates", "Design critic"]}' "$CFG" > "$CFG.t" && cp "$CFG.t" "$CFG"
held() { red_pr "$1" "$1" "h$1" "Design critic" | jq '.labels = [{name:"needs:human-approval"}]'; }
jq -s . <(held 21) > "$FIX/held.json"
want "listed: a held PR red only on the critic is green apart from the hold" "21" \
  "$(bash "$HERE/signoff-batch.sh" green < "$FIX/held.json" 2>/dev/null | cut -f1)"
jq --argjson l "$LISTED" '.release.done = true' "$CFG" > "$CFG.t" && cp "$CFG.t" "$CFG"
want "release done: it waits on the critic, as before" "" \
  "$(bash "$HERE/signoff-batch.sh" green < "$FIX/held.json" 2>/dev/null | cut -f1)"

suite_end "$FAILED"
