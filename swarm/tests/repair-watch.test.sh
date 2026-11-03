#!/usr/bin/env bash
# repair-watch.test.sh — the watcher sends no agent to a red or clashing pull request:
# there is no repair (a PR that cannot merge is rebuilt fresh by the coordinator,
# scripts/rebuild.sh). What it still does: release blocked tickets, restart a run that
# died on the service, twice at most, and raise the stall alarm.
#
# The alarm is asserted the way it is read: it fires on a machine with work and no
# agents, it says which programme, and it closes itself when they run again.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
W="$HERE/../repair-watch.sh"
w() { bash "$W" "$@" 2>&1; }
T0=$(date -u +%s)
TRIED="$STATE/swarm/repair-attempts.tsv"
LOG="$STATE/logs/repair-watch.log"

fix_at "$T0"
fix_issue 101 OPEN "status:in-review,project:widgets"
fix_issue 102 OPEN "status:in-review,project:widgets"
fix_live widgets 0; fix_at "$T0"

echo "--- a red or clashing pull request gets no agent from the watcher ---"
fix_prs "11 101 aaaaaaaaaa1 CLEAN 0 typecheck" "12 102 bbbbbbbbbb1 DIRTY 0 -"
out=$(w)
want "no agent for either"             "0" "$(grep -c . "$SPAWNS")"
want "no attempt recorded"             "0" "$(cat "$TRIED" 2>/dev/null | grep -c .)"
want_not_in "and nothing says it repaired" 'spawned repair' "$out"
fix_prs

echo "--- unblock when every parent has closed ---"
: > "$SPAWNS"
fix_issue_list "status:blocked" '[{"number":301},{"number":302}]'
fix_issue 301 OPEN "status:blocked,project:widgets"
fix_comments 301 "Blocked until #401 and #402 merge"
fix_issue 401 CLOSED ""; fix_issue 402 CLOSED ""
fix_issue 302 OPEN "status:blocked,project:widgets"
fix_comments 302 "Blocked until #403 merges"
fix_issue 403 OPEN "status:ready"
# The list read carries each held ticket's comments, as GitHub answers --json number,comments.
fix_issue_list "status:blocked" "$(jq -s '[.[] | {number, comments}]' "$FIX/gh/issue-301.json" "$FIX/gh/issue-302.json")"
: > "$GH_LOG"
out=$(w --only unblock)
want_in "the ready one is released"    'unblocked #301' "$out"
want_in "and relabelled"               'issue edit 301 .*--remove-label status:blocked --add-label status:ready' "$(cat "$GH_LOG")"
want_not_in "the held one stays held"  'unblocked #302' "$out"
# The reads on their own are the released ticket's: the relabel's (issue-status.sh) and the queue's,
# for its priority as it goes back on (unblock-waiting.sh adds it --first).
want "two held tickets and three parents: no parent or held ticket read on its own" "2" "$(grep -c '^issue view' "$GH_LOG")"
want "and both reads are the released ticket's" "2" "$(grep -c '^issue view 301 ' "$GH_LOG")"
want "and every parent in one batched read" "1" "$(grep -c '^api graphql' "$GH_LOG")"

echo "--- a run that died on an infrastructure error is restarted, twice at most ---"
: > "$SPAWNS"; : > "$TRIED"
fix_live widgets 0; fix_done 105 12 "API Error: Connection refused" true; fix_at "$T0"
fix_issue 105 OPEN "status:in-review,project:widgets"
out=$(w --only infra)
want "it is restarted"                 "1" "$(grep -c . "$SPAWNS")"
want_in "with a resume brief"          'RESUME AFTER A CONNECTION OR SERVICE ERROR' "$(cat "$SPAWNS")"
: > "$SPAWNS"; w --only infra >/dev/null
want "a second restart is allowed"     "1" "$(grep -c . "$SPAWNS")"
: > "$SPAWNS"; out=$(w --only infra)
want "a third is not"                  "0" "$(grep -c . "$SPAWNS")"
want_in "and it says so"               'INFRA-STOP #105' "$out"

echo "--- a ticket that ended on its own work is NOT an infrastructure death ---"
: > "$SPAWNS"; : > "$TRIED"
fix_live widgets 0; fix_done 106 5 "Tests failed: 3 assertions"; fix_at "$T0"
fix_issue 106 OPEN "status:in-review,project:widgets"
w --only infra >/dev/null
want "left alone"                      "0" "$(grep -c . "$SPAWNS")"
# A report that QUOTES a service error is the run's own words, not a death.
: > "$SPAWNS"; : > "$TRIED"
fix_live widgets 0; fix_done 107 5 "Done. CI's critic said: API Error 529 overloaded" false; fix_at "$T0"
fix_issue 107 OPEN "status:in-review,project:widgets"
w --only infra >/dev/null
want "a quoted service error is left alone" "0" "$(grep -c . "$SPAWNS")"

echo "--- the stall alarm: work waiting, nothing running ---"
: > "$GH_LOG"; : > "$LOG"
rm -f "$FIX/live.json"; fix_live "" 0; fix_at "$T0"
fix_ready widgets 201 202
fix_prs                                  # no red PRs; the ready tickets are the work
fix_issue_list "$(printf 'swarm:stalled')" '[]'
out=$(w --only alarm)
want_not_in "the first quiet pass does not alarm" 'ALARM opened' "$out"
fix_at $(( T0 + 21*60 ))
out=$(w --only alarm)
want_in "after 20 minutes it does"     'ALARM opened' "$out"
want_in "the issue names the programme" 'No agent has run on widgets' "$(cat "$GH_LOG")"
want_in "and is labelled for the swarm" 'issue create .*--label swarm:stalled' "$(cat "$GH_LOG")"
# GRADED LIKE EVERYTHING ELSE AN AGENT FILES. A stopped swarm is a Critical on the
# harness's one scale, so the alarm carries the Critical priority — without it the
# alarm sorts below whatever the queue happened to be showing, which is the same as
# not raising it.
want_in "and carries the Critical priority" 'issue create .*--label P0' "$(cat "$GH_LOG")"

echo "--- the alarm closes itself when the agents run again ---"
: > "$GH_LOG"
fix_issue_list "swarm:stalled" '[{"number":900}]'
fix_live widgets 2; fix_at $(( T0 + 22*60 ))
out=$(w --only alarm)
want_in "it closes"                    'alarm closed #900' "$out"
want_in "with a comment"               'issue close 900 .*Running again' "$(cat "$GH_LOG")"

echo "--- a quiet machine with NO work waiting is not a stall ---"
: > "$GH_LOG"
fix_issue_list "status:ready" '[]'
fix_issue_list "swarm:stalled" '[]'
fix_live "" 0; fix_at $(( T0 + 60*60 ))
out=$(w --only alarm)
want_not_in "nothing is raised"        'ALARM opened' "$out"

echo "--- a silent agent raises the alarm on its own ---"
: > "$GH_LOG"
jq '.live = [{ticket:"207", title:"Ticket 207", project:"widgets", quietSec:2400, startedAgoMin:60, steps:[]}]' \
   "$FIX/live.json" > "$FIX/live.json.t" && mv "$FIX/live.json.t" "$FIX/live.json"
fix_at $(( T0 + 61*60 ))
out=$(w --only alarm)
want_in "it alarms"                    'ALARM opened' "$out"
want_in "naming the silence"           'Agent silent 20\+ min' "$(cat "$GH_LOG")"

echo "--- the live view missing raises it only on the SECOND miss ---"
: > "$GH_LOG"; rm -f "$STATE/swarm/live-view-missed"
fix_issue_list "swarm:stalled" '[]'
fix_live_down
out=$(w --only alarm)
want_not_in "one slow answer is not an outage" 'ALARM opened' "$out"
out=$(w --only alarm)
want_in "two in a row is"              'ALARM opened' "$out"
want_in "and says the view is down"    'The live view is not answering' "$(cat "$GH_LOG")"

suite_end "$FAILED"
