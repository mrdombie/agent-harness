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

echo "--- a transcript with more than one result: the LAST one is the answer ---"
# The reader slurps and takes the last result OBJECT, and the header records the
# `tail -1` bug that cost: an answer spanning several lines had its closing brace read
# as the answer. No case built a multi-result transcript, so a per-line reader would
# have passed — and a retried turn produces exactly that shape.
{ jq -nc --arg s superpowers:writing-plans \
    '{type:"assistant", message:{content:[{type:"tool_use", name:"Skill", input:{skill:$s}}]}}'
  jq -nc '{type:"result", subtype:"success", is_error:false, result:"{\n  \"files\": [\"first\"]\n}"}'
  jq -nc '{type:"result", subtype:"success", is_error:false, result:"{\n  \"files\": [\"second\"]\n}"}'
} > "$FIX/ai/plan.jsonl"
rc=0; driver_ai_step 101 plan >/dev/null 2>&1 || rc=$?
want "it reads an answer"            "0" "$rc"
want "and it is the last result"     "second" \
  "$(jq -r '.files[0]' "$(driver_state_dir 101)/steps/plan.json")"

echo "--- no brief for the step ---"
rm -f "$DRIVER_BRIEFS/plan.md"
rc=0; driver_ai_step 101 plan >/dev/null 2>&1 || rc=$?
want "a missing brief refuses" "23" "$rc"

echo "--- the contract the briefs ticket owns ---"
# Every real schema in briefs/schemas declares `"type": "object"`, so the fixture's
# does too: a contract is checked as the contract, not as a reduction of it.
SCHEMA_OBJ='{"type":"object","additionalProperties":false,"required":["differences"],"properties":{"differences":{"type":"array"}}}'
fix_brief compare superpowers:requesting-code-review
fix_schema compare "$SCHEMA_OBJ"
fix_ai compare '{"differences":[]}' superpowers:requesting-code-review
rc=0; driver_ai_step 101 compare >/dev/null 2>&1 || rc=$?
want "an answer that meets its contract passes" "0" "$rc"
fix_ai compare '{"notes":"looks fine"}' superpowers:requesting-code-review
out=$(driver_ai_step 101 compare 2>&1); rc=$?
want "a missing required key refuses"  "22" "$rc"
want_in "and names the key"            'differences' "$out"
fix_ai compare '{"differences":"none"}' superpowers:requesting-code-review
rc=0; driver_ai_step 101 compare >/dev/null 2>&1 || rc=$?
want "the wrong type refuses too"      "22" "$rc"

echo "--- the contract is checked even when the step's folder was deleted under it ---"
# npx refuses to start from a deleted working directory ("getcwd: cannot access
# parent directories"), and that crash read as "the answer was never checked",
# parking finished work (2026-10-18).
fix_ai compare '{"differences":[]}' superpowers:requesting-code-review
GONE=$(mktemp -d)
rc=0; ( cd "$GONE" && rmdir "$GONE" && driver_ai_step 101 compare >/dev/null 2>&1 ) || rc=$?
want "from a deleted folder, a valid answer still passes" "0" "$rc"

echo "--- the strictness that is NOT in top-level required or type ---"
# These four are the reason the check is one call to briefs/validate.sh. The half a
# validator that used to live in this file read top-level `required` and top-level
# property `type` and nothing else, so it accepted 19 of the 24 invalid answers in
# briefs/examples. Each case below is one of the rules it could not see.
fix_ai compare '{"differences":[],"mood":"confident"}' superpowers:requesting-code-review
rc=0; driver_ai_step 101 compare >/dev/null 2>&1 || rc=$?
want "an unknown key refuses (additionalProperties: false)" "22" "$rc"

fix_schema compare '{"type":"object","required":["items"],"properties":{"items":{"type":"array","items":{"type":"object","required":["test"],"properties":{"test":{"type":"string"}}}}}}'
fix_ai compare '{"items":[{"note":"no test named"}]}' superpowers:requesting-code-review
out=$(driver_ai_step 101 compare 2>&1); rc=$?
want "a nested required key refuses"  "22" "$rc"
want_in "and names it"                'test' "$out"

fix_schema compare '{"type":"object","required":["failedBefore"],"properties":{"failedBefore":{"const":true}}}'
fix_ai compare '{"failedBefore":false}' superpowers:requesting-code-review
rc=0; driver_ai_step 101 compare >/dev/null 2>&1 || rc=$?
want "a test that passed BEFORE the change refuses" "22" "$rc"
fix_ai compare '{"failedBefore":true}' superpowers:requesting-code-review
rc=0; driver_ai_step 101 compare >/dev/null 2>&1 || rc=$?
want "and one that failed first passes"             "0"  "$rc"

fix_schema compare '{"type":"object","required":["verdict","blockers"],"properties":{"verdict":{"enum":["SHIP","BLOCKED"]},"blockers":{"type":"array"}},"if":{"properties":{"verdict":{"const":"SHIP"}}},"then":{"properties":{"blockers":{"maxItems":0}}}}'
fix_ai compare '{"verdict":"SHIP","blockers":["a.ts:9 does nothing"]}' superpowers:requesting-code-review
rc=0; driver_ai_step 101 compare >/dev/null 2>&1 || rc=$?
want "SHIP beside an open blocker refuses" "22" "$rc"
fix_ai compare '{"verdict":"SHIP","blockers":[]}' superpowers:requesting-code-review
rc=0; driver_ai_step 101 compare >/dev/null 2>&1 || rc=$?
want "and SHIP with none passes"           "0"  "$rc"

echo "--- an answer that is not an object at all ---"
fix_schema compare "$SCHEMA_OBJ"
fix_ai compare '["not an object"]' superpowers:requesting-code-review
out=$(driver_ai_step 101 compare 2>&1); rc=$?
want "an array is refused"  "22" "$rc"
want_in "and it says what it wanted" 'object' "$out"
fix_ai compare '"just prose"' superpowers:requesting-code-review
rc=0; driver_ai_step 101 compare >/dev/null 2>&1 || rc=$?
want "a bare string is refused too" "22" "$rc"

echo "--- an answer the contract refuses is asked for once more, with the reason ---"
fix_schema compare "$SCHEMA_OBJ"
driver_state_set 101 park_note ""
calls() { grep -cx compare "$CLAUDE_LOG"; }
session() { # <session-id> <answer> — a transcript the real runner would write, its session named
  { jq -nc --arg s "$1" '{type:"system", subtype:"init", session_id:$s}'
    jq -nc '{type:"assistant", message:{content:[{type:"tool_use", name:"Skill", input:{skill:"superpowers:requesting-code-review"}}]}}'
    jq -nc --arg r "$2" --arg s "$1" '{type:"result", subtype:"success", is_error:false, session_id:$s, result:$r, structured_output:($r | try fromjson catch null)}'
  }
}
session sess-1 '{"notes":"no differences key"}' > "$FIX/ai/compare.jsonl"
jq -nc '{type:"result", subtype:"success", is_error:false, result:"{\"differences\":[]}", structured_output:{differences:[]}}' > "$FIX/ai/compare.then.jsonl"
before=$(calls)
out=$(driver_ai_step 101 compare 2>&1); rc=$?
want "the second answer, read, passes"           "0" "$rc"
want "the model was asked exactly twice"         "2" "$(( $(calls) - before ))"
want_in "the re-ask resumes the same session"    'sess-1' "$(cat "$FIX/claude-args-compare.txt")"
want_in "and carries the validator's reason"     'differences' "$(cat "$FIX/claude-stdin-compare.txt")"
want_in "and says it is the answer's shape"      'could not be read by the driver' "$(cat "$FIX/claude-stdin-compare.txt")"
want "the answer kept is the second"             "[]" "$(jq -c '.differences' "$(driver_state_dir 101)/steps/compare.json")"
want "and no note is left to park on later"      "" "$(driver_state_get 101 park_note)"

echo "--- the re-ask is bounded: a second unreadable answer parks ---"
session sess-2 '{"notes":"still no differences"}' > "$FIX/ai/compare.jsonl"
before=$(calls)
out=$(driver_ai_step 101 compare 2>&1); rc=$?
want "it parks with the shape code"              "22" "$rc"
want "after exactly one re-ask"                  "2" "$(( $(calls) - before ))"
want_in "and the park names the validator's reason" 'differences' "$(driver_state_get 101 park_note)"
driver_state_set 101 park_note ""

echo "--- an answer that is not JSON is asked for again too; with no session, the whole brief goes ---"
fix_ai compare 'Here is my answer: differences are none' superpowers:requesting-code-review
jq -nc '{type:"result", subtype:"success", is_error:false, result:"{\"differences\":[]}", structured_output:{differences:[]}}' > "$FIX/ai/compare.then.jsonl"
out=$(driver_ai_step 101 compare 2>&1); rc=$?
want "read on the second ask"                    "0" "$rc"
want_not_in "no session to resume"               '--resume' "$(cat "$FIX/claude-args-compare.txt")"
want_in "so the re-ask carries the brief itself" "$(head -1 "$DRIVER_BRIEFS/compare.md")" "$(cat "$FIX/claude-stdin-compare.txt")"
want_in "and the reason"                         'not JSON' "$(cat "$FIX/claude-stdin-compare.txt")"

echo "--- a question is not re-asked ---"
fix_ai compare '{"question":"which screen is approved?"}' superpowers:requesting-code-review
before=$(calls)
rc=0; driver_ai_step 101 compare >/dev/null 2>&1 || rc=$?
want "a question parks at once"                  "20" "$rc"
want "asked once"                                "1" "$(( $(calls) - before ))"

echo "--- a schema file that does not parse disables nothing ---"
# Present-and-unmatched is a refusal, and so is present-and-unreadable. A broken
# schema used to make its step the one step with no validation at all, and said so
# nowhere. ajv cannot read it either — but it exits 2 rather than 1, which is the
# difference between "the answer is wrong" and "nobody checked the answer".
printf '{"required": [\n' > "$DRIVER_SCHEMAS/compare.json"
fix_ai compare '{}' superpowers:requesting-code-review
out=$(driver_ai_step 101 compare 2>&1); rc=$?
want "a broken schema refuses"      "22" "$rc"
want_in "naming the file to look at" 'compare.json' "$out"
want_in "and saying nothing was checked" 'NOTHING about this answer was checked' "$out"
want_in "and the park carries it"        'never checked' \
  "$(driver_state_get 101 park_note)"
driver_state_set 101 park_note ""

echo "--- a validator that cannot run is not a validator that passed ---"
# The whole point of validate.sh's exit 2. A check that could not be made must park
# the ticket, because a validator answering 0 when it validated nothing reads exactly
# like one that validated everything.
fix_schema compare "$SCHEMA_OBJ"
fix_ai compare '{"differences":[]}' superpowers:requesting-code-review
printf '#!/bin/sh\necho "briefs/validate.sh: ajv is not reachable" >&2\nexit 2\n' > "$FIX/validate-broken.sh"
chmod +x "$FIX/validate-broken.sh"
out=$(DRIVER_VALIDATE="$FIX/validate-broken.sh" driver_ai_step 101 compare 2>&1); rc=$?
want "an unrunnable check refuses rather than passing" "22" "$rc"
want_in "and says so"  'could not be read' "$out"
driver_state_set 101 park_note ""
# And the very same answer passes once the real validator is back, so the case above
# measured the refusal and not a broken fixture.
rc=0; driver_ai_step 101 compare >/dev/null 2>&1 || rc=$?
want "the same answer passes with the real one" "0" "$rc"

echo "--- a contract that cannot be REACHED is not a contract that is absent ---"
# `-f` alone answered "no schema, which is normal" to three states that are not
# that, and each returned 0 with nothing said — this call's own thesis left standing
# somewhere else. The first is the one that bites: DRIVER_SCHEMAS one directory off
# disables the check for all seven steps at once.
fix_schema compare "$SCHEMA_OBJ"
fix_ai compare '{"differences":"none","mood":"smug"}' superpowers:requesting-code-review
out=$(DRIVER_SCHEMAS="$FIX/briefs/typo-schemas" driver_ai_step 101 compare 2>&1); rc=$?
want "a schemas directory that is not there refuses" "22" "$rc"
want_in "and says nothing was checked" 'NOTHING about this answer was checked' "$out"
driver_state_set 101 park_note ""

mkdir -p "$DRIVER_SCHEMAS/isadir.json"
fix_brief isadir superpowers:requesting-code-review
fix_ai isadir '{"anything":"at all"}' superpowers:requesting-code-review
out=$(driver_ai_step 101 isadir 2>&1); rc=$?
want "a schema path that is a directory refuses" "22" "$rc"
want_in "and says nothing was checked"  'NOTHING about this answer was checked' "$out"
rmdir "$DRIVER_SCHEMAS/isadir.json"; driver_state_set 101 park_note ""

ln -s "$DRIVER_SCHEMAS/gone.json" "$DRIVER_SCHEMAS/dangling.json"
fix_brief dangling superpowers:requesting-code-review
fix_ai dangling '{"anything":"at all"}' superpowers:requesting-code-review
rc=0; driver_ai_step 101 dangling >/dev/null 2>&1 || rc=$?
want "a dangling symlink refuses too" "22" "$rc"
rm -f "$DRIVER_SCHEMAS/dangling.json"; driver_state_set 101 park_note ""

echo "--- DRIVER_VALIDATE unset is not a pass either ---"
# ai-step.sh skips sourcing driver-env.sh when DRIVER_DIR is already exported, so a
# shell carrying an older driver-env's exports has DRIVER_DIR and not DRIVER_VALIDATE.
# Unguarded, `bash "$DRIVER_VALIDATE"` died under `set -u` with status 1 — the "your
# answer is wrong" branch, about an answer that was perfectly valid.
fix_schema compare "$SCHEMA_OBJ"
fix_ai compare '{"differences":[]}' superpowers:requesting-code-review
rc=0; ( unset DRIVER_VALIDATE; driver_ai_step 101 compare >/dev/null 2>&1 ) || rc=$?
want "it falls back to the kit's validator rather than misreporting" "0" "$rc"
fix_ai compare '{"differences":"none"}' superpowers:requesting-code-review
rc=0; ( unset DRIVER_VALIDATE; driver_ai_step 101 compare >/dev/null 2>&1 ) || rc=$?
want "and still refuses a wrong answer"                              "22" "$rc"
driver_state_set 101 park_note ""

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

echo "--- a run's brief is put in front of every step, verbatim ---"
# An owner's answer or a resume note reaches a build that has no PR this way; a
# step that never saw it would build as if the owner had not answered.
driver_state_init 271
printf 'The owner answered q3: no export button.\n' > "$FIX/run-brief-271.md"
driver_state_set 271 run_brief "$FIX/run-brief-271.md"
fix_brief plan superpowers:writing-plans
fix_ai plan '{"files":["a.sh"],"tests":["a.test.sh"]}' superpowers:writing-plans
DRIVER_TICKET=271 driver_ai_step 271 plan >/dev/null 2>&1
want_in "the step's prompt carries the brief" 'The owner answered q3: no export button.' "$(cat "$FIX/claude-stdin-plan.txt")"
driver_state_init 272
DRIVER_TICKET=272 driver_ai_step 272 plan >/dev/null 2>&1
want_not_in "a run with no brief carries none"  'owner answered q3' "$(cat "$FIX/claude-stdin-plan.txt")"

echo "--- in repair mode a caller's brief reaches every step, not only repair ---"
driver_state_init 273; driver_state_set 273 mode repair; driver_state_set 273 repair_brief_source caller
printf 'The owner answered q5: rename it Archive.\n' > "$FIX/repair-brief-273.md"; driver_state_set 273 repair_brief "$FIX/repair-brief-273.md"
fix_brief review superpowers:requesting-code-review
fix_ai review '{"verdict":"SHIP","findings":[]}' superpowers:requesting-code-review
DRIVER_TICKET=273 driver_ai_step 273 review >/dev/null 2>&1
want_in "the reviewer sees the brief it must judge" 'The owner answered q5: rename it Archive.' "$(cat "$FIX/claude-stdin-review.txt")"
want_in "under the preface"                 'void' "$(cat "$FIX/claude-stdin-review.txt")"
driver_state_set 273 repair_brief_source class
DRIVER_TICKET=273 driver_ai_step 273 review >/dev/null 2>&1
want_not_in "a note-less healing run's class line is not passed around" 'q5' "$(cat "$FIX/claude-stdin-review.txt")"
driver_state_init 274; driver_state_set 274 mode repair
printf 'old build brief\n' > "$FIX/run-brief-274.md"; driver_state_set 274 run_brief "$FIX/run-brief-274.md"
DRIVER_TICKET=274 driver_ai_step 274 review >/dev/null 2>&1
want_not_in "a build's brief is not read in repair mode" 'old build brief' "$(cat "$FIX/claude-stdin-review.txt")"

exit $FAILED
