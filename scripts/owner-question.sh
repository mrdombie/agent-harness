#!/usr/bin/env bash
# owner-question.sh — a question only the owner can answer, from a run with no
# one to ask, and the answer back to the ticket.
#
#   owner-question.sh ask <ticket> <slug> "<the question, its options in plain words>"
#        needs-you.md gets it under decision:<ticket>:<slug> (coordinator-notify, owner
#        class), the ticket gets labels.ownerDecision and a comment carrying the question.
#        Until it is answered no spawner takes the ticket.
#   owner-question.sh answer <decision-key> "<the owner's answer>"
#        the label comes off, the answer is commented on the ticket, and the ticket goes
#        back on the coordinator's queue at the front with the answer in its note.
#   owner-question.sh waiting <ticket>
#        exit 0, printing the key, while a decision on it is unanswered.
#
# A builder in `claude -p` has no question tool: before this, its question went into
# its final message, nothing read it, and the ticket was respawned to ask it again.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/coordinator-env.sh" || exit 1
NOTIFY="$SELF_DIR/coordinator-notify.sh"
QUEUE="$SELF_DIR/coordinator-queue.sh"
ANSWERS="$COORD_DIR/answers.tsv"

usage() { sed -n '4,14p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

ask() { # <ticket> <slug> <question>
  local t="${1:-}" slug="${2:-}" q="${3:-}" key rc=0
  num "$t" || usage; [ -n "$q" ] || usage
  slug=$(printf '%s' "$slug" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-40)
  [ -n "$slug" ] || slug=question
  key="decision:$t:$slug"
  # A key answered once is never written again, so a second question takes a fresh one.
  local seen="$COORD_DIR/notified.did.keys" i=1
  if ! grep '^- \[ \] ' "$COORD_NEEDS_YOU" 2>/dev/null | grep -qF -- "<!-- key:$key -->"; then
    while grep -qxF -- "$key" "$seen" 2>/dev/null; do i=$((i+1)); key="decision:$t:$slug-$i"; done
  fi
  # The builder's question is real whatever mode the coordinator runs in.
  COORDINATOR_SHADOW=0 bash "$NOTIFY" --class owner "$key" "#$t: $q" || { echo "owner-question: could not write $key to needs-you.md" >&2; rc=1; }
  swarm_gh label create "$LBL_OWNER_DECISION" --repo "$REPO_SLUG" --color D93F0B \
    --description "Waiting on the owner's answer; no agent takes it" >/dev/null 2>&1 || true
  swarm_gh issue edit "$t" --repo "$REPO_SLUG" --add-label "$LBL_OWNER_DECISION" >/dev/null 2>&1 \
    || { echo "owner-question: could not label #$t $LBL_OWNER_DECISION" >&2; rc=1; }
  swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "**Waiting on the owner** (\`$key\`).

$q

The question is in the owner's channel. No agent takes this ticket until it is answered; the answer comes back here and the ticket goes back on the queue." >/dev/null 2>&1 || true
  [ "$rc" = 0 ] && echo "asked: $key — #$t waits on the answer"
  return "$rc"
}

answer() { # <key> <answer>
  local key="${1:-}" a="${2:-}" t cls n rc=0 note
  case "$key" in decision:*:*) ;; *) echo "owner-question: '$key' is not a decision key" >&2; return 2 ;; esac
  [ -n "$a" ] || usage
  t=${key#decision:}; t=${t%%:*}
  num "$t" || { echo "owner-question: no ticket in '$key'" >&2; return 2; }
  a=$(printf '%s' "$a" | tr '\n\t' '  ')
  # Kept first: whatever below fails, the answer is not lost.
  printf '%s\t%s\t%s\n' "$(swarm_stamp)" "$key" "$a" >> "$ANSWERS"
  swarm_gh issue edit "$t" --repo "$REPO_SLUG" --remove-label "$LBL_OWNER_DECISION" >/dev/null 2>&1 \
    || { echo "owner-question: could not take $LBL_OWNER_DECISION off #$t" >&2; rc=1; }
  swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "**The owner answered** (\`$key\`): $a" >/dev/null 2>&1 \
    || { echo "owner-question: could not comment the answer on #$t" >&2; rc=1; }
  cls=new
  n=$(swarm_gh pr list --repo "$REPO_SLUG" --state open --search "head:$BRANCH_PREFIX$t" --json number -q length 2>/dev/null)
  [ "${n:-0}" -gt 0 ] 2>/dev/null && cls=repair
  note="The owner answered $key: $a. Build on that answer; do not ask it again."
  bash "$QUEUE" add "$t" --class "$cls" --note "$note" --front >/dev/null 2>&1 \
    || { echo "owner-question: could not put #$t back on the queue" >&2; rc=1; }
  coord_act_log answer "$t" "$key: $a"
  bash "$SELF_DIR/needsme-watch.sh" done "$key" >/dev/null 2>&1 \
    || { echo "owner-question: could not tick $key in needs-you.md" >&2; rc=1; }
  [ "$rc" = 0 ] && echo "answered: $key — #$t back on the queue ($cls)"
  return "$rc"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  ask)     ask "$@" ;;
  answer)  answer "$@" ;;
  waiting) num "${1:-}" || usage; coord_owner_waiting "$1" ;;
  *) usage ;;
esac
