#!/usr/bin/env bash
# gh-open-prs-page.sh <prs.json> <gh args…> — what GitHub answers to one page of
# gh_prs_paged's OpenPullRequests query, read from a fixture in the shape
# `gh pr list --json` prints. Test stubs hand it the `api graphql` call:
#
#   case "$*" in "api graphql "*OpenPullRequests*) exec bash "$KIT/scripts/fixtures/gh-open-prs-page.sh" "$f" "$@" ;; esac
#
# The cursor is the offset into the fixture. FAKE_GH_PRS_MAX=N answers a page
# asking for more than N with GitHub's own 504, as 81 open PRs did on 2026-10-19.
f="$1"; shift
first=100; after=0; base=""; prev=""
for a in "$@"; do
  case "$prev" in
    -F|-f) case "$a" in first=*) first="${a#first=}" ;; after=*) after="${a#after=}" ;; base=*) base="${a#base=}" ;; esac ;;
  esac
  prev="$a"
done
if [ -n "${FAKE_GH_PRS_MAX:-}" ] && [ "$first" -gt "$FAKE_GH_PRS_MAX" ]; then
  echo "HTTP 504: Gateway Timeout (https://api.github.com/graphql)" >&2; exit 1
fi
[ -s "$f" ] || printf '[]\n' > "$f"
jq -c --argjson first "$first" --argjson off "$after" --arg base "$base" '
  [.[] | select($base == "" or .baseRefName == null or .baseRefName == $base)] as $all
  | ($all[$off:$off + $first]) as $page
  | {data: {repository: {pullRequests: {
      pageInfo: {hasNextPage: (($off + $first) < ($all | length)), endCursor: (($off + $first) | tostring)},
      nodes: [$page[] |
        (if has("labels") then .labels = {nodes: (.labels // [])} else . end)
        | (if has("closingIssuesReferences") then .closingIssuesReferences = {nodes: (.closingIssuesReferences // [])} else . end)
        | (if has("statusCheckRollup") then .statusCheckRollup = {nodes: [{commit: {statusCheckRollup: {contexts: {nodes: [
              (.statusCheckRollup // [])[]
              | if (.__typename == "StatusContext") or (.__typename == null and has("context"))
                then {__typename: "StatusContext", context, state, targetUrl, createdAt: .startedAt}
                else {__typename: "CheckRun", name, status, conclusion, startedAt, completedAt, detailsUrl,
                      checkSuite: {workflowRun: {workflow: {name: .workflowName}}}}
                end]}}}}]} else . end)
        | (if (.autoMergeRequest | type) == "object" then .autoMergeRequest.enabledBy |= (if . == null then null else . + {__typename: (if .is_bot then "Bot" else "User" end)} end) else . end)
      ]}}}}' "$f"
