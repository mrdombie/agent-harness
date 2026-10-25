#!/usr/bin/env bash
# pr-watch.sh — wait on pull requests in the shell, and wake the model once.
#
#   pr-watch.sh <pr> [<pr>…]     prints one line per PR that reached an event, then exits
#
# Events: MERGED · CLOSED · RED (a check failed) · CONFLICT · GREEN (at least one
# check reported and none pending). Run it with the Bash tool's run_in_background:
# its exit IS the wake, so a window waiting on CI spends no tokens until something
# happened. Give up after PR_WATCH_MAX seconds (default 3000) with a TIMEOUT line,
# which is the long fallback, not a poll.
#
# WHY. Measured 2026-10-15 over eight loop windows: 1,100 of 8,630 window calls
# were the model asking gh about a PR or a run, each re-reading a context of
# 150k-546k tokens to learn "still pending". Here the same question costs a gh call.
#
# GREEN needs a reported check: an empty rollup is not a green one (agent-harness#4
# merged red on an empty rollup).
set -uo pipefail
[ $# -ge 1 ] || { echo "usage: pr-watch.sh <pr>…" >&2; exit 1; }
REPO="${PR_WATCH_REPO:-${REPO_SLUG:-}}"
EVERY="${PR_WATCH_EVERY:-60}"; MAX="${PR_WATCH_MAX:-3000}"
start=$(date +%s)
# A check listed in release.nonBlockingChecks warns until the release: never a RED here.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release-checks.sh" || exit 1
HARNESS_CFG="${HARNESS_CFG:-$(git rev-parse --show-toplevel 2>/dev/null)/.claude/harness.json}"
NB=$(release_nonblocking_json)
# Merge first: an Evidence capture develop does not require wakes nobody (release_evidence_waived).
if REPO_SLUG="${REPO_SLUG:-$REPO}" release_evidence_waived; then NB=$(jq -c --arg c "$(release_evidence_check | tr '[:upper:]' '[:lower:]')" '. + [$c]' <<<"$NB"); fi

state() { # <pr> → one event word, or nothing while it is still pending
  gh pr view "$1" ${REPO:+--repo "$REPO"} --json state,mergeable,statusCheckRollup 2>/dev/null | jq -r --argjson nb "$NB" "$RELEASE_NB_JQ"'
    ([.statusCheckRollup | newest_runs | .[] | select(release_nb($nb) | not) | (.conclusion // .state // "") | ascii_upcase]) as $c
    | if .state == "MERGED" then "MERGED"
      elif .state == "CLOSED" then "CLOSED"
      elif ($c | map(select(test("FAILURE|ERROR|TIMED_OUT|STARTUP_FAILURE|ACTION_REQUIRED"))) | length) > 0 then "RED"
      elif .mergeable == "CONFLICTING" then "CONFLICT"
      elif ($c | length) > 0 and ($c | map(select(test("^(SUCCESS|NEUTRAL|SKIPPED)$") | not)) | length) == 0 then "GREEN"
      else empty end'
}

while :; do
  hit=0
  for pr in "$@"; do
    ev=$(state "$pr")
    [ -n "$ev" ] && { printf 'PR #%s %s\n' "$pr" "$ev"; hit=1; }
  done
  [ "$hit" -eq 1 ] && exit 0
  [ $(( $(date +%s) - start )) -ge "$MAX" ] && { printf 'TIMEOUT — still pending: %s\n' "$*"; exit 0; }
  sleep "$EVERY"
done
