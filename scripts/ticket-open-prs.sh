#!/usr/bin/env bash
# ticket-open-prs.sh — the other open pull requests that still carry a ticket's work.
# Source it; it reads $REPO_SLUG (or $GH_REPO) and $BRANCH_PREFIX, and needs gh_read.
#
#   ticket_open_prs <ticket> [<except-pr>]
#       prints the open PRs naming the ticket, one number a line, less <except-pr>
#       0 read · 1 the open PRs could not be read: the caller closes nothing
#
# A PR NAMES A TICKET when its body says close/fix/resolve (any tense, an optional colon)
# or "Part of" #N, owner/repo#N or the issue's URL, or its branch is the ticket's by the
# one branch rule (branch-ticket.sh). Refs names nothing: it is a mention, not work.
#
# One merge is not the whole of a ticket's work. 23 Oct: a project's #13006 closed when its
# docs PR merged with the build PR still open, and #12831 with two of its four
# acceptance criteria in a PR still open. A closer asks this first and closes on the
# last merge.
#
# The open PRs are read once a process (every page, 100 a page) and kept in
# $TICKET_OPEN_PRS_CACHE when the caller sets it to a file.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/branch-ticket.sh"

TICKET_OPEN_PRS_JQ="$BRANCH_TICKET_JQ"'
def names_ticket($t; $pre; $slugre):
  ((.head.ref // "") | branch_is_ticket($pre; $t))
  or ((.body // "") | test("(?i)(^|[^A-Za-z0-9_])(close[sd]?|fix(e[sd])?|resolve[sd]?|part of):?[ \\t]+(#|"
        + $slugre + "#|https?://github\\.com/" + $slugre + "/issues/)" + $t + "(?![0-9A-Za-z_])"));
'
_TICKET_OPEN_PRS=""

_ticket_open_prs_read() { # — every open PR as one array, into _TICKET_OPEN_PRS, or 1
  [ -z "$_TICKET_OPEN_PRS" ] || return 0
  if [ -n "${TICKET_OPEN_PRS_CACHE:-}" ] && [ -s "$TICKET_OPEN_PRS_CACHE" ]; then
    _TICKET_OPEN_PRS=$(cat "$TICKET_OPEN_PRS_CACHE"); return 0
  fi
  local repo="${GH_REPO:-$REPO_SLUG}" page=1 all="[]" one n
  while [ "$page" -le 20 ]; do
    one=$(gh_read "the open pull requests" api "repos/$repo/pulls?state=open&per_page=100&page=$page" \
      --jq '[.[] | {number, head: {ref: (.head.ref // "")}, body: (.body // "")}]') || return 1
    n=$(jq 'length' <<<"$one" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) return 1 ;; esac   # an empty answer is not an empty list
    all=$(jq -c --argjson a "$all" '$a + .' <<<"$one") || return 1
    [ "$n" -ge 100 ] || break
    page=$((page + 1))
  done
  _TICKET_OPEN_PRS="$all"
  [ -z "${TICKET_OPEN_PRS_CACHE:-}" ] || printf '%s\n' "$all" > "$TICKET_OPEN_PRS_CACHE" 2>/dev/null || true
}

ticket_open_prs() { # <ticket> [<except-pr>]
  local t="${1#\#}" x="${2:-}" re; x="${x#\#}"
  _ticket_open_prs_read || return 1
  re=$(printf '%s' "${GH_REPO:-$REPO_SLUG}" | sed 's/[].[^$*+?(){}|\\/]/\\&/g')
  jq -r --arg t "$t" --arg x "$x" --arg pre "${BRANCH_PREFIX:-}" --arg slugre "$re" \
    "$TICKET_OPEN_PRS_JQ"'.[] | select((.number | tostring) != $x) | select(names_ticket($t; $pre; $slugre)) | .number' \
    <<<"$_TICKET_OPEN_PRS" 2>/dev/null
}
