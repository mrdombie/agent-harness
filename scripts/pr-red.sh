#!/usr/bin/env bash
# pr-red.sh — is this pull request really red, so a repair may start on it?
#
#   . scripts/pr-red.sh
#   pr_red_required [branch]       the checks the branch's LIVE rules require, as a JSON
#                                  array of lower-cased names; read once per process
#   pr_red_verdict <pr-json> [hold-check] [nonblocking-json]
#   pr_red_classify <pr-json> <required-json> [hold-check] [nonblocking-json]
#
# <pr-json> is the PR as the open-PR read has it (number, baseRefName, isDraft,
# mergeable, mergeStateStatus, statusCheckRollup). Both print one line,
# "<verdict>\t<reason>", and return 0 only for a verdict a repair may start on:
#   red      a REQUIRED check concluded FAILURE or ERROR, with no required check still running
#   clash    GitHub says the branch conflicts (mergeable CONFLICTING / mergeStateStatus DIRTY)
#   finish   a draft with every required check settled and none failed: finishing it is the repair
# and 1 for every other:
#   pending  a required check is still queued or running: its result is not in yet
#   rerun    a required check was cancelled, timed out or never got a runner: a re-run, not a repair
#   green    no required check failed and nothing clashes (a red that is not required included)
#   unread   the PR or the branch's rules could not be read; the next tick asks again
#
# REPAIRS STARTED ON PRS THAT WERE NOT RED. On 2026-10-23 repairs on two PRs started
# while CI was still running, then parked asking "ship as it is?" and turned their PR
# to draft with auto-merge off, and one was spawned and parked whose only red was a
# check the base branch does not require; 30 of 101 repair runs in three days pushed
# nothing. So a repair starts only on a settled red of a required check, or a clash.
#
# REQUIRED MEANS THE LIVE RULES, NEVER A LIST IN CONFIG: the branch's rulesets
# (rules/branches/<b>) plus classic branch protection, which answers 404 when it
# requires nothing. The hold check and release.nonBlockingChecks are never a red.

_pr_red_gh() { if declare -F swarm_gh >/dev/null 2>&1; then swarm_gh "$@"; else gh "$@"; fi; }

# The cache is a file when PR_RED_REQ_FILE names one (a tick empties it at its start), so a
# read made inside $( ) still counts for the next; else a variable, for this shell only.
PR_RED_REQ_CACHE="${PR_RED_REQ_CACHE:-}"   # branch \t json, one line per branch read
pr_red_required() { # [branch]
  local b="${1:-${INTEGRATION_BRANCH:-develop}}" hit rules prot out
  [ -z "${PR_RED_REQ_FILE:-}" ] || PR_RED_REQ_CACHE=$(cat "$PR_RED_REQ_FILE" 2>/dev/null)
  hit=$(awk -F'\t' -v b="$b" '$1 == b { print $2; exit }' <<<"$PR_RED_REQ_CACHE")
  [ -z "$hit" ] || { printf '%s\n' "$hit"; return 0; }
  rules=$(_pr_red_gh api "repos/$REPO_SLUG/rules/branches/$b" --paginate 2>/dev/null) || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$rules" || return 1
  prot=$(_pr_red_gh api "repos/$REPO_SLUG/branches/$b/protection/required_status_checks" 2>/dev/null) || prot='{}'
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$prot" || prot='{}'
  out=$(jq -cn --argjson r "$rules" --argjson p "$prot" '
    [ ($r[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context),
      ($p.contexts // [])[], ($p.checks // [])[]?.context ]
    | map(select(type == "string") | ascii_downcase) | unique') || return 1
  PR_RED_REQ_CACHE="$PR_RED_REQ_CACHE$b"$'\t'"$out"$'\n'
  [ -z "${PR_RED_REQ_FILE:-}" ] || printf '%s\t%s\n' "$b" "$out" >> "$PR_RED_REQ_FILE" 2>/dev/null
  printf '%s\n' "$out"
}

pr_red_classify() { # <pr-json> <required-json> [hold] [nb-json]
  local pr="$1" req="$2" hold="${3-approval}" nb="${4:-[]}" out
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$pr" || { printf 'unread\tthe PR could not be read\n'; return 1; }
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$req" || { printf 'unread\tthe required checks could not be read\n'; return 1; }
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$nb" || nb='[]'
  out=$(jq -rn --argjson p "$pr" --argjson r "$req" --arg hold "$hold" --argjson nb "$nb" '
    def names: map(.name) | unique | join(", ");
    def stamp: [.completedAt, .startedAt, .createdAt] | map(select(type == "string" and . != "")) | first // "";
    def running: ((.status // "COMPLETED") != "COMPLETED") or ((.state // "") | test("^(PENDING|EXPECTED|QUEUED|IN_PROGRESS)$"));
    [ ($p.statusCheckRollup // [])[] | select(type == "object")
      | {name: (.name // .context // ""), run: (if running then 1 else 0 end), at: stamp,
         state: (if running then "IN_PROGRESS" else (.conclusion // .state // "") end)} ]
    | group_by(.name) | map(max_by([.run, .at]))
    | map(select((.name | ascii_downcase) as $n
                 | any($r[]; . == $n)
                   and (($hold != "" and ($n | contains($hold | ascii_downcase))) or any($nb[]; . == $n) | not))) as $c
    | ($c | map(select(.state | test("^(FAILURE|ERROR)$")))) as $failed
    | ($c | map(select(.state == "IN_PROGRESS"))) as $running
    | ($c | map(select(.state | test("^(CANCELLED|TIMED_OUT|STARTUP_FAILURE|STALE)$")))) as $cancelled
    | if ($p.mergeable // "") == "CONFLICTING" or ($p.mergeStateStatus // "") == "DIRTY" then "clash\tit conflicts with its base branch"
      elif ($running | length) > 0 then "pending\trequired \($running | names) still running"
      elif ($failed | length) > 0 then "red\trequired check(s) failed: \($failed | names)"
      elif ($cancelled | length) > 0 then "rerun\trequired \($cancelled | names) cancelled or never ran — a re-run, not a repair"
      elif ($p.isDraft // false) then "finish\ta draft with its required checks settled"
      else "green\tno required check failed and nothing clashes" end' 2>/dev/null)
  [ -n "$out" ] || { printf 'unread\tits checks could not be read\n'; return 1; }
  printf '%s\n' "$out"
  case "${out%%$'\t'*}" in red|clash|finish) return 0 ;; *) return 1 ;; esac
}

pr_red_verdict() { # <pr-json> [hold] [nb-json]
  local base req
  base=$(jq -r '.baseRefName // empty' <<<"$1" 2>/dev/null)
  req=$(pr_red_required "$base") || { printf 'unread\tthe rules of %s could not be read\n' "${base:-${INTEGRATION_BRANCH:-develop}}"; return 1; }
  pr_red_classify "$1" "$req" "${2-approval}" "${3:-[]}"
}
