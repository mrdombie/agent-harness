#!/usr/bin/env bash
# fix-pm-answer.test.sh — a fix round reads the ticket's "## PM answer" comments: a
# finding one names and accepts a non-test proof for is proved that way, checked by
# the driver, and the proof record cites the answer. Without the answer, or with an
# answer the proof does not match, it is refused as before.
#
# Measured on the origin project, 20 Oct: three tickets (a test-only fix, a type-only
# field, a plan-text correction) each carried a PM answer accepting a mutation proof
# or the fixing commit, and the fixer deferred all three to the owner — nothing in
# the fix round read the ticket's comments.
#
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
fix_real_briefs
. "$HERE/../ai-step.sh" || exit 1
. "$HERE/../steps/fix.sh" || exit 1

c() { git -C "$1" -c user.email=t@e.invalid -c user.name=T commit -qm "$2"; git -C "$1" rev-parse HEAD; }
URL_M="https://github.com/acme/widgets/issues/601#issuecomment-1"
URL_C="https://github.com/acme/widgets/issues/601#issuecomment-2"

# issue_comments <n> <json-array-of-comments>
issue_comments() {
  jq -n --argjson n "$1" --argjson cs "$2" '{number:$n, state:"OPEN", title:"Ticket \($n)",
    labels:[{name:"status:claimed"}], body:"spec", comments:$cs}' > "$FIX/gh/issue-$1.json"
}
queue_then() { # <json> — what the NEXT fix call answers
  jq -nc '{type:"assistant", message:{content:[{type:"tool_use", name:"Skill", input:{skill:"superpowers:receiving-code-review"}}]}}' > "$FIX/ai/fix.then.jsonl"
  jq -nc --arg r "$1" '{type:"result", subtype:"success", is_error:false, result:$r, structured_output:($r|fromjson)}' >> "$FIX/ai/fix.then.jsonl"
}
proofs() { jq -c . "$(driver_state_dir 601)/steps/fix.proofs.json" 2>/dev/null; }
reset() { : > "$CLAUDE_LOG"; driver_state_set 601 park_note ""; driver_state_set 601 fix_proof_note ""; rm -f "$(driver_state_dir 601)/steps/fix.proofs.json"; }

WT="$FIX/wt601"
git -C "$REPO" worktree add -q "$WT" -b "tkt-601/work" develop
driver_state_init 601 --worktree "$WT" --branch "tkt-601/work"

# The fixed code, a test that pins it, and a plan whose text is corrected.
printf 'total=54\n' > "$WT/price.txt"
printf '#!/usr/bin/env bash\ngrep -q "total=54" price.txt || { echo " FAIL  price > total"; exit 1; }\n' > "$WT/price.test.sh"
printf 'the plan says 55\n' > "$WT/plan.md"
git -C "$WT" add price.txt price.test.sh plan.md; FIXED=$(c "$WT" "fix: the test pins the total")
printf 'unrelated\n' > "$WT/other.md"; git -C "$WT" add other.md; ELSEWHERE=$(c "$WT" "docs: something else")
printf 'the plan says 54\n' > "$WT/plan.md"; git -C "$WT" add plan.md; DOCFIX=$(c "$WT" "docs: the plan says 54")

# review_of <id…> — the review graded only these findings, so a case refuses on its own.
review_of() {
  jq -nc --args '{step:"review", skills:[], status:"reviewed", round:1, verdict:"BLOCKED", findings:[
    {id:"R2", file:"price.test.sh", line:2, grade:"major", summary:"the test pinned the wrong total", reason:"it passed on a wrong total", fix:"pin 54"},
    {id:"R3", file:"plan.md", line:1, grade:"minor", summary:"the plan says 55", reason:"it misleads", fix:"say 54"}]
    | map(select(.id as $i | $ARGS.positional | index($i)))}' "$@" > "$(driver_state_dir 601)/steps/review.json"
}

PM_M="## PM answer (2026-10-20)

**Accept the fix.** R2 was a finding about the test itself, so the mutation proof counts as the evidence for a test-only finding."
pm_c() { printf '## PM answer (2026-10-20)\n\nR3 was a correction to the plan text. A doc-only finding is cleared by the commit that fixes it (`%s`).' "$1"; }

mutation() { jq -nc --arg c "$FIXED" --arg r "$1" '{blockerId:"R2", pmAnswer:$r, kind:"mutation", commit:$c,
  testFile:"price.test.sh", command:"bash price.test.sh", break:{file:"price.txt", find:"total=54", replace:"total=55"}}'; }
bycommit() { jq -nc --arg c "$1" --arg r "$2" '{blockerId:"R3", pmAnswer:$r, kind:"commit", commit:$c}'; }
answer() { # <pmProofs-json-array>
  jq -nc --argjson p "$1" '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1, pmProofs:$p}'
}
# deferred — the shape the fixer sent on the origin ticket: one finding cleared, and the
# test-only one deferred as "no red/green pair to show".
deferred() {
  jq -nc --argjson p "[$(bycommit "$DOCFIX" "$URL_C")]" '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1,
    pmProofs:$p, deferred:[{blockerId:"R2", reason:"no red/green pair to show: the finding is about the test itself", followUp:"the owner"}]}'
}

echo "--- with PM answers on the ticket: both findings pass, and the record cites each answer ---"
issue_comments 601 "$(jq -nc --arg m "$PM_M" --arg cb "$(pm_c "$(printf '%s' "$DOCFIX" | cut -c1-10)")" --arg um "$URL_M" --arg uc "$URL_C" \
  '[{body:"an unrelated comment", url:"x"}, {body:$m, url:$um, createdAt:"2026-10-20T16:31:47Z"}, {body:$cb, url:$uc}]')"
reset; review_of R2 R3
fix_ai fix "$(answer "[$(mutation "$URL_M"),$(bycommit "$DOCFIX" "$URL_C")]")" superpowers:receiving-code-review
rc=0; out=$(driver_step_fix 601 2>&1) || rc=$?
want "the round passes" "0" "$rc"
want_in "the mutation was run red then green" 'red .*with price.txt broken, then green' "$out"
want "the record cites the PM answer for the mutation proof" "$URL_M" "$(proofs | jq -r '.[] | select(.blockerId=="R2" and .proof=="mutation") | .pmAnswer')"
want "the record cites the PM answer for the commit proof" "$URL_C" "$(proofs | jq -r '.[] | select(.blockerId=="R3" and .proof=="commit") | .pmAnswer')"
want_in "the fixer was shown the PM answer" 'mutation proof counts as the evidence' "$(cat "$FIX/claude-stdin-fix.txt")"
want_in "with the ref to cite" "ref: $URL_M" "$(cat "$FIX/claude-stdin-fix.txt")"
want_not_in "and only PM answers" 'an unrelated comment' "$(cat "$FIX/claude-stdin-fix.txt")"

echo "--- a mutation the named test does not catch is refused, PM answer or not ---"
reset; review_of R2
fix_ai fix "$(answer "[$(mutation "$URL_M" | jq -c '.break.find="nothing-here"')]")" superpowers:receiving-code-review
queue_then "$(answer "[$(mutation "$URL_M" | jq -c '.break.find="nothing-here"')]")"
rc=0; out=$(driver_step_fix 601 2>&1) || rc=$?
want "a break that breaks nothing is refused" "24" "$rc"
want_in "and says nothing was broken" 'nothing was broken' "$out"

echo "--- a PM answer naming a commit that does not touch the finding's file is refused ---"
issue_comments 601 "$(jq -nc --arg cb "$(pm_c "$(printf '%s' "$ELSEWHERE" | cut -c1-10)")" --arg uc "$URL_C" '[{body:$cb, url:$uc}]')"
reset; review_of R3
fix_ai fix "$(answer "[$(bycommit "$ELSEWHERE" "$URL_C")]")" superpowers:receiving-code-review
queue_then "$(answer "[$(bycommit "$ELSEWHERE" "$URL_C")]")"
rc=0; out=$(driver_step_fix 601 2>&1) || rc=$?
want "refused" "24" "$rc"
want_in "because the commit does not touch the file" 'does not touch plan.md' "$out"
want "and nothing is recorded as proved" "" "$(proofs | jq -r '.[]? | select(.blockerId=="R3") | .pmAnswer')"

echo "--- a commit the PM answer does not name is refused ---"
reset; review_of R3
fix_ai fix "$(answer "[$(bycommit "$DOCFIX" "$URL_C")]")" superpowers:receiving-code-review
queue_then "$(answer "[$(bycommit "$DOCFIX" "$URL_C")]")"
rc=0; out=$(driver_step_fix 601 2>&1) || rc=$?
want "refused" "24" "$rc"
want_in "the answer names another commit" 'names no commit that is' "$out"

echo "--- the same findings with NO PM answer on the ticket: still refused ---"
issue_comments 601 '[{"body":"an unrelated comment","url":"x"}]'
reset; review_of R2 R3
fix_ai fix "$(answer "[$(mutation "$URL_M"),$(bycommit "$DOCFIX" "$URL_C")]")" superpowers:receiving-code-review
queue_then "$(answer "[$(mutation "$URL_M"),$(bycommit "$DOCFIX" "$URL_C")]")"
rc=0; out=$(driver_step_fix 601 2>&1) || rc=$?
want "refused without the answer" "24" "$rc"
want_in "the mutation proof cites an answer that is not there" 'R2: .*not a ## PM answer comment on the ticket' "$(driver_state_get 601 park_note)"
want "and nothing is recorded as proved" "0" "$(proofs | jq 'length')"
want_in "the fixer was told there is no PM answer" 'carries no comment headed "## PM answer"' "$(cat "$FIX/claude-stdin-fix.txt")"

echo "--- a PM answer that names another finding allows nothing for this one ---"
issue_comments 601 "$(jq -nc --arg m "${PM_M//R2/R9}" --arg um "$URL_M" '[{body:$m, url:$um}]')"
reset; review_of R2
fix_ai fix "$(answer "[$(mutation "$URL_M")]")" superpowers:receiving-code-review
queue_then "$(answer "[$(mutation "$URL_M")]")"
rc=0; out=$(driver_step_fix 601 2>&1) || rc=$?
want "refused" "24" "$rc"
want_in "the answer does not name R2" 'does not name R2 and accept a mutation proof' "$out"

echo "--- a deferral the PM already answered is asked once more, told which answer ---"
issue_comments 601 "$(jq -nc --arg m "$PM_M" --arg cb "$(pm_c "$(printf '%s' "$DOCFIX" | cut -c1-10)")" --arg um "$URL_M" --arg uc "$URL_C" \
  '[{body:$m, url:$um}, {body:$cb, url:$uc}]')"
reset; review_of R2 R3
fix_ai fix "$(deferred)" superpowers:receiving-code-review
queue_then "$(answer "[$(mutation "$URL_M"),$(bycommit "$DOCFIX" "$URL_C")]")"
rc=0; out=$(driver_step_fix 601 2>&1) || rc=$?
want "the retry clears both" "0" "$rc"
want "the fix step ran exactly twice" "2" "$(grep -cx fix "$CLAUDE_LOG")"
want_in "the retry is told which answer covers R2" "R2: deferred, but PM answer $URL_M" "$(cat "$FIX/claude-stdin-fix.txt")"
want "and the record cites it" "$URL_M" "$(proofs | jq -r '.[] | select(.blockerId=="R2") | .pmAnswer')"

echo "--- a deferral no PM answer covers still parks for a person, with no retry ---"
issue_comments 601 "$(jq -nc --arg cb "$(pm_c "$(printf '%s' "$DOCFIX" | cut -c1-10)")" --arg uc "$URL_C" '[{body:$cb, url:$uc}]')"
reset; review_of R2 R3
fix_ai fix "$(deferred)" superpowers:receiving-code-review
rc=0; out=$(driver_step_fix 601 2>&1) || rc=$?
want "refused" "24" "$rc"
want "asked once only" "1" "$(grep -cx fix "$CLAUDE_LOG")"
want "parked for a person" "person" "$(driver_state_get 601 park_cause)"

git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
exit $FAILED
