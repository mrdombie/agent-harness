#!/usr/bin/env bash
# repair.test.sh — the repair step: a red or clashing pull request, fixed on its own
# branch, with every fix carrying a proof the driver checks for itself. What the
# model says it did is never the evidence. The tree, the commits and the exit codes
# are.
#
#   a clash merges the trunk in; a clean merge needs no model at all
#   a conflict is handed over, and must come back resolved: no unmerged path, no
#     MERGE_HEAD, no marker left, the trunk an ancestor of the head
#   a test-proved fix is re-run red-then-green, exactly as build and fix are
#   a gate-proved fix's command is re-run at the head by exit code
#   a repair that committed nothing, or left the tree dirty, is refused
#   nothing red and nothing clashing is not a reason to call a model
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
fix_real_briefs
. "$HERE/../steps/repair.sh" || exit 1

# The agent's hands: before the recorded transcript is returned, $FIX/ai/repair.sh
# runs in the tree the step was started in, doing what the answer then reports.
cat > "$BIN/claude-hands" <<'SH'
#!/usr/bin/env bash
[ -f "$FIX/ai/repair.sh" ] && bash "$FIX/ai/repair.sh" >/dev/null 2>&1
exec "$BIN/claude" "$@"
SH
chmod +x "$BIN/claude-hands"; export DRIVER_CLAUDE="$BIN/claude-hands"
SK='superpowers:systematic-debugging superpowers:test-driven-development'

git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
printf 'shared line\n' > "$REPO/shared.txt"; printf 'ok\n' > "$REPO/lint.state"
printf '#!/usr/bin/env bash\ngrep -qx ok lint.state\n' > "$REPO/lint.sh"
git -C "$REPO" add . && git -C "$REPO" commit -qm "trunk base"
git -C "$REPO" push -q origin develop

N=0
setup() { # <ticket> — a PR branch with one commit, a worktree on it, the record a reenter leaves
  local t=$1; N=$((N+1))
  WT="$FIX/wt$t"
  git -C "$REPO" worktree add -q "$WT" -b "tkt-$t/work" develop
  printf 'value=bad\n' > "$WT/value$t.txt"
  git -C "$WT" add . && git -C "$WT" commit -qm "feat: $t"
  git -C "$WT" push -q -u origin "tkt-$t/work"
  driver_state_init "$t" --worktree "$WT" --branch "tkt-$t/work"
  driver_state_set "$t" pr "$t"; driver_state_set "$t" repair_base "$(git -C "$WT" rev-parse HEAD)"
  printf 'REPAIR on PR #%s: CI went red on: unit\n' "$t" > "$(driver_state_dir "$t")/repair-brief.md"
  driver_state_set "$t" repair_brief "$(driver_state_dir "$t")/repair-brief.md"
  fix_issue "$t" OPEN "status:in-review"
  rm -f "$FIX/ai/repair.sh" "$FIX/ai/repair.jsonl"; : > "$CLAUDE_LOG"
}
prs() { # <ticket> <mergeState> [failing-check-name]
  jq -n --argjson n "$1" --arg b "tkt-$1/work" --arg m "$2" --arg f "${3:-}" \
    '[{number:$n, headRefName:$b, headRefOid:"x", isDraft:false, mergeStateStatus:$m,
       statusCheckRollup:(if $f == "" then [{name:"unit", status:"COMPLETED", conclusion:"SUCCESS"}]
                          else [{name:$f, status:"COMPLETED", conclusion:"FAILURE"}] end)}]' > "$FIX/gh/prs.json"
}
trunk_moves() { # <file> <content> — a commit on the trunk, pushed
  printf '%s\n' "$2" > "$REPO/$1"; git -C "$REPO" add "$1"; git -C "$REPO" commit -qm "trunk: $1"
  git -C "$REPO" push -q origin develop
}
answer() { fix_ai repair "$1" "$SK"; }
test_fix() { # <test-sha> <impl-sha> <file> <command>
  jq -nc --arg ts "$1" --arg is "$2" --arg f "$3" --arg c "$4" '{what:"the value was wrong", proof:"test",
    change:[{path:"value.txt", action:"modify"}], test:{file:$f, behaviour:"the value is good", redWhen:"the value is put back"},
    command:$c, failedBefore:true, passedAfter:true, testCommit:$ts, implCommit:$is}'
}
gate_fix() { jq -nc --arg c "$1" '{what:"lint", proof:"gate", change:[{path:"lint.state", action:"modify"}], command:$c, noTestBecause:"a lint rule is the check"}'; }
repaired() { jq -nc --argjson f "[$1]" --argjson c "${2:-[]}" '{step:"repair", skills:["superpowers:systematic-debugging","superpowers:test-driven-development"], status:"repaired", cause:"the value", fixes:$f} + (if ($c|length) > 0 then {conflicts:$c} else {} end)'; }

echo "--- a red check, fixed test-first: the driver proves the test red then green ---"
setup 301; prs 301 CLEAN unit
printf '#!/usr/bin/env bash\ngrep -q good value301.txt\n' > "$WT/value301.test.sh"
git -C "$WT" add . && git -C "$WT" commit -qm "test: the value"; TS=$(git -C "$WT" rev-parse HEAD)
printf 'value=good\n' > "$WT/value301.txt"; git -C "$WT" add . && git -C "$WT" commit -qm "fix: the value"; IS=$(git -C "$WT" rev-parse HEAD)
answer "$(repaired "$(test_fix "$TS" "$IS" value301.test.sh 'bash value301.test.sh')")"
out=$(driver_step_repair 301 2>&1); rc=$?
want "it finishes"                     "0" "$rc"
want "the model was called once"       "repair" "$(cat "$CLAUDE_LOG")"
want_in "the fix is proved"            'red .* then green' "$out"
want_in "the failing check reached the brief" 'unit' "$(cat "$FIX/claude-stdin-repair.txt")"
want_in "and the repair brief did, verbatim" 'REPAIR on PR #301: CI went red on: unit' "$(cat "$FIX/claude-stdin-repair.txt")"

echo "--- a test that passes before the fix is refused ---"
setup 302; prs 302 CLEAN unit
printf '#!/usr/bin/env bash\ntrue\n' > "$WT/vac.test.sh"; git -C "$WT" add . && git -C "$WT" commit -qm "test: vacuous"
TS=$(git -C "$WT" rev-parse HEAD)
printf 'value=good\n' > "$WT/value302.txt"; git -C "$WT" add . && git -C "$WT" commit -qm "fix: it"
IS=$(git -C "$WT" rev-parse HEAD)
answer "$(repaired "$(test_fix "$TS" "$IS" vac.test.sh 'bash vac.test.sh')")"
out=$(driver_step_repair 302 2>&1); rc=$?
want "it refuses"                      "24" "$rc"
want_in "and says why"                 'passes without the change' "$out"

echo "--- a fix commit that is not this repair's own proves nothing ---"
setup 303; prs 303 CLEAN unit
BASE=$(driver_state_get 303 repair_base)
git -C "$WT" commit -q --allow-empty -m "fix: something"
answer "$(repaired "$(test_fix "$BASE" "$(git -C "$WT" rev-parse HEAD~1)" value303.txt 'true')")"
out=$(driver_step_repair 303 2>&1); rc=$?
want "it refuses"                      "24" "$rc"
want_in "naming the commit"            'not a commit this repair made' "$out"

echo "--- a gate-proved fix: its command is run at the head, by exit code ---"
setup 304; prs 304 CLEAN lint
printf 'ok\n' > "$WT/lint.state"; printf 'x\n' > "$WT/touch304"; git -C "$WT" add . && git -C "$WT" commit -qm "fix: lint"
answer "$(repaired "$(gate_fix 'bash lint.sh')")"
out=$(driver_step_repair 304 2>&1); rc=$?
want "a green gate at the head passes" "0" "$rc"
setup 305; prs 305 CLEAN lint
printf 'bad\n' > "$WT/lint.state"; git -C "$WT" add . && git -C "$WT" commit -qm "fix: not really"
answer "$(repaired "$(gate_fix 'bash lint.sh')")"
out=$(driver_step_repair 305 2>&1); rc=$?
want "a gate still red at the head is refused" "24" "$rc"
want_in "naming the command"           'bash lint.sh' "$out"

echo "--- a clash that merges clean needs no model ---"
setup 306; trunk_moves trunk306.txt "trunk work"; prs 306 DIRTY
out=$(driver_step_repair 306 2>&1); rc=$?
want "it finishes"                     "0" "$rc"
want "no model was called"             "" "$(cat "$CLAUDE_LOG")"
want "the trunk is now in the branch"  "yes" "$(git -C "$WT" merge-base --is-ancestor origin/develop HEAD && echo yes)"
want "the tree is clean"               "" "$(git -C "$WT" status --porcelain)"

echo "--- a conflict is handed over, and comes back resolved ---"
setup 307
printf 'branch line\n' > "$WT/shared.txt"; git -C "$WT" commit -qam "feat: our line"
driver_state_set 307 repair_base "$(git -C "$WT" rev-parse HEAD)"
trunk_moves shared.txt "trunk line"; prs 307 DIRTY
cat > "$FIX/ai/repair.sh" <<'SH'
printf 'trunk line\nbranch line\n' > shared.txt; git add shared.txt && git commit -q --no-edit
SH
answer "$(repaired "$(gate_fix 'bash lint.sh')" '[{"file":"shared.txt","resolution":"both lines kept"}]')"
out=$(driver_step_repair 307 2>&1); rc=$?
want "it finishes"                     "0" "$rc"
want_in "the conflicted file reached the brief" 'shared.txt' "$(cat "$FIX/claude-stdin-repair.txt")"
want "the trunk is now in the branch"  "yes" "$(git -C "$WT" merge-base --is-ancestor origin/develop HEAD && echo yes)"
want "both sides survive"              "trunk line branch line" "$(tr '\n' ' ' < "$WT/shared.txt" | sed 's/ $//')"

echo "--- a resolution that leaves conflict markers committed is refused ---"
setup 308
printf 'branch line\n' > "$WT/shared.txt"; git -C "$WT" commit -qam "feat: our line"
driver_state_set 308 repair_base "$(git -C "$WT" rev-parse HEAD)"
trunk_moves shared.txt "trunk line 308"; prs 308 DIRTY
cat > "$FIX/ai/repair.sh" <<'SH'
git add shared.txt && git commit -q --no-edit
SH
answer "$(repaired "$(gate_fix 'bash lint.sh')" '[{"file":"shared.txt","resolution":"kept"}]')"
out=$(driver_step_repair 308 2>&1); rc=$?
want "it refuses"                      "24" "$rc"
want_in "naming the markers"           'conflict marker' "$out"

echo "--- a merge left unfinished is refused ---"
setup 309
printf 'branch line\n' > "$WT/shared.txt"; git -C "$WT" commit -qam "feat: our line"
driver_state_set 309 repair_base "$(git -C "$WT" rev-parse HEAD)"
trunk_moves shared.txt "trunk line 309"; prs 309 DIRTY
answer "$(repaired "$(gate_fix 'bash lint.sh')" '[{"file":"shared.txt","resolution":"kept"}]')"
out=$(driver_step_repair 309 2>&1); rc=$?
want "it refuses"                      "24" "$rc"
want_in "naming the merge"             'unfinished|unmerged' "$out"
git -C "$WT" merge --abort 2>/dev/null

echo "--- a repair that committed nothing, or left the tree dirty, is refused ---"
setup 310; prs 310 CLEAN unit
answer "$(repaired "$(gate_fix 'bash lint.sh')")"
out=$(driver_step_repair 310 2>&1); rc=$?
want "nothing committed refuses"       "24" "$rc"
want_in "and says so"                  'committed nothing' "$out"
setup 311; prs 311 CLEAN unit
cat > "$FIX/ai/repair.sh" <<'SH'
printf 'x\n' > stray.txt
SH
git -C "$WT" commit -q --allow-empty -m "fix: half"
answer "$(repaired "$(gate_fix 'bash lint.sh')")"
out=$(driver_step_repair 311 2>&1); rc=$?
want "a dirty tree refuses"            "24" "$rc"
want_in "naming the file"              'stray.txt' "$out"

echo "--- nothing red and nothing clashing: no model, nothing to do ---"
setup 312; prs 312 CLEAN
out=$(driver_step_repair 312 2>&1); rc=$?
want "it finishes"                     "0" "$rc"
want "no model was called"             "" "$(cat "$CLAUDE_LOG")"
want_in "and says why"                 'nothing red' "$out"

echo "--- an unreadable PR is not a green one: the model is asked, and told ---"
setup 313; echo "pr list" > "$FIX/gh-fail"
git -C "$WT" commit -q --allow-empty -m "fix: x"
answer "$(repaired "$(gate_fix 'bash lint.sh')")"
out=$(driver_step_repair 313 2>&1); rc=$?
rm -f "$FIX/gh-fail"
want "it ran the model"                "repair" "$(cat "$CLAUDE_LOG")"
want_in "and the brief says the checks could not be read" 'could not be read' "$(cat "$FIX/claude-stdin-repair.txt")"

echo "--- a park is a park ---"
setup 314; prs 314 CLEAN e2e
fix_ai repair '{"step":"repair","skills":["superpowers:systematic-debugging"],"status":"park","question":"e2e is red on develop too — is that being fixed?"}' "superpowers:systematic-debugging"
out=$(driver_step_repair 314 2>&1); rc=$?
want "it asks"                         "20" "$rc"

echo "--- markers committed by an earlier pass are caught with no model call and nothing red ---"
setup 315
printf 'branch line\n' > "$WT/shared.txt"; git -C "$WT" commit -qam "feat: our line"
trunk_moves shared.txt "trunk line 315"
git -C "$WT" fetch -q origin; git -C "$WT" merge -q origin/develop >/dev/null 2>&1; git -C "$WT" add -A; git -C "$WT" commit -q --no-edit
driver_state_set 315 repair_base "$(git -C "$WT" rev-parse HEAD)"; driver_state_set 315 repair_conflicted "shared.txt"
prs 315 CLEAN
out=$(driver_step_repair 315 2>&1); rc=$?
want "it refuses"                          "24" "$rc"
want "without a model call"                "" "$(cat "$CLAUDE_LOG")"
want_in "naming the markers"               'conflict marker' "$out"
setup 316
printf 'branch line\n' > "$WT/shared.txt"; git -C "$WT" commit -qam "feat: our line"
trunk_moves shared.txt "trunk line 316"
git -C "$WT" fetch -q origin; git -C "$WT" merge -q origin/develop >/dev/null 2>&1; git -C "$WT" add -A; git -C "$WT" commit -q --no-edit
driver_state_set 316 repair_base "$(git -C "$WT" rev-parse HEAD)"
prs 316 CLEAN
out=$(driver_step_repair 316 2>&1); rc=$?
want "with nothing on the record, the branch's own diff still catches them" "24" "$rc"
want_in "and names the file"               'shared.txt' "$out"

echo "--- a merge left in progress by an earlier pass is resumed and handed over again ---"
setup 317
printf 'branch line\n' > "$WT/shared.txt"; git -C "$WT" commit -qam "feat: our line"
driver_state_set 317 repair_base "$(git -C "$WT" rev-parse HEAD)"
trunk_moves shared.txt "trunk line 317"
git -C "$WT" fetch -q origin; git -C "$WT" merge -q origin/develop >/dev/null 2>&1
git -C "$WT" add shared.txt   # staged, unresolved: no U path left, MERGE_HEAD still there
prs 317 CLEAN
cat > "$FIX/ai/repair.sh" <<'SH'
printf 'trunk line 317\nbranch line\n' > shared.txt; git add shared.txt && git commit -q --no-edit
SH
answer "$(repaired "$(gate_fix 'bash lint.sh')" '[{"file":"shared.txt","resolution":"both kept"}]')"
out=$(driver_step_repair 317 2>&1); rc=$?
want "it finishes"                         "0" "$rc"
want "the model was called"                "repair" "$(cat "$CLAUDE_LOG")"
want "both sides survive"                  "trunk line 317 branch line" "$(tr '\n' ' ' < "$WT/shared.txt" | sed 's/ $//')"

exit $FAILED
