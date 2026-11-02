#!/usr/bin/env bash
# feature-close.sh — a split feature is done only when every item of its feature list passes
# and its clean-up part has merged (owner, 2026-11-02, after Anthropic's long-running harness).
#
#   feature-close.sh <parent> [--dry-run]   check one feature
#   feature-close.sh sweep [--dry-run]      the coordinator's pass: every feature an item part names
#
# The plan step split the feature by behaviour (driver/steps/plan.sh), posted its feature list on
# the parent and closed the parent as split, so nothing claims it again. Each pass here:
#
#   AN ITEM PASSES ONLY WHEN ITS TEST STEPS PASS. Its part closed as completed (merged, with the
#   project's required test run green), and the test file its steps run in is on the integration
#   branch. A part closed any other way, still open, or merged without that file leaves the item
#   failing. Nothing else sets `passes`, and nothing is read back from a comment: a pass is
#   re-derived from the parts every time.
#
#   ONLY `passes` CHANGES. The first list posted on the parent is the list. A later one that
#   edits or removes an item, or its steps, is named to the parent once and ignored.
#
#   THE FEATURE IS DONE when every item passes and the clean-up part (when there is one) has
#   merged: the parent is told "Feature done" and its close reason becomes completed.
#
# The list is re-posted only when an item's passing changes. A read that fails decides nothing
# and writes nothing: exit 1.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" || exit 1
declare -F gh_read >/dev/null 2>&1 || . "$SELF_DIR/gh-batch.sh" || exit 1
DRIVER_DIR="${DRIVER_DIR:-${TMPDIR:-/tmp}}"   # feature-list.sh's run record is never written here
. "$SELF_DIR/../driver/feature-list.sh" || exit 1

DRY=0; MODE=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    sweep) MODE=sweep ;;
    *[!0-9]*|'') echo "feature-close: unknown argument '$a'" >&2; exit 2 ;;
    *) MODE="$a" ;;
  esac
done
[ -n "$MODE" ] || { echo "usage: feature-close.sh <parent>|sweep [--dry-run]" >&2; exit 2; }
GH="${SWARM_GH:-gh}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/feature-close.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

write() { [ "$DRY" = 1 ] || "$GH" "$@" >/dev/null 2>&1; }
note_once() { # <parent> <marker> <body> <comments json> — one comment, looked for first
  jq -e --arg m "<!-- feature-close: $2 -->" '[.[]?.body // "" | select(contains($m))] | length > 0' <<<"$4" >/dev/null 2>&1 && return 0
  write issue comment "$1" --repo "$REPO_SLUG" --body "$3
<!-- feature-close: $2 -->"
}

# check <parent> — 0 read (done or not) · 1 a read failed
check() {
  local p="$1" view comments first newest why n id test part pv st sr onb rc changed=0 fails=0 cl
  view=$(gh_read "feature #$p" issue view "$p" --repo "$REPO_SLUG" --json number,state,stateReason,comments) || return 1
  [ "$(jq -r '.stateReason // ""' <<<"$view")" != COMPLETED ] || { echo "done already: #$p"; return 0; }
  comments=$(jq -c '.comments // []' <<<"$view")
  feature_list_from_comments <<<"$comments" > "$WORK/lists"
  [ -s "$WORK/lists" ] || { echo "no feature list: #$p"; return 0; }
  first="$WORK/first.json"; newest="$WORK/newest.json"
  head -1 "$WORK/lists" > "$first"; tail -1 "$WORK/lists" > "$newest"
  if ! why=$(feature_list_guard "$first" "$newest"); then
    echo "feature #$p: its list was edited ($(printf '%s' "$why" | paste -sd';' -)); the first list stands"
    note_once "$p" "edited" "**Feature list edited:** $(printf '%s' "$why" | paste -sd';' - | sed 's/;/; /g'). Only \`passes\` may change; the first list on this ticket stands, and each item is read from its own part." "$comments"
  fi
  cp "$first" "$WORK/now.json"
  n=$(jq '.items | length' "$first")
  for ((i = 0; i < n; i++)); do
    id=$(jq -r --argjson i "$i" '.items[$i].id' "$first"); test=$(jq -r --argjson i "$i" '.items[$i].test' "$first")
    part=$(jq -r --argjson i "$i" '.items[$i].part // ""' "$first")
    pass=false
    if [ -z "$part" ]; then echo "feature #$p: $id failing: no part was filed for it"
    else
      pv=$(gh_read "part #$part" issue view "$part" --repo "$REPO_SLUG" --json state,stateReason) || return 1
      st=$(jq -r '.state // ""' <<<"$pv"); sr=$(jq -r '.stateReason // ""' <<<"$pv")
      if [ "$st" != CLOSED ]; then echo "feature #$p: $id failing: #$part is still open"
      elif [ "$sr" != COMPLETED ]; then echo "feature #$p: $id failing: #$part closed without merging"
      else
        rc=0; onb=$(gh_read "$id's test on $INTEGRATION_BRANCH" api "repos/$REPO_SLUG/contents/$test?ref=$INTEGRATION_BRANCH" --jq '.path // ""') || rc=$?
        if [ "$rc" -ne 0 ] && [ "$rc" -ne "$GH_READ_MISSING" ]; then return 1; fi
        if [ "$rc" -eq 0 ] && [ -n "$onb" ]; then pass=true; echo "feature #$p: $id passes (#$part merged, $test on $INTEGRATION_BRANCH)"
        else
          echo "feature #$p: $id failing: #$part merged, and its steps's test $test is not on $INTEGRATION_BRANCH"
          note_once "$p" "no-test:$id" "**$id does not pass:** its part #$part merged, and \`$test\`, where its test steps run, is not on \`$INTEGRATION_BRANCH\`. An item passes only when its steps pass in the required test run." "$comments"
        fi
      fi
    fi
    [ "$pass" = true ] || fails=$((fails + 1))
    feature_list_set_pass "$WORK/now.json" "$id" "$pass" > "$WORK/now.tmp" && mv "$WORK/now.tmp" "$WORK/now.json"
  done
  # Posted again only when an item's passing moved since the newest list on the ticket.
  if [ "$(jq -c '[.items[].passes]' "$WORK/now.json")" != "$(jq -c '[.items[].passes]' "$newest")" ]; then
    changed=1; write issue comment "$p" --repo "$REPO_SLUG" --body "$(feature_list_comment "$WORK/now.json")"
  fi
  if [ "$fails" -gt 0 ]; then echo "feature #$p: $fails of $n item(s) failing$([ "$changed" = 0 ] || echo '; list updated')"; return 0; fi
  cl=$(jq -r '.cleanup.part // ""' "$first")
  if [ -n "$cl" ]; then
    pv=$(gh_read "clean-up #$cl" issue view "$cl" --repo "$REPO_SLUG" --json state,stateReason) || return 1
    if [ "$(jq -r '.state' <<<"$pv")" != CLOSED ] || [ "$(jq -r '.stateReason // ""' <<<"$pv")" != COMPLETED ]; then
      echo "feature #$p: every item passes; waiting for its clean-up part #$cl"; return 0
    fi
  fi
  write issue comment "$p" --repo "$REPO_SLUG" --body "**Feature done:** every item of its feature list passes ($(jq -r '[.items[].id] | join(", ")' "$first"))$([ -z "$cl" ] || printf ' and its clean-up part #%s has merged' "$cl"). Closed as completed."
  write api -X PATCH "repos/$REPO_SLUG/issues/$p" -f state=closed -f state_reason=completed
  echo "done: #$p"
}

if [ "$MODE" != sweep ]; then check "$MODE"; exit $?; fi

# The features to check: every parent an item part names, open or merged, newest first.
parts=$(gh_read "the feature item parts" issue list --repo "$REPO_SLUG" --state all --search '"of the feature list of" in:body' \
  --limit 200 --json number,body) || exit 1
parents=$(jq -r '[.[]? | (.body // "") | (capture("<!-- harness:feature-item parent=(?<p>[0-9]+) ") | .p)?] | unique | .[]' <<<"$parts" 2>/dev/null)
rc=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  check "$p" || { echo "feature #$p: unknown — a read failed; next pass"; rc=1; }
done <<<"$parents"
exit "$rc"
