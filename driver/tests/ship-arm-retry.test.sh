#!/usr/bin/env bash
# ship-arm-retry.test.sh — a pull request the driver's own park left as a draft is
# readied at ship, and GitHub can still answer "is a draft" to the arm that follows
# seconds later. Measured: readied 00:34:13, arm refused by 00:34:16, and a finished,
# reviewed change parked until a person armed it. Ship now tries the arm again after
# readying again, and a refusal carries GitHub's own reason. A person's draft is
# never readied.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fixture_path REPO "$FIX"
. "$HERE/../steps/ship.sh" || exit 1

git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop

setup_wt() { # <ticket> — reviewed, everything before ship done
  local t=$1 wt st
  wt="$FIX/wt$t"; fixture_path wt "$FIX"
  git -C "$REPO" worktree add -q "$wt" -b "tkt-$t/work" develop
  printf 'change for %s\n' "$t" > "$wt/f$t.txt"
  git -C "$wt" add "f$t.txt"; git -C "$wt" commit -qm "feat: thing $t"
  driver_state_init "$t" --worktree "$wt" --branch "tkt-$t/work"; fix_gates_kept "$t"
  driver_state_set "$t" claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
  fix_issue "$t" OPEN "status:claimed"
  driver_state_put "$t" review '{"verdict":"SHIP","findings":[]}'
  driver_state_bump "$t" review
  for st in start plan build self-check review record; do driver_state_done "$t" "$st"; done
}

# gh, as GitHub answers a draft: the first $FIX/arm.fail arms are refused with its words.
cp "$BIN/gh" "$FIX/gh.keep"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2 $*" in
  "pr merge "*--auto*)
    n=$(( $(cat "$FIX/arm.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FIX/arm.n"
    if [ "$n" -le "$(cat "$FIX/arm.fail" 2>/dev/null || echo 0)" ]; then
      printf '%s\n' "$*" >> "$GH_LOG"
      echo "GraphQL: Pull request is a draft (enablePullRequestAutoMerge)" >&2; exit 1
    fi ;;
esac
exec "$FIX/gh.keep" "$@"
SH
chmod +x "$BIN/gh"
arms()    { grep -c '^pr merge .*--auto' "$GH_LOG" || true; }
readies() { grep -c '^pr ready ' "$GH_LOG" || true; }

echo "--- a draft the park made is readied, and an arm GitHub refuses as a draft is tried again ---"
setup_wt 201
echo 1 > "$FIX/arm.fail"; rm -f "$FIX/arm.n"; : > "$GH_LOG"
out=$(driver_step_ship 201 2>&1); rc=$?
want "it finishes"                         "0" "$rc"
want_in "and hands off"                    'auto-merge armed at .*Handing off' "$out"
want_in "saying what GitHub said the first time" 'did not arm on try 1 \(GraphQL: Pull request is a draft' "$out"
want "the arm was asked twice"             "2" "$(arms)"
want "and the pull request readied before each" "2" "$(readies)"
want "ready comes before the first arm"    "pr ready" "$(grep -E '^pr (ready|merge) ' "$GH_LOG" | head -1 | cut -d' ' -f1-2)"

echo "--- an arm GitHub keeps refusing is refused, with GitHub's reason ---"
setup_wt 202
echo 99 > "$FIX/arm.fail"; rm -f "$FIX/arm.n"; : > "$GH_LOG"
out=$(driver_step_ship 202 2>&1); rc=$?
want "it refuses"                          "24" "$rc"
want "after three tries"                   "3" "$(arms)"
want_in "naming GitHub's reason"           'would not arm .* in 3 tries\. GitHub said: GraphQL: Pull request is a draft \(enablePullRequestAutoMerge\)' "$out"
want_in "and the park is told it"          'GitHub said: GraphQL: Pull request is a draft' "$(driver_state_get 202 park_note)"
want_not_in "and never claims a hand-off"  'Handing off' "$out"

echo "--- an arm that takes the first time is asked once ---"
setup_wt 203
echo 0 > "$FIX/arm.fail"; rm -f "$FIX/arm.n"; : > "$GH_LOG"
out=$(driver_step_ship 203 2>&1); rc=$?
want "it finishes"                         "0" "$rc"
want "one arm, one ready"                  "1 1" "$(arms) $(readies)"

echo "--- a draft a person made is left alone, and ship says so ---"
setup_wt 204
printf 'a person (pm) put this back to draft on 2026-11-11: not yet\n' > "$FIX/person-stop.out"
printf '1\n' > "$FIX/person-stop.rc"
echo 0 > "$FIX/arm.fail"; rm -f "$FIX/arm.n"; : > "$GH_LOG"
out=$(driver_step_ship 204 2>&1); rc=$?
rm -f "$FIX/person-stop.out" "$FIX/person-stop.rc"
want "it refuses"                          "24" "$rc"
want_in "saying a person stopped it"       "a person has stopped this.*a person's stop wins over the machine" "$out"
want_in "in the person's words"            'put this back to draft on 2026-11-11: not yet' "$out"
want "it is never readied or armed"        "0 0" "$(arms) $(readies)"

suite_end "$FAILED"
