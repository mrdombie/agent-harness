#!/usr/bin/env bash
# pm-answer.sh — carry out a PM answer the judge reached, so the question does not wait
# for the PM to do by hand what was already decided.
#
#   pm-answer.sh <verdict.json> [--event-ticket <n>]
#
# The verdict is the judge's answer to ONE ticket parked on the PM (labels.pmDecision):
#   {"ticket": 1010, "answer": "<the answer, in plain words>",
#    "then": "blocked" | "ready",
#    "child": {"title": "...", "body": "...", "labels": ["type:chore"]},   optional
#    "blockedOn": [1009]}                                                 optional
# Carried out in this order, each step only when the one before landed:
#   1. the child ticket is filed, when there is one: ready, with the parent's labels except
#      a status, a hold and any family (the text before ":") the verdict's labels name;
#   2. the answer goes on the parent as "**PM answer:** …", and when it waits, the line
#      "Blocked until #child, #… merge." that the unblocker (unblock-waiting.sh) reads;
#   3. the parent is set blocked (it waits on the child or blockedOn) or ready, and the PM
#      label comes off in the same edit;
#   4. the child, and a ready parent, go on the coordinator's queue first at their priority.
# Never on an owner's item: a ticket wearing labels.ownerDecision or the hold label, one
# not wearing the PM label, or one closed is refused (exit 3) with nothing touched.
# A step that fails leaves the PM label on, puts ONE comment on the parent saying what did
# not happen, and tells the PM's channel (coordinator-notify.sh, agent class). Exit 1.
# Exit: 0 carried out · 1 a step failed · 2 a verdict that cannot be read · 3 refused.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/coordinator-env.sh" || exit 1
declare -F issue_status_set >/dev/null 2>&1 || . "$SELF_DIR/issue-status.sh" || exit 1
NOTIFY="${PM_ANSWER_NOTIFY:-$SELF_DIR/coordinator-notify.sh}"
QUEUE="${PM_ANSWER_QUEUE:-$SELF_DIR/coordinator-queue.sh}"
SLUG="${ISSUE_SLUG:-$REPO_SLUG}"

V="${1:-}"; shift || true
EVT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --event-ticket) EVT="${2:-}"; shift 2 ;;
    *) echo "pm-answer: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -f "$V" ] && jq -e 'type == "object"' "$V" >/dev/null 2>&1 || { echo "pm-answer: no verdict to read at '$V'" >&2; exit 2; }
T=$(jq -r '.ticket // "" | tostring | ltrimstr("#")' "$V")
ANSWER=$(jq -r '.answer // ""' "$V" | tr '\t' ' ')
THEN=$(jq -r '.then // ""' "$V")
CTITLE=$(jq -r '.child.title // ""' "$V")
WAITS=$(jq -r '[.blockedOn // [] | .[] | tostring | ltrimstr("#") | select(test("^[0-9]+$"))] | join(" ")' "$V")
case "$T" in ''|*[!0-9]*) echo "pm-answer: the verdict names no ticket" >&2; exit 2 ;; esac
[ -n "$ANSWER" ] || { echo "pm-answer: the verdict for #$T carries no answer" >&2; exit 2; }
case "$THEN" in blocked|ready) ;; *) echo "pm-answer: then must be blocked or ready, got '$THEN'" >&2; exit 2 ;; esac
if [ "$THEN" = blocked ] && [ -z "$CTITLE$WAITS" ]; then
  echo "pm-answer: #$T is to wait, but the verdict names no child and no ticket to wait on" >&2; exit 2
fi
if [ -n "$EVT" ] && [ "$EVT" != "$T" ]; then
  echo "pm-answer: refused — the verdict is for #$T but the event was #$EVT" >&2; exit 3
fi

# The parent, read fresh: the label is the truth for whose question it is.
META=$(swarm_gh issue view "$T" --repo "$SLUG" --json state,labels -q '.state + "\t" + ([.labels[].name] | join(","))' 2>/dev/null) \
  || { echo "pm-answer: #$T could not be read — nothing done" >&2; exit 1; }
STATE="${META%%$'\t'*}"; LABELS=",${META#*$'\t'},"
[ "$STATE" = OPEN ] || { echo "pm-answer: refused — #$T is not open" >&2; exit 3; }
for l in "${LBL_OWNER_DECISION:-}" "${HOLD_LABEL:-}"; do
  [ -n "$l" ] || continue
  case "$LABELS" in *",$l,"*) echo "pm-answer: refused — #$T wears $l: the owner's, never acted on" >&2; exit 3 ;; esac
done
case "$LABELS" in *",$LBL_PM_DECISION,"*) ;; *) echo "pm-answer: refused — #$T does not wear $LBL_PM_DECISION, so it is no PM question" >&2; exit 3 ;; esac

CHILD=""
fail() { # <what did not happen> — the label stays, one comment, the PM's channel
  local why="$1" filed=""
  [ -n "$CHILD" ] && filed=" The child ticket #$CHILD was filed."
  swarm_gh issue comment "$T" --repo "$SLUG" --body "**PM answer not carried out:** $why.$filed \`$LBL_PM_DECISION\` stays on, so the PM carries it out.

The answer reached: $ANSWER
<!-- pm-answer: failed -->" >/dev/null 2>&1 || true
  bash "$NOTIFY" --class agent "pm-answer-failed:$T:$(swarm_now)" "#$T: the PM answer was reached but not carried out ($why); $LBL_PM_DECISION stays on." >/dev/null 2>&1 || true
  echo "pm-answer: #$T — $why; $LBL_PM_DECISION left on" >&2
  exit 1
}

child_labels() { # the parent's, less a status, a hold and a family the verdict names; then its own
  local l fam
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case "$l" in "$sp"*) continue ;; esac
    [ "$l" = "${HOLD_LABEL:-}" ] || [ "$l" = "${LBL_OWNER_DECISION:-}" ] || [ "$l" = "${LBL_NEEDS_HUMAN:-}" ] && continue
    fam="${l%%:*}"
    if [ "$fam" != "$l" ] && printf '%s\n' "$own" | awk -v f="$fam:" 'index($0, f) == 1 { x = 1 } END { exit !x }'; then continue; fi
    printf '%s\n' "$l"
  done <<< "${LABELS//,/$'\n'}"
  printf '%s\n' "$own" "$LBL_READY"
}

# 1. The child: ready, in the parent's families unless the verdict names its own.
if [ -n "$CTITLE" ]; then
  own=$(jq -r '.child.labels // [] | .[]' "$V")
  sp=$(issue_status_prefix)
  args=()
  while IFS= read -r l; do [ -n "$l" ] && args+=(--label "$l"); done < <(child_labels | awk 'NF && !s[$0]++')
  body="$(jq -r '.child.body // ""' "$V")

Lands before #$T: #$T is blocked until this merges."
  url=$(swarm_gh issue create --repo "$SLUG" --title "$CTITLE" --body "$body" "${args[@]}" 2>/dev/null) \
    || fail "the child ticket could not be filed"
  CHILD=$(printf '%s' "$url" | tr -d '[:space:]' | sed -n 's|.*/issues/\([0-9][0-9]*\)$|\1|p')
  [ -n "$CHILD" ] || fail "the child ticket's number could not be read from '$url'"
  WAITS="$CHILD${WAITS:+ $WAITS}"
fi

# 2. The answer, with the wait line the unblocker reads.
note="**PM answer:** $ANSWER"
if [ "$THEN" = blocked ]; then
  list=$(printf '#%s\n' $WAITS | awk '!s[$0]++' | paste -sd, - | sed 's/,/, /g')
  [ "${list#*,}" = "$list" ] && verb=merges || verb=merge
  note="$note

Blocked until $list $verb."
fi
swarm_gh issue comment "$T" --repo "$SLUG" --body "$note
<!-- harness:machine -->" >/dev/null 2>&1 || fail "the answer could not be commented on #$T"

# 3. The status, and the PM label off in the same edit.
if [ "$THEN" = blocked ]; then want="$LBL_BLOCKED"; else want="$LBL_READY"; fi
issue_status_set "$T" "$want" --drop "$LBL_PM_DECISION" --repo "$SLUG" >/dev/null 2>&1 \
  || fail "#$T could not be set $want"

# 4. The queue: a failure here is not lost, since the next seed finds each ticket ready.
if [ -n "$CHILD" ]; then
  bash "$QUEUE" add "$CHILD" --first --note "Filed by the PM answer on #$T: $ANSWER" >/dev/null 2>&1 \
    || echo "pm-answer: #$CHILD could not be queued — the next seed finds it ready"
fi
if [ "$THEN" = ready ]; then
  bash "$QUEUE" add "$T" --first --note "PM answered: $ANSWER. Build on that answer; do not ask it again." >/dev/null 2>&1 \
    || echo "pm-answer: #$T could not be queued — the next seed finds it ready"
fi
coord_act_log pm-answer "$T" "$ANSWER"
if [ "$THEN" = blocked ]; then echo "pm-answer: #$T answered and blocked until #${WAITS// /, #}${CHILD:+ (child #$CHILD filed)}"
else echo "pm-answer: #$T answered and ready"; fi
exit 0
