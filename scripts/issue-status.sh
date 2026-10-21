#!/usr/bin/env bash
# issue-status.sh — the one way a ticket's status label changes.
#
#   issue_status_set  <n> <status> [--also <label>]... [--drop <label>]... [--repo <slug>]
#   issue_status_mark <n> <marker> [--repo <slug>]
#   bash issue-status.sh set|mark <n> <label> [...]      (the same, as a command)
#
# `set` leaves the ticket wearing exactly one lifecycle status: it reads the labels
# fresh and, in ONE `gh issue edit`, adds <status> and removes every other status
# label it has. Steps that added theirs and removed only the one they expected left
# tickets wearing ready, claimed, in-review and partial at once, and every reader
# took whichever it met first.
#
# Markers are the status-prefixed labels that are not a lifecycle state and sit
# BESIDE one on purpose: the decision labels (labels.pmDecision, labels.pmTrack and
# any status label in labels.decision) — a question waiting on the PM, whatever
# state the work is in — and labels.batched, a child built by its batch's PR. `set`
# keeps them; `mark` adds one; whoever answers the question takes it off (--drop).
#
# --also adds a marker or a non-status label (the owner's hold) in the same call;
# --drop removes any label in the same call. Every other label family is untouched.
# After `set`, ISSUE_STATUS_ADDED is 1 when <status> was not already on the ticket.
# Exit: 0 done (or nothing to do), 1 the labels could not be read or the edit failed,
# 2 a usage error (a marker given to `set`, a lifecycle status given to --also/`mark`).

# Sourced into zsh (an agent's Bash tool is the operator's login shell): run the
# bash body as a command, since zsh does not split the flag list below.
if [ -z "${BASH_VERSION:-}" ]; then
  issue_status_set()  { bash "${KIT_ROOT:?}/scripts/issue-status.sh" set "$@"; }
  issue_status_mark() { bash "${KIT_ROOT:?}/scripts/issue-status.sh" mark "$@"; }
  return 0
fi

issue_status_gh() {
  if declare -F gh_call >/dev/null 2>&1; then gh_call "$@"; else "${SWARM_GH:-gh}" "$@"; fi
}

issue_status_prefix() { printf '%s' "${STATUS_PREFIX:-${LBL_READY%%:*}:}"; }

issue_status_markers() {
  local p d; p=$(issue_status_prefix)
  printf '%s\n' "${LBL_PM_DECISION:-}" "${LBL_PM_TRACK:-}" "${LBL_BATCHED:-${p}batched}"
  for d in ${DECISION_LABELS:-}; do case "$d" in "$p"*) printf '%s\n' "$d" ;; esac; done
}

issue_status_is_marker() { issue_status_markers | grep -qxF -- "$1"; }

# A lifecycle status: status-prefixed and not a marker.
issue_status_is_lifecycle() {
  case "$1" in "$(issue_status_prefix)"*) ! issue_status_is_marker "$1" ;; *) return 1 ;; esac
}

issue_status_set() {
  ISSUE_STATUS_ADDED=0
  local n="${1:-}" want="${2:-}" repo="${REPO_SLUG:-}" also="" dropx="" l current
  n="${n#\#}"
  case "$n" in ''|*[!0-9]*) echo "issue-status: set needs a ticket number, got '${1:-}'" >&2; return 2 ;; esac
  issue_status_is_lifecycle "$want" \
    || { echo "issue-status: '$want' is not a lifecycle status — markers go on with mark" >&2; return 2; }
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --also) issue_status_is_lifecycle "${2:-}" \
                && { echo "issue-status: --also '$2' is a second lifecycle status" >&2; return 2; }
              also="$also${2:-}"$'\n'; shift 2 ;;
      --drop) dropx="$dropx${2:-}"$'\n'; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      *) echo "issue-status: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  [ -n "$repo" ] || { echo "issue-status: no repo (REPO_SLUG or --repo)" >&2; return 2; }
  current=$(issue_status_gh issue view "$n" --repo "$repo" --json labels -q '.labels[].name' 2>/dev/null) \
    || { echo "issue-status: could not read #$n's labels — status not changed" >&2; return 1; }

  # Flat strings, not arrays: macOS bash 3.2 errors expanding an empty array under set -u.
  local args="" add=0 rm_any=0
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if issue_status_is_lifecycle "$l" && [ "$l" != "$want" ]; then
      args="$args"$'\n'"--remove-label"$'\n'"$l"; rm_any=1
    elif printf '%s' "$dropx" | grep -qxF -- "$l"; then
      args="$args"$'\n'"--remove-label"$'\n'"$l"; rm_any=1
    fi
  done <<<"$current"
  printf '%s\n' "$current" | grep -qxF -- "$want" \
    || { args="$args"$'\n'"--add-label"$'\n'"$want"; add=1; ISSUE_STATUS_ADDED=1; }
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    printf '%s\n' "$current" | grep -qxF -- "$l" || { args="$args"$'\n'"--add-label"$'\n'"$l"; add=1; }
  done <<<"$also"
  [ "$add$rm_any" != 00 ] || return 0

  local IFS=$'\n'
  # shellcheck disable=SC2086  # $args is a newline-separated flag list, split on newlines only
  issue_status_gh issue edit "$n" --repo "$repo" ${args#$'\n'} >/dev/null 2>&1 \
    || { echo "issue-status: the edit of #$n to $want failed" >&2; return 1; }
}

issue_status_mark() {
  local n="${1:-}" m="${2:-}" repo="${REPO_SLUG:-}"
  n="${n#\#}"
  case "$n" in ''|*[!0-9]*) echo "issue-status: mark needs a ticket number, got '${1:-}'" >&2; return 2 ;; esac
  issue_status_is_marker "$m" \
    || { echo "issue-status: '$m' is not a marker — a lifecycle status goes on with set" >&2; return 2; }
  [ "${3:-}" = --repo ] && repo="${4:-}"
  [ -n "$repo" ] || { echo "issue-status: no repo (REPO_SLUG or --repo)" >&2; return 2; }
  issue_status_gh issue edit "$n" --repo "$repo" --add-label "$m" >/dev/null 2>&1 \
    || { echo "issue-status: could not mark #$n $m" >&2; return 1; }
}

# Run as a command. The flag stops the toolkit-env it sources from re-entering here.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ -z "${_issue_status_cmd:-}" ]; then
  _issue_status_cmd=1
  [ -n "${LBL_READY:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh" || exit 1
  declare -F gh_call >/dev/null 2>&1 || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-batch.sh" 2>/dev/null || true
  cmd="${1:-}"; shift || true
  case "$cmd" in
    set)  issue_status_set "$@" ;;
    mark) issue_status_mark "$@" ;;
    *) echo "usage: issue-status.sh set <n> <status> [--also L]... [--drop L]... [--repo R] | mark <n> <marker> [--repo R]" >&2; exit 2 ;;
  esac
fi
