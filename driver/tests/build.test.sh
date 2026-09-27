#!/usr/bin/env bash
# build.test.sh — test-first is the epic's headline target: it was used 0 times
# in 161 runs, so the driver has to PROVE it rather than ask for it. The proof is
# running the new test against the tree WITHOUT the change and requiring it to
# fail, then against the tree WITH the change and requiring it to pass.
#
# These cases are built out of real commits in a real repo, because the proof is
# made of commits and worktrees and a stubbed git would only test the stub.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/build.sh" || exit 1

# A worked example, committed the way a disciplined build commits it.
#   base        no feature, no test
#   test_commit adds a test that asserts the feature
#   impl_commit adds the feature
mk_honest() {
  printf 'no\n' > "$REPO/feature.txt"
  git -C "$REPO" add feature.txt; git -C "$REPO" commit -qm base
  printf '#!/usr/bin/env bash\ngrep -q yes feature.txt\n' > "$REPO/feature.test.sh"
  git -C "$REPO" add feature.test.sh; git -C "$REPO" commit -qm "test: the feature"
  TEST_SHA=$(git -C "$REPO" rev-parse HEAD)
  printf 'yes\n' > "$REPO/feature.txt"
  git -C "$REPO" add feature.txt; git -C "$REPO" commit -qm "feat: the feature"
  IMPL_SHA=$(git -C "$REPO" rev-parse HEAD)
}

echo "--- a test written before the change proves it ---"
mk_honest
out=$(driver_prove_red_green "$REPO" feature.test.sh "$TEST_SHA" "$IMPL_SHA" "bash feature.test.sh" 2>&1); rc=$?
want "red then green is proved" "0" "$rc"
want_in "and it says so"        'red .* then green' "$out"

echo "--- a test that was already green proves nothing ---"
# The test asserts something true before the change: the classic test-shaped
# thing that is not a test of the change.
printf '#!/usr/bin/env bash\ntest -f feature.txt\n' > "$REPO/vacuous.test.sh"
git -C "$REPO" add vacuous.test.sh; git -C "$REPO" commit -qm "test: vacuous"
V_TEST=$(git -C "$REPO" rev-parse HEAD)
printf 'yes again\n' > "$REPO/feature.txt"
git -C "$REPO" add feature.txt; git -C "$REPO" commit -qm "feat: again"
V_IMPL=$(git -C "$REPO" rev-parse HEAD)
out=$(driver_prove_red_green "$REPO" vacuous.test.sh "$V_TEST" "$V_IMPL" "bash vacuous.test.sh" 2>&1); rc=$?
want "a green-before test is refused" "1" "$rc"
want_in "and the reason is stated"    'passes without the change' "$out"

echo "--- a test still failing after the change is not done ---"
printf '#!/usr/bin/env bash\ngrep -q never feature.txt\n' > "$REPO/broken.test.sh"
git -C "$REPO" add broken.test.sh; git -C "$REPO" commit -qm "test: broken"
B_TEST=$(git -C "$REPO" rev-parse HEAD)
printf 'still not\n' > "$REPO/feature.txt"
git -C "$REPO" add feature.txt; git -C "$REPO" commit -qm "feat: does not do it"
B_IMPL=$(git -C "$REPO" rev-parse HEAD)
out=$(driver_prove_red_green "$REPO" broken.test.sh "$B_TEST" "$B_IMPL" "bash broken.test.sh" 2>&1); rc=$?
want "still red after the change is refused" "2" "$rc"
want_in "and the reason is stated"           'still fails with the change' "$out"

echo "--- one squashed commit is not two, and cannot prove an order ---"
# The whole claim rests on the test being committed BEFORE the change. Reported as
# one commit, the parent has neither the test nor the change, the test is copied in
# and goes red, and the commit makes it green — so a run that did no test-first at
# all reads as a clean proof. Nothing about the tree distinguishes them; only the
# two shas do.
out=$(driver_prove_red_green "$REPO" feature.test.sh "$IMPL_SHA" "$IMPL_SHA" "bash feature.test.sh" 2>&1); rc=$?
want "one commit for both is refused"  "3" "$rc"
want_in "and says they are the same"   'same commit' "$out"

echo "--- a test committed AFTER the change proves nothing about the order ---"
# The green half runs at the change, where the test file does not exist yet. With a
# suite-wide command that is an empty run, which exits 0 — so "then green" is said
# about a run that never executed the test.
printf 'later\n' > "$REPO/after.txt"
git -C "$REPO" add after.txt; git -C "$REPO" commit -qm "feat: the change, first"
A_IMPL=$(git -C "$REPO" rev-parse HEAD)
printf '#!/usr/bin/env bash\ngrep -q later after.txt\n' > "$REPO/after.test.sh"
git -C "$REPO" add after.test.sh; git -C "$REPO" commit -qm "test: written afterwards"
A_TEST=$(git -C "$REPO" rev-parse HEAD)
out=$(driver_prove_red_green "$REPO" after.test.sh "$A_TEST" "$A_IMPL" "bash after.test.sh" 2>&1); rc=$?
want "a test absent at the change is refused" "3" "$rc"
want_in "and says it is not there"            'not in the change' "$out"

echo "--- the proof trees carry the shared install, or every real project parks ---"
# The ticket worktree gets the shared node_modules linked into it; these two get
# nothing, so a command that resolves through it — `npx`, `./node_modules/.bin/x`,
# `npm test` — fails with 127 in BOTH trees. 127 in the second reads as "the change
# does not do the job", the rework burns all five tries, and the ticket parks. On a
# JS project that is every ticket.
mkdir -p "$REPO/node_modules/.bin"
printf '#!/usr/bin/env bash\ngrep -q yes "$1"\n' > "$REPO/node_modules/.bin/runner"
chmod +x "$REPO/node_modules/.bin/runner"
out=$(driver_prove_red_green "$REPO" feature.test.sh "$TEST_SHA" "$IMPL_SHA" \
        "./node_modules/.bin/runner feature.txt" 2>&1); rc=$?
want "a command that needs the install still proves" "0" "$rc"
want_not_in "and never reports it as not found" '127|No such file' "$out"

echo "--- both halves run the SAME version of the test, the reported one ---"
# A test refined while the change was built is ordinary: a weak first version, the
# change, then the assertion sharpened. The proof is about ONE version — red at the
# change's parent, green at the change — so both trees have to carry the version the
# build REPORTED, not whatever each tree happens to hold.
#
# The first version here asserts the OPPOSITE of the change, so it is green before
# and red after. That is what makes the two readings tell apart: run the tree's own
# copy at the change and the proof says "still fails with the change"; run the
# reported copy and it says red then green. Without that opposition both readings
# agree and the assertion measures nothing — which is how the first attempt at this
# case passed against code that had the defect.
printf 'no\n' > "$REPO/refine.txt"
printf '#!/usr/bin/env bash\ngrep -q no refine.txt\n' > "$REPO/refine.test.sh"   # v1: green BEFORE, red after
git -C "$REPO" add refine.txt refine.test.sh; git -C "$REPO" commit -qm "test: weak first version"
printf 'yes\n' > "$REPO/refine.txt"
git -C "$REPO" add refine.txt; git -C "$REPO" commit -qm "feat: the refine change"
R_IMPL=$(git -C "$REPO" rev-parse HEAD)
printf '#!/usr/bin/env bash\ngrep -q yes refine.txt\n' > "$REPO/refine.test.sh"  # v2: red BEFORE, green after
git -C "$REPO" add refine.test.sh; git -C "$REPO" commit -qm "test: sharpened"
R_TEST=$(git -C "$REPO" rev-parse HEAD)
out=$(driver_prove_red_green "$REPO" refine.test.sh "$R_TEST" "$R_IMPL" "bash refine.test.sh" 2>&1); rc=$?
want "the reported version decides both halves" "0" "$rc"
want_in "and it says red then green"            'red .* then green' "$out"
want_not_in "not the version the tree happened to hold" 'still fails with the change' "$out"


echo "--- a test command that never returns is refused, not waited on ---"
# The command comes from the MODEL. A reported watch-mode runner — `vitest` without
# `run`, `jest --watch`, a dev server — hangs the proof for ever: no park, no
# refusal, the claim held and the worktree pinned, which is the one state the design
# exists to make impossible. The retry ceiling cannot help; a step that never returns
# is never counted.
t0=$(date +%s)
out=$(DRIVER_CMD_TIMEOUT=2 driver_prove_red_green "$REPO" feature.test.sh "$TEST_SHA" "$IMPL_SHA" "sleep 60" 2>&1); rc=$?
t1=$(date +%s)
want "a hang is its own refusal" "4" "$rc"
want_in "and says it ran out of time" 'time' "$out"
if [ $((t1 - t0)) -lt 30 ]; then ok "it came back in $((t1-t0))s, not after the sleep"; else bad "waited $((t1-t0))s — the bound did not hold"; fi

echo "--- the proof leaves nothing behind ---"
want "no stray worktrees" "0" \
  "$(git -C "$REPO" worktree list | grep -c 'driver-proof' || true)"

echo "--- the build step: an item that proves itself is accepted ---"
export DRIVER_TICKET=101
driver_state_init 101 --worktree "$REPO" --repo "$REPO"
fix_brief build superpowers:subagent-driven-development
fix_ai build "$(jq -nc --arg t "$TEST_SHA" --arg i "$IMPL_SHA" \
  '{items:[{id:"1", test_file:"feature.test.sh", test_command:"bash feature.test.sh",
            test_commit:$t, impl_commit:$i}]}')" superpowers:subagent-driven-development
out=$(driver_step_build 101 2>&1); rc=$?
want "the step finishes"        "0" "$rc"
want_in "and names what it proved" 'feature.test.sh' "$out"

echo "--- the build step: an unproved item is sent back, and counted ---"
# A FRESH ticket: the counter counts attempts at the step, so re-entering 101
# after its successful attempt would make "the first failure" read as the second.
# A real run never re-enters a step that finished; the test must not either.
driver_state_init 102 --worktree "$REPO" --repo "$REPO"
fix_ai build "$(jq -nc --arg t "$V_TEST" --arg i "$V_IMPL" \
  '{items:[{id:"1", test_file:"vacuous.test.sh", test_command:"bash vacuous.test.sh",
            test_commit:$t, impl_commit:$i}]}')" superpowers:subagent-driven-development
rc=0; driver_step_build 102 >/dev/null 2>&1 || rc=$?
want "it asks for rework"  "30" "$rc"
want "the try is counted"  "1"  "$(driver_state_count 102 build)"

echo "--- five tries used up, and the ticket parks ---"
i=2; while [ $i -le "$DRIVER_MAX_BUILD_TRIES" ]; do
  rc=0; driver_step_build 102 >/dev/null 2>&1 || rc=$?
  i=$((i+1))
done
want "the last try refuses rather than looping" "24" "$rc"
want "the tries are all counted" "$DRIVER_MAX_BUILD_TRIES" "$(driver_state_count 102 build)"

echo "--- a build that claims an item with no test at all ---"
driver_state_init 202 --worktree "$REPO" --repo "$REPO"
fix_ai build '{"items":[{"id":"1","impl_commit":"HEAD"}]}' superpowers:subagent-driven-development
out=$(driver_step_build 202 2>&1); rc=$?
want "an item with no test is rework" "30" "$rc"
want_in "and it says which item"      'item 1' "$out"

echo "--- the last try does not turn a question into a refusal ---"
# The ceiling exists for an UNPROVED build. A question, a skipped Skill or a broken
# shape are not retries — they park, and the reason has to survive the last try or
# the operator is handed "build refused" in place of the model's actual question.
driver_state_init 404 --worktree "$REPO" --repo "$REPO"
i=1; while [ $i -le "$DRIVER_MAX_BUILD_TRIES" ]; do driver_state_bump 404 build; i=$((i+1)); done
fix_ai build '{"question":"which of the two schemas is the approved one?"}' superpowers:subagent-driven-development
rc=0; out=$(driver_step_build 404 2>&1) || rc=$?
want "a question on the last try is still a question" "20" "$rc"
want_in "and the question survives"  'which of the two schemas' "$out"

echo "--- a build that changed nothing at all ---"
driver_state_init 303 --worktree "$REPO" --repo "$REPO"
fix_ai build '{"items":[]}' superpowers:subagent-driven-development
out=$(driver_step_build 303 2>&1); rc=$?
want "no items is a refusal, not a pass" "24" "$rc"
want_in "and says why" 'no items' "$out"

exit $FAILED
