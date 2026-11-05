#!/usr/bin/env bash
# rebuild.test.sh — rebuild, don't repair (scripts/rebuild.sh). An open ticket PR stuck
# past coordinator.rebuildAfterMin — a required check settled red, or a clash — is closed
# with a note, its head kept at refs/stale/<ticket>/pr-<n>, and its ticket queued fresh
# with the reviewed plan as its brief. A red the base has too waits; a PR a person owns
# is never touched; a red only on a check the base does not require is not red; a stuck
# PR under the threshold is left on its clock.
# PLANT=<name> turns one rule off in a copy of rebuild.sh, so the case that pins it must fail.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
KIT="$(cd "$HERE/../.." && pwd)"
export COORDINATOR_SHADOW=0 COORDINATOR_REBUILD_AFTER_MIN=60
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
    plan)      perl -0pi -e 's/\[ -s "\$d\/plan.json" \] && plan=/false \&\& plan=/' "$p" ;;
    cancelled) perl -0pi -e 's/printf .stuck\\t%s\\n. "\$why" ;;\n    pending\|green\)/printf "pending\\t%s\\n" "\$why" ;;\n    pending|green)/' "$p" ;;
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
fresh() { : > "$GH_LOG"; : > "$QLOG"; rm -f "$C"/rebuild-clock.* "$C"/base-red.* "$C"/base-red-reruns.* "$C"/reruns.tsv "$C"/run-classes.tsv; rm -rf "$STATE/driver"; CLAIMED=""; }
closes() { grep -c "^pr close $1 " "$GH_LOG"; }
age() { fix_at $(( T0 + $1 * 60 )); }   # minutes since the first pass

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

echo "--- shadow: says what it would do, closes nothing ---"
fresh; base unit:success
pr 78 101 head10 DIRTY '[]' unit:SUCCESS:7014
age 0; COORDINATOR_SHADOW=1 pass; age 61; COORDINATOR_SHADOW=1 pass
want "nothing closed in shadow"                  "0" "$(closes 78)"
want_in "  it says it would"                     'rebuild: would close PR #78' "$OUT"

if [ -z "${PLANT:-}" ] && [ -z "${NO_PLANTS:-}" ]; then
  echo "--- every rule's plant fails its case ---"
  for p in threshold base-red held required clash plan cancelled; do
    PLANT=$p bash "$0" >/dev/null 2>&1; rc=$?
    want "plant $p: the suite fails"             "1" "$([ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] && echo 1 || echo "rc=$rc")"
  done
fi

suite_end "$FAILED"
