#!/usr/bin/env bash
# proof-command.test.sh — a proof command that cannot run as given is sent back,
# told why, with no proof run; it is never read as "still fails with the change".
#
# Measured: a repair answered `DATABASE_URL=<throwaway postgres …> npx vitest run …`,
# bash died on `<throwaway` as a redirect in both halves, and the change was refused
# as not doing the job. Two more proofs carried a literal `<kit at a9ad6222e>`.
#
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
fix_real_briefs
. "$HERE/../ai-step.sh" || exit 1
. "$HERE/../steps/fix.sh" || exit 1
. "$HERE/../steps/repair.sh" || exit 1

c() { git -C "$1" -c user.email=t@e.invalid -c user.name=T commit -qm "$2"; git -C "$1" rev-parse HEAD; }

# An honest red-then-green pair in the main repo.
printf 'no\n' > "$REPO/feat.txt"; git -C "$REPO" add feat.txt; c "$REPO" base >/dev/null
printf '#!/usr/bin/env bash\ngrep -q yes feat.txt || { echo " FAIL  feat > is yes"; exit 1; }\n' > "$REPO/feat.test.sh"
git -C "$REPO" add feat.test.sh; TS=$(c "$REPO" "test: feat")
printf 'yes\n' > "$REPO/feat.txt"; git -C "$REPO" add feat.txt; IS=$(c "$REPO" "feat: feat")

echo "--- a command that cannot run is refused before any proof, and says why ---"
out=$(driver_prove_red_green "$REPO" feat.test.sh "$TS" "$IS" "throwaway npx vitest run x.test.ts" 2>&1); rc=$?
want "a first word that is no program is its own exit" "7" "$rc"
want_in "naming the word" "first word 'throwaway' is not a program" "$out"
want_in "and what to give instead" 'give the exact command, run from the worktree root, e.g. npx vitest run feat.test.sh' "$out"
want_not_in "never 'still fails'" 'still fails' "$out"
out=$(driver_prove_red_green "$REPO" feat.test.sh "$TS" "$IS" "<kit at abc> npm test" 2>&1); rc=$?
want "a <placeholder> is the same" "7" "$rc"
want_in "naming it" "placeholder '<kit at abc>'" "$out"
want_not_in "never 'still fails'" 'still fails' "$out"
out=$(driver_prove_red_green "$REPO" feat.test.sh "$TS" "$IS" "DATABASE_URL=<throwaway postgres with migrations applied> bash feat.test.sh" 2>&1); rc=$?
want "the measured command is caught" "7" "$rc"
out=$(driver_prove_red_green "$REPO" feat.test.sh "$TS" "$IS" "bash feat.test.sh TODO" 2>&1); rc=$?
want "a placeholder word is caught" "7" "$rc"
want_in "naming it" "placeholder word 'TODO'" "$out"

out=$(driver_prove_by_break "$REPO" feat.test.sh "$TS" feat.txt yes no "<kit at abc> bash feat.test.sh" 2>&1); rc=$?
want "the break proof checks the command too" "7" "$rc"
want_in "naming it" "placeholder '<kit at abc>'" "$out"

echo "--- a command that validates still proves, and still fails honestly ---"
out=$(driver_prove_red_green "$REPO" feat.test.sh "$TS" "$IS" "FOO=1 bash feat.test.sh *.nomatch" 2>&1); rc=$?
want "env prefixes and globs are fine" "0" "$rc"
chmod +x "$REPO/feat.test.sh"
want "a script in the tree passes the check" "0" "$(driver_proof_cmd_check "$REPO" ./feat.test.sh >/dev/null; echo $?)"
want "a subshell is judged by the shell" "0" "$(driver_proof_cmd_check "$REPO" '(cd . && bash feat.test.sh)' >/dev/null; echo $?)"
want "so is an assignment the shell expands" "0" "$(driver_proof_cmd_check "$REPO" 'DB="d_$(date +%s)"; bash feat.test.sh' >/dev/null; echo $?)"
want "a prose sentence is not a command" "1" "$(driver_proof_cmd_check "$REPO" 'Capture and pin the evidence' >/dev/null; echo $?)"
want "so does a builtin" "0" "$(driver_proof_cmd_check "$REPO" 'cd . && bash feat.test.sh' >/dev/null; echo $?)"
out=$(driver_prove_red_green "$REPO" feat.test.sh "$TS" "$IS" "bash feat.test.sh && false" 2>&1); rc=$?
want "a valid command that fails is refused as before" "2" "$rc"
want_in "as still failing" 'still fails with the change' "$out"

# ---- the fix round: sent back once, told why --------------------------------
WT="$FIX/wt601"
git -C "$REPO" worktree add -q "$WT" -b "tkt-601/work" develop
driver_state_init 601 --worktree "$WT" --branch "tkt-601/work"
fix_issue 601 OPEN "status:claimed"
printf '%s\n' '{"step":"review","skills":[],"status":"reviewed","round":1,"verdict":"BLOCKED","findings":[{"id":"F9","file":"m.txt","line":1,"grade":"major","summary":"m is old","reason":"a person sees old","fix":"make it new"}]}' \
  > "$(driver_state_dir 601)/steps/review.json"
printf 'old\n' > "$WT/m.txt"; printf '#!/usr/bin/env bash\ngrep -q new m.txt\n' > "$WT/m.test.sh"
git -C "$WT" add m.txt m.test.sh; FTS=$(c "$WT" "test: m")
printf 'new\n' > "$WT/m.txt"; git -C "$WT" add m.txt; FIS=$(c "$WT" "fix: m")
fanswer() { jq -nc --arg c "$1" --arg ts "$FTS" --arg is "$FIS" \
  '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1,
    cleared:[{blockerId:"F9", change:[{path:"m.txt", action:"modify"}],
      test:{file:"m.test.sh", behaviour:"m is new", redWhen:"m goes back"},
      command:$c, testCommit:$ts, implCommit:$is, failedBefore:true, passedAfter:true}]}'; }
then_answer() { # <step> <skills> <json> — what the NEXT call of <step> answers
  local keep; keep=$(cat "$FIX/ai/$1.jsonl")
  fix_ai "$1" "$3" "$2"; mv "$FIX/ai/$1.jsonl" "$FIX/ai/$1.then.jsonl"
  printf '%s\n' "$keep" > "$FIX/ai/$1.jsonl"
}

echo "--- fix: a placeholder command is asked once more, told why, then proved ---"
: > "$CLAUDE_LOG"
fix_ai fix "$(fanswer 'throwaway npx vitest run x.test.ts')" superpowers:receiving-code-review
then_answer fix superpowers:receiving-code-review "$(fanswer 'bash m.test.sh')"
rc=0; out=$(driver_step_fix 601 2>&1) || rc=$?
want "the round finishes once the command is real" "0" "$rc"
want "the fix step ran twice" "2" "$(grep -cx fix "$CLAUDE_LOG")"
want_in "the retry is told why" "F9: .*first word 'throwaway' is not a program" "$(cat "$FIX/claude-stdin-fix.txt")"
want_not_in "never 'still fails'" 'still fails' "$out"
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1

# ---- the repair step: sent back once, with no proof run ---------------------
cat > "$BIN/claude-hands" <<'SH'
#!/usr/bin/env bash
exec "$BIN/claude" "$@"
SH
chmod +x "$BIN/claude-hands"; export DRIVER_CLAUDE="$BIN/claude-hands"
SK='superpowers:systematic-debugging superpowers:test-driven-development'
git init -q --bare "$FIX/origin"; git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop
rsetup() { # <ticket> — a red PR whose repair commits are already made, test first
  local t=$1; WT="$FIX/wt$t"
  git -C "$REPO" worktree add -q "$WT" -b "tkt-$t/work" develop
  printf 'value=bad\n' > "$WT/v$t.txt"; git -C "$WT" add . && git -C "$WT" commit -qm "feat: $t"
  git -C "$WT" push -q -u origin "tkt-$t/work"
  driver_state_init "$t" --worktree "$WT" --branch "tkt-$t/work"
  driver_state_set "$t" pr "$t"; driver_state_set "$t" repair_base "$(git -C "$WT" rev-parse HEAD)"
  printf 'REPAIR on PR #%s: CI went red on: unit\n' "$t" > "$(driver_state_dir "$t")/repair-brief.md"
  driver_state_set "$t" repair_brief "$(driver_state_dir "$t")/repair-brief.md"
  fix_issue "$t" OPEN "status:in-review"
  jq -n --argjson n "$t" --arg b "tkt-$t/work" '[{number:$n, headRefName:$b, headRefOid:"x", isDraft:false,
     mergeStateStatus:"CLEAN", statusCheckRollup:[{name:"unit", status:"COMPLETED", conclusion:"FAILURE"}]}]' > "$FIX/gh/prs.json"
  rm -f "$FIX/ai/repair.jsonl" "$FIX/ai/repair.then.jsonl"; : > "$CLAUDE_LOG"
  printf '#!/usr/bin/env bash\ngrep -q good v%s.txt\n' "$t" > "$WT/v$t.test.sh"
  git -C "$WT" add . && git -C "$WT" commit -qm "test: v"; RTS=$(git -C "$WT" rev-parse HEAD)
  printf 'value=%s\n' "${2:-good}" > "$WT/v$t.txt"; git -C "$WT" add . && git -C "$WT" commit -qm "fix: v"; RIS=$(git -C "$WT" rev-parse HEAD)
}
ranswer() { # <ticket> <command>
  jq -nc --arg ts "$RTS" --arg is "$RIS" --arg f "v$1.test.sh" --arg c "$2" \
    '{step:"repair", skills:["superpowers:systematic-debugging","superpowers:test-driven-development"], status:"repaired", cause:"the value",
      fixes:[{what:"the value was wrong", proof:"test", change:[{path:"v.txt", action:"modify"}],
        test:{file:$f, behaviour:"the value is good", redWhen:"the value is put back"},
        command:$c, failedBefore:true, passedAfter:true, testCommit:$ts, implCommit:$is}]}'; }

echo "--- repair: a placeholder command is asked once more, told why, then proved ---"
rsetup 602
fix_ai repair "$(ranswer 602 '<kit at abc> npm test')" "$SK"
then_answer repair "$SK" "$(ranswer 602 'bash v602.test.sh')"
rc=0; out=$(driver_step_repair 602 2>&1) || rc=$?
want "it finishes once the command is real" "0" "$rc"
want "the model was asked twice" "repair repair" "$(tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//')"
want_in "the second ask says why" "placeholder '<kit at abc>' and is run verbatim" "$(cat "$FIX/claude-stdin-repair.txt")"
want_in "and the fix is proved" 'red .* then green' "$out"
want_not_in "never 'still fails'" 'still fails' "$out"

echo "--- repair: still a placeholder after the retry is refused as unrunnable, not as failing ---"
rsetup 603
fix_ai repair "$(ranswer 603 'throwaway npx vitest run x.test.ts')" "$SK"
rc=0; out=$(driver_step_repair 603 2>&1) || rc=$?
want "it refuses" "24" "$rc"
want "after one retry" "repair repair" "$(tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//')"
want_in "naming the word" "first word 'throwaway' is not a program" "$(driver_state_get 603 park_note)"
want_not_in "never 'still fails'" 'still fails' "$(driver_state_get 603 park_note)"

echo "--- repair: a valid command that fails is refused as now, with no retry ---"
rsetup 604 worse
fix_ai repair "$(ranswer 604 'bash v604.test.sh')" "$SK"
rc=0; out=$(driver_step_repair 604 2>&1) || rc=$?
want "it refuses" "24" "$rc"
want "asked once" "repair" "$(tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//')"
want_in "as still failing" 'still fails with the change' "$out"

exit $FAILED
