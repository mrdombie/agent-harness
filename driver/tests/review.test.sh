#!/usr/bin/env bash
# review.test.sh — review's job is to end, and to end PROPORTIONATELY. Two rounds,
# and only a Critical or a Major sends the work back. Without a ceiling the median
# screen fix took seven rejections and six hours; without a grade, a spacing step
# cost the same round a dead control needed.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/review.sh" || exit 1
fix_issue 101 OPEN "status:claimed,project:widgets"
driver_state_init 101 --worktree "$REPO"
fix_brief review superpowers:requesting-code-review

echo "--- a clean review ships ---"
fix_ai review '{"verdict":"SHIP","findings":[]}' superpowers:requesting-code-review
out=$(driver_step_review 101 2>&1); rc=$?
want "it finishes"        "0" "$rc"
want "round 1 is counted" "1" "$(driver_state_count 101 review)"

echo "--- a Major in round 1 goes back to the build step ---"
driver_state_init 102 --worktree "$REPO"
fix_issue 102 OPEN "status:claimed,project:widgets"
fix_ai review '{"verdict":"BLOCKED","findings":[{"file":"a.sh","line":3,"grade":"major","summary":"a dead control","reason":"the person clicks Save and nothing is saved"}]}' superpowers:requesting-code-review
out=$(driver_step_review 102 2>&1); rc=$?
want "it asks for rework"       "30" "$rc"
want_in "and names the finding" 'dead control' "$out"
want_in "and says what grade sent it back" 'major' "$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')"
want "round 1 counted"          "1"  "$(driver_state_count 102 review)"

echo "--- and again in round 2 ---"
rc=0; driver_step_review 102 >/dev/null 2>&1 || rc=$?
want "round 2 still reworks" "30" "$rc"
want "round 2 counted"       "2"  "$(driver_state_count 102 review)"

echo "--- after two rounds the review stops asking for rework ---"
# The ceiling is on the ROUNDS, not on the outcome. Round three does not send the
# work back; what happens to the findings is decided by their GRADE. This ticket's
# only finding is a Major, so nothing is filed and the ship step is what refuses.
: > "$GH_LOG"
out=$(driver_step_review 102 2>&1); rc=$?
want "the third pass does not rework"      "0" "$rc"
want "the finding is still on the answer"  "1" \
  "$(jq -r '(.findings // []) | length' "$(driver_state_dir 102)/steps/review.json")"
want_not_in "and no ticket is filed for it" 'issue create' "$(cat "$GH_LOG")"

echo "--- a Minor NEVER sends work back, in any round ---"
# This is the whole point of the grade. A spacing step used to cost a round that a
# real defect needed: four rounds on the step-runner, 11 then 7 then 6 findings,
# most of them small.
: > "$GH_LOG"
driver_state_init 107 --worktree "$REPO"
fix_issue 107 OPEN "status:claimed,project:widgets"
fix_ai review '{"verdict":"SHIP","findings":[{"file":"a.sh","line":3,"grade":"minor","summary":"the retry row sits a step off the scale","reason":"the row looks misaligned"}]}' \
  superpowers:requesting-code-review
out=$(driver_step_review 107 2>&1); rc=$?
want "round 1 with only a Minor still ships" "0" "$rc"
want_in "and the Minor is filed"  'issue create' "$(cat "$GH_LOG")"

echo "--- Minors become ONE follow-up, at the Minor priority ---"
: > "$GH_LOG"
driver_state_init 108 --worktree "$REPO"
fix_issue 108 OPEN "status:claimed,project:widgets"
fix_ai review '{"verdict":"SHIP","findings":[
  {"file":"a.sh","line":1,"grade":"minor","summary":"first small thing","reason":"a"},
  {"file":"b.sh","line":2,"grade":"minor","summary":"second small thing","reason":"b"},
  {"file":"c.sh","line":3,"grade":"minor","summary":"third small thing","reason":"c"}]}' \
  superpowers:requesting-code-review
out=$(driver_step_review 108 2>&1); rc=$?
want "it ships"                          "0" "$rc"
want "exactly ONE ticket was filed"      "1" "$(grep -c 'issue create' "$GH_LOG")"
want_in "carrying the first verbatim"    'first small thing'  "$(cat "$GH_LOG")"
want_in "and the second"                 'second small thing' "$(cat "$GH_LOG")"
want_in "and the third"                  'third small thing'  "$(cat "$GH_LOG")"
want_in "at the Minor priority"          'P3' "$(cat "$GH_LOG")"
want_in "and the parent programme label" 'project:widgets' "$(cat "$GH_LOG")"

echo "--- a Nit is dropped, and the drop is said out loud ---"
# Dropped silently is indistinguishable from never raised. The count is what lets a
# reader tell "the reviewer found nothing" from "the reviewer found taste".
: > "$GH_LOG"
driver_state_init 109 --worktree "$REPO"
fix_issue 109 OPEN "status:claimed,project:widgets"
fix_ai review '{"verdict":"SHIP","findings":[
  {"file":"a.sh","line":1,"grade":"nit","summary":"the comma could be an em dash","reason":"taste"},
  {"file":"b.sh","line":2,"grade":"nit","summary":"prefers single quotes","reason":"taste"}]}' \
  superpowers:requesting-code-review
out=$(driver_step_review 109 2>&1); rc=$?
want "it ships"                        "0" "$rc"
want_not_in "no ticket is filed"       'issue create' "$(cat "$GH_LOG")"
want_not_in "and the nit does not leave" 'em dash' "$(cat "$GH_LOG")"
want_in "and the drop is counted"      '2 nit' "$out"

echo "--- the ticket's own verify: 1 Major + 5 Minors + 2 Nits ---"
# Sends back 1, files 1 follow-up carrying 5 lines at P3, drops 2.
: > "$GH_LOG"
driver_state_init 110 --worktree "$REPO"
fix_issue 110 OPEN "status:claimed,project:widgets"
fix_ai review '{"verdict":"BLOCKED","findings":[
  {"file":"a.sh","line":1,"grade":"major","summary":"the failed read renders the empty copy","reason":"a broken load reads as nothing here"},
  {"file":"b.sh","line":2,"grade":"minor","summary":"minor one","reason":"m1"},
  {"file":"b.sh","line":3,"grade":"minor","summary":"minor two","reason":"m2"},
  {"file":"b.sh","line":4,"grade":"minor","summary":"minor three","reason":"m3"},
  {"file":"b.sh","line":5,"grade":"minor","summary":"minor four","reason":"m4"},
  {"file":"b.sh","line":6,"grade":"minor","summary":"minor five","reason":"m5"},
  {"file":"c.sh","line":7,"grade":"nit","summary":"nit one","reason":"n1"},
  {"file":"c.sh","line":8,"grade":"nit","summary":"nit two","reason":"n2"}]}' \
  superpowers:requesting-code-review
out=$(driver_step_review 110 2>&1); rc=$?
want "round 1 sends the Major back"        "30" "$rc"
want_in "naming exactly the one that blocks" 'the failed read renders the empty copy' "$out"
want_not_in "and not a Minor"              'minor three' "$out"
want_not_in "and nothing is filed yet"     'issue create' "$(cat "$GH_LOG")"
# Spend the rounds; the Major stays with the ticket, the Minors leave as one, the Nits go.
: > "$GH_LOG"
i=0; while [ $i -le "$DRIVER_MAX_REVIEW_ROUNDS" ]; do driver_state_bump 110 review; i=$((i+1)); done
out=$(driver_step_review 110 2>&1); rc=$?
want "past the rounds it stops reworking"  "0" "$rc"
want "exactly ONE follow-up was filed"     "1" "$(grep -c 'issue create' "$GH_LOG")"
want "and it carries 5 Minor lines"        "5" \
  "$(grep -o 'minor \(one\|two\|three\|four\|five\)' "$GH_LOG" | sort -u | grep -c .)"
want_in "at P3"                            'P3' "$(cat "$GH_LOG")"
want_not_in "the Major does not leave"     'the failed read renders the empty copy' "$(cat "$GH_LOG")"
want_not_in "and neither do the Nits"      'nit one' "$(cat "$GH_LOG")"
want_in "the dropped Nits are counted"     '2 nit' "$out"

echo "--- a follow-up that could not be filed is not a follow-up ---"
# The two-round ceiling is justified by "nothing is lost by ending the loop". With the
# create wrapped, a rate limit or issues turned off meant the findings were lost AND
# the log asserted the opposite.
: > "$GH_LOG"
driver_state_init 106 --worktree "$REPO"
fix_issue 106 OPEN "status:claimed,project:widgets"
fix_ai review '{"verdict":"SHIP","findings":[{"file":"e.sh","line":2,"grade":"minor","summary":"the count is not shown","reason":"the person cannot tell how many there are"}]}' \
  superpowers:requesting-code-review
fix_gh_fail "issue create"
out=$(driver_step_review 106 2>&1); rc=$?
fix_gh_ok
want_not_in "it does not claim the filing happened" 'filed as one follow-up' "$out"
want_in "and names what was not filed"              'the count is not shown' "$out"
want "and it REFUSES, so a park carries the finding" "24" "$rc"
want_in "and leaves it for the handover"             'the count is not shown' \
  "$(driver_state_get 106 park_note)"

echo "--- a review that never ran its skill is not a review ---"
driver_state_init 104 --worktree "$REPO"
fix_issue 104 OPEN "status:claimed"
fix_ai review '{"verdict":"SHIP","findings":[]}'
rc=0; driver_step_review 104 >/dev/null 2>&1 || rc=$?
want "it parks" "21" "$rc"

echo "--- a verdict the driver does not recognise is not a pass ---"
fix_ai review '{"verdict":"probably fine","findings":[]}' superpowers:requesting-code-review
out=$(driver_step_review 104 2>&1); rc=$?
want "an unknown verdict refuses" "24" "$rc"
want_in "and quotes it"           'probably fine' "$out"

echo "--- SHIP typed beside an open Critical is not a SHIP ---"
# The contract refuses this too, and that is exactly why the driver must: a check and
# the thing it checks derived from one input is one input away from agreeing about
# nothing. Past the rounds the rework branch stops firing, so without this the Critical
# walks into the ship step and lands.
fix_ai review '{"verdict":"SHIP","findings":[{"file":"a.sh","line":1,"grade":"critical","summary":"the export writes another workspace rows","reason":"one client sees another client data"}]}' superpowers:requesting-code-review
out=$(driver_step_review 104 2>&1); rc=$?
want "it refuses"                "24" "$rc"
want_in "and names the finding"  'another workspace' "$out"

echo "--- a grade the driver does not recognise is not a finding it can act on ---"
# A grade outside the scale has no effect defined for it, so acting on it means
# guessing. Silently treating it as non-blocking is how a Critical typed 'crit'
# ships; silently blocking on it is how a Nit costs a round.
fix_ai review '{"verdict":"BLOCKED","findings":[{"file":"a.sh","line":1,"grade":"severe","summary":"x","reason":"y"}]}' superpowers:requesting-code-review
out=$(driver_step_review 104 2>&1); rc=$?
want "an unknown grade refuses" "24" "$rc"
want_in "and quotes it"         'severe' "$out"

exit $FAILED
