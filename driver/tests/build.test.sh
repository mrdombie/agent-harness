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

echo "--- a build that changed nothing at all ---"
driver_state_init 303 --worktree "$REPO" --repo "$REPO"
fix_ai build '{"items":[]}' superpowers:subagent-driven-development
out=$(driver_step_build 303 2>&1); rc=$?
want "no items is a refusal, not a pass" "24" "$rc"
want_in "and says why" 'no items' "$out"

exit $FAILED
