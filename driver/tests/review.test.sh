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

echo "--- a repair is reviewed on its own change, not the whole PR again ---"
# Re-reviewing the whole PR on every repair sent fixes, screens among them, after the
# owner had signed it off. The PR was reviewed before; the repair is what is new.
git -C "$REPO" worktree add -q "$FIX/wtr" -b tkt-120/work develop
mkdir -p "$FIX/wtr/screens" "$FIX/wtr/lib"; printf 'the PR change\n' > "$FIX/wtr/screens/Home.tsx"; printf 'a\n' > "$FIX/wtr/lib/a.ts"
git -C "$FIX/wtr" add . && git -C "$FIX/wtr" commit -qm "feat: the PR"
RB=$(git -C "$FIX/wtr" rev-parse HEAD)
# The trunk moves on, and the repair merges it in: its commits are the trunk's, not the repair's.
git -C "$REPO" checkout -q develop; printf 'trunk work\n' > "$REPO/develop-only.txt"
git -C "$REPO" add develop-only.txt && git -C "$REPO" commit -qm "trunk: another ticket"
git -C "$FIX/wtr" merge -q --no-edit develop
printf 'the repair\n' > "$FIX/wtr/repair-fix.txt"; git -C "$FIX/wtr" add . && git -C "$FIX/wtr" commit -qm "fix: the repair"
repair_rec() { # <ticket>
  driver_state_init "$1" --worktree "$FIX/wtr" --branch tkt-120/work
  driver_state_set "$1" mode repair; driver_state_set "$1" pr 88; driver_state_set "$1" repair_base "$RB"
  fix_issue "$1" OPEN "status:in-review"
}
repair_rec 120
fix_ai review '{"verdict":"SHIP","findings":[]}' superpowers:requesting-code-review
out=$(driver_step_review 120 2>&1); rc=$?
want "it finishes"                         "0" "$rc"
want_in "the repair's own file is reviewed" 'repair-fix.txt' "$(cat "$(driver_fact_dir 120 review)/DIFF")"
want_not_in "the PR's earlier change is not" 'screens/Home.tsx' "$(cat "$(driver_fact_dir 120 review)/DIFF")"
want_not_in "nor the trunk's commits a merge brought in" 'develop-only.txt' "$(cat "$(driver_fact_dir 120 review)/DIFF")"

echo "--- on a signed-off PR, a blocking finding on a screen parks for the owner; the verdict is never flipped ---"
# A fix there changes pixels after the sign-off: the owner's call. A Critical anywhere
# else is still fixed: filed away and shipped as SHIP, it landed a repair's own defect.
jq '.design = {"surfacePaths": ["screens/**"]}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
# The sign-off record is stubbed; the screen set is the real approval-kept.sh's.
cat > "$BIN/approval-kept" <<SH
#!/usr/bin/env bash
case "\$1" in
  signed-head) echo "\$*" >> "$FIX/ak.log"; [ "\${AK_RC:-0}" = 0 ] && echo 1111111111111111111111111111111111111111; exit "\${AK_RC:-0}" ;;
  screens) exec bash "$HERE/../../scripts/approval-kept.sh" screens ;;
  *) exit 9 ;;
esac
SH
chmod +x "$BIN/approval-kept"; export DRIVER_APPROVAL_KEPT="$BIN/approval-kept"
both='{"verdict":"BLOCKED","findings":[
  {"file":"screens/Home.tsx","line":4,"grade":"major","summary":"the card spacing is off the scale","reason":"it reads cramped"},
  {"file":"lib/a.ts","line":9,"grade":"major","summary":"the error branch is dropped","reason":"a failure shows as success"}]}'
code='{"verdict":"BLOCKED","findings":[{"file":"lib/a.ts","line":9,"grade":"critical","summary":"the repair returns another workspace data","reason":"wrong data"}]}'
screen='{"verdict":"BLOCKED","findings":[{"file":"screens/Home.tsx","line":4,"grade":"major","summary":"x","reason":"y"}]}'
: > "$GH_LOG"; AK_RC=0; export AK_RC; repair_rec 121
fix_ai review "$both" superpowers:requesting-code-review
out=$(driver_step_review 121 2>&1); rc=$?
want "a screen finding on a signed PR parks"   "24" "$rc"
want_in "for the owner, naming it"             '^Needs the owner: PR #88.*screens/Home.tsx' "$(driver_state_get 121 park_note)"
want "as a person's question"                  "person" "$(driver_state_get 121 park_cause)"
want "the verdict is the reviewer's"           "BLOCKED" "$(jq -r '.verdict' "$(driver_state_dir 121)/steps/review.json")"
want_not_in "and nothing is filed away"        'issue create' "$(cat "$GH_LOG")"
repair_rec 122
fix_ai review "$code" superpowers:requesting-code-review
out=$(driver_step_review 122 2>&1); rc=$?
want "a Critical off the screens is fixed, never shipped" "30" "$rc"
want "the verdict stays BLOCKED"               "BLOCKED" "$(jq -r '.verdict' "$(driver_state_dir 122)/steps/review.json")"
for c in "2 unreadable" "3 a-hold-removed-on-GitHub"; do
  set -- $c; AK_RC=$1; repair_rec 12$1
  fix_ai review "$screen" superpowers:requesting-code-review
  rc=0; driver_step_review 12$1 >/dev/null 2>&1 || rc=$?
  want "signed-head exit $1 ($2) counts as signed: it parks" "24" "$rc"
done
AK_RC=1; repair_rec 124
fix_ai review "$screen" superpowers:requesting-code-review
rc=0; driver_step_review 124 >/dev/null 2>&1 || rc=$?
want "never signed: a screen finding is fixed as any other" "30" "$rc"
want_in "asked with signed-head"               'signed-head 88' "$(cat "$FIX/ak.log")"
AK_RC=0; repair_rec 125
fix_ai review '{"verdict":"BLOCKED","findings":[{"file":"screens/Home.test.tsx","line":4,"grade":"major","summary":"x","reason":"y"}]}' superpowers:requesting-code-review
rc=0; driver_step_review 125 >/dev/null 2>&1 || rc=$?
want "a test under the screen globs is not a screen: it is fixed" "30" "$rc"
jq '.design.extraScreens = ["lib/a.ts"]' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
repair_rec 127
fix_ai review "$code" superpowers:requesting-code-review
rc=0; driver_step_review 127 >/dev/null 2>&1 || rc=$?
want "a file named in extraScreens is a screen: it parks" "24" "$rc"
jq '.design = {"surfacePaths": ["screens/**"]}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
: > "$FIX/ak.log"
driver_state_init 126 --worktree "$REPO"; fix_issue 126 OPEN "status:claimed"
fix_ai review "$screen" superpowers:requesting-code-review
rc=0; driver_step_review 126 >/dev/null 2>&1 || rc=$?
want "a build (not a repair) is not held" "30" "$rc"
want "and asks for no sign-off record"    "" "$(cat "$FIX/ak.log")"
jq 'del(.design)' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
unset DRIVER_APPROVAL_KEPT AK_RC

exit $FAILED
