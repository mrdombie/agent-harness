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

echo "--- a clash is GitHub's mergeable or a trial merge, not DIRTY alone ---"
# mergeStateStatus is DIRTY only when GitHub has computed it; BLOCKED and UNKNOWN hide a
# conflict, and the repair then said "nothing clashing" on a PR that could not merge.
prs_m() { # <ticket> <mergeState> <mergeable>
  jq -n --argjson n "$1" --arg b "tkt-$1/work" --arg m "$2" --arg g "$3" \
    '[{number:$n, headRefName:$b, headRefOid:"x", isDraft:false, mergeStateStatus:$m, mergeable:$g,
       statusCheckRollup:[{name:"unit", status:"COMPLETED", conclusion:"SUCCESS"}]}]' > "$FIX/gh/prs.json"
}
resolve_both='printf "trunk line\nbranch line\n" > shared.txt; git add shared.txt && git commit -q --no-edit'
for c in "331 BLOCKED CONFLICTING" "332 UNKNOWN UNKNOWN"; do
  set -- $c
  setup "$1"
  printf 'branch line\n' > "$WT/shared.txt"; git -C "$WT" commit -qam "feat: our line"
  driver_state_set "$1" repair_base "$(git -C "$WT" rev-parse HEAD)"
  trunk_moves shared.txt "trunk line $1"; prs_m "$1" "$2" "$3"
  printf '%s\n' "$resolve_both" > "$FIX/ai/repair.sh"
  answer "$(repaired "$(gate_fix 'bash lint.sh')" '[{"file":"shared.txt","resolution":"both lines kept"}]')"
  out=$(driver_step_repair "$1" 2>&1); rc=$?
  want "$2/$3 with a real conflict: merged and handed over" "0" "$rc"
  want_in "$2/$3: the conflict reached the model" 'shared.txt' "$(cat "$FIX/claude-stdin-repair.txt")"
  want "$2/$3: the trunk is in the branch" "yes" "$(git -C "$WT" merge-base --is-ancestor origin/develop HEAD && echo yes)"
done
setup 335
printf 'branch line\n' > "$WT/shared.txt"; git -C "$WT" commit -qam "feat: our line"
driver_state_set 335 repair_base "$(git -C "$WT" rev-parse HEAD)"
trunk_moves shared.txt "trunk line 335"; prs_m 335 UNKNOWN UNKNOWN
printf 'scratch\n' > "$WT/untracked-note.txt"
printf '%s\n' "rm -f untracked-note.txt; $resolve_both" > "$FIX/ai/repair.sh"
answer "$(repaired "$(gate_fix 'bash lint.sh')" '[{"file":"shared.txt","resolution":"both lines kept"}]')"
out=$(driver_step_repair 335 2>&1); rc=$?
want "an untracked file does not hide the clash" "yes" "$(git -C "$WT" merge-base --is-ancestor origin/develop HEAD && echo yes)"
want "and the trial leaves no tree behind"  "" "$(git -C "$WT" worktree list | grep repair-trial)"
setup 333; trunk_moves trunk333.txt "unrelated"; prs_m 333 CLEAN MERGEABLE
out=$(driver_step_repair 333 2>&1); rc=$?
want "no clash anywhere: nothing merged"     "no" "$(git -C "$WT" merge-base --is-ancestor origin/develop HEAD && echo yes || echo no)"
want "and the trial merge left nothing behind" "" "$(git -C "$WT" status --porcelain; [ -f "$(git -C "$WT" rev-parse --git-path MERGE_HEAD)" ] && echo MERGE_HEAD)"

echo "--- a resolution that drops the PR's own change is refused ---"
setup 334
printf 'branch line\n' > "$WT/shared.txt"; git -C "$WT" commit -qam "feat: our line"
driver_state_set 334 repair_base "$(git -C "$WT" rev-parse HEAD)"
trunk_moves shared.txt "trunk line 334"; prs 334 DIRTY
cat > "$FIX/ai/repair.sh" <<'SH'
git checkout -q origin/develop -- shared.txt; git rm -q value334.txt; git commit -q --no-edit
SH
answer "$(repaired "$(gate_fix 'bash lint.sh')" '[{"file":"shared.txt","resolution":"took the trunk"}]')"
out=$(driver_step_repair 334 2>&1); rc=$?
want "it refuses"                            "24" "$rc"
want_in "naming the dropped change"          'dropped the PR' "$out"
want_in "and the park note carries it"       'without its own change' "$(driver_state_get 334 park_note)"

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
setup 313; echo "open-prs" > "$FIX/gh-fail"
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

echo "--- a caller's brief on a green, clean PR still reaches the model; it may answer unchanged ---"
# An owner's answer on a PR'd ticket comes as a repair with a note. Read only when
# something is red, it would be dropped.
setup 318; prs 318 CLEAN; driver_state_set 318 repair_brief_source caller
driver_state_set 318 repair_brief_sha "first-brief-sha"
printf 'The owner answered q4: keep the old label.\n' > "$(driver_state_dir 318)/repair-brief.md"
fix_ai repair '{"step":"repair","skills":["superpowers:systematic-debugging"],"status":"unchanged","reason":"the PR already keeps the old label; nothing to change"}' superpowers:systematic-debugging
out=$(driver_step_repair 318 2>&1); rc=$?
want "the model was called"                "repair" "$(cat "$CLAUDE_LOG")"
want_in "with the brief"                   'The owner answered q4' "$(cat "$FIX/claude-stdin-repair.txt")"
want_in "under the driver's preface: a brief's push or hand-off is void" 'void' "$(cat "$FIX/claude-stdin-repair.txt")"
want "unchanged on a caller's brief asks rather than ships" "20" "$rc"
want_in "the question carries the reason"  'already keeps the old label' "$(driver_state_get 318 park_note)"
want "and a person answers it"             "person" "$(driver_state_get 318 park_cause)"
driver_state_set 318 park_note ""; driver_state_set 318 repair_brief_sha "answer-brief-sha"
out=$(driver_step_repair 318 2>&1); rc=$?
want "the answer, back as a new brief at the same head, is acted on — not asked again" "0" "$rc"
driver_state_set 318 repair_brief_sha "answer-brief-sha"
git -C "$WT" commit -q --allow-empty -m "moved"
out=$(driver_step_repair 318 2>&1); rc=$?
want "at a new head it asks again"         "20" "$rc"
setup 319; prs 319 CLEAN unit; driver_state_set 319 repair_brief_source caller
fix_ai repair '{"step":"repair","skills":["superpowers:systematic-debugging"],"status":"unchanged","reason":"flaky"}' superpowers:systematic-debugging
out=$(driver_step_repair 319 2>&1); rc=$?
want "unchanged with a check still red is refused" "24" "$rc"
want_in "and says to park instead"         'park' "$out"
setup 320; prs 320 CLEAN; driver_state_set 320 repair_brief_source caller
cat > "$FIX/ai/repair.sh" <<'SH'
git commit -q --allow-empty -m "fix: something after all"
SH
fix_ai repair '{"step":"repair","skills":["superpowers:systematic-debugging"],"status":"unchanged","reason":"nothing to do"}' superpowers:systematic-debugging
out=$(driver_step_repair 320 2>&1); rc=$?
want "unchanged with a new commit is refused" "24" "$rc"

echo "--- a step never pushes, readies or arms: only the driver does, after the review ---"
# Briefs written for the prose flow say "push, keep auto-merge armed, hand off", and a
# step has Bash. A push from inside a step lands through auto-merge before self-check,
# review and ship have run.
REAL_GIT=$(command -v git)
setup 321; prs 321 CLEAN unit; ORIG=$(git -C "$WT" rev-parse HEAD)
cat > "$FIX/ai/repair.sh" <<'SH'
git commit -q --allow-empty -m "fix: x"
git push -q origin HEAD:tkt-321/work 2>"$FIX/shim-git.err"
gh pr ready 321 2>"$FIX/shim-gh.err"; gh pr merge 321 --auto --squash 2>>"$FIX/shim-gh.err"
gh api -X PUT repos/o/r/rulesets/17138103 --input r.json 2>"$FIX/shim-rs.err"
gh api repos/o/r/rulesets/17138103 >/dev/null 2>&1
SH
answer "$(repaired "$(gate_fix 'bash lint.sh')")"; : > "$GH_LOG"
out=$(driver_step_repair 321 2>&1); rc=$?
want "a step's git push is stopped"        "$ORIG" "$(git -C "$FIX/origin" rev-parse tkt-321/work)"
want_in "and told why"                     'driver alone pushes' "$(cat "$FIX/shim-git.err")"
want_not_in "its gh pr ready and merge never reach GitHub" 'pr ready|pr merge' "$(cat "$GH_LOG")"
want_in "and are told why"                 'driver alone' "$(cat "$FIX/shim-gh.err")"
want_not_in "a step's ruleset write never reaches GitHub" 'api -X PUT' "$(cat "$GH_LOG")"
want_in "and is told to leave it to the PM" 'PM step' "$(cat "$FIX/shim-rs.err")"
want_in "while a read of the ruleset still goes through" 'api repos/o/r/rulesets/17138103' "$(cat "$GH_LOG")"
setup 322; prs 322 CLEAN unit
cat > "$FIX/ai/repair.sh" <<SH
git commit -q --allow-empty -m "fix: y"
"$REAL_GIT" push -q origin HEAD:tkt-322/work
SH
answer "$(repaired "$(gate_fix 'bash lint.sh')")"
out=$(driver_step_repair 322 2>&1); rc=$?
want "a push that got past the shim refuses the step" "24" "$rc"
want_in "naming what moved"                'origin/tkt-322/work moved' "$out"
want_in "and the park says so"             'moved during the repair step' "$(driver_state_get 322 park_note)"

echo "--- evidence owed is work: a repair told to add shots edits the capture plan (#297) ---"
# Three repairs in one day were told to add shots (a drawer open, dark, 390) and pushed
# without touching the capture plan: nothing red said the evidence was short.
cat > "$FIX/evgaps" <<'SH'
#!/usr/bin/env bash
case "$1" in
  tasks)    [ -f "$FIX/ev-tasks" ] && sed 's/^/- /' "$FIX/ev-tasks"; exit 0 ;;
  coverage) [ -f "$FIX/ev-left" ] && { cat "$FIX/ev-left"; exit 1; }; exit 0 ;;
esac
SH
chmod +x "$FIX/evgaps"; export DRIVER_EVIDENCE_GAPS="$FIX/evgaps"
printf 'evidence gap: apps/web/PersonDrawer.tsx is a drawer that only shows once opened, and no capture-plan shot opens it\n' > "$FIX/ev-tasks"
PLANCMD="python3 -I $KIT_ROOT/scripts/evidence-gaps.py check-plan docs/evidence/370/plan.json"
plan_fix() { jq -nc --arg c "$1" '{what:"the drawer is photographed open", proof:"gate", change:[{path:"docs/evidence/370/plan.json", action:"create"}], command:$c, noTestBecause:"evidence, not behaviour"}'; }

setup 370; prs 370 CLEAN
cat > "$FIX/ai/repair.sh" <<'SH'
mkdir -p docs/evidence/370
printf '{"shots":[{"name":"drawer-open-laptop-light","route":"/home","viewport":"laptop","theme":"light","setup":["click the \\"Ann\\" button"]}]}\n' > docs/evidence/370/plan.json
git add docs && git commit -qm "chore(evidence-plan): the drawer open"
SH
answer "$(repaired "$(plan_fix "$PLANCMD")")"
out=$(driver_step_repair 370 2>&1); rc=$?
want "with nothing red, evidence owed still calls the model" "repair" "$(cat "$CLAUDE_LOG")"
want_in "the evidence tasks reach the brief"   'PersonDrawer.tsx is a drawer' "$(cat "$FIX/claude-stdin-repair.txt")"
want_in "said as edits to the capture plan"     'docs/evidence/370/plan.json' "$(cat "$FIX/claude-stdin-repair.txt")"
want "a repair that adds the shot to the plan finishes" "0" "$rc"

setup 371; prs 371 CLEAN
cat > "$FIX/ai/repair.sh" <<'SH'
printf 'value=good\n' > value371.txt; git add . && git commit -qm "fix: code only"
SH
answer "$(repaired "$(gate_fix 'bash lint.sh')")"
out=$(driver_step_repair 371 2>&1); rc=$?
want "a repair that changes code and leaves the plan alone is asked again, then refused" "24" "$rc"
want "asked twice"                              "repair repair" "$(tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//')"
want_in "the second ask names what is open"    'LEFT THE EVIDENCE OPEN' "$(cat "$FIX/claude-stdin-repair.txt")"
want_in "and the park says the plan is unchanged" 'capture plan docs/evidence/371/plan.json is unchanged' "$(driver_state_get 371 park_note)"

setup 372; prs 372 CLEAN
sed 's/370/372/g' > "$FIX/ai/repair.sh" <<'SH'
mkdir -p docs/evidence/370
printf '{"shots":[{"name":"home-laptop-light","route":"/home","viewport":"laptop","theme":"light"}]}\n' > docs/evidence/370/plan.json
git add docs && git commit -qm "chore(evidence-plan): a shot that opens nothing"
SH
printf 'missing-state\tapps/web/PersonDrawer.tsx\t/home\tevidence gap: still unopened\n' > "$FIX/ev-left"
answer "$(repaired "$(plan_fix "${PLANCMD//370/372}")")"
out=$(driver_step_repair 372 2>&1); rc=$?
want "a plan edit that leaves the drawer unopened is refused" "24" "$rc"
want_in "naming the file"                       'PersonDrawer.tsx' "$(driver_state_get 372 park_note)"
rm -f "$FIX/ev-left" "$FIX/ev-tasks"

setup 373; prs 373 CLEAN
out=$(driver_step_repair 373 2>&1); rc=$?
want "with no evidence owed and nothing red, still no model" "" "$(cat "$CLAUDE_LOG")"
unset DRIVER_EVIDENCE_GAPS

echo "--- a claim another live run holds: the repair waits on the queue, never asks (#319) ---"
# #13191 (2026-10-20) parked in the PM's lane over "a peer holds the claim": a state the
# queue waits out reached the model as a question. The claim is checked before the step
# touches the tree and again before the model is handed the repair.
CLK="$HERE/../../scripts/claim-lock.sh"
setup 380; prs 380 CLEAN unit
bash "$CLK" acquire 380 --branch tkt-380/work --worktree "$FIX/theirs-380" --pid $$ >/dev/null 2>&1
want "the fixture's sibling run holds the claim" "$FIX/theirs-380" "$(bash "$CLK" show 380 2>/dev/null | jq -r '.worktree // ""')"
answer "$(repaired "$(gate_fix 'bash lint.sh')")"
out=$(driver_step_repair 380 2>&1); rc=$?
want "a sibling run's claim is busy (29), not a question"  "29" "$rc"
want "the model is never handed it"                        "" "$(cat "$CLAUDE_LOG")"
want_in "it says another run holds the claim"              'another run on this host holds the claim on #380' "$out"
want "the run is told to keep the holder's claim"          "1" "$(driver_state_get 380 claim_elsewhere)"
want "and the holder's claim is untouched"                 "$FIX/theirs-380" "$(bash "$CLK" show 380 2>/dev/null | jq -r '.worktree // ""')"
want "the tree is not touched"                             "$(driver_state_get 380 repair_base)" "$(git -C "$WT" rev-parse HEAD)"
bash "$CLK" release 380 --force >/dev/null 2>&1

setup 381; prs 381 CLEAN unit
CLAIM_AGENT="peer@elsewhere" bash "$CLK" acquire 381 --branch tkt-381/work --worktree "$FIX/peer-381" >/dev/null 2>&1
out=$(driver_step_repair 381 2>&1); rc=$?
want "a peer machine's claim is busy (29) too"             "29" "$rc"
want "and no model call"                                   "" "$(cat "$CLAUDE_LOG")"
want_in "the reason is on the record"                      'peer on another machine holds the claim on #381' "$(driver_state_get 381 park_note)"
bash "$CLK" release 381 --force >/dev/null 2>&1

# Taken between the step's start and the model call: the second check is the one that holds.
setup 382; prs 382 CLEAN unit
printf '0\n' > "$FIX/held-calls"
eval "_real_$(declare -f driver_claim_held_elsewhere)"
driver_claim_held_elsewhere() {
  local n=$(( $(cat "$FIX/held-calls") + 1 )); echo "$n" > "$FIX/held-calls"
  [ "$n" -ge 2 ] || return 1
  echo "a peer on another machine holds the claim on #$1"
}
out=$(driver_step_repair 382 2>&1); rc=$?
want "a claim taken mid-step stops it before the model (29)" "29" "$rc"
want "the model is never handed it"                        "" "$(cat "$CLAUDE_LOG")"
eval "$(declare -f _real_driver_claim_held_elsewhere | sed '1s/^_real_//')"

setup 383; prs 383 CLEAN unit
answer "$(repaired "$(gate_fix 'bash lint.sh')")"
out=$(driver_step_repair 383 2>&1); rc=$?
want_in "with our own claim (none here) the model is still called" 'repair' "$(cat "$CLAUDE_LOG")"
want "and nothing says to keep a claim"                    "" "$(driver_state_get 383 claim_elsewhere)"


echo "--- a red lesson check is answered in the PR body, from the diff's own guard (#332) ---"
# The body lives in $FIX/gh/body-<n>.md: read and PATCHed through the REST API.
cat > "$BIN/gh-body" <<'SH'
#!/usr/bin/env bash
case "$1 $*" in
  "api "*pulls/[0-9]*)
    printf '%s\n' "$*" >> "$GH_LOG"
    n=$(printf '%s' "$*" | sed -n 's#.*pulls/\([0-9]*\).*#\1#p'); f="$FIX/gh/body-$n.md"
    case " $* " in *" PATCH "*)
      [ ! -f "$FIX/gh-body-patch-fails" ] || exit 1
      src=$(printf '%s\n' "$@" | sed -n 's/^body=@//p'); cp "$src" "$f"; echo '{}'; exit 0 ;; esac
    [ -f "$f" ] && cat "$f" ;;
  *) exec "$BIN/gh" "$@" ;;
esac
SH
chmod +x "$BIN/gh-body"; SWARM_GH_WAS="$SWARM_GH"; export SWARM_GH="$BIN/gh-body"
LESSON_CHECK='Every fix ships a lesson'
lesson_body() { printf 'Fixes the value.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' > "$FIX/gh/body-$1.md"; }
lesson() { jq -nc --arg g "$1" '{principle:"a value written without a check that reads it back ships wrong", guard:$g,
  beforeAfter:"the guard fails on the bad value and passes on the good one", reach:"every value file this repo writes, by the same grep"}'; }
lesson_only() { jq -nc --argjson l "$1" '{step:"repair", skills:["superpowers:systematic-debugging","superpowers:test-driven-development"], status:"repaired", cause:"the body had no lesson", lesson:$l}'; }
printf '[]\n' > "$FIX/no-closing.json"
judge_body() { # <ticket> — the lesson check, run on the body GitHub now holds
  bash "$HERE/../../scripts/check-lesson.sh" --repo "$WT" --base develop --head HEAD --body-file "$FIX/gh/body-$1.md" \
    --class repair --labels "" --title "" --branch "tkt-$1/work" --closing-file "$FIX/no-closing.json" 2>&1 | head -1
}

setup 401; lesson_body 401
printf '#!/usr/bin/env bash\ngrep -q good value401.txt\n' > "$WT/value401.test.sh"; printf 'value=good\n' > "$WT/value401.txt"
git -C "$WT" add . && git -C "$WT" commit -qm "fix: the value, with its test"; git -C "$WT" push -q origin "tkt-401/work"
driver_state_set 401 repair_base "$(git -C "$WT" rev-parse HEAD)"; HEAD401=$(git -C "$WT" rev-parse HEAD)
prs 401 CLEAN "$LESSON_CHECK"
want "before the repair the lesson check is red on the body" "lesson: this is a fix pull request" "$(judge_body 401 | cut -c1-34)"
answer "$(lesson_only "$(lesson value401.test.sh)")"
out=$(driver_step_repair 401 2>&1); rc=$?
want "a lesson-only repair finishes"          "0" "$rc"
want "after one model call"                   "repair" "$(cat "$CLAUDE_LOG")"
want "with nothing committed"                 "$HEAD401" "$(git -C "$WT" rev-parse HEAD)"
want_in "the lesson check reached the brief"  'red \(Every fix ships a lesson\)' "$(cat "$FIX/claude-stdin-repair.txt")"
want_in "the body was written by the REST API" 'api -X PATCH repos/acme/widgets/pulls/401 -F body=@' "$(cat "$GH_LOG")"
want_in "the body names the diff's guard"     '^- Guard: `value401.test.sh`$' "$(cat "$FIX/gh/body-401.md")"
want_in "and keeps its own words"             '^Fixes the value\.$' "$(cat "$FIX/gh/body-401.md")"
want "the section sits above the closing line" "## Lesson" "$(grep -E '^## Lesson|Generated with' "$FIX/gh/body-401.md" | head -1)"
want_in "the step says it counted it"         'wrote the lesson into PR #401.*lesson: complete' "$out"
want_in "the lesson check is green on the body now" '^lesson: complete' "$(judge_body 401)"

echo "--- a fix with no test: the repair adds one, proves it, and the lesson names it (#332) ---"
setup 402; lesson_body 402
printf 'value=good\n' > "$WT/value402.txt"; git -C "$WT" commit -qam "fix: the value, no test" 2>/dev/null || { git -C "$WT" add . && git -C "$WT" commit -qm "fix: the value, no test"; }
git -C "$WT" push -q origin "tkt-402/work"; driver_state_set 402 repair_base "$(git -C "$WT" rev-parse HEAD)"
prs 402 CLEAN "$LESSON_CHECK"
printf '#!/usr/bin/env bash\ngrep -q good value402.txt\n' > "$WT/value402.test.sh"; printf 'value=bad\n' > "$WT/value402.txt"
git -C "$WT" add . && git -C "$WT" commit -qm "test: the value, the fix reverted"; TS=$(git -C "$WT" rev-parse HEAD)
printf 'value=good\n' > "$WT/value402.txt"; git -C "$WT" commit -qam "fix: the value restored"; IS=$(git -C "$WT" rev-parse HEAD)
answer "$(jq -c --argjson f "$(test_fix "$TS" "$IS" value402.test.sh 'bash value402.test.sh')" --argjson l "$(lesson value402.test.sh)" '.fixes = [$f] | .lesson = $l' <<<"$(lesson_only '{}')")"
out=$(driver_step_repair 402 2>&1); rc=$?
want "it finishes"                            "0" "$rc"
want_in "the added guard is proved"           'red .* then green' "$out"
want_in "and the body names it"               '^- Guard: `value402.test.sh`$' "$(cat "$FIX/gh/body-402.md")"
want_in "the lesson check is green on the body now" '^lesson: complete' "$(judge_body 402)"

echo "--- a lesson naming a guard that is not there is never written (#332) ---"
setup 403; lesson_body 403
printf 'value=good\n' > "$WT/value403.txt"; git -C "$WT" add . && git -C "$WT" commit -qm "fix: the value, no test"
git -C "$WT" push -q origin "tkt-403/work"; driver_state_set 403 repair_base "$(git -C "$WT" rev-parse HEAD)"
prs 403 CLEAN "$LESSON_CHECK"
answer "$(lesson_only "$(lesson value403.test.sh)")"
out=$(driver_step_repair 403 2>&1); rc=$?
want "it refuses"                             "24" "$rc"
want_in "naming the missing guard"            'value403.test.sh. as its guard, and that is neither in PR #403' "$out"
want_not_in "the body is not written"         'PATCH repos/acme/widgets/pulls/403' "$(cat "$GH_LOG")"
want_not_in "and carries no lesson"           '## Lesson' "$(cat "$FIX/gh/body-403.md")"

echo "--- a red lesson check answered with code alone is asked again, then refused (#332) ---"
setup 404; lesson_body 404; prs 404 CLEAN "$LESSON_CHECK"
printf 'ok\n' > "$WT/lint.state"; printf 'x\n' > "$WT/touch404"; git -C "$WT" add . && git -C "$WT" commit -qm "fix: lint"
answer "$(repaired "$(gate_fix 'bash lint.sh')")"
out=$(driver_step_repair 404 2>&1); rc=$?
want "it refuses"                             "24" "$rc"
want "the model was asked twice"              "repair repair" "$(tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//')"
want_in "the second ask names the lesson"     'only a lesson in the PR body turns it green' "$(cat "$FIX/claude-stdin-repair.txt")"
want_not_in "the body is not written"         'PATCH repos/acme/widgets/pulls/404' "$(cat "$GH_LOG")"
export SWARM_GH="$SWARM_GH_WAS"

exit $FAILED
