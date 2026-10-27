#!/usr/bin/env bash
# live-view-backoff.test.sh — the live view keeps to the backoff every other caller
# shares (scripts/gh-batch.sh): no search call while the search bucket's backoff
# holds, no call at all while the shared one holds, and the last good read served.
#
# Measured 2026-10-27: 342 calls in 2 h from the live view, 60 of them search/issues,
# into the same 30-a-minute bucket the coordinator was being refused on.
# Run: bash "$0"     LIVE_VIEW_DIR=<dir> runs it against another copy of the page.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture
on_exit_keep_status 'rm -rf "$FIX"'
command -v node >/dev/null 2>&1 || { suite_skip "SKIP live-view-backoff: node is not on PATH"; }
LV="${LIVE_VIEW_DIR:-$HERE/../live-view}"

NOW_S=$(date +%s)
SINCE=$(node -e 'const d = new Date(); d.setHours(0, 0, 0, 0); console.log(d.toISOString().replace(/\.\d{3}Z$/, "Z"))')
BACKOFF="$STATE/swarm/gh-backoff"
PRS_STATES="$STATE/swarm/pr-states.json"

snap() { # [server dir]
  local mjs="${1:-$LV}/server.mjs"
  SWARM_RUNS_DIR="$STATE/runs" SWARM_REPO=acme/widgets SWARM_TITLES="$FIX/titles.json" SWARM_GH="$BIN/gh" \
  SWARM_PROGRESS_SYNC=1 SWARM_HOST=laptop SWARM_HOLD_SCRIPT="$FIX/hold.sh" SWARM_GH_BACKOFF="$BACKOFF" \
  SWARM_PR_STATES_FILE="$PRS_STATES" SWARM_SERVER_MJS="$mjs" \
  node --input-type=module -e "
    import { pathToFileURL } from 'node:url'
    const { snapshot } = await import(pathToFileURL(process.env.SWARM_SERVER_MJS).href)
    console.log(JSON.stringify(snapshot()))"
}
# A clean slate: no backoff, no kept reads, no calls yet.
fresh() { rm -f "$BACKOFF" "$BACKOFF.search" "$STATE"/swarm/*.json; : > "$GH_LOG"; }
# The last good read: today's merges, read an hour ago, old enough to be read again.
kept_read() {
  printf '{"at":"%s","since":"%s","trunk":"develop","closed":[],"merged":{"total":7,"items":[{"number":3100,"title":"kept","mergedAt":"%s"}]},"heads":null}\n' \
    "$(node -e 'console.log(new Date(Date.now() - 3600e3).toISOString())')" "$SINCE" "$SINCE" > "$PRS_STATES"
  touch -t "$(date -r $(( NOW_S - 3600 )) +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$(( NOW_S - 3600 ))" +%Y%m%d%H%M.%S)" "$PRS_STATES"
}
printf '#!/usr/bin/env bash\necho "{}"\n' > "$FIX/hold.sh"; chmod +x "$FIX/hold.sh"
printf '{"total_count":2,"items":[]}\n' > "$FIX/gh/api-search_issues.json"
printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_pulls_state_closed_sort_updated_direction_desc_per_page_100.json"

echo "--- with no backoff the poll reads today's merges (the case the others hold back) ---"
fresh; snap >/dev/null
want "one search call"                         "1" "$(grep -c 'search/' "$GH_LOG")"

echo "--- an expired backoff holds nothing ---"
fresh; printf '%s\tsearch\told refusal\n' $(( NOW_S - 5 )) > "$BACKOFF.search"
printf '%s\t0\t0\tsecondary\told refusal\n' $(( NOW_S - 5 )) > "$BACKOFF"
snap >/dev/null
want "the search is made again"                "1" "$(grep -c 'search/' "$GH_LOG")"

echo "--- the search backoff holds: no search/ call, the other reads go on ---"
fresh; kept_read
printf '%s\tsearch\tAPI rate limit exceeded\n' $(( NOW_S + 600 )) > "$BACKOFF.search"
s=$(snap)
want "no search/ call"                         "0" "$(grep -c 'search/' "$GH_LOG")"
want "the ruleset is still read"               "1" "$(grep -c 'rules/branches' "$GH_LOG")"
want "the last good read is served"            "7" "$(printf '%s' "$s" | jq '.mergedToday.total')"
want_in "with the time it was read"            '^20[0-9-]+T' "$(printf '%s' "$s" | jq -r '.mergedToday.at')"

echo "--- the shared backoff holds: no call at all, the last read served ---"
fresh; kept_read
printf '%s\t1\t%s\tprimary\tAPI rate limit exceeded\n' $(( NOW_S + 600 )) "$NOW_S" > "$BACKOFF"
s=$(snap)
want "no gh call"                              "0" "$(wc -l < "$GH_LOG" | tr -d ' ')"
want "today's merges as last read"             "7" "$(printf '%s' "$s" | jq '.mergedToday.total')"

echo "--- the progress gather holds too ---"
fresh
printf '%s\t1\t%s\tprimary\tAPI rate limit exceeded\n' $(( NOW_S + 600 )) "$NOW_S" > "$BACKOFF"
g=$(cd "$LV" && SWARM_GH="$BIN/gh" SWARM_GIT=false SWARM_GH_BACKOFF="$BACKOFF" node --input-type=module -e '
  import { ghHeld } from "./progress.mjs"
  console.log(ghHeld(["api", "repos/acme/widgets/commits"]) + " " + ghHeld(["issue", "list"]))' 2>&1)
want "a gh call under the shared backoff is held" "true true" "$g"
rm -f "$BACKOFF"; printf '%s\tsearch\tx\n' $(( NOW_S + 600 )) > "$BACKOFF.search"
g=$(cd "$LV" && SWARM_GH_BACKOFF="$BACKOFF" node --input-type=module -e '
  import { ghHeld } from "./progress.mjs"
  console.log([["api", "search/issues", "-X", "GET"], ["search", "prs"], ["pr", "list", "--search", "x"], ["api", "graphql"], ["pr", "list"]].map(ghHeld).join(" "))' 2>&1)
want "the search backoff holds search calls only" "true true true false false" "$g"

suite_end "$FAILED"
