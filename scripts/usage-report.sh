#!/usr/bin/env bash
# usage-report.sh — what the spawned agents cost, from the records they already leave.
#
#   usage-report.sh [--state-dir DIR] [--since YYYY-MM-DD] [--by ticket|operator|week]
#
# Reads runs/<id>.json (written by spawn-claim.sh) and each run's log for its
# `result` line (total_cost_usd, num_turns, subtype). Never calls an API for cost.
# Interactive sessions write no run record; their spend is outside this report
# and the footer says so. A run with no result line DIED — it is counted, not hidden.
#
# Outcome is the RUN's own outcome (done / budget / error / died), not the PR's:
# whether the PR merged lives on GitHub, and this report reads records only.
set -uo pipefail
STATE_DIR="${HARNESS_STATE_DIR:-${MAKTURA_STATE_DIR:-}}"  # harness:legacy-alias
SINCE=""; BY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --by) BY="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "usage-report: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [ -z "$STATE_DIR" ]; then
  # No override: the resolver knows the project's state dir (needs a checkout).
  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  . "$_here/toolkit-env.sh" >/dev/null 2>&1 || { echo "usage-report: no state dir — pass --state-dir or set HARNESS_STATE_DIR" >&2; exit 1; }
fi
[ -d "$STATE_DIR/runs" ] || { echo "usage-report: no runs/ under '$STATE_DIR' — nothing was ever spawned here, or the dir is wrong" >&2; exit 1; }
case "$BY" in ""|ticket|operator|week) ;; *) echo "usage-report: --by takes ticket|operator|week" >&2; exit 2 ;; esac

# One TSV row per run: ticket  operator  started  turns  cost  outcome  run_id
rows=$(for f in "$STATE_DIR"/runs/*.json; do
  [ -f "$f" ] || continue
  rec=$(jq -c '{run_id,ticket:(.ticket//""),started_at:(.started_at//""),operator:(.operator//"unknown"),log:(.log//"")}' "$f" 2>/dev/null) || continue
  started=$(jq -r .started_at <<<"$rec"); [ -n "$SINCE" ] && [ "${started:0:10}" \< "$SINCE" ] && continue
  log=$(jq -r .log <<<"$rec"); [ -f "$log" ] || log="$STATE_DIR/logs/$(jq -r .run_id <<<"$rec").log"
  res=""; [ -f "$log" ] && res=$(tr -d '\000' < "$log" | jq -c 'select(.type=="result")' 2>/dev/null | tail -1)
  if [ -z "$res" ]; then turns=""; cost=""; outcome="died"
  else
    turns=$(jq -r '.num_turns // ""' <<<"$res"); cost=$(jq -r '.total_cost_usd // 0' <<<"$res")
    sub=$(jq -r '.subtype // ""' <<<"$res"); err=$(jq -r '.is_error // false' <<<"$res")
    # (pat) not pat): a bare `)` inside $( ... ) trips bash 3.2's parser.
    case "$sub" in (*budget*) outcome="budget" ;; (*) if [ "$err" = true ]; then outcome="error"; else outcome="done"; fi ;; esac
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(jq -r .ticket <<<"$rec")" "$(jq -r .operator <<<"$rec")" "$started" "$turns" "$cost" "$outcome" "$(jq -r .run_id <<<"$rec")"
done | sort -t $'\t' -k3,3)

[ -n "$rows" ] || { echo "no runs${SINCE:+ since $SINCE}"; exit 0; }
died=$(awk -F'\t' '$6=="died"' <<<"$rows" | wc -l | tr -d ' ')
total=$(awk -F'\t' '{s+=$5} END{printf "%.2f", s}' <<<"$rows")
n=$(wc -l <<<"$rows" | tr -d ' ')

if [ -z "$BY" ]; then
  printf '%-7s %-18s %-10s %5s %8s  %-7s %s\n' ticket operator started turns cost outcome run_id
  awk -F'\t' '{printf "%-7s %-18s %-10s %5s %8s  %-7s %s\n", $1, $2, substr($3,1,10), ($4==""?"-":$4), ($5==""?"-":sprintf("%.2f",$5)), $6, $7}' <<<"$rows"
else
  case "$BY" in
    ticket)   key='$1' ;;
    operator) key='$2' ;;
    week)     key='wk' ;;
  esac
  printf '%-18s %5s %8s  %s\n' "$BY" runs cost outcomes
  awk -F'\t' -v by="$BY" '
    function isoweek(d,   cmd, w) { cmd = "date -j -f %Y-%m-%d " d " +%G-W%V 2>/dev/null || date -d " d " +%G-W%V"; cmd | getline w; close(cmd); return w }
    { k = (by=="ticket") ? $1 : (by=="operator") ? $2 : isoweek(substr($3,1,10)); n[k]++; c[k]+=$5; oc[k","$6]++; keys[k]=1 }
    END { for (k in keys) { o=""; for (kk in oc) { split(kk, p, ","); if (p[1]==k) o = o (o==""?"":" · ") p[2] " " oc[kk] } printf "%-18s %5d %8.2f  %s\n", k, n[k], c[k], o } }' <<<"$rows" | sort
fi
printf '%-18s %5s %8s\n' total "$n" "$total"
[ "$died" -gt 0 ] && echo "$died run(s) have no result line (died before finishing) — counted above with no cost."
echo "Interactive sessions write no run record; their spend is not in this report."
