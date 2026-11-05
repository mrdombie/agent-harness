#!/usr/bin/env bash
# review-guide.test.sh — the reviewer is handed the nearest REVIEW.md above each file the
# change touches, and nothing when no file has one. Plant: with the step's guide lines
# removed, the guide never reaches the reviewer.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/review.sh" || exit 1
fix_brief review superpowers:requesting-code-review

mkdir -p "$REPO/apps/feed" "$REPO/apps/other"
printf '# Feed\nSkip generated/ files.\nAt most 2 nits.\n' > "$REPO/apps/feed/REVIEW.md"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "base with an area guide"
git -C "$REPO" checkout -qb tkt-201/guide
echo x > "$REPO/apps/feed/a.ts"; git -C "$REPO" add -A; git -C "$REPO" commit -qm change

fix_issue 201 OPEN "status:claimed,project:widgets"
driver_state_init 201 --worktree "$REPO"
fix_ai review '{"verdict":"SHIP","findings":[]}' superpowers:requesting-code-review
driver_step_review 201 >/dev/null 2>&1
d=$(cat "$(driver_fact_dir 201 review)/DIFF" 2>/dev/null)
want_in "the reviewer is handed the area's guide" "Skip generated/ files." "$d"
want_in "  under its heading"                     "AREA REVIEW GUIDES" "$d"
want_in "  naming the guide"                       "apps/feed/REVIEW.md — for " "$d"
want_in "  and the file it covers"                 "— for apps/feed/a.ts" "$d"
if printf '%s' "$d" | grep -q '^+Skip generated/'; then bad "  the guide is not in the diff itself"; else ok "  the guide is not in the diff itself"; fi

git -C "$REPO" checkout -q develop; git -C "$REPO" checkout -qb tkt-202/none
echo y > "$REPO/apps/other/b.ts" 2>/dev/null || { mkdir -p "$REPO/apps/other"; echo y > "$REPO/apps/other/b.ts"; }
git -C "$REPO" add -A; git -C "$REPO" commit -qm other
fix_issue 202 OPEN "status:claimed,project:widgets"
driver_state_init 202 --worktree "$REPO"
fix_ai review '{"verdict":"SHIP","findings":[]}' superpowers:requesting-code-review
driver_step_review 202 >/dev/null 2>&1
d=$(cat "$(driver_fact_dir 202 review)/DIFF" 2>/dev/null)
if printf '%s' "$d" | grep -q 'AREA REVIEW GUIDES'; then bad "no guide, no guide block"; else ok "no guide, no guide block"; fi
want_in "  the diff itself still goes" "apps/other/b.ts" "$d"

echo "--- plant: the guide lines removed ---"
P="$HERE/../steps/.review-planted.$$.sh"; on_exit_keep_status 'rm -rf "$FIX" "$P"'
grep -v 'review-guide.sh' "$HERE/../steps/review.sh" > "$P"
if grep -q 'review-guide.sh' "$P"; then bad "plant did not land"; else
  . "$P"; rm -f "$P"
  git -C "$REPO" checkout -q tkt-201/guide
  driver_state_init 203 --worktree "$REPO"; fix_issue 203 OPEN "status:claimed,project:widgets"
  fix_ai review '{"verdict":"SHIP","findings":[]}' superpowers:requesting-code-review
  driver_step_review 203 >/dev/null 2>&1
  d=$(cat "$(driver_fact_dir 203 review)/DIFF" 2>/dev/null)
  if printf '%s' "$d" | grep -q 'Skip generated/'; then bad "plant still passes"; else ok "plant: without the step's lines, no guide reaches the reviewer"; fi
fi

suite_end "$FAILED"
