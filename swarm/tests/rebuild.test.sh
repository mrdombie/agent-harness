#!/usr/bin/env bash
# rebuild.test.sh — rebuild, don't repair (scripts/rebuild.sh). An open ticket PR stuck
# past coordinator.rebuildAfterMin — a required check settled red, or a clash — is closed
# with a note, its head kept at refs/stale/<ticket>/pr-<n>, and its ticket queued fresh
# with the reviewed plan as its brief. A red the base has too waits; a PR a person owns
# is never touched; a red only on a check the base does not require is not red; a stuck
# PR under the threshold is left on its clock.
# The fix rounds (coordinator.fixRounds): a PR red on its own code goes back to its builder
# on its own branch, one round a head, two a PR, then parks for the PM with the PR left open.
# A round is spent only once its run started, and one whose run is gone is released.
# PLANT=<name> turns one rule off in a copy of rebuild.sh, so the case that pins it must fail.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
KIT="$(cd "$HERE/../.." && pwd)"
# The rebuild cases run with the fix rounds off; the fix cases below turn them on (fixpass).
export COORDINATOR_SHADOW=0 COORDINATOR_REBUILD_AFTER_MIN=60 COORDINATOR_FIX_ROUNDS=0
C="$STATE/coordinator"; mkdir -p "$C"
QLOG="$FIX/queue.log"; export QLOG
# The queue the rebuild writes to: a recorder, so the brief it carries can be read whole.
cat > "$BIN/queue" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$QLOG"
SH
chmod +x "$BIN/queue"
export QUEUE="$BIN/queue"
LIB="$KIT/scripts/rebuild.sh"
T0=1762160000

# The library under test, or a copy with one rule planted dead (PLANT names it).
lib() {
  [ -n "${PLANT:-}" ] || { printf '%s' "$LIB"; return; }
  local p="$FIX/rebuild.planted.sh"
  cp "$LIB" "$p"
  case "$PLANT" in
    threshold) perl -0pi -e 's/\[ "\$age" -lt "\$REBUILD_AFTER_MIN" \]/false/' "$p" ;;
    base-red)  perl -0pi -e 's/if w=\$\(rebuild_base_red [^)]*\); then/if true; then/' "$p" ;;
    held)      perl -0pi -e 's/if why=\$\(rebuild_held "\$t" "\$pj" "\$lab"\); then/if false; then/' "$p" ;;
    required)  perl -0pi -e 's/    pending\|green\) printf/    green) printf "stuck\\tplanted\\n" ;;\n    pending) printf/' "$p" ;;
    clash)     perl -0pi -e 's/    clash\)  printf .stuck/    clash)  printf '"'"'green/' "$p" ;;
    counted)   perl -0pi -e 's/  rebuild_count_failures "\$t" "\$pr" "\$pj"\n//' "$p" ;;
    cap)       perl -0pi -e 's/\[ "\$n" -ge "\$REBUILD_MAX" \]/false/' "$p" ;;
    plan)      perl -0pi -e 's/\[ -s "\$d\/plan.json" \] && plan=/false \&\& plan=/' "$p" ;;
    cancelled) perl -0pi -e 's/printf .stuck\\t%s\\n. "\$why" ;;\n    pending\|green\)/printf "pending\\t%s\\n" "\$why" ;;\n    pending|green)/' "$p" ;;
    fix-cap)      perl -0pi -e 's/\[ "\$rounds" -ge "\$FIX_ROUNDS" \]/false/' "$p" ;;
    fix-base-red) perl -0pi -e 's/else printf .base-red\\t%s\\n. "\$w"; fi/else printf "stuck\\t%s\\tred\\n" "\$why"; fi/' "$p" ;;
    fix-queued)   perl -0pi -e 's/if \[ "\$state" = queued \] && \[ -n "\$onq" \]; then/if false; then/' "$p" ;;
    fix-started)  perl -0pi -e 's/then rounds=\$\(\(rounds - 1\)\); else state=started; fi/then :; else state=started; fi/' "$p" ;;
    fix-released) perl -0pi -e 's/\[ "\$state" = started \] && rebuild_fix_run_alive "\$t"; then/[ "\$state" = started ]; then/' "$p" ;;
    fix-alive)    perl -0pi -e 's/\[ "\$state" = started \] && rebuild_fix_run_alive "\$t"; then/false; then/' "$p" ;;
    fix-mark)     perl -0pi -e 's/\$4 = "started"/\$4 = \$4/' "$p" ;;
    runners)      perl -0pi -e 's/case "\$\(ci_runners_state\)" in/case planted in/' "$p" ;;
    fix-head)     perl -0pi -e 's/if \[ "\$last" = "\$head" \]; then/if false; then/' "$p" ;;
  esac
  cmp -s "$LIB" "$p" && { echo "plant $PLANT did not apply" >&2; exit 3; }
  printf '%s' "$p"
}
# pass — one rebuild pass over $FIX/gh/prs-all.json, as the tick runs it.
pass() {
  local l; l=$(lib) || exit 3
  OUT=$(cd "$REPO" && CLAIMED="${CLAIMED:-}" bash -c '
    . "$1/scripts/coordinator-env.sh" || exit 1
    . "$1/scripts/pr-red.sh" || exit 1
    . "$1/scripts/issue-status.sh" || exit 1
    . "$2" || exit 1
    PRS=$(cat "$3"); PRS_STALE=0
    rebuild_pass' _ "$KIT" "$l" "$FIX/gh/prs-all.json" 2>&1)
}
# pr <n> <ticket> <head> <mergeState> [labels-json] [name:CONCLUSION:run-id…] — the one open PR.
# CONCLUSION IN_PROGRESS is a check still running.
pr() {
  local n="$1" t="$2" head="$3" ms="$4" labels="${5:-[]}" c rows="[]" name concl rid; shift 5 2>/dev/null || shift $#
  for c in "$@"; do
    IFS=: read -r name concl rid <<<"$c"
    rows=$(jq -c --arg n "$name" --arg c "$concl" --arg r "$rid" \
      '. + [{name: $n, status: (if $c == "IN_PROGRESS" then $c else "COMPLETED" end),
             conclusion: (if $c == "IN_PROGRESS" then null else $c end), completedAt: "2026-11-01T10:00:00Z",
             detailsUrl: "https://github.com/acme/widgets/actions/runs/\($r)/job/1"}]' <<<"$rows")
  done
  jq -n --argjson n "$n" --arg t "$t" --arg sha "$head" --arg ms "$ms" --argjson l "$labels" --argjson r "$rows" \
    '[{number: $n, headRefName: "tkt-\($t)/work", headRefOid: $sha, baseRefName: "develop", isDraft: false,
       mergeable: (if $ms == "DIRTY" then "CONFLICTING" else "MERGEABLE" end), mergeStateStatus: $ms,
       labels: $l, statusCheckRollup: $r, updatedAt: "2026-11-01T10:00:00Z", title: "the change"}]' > "$FIX/gh/prs-all.json"
}
# base <name:conclusion>… — develop's newest commit and what each check's completed run there concluded.
base() {
  local c rows="[]" name concl
  printf '[{"sha":"dev1"}]\n' > "$FIX/gh/api-repos_acme_widgets_commits_sha_develop_per_page_5.json"
  for c in "$@"; do
    IFS=: read -r name concl <<<"$c"
    rows=$(jq -c --arg n "$name" --arg c "$concl" '. + [{name: $n, id: 1, status: "completed", conclusion: $c, completed_at: "2026-11-01T09:00:00Z"}]' <<<"$rows")
  done
  jq -n --argjson r "$rows" '{check_runs: $r}' > "$FIX/gh/api-repos_acme_widgets_commits_dev1_check-runs_per_page_100_filter_all.json"
}
# plan_on_record <ticket> — this host's driver record of the last build: its plan and review.
plan_on_record() {
  local d="$STATE/driver/$1"; mkdir -p "$d/steps"
  printf '{"ticket":%s,"done":["start","plan","build","review","ship"],"mode":"build"}\n' "$1" > "$d/state.json"
  printf '{"step":"plan","status":"planned","tasks":[{"title":"Add the export button","files":["src/export.ts"]},{"title":"Test the empty state","files":["src/export.test.ts"]}]}\n' > "$d/steps/plan.json"
  printf '{"step":"review","verdict":"pass","findings":[{"grade":"minor","summary":"the empty state reads as an error","file":"src/export.tsx"}]}\n' > "$d/steps/review.json"
}
fresh() { : > "$GH_LOG"; : > "$QLOG"; rm -f "$C"/rebuild-clock.* "$C"/base-red.* "$C"/base-red-reruns.* "$C"/reruns.tsv "$C"/run-classes.tsv "$C"/fix-rounds.* "$C"/clash-updates.* "$C"/stale-updates.* "$C"/fix-parks.* "$C"/draft-resumes.* "$C"/queue.json; rm -rf "$STATE/driver"; CLAIMED=""; }
closes() { grep -c "^pr close $1 " "$GH_LOG"; }
age() { fix_at $(( T0 + $1 * 60 )); }   # minutes since the first pass
# fixpass — one pass with the rebuild off and the fix rounds at their default (2), or FR's.
fixpass() {
  local keep="$COORDINATOR_FIX_ROUNDS" min="$COORDINATOR_REBUILD_AFTER_MIN"
  unset COORDINATOR_FIX_ROUNDS; [ -z "${FR:-}" ] || export COORDINATOR_FIX_ROUNDS="$FR"
  export COORDINATOR_REBUILD_AFTER_MIN="${MIN:-0}"
  pass
  export COORDINATOR_FIX_ROUNDS="$keep" COORDINATOR_REBUILD_AFTER_MIN="$min"
}
# queued <ticket> <pr> — that PR's fix round is on the coordinator's queue (the recorder above writes none); unqueued empties it.
queued() { jq -n --argjson n "$1" --arg pr "$2" '{scope: "all", label: "all", tickets: [{n: $n, class: "new", note: "Fix: PR #\($pr) — red\n\nFix round 1 of 2.", pinned: true, front: true}]}' > "$C/queue.json"; }
unqueued() { rm -f "$C/queue.json"; }
# ran <pr> — the tick started that PR's queued fix round, as its spawn does: spent, and off the queue.
ran() {
  local l; l=$(lib) || exit 3
  (cd "$REPO" && bash -c '. "$1/scripts/coordinator-env.sh" && . "$1/scripts/pr-red.sh" && . "$1/scripts/issue-status.sh" && . "$2" && rebuild_fix_started "$3"' _ "$KIT" "$l" "Fix: PR #$1 — red") >/dev/null 2>&1
  unqueued
}
# fixcall <ticket> — rebuild_fix on the one open PR, called as the pass calls it but past its claimed-or-live guard.
fixcall() {
  local l; l=$(lib) || exit 3
  OUT=$(cd "$REPO" && env -u COORDINATOR_FIX_ROUNDS COORDINATOR_REBUILD_AFTER_MIN=0 CLAIMED="${CLAIMED:-}" bash -c '
    . "$1/scripts/coordinator-env.sh" && . "$1/scripts/pr-red.sh" && . "$1/scripts/issue-status.sh" && . "$2" || exit 1
    rebuild_fix "$4" "$(jq -c ".[0]" "$3")" "required check(s) failed: unit" red' _ "$KIT" "$l" "$FIX/gh/prs-all.json" "$1" 2>&1)
}
adds() { grep -c "^add $1 " "$QLOG"; }
rounds() { awk -F'\t' -v p="$1" '$1 == p { print $2 "/" $3 }' "$C/fix-rounds.did.tsv" 2>/dev/null; }
state() { awk -F'\t' -v p="$1" '$1 == p { print $4 }' "$C/fix-rounds.did.tsv" 2>/dev/null; }
updates() { grep -c "^api repos/acme/widgets/pulls/$1/update-branch -X PUT" "$GH_LOG"; }

fix_required unit lint
printf '{}\n' > "$FIX/gh/api-repos_acme_widgets_git_refs.json"   # the stale ref is made
fix_issue 101 OPEN "status:in-review,P1"

echo "--- a required check red past the threshold: closed and requeued fresh, the brief carrying the plan ---"
fresh; plan_on_record 101; base unit:success lint:success
pr 71 101 head1 BLOCKED '[]' unit:FAILURE:7001 lint:SUCCESS:7002
age 0; pass
want "first seen red: not rebuilt yet"           "0" "$(closes 71)"
want_in "  it says its clock runs"               'rebuild: PR #71 is stuck \(required check\(s\) failed: unit\) — 0 of 60 min' "$OUT"
age 59; pass
want "59 minutes on: still not rebuilt"          "0" "$(closes 71)"
age 61; pass
want "61 minutes on: the PR is closed"           "1" "$(closes 71)"
want_in "  with a note saying why"               'pr close 71 --repo acme/widgets --delete-branch --comment Closed to rebuild fresh: this PR could not merge within 60 minutes \(required check\(s\) failed: unit\)' "$(cat "$GH_LOG")"
want "  its head is kept on a stale ref first"   "1" "$(grep -c '^api repos/acme/widgets/git/refs -f ref=refs/stale/101/pr-71 -f sha=head1' "$GH_LOG")"
want_in "  the ticket goes back to ready"        'issue edit 101 .*--add-label status:ready' "$(cat "$GH_LOG")"
want_in "  it is queued fresh, first in its priority" '^add 101 --class new --first --note Rebuild: PR #71 could not merge within 60 min' "$(cat "$QLOG")"
want_in "  the brief carries the reviewed plan"  '- Add the export button \(src/export.ts\)' "$(cat "$QLOG")"
want_in "  and what the last review found"       '- minor: the empty state reads as an error \(src/export.tsx\)' "$(cat "$QLOG")"
want_in "  and why it could not merge"           'Why it could not merge: required check\(s\) failed: unit' "$(cat "$QLOG")"
want "  this host's record forgets its steps"    "[]" "$(jq -c .done "$STATE/driver/101/state.json")"
want "  the class is recorded as a rebuild"      "rebuild" "$(cut -f3 "$C/run-classes.tsv" | tail -1)"
want "  and its clock is gone"                   "" "$(cut -f1 "$C/rebuild-clock.did.tsv" 2>/dev/null)"

echo "--- a clash past the threshold: rebuilt ---"
fresh; base unit:success lint:success
pr 72 101 head2 DIRTY '[]' unit:SUCCESS:7003 lint:SUCCESS:7004
age 0; pass
want "first seen clashing: left on its clock"    "0" "$(closes 72)"
age 70; pass
want "70 minutes on: closed"                     "1" "$(closes 72)"
want_in "  and queued fresh"                     '^add 101 --class new --first --note Rebuild: PR #72 could not merge within 60 min \(it conflicts with its base branch\)' "$(cat "$QLOG")"
want_in "  with no plan on this host, it says to plan again" "plan again from the ticket" "$(cat "$QLOG")"

echo "--- red only because develop is red: it waits, never rebuilt ---"
fresh; base unit:failure lint:success
pr 73 101 head3 BLOCKED '[]' unit:FAILURE:7005 lint:SUCCESS:7006
age 0; pass; age 200; pass
want "200 minutes red on a check develop fails too: not closed" "0" "$(closes 73)"
want_in "  it says it waits for develop"         'rebuild: PR #73 waits — base-red on unit — waits for develop to go green' "$OUT"
want "  the PR is told, once"                    "1" "$(grep -c 'issues/73/comments -X POST -f body=Not rebuilt: unit failed on develop' "$GH_LOG")"
want "  no clock runs while it waits"            "" "$(cut -f1 "$C/rebuild-clock.did.tsv" 2>/dev/null)"
echo "  develop goes green: the waiting head's failed jobs are re-run, and its clock starts after"
base unit:success lint:success; : > "$GH_LOG"
age 210; pass
want "  not closed"                              "0" "$(closes 73)"
want "  its failed jobs are re-run once"         "1" "$(grep -c '^run rerun 7005 --failed' "$GH_LOG")"
age 215; pass
want "  still red: its clock starts now"         "73" "$(cut -f1 "$C/rebuild-clock.did.tsv" 2>/dev/null)"
age 280; pass
want "  and an hour on it is rebuilt"            "1" "$(closes 73)"

echo "--- a required check cancelled past the threshold: re-run, then rebuilt as for a red ---"
fresh; base unit:success lint:success
pr 79 101 head11 BLOCKED '[]' "unit:CANCELLED:7015" lint:SUCCESS:7016
age 0; pass
want "first seen cancelled: not rebuilt yet"     "0" "$(closes 79)"
want "  its run is re-run"                       "1" "$(grep -c '^run rerun 7015 --failed' "$GH_LOG")"
want_in "  its clock starts, naming the conclusion" 'rebuild: PR #79 is stuck \(required check\(s\) cancelled: unit\) — 0 of 60 min' "$OUT"
age 61; pass
want "61 minutes on, still cancelled: closed"    "1" "$(closes 79)"
want_in "  with a note saying it was cancelled"  'Closed to rebuild fresh: this PR could not merge within 60 minutes \(required check\(s\) cancelled: unit\)' "$(cat "$GH_LOG")"
for k in TIMED_OUT:"timed out" ACTION_REQUIRED:"action required" STARTUP_FAILURE:"startup failure"; do
  fresh; base unit:success
  pr 79 101 head11 BLOCKED '[]' "unit:${k%%:*}:7015"
  age 0; pass; age 61; pass
  want "required check ${k%%:*} past the threshold: closed" "1" "$(closes 79)"
  want_in "  and the reason says so"             "required check\(s\) ${k#*:}: unit" "$(cat "$GH_LOG")"
done

echo "--- a required check still running is not stuck, however long ---"
fresh; base unit:success
pr 80 101 head12 BLOCKED '[]' unit:IN_PROGRESS:7017
age 0; pass; age 300; pass
want "300 minutes running: not closed"           "0" "$(closes 80)"
want "  and no clock runs"                       "" "$(cut -f1 "$C/rebuild-clock.did.tsv" 2>/dev/null)"

echo "--- a red the base cannot be read for decides nothing: on the clock as the PR's own ---"
fresh; rm -f "$FIX/gh/api-repos_acme_widgets_commits_sha_develop_per_page_5.json"
pr 74 101 head4 BLOCKED '[]' unit:FAILURE:7007
age 0; pass; age 61; pass
want "rebuilt"                                   "1" "$(closes 74)"

echo "--- a person owns it: never touched, however long ---"
for held in '[{"name":"needs:human-approval"}]' '[{"name":"do-not-merge"}]'; do
  fresh; base unit:success
  pr 75 101 head5 DIRTY "$held" unit:FAILURE:7008
  age 0; pass; age 500; pass
  want "PR labelled $(jq -r '.[0].name' <<<"$held"): not closed" "0" "$(closes 75)"
  want_in "  and it says why"                    "rebuild: PR #75 left as it is — the PR carries $(jq -r '.[0].name' <<<"$held")" "$OUT"
done
for lab in needs:owner-decision status:needs-human status:parked; do
  fresh; base unit:success; fix_issue 101 OPEN "$lab,P1"
  pr 75 101 head5 DIRTY '[]' unit:FAILURE:7008
  age 0; pass; age 500; pass
  want "ticket labelled $lab: not closed"        "0" "$(closes 75)"
done
fix_issue 101 OPEN "status:in-review,P1"
fresh; base unit:success; CLAIMED=101
pr 75 101 head5 DIRTY '[]' unit:FAILURE:7008
age 0; pass; age 500; pass
want "a ticket claimed on any host: not closed"  "0" "$(closes 75)"

echo "--- red only on checks develop does not require: not red ---"
fresh; base unit:success lint:success
pr 76 101 head6 BLOCKED '[]' unit:SUCCESS:7009 "Capture and pin the evidence:FAILURE:7010"
age 0; pass; age 300; pass
want "300 minutes red on a check develop does not require: not closed" "0" "$(closes 76)"
want "  and no clock runs"                       "" "$(cut -f1 "$C/rebuild-clock.did.tsv" 2>/dev/null)"

echo "--- a PR that goes green stops its clock; red again starts a new one ---"
fresh; base unit:success
pr 77 101 head7 BLOCKED '[]' unit:FAILURE:7011
age 0; pass
pr 77 101 head8 BLOCKED '[]' unit:SUCCESS:7012
age 50; pass
pr 77 101 head9 BLOCKED '[]' unit:FAILURE:7013
age 70; pass
want "green between: the clock started again, not rebuilt at 70" "0" "$(closes 77)"
age 131; pass
want "  an hour after it went red again: rebuilt" "1" "$(closes 77)"

echo "--- a thrown-away change is counted: one sighting per failed required check, its log queued ---"
LED="$STATE/swarm/finding-classes.jsonl"
fresh; rm -f "$LED" "${LED%.jsonl}.logs.tsv"; base unit:success
pr 79 101 head11 BLOCKED '[]' unit:FAILURE:7015
age 0; pass; age 61; pass
want "the PR was closed"                         "1" "$(closes 79)"
want "one check sighting, on the ledger"         "check:unit|101|79" "$(jq -r '"\(.key)|\(.ticket)|\(.pr)"' "$LED" 2>/dev/null)"
want "its job's log queued for housekeeping"     "101	79	unit	1	0" "$(cat "${LED%.jsonl}.logs.tsv" 2>/dev/null)"
fresh; rm -f "$LED" "${LED%.jsonl}.logs.tsv"; base unit:success
pr 80 101 head12 DIRTY '[]' unit:SUCCESS:7016
age 0; pass; age 61; pass
want "a clash has no failed check, so no sighting" "0" "$(cat "$LED" 2>/dev/null | grep -c .)"
rm -f "$LED" "${LED%.jsonl}.logs.tsv"
fresh; base unit:success
pr 81 101 head13 BLOCKED '[]' unit:FAILURE:7017
age 0; COORDINATOR_SHADOW=1 pass; age 61; COORDINATOR_SHADOW=1 pass
want "shadow counts nothing"                     "0" "$(cat "$LED" 2>/dev/null | grep -c .)"

echo "--- built twice already: parked for the PM, not built a third time ---"
REFS="$FIX/gh/api-repos_acme_widgets_git_matching-refs_stale_101_.json"
fresh; base unit:success lint:success
printf '[{"ref":"refs/stale/101/pr-60"},{"ref":"refs/stale/101/pr-65"}]\n' > "$REFS"
pr 82 101 head14 BLOCKED '[]' unit:FAILURE:7018 lint:SUCCESS:7019
age 0; pass; age 61; pass
want "the PR is closed"                          "1" "$(closes 82)"
want_in "  with a note saying it parked"         'pr close 82 --repo acme/widgets --delete-branch --comment Parked for the PM: ticket #101 has been built 2 times and PR #82 still cannot merge' "$(cat "$GH_LOG")"
want "  its head is kept"                        "1" "$(grep -c '^api repos/acme/widgets/git/refs -f ref=refs/stale/101/pr-82 -f sha=head14' "$GH_LOG")"
want_in "  the ticket is parked"                 'issue edit 101 .*--add-label status:parked' "$(cat "$GH_LOG")"
want_in "  for the PM"                           'issue edit 101 .*pm-decision' "$(cat "$GH_LOG")"
want_in "  and told which check failed"          'issue comment 101 .*Failing checks on the last build:.*- unit' "$(tr '\n' ' ' < "$GH_LOG")"
want "  it is not queued again"                  "0" "$(grep -c '^add 101' "$QLOG")"
want_in "  it says so"                           'rebuild: parked #101 for the PM — built 2 times, PR #82 closed' "$OUT"

echo "--- built once: rebuilt as before ---"
fresh; base unit:success
printf '[{"ref":"refs/stale/101/pr-60"}]\n' > "$REFS"
pr 83 101 head15 BLOCKED '[]' unit:FAILURE:7020
age 0; pass; age 61; pass
want "closed"                                    "1" "$(closes 83)"
want_in "  and queued fresh"                     '^add 101 --class new --first' "$(cat "$QLOG")"

echo "--- coordinator.rebuildMax 0: no cap ---"
fresh; base unit:success
printf '[{"ref":"refs/stale/101/pr-60"},{"ref":"refs/stale/101/pr-65"},{"ref":"refs/stale/101/pr-70"}]\n' > "$REFS"
pr 84 101 head16 BLOCKED '[]' unit:FAILURE:7021
age 0; COORDINATOR_REBUILD_MAX=0 pass; age 61; COORDINATOR_REBUILD_MAX=0 pass
want_in "built 3 times, no cap: queued fresh"    '^add 101 --class new --first' "$(cat "$QLOG")"
rm -f "$REFS"
fix_issue 101 OPEN "status:in-review,P1"

echo "--- shadow: says what it would do, closes nothing ---"
fresh; base unit:success
pr 78 101 head10 DIRTY '[]' unit:SUCCESS:7014
age 0; COORDINATOR_SHADOW=1 pass; age 61; COORDINATOR_SHADOW=1 pass
want "nothing closed in shadow"                  "0" "$(closes 78)"
want_in "  it says it would"                     'rebuild: would close PR #78' "$OUT"

echo "--- every CI runner offline: nothing closed, nothing queued, and it says why ---"
RUNNERS="$FIX/gh/api-repos_acme_widgets_actions_runners_per_page_100.json"
fresh; base unit:success lint:success
printf '{"total_count":2,"runners":[{"id":1,"status":"offline"},{"id":2,"status":"offline"}]}\n' > "$RUNNERS"
pr 71 101 head1 BLOCKED '[]' unit:FAILURE:7001 lint:SUCCESS:7002
printf '71\t%s\trequired check(s) failed: unit\n' "$T0" > "$C/rebuild-clock.did.tsv"
age 61; pass
want "red 61 minutes, every runner offline: not closed" "0" "$(closes 71)"
want "  nothing queued"                          "" "$(cat "$QLOG")"
want_in "  it says every CI runner is offline"   'rebuild: every CI runner is offline' "$OUT"
FR=2 MIN=60 fixpass
want "  with fix rounds on: no fix round queued" "0" "$(grep -c 'Fix: PR #' "$QLOG")"
want "  and none spent"                          "" "$(rounds 71)"
echo "  the runner list cannot be read: the same"
fresh; rm -f "$RUNNERS"; : > "$FIX/gh/runners-unread"
pr 71 101 head1 BLOCKED '[]' unit:FAILURE:7001 lint:SUCCESS:7002
printf '71\t%s\trequired check(s) failed: unit\n' "$T0" > "$C/rebuild-clock.did.tsv"
age 61; pass
want "  not closed"                              "0" "$(closes 71)"
want "  nothing queued"                          "" "$(cat "$QLOG")"
want_in "  it says the list could not be read"   'rebuild: the CI runner list could not be read' "$OUT"
rm -f "$FIX/gh/runners-unread"
echo "  one runner online: rebuilt as before"
fresh; printf '{"total_count":2,"runners":[{"id":1,"status":"offline"},{"id":2,"status":"online"}]}\n' > "$RUNNERS"
pr 71 101 head1 BLOCKED '[]' unit:FAILURE:7001 lint:SUCCESS:7002
printf '71\t%s\trequired check(s) failed: unit\n' "$T0" > "$C/rebuild-clock.did.tsv"
age 61; pass
want "  closed once"                             "1" "$(closes 71)"
want_in "  queued with a Rebuild: brief"         '^add 101 --class new --first --note Rebuild: PR #71 could not merge within 60 min' "$(cat "$QLOG")"
want "  queued once"                             "1" "$(adds 101)"
echo "  no self-hosted runners (total_count 0): rebuilt as before"
fresh; printf '{"total_count":0,"runners":[]}\n' > "$RUNNERS"
pr 71 101 head1 BLOCKED '[]' unit:FAILURE:7001 lint:SUCCESS:7002
printf '71\t%s\trequired check(s) failed: unit\n' "$T0" > "$C/rebuild-clock.did.tsv"
age 61; pass
want "  closed once"                             "1" "$(closes 71)"
want_in "  queued with a Rebuild: brief"         '^add 101 --class new --first --note Rebuild: PR #71 could not merge within 60 min' "$(cat "$QLOG")"
want "  queued once"                             "1" "$(adds 101)"
rm -f "$RUNNERS"

echo "--- the rebuild off, a required check red on the PR's own code: back to its builder, on its branch ---"
fresh; base unit:success lint:success
pr 90 101 head20 BLOCKED '[]' unit:FAILURE:7101 lint:SUCCESS:7102
age 0; fixpass
want "round 1: queued once"                      "1" "$(adds 101)"
want_in "  first in its priority, with a Fix: brief naming the check" '^add 101 --class new --first --note Fix: PR #90 — required check\(s\) failed: unit$' "$(cat "$QLOG")"
want_in "  the brief names the PR's branch"      'The pull request is open on tkt-101/work and this run continues on that branch' "$(cat "$QLOG")"
want_in "  and the failing check's job log"      '^- unit: https://github.com/acme/widgets/actions/runs/7101/job/1$' "$(cat "$QLOG")"
want_in "  fix only what the check reports"      'Fix only what those checks report' "$(cat "$QLOG")"
want_in "  as a push, never a new pull request"  'do not open a new pull request' "$(cat "$QLOG")"
want "  a passing check is not in the brief"     "0" "$(grep -c '^- lint' "$QLOG")"
want "  no plan, no review history"              "0" "$(grep -cE 'reviewed plan|last review' "$QLOG")"
want_in "  the ticket goes back to ready"        'issue edit 101 .*--add-label status:ready' "$(cat "$GH_LOG")"
want "  the round is on the ledger, with its head" "1/head20" "$(rounds 90)"
want "  the PR is not closed"                    "0" "$(closes 90)"
want_in "  it says so"                           'rebuild: PR #90 goes back to its builder on tkt-101/work — fix round 1 of 2' "$OUT"
want "  queued, not spent: its run has not started" "queued" "$(state 90)"
queued 101 90; age 5; fixpass; age 10; fixpass
want "the same head seen again, its fix still queued: one round, one queue entry" "1" "$(adds 101)"
want "  the ledger still says one"               "1/head20" "$(rounds 90)"
want_in "  it says the round has not started"    'rebuild: PR #90 is stuck .* — fix round 1 of 2 is queued for this head and has not started' "$OUT"
want_not_in "  never that it was spent"          'was spent on this head' "$OUT"
ran 90
want "its run starts: the round is spent"        "started" "$(state 90)"
echo "  a new head, red again: round 2"
pr 90 101 head21 BLOCKED '[]' unit:FAILURE:7103 lint:SUCCESS:7104
age 30; fixpass
want "  queued a second time"                    "2" "$(adds 101)"
want "  the ledger counts the PR, not the head"  "2/head21" "$(rounds 90)"
ran 90
want_in "  with the new head's job log"          '^- unit: https://github.com/acme/widgets/actions/runs/7103/job/1$' "$(cat "$QLOG")"
echo "  a third red head: parked for the PM, the PR left open"
pr 90 101 head22 BLOCKED '[]' unit:FAILURE:7105 lint:SUCCESS:7106
: > "$GH_LOG"; age 60; fixpass
want "  nothing more is queued"                  "2" "$(adds 101)"
want "  the PR is NOT closed"                    "0" "$(closes 90)"
want "  and no stale ref is made of it"          "0" "$(grep -c 'refs/stale' "$GH_LOG")"
want_in "  the ticket is parked"                 'issue edit 101 .*--add-label status:parked' "$(cat "$GH_LOG")"
want_in "  for the PM"                           'issue edit 101 .*pm-decision' "$(cat "$GH_LOG")"
want_in "  and told its rounds and the check"    'issue comment 101 .*PR #90 had 2 fix round\(s\) on its own branch.*The PR is left open\..*Failing checks:.*- unit: https://github.com/acme/widgets/actions/runs/7105/job/1' "$(tr '\n' ' ' < "$GH_LOG")"
want "  the count did not reset on the new head" "2/head21" "$(rounds 90)"
want_in "  it says so"                           'rebuild: parked #101 for the PM — 2 fix round\(s\), PR #90 left open' "$OUT"

echo "--- a fix round that ended without a push: the next round on the same head, then the park ---"
fresh; base unit:success
pr 99 101 head40 BLOCKED '[]' unit:FAILURE:7120
age 0; fixpass; queued 101 99; age 5; fixpass
want "queued and waiting: no second entry"       "1" "$(adds 101)"
want "  no round spent"                          "1/head40 queued" "$(rounds 99) $(state 99)"
ran 99; age 10; fixpass
want "its run started and is gone, same head: round 2 is queued" "2" "$(adds 101)"
want "  on the same head"                        "2/head40 queued" "$(rounds 99) $(state 99)"
want_in "  it says the round ended without a push" 'rebuild: PR #99 — fix round 1 ended without a push' "$OUT"
queued 101 99; age 15; fixpass
want "round 2 queued and waiting: nothing more"  "2" "$(adds 101)"
ran 99; : > "$GH_LOG"; age 20; fixpass
want "2 of 2 ended without a push: never a third run" "2" "$(adds 101)"
want_in "  the ticket is parked for the PM"      'issue edit 101 .*--add-label status:parked' "$(cat "$GH_LOG")"
want "  the PR is left open"                     "0" "$(closes 99)"
want "  the cap held"                            "2/head40" "$(rounds 99)"
want_in "  it says so"                           'rebuild: parked #101 for the PM — 2 fix round\(s\), PR #99 left open' "$OUT"

echo "--- a round is spent only once its run has started ---"
fresh; base unit:success
pr 88 101 head50 BLOCKED '[]' unit:FAILURE:7130
age 0; fixpass; queued 101 88; age 5; fixpass
unqueued; : > "$GH_LOG"; age 10; fixpass
want "queued, then off the queue with no run started: queued again" "2" "$(adds 101)"
want "  still round 1: nothing was spent"        "1/head50 queued" "$(rounds 88) $(state 88)"
want_in "  it says so"                           'rebuild: PR #88 — fix round 1 left the queue without starting; no round spent' "$OUT"
want_in "  the brief is round 1 again"           'Fix round 1 of 2\.' "$(cat "$QLOG")"
want "  never round 2"                           "0" "$(grep -c 'Fix round 2 of 2' "$QLOG")"
unqueued; age 15; fixpass; unqueued; age 20; fixpass
want "  however often: never parked for rounds no run spent" "0" "$(grep -c 'status:parked' "$GH_LOG")"
echo "  a row an older version wrote at queue time, its round still queued: not spent either"
fresh; base unit:success
pr 88 101 head50 BLOCKED '[]' unit:FAILURE:7130
printf '88\t2\thead50\n' > "$C/fix-rounds.did.tsv"; queued 101 88
age 0; fixpass
want_in "  round 2 of 2 waits for its start"     'rebuild: PR #88 is stuck .* — fix round 2 of 2 is queued for this head and has not started' "$OUT"
want "  not parked"                              "0" "$(grep -c 'status:parked' "$GH_LOG")"
ran 88
want "  started, the same row is the spent one"  "2/head50 started" "$(rounds 88) $(state 88)"
echo "  a start with no row to mark is counted from its brief"
rm -f "$C"/fix-rounds.*; ran 88
want "  one round, started"                      "1/- started" "$(rounds 88) $(state 88)"

echo "--- a started round whose run is gone is released, whatever the queue holds ---"
fresh; base unit:success
pr 89 101 head60 BLOCKED '[]' unit:FAILURE:7140
printf '89\t1\thead60\tstarted\n' > "$C/fix-rounds.did.tsv"; queued 101 89
age 0; fixpass
want "no claim, no live run, its ticket still queued: round 2 starts" "1" "$(adds 101)"
want "  on the same head"                        "2/head60 queued" "$(rounds 89) $(state 89)"
want_in "  it says the round is released"        'rebuild: PR #89 — fix round 1 ended without a push; its run is gone, so it is released' "$OUT"
want_not_in "  the PR is not left waiting on it" 'it waits for that run' "$OUT"
printf '89\t2\thead60\tstarted\n' > "$C/fix-rounds.did.tsv"; : > "$QLOG"; : > "$GH_LOG"; age 5; fixpass
want "its rounds spent and the last run gone: parked for the PM" "1" "$(grep -c 'issue edit 101 .*--add-label status:parked' "$GH_LOG")"
want "  no third round"                          "0" "$(adds 101)"
echo "  while its run is alive the round is not released"
printf '89\t1\thead60\tstarted\n' > "$C/fix-rounds.did.tsv"; rm -f "$C"/fix-parks.*; unqueued; : > "$QLOG"
CLAIMED=101 fixcall 101
want "a claim on the ticket: nothing queued"     "0" "$(adds 101)"
want_in "  it waits for that run"                'rebuild: PR #89 is stuck .* — fix round 1 of 2 was spent on this head; it waits for that run' "$OUT"
mkdir -p "$STATE/runs"; printf '{"run_id":"claim-101-live","ticket":"101","child_pid":%s}\n' "$$" > "$STATE/runs/claim-101-live.json"
CLAIMED="" fixcall 101
want "a live run here, no claim: nothing queued" "0" "$(adds 101)"
want_in "  it waits for that run"                'it waits for that run' "$OUT"
rm -f "$STATE/runs/claim-101-live.json"
CLAIMED="" fixcall 101
want "the run gone: the next round"              "1" "$(adds 101)"

echo "--- under the rebuild threshold the fix round replaces the wait too ---"
fresh; base unit:success
pr 91 101 head23 BLOCKED '[]' unit:FAILURE:7107
age 0; MIN=60 fixpass
want "queued for its fix at minute 0"            "1" "$(adds 101)"
want "  and not closed"                          "0" "$(closes 91)"

echo "--- never sent for a fix: a base-red, a cancelled check, a person's PR, a claimed ticket ---"
fresh; base unit:failure lint:success
pr 92 101 head24 BLOCKED '[]' unit:FAILURE:7108 lint:SUCCESS:7109
age 0; fixpass; age 30; fixpass
want "red on a check develop fails too: no fix"  "0" "$(adds 101)"
want "  and no round spent"                      "" "$(rounds 92)"
fresh; base unit:success
pr 93 101 head25 BLOCKED '[]' unit:CANCELLED:7110
age 0; fixpass; age 30; fixpass
want "a cancelled check: no fix"                 "0" "$(adds 101)"
want "  it is re-run, as before"                 "1" "$(grep -c '^run rerun 7110 --failed' "$GH_LOG" | awk '{ print ($1 > 0) }')"
want "  and no round spent"                      "" "$(rounds 93)"
fresh; base unit:success
pr 94 101 head26 BLOCKED '[{"name":"needs:human-approval"}]' unit:FAILURE:7111
age 0; fixpass
want "a PR carrying the hold: no fix"            "0" "$(adds 101)"
fresh; base unit:success; fix_issue 101 OPEN "status:parked,P1"
pr 94 101 head26 BLOCKED '[]' unit:FAILURE:7111
age 0; fixpass
want "a parked ticket: no fix"                   "0" "$(adds 101)"
want "  and its labels are not touched"          "0" "$(grep -c '^issue edit 101' "$GH_LOG")"
fix_issue 101 OPEN "status:in-review,P1"
fresh; base unit:success; CLAIMED=101
pr 94 101 head26 BLOCKED '[]' unit:FAILURE:7111
age 0; fixpass
want "a claimed ticket: no fix"                  "0" "$(adds 101)"
want "  no round spent"                          "" "$(rounds 94)"
want "  and its labels are not touched"          "0" "$(grep -c '^issue edit 101' "$GH_LOG")"

echo "--- a clash: one update from its base, then a fix round like a red ---"
UPD="$FIX/gh/api-repos_acme_widgets_pulls_95_update-branch.json"
fresh; base unit:success; printf '{"message":"Updating pull request branch."}\n' > "$UPD"
pr 95 101 head27 DIRTY '[]' unit:SUCCESS:7112
age 0; fixpass
want "first seen clashing: its branch is updated" "1" "$(updates 95)"
want "  no builder is sent yet"                  "0" "$(adds 101)"
want_in "  it says so"                           'rebuild: PR #95 updated from develop' "$OUT"
age 5; fixpass
want "still clashing: no second update"          "1" "$(updates 95)"
want "  it goes back to its builder instead"     "1" "$(adds 101)"
want_in "  with a brief naming the clash"        '^add 101 --class new --first --note Fix: PR #95 — it conflicts with its base branch$' "$(cat "$QLOG")"
want_in "  and what to merge"                    'Merge origin/develop into tkt-101/work, resolve the conflicts' "$(cat "$QLOG")"
want "  a round is queued"                       "1/head27" "$(rounds 95)"
fresh; base unit:success; rm -f "$UPD"
pr 95 101 head28 DIRTY '[]' unit:SUCCESS:7113
age 0; fixpass
want "an update GitHub refuses: tried once"      "1" "$(updates 95)"
want "  and the clash is a fix round at once"    "1" "$(adds 101)"
age 5; fixpass
want "  never tried again"                       "1" "$(updates 95)"

echo "--- coordinator.fixRounds 0: off, exactly as before ---"
fresh; base unit:success
pr 96 101 head29 BLOCKED '[]' unit:FAILURE:7114
age 0; FR=0 fixpass
want "nothing queued"                            "0" "$(adds 101)"
want "  no ledger"                               "" "$(rounds 96)"
want "  the ticket's labels are not touched"     "0" "$(grep -c '^issue edit 101' "$GH_LOG")"
want_in "  it waits, as it did"                  'rebuild: PR #96 is stuck \(required check\(s\) failed: unit\) — 0 of 0 min \(coordinator.rebuildAfterMin 0: off\)' "$OUT"
fresh; base unit:success; rm -f "$UPD"
pr 95 101 head28 DIRTY '[]' unit:SUCCESS:7113
age 0; FR=0 fixpass
want "  a clash is not updated either"           "0" "$(updates 95)"

echo "--- shadow: says what the fix path would do, changes nothing ---"
fresh; base unit:success
pr 97 101 head30 BLOCKED '[]' unit:FAILURE:7115
age 0; COORDINATOR_SHADOW=1 fixpass
want "nothing queued in shadow"                  "0" "$(adds 101)"
want "  no round spent"                          "" "$(cat "$C"/fix-rounds.* 2>/dev/null)"
want "  the ticket's labels are not touched"     "0" "$(grep -c '^issue edit 101' "$GH_LOG")"
want_in "  it says it would"                     'rebuild: would send PR #97 back to its builder — fix round 1 of 2' "$OUT"
fresh; base unit:success; printf '{}\n' > "$UPD"
pr 95 101 head28 DIRTY '[]' unit:SUCCESS:7113
age 0; COORDINATOR_SHADOW=1 fixpass
want "  a clash is not updated in shadow"        "0" "$(updates 95)"
want "  and no update is recorded"               "" "$(cat "$C"/clash-updates.* 2>/dev/null)"
want_in "  it says it would"                     'rebuild: would update PR #95 from develop once' "$OUT"
fresh; base unit:success; rm -f "$UPD"
printf '98\t2\thead30\n' > "$C/fix-rounds.would.tsv"; printf '98\t2\thead30\n' > "$C/fix-rounds.did.tsv"
pr 98 101 head31 BLOCKED '[]' unit:FAILURE:7116
age 0; COORDINATOR_SHADOW=1 fixpass
want "  a PR past its rounds is not parked in shadow" "0" "$(grep -c '^issue ' "$GH_LOG")"
want_in "  it says it would"                     'rebuild: would park #101 for the PM — 2 fix round\(s\)' "$OUT"
rm -f "$C"/fix-rounds.*

if [ -z "${PLANT:-}" ] && [ -z "${NO_PLANTS:-}" ]; then
  echo "--- every rule's plant fails its case ---"
  for p in threshold base-red held required clash plan cancelled counted cap fix-cap fix-base-red fix-head fix-queued fix-started fix-released fix-alive fix-mark runners; do
    PLANT=$p bash "$0" >/dev/null 2>&1; rc=$?
    want "plant $p: the suite fails"             "1" "$([ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] && echo 1 || echo "rc=$rc")"
  done
fi

suite_end "$FAILED"
