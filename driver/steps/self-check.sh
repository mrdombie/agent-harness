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
# object. The kit names none of them. Two shapes are read, and only two:
#
#   { "local": ["<this project's gate command>", …] }   the documented shape
#   { "<name>": "<command>", … }        a flat map of name to command
#
# `group` and `requiredChecks` ARE NOT COMMANDS and are never run as one. `group`
# names a gate group inside the project's own runner and `requiredChecks` names the
# CI checks a pull request waits on — neither is a shell line. Reading every key as
# a command turned the documented shape into three broken ones: measured on the
# 2026-09-27 trial, `local` exited 127 with ``[: missing `]' ``, `group` with
# `gates:repo: command not found` and `requiredChecks` with `Typecheck + Unit
# tests,: command not found`, so a correctly-configured project was told "3 of 3
# gate(s) red". It failed loudly rather than falsely green, which is the right
# direction to fail in and still the wrong answer.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state.sh" || exit 1

driver_step_self_check() { # <ticket>
  local t="${1:?driver_step_self_check: need a ticket}"
  local wt names row name safe cmd rc gtype failed=0 ran=0 empty=""
  export DRIVER_TICKET="$t"
  wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"
  # Said before the gates run, and through the ticket's log: each gate's own output goes
  # to a file, so a warning printed inside one is a warning nobody sees.
  driver_check_timeout || true

  # The SHAPE first. `gates` written as a list reads as no names at all, and the
  # "nothing configured" guard below does not fire because the key is there — so one
  # typo in harness.json turned this whole step into a no-op reporting green.
  gtype=$(jq -r '(.gates // {}) | type' "$HARNESS_CFG" 2>/dev/null)
  if [ "$gtype" != "object" ]; then
    driver_say "✋ self-check: harness.json's 'gates' is a ${gtype:-unreadable value}, and this reads an object of name to command."
    return "$DRIVER_E_REFUSED"
  fi
  # ONE TAB-SEPARATED `name<TAB>command` PER LINE, from whichever shape this project
  # wrote. A command carries spaces and a name does not, so the split is on the tab.
  if [ "$(jq -r '(.gates.local // null) | type' "$HARNESS_CFG" 2>/dev/null)" = "array" ]; then
    names=$(jq -r '.gates.local | to_entries[] | "local \(.key + 1)\t\(.value)"' "$HARNESS_CFG" 2>/dev/null)
  else
    # A value that is not a string is NOT skipped: it falls through as an empty
    # command, so the "every gate is empty, nothing ran" refusal counts it by name.
    # Dropped here it would have left a key configured, unrun and unmentioned.
    names=$(jq -r '.gates | to_entries[] | "\(.key)\t\(if (.value | type) == "string" then .value else "" end)"' "$HARNESS_CFG" 2>/dev/null)
  fi
  if [ -z "$names" ]; then
    driver_say "✋ self-check: harness.json configures no local 'gates' command. A check that never ran reports exactly like one that found nothing, so this refuses rather than passing."
    return "$DRIVER_E_REFUSED"
  fi

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    name=${row%%	*}; cmd=${row#*	}
    # Trimmed before the emptiness test, and a comment is not a command. A
    # placeholder left in harness.json counted as a gate that ran, printed "ok", and
    # took the green count up with it — one keystroke from the empty case.
    case "$(printf '%s' "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" in
      ''|null|'#'*) empty="$empty $name"; continue ;;
    esac
    ran=$((ran+1))
    safe=$(printf '%s' "$name" | tr -cs 'A-Za-z0-9._-' '-')
    # Its own command, its own exit code, nothing batched with it.
    ( cd "$wt" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$cmd" ) > "$(driver_state_dir "$t")/steps/gate-$safe.out" 2>&1
    rc=$?
    if [ "$rc" -eq 124 ]; then
      # Its own outcome, not a red gate. A gate that does not return says nothing about
      # the change, and the park question a reader needs is "which command hangs", not
      # "which check failed".
      driver_say "✋ self-check: $name ran out of time (over ${DRIVER_CMD_TIMEOUT}s). A gate that does not return is not a gate that passed."
      driver_state_set "$t" park_note "the '$name' gate did not return within ${DRIVER_CMD_TIMEOUT}s: $cmd"
      return "$DRIVER_E_TIMEOUT"
    elif [ "$rc" -eq 0 ]; then
      driver_say "   self-check: $name ok"
    else
      failed=$((failed+1))
      driver_say "✋ self-check: $name failed (exit $rc) — $(tail -3 "$(driver_state_dir "$t")/steps/gate-$safe.out" 2>/dev/null | tr '\n' ' ')"
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
