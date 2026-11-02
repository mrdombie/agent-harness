#!/usr/bin/env bash
# live-view-measures.test.sh — the live page shows the newest row of the build's daily
# measures (scripts/build-measures.sh) beside the frozen baseline, and says under them
# what each figure counts. A torn last line falls back to the row before it; no file
# reads as not measured yet, never as zeros.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v node >/dev/null 2>&1 || suite_skip "node is not on PATH"
LV="${LIVE_VIEW_DIR:-$HERE/../live-view}"
T=$(mktemp -d); on_exit_keep_status 'rm -rf "$T"'
FAILED=0
ok()  { echo "OK       $1"; }
bad() { echo "MISMATCH $1"; FAILED=1; }

row() { # <day> <merged> <complete>
  jq -nc --arg d "$1" --argjson n "$2" --argjson c "$3" '{day:$d, complete:$c,
    merged:{n:$n, proxy:"pull requests merged into develop that day"},
    reverted:{n:1, share:0.024, prs:[5], proxy:"of that day merged PRs, those a revert names"},
    reviewsToPass:{runs:10, mean:1.4, fivePlusShare:0.1, oneRoundShare:0.7, proxy:"driver runs that shipped that day"},
    findingsPerRun:{mean:0.8, proxy:"blocking findings in the review round lines"},
    waitHours:{median:3.1, p75:7.2, proxy:"hours from a PR opening to its merge"},
    approvalsPerPr:{mean:0, proxy:"APPROVED reviews on the PRs merged that day"},
    findingTickets:{n:12, proxy:"issues created that day wearing fix-after-merge"},
    featureLeadHours:{features:4, median:14.6, p75:35.7, partsMedian:5, proxy:"split features whose last part closed that day"},
    incidents:{n:null, proxy:"not measured: the kit keeps no incident record yet"}}'
}
{ row 2026-11-01 70 true; row 2026-11-02 84 false; echo '{"day":"2026-11-03","merged":{'; } > "$T/m.jsonl"
row 2026-10-31 60 true > "$T/b.jsonl"

snap() { # <measures file> <baseline file>
  SWARM_MEASURES_FILE="$1" SWARM_MEASURES_BASELINE="$2" SWARM_PROGRESS_SYNC=1 SWARM_SERVER_MJS="$LV/server.mjs" \
  node --input-type=module -e "
    import { pathToFileURL } from 'node:url'
    const { measuresOf } = await import(pathToFileURL(process.env.SWARM_SERVER_MJS).href)
    console.log(JSON.stringify({ measures: measuresOf() }))"
}
page() { # <snapshot json> — what the page wrote into #measures
  printf '%s' "$1" > "$T/snap.json"
  PAGE="$LV/index.html" SNAP="$T/snap.json" node -e '
    const fs = require("fs"), vm = require("vm")
    const html = fs.readFileSync(process.env.PAGE, "utf8")
    const js = html.slice(html.indexOf("<script>") + 8, html.lastIndexOf("</script>"))
    const ctx = { document: { getElementById: () => ({}) }, fetch: () => new Promise(() => {}), setInterval: () => 0, console }
    vm.createContext(ctx); vm.runInContext(js + "\n;globalThis.__m = measuresBlock", ctx)
    console.log(ctx.__m(JSON.parse(fs.readFileSync(process.env.SNAP, "utf8")).measures).replace(/\s+/g, " "))'
}

S=$(snap "$T/m.jsonl" "$T/b.jsonl")
[ "$(jq -r .measures.latest.day <<<"$S")" = 2026-11-02 ] && ok "a torn last line falls back to the newest whole row" || bad "latest: $(jq -c .measures.latest.day <<<"$S")"
[ "$(jq -r .measures.baseline.day <<<"$S")" = 2026-10-31 ] && ok "the baseline row rides along" || bad "baseline: $S"
H=$(page "$S")
for want in '84' '2.4%' '1.4' '3.1h' '14.6h' '35.7h' 'baseline 60' 'so far' 'not measured' \
            'What each figure counts' 'counts pull requests merged into develop that day' 'counts hours from a PR opening to its merge'; do
  case "$H" in *"$want"*) ok "page shows '$want'" ;; *) bad "page lacks '$want': $H" ;; esac
done
grep -q "id=\"measures\"" "$LV/index.html" && grep -q "measuresBlock(s.measures)" "$LV/index.html" \
  && ok "render() writes the block into the page" || bad "the block is never written into the page"

S=$(snap "$T/none.jsonl" "$T/none-b.jsonl")
[ "$(jq -c .measures <<<"$S")" = null ] && ok "no file reads as null" || bad "no file: $S"
H=$(page "$S")
case "$H" in *"Not measured yet"*) ok "and the page says not measured yet, never a zero" ;; *) bad "empty page: $H" ;; esac

grep -q "measures: measuresOf()" "$LV/server.mjs" && ok "the snapshot carries the measures" || bad "snapshot() does not carry measuresOf()"

suite_end "$FAILED"
