#!/usr/bin/env bash
# skill-trim.test.sh — a step declares only the skills its work uses (the owner, 2026-10-23:
# "cut the fat"). The build declares test-driven-development and not
# subagent-driven-development: 14 build tasks in a row loaded it and started 0 helpers,
# and the driver already gives each task a fresh session and a review. A plan declares
# systematic-debugging on a bug ticket only, so a feature plan is neither told to load it
# nor counted as having run by it; writing-plans is always declared.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
export DRIVER_BRIEFS="$HERE/../../briefs"
. "$HERE/../ai-step.sh" || exit 1
fix_issue 401 OPEN "status:claimed,type:feature"
fix_issue 402 OPEN "status:claimed,type:bug"
fix_issue 403 OPEN "status:claimed,bug"
sk() { driver_declared_skills "$@" | tr '\n' ' ' | sed 's/ $//'; }

echo "--- the build ---"
want_not_in "build declares no subagent-driven-development" 'subagent-driven-development' "$(sk build 401)"
want_in "and keeps test-driven-development"  'superpowers:test-driven-development' "$(sk build 401)"
want_not_in "and its brief never asks for it" 'subagent-driven-development' "$(cat "$DRIVER_BRIEFS/build.md")"

echo "--- the plan ---"
want "a feature plan declares writing-plans alone"      "superpowers:writing-plans" "$(sk plan 401)"
want "a type:bug plan still declares systematic-debugging" "superpowers:systematic-debugging superpowers:writing-plans" "$(sk plan 402)"
want "and so does a bug-labelled one"                   "superpowers:systematic-debugging superpowers:writing-plans" "$(sk plan 403)"
want "unreadable labels keep it, the side that parks nothing" "superpowers:systematic-debugging superpowers:writing-plans" "$(sk plan 499)"
want_in "repair keeps systematic-debugging"             'superpowers:systematic-debugging' "$(sk repair 401)"

echo "--- the claim check follows the condition: a feature plan that only debugged has not run ---"
driver_state_init 401 --worktree "$MAIN_REPO" --branch "tkt-401/work"
fix_ai plan '{"step":"plan","skills":["superpowers:systematic-debugging"],"status":"park","premise":{"verdict":"still-true","evidence":"e"},"designSource":"ticket-body","question":"q"}' superpowers:systematic-debugging
rc=0; DRIVER_TICKET=401 driver_ai_step 401 plan >/dev/null 2>&1 || rc=$?
want "it is refused for skipping writing-plans"          "$DRIVER_E_NO_SKILL" "$rc"
want_in "and the plan prompt says not to debug"         'no bug label: do not run superpowers:systematic-debugging' "$(cat "$(driver_state_dir 401)/steps/plan.prompt")"
driver_state_init 402 --worktree "$MAIN_REPO" --branch "tkt-402/work"
fix_ai plan '{"step":"plan","skills":["superpowers:systematic-debugging"],"status":"park","premise":{"verdict":"still-true","evidence":"e"},"designSource":"ticket-body","question":"q"}' superpowers:systematic-debugging
rc=0; DRIVER_TICKET=402 driver_ai_step 402 plan >/dev/null 2>&1 || rc=$?
want_not_in "a bug plan that debugged passes the skill check" "^$DRIVER_E_NO_SKILL\$" "$rc"
want_not_in "and is not told to skip it"                'no bug label' "$(cat "$(driver_state_dir 402)/steps/plan.prompt")"

suite_end "$FAILED"
