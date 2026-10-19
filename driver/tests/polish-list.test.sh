#!/usr/bin/env bash
# polish-list.test.sh — a ticket for a screen carries that screen's polish list into
# its plan and build ({{POLISH_LIST}}), and the pull request names the items the
# run ticked and the ones it left. A ticket with no screen, or a list itself, gets
# a sentence saying so, never an empty fact.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../facts.sh" || exit 1
. "$HERE/../steps/ship.sh" || exit 1

# `issue list` answers from $FIX/gh/issue-list.json when every label asked for is on
# the list there; everything else goes to the fixture's stub.
mv "$BIN/gh" "$BIN/gh-base"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = "issue list" ]; then
  printf '%s\n' "$*" >> "$GH_LOG"
  want=(); prev=""; for a in "$@"; do [ "$prev" = --label ] && want+=("$a"); prev="$a"; done
  f="$FIX/gh/issue-list.json"; [ -f "$f" ] || { echo '[]'; exit 0; }
  printf '%s\n' "${want[@]}" | jq -R . | jq -s --slurpfile l "$f" \
    '. as $w | [$l[0][] | select([.labels[].name] as $have | all($w[]; . as $x | $have | index($x))) | {number}]'
  exit 0
fi
exec "$FIX/bin/gh-base" "$@"
SH
chmod +x "$BIN/gh"

list_body() { # <n> <body>
  jq -n --argjson n "$1" --arg b "$2" '{number:$n, state:"OPEN", title:"Polish list: Inbox", body:$b,
    labels:(["polish-list","screen:inbox","P3","status:ready","type:bug"] | map({name:.}))}' > "$FIX/gh/issue-$1.json"
}
list_body 900 $'Small fixes.\n\n## Items\n- [ ] Row gap is 12px, kit says 16px\n- [x] Already fixed\n- [ ] Send label wraps on a phone\n'
jq -s '.' "$FIX/gh/issue-900.json" > "$FIX/gh/issue-list.json"

echo "--- a ticket for the screen gets the list's unticked items ---"
fix_issue 501 OPEN "status:claimed,screen:inbox"; driver_state_init 501
fact=$(driver_fact_polish_list 501)
want_in "it names the list"                'Polish list #900 for screen:inbox' "$fact"
want_in "and each unticked item"           '^- Row gap is 12px, kit says 16px$' "$fact"
want_in "both of them"                     '^- Send label wraps on a phone$' "$fact"
want_not_in "never a ticked one"           'Already fixed' "$fact"
want_in "and how to tick one"              'polish-list.sh tick 900' "$fact"
driver_facts_common 501 build
want "it reaches the build step's facts"   "$fact" "$(cat "$(driver_fact_dir 501 build)/POLISH_LIST")"

echo "--- read once a run: every step sees the list the plan saw ---"
list_body 900 $'## Items\n- [ ] Something new\n'
want "the second read is the first"        "$fact" "$(driver_fact_polish_list 501)"

echo "--- no screen, a list itself, or no list: a sentence, never empty ---"
fix_issue 502 OPEN "status:claimed"; driver_state_init 502
want_in "no screen label"                  '^\(none — #502 carries no screen:<slug> label' "$(driver_fact_polish_list 502)"
fix_issue 503 OPEN "status:claimed,polish-list,screen:inbox"; driver_state_init 503
want_in "the list itself"                  'is a polish list itself' "$(driver_fact_polish_list 503)"
fix_issue 504 OPEN "status:claimed,screen:calendar"; driver_state_init 504
want_in "a screen with no list"            'no open polish list for screen:calendar' "$(driver_fact_polish_list 504)"
fix_issue 505 OPEN "status:claimed,screen:inbox"; driver_state_init 505
list_body 900 $'## Items\n- [x] all done\n'
want_in "a list with nothing unticked"     'no open polish list for screen:inbox holds an unticked item' "$(driver_fact_polish_list 505)"

echo "--- the pull request names what this run ticked and what it left ---"
list_body 900 $'## Items\n- [x] Row gap is 12px, kit says 16px\n- [x] Already fixed\n- [ ] Send label wraps on a phone\n- [ ] Something new\n'
sec=$(_driver_ship_polish 501)
want_in "a section of its own"             '^## Polish list$' "$sec"
want "the ticked one under fixed"          "- Row gap is 12px, kit says 16px (#900)" "$(printf '%s\n' "$sec" | sed -n '/^Fixed here/,/^$/p' | sed -n 2p)"
want "the unticked one under left"         "- Send label wraps on a phone (#900)" "$(printf '%s\n' "$sec" | sed -n '/^Left on/,$p' | sed -n 2p)"
want_not_in "an item added after the plan is not this run's" 'Something new' "$sec"
want "a ticket with no list adds nothing"  "" "$(_driver_ship_polish 502)"
mv "$FIX/gh/issue-900.json" "$FIX/gh/gone.json"
want_not_in "a list that cannot be read names nothing fixed" 'Fixed here' "$(_driver_ship_polish 501)"
mv "$FIX/gh/gone.json" "$FIX/gh/issue-900.json"

echo "--- and the shipped body carries it ---"
git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop
wt="$FIX/wt501"
git -C "$REPO" worktree add -q "$wt" -b "tkt-501/work" develop
printf 'change\n' > "$wt/f.txt"; git -C "$wt" add f.txt; git -C "$wt" commit -qm "feat: thing"
driver_state_set 501 worktree "$wt"; driver_state_set 501 branch "tkt-501/work"
driver_state_set 501 claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
driver_state_put 501 review '{"verdict":"SHIP","findings":[]}'
driver_state_bump 501 review
for st in start plan build self-check review record; do driver_state_done 501 "$st"; done
driver_step_ship 501 >/dev/null 2>&1
want_in "the PR body names the fixed item" 'Fixed here and ticked:' "$(grep -A60 '^pr create' "$GH_LOG")"

exit "$FAILED"
