#!/usr/bin/env bash
# format.test.sh — a format check is never what sends work back. #13623 proved seven
# tasks, then self-check's pre-push went red on `format:changed` alone and a whole fix
# round was spent running a formatter. The driver formats the branch's own files after
# each build task, after each fix round, and before the gates — and commits it.
# Run: bash "$0"
set -uo pipefail
export DRIVER_MAX_GATE_FIXES=1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/self-check.sh" || exit 1
. "$HERE/../format.sh" || exit 1

cfg() { jq "$1" "$REPO/.claude/harness.json" > "$FIX/hc" && mv "$FIX/hc" "$REPO/.claude/harness.json"; }

# The formatter rewrites UGLY to pretty in the files it is given; the check fails on
# any branch-changed file still holding UGLY — the shape of prettier and format:changed.
printf '#!/usr/bin/env bash\nfor f in "$@"; do perl -pi -e "s/UGLY/pretty/g" "$f"; done\n' > "$FIX/fmt.sh"
printf '#!/usr/bin/env bash\nb=$(git merge-base develop HEAD)\nfor f in $(git diff --name-only --diff-filter=ACMR "$b" HEAD); do\n  if grep -q "UG""LY" "$f"; then echo "✗ format:changed $f"; exit 1; fi\ndone\necho "format ok"\n' > "$FIX/fmtcheck.sh"
chmod +x "$FIX/fmt.sh" "$FIX/fmtcheck.sh"

# develop carries an unformatted file the branch never touches: it is not the branch's.
printf 'UGLY old\n' > "$REPO/old.txt"
git -C "$REPO" add old.txt; git -C "$REPO" commit -qm "develop: old"
WT="$FIX/wt"
git -C "$REPO" worktree add -q -b tkt-1 "$WT" develop
printf 'UGLY new\n' > "$WT/new.txt"
printf 'UGLY wip\n' > "$WT/wip.txt"
git -C "$WT" add new.txt wip.txt; git -C "$WT" commit -qm "feat: new"
printf 'UGLY wip, still being edited\n' > "$WT/wip.txt"
driver_state_init 1 --worktree "$WT"
export DRIVER_TICKET=1

echo "--- no formatter configured is no formatting ---"
cfg 'del(.driver.formatWrite) | del(.gates.formatChanged)'
rc=0; driver_format_changed 1 "$WT" test >/dev/null 2>&1 || rc=$?
want "nothing to run says so by its code"  "1" "$rc"
want "and nothing was committed"           "feat: new" "$(git -C "$WT" log -1 --format=%s)"

echo "--- the branch's own files are formatted and committed ---"
cfg ".driver.formatWrite = \"$FIX/fmt.sh\""
rc=0; out=$(driver_format_changed 1 "$WT" test 2>&1) || rc=$?
want "it committed"                        "0" "$rc"
want_in "and said so"                      'formatted 1 file' "$out"
want "the branch's file is formatted"      "pretty new" "$(git -C "$WT" show HEAD:new.txt)"
want_in "in a formatting commit"           '^style: ' "$(git -C "$WT" log -1 --format=%s)"
want "uncommitted work is not swept in"    "UGLY wip, still being edited" "$(cat "$WT/wip.txt")"
want "nor is it in the commit"             "UGLY wip" "$(git -C "$WT" show HEAD:wip.txt)"
want "develop's own file is not the branch's" "UGLY old" "$(cat "$WT/old.txt")"
rc=0; driver_format_changed 1 "$WT" test >/dev/null 2>&1 || rc=$?
want "a second run has nothing to do"      "1" "$rc"

echo "--- absent formatWrite: a project that checks formatting gets its prettier ---"
git -C "$WT" checkout -q -- wip.txt
printf 'UGLY two\n' > "$WT/two.txt"; git -C "$WT" add two.txt; git -C "$WT" commit -qm "feat: two"
mkdir -p "$WT/node_modules/.bin"; cp "$FIX/fmt.sh" "$WT/node_modules/.bin/prettier"
cfg 'del(.driver.formatWrite) | .gates.formatChanged = "sh fmtcheck.sh"'
want "the default is the tree's prettier"  "node_modules/.bin/prettier --write --ignore-unknown" "$(driver_format_cmd "$WT")"
rc=0; driver_format_changed 1 "$WT" test >/dev/null 2>&1 || rc=$?
want "and it formats"                      "0" "$rc"
want "the file"                            "pretty two" "$(git -C "$WT" show HEAD:two.txt)"
cfg '.driver.formatWrite = "none"'
want "\"none\" switches it off"            "" "$(driver_format_cmd "$WT")"
rm -rf "$WT/node_modules"

echo "--- self-check formats before its gates, so a format check is never a red round ---"
printf 'UGLY three\n' > "$WT/three.txt"; git -C "$WT" add three.txt; git -C "$WT" commit -qm "feat: three"
cp "$FIX/fmtcheck.sh" "$WT/fmtcheck.sh"; git -C "$WT" add fmtcheck.sh; git -C "$WT" commit -qm "chore: check"
cfg ".driver.formatWrite = \"$FIX/fmt.sh\" | .gates = {\"format\": \"bash fmtcheck.sh\", \"prePush\": false}"
rc=0; out=$(driver_step_self_check 1 2>&1) || rc=$?
want "the gates are green"                 "0" "$rc"
want_in "the format gate passed"           'self-check: format ok' "$out"
want "the file was formatted on the branch" "pretty three" "$(git -C "$WT" show HEAD:three.txt)"

echo "--- and a gate the formatter turns green is run again, not sent to fix ---"
# A formatter that only runs when the gate has failed once: the before-gates pass finds
# nothing, the gate goes red, the formatter then fixes it and the gate runs again.
printf 'UGLY four\n' > "$WT/four.txt"; git -C "$WT" add four.txt; git -C "$WT" commit -qm "feat: four"
printf '#!/usr/bin/env bash\n[ -f "%s/armed" ] || exit 0\nexec "%s/fmt.sh" "$@"\n' "$FIX" "$FIX" > "$FIX/late.sh"; chmod +x "$FIX/late.sh"
printf '#!/usr/bin/env bash\ntouch "%s/armed"\nexec bash fmtcheck.sh\n' "$FIX" > "$WT/armcheck.sh"
git -C "$WT" add armcheck.sh; git -C "$WT" commit -qm "chore: arm"
cfg ".driver.formatWrite = \"$FIX/late.sh\" | .gates = {\"format\": \"bash armcheck.sh\", \"prePush\": false}"
rc=0; out=$(driver_step_self_check 1 2>&1) || rc=$?
want "the second run is green"             "0" "$rc"
want_in "after formatting"                 'formatted 1 file' "$out"
want "and nothing went to fix"             "0" "$(driver_state_count 1 selfcheck_red)"

git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
exit $FAILED
