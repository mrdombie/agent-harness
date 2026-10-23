#!/usr/bin/env bash
# repair-base-red.test.sh — a red the base branch has too waits for the base; it is never
# repaired in the PR and never parked as a question. The PM's standing answer (the PM,
# 2026-10-21): "a red from a test this PR does not touch that also fails on develop waits
# for develop's fix and is never repaired in the PR." #13365, #13314 and #8476 parked on
# the owner asking exactly that.
#
#   every red in tests outside the diff, red on the base too → exit 34, no model call, no
#     label, no park; the ticket is on the base-wait ledger naming the check
#   the same test red only on the PR (it passes on the base)  → repaired as before
#   a failing test the PR's diff touches, red on the base too → the PR's own: repaired
#   a mix                                                     → the PR's own reds only
#   the coordinator queues the wait again when the base goes green, or after the hours
#   self-check does not count a gate red only on those base tests
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fix_real_briefs
. "$HERE/../steps/repair.sh" || exit 1
. "$HERE/../steps/self-check.sh" || exit 1
export BASE_WAITS_FILE="$FIX/base-waits.tsv"; BASE_WAITS="$BASE_WAITS_FILE"

cat > "$BIN/claude-hands" <<'SH'
#!/usr/bin/env bash
[ -f "$FIX/ai/repair.sh" ] && bash "$FIX/ai/repair.sh" >/dev/null 2>&1
exec "$BIN/claude" "$@"
SH
chmod +x "$BIN/claude-hands"; export DRIVER_CLAUDE="$BIN/claude-hands"
# gh for the REST reads base-wait.sh makes: check runs per commit, the base's commits, job logs.
cat > "$BIN/gh-basered" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "api repos/acme/widgets/commits?sha=develop&per_page="*) cat "$FIX/gh/base-commits.json" 2>/dev/null || exit 1 ;;
  "api repos/acme/widgets/commits/"*"/check-runs"*)
    s=${2#repos/acme/widgets/commits/}; s=${s%%/*}; cat "$FIX/gh/runs-$s.json" 2>/dev/null || exit 1 ;;
  "api repos/acme/widgets/actions/jobs/"*"/logs")
    j=${2#repos/acme/widgets/actions/jobs/}; j=${j%%/*}; cat "$FIX/gh/job-$j.log" 2>/dev/null || exit 1 ;;
  *) exec "$BIN/gh" "$@" ;;
esac
SH
chmod +x "$BIN/gh-basered"; export SWARM_GH="$BIN/gh-basered"
SK='superpowers:systematic-debugging superpowers:test-driven-development'

git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
mkdir -p "$REPO/src"; printf 'legacy\n' > "$REPO/src/legacy.test.ts"
git -C "$REPO" add . && git -C "$REPO" commit -qm "trunk base"
git -C "$REPO" push -q origin develop
BASE_SHA=$(git -C "$REPO" rev-parse develop)
printf '[{"sha":"%s"}]\n' "$BASE_SHA" > "$FIX/gh/base-commits.json"

setup() { # <ticket> — a PR branch with its own file and its own test, the record a reenter leaves
  local t=$1
  WT="$FIX/wt$t"
  git -C "$REPO" worktree add -q "$WT" -b "tkt-$t/work" develop
  printf 'value=bad\n' > "$WT/value$t.txt"; printf 'own\n' > "$WT/src/own$t.test.ts"
  git -C "$WT" add . && git -C "$WT" commit -qm "feat: $t"
  git -C "$WT" push -q -u origin "tkt-$t/work"
  HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
  driver_state_init "$t" --worktree "$WT" --branch "tkt-$t/work"
  driver_state_set "$t" pr "$t"; driver_state_set "$t" repair_base "$HEAD_SHA"
  printf 'REPAIR on PR #%s: CI went red\n' "$t" > "$(driver_state_dir "$t")/repair-brief.md"
  driver_state_set "$t" repair_brief "$(driver_state_dir "$t")/repair-brief.md"
  driver_state_set "$t" repair_brief_source class
  fix_issue "$t" OPEN "status:in-review"
  rm -f "$FIX/ai/repair.sh" "$FIX/ai/repair.jsonl"; : > "$CLAUDE_LOG"; : > "$GH_LOG"
}
prs() { # <ticket> <red-check>… — the open PR at the tree's head, those checks red
  local t=$1; shift
  jq -n --argjson n "$t" --arg b "tkt-$t/work" --arg h "$HEAD_SHA" --args \
    '[{number:$n, headRefName:$b, headRefOid:$h, isDraft:false, mergeStateStatus:"BLOCKED", mergeable:"MERGEABLE",
       statusCheckRollup:([$ARGS.positional[] | {name:., status:"COMPLETED", conclusion:"FAILURE"}])}]' "$@" > "$FIX/gh/prs.json"
}
runs() { # <sha> <name>:<conclusion>:<job-id>… — that commit's check runs
  local sha=$1; shift
  printf '%s\n' "$@" | jq -R -s '{check_runs: [split("\n")[] | select(. != "") | split(":")
    | {name: .[0], conclusion: .[1], id: (.[2] | tonumber), status: "completed",
       started_at: "2026-10-21T09:00:00Z", completed_at: "2026-10-21T09:10:00Z"}]}' > "$FIX/gh/runs-$sha.json"
}
joblog() { # <job-id> <failing test>… — a vitest log naming those tests failing
  { printf '2026-10-21T09:05:00.0000000Z  ✓ src/fine.test.ts (3 tests) 12ms\n'
    for f in "${@:2}"; do printf '2026-10-21T09:05:01.0000000Z  FAIL  %s > a case > fails\n' "$f"; done
    printf '2026-10-21T09:05:02.0000000Z  Test Files  %s failed | 1 passed\n' "$(( $# - 1 ))"; } > "$FIX/gh/job-$1.log"
}
answer() { fix_ai repair "$1" "$SK"; }
test_fix_answer() { # <ticket> — the model's hands make a red-then-green pair; the answer reports it
  local t=$1 ts is
  printf '#!/usr/bin/env bash\ngrep -q good value%s.txt\n' "$t" > "$WT/value$t.test.sh"
  git -C "$WT" add . && git -C "$WT" commit -qm "test: the value"; ts=$(git -C "$WT" rev-parse HEAD)
  printf 'value=good\n' > "$WT/value$t.txt"; git -C "$WT" add . && git -C "$WT" commit -qm "fix: the value"; is=$(git -C "$WT" rev-parse HEAD)
  # Made now so the answer can name them; the tree goes back to the PR head until the model runs.
  git -C "$WT" reset -q --hard "$HEAD_SHA"
  printf 'git -C %q reset -q --hard %s\n' "$WT" "$is" > "$FIX/ai/repair.sh"
  answer "$(jq -nc --arg ts "$ts" --arg is "$is" --arg f "value$t.test.sh" --arg c "bash value$t.test.sh" \
    '{step:"repair", skills:["superpowers:systematic-debugging","superpowers:test-driven-development"], status:"repaired", cause:"the value",
      fixes:[{what:"the value was wrong", proof:"test", change:[{path:"value.txt", action:"modify"}],
              test:{file:$f, behaviour:"the value is good", redWhen:"the value is put back"},
              command:$c, failedBefore:true, passedAfter:true, testCommit:$ts, implCommit:$is}]}')"
}

echo "--- every red is a test outside the PR, red on the base too: it waits, no model, no question ---"
setup 801; prs 801 unit
runs "$HEAD_SHA" unit:failure:501;  joblog 501 src/legacy.test.ts
runs "$BASE_SHA" unit:failure:901;  joblog 901 src/legacy.test.ts
answer '{"step":"repair","status":"park","question":"a red from a test outside this PR fails on develop too — fix it here?"}'
out=$(driver_step_repair 801 2>&1); rc=$?
want "the step ends as a base wait"            "34" "$rc"
want "the model is never asked"                "" "$(cat "$CLAUDE_LOG")"
want "the red check is named on the record"    "unit" "$(driver_state_get 801 base_wait_checks)"
want "with the head it was read on"            "$HEAD_SHA" "$(driver_state_get 801 base_wait_head)"
want "and its test"                            "src/legacy.test.ts" "$(driver_state_get 801 base_red_tests)"
want "no park note asks anything"              "" "$(driver_state_get 801 park_note)"
want "and the trunk's red is noted for its one develop-red ticket" "src/legacy.test.ts	801" "$(cut -f2-3 "$STATE/swarm/develop-red.tsv" 2>/dev/null | tail -1)"
want_in "it says it waits for the base"        "waiting for develop's fix, never repaired in the PR" "$out"

echo "--- the same test red only on the PR (it passes on the base): repaired as before ---"
setup 802; prs 802 unit
runs "$HEAD_SHA" unit:failure:502;  joblog 502 src/legacy.test.ts
runs "$BASE_SHA" unit:success:902
test_fix_answer 802
out=$(driver_step_repair 802 2>&1); rc=$?
want "it repairs"                              "0" "$rc"
want "the model is asked once"                 "repair" "$(cat "$CLAUDE_LOG")"
want_in "the red is read as the PR's own"      "'unit' is this PR's own red — it passes on the base" "$out"
want_in "the red reached the model"            'The checks that settled red: unit' "$(cat "$FIX/claude-stdin-repair.txt")"
want "nothing waits"                           "" "$(driver_state_get 802 base_wait_checks)"

echo "--- a failing test the PR's diff touches is its own, even with the base red ---"
setup 803; prs 803 unit
runs "$HEAD_SHA" unit:failure:503;  joblog 503 src/own803.test.ts
runs "$BASE_SHA" unit:failure:903;  joblog 903 src/own803.test.ts
test_fix_answer 803
out=$(driver_step_repair 803 2>&1); rc=$?
want "it repairs"                              "0" "$rc"
want_in "it is the PR's own"                   "'unit' is this PR's own red — fails in src/own803.test.ts that this PR changes" "$out"

echo "--- no base-branch evidence (the base log unreadable): never base-only ---"
setup 804; prs 804 unit
runs "$HEAD_SHA" unit:failure:504;  joblog 504 src/legacy.test.ts
runs "$BASE_SHA" unit:failure:904;  rm -f "$FIX/gh/job-904.log"
test_fix_answer 804
out=$(driver_step_repair 804 2>&1); rc=$?
want "it repairs"                              "0" "$rc"
want_in "the red stays the PR's"               "'unit' is this PR's own red — its log on the base could not be read" "$out"

echo "--- a mix: the PR's own red is repaired, the base's is named and left alone ---"
setup 805; prs 805 unit e2e
runs "$HEAD_SHA" unit:failure:505 e2e:failure:515; joblog 505 src/legacy.test.ts; joblog 515 src/own805.test.ts
runs "$BASE_SHA" unit:failure:905 e2e:success:915; joblog 905 src/legacy.test.ts
test_fix_answer 805
out=$(driver_step_repair 805 2>&1); rc=$?
want "it repairs"                              "0" "$rc"
want "the model is asked once"                 "repair" "$(cat "$CLAUDE_LOG")"
want_in "only its own red is owed"             'The checks that settled red: e2e' "$(cat "$FIX/claude-stdin-repair.txt")"
want_in "the base red is named as not its"     'Not yours to fix: unit is red in src/legacy.test.ts' "$(cat "$FIX/claude-stdin-repair.txt")"
want_not_in "and is not on the owed list"      'settled red: (unit|e2e, unit|unit, e2e)' "$(cat "$FIX/claude-stdin-repair.txt")"
want "no wait for the PR"                      "" "$(driver_state_get 805 base_wait_checks)"
want "self-check knows the base's test"        "src/legacy.test.ts" "$(driver_state_get 805 base_red_tests)"

echo "--- self-check: a gate red only on the base's test does not count; one on the PR's own does ---"
driver_state_set 805 mode repair
printf ' FAIL  src/legacy.test.ts > a case\n' > "$FIX/gate-base.out"
printf ' FAIL  src/legacy.test.ts > a case\n FAIL  src/own805.test.ts > b\n' > "$FIX/gate-own.out"
want "base only: not counted"                  "src/legacy.test.ts" "$(_driver_gate_base_only 805 "$FIX/gate-base.out")"
want "with its own red too: counted"           "1" "$(_driver_gate_base_only 805 "$FIX/gate-own.out" >/dev/null; echo $?)"
printf 'error TS2322\n' > "$FIX/gate-none.out"
want "a gate naming no test: counted"          "1" "$(_driver_gate_base_only 805 "$FIX/gate-none.out" >/dev/null; echo $?)"

echo "--- self-check, run whole: the gate red only on the base's test passes; red on its own as well, it does not ---"
cp "$HARNESS_CFG_PATH" "$FIX/cfg.bak"
jq --arg c "cat $FIX/gate-base.out; exit 1" '.gates = {"unit": $c}' "$FIX/cfg.bak" > "$HARNESS_CFG_PATH"
out=$(driver_step_self_check 805 2>&1); rc=$?
want "the gate does not count"                 "0" "$rc"
want_in "and says why"                         'unit red only on src/legacy.test.ts — outside this PR and red on the base too' "$out"
jq --arg c "cat $FIX/gate-own.out; exit 1" '.gates = {"unit": $c}' "$FIX/cfg.bak" > "$HARNESS_CFG_PATH"
out=$(driver_step_self_check 805 2>&1); rc=$?
want_not_in "its own red still counts"         '^0$' "$rc"
want_in "named as red"                         'self-check: unit failed' "$out"
cp "$FIX/cfg.bak" "$HARNESS_CFG_PATH"

echo "--- the whole run: a base wait ends with no label, no park, and the ledger names the check ---"
setup 806; prs 806 unit
runs "$HEAD_SHA" unit:failure:506;  joblog 506 src/legacy.test.ts
runs "$BASE_SHA" unit:failure:906;  joblog 906 src/legacy.test.ts
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1; git -C "$REPO" branch -D tkt-806/work >/dev/null 2>&1
rm -rf "$STATE/driver/806"
printf 'REPAIR on PR #806: CI went red on: unit\n' > "$FIX/brief-806.md"
: > "$GH_LOG"; : > "$CLAUDE_LOG"
out=$(bash "$HERE/../build-ticket" 806 --repair "$FIX/brief-806.md" 2>&1); rc=$?
want "the run exits as a base wait"            "34" "$rc"
want "the model is never asked"                "" "$(cat "$CLAUDE_LOG")"
want "no label goes on the ticket"             "" "$(grep -E 'issue edit .*--add-label' "$GH_LOG")"
want_not_in "no park comment, no question"     'issue comment|pr comment|pr ready' "$(cat "$GH_LOG")"
want_not_in "not parked"                       'parked \(|✋ #806 parked' "$out"
want_in "it says what it waits for"            '#806 waiting for develop, not parked: unit' "$out"
want "the ledger names the PR, head and check" "806	806	$HEAD_SHA	develop	unit	src/legacy.test.ts" "$(cut -f1-6 "$BASE_WAITS")"
want "the wait holds on that head"             "0" "$(base_wait_holds 806 "$HEAD_SHA"; echo $?)"
want "and not on a new head"                   "1" "$(base_wait_holds 806 0000000; echo $?)"

echo "--- the coordinator: queued again when the base goes green, or after the hours, never before ---"
cat > "$FIX/queue-stub.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/queue.log"
SH
rm -f "$FIX/queue.log"
export SWARM_NOW=$(( $(sed -n 1p "$BASE_WAITS" | cut -f7) + 3600 ))
out=$(base_wait_release "$FIX/queue-stub.sh")
want "an hour on, the base still red: nothing queued" "" "$(cat "$FIX/queue.log" 2>/dev/null)"
want "and the wait holds"                      "0" "$(base_wait_holds 806; echo $?)"
runs "$BASE_SHA" unit:success:907
out=$(base_wait_release "$FIX/queue-stub.sh")
want_in "the base green: queued as a repair at the front" '^add 806 --class repair --note Base-red wait over \(unit went green on develop\).* --first$' "$(cat "$FIX/queue.log")"
want "and the wait is gone"                    "1" "$(base_wait_holds 806; echo $?)"
base_wait_note 807 807 abc develop unit src/legacy.test.ts
runs "$BASE_SHA" unit:failure:908
rm -f "$FIX/queue.log"
SWARM_NOW=$(( $(swarm_now) + BASE_WAIT_HOURS * 3600 )) base_wait_release "$FIX/queue-stub.sh" >/dev/null
want_in "the base still red after the hours: queued anyway" "^add 807 --class repair --note Base-red wait over \\($BASE_WAIT_HOURS hours passed\\)" "$(cat "$FIX/queue.log" 2>/dev/null)"
unset SWARM_NOW

echo "--- a released wait whose base is still red waits again, carrying the brief it was sent ---"
setup 808; prs 808 unit
runs "$HEAD_SHA" unit:failure:509;  joblog 509 src/legacy.test.ts
runs "$BASE_SHA" unit:failure:909;  joblog 909 src/legacy.test.ts
printf 'Coordinator note (repair): %s (6 hours passed): PR #808 was red on unit. %sAlso rename the button to Save.\n' "$BASE_WAIT_NOTE_PREFIX" "$BASE_WAIT_BRIEF_MARK" > "$(driver_state_dir 808)/repair-brief.md"
driver_state_set 808 repair_brief_source caller
out=$(driver_step_repair 808 2>&1); rc=$?
want "it waits again"                          "34" "$rc"
want "the model is never asked"                "" "$(cat "$CLAUDE_LOG")"
want "the person's brief rides on, unwrapped"  "Also rename the button to Save." "$(cat "$(driver_state_get 808 base_wait_brief)")"

echo "--- a caller's brief is never lost to the wait: it comes back with the note that ends it ---"
rm -f "$FIX/queue.log"
base_wait_note 808 808 "$HEAD_SHA" develop unit src/legacy.test.ts "$(driver_state_get 808 base_wait_brief)"
runs "$BASE_SHA" unit:success:910
base_wait_release "$FIX/queue-stub.sh" >/dev/null
want_in "the release note carries it"          "^add 808 --class repair --note Base-red wait over .*The brief this repair was sent with: Also rename the button to Save. --first$" "$(cat "$FIX/queue.log" 2>/dev/null)"

suite_end "$FAILED"
