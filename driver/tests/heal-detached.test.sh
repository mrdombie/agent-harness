#!/usr/bin/env bash
# heal-detached.test.sh — a ticket tree left on a detached HEAD ahead of its branch gets
# the branch fast-forwarded and HEAD put back on it; a branch HEAD is not ahead of is
# never moved. A run left its build commits on a detached HEAD and ship, reading the
# branch, found none and parked the finished work.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/build.sh" || exit 1

commit_in() { # <tree> <file> — one commit adding <file>
  printf '%s\n' "$2" > "$1/$2"; git -C "$1" add -- "$2"; git -C "$1" commit -qm "feat: $2"
}

echo "--- detached ahead of the branch: fast-forwarded, reattached, said once ---"
wt="$FIX/wt1"; fixture_path wt "$FIX"
git -C "$REPO" worktree add -q "$wt" -b tkt-1/work develop
commit_in "$wt" claim.txt
git -C "$wt" checkout -q --detach
commit_in "$wt" a.txt; commit_in "$wt" b.txt
head=$(git -C "$wt" rev-parse HEAD)
out=$(driver_heal_detached 1 "$wt" tkt-1/work 2>&1); rc=$?
want "it heals"                       "0" "$rc"
want "the branch holds the detached commits" "$head" "$(git -C "$wt" rev-parse refs/heads/tkt-1/work)"
want "HEAD is on the branch again"    "refs/heads/tkt-1/work" "$(git -C "$wt" symbolic-ref -q HEAD)"
want "one line says so"               "1" "$(printf '%s\n' "$out" | grep -c 'heal:')"
want_in "naming the branch and the count" '2 commit\(s\) ahead of tkt-1/work' "$out"
want_in "and the reflog line that detached it" 'detached by: checkout: moving from tkt-1/work to' "$out"

echo "--- already on the branch: silent, nothing moves ---"
out=$(driver_heal_detached 1 "$wt" tkt-1/work 2>&1); rc=$?
want "it is a no-op"     "0" "$rc"
want "and says nothing"  "" "$out"
want "the branch is unchanged" "$head" "$(git -C "$wt" rev-parse refs/heads/tkt-1/work)"

echo "--- diverged: refused, neither ref moves ---"
git -C "$wt" checkout -q --detach HEAD~1
commit_in "$wt" other.txt
dhead=$(git -C "$wt" rev-parse HEAD)
out=$(driver_heal_detached 1 "$wt" tkt-1/work 2>&1); rc=$?
want "a branch that is not an ancestor is refused" "1" "$rc"
want_in "and the refusal says why" 'is not an ancestor' "$out"
want "the branch did not move"     "$head" "$(git -C "$wt" rev-parse refs/heads/tkt-1/work)"
want "HEAD did not move"           "$dhead" "$(git -C "$wt" rev-parse HEAD)"
want "and HEAD is still detached"  "" "$(git -C "$wt" symbolic-ref -q HEAD)"

echo "--- no branch on record: refused, nothing moves ---"
out=$(driver_heal_detached 1 "$wt" "" 2>&1); rc=$?
want "no branch is refused"   "1" "$rc"
want "HEAD is still detached" "" "$(git -C "$wt" symbolic-ref -q HEAD)"

echo "--- uncommitted edits survive the heal ---"
wt2="$FIX/wt2"; fixture_path wt2 "$FIX"
git -C "$REPO" worktree add -q "$wt2" -b tkt-2/work develop
git -C "$wt2" checkout -q --detach
commit_in "$wt2" c.txt
printf 'edit\n' >> "$wt2/c.txt"; printf 'new\n' > "$wt2/untracked.txt"
driver_heal_detached 2 "$wt2" tkt-2/work >/dev/null 2>&1; rc=$?
want "it heals"                   "0" "$rc"
want "HEAD is on the branch"      "refs/heads/tkt-2/work" "$(git -C "$wt2" symbolic-ref -q HEAD)"
want "the edit is still there"    "2" "$(wc -l < "$wt2/c.txt" | tr -d ' ')"
want "the new file is still there" "new" "$(cat "$wt2/untracked.txt")"

suite_end "$FAILED"
