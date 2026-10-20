#!/usr/bin/env bash
# evidence-plan.sh — where a branch's capture plan lives: the one definition; source it.
#
# CI files a pull request's evidence under <evidence.dir>/<key>/, and reads the plan
# at <evidence.dir>/<key>/plan.json. The key is the ticket of a <branchPrefix>NNNN/…
# branch, else the pull request's number (the consuming project's evidence locator:
# `sh-([0-9]+)/` off the head ref, falling back to the PR). The harness's own reading of
# a branch's ticket is wider (scripts/branch-ticket.sh: 5654/slug is ticket 5654), and
# the plan written under that number on such a branch was never seen by CI.
#
#   evidence_plan_key <branch> <pr>    prints the key, or nothing (no prefix match, no PR)
#   evidence-plan.sh key <branch> <pr> the same, as a command
# Both read $BRANCH_PREFIX.

evidence_plan_key() { # <branch> <pr>
  local b="${1:-}" pr="${2:-}" p="${BRANCH_PREFIX:-}" rest n=""
  if [ -n "$p" ] && [ "${b#"$p"}" != "$b" ]; then
    rest=${b#"$p"}
    n=$(printf '%s\n' "$rest" | sed -n 's|^\([0-9]\{1,\}\)/.*|\1|p')
  fi
  if [ -z "$n" ]; then
    case "$pr" in ''|*[!0-9]*) ;; *) n=$pr ;; esac
  fi
  printf '%s' "$n"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    key) evidence_plan_key "${2:-}" "${3:-}"; echo ;;
    *) echo "usage: evidence-plan.sh key <branch> <pr>" >&2; exit 2 ;;
  esac
fi
