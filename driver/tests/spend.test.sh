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
# #11172 — the tools a step loads are an ALLOWLIST: the eight any step of trial 3
# ever called. Everything else was ~14k tokens re-sent on every call.
want_in "only the tools a step uses are loaded" '--tools'          "$args"
want_in "Skill among them"                  '^Skill$'             "$args"
want_in "and Agent, which the skills dispatch with" '^Agent$'     "$args"
want_not_in "the ask-a-person tool is not"  'AskUserQuestion'     "$args"
want_not_in "no spend cap"                  'max-budget-usd'      "$args"
want_in "only the user's settings are loaded, so CLAUDE.md is not preloaded" '^--setting-sources$' "$args"
want_in "user"                              '^user$'              "$args"

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
DRIVER_PERMISSION_MODE=acceptEdits DRIVER_TOOLS=default DRIVER_DISALLOWED_TOOLS="" DRIVER_TICKET=302 driver_ai_step 302 plan >/dev/null 2>&1
args="$(cat "$FIX/claude-args-plan.txt")"
want_in "the mode is read from the setting" '^acceptEdits$'       "$args"
want_not_in "tools=default loads Claude Code's whole set" '--tools' "$args"
want_not_in "and an empty block list leaves every tool in" '--disallowed-tools' "$args"
DRIVER_TOOLS=default DRIVER_TICKET=302 driver_ai_step 302 plan >/dev/null 2>&1
args="$(cat "$FIX/claude-args-plan.txt")"
want_in "tools=default falls back to the block list" '--disallowed-tools' "$args"
want_in "the ask-a-person tool among it"    'AskUserQuestion'     "$args"

echo "--- a step may narrow its own tools in facts.json (#11172) ---"
mkdir -p "$FIX/briefs"; printf '{"steps":{"plan":{"tools":["Read","Grep"]}}}' > "$FIX/briefs/facts.json"
DRIVER_BRIEFS="$FIX/briefs" DRIVER_TICKET=302 driver_ai_step 302 plan >/dev/null 2>&1
args="$(cat "$FIX/claude-args-plan.txt")"
want_in "the step's own list"               '^Grep$'              "$args"
want_not_in "and nothing else"              '^Bash$'              "$args"
rm -f "$FIX/briefs/facts.json"

echo "--- the project's instruction files are named, not preloaded (#11172) ---"
wt=$(driver_state_get 302 worktree); [ -n "$wt" ] || wt="$MAIN_REPO"
printf '# rules\n' > "$wt/CLAUDE.md"; printf '# agents\n' > "$wt/AGENTS.md"
mkdir -p "$wt/.claude"; printf '{"hooks":{}}' > "$wt/.claude/settings.json"
DRIVER_TICKET=302 driver_ai_step 302 plan >/dev/null 2>&1
args="$(cat "$FIX/claude-args-plan.txt")"
want_in "the project's settings file is still loaded" "^$wt/.claude/settings.json$" "$args"
want_in "and the instruction files are named" 'CLAUDE.md, AGENTS.md' "$args"
DRIVER_PROJECT_INSTRUCTIONS=preload DRIVER_TICKET=302 driver_ai_step 302 plan >/dev/null 2>&1
args="$(cat "$FIX/claude-args-plan.txt")"
want_not_in "preload restores the old behaviour" '--setting-sources' "$args"
rm -f "$wt/CLAUDE.md" "$wt/AGENTS.md"

exit "$FAILED"
