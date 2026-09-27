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

echo "--- after two rounds the PR ships and the leftovers become a ticket ---"
: > "$GH_LOG"
out=$(driver_step_review 102 2>&1); rc=$?
want "the third pass does not rework"    "0" "$rc"
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
