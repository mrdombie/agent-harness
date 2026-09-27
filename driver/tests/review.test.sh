#!/usr/bin/env bash
# review.test.sh — review's job is to end. Two rounds, then the PR ships and
# whatever is left becomes its own ticket, carrying the finding verbatim. Without
# a ceiling the median screen fix took seven rejections and six hours.
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
fix_ai review '{"verdict":"SHIP","blockers":[],"nonblocking":[]}' superpowers:requesting-code-review
out=$(driver_step_review 101 2>&1); rc=$?
want "it finishes"        "0" "$rc"
want "round 1 is counted" "1" "$(driver_state_count 101 review)"

echo "--- blockers in round 1 go back to the build step ---"
driver_state_init 102 --worktree "$REPO"
fix_issue 102 OPEN "status:claimed,project:widgets"
fix_ai review '{"verdict":"BLOCKED","blockers":[{"file":"a.sh","line":3,"finding":"a dead control"}],"nonblocking":[]}' superpowers:requesting-code-review
out=$(driver_step_review 102 2>&1); rc=$?
want "it asks for rework"       "30" "$rc"
want_in "and names the finding" 'dead control' "$out"
want "round 1 counted"          "1"  "$(driver_state_count 102 review)"

echo "--- blockers in round 2 go back once more ---"
rc=0; driver_step_review 102 >/dev/null 2>&1 || rc=$?
want "round 2 still reworks" "30" "$rc"
want "round 2 counted"       "2"  "$(driver_state_count 102 review)"

echo "--- after two rounds the review stops asking for rework ---"
# The ceiling is on the ROUNDS, not on the outcome. Round three does not send the
# work back; what happens to the findings is decided by what kind they are, which the
# case further down measures. This ticket's only finding is a blocker, so nothing is
# filed and the ship step is what refuses, naming it.
: > "$GH_LOG"
out=$(driver_step_review 102 2>&1); rc=$?
want "the third pass does not rework"    "0" "$rc"
want "the blocker is still on the answer" "1" \
  "$(jq -r '(.blockers // []) | length' "$(driver_state_dir 102)/steps/review.json")"
want_not_in "and no ticket is filed for it" 'issue create' "$(cat "$GH_LOG")"

echo "--- a non-blocking leftover DOES become a ticket, with the parent's label ---"
: > "$GH_LOG"
fix_ai review '{"verdict":"SHIP","blockers":[],"nonblocking":[{"file":"a.sh","line":3,"finding":"a dead control"}]}' superpowers:requesting-code-review
out=$(driver_step_review 102 2>&1); rc=$?
want "it finishes"                       "0" "$rc"
want_in "a follow-up ticket is filed"    'issue create' "$(cat "$GH_LOG")"
want_in "carrying the finding verbatim"  'a dead control' "$(cat "$GH_LOG")"
want_in "and the parent programme label" 'project:widgets' "$(cat "$GH_LOG")"
want_in "and it says so"                 'follow-up' "$out"

echo "--- non-blocking findings in a clean review also become a ticket ---"
: > "$GH_LOG"
driver_state_init 103 --worktree "$REPO"
fix_issue 103 OPEN "status:claimed,project:widgets"
fix_ai review '{"verdict":"SHIP","blockers":[],"nonblocking":[{"file":"b.sh","finding":"the empty state has no copy"}]}' superpowers:requesting-code-review
rc=0; driver_step_review 103 >/dev/null 2>&1 || rc=$?
want "it still ships"                 "0" "$rc"
want_in "and the leftover is filed"   'empty state has no copy' "$(cat "$GH_LOG")"

echo "--- past the rounds, a BLOCKER stays with this ticket; only the rest leave ---"
# The rule is that anything NON-BLOCKING after the last round becomes its own ticket.
# A blocker is a dead control, a broken flow or a data-honesty failure — it does not
# ship, so the ship step refuses and names it. Filing it as a follow-up as well means
# a ticket exists for something still blocking this pull request, and the same
# finding is now recorded in two places with nobody owning either.
: > "$GH_LOG"
driver_state_init 105 --worktree "$REPO"
fix_issue 105 OPEN "status:claimed,project:widgets"
fix_ai review '{"verdict":"BLOCKED","blockers":[{"file":"c.sh","line":4,"finding":"the button calls nothing"}],"nonblocking":[{"file":"d.sh","finding":"the heading repeats the title"}]}' \
  superpowers:requesting-code-review
i=0; while [ $i -le "$DRIVER_MAX_REVIEW_ROUNDS" ]; do driver_state_bump 105 review; i=$((i+1)); done
out=$(driver_step_review 105 2>&1); rc=$?
want "the rounds are spent, so it stops asking for rework" "0" "$rc"
want_in "the non-blocking finding leaves as a ticket" 'the heading repeats the title' "$(cat "$GH_LOG")"
want_not_in "the blocker does not"  'the button calls nothing' "$(cat "$GH_LOG")"
want "exactly one ticket was filed" "1" "$(grep -c 'issue create' "$GH_LOG")"

echo "--- a review that never ran its skill is not a review ---"
driver_state_init 104 --worktree "$REPO"
fix_issue 104 OPEN "status:claimed"
fix_ai review '{"verdict":"SHIP","blockers":[]}'
rc=0; driver_step_review 104 >/dev/null 2>&1 || rc=$?
want "it parks" "21" "$rc"

echo "--- a verdict the driver does not recognise is not a pass ---"
fix_ai review '{"verdict":"probably fine","blockers":[]}' superpowers:requesting-code-review
out=$(driver_step_review 104 2>&1); rc=$?
want "an unknown verdict refuses" "24" "$rc"
want_in "and quotes it"           'probably fine' "$out"

exit $FAILED
