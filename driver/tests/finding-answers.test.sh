#!/usr/bin/env bash
# finding-answers.test.sh — every review finding ends as "fixed (commit)" or "closed:
# <reason>" on one append-only ledger (steps/review.answers.jsonl), the pull request lists
# each one with its answer, and ship refuses while a posted finding has neither.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fix_real_briefs
. "$HERE/../ai-step.sh" || exit 1
. "$HERE/../steps/review.sh" || exit 1
. "$HERE/../steps/fix.sh" || exit 1
. "$HERE/../steps/ship.sh" || exit 1
. "$HERE/../finding-answers.sh" 2>/dev/null || echo "(driver/finding-answers.sh is missing)"
export SWEEP_QUEUE="$FIX/sweep.jsonl"

c() { git -C "$1" -c user.email=t@e.invalid -c user.name=T commit -qm "$2"; git -C "$1" rev-parse HEAD; }
key() { jq -r "$(cat "$KIT_ROOT/scripts/finding-key.jq")"' finding_key' <<<"$1"; }
ledger() { cat "$(driver_state_dir "$1")/steps/review.answers.jsonl" 2>/dev/null; }
row() { # <ticket> <finding-json> — the ledger's rows for that finding's key
  ledger "$1" | jq -c --arg k "$(key "$2")" 'select(.key == $k)'
}

echo "--- driver_finding_answer: fixed carries its commit, closed its reason, and empty is refused ---"
driver_state_init 100
F='{"id":"F1","file":"src/a.js","line":3,"grade":"major","summary":"the total is wrong"}'
rc=0; driver_finding_answer 100 "$F" fixed abc1234def || rc=$?
want "a fixed answer is written" "0" "$rc"
want "as key, id, fixed and its commit" "$(key "$F") F1 fixed abc1234def" "$(row 100 "$F" | jq -r '"\(.key) \(.id) \(.answer) \(.commit)"')"
G='{"id":"F2","file":"src/b.js","line":9,"grade":"minor","summary":"spacing"}'
rc=0; driver_finding_answer 100 "$G" closed "dropped on purpose" || rc=$?
want "a closed answer is written" "0" "$rc"
want "as key, id, closed and its reason" "F2 closed dropped on purpose" "$(row 100 "$G" | jq -r '"\(.id) \(.answer) \(.reason)"')"
n0=$(ledger 100 | grep -c .)
rc=0; driver_finding_answer 100 "$F" fixed "" || rc=$?
want "a fixed answer with no commit is refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
rc=0; driver_finding_answer 100 "$G" closed "" || rc=$?
want "a closed answer with no reason is refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
want "and neither is written" "$n0" "$(ledger 100 | grep -c .)"

# ---- the fix step: a proof writes its answer --------------------------------
T=501
WT="$FIX/wt$T"
git -C "$REPO" worktree add -q "$WT" -b "tkt-$T/work" develop
driver_state_init $T --worktree "$WT" --branch "tkt-$T/work"
fix_issue $T OPEN "status:claimed"
S="$(driver_state_dir $T)/steps"
printf 'mode=old\n' > "$WT/mode.txt"; printf 'the plan says 55\n' > "$WT/plan.md"
git -C "$WT" add mode.txt plan.md; c "$WT" "chore: start" >/dev/null
printf '#!/usr/bin/env bash\ngrep -q "mode=new" mode.txt || { echo " FAIL  mode"; exit 1; }\n' > "$WT/mode.test.sh"
git -C "$WT" add mode.test.sh; TS=$(c "$WT" "test: mode is new")
printf 'mode=new\n' > "$WT/mode.txt"; git -C "$WT" add mode.txt; IS=$(c "$WT" "fix: mode is new")
printf 'the plan says 54\n' > "$WT/plan.md"; git -C "$WT" add plan.md; DOC=$(c "$WT" "docs: the plan says 54")
F7='{"id":"F7","file":"mode.txt","line":1,"grade":"major","summary":"the mode is still old","reason":"r","fix":"f"}'
D3='{"id":"D3","file":"plan.md","line":1,"grade":"major","summary":"the plan says 55","reason":"r","fix":"f"}'
printf '{"step":"review","skills":[],"status":"reviewed","round":1,"verdict":"BLOCKED","findings":[%s,%s]}\n' "$F7" "$D3" > "$S/review.json"
jq '.counters.review = 1' "$(driver_state_dir $T)/state.json" > "$FIX/st" && mv "$FIX/st" "$(driver_state_dir $T)/state.json"
fix_ai fix "$(jq -nc --arg ts "$TS" --arg is "$IS" --arg doc "$DOC" \
  '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1,
    cleared:[{blockerId:"F7", change:[{path:"mode.txt", action:"modify"}],
              test:{file:"mode.test.sh", behaviour:"the mode is new", redWhen:"the mode goes back to old"},
              command:"bash mode.test.sh", testCommit:$ts, implCommit:$is, failedBefore:true, passedAfter:true}],
    autoProofs:[{blockerId:"D3", kind:"docs-only", commit:$doc}]}')" superpowers:receiving-code-review
rc=0; out=$(driver_step_fix $T 2>&1) || rc=$?
want "the fix round passes" "0" "$rc"
want "a red-then-green proof writes a fixed row with its implCommit" "fixed $IS" "$(row $T "$F7" | jq -r '"\(.answer) \(.commit)"')"
want "an autoProofs row carries its commit" "fixed $DOC" "$(row $T "$D3" | jq -r '"\(.answer) \(.commit)"')"

echo "--- a second fix round keeps the first round's answers ---"
printf '{"step":"review","skills":[],"status":"reviewed","round":2,"verdict":"BLOCKED","findings":[%s]}\n' "$D3" > "$S/review.json"
jq '.counters.review = 2' "$(driver_state_dir $T)/state.json" > "$FIX/st" && mv "$FIX/st" "$(driver_state_dir $T)/state.json"
fix_ai fix "$(jq -nc --arg doc "$DOC" '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:2,
    autoProofs:[{blockerId:"D3", kind:"docs-only", commit:$doc}]}')" superpowers:receiving-code-review
rc=0; out=$(driver_step_fix $T 2>&1) || rc=$?
want "round 2 passes" "0" "$rc"
want "round 1's fixed row for F7 is still in the ledger" "fixed $IS" "$(row $T "$F7" | jq -r '"\(.answer) \(.commit)"')"

# ---- every writer that takes a finding out writes a closed row ---------------
echo "--- the review's deferral closes each finding it takes out, saying where it went ---"
T=601; driver_state_init $T; S="$(driver_state_dir $T)/steps"; mkdir -p "$S"
M1='{"id":"M1","file":"elsewhere.js","line":2,"grade":"minor","summary":"a slip outside the change"}'
M2='{"id":"M2","file":"own.js","line":4,"grade":"minor","summary":"a slip inside the change","inChange":true}'
printf '{"verdict":"BLOCKED","findings":[%s,%s]}\n' "$M1" "$M2" > "$S/review.json"
_driver_review_defer $T "$S/review.json" 2 >/dev/null
want "outside the change: closed to the sweep" "closed outside this change's files: to the nightly sweep" "$(row $T "$M1" | jq -r '"\(.answer) \(.reason)"')"
want "inside the change: closed as dropped, with its grade and round" "closed graded minor in round 2, below its blocking set: dropped" "$(row $T "$M2" | jq -r '"\(.answer) \(.reason)"')"
want "both are written as deferred" "true true" "$(row $T "$M1" | jq -s 'all(.deferred == true)') $(row $T "$M2" | jq -s 'all(.deferred == true)')"

echo "--- merge first's deferral in the fix step closes what it drops ---"
T=602; driver_state_init $T; S="$(driver_state_dir $T)/steps"; mkdir -p "$S"
J1='{"id":"J1","file":"db.sql","line":1,"grade":"major","summary":"needs a schema change"}'
printf '{"verdict":"BLOCKED","findings":[%s]}\n' "$J1" > "$S/review.json"
_driver_fix_mf_file_deferred $T "$S/review.json" '[{"blockerId":"J1","reason":"the spec rules out a migration"}]' 1 >/dev/null 2>&1
want_in "closed, with the fix round's reason" '^closed .*the spec rules out a migration' "$(row $T "$J1" | jq -r '"\(.answer) \(.reason)"')"

echo "--- a nonblocking deferral the fix step drops is closed ---"
T=603; driver_state_init $T; S="$(driver_state_dir $T)/steps"; mkdir -p "$S"
N1='{"id":"N1","file":"page.tsx","line":9,"grade":"minor","summary":"the bubble may start off-screen"}'
printf '{"verdict":"BLOCKED","findings":[%s]}\n' "$N1" > "$S/review.json"
printf '{"deferred":[{"blockerId":"N1","reason":"a minor"}]}\n' > "$S/fix.json"
_driver_fix_drop_nonblocking $T "$S/fix.json" '[{"id":"N1","grade":"minor","sameChange":false}]' 2 >/dev/null
want_in "closed, naming its grade" '^closed .*minor' "$(row $T "$N1" | jq -r '"\(.answer) \(.reason)"')"

echo "--- the critic's finding, off until the release, is closed when given a ticket ---"
T=604; driver_state_init $T; S="$(driver_state_dir $T)/steps"; mkdir -p "$S"
CR='{"id":"critic-row","file":"screens/Home.tsx","line":1,"grade":"major","summary":"no shot of a chosen row"}'
printf '{"verdict":"BLOCKED","findings":[%s]}\n' "$CR" > "$S/review.json"
# The critic's check is off until the release (its own suite proves when that holds).
( release_critic_paused() { return 0; }; driver_drop_critic_findings "$S/review.json" review $T >/dev/null )
want_in "closed as the critic's" '^closed .*critic' "$(row $T "$CR" | jq -r '"\(.answer) \(.reason)"')"

echo "--- a clash-only finding is closed when given a ticket ---"
CL='{"id":"K1","file":"(branch)","line":0,"grade":"major","summary":"the branch conflicts with develop"}'
printf '{"verdict":"BLOCKED","findings":[%s]}\n' "$CL" > "$S/review.json"
driver_drop_clash_findings "$S/review.json" review $T >/dev/null
want_in "closed as a clash" '^closed .*clash' "$(row $T "$CL" | jq -r '"\(.answer) \(.reason)"')"

# ---- ship reads the ledger ---------------------------------------------------
git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop
setup_ship() { # <ticket> — reviewed, everything before ship done
  local t=$1 wt st
  wt="$FIX/wt$t"
  git -C "$REPO" worktree add -q "$wt" -b "tkt-$t/work" develop
  printf 'change for %s\n' "$t" > "$wt/f$t.txt"
  git -C "$wt" add "f$t.txt"; git -C "$wt" commit -qm "feat: thing $t"
  driver_state_init "$t" --worktree "$wt" --branch "tkt-$t/work"; fix_gates_kept "$t"
  driver_state_set "$t" claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
  fix_issue "$t" OPEN "status:claimed"
  driver_state_put "$t" review '{"verdict":"SHIP","findings":[]}'
  driver_state_bump "$t" review
  for st in start plan build self-check review record; do driver_state_done "$t" "$st"; done
}
post() { # <ticket> <finding-json> — on the posted ledger, as the review writes it
  jq -c "$(cat "$KIT_ROOT/scripts/finding-key.jq")"' {key: finding_key, id, file, line, grade, summary, round: 1, fix: 0}' <<<"$2" \
    >> "$(driver_state_dir "$1")/steps/review.posted.jsonl"
}
P1='{"id":"P1","file":"src/pay.js","line":12,"grade":"major","summary":"the total skips the tax"}'
P2='{"id":"P2","file":"src/note.tsx","line":4,"grade":"minor","summary":"the note says saved too early"}'

echo "--- ship refuses while a posted finding has no answer, naming its file and summary ---"
setup_ship 701
post 701 "$P1"; post 701 "$P2"
driver_finding_answer 701 "$P1" fixed 0123456789abcdef
want "driver_findings_unanswered names P2's key alone" "$(key "$P2")" "$(driver_findings_unanswered 701)"
: > "$GH_LOG"
rc=0; out=$(driver_step_ship 701 2>&1) || rc=$?
want "ship refuses" "$DRIVER_E_REFUSED" "$rc"
want_in "the park names the file" 'src/note.tsx' "$(driver_state_get 701 park_note)"
want_in "and the summary" 'the note says saved too early' "$(driver_state_get 701 park_note)"
want_not_in "and the answered one is not named" 'the total skips the tax' "$(driver_state_get 701 park_note)"
want "nothing is armed" "0" "$(grep -c '^pr merge .*--auto' "$GH_LOG")"

echo "--- every posted finding answered: ship proceeds, and the body lists each answer ---"
setup_ship 702
post 702 "$P1"; post 702 "$P2"
driver_finding_answer 702 "$P1" fixed 0123456789abcdef
driver_finding_answer 702 "$P2" closed "graded minor in round 2, below its blocking set: dropped"
: > "$GH_LOG"
rc=0; out=$(driver_step_ship 702 2>&1) || rc=$?
want "ship proceeds" "0" "$rc"
B=$(cat "$GH_LOG")
want_in "the body has the section" '## Review findings, answered' "$B"
want_in "a fixed line with the short sha" 'src/pay.js:12 — the total skips the tax: fixed \(0123456\)' "$B"
want_in "a closed line with its reason" 'src/note.tsx:4 — the note says saved too early: closed: graded minor in round 2, below its blocking set: dropped' "$B"

echo "--- no posted ledger: no section, and no refusal ---"
setup_ship 703
: > "$GH_LOG"
rc=0; out=$(driver_step_ship 703 2>&1) || rc=$?
want "ship proceeds" "0" "$rc"
want_not_in "and the body has no answered section" 'Review findings, answered' "$(cat "$GH_LOG")"

suite_end "$FAILED"
