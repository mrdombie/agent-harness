#!/usr/bin/env bash
# steps/self-check.sh — the gates, run by the driver, read by exit code.
#
#   driver_step_self_check <ticket>
#
# Three rules, each of which has cost this project a shipped defect:
#
#   ONE GATE, ONE COMMAND, AND THE EXIT CODE IS THE VERDICT. A gate batched with
#   anything else reports on the shell reaching that line. A warning list is not
#   a failure and a printed error is not one either — the exit line is.
#
#   EVERY GATE RUNS, INCLUDING THE ONES BEHIND A FAILURE. A group that stops at
#   the first red means "gates pass locally" is only ever true of a prefix, and
#   the gates behind it have never run on this change even once.
#
#   NOTHING CONFIGURED IS A REFUSAL, NOT A PASS. A self-check with no gates
#   reports exactly like a self-check that found nothing wrong. That is the
#   whole failure mode: a protection that did not run looks like one that
#   passed.
#
# The gates themselves are a project fact, read from harness.json's `gates`
# object — name to command. The kit names none of them.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state.sh" || exit 1

driver_step_self_check() { # <ticket>
  local t="${1:?driver_step_self_check: need a ticket}"
  local wt names name cmd rc failed=0 ran=0
  export DRIVER_TICKET="$t"
  wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"

  names=$(jq -r '(.gates // {}) | keys_unsorted[]' "$HARNESS_CFG" 2>/dev/null)
  if [ -z "$names" ]; then
    driver_say "✋ self-check: harness.json configures no 'gates'. A check that never ran reports exactly like one that found nothing, so this refuses rather than passing."
    return "$DRIVER_E_REFUSED"
  fi

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    cmd=$(jq -r --arg n "$name" '.gates[$n]' "$HARNESS_CFG" 2>/dev/null)
    [ -n "$cmd" ] && [ "$cmd" != "null" ] || continue
    ran=$((ran+1))
    # Its own command, its own exit code, nothing batched with it.
    ( cd "$wt" && eval "$cmd" ) > "$(driver_state_dir "$t")/steps/gate-$name.out" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
      driver_say "   self-check: $name ok"
    else
      failed=$((failed+1))
      driver_say "✋ self-check: $name failed (exit $rc) — $(tail -3 "$(driver_state_dir "$t")/steps/gate-$name.out" 2>/dev/null | tr '\n' ' ')"
    fi
  done <<EOS
$names
EOS

  if [ "$failed" -gt 0 ]; then
    driver_say "✋ self-check: $failed of $ran gate(s) red. The local gate IS the gate — nothing is pushed past it."
    return "$DRIVER_E_REFUSED"
  fi
  driver_say "   self-check: $ran gate(s) green"
  return "$DRIVER_OK"
}
