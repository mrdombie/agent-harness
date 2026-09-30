#!/usr/bin/env bash
# repair-watch.test.sh — the watcher's job is to send exactly one agent to a
# broken pull request and then to STOP. So what this asserts is the stopping:
# one attempt per head commit, three attempts a day, and a stop that survives
# the window rolling because it is a label rather than a count.
#
# The alarm is asserted the same way: it fires on a machine with work and no
# agents, it says which programme, and it closes itself when they run again.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
W="$HERE/../repair-watch.sh"
w() { bash "$W" "$@" 2>&1; }
T0=$(date -u +%s)
TRIED="$STATE/swarm/repair-attempts.tsv"
LOG="$STATE/logs/repair-watch.log"

fix_at "$T0"
fix_issue 101 OPEN "status:in-review,project:widgets"
fix_issue 102 OPEN "status:in-review,project:widgets"
fix_live widgets 0; fix_at "$T0"

echo "--- CI settled red gets one agent ---"
fix_prs "11 101 aaaaaaaaaa1 CLEAN 0 typecheck"
out=$(w --only repair)
want "one spawn"                       "1" "$(grep -c . "$SPAWNS")"
want_in "for the right ticket"         '^101' "$(cat "$SPAWNS")"
want_in "the brief names the failure"  'CI went red on: typecheck' "$(cat "$SPAWNS")"
want_in "and it is logged"             'spawned repair for #11 \(101\)' "$out"

echo "--- the same head commit is never repaired twice ---"
: > "$SPAWNS"
out=$(w --only repair)
want "nothing spawned"                 "0" "$(grep -c . "$SPAWNS")"

echo "--- checks still running are not a failure ---"
: > "$SPAWNS"
fix_prs "12 102 bbbbbbbbbb1 CLEAN 2 typecheck"
w --only repair >/dev/null
want "a pending check waits"           "0" "$(grep -c . "$SPAWNS")"

echo "--- a clash is a separate kind, on the same head commit ---"
: > "$SPAWNS"
fix_prs "11 101 aaaaaaaaaa1 DIRTY 0 -"
out=$(w --only repair)
want "the clash still gets an agent"   "1" "$(grep -c . "$SPAWNS")"
want_in "and says so"                  'clashes with develop' "$out"

echo "--- a healthy pull request is left alone ---"
: > "$SPAWNS"
fix_prs "13 102 ccccccccc1 CLEAN 0 -"
w --only repair >/dev/null
want "nothing to repair"               "0" "$(grep -c . "$SPAWNS")"

echo "--- busy machine: it holds, and does not spend the one attempt ---"
: > "$SPAWNS"; : > "$TRIED"
fix_live widgets 3; fix_at "$T0"
fix_prs "11 101 ddddddddd1 DIRTY 0 -"
out=$(w --only repair)
want "nothing spawned at the cap"      "0" "$(grep -c . "$SPAWNS")"
want_in "and the hold names it"        'hold #11 \(101\).*machine busy \(agents 3, cap 3\)' "$out"
want "no attempt was recorded"         "0" "$(grep -c . "$TRIED")"
fix_live widgets 0; fix_at "$T0"

echo "--- a red trunk holds CI repairs, and spends no attempt ---"
: > "$SPAWNS"; : > "$TRIED"
fix_trunk red
fix_prs "11 101 fffffffff1 CLEAN 0 typecheck"
out=$(w --only repair)
want "no agent while develop is red"   "0" "$(grep -c . "$SPAWNS")"
want "no attempt was recorded"         "0" "$(grep -c . "$TRIED")"
want_in "and it says why"              'develop is red \(build\)' "$out"

echo "--- a clash is still repaired while the trunk is red ---"
fix_prs "11 101 fffffffff1 DIRTY 0 -"
w --only repair >/dev/null
want "the clash gets its agent"        "1" "$(grep -c . "$SPAWNS")"

echo "--- an unreadable trunk holds, like a red one ---"
: > "$SPAWNS"; : > "$TRIED"
fix_trunk unreadable
fix_prs "11 101 fffffffff1 CLEAN 0 typecheck"
w --only repair >/dev/null
want "no agent when it cannot tell"    "0" "$(grep -c . "$SPAWNS")"

echo "--- once develop is green the same head commit IS repaired ---"
fix_trunk green
w --only repair >/dev/null
want "the held repair now runs"        "1" "$(grep -c . "$SPAWNS")"
: > "$SPAWNS"; : > "$TRIED"

echo "--- three repairs in a day: the stop is a LABEL, not a count ---"
: > "$SPAWNS"
for s in s1 s2 s3; do printf '101\t%s\tci\t%s\n' "$s" "$T0" >> "$TRIED"; done
fix_prs "11 101 eeeeeeeee1 CLEAN 0 typecheck"
out=$(w --only repair)
want "no fourth agent"                 "0" "$(grep -c . "$SPAWNS")"
want_in "it is handed to a person"     'issue edit 101 .*--add-label status:needs-human' "$(cat "$GH_LOG")"
want_in "with a comment saying why"    'Stopped after 3 repairs in 24 hours' "$(cat "$GH_LOG")"
want_in "and the stop is logged"       'STOP #11 \(101\)' "$out"

echo "--- and the stop STICKS once the 24h window has rolled ---"
# The window is what used to expire; the label is what must not. Clear every
# attempt, move a day on, and the ticket must still be left alone.
: > "$TRIED"; : > "$SPAWNS"
fix_issue 101 OPEN "status:needs-human,project:widgets"
fix_at $(( T0 + 86400 + 60 )); fix_live widgets 0; fix_at $(( T0 + 86400 + 60 ))
fix_prs "11 101 fffffffff1 CLEAN 0 typecheck"
w --only repair >/dev/null
want "still no agent, a day later"     "0" "$(grep -c . "$SPAWNS")"
fix_issue 101 OPEN "status:in-review,project:widgets"
fix_at "$T0"

echo "--- unblock when every parent has closed ---"
: > "$SPAWNS"
fix_issue_list "status:blocked" '[{"number":301},{"number":302}]'
fix_issue 301 OPEN "status:blocked,project:widgets"
fix_comments 301 "Blocked until #401 and #402 merge"
fix_issue 401 CLOSED ""; fix_issue 402 CLOSED ""
fix_issue 302 OPEN "status:blocked,project:widgets"
fix_comments 302 "Blocked until #403 merges"
fix_issue 403 OPEN "status:ready"
out=$(w --only unblock)
want_in "the ready one is released"    'unblocked #301' "$out"
want_in "and relabelled"               'issue edit 301 .*--remove-label status:blocked --add-label status:ready' "$(cat "$GH_LOG")"
want_not_in "the held one stays held"  'unblocked #302' "$out"

echo "--- a run that died on an infrastructure error is restarted, twice at most ---"
: > "$SPAWNS"; : > "$TRIED"
fix_live widgets 0; fix_done 105 12 "API Error: Connection refused"; fix_at "$T0"
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

echo "--- --explain changes nothing ---"
: > "$GH_LOG"; : > "$SPAWNS"; : > "$TRIED"
fix_live widgets 0; fix_at "$T0"
fix_prs "11 101 99999999991 CLEAN 0 typecheck"
out=$(w --only repair --explain)
want_in "it says what it would do"     'WOULD repair #11' "$out"
want "but spawns nothing"              "0" "$(grep -c . "$SPAWNS")"
want "and records no attempt"          "0" "$(grep -c . "$TRIED")"

exit $FAILED
