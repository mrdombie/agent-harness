#!/usr/bin/env bash
# approval-kept.sh — does a sign-off still cover a pull request after an update?
#
#   approval-kept.sh check <approved-sha> <head-sha> [--screens "<cmd>"]
#       0  kept: every commit of the PR's own since the approved head is a merge,
#          and none of its screen files changed since it. Prints the sentence to
#          comment, naming both SHAs.
#       1  voided: prints why (a commit of its own, or the screen files that moved).
#       2  could not be read: the hold stays, and the caller says it could not tell.
#   approval-kept.sh approved-head <pr>
#       the head SHA the last sign-off was given at; exit 1 when there is none.
#   approval-kept.sh signed-head <pr>
#       the head the last sign-off of any kind covered, a bare label removal included;
#       1 never signed, 2 unreadable, 3 signed but the head then cannot be placed.
#   approval-kept.sh marker <sha>
#       the marker line clear-hold.sh ends a sign-off with.
#   approval-kept.sh screens [--screens "<cmd>"]
#       paths on stdin, the screen ones on stdout, by the rule below.
#
# An approval is attached to what was approved, and only a change to that thing
# voids it. A develop merge brings other tickets' screens, which passed their own
# sign-off; what voids is a change to THIS PR's screens — its own commits, or a
# merge whose resolution edited, dropped or un-renamed one of them.
#
#   since = approved..head            own = trunk...approved  ∪  trunk...head
#   voided when a commit in both since and the PR's own diff is not a merge, or a
#   screen file of `own` changed in `since`. The PR's screens are read at BOTH
#   heads: a resolution that takes develop's version, or drops a screen the PR
#   added, leaves no trace in the new head's diff alone.
#
# A screen is any file that is not a test (tests.patterns, *.test.*, *.spec.*,
# __tests__/, __mocks__/) and not under design.neverScreens — unless
# design.surfacePathsComplete is true, when only design.surfacePaths (or the
# --screens command: paths on stdin, the screen ones out) decide. A partial screen
# list keeps approvals it should void; a full one only holds more.
# Globs read as git pathspecs written as globs: ** crosses directories, * and ?
# stay in one, a plain path matches itself and everything under it.
#
# GitHub cuts a comparison at 300 files and 250 commits: a cut update is read file
# by file; a cut own diff or commit list is unreadable, never kept.
#
# The approved head comes from a GitHub review (its commit_id) or from a
# clear-hold.sh comment in its own words, ending in the marker, that the hold's
# removal by a person followed within APPROVAL_WINDOW_SEC (300). A comment alone
# proves nothing: anything on the operator's token can post one.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" || exit 2
. "$SELF_DIR/gh-batch.sh" || exit 2
REPO="${GH_REPO:-$REPO_SLUG}"
WINDOW="${APPROVAL_WINDOW_SEC:-300}"

usage() { sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

marker() { printf '<!-- approval-head:%s -->\n' "$1"; }

glob_re() { # <glob> — an anchored ERE
  local p="$1" out="" i c
  for ((i = 0; i < ${#p}; i++)); do
    c="${p:i:1}"
    case "$c" in
      '*') if [ "${p:i+1:1}" = '*' ]; then
             if [ "${p:i+2:1}" = / ]; then out+='(.*/)?'; i=$((i + 2)); else out+='.*'; i=$((i + 1)); fi
           else out+='[^/]*'; fi ;;
      '?') out+='[^/]' ;;
      .|+|\(|\)|\||^|\$|\{|\}|\\) out+="\\$c" ;;
      *) out+="$c" ;;
    esac
  done
  printf '^%s(/.*)?$' "${out%/}"
}

matches_any() { # <path> <json-array-of-globs>
  local f="$1" pat re
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    re=$(glob_re "$pat"); [[ "$f" =~ $re ]] && return 0
  done <<< "$(jq -r '.[]' <<<"$2")"
  return 1
}

is_screen_glob() { # <path> <surface-json> — includes of surfacePaths, minus its excludes
  local inc exc
  exc=$(jq -c '[.[] | select(startswith(":(exclude)") or startswith(":!")) | sub("^:\\(exclude\\)"; "") | sub("^:!"; "")]' <<<"$2")
  inc=$(jq -c '[.[] | select((startswith(":(exclude)") or startswith(":!")) | not)]' <<<"$2")
  matches_any "$1" "$exc" && return 1
  matches_any "$1" "$inc"
}

screens_of() { # <screens-cmd|""> — paths on stdin, the screen ones on stdout
  local cmd="$1" surface never tests complete f listed
  surface=$(jq -c '.design.surfacePaths // [] | if type == "array" then . else [] end' "$HARNESS_CFG" 2>/dev/null) || surface='[]'
  never=$(jq -c '.design.neverScreens // [] | if type == "array" then . else [] end' "$HARNESS_CFG" 2>/dev/null) || never='[]'
  tests=$(jq -c '["**/*.test.*", "**/*.spec.*", "**/__tests__/**", "**/__mocks__/**"] + (.tests.patterns // [] | if type == "array" then map("**/" + .) else [] end)' "$HARNESS_CFG" 2>/dev/null) \
    || tests='["**/*.test.*","**/*.spec.*","**/__tests__/**","**/__mocks__/**"]'
  complete=$(jq -r '.design.surfacePathsComplete == true' "$HARNESS_CFG" 2>/dev/null)
  local paths; paths=$(cat)
  listed=""
  [ -z "$cmd" ] || listed=$(printf '%s\n' "$paths" | sh -c "$cmd" 2>/dev/null)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -n "$cmd" ] && printf '%s\n' "$listed" | grep -qxF -- "$f"; then printf '%s\n' "$f"; continue; fi
    matches_any "$f" "$never" && continue
    if [ "$complete" = true ]; then
      [ -n "$cmd" ] || { is_screen_glob "$f" "$surface" && printf '%s\n' "$f"; }
      continue
    fi
    matches_any "$f" "$tests" || printf '%s\n' "$f"
  done <<<"$paths"
}

blob_at() { # <sha> <path> — the file's blob, "absent" when the commit has none, 1 unreadable
  local enc out
  enc=$(jq -rn --arg p "$2" '$p | split("/") | map(@uri) | join("/")')
  if out=$(gh_call api "repos/$REPO/contents/$enc?ref=$1" --jq .sha 2>&1); then
    [ -n "$out" ] && printf '%s' "$out" && return 0; return 1
  fi
  case "$out" in *"Not Found"*|*"HTTP 404"*) printf absent; return 0 ;; esac
  return 1
}

cut() { jq -e '(.files | length) >= 300 or ((.total_commits // (.commits | length)) > (.commits | length))' >/dev/null <<<"$1"; }
shaped() { jq -e '(.commits | type == "array") and (.files | type == "array")' >/dev/null 2>&1 <<<"$1"; }

check() { # <approved> <head> [--screens cmd]
  local approved="${1:-}" head="${2:-}" cmd="" since own owna moved screens f a b
  [ -n "$approved" ] && [ -n "$head" ] || usage
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in --screens) cmd="${2:?--screens needs a command}"; shift 2 ;; *) usage ;; esac
  done
  if [ "$approved" = "$head" ]; then
    echo "approval kept: the head is the approved ${approved:0:7}"; return 0
  fi
  since=$(gh_call api "repos/$REPO/compare/$approved...$head" 2>/dev/null) || { echo "could not compare ${approved:0:7} with ${head:0:7}"; return 2; }
  own=$(gh_call api "repos/$REPO/compare/$INTEGRATION_BRANCH...$head" 2>/dev/null) || { echo "could not read the PR's own diff at ${head:0:7}"; return 2; }
  owna=$(gh_call api "repos/$REPO/compare/$INTEGRATION_BRANCH...$approved" 2>/dev/null) || { echo "could not read the PR's own diff at the approved ${approved:0:7}"; return 2; }
  shaped "$since" || { echo "the comparison of ${approved:0:7} with ${head:0:7} carries no commits or files"; return 2; }
  shaped "$own" || { echo "the PR's own diff at ${head:0:7} carries no commits or files"; return 2; }
  shaped "$owna" || { echo "the PR's own diff at the approved ${approved:0:7} carries no commits or files"; return 2; }
  if jq -e '(.total_commits // (.commits | length)) > (.commits | length)' >/dev/null <<<"$since" || cut "$own" || cut "$owna"; then
    echo "GitHub cut the comparison short (300 files or 250 commits), so the screens it changes cannot be read"; return 2
  fi
  if jq -e '(.status // "") == "behind" or (.status // "") == "diverged"' >/dev/null <<<"$since"; then
    echo "the approved ${approved:0:7} is no longer under ${head:0:7} — history was rewritten"; return 1
  fi
  # The trunk's own commits come in with a merge; only the PR's own (in `own`) count.
  if jq -e --argjson own "$(jq -c '[.commits[]?.sha]' <<<"$own")" \
       '[.commits[] | select(.sha as $s | $own | index($s))] | length == 0 or any(.[]; (.parents | length) < 2)' >/dev/null <<<"$since"; then
    echo "it carries a commit of its own since the approved ${approved:0:7}"; return 1
  fi
  # Both heads, and a rename's old path: a screen the resolution dropped or moved still counts.
  screens=$(jq -r '.files[] | .filename, (.previous_filename // empty)' <<<"$own"$'\n'"$owna" | sort -u | screens_of "$cmd" | sort -u)
  if jq -e '(.files | length) < 300' >/dev/null <<<"$since"; then
    moved=$(comm -12 <(printf '%s\n' "$screens") \
      <(jq -r '.files[] | .filename, (.previous_filename // empty)' <<<"$since" | sort -u) | sed '/^$/d')
  else
    # A busy trunk fills the 300-file list; then each own screen is compared by blob.
    moved=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      a=$(blob_at "$approved" "$f") || { echo "could not read $f at ${approved:0:7}"; return 2; }
      b=$(blob_at "$head" "$f") || { echo "could not read $f at ${head:0:7}"; return 2; }
      [ "$a" = "$b" ] || moved="$moved$f"$'\n'
    done <<<"$screens"
    moved=$(printf '%s' "$moved" | sed '/^$/d')
  fi
  if [ -n "$moved" ]; then
    echo "the update changed its own screen files: $(printf '%s' "$moved" | tr '\n' ' ' | sed 's/ $//')"; return 1
  fi
  echo "approval kept: $INTEGRATION_BRANCH-only update, screens unchanged (approved ${approved}, now ${head})"
  return 0
}

# signoffs <pr> [place] — every sign-off of the PR as {at, sha, how}, oldest first: a review
# or a marked clear-hold comment (how=marked, sha its head), and a person's removal
# of the hold with no marked record beside it (how=label, sha the head then, or ""
# when the commits cannot place it; they are read only with `place`). Exit 2 when
# the PR cannot be read.
signoffs() {
  local pr="$1" place="${2:-}" comments reviews events commits
  comments=$(gh_call api "repos/$REPO/issues/$pr/comments?per_page=100" --paginate 2>/dev/null | jq -cs 'add // []') || comments=""
  reviews=$(gh_call api "repos/$REPO/pulls/$pr/reviews?per_page=100" --paginate 2>/dev/null | jq -cs 'add // []') || reviews=""
  events=$(gh_call api "repos/$REPO/issues/$pr/events?per_page=100" --paginate 2>/dev/null | jq -cs 'add // []') || events=""
  [ -n "$comments" ] && [ -n "$reviews" ] && [ -n "$events" ] || { echo "could not read PR #$pr's sign-offs" >&2; return 2; }
  commits='[]'
  if [ "$place" = place ] && jq -e --arg hold "$HOLD_LABEL" 'any(.[]; .event == "unlabeled" and .label.name == $hold)' >/dev/null 2>&1 <<<"$events"; then
    commits=$(gh_call api "repos/$REPO/pulls/$pr/commits?per_page=100" --paginate 2>/dev/null | jq -cs 'add // []') \
      || { echo "could not read PR #$pr's commits" >&2; return 2; }
  fi
  jq -cn --argjson c "$comments" --argjson r "$reviews" --argjson e "$events" --argjson k "$commits" \
         --arg hold "$HOLD_LABEL" --argjson win "$WINDOW" '
    def t: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    def human: (.type // "User") != "Bot" and ((.login // "") | endswith("[bot]") | not);
    ([ $e[] | select(.event == "unlabeled" and .label.name == $hold and (.actor | human)) | .created_at | t ]) as $offs
    | [ ( $r[] | select(.state == "APPROVED" and (.user | human) and (.commit_id // "" | test("^[0-9a-f]{40}$")))
          | {at: (.submitted_at | t), sha: .commit_id, how: "marked"} ),
        ( $c[] | select(.user | human) | (.body // "") as $b
          | select(($b | startswith("Approved by @")) or ($b | startswith("`" + $hold + "` cleared on @")))
          | ($b | capture("\n<!-- approval-head:(?<s>[0-9a-f]{40}) -->\\s*$")?) as $m
          | select($m != null) | (.created_at | t) as $at
          | select(any($offs[]; . >= $at and . <= $at + $win))
          | {at: $at, sha: $m.s, how: "marked"} ) ] as $marked
    | [ $offs[] as $o | select(all($marked[]; ($o < .at or $o > .at + $win)))
        | {at: $o, how: "label",
           sha: ([ $k[] | select((.commit.committer.date // "") != "" and (.commit.committer.date | t) <= $o) | .sha ] | last // "")} ] as $bare
    | $marked + $bare | sort_by(.at)'
}

approved_head() { # <pr>
  local pr="${1:-}" all sha
  case "$pr" in ''|*[!0-9]*) usage ;; esac
  all=$(signoffs "$pr") || return 2
  sha=$(jq -r '[.[] | select(.how == "marked")] | last | .sha // empty' <<<"$all")
  [ -n "$sha" ] || { echo "PR #$pr carries no sign-off that names its head" >&2; return 1; }
  printf '%s\n' "$sha"
}

# signed_head <pr> — the head the last sign-off of ANY kind covered. A hold a person
# removed on GitHub writes no marker, and is still a sign-off: its head is the PR's
# head at that moment. 0 prints it · 1 never signed · 2 unreadable · 3 signed, head
# unknown (the commits could not place the removal).
signed_head() {
  local pr="${1:-}" all last
  case "$pr" in ''|*[!0-9]*) usage ;; esac
  all=$(signoffs "$pr" place) || return 2
  last=$(jq -c 'last // empty' <<<"$all")
  [ -n "$last" ] || { echo "PR #$pr was never signed off" >&2; return 1; }
  jq -r '.sha' <<<"$last" | grep -qE '^[0-9a-f]{40}$' || { echo "PR #$pr was signed off at $(jq -r '.at | todate' <<<"$last"), and its head then cannot be placed" >&2; return 3; }
  jq -r '.sha' <<<"$last"
}

case "${1:-}" in
  check)         shift; check "$@" ;;
  approved-head) shift; approved_head "$@" ;;
  signed-head)   shift; signed_head "$@" ;;
  marker)        [ -n "${2:-}" ] || usage; marker "$2" ;;
  screens)       case "${2:-}" in '') screens_of "" ;; --screens) [ -n "${3:-}" ] || usage; screens_of "$3" ;; *) usage ;; esac ;;
  *)             usage ;;
esac
