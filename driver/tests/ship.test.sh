#!/usr/bin/env bash
# ship.test.sh — the last step, and the one whose mistakes are public. The two
# that matter: a pull request is opened as a DRAFT and only marked ready once the
# review verdict is in, and the run ENDS at the push rather than watching CI.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
# The gate cap at 1, so a second red here is past it.
export DRIVER_MAX_GATE_FIXES=1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
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
want_in "the body closes its ticket"     'pr create .*--body Closes #101' "$(tr '\n' ' ' < "$GH_LOG")"
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

echo "--- past the size cap a finished build still ships, and says its size ---"
# The limit splits plans before they build; a finished build is never stranded for size
# (#12273 finished at 37 files and parked "split needed", 2026-10-23).
wide_wt() { # <ticket> <files> [lockfile] — a branch changing that many files
  local t=$1 n=$2 wt i
  wt="$FIX/wt$t"
  git -C "$REPO" worktree add -q "$wt" -b "tkt-$t/work" develop
  i=0; while [ "$i" -lt "$n" ]; do i=$((i+1)); printf 'f %s\n' "$i" > "$wt/w$t-$i.txt"; done
  [ -z "${3:-}" ] || printf '{}\n' > "$wt/package-lock.json"
  git -C "$wt" add -A; git -C "$wt" commit -qm "feat: wide $t"
  driver_state_init "$t" --worktree "$wt" --branch "tkt-$t/work"
  driver_state_set "$t" claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
  fix_issue "$t" OPEN "status:claimed"
}
create_body() { tr '\n' ' ' < "$GH_LOG"; }
: > "$GH_LOG"; wide_wt 761 21
out=$(driver_step_ship 761 2>&1); rc=$?
want_not_in "21 files: no split needed"      'split needed' "$out"
want_in "  it says its size and ships"    'tkt-761/work changes 21 files, over driver.split.maxFiles \(20.* it ships' "$out"
want_in "  the draft is opened"           'pr create.*--draft' "$(cat "$GH_LOG")"
want_in "  and the PR says its size"      '## Size.*This change is 21 files, over the 20-file size limit' "$(create_body)"
want "  nothing parks it for size"        "" "$(driver_state_get 761 park_split)"
: > "$GH_LOG"; wide_wt 762 20 lock
out=$(driver_step_ship 762 2>&1); rc=$?
want_not_in "20 files and a lockfile: not over the cap" 'over driver.split.maxFiles' "$out"
want_not_in "  and no Size section"       '## Size' "$(create_body)"
: > "$GH_LOG"; wide_wt 763 25
jq '.driver.split.maxFiles = 0' "$HARNESS_CFG" > "$FIX/cfg0.json"
out=$(HARNESS_CFG="$FIX/cfg0.json" driver_step_ship 763 2>&1); rc=$?
want_not_in "maxFiles 0 says nothing of size"  'over driver.split.maxFiles' "$out"
: > "$GH_LOG"; wide_wt 764 6
jq '.driver.split.maxFiles = 5' "$HARNESS_CFG" > "$FIX/cfg5.json"
out=$(HARNESS_CFG="$FIX/cfg5.json" driver_step_ship 764 2>&1); rc=$?
want_in "the cap is a setting: 6 over 5"   'tkt-764/work changes 6 files, over driver.split.maxFiles \(5' "$out"

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
# BACK TO FIX FIRST, not a park: a park was left ready as the driver's fault and every
# resume walked straight back here (#13620). Ship's own rounds are bounded.
for n in 1 2; do
  out=$(driver_step_ship 107 2>&1); rc=$?
  want "ship's round $n goes back to fix"   "30" "$rc"
  want_in "saying so"                       'back to fix, then review again' "$out"
done
want "two rounds are counted"           "2" "$(driver_state_count 107 ship_rework)"
out=$(driver_step_ship 107 2>&1); rc=$?
want "past its rounds it refuses"      "24" "$rc"
want "and the park is the PM's, not left ready" "pm" "$(driver_state_get 107 park_cause)"
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
# A MINOR BLOCKS TOO, so it is on the refusal and in the handover: it is fixed in
# this change, never filed as a follow-up.
want_in "and the Minor is something to clear" 'spacing step out' "$out"
want_in "in the handover note too"            'spacing step out' "$(driver_state_get 107 park_note)"
want_in "the count is of what blocks"         '2 blocking' "$out"

echo "--- a branch with no commits on it has nothing to ship ---"
: > "$GH_LOG"
git -C "$REPO" worktree add -q "$FIX/wt111" -b tkt-111/work develop
driver_state_init 111 --worktree "$FIX/wt111" --branch tkt-111/work
driver_state_put 111 review '{"verdict":"SHIP","findings":[]}'
fix_issue 111 OPEN "status:claimed"
out=$(driver_step_ship 111 2>&1); rc=$?
want "an empty branch refuses" "24" "$rc"
want_in "and says so"          'no commits' "$out"

echo "--- a branch that deletes a test stays a draft until the body accounts for it ---"
# The body ship writes has no "## Deleted tests" section, so a deleted test must stop
# the hand-off: pushed and visible as a draft, never marked ready, never auto-merged,
# and the file named on the park note for whoever picks it up.
: > "$GH_LOG"
git -C "$REPO" checkout -q develop
printf "it('a writer can post for a teammate', () => {});\n" > "$REPO/pinned.test.ts"
git -C "$REPO" add pinned.test.ts
git -C "$REPO" -c user.email=t@example.invalid -c user.name=T commit -qm "test: pin it"
git -C "$REPO" push -q origin develop
git -C "$REPO" worktree add -q "$FIX/wt112" -b tkt-112/work develop
git -C "$FIX/wt112" rm -q pinned.test.ts
git -C "$FIX/wt112" -c user.email=t@example.invalid -c user.name=T commit -qm "feat: rebuild"
driver_state_init 112 --worktree "$FIX/wt112" --branch tkt-112/work
driver_state_put 112 review '{"verdict":"SHIP","findings":[]}'
fix_issue 112 OPEN "status:claimed"
out=$(driver_step_ship 112 2>&1); rc=$?
want "a reviewed branch that deletes a test refuses" "24" "$rc"
want_in "naming the file"                  'pinned.test.ts' "$out"
want_in "the work is pushed as a draft"    'pr create.*--draft' "$(cat "$GH_LOG")"
want_not_in "but never marked ready"       'pr ready' "$(cat "$GH_LOG")"
want_not_in "and auto is never armed"      'pr merge' "$(cat "$GH_LOG")"
want_in "the file is on the park note"     'pinned.test.ts' "$(driver_state_get 112 park_note)"

echo "--- a refused push keeps what the pre-push said (#11163) ---"
# Trial 3: ship said "read its own output" and that output was nowhere; the failing
# check had to be found by re-running the push by hand.
setup_wt 113
driver_state_put 113 review '{"verdict":"SHIP","findings":[]}'
for st in start plan build self-check review record; do driver_state_done 113 "$st"; done
mkdir -p "$FIX/hooks113"
cat > "$FIX/hooks113/pre-push" <<'SH'
#!/usr/bin/env sh
echo "→ Pre-push: checking UI changes carry a design-critic verdict…"
echo "✗ check:design-critic-attested — this diff touches UI with no matching design verdict."
exit 1
SH
chmod +x "$FIX/hooks113/pre-push"
git -C "$FIX/wt113" config core.hooksPath "$FIX/hooks113"
: > "$GH_LOG"
out=$(driver_step_ship 113 2>&1); rc=$?
# The first refusal goes to fix with the hook's output as the finding (#236).
want "the first refused push goes to fix" "30" "$rc"
want_in "the log names the check that said no" 'check:design-critic-attested' "$out"
want_in "the whole output is kept" 'Pre-push: checking UI changes' \
  "$(cat "$(driver_state_dir 113)/steps/ship-push.out" 2>/dev/null)"
want_in "fix is handed the check as a finding" 'check:design-critic-attested' \
  "$(jq -r '.[0].output' "$(driver_state_dir 113)/steps/self-check.findings.json" 2>/dev/null)"
want_not_in "and nothing was opened" 'pr create' "$(cat "$GH_LOG")"
out=$(driver_step_ship 113 2>&1); rc=$?
want "a second refused push parks" "24" "$rc"
want_in "and the park note carries it" 'check:design-critic-attested' "$(driver_state_get 113 park_note)"

echo "--- a hook that prints 'fatal:' is still a hook's refusal: it goes to fix ---"
setup_wt 118
driver_state_put 118 review '{"verdict":"SHIP","findings":[]}'
for st in start plan build self-check review record; do driver_state_done 118 "$st"; done
mkdir -p "$FIX/hooks118"
printf '#!/usr/bin/env sh\necho "fatal: knip found unused exports"\nexit 1\n' > "$FIX/hooks118/pre-push"; chmod +x "$FIX/hooks118/pre-push"
git -C "$FIX/wt118" config core.hooksPath "$FIX/hooks118"
out=$(driver_step_ship 118 2>&1); rc=$?
want "a hook's fatal: line goes to fix"      "30" "$rc"
git -C "$FIX/wt118" config --unset core.hooksPath

echo "--- a sign-off refusal at the push is the owner's call: it parks, never goes to fix ---"
setup_wt 119
driver_state_put 119 review '{"verdict":"SHIP","findings":[]}'
for st in start plan build self-check review record; do driver_state_done 119 "$st"; done
mkdir -p "$FIX/hooks119"
printf '#!/usr/bin/env sh\necho "✗ pre-push blocked: sign-off comes last. The owner signed PR #7 at abc1234, and this push changes its screens: a.tsx" >&2\nexit 1\n' > "$FIX/hooks119/pre-push"; chmod +x "$FIX/hooks119/pre-push"
git -C "$FIX/wt119" config core.hooksPath "$FIX/hooks119"
out=$(driver_step_ship 119 2>&1); rc=$?
want "it parks"                              "24" "$rc"
want "nothing goes to fix"                   "absent" "$([ -e "$(driver_state_dir 119)/steps/self-check.findings.json" ] && echo present || echo absent)"
want_in "the note is for the owner"          '^Needs the owner: .*abc1234' "$(driver_state_get 119 park_note)"
git -C "$FIX/wt119" config --unset core.hooksPath

echo "--- a push the remote refused is not a finding: it parks ---"
setup_wt 117
driver_state_put 117 review '{"verdict":"SHIP","findings":[]}'
for st in start plan build self-check review record; do driver_state_done 117 "$st"; done
git -C "$FIX/wt117" remote set-url origin "$FIX/no-such-origin"
out=$(driver_step_ship 117 2>&1); rc=$?
want "an unreachable remote parks" "24" "$rc"
want "and leaves fix nothing" "absent" "$([ -e "$(driver_state_dir 117)/steps/self-check.findings.json" ] && echo present || echo absent)"
git -C "$FIX/wt117" remote set-url origin "$FIX/origin"
# Worktrees share the repository's config, so the refusing hook would follow every
# later case in this file.
git -C "$FIX/wt113" config --unset core.hooksPath

echo "--- a push the sign-off guard refuses parks for the owner, saying so ---"
setup_wt 213
driver_state_put 213 review '{"verdict":"SHIP","findings":[]}'
for st in start plan build self-check review record; do driver_state_done 213 "$st"; done
mkdir -p "$FIX/hooks213"
cat > "$FIX/hooks213/pre-push" <<'SH'
#!/usr/bin/env sh
echo "✗ pre-push blocked: sign-off comes last. The owner signed PR #7 at abc1234, and this push changes its screens: apps/web/page.tsx" >&2
exit 1
SH
chmod +x "$FIX/hooks213/pre-push"
git -C "$FIX/wt213" config core.hooksPath "$FIX/hooks213"
: > "$GH_LOG"
out=$(driver_step_ship 213 2>&1); rc=$?
want "the push is refused" "24" "$rc"
want_in "the log says the owner signed" 'the owner has signed this PR' "$out"
want_in "the park note is for the owner" '^Needs the owner: .*signed PR #7 at abc1234.*apps/web/page.tsx.*follow-up ticket.*pixel-change-after-signoff' "$(driver_state_get 213 park_note)"
want_not_in "and nothing was opened" 'pr create' "$(cat "$GH_LOG")"
git -C "$FIX/wt213" config --unset core.hooksPath

echo "--- the park escape in the caller's environment never waves a ship past the gate ---"
# The park escape (PARK_PUSH=1, or the project's driver.parkPushEnv) lets a park's
# push of a draft branch skip quality gates. A ship is the push that has to pass
# them: an escape inherited from the shell would let it skip, so ship strips it.
CFG_KEEP115="$FIX/harness.json.keep115"; cp "$HARNESS_CFG_PATH" "$CFG_KEEP115"
for esc in PARK_PUSH MY_PARK; do
  n=131; [ "$esc" = MY_PARK ] && n=132
  jq --arg e "$esc" '.driver.parkPushEnv = $e' "$CFG_KEEP115" > "$HARNESS_CFG_PATH"
  setup_wt $n
  driver_state_put $n review '{"verdict":"SHIP","findings":[]}'
  for st in start plan build self-check review record; do driver_state_done $n "$st"; done
  mkdir -p "$FIX/hooks$n"
  printf '#!/usr/bin/env sh\n[ "${%s:-}" = "1" ] && exit 0\necho "✗ format:changed"\nexit 1\n' "$esc" > "$FIX/hooks$n/pre-push"
  chmod +x "$FIX/hooks$n/pre-push"
  git -C "$FIX/wt$n" config core.hooksPath "$FIX/hooks$n"
  : > "$GH_LOG"
  out=$(export PARK_PUSH=1 MY_PARK=1; driver_step_ship $n 2>&1); rc=$?
  git -C "$FIX/wt$n" config --unset core.hooksPath
  # Refused, and as a hook's refusal the first one goes to fix (#236): 30, never a push.
  want "[$esc] the ship's push is refused, to fix"  "30" "$rc"
  want_in "[$esc] and ship reports the hook's line" '✗ format:changed' "$out"
  want "[$esc] the branch is not on origin"         "0" \
    "$(git -C "$FIX/origin" rev-parse --verify tkt-$n/work >/dev/null 2>&1 && echo 1 || echo 0)"
  want_not_in "[$esc] and nothing was opened"       'pr create' "$(cat "$GH_LOG")"
done
cp "$CFG_KEEP115" "$HARNESS_CFG_PATH"

echo "--- the PR body never claims a parity check that was not made (#11205) ---"
setup_wt 114
driver_state_put 114 review '{"verdict":"SHIP","findings":[]}'
for st in start plan build self-check review record; do driver_state_done 114 "$st"; done
driver_state_set 114 design_source debugged
driver_state_set 114 renders "$(printf 'desk light\tshots/a.png\tlight\t/dashboard/desk')"
: > "$GH_LOG"
out=$(driver_step_ship 114 2>&1)
want_in "it says no parity check was made" 'no approved picture, so no parity check was made' "$(cat "$GH_LOG")"
want_not_in "and not that renders were compared" 'compared against the approved design' "$(cat "$GH_LOG")"

echo "--- a test the build reported removing is accounted for in the body, and ships (#11222) ---"
git -C "$REPO" worktree add -q "$FIX/wt116" -b tkt-116/work develop
git -C "$FIX/wt116" rm -q pinned.test.ts
git -C "$FIX/wt116" -c user.email=t@example.invalid -c user.name=T commit -qm "feat: rebuild without it"
driver_state_init 116 --worktree "$FIX/wt116" --branch tkt-116/work
driver_state_put 116 review '{"verdict":"SHIP","findings":[]}'
fix_issue 116 OPEN "status:claimed"
printf '%s\n' '{"file":"pinned.test.ts","removedBecause":"posting for a teammate moved to the access rules,\npinned by their own test"}' \
  > "$(driver_state_dir 116)/steps/replaced.jsonl"
: > "$GH_LOG"
out=$(driver_step_ship 116 2>&1); rc=$?
want "it ships"                                   "0" "$rc"
want_in "the body carries the section the build reported" 'Deleted tests' "$(cat "$GH_LOG")"
want_in "with the reason, in the build's words, on one line"  'removed on purpose: posting for a teammate moved to the access rules, pinned by their own test' "$(cat "$GH_LOG")"
want_in "and it is marked ready"                  'pr ready' "$(cat "$GH_LOG")"

echo "--- a fix round's report counts too, and a removal nobody reported still parks ---"
git -C "$REPO" worktree add -q "$FIX/wt117" -b tkt-117/work develop
git -C "$FIX/wt117" rm -q pinned.test.ts
git -C "$FIX/wt117" -c user.email=t@example.invalid -c user.name=T commit -qm "feat: rebuild without it"
driver_state_init 117 --worktree "$FIX/wt117" --branch tkt-117/work
driver_state_put 117 review '{"verdict":"SHIP","findings":[]}'
fix_issue 117 OPEN "status:claimed"
printf '%s\n' '{"file":"pinned.test.ts"}' > "$(driver_state_dir 117)/steps/replaced.jsonl"
out=$(driver_step_ship 117 2>&1); rc=$?
want "unreported (an entry with neither field), it stays a draft" "24" "$rc"
printf '%s\n' '{"file":"pinned.test.ts","removedBecause":"retired with the old screen"}' '{"file":"pinned.test.ts"}' \
  >> "$(driver_state_dir 117)/steps/replaced.jsonl"
printf '[{"number":77}]\n' > "$FIX/gh/prs.json"
: > "$GH_LOG"
out=$(driver_step_ship 117 2>&1); rc=$?
want "reported later, it ships — an empty later entry does not hide it" "0" "$rc"
want_in "the open PR is rewritten by number"        'pr edit 77' "$(cat "$GH_LOG")"
want_in "with the ticket's own title"               'pr edit 77 .*--title #117: ' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "and the body carrying the section"         'pr edit 77 .*## Deleted tests' "$(tr '\n' ' ' < "$GH_LOG")"

echo "--- a reworded case in a surviving file, covered by that same file ---"
git -C "$REPO" worktree add -q "$FIX/wt118" -b tkt-118/work develop
printf "it('a writer can post for a teammate, and the post is theirs', () => {});\n" > "$FIX/wt118/pinned.test.ts"
git -C "$FIX/wt118" add pinned.test.ts
git -C "$FIX/wt118" -c user.email=t@example.invalid -c user.name=T commit -qm "test: reword it"
driver_state_init 118 --worktree "$FIX/wt118" --branch tkt-118/work
driver_state_put 118 review '{"verdict":"SHIP","findings":[]}'
fix_issue 118 OPEN "status:claimed"
printf '%s\n' '{"file":"pinned.test.ts","coveredBy":"pinned.test.ts"}' > "$(driver_state_dir 118)/steps/replaced.jsonl"
printf '[]\n' > "$FIX/gh/prs.json"
out=$(driver_step_ship 118 2>&1); rc=$?
want "it ships"                                     "0" "$rc"
want_in "covered by the same file"                  'pinned.test.ts. → covered by .pinned.test.ts.' "$(cat "$GH_LOG")"

echo "--- an existing PR that cannot be rewritten refuses ---"
git -C "$REPO" worktree add -q "$FIX/wt119" -b tkt-119/work develop
printf 'x\n' > "$FIX/wt119/f119.txt"; git -C "$FIX/wt119" add f119.txt
git -C "$FIX/wt119" -c user.email=t@example.invalid -c user.name=T commit -qm "feat: thing"
driver_state_init 119 --worktree "$FIX/wt119" --branch tkt-119/work
driver_state_put 119 review '{"verdict":"SHIP","findings":[]}'
fix_issue 119 OPEN "status:claimed"
printf '[{"number":79}]\n' > "$FIX/gh/prs.json"
printf 'pr edit\n' > "$FIX/gh-fail"
: > "$GH_LOG"
out=$(driver_step_ship 119 2>&1); rc=$?
want "it refuses"                                   "24" "$rc"
want_in "saying it would ship the park's words"     "park's words" "$out"
want_not_in "and it is never marked ready"          'pr ready' "$(cat "$GH_LOG")"
rm -f "$FIX/gh-fail"; printf '[]\n' > "$FIX/gh/prs.json"

echo "--- a pull request lookup that fails refuses, rather than reading as none ---"
git -C "$REPO" worktree add -q "$FIX/wt121" -b tkt-121/work develop
printf 'x\n' > "$FIX/wt121/f121.txt"; git -C "$FIX/wt121" add f121.txt
git -C "$FIX/wt121" -c user.email=t@example.invalid -c user.name=T commit -qm "feat: thing"
driver_state_init 121 --worktree "$FIX/wt121" --branch tkt-121/work
driver_state_put 121 review '{"verdict":"SHIP","findings":[]}'
fix_issue 121 OPEN "status:claimed"
printf 'pr list\n' > "$FIX/gh-fail"
: > "$GH_LOG"
out=$(DRIVER_LOOKUP_RETRY_SEC=0 driver_step_ship 121 2>&1); rc=$?
want "it stops as unread, not a refusal"   "26" "$rc"
want_in "saying it could not ask"          'could not ask GitHub' "$out"
want_not_in "and nothing is marked ready"  'pr ready' "$(cat "$GH_LOG")"
rm -f "$FIX/gh-fail"
echo "--- when the hooks cannot be made to run, nothing is pushed ---"
setup_wt 130
driver_state_put 130 review '{"verdict":"SHIP","findings":[]}'
driver_state_bump 130 review
for st in start plan build self-check review record; do driver_state_done 130 "$st"; done
printf '#!/usr/bin/env bash\necho "🛑 ensure-hooks: planted refusal" >&2\nexit 1\n' > "$BIN/ensure-hooks-refuses"
chmod +x "$BIN/ensure-hooks-refuses"
out=$(DRIVER_ENSURE_HOOKS="$BIN/ensure-hooks-refuses" driver_step_ship 130 2>&1); rc=$?
want "it refuses"                          "24" "$rc"
want_in "with the script's own reason"     'planted refusal' "$out"
want "the branch never reached origin"     "0" \
  "$(git -C "$FIX/origin" rev-parse --verify tkt-130/work >/dev/null 2>&1 && echo 1 || echo 0)"

echo "--- a repair ships onto the PR it repaired, and leaves that PR's words alone ---"
# The PR may be a person's, or /claim's, with a Lesson section and a body a reviewer
# already read. A repair says what it did in a comment and rewrites none of it.
setup_wt 140
driver_state_set 140 mode repair; driver_state_set 140 pr 88
driver_state_put 140 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 140 review
driver_state_put 140 repair '{"step":"repair","cause":"the reader dropped its error branch"}'
for st in reenter repair fix self-check review record; do driver_state_done 140 "$st"; done
printf '[{"number":88}]\n' > "$FIX/gh/prs.json"
: > "$FIX/pr-created-88"; : > "$FIX/pr-created-tkt-140_work"
printf '{"number":88,"isDraft":false,"body":"A body a person wrote.\\n\\n## Lesson\\n- Principle: kept.\\n\\nCloses #140"}\n' > "$FIX/gh/pr-view.json"
: > "$GH_LOG"
out=$(driver_step_ship 140 2>&1); rc=$?
want "it ships"                              "0" "$rc"
want "the branch is pushed to the same name" "$(git -C "$FIX/wt140" rev-parse HEAD)" "$(git -C "$FIX/origin" rev-parse tkt-140/work 2>/dev/null)"
want_not_in "the PR's title and body are not rewritten" 'pr edit' "$(cat "$GH_LOG")"
want_not_in "no second PR is opened"         'pr create' "$(cat "$GH_LOG")"
want_in "the deleted-tests check reads the PR's own body" 'pr view 88 .*--json body' "$(cat "$GH_LOG")"
want_in "it is ready"                        'pr ready' "$(cat "$GH_LOG")"
want_in "auto-merge is armed"                'pr merge.*--auto' "$(cat "$GH_LOG")"
want_in "and the repair is said on the PR"   'pr comment 88 .*Repaired by the driver' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "with its cause"                     'the reader dropped its error branch' "$(cat "$GH_LOG")"
rm -f "$FIX/gh/pr-view.json"

echo "--- a repair puts back the closing line a PR's body lacks, and keeps every word ---"
# #5654: a body without "Closes #n" on a branch without the prefix — every reader that
# finds a ticket's PR missed it, and its repair parked "no open pull request".
setup_wt 150
driver_state_set 150 mode repair; driver_state_set 150 pr 99
driver_state_put 150 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 150 review
for st in reenter repair fix self-check review record; do driver_state_done 150 "$st"; done
printf '[{"number":99}]\n' > "$FIX/gh/prs.json"
: > "$FIX/pr-created-99"; : > "$FIX/pr-created-tkt-150_work"
printf '{"number":99,"isDraft":false,"body":"Closes ticket 150.\\n\\n## Lesson\\n- Principle: kept."}\n' > "$FIX/gh/pr-view.json"
: > "$GH_LOG"
out=$(driver_step_ship 150 2>&1); rc=$?
want "it ships"                              "0" "$rc"
want_in "the body gets the line, its words kept" 'pr edit 99 .*--body Closes ticket 150\.  ## Lesson - Principle: kept\.  Closes #150' "$(tr '\n' ' ' < "$GH_LOG")"
want_not_in "the title is left alone"        'pr edit 99 .*--title' "$(tr '\n' ' ' < "$GH_LOG")"
rm -f "$FIX/gh/pr-view.json"

echo "--- a repair whose PR has gone refuses rather than opening a new one ---"
setup_wt 141
driver_state_set 141 mode repair; driver_state_set 141 pr 89
driver_state_put 141 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 141 review
printf '[]\n' > "$FIX/gh/prs.json"; : > "$GH_LOG"
# Read afresh it is CLOSED, never merged: the park stands.
: > "$FIX/pr-created-89"; printf '{"number":89,"state":"CLOSED","mergedAt":null,"headRefOid":""}\n' > "$FIX/gh/pr-view.json"
out=$(driver_step_ship 141 2>&1); rc=$?
want "it refuses"                            "24" "$rc"
want_in "saying the PR is no longer open"    'no longer open' "$out"
want_in "after reading whether it merged"    'pr view 89 .*state,mergedAt' "$(cat "$GH_LOG")"
want_in "and the park says it closed"        'closed while it was being repaired' "$(driver_state_get 141 park_note)"
rm -f "$FIX/gh/pr-view.json"
want_not_in "and opens none"                 'pr create' "$(cat "$GH_LOG")"

echo "--- a repair whose PR MERGED mid-run ends clean: no park, its extra commit backed up ---"
# #13676 parked "closed while it was being repaired" on a PR automerge had landed.
setup_wt 371
driver_state_set 371 mode repair; driver_state_set 371 pr 191
git -C "$FIX/wt371" push -q origin tkt-371/work; MERGED_HEAD=$(git -C "$FIX/wt371" rev-parse HEAD)
driver_state_set 371 repair_base "$MERGED_HEAD"
printf 'late\n' > "$FIX/wt371/r371.txt"; git -C "$FIX/wt371" add r371.txt; git -C "$FIX/wt371" commit -qm "fix: late repair 371"
LATE=$(git -C "$FIX/wt371" rev-parse HEAD)
driver_state_put 371 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 371 review
printf '[]\n' > "$FIX/gh/prs.json"; : > "$GH_LOG"
: > "$FIX/pr-created-191"; printf '{"number":191,"state":"MERGED","mergedAt":"2026-10-21T07:14:34Z","headRefOid":"%s"}\n' "$MERGED_HEAD" > "$FIX/gh/pr-view.json"
RELS="$FIX/rel371"; : > "$RELS"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$RELS" > "$BIN/claim-lock-371"; chmod +x "$BIN/claim-lock-371"
out=$(CL="$BIN/claim-lock-371" driver_step_ship 371 2>&1); rc=$?
want "it ends as nothing owed (exit 0 through the run)" "$DRIVER_E_NOOP" "$rc"
want_in "saying it merged while repairing"   'merged at 2026-10-21T07:14:34Z while repairing' "$out"
want "no park note is left"                  "" "$(driver_state_get 371 park_note)"
want_in "the extra commit is named"          'fix: late repair 371' "$out"
want "and backed up on a stranded ref"       "$LATE" "$(git -C "$FIX/origin" for-each-ref --format='%(objectname)' 'refs/stranded/371/' | head -1)"
want "the merged branch is not pushed to"    "$MERGED_HEAD" "$(git -C "$FIX/origin" rev-parse tkt-371/work)"
want_in "the claim is released"              'release 371' "$(cat "$RELS")"
want_not_in "no PR is opened"                'pr create' "$(cat "$GH_LOG")"

echo "--- a repair whose PR merged with nothing past its head backs nothing up ---"
setup_wt 372
driver_state_set 372 mode repair; driver_state_set 372 pr 192
git -C "$FIX/wt372" push -q origin tkt-372/work
driver_state_put 372 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 372 review
: > "$FIX/pr-created-192"; printf '{"number":192,"state":"MERGED","mergedAt":"2026-10-21T07:14:34Z","headRefOid":"%s"}\n' "$(git -C "$FIX/wt372" rev-parse HEAD)" > "$FIX/gh/pr-view.json"
out=$(driver_step_ship 372 2>&1); rc=$?
want "it ends clean"                         "$DRIVER_E_NOOP" "$rc"
want "no stranded ref"                       "" "$(git -C "$FIX/origin" for-each-ref 'refs/stranded/372/')"
rm -f "$FIX/gh/pr-view.json"

echo "--- a repair the review did not pass is not pushed: on an armed PR the push is the merge ---"
setup_wt 142
driver_state_set 142 mode repair; driver_state_set 142 pr 90
git -C "$FIX/wt142" push -q origin tkt-142/work; ORIG=$(git -C "$FIX/wt142" rev-parse HEAD)
printf 'repair\n' > "$FIX/wt142/r142.txt"; git -C "$FIX/wt142" add r142.txt; git -C "$FIX/wt142" commit -qm "fix: repair"
driver_state_put 142 review '{"verdict":"BLOCKED","findings":[{"grade":"major","summary":"x"}]}'; driver_state_bump 142 review
printf '[{"number":90}]\n' > "$FIX/gh/prs.json"; : > "$GH_LOG"
out=$(driver_step_ship 142 2>&1); rc=$?
want "with rounds left it goes back to fix"  "30" "$rc"
want "pushing nothing"                       "$ORIG" "$(git -C "$FIX/origin" rev-parse tkt-142/work)"
driver_state_bump 142 ship_rework
out=$(driver_step_ship 142 2>&1); rc=$?
want "it refuses"                            "24" "$rc"
want "origin still has the PR's old head"    "$ORIG" "$(git -C "$FIX/origin" rev-parse tkt-142/work)"
want_in "and it says why"                    'nothing is pushed' "$out"
printf '[]\n' > "$FIX/gh/prs.json"

echo "--- a repair that deletes a test is accounted for BEFORE the push: on an armed PR the push is the merge ---"
repair_wt() { # <ticket> <pr> — a repair-mode record on a pushed PR branch, reviewed SHIP
  local t=$1 pr=$2
  git -C "$REPO" worktree add -q "$FIX/wt$t" -b "tkt-$t/work" develop
  printf 'x\n' > "$FIX/wt$t/f$t.txt"; git -C "$FIX/wt$t" add "f$t.txt"
  git -C "$FIX/wt$t" -c user.email=t@example.invalid -c user.name=T commit -qm "feat: $t"
  git -C "$FIX/wt$t" push -q origin "tkt-$t/work"
  driver_state_init "$t" --worktree "$FIX/wt$t" --branch "tkt-$t/work"
  driver_state_set "$t" mode repair; driver_state_set "$t" pr "$pr"
  driver_state_put "$t" review '{"verdict":"SHIP","findings":[]}'; driver_state_bump "$t" review
  fix_issue "$t" OPEN "status:in-review"
  printf '[{"number":%s}]\n' "$pr" > "$FIX/gh/prs.json"
  : > "$FIX/pr-created-$pr"; : > "$FIX/pr-created-tkt-${t}_work"
  printf '{"number":%s,"isDraft":false,"body":"Its author wrote this."}\n' "$pr" > "$FIX/gh/pr-view.json"
}
repair_wt 143 92; ORIG=$(git -C "$FIX/wt143" rev-parse HEAD)
git -C "$FIX/wt143" rm -q pinned.test.ts
git -C "$FIX/wt143" -c user.email=t@example.invalid -c user.name=T commit -qm "fix: drop it"
: > "$GH_LOG"
out=$(driver_step_ship 143 2>&1); rc=$?
want "an unaccounted deletion refuses"       "24" "$rc"
want "and nothing reached origin"            "$ORIG" "$(git -C "$FIX/origin" rev-parse tkt-143/work)"
want_in "naming the file"                    'pinned.test.ts' "$out"

repair_wt 144 93
git -C "$FIX/wt144" rm -q pinned.test.ts
git -C "$FIX/wt144" -c user.email=t@example.invalid -c user.name=T commit -qm "fix: retire it"
printf '%s\n' '{"file":"pinned.test.ts","removedBecause":"the screen it pinned is retired"}' > "$(driver_state_dir 144)/steps/replaced.jsonl"
: > "$GH_LOG"
out=$(driver_step_ship 144 2>&1); rc=$?
want "an accounted deletion ships"           "0" "$rc"
want "the repair reached origin"             "$(git -C "$FIX/wt144" rev-parse HEAD)" "$(git -C "$FIX/origin" rev-parse tkt-144/work 2>/dev/null)"
want_in "the section is added to the PR body, where CI reads it" 'pr edit 93 .*--body Its author wrote this\..*## Deleted tests.*pinned.test.ts. → removed on purpose: the screen it pinned is retired' "$(tr '\n' ' ' < "$GH_LOG")"
want_not_in "and the title is left alone"   'pr edit 93 .*--title' "$(tr '\n' ' ' < "$GH_LOG")"
want "before the push, so CI's first run of the new head reads it" "pr edit" "$(grep -m1 -oE '^pr (edit|ready)' "$GH_LOG")"
rm -f "$FIX/gh/pr-view.json"; printf '[]\n' > "$FIX/gh/prs.json"

echo "--- a repair carrying conflict markers is never pushed ---"
repair_wt 145 95; ORIG=$(git -C "$FIX/wt145" rev-parse HEAD)
printf '<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> origin/develop\n' > "$FIX/wt145/m.txt"
git -C "$FIX/wt145" add m.txt; git -C "$FIX/wt145" -c user.email=t@example.invalid -c user.name=T commit -qm "merge"
out=$(driver_step_ship 145 2>&1); rc=$?
want "it refuses"                          "24" "$rc"
want "nothing reached origin"              "$ORIG" "$(git -C "$FIX/origin" rev-parse tkt-145/work)"
want_in "naming the file"                  'm.txt' "$out"
rm -f "$FIX/gh/pr-view.json"; printf '[]\n' > "$FIX/gh/prs.json"

echo "--- a branch that tracks the trunk still pushes to itself ---"
# A worktree cut from origin/develop tracks develop, and under push.default=upstream
# a push naming only the branch lands on develop.
: > "$GH_LOG"
setup_wt 131
git -C "$REPO" fetch -q origin
git -C "$FIX/wt131" branch -q --set-upstream-to=origin/develop
driver_state_put 131 review '{"verdict":"SHIP","findings":[]}'
driver_state_bump 131 review
for st in start plan build self-check review record; do driver_state_done 131 "$st"; done
TRUNK_BEFORE=$(git -C "$FIX/origin" rev-parse develop)
git -C "$REPO" config push.default upstream
out=$(driver_step_ship 131 2>&1); rc=$?
git -C "$REPO" config --unset push.default
want "it ships"                            "0" "$rc"
want "origin's develop did not move"       "$TRUNK_BEFORE" "$(git -C "$FIX/origin" rev-parse develop)"
want "the branch is on origin at its head" "$(git -C "$FIX/wt131" rev-parse HEAD)" \
  "$(git -C "$FIX/origin" rev-parse tkt-131/work 2>/dev/null)"

echo "--- a run's brief expires when the ticket ships ---"
setup_wt 146
driver_state_put 146 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 146 review
printf 'note\n' > "$FIX/rb146"; driver_state_set 146 run_brief "$FIX/rb146"
for st in start plan build self-check review record; do driver_state_done 146 "$st"; done
rc=0; driver_step_ship 146 >/dev/null 2>&1 || rc=$?
want "it ships"                              "0" "$rc"
want "and the brief is cleared"              "" "$(driver_state_get 146 run_brief)"

echo "--- a repair that changed nothing says so on the PR, not 'Repaired' ---"
repair_wt 147 96
: > "$GH_LOG"
rc=0; driver_step_ship 147 >/dev/null 2>&1 || rc=$?
want "it ships"                              "0" "$rc"
want_in "the comment says it re-checked, and changed nothing" 'pr comment 96 .*Re-checked by the driver.*nothing was red or clashing' "$(tr '\n' ' ' < "$GH_LOG")"
want_not_in "and does not claim a repair"    'pr comment 96 .*Repaired by the driver' "$(tr '\n' ' ' < "$GH_LOG")"
repair_wt 148 97
driver_state_put 148 repair '{"step":"repair","status":"unchanged","reason":"the PR already keeps the old label"}'
: > "$GH_LOG"
rc=0; driver_step_ship 148 >/dev/null 2>&1 || rc=$?
want_in "an unchanged answer is named as one" 'pr comment 97 .*Re-checked by the driver.*unchanged: the PR already keeps the old label' "$(tr '\n' ' ' < "$GH_LOG")"
rm -f "$FIX/gh/pr-view.json"; printf '[]\n' > "$FIX/gh/prs.json"

echo "--- a repair never readies a draft the driver did not build ---"
# 27 open drafts had no driver record; a repair readied and armed them, landing work
# their authors had left unfinished.
repair_wt 149 98; ORIG=$(git -C "$FIX/wt149" rev-parse HEAD)
printf 'fix\n' > "$FIX/wt149/r149.txt"; git -C "$FIX/wt149" add r149.txt
git -C "$FIX/wt149" -c user.email=t@example.invalid -c user.name=T commit -qm "fix: repair"
printf '[{"number":98,"isDraft":true}]\n' > "$FIX/gh/prs.json"; : > "$GH_LOG"
out=$(driver_step_ship 149 2>&1); rc=$?
want "a draft with no build on the record refuses" "24" "$rc"
want "nothing reached origin"                "$ORIG" "$(git -C "$FIX/origin" rev-parse tkt-149/work)"
want_not_in "never readied, never armed"     'pr ready|pr merge' "$(cat "$GH_LOG")"
want_in "the park note says why"             'draft the driver did not build' "$(driver_state_get 149 park_note)"
want_in "and sends it to the adoption"       'build-ticket 149 --adopt' "$(driver_state_get 149 park_note)"
driver_state_done 149 start
rc=0; driver_step_ship 149 >/dev/null 2>&1 || rc=$?
want "the driver's own draft (a build ran start) ships" "0" "$rc"
rm -f "$FIX/gh/pr-view.json"; printf '[]\n' > "$FIX/gh/prs.json"

echo "--- an adopted draft is readied only on the review's SHIP ---"
repair_wt 150 99; ORIG=$(git -C "$FIX/wt150" rev-parse HEAD)
printf 'done\n' > "$FIX/wt150/r150.txt"; git -C "$FIX/wt150" add r150.txt
git -C "$FIX/wt150" -c user.email=t@example.invalid -c user.name=T commit -qm "feat: finish the draft"
printf '[{"number":99,"isDraft":true}]\n' > "$FIX/gh/prs.json"
driver_state_set 150 adopted "2026-10-22T00:00:00Z"
driver_state_put 150 review '{"verdict":"SPIT-BACK","findings":[{"grade":"major","summary":"half the acceptance is missing"}]}'
: > "$GH_LOG"; rc=0; driver_step_ship 150 >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && ok "an adopted draft the review sent back is not shipped (rc $rc)" || bad "an adopted draft shipped on a SPIT-BACK"
want "nothing reached origin"                "$ORIG" "$(git -C "$FIX/origin" rev-parse tkt-150/work)"
want_not_in "and it is never readied"        'pr ready|pr merge' "$(cat "$GH_LOG")"
driver_state_put 150 review '{"verdict":"SHIP","findings":[]}'
: > "$GH_LOG"; rc=0; driver_step_ship 150 >/dev/null 2>&1 || rc=$?
want "an adopted draft the review passed ships" "0" "$rc"
want_in "readied, then armed"                'pr ready.*pr merge' "$(tr '\n' ' ' < "$GH_LOG")"
want "and its work reached origin"           "$(git -C "$FIX/wt150" rev-parse HEAD)" "$(git -C "$FIX/origin" rev-parse tkt-150/work 2>/dev/null)"
rm -f "$FIX/gh/pr-view.json"; printf '[]\n' > "$FIX/gh/prs.json"

echo "--- a plan the run wrote into a TRACKED scratch folder is committed, not refused ---"
# A project that keeps docs/superpowers in git: the sweep leaves the folder alone
# (it is the change there), so the run's own new plan file sat uncommitted and ship
# refused "uncommitted changes" on five finished tickets (2026-10-18).
setup_wt 194
driver_state_set 194 mode new
mkdir -p "$FIX/wt194/docs/superpowers/plans"
printf 'kept\n' > "$FIX/wt194/docs/superpowers/plans/older.md"
git -C "$FIX/wt194" add docs/superpowers/plans/older.md; git -C "$FIX/wt194" commit -qm "docs: an older plan the project keeps"
printf '# plan for 194\n' > "$FIX/wt194/docs/superpowers/plans/2026-10-18-194-plan.md"
driver_state_put 194 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 194 review
for st in start plan build self-check review record; do driver_state_done 194 "$st"; done
rc=0; out=$(driver_step_ship 194 2>&1) || rc=$?
want "it ships"                              "0" "$rc"
want "the plan is committed on the branch"   "yes" \
  "$(git -C "$FIX/wt194" ls-files --error-unmatch docs/superpowers/plans/2026-10-18-194-plan.md >/dev/null 2>&1 && echo yes)"
want "and the tree is clean"                 "" "$(git -C "$FIX/wt194" status --porcelain)"

echo "--- evidence follows the approved picture, not the builder's list ---"
# The builder listed the one region it built; the picture had a menu and a phone frame
# too, and nobody photographed them. Every region the picture declares is planned.
: > "$GH_LOG"
setup_wt 195
mkdir -p "$FIX/wt195/.design" "$FIX/wt195/docs/evidence/195"
cat > "$FIX/wt195/.design/voices-mock.html" <<'HTML'
<html><body>
<section data-evidence-shot="voices-grid-laptop-light" data-evidence-route="/settings/voices" data-evidence-viewport="laptop" data-evidence-theme="light"></section>
<section data-evidence-shot="voices-menu-laptop-dark" data-evidence-route="/settings/voices" data-evidence-viewport="laptop" data-evidence-theme="dark" data-evidence-setup='press Meta+K'></section>
<section data-evidence-shot="voices-share-phone-light" data-evidence-route="/voices/share" data-evidence-viewport="phone" data-evidence-theme="light"></section>
</body></html>
HTML
# The builder's own plan named only the grid, with a setup of its own.
printf '{"shots":[{"name":"voices-grid-laptop-light","route":"/settings/voices","viewport":"laptop","theme":"light","setup":["wait for the text \\"Voices\\""]}]}\n' > "$FIX/wt195/docs/evidence/195/plan.json"
git -C "$FIX/wt195" add .design docs; git -C "$FIX/wt195" commit -qm "feat: the voices grid, to the picture"
driver_state_put 195 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 195 review
for st in start plan build self-check review record; do driver_state_done 195 "$st"; done
rc=0; out=$(driver_step_ship 195 2>&1) || rc=$?
want "it ships"                                    "0" "$rc"
want "every region the picture declares is planned" "voices-grid-laptop-light voices-menu-laptop-dark voices-share-phone-light" \
  "$(jq -r '[.shots[].name] | join(" ")' "$FIX/wt195/docs/evidence/195/plan.json")"
want "the builder's own setup for its shot is kept" 'wait for the text "Voices"' \
  "$(jq -r '.shots[0].setup[0]' "$FIX/wt195/docs/evidence/195/plan.json")"
want "and the plan is committed"                   "" "$(git -C "$FIX/wt195" status --porcelain)"
want_in "the body names every required shot"       'Required evidence' "$(cat "$GH_LOG")"
want_in "including the phone frame"                'voices-share-phone-light' "$(cat "$GH_LOG")"
want_in "and the picture's routes are the evidence routes" '- /voices/share' "$(cat "$GH_LOG")"

echo "--- an older picture with no region markers: its frames are planned ---"
# Approved before the markers existed, it draws two frames and a phone inside one.
# Ship once planned nothing for it; the regions are derived on the build's route.
: > "$GH_LOG"
setup_wt 197
mkdir -p "$FIX/wt197/.design"
cat > "$FIX/wt197/.design/desk-mock.html" <<'HTML'
<html><body>
<div class="frame" id="arriving"><h3>Arriving</h3><div class="phone">on a phone</div></div>
<section class="frame" id="empty"><h3>No rooms yet</h3></section>
</body></html>
HTML
git -C "$FIX/wt197" add .design; git -C "$FIX/wt197" commit -qm "feat: the desk, to the picture"
driver_state_set 197 screen_states '[{"route":"/desk"}]'
driver_state_put 197 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 197 review
for st in start plan build self-check review record; do driver_state_done 197 "$st"; done
rc=0; out=$(driver_step_ship 197 2>&1) || rc=$?
want "it ships"                                       "0" "$rc"
want "each page state of the older picture is planned once" "arriving-laptop-light arriving-phone-light" \
  "$(jq -r '[.shots[].name] | join(" ")' "$FIX/wt197/docs/evidence/197/plan.json" 2>/dev/null)"
want "on the build's own route"                       "/desk" \
  "$(jq -r '[.shots[].route] | unique | join(" ")' "$FIX/wt197/docs/evidence/197/plan.json" 2>/dev/null)"
want_in "and ship says how the regions were found"    'desk-mock.html: frames' "$out"
want_in "the body names the derived shots"            'arriving-phone-light' "$(cat "$GH_LOG")"

echo "--- no picture binds the ticket: its changed screens at laptop/phone x light/dark (#297) ---"
: > "$GH_LOG"
setup_wt 198
driver_state_set 198 screen_states '[{"route":"/desk"}]'
driver_state_put 198 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 198 review
for st in start plan build self-check review record; do driver_state_done 198 "$st"; done
rc=0; out=$(driver_step_ship 198 2>&1) || rc=$?
want "it ships"                                       "0" "$rc"
want "the route is planned at both widths and themes" "/desk laptop light,/desk laptop dark,/desk phone light,/desk phone dark" \
  "$(jq -r '[.shots[] | "\(.route) \(.viewport) \(.theme)"] | join(",")' "$FIX/wt198/docs/evidence/198/plan.json" 2>/dev/null)"
want "and the plan is committed"                      "" "$(git -C "$FIX/wt198" status --porcelain)"
want_in "the body names its route"                    '- /desk' "$(cat "$GH_LOG")"

echo "--- the plan goes where CI reads it: the PR's number on a branch not named <prefix>NNNN/ (#308) ---"
# CI keys evidence by the ticket of a <prefix>NNNN/ branch, else by the PR's number. Four
# PRs on 5654/approval-preview-shaped branches had their plan under the ticket, unseen.
setup_odd() { # <ticket> <branch> <pr>
  local t=$1 wt="$FIX/wt$1"
  git -C "$REPO" worktree add -q "$wt" -b "$2" develop
  printf 'change for %s\n' "$t" > "$wt/f$t.txt"
  git -C "$wt" add "f$t.txt"; git -C "$wt" commit -qm "feat: thing $t"
  driver_state_init "$t" --worktree "$wt" --branch "$2"
  driver_state_set "$t" claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
  driver_state_set "$t" pr "$3"
  fix_issue "$t" OPEN "status:claimed"
  driver_state_set "$t" screen_states '[{"route":"/desk"}]'
  driver_state_put "$t" review '{"verdict":"SHIP","findings":[]}'; driver_state_bump "$t" review
  for st in start plan build self-check review record; do driver_state_done "$t" "$st"; done
}
: > "$GH_LOG"
setup_odd 187 187/approval-preview 4321
rc=0; out=$(driver_step_ship 187 2>&1) || rc=$?
want "it ships"                                      "0" "$rc"
want "the plan is under the PR's number"             "yes" "$([ -f "$FIX/wt187/docs/evidence/4321/plan.json" ] && echo yes)"
want "and not under the ticket"                      "" "$(ls "$FIX/wt187/docs/evidence/187" 2>/dev/null)"
want "a prefixed branch still keys by its ticket"    "docs/evidence/198/plan.json" "$(driver_evidence_plan 198)"
echo "--- a plan an earlier run filed under the ticket is moved to where CI reads it ---"
: > "$GH_LOG"
setup_odd 188 188/old-shape 4322
mkdir -p "$FIX/wt188/docs/evidence/188"
printf '{"shots":[{"name":"desk-drawer-laptop-light","route":"/desk","viewport":"laptop","theme":"light","setup":["click the \\"Open\\" button"]}]}\n' > "$FIX/wt188/docs/evidence/188/plan.json"
git -C "$FIX/wt188" add docs; git -C "$FIX/wt188" commit -qm "chore: the plan, filed under the ticket"
rc=0; out=$(driver_step_ship 188 2>&1) || rc=$?
want "it ships"                                      "0" "$rc"
want "the old plan is gone from the ticket's folder" "" "$(git -C "$FIX/wt188" ls-files docs/evidence/188)"
want "its shot is kept, under the PR's number"       'click the "Open" button' \
  "$(jq -r '.shots[] | select(.name=="desk-drawer-laptop-light") | .setup[0]' "$FIX/wt188/docs/evidence/4322/plan.json" 2>/dev/null)"
want "and the tree is clean"                         "" "$(git -C "$FIX/wt188" status --porcelain)"

echo "--- the plan ship writes is formatted as the project formats it, so pre-push passes ---"
# Python's indent-2 JSON unfolds every short array; prettier folds them, so the project's
# pre-push format check failed on the plan alone and every screen ticket spent a fix
# round on it. The stand-in prettier folds arrays of scalars, as the real one does.
cat > "$FIX/fake-prettier" <<'PY'
#!/usr/bin/env python3
import json, re, sys
def fmt(p):
    s = json.dumps(json.load(open(p)), indent=2)
    return re.sub(r'\[\s*\n((?:\s*(?:"(?:[^"\\]|\\.)*"|-?[0-9.]+|true|false|null),?\n)+)\s*\]',
                  lambda m: "[" + ", ".join(x.strip().rstrip(",") for x in m.group(1).strip().splitlines()) + "]", s) + "\n"
check = "--check" in sys.argv
bad = 0
for p in [a for a in sys.argv[1:] if not a.startswith("--")]:
    if not p.endswith(".json"): continue
    want = fmt(p)
    if check: bad |= open(p).read() != want
    else: open(p, "w").write(want)
sys.exit(1 if bad else 0)
PY
chmod +x "$FIX/fake-prettier"
: > "$GH_LOG"
setup_wt 199
mkdir -p "$FIX/wt199/.design" "$FIX/wt199/node_modules/.bin"
cp "$FIX/fake-prettier" "$FIX/wt199/node_modules/.bin/prettier"
printf '{ "semi": false }\n' > "$FIX/wt199/.prettierrc"
# A JSON file the branch carries that ship never wrote: it is not ship's to format.
printf '{"keep":[\n1]}\n' > "$FIX/wt199/other.json"
cat > "$FIX/wt199/.design/desk-mock.html" <<'HTML'
<html><body>
<section data-evidence-shot="desk-grid-laptop-light" data-evidence-route="/desk" data-evidence-viewport="laptop" data-evidence-theme="light" data-evidence-setup='press Meta+K'></section>
</body></html>
HTML
printf 'node_modules/\n' > "$FIX/wt199/.gitignore"
git -C "$FIX/wt199" add .design .prettierrc .gitignore other.json; git -C "$FIX/wt199" commit -qm "feat: the desk, to the picture"
driver_state_put 199 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 199 review
for st in start plan build self-check review record; do driver_state_done 199 "$st"; done
rc=0; out=$(driver_step_ship 199 2>&1) || rc=$?
want "it ships"                                        "0" "$rc"
want "the plan is written"                             "desk-grid-laptop-light" \
  "$(jq -r '[.shots[].name] | join(" ")' "$FIX/wt199/docs/evidence/199/plan.json" 2>/dev/null)"
rc=0; ( cd "$FIX/wt199" && node_modules/.bin/prettier --check docs/evidence/199/plan.json ) || rc=$?
want "prettier --check passes on the committed plan"   "0" "$rc"
want "the commit holds the formatted plan"             "$(cat "$FIX/wt199/docs/evidence/199/plan.json")" \
  "$(git -C "$FIX/wt199" show HEAD:docs/evidence/199/plan.json)"
want "a file ship did not write is left as it was"     "$(printf '{"keep":[\n1]}')" "$(cat "$FIX/wt199/other.json")"
want "and the tree is clean"                           "" "$(git -C "$FIX/wt199" status --porcelain)"

echo "--- with no formatter the plan is in Prettier's JSON layout, with a trailing newline ---"
mkdir -p "$FIX/plain"; printf '{"shots":[{"a":[1,2]}]}' > "$FIX/plain/p.json"
rc=0; driver_format_files "$FIX/plain" p.json || rc=$?
want "it formats"                                      "0" "$rc"
want "Prettier's layout: a short array on one line"   "$(printf '{\n  "shots": [\n    {\n      "a": [1, 2]\n    }\n  ]\n}\nX')" \
  "$(cat "$FIX/plain/p.json"; printf X)"
rc=0; driver_format_files "$FIX/plain" missing.json || rc=$?
want "a file that is not there is nothing to do"       "1" "$rc"

echo "--- a design verdict this run committed is never pushed ---"
: > "$GH_LOG"
setup_wt 196
git -C "$FIX/wt196" commit -q --allow-empty -m "chore: design-critic" -m "Design-Critic: SHIP (agent) f9ad4e1a738d"
driver_state_put 196 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 196 review
for st in start plan build self-check review record; do driver_state_done 196 "$st"; done
rc=0; out=$(driver_step_ship 196 2>&1) || rc=$?
want "it refuses"                          "24" "$rc"
want_in "naming the verdict commit"        'committed a design verdict' "$out"
want "and nothing reached origin"          "" "$(git -C "$FIX/origin" rev-parse --verify -q tkt-196/work 2>/dev/null)"

echo "--- an earlier run's verdict on a branch that never reached origin is dropped, not refused (#13048) ---"
VKEY="Design-Critic"
old_verdict() { # <ticket> — a verdict commit an earlier run made, then this run's real work
  setup_wt "$1"
  GIT_AUTHOR_DATE="2026-10-20T10:00:00Z" GIT_COMMITTER_DATE="2026-10-20T10:00:00Z" \
    git -C "$FIX/wt$1" commit -q --allow-empty -m "chore: design-critic" -m "$VKEY: SHIP (agent) f9ad4e1a738d"
  printf 'work %s\n' "$1" > "$FIX/wt$1/work-$1.txt"; git -C "$FIX/wt$1" add "work-$1.txt"; git -C "$FIX/wt$1" commit -q -m "feat: the work"
  driver_state_put "$1" review '{"verdict":"SHIP","findings":[]}'; driver_state_bump "$1" review
  for st in start plan build self-check review record; do driver_state_done "$1" "$st"; done
}
: > "$GH_LOG"; old_verdict 471
rc=0; out=$(DRIVER_RUN_STARTED=$(date +%s) driver_step_ship 471 2>&1) || rc=$?
want "it ships"                            "0" "$rc"
want_in "saying it dropped the old verdict" "dropped an earlier run's design verdict" "$out"
want "the pushed branch carries no verdict" "0" "$(git -C "$FIX/origin" log --format=%B tkt-471/work 2>/dev/null | grep -c "^$VKEY:")"
want "and keeps the work"                  "work 471" "$(git -C "$FIX/origin" show tkt-471/work:work-471.txt 2>/dev/null)"

echo "--- one made this run is still refused, beside an old one ---"
: > "$GH_LOG"; old_verdict 472
git -C "$FIX/wt472" commit -q --allow-empty -m "chore: design-critic again" -m "$VKEY: SHIP (agent) 0000000000aa"
rc=0; out=$(DRIVER_RUN_STARTED=$(( $(date +%s) - 60 )) driver_step_ship 472 2>&1) || rc=$?
want "it refuses"                          "24" "$rc"
want_in "naming this run's verdict"        'committed a design verdict \([0-9a-f]+ chore: design-critic again' "$out"
want "and nothing reached origin"          "" "$(git -C "$FIX/origin" rev-parse --verify -q tkt-472/work 2>/dev/null)"

echo "--- plant: the drop out, the old verdict refuses again ---"
eval "$(declare -f _driver_ship_drop_old_verdicts | sed '1,2s/{/{ return 0;/')"
: > "$GH_LOG"; old_verdict 473
rc=0; out=$(DRIVER_RUN_STARTED=$(date +%s) driver_step_ship 473 2>&1) || rc=$?
want "planted: the old verdict refuses the ship" "24" "$rc"
. "$HERE/../steps/ship.sh"

# earlier_run <ticket> <file> <content> — an earlier run of the same ticket pushed a
# commit to the ticket's own branch on origin, from a clone this run never saw.
earlier_run() {
  local t=$1 c="$FIX/earlier$1"
  git clone -q -n "$FIX/origin" "$c"
  git -C "$c" checkout -q -b "tkt-$t/work" origin/develop
  printf '%s\n' "$3" > "$c/$2"
  git -C "$c" add "$2"
  git -C "$c" -c user.name=Earlier -c user.email=e@example.invalid commit -qm "feat: the earlier run's $2"
  git -C "$c" push -q origin "tkt-$t/work"
  git -C "$c" rev-parse HEAD
}

echo "--- an earlier run of the ticket pushed first: its commits are merged, not refused (#300) ---"
: > "$GH_LOG"
setup_wt 190
early=$(earlier_run 190 early190.txt "from the earlier run")
driver_state_put 190 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 190 review
for st in start plan build self-check review record; do driver_state_done 190 "$st"; done
rc=0; out=$(driver_step_ship 190 2>&1) || rc=$?
want "it ships"                                    "0" "$rc"
want_not_in "no 'fetch first' refusal"             'fetch first' "$out"
want "the earlier run's commit is kept, not forced" "yes" \
  "$(git -C "$FIX/origin" merge-base --is-ancestor "$early" tkt-190/work && echo yes)"
want "and this run's work is on origin too"        "change for 190" "$(git -C "$FIX/origin" show tkt-190/work:f190.txt 2>/dev/null)"
want "by a merge, never a rebase"                  "2" "$(git -C "$FIX/origin" rev-list --parents -n1 tkt-190/work | wc -w | tr -d ' ' | awk '{print $1-1}')"
want_in "whose subject passes commitlint"          '^chore\(merge\): [a-z]' "$(git -C "$FIX/origin" log -1 --format=%s tkt-190/work)"
want_in "and self-check ran again on the merge"    'self-check runs again' "$out"

echo "--- both runs changed one file: this run's version wins ---"
: > "$GH_LOG"
setup_wt 191
earlier_run 191 f191.txt "the earlier run's version" >/dev/null
driver_state_put 191 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 191 review
for st in start plan build self-check review record; do driver_state_done 191 "$st"; done
rc=0; out=$(driver_step_ship 191 2>&1) || rc=$?
want "it ships"                          "0" "$rc"
want "with this run's version"           "change for 191" "$(git -C "$FIX/origin" show tkt-191/work:f191.txt 2>/dev/null)"
want "and no conflict marker"            "" "$(git -C "$FIX/origin" show tkt-191/work:f191.txt 2>/dev/null | grep -E '^(<<<<<<<|>>>>>>>)')"

echo "--- a conflict in a file this run did not change: stop, name it, push nothing ---"
: > "$GH_LOG"
setup_wt 192
early=$(earlier_run 192 shared192.txt "the earlier run's shared file")
printf 'the trunk moved\n' > "$REPO/shared192.txt"
git -C "$REPO" add shared192.txt; git -C "$REPO" commit -qm "feat: trunk change"; git -C "$REPO" push -q origin develop
git -C "$FIX/wt192" fetch -q origin
git -C "$FIX/wt192" merge -q --no-edit origin/develop
driver_state_put 192 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 192 review
for st in start plan build self-check review record; do driver_state_done 192 "$st"; done
rc=0; out=$(driver_step_ship 192 2>&1) || rc=$?
want "it refuses"                        "24" "$rc"
want_in "naming the conflicting file"    'shared192.txt' "$out"
want "origin's branch is untouched"      "$early" "$(git -C "$FIX/origin" rev-parse tkt-192/work)"
want "and the tree is left clean"        "" "$(git -C "$FIX/wt192" status --porcelain)"
want "with no merge half-done"           "" "$(test -f "$(git -C "$FIX/wt192" rev-parse --git-path MERGE_HEAD)" && echo merging)"

echo "--- a trunk merge's squash commits carry their own critic's verdict: not this run's ---"
# Another PR's squash lands on origin's develop with its real critic trailer, this run
# merges develop in, and this tree's origin/develop is older than that merge.
other="$FIX/other-trunk"
git clone -q -b develop "$FIX/origin" "$other"
git -C "$other" -c user.name=O -c user.email=o@example.invalid commit -q --allow-empty \
  -m "polish(home): another PR (#9001)" -m "Design-Critic: SHIP (agent) 0123456789ab"
git -C "$other" push -q origin HEAD:develop
squash=$(git -C "$other" rev-parse HEAD)
trunk_merge() { # <ticket> — merge origin's develop in, leaving origin/develop stale
  git -C "$FIX/wt$1" fetch -q "$FIX/origin" "+refs/heads/develop:refs/tmp/dev$1"
  git -C "$FIX/wt$1" merge -q --no-ff --no-verify -m "chore(merge): develop into the branch" "refs/tmp/dev$1"
}
: > "$GH_LOG"
setup_wt 181
trunk_merge 181
want "the fixture's origin/develop is stale"   "no" \
  "$(git -C "$FIX/wt181" merge-base --is-ancestor "$squash" origin/develop && echo yes || echo no)"
driver_state_put 181 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 181 review
for st in start plan build self-check review record; do driver_state_done 181 "$st"; done
rc=0; out=$(driver_step_ship 181 2>&1) || rc=$?
want_not_in "the trunk's verdict is not called this run's" 'committed a design verdict' "$out"
want "it ships"                                "0" "$rc"
want "with the trunk merge on origin"          "yes" \
  "$(git -C "$FIX/origin" merge-base --is-ancestor "$squash" tkt-181/work 2>/dev/null && echo yes)"

echo "--- after a trunk merge, a verdict this run committed is still refused ---"
: > "$GH_LOG"
setup_wt 182
trunk_merge 182
git -C "$FIX/wt182" commit -q --allow-empty -m "chore: design-critic" -m "Design-Critic: SHIP (agent) f9ad4e1a738d"
own=$(git -C "$FIX/wt182" rev-parse --short HEAD)
driver_state_put 182 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 182 review
for st in start plan build self-check review record; do driver_state_done 182 "$st"; done
rc=0; out=$(driver_step_ship 182 2>&1) || rc=$?
want "it refuses"                              "24" "$rc"
want_in "naming this run's commit"             "$own chore: design-critic" "$out"
want_not_in "and only that one"                'another PR' "$out"
want "and nothing reached origin"              "" "$(git -C "$FIX/origin" rev-parse --verify -q tkt-182/work 2>/dev/null)"

echo "--- a person's stop wins over the machine: a draft a person made is never readied ---"
# 22 Oct: a PM named a Critical and put the PR back to draft; a driver re-check
# ("unchanged … meets every acceptance item") readied it, armed it, and it merged.
repair_wt 731 734; ORIG=$(git -C "$FIX/wt731" rev-parse HEAD)
printf 'fix\n' > "$FIX/wt731/r731.txt"; git -C "$FIX/wt731" add r731.txt
git -C "$FIX/wt731" -c user.email=t@example.invalid -c user.name=T commit -qm "fix: repair"
driver_state_done 731 start
driver_state_put 731 repair '{"step":"repair","status":"unchanged","reason":"meets every acceptance item"}'
printf '[{"number":734,"isDraft":true}]\n' > "$FIX/gh/prs.json"
printf 'a person (pm) put this back to draft on 2026-10-22: Back to draft: must not merge until the COLLEAGUE key (Critical, lost data) is fixed\n' > "$FIX/person-stop.out"
printf '1\n' > "$FIX/person-stop.rc"; : > "$FIX/person-stop.log"; : > "$GH_LOG"
out=$(driver_step_ship 731 2>&1); rc=$?
want "a draft a person made refuses"              "24" "$rc"
want_not_in "never readied, never armed"          'pr ready|pr merge' "$(cat "$GH_LOG")"
want "nothing reached origin"                     "$ORIG" "$(git -C "$FIX/origin" rev-parse tkt-731/work)"
want_in "the stop was read for the ticket and its PR" '^check 731 734$' "$(cat "$FIX/person-stop.log")"
want_in "the park names the person and their words" 'put this back to draft on 2026-10-22: Back to draft' "$(driver_state_get 731 park_note)"
want "and parks for the person, not the machine"  "pm" "$(driver_state_get 731 park_cause)"
want_not_in "no re-check comment claims it unchanged" 'Re-checked by the driver' "$(cat "$GH_LOG")"
rm -f "$FIX/person-stop.out" "$FIX/person-stop.rc"; printf '[]\n' > "$FIX/gh/prs.json"

echo "--- a person's Critical newer than the review makes ship refuse at the hand-off ---"
setup_wt 732
driver_state_put 732 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 732 review
for st in start plan build self-check review record; do driver_state_done 732 "$st"; done
printf 'pm named a blocking finding on #732 on 2026-10-22: Critical (lost data): erasing one member deletes another'"'"'s facts\n' > "$FIX/person-stop.out"
printf '1\n' > "$FIX/person-stop.rc"; : > "$GH_LOG"
out=$(driver_step_ship 732 2>&1); rc=$?
want "a SHIP verdict does not outvote a person's Critical" "24" "$rc"
want_not_in "the PR is never readied or armed"    'pr ready|pr merge' "$(cat "$GH_LOG")"
want_in "the refusal names the finding"           'Critical \(lost data\)' "$out"
want_not_in "no hand-off is announced"            'Handed off at' "$(cat "$GH_LOG")"
rm -f "$FIX/person-stop.out" "$FIX/person-stop.rc"

echo "--- a stop that cannot be read holds, as a stop does ---"
setup_wt 733
driver_state_put 733 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 733 review
for st in start plan build self-check review record; do driver_state_done 733 "$st"; done
printf 'could not read the comments on #733\n' > "$FIX/person-stop.out"; printf '2\n' > "$FIX/person-stop.rc"; : > "$GH_LOG"
rc=0; driver_step_ship 733 >/dev/null 2>&1 || rc=$?
want "unreadable is not clear"                    "26" "$rc"
want_not_in "never readied or armed"              'pr ready|pr merge' "$(cat "$GH_LOG")"
rm -f "$FIX/person-stop.out" "$FIX/person-stop.rc"

suite_end "$FAILED"
