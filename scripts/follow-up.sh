#!/usr/bin/env bash
# follow-up.sh — merge first, fix after: a review finding that does not hold the change
# becomes its own ticket, ready and first in the queue, and the change ships.
#
#   follow-up.sh file <ticket> <pr> <findings.jsonl>
#     one JSON object a line: {id, grade, file, line, summary, reason, fix, round}
#   exit 0 every finding filed or already filed · 1 one or more could not be · 2 usage
#
# The owner's ruling, 2026-10-22 (release.mergeFirst, release-checks.sh): until the
# release a Critical alone blocks, and is fixed in the change, never filed. A Major is filed at labels.priority.major (P1), a Minor
# no screen's polish list took at labels.priority.minor (P3); the review step already put
# a Minor on a screen's list. Each ticket names the PR, the file:line and the finding.
#
# ONE TICKET PER PR AND FINDING. The key is "<pr> <finding id>": a ledger on this host
# ($STATE_DIR/swarm/follow-ups.tsv) and a marker in the body, searched on the forge, so a
# resumed ship or another host files nothing twice. Then status ready (issue-status.sh)
# and `coordinator-queue.sh add --front`. FOLLOW_UP_QUEUE=off skips the queue (tests).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" || exit 1

die() { echo "follow-up: $*" >&2; exit 2; }
[ "${1:-}" = file ] || die "usage: follow-up.sh file <ticket> <pr> <findings.jsonl>"
T="${2:-}"; PR="${3:-}"; F="${4:-}"
case "$T$PR" in ''|*[!0-9]*) die "the ticket and the pull request are numbers" ;; esac
[ -f "$F" ] || die "no findings file at $F"
GH="${FOLLOW_UP_GH:-gh}"
LEDGER="${FOLLOW_UP_LEDGER:-$STATE_DIR/swarm/follow-ups.tsv}"
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null
P_MAJOR=$(toolkit_cfg labels.priority.major 2>/dev/null); P_MAJOR="${P_MAJOR:-P1}"
P_MINOR=$(toolkit_cfg labels.priority.minor 2>/dev/null); P_MINOR="${P_MINOR:-P3}"

# The parent's screen and area labels ride along, so the follow-up sorts with its screen.
carry=$("$GH" api "repos/$REPO_SLUG/issues/$T" -q '.labels[].name' 2>/dev/null \
  | grep -E "^(${LBL_SCREEN_PREFIX:-screen:}|area:|repo:)" || true)

failed=0; filed=0; had=0
while IFS= read -r x; do
  [ -n "$x" ] || continue
  id=$(jq -r '.id // empty | tostring' <<<"$x" 2>/dev/null)
  [ -n "$id" ] || { echo "a finding with no id was not filed: $(cut -c1-160 <<<"$x")"; failed=1; continue; }
  key="$PR	$id"
  if n=$(awk -F'\t' -v p="$PR" -v i="$id" '$1 == p && $2 == i { print $3; exit }' "$LEDGER" 2>/dev/null) && [ -n "$n" ]; then
    had=$((had + 1)); continue
  fi
  marker="<!-- follow-up: pr=$PR finding=$id -->"
  n=$("$GH" api -X GET search/issues -f q="repo:$REPO_SLUG is:issue in:body \"follow-up: pr=$PR finding=$id\"" \
        -q '.items[0].number // empty' 2>/dev/null)
  if [ -n "$n" ]; then printf '%s\t%s\n' "$key" "$n" >> "$LEDGER"; had=$((had + 1)); continue; fi
  grade=$(jq -r '.grade // "" | ascii_downcase' <<<"$x")
  case "$grade" in
    major) pri="$P_MAJOR" ;; minor) pri="$P_MINOR" ;;
    # A Critical holds the change and is fixed in it; a Nit is dropped. Neither is filed.
    *) echo "finding $id is graded '${grade:-none}', which is never filed as a follow-up"; continue ;;
  esac
  where=$(jq -r '"\(.file // "?"):\(.line // "?")"' <<<"$x")
  summary=$(jq -r '.summary // "" | gsub("[\r\n]+"; " ")' <<<"$x")
  title="$(printf '%s' "$summary" | cut -c1-110) ($where, from PR #$PR)"
  body=$(jq -r --arg pr "$PR" --arg t "$T" --arg w "$where" --arg m "$marker" --arg g "$grade" '
    "A review finding on PR #\($pr) (ticket #\($t)), filed so the change could merge first (release.mergeFirst).\n\n" +
    "**\($g | (.[0:1] | ascii_upcase) + .[1:])** at `\($w)`: \(.summary // "")\n\n" +
    (if (.reason // "") != "" then "Why it matters: \(.reason)\n\n" else "" end) +
    (if (.fix // "") != "" then "The fix the reviewer proposed: \(.fix)\n\n" else "" end) +
    "Fix it on the trunk as its own change. PR #\($pr) has merged or is merging without it.\n\n\($m)"' <<<"$x")
  args=(-f title="$title" -f body="$body" -f "labels[]=$pri")
  while IFS= read -r l; do [ -n "$l" ] && args+=(-f "labels[]=$l"); done <<<"$carry"
  if ! n=$("$GH" api "repos/$REPO_SLUG/issues" -X POST "${args[@]}" -q .number 2>/dev/null) || [ -z "$n" ]; then
    echo "finding $id ($grade, $where) could not be filed as a ticket"; failed=1; continue
  fi
  printf '%s\t%s\n' "$key" "$n" >> "$LEDGER"
  issue_status_set "$n" "$LBL_READY" >/dev/null 2>&1 || { echo "follow-up #$n is filed but could not be marked ${LBL_READY}"; failed=1; }
  if [ "${FOLLOW_UP_QUEUE:-on}" != off ]; then
    bash "${FOLLOW_UP_QUEUE_CMD:-$SELF_DIR/coordinator-queue.sh}" add "$n" --front --note "follow-up of PR #$PR: $grade at $where" >/dev/null 2>&1 \
      || echo "follow-up #$n is filed and ready, and could not be put at the front of the coordinator queue"
  fi
  filed=$((filed + 1))
  echo "filed #$n ($pri) for the $grade at $where on PR #$PR, ready and at the front of the queue"
done < "$F"
[ "$had" -eq 0 ] || echo "$had finding(s) on PR #$PR were already filed as follow-ups"
exit "$failed"
