#!/usr/bin/env bash
# fix-proof.test.sh — a fix that edits the test it names is proved with the version
# that lands; a proof that fails says which case failed; and a fix round whose proof
# fails is asked once more, told why, and still refused when the retry proves nothing.
#
# Measured on the origin project, 18–20 Oct: 12 of 18 "still fails with the change"
# refusals in a fix round were a test file the fix had also edited (sibling cases
# that asserted the old behaviour), and the proof ran the TEST commit's version in
# both trees. The reason it printed was `head -5` of the output — a runner's config
# banner — so the one retry was handed nothing and re-sent the same commits.
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
BANNER='for i in 1 2 3 4 5 6; do echo "(!) a config banner line $i that says nothing"; done'

# mk_mode <repo> — a test commit whose file holds the new case AND a sibling that
# asserts the old behaviour, so the fix has to edit the test file it names.
mk_mode() {
  local r="$1"
  printf 'mode=old\n' > "$r/mode.txt"
  git -C "$r" add mode.txt; c "$r" "base: mode" >/dev/null
  { echo '#!/usr/bin/env bash'; echo "$BANNER"
    echo "grep -q 'mode=new' mode.txt || { echo ' FAIL  mode.test > new'; exit 1; }"
    echo "grep -q 'mode=old' mode.txt || { echo ' FAIL  mode.test > old'; exit 1; }"; } > "$r/mode.test.sh"
  git -C "$r" add mode.test.sh; M_TEST=$(c "$r" "test: mode is new")
}
# set_sibling <repo> <line> — the sibling line of mode.test.sh, replaced and asserted.
set_sibling() {
  local r="$1" want="$2"
  { echo '#!/usr/bin/env bash'; echo "$BANNER"
    echo "grep -q 'mode=new' mode.txt || { echo ' FAIL  mode.test > new'; exit 1; }"
    echo "$want"; } > "$r/mode.test.sh"
  grep -qxF -- "$want" "$r/mode.test.sh" || { echo "fixture: the sibling edit did not land"; exit 1; }
}

echo "--- a fix that edits the test it names is proved with the version that lands ---"
# The fix changes the behaviour and rewrites the sibling that asserted the old one.
mk_mode "$REPO"
printf 'mode=new\n' > "$REPO/mode.txt"
set_sibling "$REPO" "grep -q 'mode=' mode.txt || { echo ' FAIL  mode.test > has a mode'; exit 1; }"
git -C "$REPO" add mode.txt mode.test.sh; M_IMPL=$(c "$REPO" "fix: mode is new, and the sibling follows it")
out=$(driver_prove_red_green "$REPO" mode.test.sh "$M_TEST" "$M_IMPL" "bash mode.test.sh" 2>&1); rc=$?
want "red on the code before the fix, green after, with the fix's own version" "0" "$rc"
want_in "and it says red then green" 'red .*then green' "$out"
want_not_in "never blamed on the sibling the fix rewrote" 'still fails with the change' "$out"

echo "--- a case the fix ADDS to the test it names is run too ---"
# Added red at the change itself, so only a run of the post-fix version can see it.
mk_mode "$REPO"
printf 'mode=new\n' > "$REPO/mode.txt"
set_sibling "$REPO" "grep -q 'never' mode.txt || { echo ' FAIL  mode.test > added by the fix'; exit 1; }"
git -C "$REPO" add mode.txt mode.test.sh; A_IMPL=$(c "$REPO" "fix: mode is new, with an added case")
out=$(driver_prove_red_green "$REPO" mode.test.sh "$M_TEST" "$A_IMPL" "bash mode.test.sh" 2>&1); rc=$?
want "the added case is red at the change, so the fix is not proved" "2" "$rc"
want_in "and the reason quotes that case, not the runner's banner" 'FAIL  mode.test > added by the fix' "$out"
want_not_in "the banner is not the reason" 'config banner line 1' "$out"

echo "--- a fix that guts the test it names proves nothing ---"
# Not a way round the rule: the post-fix version has to be RED on the code before it.
mk_mode "$REPO"
printf 'mode=new\n' > "$REPO/mode.txt"
printf '#!/usr/bin/env bash\ntrue\n' > "$REPO/mode.test.sh"
git -C "$REPO" add mode.txt mode.test.sh; G_IMPL=$(c "$REPO" "fix: mode is new, and the test says nothing")
out=$(driver_prove_red_green "$REPO" mode.test.sh "$M_TEST" "$G_IMPL" "bash mode.test.sh" 2>&1); rc=$?
want "a post-fix test green before the fix is refused" "1" "$rc"
want_in "as one that does not test the change" 'passes without the change' "$out"

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

# Round 1 names a change that does not do the job; the retry names the one that does.
printf 'mode=old\n' > "$WT/mode.txt"
{ echo '#!/usr/bin/env bash'; echo "$BANNER"
  echo "grep -q 'mode=new' mode.txt || { echo ' FAIL  mode.test > new'; exit 1; }"; } > "$WT/mode.test.sh"
git -C "$WT" add mode.txt mode.test.sh; TS=$(c "$WT" "test: mode is new")
printf 'noise\n' > "$WT/other.txt"; git -C "$WT" add other.txt; BAD_IS=$(c "$WT" "fix: not the fix")
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
fix_ai fix "$(answer "$TS" "$BAD_IS")" superpowers:receiving-code-review
queue_then "$(answer "$TS" "$GOOD_IS")"
rc=0; out=$(driver_step_fix 501 2>&1) || rc=$?
want "the round finishes once the retry proves it" "0" "$rc"
want "the fix step ran exactly twice" "2" "$(grep -cx fix "$CLAUDE_LOG")"
want_in "it said it was asking again" 'asking the fix step once more' "$out"
RETRY_PROMPT=$(grep -A4 "PROOF FAILED" "$FIX/claude-stdin-fix.txt")
want_in "the retry is told which finding lacks proof" '- F7: ' "$RETRY_PROMPT"
want_in "and the case that failed" 'FAIL  mode.test > new' "$RETRY_PROMPT"
want_not_in "not the runner's banner" 'config banner line 1' "$RETRY_PROMPT"
want_in "and it ends proved" 'red .*then green' "$out"
want "the retry note is cleared afterwards" "" "$(driver_state_get 501 fix_proof_note)"

echo "--- a retry that still proves nothing is refused with the same exit ---"
: > "$CLAUDE_LOG"
driver_state_set 501 park_note ""
fix_ai fix "$(answer "$TS" "$BAD_IS")" superpowers:receiving-code-review
queue_then "$(answer "$TS" "$BAD_IS")"
rc=0; out=$(driver_step_fix 501 2>&1) || rc=$?
want "still unproved after the retry refuses" "24" "$rc"
want "and the retry is bounded at one" "2" "$(grep -cx fix "$CLAUDE_LOG")"
want_in "the park names what was not proved" 'not proved red-then-green' "$(driver_state_get 501 park_note)"
want_in "and why, so the next run is told" 'F7: .*FAIL  mode.test > new' "$(driver_state_get 501 park_note)"

git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
suite_end "$FAILED"
