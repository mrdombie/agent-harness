#!/usr/bin/env bash
# develop-red.sh — one ticket for the trunk when a pre-push check is red on the trunk
# itself, instead of every builder built on it parking.
#
#   develop-red.sh file [dry]
#     reads develop-red.tsv (driver/base-red.sh driver_base_red_note: a push that went out
#     base-red) and files ONE "<trunk> is red: <checks> (<trunk>@<sha7>)" ticket per check
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

failed=0
# One row per (sha, checks), the builders that hit it gathered.
while IFS=$'\t' read -r sha checks who prs; do
  [ -n "$sha" ] && [ -n "$checks" ] || continue
  s7=$(printf '%s' "$sha" | cut -c1-7)
  n=$(awk -F'\t' -v s="$sha" -v c="$checks" '$1 == s && $2 == c { print $3; exit }' "$LEDGER" 2>/dev/null)
  [ -z "$n" ] || continue
  # Searched by the check set alone: an open ticket for an older commit of the same red covers this one.
  if ! found=$(SWARM_GH="$GH" gh_read "whether the $TRUNK red on $checks was filed" api -X GET search/issues \
         -f q="repo:$REPO_SLUG is:issue is:open in:body \"develop-red: checks=$checks\"" \
         -q "[.items[]? | select((.body // \"\") | contains(\"develop-red: checks=$checks sha=\"))][0].number // empty"); then
    echo "unknown — whether the $TRUNK red on $checks was filed could not be read; not filed this pass"; failed=1; continue
  fi
  if [ -z "$found" ] && ! found=$(SWARM_GH="$GH" gh_read "whether the $TRUNK red on $checks at $s7 was filed" api -X GET search/issues \
         -f q="repo:$REPO_SLUG is:issue in:body \"develop-red: checks=$checks sha=$s7\"" \
         -q "[.items[]? | select((.body // \"\") | contains(\"develop-red: checks=$checks sha=$s7 \"))][0].number // empty"); then
    echo "unknown — whether the $TRUNK red on $checks at $s7 was filed could not be read; not filed this pass"; failed=1; continue
  fi
  if [ -n "$found" ]; then
    printf '%s\t%s\t%s\n' "$sha" "$checks" "$found" >> "$LEDGER"
    echo "the $TRUNK red on ${checks//,/, } at $s7 is #$found's, already filed"; continue
  fi
  title="$TRUNK is red: ${checks//,/, } ($TRUNK@$s7)"
  if [ -n "$DRY" ]; then echo "would file \"$title\" ($PRI, $PROC), ready and first in the queue"; continue; fi
  marker="<!-- develop-red: checks=$checks sha=$s7 -->"
  cmds=$(printf '%s\n' "${checks//,/$'\n'}" | sed 's/^/- `/; s/$/`/')
  body="The pre-push check(s) below fail on $TRUNK itself, at \`$sha\`, the commit the branch(es) of ${who//,/, } merged. Each was run on that commit by itself and failed there, so every branch built on it was refused the same way. Those pushes went out as base-red, and nobody parked. This ticket is the one fix: make these checks green on $TRUNK.

$cmds

Builders that hit it: ${who//,/, }${prs:+ (PRs ${prs//,/, })}.

$marker"
  if ! n=$("$GH" api "repos/$REPO_SLUG/issues" -X POST -f title="$title" -f body="$body" \
             -f "labels[]=$PRI" -f "labels[]=$PROC" -q .number 2>/dev/null) || [ -z "$n" ]; then
    echo "the $TRUNK red on ${checks//,/, } at $s7 could not be filed"; failed=1; continue
  fi
  printf '%s\t%s\t%s\n' "$sha" "$checks" "$n" >> "$LEDGER"
  issue_status_set "$n" "$LBL_READY" >/dev/null 2>&1 || { echo "#$n is filed but could not be marked ${LBL_READY}"; failed=1; }
  if [ "${DEVELOP_RED_QUEUE:-on}" != off ]; then
    bash "${DEVELOP_RED_QUEUE_CMD:-$SELF_DIR/coordinator-queue.sh}" add "$n" --front --note "$TRUNK is red: $checks at $s7" >/dev/null 2>&1 \
      || echo "#$n is filed and ready, and could not be put at the front of the coordinator queue"
  fi
  echo "filed #$n ($PRI, $PROC): $title — ready and at the front of the queue"
done < <(awk -F'\t' 'NF >= 2 && $1 != "" && $2 != "" {
           k = $1 "\t" $2
           if (!(k in seen)) { seen[k] = 1; order[++n] = k; who[k] = ""; prs[k] = "" }
           if ($3 != "" && index("," who[k] ",", "," "#" $3 ",") == 0) who[k] = who[k] (who[k] == "" ? "" : ",") "#" $3
           if ($4 != "" && index("," prs[k] ",", "," "#" $4 ",") == 0) prs[k] = prs[k] (prs[k] == "" ? "" : ",") "#" $4
         } END { for (i = 1; i <= n; i++) print order[i] "\t" who[order[i]] "\t" prs[order[i]] }' "$PENDING")
exit "$failed"
