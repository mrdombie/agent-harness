#!/usr/bin/env bash
# fix-body-proof.test.sh — a finding cleared by editing the PR description is proved
# by the driver: it fetches the description from GitHub, runs the check the fixer
# names on it, and requires a pass on the description now and a fail on the one the
# review judged. The fixer's own run is never the evidence.
#
# Measured on the origin project, 21 Oct: the fix round parked a ticket with "left R1
# unanswered" after the fixer cleared R1 ("the Approved picture check stays red") by
# adding the picture line to the PR description; the answer had nowhere to put it.
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

# GitHub as the driver reads it: the description now (pr view) and its edit history
# (api graphql). Everything else goes to the fixture's stub.
cat > "$FIX/gh-body" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr view")     printf '%s\n' "\$*" >> "$GH_LOG"; [ -f "$FIX/gh/pr-body.json" ] || exit 1; cat "$FIX/gh/pr-body.json"; exit 0 ;;
  "api graphql") case "\$*" in *userContentEdits*) printf '%s\n' "\$*" >> "$GH_LOG"; [ -f "$FIX/gh/pr-edits.json" ] || exit 1; cat "$FIX/gh/pr-edits.json"; exit 0 ;; esac ;;
esac
exec "$BIN/gh" "\$@"
SH
chmod +x "$FIX/gh-body"; export SWARM_GH="$FIX/gh-body"

queue_then() { # <json> — what the NEXT fix call answers
  jq -nc '{type:"assistant", message:{content:[{type:"tool_use", name:"Skill", input:{skill:"superpowers:receiving-code-review"}}]}}' > "$FIX/ai/fix.then.jsonl"
  jq -nc --arg r "$1" '{type:"result", subtype:"success", is_error:false, result:$r, structured_output:($r|fromjson)}' >> "$FIX/ai/fix.then.jsonl"
}
proofs() { jq -c . "$(driver_state_dir 701)/steps/fix.proofs.json" 2>/dev/null; }
reset() { : > "$CLAUDE_LOG"; : > "$GH_LOG"; driver_state_set 701 park_note ""; driver_state_set 701 fix_proof_note ""; rm -f "$(driver_state_dir 701)/steps/fix.proofs.json"; }

WT="$FIX/wt701"
git -C "$REPO" worktree add -q "$WT" -b "tkt-701/work" develop
driver_state_init 701 --worktree "$WT" --branch "tkt-701/work"
driver_state_set 701 pr 42

# The repo's own check: a screen change owes a "Picture:" line naming a mock. It reads
# the description from BODY_FILE and the changed paths from stdin, as CI feeds it.
mkdir -p "$WT/scripts" "$WT/app"
cat > "$WT/scripts/check-picture.sh" <<'SH'
#!/bin/sh
changed=$(cat)
printf '%s\n' "$changed" | grep -q '^app/' || { echo "not owed"; exit 0; }
grep -qE '^Picture: `\.design/[a-z-]+-mock\.html`' "${BODY_FILE:-/nonexistent}" && { echo "present"; exit 0; }
echo "owed and missing" >&2; exit 1
SH
printf 'export const Screen = 1\n' > "$WT/app/screen.tsx"
git -C "$WT" add scripts app; c "$WT" "feat: the screen" >/dev/null

review_r1() {
  jq -nc '{step:"review", skills:[], status:"reviewed", round:1, verdict:"BLOCKED", findings:[
    {id:"R1", file:"PR #42 body", line:0, grade:"major", summary:"The Approved picture required check stays red",
     reason:"the PR cannot merge", fix:"name the approved mock in the PR body"}]}' > "$(driver_state_dir 701)/steps/review.json"
}
OLD_BODY='## Summary
Renders this run compared against the approved design:'
NEW_BODY="$OLD_BODY
Picture: \`.design/watch-mock.html\` — the approved mock"
# bodies <now> <as-the-review-judged-it> — the description GitHub holds now, and its
# edit history: the version the review saw an hour before it, the fixer's edit after.
bodies() {
  jq -nc --arg b "$1" '{body:$b, labels:[{name:"needs:human-approval"}]}' > "$FIX/gh/pr-body.json"
  jq -nc --arg now "$1" --arg was "$2" '{data:{repository:{pullRequest:{userContentEdits:{nodes:[
    {editedAt:((now + 3600) | todate), diff:$now},
    {editedAt:((now - 3600) | todate), diff:$was},
    {editedAt:((now - 7200) | todate), diff:"## Summary"}]}}}}}' > "$FIX/gh/pr-edits.json"
}
answer() { # [command]
  jq -nc --arg cmd "${1:-sh scripts/check-picture.sh}" '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1,
    bodyProofs:[{blockerId:"R1", command:$cmd}],
    notes:"R1 was cleared by a PR description edit, not a commit; the check exits 0 locally"}'
}

echo "--- R1 cleared by a description edit: passes now, failed on the body the review judged → accepted ---"
reset; review_r1; bodies "$NEW_BODY" "$OLD_BODY"
fix_ai fix "$(answer)" superpowers:receiving-code-review
rc=0; out=$(driver_step_fix 701 2>&1) || rc=$?
want "the round passes" "0" "$rc"
want "the record names the proof pr-body" "pr-body" "$(proofs | jq -r '.[] | select(.blockerId=="R1") | .proof')"
want_in "it says red on the old body, green on the new" 'fails on the description the review judged.*passes on the description now' "$out"
want_in "the driver read the description from GitHub itself" 'pr view 42 --repo acme/widgets --json body,labels' "$(cat "$GH_LOG")"
want_in "and its edit history" 'userContentEdits' "$(cat "$GH_LOG")"
want_in "the fixer was told about bodyProofs" 'bodyProofs' "$(cat "$FIX/claude-stdin-fix.txt")"

echo "--- the check still fails on the description now → refused, whatever the fixer says ---"
reset; review_r1; bodies "$OLD_BODY" "$OLD_BODY"
fix_ai fix "$(answer)" superpowers:receiving-code-review
queue_then "$(answer)"
rc=0; out=$(driver_step_fix 701 2>&1) || rc=$?
want "refused" "24" "$rc"
want_in "because the check fails on the description now" 'R1: .*fails on the description now' "$(driver_state_get 701 park_note)"
want "and nothing is recorded as proved" "" "$(proofs | jq -r '.[]? | select(.blockerId=="R1") | .proof')"

echo "--- the check already passed on the body the review judged → nothing proved, refused ---"
reset; review_r1; bodies "$NEW_BODY" "$NEW_BODY"
fix_ai fix "$(answer)" superpowers:receiving-code-review
queue_then "$(answer)"
rc=0; out=$(driver_step_fix 701 2>&1) || rc=$?
want "refused" "24" "$rc"
want_in "because it already passed before the edit" 'R1: .*already passes on the description the review judged' "$(driver_state_get 701 park_note)"

echo "--- a check that ignores the description proves nothing (it passes on both) ---"
reset; review_r1; bodies "$NEW_BODY" "$OLD_BODY"
fix_ai fix "$(answer true)" superpowers:receiving-code-review
queue_then "$(answer true)"
rc=0; out=$(driver_step_fix 701 2>&1) || rc=$?
want "refused" "24" "$rc"

echo "--- the edit history cannot be read → refused, never taken on the fixer's word ---"
reset; review_r1; bodies "$NEW_BODY" "$OLD_BODY"; rm -f "$FIX/gh/pr-edits.json"
fix_ai fix "$(answer)" superpowers:receiving-code-review
queue_then "$(answer)"
rc=0; out=$(driver_step_fix 701 2>&1) || rc=$?
want "refused" "24" "$rc"
want_in "and says why" 'R1: .*could not be read' "$(driver_state_get 701 park_note)"

echo "--- no PR on the run → refused ---"
reset; review_r1; bodies "$NEW_BODY" "$OLD_BODY"; driver_state_set 701 pr ""
fix_ai fix "$(answer)" superpowers:receiving-code-review
queue_then "$(answer)"
rc=0; out=$(driver_step_fix 701 2>&1) || rc=$?
want "refused" "24" "$rc"
driver_state_set 701 pr 42

echo "--- the origin shape: the edit named only in notes is still unanswered ---"
reset; review_r1; bodies "$NEW_BODY" "$OLD_BODY"
fix_ai fix "$(answer | jq -c 'del(.bodyProofs) | .cleared = [{blockerId:"R9", change:[{path:"x", action:"modify"}], test:{file:"x", behaviour:"x", redWhen:"x"}, command:"true", testCommit:"aaaaaaa", implCommit:"bbbbbbb", failedBefore:true, passedAfter:true}]')" superpowers:receiving-code-review
rc=0; out=$(driver_step_fix 701 2>&1) || rc=$?
want "refused" "24" "$rc"
want_in "as unanswered" 'left R1 unanswered' "$(driver_state_get 701 park_note)"

git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
exit $FAILED
