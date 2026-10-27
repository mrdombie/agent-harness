#!/usr/bin/env bash
# develop-red.sh — one ticket for the trunk when a pre-push check is red on the trunk
# itself, instead of every builder built on it parking.
#
#   develop-red.sh file [dry]
#     reads develop-red.tsv (driver/base-red.sh driver_base_red_note: a push that went out
#     base-red, or develop-hook-red.sh's sweep of the hooks' checks) and files ONE "<trunk> is red: <checks> (<trunk>@<sha7>)" ticket per check
#     set and trunk commit, at the integration priority's top (labels.priority.critical, P0)
#     with the process label (coordinator.processLabel, default process), status ready and
#     at the front of the coordinator queue. `dry` files nothing and says what it would.
#   exit 0 every row filed or already filed · 1 one or more could not be · 2 usage
#
# FILED ONCE, the follow-up.sh way: a ledger on this host (develop-red-filed.tsv) and a
# marker in the body, searched on the forge, so another builder, a resumed tick or another
# host files nothing twice. While a ticket for the same check set is still open, a newer
# trunk commit red on the same checks is that ticket's, not a new one: the trunk moves
# every few minutes and the red is the same red. An unreadable search is unknown, never
# "not filed": the row waits for the next tick.
#
# TWO SEARCHES A PASS, whatever is pending: the open develop-red ticket, then every marker,
# each read once and the rows matched here. Searched per row, 22 stuck rows made 44 search
# calls a tick against GitHub's 30 a minute, every one was refused, and none ever left
# develop-red.tsv. While the search limit is spent nothing is searched. A row the ledger
# holds is pruned from develop-red.tsv.
#
#   develop-red.tsv        <sha> \t <checks> \t <ticket> \t <pr> \t <epoch>   (pending, appended by builders)
#   develop-red-filed.tsv  <sha> \t <checks> \t <issue>
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" || exit 1

die() { echo "develop-red: $*" >&2; exit 2; }
[ "${1:-}" = file ] || die "usage: develop-red.sh file [dry]"
DRY=""; [ "${2:-}" = dry ] && DRY=1
GH="${DEVELOP_RED_GH:-gh}"
declare -F gh_read >/dev/null 2>&1 || . "$SELF_DIR/gh-batch.sh" || exit 1
PENDING="${DEVELOP_RED_FILE:-$STATE_DIR/swarm/develop-red.tsv}"
LEDGER="${DEVELOP_RED_LEDGER:-$STATE_DIR/swarm/develop-red-filed.tsv}"
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null; touch "$LEDGER" 2>/dev/null
[ -s "$PENDING" ] || exit 0
TRUNK="${INTEGRATION_BRANCH:-$(toolkit_cfg integrationBranch 2>/dev/null)}"; TRUNK="${TRUNK:-develop}"
PRI=$(toolkit_cfg labels.priority.critical 2>/dev/null); PRI="${PRI:-P0}"
PROC=$(toolkit_cfg coordinator.processLabel 2>/dev/null); PROC="${PROC:-process}"

# One row per (sha, checks), the builders that hit it gathered.
rows() {
  awk -F'\t' 'NF >= 2 && $1 != "" && $2 != "" {
    k = $1 "\t" $2
    if (!(k in seen)) { seen[k] = 1; order[++n] = k; who[k] = ""; prs[k] = "" }
    if ($3 != "" && index("," who[k] ",", "," "#" $3 ",") == 0) who[k] = who[k] (who[k] == "" ? "" : ",") "#" $3
    if ($4 != "" && index("," prs[k] ",", "," "#" $4 ",") == 0) prs[k] = prs[k] (prs[k] == "" ? "" : ",") "#" $4
  } END { for (i = 1; i <= n; i++) print order[i] "\t" who[order[i]] "\t" prs[order[i]] }' "$PENDING"
}
ledgered() { awk -F'\t' -v s="$1" -v c="$2" '$1 == s && $2 == c { print $3; exit }' "$LEDGER" 2>/dev/null; }
ledger() { [ -n "$DRY" ] || printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$LEDGER"; }
# prune — drops the rows the ledger holds. Re-read at write time and swapped in whole, so
# a row a builder appends meanwhile survives. Never in dry.
prune() {
  [ -z "$DRY" ] && [ -s "$PENDING" ] || return 0
  local tmp; tmp=$(mktemp "$PENDING.XXXXXX") || return 0
  if awk -F'\t' -v l="$LEDGER" 'FILENAME == l { done[$1 "\t" $2] = 1; next } !(($1 "\t" $2) in done)' "$LEDGER" "$PENDING" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$PENDING"
  else rm -f "$tmp"; fi
}

prune
TODO=$(rows | while IFS=$'\t' read -r sha checks who prs; do [ -n "$(ledgered "$sha" "$checks")" ] || printf '%s\t%s\t%s\t%s\n' "$sha" "$checks" "$who" "$prs"; done)
[ -n "$TODO" ] || exit 0
pending_n=$(printf '%s\n' "$TODO" | grep -c .)
if until=$(gh_backoff_search_active); then
  echo "GitHub's search limit is spent until $(date -u -r "$until" +%H:%M:%SZ 2>/dev/null || date -u -d "@$until" +%H:%M:%SZ 2>/dev/null) — the $pending_n pending $TRUNK red row(s) wait for a pass after it; nothing searched"
  exit 1
fi
E=$(mktemp "${TMPDIR:-/tmp}/develop-red.XXXXXX") || exit 1
trap 'rm -f "$E"' EXIT
MARK='develop-red: checks=([^ ]+) sha=([0-9a-f]+)'
# 1. ANY OPEN develop-red TICKET COVERS EVERY ROW: a red set that grew or shrank (one check
# fixed, another broke) is the same red trunk. A second ticket was built in full beside the
# first (#14229 beside #14215, 2026-10-24). A new set goes on the open one as a comment.
if ! open=$(SWARM_GH="$GH" gh_read "whether an open $TRUNK red was filed" api -X GET search/issues \
       -f q="repo:$REPO_SLUG is:issue is:open in:body \"develop-red: checks=\"" \
       -q "[.items[]? | select((.body // \"\") | test(\"$MARK\"))][0] | if . == null then empty else \"\\(.number)\\t\\([(.body // \"\") | scan(\"$MARK\") | .[0]] | join(\" \"))\" end" 2>"$E"); then
  echo "$(grep -m1 . "$E" || echo "unknown — whether an open $TRUNK red was filed could not be read") — $pending_n row(s) not filed this pass"; exit 1
fi
OPEN_N=${open%%$'\t'*}; OPEN_SETS=" ${open#*$'\t'} "; [ -n "$OPEN_N" ] || OPEN_SETS=" "
# 2. No open ticket: every marker, open or closed, newest first. A row older than the last
# 100 was ledgered long ago.
MARKERS=""
if [ -z "$OPEN_N" ] && ! MARKERS=$(SWARM_GH="$GH" gh_read "which $TRUNK reds were filed" api -X GET search/issues \
       -f q="repo:$REPO_SLUG is:issue in:body \"develop-red: checks=\"" -f sort=created -f order=desc -f per_page=100 \
       -q ".items[]? | .number as \$n | (.body // \"\") | scan(\"$MARK\") | \"\\(\$n)\\t\\(.[0])\\t\\(.[1])\"" 2>"$E"); then
  echo "$(grep -m1 . "$E" || echo "unknown — which $TRUNK reds were filed could not be read") — $pending_n row(s) not filed this pass"; exit 1
fi

failed=0
while IFS=$'\t' read -r sha checks who prs; do
  [ -n "$sha" ] && [ -n "$checks" ] || continue
  s7=$(printf '%s' "$sha" | cut -c1-7)
  if [ -n "$OPEN_N" ]; then
    case "$OPEN_SETS" in
      *" $checks "*) ledger "$sha" "$checks" "$OPEN_N"; echo "the $TRUNK red on ${checks//,/, } at $s7 is the open #$OPEN_N's, already filed"; continue ;;
    esac
    if [ -n "$DRY" ]; then echo "would add the $TRUNK red on ${checks//,/, } at $s7 to the open #$OPEN_N"; continue; fi
    "$GH" api "repos/$REPO_SLUG/issues/$OPEN_N/comments" -X POST \
      -f body="$TRUNK is still red at \`$sha\`, now on: ${checks//,/, }.${who:+ Builders that hit it: ${who//,/, }.} This ticket covers it; no second one is filed." >/dev/null 2>&1 \
      || { echo "the $TRUNK red on ${checks//,/, } at $s7 could not be added to #$OPEN_N"; failed=1; continue; }
    ledger "$sha" "$checks" "$OPEN_N"; OPEN_SETS="$OPEN_SETS$checks "
    echo "the $TRUNK red on ${checks//,/, } at $s7 is the open #$OPEN_N's: added there as a comment"; continue
  fi
  found=$(printf '%s\n' "$MARKERS" | awk -F'\t' -v c="$checks" -v s="$s7" '$2 == c && $3 == s { print $1; exit }')
  if [ -n "$found" ]; then
    ledger "$sha" "$checks" "$found"
    echo "the $TRUNK red on ${checks//,/, } at $s7 is #$found's, already filed"; continue
  fi
  title="$TRUNK is red: ${checks//,/, } ($TRUNK@$s7)"
  if [ -n "$DRY" ]; then echo "would file \"$title\" ($PRI, $PROC), ready and first in the queue"; continue; fi
  marker="<!-- develop-red: checks=$checks sha=$s7 -->"
  cmds=$(printf '%s\n' "${checks//,/$'\n'}" | sed 's/^/- `/; s/$/`/')
  # No builder on the row: the coordinator's sweep of the hooks' checks found it first.
  if [ -n "$who" ]; then
    body="The pre-push check(s) below fail on $TRUNK itself, at \`$sha\`, the commit the branch(es) of ${who//,/, } merged. Each was run on that commit by itself and failed there, so every branch built on it was refused the same way. Those pushes went out as base-red, and nobody parked. This ticket is the one fix: make these checks green on $TRUNK.

$cmds

Builders that hit it: ${who//,/, }${prs:+ (PRs ${prs//,/, })}.

$marker"
  else
    body="The check(s) below, which the commit or push hooks run, fail on $TRUNK itself, at \`$sha\`. The coordinator ran each on that commit by itself (scripts/develop-hook-red.sh) and it failed there, so every builder whose hook runs it will be refused the same way. This ticket is the one fix: make these checks green on $TRUNK.

$cmds

No builder has hit it yet.

$marker"
  fi
  if ! n=$("$GH" api "repos/$REPO_SLUG/issues" -X POST -f title="$title" -f body="$body" \
             -f "labels[]=$PRI" -f "labels[]=$PROC" -q .number 2>/dev/null) || [ -z "$n" ]; then
    echo "the $TRUNK red on ${checks//,/, } at $s7 could not be filed"; failed=1; continue
  fi
  ledger "$sha" "$checks" "$n"
  # Filed this pass, it is the open ticket for every row after this one: the search index
  # would not show it yet.
  OPEN_N=$n; OPEN_SETS=" $checks "
  issue_status_set "$n" "$LBL_READY" >/dev/null 2>&1 || { echo "#$n is filed but could not be marked ${LBL_READY}"; failed=1; }
  if [ "${DEVELOP_RED_QUEUE:-on}" != off ]; then
    bash "${DEVELOP_RED_QUEUE_CMD:-$SELF_DIR/coordinator-queue.sh}" add "$n" --front --note "$TRUNK is red: $checks at $s7" >/dev/null 2>&1 \
      || echo "#$n is filed and ready, and could not be put at the front of the coordinator queue"
  fi
  echo "filed #$n ($PRI, $PROC): $title — ready and at the front of the queue"
done <<<"$TODO"
prune
exit "$failed"
