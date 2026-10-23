#!/usr/bin/env bash
# close-merged.test.sh — a PR merged into the integration branch closes every ticket it
# names with a closing keyword, whoever merged it; GitHub does that only on the default
# branch. "Refs" closes nothing, and a failed read changes nothing.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
CM="$HERE/close-merged.sh"
LIST="$FIX/gh/api-repos_acme_widgets_pulls_state_closed_base_develop_sort_updated_direction_desc_per_page_100.json"
CD="$STATE/coordinator"; mkdir -p "$CD"
api_issue() { # <n> <open|closed> <label,label…> [pr]
  jq -n --argjson n "$1" --arg s "$2" --arg l "$3" --arg pr "${4:-}" \
    '{number:$n, state:$s, labels:($l|split(",")|map(select(length>0)|{name:.}))} + (if $pr == "" then {} else {pull_request:{}} end)' \
    > "$FIX/gh/api-repos_acme_widgets_issues_$1.json"
}
pr() { # <n> <merged_at|null> <merged_by> <body> [base]
  jq -n --argjson n "$1" --arg m "$2" --arg by "$3" --arg b "$4" --arg base "${5:-develop}" \
    '{number:$n, merged_at:(if $m == "null" then null else $m end), merged_by:{login:$by}, body:$b, base:{ref:$base}}'
}
run() { bash "$CM" "$@" 2>&1; }

echo "--- a PR merged into develop by a person closes the ticket its Fixes line names ---"
{ pr 41 2026-10-22T15:00:00Z dom "Hand-merged past CI.

Fixes #501"
  pr 42 2026-10-22T15:01:00Z github-actions[bot] "Refs #502"
  pr 43 2026-10-22T15:02:00Z dom "closes: https://github.com/acme/widgets/issues/503 and RESOLVED acme/widgets#504"
  pr 44 2026-10-22T15:03:00Z dom "Closes #505" main
  pr 45 null dom "Closes #506"
  pr 46 2026-10-22T15:04:00Z dom "Fixes #507 (already closed), fixes #508 (a polish list), fixes #509 (a PR), Closes #5100"
} | jq -s . > "$LIST"
api_issue 501 open "status:ready,P1,status:pm-decision,area:OPS"
api_issue 502 open "status:ready"
api_issue 503 open "status:in-review"
api_issue 504 open "status:parked"
api_issue 505 open "status:ready"
api_issue 506 open "status:ready"
api_issue 507 closed ""
api_issue 508 open "polish-list,status:ready"
api_issue 509 open "" pr
api_issue 5100 open "status:claimed"
printf '{"tickets":[{"n":501,"class":"new"},{"n":502,"class":"new"},{"n":503,"class":"new"}]}\n' > "$CD/queue.json"
echo 2026-10-22T14:00:00Z > "$CD/close-merged.hwm"
: > "$GH_LOG"
out=$(run); rc=$?
want "the pass succeeds"                          0 "$rc"
log=$(cat "$GH_LOG")
want_in "#501 is closed"                          '^issue close 501 .*--reason completed' "$log"
want_in "with one comment naming the PR and the branch" '^issue comment 501 .*Closed by #41, merged to develop\.' "$log"
want "and only one"                               1 "$(grep -c '^issue comment 501 ' <<<"$log")"
want_in "its status labels come off"              '^issue edit 501 .*--remove-label status:ready.*--remove-label status:pm-decision' "$log"
want_not_in "its other labels stay"               '^issue edit 501 .*--remove-label (P1|area:OPS)' "$log"
want "closed tickets leave the coordinator's queue" "502" "$(jq -r '[.tickets[].n | tostring] | join(",")' "$CD/queue.json")"
want_not_in "Refs #502 closes nothing"            '^issue (close|comment|edit) 502 ' "$log"
want_in "a full issue URL closes #503"            '^issue close 503 ' "$log"
want_in "owner/repo#N with RESOLVED closes #504"  '^issue close 504 ' "$log"
want_not_in "a PR into another branch closes nothing" '^issue (close|comment) 505 ' "$log"
want_not_in "a PR closed unmerged closes nothing" '^issue (close|comment) 506 ' "$log"
want_not_in "a closed ticket is not touched"      '^issue (close|comment|edit) 507 ' "$log"
want_not_in "a polish list is left to its sweep"  '^issue (close|comment|edit) 508 ' "$log"
want_not_in "a PR named by number is not closed"  '^issue (close|comment|edit) 509 ' "$log"
want_in "#5100 is read whole, not as #510"        '^issue close 5100 ' "$log"
want "the mark moves to the newest merge"         2026-10-22T15:04:00Z "$(cat "$CD/close-merged.hwm")"

echo "--- the next pass reads nothing it already handled ---"
: > "$GH_LOG"
run >/dev/null; want_not_in "nothing is closed twice" '^issue (close|comment)' "$(cat "$GH_LOG")"

echo "--- a failed list read changes nothing ---"
mv "$LIST" "$LIST.away"; echo 2026-10-22T14:00:00Z > "$CD/close-merged.hwm"; : > "$GH_LOG"
out=$(run); rc=$?
want "it fails"                                   1 "$rc"
want_in "and says the merged PRs were unknown"    'unknown — the PRs merged into develop could not be read' "$out"
want_not_in "nothing is written"                  '^issue (close|comment|edit)' "$(cat "$GH_LOG")"
want "the mark stays"                             2026-10-22T14:00:00Z "$(cat "$CD/close-merged.hwm")"
mv "$LIST.away" "$LIST"

echo "--- a failed ticket read closes nothing and holds the mark before its PR ---"
pr 47 2026-10-22T16:00:00Z dom "Fixes #511" | jq -s . > "$LIST"
echo 2026-10-22T15:30:00Z > "$CD/close-merged.hwm"; rm -f "$FIX/gh/api-repos_acme_widgets_issues_511.json"
printf '#!/usr/bin/env bash\ncase "$*" in *issues/511*) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$BIN/gh" > "$BIN/gh-flaky"; chmod +x "$BIN/gh-flaky"
: > "$GH_LOG"
out=$(SWARM_GH="$BIN/gh-flaky" run); rc=$?
want "it fails"                                   1 "$rc"
want_not_in "#511 is not closed"                  '^issue (close|comment|edit) 511' "$(cat "$GH_LOG")"
want "the mark sits one second before the PR"     2026-10-22T15:59:59Z "$(cat "$CD/close-merged.hwm")"
api_issue 511 open "status:ready"; : > "$GH_LOG"
run >/dev/null
want_in "the next pass closes it"                 '^issue close 511 ' "$(cat "$GH_LOG")"

echo "--- a dry run writes nothing ---"
pr 48 2026-10-22T17:00:00Z dom "Fixes #512" | jq -s . > "$LIST"; api_issue 512 open "status:ready"
echo 2026-10-22T16:30:00Z > "$CD/close-merged.hwm"; : > "$GH_LOG"
out=$(run --dry-run)
want_in "it says what it would close"             'would close #512 — PR #48' "$out"
want_not_in "and writes nothing"                  '^issue (close|comment|edit)' "$(cat "$GH_LOG")"
want "nor moves the mark"                         2026-10-22T16:30:00Z "$(cat "$CD/close-merged.hwm")"

echo "--- housekeeping runs it every pass, before reconcile, in shadow as a dry run ---"
HK="$HERE/coordinator-housekeeping.sh"; ORDER="$FIX/order.log"
for s in closemerged reconcile sweep wtsweep judge lane keepfresh polish critic; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "$s" "$ORDER" > "$BIN/$s"; chmod +x "$BIN/$s"
done
hk() { : > "$ORDER"
  COORDINATOR_SHADOW="$1" COORDINATOR_CLOSE_MERGED="$BIN/closemerged" COORDINATOR_RECONCILE="$BIN/reconcile" \
  COORDINATOR_SWEEP="$BIN/sweep" COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep" COORDINATOR_JUDGE="$BIN/judge" \
  COORDINATOR_LANE="$BIN/lane" COORDINATOR_KEEP_FRESH="$BIN/keepfresh" COORDINATOR_POLISH_LIST="$BIN/polish" \
  COORDINATOR_CRITIC_JUDGE="$BIN/critic" COORDINATOR_SHARED_INSTALL=off COORDINATOR_STRANDED_SWEEP=off \
  COORDINATOR_NOTIFY_CMD=true COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 bash "$HK" >/dev/null 2>&1
  grep -E '^(closemerged|reconcile) ' "$ORDER" | tr '\n' '|'; }
want "a live pass closes merged tickets, then reconciles" "closemerged |reconcile --quiet|" "$(hk 0)"
want "a shadow pass dry-runs it, then reconciles dry"     "closemerged --dry-run|reconcile --dry-run --quiet|" "$(hk 1)"

suite_end "$FAILED"
