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
# tells, or a question to the operator, and no AskUserQuestion ran since the operator's last message" as a
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
#    OPEN tells are the operator's own phrases, a question sentence addressed to
#    him (ends "?", says "you"), and options listed with no ask. A report's shape
#    is not a tell: a 🔴 heading, a "Needs you" table or a line naming who a thing
#    waits on is information, and boxing it made plain reports hard to read
#    (Dom, 2026-10-21). NOT included on purpose: `Reply "approve <n>"`, which /agent-harness:bug
#    prescribes as its hand-back — a hook must not fight a documented flow.
#
#    A decision already taken is a report, not a question (2026-10-20: a fired
#    nag on one forced a contrived second reply). Its wording is cut out before
#    the open tells are read, so "your call stands" is not "your call".
DONE='as you (chose|picked|decided|asked|said)|your (call|choice|decision|answer) (stands|holds|was|is (in|recorded|taken))|you (chose|picked|decided|approved|confirmed|signed off)|(already|now) (decided|answered|confirmed|approved)|(^|[^a-z])confirmed([^a-z]|$)|per your (call|answer|choice)'
OPEN='your call|worth your eye|needs a decision|up to you|do you want|should i |shall i |let me know which|calls? (for you|for your|only you)'
LISTED='^[[:space:]]*([-*][[:space:]]*)?\**(option|choice)[[:space:]]+[a-c1-3]\b'
# Lowercased first: BSD sed has no case-insensitive s///.
REST=$(printf '%s' "$LAST" | tr '[:upper:]' '[:lower:]' | sed -E "s/($DONE)//g")
HIT=""
printf '%s' "$REST" | grep -qiE "$OPEN" && HIT=tell
# A question to the operator: a sentence ending "?" that says "you". The "?" must
# end the sentence, so a URL's query string is not one.
printf '%s\n' "$REST" | grep -oE '[^.!?]*\?([[:space:]"'"'"')*_]|$)' | grep -qE '(^|[^a-z])your?([^a-z]|$)' && HIT=${HIT:-question}
[ "$(printf '%s\n' "$REST" | grep -ciE "$LISTED")" -ge 2 ] && HIT=${HIT:-options}

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
"worth your eye" and "needs a decision" are the tells, and so is a question to
the operator written as a sentence.

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
