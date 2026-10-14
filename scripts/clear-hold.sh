#!/usr/bin/env bash
# clear-hold.sh <pr> [--reason "<why>"] — the operator has said "approve <pr>",
# or the merge lane is carrying an approval through a develop-only update.
# Record who decided and why, and clear the hold the way the gate accepts it:
#   - a peer's PR, and the operator is in HUMAN_APPROVERS → an APPROVED review.
#     The gate sees it and removes the label itself; the review IS the record.
#   - otherwise (the operator's own PR, or not an approver) → a timeline comment,
#     then the label off the issue, then off the PR — PR last, because that
#     removal wakes the gate, which re-reads everything.
# The label is labels.hold and the issue comes from branchPrefix, both from harness.json.
# One motion for /needsme, /bug and the merge lane, so the next fix lands in all three.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh" || exit 1
PR="${1:?usage: clear-hold.sh <pr-number> [--reason \"<why>\"]}"; shift
REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reason) REASON="${2:?--reason needs text}"; shift 2 ;;
    *) echo "clear-hold: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
REPO="${GH_REPO:-$REPO_SLUG}"
OPERATOR=$(toolkit_login); TODAY=$(date -u +%Y-%m-%d)
AUTHOR=$(gh pr view "$PR" --repo "$REPO" --json author --jq .author.login) || exit 1
if [ -n "$REASON" ]; then WHY="the earlier approval carried forward: $REASON"
else WHY="on their instruction"; fi

if [ "$AUTHOR" != "$OPERATOR" ] && toolkit_is_approver "$OPERATOR"; then
  gh pr review "$PR" --repo "$REPO" --approve \
    --body "Approved by @$OPERATOR in the agent window on $TODAY, $WHY — the decision is theirs, the keystroke is mine." \
    && echo "approved #$PR as @$OPERATOR — the gate clears the label on this review" || exit 1
  exit 0
fi

# Comment FIRST: it must survive a race with automerge, and it is the only
# record of which human decided when every click comes from the same token.
gh pr comment "$PR" --repo "$REPO" \
  --body "Approved by @$OPERATOR in the agent window on $TODAY. \`$HOLD_LABEL\` cleared $WHY — the decision is theirs, the keystroke is mine." >/dev/null || exit 1
ISSUE=$(gh pr view "$PR" --repo "$REPO" --json headRefName --jq .headRefName \
  | awk -v p="$BRANCH_PREFIX" 'index($0, p) == 1 { s = substr($0, length(p) + 1); if (match(s, /^[0-9]+/)) print substr(s, 1, RLENGTH) }')
[ -n "$ISSUE" ] && gh issue edit "$ISSUE" --repo "$REPO" --remove-label "$HOLD_LABEL" >/dev/null 2>&1
gh pr edit "$PR" --repo "$REPO" --remove-label "$HOLD_LABEL" || exit 1
echo "cleared #$PR${ISSUE:+ and issue #$ISSUE} as @$OPERATOR — the gate re-runs on the unlabeled event"
