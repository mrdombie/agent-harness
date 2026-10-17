#!/usr/bin/env bash
# clear-hold.sh <pr> [--reason "<why>"] [--sha <head>] — the operator has said "approve <pr>",
# or the merge lane is carrying an approval through a develop-only update.
# Record who decided and why, and clear the hold the way the gate accepts it:
#   - a peer's PR, and the operator is in HUMAN_APPROVERS → an APPROVED review.
#     The gate sees it and removes the label itself; the review IS the record.
#   - otherwise (the operator's own PR, or not an approver) → a timeline comment,
#     then the label off the issue, then off the PR — PR last, because that
#     removal wakes the gate, which re-reads everything.
# --sha is the head the operator was shown (7 to 40 hex). It must still be the
# PR's head, or nothing is cleared: an approval of one head never lands on another.
# Then both records end in an approval-head marker naming it in full, which
# scripts/approval-kept.sh approved-head reads back. Without --sha the hold clears
# with no marker, since the head that was looked at is unknown.
# The label is labels.hold and the issue comes from branchPrefix, both from harness.json.
# One motion for /needsme, /bug and the merge lane, so the next fix lands in all three.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/branch-ticket.sh" || exit 1
PR="${1:?usage: clear-hold.sh <pr-number> [--reason \"<why>\"] [--sha <head>]}"; shift
REASON=""; SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reason) REASON="${2:?--reason needs text}"; shift 2 ;;
    --sha) SHA="${2:?--sha needs a commit}"; shift 2 ;;
    *) echo "clear-hold: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
REPO="${GH_REPO:-$REPO_SLUG}"
OPERATOR=$(toolkit_login); TODAY=$(date -u +%Y-%m-%d)
META=$(gh pr view "$PR" --repo "$REPO" --json author,headRefOid,headRefName) || exit 1
AUTHOR=$(jq -er '.author.login' <<<"$META" 2>/dev/null) || { echo "clear-hold: could not read #$PR's author — nothing cleared" >&2; exit 1; }
HEAD_NOW=$(jq -r '.headRefOid // empty' <<<"$META")
if [ -n "$SHA" ]; then
  printf '%s' "$SHA" | grep -qE '^[0-9a-f]{7,40}$' || { echo "clear-hold: --sha '$SHA' is not a commit — nothing cleared" >&2; exit 2; }
  case "$HEAD_NOW" in
    "$SHA"*) SHA="$HEAD_NOW" ;;
    *) echo "clear-hold: #$PR moved from the ${SHA:0:7} that was approved to ${HEAD_NOW:0:7} — nothing cleared; show the new head and ask again" >&2; exit 1 ;;
  esac
fi
if [ -n "$REASON" ]; then
  REVIEW="@$OPERATOR's earlier approval carried forward on $TODAY: $REASON."
  COMMENT="\`$HOLD_LABEL\` cleared on @$OPERATOR's earlier approval, carried forward on $TODAY: $REASON."
else
  REVIEW="Approved by @$OPERATOR in the agent window on $TODAY — the decision is theirs, the keystroke is mine."
  COMMENT="Approved by @$OPERATOR in the agent window on $TODAY. \`$HOLD_LABEL\` cleared on their instruction — the decision is theirs, the keystroke is mine."
fi
if printf '%s' "$SHA" | grep -qE '^[0-9a-f]{40}$'; then
  MARK=$(bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/approval-kept.sh" marker "$SHA")
  REVIEW="$REVIEW

$MARK"
  COMMENT="$COMMENT

$MARK"
else
  echo "clear-hold: no --sha, so the head that was approved is unknown — clearing #$PR without an approval-head marker" >&2
fi

if [ "$AUTHOR" != "$OPERATOR" ] && toolkit_is_approver "$OPERATOR"; then
  gh pr review "$PR" --repo "$REPO" --approve \
    --body "$REVIEW" \
    && echo "approved #$PR as @$OPERATOR — the gate clears the label on this review" || exit 1
  exit 0
fi

# Comment FIRST: it must survive a race with automerge, and it is the only
# record of which human decided when every click comes from the same token.
gh pr comment "$PR" --repo "$REPO" \
  --body "$COMMENT" >/dev/null || exit 1
ISSUE=$(jq -r '.headRefName // empty' <<<"$META" | branch_tickets | cut -f1)
[ -n "$ISSUE" ] && gh issue edit "$ISSUE" --repo "$REPO" --remove-label "$HOLD_LABEL" >/dev/null 2>&1
gh pr edit "$PR" --repo "$REPO" --remove-label "$HOLD_LABEL" || exit 1
echo "cleared #$PR${ISSUE:+ and issue #$ISSUE} as @$OPERATOR — the gate re-runs on the unlabeled event"
