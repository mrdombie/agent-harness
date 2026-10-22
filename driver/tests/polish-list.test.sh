#!/usr/bin/env bash
# polish-list.test.sh — a ticket for a screen carries that screen's polish list into
# its plan and build ({{POLISH_LIST}}). The builder records what it fixed (take);
# ship reserves those items for its PR and names them — nothing is ticked before the
# PR merges. A polish list's own PR says "Refs", never "Closes". A ticket with no
# screen gets a sentence saying so, never an empty fact.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../facts.sh" || exit 1
. "$HERE/../steps/ship.sh" || exit 1
KIT="$(cd "$HERE/../.." && pwd)"

# `issue list` answers from $FIX/gh/issue-list.json when every label asked for is on
# the list there; everything else goes to the fixture's stub.
mv "$BIN/gh" "$BIN/gh-base"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = "issue list" ] || { [ "$1" = api ] && case "$2" in repos/*/issues\?*) true ;; *) false ;; esac; }; then
  printf '%s\n' "$*" >> "$GH_LOG"
  want=(); prev=""; for a in "$@"; do [ "$prev" = --label ] && want+=("$a"); prev="$a"; done
  if [ "$1" = api ]; then
    q=$(printf '%s' "$2" | sed -n 's/.*[?&]labels=\([^&]*\).*/\1/p')
    while IFS= read -r l; do [ -n "$l" ] && want+=("$(printf '%b' "${l//%/\\x}")"); done < <(printf '%s\n' "$q" | tr ',' '\n')
  fi
  f="$FIX/gh/issue-list.json"; [ -f "$f" ] || { echo '[]'; exit 0; }
  printf '%s\n' "${want[@]}" | jq -R . | jq -s --slurpfile l "$f" \
    '. as $w | [$l[0][] | select([.labels[].name] as $have | all($w[]; . as $x | $have | index($x))) | {number}]'
  exit 0
fi
if [ "$1 $2" = "issue edit" ] && [ "${4:-}" = --repo ] && printf '%s\n' "$@" | grep -qx -- --body-file; then
  printf '%s\n' "$*" >> "$GH_LOG"
  f="$FIX/gh/issue-$3.json"; b=$(cat); jq --arg b "$b" '.body = $b' "$f" > "$f.t" && mv "$f.t" "$f"; exit 0
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
want_in "it names the list"                'Polish list #900 — fix these' "$fact"
want_in "and each unticked item"           '^- Row gap is 12px, kit says 16px$' "$fact"
want_in "both of them"                     '^- Send label wraps on a phone$' "$fact"
want_not_in "never a ticked one"           'Already fixed' "$fact"
want_in "and how to record a fixed one, for this run" 'polish-list.sh take 900 501' "$fact"
want_in "never ticked by the builder"      'ticked when the pull request merges, never by you' "$fact"
driver_facts_common 501 build
want "it reaches the build step's facts"   "$fact" "$(cat "$(driver_fact_dir 501 build)/POLISH_LIST")"

echo "--- read once a run: every step sees the list the plan saw ---"
list_body 900 $'## Items\n- [ ] Something new\n'
want "the second read is the first"        "$fact" "$(driver_fact_polish_list 501)"

echo "--- no screen, or no list: a sentence, never empty ---"
fix_issue 502 OPEN "status:claimed"; driver_state_init 502
want_in "no screen label"                  '^\(none — #502 carries no screen:<slug> label' "$(driver_fact_polish_list 502)"
fix_issue 504 OPEN "status:claimed,screen:calendar"; driver_state_init 504
want_in "a screen with no list"            'no open polish list for screen:calendar' "$(driver_fact_polish_list 504)"
fix_issue 505 OPEN "status:claimed,screen:inbox"; driver_state_init 505
list_body 900 $'## Items\n- [x] all done\n- [ ] taken (in PR #9)\n'
want_in "a list with nothing free"         'no open polish list for this ticket holds a free item' "$(driver_fact_polish_list 505)"

echo "--- a polish list's own ticket works its own items ---"
list_body 503 $'## Items\n- [ ] Own item\n'
jq '.labels += [{name:"screen:inbox"}]' "$FIX/gh/issue-503.json" > "$FIX/t" && mv "$FIX/t" "$FIX/gh/issue-503.json"
driver_state_init 503
want_in "the list itself is the work"      'Polish list #503 \(this ticket\)' "$(driver_fact_polish_list 503)"
want_in "with its own items"               '^- Own item$' "$(driver_fact_polish_list 503)"
want "a polish list's PR refers to it, never closes it" "Refs" "$(_driver_ship_closes 503)"
want "any other ticket's PR closes it"     "Closes" "$(_driver_ship_closes 501)"
fix_gh_fail "issue view"
want "an unread label falls back to what the plan saw" "Refs" "$(_driver_ship_closes 503)"
fix_gh_ok

echo "--- the builder takes, ship reserves for its PR, nothing is ticked ---"
list_body 900 $'## Items\n- [ ] Row gap is 12px, kit says 16px\n- [x] Already fixed\n- [ ] Send label wraps on a phone\n'
bash "$KIT/scripts/polish-list.sh" take 900 501 "Row gap is 12px, kit says 16px" >/dev/null
want "taking ticks nothing, it marks the item for this run" "- [ ] Row gap is 12px, kit says 16px (taken by #501)" "$(jq -r .body "$FIX/gh/issue-900.json" | grep 'Row gap')"
want "nothing reserved, nothing said"      "" "$(_driver_ship_polish 501)"
_driver_ship_reserve 501 42 >/dev/null
want "ship reserves it for the PR, unticked" "- [ ] Row gap is 12px, kit says 16px (in PR #42)" "$(jq -r .body "$FIX/gh/issue-900.json" | grep 'Row gap')"
sec=$(_driver_ship_polish 501)
want_in "a section of its own"             '^## Polish list$' "$sec"
want "the reserved one under fixed"        "- Row gap is 12px, kit says 16px (#900)" "$(printf '%s\n' "$sec" | sed -n '/^Fixed here/,/^$/p' | sed -n 2p)"
want "the one it did not take under left"  "- Send label wraps on a phone (#900)" "$(printf '%s\n' "$sec" | sed -n '/^Left on/,$p' | sed -n 2p)"
want_not_in "it never says ticked by this run" 'Fixed here and ticked' "$sec"
want "once reserved, it leaves the run's record" "" "$(bash "$KIT/scripts/polish-list.sh" taken 501)"
# PR #42 closes unmerged; the sweep frees the item. A later ship of the same ticket
# must not reserve a take that belonged to the closed PR.
list_body 900 "$(jq -r .body "$FIX/gh/issue-900.json" | sed 's/ (in PR #42)$//')"
_driver_ship_reserve 501 47 >/dev/null 2>&1
want "a closed PR's take is never reserved by a later run" "- [ ] Row gap is 12px, kit says 16px" "$(jq -r .body "$FIX/gh/issue-900.json" | grep 'Row gap')"
list_body 900 "$(jq -r .body "$FIX/gh/issue-900.json" | sed 's/^- \[ \] Row gap is 12px, kit says 16px$/- [ ] Row gap is 12px, kit says 16px (in PR #42)/')"
bash "$KIT/scripts/polish-list.sh" take 900 506 "Send label wraps on a phone" >/dev/null; driver_state_init 506
bash "$KIT/scripts/polish-list.sh" reserve --ticket 506 900 77 "Send label wraps on a phone" >/dev/null
_driver_ship_reserve 506 43 >/dev/null 2>&1
want "an item another PR holds is not this run's to name" "" "$(_driver_ship_polish 506)"

echo "--- and the shipped body carries it ---"
list_body 900 "$(jq -r .body "$FIX/gh/issue-900.json")"$'\n- [ ] Ship item'
bash "$KIT/scripts/polish-list.sh" take 900 501 "Ship item" >/dev/null
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
want_in "the new PR's body names the reserved item" 'Fixed here, ticked on the list when this pull request merges' "$(grep -A80 '^pr edit 42' "$GH_LOG")"
want_in "and its first line closes the ticket" '--body Closes #501' "$(grep -A2 '^pr create' "$GH_LOG")"

echo "--- a repair that took items reserves them, and says so in its comment ---"
wt2="$FIX/wt507"
git -C "$REPO" worktree add -q "$wt2" -b "tkt-507/work" develop
printf 'repair\n' > "$wt2/r.txt"; git -C "$wt2" add r.txt; git -C "$wt2" commit -qm "fix: repair"
git -C "$wt2" push -q origin tkt-507/work
fix_issue 507 OPEN "status:in-review,screen:inbox"; driver_state_init 507 --worktree "$wt2" --branch "tkt-507/work"
driver_state_set 507 claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
driver_state_set 507 mode repair; driver_state_set 507 pr 88
driver_state_put 507 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 507 review
driver_state_put 507 repair '{"step":"repair","cause":"a clash"}'
for st in reenter repair fix self-check review record; do driver_state_done 507 "$st"; done
list_body 900 $'## Items\n- [ ] Header weight\n'
bash "$KIT/scripts/polish-list.sh" take 900 507 "Header weight" >/dev/null
printf '[{"number":88}]\n' > "$FIX/gh/prs.json"; : > "$FIX/pr-created-tkt-507_work"; : > "$FIX/pr-created-88"
printf '{"number":88,"isDraft":false,"body":"A body a person wrote.\\n\\nCloses #507"}\n' > "$FIX/gh/pr-view.json"
: > "$GH_LOG"
driver_step_ship 507 >/dev/null 2>&1
want "the repair's take is reserved for its PR" "- [ ] Header weight (in PR #88)" "$(jq -r .body "$FIX/gh/issue-900.json" | grep 'Header weight')"
want_in "named in the repair comment"      'Header weight \(#900\)' "$(grep -A20 '^pr comment 88' "$GH_LOG")"
want_not_in "and the PR's own words are not rewritten" '^pr edit 88' "$(cat "$GH_LOG")"


echo "--- a full list rides along with another ticket, at most polishListFull items ---"
list_body 900 "$(printf '## Items\n'; for i in 1 2 3 4 5 6 7 8 9 10; do printf -- '- [ ] full item %s\n' "$i"; done)"
fix_issue 508 OPEN "status:claimed,screen:inbox"; driver_state_init 508
fact=$(driver_fact_polish_list 508)
want_in "a full list lends its items"      'full item 8' "$fact"
want_not_in "but no more than 8 to one change" 'full item 9' "$fact"
jq '.labels += [{name:"status:claimed"}]' "$FIX/gh/issue-900.json" > "$FIX/gh/c.json" && mv "$FIX/gh/c.json" "$FIX/gh/issue-900.json"
driver_state_init 900
fact=$(driver_fact_polish_list 900)
want_in "the list's own run still gets all of it" 'full item 10' "$fact"

suite_end "$FAILED"
