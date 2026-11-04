#!/usr/bin/env bash
# proof-unreachable.test.sh — a proof whose test could not reach the app was never
# run, and is never read as "still fails with the change".
#
# Measured: four fix and repair steps named a Playwright e2e spec as their proof. The
# proof trees run no app server, so `page.goto: net::ERR_CONNECTION_REFUSED` came
# back on both sides and the change was refused as not doing the job.
#
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fix_real_briefs
. "$HERE/../ai-step.sh" || exit 1
. "$HERE/../steps/fix.sh" || exit 1
. "$HERE/../facts.sh" || exit 1

c() { git -C "$1" -c user.email=t@e.invalid -c user.name=T commit -qm "$2"; git -C "$1" rev-parse HEAD; }
CFG="$REPO/.claude/harness.json"; cp "$CFG" "$FIX/harness.orig.json"
e2e_on()  { jq '.tests.e2eProofs = true' "$FIX/harness.orig.json" > "$CFG"; }
e2e_off() { cp "$FIX/harness.orig.json" "$CFG"; }

# A test that dies the way a browser spec dies with no server, in both trees.
printf 'no\n' > "$REPO/feat.txt"; git -C "$REPO" add feat.txt; c "$REPO" base >/dev/null
printf '#!/usr/bin/env bash\ngrep -q yes feat.txt || echo "wrong"\necho "  1) page.goto: net::ERR_CONNECTION_REFUSED at http://localhost:3000/inbox"\nexit 1\n' > "$REPO/feat.ui.test.sh"
printf '#!/usr/bin/env bash\necho "Error: connect ECONNREFUSED 127.0.0.1:3000"\nexit 1\n' > "$REPO/feat.api.test.sh"
mkdir -p "$REPO/e2e"; printf '#!/usr/bin/env bash\ngrep -q yes feat.txt\n' > "$REPO/e2e/feat.spec.ts"
printf '#!/usr/bin/env bash\ngrep -q yes feat.txt || { echo " FAIL  feat > is yes"; exit 1; }\n' > "$REPO/feat.test.sh"
git -C "$REPO" add .; TS=$(c "$REPO" "test: feat")
printf 'yes\n' > "$REPO/feat.txt"; git -C "$REPO" add feat.txt; IS=$(c "$REPO" "feat: feat")

echo "--- an app that could not be reached is never run there, not 'still fails' ---"
out=$(driver_prove_red_green "$REPO" feat.ui.test.sh "$TS" "$IS" "bash feat.ui.test.sh" 2>&1); rc=$?
want "it is its own exit" "9" "$rc"
want_in "saying the app could not be reached" "could not reach the app" "$out"
want_in "so the test was never run" "never run" "$out"
want_in "and what proves it instead" "unit or DOM test" "$out"
want_not_in "never 'still fails'" 'still fails' "$out"
out=$(driver_prove_red_green "$REPO" feat.api.test.sh "$TS" "$IS" "bash feat.api.test.sh" 2>&1); rc=$?
want "ECONNREFUSED to localhost is the same" "9" "$rc"
want_not_in "never 'still fails'" 'still fails' "$out"
out=$(driver_prove_by_break "$REPO" feat.ui.test.sh "$TS" feat.txt no maybe "bash feat.ui.test.sh" 2>&1); rc=$?
want "the break proof reads it too" "9" "$rc"

echo "--- an e2e spec named as the proof is turned back before any tree is built ---"
out=$(driver_prove_red_green "$REPO" e2e/feat.spec.ts "$TS" "$IS" "bash e2e/feat.spec.ts" 2>&1); rc=$?
want "as a command that cannot prove" "7" "$rc"
want_in "saying why" "e2e browser spec cannot prove a change here" "$out"
want_in "and what to prove it with" "vitest" "$out"
want_not_in "never 'still fails'" 'still fails' "$out"
out=$(driver_prove_red_green "$REPO" feat.test.sh "$TS" "$IS" "npx playwright test e2e/feat.spec.ts" 2>&1); rc=$?
want "a playwright command is the same" "7" "$rc"

echo "--- a unit test red then green is proved as now ---"
out=$(driver_prove_red_green "$REPO" feat.test.sh "$TS" "$IS" "bash feat.test.sh" 2>&1); rc=$?
want "proved" "0" "$rc"
want_in "red then green" 'red .* then green' "$out"

echo "--- tests.e2eProofs: true — this project's e2e harness proves ---"
e2e_on
out=$(driver_prove_red_green "$REPO" e2e/feat.spec.ts "$TS" "$IS" "bash e2e/feat.spec.ts" 2>&1); rc=$?
want "an e2e spec proves" "0" "$rc"
out=$(driver_prove_red_green "$REPO" feat.ui.test.sh "$TS" "$IS" "bash feat.ui.test.sh" 2>&1); rc=$?
want "and a refused connection is the test's own failure" "2" "$rc"
e2e_off

echo "--- the briefs carry the rule, and the opt-out changes it ---"
for s in build fix; do
  want_in "$s.md has the place it goes" '{{PROOF_LIMITS}}' "$(cat "$HERE/../../briefs/$s.md")"
  want "facts.json declares it for $s" "true" "$(jq --arg s "$s" '.steps[$s].facts | has("PROOF_LIMITS")' "$HERE/../../briefs/facts.json")"
done
want_in "the fact says e2e cannot prove" "cannot prove" "$(driver_fact_proof_limits)"
e2e_on; want_in "opted in, it says they can" "can prove" "$(driver_fact_proof_limits)"; e2e_off
driver_state_init 600 >/dev/null 2>&1 || true
driver_facts_common 600 fix
want_in "and it is written for a step" "cannot prove" "$(cat "$(driver_state_dir 600)/steps/fix.facts/PROOF_LIMITS" 2>/dev/null)"

# ---- the fix round: sent back once, told why --------------------------------
WT="$FIX/wt601"
git -C "$REPO" worktree add -q "$WT" -b "tkt-601/work" develop
driver_state_init 601 --worktree "$WT" --branch "tkt-601/work"
fix_issue 601 OPEN "status:claimed"
printf '%s\n' '{"step":"review","skills":[],"status":"reviewed","round":1,"verdict":"BLOCKED","findings":[{"id":"F9","file":"m.txt","line":1,"grade":"major","summary":"m is old","reason":"a person sees old","fix":"make it new"}]}' \
  > "$(driver_state_dir 601)/steps/review.json"
printf 'old\n' > "$WT/m.txt"; printf '#!/usr/bin/env bash\ngrep -q new m.txt\n' > "$WT/m.test.sh"
printf '#!/usr/bin/env bash\necho "page.goto: net::ERR_CONNECTION_REFUSED at http://localhost:3000/"\nexit 1\n' > "$WT/m.ui.test.sh"
git -C "$WT" add .; FTS=$(c "$WT" "test: m")
printf 'new\n' > "$WT/m.txt"; git -C "$WT" add m.txt; FIS=$(c "$WT" "fix: m")
fanswer() { jq -nc --arg f "$1" --arg c "$2" --arg ts "$FTS" --arg is "$FIS" \
  '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1,
    cleared:[{blockerId:"F9", change:[{path:"m.txt", action:"modify"}],
      test:{file:$f, behaviour:"m is new", redWhen:"m goes back"},
      command:$c, testCommit:$ts, implCommit:$is, failedBefore:true, passedAfter:true}]}'; }
then_answer() { # <step> <skills> <json> — what the NEXT call of <step> answers
  local keep; keep=$(cat "$FIX/ai/$1.jsonl")
  fix_ai "$1" "$3" "$2"; mv "$FIX/ai/$1.jsonl" "$FIX/ai/$1.then.jsonl"
  printf '%s\n' "$keep" > "$FIX/ai/$1.jsonl"
}

echo "--- fix: an unreachable app is asked once more, told why, then proved by a unit test ---"
: > "$CLAUDE_LOG"
fix_ai fix "$(fanswer m.ui.test.sh 'bash m.ui.test.sh')" superpowers:receiving-code-review
then_answer fix superpowers:receiving-code-review "$(fanswer m.test.sh 'bash m.test.sh')"
rc=0; out=$(driver_step_fix 601 2>&1) || rc=$?
want "the round finishes once a unit test proves it" "0" "$rc"
want "the fix step ran twice" "2" "$(grep -cx fix "$CLAUDE_LOG")"
want_in "the retry is told why" "F9: .*could not reach the app" "$(cat "$FIX/claude-stdin-fix.txt")"
want_not_in "never 'still fails'" 'still fails' "$out"
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1

suite_end "$FAILED"
