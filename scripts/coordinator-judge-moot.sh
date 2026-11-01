#!/usr/bin/env bash
# coordinator-judge-moot.sh — the judgement events a rule can settle, so no model is
# started for them. Sourced by coordinator-judge.sh after coordinator-env.sh.
#
#   judge_moot_read < events        one batched read for every waiting event: the
#                                   tickets' and PRs' states, the open PRs' heads.
#                                   Exit 1 when GitHub could not be read: nothing is
#                                   settled this tick.
#   judge_moot <event-json>         prints why the event is already settled and exits 0;
#                                   exits 1 when only a judge can decide it.
#
# THE PROXY, NAMED: "the PR is merged or closed, its head is not the event's head, its
# ticket is closed, or the ticket already has a queue entry or a live run" stands in
# for "a judge would decide nothing". Measured over 441 judgements (28 Oct – 1 Nov):
# 318 were exactly those, each a fresh claude -p.
# A frozen or other event kind is never settled here: a judge reads it.

declare -F gh_issues_batch >/dev/null 2>&1 || . "$KIT_ROOT/scripts/gh-batch.sh" || return 1
declare -F pid_is_run >/dev/null 2>&1 || . "$KIT_ROOT/scripts/claim-proc.sh" || return 1

JUDGE_MOOT_STATES='{}'
JUDGE_MOOT_HEADS='{}'

judge_moot_read() {
  local nums prs
  nums=$(jq -r 'select(.kind == "red-pr" or .kind == "stood-down") | .ticket // empty, .pr // empty' 2>/dev/null \
    | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ')
  [ -n "${nums// /}" ] || return 0
  # shellcheck disable=SC2086
  JUDGE_MOOT_STATES=$(gh_issues_batch $nums 2>/dev/null) || { JUDGE_MOOT_STATES='{}'; return 1; }
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$JUDGE_MOOT_STATES" || { JUDGE_MOOT_STATES='{}'; return 1; }
  prs=$(gh_open_prs 2>/dev/null) || { JUDGE_MOOT_STATES='{}'; return 1; }
  JUDGE_MOOT_HEADS=$(jq -c 'map({key: (.number|tostring), value: (.headRefOid // "")}) | from_entries' <<<"$prs" 2>/dev/null) \
    || { JUDGE_MOOT_STATES='{}'; JUDGE_MOOT_HEADS='{}'; return 1; }
}

# The ticket has a run going now: a record with no end, whose pid is still that run.
judge_moot_live() { # <ticket>
  local rec pid at
  for rec in "$STATE_DIR"/runs/claim-"$1"-*.json; do
    [ -f "$rec" ] || continue
    [ -f "${rec%.json}.ended" ] && continue
    pid=$(jq -r '.child_pid // .pid // empty' "$rec" 2>/dev/null); [ -n "$pid" ] || continue
    at=$(jq -r '.started_at // empty' "$rec" 2>/dev/null)
    if [ -n "$at" ]; then pid_is_run "$pid" "$at" && return 0
    else claim_pid_alive "$pid" && return 0; fi
  done
  return 1
}

judge_moot() { # <event-json>
  local ev="$1" kind t pr sha st head
  kind=$(jq -r '.kind // ""' <<<"$ev"); t=$(jq -r '.ticket // ""' <<<"$ev"); pr=$(jq -r '.pr // ""' <<<"$ev")
  case "$kind" in red-pr|stood-down) ;; *) return 1 ;; esac
  if [ -n "$pr" ]; then
    st=$(jq -r --arg n "$pr" '.[$n].state // ""' <<<"$JUDGE_MOOT_STATES")
    case "$st" in MERGED|CLOSED) printf 'PR #%s is %s' "$pr" "$st"; return 0 ;; esac
  fi
  if [ "$kind" = red-pr ] && [ -n "$pr" ]; then
    sha=$(jq -r '.id // ""' <<<"$ev"); sha=${sha##*:}
    head=$(jq -r --arg n "$pr" '.[$n] // ""' <<<"$JUDGE_MOOT_HEADS")
    if [ -n "$head" ] && [ -n "$sha" ] && [ "$head" != "$sha" ]; then
      printf 'PR #%s moved on to %s' "$pr" "${head:0:9}"; return 0
    fi
  fi
  if [ -n "$t" ]; then
    st=$(jq -r --arg n "$t" '.[$n].state // ""' <<<"$JUDGE_MOOT_STATES")
    [ "$st" = CLOSED ] && { printf '#%s is closed' "$t"; return 0; }
    if jq -e --argjson n "$t" '(.tickets // []) | any(.n == $n)' "$COORD_QUEUE" >/dev/null 2>&1; then
      printf '#%s is already on the queue' "$t"; return 0
    fi
    judge_moot_live "$t" && { printf '#%s has a live run' "$t"; return 0; }
  fi
  return 1
}
