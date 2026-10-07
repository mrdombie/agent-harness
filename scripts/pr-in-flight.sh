#!/usr/bin/env bash
# pr-in-flight.sh — tickets whose PR is armed for auto-merge with nothing red:
# merging, not stranded. One ticket number per line.
#
#   gh pr list --state open --json number,headRefName,isDraft,title,autoMergeRequest,closingIssuesReferences,statusCheckRollup \
#     | pr-in-flight.sh
#
# claimable-issues.sh leaves these out of [RESUME PR]: an agent that handed off
# at "armed" (merge.handoff: armed) released its claim on purpose, and sending the
# next agent to a PR that is about to merge wastes a slot. A PR with any failed,
# cancelled, timed-out or action-required check is NOT in flight — that one needs
# a person or an agent.
#
# The ticket is the PR's closing reference, else ${BRANCH_PREFIX}<n>/ in the
# branch, else a title that opens with the number ("1234: …", "SH-1234: …").
set -euo pipefail
PREFIX="${BRANCH_PREFIX:-sh-}"
jq -r --arg prefix "$PREFIX" '
  .[]
  | select((.isDraft | not) and .autoMergeRequest != null)
  | select([.statusCheckRollup[]?
            | ((.conclusion // "") + " " + (.state // ""))
            | test("FAILURE|ERROR|CANCELLED|TIMED_OUT|ACTION_REQUIRED|STARTUP_FAILURE")]
           | any | not)
  | if (.closingIssuesReferences | length) > 0 then .closingIssuesReferences[].number
    elif (.headRefName | test("^" + $prefix + "[0-9]+/")) then (.headRefName | capture("^" + $prefix + "(?<n>[0-9]+)/").n)
    else (.title | [match("^[^0-9]{0,4}([0-9]{3,6}):").captures[0].string] | first // empty)
    end
' | sort -un
