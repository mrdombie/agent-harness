#!/usr/bin/env bash
# fix-stale-critic.test.sh — a fix round that says a critic finding is "not outstanding"
# because later commits cover it is re-checked by the driver, never parked on the owner.
# The cited commits on the branch and absent from the head the critic failed: the critic
# judges the pushed head again, and the round carries on. Otherwise it is refused for
# the PM.
#
# Measured on the origin project, 20 Oct: a fixer answered a critic finding with "Not
# outstanding: commits 268e366 and 98297dd came after the critic's run and already
# cover the four pages it flagged", and the round parked on the owner (exit 24). The
# PM cleared it by hand: the commits were real and the finding was stale.
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
export CRITIC_JUDGE_DIR="$FIX/judge"; mkdir -p "$CRITIC_JUDGE_DIR"

WT="$FIX/wt801"
git -C "$REPO" worktree add -q "$WT" -b "tkt-801/work" develop
driver_state_init 801 --worktree "$WT" --branch "tkt-801/work"
driver_state_set 801 pr 77
fix_issue 801 OPEN "status:claimed"

printf 'page one\n' > "$WT/pages.txt"; git -C "$WT" add pages.txt; EARLY=$(c "$WT" "feat: page one")
JUDGED=$EARLY
printf '{"shots":["connect"]}\n' > "$WT/plan.json"; git -C "$WT" add plan.json; L1=$(c "$WT" "evidence: connect shot")
printf '{"shots":["connect","success"]}\n' > "$WT/plan.json"; git -C "$WT" add plan.json; L2=$(c "$WT" "evidence: success shot")
# The review finding the round clears with a real red/green pair.
printf '#!/usr/bin/env bash\ngrep -q "mode=new" mode.txt || { echo " FAIL  mode"; exit 1; }\n' > "$WT/mode.test.sh"
printf 'mode=old\n' > "$WT/mode.txt"; git -C "$WT" add mode.test.sh mode.txt; TS=$(c "$WT" "test: mode is new")
printf 'mode=new\n' > "$WT/mode.txt"; git -C "$WT" add mode.txt; IS=$(c "$WT" "fix: mode is new")
# A commit that is on no branch this ticket has.
git -C "$REPO" branch -q elsewhere develop
OTHER_WT="$FIX/wt-elsewhere"; git -C "$REPO" worktree add -q "$OTHER_WT" elsewhere
printf 'x\n' > "$OTHER_WT/x.txt"; git -C "$OTHER_WT" add x.txt; OFFBRANCH=$(c "$OTHER_WT" "elsewhere")

printf '%s\n' '{"step":"review","skills":[],"status":"reviewed","round":1,"verdict":"BLOCKED","findings":[{"id":"F1","file":"mode.txt","line":1,"grade":"major","summary":"the mode is still old","reason":"a person sees the old mode","fix":"make it new"}]}' \
  > "$(driver_state_dir 801)/steps/review.json"

ledger() { printf '77\t%s\tset1\tSLOP\tfailure\thttps://x/c/1\n' "$1" > "$CRITIC_JUDGE_DIR/verdicts.tsv"; }
answer() { # <reason> [extra-deferred-json]
  jq -nc --arg ts "$TS" --arg is "$IS" --arg r "$1" --argjson x "${2:-[]}" \
    '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1,
      cleared:[{blockerId:"F1", change:[{path:"mode.txt", action:"modify"}],
                test:{file:"mode.test.sh", behaviour:"the mode is new", redWhen:"the mode goes back to old"},
                command:"bash mode.test.sh", testCommit:$ts, implCommit:$is, failedBefore:true, passedAfter:true}],
      deferred:([{blockerId:"critic-evidence-gaps", reason:$r, followUp:"the critic re-judges the pushed head"}] + $x)}'
}
short() { printf '%s' "$1" | cut -c1-7; }
run() { # <answer>
  : > "$CLAUDE_LOG"; driver_state_set 801 park_note ""; driver_state_set 801 park_cause ""
  fix_ai fix "$1" superpowers:receiving-code-review
  rc=0; out=$(driver_step_fix 801 2>&1) || rc=$?
}

echo "--- 'not outstanding' with real later commits: re-checked, and not parked ---"
ledger "$JUDGED"
run "$(answer "Not outstanding: commits $(short "$L1") and $(short "$L2") came after the critic's run and already cover the pages it flagged.")"
want "the round passes" "0" "$rc"
want_in "it says it re-checked" 'said not outstanding, and re-checked' "$out"
want "nothing is parked" "" "$(driver_state_get 801 park_cause)"
want "the record says it went back to the critic" "critic-recheck" \
  "$(jq -r '.[] | select(.blockerId=="critic-evidence-gaps") | .proof' "$(driver_state_dir 801)/steps/fix.proofs.json")"

echo "--- a cited commit not on the branch: still refused, and not the owner's ---"
run "$(answer "Not outstanding: commit $(short "$OFFBRANCH") already covers it.")"
want "refused" "24" "$rc"
want_in "because the commit is not on the branch" 'is not on this branch' "$(driver_state_get 801 park_note)"
want "parked for the PM, not the owner" "pm" "$(driver_state_get 801 park_cause)"

echo "--- a cited commit the critic already judged: refused ---"
ledger "$L2"
run "$(answer "Not outstanding: commit $(short "$L1") covers it.")"
want "refused" "24" "$rc"
want_in "because the critic saw that commit" 'already in .*the head the critic failed' "$(driver_state_get 801 park_note)"
want "for the PM" "pm" "$(driver_state_get 801 park_cause)"

echo "--- no failing verdict in the critic's ledger: 'after its run' cannot be checked, refused ---"
rm -f "$CRITIC_JUDGE_DIR/verdicts.tsv"
run "$(answer "Not outstanding: commits $(short "$L1") and $(short "$L2") came after the critic's run.")"
want "refused" "24" "$rc"
want_in "and says why" 'not in its ledger' "$(driver_state_get 801 park_note)"
want "for the PM" "pm" "$(driver_state_get 801 park_cause)"

echo "--- a stale claim beside a real deferral of a review finding: the real one still parks for a person ---"
ledger "$JUDGED"
run "$(answer "Not outstanding: commit $(short "$L1") covers it." '[{"blockerId":"F1","reason":"I disagree with the grade","followUp":"the owner"}]')"
want "refused" "24" "$rc"
want "for a person" "person" "$(driver_state_get 801 park_cause)"
want_in "naming the review finding" 'F1: I disagree with the grade' "$(driver_state_get 801 park_note)"
want_not_in "and not the stale one it re-checked" 'critic-evidence-gaps' "$(driver_state_get 801 park_note)"

git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
git -C "$REPO" worktree remove --force "$OTHER_WT" >/dev/null 2>&1
suite_end "$FAILED"
