#!/usr/bin/env bash
# proof-output-kept.test.sh — the build keeps each proof's command and what it printed.
# The pull request carries the run's evidence: the command the
# driver ran, its exit and its output, red without the change and green with it. The
# proof trees are thrown away, so the output is kept beside the task's .proved record
# or it is gone before ship can show it. Self-check's green gates are kept the same way.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/build.sh" || exit 1
. "$HERE/../steps/self-check.sh" || exit 1

printf 'no\n' > "$REPO/feature.txt"
git -C "$REPO" add feature.txt; git -C "$REPO" commit -qm base
printf '#!/usr/bin/env bash\necho "checking the feature"\ngrep -q yes feature.txt || { echo "FEATURE-MISSING"; exit 1; }\necho FEATURE-PRESENT\n' > "$REPO/feature.test.sh"
git -C "$REPO" add feature.test.sh; git -C "$REPO" commit -qm "test: the feature"
TS=$(git -C "$REPO" rev-parse HEAD)
printf 'yes\n' > "$REPO/feature.txt"
git -C "$REPO" add feature.txt; git -C "$REPO" commit -qm "feat: the feature"
IS=$(git -C "$REPO" rev-parse HEAD)

echo "--- a red/green proof keeps its command and both halves' output ---"
K="$FIX/keep.json"
out=$(DRIVER_PROOF_KEEP="$K" driver_prove_red_green "$REPO" feature.test.sh "$TS" "$IS" "bash feature.test.sh" 2>&1); rc=$?
want "it proves"                         "0" "$rc"
want "the command is kept"               "bash feature.test.sh" "$(jq -r '.command' "$K" 2>/dev/null)"
want "and the test file"                 "feature.test.sh" "$(jq -r '.testFile' "$K" 2>/dev/null)"
want "the red half's exit"               "1" "$(jq -r '.red.exit' "$K" 2>/dev/null)"
want_in "and what it printed"            'FEATURE-MISSING' "$(jq -r '.red.output' "$K" 2>/dev/null)"
want "the green half's exit"             "0" "$(jq -r '.green.exit' "$K" 2>/dev/null)"
want_in "and what it printed"            'FEATURE-PRESENT' "$(jq -r '.green.output' "$K" 2>/dev/null)"
want "each half names its commit"        "$(git -C "$REPO" rev-parse --short=8 "$IS^") $(git -C "$REPO" rev-parse --short=8 "$IS")" \
  "$(jq -r '"\(.red.at) \(.green.at)"' "$K" 2>/dev/null)"

echo "--- a planted-break proof keeps them too ---"
K2="$FIX/keep-break.json"
rc=0; DRIVER_PROOF_KEEP="$K2" driver_prove_by_break "$REPO" feature.test.sh "$IS" feature.txt yes no "bash feature.test.sh" >/dev/null 2>&1 || rc=$?
want "it proves"                         "0" "$rc"
want "red with the break"                "1" "$(jq -r '.red.exit' "$K2" 2>/dev/null)"
want_in "and what it printed"            'FEATURE-MISSING' "$(jq -r '.red.output' "$K2" 2>/dev/null)"
want "green with it restored"            "0" "$(jq -r '.green.exit' "$K2" 2>/dev/null)"
want_in "the red half says what broke"   'feature.txt broken' "$(jq -r '.red.at' "$K2" 2>/dev/null)"

echo "--- the output is bounded: a runner that prints a megabyte keeps its tail ---"
printf '#!/usr/bin/env bash\nyes filler | head -50000\ngrep -q yes feature.txt || { echo LAST-LINE-RED; exit 1; }\necho LAST-LINE-GREEN\n' > "$REPO/loud.test.sh"
git -C "$REPO" add loud.test.sh; git -C "$REPO" commit -qm "test: loud"; LT=$(git -C "$REPO" rev-parse HEAD)
printf 'no\n' > "$REPO/feature.txt"; git -C "$REPO" commit -qam "undo"
printf 'yes\n' > "$REPO/feature.txt"; git -C "$REPO" commit -qam "redo"; LI=$(git -C "$REPO" rev-parse HEAD)
K3="$FIX/keep-loud.json"
DRIVER_PROOF_KEEP="$K3" driver_prove_red_green "$REPO" loud.test.sh "$LT" "$LI" "bash loud.test.sh" >/dev/null 2>&1
want_in "the last line is kept"          'LAST-LINE-GREEN' "$(jq -r '.green.output' "$K3" 2>/dev/null)"
LN=$(jq -r '.green.output' "$K3" 2>/dev/null | wc -c | tr -d ' ')
want "and no more than the cap"          "1" "$(( LN > 0 && LN <= 2100 ? 1 : 0 ))"

# --- the build step puts it on the task's .proved record ---------------------
fix_plan() {
  printf '{"step":"plan","skills":["superpowers:writing-plans"],"status":"planned","designSource":"ticket-body","premise":{"verdict":"still-true","evidence":"a.sh:1"},"tasks":[%s]}\n' \
    "$(jq -nc '{title:"task 1", files:[{path:"a.sh",action:"modify"}], tests:[{file:"a.test.sh", behaviour:"it does the thing", redWhen:"the fix is deleted"}]}')" \
    | jq . > "$(driver_state_dir "$1")/steps/plan.json"
}
fix_build() {
  jq -nc --arg f "$1" --arg c "$2" --arg t "$3" --arg i "$4" \
    '{step:"build", skills:["superpowers:subagent-driven-development"], status:"built", task:"task 1",
      testFirst:{test:{file:$f, behaviour:"it does the thing", redWhen:"the fix is deleted"},
                 command:$c, testCommit:$t, implCommit:$i,
                 failedBefore:true, redOutput:"FAIL", passedAfter:true, greenOutput:"PASS"},
      changed:[{path:"a.sh", action:"modify"}], changelog:{skipped:"a test-only change"}}'
}
echo "--- the build step records the proof on the task ---"
export DRIVER_TICKET=101
driver_state_init 101 --worktree "$REPO" --repo "$REPO"
fix_brief build superpowers:subagent-driven-development
fix_plan 101
fix_ai build "$(fix_build feature.test.sh "bash feature.test.sh" "$TS" "$IS")" superpowers:subagent-driven-development
rc=0; driver_step_build 101 >/dev/null 2>&1 || rc=$?
P="$(driver_state_dir 101)/steps/build-task-1.proved"
want "the step finishes"                 "0" "$rc"
want "the record names the command"      "bash feature.test.sh" "$(jq -r '.proof.command // ""' "$P" 2>/dev/null)"
want_in "and keeps the red output"       'FEATURE-MISSING' "$(jq -r '.proof.red.output // ""' "$P" 2>/dev/null)"
want_in "and the green output"           'FEATURE-PRESENT' "$(jq -r '.proof.green.output // ""' "$P" 2>/dev/null)"
want_in "and the verdict line"           'red \(exit 1\) at .* then green' "$(jq -r '.proof.line // ""' "$P" 2>/dev/null)"

echo "--- self-check keeps every green gate's command and output ---"
jq '.gates = {lint: "echo lint-said-ok", unit: "printf \"unit: 3 passed\\n\""}' "$HARNESS_CFG_PATH" > "$FIX/cfg.json"
export HARNESS_CFG="$FIX/cfg.json" HARNESS_CFG_PATH="$FIX/cfg.json"
rc=0; driver_step_self_check 101 >/dev/null 2>&1 || rc=$?
G="$(driver_state_dir 101)/steps/self-check.gates.jsonl"
want "self-check is green"               "0" "$rc"
want "both gates are kept"               "lint unit" "$(jq -rs '[.[].gate] | sort | join(" ")' "$G" 2>/dev/null)"
want "with their commands"               "echo lint-said-ok" "$(jq -rs '.[] | select(.gate == "lint") | .command' "$G" 2>/dev/null)"
want_in "and what they printed"          'unit: 3 passed' "$(jq -rs '.[] | select(.gate == "unit") | .output' "$G" 2>/dev/null)"
want "and their exit"                    "0" "$(jq -rs '.[] | select(.gate == "unit") | .exit' "$G" 2>/dev/null)"
jq '.gates = {lint: "echo second-run"}' "$FIX/cfg.json" > "$FIX/cfg2.json"
rc=0; HARNESS_CFG="$FIX/cfg2.json" HARNESS_CFG_PATH="$FIX/cfg2.json" driver_step_self_check 101 >/dev/null 2>&1 || rc=$?
want "a later run replaces the record"   "lint" "$(jq -rs '[.[].gate] | join(" ")' "$G" 2>/dev/null)"

suite_end "$FAILED"
