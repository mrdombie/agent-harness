#!/usr/bin/env bash
# claimable-issues.sh — the tickets /claim may pick, one per line:
#   number \t priority \t area \t repo \t mode \t title
#
# This is /claim's Pass A, made into the ONE place the rule lives so the queue
# health report cannot disagree with the thing that hands out work.
#
#   status:ready      — never started. Build it.
#   status:in-review  — orphaned: the agent holding it died with a PR open.
#                       Offered as [RESUME PR] unless it is waiting on a human
#                       (needs:human-approval), which is the other meaning of the label.
#   epic              — only with epic:run-ready ([EPIC MODE]); never as a resume.
#   held              — anything with a live claim (refs on origin + legacy
#                       lockfiles, via claim-lock.sh) is not offered.
#
# Usage: claimable-issues.sh            # the list
#        claimable-issues.sh --count    # how many
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh" || exit 1
GH_REPO="${GH_REPO:-$REPO_SLUG}"

HELD=$(toolkit_claimed_issues || true)
rows() {
  for STATE in status:ready status:in-review; do
    ORPHAN=$([ "$STATE" = "status:in-review" ] && echo true || echo false)
    gh issue list --repo "$GH_REPO" --state open --limit 1000 \
      --label "$STATE" --json number,title,labels \
      -q '.[] | . as $i
          | ([$i.labels[].name] | index("epic")) as $is_epic
          | ([$i.labels[].name] | index("epic:run-ready")) as $run_ready
          | ([$i.labels[].name] | index("needs:human-approval")) as $needs_human
          | '"$ORPHAN"' as $orphan
          | select(($is_epic == null) or (($run_ready != null) and ($orphan | not)))
          | select(($orphan | not) or ($needs_human == null))
          | [ ($i.number|tostring),
              ([$i.labels[].name | select(startswith("P"))] | first // "P?"),
              ([$i.labels[].name | select(startswith("area:"))] | first // "area:UNFILED" | ltrimstr("area:")),
              ([$i.labels[].name | select(startswith("repo:"))] | first // "repo:-" | ltrimstr("repo:")),
              (if $run_ready != null then "[EPIC MODE]" elif $orphan then "[RESUME PR]" else "-" end),
              $i.title
            ] | @tsv' 2>/dev/null
  done \
    | sort -t $'\t' -k2,2 -k1,1 \
    | awk -F'\t' '!seen[$1]++' \
    | while IFS=$'\t' read -r id pri area repo mode title; do
        # Empty TSV fields collapse under a tab IFS, so jq never emits one: repo
        # defaults to "-" (the main repo) and mode to "-", mapped back here. A ticket
        # wearing both status:ready and status:in-review is listed once, as ready.
        [ "$mode" = "-" ] && mode=""
        [ "$repo" = "-" ] && repo=""
        grep -qx "$id" <<<"$HELD" || printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$id" "$pri" "$area" "$repo" "$mode" "$title"
      done
}
case "${1:-}" in
  --count) rows | wc -l | tr -d ' ' ;;
  "")      rows ;;
  *)       echo "usage: claimable-issues.sh [--count]" >&2; exit 2 ;;
esac
