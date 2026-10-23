#!/usr/bin/env bash
# close-merged.test.sh — a PR merged into the integration branch closes every ticket it
# names with a closing keyword, whoever merged it; GitHub does that only on the default
# branch. "Refs" closes nothing, a failed read changes nothing, and a ticket another open
# PR still names stays open until the last of its PRs merges.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
CM="$HERE/close-merged.sh"
LIST="$FIX/gh/api-repos_acme_widgets_pulls_state_closed_base_develop_sort_updated_direction_desc_per_page_100.json"
OPEN="$FIX/gh/api-repos_acme_widgets_pulls_state_open_per_page_100_page_1.json"
echo '[]' > "$OPEN"   # no open PRs: a merge is the whole of its tickets' work
CD="$STATE/coordinator"; mkdir -p "$CD"
api_issue() { # <n> <open|closed> <label,label…> [pr] [body]
  jq -n --argjson n "$1" --arg s "$2" --arg l "$3" --arg pr "${4:-}" --arg b "${5:-}" \
    '{number:$n, state:$s, body:$b, labels:($l|split(",")|map(select(length>0)|{name:.}))} + (if $pr == "" then {} else {pull_request:{}} end)' \
    > "$FIX/gh/api-repos_acme_widgets_issues_$1.json"
}
pr() { # <n> <merged_at|null> <merged_by> <body> [base] [title]
  jq -n --argjson n "$1" --arg m "$2" --arg by "$3" --arg b "$4" --arg base "${5:-develop}" --arg t "${6:-}" \
    '{number:$n, title:$t, merged_at:(if $m == "null" then null else $m end), merged_by:{login:$by}, body:$b, base:{ref:$base}}'
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

echo "--- a merged \"parked — \" PR closes nothing: each named ticket is told to check its acceptance ---"
# 23 Oct: #13565 "#13477: parked — …" merged under merge-first with auto-merge armed, and
# its "Closes" closed a batch ticket with 5 of its 6 children half done.
pr 60 2026-10-22T18:00:00Z dom "Parked mid-run.

Closes #520" develop "#520: parked — the build step ran out of turns" | jq -s . > "$LIST"
api_issue 520 open "status:in-review"
echo 2026-10-22T17:30:00Z > "$CD/close-merged.hwm"; : > "$GH_LOG"
out=$(run); rc=$?
want "the pass succeeds"                          0 "$rc"
log=$(cat "$GH_LOG")
want_not_in "the parked PR closes nothing"        '^issue (close|edit) 520 ' "$log"
want_in "it comments on the ticket instead"       "^issue comment 520 .*Merged by #60, a parked run; check this ticket's acceptance before closing\." "$log"
want "and only once"                              1 "$(grep -c '^issue comment 520 ' <<<"$log")"
want "the mark moves past it"                     2026-10-22T18:00:00Z "$(cat "$CD/close-merged.hwm")"
: > "$GH_LOG"; echo 2026-10-22T17:30:00Z > "$CD/close-merged.hwm"; run >/dev/null
want_not_in "a re-read pass comments no second time" '^issue comment 520 ' "$(cat "$GH_LOG")"

echo "--- a WIP title is the same ---"
pr 61 2026-10-22T18:10:00Z dom "Fixes #521" develop "WIP: half a migration" | jq -s . > "$LIST"
api_issue 521 open "status:in-review"
echo 2026-10-22T18:05:00Z > "$CD/close-merged.hwm"; : > "$GH_LOG"; run >/dev/null
want_not_in "a WIP PR closes nothing"             '^issue close 521 ' "$(cat "$GH_LOG")"
want_in "and comments"                            '^issue comment 521 .*Merged by #61, a parked run' "$(cat "$GH_LOG")"

echo "--- a batch PR closes nothing, and its batched children come back to ready ---"
pr 62 2026-10-22T18:20:00Z dom "Closes #530" develop "#530: settings polish batch" | jq -s . > "$LIST"
api_issue 530 open "status:in-review" "" "Batch of small settings fixes.

**Children (3):** #531, #532, #533"
api_issue 531 open "status:ready,status:batched,P2"
api_issue 532 open "status:batched"
api_issue 533 closed "status:batched"
for n in 531 532 533; do
  jq '{number, state:(.state | ascii_upcase), labels}' "$FIX/gh/api-repos_acme_widgets_issues_$n.json" > "$FIX/gh/issue-$n.json"
done
echo 2026-10-22T18:15:00Z > "$CD/close-merged.hwm"; : > "$GH_LOG"
out=$(SWARM_GH="$BIN/gh-labels" run); rc=$?
want "the pass succeeds"                          0 "$rc"
log=$(cat "$GH_LOG")
want_not_in "the batch ticket is not closed"      '^issue close 530 ' "$log"
want_in "it is told to check its acceptance"      "^issue comment 530 .*Merged by #62, a batch run; check this ticket's acceptance before closing\." "$log"
want "child #531 is ready and no longer batched"  "status:ready,P2" "$(jq -r '[.labels[].name] | join(",")' "$FIX/gh/issue-531.json")"
want "child #532 is ready"                        "status:ready" "$(jq -r '[.labels[].name] | join(",")' "$FIX/gh/issue-532.json")"
want_in "with the same comment"                   "^issue comment 532 .*Merged by #62, a batch run; check this ticket's acceptance" "$log"
want_not_in "a closed child is not touched"       '^issue (comment|edit|close) 533 ' "$log"
want_not_in "no child is closed"                  '^issue close 53[123] ' "$log"

echo "--- one merge is not the whole ticket: another open PR naming it keeps it open ---"
# 23 Oct: a consuming project's #13006 closed when its docs PR #13016 merged, with build PR #13073
# (branch sh-13006/…) still open; #12831 closed with two criteria in open PR #12847.
pr 80 2026-10-22T19:00:00Z dom "Docs half.

Closes #540" | jq -s . > "$LIST"
api_issue 540 open "status:in-review,P1"
openpr() { # <n> <branch> <body>
  jq -n --argjson n "$1" --arg h "$2" --arg b "$3" '{number:$n, head:{ref:$h}, body:$b, state:"open"}'; }
{ openpr 81 tkt-540/build "The build half."
  openpr 82 other/work "Part of #540"
  openpr 83 other/refs "Refs #540"
  openpr 84 other/near "Closes #5400 and fixes #54"
  openpr 85 tkt-5401/x "" ; } | jq -s . > "$OPEN"
printf '{"tickets":[{"n":540,"class":"new"}]}\n' > "$CD/queue.json"
echo 2026-10-22T18:30:00Z > "$CD/close-merged.hwm"; : > "$GH_LOG"
out=$(run); rc=$?
want "the pass succeeds"                          0 "$rc"
log=$(cat "$GH_LOG")
want_not_in "the ticket is not closed"            '^issue (close|edit) 540 ' "$log"
want_in "a PR on the ticket's branch is its work" '^issue comment 540 .*Merged #80; #81 is still open for this ticket\.' "$log"
want_in "so is one saying Part of"                '^issue comment 540 .*Merged #80; #82 is still open for this ticket\.' "$log"
want "one comment a pair, nothing else"           2 "$(grep -c '^issue comment 540 ' <<<"$log")"
want_not_in "Refs is no claim on the ticket"      'Merged #80; #83' "$log"
want_not_in "#5400, #54 and tkt-5401 are other tickets" 'Merged #80; #8[45]' "$log"
want_in "it says why"                             'left open #540 — PR #80 merged; #81 #82 still open' "$out"
want "it stays on the queue"                      "540" "$(jq -r '[.tickets[].n | tostring] | join(",")' "$CD/queue.json")"
want "the mark moves past the PR"                 2026-10-22T19:00:00Z "$(cat "$CD/close-merged.hwm")"
: > "$GH_LOG"; echo 2026-10-22T18:30:00Z > "$CD/close-merged.hwm"; run >/dev/null
want_not_in "a re-read pass comments no second time" '^issue (comment|close) 540 ' "$(cat "$GH_LOG")"

echo "--- the second merge, with a third PR still open, still leaves it open ---"
pr 81 2026-10-22T19:10:00Z dom "The build half." | jq -s . > "$LIST"
{ openpr 82 other/work "Part of #540"; openpr 83 other/refs "Refs #540"; } | jq -s . > "$OPEN"
echo 2026-10-22T19:05:00Z > "$CD/close-merged.hwm"; : > "$GH_LOG"
run >/dev/null
want_not_in "not closed while #82 is open"        '^issue close 540 ' "$(cat "$GH_LOG")"

echo "--- the last merge closes it, whichever PR it was ---"
pr 82 2026-10-22T19:20:00Z dom "Part of #540" | jq -s . > "$LIST"
{ openpr 83 other/refs "Refs #540"; } | jq -s . > "$OPEN"
echo 2026-10-22T19:15:00Z > "$CD/close-merged.hwm"; : > "$GH_LOG"
out=$(run); rc=$?
want "the pass succeeds"                          0 "$rc"
log=$(cat "$GH_LOG")
want_in "the ticket closes"                       '^issue close 540 .*--reason completed' "$log"
want_in "saying no open PR names it any more"     '^issue comment 540 .*Closed: #80 merged to develop, and no open pull request names this ticket any more\.' "$log"
want_in "its status labels come off"              '^issue edit 540 .*--remove-label status:in-review' "$log"
want "it leaves the queue"                        "" "$(jq -r '[.tickets[].n | tostring] | join(",")' "$CD/queue.json")"
want "and stops waiting"                          "" "$(grep '^540 ' "$CD/close-merged.waiting" 2>/dev/null)"
: > "$GH_LOG"; run >/dev/null
want_not_in "it is closed once"                   '^issue (close|comment) 540 ' "$(cat "$GH_LOG")"

echo "--- the other PR merging with its own Closes line closes it on that merge ---"
pr 90 2026-10-22T20:00:00Z dom "Closes #545" | jq -s . > "$LIST"; api_issue 545 open "status:in-review"
openpr 91 tkt-545/rest "Closes #545" | jq -s . > "$OPEN"
echo 2026-10-22T19:55:00Z > "$CD/close-merged.hwm"; : > "$GH_LOG"; run >/dev/null
want_not_in "the first merge leaves it open"      '^issue close 545 ' "$(cat "$GH_LOG")"
{ pr 90 2026-10-22T20:00:00Z dom "Closes #545"; pr 91 2026-10-22T20:10:00Z dom "Closes #545"; } | jq -s . > "$LIST"
echo '[]' > "$OPEN"; echo 2026-10-22T20:05:00Z > "$CD/close-merged.hwm"; : > "$GH_LOG"; run >/dev/null
want_in "the second closes it"                    '^issue comment 545 .*Closed by #91, merged to develop\.' "$(cat "$GH_LOG")"
want "once"                                       1 "$(grep -c '^issue close 545 ' "$GH_LOG")"

echo "--- a waiting ticket whose last PR was a parked run is not closed by the wait ---"
pr 95 2026-10-22T20:20:00Z dom "Closes #547" | jq -s . > "$LIST"; api_issue 547 open "status:in-review"
openpr 96 tkt-547/rest "Closes #547" | jq -s . > "$OPEN"
echo 2026-10-22T20:15:00Z > "$CD/close-merged.hwm"; run >/dev/null
pr 96 2026-10-22T20:30:00Z dom "Closes #547" develop "#547: parked — out of turns" | jq -s . > "$LIST"
echo '[]' > "$OPEN"; echo 2026-10-22T20:25:00Z > "$CD/close-merged.hwm"; : > "$GH_LOG"; run >/dev/null
want_not_in "the parked merge leaves it open"     '^issue close 547 ' "$(cat "$GH_LOG")"
want_in "asking for its acceptance to be checked" "^issue comment 547 .*Merged by #96, a parked run" "$(cat "$GH_LOG")"
: > "$GH_LOG"; run >/dev/null
want_not_in "and no later pass closes it"         '^issue close 547 ' "$(cat "$GH_LOG")"

echo "--- open PRs that cannot be read close nothing and hold the mark ---"
pr 92 2026-10-22T21:00:00Z dom "Fixes #546" | jq -s . > "$LIST"; api_issue 546 open "status:ready"
mv "$OPEN" "$OPEN.away"; echo 2026-10-22T20:30:00Z > "$CD/close-merged.hwm"; : > "$GH_LOG"
out=$(run); rc=$?
want "it fails"                                   1 "$rc"
want_not_in "#546 is not closed"                  '^issue (close|comment|edit) 546 ' "$(cat "$GH_LOG")"
want "the mark sits before the PR"                2026-10-22T20:59:59Z "$(cat "$CD/close-merged.hwm")"
echo 'not json' > "$OPEN"; : > "$GH_LOG"; run >/dev/null
want_not_in "nor does an answer that is not a list" '^issue close 546 ' "$(cat "$GH_LOG")"
: > "$OPEN"; : > "$GH_LOG"; run >/dev/null
want_not_in "nor an empty answer"                 '^issue close 546 ' "$(cat "$GH_LOG")"
echo '[]' > "$OPEN"; rm -f "$OPEN.away"; : > "$GH_LOG"; run >/dev/null
want_in "read again, it closes"                   '^issue close 546 ' "$(cat "$GH_LOG")"

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
