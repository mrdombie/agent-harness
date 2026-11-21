#!/usr/bin/env bash
# compare-dev-shot.test.sh — a screen change is shot on its /dev page before it merges,
# merge first included: the compare step runs the project's devShot command and the
# renders record names every shot, every screen file with no /dev page, or the failure.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/compare.sh" || exit 1
CFG="$REPO/.claude/harness.json"
cfg() { jq "$1" "$CFG" > "$FIX/cfg.t" && mv "$FIX/cfg.t" "$CFG"; }

cat > "$FIX/dev-shot.sh" <<'SH'
#!/usr/bin/env bash
[ -d "$1" ] || { echo "no out dir" >&2; exit 2; }
printf 'home\t/x.png\tlight\t/dev/home\n'
printf 'not a shot line\n'
case "${SHOT_EXIT:-0}" in
  5) echo "apps/web/src/X.tsx" >&2; exit 5 ;;
  1) echo "playwright exploded" >&2; exit 1 ;;
  3) exit 3 ;;
esac
exit 0
SH
chmod +x "$FIX/dev-shot.sh"

cfg '.design = {"surfacePaths": ["apps/web/**"], "baselineRoute": {"enabled": true}}'
git -C "$REPO" add -A && git -C "$REPO" commit -qm "screens are apps/web; the baseline route is on"

tree() { # <ticket> <labels-csv>
  git -C "$REPO" worktree add -q "$FIX/wt$1" -b "tkt-$1/work" develop
  driver_state_init "$1" --worktree "$FIX/wt$1" --branch "tkt-$1/work"
  fix_issue "$1" OPEN "status:claimed${2:+,$2}"
  mkdir -p "$FIX/wt$1/apps/web/src"; printf 'x %s\n' "$1" > "$FIX/wt$1/apps/web/src/Home.tsx"
  git -C "$FIX/wt$1" add -A; git -C "$FIX/wt$1" commit -qm "change the home screen"
}
tree 811 ""; tree 812 screen:new
run() { driver_step_compare "$1" >/dev/null 2>&1; }

echo "--- no devShot: nothing is shot and nothing is claimed ---"
run 811
want_not_in "the renders record names no shots" 'dev-page shots' "$(driver_state_get 811 renders)"

cfg ".devShot = \"$FIX/dev-shot.sh\""

echo "--- the baseline route shoots the screen ---"
SHOT_EXIT=0 run 811
want_in "the record lists the shot"               '/x.png' "$(driver_state_get 811 renders)"
want_in "and the shots are kept for the PR"       '/x.png' "$(driver_state_get 811 dev_shots)"
want_not_in "a line that is not a shot is dropped" 'not a shot line' "$(driver_state_get 811 dev_shots)"
want_in "it says they go on the PR"               'put each on the PR' "$(driver_state_get 811 renders)"

echo "--- a screen file with no /dev page is named ---"
SHOT_EXIT=5 run 811
want_in "the uncovered file is named"             'apps/web/src/X.tsx' "$(driver_state_get 811 renders)"
want_in "as having no /dev page"                  'NO /dev page' "$(driver_state_get 811 renders)"
want_in "the shots it did take still count"       '/x.png' "$(driver_state_get 811 dev_shots)"

echo "--- a broken shot command is said, not hidden ---"
SHOT_EXIT=1 run 811
want_in "the failure and its exit"                'failed \(exit 1\)' "$(driver_state_get 811 renders)"
want_in "with the command's last words"           'playwright exploded' "$(driver_state_get 811 renders)"

echo "--- no screen file: says none ---"
SHOT_EXIT=3 run 811
want_in "the record says no screen file"          'found no screen file' "$(driver_state_get 811 renders)"

echo "--- merge first no longer skips the shots ---"
cfg '.release = {"mergeFirst": true, "done": false}'
SHOT_EXIT=0 run 812
want_in "merge first still records merge first"   'merge first' "$(driver_state_get 812 renders)"
want_in "and the screen is shot"                  '/x.png' "$(driver_state_get 812 renders)"

suite_end "$FAILED"
