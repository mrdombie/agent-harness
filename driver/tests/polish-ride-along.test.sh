#!/usr/bin/env bash
# polish-ride-along.test.sh — polish rides along with a screen's next real change and
# never blocks it. A sidebar change touching 4 screens took on 55 polish items beside
# its 3 real findings, and its fix round was refused because some of those items were
# left unanswered. Now a change takes at most 8 items, oldest first. An item the fixer
# leaves goes back free on its list, is noted in the PR, and the run goes on.
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
c() { git -C "$1" -c user.email=t@e.invalid -c user.name=T commit -qm "$2"; git -C "$1" rev-parse HEAD; }

# 40 free items over 4 lists, given newest list first, so oldest-first has to sort.
cat > "$FIX/sf" <<SH
#!/usr/bin/env bash
[ "\$1" = polish ] || exit 0
for n in 917 911 910 908; do for i in \$(seq 1 10); do printf 'minor\t%s\titem %s of list %s\n' "\$n" "\$i" "\$n"; done; done
SH
cat > "$FIX/pl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FIX/pl.calls"; exit 0
SH
chmod +x "$FIX/sf" "$FIX/pl"; : > "$FIX/pl.calls"
export DRIVER_SCREEN_FINDINGS="$FIX/sf" DRIVER_POLISH_LIST="$FIX/pl"

echo "--- a change takes at most 8 polish items, oldest first ---"
driver_state_init 701 --worktree "$REPO"; fix_issue 701 OPEN "status:claimed,screen:menu"
f="$(driver_state_dir 701)/steps/review.json"; mkdir -p "$(dirname "$f")"
printf '%s\n' '{"verdict":"SHIP","findings":[]}' > "$f"
out=$(_driver_review_touched 701 "$f" "$REPO" develop 2>&1)
want "8 ride along"                       "8" "$(jq '[.findings[] | select(.id | startswith("polish-"))] | length' "$f")"
want "from the oldest list"               "908" "$(jq -r '[.findings[].file | capture("#(?<n>[0-9]+)").n] | unique | join(" ")' "$f")"
want "in its own order"                   "item 1 of list 908" "$(jq -r '.findings[0].summary' "$f")"
want_in "and the rest are said to stay"   '8 of 40 free polish item.*32 stay on their lists' "$out"
printf '%s\n' '{"verdict":"SHIP","findings":[]}' > "$f"
DRIVER_POLISH_RIDE_ALONG=3 _driver_review_touched 701 "$f" "$REPO" develop >/dev/null 2>&1
want "the bound is configurable"          "3" "$(jq '.findings | length' "$f")"

echo "--- a fix round: 2 real findings answered, 40 polish items, 10 left -> not refused ---"
WT="$FIX/wt702"
git -C "$REPO" worktree add -q "$WT" -b "tkt-702/work" develop
driver_state_init 702 --worktree "$WT" --branch "tkt-702/work"; fix_issue 702 OPEN "status:claimed"
printf 'mode=old\n' > "$WT/mode.txt"
printf '#!/usr/bin/env bash\ngrep -q mode=new mode.txt || { echo " FAIL  mode > new"; exit 1; }\n' > "$WT/mode.test.sh"
git -C "$WT" add mode.txt mode.test.sh; TS=$(c "$WT" "test: mode is new")
printf 'mode=new\n' > "$WT/mode.txt"; git -C "$WT" add mode.txt; IS=$(c "$WT" "fix: mode is new")
jq -n '{step:"review", skills:[], status:"reviewed", round:1, verdict:"BLOCKED",
  findings: (([{id:"F1",grade:"major"},{id:"F2",grade:"critical"}]
             | map(. + {file:"mode.txt", line:1, summary:"the mode is old", reason:"a person sees it", fix:"make it new"}))
          + [range(0;40) | {id:"polish-908-\(.)", file:"(polish list #908)", line:0, grade:"minor",
                            summary:"item \(.) of list 908", reason:"what you touch, you fix", fix:"fix it"}])}' \
  > "$(driver_state_dir 702)/steps/review.json"
cleared=$(jq -nc --arg ts "$TS" --arg is "$IS" '[("F1","F2"), (range(0;30) | "polish-908-\(.)")]
  | map({blockerId:., change:[{path:"mode.txt", action:"modify"}],
         test:{file:"mode.test.sh", behaviour:"the mode is new", redWhen:"the mode goes back"},
         command:"bash mode.test.sh", testCommit:$ts, implCommit:$is, failedBefore:true, passedAfter:true})')
fix_ai fix "$(jq -nc --argjson c "$cleared" '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1, cleared:$c}')" superpowers:receiving-code-review
: > "$FIX/pl.calls"
rc=0; out=$(driver_step_fix 702 2>&1) || rc=$?
want "the fix round is not refused"       "0" "$rc"
want_not_in "no item is called unanswered" 'unanswered|neither cleared' "$out"
want "the 10 go back on their list"       "10" "$(grep -c '^forget 702 908 item ' "$FIX/pl.calls")"
want "and are noted for the PR"           "10" "$(grep -c 'back on its list' "$(driver_state_dir 702)/steps/review.deferred.jsonl" 2>/dev/null)"

echo "--- a real finding left unanswered is still refused ---"
fix_ai fix "$(jq -nc --argjson c "$(printf '%s' "$cleared" | jq -c '[.[] | select(.blockerId != "F2")]')" '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1, cleared:$c}')" superpowers:receiving-code-review
rc=0; out=$(driver_step_fix 702 2>&1) || rc=$?
want "refused"                            "$DRIVER_E_REFUSED" "$rc"
want_in "naming the real one only"        'finding\(s\) F2 appear' "$out"

suite_end "$FAILED"
