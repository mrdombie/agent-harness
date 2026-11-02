#!/usr/bin/env bash
# sweep-queue.sh — where a pre-existing review finding goes: a defect in code the change
# did not introduce is the nightly sweep's to fix, never the builder's and never a
# ticket's. The review step adds to it; the sweep reads it.
#
#   sweep-queue.sh add <ticket> [<round>]   findings on stdin (a JSON array or one per line)
#   sweep-queue.sh list                     the queue, one JSON object a line
#   sweep-queue.sh count                    how many defects it holds
#   sweep-queue.sh key                      the fingerprint of the one finding on stdin
#   exit 0 done · 2 usage, unreadable input, or no queue path
#
# The queue is $SWEEP_QUEUE, else <stateDir>/swarm/sweep/pre-existing.jsonl. Each defect is
# kept once, by finding_key (scripts/finding-key.jq, the same key the review step's
# never-twice ledger uses): two reviews raising the same old defect queue it once.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYDEF="$(cat "$SELF_DIR/finding-key.jq")" || { echo "sweep-queue: $SELF_DIR/finding-key.jq is missing" >&2; exit 2; }
die() { echo "sweep-queue: $*" >&2; exit 2; }

queue_path() {
  if [ -n "${SWEEP_QUEUE:-}" ]; then printf '%s' "$SWEEP_QUEUE"; return 0; fi
  local sd="${HARNESS_STATE_DIR:-}"
  if [ -z "$sd" ]; then sd=$( . "$SELF_DIR/toolkit-env.sh" >/dev/null 2>&1 && printf '%s' "${STATE_DIR:-}"); fi
  [ -n "$sd" ] || return 1
  printf '%s/swarm/sweep/pre-existing.jsonl' "$sd"
}

# Every input finding as one compact object a line; nothing when the input is not JSON.
read_findings() { jq -c 'if type == "array" then .[] else . end | select(type == "object")' 2>/dev/null; }

CMD="${1:-}"
case "$CMD" in
  key)
    jq -r "$KEYDEF finding_key" 2>/dev/null || die "the finding on stdin is not JSON"
    exit 0 ;;
  add|list|count) : ;;
  *) die "usage: sweep-queue.sh add <ticket> [<round>] | list | count | key" ;;
esac
Q=$(queue_path) || die "no queue: set SWEEP_QUEUE, or a stateDir in harness.json"

case "$CMD" in
  list)  [ -f "$Q" ] && cat "$Q"; exit 0 ;;
  count) if [ -f "$Q" ]; then grep -c . "$Q"; else echo 0; fi; exit 0 ;;
esac

T="${2:-}"; R="${3:-0}"
case "$T" in ''|*[!0-9]*) die "the ticket is a number" ;; esac
case "$R" in ''|*[!0-9]*) die "the round is a number" ;; esac
in=$(cat)
items=$(printf '%s' "$in" | read_findings) || items=""
if [ -z "$items" ]; then
  printf '%s' "$in" | jq -e 'type == "array" and length == 0' >/dev/null 2>&1 && { echo "sweep-queue: 0 queued, 0 already queued"; exit 0; }
  die "the findings on stdin are not JSON"
fi
mkdir -p "$(dirname "$Q")" || die "cannot make $(dirname "$Q")"
touch "$Q" || die "cannot write $Q"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
added=0; dup=0
while IFS= read -r x; do
  [ -n "$x" ] || continue
  k=$(printf '%s' "$x" | jq -r "$KEYDEF finding_key")
  if jq -e --arg k "$k" 'select(.key == $k)' "$Q" >/dev/null 2>&1; then dup=$((dup + 1)); continue; fi
  printf '%s' "$x" | jq -c --arg k "$k" --argjson t "$T" --argjson r "$R" --arg at "$now" \
    '{key: $k, ticket: $t, round: $r, at: $at, file, line, grade, summary, reason, fix}
     + (if .class then {class, instances: (.instances // [])} else {} end)' >> "$Q" \
    || die "cannot append to $Q"
  added=$((added + 1))
done <<<"$items"
echo "sweep-queue: $added queued, $dup already queued ($Q)"
