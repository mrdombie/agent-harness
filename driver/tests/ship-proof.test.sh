#!/usr/bin/env bash
# ship-proof.test.sh — ship puts the run's proof on the pull request, and refuses one without it.
# The body carries the commands the driver ran with their output, and two lines: how it
# was tested, how to undo it. A body without them is never
# opened, rewritten or pushed onto.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/ship.sh" || exit 1

git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop

setup_wt() { # <ticket>
  local t=$1 wt="$FIX/wt$1"
  git -C "$REPO" worktree add -q "$wt" -b "tkt-$t/work" develop
  printf 'change for %s\n' "$t" > "$wt/f$t.txt"
  git -C "$wt" add "f$t.txt"; git -C "$wt" commit -qm "feat: thing $t"
  driver_state_init "$t" --worktree "$wt" --branch "tkt-$t/work"
  driver_state_set "$t" claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
  driver_state_put "$t" review '{"verdict":"SHIP","findings":[]}'; driver_state_bump "$t" review
  for st in start plan build self-check review record; do driver_state_done "$t" "$st"; done
  fix_issue "$t" OPEN "status:claimed"
}
proved() { # <ticket> — a task the build proved, as build leaves it
  jq -n '{title: "the widget counts", merged: false,
          proof: {command: "bash widget.test.sh", testFile: "widget.test.sh",
                  red: {exit: 1, at: "aaaaaaaa", output: "WIDGET-RED-OUTPUT"},
                  green: {exit: 0, at: "bbbbbbbb", output: "WIDGET-GREEN-OUTPUT"}}}' \
    > "$(driver_state_dir "$1")/steps/build-task-1.proved"
  printf '%s\n' '{"gate":"lint","command":"npm run lint","exit":0,"output":"LINT-CLEAN"}' \
    > "$(driver_state_dir "$1")/steps/self-check.gates.jsonl"
}
log() { tr '\n' ' ' < "$GH_LOG"; }

echo "--- the opened PR carries the commands, their output and both lines ---"
setup_wt 201; proved 201; : > "$GH_LOG"
out=$(driver_step_ship 201 2>&1); rc=$?
want "it ships"                               "0" "$rc"
want_in "the body has a Proof section"        'pr create .*--body .*## Proof' "$(log)"
want_in "with the test's command"             'pr create .*`bash widget.test.sh`' "$(log)"
want_in "and its red output"                  'pr create .*WIDGET-RED-OUTPUT' "$(log)"
want_in "and its green output"                'pr create .*WIDGET-GREEN-OUTPUT' "$(log)"
want_in "and each gate's"                     'pr create .*`npm run lint`.*LINT-CLEAN' "$(log)"
want_in "how it was tested"                   'pr create .*How it was tested: 1 test ' "$(log)"
want_in "how to undo it"                      'pr create .*How to undo it: revert' "$(log)"
want_in "the closing line is still first"     'pr create .*--body Closes #201' "$(log)"

echo "--- a run that kept no gate record runs the gates for it, never ships without ---"
setup_wt 202; : > "$GH_LOG"
out=$(driver_step_ship 202 2>&1); rc=$?
want "it ships"                               "0" "$rc"
want_in "it says why it ran them"             'no record of the gates' "$out"
want_in "and the body carries what they printed" 'pr create .*`echo lint-ok`.*lint-ok' "$(log)"

echo "--- a body with nothing proved is never opened ---"
setup_wt 203; : > "$(driver_state_dir 203)/steps/self-check.gates.jsonl"; : > "$GH_LOG"
out=$(driver_step_ship 203 2>&1); rc=$?
want "it refuses"                             "24" "$rc"
want_in "saying what the body lacks"          'no command run' "$out"
want_in "on the record for the park"          'proof' "$(driver_state_get 203 park_note)"
want_not_in "no PR is opened"                 'pr create' "$(log)"
want "and nothing is pushed"                  "0" "$(git -C "$FIX/origin" rev-parse --verify -q tkt-203/work >/dev/null && echo 1 || echo 0)"

echo "--- a PR a park opened is rewritten with the proof, and never without ---"
setup_wt 204; proved 204
printf '[{"number":77}]\n' > "$FIX/gh/prs.json"; : > "$FIX/pr-created-tkt-204_work"; : > "$GH_LOG"
out=$(driver_step_ship 204 2>&1); rc=$?
want "it ships"                               "0" "$rc"
want_in "the rewrite carries the proof"       'pr edit 77 .*--body .*## Proof.*How it was tested:.*How to undo it:' "$(log)"
rm -f "$FIX/gh/prs.json"

suite_end "$FAILED"
