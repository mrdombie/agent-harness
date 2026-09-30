#!/usr/bin/env bash
# spend.test.sh — a step runs headless with a permission mode, each step is capped
# by the CLI, the whole run is capped by the driver, and every step's cost, context
# size and brief length land on the record: those are the shadow run's measurements.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../ai-step.sh" || exit 1
export DRIVER_TICKET=301
driver_state_init 301

# A transcript with two assistant turns (context 1,000 then 4,500 tokens) and a
# result line that says the step cost $1.50.
fix_ai_costed() { # <step> <answer> <cost> <skill>
  local f="$FIX/ai/$1.jsonl"
  jq -nc --arg s "$4" '{type:"assistant", message:{content:[{type:"tool_use", name:"Skill", input:{skill:$s}}],
    usage:{input_tokens:100, cache_read_input_tokens:900, cache_creation_input_tokens:0}}}' > "$f"
  jq -nc '{type:"assistant", message:{content:[{type:"text", text:"ok"}],
    usage:{input_tokens:500, cache_read_input_tokens:3000, cache_creation_input_tokens:1000}}}' >> "$f"
  printf 'not json — the CLI prints warnings too\n' >> "$f"
  jq -nc --arg r "$2" --argjson c "$3" \
    '{type:"result", subtype:"success", is_error:false, result:$r, structured_output:($r | fromjson), total_cost_usd:$c, num_turns:2}' >> "$f"
}

fix_brief plan superpowers:writing-plans
fix_ai_costed plan '{"files":["a.sh"],"tests":["a.test.sh"]}' 1.5 superpowers:writing-plans

echo "--- a step runs headless, capped ---"
DRIVER_RUN_BUDGET_USD=100 driver_ai_step 301 plan >/dev/null 2>&1; rc=$?
want "it finishes"                        "0"    "$rc"
args="$(cat "$FIX/claude-args-plan.txt")"
want_in "it passes a permission mode"     '--permission-mode'  "$args"
want_in "auto, unless told otherwise"     '^auto$'             "$args"
want_in "and a per-step budget"           '--max-budget-usd'   "$args"
want_in "of 25, unless told otherwise"    '^25$'               "$args"

echo "--- the step's cost and context are on the record ---"
S="$(driver_state_dir 301)/state.json"
want "its cost"                           "1.5"  "$(jq -r '.usage.plan[0].cost' "$S")"
want "its first context"                  "1000" "$(jq -r '.usage.plan[0].ctxFirst' "$S")"
want "its largest context"                "4500" "$(jq -r '.usage.plan[0].ctxMax' "$S")"
want "its turns"                          "2"    "$(jq -r '.usage.plan[0].turns' "$S")"
want "the words it was given"             "yes"  "$(jq -r 'if .usage.plan[0].words > 0 then "yes" else "no" end' "$S")"
want "and the run's spend"                "1.5"  "$(jq -r '.spend' "$S")"

echo "--- a second run of the step appends, and the spend adds up ---"
DRIVER_RUN_BUDGET_USD=100 driver_ai_step 301 plan >/dev/null 2>&1
want "two records"                        "2"    "$(jq -r '.usage.plan | length' "$S")"
want "spend is the sum"                   "3"    "$(jq -r '.spend' "$S")"

echo "--- past the run's budget, the next step does not start ---"
before=$(grep -c . "$CLAUDE_LOG")
out=$(DRIVER_RUN_BUDGET_USD=3 driver_ai_step 301 plan 2>&1); rc=$?
want "it refuses with the budget code"    "26"   "$rc"
want "and no agent was started"           "$before" "$(grep -c . "$CLAUDE_LOG")"
want_in "it says what was spent"          'spent \$3 of its \$3' "$out"
want_in "and leaves a park note"          'budget before plan' "$(jq -r '.park_note // ""' "$S")"

echo "--- the permission mode and step budget are settings ---"
driver_state_init 302
fix_ai_costed plan '{"files":["b.sh"],"tests":["b.test.sh"]}' 0.25 superpowers:writing-plans
DRIVER_PERMISSION_MODE=acceptEdits DRIVER_STEP_BUDGET_USD=7 DRIVER_TICKET=302 driver_ai_step 302 plan >/dev/null 2>&1
args="$(cat "$FIX/claude-args-plan.txt")"
want_in "the mode is read from the setting"   '^acceptEdits$' "$args"
want_in "and the step budget"                 '^7$'           "$args"

exit "$FAILED"
