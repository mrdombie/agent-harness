#!/usr/bin/env bash
# ship-deleted-tests.test.sh — a branch that deletes a test nobody accounted for gets
# ONE accounting round at ship: the builder says why, the answer goes on the record,
# the body carries it and the pull request ships.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/ship.sh" || exit 1

git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop

# The builder's answer, stubbed: writes the step's JSON and counts its calls.
CALLS="$FIX/account-calls"; : > "$CALLS"
driver_ai_step() {
  [ "$2" = account-tests ] || return 99
  echo call >> "$CALLS"
  printf '%s\n' '{"step":"account-tests","skills":[],"replacedTests":[{"file":"pinned.test.ts","removedBecause":"obsolete"}]}' \
    > "$(driver_state_dir "$1")/steps/account-tests.json"
}

echo "--- a deleted test nobody accounted for gets one round, then ships ---"
: > "$GH_LOG"
printf "it('a writer can post for a teammate', () => {});\n" > "$REPO/pinned.test.ts"
git -C "$REPO" add pinned.test.ts
git -C "$REPO" -c user.email=t@example.invalid -c user.name=T commit -qm "test: pin it"
git -C "$REPO" push -q origin develop
git -C "$REPO" worktree add -q "$FIX/wt112" -b tkt-112/work develop
git -C "$FIX/wt112" rm -q pinned.test.ts
git -C "$FIX/wt112" -c user.email=t@example.invalid -c user.name=T commit -qm "feat: rebuild"
driver_state_init 112 --worktree "$FIX/wt112" --branch tkt-112/work; fix_gates_kept 112
driver_state_set 112 claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
driver_state_put 112 review '{"verdict":"SHIP","findings":[]}'
: > "$(driver_state_dir 112)/steps/replaced.jsonl"
fix_issue 112 OPEN "status:claimed"
out=$(driver_step_ship 112 2>&1); rc=$?
want "it ships" "0" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -15
want "the builder is asked once" "1" "$(grep -c . "$CALLS")"
want_in "the answer is on the record" 'pinned.test.ts' "$(cat "$(driver_state_dir 112)/steps/replaced.jsonl")"
log=$(tr "\n" " " < "$GH_LOG" | cut -c1-100000)
want_in "the body is rewritten with the section" 'pr edit .*## Deleted tests.*pinned.test.ts' "$log"
want_in "then marked ready"   'Deleted tests.*pr ready' "$log"
want_in "and auto is armed"   'pr ready.*pr merge.*--auto' "$log"

echo "--- a file the round leaves unexplained parks once, naming the record line ---"
: > "$GH_LOG"; : > "$CALLS"
driver_ai_step() {
  [ "$2" = account-tests ] || return 99
  echo call >> "$CALLS"
  printf '%s\n' '{"step":"account-tests","skills":[],"replacedTests":[]}' \
    > "$(driver_state_dir "$1")/steps/account-tests.json"
}
git -C "$REPO" worktree add -q "$FIX/wt113" -b tkt-113/work develop
git -C "$FIX/wt113" rm -q pinned.test.ts
git -C "$FIX/wt113" -c user.email=t@example.invalid -c user.name=T commit -qm "feat: rebuild"
driver_state_init 113 --worktree "$FIX/wt113" --branch tkt-113/work; fix_gates_kept 113
driver_state_set 113 claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
driver_state_put 113 review '{"verdict":"SHIP","findings":[]}'
: > "$(driver_state_dir 113)/steps/replaced.jsonl"
fix_issue 113 OPEN "status:claimed"
out=$(driver_step_ship 113 2>&1); rc=$?
want "it parks refused" "24" "$rc"
want "the builder is asked once" "1" "$(grep -c . "$CALLS")"
note=$(driver_state_get 113 park_note)
want_in "the note names the record file" "$(driver_state_dir 113)/steps/replaced.jsonl" "$note"
want_in "the note gives the line to write" '"file":"pinned.test.ts"' "$note"
want_in "the note says it is not the body" 'not the PR body' "$note"
want "the park is the PM's" "pm" "$(driver_state_get 113 park_cause)"
log=$(tr "\n" " " < "$GH_LOG" | cut -c1-100000)
case "$log" in *"pr ready"*|*"pr merge"*) want "nothing is readied or merged" "no" "yes" ;; *) want "nothing is readied or merged" "no" "no" ;; esac

suite_end "$FAILED"
