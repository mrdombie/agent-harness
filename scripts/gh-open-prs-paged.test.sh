#!/usr/bin/env bash
# gh-open-prs-paged.test.sh — a GitHub read sized by the repo's growth is paged,
# never fetched in one request. On 2026-10-19 `gh pr list --limit 200` with the
# checks of 81 open PRs timed out (HTTP 504) every tick, so the coordinator spawned
# nothing and the driver parked every ticket it started.
# The forge here answers like GitHub did: a request for more than FAKE_GH_PRS_MAX
# PRs at once is a 504.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
FIX=$(mktemp -d); trap 'rm -rf "$FIX"' EXIT
FAILED=0
want()        { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: wanted '$2', got '$3'"; FAILED=1; fi; }

mkdir -p "$FIX/bin" "$FIX/state"
cat > "$FIX/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/gh.log"
# `gh pr list` asks GitHub for min(limit, 100) a request.
if [ "$1 $2" = "pr list" ]; then
  lim=30; prev=""; for a in "$@"; do [ "$prev" = --limit ] && lim="$a"; prev="$a"; done
  [ "$lim" -gt 100 ] && lim=100
  if [ "$lim" -gt "${FAKE_GH_PRS_MAX:-1000}" ]; then echo "HTTP 504: Gateway Timeout (https://api.github.com/graphql)" >&2; exit 1; fi
  jq ".[0:$lim]" "$FIX/prs.json"; exit 0
fi
case "$*" in "api graphql "*OpenPullRequests*)
  case "$*" in *"after=${FAKE_GH_FAIL_AFTER:-none}"*) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;; esac
  exec bash "$GH_OPEN_PRS_PAGE" "$FIX/prs.json" "$@" ;;
esac
exit 1
SH
chmod +x "$FIX/bin/gh"
export FIX SWARM_GH="$FIX/bin/gh" GH_REPO=acme/widgets GH_BACKOFF_FILE="$FIX/state/gh-backoff"
export GH_OPEN_PRS_PAGE="$HERE/fixtures/gh-open-prs-page.sh" GH_PRS_RETRY_SEC=0

# 81 open PRs in the shape gh prints, every field the callers read.
jq -n '[range(0; 81) as $i | {
  number: (1000 - $i), title: "PR \($i)", headRefName: "tkt-\($i)/x", headRefOid: "sha\($i)",
  baseRefName: "develop", isDraft: ($i % 3 == 0), mergeable: "MERGEABLE", mergeStateStatus: "CLEAN",
  updatedAt: "2026-10-19T10:00:00Z",
  labels: [{id: "L\($i)", name: "needs:human-approval", description: "held", color: "B60205"}],
  closingIssuesReferences: [{id: "I\($i)", number: (500 + $i), repository: {id: "R", name: "widgets", owner: {id: "O", login: "acme"}}, url: "https://github.com/acme/widgets/issues/\(500 + $i)"}],
  autoMergeRequest: (if $i % 2 == 0 then null else {authorEmail: null, commitBody: null, commitHeadline: null, mergeMethod: "SQUASH", enabledAt: "2026-10-19T10:54:51Z", enabledBy: {id: "U", is_bot: false, login: "acme", name: "Acme"}} end),
  statusCheckRollup: [
    {__typename: "CheckRun", completedAt: "2026-10-19T11:01:43Z", conclusion: "FAILURE", detailsUrl: "https://x/\($i)", name: "build", startedAt: "2026-10-19T11:01:00Z", status: "COMPLETED", workflowName: "CI"},
    {__typename: "CheckRun", completedAt: "0001-01-01T00:00:00Z", conclusion: "", detailsUrl: "https://y/\($i)", name: "lint", startedAt: "2026-10-19T11:01:00Z", status: "IN_PROGRESS", workflowName: "CI"},
    {__typename: "StatusContext", context: "Design critic", startedAt: "2026-10-19T11:03:43Z", state: "SUCCESS", targetUrl: "https://z/\($i)"}]
}]' > "$FIX/prs.json"
F=number,headRefName,headRefOid,baseRefName,isDraft,labels,mergeStateStatus,statusCheckRollup,mergeable,closingIssuesReferences,title,updatedAt,autoMergeRequest
open_prs() { bash -c '. "$1/gh-batch.sh" || exit 9; gh_open_prs 0' _ "$HERE"; }

echo "--- 81 open PRs, and GitHub times out past 25 a request ---"
export FAKE_GH_PRS_MAX=25
: > "$FIX/gh.log"
out=$(open_prs); rc=$?
want "the read succeeds"                         "0" "$rc"
want "every open PR comes back"                  "81" "$(jq 'length' <<<"$out" 2>/dev/null)"
want "newest first, none twice"                 "$(jq -c '[.[].number]' "$FIX/prs.json")" "$(jq -c '[.[].number]' <<<"$out" 2>/dev/null)"
want "no request asked for more than 25"         "" "$(grep -oE 'first=[0-9]+' "$FIX/gh.log" | awk -F= '$2 > 25')"
want "in the shape gh pr list prints, field for field" "true" \
  "$(bash -c '. "$1/gh-batch.sh"; gh_prs_paged "$2"' _ "$HERE" "$F" | jq --slurpfile want "$FIX/prs.json" '. == $want[0]' 2>/dev/null)"
want "the shared copy holds it too"              "81" "$(jq 'length' "$FIX/state/prs.json" 2>/dev/null)"

echo "--- a page that times out is asked again smaller ---"
export FAKE_GH_PRS_MAX=20
: > "$FIX/gh.log"
out=$(open_prs); rc=$?
want "the read still succeeds"                  "0" "$rc"
want "with every open PR"                        "81" "$(jq 'length' <<<"$out" 2>/dev/null)"
want "after one 504 at 25, the rest at 12"       "25 12" "$(grep -oE 'first=[0-9]+' "$FIX/gh.log" | cut -d= -f2 | sort -rnu | tr '\n' ' ' | sed 's/ $//')"

echo "--- any page failing fails the whole read: never a partial list ---"
export FAKE_GH_PRS_MAX=25 FAKE_GH_FAIL_AFTER=50
cp "$FIX/state/prs.json" "$FIX/before.json"; touch -t 202601010000 "$FIX/state/prs.json"
out=$(open_prs); rc=$?
want "it fails"                                  "1" "$rc"
want "printing nothing"                          "" "$out"
want "and the shared copy is not overwritten"    "$(cat "$FIX/before.json")" "$(cat "$FIX/state/prs.json")"
unset FAKE_GH_FAIL_AFTER

echo "--- a field with no paged reading is refused, not read in one request ---"
rc=0; bash -c '. "$1/gh-batch.sh"; gh_prs_paged number,files' _ "$HERE" >/dev/null 2>&1 || rc=$?
want "it fails"                                  "1" "$rc"

echo "--- on a base branch, only that branch's PRs ---"
jq '(.[0].baseRefName = "main")' "$FIX/prs.json" > "$FIX/p.json" && mv "$FIX/p.json" "$FIX/prs.json"
want "develop's 80"                              "80" "$(bash -c '. "$1/gh-batch.sh"; gh_prs_paged number,baseRefName develop' _ "$HERE" | jq 'length')"

echo "--- no script reads every open PR's checks or merge state in one gh pr list ---"
# The sibling: merge-lane and claimable-issues made the same read. Continuation lines
# are joined so a --json on the next line counts.
heavy=$(cd "$HERE/.." && git ls-files '*.sh' 'driver/build-ticket' 2>/dev/null | grep -vE '(^|/)tests?/|\.test\.sh$|^reference/' \
  | while IFS= read -r f; do
      awk -v f="$f" '{ line = line $0 } /\\$/ { sub(/\\$/, "", line); next }
        { if (line ~ /pr list/ && line !~ /--head/ && line ~ /statusCheckRollup|closingIssuesReferences|mergeable|mergeStateStatus/) print f ": " substr(line, 1, 120); line = "" }' "$f"
    done)
want "none"                                      "" "$heavy"

exit $FAILED
