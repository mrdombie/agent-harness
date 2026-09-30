#!/usr/bin/env bash
# spend.test.sh — a step runs headless with a permission mode, carries only the tools
# its work uses, and leaves what it cost, how big its context got and how many words
# it was given on the record: those are the shadow run's measurements.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../ai-step.sh" || exit 1
export DRIVER_TICKET=301
driver_state_init 301

# A transcript with two assistant turns (context 1,000 then 4,500 tokens), a line
# that is not JSON, and a result line that says the step cost $1.50.
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

echo "--- a step runs headless, and lean ---"
driver_ai_step 301 plan >/dev/null 2>&1; rc=$?
want "it finishes, a non-JSON line and all" "0"  "$rc"
args="$(cat "$FIX/claude-args-plan.txt")"
want_in "it passes a permission mode"       '--permission-mode'   "$args"
want_in "auto, unless told otherwise"       '^auto$'              "$args"
want_in "no connectors"                     '--strict-mcp-config' "$args"
want_in "an empty connector list"           'mcpServers'          "$args"
want_in "and the tools no step uses left out" '--disallowed-tools' "$args"
want_in "the ask-a-person tool among them"  'AskUserQuestion'     "$args"
want_not_in "no spend cap"                  'max-budget-usd'      "$args"
want_not_in "and Skill is never left out"   '(^| )Skill( |$)'      "$(grep -A1 -- '--disallowed-tools' "$FIX/claude-args-plan.txt" | tail -1)"

echo "--- the step's cost and context are on the record ---"
S="$(driver_state_dir 301)/state.json"
want "its cost"                             "1.5"  "$(jq -r '.usage.plan[0].cost' "$S")"
want "its first context"                    "1000" "$(jq -r '.usage.plan[0].ctxFirst' "$S")"
want "its largest context"                  "4500" "$(jq -r '.usage.plan[0].ctxMax' "$S")"
want "its turns"                            "2"    "$(jq -r '.usage.plan[0].turns' "$S")"
want "the words it was given"               "yes"  "$(jq -r 'if .usage.plan[0].words > 0 then "yes" else "no" end' "$S")"
want "and the run's spend"                  "1.5"  "$(jq -r '.spend' "$S")"

echo "--- a second run of the step appends, and the spend adds up — nothing stops it ---"
driver_ai_step 301 plan >/dev/null 2>&1
driver_ai_step 301 plan >/dev/null 2>&1; rc=$?
want "three records"                        "3"    "$(jq -r '.usage.plan | length' "$S")"
want "spend is the sum"                     "4.5"  "$(jq -r '.spend' "$S")"
want "and the step still ran"               "0"    "$rc"

echo "--- the permission mode and the tool list are settings ---"
driver_state_init 302
fix_ai_costed plan '{"files":["b.sh"],"tests":["b.test.sh"]}' 0.25 superpowers:writing-plans
DRIVER_PERMISSION_MODE=acceptEdits DRIVER_DISALLOWED_TOOLS="" DRIVER_TICKET=302 driver_ai_step 302 plan >/dev/null 2>&1
args="$(cat "$FIX/claude-args-plan.txt")"
want_in "the mode is read from the setting" '^acceptEdits$'       "$args"
want_not_in "an empty tool list leaves every tool in" '--disallowed-tools' "$args"

exit "$FAILED"
