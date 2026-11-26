#!/usr/bin/env bash
# project-env.test.sh — a project's command (a proof, a gate) is run without the build
# run's own state in its environment.
#
# The driver exports where its run lives for its own scripts. A suite of this kit, proved
# in a clone, inherited RUNS_DIR, SWARM_DIR and KIT_ROOT from the build: each tick it
# started walked the build machine's own run records (5,274 of them) and ran the installed
# kit's code, and the proof did not finish in an hour, twice. By itself it takes minutes.
#   - the command inherits none of the run's state paths, repo facts, or COORDINATOR_*,
#     COORD_*, SWARM_*, DRIVER_*, CLAIM_*, LBL_*, GIT_* and HARNESS_* variables
#   - the driver's own shell still has them afterwards
#   - what a person exported for the project (a token, PATH, a variable of their own) stays
# case-filter: SUITE_ONLY='<a case title, or a pattern over them>' bash driver/tests/project-env.test.sh
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/build.sh" || exit 1
. "$HERE/../../swarm/swarm-env.sh" || exit 1

# What a build run has in its environment when it reaches a proof: the driver's and the
# swarm's own exports (sourced above), and what the coordinator and git hand a spawned run.
export COORDINATOR_CAP=2 COORDINATOR_DIR="$FIX/live-coordinator" COORD_QUEUE="$FIX/live-queue.json"
export CLAIM_RUN_ID=claim-1-live CLAIM_REPO="$REPO" GIT_AUTHOR_NAME="the build"
export HARNESS_MAIN_REPO="$REPO"
export PROJECT_TOKEN=keep-me GH_TOKEN=keep-this-too
NAMES='STATE_DIR KIT_ROOT REPO_ROOT MAIN_REPO CL RUNS_DIR SWARM_DIR SWARM_LOGS SWARM_GH SWARM_SPAWN DRIVER_DIR DRIVER_HOME REPO_SLUG INTEGRATION_BRANCH BRANCH_PREFIX LBL_READY HOLD_LABEL COORDINATOR_CAP COORDINATOR_DIR COORD_QUEUE CLAIM_RUN_ID CLAIM_REPO GIT_AUTHOR_NAME HARNESS_MAIN_REPO HARNESS_STATE_DIR HARNESS_CFG_PATH'
set_here() { local v out=""; for v in $NAMES; do [ -z "${!v:-}" ] || out="$out $v"; done; printf '%s' "${out# }"; }

if suite_case "the run's own state is in the driver's environment, as a build has it"; then
want "every name is set and exported before the command" "$NAMES" "$(for v in $NAMES; do env | grep -q "^$v=" && printf '%s ' "$v"; done | sed 's/ $//')"
fi

if suite_case "a project command inherits none of it"; then
seen=$(driver_run_project 30 'env' 2>&1)
leaked=$(for v in $NAMES; do printf '%s\n' "$seen" | grep -q "^$v=" && printf '%s ' "$v"; done | sed 's/ $//')
want "none of the run's state reaches the command" "" "$leaked"
want "no variable of those families at all" "" "$(printf '%s\n' "$seen" | grep -E '^(HARNESS|COORDINATOR|COORD|SWARM|DRIVER|CLAIM|LBL|GIT)_' | cut -d= -f1 | tr '\n' ' ' | sed 's/ $//')"
want_in "a token a person exported is still there" '^GH_TOKEN=keep-this-too$' "$seen"
want_in "and a variable of the project's own" '^PROJECT_TOKEN=keep-me$' "$seen"
want_in "and the PATH the stubs are on" "^PATH=$BIN:" "$seen"
want "the driver's own shell still has every one afterwards" "$NAMES" "$(set_here)"
want "and still exports them to its own scripts" "$RUNS_DIR" "$(bash -c 'printf %s "$RUNS_DIR"')"
fi

if suite_case "a proof runs its test without the run's state"; then
printf 'no\n' > "$REPO/env.txt"
printf '%s\n' '#!/usr/bin/env bash' '# Fails while it can see where the build run lives.' \
  '[ -z "${RUNS_DIR:-}${SWARM_DIR:-}${DRIVER_DIR:-}${KIT_ROOT:-}${STATE_DIR:-}${COORDINATOR_CAP:-}${GIT_AUTHOR_NAME:-}" ] || { echo "the run is visible: ${RUNS_DIR:-}${KIT_ROOT:-}"; exit 1; }' \
  'grep -q yes env.txt' > "$REPO/env.test.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: env"
E_TEST=$(git -C "$REPO" rev-parse HEAD)
printf 'yes\n' > "$REPO/env.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: env"
E_IMPL=$(git -C "$REPO" rev-parse HEAD)
out=$(driver_prove_red_green "$REPO" env.test.sh "$E_TEST" "$E_IMPL" "bash env.test.sh" 2>&1); rc=$?
want "red without the change, green with it" "0" "$rc"
want_not_in "the test never saw the run" 'the run is visible' "$out"
fi

suite_end "$FAILED"
