#!/usr/bin/env bash
# ai-step.test.sh — an AI step is the only place the driver hands control to a
# model, so it is the only place the driver has to be suspicious. Three things
# are asserted, and the first is the rule Dom added on 2026-09-27: a brief that
# names a Skill has not run until that Skill call is in the run log.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../ai-step.sh" || exit 1
export DRIVER_TICKET=101
driver_state_init 101

echo "--- the happy path ---"
fix_brief plan superpowers:writing-plans
fix_ai    plan '{"files":["a.sh"],"tests":["a.test.sh"]}' superpowers:writing-plans
out=$(driver_ai_step 101 plan 2>&1); rc=$?
want "it finishes"              "0"          "$rc"
want "the answer is stored"     "a.sh"       "$(jq -r '.files[0]' "$(driver_state_dir 101)/steps/plan.json")"
want_in "and it says the skill ran" 'superpowers:writing-plans' "$out"

echo "--- the brief named a Skill and the log does not contain it ---"
fix_ai plan '{"files":["a.sh"],"tests":["a.test.sh"]}'    # no skill block
out=$(driver_ai_step 101 plan 2>&1); rc=$?
want "it refuses with the no-skill code" "21" "$rc"
want_in "and names the skill it wanted"  'superpowers:writing-plans' "$out"

echo "--- a DIFFERENT skill ran; that is not the one the brief named ---"
fix_ai plan '{"files":["a.sh"],"tests":["a.test.sh"]}' superpowers:brainstorming
rc=0; driver_ai_step 101 plan >/dev/null 2>&1 || rc=$?
want "a near miss still refuses" "21" "$rc"

echo "--- the build brief must invoke subagent-driven-development ---"
fix_brief build superpowers:subagent-driven-development
fix_ai    build '{"items":[]}' superpowers:subagent-driven-development
rc=0; driver_ai_step 101 build >/dev/null 2>&1 || rc=$?
want "the named build skill satisfies it" "0" "$rc"
fix_ai    build '{"items":[]}' superpowers:test-driven-development
rc=0; driver_ai_step 101 build >/dev/null 2>&1 || rc=$?
want "a sibling skill does not"           "21" "$rc"

echo "--- the AI asked a question instead of answering ---"
fix_ai plan '{"question":"which table owns the org id?"}' superpowers:writing-plans
out=$(driver_ai_step 101 plan 2>&1); rc=$?
want "a question parks the ticket"  "20" "$rc"
want_in "and the question survives" 'which table owns the org id' "$out"

echo "--- no brief for the step ---"
rm -f "$DRIVER_BRIEFS/plan.md"
rc=0; driver_ai_step 101 plan >/dev/null 2>&1 || rc=$?
want "a missing brief refuses" "23" "$rc"

echo "--- the schema the briefs ticket owns ---"
fix_brief compare superpowers:requesting-code-review
fix_schema compare '{"required":["differences"],"properties":{"differences":{"type":"array"}}}'
fix_ai compare '{"differences":[]}' superpowers:requesting-code-review
rc=0; driver_ai_step 101 compare >/dev/null 2>&1 || rc=$?
want "an answer that matches its schema passes" "0" "$rc"
fix_ai compare '{"notes":"looks fine"}' superpowers:requesting-code-review
out=$(driver_ai_step 101 compare 2>&1); rc=$?
want "a missing required key refuses"  "22" "$rc"
want_in "and names the key"            'differences' "$out"
fix_ai compare '{"differences":"none"}' superpowers:requesting-code-review
rc=0; driver_ai_step 101 compare >/dev/null 2>&1 || rc=$?
want "the wrong type refuses too"      "22" "$rc"

echo "--- no schema on disk is normal: the briefs ticket may not have landed ---"
rm -f "$DRIVER_SCHEMAS/compare.json"
fix_ai compare '{"anything":1}' superpowers:requesting-code-review
rc=0; driver_ai_step 101 compare >/dev/null 2>&1 || rc=$?
want "it still finishes" "0" "$rc"

echo "--- a brief that names no skill is not held to one ---"
fix_brief note ""
fix_ai    note '{"ok":true}'
rc=0; driver_ai_step 101 note >/dev/null 2>&1 || rc=$?
want "no skill named, no skill demanded" "0" "$rc"

echo "--- the answer is not JSON at all ---"
fix_brief plan superpowers:writing-plans
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"superpowers:writing-plans"}}]}}' > "$FIX/ai/plan.jsonl"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"I had a think and it seems fine."}' >> "$FIX/ai/plan.jsonl"
rc=0; driver_ai_step 101 plan >/dev/null 2>&1 || rc=$?
want "prose where JSON was asked for refuses" "22" "$rc"

echo "--- JSON inside a fence is still JSON ---"
fix_ai plan '```json
{"files":["b.sh"]}
```' superpowers:writing-plans
rc=0; driver_ai_step 101 plan >/dev/null 2>&1 || rc=$?
want "a fenced answer is read"  "0"     "$rc"
want "and parsed"               "b.sh"  "$(jq -r '.files[0]' "$(driver_state_dir 101)/steps/plan.json")"

echo "--- the transcript is kept, because a verdict nobody can re-read is a claim ---"
want "the run log is on disk" "1" "$([ -s "$(driver_state_dir 101)/steps/plan.log" ] && echo 1)"

exit $FAILED
