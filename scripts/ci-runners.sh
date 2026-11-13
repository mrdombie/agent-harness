#!/usr/bin/env bash
# ci-runners.sh — is any of the repo's self-hosted CI runners online? Read once a tick.
#
#   sourced by coordinator-env.sh (needs its swarm_gh, REPO_SLUG)
#   ci_runners_state          online | none | offline | unread
#
#   online   at least one self-hosted runner is online
#   none     the repo has no self-hosted runners (hosted CI): nothing to wait for
#   offline  it has runners and every one is offline: no check can run, so no red is the PR's
#   unread   the list could not be read: offline cannot be ruled out, and stderr names the repo and why
#
# Nothing is kept on disk between calls: every process sources this, and a shared file one
# of them clears under another turns that one's read into unread.
[ -z "${_CI_RUNNERS_SH:-}" ] || return 0
_CI_RUNNERS_SH=1

ci_runners_state() {
  local out st err
  err=$(mktemp "${TMPDIR:-/tmp}/ci-runners.XXXXXX") || err=/dev/null
  # Pages concatenated: count across all of them.
  if out=$(swarm_gh api "repos/${REPO_SLUG:?}/actions/runners?per_page=100" --paginate 2>"$err") \
    && st=$(jq -rs '
        if length == 0 or any(.[]; type != "object" or (.runners | type) != "array") then error("unread") else . end
        | [.[].runners[]] as $r
        | if ($r | length) == 0 then "none"
          elif any($r[]; .status == "online") then "online"
          else "offline" end' <<<"$out" 2>/dev/null) && [ -n "$st" ]; then
    :
  else
    st=unread
    printf 'ci-runners: the runner list of %s could not be read%s\n' "$REPO_SLUG" \
      "$(tr '\n' ' ' <"$err" 2>/dev/null | cut -c1-200 | sed 's/^ *\(..*\)/: \1/; s/ *$//')" >&2
  fi
  [ "$err" = /dev/null ] || rm -f "$err"
  printf '%s\n' "$st"
}
