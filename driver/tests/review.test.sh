#!/usr/bin/env bash
# review.test.sh — review's job is to end, and to end PROPORTIONATELY. Two rounds,
# and a Critical, a Major or a Minor sends the work back; a Nit never does. Without a ceiling the median
# screen fix took seven rejections and six hours; without a grade, a spacing step
# cost the same round a dead control needed.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/review.sh" || exit 1
fix_issue 101 OPEN "status:claimed,project:widgets"
driver_state_init 101 --worktree "$REPO"
fix_brief review superpowers:requesting-code-review

echo "--- a clean review ships ---"
fix_ai review '{"verdict":"SHIP","findings":[]}' superpowers:requesting-code-review
out=$(driver_step_review 101 2>&1); rc=$?
want "it finishes"        "0" "$rc"
want "round 1 is counted" "1" "$(driver_state_count 101 review)"

echo "--- a Major in round 1 goes back to the build step ---"
driver_state_init 102 --worktree "$REPO"
fix_issue 102 OPEN "status:claimed,project:widgets"
fix_ai review '{"verdict":"BLOCKED","findings":[{"file":"a.sh","line":3,"grade":"major","summary":"a dead control","reason":"the person clicks Save and nothing is saved"}]}' superpowers:requesting-code-review
out=$(driver_step_review 102 2>&1); rc=$?
want "it asks for rework"       "30" "$rc"
want_in "and names the finding" 'dead control' "$out"
want_in "and says what grade sent it back" 'major' "$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')"
want "round 1 counted"          "1"  "$(driver_state_count 102 review)"

echo "--- and again in round 2 ---"
rc=0; driver_step_review 102 >/dev/null 2>&1 || rc=$?
want "round 2 still reworks" "30" "$rc"
want "round 2 counted"       "2"  "$(driver_state_count 102 review)"

echo "--- after two rounds the review stops asking for rework ---"
# The ceiling is on the ROUNDS, not on the outcome. Round three does not send the
# work back; every blocking finding stays with the ticket and the ship step is what
# refuses. Nothing is filed.
: > "$GH_LOG"
out=$(driver_step_review 102 2>&1); rc=$?
want "the third pass does not rework"      "0" "$rc"
want "the finding is still on the answer"  "1" \
  "$(jq -r '(.findings // []) | length' "$(driver_state_dir 102)/steps/review.json")"
want_not_in "and no ticket is filed for it" 'issue create' "$(cat "$GH_LOG")"

echo "--- a Minor sends work back, like a Major ---"
# Minors filed as follow-ups made every passing review open new tickets: 110 of the
# 339 bugs filed in one week. A Minor is fixed in the change that caused it.
: > "$GH_LOG"
driver_state_init 107 --worktree "$REPO"
fix_issue 107 OPEN "status:claimed,project:widgets"
fix_ai review '{"verdict":"BLOCKED","findings":[{"file":"a.sh","line":3,"grade":"minor","summary":"the retry row sits a step off the scale","reason":"the row looks misaligned"}]}' \
  superpowers:requesting-code-review
out=$(driver_step_review 107 2>&1); rc=$?
want "round 1 with only a Minor asks for rework" "30" "$rc"
want_in "and names the Minor"            'retry row sits a step off' "$out"
want_not_in "and files no ticket"        'issue create' "$(cat "$GH_LOG")"

echo "--- SHIP beside a Minor in round 1 is refused ---"
driver_state_init 108 --worktree "$REPO"
fix_issue 108 OPEN "status:claimed,project:widgets"
fix_ai review '{"verdict":"SHIP","findings":[{"file":"a.sh","line":1,"grade":"minor","summary":"first small thing","reason":"a"}]}' \
  superpowers:requesting-code-review
: > "$GH_LOG"
out=$(driver_step_review 108 2>&1); rc=$?
want "a SHIP verdict cannot carry a Minor" "24" "$rc"
want_not_in "and nothing is filed"         'issue create' "$(cat "$GH_LOG")"

echo "--- a Nit is dropped, and the drop is said out loud ---"
# Dropped silently is indistinguishable from never raised. The count is what lets a
# reader tell "the reviewer found nothing" from "the reviewer found taste".
: > "$GH_LOG"
driver_state_init 109 --worktree "$REPO"
fix_issue 109 OPEN "status:claimed,project:widgets"
fix_ai review '{"verdict":"SHIP","findings":[
  {"file":"a.sh","line":1,"grade":"nit","summary":"the comma could be an em dash","reason":"taste"},
  {"file":"b.sh","line":2,"grade":"nit","summary":"prefers single quotes","reason":"taste"}]}' \
  superpowers:requesting-code-review
out=$(driver_step_review 109 2>&1); rc=$?
want "it ships"                        "0" "$rc"
want_not_in "no ticket is filed"       'issue create' "$(cat "$GH_LOG")"
want_not_in "and the nit does not leave" 'em dash' "$(cat "$GH_LOG")"
want_in "and the drop is counted"      '2 nit' "$out"

echo "--- 1 Major + 5 Minors + 2 Nits: six go back, two are dropped, none filed ---"
: > "$GH_LOG"
driver_state_init 110 --worktree "$REPO"
fix_issue 110 OPEN "status:claimed,project:widgets"
fix_ai review '{"verdict":"BLOCKED","findings":[
  {"file":"a.sh","line":1,"grade":"major","summary":"the failed read renders the empty copy","reason":"a broken load reads as nothing here"},
  {"file":"b.sh","line":2,"grade":"minor","summary":"minor one","reason":"m1"},
  {"file":"b.sh","line":3,"grade":"minor","summary":"minor two","reason":"m2"},
  {"file":"b.sh","line":4,"grade":"minor","summary":"minor three","reason":"m3"},
  {"file":"b.sh","line":5,"grade":"minor","summary":"minor four","reason":"m4"},
  {"file":"b.sh","line":6,"grade":"minor","summary":"minor five","reason":"m5"},
  {"file":"c.sh","line":7,"grade":"nit","summary":"nit one","reason":"n1"},
  {"file":"c.sh","line":8,"grade":"nit","summary":"nit two","reason":"n2"}]}' \
  superpowers:requesting-code-review
out=$(driver_step_review 110 2>&1); rc=$?
want "round 1 sends them back"              "30" "$rc"
want_in "naming the Major"                  'the failed read renders the empty copy' "$out"
want_in "and the Minors"                    'minor three' "$out"
want_not_in "and not a Nit"                 'nit one' "$out"
want_in "counting six"                      '6 blocking' "$out"
: > "$GH_LOG"
i=0; while [ $i -le "$DRIVER_MAX_REVIEW_ROUNDS" ]; do driver_state_bump 110 review; i=$((i+1)); done
out=$(driver_step_review 110 2>&1); rc=$?
want "past the rounds it stops reworking"   "0" "$rc"
want_not_in "and NOTHING is filed"          'issue create' "$(cat "$GH_LOG")"
want_in "the dropped Nits are counted"      '2 nit' "$out"

echo "--- a review that never ran its skill is not a review ---"
driver_state_init 104 --worktree "$REPO"
fix_issue 104 OPEN "status:claimed"
fix_ai review '{"verdict":"SHIP","findings":[]}'
rc=0; driver_step_review 104 >/dev/null 2>&1 || rc=$?
want "it parks" "21" "$rc"

echo "--- a verdict the driver does not recognise is not a pass ---"
fix_ai review '{"verdict":"probably fine","findings":[]}' superpowers:requesting-code-review
out=$(driver_step_review 104 2>&1); rc=$?
want "an unknown verdict refuses" "24" "$rc"
want_in "and quotes it"           'probably fine' "$out"

echo "--- SHIP typed beside an open Critical is not a SHIP ---"
# The contract refuses this too, and that is exactly why the driver must: a check and
# the thing it checks derived from one input is one input away from agreeing about
# nothing. Past the rounds the rework branch stops firing, so without this the Critical
# walks into the ship step and lands.
fix_ai review '{"verdict":"SHIP","findings":[{"file":"a.sh","line":1,"grade":"critical","summary":"the export writes another workspace rows","reason":"one client sees another client data"}]}' superpowers:requesting-code-review
out=$(driver_step_review 104 2>&1); rc=$?
want "it refuses"                "24" "$rc"
want_in "and names the finding"  'another workspace' "$out"

echo "--- a grade the driver does not recognise is not a finding it can act on ---"
# A grade outside the scale has no effect defined for it, so acting on it means
# guessing. Silently treating it as non-blocking is how a Critical typed 'crit'
# ships; silently blocking on it is how a Nit costs a round.
fix_ai review '{"verdict":"BLOCKED","findings":[{"file":"a.sh","line":1,"grade":"severe","summary":"x","reason":"y"}]}' superpowers:requesting-code-review
out=$(driver_step_review 104 2>&1); rc=$?
want "an unknown grade refuses" "24" "$rc"
want_in "and quotes it"         'severe' "$out"

echo "--- a repair is reviewed on its own change, not the whole PR again ---"
# Re-reviewing the whole PR on every repair sent fixes, screens among them, after the
# owner had signed it off. The PR was reviewed before; the repair is what is new.
git -C "$REPO" worktree add -q "$FIX/wtr" -b tkt-120/work develop
mkdir -p "$FIX/wtr/screens" "$FIX/wtr/lib"; printf 'the PR change\n' > "$FIX/wtr/screens/Home.tsx"; printf 'a\n' > "$FIX/wtr/lib/a.ts"
git -C "$FIX/wtr" add . && git -C "$FIX/wtr" commit -qm "feat: the PR"
RB=$(git -C "$FIX/wtr" rev-parse HEAD)
# The trunk moves on, and the repair merges it in: its commits are the trunk's, not the repair's.
git -C "$REPO" checkout -q develop; printf 'trunk work\n' > "$REPO/develop-only.txt"
git -C "$REPO" add develop-only.txt && git -C "$REPO" commit -qm "trunk: another ticket"
git -C "$FIX/wtr" merge -q --no-edit develop
printf 'the repair\n' > "$FIX/wtr/repair-fix.txt"; git -C "$FIX/wtr" add . && git -C "$FIX/wtr" commit -qm "fix: the repair"
repair_rec() { # <ticket>
  driver_state_init "$1" --worktree "$FIX/wtr" --branch tkt-120/work
  driver_state_set "$1" mode repair; driver_state_set "$1" pr 88; driver_state_set "$1" repair_base "$RB"
  fix_issue "$1" OPEN "status:in-review"
}
repair_rec 120
fix_ai review '{"verdict":"SHIP","findings":[]}' superpowers:requesting-code-review
out=$(driver_step_review 120 2>&1); rc=$?
want "it finishes"                         "0" "$rc"
want_in "the repair's own file is reviewed" 'repair-fix.txt' "$(cat "$(driver_fact_dir 120 review)/DIFF")"
want_not_in "the PR's earlier change is not" 'screens/Home.tsx' "$(cat "$(driver_fact_dir 120 review)/DIFF")"
want_not_in "nor the trunk's commits a merge brought in" 'develop-only.txt' "$(cat "$(driver_fact_dir 120 review)/DIFF")"

echo "--- on a signed-off PR, a blocking finding on a screen parks for the owner; the verdict is never flipped ---"
# A fix there changes pixels after the sign-off: the owner's call. A Critical anywhere
# else is still fixed: filed away and shipped as SHIP, it landed a repair's own defect.
jq '.design = {"surfacePaths": ["screens/**"]}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
# The sign-off record is stubbed; the screen set is the real approval-kept.sh's.
cat > "$BIN/approval-kept" <<SH
#!/usr/bin/env bash
case "\$1" in
  signed-head) echo "\$*" >> "$FIX/ak.log"; [ "\${AK_RC:-0}" = 0 ] && echo 1111111111111111111111111111111111111111; exit "\${AK_RC:-0}" ;;
  screens) exec bash "$HERE/../../scripts/approval-kept.sh" screens ;;
  *) exit 9 ;;
esac
SH
chmod +x "$BIN/approval-kept"; export DRIVER_APPROVAL_KEPT="$BIN/approval-kept"
both='{"verdict":"BLOCKED","findings":[
  {"file":"screens/Home.tsx","line":4,"grade":"major","summary":"the card spacing is off the scale","reason":"it reads cramped"},
  {"file":"lib/a.ts","line":9,"grade":"major","summary":"the error branch is dropped","reason":"a failure shows as success"}]}'
code='{"verdict":"BLOCKED","findings":[{"file":"lib/a.ts","line":9,"grade":"critical","summary":"the repair returns another workspace data","reason":"wrong data"}]}'
screen='{"verdict":"BLOCKED","findings":[{"file":"screens/Home.tsx","line":4,"grade":"major","summary":"x","reason":"y"}]}'
: > "$GH_LOG"; AK_RC=0; export AK_RC; repair_rec 121
fix_ai review "$both" superpowers:requesting-code-review
out=$(driver_step_review 121 2>&1); rc=$?
want "a screen finding on a signed PR parks"   "24" "$rc"
want_in "for the owner, naming it"             '^Needs the owner: PR #88.*screens/Home.tsx' "$(driver_state_get 121 park_note)"
want "as a person's question"                  "person" "$(driver_state_get 121 park_cause)"
want "the verdict is the reviewer's"           "BLOCKED" "$(jq -r '.verdict' "$(driver_state_dir 121)/steps/review.json")"
want_not_in "and nothing is filed away"        'issue create' "$(cat "$GH_LOG")"
repair_rec 122
fix_ai review "$code" superpowers:requesting-code-review
out=$(driver_step_review 122 2>&1); rc=$?
want "a Critical off the screens is fixed, never shipped" "30" "$rc"
want "the verdict stays BLOCKED"               "BLOCKED" "$(jq -r '.verdict' "$(driver_state_dir 122)/steps/review.json")"
for c in "2 unreadable" "3 a-hold-removed-on-GitHub"; do
  set -- $c; AK_RC=$1; repair_rec 12$1
  fix_ai review "$screen" superpowers:requesting-code-review
  rc=0; driver_step_review 12$1 >/dev/null 2>&1 || rc=$?
  want "signed-head exit $1 ($2) counts as signed: it parks" "24" "$rc"
done
AK_RC=1; repair_rec 124
fix_ai review "$screen" superpowers:requesting-code-review
rc=0; driver_step_review 124 >/dev/null 2>&1 || rc=$?
want "never signed: a screen finding is fixed as any other" "30" "$rc"
want_in "asked with signed-head"               'signed-head 88' "$(cat "$FIX/ak.log")"
AK_RC=0; repair_rec 125
fix_ai review '{"verdict":"BLOCKED","findings":[{"file":"screens/Home.test.tsx","line":4,"grade":"major","summary":"x","reason":"y"}]}' superpowers:requesting-code-review
rc=0; driver_step_review 125 >/dev/null 2>&1 || rc=$?
want "a test under the screen globs is not a screen: it is fixed" "30" "$rc"
jq '.design.extraScreens = ["lib/a.ts"]' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
repair_rec 127
fix_ai review "$code" superpowers:requesting-code-review
rc=0; driver_step_review 127 >/dev/null 2>&1 || rc=$?
want "a file named in extraScreens is a screen: it parks" "24" "$rc"
jq '.design = {"surfacePaths": ["screens/**"]}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
: > "$FIX/ak.log"
driver_state_init 126 --worktree "$REPO"; fix_issue 126 OPEN "status:claimed"
fix_ai review "$screen" superpowers:requesting-code-review
rc=0; driver_step_review 126 >/dev/null 2>&1 || rc=$?
want "a build (not a repair) is not held" "30" "$rc"
want "and asks for no sign-off record"    "" "$(cat "$FIX/ak.log")"
jq 'del(.design)' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
unset DRIVER_APPROVAL_KEPT AK_RC

echo "--- from round 2 a Minor does not block: it goes on its screen's polish list ---"
# The owner, 2026-10-20: round 1 fixes Critical, Major and Minor; from round 2 only
# Critical and Major block. 86 of 117 latest findings were Minor, and the 4-5 hour
# loops were mostly Minor churn.
cat > "$FIX/sf" <<SH
#!/usr/bin/env bash
[ "\$1" = screens ] || exit 0
[ -n "\${SF_NONE:-}" ] && exit 0
echo inbox
[ -n "\${3:-}" ] && grep -q '^screens/Settings' "\$3" && echo settings
exit 0
SH
cat > "$FIX/pl" <<SH
#!/usr/bin/env bash
case "\$1" in add) printf '%s\n' "\$*" >> "$FIX/pl.adds"; exit "\${PL_RC:-0}" ;; esac
exit 0
SH
chmod +x "$FIX/sf" "$FIX/pl"; : > "$FIX/pl.adds"
export DRIVER_SCREEN_FINDINGS="$FIX/sf" DRIVER_POLISH_LIST="$FIX/pl"
minor='{"verdict":"BLOCKED","findings":[{"file":"screens/Settings.tsx","line":12,"grade":"minor","summary":"the save row sits 4px off the scale","reason":"it looks misaligned"}]}'
majmin='{"verdict":"BLOCKED","findings":[
  {"file":"lib/a.ts","line":9,"grade":"major","summary":"the error branch is dropped","reason":"a failure shows as success"},
  {"file":"lib/b.ts","line":3,"grade":"minor","summary":"the toast wording is stiff","reason":"reads oddly"}]}'
driver_state_init 130 --worktree "$REPO"; fix_issue 130 OPEN "status:claimed,screen:inbox"
fix_ai review "$minor" superpowers:requesting-code-review
rc=0; driver_step_review 130 >/dev/null 2>&1 || rc=$?
want "round 1: the Minor blocks"                 "30" "$rc"
want "and nothing goes on a list"                "" "$(cat "$FIX/pl.adds")"
out=$(driver_step_review 130 2>&1); rc=$?
want "round 2: the same Minor does not block"    "0" "$rc"
want_in "it lands on the polish list of the screen its file is on" '^add settings \[Minor\] the save row sits 4px off the scale — screens/Settings.tsx:12' "$(cat "$FIX/pl.adds")"
want "it leaves the findings"                    "0" "$(jq '[.findings[] | select(.grade == "minor")] | length' "$(driver_state_dir 130)/steps/review.json")"
want "and the verdict ships"                     "SHIP" "$(jq -r .verdict "$(driver_state_dir 130)/steps/review.json")"
want "recorded as deferred, with its list"       "settings" "$(jq -r .list "$(driver_state_dir 130)/steps/review.deferred.jsonl")"
want_in "and the deferral is said"               'do not block' "$out"

echo "--- round 2: a Major still blocks, the Minor beside it does not ---"
: > "$FIX/pl.adds"
driver_state_init 131 --worktree "$REPO"; fix_issue 131 OPEN "status:claimed,screen:inbox"; driver_state_bump 131 review
fix_ai review "$majmin" superpowers:requesting-code-review
out=$(driver_step_review 131 2>&1); rc=$?
want "the Major sends it back"                   "30" "$rc"
want_in "named as what blocks"                   'error branch is dropped' "$out"
want_not_in "and the Minor is not among it"      'blocking.*toast wording' "$out"
want_in "the Minor goes on the ticket's screen's list" '^add inbox \[Minor\] the toast wording is stiff' "$(cat "$FIX/pl.adds")"
want "only the Major is left to fix"             "major" "$(jq -r "[.findings[] | $(driver_blocking_select) | .grade] | join(\" \")" "$(driver_state_dir 131)/steps/review.json")"

echo "--- round 2 with no screen: the Minor is a note in the PR, still not blocking ---"
: > "$FIX/pl.adds"
driver_state_init 132 --worktree "$REPO"; fix_issue 132 OPEN "status:claimed"; driver_state_bump 132 review
fix_ai review "$minor" superpowers:requesting-code-review
rc=0; SF_NONE=1 driver_step_review 132 >/dev/null 2>&1 || rc=$?
want "it does not block"                         "0" "$rc"
want "no list is written"                        "" "$(cat "$FIX/pl.adds")"
. "$HERE/../steps/ship.sh" || exit 1
sec=$(_driver_ship_deferred 132)
want_in "the PR body says Minor, deferred"       '^## Minor, deferred' "$sec"
want_in "with the finding, its file and line"    'screens/Settings.tsx:12 — the save row sits 4px off the scale.*no screen resolved' "$sec"
want "a run with nothing deferred says nothing"  "" "$(driver_state_init 136 --worktree "$REPO"; _driver_ship_deferred 136)"
driver_state_init 133 --worktree "$REPO"; fix_issue 133 OPEN "status:claimed,screen:inbox"; driver_state_bump 133 review
fix_ai review "$minor" superpowers:requesting-code-review
rc=0; PL_RC=1 driver_step_review 133 >/dev/null 2>&1 || rc=$?
want "a list that cannot be written: still not blocking" "0" "$rc"
want_in "and kept for the PR"                    'no screen resolved' "$(_driver_ship_deferred 133)"

echo "--- past the round limit, with the first round's set configured as Critical and Major ---"
# #13621: round 3 of 2, two Minors and a Nit, DRIVER_BLOCKING_GRADES="critical major".
# The two sets matched, so nothing was deferred, the reviewer's BLOCKED stood with
# nothing blocking under it, and ship parked the ticket on Minors.
late='{"verdict":"BLOCKED","findings":[
  {"file":"screens/Settings.tsx","line":4,"grade":"minor","summary":"a doc block sits above the wrong function","reason":"misleads a reader"},
  {"file":"lib/b.ts","line":7,"grade":"minor","summary":"a pin test can pass vacuously","reason":"weak test"},
  {"file":"lib/b.ts","line":9,"grade":"nit","summary":"judge reads a stack trace as a catch","reason":"taste"}]}'
: > "$FIX/pl.adds"
driver_state_init 140 --worktree "$REPO"; fix_issue 140 OPEN "status:claimed,screen:inbox"
driver_state_bump 140 review; driver_state_bump 140 review
fix_ai review "$late" superpowers:requesting-code-review
rc=0; DRIVER_BLOCKING_GRADES="critical major" driver_step_review 140 >/dev/null 2>&1 || rc=$?
want "round 3, Minors and a Nit only: it finishes"  "0" "$rc"
want "and the verdict is not BLOCKED"               "SHIP" "$(jq -r .verdict "$(driver_state_dir 140)/steps/review.json")"
want "both Minors go on a polish list"              "2" "$(grep -c '\[Minor\]' "$FIX/pl.adds")"
want "and the Nit does not"                         "0" "$(grep -c 'stack trace' "$FIX/pl.adds")"
want "the Minors are recorded as deferred"          "2" "$(grep -c . "$(driver_state_dir 140)/steps/review.deferred.jsonl" 2>/dev/null)"
: > "$FIX/pl.adds"
driver_state_init 141 --worktree "$REPO"; fix_issue 141 OPEN "status:claimed,screen:inbox"
driver_state_bump 141 review; driver_state_bump 141 review
fix_ai review "$majmin" superpowers:requesting-code-review
rc=0; DRIVER_BLOCKING_GRADES="critical major" driver_step_review 141 >/dev/null 2>&1 || rc=$?
want "round 3 with a Major: BLOCKED"                "BLOCKED" "$(jq -r .verdict "$(driver_state_dir 141)/steps/review.json")"
want "the Major stays to clear"                     "major" "$(jq -r "[.findings[] | $(driver_blocking_select) | .grade] | join(\" \")" "$(driver_state_dir 141)/steps/review.json")"
driver_state_init 142 --worktree "$REPO"; fix_issue 142 OPEN "status:claimed,screen:inbox"
driver_state_bump 142 review; driver_state_bump 142 review
fix_ai review "$late" superpowers:requesting-code-review
rc=0; driver_step_review 142 >/dev/null 2>&1 || rc=$?
want "round 3 with the default sets: SHIP too"      "SHIP" "$(jq -r .verdict "$(driver_state_dir 142)/steps/review.json")"
driver_state_init 143 --worktree "$REPO"; fix_issue 143 OPEN "status:claimed"
driver_state_bump 143 review; driver_state_bump 143 review
fix_ai review '{"verdict":"BLOCKED","findings":[]}' superpowers:requesting-code-review
rc=0; driver_step_review 143 >/dev/null 2>&1 || rc=$?
want "a BLOCKED that names nothing stays BLOCKED"   "BLOCKED" "$(jq -r .verdict "$(driver_state_dir 143)/steps/review.json")"

echo "--- a repair counts its own rounds the same way ---"
cat > "$BIN/approval-kept" <<'SH'
#!/usr/bin/env bash
case "$1" in signed-head) exit 1 ;; screens) cat ;; esac
SH
chmod +x "$BIN/approval-kept"; export DRIVER_APPROVAL_KEPT="$BIN/approval-kept"
: > "$FIX/pl.adds"
repair_rec 134
fix_ai review "$minor" superpowers:requesting-code-review
rc=0; driver_step_review 134 >/dev/null 2>&1 || rc=$?
want "repair round 1: the Minor blocks"          "30" "$rc"
rc=0; driver_step_review 134 >/dev/null 2>&1 || rc=$?
want "repair round 2: it does not"               "0" "$rc"
want_in "and lands on the polish list"           '^add settings \[Minor\]' "$(cat "$FIX/pl.adds")"
fix_ai review "$majmin" superpowers:requesting-code-review
repair_rec 135; driver_state_bump 135 review
rc=0; driver_step_review 135 >/dev/null 2>&1 || rc=$?
want "repair round 2: a Major still blocks"      "30" "$rc"

echo "--- on a signed-off PR, a Minor on its screens goes on the polish list: no park, no fix round ---"
# The owner's rule: after sign-off a screen's review note is polish, never a call for
# the owner. #13339 parked on one Minor (a HelpTip bubble off a 375px phone).
jq '.design = {"surfacePaths": ["screens/**"]}' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
cat > "$BIN/approval-kept" <<SH
#!/usr/bin/env bash
case "\$1" in
  signed-head) echo 1111111111111111111111111111111111111111 ;;
  screens) exec bash "$HERE/../../scripts/approval-kept.sh" screens ;;
esac
SH
chmod +x "$BIN/approval-kept"; export DRIVER_APPROVAL_KEPT="$BIN/approval-kept"
: > "$FIX/pl.adds"; : > "$GH_LOG"
repair_rec 150
fix_ai review "$minor" superpowers:requesting-code-review
out=$(driver_step_review 150 2>&1); rc=$?
want "repair round 1, one Minor on a signed screen: it carries on" "0" "$rc"
want "and parks for nobody"                      "" "$(driver_state_get 150 park_note)"
want_in "the Minor is on its screen's polish list, citing the PR" '^add settings \[Minor\] the save row sits 4px off the scale — screens/Settings.tsx:12 .*PR #88' "$(cat "$FIX/pl.adds")"
want "it leaves the findings, so no fix round touches the screen" "0" "$(jq '.findings | length' "$(driver_state_dir 150)/steps/review.json")"
want "and the verdict ships"                     "SHIP" "$(jq -r .verdict "$(driver_state_dir 150)/steps/review.json")"
want "recorded as deferred"                      "settings" "$(jq -r .list "$(driver_state_dir 150)/steps/review.deferred.jsonl")"
want_not_in "and nothing is filed"               'issue create' "$(cat "$GH_LOG")"
: > "$FIX/pl.adds"
repair_rec 151
fix_ai review '{"verdict":"BLOCKED","findings":[
  {"file":"screens/Settings.tsx","line":12,"grade":"minor","summary":"the save row sits 4px off the scale","reason":"it looks misaligned"},
  {"file":"lib/b.ts","line":3,"grade":"minor","summary":"the toast wording is stiff","reason":"reads oddly"}]}' superpowers:requesting-code-review
rc=0; driver_step_review 151 >/dev/null 2>&1 || rc=$?
want "a Minor off the screens is still fixed in round 1" "30" "$rc"
want "only the screen's Minor went on a list"    "1" "$(grep -c . "$FIX/pl.adds")"
want "the code Minor is what is left to fix"     "lib/b.ts" "$(jq -r '[.findings[].file] | join(" ")' "$(driver_state_dir 151)/steps/review.json")"
: > "$FIX/pl.adds"
repair_rec 152
fix_ai review "$screen" superpowers:requesting-code-review
out=$(driver_step_review 152 2>&1); rc=$?
want "a Major on a signed screen still parks for the owner" "24" "$rc"
want_in "naming it"                              '^Needs the owner: PR #88.*major screens/Home.tsx' "$(driver_state_get 152 park_note)"
want "and nothing goes on a list"                "" "$(cat "$FIX/pl.adds")"
jq 'del(.design)' "$REPO/.claude/harness.json" > "$FIX/h" && mv "$FIX/h" "$REPO/.claude/harness.json"
unset DRIVER_APPROVAL_KEPT DRIVER_SCREEN_FINDINGS DRIVER_POLISH_LIST

exit $FAILED
