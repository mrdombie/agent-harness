#!/usr/bin/env bash
# fix-proof.test.sh — a fix whose proof fails is told WHY, asked once more, and
# still refused when the second answer is not proved either.
#
# Measured on maktura 18–20 Oct: 12 of 18 "still fails with the change" refusals in
# a fix round were a test file the fix had rewritten (sibling cases asserting the old
# behaviour), and the proof runs the TEST commit's version in both trees. The reason
# the proof printed was `head -5` of the output — for vitest, its config banner every
# time — so the one retry was handed nothing and re-sent the same commits (#13621).
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

# A test file with a sibling case that asserts the OLD behaviour, and a fix that
# changes the behaviour and rewrites that sibling in the change commit.
#   test commit:  case "new" (red before) + case "old" (asserts mode=old)
#   impl commit:  mode=new, and case "old" rewritten to assert mode=new
mk_rewritten() { # <repo>
  local r="$1"
  printf 'mode=old\n' > "$r/mode.txt"
  git -C "$r" add mode.txt; c "$r" "base: mode" >/dev/null
  cat > "$r/mode.test.sh" <<'SH'
#!/usr/bin/env bash
for i in 1 2 3 4 5 6; do echo "(!) a config banner line $i that says nothing"; done
grep -q 'mode=new' mode.txt || { echo " FAIL  mode.test > new: mode is new"; exit 1; }
grep -q 'mode=old' mode.txt || { echo " FAIL  mode.test > old: mode is old"; exit 1; }
echo ok
SH
  git -C "$r" add mode.test.sh; RW_TEST=$(c "$r" "test: mode is new")
  printf 'mode=new\n' > "$r/mode.txt"
  sed -i.bak "s/'mode=old' mode.txt || { echo \" FAIL  mode.test > old: mode is old\"/'mode=new' mode.txt || { echo \" FAIL  mode.test > old: mode is old\"/" "$r/mode.test.sh"
  rm -f "$r/mode.test.sh.bak"
  grep -c "mode=new" "$r/mode.test.sh" | grep -qx 2 || { echo "fixture: the sibling rewrite did not land"; exit 1; }
  git -C "$r" add mode.txt mode.test.sh; RW_IMPL=$(c "$r" "fix: mode is new, and the old case follows it")
}

echo "--- a proof that fails quotes the failing case, not the runner's banner ---"
mk_rewritten "$REPO"
out=$(driver_prove_red_green "$REPO" mode.test.sh "$RW_TEST" "$RW_IMPL" "bash mode.test.sh" 2>&1); rc=$?
want "a sibling the change rewrote still fails in the test commit's version" "2" "$rc"
want_in "the reason names the case that failed" 'FAIL  mode.test > old: mode is old' "$out"
want_not_in "and not the banner in its place" 'config banner line 1' "$out"
want_in "and says the change commit edits the test file" \
  'mode.test.sh changes between the test commit .* and the change commit' "$out"
want_in "with what to do about it" 'every edit to mode.test.sh in the test commit' "$out"

echo "--- a test file the change leaves alone is not blamed on a rewrite ---"
printf 'n\n' > "$REPO/plain.txt"; git -C "$REPO" add plain.txt; c "$REPO" "base: plain" >/dev/null
printf '#!/usr/bin/env bash\ngrep -q never plain.txt || { echo " FAIL  plain > never"; exit 1; }\n' > "$REPO/plain.test.sh"
git -C "$REPO" add plain.test.sh; P_TEST=$(c "$REPO" "test: plain")
printf 'still n\n' > "$REPO/plain.txt"; git -C "$REPO" add plain.txt; P_IMPL=$(c "$REPO" "fix: plain, not done")
out=$(driver_prove_red_green "$REPO" plain.test.sh "$P_TEST" "$P_IMPL" "bash plain.test.sh" 2>&1); rc=$?
want "a change that does not do the job still fails" "2" "$rc"
want_in "quoting the case" 'FAIL  plain > never' "$out"
want_not_in "and says nothing about a rewrite" 'changes between the test commit' "$out"

echo "--- the sibling proof, by a planted break, quotes the failing case too ---"
printf 'on\n' > "$REPO/brk.txt"
cat > "$REPO/brk.test.sh" <<'SH'
#!/usr/bin/env bash
for i in 1 2 3 4 5 6; do echo "(!) a config banner line $i that says nothing"; done
grep -q on brk.txt || { echo " FAIL  brk > is on"; exit 1; }
grep -q never brk.txt || { echo " FAIL  brk > also never"; exit 1; }
SH
git -C "$REPO" add brk.txt brk.test.sh; B_TS=$(c "$REPO" "test: brk")
out=$(driver_prove_by_break "$REPO" brk.test.sh "$B_TS" brk.txt on off "bash brk.test.sh" 2>&1); rc=$?
want "a test red with the code intact is refused" "2" "$rc"
want_in "quoting the case" 'FAIL  brk > also never' "$out"
want_not_in "not the banner" 'config banner line 1' "$out"

# ---- the fix round: one bounded retry, told which finding and why ------------
WT="$FIX/wt501"
git -C "$REPO" worktree add -q "$WT" -b "tkt-501/work" develop
driver_state_init 501 --worktree "$WT" --branch "tkt-501/work"
fix_issue 501 OPEN "status:claimed"
printf '%s\n' '{"step":"review","skills":[],"status":"reviewed","round":1,"verdict":"BLOCKED","findings":[{"id":"F7","file":"mode.txt","line":1,"grade":"major","summary":"the mode is still old","reason":"a person sees the old mode","fix":"make it new"}]}' \
  > "$(driver_state_dir 501)/steps/review.json"

# Round 1 names the rewritten layout. The honest layout the retry can name: the
# test file already in its final form (every case asserting the new mode) at a
# commit where the mode is old, then the change alone.
mk_rewritten "$WT"
BAD_TS=$RW_TEST; BAD_IS=$RW_IMPL
printf 'mode=old\n' > "$WT/mode.txt"; git -C "$WT" add mode.txt
GOOD_TS=$(c "$WT" "test: every case of mode.test.sh in its final form, mode still old")
printf 'mode=new\n' > "$WT/mode.txt"; git -C "$WT" add mode.txt; GOOD_IS=$(c "$WT" "fix: mode is new")

answer() { # <testCommit> <implCommit>
  jq -nc --arg ts "$1" --arg is "$2" \
    '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1,
      cleared:[{blockerId:"F7", change:[{path:"mode.txt", action:"modify"}],
                test:{file:"mode.test.sh", behaviour:"the mode is new", redWhen:"the mode goes back to old"},
                command:"bash mode.test.sh", testCommit:$ts, implCommit:$is,
                failedBefore:true, passedAfter:true}]}'
}
queue_then() { # <json> — what the NEXT fix call answers
  jq -nc '{type:"assistant", message:{content:[{type:"tool_use", name:"Skill", input:{skill:"superpowers:receiving-code-review"}}]}}' > "$FIX/ai/fix.then.jsonl"
  jq -nc --arg r "$1" '{type:"result", subtype:"success", is_error:false, result:$r, structured_output:($r|fromjson)}' >> "$FIX/ai/fix.then.jsonl"
}

echo "--- an unproved finding is asked for once more, named, and green when the retry proves it ---"
: > "$CLAUDE_LOG"
fix_ai fix "$(answer "$BAD_TS" "$BAD_IS")" superpowers:receiving-code-review
queue_then "$(answer "$GOOD_TS" "$GOOD_IS")"
rc=0; out=$(driver_step_fix 501 2>&1) || rc=$?
want "the round finishes once the retry proves it" "0" "$rc"
want "the fix step ran exactly twice" "2" "$(grep -cx fix "$CLAUDE_LOG")"
want_in "it said it was asking again" 'asking the fix step once more' "$out"
RETRY_PROMPT=$(grep -A4 "PROOF FAILED" "$FIX/claude-stdin-fix.txt")
want_in "the retry is told which finding lacks proof" '- F7: ' "$RETRY_PROMPT"
want_in "and the case that failed" 'FAIL  mode.test > old' "$RETRY_PROMPT"
want_in "and that the change rewrote the test file" 'mode.test.sh changes between the test commit' "$RETRY_PROMPT"
want_in "and it ends proved" 'red .*then green' "$out"
want "the retry note is cleared afterwards" "" "$(driver_state_get 501 fix_proof_note)"

echo "--- a retry that still proves nothing is refused with the same exit ---"
: > "$CLAUDE_LOG"
driver_state_set 501 park_note ""
fix_ai fix "$(answer "$BAD_TS" "$BAD_IS")" superpowers:receiving-code-review
queue_then "$(answer "$BAD_TS" "$BAD_IS")"
rc=0; out=$(driver_step_fix 501 2>&1) || rc=$?
want "still unproved after the retry refuses" "24" "$rc"
want "and the retry is bounded at one" "2" "$(grep -cx fix "$CLAUDE_LOG")"
want_in "the park names what was not proved" 'not proved red-then-green' "$(driver_state_get 501 park_note)"
want_in "and why, so the next run is told" 'F7: .*FAIL  mode.test > old' "$(driver_state_get 501 park_note)"

git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
exit $FAILED
