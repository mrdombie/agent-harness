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
set -uo pipefail

IN=$(cat)
LOG=/tmp/claude-heartbeat.log
say() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

# 0. A driver step has no operator to read a status block.
[ -n "${HARNESS_DRIVER_RUN:-}" ] && { say "exit0 driver-run"; exit 0; }

# 1. Already sent back once this turn.
[ "$(printf '%s' "$IN" | jq -r '.stop_hook_active // false')" = "true" ] && {
  say "exit0 stop_hook_active"; exit 0; }

LAST=$(printf '%s' "$IN" | jq -r '.last_assistant_message // ""')
[ -n "$LAST" ] || { say "exit0 empty-message"; exit 0; }

# 2. The block is there. Its Running row must name work, not only a wait.
#
# THE PROXY, NAMED: "the Running row names only waits (checks, CI, a watcher,
# reviewers, approval, a merge) and no work word" stands in for "the agent is
# idle while a PR's checks run". On 2026-10-10 an agent sat through four CI runs
# in a row: finish said to hold the claim until the merge and never said to move
# on. A row that says nothing is ready is the honest exit.
case "$LAST" in
  *💓*)
    ROW=$(printf '%s\n' "$LAST" | grep -iE '^\|[[:space:]]*\**Running\**[[:space:]]*\|' | tail -1 | tr '[:upper:]' '[:lower:]')
    if printf '%s' "$ROW" | grep -qE '\b(checks?|ci|watcher|merg(e|es|ing)|sign-?off|approval|reviewers?|reviews?)\b' &&
      ! printf '%s' "$ROW" | grep -qE '\b(build(ing)?|writ(e|ing)|plant(ing)?|test(s|ing)?|captur(e|ing)|fix(ing)?|draw(ing)?|render(ing)?|claim(ed|ing)?)\b|(no|nothing|none)( other| else)? (ready|takeable|left)|queue (is )?empty'; then
      say "exit2 idle-while-waiting"
      cat >&2 <<'EOF'
Your Running row is only a wait: checks, a watcher, reviewers, approval or a merge.
None of those needs you watching. Take the next ticket in your scope now and put
it in Running; the watcher's event outranks it the moment it fires. If nothing in
scope is ready, say so in the Running row ("nothing else ready").
EOF
      exit 2
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
A loop is running and this reply has no status block. End every wake with it,
even when nothing changed, so the operator can tell idle from stuck:

## 💓 Status

| | |
|---|---|
| **Running** | what is working right now, or "nothing" |
| Waiting for | the event or person each wait is on |
| Next check | when the loop next wakes, or what wakes it |

Add the block to the end of this reply now. Do not explain this message.
EOF
exit 2
