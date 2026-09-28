#!/usr/bin/env bash
# claim-liveness.sh — is the thing holding this claim still working?
#
#   . scripts/claim-liveness.sh
#   claim_run_fresh <ticket> [state-dir] [stale-hours]   0 = a run touched it recently
#
# WHY A SECOND ANSWER IS NEEDED. The claim record carries a pid and the reconciler
# tests it with `kill -0`. That is the right question for an agent SESSION, which
# lives as long as the work does. It is the wrong question for the step-runner: the
# driver walks seven steps and a step is a process, so between two invocations —
# `--steps start`, then a resume — there is no process at all, and the claim reads
# as abandoned by a run that is very much in progress.
#
# Measured on the 2026-09-27 trial: #10867's claim was RELEASED mid-run, reported as
# "agent gone, no branch, no PR", while the trial was still working it. Nothing had
# gone wrong; the pid it named had simply exited at the end of a step.
#
# THE PROXY, NAMED: `the driver's run record for this ticket was written inside the
# idle window` stands in for `a step-runner is working this ticket`. Those are not
# the same thing — a run killed thirty seconds ago still reads as fresh for the rest
# of the window — and that is the direction to be wrong in: the cost of waiting is
# one window, and the cost of releasing a live claim is two agents on one branch.
#
# It is the same rule the claim flow already states for staleness — "a ticket claimed
# three days ago whose branch was pushed an hour ago is being worked on" — applied to
# the one artifact a driver run writes on every step.

# claim_run_fresh <ticket> [state-dir] [stale-hours]
claim_run_fresh() {
  local t="${1:?claim_run_fresh: need a ticket}"
  local dir="${2:-${STATE_DIR:-}}" hours="${3:-${STALE_HOURS:-4}}"
  local f at epoch now
  [ -n "$dir" ] || return 1
  f="$dir/driver/$t/state.json"
  [ -f "$f" ] || return 1
  at=$(jq -r '.updated_at // ""' "$f" 2>/dev/null)
  [ -n "$at" ] || return 1
  # A whole number of hours, or the window is not a window. `[` fails OPEN on a
  # non-integer, and failing open here means calling a dead run fresh for ever.
  case "$hours" in ''|*[!0-9]*) return 1 ;; esac
  # Both date dialects: BSD wants -j -f, GNU wants -d. A stamp neither can read is
  # not a fresh run — it is an unreadable record, and that is a "no".
  epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$at" +%s 2>/dev/null) \
    || epoch=$(date -u -d "$at" +%s 2>/dev/null) || return 1
  [ -n "$epoch" ] || return 1
  now=$(date +%s)
  [ $(( now - epoch )) -lt $(( hours * 3600 )) ]
}
