#!/usr/bin/env bash
# A fake GitHub answering gh_open_prs's paged GraphQL read from a file of open PRs
# in `gh pr list --json` shape, so a test keeps writing the shape its code reads.
#
#   bash gh-open-prs.sh <prs.json> <the gh args…>   # from a fake gh's `api graphql` case
#
# Knobs: FAKE_PRS_504_ABOVE=<n> answers HTTP 504 to a page asking for more than n;
# FAKE_PRS_FAIL_AFTER=<cursor> fails the page after that cursor ("" = the first).
# FAKE_PRS_TOTAL=<n> reports that totalCount instead of the file's (a PR opened mid-read).
f="$1"; shift
first=100; after=""; has_after=0; prev=""
for a in "$@"; do
  case "$prev" in
    -F|-f) case "$a" in first=*) first="${a#first=}" ;; after=*) after="${a#after=}"; has_after=1 ;; esac ;;
  esac
  prev="$a"
done
if [ -n "${FAKE_PRS_504_ABOVE:-}" ] && [ "$first" -gt "$FAKE_PRS_504_ABOVE" ]; then
  echo "HTTP 504: 504 Gateway Timeout (https://api.github.com/graphql)" >&2; exit 1
fi
if [ "${FAKE_PRS_FAIL_AFTER+set}" = set ] && [ "$FAKE_PRS_FAIL_AFTER" = "$after" ]; then
  echo "gh: something went wrong (induced)" >&2; exit 1
fi
[ "$has_after" = 1 ] && start="${after#c}" || start=0
# Oldest first, as the real query orders them.
jq -c --argjson s "$start" --argjson n "$first" --arg tt "${FAKE_PRS_TOTAL:-}" '
  sort_by(.number) as $all | ($all | length) as $len | (if $tt == "" then $len else ($tt | tonumber) end) as $t
  | ($all[$s:$s + $n]) as $page
  | {data: {repository: {pullRequests: {
      totalCount: $t,
      pageInfo: {hasNextPage: ($s + $n < $len), endCursor: ("c" + (($s + ($page | length)) | tostring))},
      nodes: [$page[] | (. + {
        labels: {nodes: (.labels // [])},
        closingIssuesReferences: {nodes: (.closingIssuesReferences // [])},
        commits: {nodes: [{commit: {statusCheckRollup: (if (.statusCheckRollup // []) == [] then null else {contexts: {nodes: [.statusCheckRollup[]
          | if has("context") and (has("name") | not)
            then (. + {__typename: "StatusContext", createdAt: .startedAt} | del(.startedAt))
            else (. + {__typename: "CheckRun", checkSuite: {workflowRun: {workflow: {name: (.workflowName // "")}}}} | del(.workflowName)) end]}} end)}}]}
      }) | del(.statusCheckRollup)]}}}}' < <(if [ -s "$f" ]; then cat "$f"; else echo '[]'; fi)
