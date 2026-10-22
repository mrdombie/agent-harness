#!/usr/bin/env bash
# review-once.test.sh — the model reviews a change once. A second review runs only when
# the fix round touched a file the first review never saw, and then only Critical and
# Major block. Never a third. (The owner, 2026-10-22: review was 26% of driver usage.)
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/review.sh" || exit 1
fix_brief review superpowers:requesting-code-review "Review round {{ROUND}}. The change: {{DIFF}} Renders: {{RENDERS}}"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/sf"
printf '#!/usr/bin/env bash\ncase "$1" in add) printf "%%s\\n" "$*" >> "$FIX/pl.adds" ;; esac\nexit 0\n' > "$FIX/pl"
chmod +x "$FIX/sf" "$FIX/pl"; : > "$FIX/pl.adds"
export DRIVER_SCREEN_FINDINGS="$FIX/sf" DRIVER_POLISH_LIST="$FIX/pl"

# ro_tree <ticket> — a branch carrying one reviewed file, a.sh.
ro_tree() {
  git -C "$REPO" worktree add -q "$FIX/ro$1" -b "tkt-$1/work" develop
  printf 'a\n' > "$FIX/ro$1/a.sh"; git -C "$FIX/ro$1" add -A; git -C "$FIX/ro$1" commit -qm "feat: a"
  driver_state_init "$1" --worktree "$FIX/ro$1" --branch "tkt-$1/work"
  fix_issue "$1" OPEN "status:claimed"
}
# ro_fix <ticket> <file> — a fix round: one commit on that file, and the fix step counted.
ro_fix() {
  printf 'fixed\n' >> "$FIX/ro$1/$2"; git -C "$FIX/ro$1" add -A; git -C "$FIX/ro$1" commit -qm "fix: $2"
  driver_state_bump "$1" fix
}
calls() { grep -c '^review$' "$CLAUDE_LOG"; }
rj() { printf '%s/steps/review.json' "$(driver_state_dir "$1")"; }
major_a='{"verdict":"BLOCKED","findings":[{"id":"f1","file":"a.sh","line":1,"grade":"major","summary":"the save is dropped","reason":"a failure shows as success","fix":"keep it"}]}'
# What a reviewer called when it should not be would say: a Major that blocks.
planted='{"verdict":"BLOCKED","findings":[{"id":"p1","file":"a.sh","line":1,"grade":"major","summary":"PLANTED a second review ran","reason":"r","fix":"f"}]}'

echo "--- the fix round stays inside the reviewed diff: no second review ---"
ro_tree 160; : > "$CLAUDE_LOG"
fix_ai review "$major_a" superpowers:requesting-code-review
rc=0; driver_step_review 160 >/dev/null 2>&1 || rc=$?
want "round 1: the Major goes to fix"            "30" "$rc"
want "one review call"                           "1" "$(calls)"
ro_fix 160 a.sh
fix_ai review "$planted" superpowers:requesting-code-review
rc=0; out=$(driver_step_review 160 2>&1) || rc=$?
want "the pass after the fix finishes"           "0" "$rc"
want "and calls no reviewer"                     "1" "$(calls)"
want "the verdict ships"                         "SHIP" "$(jq -r .verdict "$(rj 160)")"
want "nothing blocks"                            "0" "$(_driver_count "$(rj 160)" blocking)"
want_not_in "the planted answer never landed"    'PLANTED' "$(cat "$(rj 160)")"
want_in "and says why"                           'no new review — every file changed since the reviewed head' "$out"
want "the pass is counted"                       "2" "$(driver_state_count 160 review)"

echo "--- the fix round touches a new file: one second review, only Critical and Major block ---"
ro_tree 161; : > "$CLAUDE_LOG"; : > "$FIX/pl.adds"
fix_ai review "$major_a" superpowers:requesting-code-review
rc=0; driver_step_review 161 >/dev/null 2>&1 || rc=$?
want "round 1: the Major goes to fix"            "30" "$rc"
ro_fix 161 z.sh
fix_ai review '{"verdict":"BLOCKED","findings":[
  {"id":"z1","file":"z.sh","line":1,"grade":"major","summary":"the new helper swallows the error","reason":"a failure shows as success","fix":"return it"},
  {"id":"z2","file":"z.sh","line":2,"grade":"minor","summary":"the helper name is vague","reason":"reads oddly","fix":"rename"}]}' \
  superpowers:requesting-code-review
rc=0; out=$(driver_step_review 161 2>&1) || rc=$?
want "the second review ran"                     "2" "$(calls)"
want_in "naming the file the first never saw"    'never saw: z.sh' "$out"
want_in "and the reviewer is told the round rule" 'ROUND 2: only critical major block' "$(cat "$FIX/claude-stdin-review.txt")"
want "its Major goes to fix"                     "30" "$rc"
want "only the Major blocks"                     "major" "$(jq -r "[.findings[] | $(driver_blocking_select) | .grade] | join(\" \")" "$(rj 161)")"
want "the Minor is deferred, not blocking"       "1" "$(grep -c '"grade":"minor"' "$(driver_state_dir 161)/steps/review.deferred.jsonl")"

echo "--- never a third review, whatever the next fix touches ---"
ro_fix 161 y.sh
fix_ai review "$planted" superpowers:requesting-code-review
rc=0; out=$(driver_step_review 161 2>&1) || rc=$?
want "the third pass finishes"                   "0" "$rc"
want "and calls no reviewer"                     "2" "$(calls)"
want "the verdict ships"                         "SHIP" "$(jq -r .verdict "$(rj 161)")"
want_in "saying the rounds are spent"            'review round\(s\) are spent — never a third' "$out"

echo "--- no fix round since the review: the findings stand ---"
ro_tree 162; : > "$CLAUDE_LOG"
fix_ai review "$major_a" superpowers:requesting-code-review
DRIVER_MAX_REVIEW_ROUNDS=1 driver_step_review 162 >/dev/null 2>&1
rc=0; DRIVER_MAX_REVIEW_ROUNDS=1 driver_step_review 162 >/dev/null 2>&1 || rc=$?
want "past the rounds it calls no reviewer"      "1" "$(calls)"
want "the Major is still on the answer"          "1" "$(_driver_count "$(rj 162)" blocking)"

echo "--- a refused answer is no review: the next pass calls the reviewer ---"
ro_tree 164; : > "$CLAUDE_LOG"
fix_ai review '{"verdict":"probably fine","findings":[]}' superpowers:requesting-code-review
rc=0; driver_step_review 164 >/dev/null 2>&1 || rc=$?
want "the unread verdict refuses"                "24" "$rc"
fix_ai review '{"verdict":"SHIP","findings":[{"id":"c1","file":"a.sh","line":1,"grade":"critical","summary":"another workspace rows","reason":"r","fix":"f"}]}' superpowers:requesting-code-review
rc=0; driver_step_review 164 >/dev/null 2>&1 || rc=$?
want "the next pass reviews"                     "2" "$(calls)"
want "and refuses SHIP beside a Critical"        "24" "$rc"
fix_ai review '{"verdict":"BLOCKED","findings":[{"id":"c2","file":"a.sh","line":1,"grade":"critical","summary":"still there","reason":"r","fix":"f"}]}' superpowers:requesting-code-review
rc=0; driver_step_review 164 >/dev/null 2>&1 || rc=$?
want "past the rounds, still not skipped on a refused answer" "3" "$(calls)"
want "and the Critical is not cleared"           "1" "$(_driver_count "$(rj 164)" blocking)"

echo "--- the settings ---"
jq '.review = {maxRounds: 1}' "$HARNESS_CFG" > "$FIX/ro-one.json"
want "review.maxRounds is read"                  "1" "$(HARNESS_CFG_PATH="$FIX/ro-one.json" HARNESS_CFG="$FIX/ro-one.json" DRIVER_MAX_REVIEW_ROUNDS= bash -c '. "$1/../driver-env.sh" && printf %s "$DRIVER_MAX_REVIEW_ROUNDS"' _ "$HERE")"
jq '.review = {maxRounds: "two"}' "$HARNESS_CFG" > "$FIX/ro-bad.json"
want "a maxRounds that is not a number is 2"     "2" "$(HARNESS_CFG_PATH="$FIX/ro-bad.json" HARNESS_CFG="$FIX/ro-bad.json" DRIVER_MAX_REVIEW_ROUNDS= bash -c '. "$1/../driver-env.sh" && printf %s "$DRIVER_MAX_REVIEW_ROUNDS"' _ "$HERE")"
jq '.review = {secondOnlyOnNewFiles: false}' "$HARNESS_CFG" > "$FIX/ro-every.json"
ro_tree 163; : > "$CLAUDE_LOG"
fix_ai review "$major_a" superpowers:requesting-code-review
HARNESS_CFG="$FIX/ro-every.json" driver_step_review 163 >/dev/null 2>&1
ro_fix 163 a.sh
fix_ai review '{"verdict":"SHIP","findings":[]}' superpowers:requesting-code-review
rc=0; out=$(HARNESS_CFG="$FIX/ro-every.json" driver_step_review 163 2>&1) || rc=$?
want "secondOnlyOnNewFiles false: the second review runs" "2" "$(calls)"
want_in "and says so"                            'secondOnlyOnNewFiles is off' "$out"

suite_end "$FAILED"
