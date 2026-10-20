#!/usr/bin/env bash
# pr-closes.sh — a ticket's pull request names its ticket in its body, always.
#
#   . scripts/pr-closes.sh                    the functions, for a step that writes a body
#   pr-closes.sh ensure <pr> <ticket>         add the line to an open PR's body if it lacks it
#
#   pr_closes_names <ticket>        0 when the body on stdin already names the ticket:
#                                   Closes/Fixes/Resolves (any tense), Refs or Part of #<ticket>
#   pr_closes_ensure <ticket> <w>   the body on stdin, with "<w> #<ticket>" appended when
#                                   it does not already name the ticket (w: Closes or Refs)
#   PR_CLOSES_JQ                    the same closing-keyword test as a jq regex prefix,
#                                   for a reader that finds a ticket's PR by its body
#
# A PR whose body does not name its ticket is invisible to every reader that finds a
# ticket's PR by GitHub's closing references, and those are empty on a PR into a
# non-default base even when the body says "Closes". A repair parked "no open pull
# request" beside one because of it.
PR_CLOSES_KEYWORDS='close[sd]?|fix(e[sd])?|resolve[sd]?'
PR_CLOSES_JQ='(^|[^A-Za-z0-9_])(close[sd]?|fix(e[sd])?|resolve[sd]?):?[ \t]+#'

pr_closes_names() { # <ticket>
  local t="${1#\#}"
  grep -qiE "(^|[^A-Za-z0-9_])(${PR_CLOSES_KEYWORDS}|refs|part of):?[[:space:]]+#${t}([^0-9]|\$)"
}

pr_closes_ensure() { # <ticket> <word>
  local t="${1#\#}" w="${2:-Closes}" body
  body=$(cat; printf x); body=${body%x}
  if printf '%s' "$body" | pr_closes_names "$t"; then printf '%s' "$body"; return 0; fi
  body=${body%$'\n'}
  if [ -n "$body" ]; then printf '%s\n\n%s #%s\n' "$body" "$w" "$t"; else printf '%s #%s\n' "$w" "$t"; fi
}

# The CLI: read the PR's body and the ticket's labels, and write the line if it is
# missing. A polish list is named with Refs: it closes only when nothing is left on it.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh" || exit 1
  [ "${1:-}" = ensure ] || { echo "usage: $(basename "$0") ensure <pr> <ticket>" >&2; exit 2; }
  pr="${2:?usage: pr-closes.sh ensure <pr> <ticket>}"; t="${3:?usage: pr-closes.sh ensure <pr> <ticket>}"
  pr="${pr#\#}"; t="${t#\#}"
  body=$(gh pr view "$pr" --repo "$REPO_SLUG" --json body -q .body 2>/dev/null) \
    || { echo "pr-closes: could not read PR #$pr's body — nothing written; run it again" >&2; exit 1; }
  word=Closes
  labels=$(gh issue view "$t" --repo "$REPO_SLUG" --json labels -q '.labels[].name' 2>/dev/null) \
    || { echo "pr-closes: could not read #$t's labels — nothing written; run it again" >&2; exit 1; }
  printf '%s\n' "$labels" | grep -qxF -- "${LBL_POLISH_LIST:-polish-list}" && word=Refs
  new=$(printf '%s' "$body" | pr_closes_ensure "$t" "$word")
  if [ "$new" = "$body" ] || [ "$new" = "$body"$'\n' ]; then echo "PR #$pr already names #$t"; exit 0; fi
  gh pr edit "$pr" --repo "$REPO_SLUG" --body "$new" >/dev/null 2>&1 \
    || { echo "pr-closes: could not write PR #$pr's body" >&2; exit 1; }
  echo "PR #$pr now says $word #$t"
fi
