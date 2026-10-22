#!/usr/bin/env bash
# fix-nonblocking-deferral.test.sh — a fix round judges what it left by the same round
# rule the review used to choose what to fix. A finding the round does not block (a
# Minor from review round 2, a Nit at any round) that the fixer defers is on the polish
# list and never refuses; a deferred Critical or Major, or a Minor in round 1, refuses.
# The grade is the review's recorded one, never the fixer's wording.
#
# Measured on the origin project, 22 Oct: 11 of 43 draft PRs parked on "the fix round
# deferred a blocking finding", among them four round-2 Minors the fixer had put on the
# screen's polish list ("R3: Minor (bubble align=end may start off-screen …)").
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

WT="$FIX/wt901"
git -C "$REPO" worktree add -q "$WT" -b "tkt-901/work" develop
driver_state_init 901 --worktree "$WT" --branch "tkt-901/work"
fix_issue 901 OPEN "status:claimed"
printf '#!/usr/bin/env bash\ngrep -q "mode=new" mode.txt || { echo " FAIL  mode"; exit 1; }\n' > "$WT/mode.test.sh"
printf 'mode=old\n' > "$WT/mode.txt"; git -C "$WT" add mode.test.sh mode.txt; TS=$(c "$WT" "test: mode is new")
printf 'mode=new\n' > "$WT/mode.txt"; git -C "$WT" add mode.txt; IS=$(c "$WT" "fix: mode is new")

# The screen's polish list and the screen a file maps to, stood in for.
cat > "$FIX/pl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/pl.calls"; exit 0
SH
cat > "$FIX/sf" <<'SH'
#!/usr/bin/env bash
[ "$1" = screens ] && echo create; exit 0
SH
chmod +x "$FIX/pl" "$FIX/sf"
export DRIVER_POLISH_LIST="$FIX/pl" DRIVER_SCREEN_FINDINGS="$FIX/sf"

S="$(driver_state_dir 901)/steps"
F1='{"id":"F1","file":"mode.txt","line":1,"grade":"major","summary":"the mode is still old","reason":"a person sees the old mode","fix":"make it new"}'
review() { # <round> <second finding json>
  printf '{"step":"review","skills":[],"status":"reviewed","round":%s,"verdict":"BLOCKED","findings":[%s,%s]}\n' "$1" "$F1" "$2" > "$S/review.json"
  rm -f "$S/review.deferred.jsonl" "$FIX/pl.calls"
  jq --argjson r "$1" '.counters.review = $r | .counters.fix = 0' "$(driver_state_dir 901)/state.json" > "$FIX/st" && mv "$FIX/st" "$(driver_state_dir 901)/state.json"
}
R2='{"id":"R2","file":"page.tsx","line":9,"grade":"%s","summary":"the bubble may start off-screen on a 375px phone","reason":"r","fix":"f"}'
answer() { # <deferral reason>
  jq -nc --arg ts "$TS" --arg is "$IS" --arg r "$1" \
    '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1,
      cleared:[{blockerId:"F1", change:[{path:"mode.txt", action:"modify"}],
                test:{file:"mode.test.sh", behaviour:"the mode is new", redWhen:"the mode goes back to old"},
                command:"bash mode.test.sh", testCommit:$ts, implCommit:$is, failedBefore:true, passedAfter:true}],
      deferred:[{blockerId:"R2", reason:$r, followUp:"the screen polish list"}]}'
}
run() { # <answer>
  : > "$CLAUDE_LOG"; driver_state_set 901 park_note ""; driver_state_set 901 park_cause ""
  fix_ai fix "$1" superpowers:receiving-code-review
  rc=0; out=$(driver_step_fix 901 2>&1) || rc=$?
}

echo "--- round 2, a deferred Minor: no refusal, and a polish entry ---"
review 2 "$(printf "$R2" minor)"
run "$(answer "Minor; on the polish list per the brief.")"
want "the round passes" "0" "$rc"
want "nothing is parked" "" "$(driver_state_get 901 park_note)"
want_in "the Minor went on the screen's polish list" 'add create \[Minor\] the bubble may start off-screen' "$(cat "$FIX/pl.calls" 2>/dev/null)"
want "and is recorded for the PR's Minor, deferred" "R2 minor create" "$(jq -r '"\(.id) \(.grade) \(.list)"' "$S/review.deferred.jsonl" 2>/dev/null)"
handed=$(cat "$(driver_fact_dir 901 fix)/BLOCKERS" 2>/dev/null)
want_in "the fixer was handed the Major" 'id F1' "$handed"
want_not_in "and not the Minor, as a blocker" 'id R2' "$handed"

echo "--- round 1, a deferred Minor: still refused ---"
review 1 "$(printf "$R2" minor)"
run "$(answer "Minor; the round-2 Minors went on the screen's polish list.")"
want "refused" "24" "$rc"
want_in "naming it" 'deferred a blocking finding: R2' "$(driver_state_get 901 park_note)"
want "nothing went on a list" "" "$(cat "$FIX/pl.calls" 2>/dev/null)"

echo "--- round 2, a deferred Major: still refused, whatever the fixer calls it ---"
review 2 "$(printf "$R2" major)"
run "$(answer "Minor, and round 2 already put it on the screen's polish list.")"
want "refused" "24" "$rc"
want_in "naming it" 'deferred a blocking finding: R2' "$(driver_state_get 901 park_note)"

echo "--- a Nit is never a refusal ---"
for r in 1 2; do
  review "$r" "$(printf "$R2" nit)"
  run "$(answer "A Nit.")"
  want "round $r: the round passes" "0" "$rc"
  want "round $r: nothing is parked" "" "$(driver_state_get 901 park_note)"
done

git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
suite_end "$FAILED"
