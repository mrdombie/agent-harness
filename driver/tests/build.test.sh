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


# --- the build answer, in the contract's shape -------------------------------
# It was `{items:[{test_file, test_command, test_commit, impl_commit}]}` — four names
# briefs/schemas/build.json does not have, under a key it does not have either, and
# the contract is additionalProperties:false. So this suite passed while the shipped
# build step could not read a single contract-valid answer. The contract carries ONE
# `task` and ONE `testFirst`, and the driver now calls the step once per plan task.
#
# A PLAN IS WHAT THE STEP READS ITS TASKS FROM, so each case writes one.
fix_plan() { # <ticket> <task-count>
  local t="$1" n="${2:-1}" i=1 tasks=""
  while [ "$i" -le "$n" ]; do
    tasks="${tasks:+$tasks,}$(jq -nc --arg ti "task $i" \
      '{title:$ti, files:[{path:"a.sh",action:"modify"}],
        tests:[{file:"a.test.sh", behaviour:"it does the thing", redWhen:"the fix is deleted"}]}')"
    i=$((i+1))
  done
  printf '{"step":"plan","skills":["superpowers:writing-plans"],"status":"planned","designSource":"ticket-body","premise":{"verdict":"still-true","evidence":"a.sh:1"},"tasks":[%s]}\n' \
    "$tasks" | jq . > "$(driver_state_dir "$t")/steps/plan.json"
}

# fix_build <test-file> <command> <test-sha> <impl-sha> [task]
fix_build() {
  jq -nc --arg f "$1" --arg c "$2" --arg t "$3" --arg i "$4" --arg k "${5:-task 1}" \
    '{step:"build", skills:["superpowers:subagent-driven-development"], status:"built",
      task:$k,
      testFirst:{test:{file:$f, behaviour:"it does the thing", redWhen:"the fix is deleted"},
                 command:$c, testCommit:$t, implCommit:$i,
                 failedBefore:true, redOutput:"FAIL", passedAfter:true, greenOutput:"PASS"},
      changed:[{path:"a.sh", action:"modify"}],
      changelog:{skipped:"a test-only change"}} + (if $ENV.FIX_REPLACED then {replacedTests:[{file:$ENV.FIX_REPLACED, coveredBy:$ENV.FIX_REPLACED}]} else {} end)'
}

# A per-call stub: the nth call answers with $FIX/ai/<step>.<n>.jsonl, so two calls
# in one step can return two different answers. With one answer for both, the
# two-task case below proved task 1 twice and task 2 never, and passed.
nth_claude() {
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
# Everything the fixture stub records, kept — a replacement that quietly drops
# them makes the next assertion added below measure a different stub than the
# ones above it. The one thing it adds is a per-step call counter.
step=""; prev=""; schema=""
for a in "$@"; do
  case "$prev" in --name) step="$a" ;; --json-schema) schema="$a" ;; esac
  prev="$a"
done
printf '%s
' "$step" >> "$CLAUDE_LOG"
printf '%s	%s	%s
' "$step" "$PWD" "${HARNESS_DRIVER_RUN:-}" >> "$FIX/claude-env.log"
printf '%s' "$schema" > "$FIX/claude-schema-$step.json"
# BOUNDED, because an unredirected stdin BLOCKS. Dropping the driver's
# `< "$prompt"` is the plant that proves the redirect is load-bearing — and with a
# plain `cat` here that plant HUNG instead of going red, which reports the guard as
# sound. perl is the same tool driver_bounded uses and is on every machine this kit
# runs on; the real CLI bounds its own stdin wait the same way (measured: "no stdin
# data received in 3s, proceeding without it").
perl -e 'eval { local $SIG{ALRM} = sub { die }; alarm 5; print while <STDIN>; alarm 0 }' \
  > "$FIX/claude-stdin-$step.txt" 2>/dev/null || true
n=$(( $(cat "$FIX/nth.$step" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FIX/nth.$step"
if [ -f "$FIX/ai/$step.$n.jsonl" ]; then cat "$FIX/ai/$step.$n.jsonl"; exit 0; fi
# The fixture stub's own refusal, kept: a missing transcript must not read as
# "the agent produced no transcript".
f="$FIX/ai/$step.jsonl"
[ -f "$f" ] || { echo "no transcript for step '$step'" >&2; exit 3; }
cat "$f"
SH
chmod +x "$BIN/claude"; rm -f "$FIX"/nth.*
}

echo "--- the build step: an item that proves itself is accepted ---"
export DRIVER_TICKET=101
driver_state_init 101 --worktree "$REPO" --repo "$REPO"
fix_brief build superpowers:subagent-driven-development
fix_plan 101 1
fix_ai build "$(fix_build feature.test.sh "bash feature.test.sh" "$TEST_SHA" "$IMPL_SHA")" \
  superpowers:subagent-driven-development
out=$(driver_step_build 101 2>&1); rc=$?
want "the step finishes"        "0" "$rc"
want_in "and names what it proved" 'feature.test.sh' "$out"
want "a build that reworded no test leaves the ledger empty" "" \
  "$(cat "$(driver_state_dir 101)/steps/replaced.jsonl" 2>/dev/null)"

echo "--- the build step: an unproved item is sent back, and counted ---"
# A FRESH ticket: the counter counts attempts at the step, so re-entering 101
# after its successful attempt would make "the first failure" read as the second.
# A real run never re-enters a step that finished; the test must not either.
driver_state_init 102 --worktree "$REPO" --repo "$REPO"
fix_plan 102 1
fix_ai build "$(fix_build vacuous.test.sh "bash vacuous.test.sh" "$V_TEST" "$V_IMPL")" \
  superpowers:subagent-driven-development
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

echo "--- a hang in the proof is not retried five times and blamed on the tests ---"
# Folded in with a failing test it went round the retry loop — at the default ceiling
# five attempts times two proof halves of waiting — and parked saying the tests do not
# prove the change. It has its own outcome, and the orchestrator parks on it at once.
driver_state_init 505 --worktree "$REPO" --repo "$REPO"
fix_plan 505 1
fix_ai build "$(fix_build feature.test.sh "sleep 60" "$TEST_SHA" "$IMPL_SHA")" \
  superpowers:subagent-driven-development
rc=0; out=$(DRIVER_CMD_TIMEOUT=2 driver_step_build 505 2>&1) || rc=$?
want "a hang is its own outcome, not a rework" "25" "$rc"
want_in "and it says it ran out of time"       'time' "$out"
want "and only one try was spent"              "1" "$(driver_state_count 505 build)"

echo "--- a build that claims an item with no test at all ---"
driver_state_init 202 --worktree "$REPO" --repo "$REPO"
fix_plan 202 1
# Every field of testFirst is required by the contract, so the shape with no test is
# the one where testFirst is absent altogether — status `built` with nothing to prove.
fix_ai build '{"step":"build","skills":["superpowers:subagent-driven-development"],"status":"built","task":"task 1","changed":[{"path":"a.sh","action":"modify"}],"changelog":{"skipped":"none"}}' superpowers:subagent-driven-development
out=$(driver_step_build 202 2>&1); rc=$?
want "a task with no test is rework" "30" "$rc"
want_in "and it says which task"     'task 1' "$out"

echo "--- the last try does not turn a question into a refusal ---"
# The ceiling exists for an UNPROVED build. A question, a skipped Skill or a broken
# shape are not retries — they park, and the reason has to survive the last try or
# the operator is handed "build refused" in place of the model's actual question.
driver_state_init 404 --worktree "$REPO" --repo "$REPO"
i=1; while [ $i -le "$DRIVER_MAX_BUILD_TRIES" ]; do driver_state_bump 404 build; i=$((i+1)); done
fix_plan 404 1
fix_ai build '{"step":"build","skills":["superpowers:subagent-driven-development"],"status":"park","task":"task 1","question":"which of the two schemas is the approved one?"}' superpowers:subagent-driven-development
rc=0; out=$(driver_step_build 404 2>&1) || rc=$?
want "a question on the last try is still a question" "20" "$rc"
want_in "and the question survives"  'which of the two schemas' "$out"

echo "--- a plan with nothing in it is not a build that passed ---"
driver_state_init 303 --worktree "$REPO" --repo "$REPO"
fix_plan 303 0
fix_ai build '{"step":"build","skills":["superpowers:subagent-driven-development"],"status":"built","task":"none"}' superpowers:subagent-driven-development
out=$(driver_step_build 303 2>&1); rc=$?
want "no task is a refusal, not a pass" "24" "$rc"
want_in "and says why" 'no task' "$out"

echo "--- two plan tasks are two calls, in order, never in parallel ---"
# One call per task is what build.md and the contract say. Inside a ticket the
# fan-out belongs to superpowers:subagent-driven-development, which the brief invokes;
# the driver never starts several agents on one ticket. So the count is the measure.
# EACH CALL ANSWERS ABOUT ITS OWN TASK, with its own two commits — which is what the
# two refusals at the end of this file insist on, and what this case used to break.
driver_state_init 606 --worktree "$REPO" --repo "$REPO"
fix_plan 606 2
nth_claude
fix_ai build "$(fix_build feature.test.sh "bash feature.test.sh" "$TEST_SHA" "$IMPL_SHA" "task 1")" \
  superpowers:subagent-driven-development
cp "$FIX/ai/build.jsonl" "$FIX/ai/build.1.jsonl"
fix_ai build "$(fix_build refine.test.sh "bash refine.test.sh" "$R_TEST" "$R_IMPL" "task 2")" \
  superpowers:subagent-driven-development
cp "$FIX/ai/build.jsonl" "$FIX/ai/build.2.jsonl"
: > "$CLAUDE_LOG"
rc=0; out=$(driver_step_build 606 2>&1) || rc=$?
want "both tasks are proved"           "0" "$rc"
want_in "and each by its own test"     'feature.test.sh' "$out"
want_in "including the second"         'refine.test.sh'  "$out"
want "one call per task and no more"   "2" "$(grep -c . "$CLAUDE_LOG")"
want "each task's own answer is kept"  "2" \
  "$(ls "$(driver_state_dir 606)/steps"/build-task-*.json | grep -c . || true)"
want "and the step's own answer file is the last of them" "build" \
  "$(jq -r '.step' "$(driver_state_dir 606)/steps/build.json")"
rm -f "$FIX"/nth.* "$FIX/ai/build.1.jsonl" "$FIX/ai/build.2.jsonl"

echo "--- the answer must build the task this call was given ---"
# The proof re-runs whatever two shas it is handed and cannot tell which task they
# belong to. So an answer returning the PREVIOUS task's title and commits proved red
# then green, `bad` stayed 0, and the step reported every task built while one was
# never touched. The two-task case above did exactly that and passed.
# THE TWO GUARDS ARE MEASURED SEPARATELY. Written with one answer for both calls this
# case passed with the title check inert — the SECOND call was caught by the commit-pair
# check instead, so the rc was right for the wrong reason and only the message assertion
# went red on the plant. Here call 2 carries the wrong TITLE and its own commits, so the
# pair check cannot fire and nothing but the title check can catch it.
driver_state_init 707 --worktree "$REPO" --repo "$REPO"
fix_plan 707 2
nth_claude
fix_ai build "$(fix_build feature.test.sh "bash feature.test.sh" "$TEST_SHA" "$IMPL_SHA" "task 1")" \
  superpowers:subagent-driven-development
cp "$FIX/ai/build.jsonl" "$FIX/ai/build.1.jsonl"
fix_ai build "$(fix_build refine.test.sh "bash refine.test.sh" "$R_TEST" "$R_IMPL" "task 1")" \
  superpowers:subagent-driven-development
cp "$FIX/ai/build.jsonl" "$FIX/ai/build.2.jsonl"
out=$(driver_step_build 707 2>&1); rc=$?
want "an answer about another task is sent back" "30" "$rc"
want_in "and names both"  "given 'task 2'" "$out"
want_not_in "and not by the commit-pair check" 'same two commits' "$out"
rm -f "$FIX"/nth.* "$FIX/ai/build.1.jsonl" "$FIX/ai/build.2.jsonl"

echo "--- a title the plan does not carry at all is said, not refused ---"
# The near-miss: a restored full stop, a normalised dash. Nothing in build.md told the
# model the string had to be verbatim, so refusing here sent a correctly-built task
# round the rework loop five times and parked it saying "the tests still do not prove
# the change" — false, about tests that are fine.
driver_state_init 710 --worktree "$REPO" --repo "$REPO"
fix_plan 710 1
fix_ai build "$(fix_build feature.test.sh "bash feature.test.sh" "$TEST_SHA" "$IMPL_SHA" "task 1.")" \
  superpowers:subagent-driven-development
out=$(driver_step_build 710 2>&1); rc=$?
want "a near miss is not a refusal" "0" "$rc"
want_in "and the difference is said"  "calls this task 'task 1.'" "$out"

echo "--- and it must be proved by its own two commits ---"
# The other door to the same hole: the right title, a pair already spent on task 1.
driver_state_init 708 --worktree "$REPO" --repo "$REPO"
fix_plan 708 2
nth_claude
fix_ai build "$(fix_build feature.test.sh "bash feature.test.sh" "$TEST_SHA" "$IMPL_SHA" "task 1")" \
  superpowers:subagent-driven-development
cp "$FIX/ai/build.jsonl" "$FIX/ai/build.1.jsonl"
fix_ai build "$(fix_build feature.test.sh "bash feature.test.sh" "$TEST_SHA" "$IMPL_SHA" "task 2")" \
  superpowers:subagent-driven-development
cp "$FIX/ai/build.jsonl" "$FIX/ai/build.2.jsonl"
out=$(driver_step_build 708 2>&1); rc=$?
want "one change cannot be two tasks built test-first" "30" "$rc"
want_in "and it says so"  'same two commits' "$out"
rm -f "$FIX"/nth.* "$FIX/ai/build.1.jsonl" "$FIX/ai/build.2.jsonl"

echo "--- a proof tree that could not be prepared is not a red ---"
# The measurement was never taken, so blaming the change is the one thing this must
# not do — and it used to, five times over, because the prepare ran into /dev/null
# with `|| true`. Every try would have been spent and the ticket parked accusing a
# change that works.
jq '.worktree.prepare = ["sh -c \"exit 4\""]' "$REPO/.claude/harness.json" > "$FIX/hb.json"
mv "$FIX/hb.json" "$REPO/.claude/harness.json"
out=$(driver_prove_red_green "$REPO" feature.test.sh "$TEST_SHA" "$IMPL_SHA" "bash feature.test.sh" 2>&1); rc=$?
want "the proof says it could not be taken"  "5" "$rc"
want_in "and names the prepare, not the test" 'could not be prepared' "$out"
want_not_in "it never blames the change"      'does not test it|still fails with the change' "$out"
driver_state_init 709 --worktree "$REPO" --repo "$REPO"
fix_plan 709 1
fix_ai build "$(fix_build feature.test.sh "bash feature.test.sh" "$TEST_SHA" "$IMPL_SHA")" \
  superpowers:subagent-driven-development
out=$(driver_step_build 709 2>&1); rc=$?
want "the step refuses rather than retrying it five times" "24" "$rc"
want "and spends one try, not five"  "1" "$(driver_state_count 709 build)"

echo "--- a prepare list that is not a list prepared nothing, and says so ---"
# `"prepare": "npx generate"` — `// []` does not fire on a string, `length` is the
# CHARACTER count, every element read errors into /dev/null, and this returned 0
# having run nothing. Measured: 19 for a 19-character string.
jq '.worktree.prepare = "sh -c \"echo generated > .prepared\""' "$REPO/.claude/harness.json" > "$FIX/hc.json"
mv "$FIX/hc.json" "$REPO/.claude/harness.json"
out=$(driver_prepare_worktree "$FIX" 2>&1); rc=$?
want "a string is refused"      "1" "$rc"
want_in "and named as a string" 'is a string' "$out"
want "nothing was prepared"     "no" "$([ -f "$FIX/.prepared" ] && echo yes || echo no)"
jq '.worktree.prepare = ["sh -c \"echo ok\"", 3]' "$REPO/.claude/harness.json" > "$FIX/hd.json"
mv "$FIX/hd.json" "$REPO/.claude/harness.json"
out=$(driver_prepare_worktree "$FIX" 2>&1); rc=$?
want "an entry that is not a command is refused" "1" "$rc"
want_in "and named by its position"              'entry 2' "$out"
jq 'del(.worktree)' "$REPO/.claude/harness.json" > "$FIX/he.json"
mv "$FIX/he.json" "$REPO/.claude/harness.json"
want "and no prepare at all is still normal" "0" "$(driver_prepare_worktree "$FIX" >/dev/null 2>&1; echo $?)"
echo "--- a test-only task is proved by breaking the code it covers ---"
# The code already exists, so the red/green proof can only say "passes without the
# change". The break is the proof: red with the code broken, green with it restored.
git -C "$REPO" checkout -q -- . 2>/dev/null
printf 'price=100\n' > "$REPO/price.txt"
printf '#!/usr/bin/env bash\ngrep -q price=100 price.txt\n' > "$REPO/price.test.sh"
printf '#!/usr/bin/env bash\ntest -f price.txt\n' > "$REPO/loose.test.sh"
git -C "$REPO" add price.txt price.test.sh loose.test.sh; git -C "$REPO" commit -qm "test: price"
P_SHA=$(git -C "$REPO" rev-parse HEAD)
out=$(driver_prove_by_break "$REPO" price.test.sh "$P_SHA" price.txt "price=100" "price=0" "bash price.test.sh" 2>&1); rc=$?
want "red when broken, green when restored" "0" "$rc"
want_in "and it says so"                    'red .*broken, then green' "$out"
want "the ticket's own tree is untouched"   "price=100" "$(cat "$REPO/price.txt")"

echo "--- a test that stays green with the code broken does not cover it ---"
out=$(driver_prove_by_break "$REPO" loose.test.sh "$P_SHA" price.txt "price=100" "price=0" "bash loose.test.sh" 2>&1); rc=$?
want "it is refused"         "1" "$rc"
want_in "and the reason"     'still passes with price.txt broken' "$out"

echo "--- a break planted in the test itself proves nothing ---"
out=$(driver_prove_by_break "$REPO" price.test.sh "$P_SHA" price.test.sh "grep" "false" "bash price.test.sh" 2>&1); rc=$?
want "it cannot be checked"  "3" "$rc"
want_in "and says why"       'test file' "$out"

echo "--- a break whose text is not in the file broke nothing ---"
out=$(driver_prove_by_break "$REPO" price.test.sh "$P_SHA" price.txt "price=999" "price=0" "bash price.test.sh" 2>&1); rc=$?
want "it cannot be checked"  "3" "$rc"
want_in "and says so"        'not in price.txt' "$out"

echo "--- a test that fails with the code intact is not done ---"
printf '#!/usr/bin/env bash\ngrep -q price=5 price.txt\n' > "$REPO/wrong.test.sh"
git -C "$REPO" add wrong.test.sh; git -C "$REPO" commit -qm "test: wrong"
W_SHA=$(git -C "$REPO" rev-parse HEAD)
out=$(driver_prove_by_break "$REPO" wrong.test.sh "$W_SHA" price.txt "price=100" "price=0" "bash wrong.test.sh" 2>&1); rc=$?
want "it is refused"         "2" "$rc"
want_in "and the reason"     'fails with the code intact' "$out"

echo "--- the build step accepts a test-only answer proved by its break ---"
driver_state_init 131 --worktree "$REPO" --repo "$REPO"
fix_plan 131 1
fix_ai build "$(jq -nc --arg t "$P_SHA" '{step:"build", skills:["superpowers:subagent-driven-development"], status:"built", task:"task 1",
  testOnly:{test:{file:"price.test.sh", behaviour:"the price is 100"}, command:"bash price.test.sh", testCommit:$t,
            break:{file:"price.txt", find:"price=100", replace:"price=0"}},
  changed:[{path:"price.test.sh", action:"create"}], changelog:{skipped:"a test-only change"}}')" \
  superpowers:subagent-driven-development
out=$(DRIVER_TICKET=131 driver_step_build 131 2>&1); rc=$?
want "the step finishes"            "0" "$rc"
want_in "naming the planted break"  'price.txt broken' "$out"

echo "--- and sends back a test-only answer whose break is not covered ---"
driver_state_init 132 --worktree "$REPO" --repo "$REPO"
fix_plan 132 1
fix_ai build "$(jq -nc --arg t "$P_SHA" '{step:"build", skills:["superpowers:subagent-driven-development"], status:"built", task:"task 1",
  testOnly:{test:{file:"loose.test.sh", behaviour:"the file exists"}, command:"bash loose.test.sh", testCommit:$t,
            break:{file:"price.txt", find:"price=100", replace:"price=0"}},
  changed:[{path:"loose.test.sh", action:"create"}], changelog:{skipped:"a test-only change"}}')" \
  superpowers:subagent-driven-development
rc=0; DRIVER_TICKET=132 driver_step_build 132 >/dev/null 2>&1 || rc=$?
want "it asks for rework"  "30" "$rc"

# The config is left as the fixture wrote it. Four cases above mutate it, and a suite
# whose end state is not its start state is an ordering dependency nothing states.
git -C "$REPO" checkout -- .claude/harness.json 2>/dev/null || true

echo "--- a build's reworded tests reach the run's ledger, across tries (#11222) ---"
export DRIVER_TICKET=131
driver_state_init 131 --worktree "$REPO" --repo "$REPO"
fix_plan 131 1
printf '%s\n' '{"file":"earlier.test.sh","removedBecause":"an earlier try removed it"}' > "$(driver_state_dir 131)/steps/replaced.jsonl"
fix_ai build "$(FIX_REPLACED=feature.test.sh fix_build feature.test.sh "bash feature.test.sh" "$TEST_SHA" "$IMPL_SHA")" \
  superpowers:subagent-driven-development
out=$(driver_step_build 131 2>&1); rc=$?
want "the step finishes"                          "0" "$rc"
want_in "its report is on the ledger"             'feature.test.sh' "$(cat "$(driver_state_dir 131)/steps/replaced.jsonl")"
want_in "and an earlier try's report is still there" 'earlier.test.sh' "$(cat "$(driver_state_dir 131)/steps/replaced.jsonl")"
exit $FAILED
