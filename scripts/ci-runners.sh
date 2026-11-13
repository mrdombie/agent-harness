#!/usr/bin/env bash
# ci-runners.sh — is any of the repo's self-hosted CI runners online? Read once a tick.
#
#   . scripts/ci-runners.sh   (after coordinator-env.sh: swarm_gh, REPO_SLUG, COORD_DIR)
#   ci_runners_state          online | none | offline | unread
#
#   online   at least one self-hosted runner is online
#   none     the repo has no self-hosted runners (hosted CI): nothing to wait for
#   offline  it has runners and every one is offline: no check can run, so no red is the PR's
#   unread   the list could not be read: offline cannot be ruled out
#
# The answer is kept per repo for the tick (CI_RUNNERS_CACHE, emptied when this is sourced),
# so the pass over each repo makes one paged read.
[ -z "${_CI_RUNNERS_SH:-}" ] || return 0
_CI_RUNNERS_SH=1

CI_RUNNERS_CACHE="${COORD_DIR:?}/ci-runners.$(coord_mode)"
rm -rf "$CI_RUNNERS_CACHE" 2>/dev/null; mkdir -p "$CI_RUNNERS_CACHE" 2>/dev/null

ci_runners_state() {
  local f out st
  f="$CI_RUNNERS_CACHE/$(printf '%s' "${REPO_SLUG:?}" | tr -c 'A-Za-z0-9._-' '_')"
  if [ -s "$f" ]; then cat "$f"; return 0; fi
  # Pages concatenated: count across all of them.
  if out=$(swarm_gh api "repos/$REPO_SLUG/actions/runners?per_page=100" --paginate 2>/dev/null) \
    && st=$(jq -rs '
        if length == 0 or any(.[]; type != "object" or (.runners | type) != "array") then error("unread") else . end
        | [.[].runners[]] as $r
        | if ($r | length) == 0 then "none"
          elif any($r[]; .status == "online") then "online"
          else "offline" end' <<<"$out" 2>/dev/null) && [ -n "$st" ]; then
    :
  else
    st=unread
  fi
  printf '%s\n' "$st" > "$f" 2>/dev/null
  printf '%s\n' "$st"
}
