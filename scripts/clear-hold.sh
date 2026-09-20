#!/usr/bin/env bash
# clear-hold.sh <pr> — the operator has said "approve <pr>". Record who decided
# and clear the hold the way the gate accepts it:
#   - a peer's PR, and the operator is in HUMAN_APPROVERS → an APPROVED review.
#     The gate sees it and removes the label itself; the review IS the record.
#   - otherwise (the operator's own PR, or not an approver) → a timeline comment,
#     then the label off the issue, then off the PR — PR last, because that
#     removal wakes the gate, which re-reads everything.
# One motion for /needsme and /bug, so the next fix lands in both.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh" || exit 1
PR="${1:?usage: clear-hold.sh <pr-number>}"; REPO="${GH_REPO:-$REPO_SLUG}"
OPERATOR=$(toolkit_login); TODAY=$(date -u +%Y-%m-%d)
AUTHOR=$(gh pr view "$PR" --repo "$REPO" --json author --jq .author.login) || exit 1

if [ "$AUTHOR" != "$OPERATOR" ] && toolkit_is_approver "$OPERATOR"; then
  gh pr review "$PR" --repo "$REPO" --approve \
    --body "Approved by @$OPERATOR in the agent window on $TODAY — the decision is theirs, the keystroke is mine." \
    && echo "approved #$PR as @$OPERATOR — the gate clears the label on this review" || exit 1
  exit 0
fi

# Comment FIRST: it must survive a race with automerge, and it is the only
# record of which human decided when every click comes from the same token.
gh pr comment "$PR" --repo "$REPO" \
  --body "Approved by @$OPERATOR in the agent window on $TODAY. \`needs:human-approval\` cleared on their instruction — the decision is theirs, the keystroke is mine." >/dev/null || exit 1
ISSUE=$(gh pr view "$PR" --repo "$REPO" --json headRefName --jq .headRefName | sed -n 's|^sh-\([0-9]\{1,\}\)/.*|\1|p')
[ -n "$ISSUE" ] && gh issue edit "$ISSUE" --repo "$REPO" --remove-label "needs:human-approval" >/dev/null 2>&1
gh pr edit "$PR" --repo "$REPO" --remove-label "needs:human-approval" || exit 1
echo "cleared #$PR${ISSUE:+ and issue #$ISSUE} as @$OPERATOR — the gate re-runs on the unlabeled event"
