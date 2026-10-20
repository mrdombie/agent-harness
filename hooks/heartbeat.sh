#!/usr/bin/env bash
# Backstop for "every wake in a loop ends with a status block".
#
# WHY: in a self-paced /loop, a watcher event or a timer wakes the model, and a
# wake where nothing changed tended to end in a bare one-liner ("No change: the
# PR is still held"). The operator could not tell an idle loop from a stuck one
# (2026-10-09: "I wish you updated me or something or some sort of heart beat
# to know it was still active"). A written rule landed the same day; this makes
# it hold.
#
# THE PROXY, NAMED: "the newest ScheduleWakeup call in the transcript is not a
# stop" stands in for "a loop is running". A loop paced by CronCreate alone, or
# a Monitor with no wakeup, is not seen — false quiet, the accepted failure.
# "The closing message carries the 💓 glyph" stands in for "it has the status
# block"; the glyph opens the block's heading, so a reply that names the glyph
# in prose would pass.
#
# A Stop hook cannot print to the terminal; exit 2 feeds the reason back to the
# model and continues the turn. A blocking Stop hook is how /goal looped ~20x on
# 2026-08-30, so each guard below ends the turn on its own, and there is no
# cooldown on purpose: the block is owed on every wake, and stop_hook_active
# already stops a second nag inside one turn.
#
# Advice rides on UserPromptSubmit, not on the Stop's own additionalContext: that
# one continues the turn just as exit 2 does, and a continued turn is a second reply.
set -uo pipefail

IN=$(cat)
LOG=/tmp/claude-heartbeat.log
say() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

NDIR="${TMPDIR:-/tmp}/claude-heartbeat"
WORK='\b(build(ing)?|writ(e|ing)|plant(ing)?|test(s|ing)?|captur(e|ing)|fix(ing)?|draw(ing)?|render(ing)?|claim(ed|ing)?|spec(cing)?)\b'
OTHERS='\b(builders?|coordinator|agents?|workers?|(another|other|the [a-z-]+) session|owned by)\b'
NOTHING='(no|nothing|none)( other| else)? (ready|takeable|left|to take|in scope)|queue (is )?empty|nothing in scope'
ADVICE='Last reply'"'"'s Running row was only a wait (checks, a watcher, reviewers, approval or a merge). If a ticket in your scope is ready, take it this turn and put it in Running. If the queue belongs to the coordinator or nothing is ready, name that in the Running row ("builders on X", "nothing else ready"). Do not resend the earlier status block.'

# The UserPromptSubmit half: hand over advice the Stop half queued, once.
if [ "$(printf '%s' "$IN" | jq -r '.hook_event_name // ""')" = "UserPromptSubmit" ]; then
  SID=$(printf '%s' "$IN" | jq -r '.session_id // "nosession"')
  [ -f "$NDIR/$SID" ] || exit 0
  NOTE=$(cat "$NDIR/$SID"); rm -f "$NDIR/$SID"
  say "advice-delivered $SID"
  jq -nc --arg c "$NOTE" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
  exit 0
fi

# 0. A driver step has no operator to read a status block.
[ -n "${HARNESS_DRIVER_RUN:-}" ] && { say "exit0 driver-run"; exit 0; }

# 1. Already sent back once this turn.
[ "$(printf '%s' "$IN" | jq -r '.stop_hook_active // false')" = "true" ] && {
  say "exit0 stop_hook_active"; exit 0; }

LAST=$(printf '%s' "$IN" | jq -r '.last_assistant_message // ""')
[ -n "$LAST" ] || { say "exit0 empty-message"; exit 0; }

# 2. The block is there, so the stop is never refused: a refusal here made the
#    agent post the same block a second time (2026-10-20: "Why are there two
#    status every time too"). A Running row that is only a wait gets advice for
#    the NEXT turn instead, carried by the UserPromptSubmit half of this hook.
#
# THE PROXY, NAMED: "the Running row names only waits (checks, CI, a watcher,
# reviewers, approval, a merge) and no work word, no work owned by others and no
# 'nothing ready'" stands in for "the agent is idle while work it could take is
# ready". A PM session whose queue the coordinator owns has nothing to take, and
# says so by naming the builders, the coordinator or another session.
case "$LAST" in
  *💓*)
    ROW=$(printf '%s\n' "$LAST" | grep -iE '^\|[[:space:]]*\**Running\**[[:space:]]*\|' | tail -1 | tr '[:upper:]' '[:lower:]')
    if printf '%s' "$ROW" | grep -qE '\b(checks?|ci|watcher|merg(e|es|ing)|sign-?off|approval|reviewers?|reviews?)\b' &&
      ! printf '%s' "$ROW" | grep -qE "$WORK|$OTHERS|$NOTHING"; then
      SID=$(printf '%s' "$IN" | jq -r '.session_id // "nosession"')
      mkdir -p "$NDIR" && printf '%s\n' "$ADVICE" > "$NDIR/$SID"
      say "exit0 has-heartbeat idle-advice-queued $SID"; exit 0
    fi
    say "exit0 has-heartbeat"; exit 0 ;;
esac

# 3. Is a loop running? Unreadable transcript means we cannot tell: stay quiet.
TP=$(printf '%s' "$IN" | jq -r '.transcript_path // ""')
[ -n "$TP" ] && [ -r "$TP" ] || { say "exit0 no-transcript"; exit 0; }
WAKE=$(grep -F '"name":"ScheduleWakeup"' "$TP" 2>/dev/null | tail -1)
[ -n "$WAKE" ] || { say "exit0 no-loop"; exit 0; }
printf '%s' "$WAKE" | grep -qE '"stop"[[:space:]]*:[[:space:]]*true' && {
  say "exit0 loop-stopped"; exit 0; }

say "exit2 missing-heartbeat"
cat >&2 <<'EOF'
A loop is running and your reply has no status block. Your reply stands: do not
resend or restate it. Add only the block, as the whole of your next message:

## 💓 Status

| | |
|---|---|
| **Running** | what is working right now, yours or others' (builders, the coordinator), or "nothing" |
| Waiting for | the event or person each wait is on |
| Next check | when the loop next wakes, or what wakes it |

Do not explain this message.
EOF
exit 2
