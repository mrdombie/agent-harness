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
driver_state_put 101 review '{"verdict":"SHIP","findings":[]}'
driver_state_bump 101 review
# The state ship actually runs in: everything before it is finished. The body's step
# list is read off that, so a record with nothing done cannot tell an empty line
# from a rendered one.
for st in start plan build self-check review record; do driver_state_done 101 "$st"; done
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

echo "--- the body's own evidence lines are real, not empty ---"
# The header says the body carries these "so both rules are checkable by a reader
# rather than promised by the agent that wrote them". A line that always renders
# empty is a promise with nothing behind it, and it looks exactly like a line that
# rendered.
want_in "the step list is in the body"  'start .*plan .*build' "$(cat "$GH_LOG")"
want_in "and the title names the ticket's own subject" 'Ticket 101' "$(cat "$GH_LOG")"
want_not_in "not the number twice"      '#101: 101' "$(cat "$GH_LOG")"

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
driver_state_put 103 review '{"verdict":"SHIP","findings":[]}'
printf 'stray\n' > "$FIX/wt103/stray.txt"
out=$(driver_step_ship 103 2>&1); rc=$?
want "a dirty tree refuses"  "24" "$rc"
want_in "naming the file"    'stray.txt' "$out"
want_not_in "nothing pushed" 'pr create' "$(cat "$GH_LOG")"

echo "--- never from the trunk itself ---"
# The case has to be built so the TRUNK GUARD is the only thing that can refuse it.
# Written against $REPO, whose develop equals origin/develop, the branch is zero
# commits ahead and the later "nothing to ship" guard refuses it instead — so with the
# trunk guard deleted the case still passed, and `want_in … 'develop'` was satisfied by
# "no commits on it against origin/develop". Proved by building it properly: guard off,
# the step pushes and MOVES origin/develop.
: > "$GH_LOG"
# A clone of its own, because the trunk cannot be checked out twice and $REPO
# already has it. `git worktree add <path> develop` fails there, and the step then
# refused for a missing worktree — which looks exactly like the guard firing.
WT104="$FIX/wt104"
git clone -q "$FIX/origin" "$WT104" 2>/dev/null
# The bare origin's HEAD names a branch it does not have, so the clone lands on an
# unborn branch and `push develop` then fails for a reason that has nothing to do with
# the guard. Put it on the trunk explicitly.
git -C "$WT104" checkout -q -B develop origin/develop
git -C "$WT104" config user.email t@example.invalid
git -C "$WT104" config user.name T
want "the case really is ON the trunk" "develop" "$(git -C "$WT104" rev-parse --abbrev-ref HEAD)"
printf 'straight onto the trunk\n' > "$WT104/oops.txt"
git -C "$WT104" add oops.txt
git -C "$WT104" commit -qm "feat: onto the trunk"
want "and one commit ahead of origin" "1" "$(git -C "$WT104" rev-list --count origin/develop..develop)"
TRUNK_BEFORE=$(git -C "$FIX/origin" rev-parse develop)
driver_state_init 104 --worktree "$WT104" --branch develop
driver_state_put 104 review '{"verdict":"SHIP","findings":[]}'
fix_issue 104 OPEN "status:claimed"
out=$(driver_step_ship 104 2>&1); rc=$?
want "shipping from the trunk refuses" "24" "$rc"
want_in "and names the branch"         'develop' "$out"
want_in "saying nothing goes straight to the trunk" 'straight to the trunk' "$out"
want "and origin's trunk did not move" "$TRUNK_BEFORE" "$(git -C "$FIX/origin" rev-parse develop)"
want_not_in "no pull request was opened" 'pr create' "$(cat "$GH_LOG")"

echo "--- nor from a detached worktree, where the branch is no branch ---"
# `push -u origin HEAD` from a detached head is the other half of the same guard and
# had no case at all.
: > "$GH_LOG"
WT105="$FIX/wt105det"
git -C "$REPO" worktree add -q --detach "$WT105" develop
printf 'detached\n' > "$WT105/d.txt"
git -C "$WT105" add d.txt
git -C "$WT105" -c user.email=t@example.invalid -c user.name=T commit -qm "feat: detached"
driver_state_init 105 --worktree "$WT105" --branch ""
driver_state_put 105 review '{"verdict":"SHIP","findings":[]}'
fix_issue 105 OPEN "status:claimed"
out=$(driver_step_ship 105 2>&1); rc=$?
want "a detached worktree refuses"       "24" "$rc"
want_not_in "and nothing was pushed"     'pr create' "$(cat "$GH_LOG")"

echo "--- GitHub refusing every write is not a completed hand-off ---"
# Every gh call here is wrapped in `|| true`, so an expired token, a protected base or
# a rate limit produced "pushed, pull request ready, auto-merge armed" with no pull
# request in existence — and because the orchestrator then records ship as finished,
# every later run reports "nothing left to do" and never comes back. The branch sits
# on origin with nothing on the board and the claim still held.
: > "$GH_LOG"
setup_wt 108
driver_state_put 108 review '{"verdict":"SHIP","findings":[]}'
fix_gh_fail "pr create"
out=$(driver_step_ship 108 2>&1); rc=$?
fix_gh_ok
want "it refuses"                        "24" "$rc"
want_not_in "and never claims a hand-off" 'Handing off' "$out"
want_in "saying no pull request exists"   'pull request' "$out"
want "the branch still reached origin"    "1" \
  "$(git -C "$FIX/origin" rev-parse --verify tkt-108/work >/dev/null 2>&1 && echo 1)"

echo "--- and neither is a pull request that could not be marked ready ---"
: > "$GH_LOG"
setup_wt 109
driver_state_put 109 review '{"verdict":"SHIP","findings":[]}'
fix_gh_fail "pr ready"
out=$(driver_step_ship 109 2>&1); rc=$?
fix_gh_ok
want "it refuses"                        "24" "$rc"
want_not_in "and never claims a hand-off" 'Handing off' "$out"
want_not_in "auto is not armed over it"   'pr merge' "$(cat "$GH_LOG")"

echo "--- or one auto-merge would not arm on ---"
: > "$GH_LOG"
setup_wt 110
driver_state_put 110 review '{"verdict":"SHIP","findings":[]}'
fix_gh_fail "pr merge"
out=$(driver_step_ship 110 2>&1); rc=$?
fix_gh_ok
want "it refuses"                        "24" "$rc"
want_not_in "and never claims a hand-off" 'Handing off' "$out"

echo "--- the trunk is found on origin, not only locally ---"
# start deliberately prefers origin/<trunk> because a fresh clone may have no local
# branch of that name. ship measured against the LOCAL one, so in that clone a
# finished ticket counted zero commits and refused — and, being the only unfinished
# step, refused again on every resume.
: > "$GH_LOG"
setup_wt 106
driver_state_put 106 review '{"verdict":"SHIP","findings":[]}'
# `branch -D` refuses a branch that is checked out, and REPO's own HEAD is on it —
# so the first version of this case deleted nothing and passed against the defect.
# Detach first, and prove the ref is actually gone before running the step.
git -C "$REPO" checkout -q --detach
git -C "$REPO" branch -q -D develop
want "the local trunk really is gone" "" \
  "$(git -C "$REPO" rev-parse --verify -q develop 2>/dev/null)"
out=$(driver_step_ship 106 2>&1); rc=$?
git -C "$REPO" branch -q develop origin/develop && git -C "$REPO" checkout -q develop
want "it still finds the commits" "0" "$rc"
want_not_in "and does not claim there are none" 'no commits' "$out"

echo "--- past the review rounds with blockers still open: it refuses ONCE, answerably ---"
# review returns OK on the round after the last one so the leftovers can be filed.
# ship then refuses anything that is not SHIP — correctly, because a blocker is a
# dead control, a broken flow or a data-honesty failure and none of those ship. What
# it must not do is refuse with a code: review is recorded finished, so every resume
# walks straight back here, and the operator needs the blockers, not exit 24.
: > "$GH_LOG"
setup_wt 107
driver_state_put 107 review '{"verdict":"BLOCKED","findings":[{"file":"a.ts","line":9,"grade":"critical","summary":"the save button calls nothing","reason":"the person believes their work is saved and it is not"},{"file":"b.ts","line":4,"grade":"minor","summary":"the row is a spacing step out","reason":"it reads as misaligned"}]}'
driver_state_bump 107 review; driver_state_bump 107 review; driver_state_bump 107 review
out=$(driver_step_ship 107 2>&1); rc=$?
want "it refuses"                      "24" "$rc"
want_in "naming the blocker"           'the save button calls nothing' "$out"
want_in "and where it is"              'a.ts:9' "$out"
want_in "and says the rounds are spent" "$DRIVER_MAX_REVIEW_ROUNDS" "$out"
want_in "the work is still pushed and visible" 'pr create.*--draft' "$(cat "$GH_LOG")"
want_not_in "but never marked ready"   'pr ready' "$(cat "$GH_LOG")"
# AND THE BLOCKERS HAVE TO LEAVE THE MACHINE. driver_say writes stdout and a log file
# in the state directory — the one place a handover must not depend on, because a park
# exists to be read by somebody who is not this process. The note is what the park
# brief asks the operator to act on.
want_in "the blockers are left for the handover" 'the save button calls nothing' \
  "$(driver_state_get 107 park_note)"
want_in "with the file and line"                 'a.ts:9' "$(driver_state_get 107 park_note)"
# ONLY WHAT BLOCKS. A Minor left the review as its own follow-up ticket, so listing it
# here hands the operator polish to "clear" before a merge — the exact weighting the
# grade exists to remove. It must not appear on the refusal or in the park note.
want_not_in "and the Minor is NOT something to clear" 'spacing step out' "$out"
want_not_in "nor in the handover note"                'spacing step out' "$(driver_state_get 107 park_note)"
want_in "the count is of what blocks, not of everything" '1 critical/major' "$out"

echo "--- a branch with no commits on it has nothing to ship ---"
: > "$GH_LOG"
git -C "$REPO" worktree add -q "$FIX/wt111" -b tkt-111/work develop
driver_state_init 111 --worktree "$FIX/wt111" --branch tkt-111/work
driver_state_put 111 review '{"verdict":"SHIP","findings":[]}'
fix_issue 111 OPEN "status:claimed"
out=$(driver_step_ship 111 2>&1); rc=$?
want "an empty branch refuses" "24" "$rc"
want_in "and says so"          'no commits' "$out"

exit $FAILED
