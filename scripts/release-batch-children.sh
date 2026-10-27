#!/usr/bin/env bash
# release-batch-children.sh — a ticket held as a batch's child goes back to ready the
# moment its batch is not open, however the batch closed.
#
#   release-batch-children.sh [--dry-run | --check]
#
# A held child is open and wears labels.batched ("not picked on its own"): every
# spawner skips it, so only its batch's PR ever builds it. Its batch is the newest
# "batch #N" its comments or else its body names ("Built in batch #13468."). When that
# batch is closed — merged in full, merged in part, closed not planned, closed by hand —
# or the child names no batch at all, nothing will ever build it, so it is set ready,
# told why, and queued first at its priority. close-merged.sh releases on a partial
# merge only; this catches every other route, every pass.
#
# Seen 2026-10-26: 82 of 186 batched tickets in the origin project belonged to batches
# already closed, 48 of them P0/P1.
#
# --check lists the stranded children and exits 1 when there is one: the guard.
# Exit: 0 done · 1 a read failed (nothing is released then) or --check found one.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" || exit 1
declare -F gh_issues_batch >/dev/null 2>&1 || . "$SELF_DIR/gh-batch.sh" || exit 1
declare -F issue_status_set >/dev/null 2>&1 || . "$SELF_DIR/issue-status.sh" || exit 1
MODE=act
case "${1:-}" in --dry-run) MODE=dry ;; --check) MODE=check ;; "") ;; *) echo "usage: $0 [--dry-run | --check]" >&2; exit 2 ;; esac
GH="${SWARM_GH:-gh}"
QUEUE="${RELEASE_BATCH_QUEUE:-$SELF_DIR/coordinator-queue.sh}"
BATCHED="${LBL_BATCHED:-status:batched}"

# "<n>\t<batch or ->" for every held child, the batch from its newest mention.
held=$("$GH" issue list --repo "$REPO_SLUG" --label "$BATCHED" --state open --limit 500 --json number,body,comments 2>/dev/null \
  | jq -r '.[]? | .number as $n
      | ([(.body // ""), ((.comments // [])[]? | .body // "")]
         | map([scan("(?i)\\bbatch(?: ticket)?\\s+#([0-9]+)")[0]] | map(select(. != ($n | tostring)))) | map(select(length > 0)) | last // [] | last // "-") as $b
      | "\($n)\t\($b)"') || { echo "release-batch: the $BATCHED tickets could not be read"; exit 1; }
[ -n "$held" ] || exit 0

batches=$(printf '%s\n' "$held" | cut -f2 | grep -E '^[0-9]+$' | sort -un)
states='{}'
if [ -n "$batches" ]; then
  # shellcheck disable=SC2086  # a list of numbers, split on purpose
  states=$(gh_issues_batch $batches 2>/dev/null) && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$states" \
    || { echo "release-batch: the batches' states could not be read"; exit 1; }
fi

stranded=0
while IFS=$'\t' read -r n b; do
  [ -n "${n:-}" ] || continue
  if [ "$b" = - ]; then why="it names no batch"
  else
    st=$(jq -r --arg b "$b" '.[$b].state // ""' <<<"$states")
    case "$st" in
      OPEN) continue ;;
      "") why="batch #$b could not be found" ;;
      *) why="batch #$b is closed" ;;
    esac
  fi
  stranded=$((stranded + 1))
  case "$MODE" in
    check) echo "stranded: #$n — $why, so nothing builds it" ; continue ;;
    dry)   echo "would release #$n to $LBL_READY — $why" ; continue ;;
  esac
  issue_status_set "$n" "$LBL_READY" --drop "$BATCHED" >/dev/null 2>&1 \
    || { echo "release-batch: #$n could not be set $LBL_READY"; continue; }
  "$GH" issue comment "$n" --repo "$REPO_SLUG" --body "**Released from its batch:** $why, so no batch run will build this. Back on the queue on its own, first at its priority." >/dev/null 2>&1 || true
  bash "$QUEUE" add "$n" --first >/dev/null 2>&1 || echo "release-batch: #$n could not be queued — the next seed finds it ready"
  echo "released #$n — $why"
done <<< "$held"
[ "$MODE" = check ] && [ "$stranded" -gt 0 ] && exit 1
exit 0
