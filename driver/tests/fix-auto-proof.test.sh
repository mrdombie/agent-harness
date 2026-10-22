#!/usr/bin/env bash
# fix-auto-proof.test.sh — a finding no red/green pair can show, fixed by a commit that
# is only docs, only comments, only wording or only tests, is accepted on a check the
# driver runs itself — the commit's diff read for the class, and for test-only a
# mutation planted in non-test code, red then green — with no PM answer and no park.
# A claim the diff does not bear out is refused, as is a code finding with no test.
#
# Measured on the origin project, 22 Oct: about 10 of the day's ~40 builder questions
# were "this finding is comment/wording/test-only, so no red-then-green pair exists —
# will you accept the commit / a mutation proof?", and the PM's answer was the same
# every time. Each one stopped a run.
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

c() { git -C "$1" -c user.email=t@e.invalid -c user.name=T commit -qm "$2"; git -C "$1" rev-parse HEAD; }
T=602
issue() { jq -n --argjson n "$T" '{number:$n, state:"OPEN", title:"Ticket", labels:[{name:"status:claimed"}], body:"spec", comments:[]}' > "$FIX/gh/issue-$T.json"; }
issue
queue_then() { # <json> — what the NEXT fix call answers
  jq -nc '{type:"assistant", message:{content:[{type:"tool_use", name:"Skill", input:{skill:"superpowers:receiving-code-review"}}]}}' > "$FIX/ai/fix.then.jsonl"
  jq -nc --arg r "$1" '{type:"result", subtype:"success", is_error:false, result:$r, structured_output:($r|fromjson)}' >> "$FIX/ai/fix.then.jsonl"
}
proofs() { jq -c . "$(driver_state_dir $T)/steps/fix.proofs.json" 2>/dev/null; }
reset() { : > "$CLAUDE_LOG"; rm -f "$FIX/ai/fix.then.jsonl"; driver_state_set $T park_note ""; driver_state_set $T park_cause ""; driver_state_set $T fix_proof_note ""; rm -f "$(driver_state_dir $T)/steps/fix.proofs.json"; }

WT="$FIX/wt$T"
git -C "$REPO" worktree add -q "$WT" -b "tkt-$T/work" develop
driver_state_init $T --worktree "$WT" --branch "tkt-$T/work"
mkdir -p "$WT/src"

# The change as built: code a test pins, a helper, a screen and a plan.
printf 'export const total = 54; // the total a person pays\n' > "$WT/src/price.js"
printf '#!/usr/bin/env bash\ngrep -q "total = 5" src/price.js || { echo " FAIL  price > total"; exit 1; }\n' > "$WT/price.test.sh"
printf '// rounds a price\nexport function round(x) {\n  return Math.round(x);\n}\n' > "$WT/src/util.js"
printf 'export const Saved = () => <p className="note">Saved your draft</p>;\n' > "$WT/src/saved.tsx"
printf 'the plan says 55\n' > "$WT/plan.md"
git -C "$WT" add -A; c "$WT" "feat: the change" >/dev/null
# The fixing commits, one kind each.
printf '// rounds a price to the nearest whole pound\n/* never down to zero */\nexport function round(x) {\n  return Math.round(x); // half up\n}\n' > "$WT/src/util.js"
git -C "$WT" add -A; COMMENT=$(c "$WT" "docs: say what round does")
printf '// rounds a price, and now floors it\nexport function round(x) {\n  return Math.floor(x);\n}\n' > "$WT/src/util.js"
git -C "$WT" add -A; CODEY=$(c "$WT" "comment: says comment, changes code")
printf '#!/usr/bin/env bash\ngrep -q "total = 54" src/price.js || { echo " FAIL  price > total"; exit 1; }\n' > "$WT/price.test.sh"
git -C "$WT" add -A; TESTFIX=$(c "$WT" "test: pin the exact total")
printf 'the plan says 54\n' > "$WT/plan.md"
git -C "$WT" add -A; DOCFIX=$(c "$WT" "docs: the plan says 54")
printf 'export const Saved = () => <p className="note">Draft saved — you can come back to it</p>;\n' > "$WT/src/saved.tsx"
git -C "$WT" add -A; WORDFIX=$(c "$WT" "copy: plainer saved note")
printf 'export const Saved = () => <p className="alert">Draft kept</p>;\n' > "$WT/src/saved.tsx"
git -C "$WT" add -A; WORDCODE=$(c "$WT" "copy: says wording, changes a class")

review_of() { # <id…> — the review graded only these findings
  jq -nc --args '{step:"review", skills:[], status:"reviewed", round:1, verdict:"BLOCKED", findings:[
    {id:"R1", file:"src/util.js", line:1, grade:"minor", summary:"the comment does not say what round does", reason:"misleads", fix:"say it"},
    {id:"R2", file:"price.test.sh", line:2, grade:"major", summary:"the test passes on a wrong total", reason:"it greps a prefix", fix:"pin 54"},
    {id:"R3", file:"plan.md", line:1, grade:"minor", summary:"the plan says 55", reason:"it misleads", fix:"say 54"},
    {id:"R4", file:"src/saved.tsx", line:1, grade:"minor", summary:"the saved note is jargon", reason:"unclear", fix:"plainer words"},
    {id:"R5", file:"src/util.js", line:3, grade:"major", summary:"round goes the wrong way", reason:"overcharges", fix:"floor it"}]
    | map(select(.id as $i | $ARGS.positional | index($i)))}' "$@" > "$(driver_state_dir $T)/steps/review.json"
}
auto() { # <blocker> <kind> <commit> [extra-json]
  local x="${4:-}"; [ -n "$x" ] || x='{}'
  jq -nc --arg b "$1" --arg k "$2" --arg c "$3" --argjson x "$x" '{blockerId:$b, kind:$k, commit:$c} + $x'
}
MUT='{"testFile":"price.test.sh","command":"bash price.test.sh","break":{"file":"src/price.js","find":"total = 54","replace":"total = 55"}}'
answer() { jq -nc --argjson p "$1" '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1, autoProofs:$p}'; }
run() { rc=0; out=$(driver_step_fix $T 2>&1) || rc=$?; }

echo "--- a comment-only fix whose diff is only comments: accepted, no park ---"
reset; review_of R1
fix_ai fix "$(answer "[$(auto R1 comment-only "$COMMENT")]")" superpowers:receiving-code-review
run
want "the round passes" "0" "$rc"
want "nothing parked" "" "$(driver_state_get $T park_note)"
want "the record is a commit proof of kind comment-only" "commit comment-only" "$(proofs | jq -r '.[] | select(.blockerId=="R1") | "\(.proof) \(.kind)"')"
want "and cites no PM answer" "null" "$(proofs | jq -r '.[] | select(.blockerId=="R1") | .pmAnswer')"
want "the fixer was asked once" "1" "$(grep -cx fix "$CLAUDE_LOG")"

echo "--- a comment-only claim whose diff changes code: refused, with the line named ---"
reset; review_of R1
fix_ai fix "$(answer "[$(auto R1 comment-only "$CODEY")]")" superpowers:receiving-code-review
queue_then "$(answer "[$(auto R1 comment-only "$CODEY")]")"
run
want "refused" "24" "$rc"
want_in "the park names the code that changed" 'R1: the comment-only proof is not accepted: .*changes code in src/util.js outside comments.*Math.round' "$(driver_state_get $T park_note)"
want "nothing recorded as proved" "0" "$(proofs | jq 'length')"

echo "--- the same claim on a code finding with no red-then-green pair: refused ---"
reset; review_of R5
fix_ai fix "$(answer "[$(auto R5 wording-only "$CODEY")]")" superpowers:receiving-code-review
queue_then "$(answer "[$(auto R5 wording-only "$CODEY")]")"
run
want "a code fix passed off as wording is refused" "24" "$rc"
reset; review_of R5
fix_ai fix "$(jq -nc '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1, cleared:[{blockerId:"R5", change:[{path:"src/util.js", action:"modify"}],
  test:{file:"price.test.sh", behaviour:"b", redWhen:"r"}, command:"bash price.test.sh", failedBefore:true, passedAfter:true, testCommit:"'"$CODEY"'", implCommit:"'"$CODEY"'"}]}')" superpowers:receiving-code-review
queue_then "$(cat "$FIX/ai/fix.jsonl" | tail -1 | jq -r .result)"
run
want "a code fix with no red-then-green pair still refuses" "24" "$rc"
want_in "as not proved red-then-green" 'not proved red-then-green' "$(driver_state_get $T park_note)"

echo "--- a test-only fix with a mutation that turns its test red: accepted ---"
reset; review_of R2
fix_ai fix "$(answer "[$(auto R2 test-only "$TESTFIX" "$MUT")]")" superpowers:receiving-code-review
run
want "the round passes" "0" "$rc"
want_in "the mutation ran red then green" 'red .*with src/price.js broken, then green' "$out"
want "the record is a mutation proof" "mutation test-only" "$(proofs | jq -r '.[] | select(.blockerId=="R2") | "\(.proof) \(.kind)"')"

echo "--- a mutation that does not turn the test red: parks with the output ---"
reset; review_of R2
NOMUT=$(jq -c '.break.find="the total"|.break.replace="a total"' <<<"$MUT")
fix_ai fix "$(answer "[$(auto R2 test-only "$TESTFIX" "$NOMUT")]")" superpowers:receiving-code-review
queue_then "$(answer "[$(auto R2 test-only "$TESTFIX" "$NOMUT")]")"
run
want "parked" "24" "$rc"
want_in "saying the test still passes with the code broken" 'still passes with src/price.js broken' "$(driver_state_get $T park_note)"

echo "--- a mutation planted in a test file: refused ---"
reset; review_of R2
INTEST=$(jq -c '.break.file="price.test.sh"|.break.find="total = 54"' <<<"$MUT")
fix_ai fix "$(answer "[$(auto R2 test-only "$TESTFIX" "$INTEST")]")" superpowers:receiving-code-review
queue_then "$(answer "[$(auto R2 test-only "$TESTFIX" "$INTEST")]")"
run
want "refused" "24" "$rc"
want_in "because the break is in a test" 'planted in price.test.sh, a test file' "$(driver_state_get $T park_note)"

echo "--- test-only on a commit that changes code: refused ---"
reset; review_of R1
fix_ai fix "$(answer "[$(auto R1 test-only "$CODEY" "$MUT")]")" superpowers:receiving-code-review
queue_then "$(answer "[$(auto R1 test-only "$CODEY" "$MUT")]")"
run
want "refused" "24" "$rc"
want_in "src/util.js is not a test file" 'touches src/util.js, which is not a test file' "$(driver_state_get $T park_note)"

echo "--- docs-only and wording-only fixes: accepted; wording that changes a class is not ---"
reset; review_of R3 R4
fix_ai fix "$(answer "[$(auto R3 docs-only "$DOCFIX"),$(auto R4 wording-only "$WORDFIX")]")" superpowers:receiving-code-review
run
want "both pass" "0" "$rc"
want "two commit proofs" "2" "$(proofs | jq '[.[] | select(.proof=="commit")] | length')"
reset; review_of R4
fix_ai fix "$(answer "[$(auto R4 wording-only "$WORDCODE")]")" superpowers:receiving-code-review
queue_then "$(answer "[$(auto R4 wording-only "$WORDCODE")]")"
run
want "wording that also changes className is refused" "24" "$rc"
want_in "naming the line" 'changes code in src/saved.tsx outside comments and prose literals' "$(driver_state_get $T park_note)"
reset; review_of R3
fix_ai fix "$(answer "[$(auto R3 docs-only "$COMMENT")]")" superpowers:receiving-code-review
queue_then "$(answer "[$(auto R3 docs-only "$COMMENT")]")"
run
want "a docs-only claim on a code commit is refused" "24" "$rc"

echo "--- the fixer asks for the PM: asked once more, pointed at autoProofs, and accepted ---"
reset; review_of R2
fix_ai fix "$(jq -nc '{step:"fix", skills:["superpowers:receiving-code-review"], status:"park", round:1, questionFor:"pm",
  question:"R2 only touches a test, so no red-then-green pair is possible. Will you accept a mutation proof for R2?"}')" superpowers:receiving-code-review
queue_then "$(answer "[$(auto R2 test-only "$TESTFIX" "$MUT")]")"
run
want "the retry clears it" "0" "$rc"
want "the fix step ran twice" "2" "$(grep -cx fix "$CLAUDE_LOG")"
want_in "the retry was told to use autoProofs" 'not a question for a person.*autoProofs' "$(cat "$FIX/claude-stdin-fix.txt")"

echo "--- a deferral saying wording-only: asked once more, and accepted ---"
# The shape the fixer sent on the origin ticket: one finding answered, the wording one
# deferred as "no red/green test can exist".
reset; review_of R3 R4
fix_ai fix "$(jq -nc --argjson p "[$(auto R3 docs-only "$DOCFIX")]" '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1, autoProofs:$p,
  deferred:[{blockerId:"R4", reason:"Fixed in a commit that is wording only, so no red/green test can exist.", followUp:"the owner"}]}')" superpowers:receiving-code-review
queue_then "$(answer "[$(auto R3 docs-only "$DOCFIX"),$(auto R4 wording-only "$WORDFIX")]")"
run
want "the retry clears it" "0" "$rc"
want "the fix step ran twice" "2" "$(grep -cx fix "$CLAUDE_LOG")"
want_in "told to answer it in autoProofs" "R4: deferred as having no red-then-green pair" "$(cat "$FIX/claude-stdin-fix.txt")"

echo "--- a question about something else is still a question ---"
reset; review_of R4
fix_ai fix "$(jq -nc '{step:"fix", skills:["superpowers:receiving-code-review"], status:"park", round:1, questionFor:"owner", question:"Should the note say draft or post?"}')" superpowers:receiving-code-review
run
want "parks as a question" "$DRIVER_E_QUESTION" "$rc"
want "asked once" "1" "$(grep -cx fix "$CLAUDE_LOG")"

echo "--- proof.autoAccept off: the same honest comment-only fix needs a PM answer ---"
# A copy of the project's settings with the one key changed; the driver reads HARNESS_CFG.
CFG_REAL="${HARNESS_CFG:-}"
with_auto() { jq --argjson v "$1" '.proof = {autoAccept: $v}' "$CFG_REAL" > "$FIX/cfg-auto.json"; HARNESS_CFG="$FIX/cfg-auto.json"; }
with_auto false
reset; review_of R1
fix_ai fix "$(answer "[$(auto R1 comment-only "$COMMENT")]")" superpowers:receiving-code-review
queue_then "$(answer "[$(auto R1 comment-only "$COMMENT")]")"
run
want "refused" "24" "$rc"
want_in "because the setting is off" 'proof.autoAccept is off for comment-only' "$(driver_state_get $T park_note)"
want_in "and the brief says so" 'proof.autoAccept is off here' "$(driver_fact_proof_limits)"
with_auto '{"kinds":["docs-only"]}'
want "a kinds list turns on only those" "docs-only" "$(driver_auto_proof_kinds)"
HARNESS_CFG="$CFG_REAL"
want "by default all four are on" "docs-only comment-only wording-only test-only" "$(driver_auto_proof_kinds)"
want_in "and the proof limits name them" 'only docs-only comment-only wording-only test-only needs no PM answer.*autoProofs.*break' "$(driver_fact_proof_limits)"

git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
suite_end "$FAILED"
