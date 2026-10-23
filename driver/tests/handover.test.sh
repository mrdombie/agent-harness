#!/usr/bin/env bash
# handover.test.sh — a fix or repair step is handed what it needs, not the whole history
# (the owner, 2026-10-23: repair started at a median 98k tokens and fix at 102k, against
# 47k for a build task; one fix prompt carried a 1 MB diff). The change is the file list
# plus the diff of the files the step is about, cut at driver.handoverDiffBytes and the cut
# said; a red check comes with the tail of its own failed log.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/fix.sh" || exit 1

wt="$FIX/wt1"
git -C "$REPO" worktree add -q "$wt" -b tkt-1/work develop
mkdir -p "$wt/src"
awk 'BEGIN { for (i = 0; i < 3000; i++) print "const line" i " = \"a long generated line that fills the diff\";" }' > "$wt/src/big.ts"
printf 'export const card = 1;\n' > "$wt/src/Card.tsx"
git -C "$wt" add -A && git -C "$wt" commit -qm "feat: a big change"
full=$(git -C "$wt" diff develop...HEAD | wc -c | tr -d ' ')

echo "--- the change is bounded, and the cut is said ---"
out=$(driver_handover_diff "$wt" develop...HEAD)
bytes=$(printf '%s' "$out" | wc -c | tr -d ' ')
want "the whole diff is big"                     "1" "$([ "$full" -gt 100000 ] && echo 1 || echo 0)"
want "the handed diff is under 10 KB"            "1" "$([ "$bytes" -lt 10000 ] && echo 1 || echo 0)"
want_in "it lists every file the change touches" 'src/Card.tsx' "$out"
want_in "and says where the rest is"             'CUT at 8000 of [0-9]+ bytes' "$out"
jq '.driver = ((.driver // {}) + {handoverDiffBytes: 500})' "$HARNESS_CFG" > "$FIX/small.json"
want "driver.handoverDiffBytes sets the cut"     "1" "$(HARNESS_CFG="$FIX/small.json" driver_handover_diff "$wt" develop...HEAD | grep -c 'CUT at 500 of')"

echo "--- named files are shown whole, the rest by name ---"
out=$(driver_handover_diff "$wt" develop...HEAD src/Card.tsx)
want_in "the named file's diff is there"         'export const card' "$out"
want_not_in "the big file's lines are not"       'const line1 =' "$out"
want_in "but it is listed"                       'src/big.ts' "$out"

echo "--- a change across hundreds of files names 60 of them, then the total ---"
git -C "$REPO" worktree add -q "$FIX/wt3" -b tkt-3/work develop
mkdir -p "$FIX/wt3/many"; for i in $(seq 1 200); do printf 'x\n' > "$FIX/wt3/many/f$i.ts"; done
git -C "$FIX/wt3" add -A && git -C "$FIX/wt3" commit -qm "feat: many"
out=$(driver_handover_diff "$FIX/wt3" develop...HEAD)
want "60 files by name"                          "60" "$(printf '%s\n' "$out" | grep -c '^ many/f[0-9]*\.ts')"
want_in "the rest counted"                       '… 140 more' "$out"
want_in "and git's total"                        '200 files changed' "$out"

echo "--- no change: nothing, so the caller's own line shows ---"
git -C "$REPO" worktree add -q "$FIX/wt2" -b tkt-2/work develop
want "an empty range hands nothing"              "" "$(driver_handover_diff "$FIX/wt2" develop...HEAD)"

echo "--- the fix step is handed the bounded diff of the files its findings name ---"
driver_state_init 1 --worktree "$wt" --branch tkt-1/work
fix_issue 1 OPEN "status:claimed"
mkdir -p "$(driver_state_dir 1)/steps"
echo '{"verdict":"BLOCKED","findings":[{"id":"f1","file":"src/Card.tsx","line":1,"grade":"major","summary":"s","reason":"r","fix":"f"}]}' > "$(driver_state_dir 1)/steps/review.json"
driver_state_bump 1 review
fix_brief fix superpowers:receiving-code-review "Fix {{BLOCKERS}} in {{DIFF}} round {{ROUND}} {{PM_ANSWERS}} {{CRITIC_FINDINGS}} {{EVIDENCE_TASKS}} {{PROOF_LIMITS}}"
fix_ai fix '{"step":"fix","skills":["superpowers:receiving-code-review"],"status":"park","question":"q"}' superpowers:receiving-code-review
driver_step_fix 1 >/dev/null 2>&1
sent=$(cat "$FIX/claude-stdin-fix.txt" 2>/dev/null)
want_in "the finding's file is in the prompt"    'export const card' "$sent"
want_not_in "the big file's body is not"         'const line1 =' "$sent"
want "and the prompt is small"                   "1" "$([ "$(printf '%s' "$sent" | wc -c)" -lt 20000 ] && echo 1 || echo 0)"

echo "--- a red check comes with the tail of its failed log ---"
swarm_gh() { case "$*" in *"run view"*"--job 777"*) awk 'BEGIN { for (i = 0; i < 100; i++) printf "build\tstep\t2026-10-23T10:00:00.0000000Z log line %d\n", i; print "build\tstep\t2026-10-23T10:00:01.0000000Z FAIL src/x.test.ts > it breaks" }' ;; *) return 1 ;; esac; }
rollup='[{"name":"tests","conclusion":"FAILURE","detailsUrl":"https://github.com/a/b/actions/runs/1/job/777"},{"name":"lint","conclusion":"FAILURE","detailsUrl":"https://example.invalid/x"}]'
out=$(driver_failing_log_tails "$rollup" "tests, lint")
want_in "the failing line is there"              'FAIL src/x.test.ts > it breaks' "$out"
want_not_in "the head of the log is not"         'log line 5$' "$out"
want_not_in "nor the runner's timestamps"        '2026-10-23T10:00' "$out"
want "40 lines at most"                          "1" "$([ "$(printf '%s\n' "$out" | grep -c 'log line')" -le 40 ] && echo 1 || echo 0)"
want_in "a check with no readable log is named with the command" 'lint: its log could not be read here' "$out"

suite_end "$FAILED"
