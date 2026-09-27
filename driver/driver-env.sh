#!/usr/bin/env bash
# driver-env.sh — the one place the driver resolves WHERE things are and HOW it
# reaches the outside world.
#
#   . "$KIT_ROOT/driver/driver-env.sh" || exit 1
#
# It sits on swarm/swarm-env.sh rather than beside it. The swarm layer already
# resolves the state dir, the project's labels, the GitHub seam and the clock,
# and a second copy of that resolution is a second thing to keep in step — the
# drift this whole epic exists to remove.
#
# Sets, on top of everything swarm-env.sh sets:
#   DRIVER_DIR       per-ticket run records: $STATE_DIR/driver/<ticket>
#   DRIVER_BRIEFS    the AI step briefs (owned by the briefs ticket, read here)
#   DRIVER_SCHEMAS   $DRIVER_BRIEFS/schemas — the JSON each brief must return
#   DRIVER_STEPS     the fixed order, one name per step
#   DRIVER_MAX_BUILD_TRIES   red-before-green attempts before the ticket parks (5)
#   DRIVER_MAX_REVIEW_ROUNDS review rounds before leftovers become a ticket (2)
#
# The seams, each overridable so a test points it at a recorder:
#   DRIVER_CLAUDE    the agent runner   (default: claude)
#   SWARM_GH         the GitHub CLI     (inherited from swarm-env)
#
# Exit codes are the driver's whole control flow, so they are named once here and
# nowhere else:
#   0  the step finished
#   20 the step asked a question — the ticket parks with it
#   21 the brief named a Skill and the run log does not contain that Skill call
#   22 the answer did not match the schema the brief must return
#   23 there is no brief for this step
#   24 a refusal gate said no
#   25 a command outran its time limit — a hang is not a failure to retry
#   30 the reviewer found blockers — go back to the build step
_driver_self="${BASH_SOURCE[0]}"
. "$(cd "$(dirname "$_driver_self")/../swarm" && pwd)/swarm-env.sh" || return 1 2>/dev/null || exit 1
DRIVER_HOME="$(cd "$(dirname "$_driver_self")" && pwd)"
unset _driver_self

DRIVER_DIR="${DRIVER_DIR:-$STATE_DIR/driver}"
DRIVER_BRIEFS="${DRIVER_BRIEFS:-$KIT_ROOT/briefs}"
DRIVER_SCHEMAS="${DRIVER_SCHEMAS:-$DRIVER_BRIEFS/schemas}"
mkdir -p "$DRIVER_DIR" 2>/dev/null || true

# The order. It is a list, not a set: "runs the steps in order" is the guarantee,
# and the orchestrator walks exactly this.
DRIVER_STEPS="${DRIVER_STEPS:-start plan build self-check review record ship}"

# Five tries, then park — the number in the approved design's flowchart.
DRIVER_MAX_BUILD_TRIES="${DRIVER_MAX_BUILD_TRIES:-5}"
DRIVER_MAX_REVIEW_ROUNDS="${DRIVER_MAX_REVIEW_ROUNDS:-2}"

DRIVER_CLAUDE="${DRIVER_CLAUDE:-claude}"

DRIVER_OK=0
DRIVER_E_QUESTION=20
DRIVER_E_NO_SKILL=21
DRIVER_E_SCHEMA=22
DRIVER_E_NO_BRIEF=23
DRIVER_E_REFUSED=24
DRIVER_E_TIMEOUT=25
DRIVER_E_REWORK=30

# driver_say <message…> — one line on stdout and one in the ticket's own log, so
# a run that scrolled past is still readable afterwards.
driver_say() {
  printf '%s\n' "$*"
  [ -n "${DRIVER_TICKET:-}" ] || return 0
  mkdir -p "$DRIVER_DIR/$DRIVER_TICKET" 2>/dev/null
  printf '%s %s\n' "$(swarm_stamp)" "$*" >> "$DRIVER_DIR/$DRIVER_TICKET/log"
}

driver_opt_early() { local v; v=$(toolkit_cfg "$1" 2>/dev/null) || v=""; printf '%s' "${v:-$2}"; }

# driver_bounded <seconds> <command> — run a command with a ceiling on its life.
#
# NOTHING ELSE BOUNDS A STEP THAT NEVER RETURNS. The orchestrator bounds a step that
# keeps saying "go back", and the build step bounds its own retries, but a command that
# hangs is outside both: no park, no refusal, the claim held and the worktree pinned —
# the one state the whole design exists to make impossible. And the build step's command
# comes from the MODEL, so a reported watch-mode runner (`vitest` without `run`,
# `jest --watch`, a dev server) hangs the run for ever on an answer that looks perfectly
# reasonable.
#
# Returns 124 on a timeout, which is the conventional code and is what a caller names
# its refusal from. A command that genuinely exits 124 is indistinguishable; that is the
# cost of having a bound at all.
#
# IT KILLS THE PROCESS GROUP, not just the command. `exec` plus a bare alarm terminates
# the shell and orphans its children, so a watch-mode runner carries on inside the ticket
# worktree after the bound has "held" — and the worktree is then removed from under a
# live process. The child gets its own group and the group is signalled.
#
# `timeout` is GNU coreutils and is not on a stock mac, so perl is the portable one.
# Neither available: run it unbounded and SAY SO, because a bound nobody applied must not
# read like one that held.
DRIVER_CMD_TIMEOUT="${DRIVER_CMD_TIMEOUT:-$(driver_opt_early cmdTimeout 900)}"

# driver_warn_unbounded — say ONCE, through the ticket's own log, that the configured
# time limit is not a number and therefore bounds nothing. driver_bounded also warns, but
# a caller that redirects the command's output (self-check writes each gate to a file)
# captures that warning into the file nobody is reading yet. This one goes where the
# operator is looking.
driver_check_timeout() {
  case "${DRIVER_CMD_TIMEOUT:-}" in
    ''|*[!0-9]*|0)
      driver_say "⚠ the configured time limit is '${DRIVER_CMD_TIMEOUT:-}', which is not a number of seconds, so commands run UNBOUNDED — set cmdTimeout to a whole number."
      return 1 ;;
  esac
  return 0
}

driver_bounded() { # <seconds> <command>
  local secs cmd rc
  # One name per line. bash expands the whole `local` command before assigning any of
  # it, so `local secs="${1:-$X}" cmd="$2"` with $2 unset aborts on the SECOND word
  # under `set -u` before the first default is ever applied.
  secs="${1:-}"
  cmd="${2:-}"
  [ -n "$secs" ] || secs="$DRIVER_CMD_TIMEOUT"
  # A NON-NUMBER IS NOT A CEILING. perl reads `alarm "15m"` as `alarm 0`, which CANCELS
  # the alarm — so an operator writing "15m" or "900s" in the config silently removes
  # every bound in the driver. Refuse to pretend: run it, and say the bound is not there.
  case "$secs" in
    ''|*[!0-9]*|0)
      echo "driver: '$secs' is not a number of seconds, so '$cmd' runs UNBOUNDED — set cmdTimeout to a whole number of seconds." >&2
      /bin/sh -c "$cmd"; return $? ;;
  esac
  if command -v perl >/dev/null 2>&1; then
    perl -e '
      my $secs = shift; my @cmd = @ARGV;
      my $pid = fork;
      if (!defined $pid) { exit 127 }
      if ($pid == 0) { setpgrp(0, 0); exec @cmd; exit 127 }
      $SIG{ALRM} = sub { kill("TERM", -$pid); sleep 1; kill("KILL", -$pid); exit 124 };
      alarm $secs;
      waitpid($pid, 0);
      my $st = $?;
      alarm 0;
      exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' "$secs" /bin/sh -c "$cmd"
    rc=$?
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$secs" /bin/sh -c "$cmd"; rc=$?
  else
    echo "driver: neither perl nor timeout is available, so '$cmd' runs UNBOUNDED" >&2
    /bin/sh -c "$cmd"; rc=$?
  fi
  return "$rc"
}

# driver_opt <dotted.key> <default> — an OPTIONAL project fact. toolkit_cfg
# refuses a missing key by name, which is right for a fact the kit cannot invent;
# these are tuning the kit can default without naming anyone's project.
driver_opt() { local v; v=$(toolkit_cfg "$1" 2>/dev/null) || v=""; printf '%s' "${v:-$2}"; }

export DRIVER_HOME DRIVER_DIR DRIVER_BRIEFS DRIVER_SCHEMAS DRIVER_STEPS
export DRIVER_MAX_BUILD_TRIES DRIVER_MAX_REVIEW_ROUNDS DRIVER_CLAUDE DRIVER_CMD_TIMEOUT
export DRIVER_OK DRIVER_E_QUESTION DRIVER_E_NO_SKILL DRIVER_E_SCHEMA
export DRIVER_E_NO_BRIEF DRIVER_E_REFUSED DRIVER_E_TIMEOUT DRIVER_E_REWORK
