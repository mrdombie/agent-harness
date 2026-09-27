#!/usr/bin/env bash
# ship.test.sh — the last step, and the one whose mistakes are public. The two
# that matter: a pull request is opened as a DRAFT and only marked ready once the
# review verdict is in, and the run ENDS at the push rather than watching CI.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/ship.sh" || exit 1

# A bare origin the worktree can really push to, so "the branch is on origin" is
# a fact rather than a recorded intention.
git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop

setup_wt() { # <ticket>
  local t=$1 wt
  wt="$FIX/wt$t"
  git -C "$REPO" worktree add -q "$wt" -b "tkt-$t/work" develop
  printf 'change for %s\n' "$t" > "$wt/f$t.txt"
  git -C "$wt" add "f$t.txt"; git -C "$wt" commit -qm "feat: thing $t"
  driver_state_init "$t" --worktree "$wt" --branch "tkt-$t/work"
  driver_state_set "$t" claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
  fix_issue "$t" OPEN "status:claimed"
}

echo "--- a reviewed ticket ships ---"
setup_wt 101
driver_state_put 101 review '{"verdict":"SHIP","blockers":[]}'
driver_state_bump 101 review
out=$(driver_step_ship 101 2>&1); rc=$?
want "it finishes" "0" "$rc"
want "the branch is really on origin" "1" \
  "$(git -C "$FIX/origin" rev-parse --verify tkt-101/work >/dev/null 2>&1 && echo 1)"
want_in "the PR is opened as a draft"     'pr create.*--draft' "$(cat "$GH_LOG")"
want_in "and marked ready once reviewed"  'pr ready'           "$(cat "$GH_LOG")"
want_in "auto-merge is armed"             'pr merge.*--auto'   "$(cat "$GH_LOG")"
want_in "the body carries the round count" 'Review rounds: 1 of 2' "$(cat "$GH_LOG")"
want_in "and the SHA it was claimed at"   "$(git -C "$REPO" rev-parse develop | cut -c1-8)" "$(cat "$GH_LOG")"
want_in "a hand-off comment is left"      'Handed off at' "$(cat "$GH_LOG")"

echo "--- it does NOT wait for CI: a watcher brings an agent back ---"
want_not_in "no run watch" 'run watch'   "$(cat "$GH_LOG")"
want_not_in "no check wait" 'pr checks.*--watch' "$(cat "$GH_LOG")"

echo "--- an unreviewed ticket opens the draft and stops there ---"
: > "$GH_LOG"
setup_wt 102
out=$(driver_step_ship 102 2>&1); rc=$?
want "it refuses to finish"            "24" "$rc"
want_in "the draft was still opened"   'pr create.*--draft' "$(cat "$GH_LOG")"
want_not_in "but never marked ready"   'pr ready'           "$(cat "$GH_LOG")"
want_not_in "and auto is never armed"  'pr merge'           "$(cat "$GH_LOG")"
want_in "and it says what is missing"  'review' "$out"

echo "--- an uncommitted change is not shipped silently ---"
: > "$GH_LOG"
setup_wt 103
driver_state_put 103 review '{"verdict":"SHIP","blockers":[]}'
printf 'stray\n' > "$FIX/wt103/stray.txt"
out=$(driver_step_ship 103 2>&1); rc=$?
want "a dirty tree refuses"  "24" "$rc"
want_in "naming the file"    'stray.txt' "$out"
want_not_in "nothing pushed" 'pr create' "$(cat "$GH_LOG")"

echo "--- never from the trunk itself ---"
: > "$GH_LOG"
driver_state_init 104 --worktree "$REPO" --branch develop
driver_state_put 104 review '{"verdict":"SHIP","blockers":[]}'
fix_issue 104 OPEN "status:claimed"
out=$(driver_step_ship 104 2>&1); rc=$?
want "shipping from the trunk refuses" "24" "$rc"
want_in "and names the branch"         'develop' "$out"

echo "--- a branch with no commits on it has nothing to ship ---"
: > "$GH_LOG"
git -C "$REPO" worktree add -q "$FIX/wt105" -b tkt-105/work develop
driver_state_init 105 --worktree "$FIX/wt105" --branch tkt-105/work
driver_state_put 105 review '{"verdict":"SHIP","blockers":[]}'
fix_issue 105 OPEN "status:claimed"
out=$(driver_step_ship 105 2>&1); rc=$?
want "an empty branch refuses" "24" "$rc"
want_in "and says so"          'no commits' "$out"

exit $FAILED
