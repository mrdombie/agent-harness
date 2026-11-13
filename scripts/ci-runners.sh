#!/usr/bin/env bash
# ci-runners.sh — is any self-hosted CI runner, the repo's or its org's, online? Read once a tick.
#
#   sourced by coordinator-env.sh (needs its swarm_gh, REPO_SLUG, COORD_DIR, coord_mode)
#   ci_runners_state          online | none | offline | unread
#
#   online   at least one self-hosted runner is online
#   none     the repo has no self-hosted runners (hosted CI): nothing to wait for
#   offline  it has runners and every one is offline: no check can run, so no red is the PR's
#   unread   the list could not be read: offline cannot be ruled out, and stderr names the repo and why
#
# A list GitHub refuses (403: a token without admin scope; 404) reads as none, said once
# (CI_RUNNERS_REFUSED): held as unread, it would stop every rebuild on a hosted-CI repo for ever.
# Nothing else is kept on disk between calls: every process sources this, and a shared file
# one of them clears under another turns that one's read into unread.
[ -z "${_CI_RUNNERS_SH:-}" ] || return 0
_CI_RUNNERS_SH=1

CI_RUNNERS_REFUSED="${COORD_DIR:?}/ci-runners-refused.$(coord_mode).tsv"   # endpoint whose refusal was said

# _ci_runners_read <endpoint> — its runners as one JSON array. 0 read, 2 refused, 1 failed;
# stderr says why when it is not read.
_ci_runners_read() {
  local ep="$1" out err rc=0 r code who
  who="${ep%/actions/runners}"; case "$who" in repos/*) who="${who#repos/}" ;; orgs/*) who="the org ${who#orgs/}" ;; esac
  err=$(mktemp "${TMPDIR:-/tmp}/ci-runners.XXXXXX") || err=/dev/null
  # Pages concatenated: count across all of them.
  if out=$(swarm_gh api "$ep?per_page=100" --paginate 2>"$err") \
    && r=$(jq -cs 'if length == 0 or any(.[]; type != "object" or (.runners | type) != "array") then error("unread")
                   else [.[].runners[]] end' <<<"$out" 2>/dev/null) && [ -n "$r" ]; then
    printf '%s\n' "$r"
    awk -v e="$ep" '$0 != e' "$CI_RUNNERS_REFUSED" > "$CI_RUNNERS_REFUSED.$$" 2>/dev/null \
      && mv -f "$CI_RUNNERS_REFUSED.$$" "$CI_RUNNERS_REFUSED" 2>/dev/null; rm -f "$CI_RUNNERS_REFUSED.$$" 2>/dev/null
  else
    r=$(tr '\n' ' ' <"$err" 2>/dev/null | cut -c1-200 | sed 's/ *$//')
    code=$(printf '%s' "$r" | sed -nE 's/.*HTTP (40[34]).*/\1/p')
    if [ -n "$code" ]; then
      rc=2
      grep -qxF -- "$ep" "$CI_RUNNERS_REFUSED" 2>/dev/null || {
        printf '%s\n' "$ep" >> "$CI_RUNNERS_REFUSED" 2>/dev/null
        printf 'ci-runners: the runner list of %s is refused (HTTP %s) — counted as no self-hosted runners; give the token Administration read to hold rebuilds while CI is down\n' \
          "$who" "$code" >&2
      }
    else
      rc=1
      printf 'ci-runners: the runner list of %s could not be read%s\n' "$who" "${r:+: $r}" >&2
    fi
  fi
  [ "$err" = /dev/null ] || rm -f "$err"
  return "$rc"
}

ci_runners_state() {
  local ep r all='[]' failed=""
  # The repo's own runners and its org's: an org-wide outage is the usual shared setup.
  for ep in "repos/${REPO_SLUG:?}/actions/runners" "orgs/${REPO_SLUG%%/*}/actions/runners"; do
    if r=$(_ci_runners_read "$ep"); then all=$(jq -c --argjson r "$r" '. + $r' <<<"$all")
    elif [ $? -eq 1 ]; then failed=1; fi
  done
  # One online is enough; otherwise a list not read could hold the one that is.
  if jq -e 'any(.[]; .status == "online")' >/dev/null <<<"$all"; then echo online
  elif [ -n "$failed" ]; then echo unread
  elif jq -e 'length == 0' >/dev/null <<<"$all"; then echo none
  else echo offline; fi
}
