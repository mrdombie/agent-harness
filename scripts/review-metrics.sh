#!/usr/bin/env bash
# review-metrics.sh — the review's before and after: findings per PR, rounds to pass, and
# finding tickets filed per day, split at the day a review change landed.
#
#   review-metrics.sh --split <YYYY-MM-DD> [--from <day>] [--to <day>] [--driver-dir <dir>]
#                     [--tickets-json <file> | --repo <owner/name>] [--label <name>] [--json]
#   exit 0 · 2 usage, or a source that cannot be read (never a row of zeros)
#
# WHAT EACH FIGURE STANDS IN FOR. Every figure is read off the driver's per-ticket record
# (<stateDir>/driver/<ticket>/), bucketed by the run's started_at:
#   a PR reviewed       a record with a pr (or repair_pr) and at least one MODEL review
#                       (counters.review minus counters.review_skipped)
#   findings per PR     what that review handed on: the never-twice ledger
#                       (steps/review.posted.jsonl) where it exists; before it, the last
#                       review.json's findings that are not nits plus the deferred list
#                       (steps/review.deferred.jsonl). The older records keep only the last
#                       round's answer, so the before figure is a floor.
#   rounds to pass      the model reviews of a record that reached ship
#   tickets per day     finding tickets (release.followUpLabel, default fix-after-merge)
#                       created in the window, over its calendar days
# Before is [from, split), after is [split, to]; from defaults to 14 days before the split
# and to to today (UTC).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "review-metrics: $*" >&2; exit 2; }

SPLIT="" FROM="" TO="" DD="" TJ="" REPO="" LABEL="fix-after-merge" JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --split) SPLIT="${2:-}"; shift 2 ;;
    --from) FROM="${2:-}"; shift 2 ;;
    --to) TO="${2:-}"; shift 2 ;;
    --driver-dir) DD="${2:-}"; shift 2 ;;
    --tickets-json) TJ="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --label) LABEL="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    *) die "unknown argument '$1' (see the header for usage)" ;;
  esac
done
isday() { printf '%s' "$1" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; }
isday "$SPLIT" || die "--split <YYYY-MM-DD> is required"
day_add() { # <day> <n> — the day n days later (negative: earlier), UTC. Signed always:
  # BSD date's -v1d SETS the day of the month to 1, it does not add one.
  local n="$2"; case "$n" in -*|+*) : ;; *) n="+$n" ;; esac
  if date -u -j -f %Y-%m-%d "$1" +%s >/dev/null 2>&1; then
    date -u -j -v"${n}"d -f %Y-%m-%d "$1" +%Y-%m-%d
  else date -u -d "$1 $n days" +%Y-%m-%d; fi
}
[ -n "$FROM" ] || FROM=$(day_add "$SPLIT" -14)
[ -n "$TO" ] || TO=$(date -u +%Y-%m-%d)
isday "$FROM" && isday "$TO" || die "--from and --to are YYYY-MM-DD"
span=$(jq -n --arg a "$FROM" --arg b "$TO" '((($b + "T00:00:00Z") | fromdate) - (($a + "T00:00:00Z") | fromdate)) / 86400') || die "the window $FROM to $TO could not be read"
[ "${span%.*}" -ge 0 ] 2>/dev/null || die "--from $FROM is after --to $TO"
[ "${span%.*}" -le 400 ] || die "the window $FROM to $TO is over 400 days; give a shorter one"
GH="${REVIEW_METRICS_GH:-gh}"

if [ -z "$DD" ]; then
  sd=$( . "$SELF_DIR/toolkit-env.sh" >/dev/null 2>&1 && printf '%s' "${STATE_DIR:-}")
  [ -n "$sd" ] || die "no --driver-dir, and no stateDir to find the driver's records in"
  DD="$sd/driver"
fi
[ -d "$DD" ] || die "no driver records at $DD"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/review-metrics-XXXXXX") || die "no scratch directory"
trap 'rm -rf "$WORK"' EXIT
TK="$WORK/tickets.json"; RW="$WORK/rows.json"
if [ -n "$TJ" ]; then
  jq -c '[.[]? | {createdAt}]' "$TJ" > "$TK" 2>/dev/null || die "$TJ is not a JSON list of tickets"
else
  [ -n "$REPO" ] || REPO=$( . "$SELF_DIR/toolkit-env.sh" >/dev/null 2>&1 && printf '%s' "${REPO_SLUG:-}")
  [ -n "$REPO" ] || die "no --tickets-json and no --repo to read the finding tickets from"
  # ONE DAY A CALL: GitHub's search stops at 1000 results, and a two-week window passed that
  # (measured 2026-11-02: ten days summing to exactly 1000, the first five days missing).
  printf '[]' > "$TK"; day="$FROM"
  while [ "$day" \< "$TO" ] || [ "$day" = "$TO" ]; do
    "$GH" issue list --repo "$REPO" --label "$LABEL" --state all --limit 1000 \
             --search "created:$day" --json createdAt > "$WORK/page.json" 2>/dev/null || die "the finding tickets of $REPO on $day could not be read"
    jq -e 'type == "array"' "$WORK/page.json" >/dev/null 2>&1 || die "the finding tickets of $REPO on $day could not be read"
    [ "$(jq length "$WORK/page.json")" -lt 1000 ] || die "$day alone has 1000 finding tickets, GitHub's search ceiling, so the count would be cut short"
    jq -c --slurpfile p "$WORK/page.json" '. + $p[0]' "$TK" > "$WORK/t2.json" && mv "$WORK/t2.json" "$TK"
    next=$(day_add "$day" 1)
    [ "$next" \> "$day" ] || die "the day after $day came out as $next, so the count stops here"
    day="$next"
  done
fi

# One row per record: started day, reviewed-by-model, findings, shipped.
for s in "$DD"/*/state.json; do
  [ -f "$s" ] || continue
  d=$(dirname "$s")/steps
  n=""
  if [ -s "$d/review.posted.jsonl" ]; then n=$(grep -c . "$d/review.posted.jsonl")
  elif [ -f "$d/review.json" ]; then
    a=$(jq '[.findings[]? | select((.grade // "") != "nit")] | length' "$d/review.json" 2>/dev/null)
    b=0; [ -f "$d/review.deferred.jsonl" ] && b=$(grep -c . "$d/review.deferred.jsonl")
    n=$(( ${a:-0} + ${b:-0} ))
  fi
  jq -c --argjson n "${n:-0}" '{day: ((.started_at // "") | .[0:10]),
      pr: ((.pr // .repair_pr // "") | tostring | length > 0),
      model: (((.counters.review // 0) - (.counters.review_skipped // 0))),
      shipped: ((.done // []) | index("ship") != null), findings: $n}' "$s" 2>/dev/null
done | jq -sc '.' > "$RW"

out=$(jq -n --slurpfile rw "$RW" --slurpfile tkf "$TK" --arg split "$SPLIT" --arg from "$FROM" --arg to "$TO" '
  ($rw[0] // []) as $rows | ($tkf[0] // []) as $tk
  | def r2: (. * 100 | round) / 100;
  def days($a; $b): ((($b + "T00:00:00Z") | fromdate) - (($a + "T00:00:00Z") | fromdate)) / 86400;
  def side($lo; $hi; $ndays):
    ([$rows[] | select(.day >= $lo and .day < $hi and .pr and .model >= 1)]) as $rv
    | ([$rv[] | select(.shipped)]) as $sh
    | ([$tk[] | (.createdAt // "") | .[0:10] | select(. >= $lo and . < $hi)] | length) as $nt
    | { prs: ($rv | length),
        findingsPerPr: (if ($rv | length) > 0 then ([$rv[].findings] | add) / ($rv | length) | r2 else null end),
        roundsToPass: (if ($sh | length) > 0 then ([$sh[].model] | add) / ($sh | length) | r2 else null end),
        oneRoundShare: (if ($sh | length) > 0 then ([$sh[] | select(.model == 1)] | length) / ($sh | length) | r2 else null end),
        findingTickets: $nt, days: $ndays,
        ticketsPerDay: (if $ndays > 0 then $nt / $ndays | r2 else null end) };
  # The day after "to", so "to" itself is inside the after window.
  (($to + "T00:00:00Z") | fromdate + 86400 | todate | .[0:10]) as $end
  | { split: $split, from: $from, to: $to,
      before: side($from; $split; days($from; $split)),
      after: side($split; $end; days($split; $end)) }') || die "the figures could not be worked out"

if [ "$JSON" = 1 ]; then printf '%s\n' "$out"; exit 0; fi
printf '%s' "$out" | jq -r '
  def f: if . == null then "n/a" else tostring end;
  "Review before and after \(.split) (before: \(.from) to the split; after: the split to \(.to))",
  (["before", "after"][] as $k | .[$k] as $s
   | "  \($k): \($s.prs) PR(s) reviewed · \($s.findingsPerPr | f) findings per PR · \($s.roundsToPass | f) rounds to pass (\(($s.oneRoundShare // null) | if . == null then "n/a" else (. * 100 | round | tostring) + "%" end) in one) · \($s.ticketsPerDay | f) finding tickets filed per day (\($s.findingTickets) in \($s.days) day(s))")'
