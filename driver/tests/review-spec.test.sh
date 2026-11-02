#!/usr/bin/env bash
# review-spec.test.sh — the review reads the ticket and the approved picture beside the diff.
# Before the pull request opens, a fresh session reviews the diff against what was asked:
# the ticket as filed and the picture a person approved. Handed
# the diff alone it can only judge the code, never whether the code is the change asked for.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/review.sh" || exit 1
fix_brief review superpowers:requesting-code-review
sent() { cat "$FIX/claude-stdin-review.txt" 2>/dev/null; }

echo "--- the review is sent the ticket as filed ---"
jq -n '{number: 301, state: "OPEN", title: "Counts show the real total", labels: [{name: "status:claimed"}],
        body: "The badge shows the TOTAL-OF-OPEN-ITEMS, never a capped 99+."}' > "$FIX/gh/issue-301.json"
driver_state_init 301 --worktree "$REPO"
fix_ai review '{"verdict":"SHIP","findings":[]}' superpowers:requesting-code-review
rc=0; driver_step_review 301 >/dev/null 2>&1 || rc=$?
want "the review runs"                      "0" "$rc"
want_in "the ticket's words are in its prompt" 'TOTAL-OF-OPEN-ITEMS, never a capped 99\+' "$(sent)"
want_in "under a heading that says to judge the diff against it" '^## What this change was asked to do' "$(sent)"
want_in "a missed part of the ticket is a finding" 'does not do.* is a finding' "$(sent)"
want_in "with no picture, it says the ticket stands in" 'No approved picture' "$(sent)"

echo "--- and the approved picture, with what compare made of it ---"
driver_state_init 302 --worktree "$REPO"
fix_issue 302 OPEN "status:claimed"
mkdir -p "$REPO/.design"; printf '<html>approved</html>\n' > "$REPO/.design/badge-mock.html"
driver_state_set 302 design_ref ".design/badge-mock.html"
driver_state_set 302 design_source approved-picture
jq -n '{step: "compare", status: "compared", approved: {ref: ".design/badge-mock.html"}, renders: [{route: "/x"}],
        differences: [{what: "the badge sat 2px low", fixed: true, reason: "nudged"}]}' > "$(driver_state_dir 302)/steps/compare.json"
fix_ai review '{"verdict":"SHIP","findings":[]}' superpowers:requesting-code-review
rc=0; driver_step_review 302 >/dev/null 2>&1 || rc=$?
want "the review runs"                      "0" "$rc"
want_in "the picture is named"              'Approved picture: \.design/badge-mock\.html' "$(sent)"
want_in "with the file to open in the tree"  "$REPO/.design/badge-mock.html" "$(sent)"
want_in "and compare's reading of the renders" 'the badge sat 2px low' "$(sent)"
want_in "a departure from it is a finding"  'departs from the approved picture' "$(sent)"

echo "--- no other step is sent it ---"
fix_brief plan superpowers:writing-plans
driver_state_init 303 --worktree "$REPO"; fix_issue 303 OPEN "status:claimed"
fix_ai plan '{"step":"plan"}' superpowers:writing-plans
driver_ai_step 303 plan >/dev/null 2>&1 || true
want_not_in "the plan prompt carries no review section" 'What this change was asked to do' "$(cat "$FIX/claude-stdin-plan.txt" 2>/dev/null)"

suite_end "$FAILED"
