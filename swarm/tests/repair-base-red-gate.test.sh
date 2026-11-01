#!/usr/bin/env bash
# repair-base-red-gate.test.sh — a PR whose every failing required check failed on the
# base's newest completed run too gets no repair and no rebuild: it waits for the base.
# A red the base passes is repaired as before; a base that cannot be read decides nothing;
# when the base goes green the PR's failed jobs are re-run once before any repair; and a
# PR seen base-red starts its rebuild count again. Driven through repair-watch, one of the
# callers of the one repair gate (scripts/repair-gate.sh).
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
W="${REPAIR_WATCH:-$HERE/../repair-watch.sh}"
export COORDINATOR_SHADOW=0 COORDINATOR_REBUILD_AFTER_REPAIRS=2
TRIED="$STATE/swarm/repair-attempts.tsv"
CLASSES="$STATE/coordinator/run-classes.tsv"
T0=$(date -u +%s)
fix_at "$T0"
fix_issue 101 OPEN "status:in-review,project:widgets"
fix_live widgets 0; fix_at "$T0"
mkdir -p "$STATE/coordinator"

# pr_red <pr> <head> <name:CONCLUSION:run-id>… — ticket 101's one open PR, its checks settled.
pr_red() {
  local pr="$1" head="$2" c rows="[]" name concl rid; shift 2
  for c in "$@"; do
    IFS=: read -r name concl rid <<<"$c"
    rows=$(jq -c --arg n "$name" --arg c "$concl" --arg r "$rid" \
      '. + [{name: $n, status: "COMPLETED", conclusion: $c, completedAt: "2026-11-01T10:00:00Z",
             detailsUrl: "https://github.com/acme/widgets/actions/runs/\($r)/job/1"}]' <<<"$rows")
  done
  jq -n --argjson n "$pr" --arg sha "$head" --argjson r "$rows" \
    '[{number: $n, headRefName: "tkt-101/work", headRefOid: $sha, baseRefName: "develop", isDraft: false,
       mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED", labels: [], statusCheckRollup: $r}]' > "$FIX/gh/prs-all.json"
  fix_required unit lint
  rm -f "$STATE/swarm/prs.json"
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
base_unreadable() { rm -f "$FIX/gh/api-repos_acme_widgets_commits_sha_develop_per_page_5.json"; }
# marks <kind…> — the PR's comments, oldest first: r a repair spawn, b a base-red note.
marks() {
  local k out="[]"
  for k in "$@"; do
    case "$k" in
      r) out=$(jq -c '. + [{body: "Repair started on mac for #101.\n<!-- harness:repair-spawn -->"}]' <<<"$out") ;;
      b) out=$(jq -c '. + [{body: "Not repaired: unit failed on develop too.\n<!-- harness:base-red -->"}]' <<<"$out") ;;
    esac
  done
  printf '%s\n' "$out" > "$FIX/gh/api-repos_acme_widgets_issues_71_comments.json"
}
fresh() { : > "$SPAWNS"; : > "$TRIED"; : > "$GH_LOG"; : > "$CLASSES"; marks; }
run() { OUT=$(bash "$W" --only repair 2>&1); }
spawns() { grep -c . "$SPAWNS"; }

echo "--- red only on a check the base fails too: no repair, it waits ---"
fresh; rm -f "$STATE/coordinator/base-red."*; pr_red 71 head1 unit:FAILURE:7001; base unit:failure
run
want "no repair is sent"                 "0" "$(spawns)"
want_in "  and it says it waits on the base" 'skip #71 \(101\): base-red on unit — waits for develop to go green' "$OUT"
want_in "  the PR is told, once"         'issues/71/comments -X POST -f body=Not repaired: unit failed on develop' "$(tr '\n' ' ' < "$GH_LOG")"
want "  and its rebuild count starts again here" "base-red" "$(cut -f3 "$CLASSES" | tail -1)"
: > "$GH_LOG"; run
want "a second pass posts nothing more"  "0" "$(grep -c 'comments -X POST' "$GH_LOG")"

echo "--- repaired twice already, and base-red: no rebuild either ---"
fresh; rm -f "$STATE/coordinator/base-red."*; marks r r
printf 'r1\t101\trepair\t1\nr2\t101\trepair\t2\n' > "$CLASSES"
printf '{}\n' > "$FIX/gh/api-repos_acme_widgets_git_refs.json"
pr_red 71 head2 unit:FAILURE:7002; base unit:failure
run
want "no repair"                         "0" "$(spawns)"
want "no rebuild: the PR is not closed"  "0" "$(grep -c 'pr close' "$GH_LOG")"
want_in "  it waits on the base"         'base-red on unit' "$OUT"
rm -f "$FIX/gh/api-repos_acme_widgets_git_refs.json"

echo "--- a red the base passes is the PR's own: repaired as before ---"
fresh; rm -f "$STATE/coordinator/base-red."*; pr_red 71 head3 unit:FAILURE:7003; base unit:success
run
want "the repair is sent"                "1" "$(spawns)"

echo "--- one red shared with the base, one the base passes: repaired ---"
fresh; rm -f "$STATE/coordinator/base-red."*; pr_red 71 head4 unit:FAILURE:7004 lint:FAILURE:7005; base unit:failure lint:success
run
want "the repair is sent"                "1" "$(spawns)"

echo "--- a base that cannot be read decides nothing: repaired as before ---"
fresh; rm -f "$STATE/coordinator/base-red."*; pr_red 71 head5 unit:FAILURE:7006; base_unreadable
run
want "the repair is sent"                "1" "$(spawns)"

echo "--- the base goes green: the waiting head's failed jobs are re-run once, before any repair ---"
fresh; rm -f "$STATE/coordinator/base-red."* "$STATE/coordinator/base-red-reruns."*
pr_red 71 head6 unit:FAILURE:7007; base unit:failure
run
want "base-red first: no repair"         "0" "$(spawns)"
base unit:success; : > "$GH_LOG"
run
want "the base green: no repair yet"     "0" "$(spawns)"
want "  its failed jobs are re-run"      "1" "$(grep -c '^run rerun 7007 --failed' "$GH_LOG")"
want_in "  and it says so"               'skip #71 \(101\): PR #71 waited on develop, which passes unit now — re-ran 7007' "$OUT"
: > "$GH_LOG"; run
want "still red after the re-run: now it is repaired" "1" "$(spawns)"
want "  and nothing is re-run again"     "0" "$(grep -c '^run rerun' "$GH_LOG")"

echo "--- a head never seen base-red is not re-run: repaired as before ---"
fresh; pr_red 71 head7 unit:FAILURE:7008; base unit:success
run
want "the repair is sent"                "1" "$(spawns)"
want "  nothing re-run"                  "0" "$(grep -c '^run rerun' "$GH_LOG")"

echo "--- repairs before a base-red note do not count toward a rebuild ---"
fresh; rm -f "$STATE/coordinator/base-red."*; marks r r b
printf 'r1\t101\trepair\t1\nr2\t101\trepair\t2\n-\t101\tbase-red\t3\n' > "$CLASSES"
printf '{}\n' > "$FIX/gh/api-repos_acme_widgets_git_refs.json"
pr_red 71 head8 unit:FAILURE:7009; base unit:success
run
want "repaired, not rebuilt"             "1" "$(spawns)"
want "  the PR is not closed"            "0" "$(grep -c 'pr close' "$GH_LOG")"
fresh; marks r r
printf 'r1\t101\trepair\t1\nr2\t101\trepair\t2\n' > "$CLASSES"
pr_red 71 head9 unit:FAILURE:7010; base unit:success
run
want "with no base-red note, two repairs still rebuild" "0" "$(spawns)"
want_in "  and it says so"               'repaired 2 times since it last started fresh — rebuilt' "$OUT"
rm -f "$FIX/gh/api-repos_acme_widgets_git_refs.json"

suite_end "$FAILED"
