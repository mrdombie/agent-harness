#!/usr/bin/env bash
# unblock-waiting.sh — a ticket waiting on others goes back to ready the moment every one
# of them has landed. The one unblocker: coordinator housekeeping runs it every pass, and
# repair-watch's unblock section calls it only when no coordinator is live, so the two never
# both run.
#
#   unblock-waiting.sh [--dry-run]
#
# A waiting ticket is open and wears the blocked or the gated status (labels.blocked,
# labels.gated). Its blockers are the #numbers after "Blocked until" on the newest line
# saying so, in its comments or else its body (a split part's body says it; the PM writes
# "**PM answer:** Yes, it waits. Blocked until #14268, #14269 … merge."). A blocker has
# landed when it is closed as completed, or is a merged pull request; one closed as not
# planned has not, with one exception: a blocker CLOSED AS SPLIT stands for its parts, read
# from its "Split … into #…" comment, and is landed only once every part is (a part split
# again is read the same way, three levels deep). One closed unmerged for any other reason
# stays a blocker, and the waiting ticket gets one note for the PM. With every blocker
# landed the ticket is set ready, told so, and put on the coordinator's queue with --first,
# so it ranks first at its own priority. (Seen: #13581 was requeued when its blocker closed
# as split into four parts, none merged, and it parked asking.)
#
# Seen 2026-10-24: three parts of split tickets parked within 3 minutes asking "should I
# wait for part N?", and nothing in the coordinator would ever have released them.
# Exit: 0 done · 1 a read failed (nothing is released on a read that failed).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" || exit 1
declare -F gh_issues_batch >/dev/null 2>&1 || . "$SELF_DIR/gh-batch.sh" || exit 1
declare -F issue_status_set >/dev/null 2>&1 || . "$SELF_DIR/issue-status.sh" || exit 1
DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
GH="${SWARM_GH:-gh}"
QUEUE="${UNBLOCK_QUEUE:-$SELF_DIR/coordinator-queue.sh}"

# The waiting tickets, each as "<n>\t<blockers…>" from its newest "Blocked until" line.
read_waiting() { # <label>
  "$GH" issue list --repo "$REPO_SLUG" --label "$1" --state open --limit 200 --json number,body,comments 2>/dev/null \
  | jq -r '.[]? | .number as $n
      | ([(.body // ""), ((.comments // [])[]? | .body // "")] | map(split("\n")[] | select(test("blocked until"; "i"))) | last // "") as $l
      | ($l | sub("(?i).*blocked until"; "") | [scan("#([0-9]+)")[0]] | map(select(. != ($n | tostring))) | unique | join(" ")) as $b
      | select($b != "") | "\($n)\t\($b)"'
}
held=""
for lab in "${LBL_BLOCKED:-}" "${LBL_GATED:-}"; do
  [ -n "$lab" ] || continue
  out=$(read_waiting "$lab") || { echo "unblock: the $lab tickets could not be read"; exit 1; }
  held="$held$out"$'\n'
done
held=$(printf '%s\n' "$held" | awk -F'\t' 'NF == 2 && !seen[$1]++')
[ -n "$held" ] || exit 0
all=$(printf '%s\n' "$held" | cut -f2 | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un)
# shellcheck disable=SC2086  # a list of numbers, split on purpose
states=$(gh_issues_batch $all 2>/dev/null) && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$states" \
  || { echo "unblock: the blockers' states could not be read"; exit 1; }
# A blocker closed as not planned: its split comment's parts, or nothing. Read once each.
SPLITS=""   # <n> \t <parts…>  ("-" when it was not a split)
parts_of() { # <n>
  local hit c
  hit=$(awk -F'\t' -v n="$1" '$1 == n { print $2; f = 1; exit } END { exit !f }' <<<"$SPLITS") && { [ "$hit" = - ] || printf '%s' "$hit"; return 0; }
  c=$("$GH" issue view "$1" --repo "$REPO_SLUG" --json comments 2>/dev/null) || return 1
  hit=$(jq -r '[.comments[]?.body // "" | split("\n")[] | select(test("split[^#]* into #"; "i"))] | last // ""
               | sub("(?i)^.*?split[^#]* into"; "") | [scan("#([0-9]+)")[0]] | join(" ")' <<<"$c" 2>/dev/null)
  SPLITS="$SPLITS$1"$'\t'"${hit:--}"$'\n'
  printf '%s' "$hit"
}
# landed <n> [depth] — 0 landed · 1 still open · 2 closed unmerged, not as split (the PM's).
landed() {
  local b="$1" d="${2:-0}" st rs parts p r worst=0 ps
  st=$(jq -r --arg b "$b" '.[$b].state // ""' <<<"$states"); rs=$(jq -r --arg b "$b" '.[$b].stateReason // ""' <<<"$states")
  if [ -z "$st" ]; then
    ps=$(gh_issues_batch "$b" 2>/dev/null) && states=$(jq -c --argjson p "$ps" '. + $p' <<<"$states")
    st=$(jq -r --arg b "$b" '.[$b].state // ""' <<<"$states"); rs=$(jq -r --arg b "$b" '.[$b].stateReason // ""' <<<"$states")
  fi
  case "$st:$rs" in
    MERGED:*) return 0 ;;
    CLOSED:NOT_PLANNED)
      [ "$d" -lt 3 ] || return 1
      parts=$(parts_of "$b") || return 1
      [ -n "$parts" ] || return 2
      for p in $parts; do
        landed "$p" $((d + 1)); r=$?
        [ "$r" -eq 0 ] || { [ "$r" -gt "$worst" ] && worst=$r; [ "$worst" -lt 1 ] && worst=1; }
      done
      return "$worst" ;;
    CLOSED:*) return 0 ;;
    *) return 1 ;;
  esac
}
while IFS=$'\t' read -r n bl; do
  [ -n "${n:-}" ] || continue
  open=""; unmerged=""
  for b in $bl; do
    landed "$b"; case $? in 0) ;; 2) unmerged="$unmerged #$b" ;; *) open="$open #$b" ;; esac
  done
  if [ -n "$unmerged" ]; then
    echo "waits: #$n — closed unmerged, not as split:$unmerged (the PM decides)"
    # One note for the PM, not one a pass: the marker is looked for on the ticket first.
    if [ "$DRY" = 0 ] && ! "$GH" issue view "$n" --repo "$REPO_SLUG" --json comments -q '.comments[].body' 2>/dev/null | grep -qF "<!-- unblock: unmerged$unmerged -->"; then
      "$GH" issue comment "$n" --repo "$REPO_SLUG" --body "**Still waiting:**$unmerged closed without merging and not as a split, so this ticket stays waiting. The PM decides whether it still needs it.
<!-- unblock: unmerged$unmerged -->" >/dev/null 2>&1 || true
    fi
    continue
  fi
  if [ -n "$open" ]; then echo "waits: #$n — still open:$open"; continue; fi
  if [ "$DRY" = 1 ]; then echo "would unblock #$n — every blocker landed (#${bl// /, #})"; continue; fi
  issue_status_set "$n" "$LBL_READY" >/dev/null 2>&1 || { echo "unblock: #$n could not be set $LBL_READY"; continue; }
  "$GH" issue comment "$n" --repo "$REPO_SLUG" --body "**Unblocked:** every ticket it waited for has landed (#${bl// /, #}). Back on the queue, first at its priority." >/dev/null 2>&1 || true
  bash "$QUEUE" add "$n" --first >/dev/null 2>&1 || echo "unblock: #$n could not be queued — the next seed finds it ready"
  echo "unblocked #$n"
done <<< "$held"
exit 0
