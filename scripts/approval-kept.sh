#!/usr/bin/env bash
# approval-kept.sh — does a sign-off still cover a pull request after an update?
#
#   approval-kept.sh check <approved-sha> <head-sha> [--screens "<cmd>"]
#       0  kept: every commit since the approved head is a merge, and no screen
#          file in the PR's own diff changed since it. Prints the sentence to
#          comment, naming both SHAs.
#       1  voided: prints why (a commit of its own, or the screen files that moved).
#       2  could not be read: the hold stays, and the caller says it could not tell.
#   approval-kept.sh approved-head <pr>
#       the head SHA the last sign-off was given at, read from the marker
#       clear-hold.sh writes; exit 1 when the PR carries none.
#   approval-kept.sh marker <sha>
#       the marker line itself, for whoever records a sign-off.
#
# An approval is attached to what was approved, and only a change to that thing
# voids it ("keep your approval through updates"). A
# develop merge brings other tickets' screens, which passed their own sign-off;
# what voids is a change to THIS PR's screens — its own commits, or a merge whose
# conflict resolution edited one of them.
#
#   since = approved..head (the update)        own = trunk...head (the PR's diff)
#   voided when a commit in both is not a merge, or a screen file is in both.
#   The trunk's commits a merge brings are in `since` only, so they never count.
#
# A file the develop merge brought that the PR also changes counts as changed:
# that is where a conflict resolution lands, so it holds more, never less.
#
# Screens: --screens names a command that reads paths on stdin and prints the
# ones that are screens (a project's own predicate). Without it, a path is a
# screen when it matches an include of design.surfacePaths and no :(exclude);
# with no surfacePaths every file counts. GitHub cuts a comparison at 300 files
# and 250 commits: a cut update is read file by file, a cut own diff or commit
# list is unreadable, never kept.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" || exit 2
. "$SELF_DIR/gh-batch.sh" || exit 2
REPO="${GH_REPO:-$REPO_SLUG}"
MARK_RE='<!-- approval-head:([0-9a-f]{40}) -->'

usage() { sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

marker() { printf '<!-- approval-head:%s -->\n' "$1"; }

# Globs from design.surfacePaths; ** crosses directories, as git reads it.
is_screen_glob() { # <path> <surface-json>
  local f="$1" pat inc=0 hit=0
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    case "$pat" in
      ':(exclude)'*|':!'*)
        pat="${pat#:(exclude)}"; pat="${pat#:!}"; pat="${pat//\*\*\//}"; pat="${pat//\*\*/*}"
        [[ "$f" == $pat ]] && return 1 ;;
      *) inc=1; pat="${pat//\*\*\//}"; pat="${pat//\*\*/*}"; [[ "$f" == $pat ]] && hit=1 ;;
    esac
  done <<< "$(jq -r '.[]' <<<"$2")"
  [ "$inc" = 0 ] || [ "$hit" = 1 ]
}

screens_of() { # <screens-cmd|""> — paths on stdin, the screen ones on stdout
  local cmd="$1" surface f
  if [ -n "$cmd" ]; then sh -c "$cmd"; return 0; fi
  surface=$(jq -c '.design.surfacePaths // [] | if type == "array" then . else [] end' "$HARNESS_CFG" 2>/dev/null) || surface='[]'
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_screen_glob "$f" "$surface" && printf '%s\n' "$f"
  done
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

check() { # <approved> <head> [--screens cmd]
  local approved="${1:-}" head="${2:-}" cmd="" since own moved screens f a b
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
  jq -e '(.commits | type == "array") and (.files | type == "array")' >/dev/null 2>&1 <<<"$since" \
    || { echo "the comparison of ${approved:0:7} with ${head:0:7} carries no commits or files"; return 2; }
  jq -e '(.commits | type == "array") and (.files | type == "array")' >/dev/null 2>&1 <<<"$own" \
    || { echo "the PR's own diff at ${head:0:7} carries no commits or files"; return 2; }
  if jq -e '(.total_commits // (.commits | length)) > (.commits | length)' >/dev/null <<<"$since" \
     || jq -e '(.files | length) >= 300 or ((.total_commits // (.commits | length)) > (.commits | length))' >/dev/null <<<"$own"; then
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
  # A rename's old path counts: moving a screen away changes it.
  screens=$(jq -r '.files[] | .filename, (.previous_filename // empty)' <<<"$own" | screens_of "$cmd" | sort -u)
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

approved_head() { # <pr>
  local pr="${1:-}" bodies sha
  case "$pr" in ''|*[!0-9]*) usage ;; esac
  # Comments and reviews, oldest first; the newest marker is the last sign-off.
  bodies=$( { gh_call api "repos/$REPO/issues/$pr/comments?per_page=100" --paginate \
                --jq '.[] | select(.user.type != "Bot") | [.created_at, (.body // "" | gsub("\n"; " "))] | @tsv' 2>/dev/null
              gh_call api "repos/$REPO/pulls/$pr/reviews?per_page=100" --paginate \
                --jq '.[] | select(.user.type != "Bot") | [.submitted_at // "", (.body // "" | gsub("\n"; " "))] | @tsv' 2>/dev/null
            } | sort -t$'\t' -k1,1)
  sha=$(printf '%s\n' "$bodies" | grep -oE "$MARK_RE" | tail -1 | sed -E "s/$MARK_RE/\\1/")
  [ -n "$sha" ] || { echo "PR #$pr carries no approval-head marker" >&2; return 1; }
  printf '%s\n' "$sha"
}

case "${1:-}" in
  check)         shift; check "$@" ;;
  approved-head) shift; approved_head "$@" ;;
  marker)        [ -n "${2:-}" ] || usage; marker "$2" ;;
  *)             usage ;;
esac
