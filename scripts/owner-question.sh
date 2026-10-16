#!/usr/bin/env bash
# owner-question.sh — a question only the owner can answer, from a run with no
# one to ask, and the answer back to the ticket.
#
#   owner-question.sh ask <ticket> <slug> "<the question, its options in plain words>"
#        the ticket gets labels.ownerDecision, then needs-you.md gets the question under
#        decision:<ticket>:<slug> (coordinator-notify, owner class) and the ticket a comment.
#   owner-question.sh answer <decision-key> "<the owner's answer>"
#        the label comes off, the answer is commented on the ticket, the ticket goes back
#        on the coordinator's queue at the front with the answer in its note, the line is
#        ticked. A step that fails leaves the answer pending and the line open; sync retries.
#   owner-question.sh sync
#        retry every pending answer; then an open decision line whose ticket no longer
#        wears the label was answered elsewhere: tick it and requeue the ticket.
#   owner-question.sh waiting <ticket>
#        exit 0, printing the label, while the ticket wears it.
#
# The label is the one truth for "waiting on the owner": the spawners read it, and a
# needs-you line only says what was asked.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/coordinator-env.sh" || exit 1
NOTIFY="$SELF_DIR/coordinator-notify.sh"
QUEUE="$SELF_DIR/coordinator-queue.sh"
WATCH="$SELF_DIR/needsme-watch.sh"
ANSWERS="$COORD_DIR/answers.tsv"
PENDING="$COORD_DIR/answers.pending"

usage() { sed -n '4,19p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
ticket_of() { local t=${1#decision:}; printf '%s' "${t%%:*}"; }

# The ticket's state and labels, "OPEN label,label"; nothing when it could not be read.
meta() { swarm_gh issue view "$1" --repo "$REPO_SLUG" --json state,labels -q '.state+" "+([.labels[].name]|join(","))' 2>/dev/null; }
wears() { case ",${1#* }," in *",$LBL_OWNER_DECISION,"*) return 0 ;; esac; return 1; }

ask() { # <ticket> <slug> <question>
  local t="${1:-}" slug="${2:-}" q="${3:-}" key
  num "$t" || usage; [ -n "$q" ] || usage
  slug=$(printf '%s' "$slug" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-40)
  [ -n "$slug" ] || slug=question
  key="decision:$t:$slug"
  # A key answered once is never written again, so a second question takes a fresh one.
  local seen="$COORD_DIR/notified.did.keys" i=1
  if ! grep '^- \[ \] ' "$COORD_NEEDS_YOU" 2>/dev/null | grep -qF -- "<!-- key:$key -->"; then
    while grep -qxF -- "$key" "$seen" 2>/dev/null; do i=$((i+1)); key="decision:$t:$slug-$i"; done
  fi
  swarm_gh label create "$LBL_OWNER_DECISION" --repo "$REPO_SLUG" --color D93F0B \
    --description "Waiting on the owner's answer; no agent takes it" >/dev/null 2>&1 || true
  # Label first: a line with no label on its ticket reads as already answered.
  swarm_gh issue edit "$t" --repo "$REPO_SLUG" --add-label "$LBL_OWNER_DECISION" >/dev/null 2>&1 \
    || { echo "owner-question: could not label #$t $LBL_OWNER_DECISION — nothing asked; try again" >&2; return 1; }
  # The builder's question is real whatever mode the coordinator runs in.
  COORDINATOR_SHADOW=0 bash "$NOTIFY" --class owner "$key" "#$t: $q" \
    || { echo "owner-question: could not write $key to needs-you.md" >&2; return 1; }
  swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "**Waiting on the owner** (\`$key\`).

$q

The question is in the owner's channel. No agent takes this ticket while it wears \`$LBL_OWNER_DECISION\`. Answer in the owner's window, or here: reply and take the label off, and the ticket goes back on the queue." >/dev/null 2>&1 || true
  echo "asked: $key — #$t waits on the answer"
}

requeue() { # <ticket> <note> — echoes the class
  local t="$1" cls=new n
  n=$(swarm_gh pr list --repo "$REPO_SLUG" --state open --search "head:$BRANCH_PREFIX$t" --json number -q length 2>/dev/null)
  [ "${n:-0}" -gt 0 ] 2>/dev/null && cls=repair
  bash "$QUEUE" add "$t" --class "$cls" --note "$2" --front >/dev/null 2>&1 || return 1
  printf '%s' "$cls"
}

# Every step of an answer; 0 only when all of them landed.
apply() { # <key> <answer>
  local key="$1" a="$2" t cls
  t=$(ticket_of "$key")
  swarm_gh issue edit "$t" --repo "$REPO_SLUG" --remove-label "$LBL_OWNER_DECISION" >/dev/null 2>&1 \
    || { echo "owner-question: could not take $LBL_OWNER_DECISION off #$t — the answer is kept and retried" >&2; return 1; }
  swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "**The owner answered** (\`$key\`): $a" >/dev/null 2>&1 \
    || { echo "owner-question: could not comment the answer on #$t — kept and retried" >&2; return 1; }
  cls=$(requeue "$t" "The owner answered $key: $a. Build on that answer; do not ask it again.") \
    || { echo "owner-question: could not put #$t back on the queue — kept and retried" >&2; return 1; }
  bash "$WATCH" done "$key" >/dev/null 2>&1 \
    || { echo "owner-question: could not tick $key in needs-you.md — kept and retried" >&2; return 1; }
  coord_act_log answer "$t" "$key: $a"
  echo "answered: $key — #$t back on the queue ($cls)"
}

pending_drop() { # <key>
  [ -f "$PENDING" ] || return 0
  awk -F'\t' -v k="$1" '$1 != k' "$PENDING" > "$PENDING.$$" && mv -f "$PENDING.$$" "$PENDING"
}

answer() { # <key> <answer>
  local key="${1:-}" a="${2:-}"
  case "$key" in decision:*:*) ;; *) echo "owner-question: '$key' is not a decision key" >&2; return 2 ;; esac
  [ -n "$a" ] || usage
  num "$(ticket_of "$key")" || { echo "owner-question: no ticket in '$key'" >&2; return 2; }
  a=$(printf '%s' "$a" | tr '\n\t' '  ')
  # Kept first: whatever below fails, the answer is not lost.
  printf '%s\t%s\t%s\n' "$(swarm_stamp)" "$key" "$a" >> "$ANSWERS"
  pending_drop "$key"; printf '%s\t%s\n' "$key" "$a" >> "$PENDING"
  apply "$key" "$a" || return 1
  pending_drop "$key"
}

sync() {
  local key a t m rc=0 cls
  if [ -s "$PENDING" ]; then
    while IFS=$'\t' read -r key a; do
      [ -n "${key:-}" ] || continue
      if apply "$key" "$a"; then pending_drop "$key"; else rc=1; fi
    done < <(cat "$PENDING")
  fi
  [ -f "$COORD_NEEDS_YOU" ] || return "$rc"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    grep -qF -- "$key"$'\t' "$PENDING" 2>/dev/null && continue
    t=$(ticket_of "$key"); num "$t" || continue
    m=$(meta "$t"); [ -n "$m" ] || continue
    wears "$m" && continue
    # The label came off somewhere else (a reply on the ticket, by hand): answered.
    if [ "${m%% *}" = OPEN ]; then
      cls=$(requeue "$t" "The owner answered $key on the ticket itself: read its newest comments, build on that answer, and do not ask it again.") || { rc=1; continue; }
      echo "answered elsewhere: $key — #$t back on the queue ($cls)"
    fi
    bash "$WATCH" done "$key" >/dev/null 2>&1 || rc=1
    coord_act_log answer "$t" "$key: answered on the ticket"
  done < <(grep '^- \[ \] ' "$COORD_NEEDS_YOU" | sed -n 's/.*<!-- key:\(decision:[0-9][0-9]*:[^ ]*\) -->[[:space:]]*$/\1/p')
  return "$rc"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  ask)     ask "$@" ;;
  answer)  answer "$@" ;;
  sync)    sync ;;
  waiting) num "${1:-}" || usage; m=$(meta "$1"); wears "${m:-x }" && printf '%s\n' "$LBL_OWNER_DECISION" ;;
  *) usage ;;
esac
