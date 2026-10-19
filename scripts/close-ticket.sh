#!/usr/bin/env bash
# close-ticket.sh <ticket> <pr> — /finish's close-out once a ticket's PR merged:
# close the ticket, unless it is a polish list.
#
# A polish list (labels.polishList, default polish-list) is not done because one PR
# that fixed some of it merged. It closes only when nothing is left on it, which
# polish-list.sh sweep decides; here it goes back to ready with a comment.
#
# Prints "closed #n" or "polish list #n left open". The label read goes through
# gh_call (the shared backoff) and is tried CLOSE_TICKET_TRIES times (default 3),
# CLOSE_TICKET_RETRY_SEC apart (default 10): one refused read must not leave an
# ordinary shipped ticket open. Unread after that, it is not closed: closing a list
# by mistake buries every item still on it.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-batch.sh" || exit 1
TRIES="${CLOSE_TICKET_TRIES:-3}"; case "$TRIES" in ''|0|*[!0-9]*) TRIES=3 ;; esac
DELAY="${CLOSE_TICKET_RETRY_SEC:-10}"; case "$DELAY" in ''|*[!0-9]*) DELAY=10 ;; esac
T="${1:?usage: close-ticket.sh <ticket> <pr>}"; PR="${2:?usage: close-ticket.sh <ticket> <pr>}"
T="${T#\#}"; PR="${PR#\#}"

i=0; labels=""
until labels=$(gh_call issue view "$T" --repo "$REPO_SLUG" --json labels -q '.labels[].name' 2>/dev/null); do
  i=$((i+1))
  [ "$i" -lt "$TRIES" ] || { echo "close-ticket: could not read #$T's labels after $TRIES tries — not closed; run it again" >&2; exit 1; }
  sleep "$DELAY"
done
if printf '%s\n' "$labels" | grep -qxF -- "$LBL_POLISH_LIST"; then
  drop=""
  while IFS= read -r l; do
    case "$l" in "$STATUS_PREFIX"*) [ "$l" = "$LBL_READY" ] || drop="$drop --remove-label $l" ;; esac
  done <<<"$labels"
  # shellcheck disable=SC2086  # $drop is a built flag list, deliberately split
  gh issue edit "$T" --repo "$REPO_SLUG" $drop --add-label "$LBL_READY" >/dev/null 2>&1
  gh issue comment "$T" --repo "$REPO_SLUG" --body "PR #$PR merged and fixed part of this polish list. The list closes on its own once every item is ticked; until then its free items wait for the next ticket for this screen." >/dev/null 2>&1
  echo "polish list #$T left open"; exit 0
fi
gh issue close "$T" --repo "$REPO_SLUG" --reason completed >/dev/null 2>&1 \
  || { echo "close-ticket: could not close #$T" >&2; exit 1; }
echo "closed #$T"
