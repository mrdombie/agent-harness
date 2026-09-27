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
  local wt names name cmd rc gtype failed=0 ran=0 empty=""
  export DRIVER_TICKET="$t"
  wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"

  # The SHAPE first. `gates` written as a list reads as no names at all, and the
  # "nothing configured" guard below does not fire because the key is there — so one
  # typo in harness.json turned this whole step into a no-op reporting green.
  gtype=$(jq -r '(.gates // {}) | type' "$HARNESS_CFG" 2>/dev/null)
  if [ "$gtype" != "object" ]; then
    driver_say "✋ self-check: harness.json's 'gates' is a ${gtype:-unreadable value}, and this reads an object of name to command."
    return "$DRIVER_E_REFUSED"
  fi
  names=$(jq -r '.gates | keys_unsorted[]' "$HARNESS_CFG" 2>/dev/null)
  if [ -z "$names" ]; then
    driver_say "✋ self-check: harness.json configures no 'gates'. A check that never ran reports exactly like one that found nothing, so this refuses rather than passing."
    return "$DRIVER_E_REFUSED"
  fi

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    cmd=$(jq -r --arg n "$name" '.gates[$n]' "$HARNESS_CFG" 2>/dev/null)
    # Trimmed before the emptiness test, and a comment is not a command. A
    # placeholder left in harness.json counted as a gate that ran, printed "ok", and
    # took the green count up with it — one keystroke from the empty case.
    case "$(printf '%s' "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" in
      ''|null|'#'*) empty="$empty $name"; continue ;;
    esac
    ran=$((ran+1))
    # Its own command, its own exit code, nothing batched with it.
    ( cd "$wt" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$cmd" ) > "$(driver_state_dir "$t")/steps/gate-$name.out" 2>&1
    rc=$?
    if [ "$rc" -eq 124 ]; then
      failed=$((failed+1))
      driver_say "✋ self-check: $name ran out of time (over ${DRIVER_CMD_TIMEOUT}s). A gate that does not return is not a gate that passed."
    elif [ "$rc" -eq 0 ]; then
      driver_say "   self-check: $name ok"
    else
      failed=$((failed+1))
      driver_say "✋ self-check: $name failed (exit $rc) — $(tail -3 "$(driver_state_dir "$t")/steps/gate-$name.out" 2>/dev/null | tr '\n' ' ')"
    fi
  done <<EOS
$names
EOS

  # NOTHING RAN IS A REFUSAL. Every command empty is the same failure as no gates at
  # all, wearing a configured shape — and it printed "0 gate(s) green" and returned
  # OK, so ship pushed and armed auto-merge on code nothing had checked.
  if [ "$ran" -eq 0 ]; then
    driver_say "✋ self-check: every configured gate has an empty command (${empty# }), so nothing ran. Nothing having run is not everything having passed."
    return "$DRIVER_E_REFUSED"
  fi
  if [ "$failed" -gt 0 ]; then
    driver_say "✋ self-check: $failed of $ran gate(s) red. The local gate IS the gate — nothing is pushed past it."
    return "$DRIVER_E_REFUSED"
  fi
  driver_say "   self-check: $ran gate(s) green"
  return "$DRIVER_OK"
}
