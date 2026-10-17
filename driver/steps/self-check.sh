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

# _driver_note_changelog_skip <ticket> <tree> — the build steps answered `changelog:
# {skipped: <reason>}`, and their commits did not carry the project's skip line: the
# push was refused after review was paid for (trial run of #11168, 2026-10-01). When
# the project's gate accepts ONE branch-wide line (changelog.branchTrailer), the
# driver adds one empty commit carrying `<trailer>: <reason>` — no history is
# rewritten. Only when EVERY build answer reported skipped, and no commit on the
# branch already carries the line.
_driver_note_changelog_skip() {
  local t="$1" wt="$2" trailer all reason base c out
  trailer=$(driver_opt changelog.branchTrailer "")
  [ -n "$trailer" ] || return 0
  all="$(driver_state_dir "$t")/steps/build.all.json"
  [ -s "$all" ] || return 0
  jq -e -s 'length > 0 and all(.[]; ((.changelog.skipped // "") | gsub("\\s"; "")) != "")' "$all" >/dev/null 2>&1 || return 0
  reason=$(jq -r -s '[.[] | .changelog.skipped] | first' "$all" 2>/dev/null | tr '\r\n\t' '   ' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | cut -c1-200)
  [ -n "$reason" ] || return 0
  base=$(git -C "$wt" merge-base "origin/$INTEGRATION_BRANCH" HEAD 2>/dev/null \
         || git -C "$wt" merge-base "$INTEGRATION_BRANCH" HEAD 2>/dev/null)
  [ -n "$base" ] || return 0
  for c in $(git -C "$wt" rev-list "$base"..HEAD 2>/dev/null); do
    git -C "$wt" log -1 --format=%B "$c" \
      | awk -v t="$trailer:" 'index($0, t) == 1 && substr($0, length(t) + 1) ~ /[^[:space:]]/ { f = 1 } END { exit !f }' && return 0
  done
  # A normal commit: the project's hooks run on it, nothing is skipped.
  out="$(driver_state_dir "$t")/steps/changelog-note.out"
  if ! git -C "$wt" commit -q --only --allow-empty -m "$(driver_opt commit.parkType chore): no changelog for #$t" -m "$trailer: $reason" > "$out" 2>&1; then
    driver_say "✋ self-check: the build answered 'no changelog' and the commit saying so for the branch could not be made — $(tail -2 "$out" | tr '\n' ' ')"
    driver_state_set "$t" park_note "could not commit '$trailer: $reason' for the branch: $(tail -2 "$out" | tr '\n' ' ' | cut -c1-200)"
    return "$DRIVER_E_REFUSED"
  fi
  driver_say "   self-check: every build step answered 'no changelog' — said once for the branch: $trailer: $reason"
  return 0
}

# The compiler's or runner's own error lines when it printed any, else the tail.
_driver_gate_lines() { # <file>
  local l
  l=$(grep -E 'error TS[0-9]+|(^|[[:space:]])(error|Error|FAIL)[:[:space:]]' "$1" 2>/dev/null | head -3)
  [ -n "$l" ] || l=$(tail -3 "$1" 2>/dev/null)
  printf '%s' "$l" | tr '\n' ' ' | tr -s ' ' | cut -c1-400
}

_driver_order_has() { case " ${DRIVER_STEPS:-} " in *" $1 "*) return 0 ;; esac; return 1; }

driver_step_self_check() { # <ticket>
  local t="${1:?driver_step_self_check: need a ticket}"
  local wt names row name safe cmd rc gtype failed=0 ran=0 empty="" redlines="" infra="" findings
  export DRIVER_TICKET="$t"
  wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"
  findings="$(driver_state_dir "$t")/steps/self-check.findings.json"
  rm -f "$findings" "$findings.rows"
  # Said before the gates run, and through the ticket's log: each gate's own output goes
  # to a file, so a warning printed inside one is a warning nobody sees.
  driver_check_timeout || true

  # The build's own changelog claim, written where the project's gate reads it.
  local trc=0; _driver_note_changelog_skip "$t" "$wt" || trc=$?
  [ "$trc" -eq 0 ] || return "$trc"

  # The SHAPE first. `gates` written as a list reads as no names at all, and the
  # "nothing configured" guard below does not fire because the key is there — so one
  # typo in harness.json turned this whole step into a no-op reporting green.
  gtype=$(jq -r '(.gates // {}) | type' "$HARNESS_CFG" 2>/dev/null)
  if [ "$gtype" != "object" ]; then
    driver_say "✋ self-check: harness.json's 'gates' is a ${gtype:-unreadable value}, and this reads an object of name to command."
    driver_state_set "$t" park_note "the gates in harness.json are a ${gtype:-unreadable value}; self-check reads an object of name to command"
    return "$DRIVER_E_REFUSED"
  fi
  # ONE TAB-SEPARATED `name<TAB>command` PER LINE, from whichever shape this project
  # wrote. A command carries spaces and a name does not, so the split is on the tab.
  #
  # CHANGED-ONLY WHEN THE PROJECT SAYS HOW. The kit's standing rule: local checks run
  # what the change touches, and CI runs the whole suite before anything merges. A
  # project's `gates.changed` is that list; `gates.local` is the whole-app form. On
  # the 2026-09-30 trial the whole-app form ran repo-wide lint and typecheck plus 37
  # repo checks for a one-file fix, and failed on a check the change never touched.
  if [ "$(jq -r '(.gates.changed // null) | type' "$HARNESS_CFG" 2>/dev/null)" = "array" ]; then
    names=$(jq -r '.gates.changed | to_entries[] | "changed \(.key + 1)\t\(.value)"' "$HARNESS_CFG" 2>/dev/null)
  elif [ "$(jq -r '(.gates.local // null) | type' "$HARNESS_CFG" 2>/dev/null)" = "array" ]; then
    names=$(jq -r '.gates.local | to_entries[] | "local \(.key + 1)\t\(.value)"' "$HARNESS_CFG" 2>/dev/null)
  else
    # A value that is not a string is NOT skipped: it falls through as an empty
    # command, so the "every gate is empty, nothing ran" refusal counts it by name.
    # Dropped here it would have left a key configured, unrun and unmentioned.
    names=$(jq -r '.gates | to_entries[] | "\(.key)\t\(if (.value | type) == "string" then .value else "" end)"' "$HARNESS_CFG" 2>/dev/null)
  fi
  if [ -z "$names" ]; then
    driver_say "✋ self-check: harness.json configures no local 'gates' command. A check that never ran reports exactly like one that found nothing, so this refuses rather than passing."
    driver_state_set "$t" park_note "harness.json configures no gate command for self-check to run"
    return "$DRIVER_E_REFUSED"
  fi

  # Heavy local work waits for the machine: under the load ceiling, then one gate
  # slot held across every gate. It waits as long as it takes; it never parks.
  . "$KIT_ROOT/scripts/machine-gate.sh" || {
    driver_state_set "$t" park_note "self-check could not load $KIT_ROOT/scripts/machine-gate.sh, so no gate ran"
    return "$DRIVER_E_REFUSED"; }
  machine_gate_wait_load 0
  machine_gate_acquire 0 "self-check #$t"

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
    ( cd "$wt" && driver_run_project "$DRIVER_CMD_TIMEOUT" "$cmd" ) > "$(driver_state_dir "$t")/steps/gate-$safe.out" 2>&1
    rc=$?
    if [ "$rc" -eq 124 ]; then
      # Its own outcome, not a red gate. A gate that does not return says nothing about
      # the change, and the park question a reader needs is "which command hangs", not
      # "which check failed".
      driver_say "✋ self-check: $name ran out of time (over ${DRIVER_CMD_TIMEOUT}s). A gate that does not return is not a gate that passed."
      driver_state_set "$t" park_note "the '$name' gate did not return within ${DRIVER_CMD_TIMEOUT}s: $cmd"
      machine_gate_release
      return "$DRIVER_E_TIMEOUT"
    elif [ "$rc" -eq 0 ]; then
      driver_say "   self-check: $name ok"
    else
      failed=$((failed+1))
      driver_say "✋ self-check: $name failed (exit $rc) — $(tail -3 "$(driver_state_dir "$t")/steps/gate-$safe.out" 2>/dev/null | tr '\n' ' ')"
      redlines="$redlines${redlines:+ | }$name (\`$cmd\`, exit $rc): $(_driver_gate_lines "$(driver_state_dir "$t")/steps/gate-$safe.out")"
      # 126/127: the command itself could not run — configuration, not the change.
      case "$rc" in 126|127) infra="$infra $name" ;; esac
      jq -cn --arg id "gate-$safe" --arg name "$name" --arg cmd "$cmd" --argjson rc "$rc" \
        --arg out "$(tail -60 "$(driver_state_dir "$t")/steps/gate-$safe.out" 2>/dev/null | cut -c1-400)" \
        '{id: $id, gate: $name, command: $cmd, exit: $rc, output: $out}' >> "$findings.rows"
    fi
  done <<EOS
$names
EOS
  machine_gate_release

  # NOTHING RAN IS A REFUSAL. Every command empty is the same failure as no gates at
  # all, wearing a configured shape — and it printed "0 gate(s) green" and returned
  # OK, so ship pushed and armed auto-merge on code nothing had checked.
  if [ "$ran" -eq 0 ]; then
    driver_say "✋ self-check: every configured gate has an empty command (${empty# }), so nothing ran. Nothing having run is not everything having passed."
    driver_state_set "$t" park_note "every configured gate has an empty command (${empty# }), so nothing ran"
    return "$DRIVER_E_REFUSED"
  fi
  if [ "$failed" -gt 0 ]; then
    driver_say "✋ self-check: $failed of $ran gate(s) red. The local gate IS the gate — nothing is pushed past it."
    # The failing gates travel with the refusal: a park pointing at a log on the host
    # that ran it is a reason nobody else can read.
    driver_state_set "$t" park_note "$failed of $ran gate(s) red — $redlines"
    # ONE REPAIR ROUND, then a park. A gate the model can repair goes to fix with its
    # output as the finding, inside the fix-round ceiling; a second red parks.
    local reds fixes
    reds=$(driver_state_count "$t" selfcheck_red); fixes=$(driver_state_count "$t" fix)
    driver_state_bump "$t" selfcheck_red
    if [ -n "$infra" ]; then
      driver_say "   self-check: not sent to fix —${infra} could not run at all (exit 126/127), which is configuration, not the change."
    elif [ "${reds:-0}" -ge 1 ]; then
      driver_say "   self-check: not sent to fix — this is the second red self-check on this run."
    elif [ "${fixes:-0}" -ge "$DRIVER_MAX_REVIEW_ROUNDS" ]; then
      driver_say "   self-check: not sent to fix — the $DRIVER_MAX_REVIEW_ROUNDS fix round(s) are used."
    elif ! _driver_order_has fix; then
      driver_say "   self-check: not sent to fix — this run has no fix step."
    else
      jq -s . "$findings.rows" > "$findings" && rm -f "$findings.rows"
      driver_state_set "$t" park_note ""
      driver_say "↩ self-check: $failed red gate(s) go to fix with their output as the findings."
      return "$DRIVER_E_REWORK"
    fi
    rm -f "$findings.rows"
    return "$DRIVER_E_REFUSED"
  fi
  rm -f "$findings.rows"
  driver_say "   self-check: $ran gate(s) green"
  return "$DRIVER_OK"
}
