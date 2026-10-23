#!/usr/bin/env bash
# driver-draft.sh — a parked run's pull request is the driver's own draft: never armed,
# never ready, and marked so a person's stop can tell it from a person's draft.
#
#   driver-draft.sh park <pr>   disarm auto-merge, convert to draft, mark it the driver's
#       0  the PR is a draft with auto-merge off (or is not open); one line on stdout
#       1  it could not be made so; the reason on stdout
#   . driver-draft.sh           sourced: DRIVER_DRAFT_MARK and DRIVER_DRAFT_JQ
#
# THE MARK. person-stop.sh reads a PR whose last convert_to_draft is a person's login as
# a person saying "not yet", and the driver and the PM can share one token. So the driver
# posts a PR comment carrying DRIVER_DRAFT_MARK right after its own conversion, and only
# when it made that conversion: a draft whose last conversion has a mark at or after it
# is the driver's, which its own resume readies again. A person's later conversion is a
# newer event than every mark, so it still stops the machine.
#
# 23 Oct: a run titled "parked — …" merged under merge-first with auto-merge still armed;
# its batch ticket closed with 5 of 6 children half done.

DRIVER_DRAFT_MARK='<!-- harness:driver-draft -->'
# def driver_draft($c; $pc): $c is the last convert_to_draft event, $pc the PR's comments.
DRIVER_DRAFT_JQ='
  def driver_draft($c; $pc): $c != null
    and any($pc[]?; ((.body // "") | contains("<!-- harness:driver-draft -->"))
                    and ((.created_at // "") >= ($c.created_at // "~")));
'
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" || exit 1
. "$SELF_DIR/gh-batch.sh" || exit 1
export GH_CALLER="${GH_CALLER:-driver-draft}"
REPO="${GH_REPO:-$REPO_SLUG}"

usage() { sed -n '5,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

pr_state() { # <pr> — "<state> <draft> <armed>" from a fresh read, or exit 1
  gh_read "pull request #$1" api "repos/$REPO/pulls/$1" \
    --jq '"\(.state // "") \(.draft // false) \(.auto_merge != null)"'
}

park() {
  local pr="${1:-}" s st draft armed did=""
  case "$pr" in ''|*[!0-9]*) usage ;; esac
  s=$(pr_state "$pr") || { echo "PR #$pr could not be read, so whether it is still armed is unknown"; return 1; }
  read -r st draft armed <<<"$s"
  [ "$st" = open ] || { echo "PR #$pr is $st — nothing to disarm"; return 0; }
  if [ "$armed" = true ]; then
    gh_call pr merge "$pr" --repo "$REPO" --disable-auto >/dev/null 2>&1 && did="auto-merge disarmed"
  fi
  if [ "$draft" != true ] && gh_call pr ready "$pr" --repo "$REPO" --undo >/dev/null 2>&1; then
    did="${did:+$did, }converted to draft"
    gh_call pr comment "$pr" --repo "$REPO" --body "**Parked** by the driver: this pull request is back to draft with auto-merge off, because the run stopped before it finished. The driver readies it again itself when the run resumes. $DRIVER_DRAFT_MARK" >/dev/null 2>&1 \
      || did="$did (the driver's mark could not be posted, so it reads as a person's draft)"
  fi
  s=$(pr_state "$pr") || { echo "PR #$pr could not be read back after ${did:-nothing}, so whether it is still armed is unknown"; return 1; }
  read -r st draft armed <<<"$s"
  if [ "$st" = open ] && { [ "$draft" != true ] || [ "$armed" = true ]; }; then
    echo "PR #$pr is still $([ "$draft" = true ] && echo "a draft" || echo ready) with auto-merge $([ "$armed" = true ] && echo armed || echo off) — it could land by itself"
    return 1
  fi
  echo "PR #$pr is a draft with auto-merge off${did:+ ($did)}"
}

case "${1:-}" in
  park) shift; park "$@" ;;
  *) usage ;;
esac
