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
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
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

echo "--- a fix answered only by the branch's earlier commit: asked once more, then refused ---"
setup 303; prs 303 CLEAN unit
BASE=$(driver_state_get 303 repair_base)
git -C "$WT" commit -q --allow-empty -m "fix: something"
answer "$(repaired "$(test_fix "$BASE" "$(git -C "$WT" rev-parse HEAD~1)" value303.txt 'true')")"
out=$(driver_step_repair 303 2>&1); rc=$?
want "it refuses"                      "24" "$rc"
want "the model was asked twice"       "repair repair" "$(tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//')"
want_in "the second ask names the earlier round" "an earlier round's, proved then" "$(cat "$FIX/claude-stdin-repair.txt")"
want_in "and the refusal says so"      "every fix it named is an earlier round's" "$out"
want_not_in "it was never re-proved"   'red .* then green' "$out"

echo "--- a fix commit that is on neither the branch nor this round is refused (#12858) ---"
setup 391; prs 391 CLEAN unit
git -C "$WT" commit -q --allow-empty -m "fix: something"
TRUNK0=$(git -C "$REPO" rev-list --max-parents=0 develop)
answer "$(repaired "$(test_fix "$TRUNK0" "$TRUNK0" value391.txt 'true')")"
out=$(driver_step_repair 391 2>&1); rc=$?
want "a trunk commit is refused"       "24" "$rc"
want "at once, with no second ask"     "repair" "$(cat "$CLAUDE_LOG")"
want_in "naming the commit"            'not a commit this repair made' "$out"
want "and the park note keeps its words" "a repair fix named a commit that is not this repair's own" "$(driver_state_get 391 park_note)"
setup 392; prs 392 CLEAN unit
git -C "$WT" commit -q --allow-empty -m "fix: something"
answer "$(repaired "$(test_fix 0123456789abcdef0123456789abcdef01234567 0123456789abcdef0123456789abcdef01234567 value392.txt 'true')")"
out=$(driver_step_repair 392 2>&1); rc=$?
want "a commit that does not exist is refused" "24" "$rc"
want_in "naming it"                    'not a commit this repair made' "$out"

echo "--- this round's proved pair beside an earlier round's: the earlier one is noted, not refused (#12858) ---"
setup 393; prs 393 CLEAN unit
printf '#!/usr/bin/env bash\ngrep -q mended old393.txt\n' > "$WT/old393.test.sh"
git -C "$WT" add . && git -C "$WT" commit -qm "test: an earlier round's"; OTS=$(git -C "$WT" rev-parse HEAD)
printf 'mended\n' > "$WT/old393.txt"; git -C "$WT" add . && git -C "$WT" commit -qm "fix: an earlier round's"; OIS=$(git -C "$WT" rev-parse HEAD)
driver_state_set 393 repair_base "$OIS"
printf '#!/usr/bin/env bash\ngrep -q good value393.txt\n' > "$WT/value393.test.sh"
git -C "$WT" add . && git -C "$WT" commit -qm "test: the value"; TS=$(git -C "$WT" rev-parse HEAD)
printf 'value=good\n' > "$WT/value393.txt"; git -C "$WT" add . && git -C "$WT" commit -qm "fix: the value"; IS=$(git -C "$WT" rev-parse HEAD)
answer "$(repaired "$(test_fix "$OTS" "$OIS" old393.test.sh 'bash old393.test.sh'),$(test_fix "$TS" "$IS" value393.test.sh 'bash value393.test.sh')")"
out=$(driver_step_repair 393 2>&1); rc=$?
want "it finishes"                     "0" "$rc"
want "the model was called once"       "repair" "$(cat "$CLAUDE_LOG")"
want_in "this round's fix is proved"   'red .* then green' "$out"
want_in "the earlier pair is noted"    "$(printf '%s' "$OIS" | cut -c1-10) is on the branch from before this repair started .*proved in an earlier round" "$out"
want_in "and counted apart"            '1 fix\(es\), each proved, 1 from an earlier round noted' "$out"

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

echo "--- a red on a branch behind the trunk merges the trunk first, never asks (#13285) ---"
setup 361; trunk_moves trunk361.txt "trunk work 361"; prs 361 CLEAN unit
out=$(driver_step_repair 361 2>&1); rc=$?
want "it finishes"                     "0" "$rc"
want "no model was called"             "" "$(cat "$CLAUDE_LOG")"
want "the trunk is now in the branch"  "yes" "$(git -C "$WT" merge-base --is-ancestor origin/develop HEAD && echo yes)"
want "with no question for anyone"     "" "$(driver_state_get 361 park_note)"

echo "--- the model asking 'merge develop?' is a yes: merged, re-run, no owner park ---"
setup 362; trunk_moves trunk362.txt "trunk work 362"; prs 362 CLEAN
driver_state_set 362 repair_brief_source caller
fix_ai repair '{"step":"repair","skills":["superpowers:systematic-debugging"],"status":"park","question":"The branch base predates develop'"'"'s changes to ci.yml. Merge origin/develop and re-run, yes/no?"}' "superpowers:systematic-debugging"
out=$(driver_step_repair 362 2>&1); rc=$?
want "it does not ask"                 "0" "$rc"
want "the trunk is now in the branch"  "yes" "$(git -C "$WT" merge-base --is-ancestor origin/develop HEAD && echo yes)"
want "the tree is clean"               "" "$(git -C "$WT" status --porcelain)"
want "with no question for anyone"     "" "$(driver_state_get 362 park_note)$(driver_state_get 362 park_cause)"
setup 363; prs 363 CLEAN; driver_state_set 363 repair_brief_source caller
fix_ai repair '{"step":"repair","skills":["superpowers:systematic-debugging"],"status":"park","question":"Merge origin/develop and re-run, yes/no?"}' "superpowers:systematic-debugging"
out=$(driver_step_repair 363 2>&1); rc=$?
want "with the trunk already in, the same question still parks" "20" "$rc"

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

echo "--- an adopted draft: the model reads the adoption brief; unchanged goes on to the gates ---"
setup 3640; prs 3640 CLEAN; driver_state_set 3640 repair_brief_source adopt
printf 'Adopted: #3640 has an open pull request that is a draft the driver did not build.\n' > "$(driver_state_dir 3640)/repair-brief.md"
driver_state_set 3640 repair_brief "$(driver_state_dir 3640)/repair-brief.md"
: > "$CLAUDE_LOG"
fix_ai repair '{"step":"repair","skills":["superpowers:systematic-debugging"],"status":"unchanged","reason":"the draft already meets the acceptance"}' superpowers:systematic-debugging
out=$(driver_step_repair 3640 2>&1); rc=$?
want "the model was called on a green, clean draft" "repair" "$(cat "$CLAUDE_LOG")"
want_in "with the adoption brief"          'Adopted: #3640' "$(cat "$FIX/claude-stdin-repair.txt")"
want "unchanged carries on to self-check and the whole-PR review, never asked of a person" "0" "$rc"
want "and parks nothing"                   "" "$(driver_state_get 3640 park_note)"
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

echo "--- unchanged, and GitHub agrees nothing is owed: a clean no-op, never the owner's question ---"
# #13636: "head 7a636eb4bd already contains origin/develop, GitHub reports MERGEABLE, no
# check is red. This step committed nothing. Should the PR ship as it is?" went to the
# owner. Every half of that is a read the driver makes itself, afresh, not the model's word.
pr_view() { # <ticket> <mergeable> <auto: 1|0> [red-check-name] — the PR as a fresh read sees it
  : > "$FIX/pr-created-$1"
  jq -n --arg h "$(git -C "$WT" rev-parse HEAD)" --arg g "$2" --arg a "$3" --arg f "${4:-}" \
    '{headRefOid:$h, mergeable:$g, isDraft:false,
      autoMergeRequest:(if $a == "1" then {mergeMethod:"SQUASH"} else null end),
      statusCheckRollup:([{name:"unit", status:"COMPLETED", conclusion:"SUCCESS"}, {name:"e2e", status:"IN_PROGRESS", conclusion:""}]
        + (if $f == "" then [] else [{name:$f, status:"COMPLETED", conclusion:"FAILURE"}] end))}' > "$FIX/gh/pr-view.json"
}
noop_case() { # <ticket> — a caller's brief, a clean PR, and the model answers unchanged
  setup "$1"; prs_m "$1" CLEAN MERGEABLE; driver_state_set "$1" repair_brief_source caller
  printf 'The owner asked: fix the clash.\n' > "$(driver_state_dir "$1")/repair-brief.md"
  fix_ai repair '{"step":"repair","skills":["superpowers:systematic-debugging"],"status":"unchanged","reason":"the clash is already fixed; nothing to commit"}' superpowers:systematic-debugging
  : > "$GH_LOG"
}
noop_case 341; pr_view 341 MERGEABLE 1
out=$(driver_step_repair 341 2>&1); rc=$?
want "up to date, mergeable, nothing red, armed: the run ends clean" "32" "$rc"
want "with no question for anyone"         "" "$(driver_state_get 341 park_note)"
want "and no person's cause"               "" "$(driver_state_get 341 park_cause)"
want_in "it says there is nothing to repair" 'nothing to repair' "$out"
want_in "and the PR says what was checked"  'pr comment 341 .*nothing to repair' "$(tr '\n' ' ' < "$GH_LOG")"

noop_case 342; prs_m 342 CLEAN MERGEABLE
jq '.[0].statusCheckRollup += [{name:"approval-gate", status:"COMPLETED", conclusion:"FAILURE"}]' "$FIX/gh/prs.json" > "$FIX/gh/prs.json.t" && mv "$FIX/gh/prs.json.t" "$FIX/gh/prs.json"
pr_view 342 MERGEABLE 1 approval-gate
out=$(driver_step_repair 342 2>&1); rc=$?
want "a red check on the head (the sign-off hold) still asks" "20" "$rc"
want_in "the question as before"           'should the PR ship as it is' "$(driver_state_get 342 park_note)"
want "a person's"                          "person" "$(driver_state_get 342 park_cause)"
want_in "and the log names what failed"    'approval-gate' "$out"

noop_case 343; pr_view 343 MERGEABLE 1 unit
out=$(driver_step_repair 343 2>&1); rc=$?
want "a check red on the fresh read, green on the shared copy, still asks" "20" "$rc"

noop_case 344; trunk_moves trunk336.txt "trunk moved on"; pr_view 344 MERGEABLE 1
out=$(driver_step_repair 344 2>&1); rc=$?
want "behind the base: still asks"         "20" "$rc"
want_in "naming the base it lacks"         'does not contain origin/develop' "$out"

noop_case 345; pr_view 345 MERGEABLE 0
out=$(driver_step_repair 345 2>&1); rc=$?
want "auto-merge not armed: still asks"    "20" "$rc"

noop_case 346; pr_view 346 UNKNOWN 1
out=$(driver_step_repair 346 2>&1); rc=$?
want "mergeable not yet MERGEABLE: still asks" "20" "$rc"

noop_case 347; pr_view 347 MERGEABLE 1; git -C "$WT" commit -q --allow-empty -m "local only"
driver_state_set 347 repair_base "$(git -C "$WT" rev-parse HEAD)"
jq --arg h "$(git -C "$WT" rev-parse HEAD~1)" '.headRefOid = $h' "$FIX/gh/pr-view.json" > "$FIX/gh/pr-view.json.t" && mv "$FIX/gh/pr-view.json.t" "$FIX/gh/pr-view.json"
out=$(driver_step_repair 347 2>&1); rc=$?
want "the PR's head is not the tree's: still asks" "20" "$rc"
want_in "naming the head"                  'is not this tree head' "$out"

noop_case 348; rm -f "$FIX/pr-created-348"
out=$(driver_step_repair 348 2>&1); rc=$?
want "the PR cannot be read afresh: still asks" "20" "$rc"

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
printf '#!/usr/bin/env bash\necho $#\n' > "$FIX/argc"; chmod +x "$FIX/argc"
sed "s#$BIN/gh#$FIX/argc#" "$(driver_state_dir 321)/steps/.driver-shim/gh" > "$FIX/shim-argc"
want "the gh shim hands each argument through whole" "3" "$(bash "$FIX/shim-argc" api x 'a filter | with spaces')"
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

echo "--- an evidence gap while its check is report-only until the release: a warning, not a refusal ---"
# #13305 and #13362 (2026-10-22) parked on exit 24 over approved-picture shots while
# "Design critic" and "Approved picture" sat in release.nonBlockingChecks: the CI red
# warned, and the repair derived the same gaps as tasks of its own.
CFGF="$REPO/.claude/harness.json"; cp "$CFGF" "$FIX/cfg.nb-orig"
cfg_release() { jq --argjson l "$1" --argjson d "$2" '.release = {nonBlockingChecks: $l, done: $d}' "$FIX/cfg.nb-orig" > "$CFGF"; }
EV_ONLY='evidence gap: the approved picture declares today-laptop-light (/today, laptop, light) and CI pinned no shot of it — nobody saw it'
ev_only_case() { # <ticket> — nothing red, one evidence gap, a code-only answer if asked
  setup "$1"; prs "$1" CLEAN; printf '%s\n' "$EV_ONLY" > "$FIX/ev-tasks"; : > "$GH_LOG"
  cat > "$FIX/ai/repair.sh" <<SH
printf 'value=good\n' > value$1.txt; git add . && git commit -qm "fix: code only"
SH
  answer "$(repaired "$(gate_fix 'bash lint.sh')")"
}
cfg_release '["Lesson / Every fix ships a lesson", "Design critic", "Approved picture"]' false
ev_only_case 374
out=$(driver_step_repair 374 2>&1); rc=$?
want "the only task an evidence gap, its check report-only: no refusal" "0" "$rc"
want "and no model is asked for it"                 "" "$(cat "$CLAUDE_LOG")"
want_in "the run log carries the warning"           'report-only until the release' "$out"
want_in "naming the gap"                            'today-laptop-light' "$out"
want "it is no owed task"                           "" "$(driver_state_get 374 evidence_tasks)"
want_in "the PR is told, report-only"               'issues/374/comments -X POST' "$(cat "$GH_LOG")"
want "and the park note is empty"                   "" "$(driver_state_get 374 park_note)"

cfg_release '["approved picture"]' false
ev_only_case 375
out=$(driver_step_repair 375 2>&1); rc=$?
want "one of the two names listed, any case, is enough" "0" "$rc"

cfg_release '["Lesson / Every fix ships a lesson", "Widths and contrast on changed routes"]' false
ev_only_case 376
out=$(driver_step_repair 376 2>&1); rc=$?
want "neither check listed: the gap is owed and a code-only repair is refused" "24" "$rc"
want_in "the park names the plan"                   'capture plan docs/evidence/376/plan.json is unchanged' "$(driver_state_get 376 park_note)"

cfg_release '["Design critic", "Approved picture"]' true
ev_only_case 377
out=$(driver_step_repair 377 2>&1); rc=$?
want "after the release (done:true) the gap blocks again" "24" "$rc"
# Plant: the report-only reading gone, the first case parks on exit 24 again.
cfg_release '["Lesson / Every fix ships a lesson", "Design critic", "Approved picture"]' false
( _driver_evidence_report_only() { return 1; }
  ev_only_case 378; out=$(driver_step_repair 378 2>&1); rc=$?
  [ "$rc" = 24 ] && echo flipped ) > "$FIX/plant-evnb" 2>&1
want "planted (no report-only reading): the evidence-gap-only repair is refused" "flipped" "$(tail -1 "$FIX/plant-evnb")"
cp "$FIX/cfg.nb-orig" "$CFGF"; rm -f "$FIX/ev-tasks"
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
    # The PR as GitHub answers it; the caller's --jq picks the body out.
    q=""; prev=""; for a in "$@"; do case "$prev" in -q|--jq) q="$a" ;; esac; prev="$a"; done
    [ -f "$f" ] && jq -Rs '{number: 0, body: .}' "$f" | if [ -n "$q" ]; then jq -r "$q"; else cat; fi ;;
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

echo "--- a lesson red on an older head is re-run here on the body now and this tree (#13321) ---"
# The PR's head on GitHub is behind an earlier round's unpushed commits, and its lesson
# check run is red there. The body already carries a lesson whose guard this tree's diff
# has: run as CI runs it, the check passes, so "unchanged" is the right answer.
unchanged() { jq -nc '{step:"repair", skills:["superpowers:systematic-debugging"], status:"unchanged", reason:"the unpushed commits are the repair"}'; }
with_lesson_body() { # <ticket>
  { printf 'Fixes the value.\n\n## Lesson\n'
    printf -- '- Principle: a value written without a check that reads it back ships wrong\n'
    printf -- '- Guard: `value%s.test.sh`\n' "$1"
    printf -- '- Before/after: the guard fails on the bad value and passes on the good one\n'
    printf -- '- Reach: every value file this repo writes, by the same grep\n\n'
    printf '🤖 Generated with [Claude Code](https://claude.com/claude-code)\n'; } > "$FIX/gh/body-$1.md"
}
stale_head() { # <ticket> — the PR head is the pushed commit; two unpushed commits ride on top
  local t=$1
  printf 'value=good\n' > "$WT/value$t.txt"; git -C "$WT" add . && git -C "$WT" commit -qm "fix: the value"
  git -C "$WT" push -q origin "tkt-$t/work"; PRHEAD=$(git -C "$WT" rev-parse HEAD)
  printf '#!/usr/bin/env bash\ngrep -q good value%s.txt\n' "$t" > "$WT/value$t.test.sh"
  git -C "$WT" add . && git -C "$WT" commit -qm "test: the value"
  printf 'x\n' > "$WT/more$t.txt"; git -C "$WT" add . && git -C "$WT" commit -qm "fix: an earlier round, never pushed"
  driver_state_set "$t" repair_base "$PRHEAD"; driver_state_set "$t" repair_brief_source caller
  jq -n --argjson n "$t" --arg b "tkt-$t/work" --arg h "$PRHEAD" --arg f "$LESSON_CHECK" \
    '[{number:$n, headRefName:$b, headRefOid:$h, isDraft:false, mergeStateStatus:"CLEAN",
       statusCheckRollup:[{name:$f, status:"COMPLETED", conclusion:"FAILURE"}]}]' > "$FIX/gh/prs.json"
}
setup 405; with_lesson_body 405; stale_head 405; HEAD405=$(git -C "$WT" rev-parse HEAD)
answer "$(unchanged)"
out=$(driver_step_repair 405 2>&1); rc=$?
want "an unchanged answer is accepted"        "0" "$rc"
want_in "the lesson red is re-run, not owed"  "Every fix ships a lesson' reads red on GitHub.*it passes \(lesson: complete" "$out"
want "the model was asked once"               "repair" "$(cat "$CLAUDE_LOG")"
want_not_in "and never told the lesson is red" 'red \(Every fix ships a lesson\)' "$(cat "$FIX/claude-stdin-repair.txt")"
want "nothing was committed"                  "$HEAD405" "$(git -C "$WT" rev-parse HEAD)"
want_not_in "the body is not rewritten"       'PATCH repos/acme/widgets/pulls/405' "$(cat "$GH_LOG")"

setup 406; lesson_body 406; stale_head 406
answer "$(unchanged)"
out=$(driver_step_repair 406 2>&1); rc=$?
want "with no lesson in the body it still refuses" "24" "$rc"
want_not_in "the lesson red is not waved off"  "reads red on GitHub" "$out"
want_in "and the lesson is still demanded"    'red \(Every fix ships a lesson\)' "$(cat "$FIX/claude-stdin-repair.txt")"
echo "--- a superseded CANCELLED run is not red: a lesson-only repair still passes (#13629) ---"
setup 407; lesson_body 407
printf '#!/usr/bin/env bash\ngrep -q good value407.txt\n' > "$WT/value407.test.sh"; printf 'value=good\n' > "$WT/value407.txt"
git -C "$WT" add . && git -C "$WT" commit -qm "fix: the value, with its test"; git -C "$WT" push -q origin "tkt-407/work"
driver_state_set 407 repair_base "$(git -C "$WT" rev-parse HEAD)"; HEAD407=$(git -C "$WT" rev-parse HEAD)
jq -n --arg l "$LESSON_CHECK" '[{number:407, headRefName:"tkt-407/work", headRefOid:"x", isDraft:false, mergeStateStatus:"CLEAN",
  statusCheckRollup:[{name:"Deleted tests", status:"COMPLETED", conclusion:"CANCELLED", startedAt:"2026-10-21T04:04:27Z"},
    {name:$l, status:"COMPLETED", conclusion:"CANCELLED", startedAt:"2026-10-21T04:04:27Z"},
    {name:"Deleted tests", status:"COMPLETED", conclusion:"SUCCESS", startedAt:"2026-10-21T04:05:35Z"},
    {name:$l, status:"COMPLETED", conclusion:"FAILURE", startedAt:"2026-10-21T04:05:44Z"}]}]' > "$FIX/gh/prs.json"
answer "$(lesson_only "$(lesson value407.test.sh)")"
out=$(driver_step_repair 407 2>&1); rc=$?
want "a lesson-only repair finishes"          "0" "$rc"
want "with nothing committed"                 "$HEAD407" "$(git -C "$WT" rev-parse HEAD)"
want_in "the body names the diff's guard"     '^- Guard: `value407.test.sh`$' "$(cat "$FIX/gh/body-407.md")"
want_in "the lesson check is green on the body now" '^lesson: complete' "$(judge_body 407)"
want_not_in "the cancelled run never reached the brief" 'Deleted tests' "$(cat "$FIX/claude-stdin-repair.txt")"

export SWARM_GH="$SWARM_GH_WAS"

echo "--- a repair tree whose own install lacks a declared package: relinked before its proof (#12442) ---"
# The shared clone installs @axe-core/playwright; the repair worktree has a private install
# made before its lockfile gained it. The proof trees link from the worktree.
printf 'node_modules\n' >> "$REPO/.git/info/exclude"
AXLOCK='{"lockfileVersion":3,"packages":{"":{},"node_modules/@axe-core/playwright":{"version":"4.0.0"}}}'
printf '{"name":"fx","private":true}\n' > "$REPO/package.json"; printf '%s\n' "$AXLOCK" > "$REPO/package-lock.json"
mkdir -p "$REPO/node_modules/@axe-core/playwright"; printf '%s\n' "$AXLOCK" > "$REPO/node_modules/.package-lock.json"
printf '[]\n' > "$FIX/claims.json"
printf '#!/bin/sh\ncat "%s"\n' "$FIX/claims.json" > "$FIX/claim-list"; printf '#!/bin/sh\n:\n' > "$FIX/claim-refs"
chmod +x "$FIX/claim-list" "$FIX/claim-refs"
export WT_CLAIM_LIST="$FIX/claim-list" WT_CLAIM_REFS="$FIX/claim-refs"
behind_repair() { # <ticket> — a red PR whose tree's private install lacks the package its test imports
  local t=$1
  setup "$t"; prs "$t" CLEAN unit
  cp "$REPO/package.json" "$REPO/package-lock.json" "$WT/"; git -C "$WT" add package.json package-lock.json; git -C "$WT" commit -qm "deps"
  driver_state_set "$t" repair_base "$(git -C "$WT" rev-parse HEAD)"
  mkdir -p "$WT/node_modules/left-pad"; printf '{"lockfileVersion":3,"packages":{}}\n' > "$WT/node_modules/.package-lock.json"
  printf '#!/usr/bin/env bash\ntest -e node_modules/@axe-core/playwright || { echo "Error: Cannot find module '"'"'@axe-core/playwright'"'"'"; exit 1; }\ngrep -q good value%s.txt\n' "$t" > "$WT/ax$t.test.sh"
  git -C "$WT" add . && git -C "$WT" commit -qm "test: the value"; TS=$(git -C "$WT" rev-parse HEAD)
  printf 'value=good\n' > "$WT/value$t.txt"; git -C "$WT" add . && git -C "$WT" commit -qm "fix: the value"; IS=$(git -C "$WT" rev-parse HEAD)
  answer "$(repaired "$(test_fix "$TS" "$IS" "ax$t.test.sh" "bash ax$t.test.sh")")"
}
behind_repair 461
want "the tree is behind before the repair" "0" "$(bash "$KIT_ROOT/scripts/link-node-modules.sh" --behind "$WT" >/dev/null 2>&1; echo $?)"
out=$(DRIVER_TICKET=461 driver_step_repair 461 2>&1); rc=$?
want "the repair finishes"                    "0" "$rc"
want_in "the fix is proved"                   'red .* then green' "$out"
want_in "it says the install was relinked"    'install: .* relinking it to the shared install' "$out"
want_not_in "before the proof, not after a failed one" 'taken once more' "$out"
want "the tree is linked from the shared install" "yes" "$([ -f "$WT/node_modules/.linked-from-shared-install" ] && echo yes || echo no)"
W461="$WT"

echo "--- …held by another run, it cannot be relinked: a machine fault, back on the queue, never 'not proved' ---"
behind_repair 462
printf '[{"issue":"999","worktree":"%s","branch":"","host":"elsewhere"}]\n' "$(cd "$WT" && pwd -P)" > "$FIX/claims.json"
out=$(DRIVER_TICKET=462 driver_step_repair 462 2>&1); rc=$?
want "back on the queue, not refused"         "29" "$rc"
want_in "named a machine fault"               'machine fault, not the change: the proof failed on a missing module' "$out"
want_not_in "never 'not proved'"              'not proved red-then-green' "$(driver_state_get 462 park_note)"
W462="$WT"

echo "--- …and a missing module the install is not behind on is still the change's ---"
behind_repair 463; printf '[]\n' > "$FIX/claims.json"
bash "$KIT_ROOT/scripts/link-node-modules.sh" "$REPO" "$WT" >/dev/null 2>&1
printf '#!/usr/bin/env bash\necho "Error: Cannot find module '"'"'not-declared'"'"'"; exit 1\n' > "$FIX/nd.sh"
answer "$(repaired "$(test_fix "$TS" "$IS" "ax463.test.sh" "bash $FIX/nd.sh")")"
out=$(DRIVER_TICKET=463 driver_step_repair 463 2>&1); rc=$?
want "refused as the change's"                "24" "$rc"
want_not_in "not called a machine fault"      'machine fault' "$out"

echo "--- a file the trunk deleted is taken by the driver; the model never runs git rm (#13139, #12975) ---"
TRIGGERS='.deploy-trigger apps/api/.deploy-trigger apps/web/.deploy-trigger'
triggers_in() { # <ticket> — the sentinel files on the trunk, before the branch is cut
  mkdir -p "$REPO/apps/api" "$REPO/apps/web"
  for f in $TRIGGERS; do printf 'bump %s\n' "$1" > "$REPO/$f"; done
  git -C "$REPO" add -f $TRIGGERS && git -C "$REPO" commit -qm "trunk: sentinels $1" && git -C "$REPO" push -q origin develop
}
triggers_retired() { git -C "$REPO" rm -q $TRIGGERS && git -C "$REPO" commit -qm "retire the deploy sentinel files" && git -C "$REPO" push -q origin develop; }
gone_at_head() { local f o=""; for f in $TRIGGERS; do git -C "$WT" cat-file -e "HEAD:$f" 2>/dev/null && o="$o$f "; done; printf '%s' "$o"; }
take_answer() { # <paths-json> [conflicts-json]
  repaired "$(gate_fix 'bash lint.sh')" "${2:-[]}" | jq -c --argjson d "$1" '. + {takeBaseDeletions:$d}'
}
# #13139: the branch only appended bump lines; the model's mode refuses git rm, so it lists them.
triggers_in 13139; setup 13139
for f in $TRIGGERS; do printf 'bump again\n' >> "$WT/$f"; done; git -C "$WT" commit -qam "chore: bump deploy"
driver_state_set 13139 repair_base "$(git -C "$WT" rev-parse HEAD)"
triggers_retired; prs 13139 DIRTY
answer "$(take_answer '[".deploy-trigger","apps/api/.deploy-trigger","apps/web/.deploy-trigger"]' '[{"file":".deploy-trigger","resolution":"took develop'"'"'s deletion"}]')"
out=$(driver_step_repair 13139 2>&1); rc=$?
want "13139: it finishes"                      "0" "$rc"
want_in "13139: the brief tells the model to list them" 'takeBaseDeletions' "$(cat "$FIX/claude-stdin-repair.txt")"
want_in "13139: and when to take the deletion"  'only served that retired purpose' "$(cat "$FIX/claude-stdin-repair.txt")"
want "13139: the driver removed all three"      "" "$(gone_at_head)"
want "13139: the merge is finished"             "yes" "$([ ! -f "$(git -C "$WT" rev-parse --git-path MERGE_HEAD)" ] && git -C "$WT" merge-base --is-ancestor origin/develop HEAD && echo yes)"
want "13139: the tree is clean"                 "" "$(git -C "$WT" status --porcelain)"
# #12975: the branch edited the sentinels and a real file conflicts too; the model resolves
# the file, stages it, and lists the sentinels.
triggers_in 12975; setup 12975
printf 'branch line\n' > "$WT/shared.txt"
for f in $TRIGGERS; do printf 'edited by the branch\n' > "$WT/$f"; done; git -C "$WT" commit -qam "feat: our line, and deploy edits"
driver_state_set 12975 repair_base "$(git -C "$WT" rev-parse HEAD)"
trunk_moves shared.txt "trunk line 12975"; triggers_retired; prs 12975 DIRTY
printf '%s\n' 'printf "trunk line 12975\nbranch line\n" > shared.txt; git add shared.txt' > "$FIX/ai/repair.sh"
answer "$(take_answer '[".deploy-trigger","apps/api/.deploy-trigger","apps/web/.deploy-trigger"]' '[{"file":"shared.txt","resolution":"both lines kept"}]')"
out=$(driver_step_repair 12975 2>&1); rc=$?
want "12975: it finishes"                       "0" "$rc"
want "12975: the sentinels are gone"            "" "$(gone_at_head)"
want "12975: both sides of the real file kept"  "trunk line 12975 branch line" "$(git -C "$WT" show HEAD:shared.txt | tr '\n' ' ' | sed 's/ $//')"
want "12975: the merge is finished"             "yes" "$([ ! -f "$(git -C "$WT" rev-parse --git-path MERGE_HEAD)" ] && git -C "$WT" merge-base --is-ancestor origin/develop HEAD && echo yes)"
# A sentinel the branch never changed, left conflicted by an earlier pass: no model at all.
triggers_in 13140; setup 13140; triggers_retired; prs 13140 CLEAN
git -C "$WT" fetch -q origin; git -C "$WT" merge -q --no-commit --no-ff origin/develop >/dev/null 2>&1
mb=$(git -C "$WT" merge-base HEAD MERGE_HEAD)
for f in $TRIGGERS; do
  bl=$(git -C "$WT" rev-parse "$mb:$f")
  printf '100644 %s 1\t%s\n100644 %s 2\t%s\n' "$bl" "$f" "$bl" "$f" | git -C "$WT" update-index --index-info
  mkdir -p "$(dirname "$WT/$f")"; git -C "$WT" show "$mb:$f" > "$WT/$f"
done
want "13140: the fixture conflicts on the sentinels" "3" "$(git -C "$WT" diff --name-only --diff-filter=U | wc -l | tr -d ' ')"
out=$(driver_step_repair 13140 2>&1); rc=$?
want "13140: it finishes"                       "0" "$rc"
want "13140: no model was asked"                "" "$(cat "$CLAUDE_LOG")"
want "13140: the driver took the deletion"      "" "$(gone_at_head)"
want "13140: the merge is finished"             "yes" "$([ ! -f "$(git -C "$WT" rev-parse --git-path MERGE_HEAD)" ] && git -C "$WT" merge-base --is-ancestor origin/develop HEAD && echo yes)"
# A listed path the trunk never deleted is refused, and nothing is removed.
setup 13141
printf 'branch line\n' > "$WT/shared.txt"; git -C "$WT" commit -qam "feat: our line"
driver_state_set 13141 repair_base "$(git -C "$WT" rev-parse HEAD)"
trunk_moves shared.txt "trunk line 13141"; prs 13141 DIRTY
printf '%s\n' 'printf "trunk line 13141\nbranch line\n" > shared.txt; git add shared.txt' > "$FIX/ai/repair.sh"
answer "$(take_answer '["value13141.txt"]' '[{"file":"shared.txt","resolution":"both lines kept"}]')"
out=$(driver_step_repair 13141 2>&1); rc=$?
want "13141: it refuses"                        "24" "$rc"
want_in "13141: naming the path"                'not deleted on the trunk' "$out"
want "13141: the branch's file is still there"  "yes" "$([ -f "$WT/value13141.txt" ] && git -C "$WT" ls-files --error-unmatch value13141.txt >/dev/null 2>&1 && echo yes)"
git -C "$WT" merge --abort 2>/dev/null

echo "--- git steps the model's mode refuses are run by the driver, checked first (#12840, #13139, #13305, #13356) ---"
ga() { jq -nc --argjson a "$1" '{gitActions:$a}' > "$FIX/ga.json"; }
# #13139's third park: resolved, but `git commit --no-edit` refused. The model edits the
# file, stages nothing, commits nothing, and lists commitMerge.
merge_answer() { repaired "$(gate_fix 'bash lint.sh')" '[{"file":"shared.txt","resolution":"both lines kept"}]' | jq -c '. + {gitActions:[{action:"commitMerge"}]}'; }
merge_case() { # <ticket> <hands> — a branch and trunk that both change shared.txt, merging
  setup "$1"
  printf 'branch line\n' > "$WT/shared.txt"; git -C "$WT" commit -qam "feat: our line"
  driver_state_set "$1" repair_base "$(git -C "$WT" rev-parse HEAD)"
  trunk_moves shared.txt "trunk line $1"; prs "$1" DIRTY
  printf '%s\n' "$2" > "$FIX/ai/repair.sh"
  answer "$(merge_answer)"
}
merge_done() { [ ! -f "$(git -C "$WT" rev-parse --git-path MERGE_HEAD)" ] && git -C "$WT" merge-base --is-ancestor origin/develop HEAD && echo yes; }
merge_case 13600 'printf "trunk line 13600\nbranch line\n" > shared.txt'
out=$(driver_step_repair 13600 2>&1); rc=$?
want "commitMerge: it finishes"                 "0" "$rc"
want_in "commitMerge: the driver made the commit" 'commitMerge — the driver finished the merge' "$out"
want "commitMerge: the merge is finished"       "yes" "$(merge_done)"
want "commitMerge: both sides kept"             "trunk line 13600 branch line" "$(git -C "$WT" show HEAD:shared.txt | tr '\n' ' ' | sed 's/ $//')"
want "commitMerge: it is a merge commit"        "3" "$(git -C "$WT" rev-list --parents -1 HEAD | wc -w | tr -d ' ')"
want_in "commitMerge: the brief names gitActions" 'gitActions' "$(cat "$FIX/claude-stdin-repair.txt")"
want_in "and says to resolve with Edit, not a script" 'with the Edit tool, never a script' "$(cat "$FIX/claude-stdin-repair.txt")"
# A marker left in: the driver stages nothing and commits nothing.
merge_case 13601 'true'
out=$(driver_step_repair 13601 2>&1); rc=$?
want "commitMerge with markers: refused"        "24" "$rc"
want_in "commitMerge with markers: says why"    'conflict markers are still in shared.txt' "$out"
want "commitMerge with markers: still merging"  "yes" "$([ -f "$(git -C "$WT" rev-parse --git-path MERGE_HEAD)" ] && echo yes)"
git -C "$WT" merge --abort 2>/dev/null

echo "--- a refused merge commit keeps git's words, and the same refusal twice is not retried ---"
# The commit's stderr was thrown away, so each run retried the same merge blind (14 times, 8 times).
merge_case 13610 'printf "trunk line 13610\nbranch line\n" > shared.txt'
HOOKS=$(git -C "$WT" rev-parse --git-path hooks); case "$HOOKS" in /*) ;; *) HOOKS="$WT/$HOOKS" ;; esac
mkdir -p "$HOOKS"; cp "$HOOKS/commit-msg" "$FIX/commit-msg.was" 2>/dev/null || rm -f "$FIX/commit-msg.was"
printf '#!/bin/sh\necho "subject may not be longer than 72 characters [header-max-length]" >&2\nexit 1\n' > "$HOOKS/commit-msg"; chmod +x "$HOOKS/commit-msg"
out=$(driver_step_repair 13610 2>&1); rc=$?
want "a refused merge commit: refused"          "24" "$rc"
want_in "  git's own words are in the log"      'commitMerge: git commit --no-edit failed: .*header-max-length' "$out"
want_in "  and in the park note"                'header-max-length' "$(driver_state_get 13610 park_note)"
want "  a first refusal is the driver's"        "" "$(driver_state_get 13610 park_cause)"
ga '[{"action":"commitMerge"}]'
out=$(driver_git_actions 13610 "$WT" "$FIX/ga.json" repair 2>&1); rc=$?
want "the same refusal again: refused"          "1" "$rc"
want_in "  says it is not retried"              'failed the same way as the last try, so it is not retried: .*header-max-length' "$out"
want "  parked for the PM, not the machine"     "pm" "$(driver_state_get 13610 park_cause)"
if [ -f "$FIX/commit-msg.was" ]; then mv "$FIX/commit-msg.was" "$HOOKS/commit-msg"; else rm -f "$HOOKS/commit-msg"; fi
driver_state_set 13610 park_cause ""
out=$(driver_git_actions 13610 "$WT" "$FIX/ga.json" repair 2>&1); rc=$?
want "once the cause is gone it commits"        "0" "$rc"
want "  and the failure is forgotten"           "" "$(driver_state_get 13610 commit_merge_fail)"

echo "--- a clash only on a generated tally file is recounted, with no model call ---"
# develop's most-edited files were generated baselines; each clash on one was a builder run.
setup 13620
printf 'branch\n' > "$WT/tally.txt"; git -C "$WT" add tally.txt; git -C "$WT" commit -qm "feat: branch tally"
driver_state_set 13620 repair_base "$(git -C "$WT" rev-parse HEAD)"
trunk_moves tally.txt "trunk"; prs 13620 DIRTY
jq '.merge.regenerate = [{path: "tally.txt", command: "ls value*.txt | wc -l | tr -d \" \" > tally.txt"}]' "$HARNESS_CFG" > "$FIX/cfg-regen.json"
: > "$CLAUDE_LOG"
out=$(HARNESS_CFG="$FIX/cfg-regen.json" driver_step_repair 13620 2>&1); rc=$?
want "it finishes"                               "0" "$rc"
want_in "  the tally is recounted"               'tally.txt — regenerated from the merged tree' "$out"
want "  no model call"                           "" "$(cat "$CLAUDE_LOG")"
want "  the merge is finished, the trunk in it"  "yes" "$([ ! -f "$(git -C "$WT" rev-parse --git-path MERGE_HEAD)" ] && git -C "$WT" merge-base --is-ancestor origin/develop HEAD && echo yes)"
want "  the tally is the merged tree's count"    "$(git -C "$WT" ls-files 'value*.txt' | grep -c .)" "$(git -C "$WT" show HEAD:tally.txt)"

echo "--- the model's own edit to a cleanly merged file goes into the merge (#13365) ---"
# The clean side of the merge doubled a key in package.json; the model fixed it,
# named it in its answer, and only the conflicted file was staged.
setup 13365
printf '{"scripts":{"a":"1"}}\n' > "$WT/package.json"; printf 'branch line\n' > "$WT/shared.txt"
git -C "$WT" add . && git -C "$WT" commit -qm "feat: our line"
driver_state_set 13365 repair_base "$(git -C "$WT" rev-parse HEAD)"
trunk_moves shared.txt "trunk line 13365"; prs 13365 DIRTY
printf '%s\n' 'printf "trunk line 13365\nbranch line\n" > shared.txt; printf "{\"scripts\":{}}\n" > package.json' > "$FIX/ai/repair.sh"
answer "$(merge_answer | jq -c '.fixes[0].change += [{path:"package.json", action:"modify"}]')"
out=$(driver_step_repair 13365 2>&1); rc=$?
want "13365: it finishes"                       "0" "$rc"
want "13365: the merge carries the model's package.json" '{"scripts":{}}' "$(git -C "$WT" show HEAD:package.json)"
want "13365: nothing is left uncommitted"       "" "$(git -C "$WT" status --porcelain)"
want_not_in "13365: no uncommitted refusal"     'uncommitted changes' "$out"

echo "--- a tool's rewrite of a tracked file the answer never names is put back, and kept (#13160) ---"
setup 13160
printf '# rules\n' > "$WT/AGENTS.md"; git -C "$WT" add . && git -C "$WT" commit -qm "docs: agents"
driver_state_set 13160 repair_base "$(git -C "$WT" rev-parse HEAD)"; prs 13160 CLEAN unit
printf '%s\n' 'printf "fixed\n" > fix13160.txt; git add fix13160.txt; git commit -qm "fix: lint"; printf "## rules\n" > AGENTS.md' > "$FIX/ai/repair.sh"
answer "$(repaired "$(gate_fix 'bash lint.sh')")"
out=$(driver_step_repair 13160 2>&1); rc=$?
want "13160: it finishes"                       "0" "$rc"
want "13160: the tool's edit is put back"       "# rules" "$(cat "$WT/AGENTS.md")"
want_in "13160: and it says so"                 'put back AGENTS.md' "$out"
want_in "13160: the change is kept as a patch"  '## rules' "$(cat "$(driver_state_dir 13160)"/steps/put-back-*.patch 2>/dev/null)"

echo "--- the model's own named edit, left uncommitted, is still refused ---"
setup 13161; prs 13161 CLEAN unit
printf '%s\n' 'printf "fixed\n" > fix13161.txt; git add fix13161.txt; git commit -qm "fix: lint"; printf "value=mine\n" > value13161.txt' > "$FIX/ai/repair.sh"
answer "$(repaired "$(gate_fix 'bash lint.sh' | jq -c '.change += [{path:"value13161.txt", action:"modify"}]')")"
out=$(driver_step_repair 13161 2>&1); rc=$?
want "13161: refused"                           "24" "$rc"
want_in "13161: as uncommitted"                 'uncommitted changes — value13161.txt' "$out"
want "13161: the model's edit is not discarded" "value=mine" "$(cat "$WT/value13161.txt")"

# resetTo and dropLocalCommits, at the helper: the branch pushed, then local commits.
setup 13305
printf 'a\n' > "$WT/a13305.txt"; git -C "$WT" add . && git -C "$WT" commit -qm "local a"; LA=$(git -C "$WT" rev-parse HEAD)
printf 'b\n' > "$WT/b13305.txt"; git -C "$WT" add . && git -C "$WT" commit -qm "local b"; LB=$(git -C "$WT" rev-parse HEAD)
TRUNK0=$(git -C "$REPO" rev-list --max-parents=0 develop)
OTHER=$(git -C "$REPO" commit-tree -p "$TRUNK0" -m "someone else's" "$(git -C "$REPO" rev-parse "$TRUNK0^{tree}")")
ga "[{\"action\":\"resetTo\",\"sha\":\"$TRUNK0\"}]"
out=$(driver_git_actions 13305 "$WT" "$FIX/ga.json" build 2>&1); rc=$?
want "resetTo a trunk commit: refused"          "1" "$rc"
want_in "resetTo a trunk commit: says why"      "not one of this branch's own commits" "$out"
want "resetTo a trunk commit: HEAD unmoved"     "$LB" "$(git -C "$WT" rev-parse HEAD)"
want_in "resetTo refused: the park note says so" 'git step it refuses' "$(driver_state_get 13305 park_note)"
ga "[{\"action\":\"resetTo\",\"sha\":\"$OTHER\"}]"
out=$(driver_git_actions 13305 "$WT" "$FIX/ga.json" build 2>&1); rc=$?
want "resetTo someone else's commit: refused"   "1" "$rc"
want "resetTo someone else's commit: HEAD unmoved" "$LB" "$(git -C "$WT" rev-parse HEAD)"
ga '[{"action":"resetTo","sha":"origin/develop"}]'
out=$(driver_git_actions 13305 "$WT" "$FIX/ga.json" build 2>&1); rc=$?
want "resetTo a ref name: refused"              "1" "$rc"
want_in "resetTo a ref name: says why"          'not a commit sha' "$out"
ga "[{\"action\":\"resetTo\",\"sha\":\"$LA\"}]"
out=$(driver_git_actions 13305 "$WT" "$FIX/ga.json" build 2>&1); rc=$?
want "resetTo an unpushed commit of its own: done" "0" "$rc"
want "resetTo: HEAD is there"                   "$LA" "$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" reset -q --hard "$LB"; git -C "$WT" push -q origin HEAD
printf 'c\n' > "$WT/c13305.txt"; git -C "$WT" add . && git -C "$WT" commit -qm "local c"
out=$(driver_git_actions 13305 "$WT" "$FIX/ga.json" build 2>&1); rc=$?
want "resetTo behind origin's head: refused"    "1" "$rc"
want_in "resetTo behind origin's head: says why" 'would drop pushed work' "$out"
ga "[{\"action\":\"resetTo\",\"sha\":\"$LB\"}]"
out=$(driver_git_actions 13305 "$WT" "$FIX/ga.json" build 2>&1); rc=$?
want "resetTo the branch's head on origin: done" "0" "$rc"
want "resetTo: HEAD is origin's"                "$LB" "$(git -C "$WT" rev-parse HEAD)"
# dropLocalCommits: a commit origin lacks is refused; one origin has as the same patch is dropped.
printf 'd\n' > "$WT/d13305.txt"; git -C "$WT" add . && git -C "$WT" commit -qm "local d"; LD=$(git -C "$WT" rev-parse HEAD)
ga '[{"action":"dropLocalCommits"}]'
out=$(driver_git_actions 13305 "$WT" "$FIX/ga.json" fix 2>&1); rc=$?
want "dropLocalCommits not on origin: refused"  "1" "$rc"
want_in "dropLocalCommits not on origin: names it" "not on origin, so not dropped: $(git -C "$WT" rev-parse --short=10 "$LD")" "$out"
want "dropLocalCommits not on origin: HEAD unmoved" "$LD" "$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" commit -q --amend -m "local d, as origin has it"; git -C "$WT" push -q origin HEAD
git -C "$WT" reset -q --hard "$LD"
out=$(driver_git_actions 13305 "$WT" "$FIX/ga.json" fix 2>&1); rc=$?
want "dropLocalCommits already on origin: done" "0" "$rc"
want "dropLocalCommits: HEAD is origin's"       "$(git -C "$WT" rev-parse "origin/tkt-13305/work")" "$(git -C "$WT" rev-parse HEAD)"
ga '[{"action":"rebase"}]'
out=$(driver_git_actions 13305 "$WT" "$FIX/ga.json" fix 2>&1); rc=$?
want "an action not in the set: refused"        "1" "$rc"

echo "--- plants: each guard out, its case fails ---"
# The relink before the proof gone (and so the retry's): the #461 case is never proved.
( driver_relink_if_behind() { DRIVER_BEHIND_WHY="planted"; return 1; }
  behind_repair 471; out=$(DRIVER_TICKET=471 driver_step_repair 471 2>&1); rc=$?
  [ "$rc" != 0 ] && echo flipped ) > "$FIX/plant1" 2>&1
want "planted (no relink): the behind tree is not proved" "flipped" "$(tail -1 "$FIX/plant1")"
# The proof read straight, without the machine-fault reading: the #462 case is "not proved".
printf '[{"issue":"999","worktree":"%s","branch":"","host":"elsewhere"}]\n' "$W462" > "$FIX/claims.json"
( driver_prove_red_green() { _driver_prove_red_green_once "$@"; }
  behind_repair 472
  printf '[{"issue":"999","worktree":"%s","branch":"","host":"elsewhere"}]\n' "$(cd "$WT" && pwd -P)" > "$FIX/claims.json"
  out=$(DRIVER_TICKET=472 driver_step_repair 472 2>&1); rc=$?
  [ "$rc" = 24 ] && echo flipped ) > "$FIX/plant2" 2>&1
want "planted (no machine-fault reading): the held tree reads as not proved" "flipped" "$(tail -1 "$FIX/plant2")"
unset WT_CLAIM_LIST WT_CLAIM_REFS

# The driver's own git rm gone: the listed deletions are never taken, so the merge stays unfinished.
( _driver_repair_take_listed() { return 0; }
  triggers_in 13142; setup 13142
  for f in $TRIGGERS; do printf 'bump again\n' >> "$WT/$f"; done; git -C "$WT" commit -qam "chore: bump deploy"
  driver_state_set 13142 repair_base "$(git -C "$WT" rev-parse HEAD)"; triggers_retired; prs 13142 DIRTY
  answer "$(take_answer '[".deploy-trigger","apps/api/.deploy-trigger","apps/web/.deploy-trigger"]')"
  out=$(driver_step_repair 13142 2>&1); rc=$?
  [ "$rc" != 0 ] && echo flipped ) > "$FIX/plant3" 2>&1
want "planted (no driver git rm): the listed deletions leave the merge unfinished" "flipped" "$(tail -1 "$FIX/plant3")"
# The on-base reading gone: the untouched sentinel goes to the model, and a listed one is refused.
( _driver_repair_deleted_on_base() { return 1; }
  triggers_in 13143; setup 13143; triggers_retired; prs 13143 CLEAN
  git -C "$WT" fetch -q origin; git -C "$WT" merge -q --no-commit --no-ff origin/develop >/dev/null 2>&1
  mb=$(git -C "$WT" merge-base HEAD MERGE_HEAD)
  for f in $TRIGGERS; do bl=$(git -C "$WT" rev-parse "$mb:$f")
    printf '100644 %s 1\t%s\n100644 %s 2\t%s\n' "$bl" "$f" "$bl" "$f" | git -C "$WT" update-index --index-info; done
  out=$(driver_step_repair 13143 2>&1); rc=$?
  [ -n "$(cat "$CLAUDE_LOG")" ] || [ "$rc" != 0 ] && echo flipped ) > "$FIX/plant4" 2>&1
want "planted (no on-base reading): the untouched sentinel is not taken by the driver" "flipped" "$(tail -1 "$FIX/plant4")"
# The driver's git actions gone (the call deleted): commitMerge never runs, so the merge stays unfinished.
( driver_git_actions() { return 0; }
  merge_case 13602 'printf "trunk line 13602\nbranch line\n" > shared.txt'
  out=$(driver_step_repair 13602 2>&1); rc=$?
  [ "$rc" != 0 ] && [ -z "$(merge_done)" ] && echo flipped ) > "$FIX/plant5" 2>&1
want "planted (no driver git actions): commitMerge leaves the merge unfinished" "flipped" "$(tail -1 "$FIX/plant5")"
# The own-history check gone: a trunk commit is taken as a reset target.
( _driver_ga_reset_to() { git -C "$2" reset -q --keep "$4"; }
  setup 13603; ga "[{\"action\":\"resetTo\",\"sha\":\"$TRUNK0\"}]"
  driver_git_actions 13603 "$WT" "$FIX/ga.json" build >/dev/null 2>&1 && echo flipped ) > "$FIX/plant6" 2>&1
want "planted (no reset check): a trunk commit is accepted" "flipped" "$(tail -1 "$FIX/plant6")"
# The on-origin check gone: a commit origin lacks is dropped.
( _driver_ga_drop_local() { git -C "$2" reset -q --keep "origin/$4"; }
  setup 13604; git -C "$WT" commit -q --allow-empty -m "local only"; ga '[{"action":"dropLocalCommits"}]'
  driver_git_actions 13604 "$WT" "$FIX/ga.json" fix >/dev/null 2>&1 && echo flipped ) > "$FIX/plant7" 2>&1
want "planted (no on-origin check): a local-only commit is dropped" "flipped" "$(tail -1 "$FIX/plant7")"

echo "--- the driver owns the trunk merge: a resolution without one is merged by the driver (#13362, #13044) ---"
parents() { git -C "$WT" rev-list --parents -1 HEAD | wc -w | tr -d ' '; }
# The model aborts the driver's merge and commits its resolution as a plain commit.
nomerge_case() { merge_case "$1" "git merge --abort; printf 'trunk line $1\nbranch line\n' > shared.txt; git commit -qam 'resolve by hand'"
  answer "$(repaired "$(gate_fix 'bash lint.sh')" '[{"file":"shared.txt","resolution":"both lines kept"}]')"; }
nomerge_case 13700
out=$(driver_step_repair 13700 2>&1); rc=$?
want "no merge from the model: it finishes"         "0" "$rc"
want "no merge from the model: a merge commit"      "3" "$(parents)"
want "no merge from the model: the trunk is its second parent" "$(git -C "$WT" rev-parse origin/develop)" "$(git -C "$WT" rev-parse HEAD^2)"
want "no merge from the model: the model's content kept" "trunk line 13700 branch line" "$(git -C "$WT" show HEAD:shared.txt | tr '\n' ' ' | sed 's/ $//')"
want "no merge from the model: asked once"          "repair" "$(cat "$CLAUDE_LOG")"
want_not_in "no merge from the model: never refused" 'without merging|machine fault' "$out"
driver_push 13700 "$WT" tkt-13700/work repair >/dev/null 2>&1; prc=$?
want "no merge from the model: then the push happens" "0 $(git -C "$WT" rev-parse HEAD)" "$prc $(git -C "$FIX/origin" rev-parse tkt-13700/work)"

# The incident itself: a real merge, then the trunk moves (a peer's fetch in the shared
# clone) before the ancestor check. The driver merges the newer trunk too.
merge_case 13701 "printf 'trunk line 13701\nbranch line\n' > shared.txt
( cd \"\$FIX/repo\"; printf 'later\n' > later13701.txt; git add later13701.txt; git commit -qm 'trunk: later'; git --git-dir=\"\$FIX/origin\" fetch -q \"\$FIX/repo\" +develop:develop )
git fetch -q origin"
out=$(driver_step_repair 13701 2>&1); rc=$?
want "trunk moved under the model: it finishes"     "0" "$rc"
want "trunk moved under the model: the newer trunk is in" "yes" "$(git -C "$WT" merge-base --is-ancestor "$(git -C "$REPO" rev-parse develop)" HEAD && echo yes)"
want "trunk moved under the model: a merge commit"  "3" "$(parents)"
want "trunk moved under the model: content kept"    "trunk line 13701 branch line" "$(git -C "$WT" show HEAD:shared.txt | tr '\n' ' ' | sed 's/ $//')"

echo "--- a file the model left marked is handed back, once ---"
merge_case 13702 "n=\$(cat \"\$FIX/n13702\" 2>/dev/null || echo 0); echo \$((n+1)) > \"\$FIX/n13702\"
[ \"\$n\" -ge 1 ] && printf 'trunk line 13702\nbranch line\n' > shared.txt; true"
out=$(driver_step_repair 13702 2>&1); rc=$?
want "a marker left: it finishes"                   "0" "$rc"
want "a marker left: the model was asked twice"     "repair repair" "$(tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//')"
want_in "a marker left: the file was handed back"   'handed back to the model' "$out"
want_in "a marker left: the second brief names it"  'still carry conflict markers: shared.txt' "$(cat "$FIX/claude-stdin-repair.txt")"
want "a marker left: a merge commit with the trunk" "3 yes" "$(parents) $(merge_done)"
want "a marker left: both sides kept"               "trunk line 13702 branch line" "$(git -C "$WT" show HEAD:shared.txt | tr '\n' ' ' | sed 's/ $//')"

echo "--- a head that already has the trunk is not merged again ---"
merge_case 13703 'printf "trunk line 13703\nbranch line\n" > shared.txt'
out=$(driver_step_repair 13703 2>&1); rc=$?
want "already merged: it finishes"                  "0" "$rc"
want "already merged: exactly one merge of the trunk" "1" "$(git -C "$WT" rev-list --merges --count "$(driver_state_get 13703 repair_base)"..HEAD)"
H=$(git -C "$WT" rev-parse HEAD)
_driver_repair_own_trunk 13703 "$WT" "$(git -C "$WT" rev-parse origin/develop)" "$(driver_state_dir 13703)/steps/repair.json" >/dev/null 2>&1; orc=$?
want "already merged: the driver's merge is a no-op" "0 $H" "$orc $(git -C "$WT" rev-parse HEAD)"

echo "--- plant: the driver's merge gone, the resolution without one refuses again ---"
( _driver_repair_own_trunk() { DRIVER_REPAIR_LEFT=""; return 0; }
  nomerge_case 13704
  out=$(driver_step_repair 13704 2>&1); rc=$?
  [ "$rc" = 24 ] && [ "$(parents)" = 2 ] && echo flipped ) > "$FIX/plant-own-merge" 2>&1
want "planted (no driver merge): the resolution without a merge is refused" "flipped" "$(tail -1 "$FIX/plant-own-merge")"

suite_end "$FAILED"
