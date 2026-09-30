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
#   clashing PR       — an open, non-draft PR GitHub reports CONFLICTING puts the
#                       ticket it closes on the list as [FINISH PR], whatever that
#                       ticket's status label says. Finish before start: a clashing
#                       PR is work already paid for that only gets dearer, so these
#                       rows sort FIRST, then [RESUME PR], then fresh builds.
#                       (2026-09-30: an approved PR whose ticket had lost its status
#                       label clashed for days — nothing on this list could reach it.)
#   held              — anything with a live claim (refs on origin + legacy
#                       lockfiles, via claim-lock.sh) is not offered.
#
# Usage: claimable-issues.sh            # the list
#        claimable-issues.sh --count    # how many
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh" || exit 1
GH_REPO="${GH_REPO:-$REPO_SLUG}"

HELD=$(toolkit_claimed_issues || true)
# Tickets closed by an open, non-draft PR that GitHub says cannot merge — read from
# the PR's closing reference, else from a title that opens with the ticket number
# ("10902: …", "SH-10625: …"), because a body that says "Closes ticket SH-10704"
# links nothing and hid two clashing PRs on the day this landed. GitHub's
# own mergeability is the authority; a local merge-tree can call a real conflict
# clean. UNKNOWN (not yet computed) is left out rather than guessed at.
finish_rows() {
  # A ticket parked on a person or a prerequisite stays parked, clash or not:
  # finishing it means a decision nobody has made yet.
  local STOP
  STOP=$(printf '"%s",' "$LBL_GATED" "$LBL_BLOCKED" "$LBL_EXTERNAL_BLOCKED" "$LBL_PARKED" \
           "$LBL_PM_DECISION" "$LBL_PM_TRACK" "$LBL_DRAFTING")
  STOP="[${STOP%,}]"
  gh pr list --repo "$GH_REPO" --state open --limit 200 \
    --json isDraft,mergeable,closingIssuesReferences,title \
    -q '.[] | select((.isDraft | not) and .mergeable == "CONFLICTING")
         | if (.closingIssuesReferences | length) > 0 then .closingIssuesReferences[].number
           else (.title | [match("^[^0-9]{0,4}([0-9]{3,6}):").captures[0].string] | first // empty)
           end' 2>/dev/null \
  | sort -un \
  | while read -r n; do
      [ -n "$n" ] || continue
      gh issue view "$n" --repo "$GH_REPO" --json number,title,labels,state \
        -q 'select(.state == "OPEN") | . as $i
            | select([$i.labels[].name] - ('"$STOP"') == [$i.labels[].name])
            | [ "0",
                ($i.number|tostring),
                ([$i.labels[].name | select(startswith("P"))] | first // "P?"),
                ([$i.labels[].name | select(startswith("area:"))] | first // "area:UNFILED" | ltrimstr("area:")),
                ([$i.labels[].name | select(startswith("repo:"))] | first // "repo:-" | ltrimstr("repo:")),
                "[FINISH PR]",
                $i.title
              ] | @tsv' 2>/dev/null
    done
}
rows() {
  { finish_rows
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
          | [ (if $orphan then "1" else "2" end),
              ($i.number|tostring),
              ([$i.labels[].name | select(startswith("P"))] | first // "P?"),
              ([$i.labels[].name | select(startswith("area:"))] | first // "area:UNFILED" | ltrimstr("area:")),
              ([$i.labels[].name | select(startswith("repo:"))] | first // "repo:-" | ltrimstr("repo:")),
              (if $run_ready != null then "[EPIC MODE]" elif $orphan then "[RESUME PR]" else "-" end),
              $i.title
            ] | @tsv' 2>/dev/null
  done; } \
    | sort -t $'\t' -k1,1n -k3,3 -k2,2n \
    | awk -F'\t' '!seen[$2]++' \
    | while IFS=$'\t' read -r _rank id pri area repo mode title; do
        # Empty TSV fields collapse under a tab IFS, so jq never emits one: repo
        # defaults to "-" (the main repo) and mode to "-", mapped back here. A ticket
        # wearing both status:ready and status:in-review is listed once, as the
        # resume (rank 1 beats rank 2); a clashing PR's ticket once, as [FINISH PR].
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
