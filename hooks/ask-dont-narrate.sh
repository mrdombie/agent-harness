#!/usr/bin/env bash
# Backstop for "decisions go in AskUserQuestion, never a line of prose".
#
# WHY: the rule already exists in three places — the house output style (Dom's, recorded 2026-09-05), and the
# memories feedback_short_answers_use_askuserquestion and
# feedback_ask_dont_narrate_decisions — and on 2026-09-05 it was skipped anyway,
# on a /agent-harness:standup whose own Step 5 mandates the question. A rule written down in
# three places and still missed is not a memory problem; it needs enforcement.
#
# THE PROXY, NAMED: this uses "the closing message contains one of the operator's own
# tells named in feedback_ask_dont_narrate_decisions, and no AskUserQuestion ran since the operator's last message" as a
# stand-in for "a decision was left as prose". Those are not the same thing — a
# decision phrased in words this does not match slips through, which is why the
# tell list is the specific phrases they have called out rather than a guess at
# every way a question can be asked. False quiet is the accepted failure; false
# nag costs one turn.
#
# A Stop hook cannot print to the terminal (measured 2026-09-04, see
# signoff-backstop.sh). exit 2 is the only way to get the text in front of the
# model, and it continues the turn rather than ending it.
#
# A blocking Stop hook is how /goal looped ~20x on 2026-08-30. FOUR guards, each
# of which alone ends the turn.
set -uo pipefail

IN=$(cat)
LOG=/tmp/claude-ask-dont-narrate.log
say() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

# 0. A DRIVER STEP IS NOT A PERSON'S TURN. The driver exports HARNESS_DRIVER_RUN
#    for the step it is running, and both Stop hooks stand down on it. Measured on
#    the 2026-09-27 trial: this hook's exit 2 made the model replace its whole final
#    answer with the four-line banner, so the driver read no JSON at all on either
#    ticket and both runs parked at step 1 of 7. A banner is an instruction to an
#    operator's terminal; there is no operator here, and nothing to keep track of
#    that the run record does not already hold.
[ -n "${HARNESS_DRIVER_RUN:-}" ] && { say "exit0 driver-run ${HARNESS_DRIVER_RUN}"; exit 0; }

# 1. The documented escape hatch — we already blocked once this turn.
[ "$(printf '%s' "$IN" | jq -r '.stop_hook_active // false')" = "true" ] && {
  say "exit0 stop_hook_active"; exit 0; }

# 2. Cooldown: at most one nag per session per 10 minutes.
SID=$(printf '%s' "$IN" | jq -r '.session_id // "nosession"')
MDIR="${TMPDIR:-/tmp}/claude-ask-dont-narrate"; mkdir -p "$MDIR"
MARK="$MDIR/$SID"
if [ -f "$MARK" ]; then
  AGE=$(( $(date +%s) - $(stat -c %Y "$MARK" 2>/dev/null || stat -f %m "$MARK" 2>/dev/null || echo 0) ))
  [ "$AGE" -lt 600 ] && { say "exit0 cooldown ${AGE}s $SID"; exit 0; }
fi

LAST=$(printf '%s' "$IN" | jq -r '.last_assistant_message // ""')
[ -n "$LAST" ] || { say "exit0 empty-message"; exit 0; }

# 3. Did the closing message actually leave a decision hanging?
#    OPEN tells are the phrases named in feedback_ask_dont_narrate_decisions, the
#    interrogative forms that put a choice in prose, and options listed with no
#    ask. NOT included on purpose: `Reply "approve <n>"`, which /agent-harness:bug
#    prescribes as its hand-back — a hook must not fight a documented flow.
#
#    A decision already taken is a report, not a question (2026-10-20: a fired
#    nag on one forced a contrived second reply). Its wording is cut out before
#    the open tells are read, so "your call stands" is not "your call".
DONE='as you (chose|picked|decided|asked|said)|your (call|choice|decision|answer) (stands|holds|was|is (in|recorded|taken))|you (chose|picked|decided|approved|confirmed|signed off)|(already|now) (decided|answered|confirmed|approved)|(^|[^a-z])confirmed([^a-z]|$)|per your (call|answer|choice)'
OPEN='your call|worth your eye|needs a decision|which would you prefer|let me know which|let me know if you.d|do you want me to|would you like me to|shall I |should I |want me to |or shall we|up to you|either way, tell me|calls? (for you|for your|only you)|on one page'
LISTED='^[[:space:]]*([-*][[:space:]]*)?\**(option|choice)[[:space:]]+[a-c1-3]\b'
# Lowercased first: BSD sed has no case-insensitive s///.
REST=$(printf '%s' "$LAST" | tr '[:upper:]' '[:lower:]' | sed -E "s/($DONE)//g")
HIT=""
printf '%s' "$REST" | grep -qiE "$OPEN" && HIT=tell
printf '%s\n' "$REST" | grep -iE "$LISTED" | wc -l | grep -qvE '^[[:space:]]*[01]$' && HIT=${HIT:-options}

# SHAPE tells: a 🔴 heading (the house style opens every "needs him" block with
# it), a "needs you" line, or a NEXT block with a row addressed to the operator
# (/agent-harness:standup's shape; its Step 5 makes the question mandatory).
SHAPE=""
printf '%s' "$LAST" | grep -qiE 'needs you' && SHAPE=needs-you
printf '%s' "$LAST" | grep -qE '^#+[[:space:]]*🔴' && SHAPE=red
printf '%s' "$LAST" | grep -qE '^\s*(▶️ *)?NEXT' \
  && printf '%s' "$LAST" | grep -qiE '^\|[^|]*\*{0,2}You\*{0,2}[^|]*\|' && SHAPE=next
# A shape is only a question when something is left to choose. Not when the
# reply reports a call already made, nor when what it hands over is a physical
# step with the command spelled out ("run this on the VM").
if [ -n "$SHAPE" ]; then
  if printf '%s' "$LAST" | grep -qiE "$DONE"; then
    say "shape-skipped decided shape=$SHAPE"
  elif printf '%s' "$LAST" | grep -qE '^[[:space:]]*```' &&
       printf '%s' "$LAST" | grep -qiE '\b(run|paste|type|execute)\b[^.|]{0,40}\b(this|these|the following|it|below|command)\b|\bon (the|your|that) [a-z0-9-]*[[:space:]]?(vm|mac|machine|server|box|laptop|phone|terminal|host)\b'; then
    say "shape-skipped physical-action shape=$SHAPE"
  else
    HIT=${HIT:-$SHAPE}
  fi
fi

[ -n "$HIT" ] || { say "exit0 no-decision-tell"; exit 0; }

# 4. The common path — the question was already asked this turn. Read the
#    transcript back to the operator's last message and look for the tool call. If the
#    transcript cannot be read we CANNOT prove it was skipped, so stay quiet:
#    nagging straight after a genuine ask is what gets a hook switched off.
TP=$(printf '%s' "$IN" | jq -r '.transcript_path // ""')
[ -n "$TP" ] && [ -r "$TP" ] || { say "exit0 no-transcript hit=$HIT"; exit 0; }

ASKED=$(awk '
  /"role"[[:space:]]*:[[:space:]]*"user"/ && !/tool_result/ { last=NR }
  { line[NR]=$0 }
  END { for (i=last; i<=NR; i++) if (line[i] ~ /AskUserQuestion/) { print "yes"; exit } }
' "$TP" 2>/dev/null)
[ "$ASKED" = "yes" ] && { say "exit0 already-asked hit=$HIT"; exit 0; }

touch "$MARK"
say "exit2 nagging hit=$HIT session=$SID"
cat >&2 <<'EOF'
You are ending a turn with a decision left as prose. The house output style (recorded 2026-09-05) is
explicit: decisions go in AskUserQuestion, never a line of prose — "your call",
"worth your eye" and "needs a decision" are the tells, and a NEXT block with a
row addressed to the operator is the same failure in table form.

Put the choice to the operator now with AskUserQuestion:
  - options are the rows you just wrote, in the same words
  - each description says what happens if they pick it
  - plain language, no ticket numbers or file paths in a label
  - no "do nothing" option; the tool always offers Other

Your reply above stands: send only the AskUserQuestion call, then act on the
answer in the same turn. Do not repeat the report or a status block, do not
restate the question as prose, and do not explain this message.
EOF
exit 2
