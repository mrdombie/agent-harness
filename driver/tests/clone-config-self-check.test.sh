#!/usr/bin/env bash
# clone-config-self-check.test.sh — the config a run is handed in a clone whose trunk
# carries none (driver_repo_clone_config) has to carry a run through self-check.
#
# The first ticket built in such a clone did every build step and parked at self-check:
# the handed config named no gate, and self-check refuses to pass on nothing run. Here
# the real self-check step runs in a clone, on the config written for it.
#   - its gates run, on the change, in a repo with no install, and a clean change passes
#   - each gate is a real check: a script that does not parse, or a whitespace error, is red
#   - a change in that clone is not a screen build: the config declares no screen
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../driver-env.sh" || exit 1
. "$HERE/../size-rules.sh" || exit 1

# A clone of acme/kit beside the project's own, its trunk carrying no config.
KIT="$FIX/kit"; KWT="$FIX/kit-wt"
git init -q -b main "$KIT"
git -C "$KIT" config user.email t@example.invalid; git -C "$KIT" config user.name Tester
printf '#!/usr/bin/env bash\necho tool\n' > "$KIT/tool.sh"
git -C "$KIT" add -A && git -C "$KIT" commit -qm root
git -C "$KIT" remote add origin https://github.com/acme/kit.git
git -C "$KIT" update-ref refs/remotes/origin/main HEAD
CC=$(driver_repo_clone_config "$KIT"); fixture_path CC "$FIX"
want "the clone is handed a config" "$STATE/clone-config/kit.json" "$CC"
want "naming a local set, kept for the local run" "true 2" "$(jq -r '[(.gates.localOnly | tostring), (.gates.local | length | tostring)] | join(" ")' "$CC")"

git -C "$KIT" worktree add -q "$KWT" -b tkt-701/work main
printf '#!/usr/bin/env bash\necho added\n' > "$KWT/added.sh"; printf 'notes\n' > "$KWT/notes.md"
git -C "$KWT" add -A && git -C "$KWT" commit -qm "feat: a script and a note"
fix_issue 701 OPEN "status:claimed,repo:kit"

# in_clone <shell> — as a run spawned in the clone: its own repo, the handed config, the queue's state dir.
in_clone() {
  # Nothing the project's own load exported reaches it: the run reads the clone afresh.
  ( for v in $(env | sed -n 's/^\(HARNESS_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
    unset DRIVER_DIR STATE_DIR MAIN_REPO REPO_ROOT REPO_SLUG INTEGRATION_BRANCH ISSUE_SLUG ISSUE_REF BRANCH_PREFIX KIT_ROOT
    cd "$KWT" && HARNESS_MAIN_REPO="$KIT" HARNESS_STATE_DIR="$STATE" HARNESS_CFG_PATH="$CC" HARNESS_LOGIN=tester \
      HARNESS_DISK_GUARD=off HARNESS_LOCAL_EVIDENCE=1 \
      bash -c '. "$1/../steps/self-check.sh" || exit 90; . "$1/../tier.sh" || exit 90; eval "$2"' _ "$HERE" "$1" ) 2>&1
}
in_clone "driver_state_init 701 --worktree '$KWT' --branch tkt-701/work" >/dev/null

echo "--- self-check runs the handed gates in the clone, and a clean change passes ---"
rc=0; out=$(in_clone 'driver_step_self_check 701') || rc=$?
want "self-check passes" "0" "$rc"
want_in "the diff check ran" 'self-check: local 1 ok' "$out"
want_in "the shell parse ran" 'self-check: local 2 ok' "$out"
want_not_in "it is not refused for want of a gate" 'configures no' "$out"
kept="$STATE/driver/701/steps/self-check.gates.jsonl"
want "both are kept as the pull request's proof, with the command each ran" \
  "git diff --check origin/main...HEAD" "$(jq -r 'select(.gate == "local 1") | .command' "$kept")"
want_in "the parse names the changed scripts off the diff" "git diff --name-only --diff-filter=ACMR origin/main...HEAD -- '\*.sh'" "$(jq -r 'select(.gate == "local 2") | .command' "$kept")"

echo "--- a change in that clone is not a screen build ---"
tier=$(in_clone 'driver_change_tier 701 "$PWD" origin/main | cut -f1')
want "the script and the note are product code, not a screen" "backend" "$tier"

echo "--- each gate is a real check of the change ---"
printf '#!/usr/bin/env bash\nif then\n' > "$KWT/broken.sh"
git -C "$KWT" add -A && git -C "$KWT" commit -qm "feat: a script that does not parse"
rc=0; out=$(in_clone 'driver_step_self_check 701') || rc=$?
want "a changed script that does not parse is red, sent to fix" "$DRIVER_E_REWORK" "$rc"
want_in "by the parse gate" 'self-check: local 2 failed' "$out"
want_in "the diff check still ran and passed" 'self-check: local 1 ok' "$out"
git -C "$KWT" rm -q broken.sh && git -C "$KWT" commit -qm "fix: drop it"
printf 'a line that ends in spaces   \n' >> "$KWT/notes.md"
git -C "$KWT" add -A && git -C "$KWT" commit -qm "docs: trailing spaces"
in_clone "driver_state_init 701 --worktree '$KWT' --branch tkt-701/work" >/dev/null
rc=0; out=$(in_clone 'driver_step_self_check 701') || rc=$?
want_in "a whitespace error in the diff is red, by the diff check" 'self-check: local 1 failed' "$out"
want_in "and the parse gate still passed" 'self-check: local 2 ok' "$out"

echo "--- a script the change does not touch is not this change's to answer for ---"
git -C "$KWT" checkout -q -b tkt-702/work main
printf 'only a note\n' > "$KWT/other.md"
git -C "$KWT" add -A && git -C "$KWT" commit -qm "docs: a note"
fix_issue 702 OPEN "status:claimed,repo:kit"
in_clone "driver_state_init 702 --worktree '$KWT' --branch tkt-702/work" >/dev/null
rc=0; out=$(in_clone 'driver_step_self_check 702') || rc=$?
want "a change with no script passes: the parse gate ran and found none to read" "0" "$rc"
want_in "it ran" 'self-check: local 2 ok' "$out"

suite_end "$FAILED"
