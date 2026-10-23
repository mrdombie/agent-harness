#!/usr/bin/env bash
# review-priority.test.sh — under release.mergeFirst the driver's review model runs only
# for a ticket at release.reviewPriorities (default P0 P1); anything else ships on CI with
# no model call. A person's stop still blocks. With mergeFirst off, every ticket is
# reviewed. (The owner, 2026-10-23: speed-up 3 of 3.)
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fix_real_briefs
BT="$HERE/../build-ticket"

# The run's config lives outside the repo, so each case flips the switch without a commit.
BASECFG="$FIX/base.json"; RUNCFG="$FIX/run.json"
jq --arg r "$FIX/trees" '.gates = {"local": ["echo lint-ok"]} | .worktreeRoot = $r | .commit = {"parkType": "chore"}' \
  "$HARNESS_CFG_PATH" > "$BASECFG"
export HARNESS_CFG_PATH="$RUNCFG" HARNESS_CFG="$RUNCFG"; cp "$BASECFG" "$RUNCFG"
mkdir -p "$REPO/config"; printf '{ "lint": "loose" }\n' > "$REPO/config/app.json"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "a project with a config file"
git init -q --bare "$FIX/origin"; git -C "$REPO" remote add origin "$FIX/origin"; git -C "$REPO" push -q origin develop

export HARNESS_STATE_DIR="$STATE"
. "$HERE/../driver-env.sh" || exit 1
. "$HERE/../state.sh" || exit 1
. "$HERE/../steps/review.sh" || exit 1
cfg() { jq "$1" "$BASECFG" > "$RUNCFG"; }
mf_on()  { cfg '.release = {mergeFirst: true, done: false}'; }
mf_off() { cfg '.release = {mergeFirst: false, done: false}'; }

issue() { # <n> <labels-csv>
  jq -n --argjson n "$1" --arg l "$2" '{number:$n, state:"OPEN", title:"Make lint strict", body:$b,
    labels:($l|split(",")|map(select(length>0)|{name:.}))}' --arg b 'In `config/app.json`, change `lint` from "loose" to "strict":
```json
{ "lint": "strict" }
```' > "$FIX/gh/issue-$1.json"
}
cat > "$BIN/claude-q" <<'SH'
#!/usr/bin/env bash
step=""; prev=""; for a in "$@"; do [ "$prev" = --name ] && step="$a"; prev="$a"; done
[ ! -x "$FIX/ai/$step.do" ] || "$FIX/ai/$step.do" </dev/null >/dev/null 2>&1
exec "$BIN/claude" "$@"
SH
chmod +x "$BIN/claude-q"; export DRIVER_CLAUDE="$BIN/claude-q"
printf '#!/usr/bin/env bash\nset -e\nprintf "{ \\"lint\\": \\"strict\\" }\\n" > config/app.json; git add config/app.json; git commit -qm "chore(config): lint strict"\n' > "$FIX/ai/quick.do"
chmod +x "$FIX/ai/quick.do"
fix_ai quick "$(jq -c . "$DRIVER_BRIEFS/examples/quick.valid.json")" superpowers:verification-before-completion
REVIEW_SHIP=$(jq -c . "$DRIVER_BRIEFS/examples/review.valid-ship-clean.json")

run() { # <ticket> — a whole run; sets rc, out
  fix_ai review "$REVIEW_SHIP" superpowers:requesting-code-review
  : > "$CLAUDE_LOG"; : > "$GH_LOG"
  rc=0; out=$(bash "$BT" "$1" 2>&1) || rc=$?
}
calls() { tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//'; }
shipped() { if grep -q 'pr merge .*--auto' "$GH_LOG"; then echo shipped; else echo held; fi; }

echo "--- merge first: a P2 ticket's run makes no review model call and ships ---"
mf_on; issue 201 "status:ready,P2"; run 201
want "the run finishes"                 0 "$rc"
want "the only model call is the build" "quick" "$(calls)"
want_in "it says why"                   'review: skipped \(P2, merge-first: ships on CI\)' "$out"
want "review is marked done, record and ship follow" "start,size,quick,review,ship" "$(driver_state_get 201 'done|join(",")')"
want "and it ships"                     shipped "$(shipped)"

echo "--- merge first: a P1 ticket's run reviews ---"
mf_on; issue 202 "status:ready,P1"; run 202
want "the run finishes"                 0 "$rc"
want "build, then the review model"     "quick review" "$(calls)"
want_not_in "no skip line"              'review: skipped' "$out"

echo "--- merge first: a P3 quick-route run skips review ---"
mf_on; issue 203 "status:ready,P3"; run 203
want "on the quick route"               quick "$(driver_state_get 203 route)"
want "no review model call"             "quick" "$(calls)"
want_in "said as P3"                    'review: skipped \(P3, merge-first' "$out"
want "and it ships"                     shipped "$(shipped)"

echo "--- merge first off: a P2 is reviewed ---"
mf_off; issue 204 "status:ready,P2"; run 204
want "the review model runs"            "quick review" "$(calls)"
want "and it ships"                     shipped "$(shipped)"

echo "--- merge first: a person's Critical still blocks a P2 ---"
mf_on; issue 205 "status:ready,P2"
printf 'pm named a blocking finding on #205 on 2026-10-23: Critical (lost data): the save drops the row\n' > "$FIX/person-stop.out"
printf '1\n' > "$FIX/person-stop.rc"
run 205
want "it is not shipped"                held "$(shipped)"
want_not_in "the stop is not skipped past" 'review: skipped' "$out"
want_in "the person's stop is named"    'a person has stopped this' "$out"
rm -f "$FIX/person-stop.out" "$FIX/person-stop.rc"

echo "--- the step: priority, the PR's own label, the setting ---"
git -C "$REPO" worktree add -q "$FIX/wt300" -b tkt-300/x develop
printf '{ "lint": "strict" }\n' > "$FIX/wt300/config/app.json"; git -C "$FIX/wt300" commit -qam "config"
step() { # <ticket> <ticket labels> [pr labels] — one review step on a fresh record; sets rc, out
  driver_state_init "$1" --worktree "$FIX/wt300" --branch tkt-300/x
  fix_issue "$1" OPEN "status:claimed,$2"
  rm -f "$FIX/pr-created-7$1"
  if [ -n "${3+x}" ]; then
    driver_state_set "$1" pr "7$1"; : > "$FIX/pr-created-7$1"
    jq -n --arg l "$3" '{number:1, isDraft:false, labels:($l|split(",")|map(select(length>0)|{name:.}))}' > "$FIX/gh/pr-view.json"
  fi
  fix_ai review "$REVIEW_SHIP" superpowers:requesting-code-review
  : > "$CLAUDE_LOG"; rc=0; out=$(driver_step_review "$1" 2>&1) || rc=$?
}
mf_on
step 301 ""; want "unprioritised skips" "" "$(calls)"; want_in "said" 'skipped \(no priority' "$out"
want "the answer is a SHIP for record" SHIP "$(jq -r .verdict "$(driver_state_dir 301)/steps/review.json")"
step 302 "P1,polish-list"; want "a polish list skips" "" "$(calls)"
step 303 "P0"; want "a P0 reviews" "review" "$(calls)"
step 304 "P1" "P2"; want "the PR's own P2 wins over its ticket's P1" "" "$(calls)"
step 305 "P3" "P1"; want "the PR's own P1 wins over its ticket's P3" "review" "$(calls)"
step 306 "P2" ""; want "a PR with no P label takes its ticket's" "" "$(calls)"
cfg '.release = {mergeFirst: true, done: false, reviewPriorities: ["P0","P1","P2"]}'
step 307 "P2"; want "release.reviewPriorities is read" "review" "$(calls)"
cfg '.release = {mergeFirst: true, done: true}'
step 308 "P2"; want "a done release reviews" "review" "$(calls)"
mf_on; rm -f "$FIX/gh/issue-309.json"
driver_state_init 309 --worktree "$FIX/wt300" --branch tkt-300/x
fix_ai review "$REVIEW_SHIP" superpowers:requesting-code-review
: > "$CLAUDE_LOG"; DRIVER_LOOKUP_TRIES=1 driver_step_review 309 >/dev/null 2>&1
want "labels that cannot be read: it reviews" "review" "$(calls)"

suite_end "$FAILED"
