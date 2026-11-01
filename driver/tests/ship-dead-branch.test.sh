#!/usr/bin/env bash
# ship-dead-branch.test.sh — a branch whose pull requests are all closed is history,
# not work. Origin's copy of the ticket's branch sat at an earlier run's tip whose
# four PRs were closed; every later run conflicted with it at ship and parked
# "ship refused (exit 24)", four times over two days. With no open PR on the branch
# ship archives that tip under refs/stranded/<ticket>/archive-<sha7>, replaces the
# branch with a lease on that exact tip, and ships. An open PR still parks.
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
  local t=$1 wt
  wt="$FIX/wt$t"
  git -C "$REPO" worktree add -q "$wt" -b "tkt-$t/work" develop
  printf 'change for %s\n' "$t" > "$wt/f$t.txt"
  git -C "$wt" add "f$t.txt"; git -C "$wt" commit -qm "feat: thing $t"
  driver_state_init "$t" --worktree "$wt" --branch "tkt-$t/work"
  driver_state_set "$t" claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
  fix_issue "$t" OPEN "status:claimed"
  driver_state_put "$t" review '{"verdict":"SHIP","findings":[]}'; driver_state_bump "$t" review
  for st in start plan build self-check review record; do driver_state_done "$t" "$st"; done
}

# dead_tip <ticket> — an earlier run pushed the ticket's branch, then the trunk changed
# the same file and this run merged the trunk: origin's tip conflicts in a file this
# run never changed (the #13304 shape). Prints the dead tip.
dead_tip() {
  local t=$1 c="$FIX/earlier$1"
  git clone -q -n "$FIX/origin" "$c"
  git -C "$c" checkout -q -b "tkt-$t/work" origin/develop
  printf 'the dead run\n' > "$c/shared$t.txt"
  git -C "$c" add "shared$t.txt"
  git -C "$c" -c user.name=Earlier -c user.email=e@example.invalid commit -qm "feat: the dead run's shared$t"
  git -C "$c" push -q origin "tkt-$t/work"
  printf 'the trunk moved\n' > "$REPO/shared$t.txt"
  git -C "$REPO" add "shared$t.txt"; git -C "$REPO" commit -qm "feat: trunk change $t"; git -C "$REPO" push -q origin develop
  git -C "$FIX/wt$t" fetch -q origin
  git -C "$FIX/wt$t" merge -q --no-edit origin/develop
  git -C "$c" rev-parse HEAD
}
archive_of() { git -C "$FIX/origin" rev-parse -q --verify "refs/stranded/$1/archive-$(printf '%s' "$2" | cut -c1-7)" 2>/dev/null; }

echo "--- origin's branch is a dead tip and no PR is open on it: archived, leased over, shipped ---"
: > "$GH_LOG"; printf '[]\n' > "$FIX/gh/prs.json"
setup_wt 501
dead=$(dead_tip 501)
rc=0; out=$(driver_step_ship 501 2>&1) || rc=$?
want "it ships"                                 "0" "$rc"
want "the dead tip is archived on origin"       "$dead" "$(archive_of 501 "$dead")"
want "the branch is this run's line now"        "$(git -C "$FIX/wt501" rev-parse HEAD)" "$(git -C "$FIX/origin" rev-parse tkt-501/work)"
want "with none of the dead run's commits"      "no" "$(git -C "$FIX/origin" merge-base --is-ancestor "$dead" tkt-501/work && echo yes || echo no)"
want "and this run's work on it"                "change for 501" "$(git -C "$FIX/origin" show tkt-501/work:f501.txt 2>/dev/null)"
want_in "the run says where the old tip went"   "refs/stranded/501/archive-$(printf '%s' "$dead" | cut -c1-7)" "$out"
want_in "and the pull request does"             "refs/stranded/501/archive-$(printf '%s' "$dead" | cut -c1-7)" "$(tr '\n' ' ' < "$GH_LOG")"
want_in "the PR is opened"                      'pr create' "$(cat "$GH_LOG")"

echo "--- a park after the archive names it too ---"
. "$HERE/../steps/park.sh" || exit 1
: > "$GH_LOG"
driver_park 501 "ship refused (exit 24)" "a later refusal" driver >/dev/null 2>&1
want_in "the park comment names the archive"    "refs/stranded/501/archive-$(printf '%s' "$dead" | cut -c1-7)" "$(tr '\n' ' ' < "$GH_LOG")"

echo "--- an archive is never the line a run resumes from ---"
# The PM's hand-made archive on #13304 sorted after every stamp ("56738df" > "2026…").
git -C "$FIX/wt501" push -q origin "HEAD~1:refs/stranded/501/archive-27oct-56738df"
git -C "$FIX/wt501" push -q origin "HEAD:refs/stranded/501/host-20261101T000000Z"
want_not_in "the stranded list leaves archives out" 'archive-' "$(driver_stranded_list 501 "$REPO")"
driver_stranded_restore 501 "$REPO" ""
want "restore picks the run's own stranded ref" "refs/stranded/501/host-20261101T000000Z" "$DRIVER_STRANDED_FROM"

echo "--- an open PR uses the branch: unchanged, it parks and pushes nothing ---"
: > "$GH_LOG"
setup_wt 502
dead=$(dead_tip 502)
printf '[{"number":77,"isDraft":false,"headRefName":"tkt-502/work"}]\n' > "$FIX/gh/prs.json"
rc=0; out=$(driver_step_ship 502 2>&1) || rc=$?
want "it refuses"                               "24" "$rc"
want_in "naming the conflicting file"           'shared502.txt' "$out"
want "origin's branch is untouched"             "$dead" "$(git -C "$FIX/origin" rev-parse tkt-502/work)"
want "and nothing is archived"                  "" "$(archive_of 502 "$dead")"
printf '[]\n' > "$FIX/gh/prs.json"

echo "--- GitHub cannot say whether a PR is open: nothing is replaced ---"
: > "$GH_LOG"
setup_wt 503
dead=$(dead_tip 503)
printf 'pr list\n' > "$FIX/gh-fail"
rc=0; out=$(DRIVER_LOOKUP_RETRY_SEC=0 driver_step_ship 503 2>&1) || rc=$?
rm -f "$FIX/gh-fail"
want "it stops unread"                          "26" "$rc"
want "origin's branch is untouched"             "$dead" "$(git -C "$FIX/origin" rev-parse tkt-503/work)"
want "and nothing is archived"                  "" "$(archive_of 503 "$dead")"

echo "--- the lease names the tip: a branch that moved since is not overwritten ---"
setup_wt 504
moved=$(dead_tip 504)
DRIVER_PUSH_LEASE_BRANCH=tkt-504/work DRIVER_PUSH_LEASE_SHA=$(git -C "$REPO" rev-parse develop)
rc=0; driver_push 504 "$FIX/wt504" tkt-504/work ship >/dev/null 2>&1 || rc=$?
DRIVER_PUSH_LEASE_BRANCH="" DRIVER_PUSH_LEASE_SHA=""
want "the push is refused"                      "no" "$([ "$rc" -eq 0 ] && echo yes || echo no)"
want "and origin keeps what it had"             "$moved" "$(git -C "$FIX/origin" rev-parse tkt-504/work)"

suite_end "$FAILED"
