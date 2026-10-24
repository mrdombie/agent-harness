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
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
W="$HERE/../repair-watch.sh"
# Each case repairs the same tickets again: the rebuild after two repairs (repair-gate.sh) has its own cases.
export COORDINATOR_REBUILD_AFTER_REPAIRS=0
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
want "its first line is sign-off comes last" "$(head -1 "$HERE/../../shared/signoff-last.md")" "$(head -1 "$STATE/swarm/briefs/repair-101.md")"
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
: > "$SPAWNS"; : > "$TRIED"
fix_prs "11 101 ddddddddd1 DIRTY 0 -"
out=$(SWARM_IDLE=7 w --only repair)
want "nothing spawned under the idle floor" "0" "$(grep -c . "$SPAWNS")"
want_in "and the hold names the idle"  'hold #11 \(101\).*machine busy \(cpu idle 7%, floor 15%\)' "$out"
want "no attempt was recorded"         "0" "$(grep -c . "$TRIED")"
fix_at "$T0"

echo "--- a parked draft the driver made is repaired when it clashes, or once its park clears ---"
# 23 Oct: 11 of 17 clashing PRs were parked drafts; drafts were never read here.
cat > "$BIN/pstop" <<'SH'
#!/usr/bin/env bash
case "$2" in 17) echo "a person (pm) put PR #17 back to draft on 2026-10-22"; exit 0 ;; esac
exit 1
SH
chmod +x "$BIN/pstop"; export OPEN_WORK_PERSON_STOP="$BIN/pstop" OPEN_WORK_DRAFTED_CACHE="$FIX/pdrafted.tsv"
as_draft() { jq --argjson n "$1" 'map(if .number == $n then .isDraft = true | .updatedAt = "2026-10-23T08:00:00Z" else . end)' "$FIX/gh/prs-all.json" > "$FIX/p.json" && mv "$FIX/p.json" "$FIX/gh/prs-all.json"; }
fix_issue 103 OPEN "status:parked,project:widgets"
fix_issue 104 OPEN "status:in-review,project:widgets"
fix_issue 105 OPEN "status:parked,project:widgets"
fix_issue 106 OPEN "status:in-review,project:widgets"
: > "$SPAWNS"; : > "$TRIED"; rm -f "$STATE/swarm/prs.json"
fix_prs "15 103 a15a15a15a1 DIRTY 0 -"; as_draft 15
out=$(w --only repair)
want_in "a parked driver draft that clashes gets its repair" '^103' "$(cat "$SPAWNS")"
want_in "and says it clashes"           'spawned repair for #15 \(103\).*clashes with develop' "$out"
: > "$SPAWNS"; : > "$TRIED"; rm -f "$STATE/swarm/prs.json"
fix_prs "16 105 a16a16a16a1 CLEAN 0 typecheck"; as_draft 16
w --only repair >/dev/null
want "a draft still parked, not clashing, waits for its park" "0" "$(grep -c . "$SPAWNS")"
: > "$SPAWNS"; : > "$TRIED"; rm -f "$STATE/swarm/prs.json"
fix_prs "18 104 a18a18a18a1 CLEAN 0 -"; as_draft 18
out=$(w --only repair)
want_in "a driver draft whose park cleared gets its repair" '^104' "$(cat "$SPAWNS")"
: > "$SPAWNS"; : > "$TRIED"; rm -f "$STATE/swarm/prs.json"
fix_prs "17 106 a17a17a17a1 DIRTY 0 -"; as_draft 17
w --only repair >/dev/null
want "a draft a person made is never repaired, clash or not" "0" "$(grep -c . "$SPAWNS")"
: > "$SPAWNS"; : > "$TRIED"; rm -f "$STATE/swarm/prs.json"
fix_prs "19 106 a19a19a19a1 DIRTY 0 -"
jq 'map(.labels = [{name: "do-not-merge"}])' "$FIX/gh/prs-all.json" > "$FIX/p.json" && mv "$FIX/p.json" "$FIX/gh/prs-all.json"
w --only repair >/dev/null
want "nor one carrying do-not-merge"     "0" "$(grep -c . "$SPAWNS")"
: > "$SPAWNS"; : > "$TRIED"; rm -f "$STATE/swarm/prs.json"
fix_prs "20 106 a20a20a20a1 DIRTY 0 -"
jq 'map(.headRefName = "106/fill-gaps")' "$FIX/gh/prs-all.json" > "$FIX/p.json" && mv "$FIX/p.json" "$FIX/gh/prs-all.json"
out=$(w --only repair)
want_in "a bare-number branch is its ticket's PR too" '^106' "$(cat "$SPAWNS")"
: > "$SPAWNS"; : > "$TRIED"; rm -f "$STATE/swarm/prs.json"

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

echo "--- a commit status is read by its state, not as a check run ---"
fix_prs "14 102 a14a14a14a1 CLEAN 0 typecheck"; fix_pr_status 14 "Design critic" SUCCESS
w --only repair >/dev/null
want "a green status does not hold a red PR" "1" "$(grep -c . "$SPAWNS")"
: > "$SPAWNS"; : > "$TRIED"
fix_prs "14 102 b14b14b14b1 CLEAN 0 -"; fix_pr_status 14 "Design critic" FAILURE
w --only repair >/dev/null
want "a failed status is red"              "1" "$(grep -c . "$SPAWNS")"
want_in "and names the status"             'CI went red on: Design critic' "$(cat "$SPAWNS")"
: > "$SPAWNS"; : > "$TRIED"
fix_prs "14 102 c14c14c14c1 CLEAN 0 typecheck"; fix_pr_status 14 "Design critic" PENDING
fix_required typecheck   # the design status is not one develop requires
w --only repair >/dev/null
want "a pending status does not hold a real red back" "1" "$(grep -c . "$SPAWNS")"
want_in "and only the real failure is named"  'CI went red on: typecheck[^;]' "$(cat "$SPAWNS")"
: > "$SPAWNS"; : > "$TRIED"
fix_prs "14 102 d14d14d14d1 CLEAN 0 -"; fix_pr_status 14 "Design critic" PENDING
w --only repair >/dev/null
want "a pending status alone is not red"   "0" "$(grep -c . "$SPAWNS")"
: > "$SPAWNS"; : > "$TRIED"

echo "--- each check is read by its NEWEST run, not any run ---"
fix_prs "15 102 a15a15a15a1 CLEAN 0 -"
fix_pr_run 15 typecheck COMPLETED FAILURE 2026-10-21T08:00:00Z
fix_pr_run 15 typecheck COMPLETED SUCCESS 2026-10-21T10:00:00Z
w --only repair >/dev/null
want "a failure that passed on re-run is not red" "0" "$(grep -c . "$SPAWNS")"
: > "$SPAWNS"; : > "$TRIED"
fix_prs "15 102 b15b15b15b1 CLEAN 0 -"
fix_pr_run 15 typecheck COMPLETED SUCCESS 2026-10-21T08:00:00Z
fix_pr_run 15 typecheck COMPLETED FAILURE 2026-10-21T10:00:00Z
w --only repair >/dev/null
want "a check that failed on its newest run is red" "1" "$(grep -c . "$SPAWNS")"
want_in "and is named once"            'CI went red on: typecheck$' "$(grep -o 'CI went red on: [^.]*' "$STATE/swarm/briefs/repair-102.md" | head -1)"
: > "$SPAWNS"; : > "$TRIED"
fix_prs "15 102 c15c15c15c1 CLEAN 0 -"
fix_pr_run 15 typecheck COMPLETED FAILURE 2026-10-21T08:00:00Z
fix_pr_run 15 typecheck IN_PROGRESS - 2026-10-21T10:00:00Z
w --only repair >/dev/null
want "a failure being re-run waits for the re-run" "0" "$(grep -c . "$SPAWNS")"
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
# The list read carries each held ticket's comments, as GitHub answers --json number,comments.
fix_issue_list "status:blocked" "$(jq -s '[.[] | {number, comments}]' "$FIX/gh/issue-301.json" "$FIX/gh/issue-302.json")"
: > "$GH_LOG"
out=$(w --only unblock)
want_in "the ready one is released"    'unblocked #301' "$out"
want_in "and relabelled"               'issue edit 301 .*--remove-label status:blocked --add-label status:ready' "$(cat "$GH_LOG")"
want_not_in "the held one stays held"  'unblocked #302' "$out"
# The one read on its own is the relabel's fresh read of the ticket it moves (issue-status.sh).
want "two held tickets and three parents: no parent or held ticket read on its own" "1" "$(grep -c '^issue view' "$GH_LOG")"
want "and that one read is the released ticket's, before its relabel" "1" "$(grep -c '^issue view 301 ' "$GH_LOG")"
want "and every parent in one batched read" "1" "$(grep -c '^api graphql' "$GH_LOG")"

echo "--- a pass over many broken PRs reads their tickets in one request ---"
: > "$SPAWNS"; : > "$TRIED"; : > "$GH_LOG"
for t in 501 502 503 504 505; do fix_issue "$t" OPEN "status:needs-human,project:widgets"; done
fix_prs "51 501 a501 DIRTY 0 -" "52 502 a502 DIRTY 0 -" "53 503 a503 CLEAN 0 typecheck" "54 504 a504 DIRTY 0 -" "55 505 a505 DIRTY 0 -"
w --only repair >/dev/null
want "five paused tickets: none spawned" "0" "$(grep -c . "$SPAWNS")"
want "and none read on its own"          "0" "$(grep -c '^issue view' "$GH_LOG")"
want_in "they were read in one batch"    'i501:issueOrPullRequest.*i505:issueOrPullRequest' "$(grep '^api graphql' "$GH_LOG" | grep -v OpenPullRequests)"
printf '%s\t%s\t%s\t%s\n' 501 a501 conflict "$T0" 502 a502 conflict "$T0" 503 a503 ci "$T0" 504 a504 conflict "$T0" 505 a505 conflict "$T0" > "$TRIED"
: > "$GH_LOG"; w --only repair >/dev/null
want "every head already tried: no ticket is read at all" "0" "$(grep -cE '^issue view|issueOrPullRequest' "$GH_LOG")"
: > "$TRIED"; fix_prs; fix_issue 101 OPEN "status:in-review,project:widgets"

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

echo "--- a repair waiting for develop's fix (base-waits.tsv) is not sent again on that head ---"
: > "$SPAWNS"; : > "$TRIED"
fix_live widgets 0; fix_at "$T0"; fix_trunk green
printf '101\t11\teeeeeeeee1\tdevelop\ttypecheck\tsrc/legacy.test.ts\t%s\t\n' "$T0" > "$STATE/swarm/base-waits.tsv"
fix_prs "11 101 eeeeeeeee1 CLEAN 0 typecheck"
out=$(w --only repair)
want "no agent while it waits"         "0" "$(grep -c . "$SPAWNS")"
want_in "and it says why"              'skip #11 \(101\): its reds fail on develop too' "$out"
fix_prs "11 101 eeeeeeeee2 CLEAN 0 typecheck"
w --only repair >/dev/null
want "a new head is repaired"          "1" "$(grep -c . "$SPAWNS")"
rm -f "$STATE/swarm/base-waits.tsv"

echo "--- --explain changes nothing ---"
: > "$GH_LOG"; : > "$SPAWNS"; : > "$TRIED"
fix_live widgets 0; fix_at "$T0"
fix_prs "11 101 99999999991 CLEAN 0 typecheck"
out=$(w --only repair --explain)
want_in "it says what it would do"     'WOULD repair #11' "$out"
want "but spawns nothing"              "0" "$(grep -c . "$SPAWNS")"
want "and records no attempt"          "0" "$(grep -c . "$TRIED")"

echo "--- repair-watch goes through the one repair gate (repair-gate.sh) ---"
# Seen 2026-10-23: a repair on Maktura #5989 whose only red was a check develop does not require.
: > "$SPAWNS"; : > "$TRIED"
fix_prs "61 101 e61e61e61e1 CLEAN 0 Capture-evidence"; fix_required typecheck
out=$(w --only repair)
want "only a non-required check red: no repair" "0" "$(grep -c . "$SPAWNS")"
want_in "  and it says why"                    'skip #61 \(101\): PR #61 is not red \(green: no required check failed' "$out"
: > "$SPAWNS"; : > "$TRIED"
fix_prs "62 101 e62e62e62e1 CLEAN 0 typecheck"
w --only repair >/dev/null
want "a required red still gets its repair"     "1" "$(grep -c . "$SPAWNS")"
want "  and the spawn is on record for the rebuild count" "repair" "$(cut -f3 "$STATE/coordinator/run-classes.tsv" 2>/dev/null | tail -1)"
: > "$SPAWNS"; : > "$TRIED"; fix_issue 103 CLOSED "status:in-review"
fix_prs "63 103 e63e63e63e1 CLEAN 0 typecheck"
out=$(w --only repair)
want "a closed ticket: no repair"               "0" "$(grep -c . "$SPAWNS")"
: > "$SPAWNS"; : > "$TRIED"; mkdir -p "$STATE/coordinator"
printf 'r1\t101\trepair\t1\nr2\t101\trepair\t2\n' > "$STATE/coordinator/run-classes.tsv"
printf '{}\n' > "$FIX/gh/api-repos_acme_widgets_git_refs.json"
fix_prs "64 101 e64e64e64e1 CLEAN 0 typecheck"
out=$(COORDINATOR_REBUILD_AFTER_REPAIRS=2 COORDINATOR_SHADOW=0 w --only repair)
want "repaired twice: rebuilt, not repaired a third time" "0" "$(grep -c . "$SPAWNS")"
want_in "  and it says so"                     'skip #64 \(101\): repaired 2 times since it last started fresh — rebuilt' "$out"
rm -f "$STATE/coordinator/run-classes.tsv"; fix_issue 103 OPEN "status:in-review,project:widgets"

suite_end "$FAILED"
