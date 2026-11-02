#!/usr/bin/env bash
# build-measures.sh — the figures the build is judged by, one JSON line per day.
#
#   build-measures.sh [--days N] [--baseline] [--span]
#
#   --days N     today and the N-1 days before it, in UTC (default 1)
#   --baseline   also keep the rows in measures-baseline.jsonl, beside the daily file,
#                so a later layer's effect is read against them
#   --span       print only one row over the whole window, and write nothing
#
# Writes $STATE_DIR/swarm/measures.jsonl (MEASURES_FILE), one row per day, a rerun
# replacing that day's row; the live view shows the newest. Prints the rows, then
# one line per figure naming what it counts.
#
# The set is the Claude Code team's (claude.dev/blog/solving-code-review-at-anthropic):
# merged per day, reverted share as the guardrail, reviews to pass (mean, share needing
# 5+), PR wait time, approvals per PR; ours adds finding tickets filed and the lead time
# of a split feature. EVERY FIGURE CARRIES ITS PROXY: almost nothing here is measured
# directly, and the row says what was counted in its place.
#
# A READ THAT FAILS OR HANGS WRITES NOTHING. An unread figure is unknown, never zero:
# the run exits 1 with one "unknown — …" line and the file stays as it was. Every gh
# call goes through gh_read/gh_call (the shared backoff) under GH_CALL_TIMEOUT
# (MEASURES_GH_TIMEOUT, 60 s).
#
# Seams: MEASURES_NOW (epoch), MEASURES_FILE, MEASURES_BASELINE_FILE, DRIVER_DIR,
# MEASURES_FINDING_LABEL (else release.followUpLabel, else fix-after-merge),
# MEASURES_FEATURE_LOOKBACK_DAYS (14: how far back a finished feature's parts are read).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${REPO_SLUG:-}" ] || [ -z "${STATE_DIR:-}" ]; then . "$SELF_DIR/toolkit-env.sh" || exit 1; fi
declare -F gh_read >/dev/null 2>&1 || . "$SELF_DIR/gh-batch.sh" || exit 1

DAYS_N=1 BASELINE=0 SPAN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS_N="${2:-}"; shift 2 ;;
    --baseline) BASELINE=1; shift ;;
    --span) SPAN=1; shift ;;
    *) echo "build-measures: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
case "$DAYS_N" in ''|0|*[!0-9]*) echo "build-measures: --days takes a whole number above 0" >&2; exit 2 ;; esac

ISSUE_SLUG="${ISSUE_SLUG:-$REPO_SLUG}"
TRUNK="${INTEGRATION_BRANCH:-develop}"
DRIVER_DIR="${DRIVER_DIR:-$STATE_DIR/driver}"
OUT_FILE="${MEASURES_FILE:-$STATE_DIR/swarm/measures.jsonl}"
BASE_FILE="${MEASURES_BASELINE_FILE:-$(dirname "$OUT_FILE")/measures-baseline.jsonl}"
LABEL="${MEASURES_FINDING_LABEL:-}"
if [ -z "$LABEL" ] && declare -F toolkit_cfg >/dev/null 2>&1; then LABEL=$(toolkit_cfg release.followUpLabel 2>/dev/null); fi
LABEL="${LABEL:-fix-after-merge}"
LOOKBACK="${MEASURES_FEATURE_LOOKBACK_DAYS:-14}"
NOW="${MEASURES_NOW:-$(date +%s)}"
export GH_CALL_TIMEOUT="${MEASURES_GH_TIMEOUT:-60}"

DAYS=$(jq -nc --argjson now "$NOW" --argjson n "$DAYS_N" '[range($n - 1; -1; -1) | ($now - . * 86400) | strftime("%Y-%m-%d")]')
START=$(jq -r '.[0]' <<<"$DAYS")
# The parts of a feature that finished in the window were filed up to LOOKBACK days before it.
PART_DAYS=$(jq -nc --argjson now "$NOW" --argjson n "$((DAYS_N + LOOKBACK))" '[range($n - 1; -1; -1) | ($now - . * 86400) | strftime("%Y-%m-%d")]')

# _m_search <what> <search> <node selection> — every node a GitHub search answers, as one
# array, 100 a request; any failed page fails the whole read (no partial list).
_m_search() {
  local what="$1" q="$2" sel="$3" after="" out="[]" page pages=0
  local gql='query($q:String!,$after:String){search(query:$q,type:ISSUE,first:100,after:$after){pageInfo{hasNextPage endCursor} nodes{'"$sel"'}}}'
  while :; do
    pages=$((pages + 1))
    [ "$pages" -le 10 ] || { echo "unknown — $what could not be read (over 1000 rows in one search; narrow it)" >&2; return 1; }
    page=$(gh_read "$what" api graphql -f query="$gql" -f q="$q" ${after:+-f after="$after"}) || return 1
    out=$(_gh_jq_acc "$out" '$acc + [.data.search.nodes[]?]' <<<"$page") || { echo "unknown — $what could not be read (its answer was not a search)" >&2; return 1; }
    jq -e '.data.search.pageInfo.hasNextPage == true' >/dev/null 2>&1 <<<"$page" || break
    after=$(jq -r '.data.search.pageInfo.endCursor // ""' <<<"$page")
    [ -n "$after" ] || { echo "unknown — $what could not be read (a page with no cursor)" >&2; return 1; }
  done
  printf '%s\n' "$out"
}

# _m_each_day <what> <search, @DAY@ standing for the day> <selection> <days json> — one search per day, joined.
_m_each_day() {
  local what="$1" fmt="$2" sel="$3" days="$4" d all="[]" part
  for d in $(jq -r '.[]' <<<"$days"); do
    part=$(_m_search "$what ($d)" "${fmt//@DAY@/$d}" "$sel") || return 1
    all=$(_gh_jq_acc "$all" '$acc + .' <<<"$part") || return 1
  done
  printf '%s\n' "$all"
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/measures.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PR_SEL='... on PullRequest{number createdAt mergedAt mergeCommit{oid} reviews(states:APPROVED){totalCount}}'
_m_each_day "the pull requests merged into $TRUNK" "repo:$REPO_SLUG is:pr is:merged base:$TRUNK merged:@DAY@T00:00:00Z..@DAY@T23:59:59Z" \
  "$PR_SEL" "$DAYS" > "$TMP/merged.json" || exit 1

_m_search "the merged revert pull requests" "repo:$REPO_SLUG is:pr is:merged Revert in:title merged:>=$START" \
  '... on PullRequest{number title body mergedAt}' > "$TMP/revert-prs.json" || exit 1

# Commit search is fuzzy (any "revert" in a message); the filter below keeps a commit whose first line starts Revert.
page=1; echo '[]' > "$TMP/commits.json"
while :; do
  body=$(gh_read "the revert commits" api -X GET search/commits -f q="repo:$REPO_SLUG revert committer-date:>=$START" \
           -f per_page=100 -f page="$page") || exit 1
  _gh_jq_acc "$(cat "$TMP/commits.json")" '$acc + [.items[]? | {sha, message: .commit.message}]' <<<"$body" > "$TMP/c.json" || exit 1
  mv "$TMP/c.json" "$TMP/commits.json"
  [ "$(jq '.items | length' <<<"$body")" -ge 100 ] && [ "$page" -lt 10 ] || break
  page=$((page + 1))
done

FQ=$(jq -rn --argjson days "$DAYS" --arg r "$ISSUE_SLUG" --arg l "$LABEL" \
  '"query{" + ([$days | to_entries[] | "d\(.key): search(query: \(("repo:" + $r + " is:issue label:\"" + $l + "\" created:" + .value) | tojson), type: ISSUE, first: 0){issueCount}"] | join(" ")) + "}"')
gh_read "the finding tickets filed" api graphql -f query="$FQ" > "$TMP/findings.json" || exit 1

_m_each_day "the parts of split features" "repo:$ISSUE_SLUG is:issue \"split from #\" in:body created:@DAY@" \
  '... on Issue{number createdAt closedAt state stateReason body}' "$PART_DAYS" > "$TMP/parts.json" || exit 1

# The driver's runs: one TSV line per "✓ #N shipped" — when, ticket, the review figure
# before it in that run (empty when none), and the blocking findings its rounds sent back.
for f in "$DRIVER_DIR"/*/log; do
  [ -f "$f" ] || continue
  awk '
    /review: [A-Z]+ after [0-9]+ (round|pass)/ { if (match($0, /after [0-9]+/)) r = substr($0, RSTART + 6, RLENGTH - 6) }
    /review round [0-9]+ of [0-9]+: [0-9]+ blocking/ { if (match($0, /: [0-9]+ blocking/)) n += substr($0, RSTART + 2, RLENGTH - 11) }
    /^[0-9TZ:-]+ +✓ #[0-9]+ shipped/ { match($0, /#[0-9]+/); print $1 "\t" substr($0, RSTART + 1, RLENGTH - 1) "\t" r "\t" (n + 0); r = ""; n = 0 }
  ' "$f"
done | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {at: .[0], ticket: .[1], rounds: (if .[2] == "" then null else (.[2] | tonumber) end), findings: (.[3] | tonumber)})' > "$TMP/runs.json"

ROWS=$(jq -nc --slurpfile merged "$TMP/merged.json" --slurpfile rprs "$TMP/revert-prs.json" --slurpfile commits "$TMP/commits.json" \
  --slurpfile fq "$TMP/findings.json" --slurpfile parts "$TMP/parts.json" --slurpfile runs "$TMP/runs.json" \
  --argjson days "$DAYS" --argjson now "$NOW" --argjson span "$SPAN" \
  --arg repo "$REPO_SLUG" --arg trunk "$TRUNK" --arg label "$LABEL" --arg ddir "$DRIVER_DIR" '
  def q(p): sort as $s | ($s | length) as $n
    | if $n == 0 then null else (($n - 1) * p) as $i | ($i | floor) as $lo | ($i | ceil) as $hi
        | $s[$lo] + ($s[$hi] - $s[$lo]) * ($i - $lo) end;
  def rnd(k): if . == null then null else (. * k | round) / k end;
  def mean: if length == 0 then null else add / length end;
  def hours(a; b): ((b | fromdateiso8601) - (a | fromdateiso8601)) / 3600;
  def nums: [scan("#([0-9]+)") | .[0] | tonumber];
  def shas: [scan("reverts commit ([0-9a-f]{6,40})") | .[0]];

  ($merged[0] | unique_by(.number)) as $m
  | ($now | strftime("%Y-%m-%d")) as $today
  # Every revert names its target by #number or by merge-commit sha; its own number is never one.
  | ([$rprs[0][] | select(.title | test("^Revert\\b"; "i"))
        | {own: [.number], text: (.title + "\n" + (.body // ""))}]
     # A commit counts by its headline: a squash body carries the branch'"'"'s own in-branch reverts.
     + [$commits[0][] | (.message | split("\n")[0]) as $h | select($h | test("^Revert\\b"; "i"))
        | {own: [$h | scan("\\(#([0-9]+)\\)$") | .[0] | tonumber], text: .message}]) as $reverts
  | ([$reverts[] | (.text | nums) - .own] | add // []) as $byNum
  | ([$reverts[] | .text | shas] | add // []) as $bySha
  | ([$m[] | select((.number as $n | $byNum | index($n)) or ((.mergeCommit.oid // "") as $o | $o != "" and ($bySha | any(. as $s | $o | startswith($s)))))
       | .number]) as $reverted
  # A feature is done when every one of its m parts is closed; it is dated by the last close.
  | ([$parts[0] | unique_by(.number)[] | (.body // "" | capture("Part (?<p>[0-9]+) of (?<m>[0-9]+), split from #(?<x>[0-9]+)"; "i")?) as $c
       | select($c != null) | . + {part: ($c.p | tonumber), of: ($c.m | tonumber), parent: $c.x}]
     | group_by(.parent)
     | map(select(([.[] | select(.state == "CLOSED") | .part] | unique | length) == .[0].of)
           | {parent: .[0].parent, parts: .[0].of, filed: (map(.createdAt) | min), done: (map(.closedAt) | max)}
           | . + {hours: hours(.filed; .done), day: .done[0:10]})) as $features
  | def row($from; $to; $name):
      def within: . >= $from and . <= $to;
      ([$m[] | select(.mergedAt[0:10] | within)]) as $dm
      | ([$runs[0][] | select(.at[0:10] | within) | select(.rounds != null)]) as $dr
      | ([$features[] | select(.day | within)]) as $df
      | {day: $name, at: ($now | todate), repo: $repo, complete: ($to < $today),
         merged: {n: ($dm | length),
           proxy: "pull requests merged into \($trunk) that day (UTC), from GitHub search is:pr is:merged base:\($trunk)"},
         reverted: {n: ([$dm[] | select(.number as $n | $reverted | index($n))] | length),
           share: (if ($dm | length) == 0 then null else ([$dm[] | select(.number as $n | $reverted | index($n))] | length) / ($dm | length) | rnd(1000) end),
           prs: ([$dm[] | select(.number as $n | $reverted | index($n)) | .number] | sort),
           proxy: "of that day'"'"'s merged PRs, those named (by #number or merge-commit sha) by a merged PR titled Revert, or by a default-branch commit whose first line starts Revert; incidents are not in it"},
         reviewsToPass: {runs: ($dr | length), mean: ([$dr[].rounds] | mean | rnd(100)),
           fivePlusShare: (if ($dr | length) == 0 then null else ([$dr[] | select(.rounds >= 5)] | length) / ($dr | length) | rnd(1000) end),
           oneRoundShare: (if ($dr | length) == 0 then null else ([$dr[] | select(.rounds <= 1)] | length) / ($dr | length) | rnd(1000) end),
           proxy: "driver runs that shipped that day (a ✓ shipped line in \($ddir)/*/log), each at the review: SHIP after N round(s)/pass(es) line before it; a run with no such line is left out"},
         findingsPerRun: {mean: ([$dr[].findings] | mean | rnd(100)),
           proxy: "blocking findings in the ✋ review round lines of those same runs: what review sent back to the builder, not the nits or the minors it set aside"},
         waitHours: {median: ([$dm[] | hours(.createdAt; .mergedAt)] | q(0.5) | rnd(10)), p75: ([$dm[] | hours(.createdAt; .mergedAt)] | q(0.75) | rnd(10)),
           proxy: "hours from a PR opening to its merge, for the PRs merged that day; it is not time spent waiting on a person"},
         approvalsPerPr: {mean: ([$dm[].reviews.totalCount] | mean | rnd(100)),
           proxy: "APPROVED reviews on the PRs merged that day, from any account, bots included"},
         findingTickets: {n: ([$days | to_entries[] | select(.value | within) | $fq[0].data["d\(.key)"].issueCount] | add),
           proxy: "issues created that day wearing \($label), the label follow-up.sh files each review finding under"},
         featureLeadHours: {features: ($df | length), median: ([$df[].hours] | q(0.5) | rnd(10)), p75: ([$df[].hours] | q(0.75) | rnd(10)),
           partsMedian: ([$df[].parts] | q(0.5)),
           proxy: "split features (issues whose body says Part n of m, split from #X) whose last part closed that day: first part filed to last part closed, the close standing in for the merge"},
         incidents: {n: null, proxy: "not measured: the kit keeps no incident record yet, so this is unknown, not zero"}};
  if $span == 1 then row($days[0]; $days[-1]; "\($days[0])..\($days[-1])") else ($days[] | row(.; .; .)) end') || { echo "build-measures: the figures could not be worked out" >&2; exit 1; }
[ -n "$ROWS" ] || { echo "build-measures: no rows came out" >&2; exit 1; }

upsert() { # <file> — each day's row replaces the one it had; other days are kept, oldest first
  local f="$1"
  mkdir -p "$(dirname "$f")" || return 1
  { [ -f "$f" ] && jq -c 'select(type == "object" and .day != null)' "$f" 2>/dev/null; printf '%s\n' "$ROWS"; } \
    | jq -sc --argjson days "$DAYS" '[.[] | select(.day as $d | $days | index($d) | not)] + [.[] | select(.day as $d | $days | index($d))]
                                     | group_by(.day) | map(.[-1]) | sort_by(.day) | .[]' > "$f.tmp.$$" \
    && mv "$f.tmp.$$" "$f"
}
[ "$SPAN" = 1 ] || upsert "$OUT_FILE" || { echo "build-measures: could not write $OUT_FILE" >&2; exit 1; }
[ "$BASELINE" = 0 ] || [ "$SPAN" = 1 ] || upsert "$BASE_FILE" || { echo "build-measures: could not write $BASE_FILE" >&2; exit 1; }

printf '%s\n' "$ROWS"
printf '%s\n' "$ROWS" | jq -r '
  def pct: if . == null then "—" else "\(. * 1000 | round / 10)%" end;
  def v: if . == null then "—" else tostring end;
  "\(.day)\(if .complete then "" else " (so far)" end): \(.merged.n) merged · \(.reverted.share | pct) reverted · reviews to pass \(.reviewsToPass.mean | v) (5+: \(.reviewsToPass.fivePlusShare | pct), first time: \(.reviewsToPass.oneRoundShare | pct), \(.reviewsToPass.runs) runs) · findings/run \(.findingsPerRun.mean | v) · wait \(.waitHours.median | v)h median, \(.waitHours.p75 | v)h p75 · approvals/PR \(.approvalsPerPr.mean | v) · \(.findingTickets.n | v) finding tickets · features \(.featureLeadHours.features) done, lead \(.featureLeadHours.median | v)h median, \(.featureLeadHours.p75 | v)h p75, \(.featureLeadHours.partsMedian | v) parts"'
printf '%s\n' "$ROWS" | head -1 | jq -r 'to_entries[] | select(.value | type == "object" and has("proxy")) | "  \(.key) counts: \(.value.proxy)"'
