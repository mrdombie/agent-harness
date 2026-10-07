#!/usr/bin/env bash
# pr-in-flight.test.sh — which tickets have a PR that is simply waiting to merge.
#
# An agent that hands off at "armed" (merge.handoff: armed) leaves its ticket
# status:in-review with no claim. claimable-issues.sh offers every such ticket as
# [RESUME PR]; one whose PR is armed and has nothing red is not stranded — it is
# merging — and sending an agent to it wastes a slot.
#
# Run: bash "$0"
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)/pr-in-flight.sh"

FAILED=0
ok()   { printf 'OK       %s\n' "$1"; }
bad()  { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi; }

pr() { # pr <number> <branch> <armed true|false> <draft true|false> <title> <closes|-> <conclusions…>
  local n=$1 br=$2 armed=$3 draft=$4 title=$5 closes=$6; shift 6
  jq -n --argjson n "$n" --arg br "$br" --argjson armed "$armed" --argjson draft "$draft" \
     --arg title "$title" --arg closes "$closes" --args '{
       number: $n, headRefName: $br, isDraft: $draft, title: $title,
       autoMergeRequest: (if $armed then {enabledAt: "x"} else null end),
       closingIssuesReferences: (if $closes == "-" then [] else [{number: ($closes|tonumber)}] end),
       statusCheckRollup: ($ARGS.positional | map({conclusion: (if . == "" then null else . end), state: null}))
     }' "$@"
}
run() { jq -s '.' | BRANCH_PREFIX=sh- bash "$S" | sort -n | tr '\n' ' ' | sed 's/ $//'; }

echo "--- armed with nothing red is in flight; red, unarmed or draft is not ---"
got=$( { pr 1 sh-101/a true  false "fix: a" -  SUCCESS ""
         pr 2 sh-102/b true  false "fix: b" -  SUCCESS FAILURE
         pr 3 sh-103/c false false "fix: c" -  SUCCESS
         pr 4 sh-104/d true  true  "fix: d" -  SUCCESS
         pr 5 sh-105/e true  false "fix: e" -  ""; } | run)
want "only the armed, non-red, non-draft PRs" "101 105" "$got"

echo "--- a timed-out or cancelled check counts as red ---"
got=$( { pr 1 sh-201/a true false "x" - TIMED_OUT
         pr 2 sh-202/b true false "x" - CANCELLED
         pr 3 sh-203/c true false "x" - ACTION_REQUIRED; } | run)
want "timed out, cancelled and action-required are not in flight" "" "$got"

echo "--- the ticket comes from the closing reference, else the branch, else the title ---"
got=$( { pr 1 feature/x  true false "chore: y"     310 SUCCESS
         pr 2 sh-311/z   true false "chore: y"     -   SUCCESS
         pr 3 random     true false "312: thing"   -   SUCCESS
         pr 4 random     true false "SH-313: thing" -  SUCCESS
         pr 5 random     true false "no number"    -   SUCCESS; } | run)
want "closing ref, branch, both title forms; no number gives nothing" "310 311 312 313" "$got"

echo "--- a commit status in ERROR or FAILURE is red too ---"
got=$(jq -n '[{number:1, headRefName:"sh-401/a", isDraft:false, title:"x",
               autoMergeRequest:{enabledAt:"x"}, closingIssuesReferences:[],
               statusCheckRollup:[{conclusion:null, state:"ERROR"}]}]' | BRANCH_PREFIX=sh- bash "$S" | tr '\n' ' ' | sed 's/ $//')
want "status ERROR is red" "" "$got"

echo "--- empty input is no output, not an error ---"
got=$(echo '[]' | BRANCH_PREFIX=sh- bash "$S"); rc=$?
want "empty list" "" "$got"; want "exit 0" "0" "$rc"

exit "$FAILED"
