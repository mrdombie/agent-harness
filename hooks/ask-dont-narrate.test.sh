#!/usr/bin/env bash
# Plant tests for ask-dont-narrate.sh. Exit 1 on any mismatch.
#
# Every case plants the thing that should make the hook fire or stay quiet.
# A hook that never fires is decorative; a hook that always fires is a loop.
H="$(dirname "$0")/ask-dont-narrate.sh"; fail=0
MDIR="${TMPDIR:-/tmp}/claude-ask-dont-narrate"
TDIR=$(mktemp -d); trap 'rm -rf "$TDIR"' EXIT

# A transcript with the operator's message, then an assistant turn. $1 = did we ask?
transcript(){
  f="$TDIR/t$RANDOM.jsonl"
  printf '%s\n' '{"role":"user","content":"do the thing"}' > "$f"
  [ "$1" = asked ] && printf '%s\n' '{"role":"assistant","content":[{"type":"tool_use","name":"AskUserQuestion"}]}' >> "$f"
  printf '%s\n' '{"role":"assistant","content":"done"}' >> "$f"
  printf '%s' "$f"
}

# want: nag | quiet ; t <want> <desc> <msg> <stop_hook_active> <session> <transcript|none>
t(){ want=$1 desc=$2 msg=$3 active=$4 sess=$5 tp=${6:-none}
  jq -nc --arg m "$msg" --argjson a "$active" --arg s "$sess" --arg p "$tp" \
    '{session_id:$s,hook_event_name:"Stop",stop_hook_active:$a,last_assistant_message:$m,transcript_path:$p}' \
    | "$H" >/dev/null 2>&1
  [ $? -eq 2 ] && got=nag || got=quiet
  mark=OK; [ "$got" = "$want" ] || { mark=MISMATCH; fail=1; }
  printf '%-9s want=%-6s got=%-6s %s\n' "$mark" "$want" "$got" "$desc"; }

NOASK=$(transcript noask); ASKED=$(transcript asked)

# --- fires on the tells the operator has actually named
rm -rf "$MDIR"; t nag 'a decision left as "your call"' 'Two options here. Your call.' false s1 "$NOASK"
rm -rf "$MDIR"; t nag 'the "worth your eye" tell'      'This one is worth your eye.'  false s2 "$NOASK"
rm -rf "$MDIR"; t nag 'offering a choice in prose'     'Do you want me to merge it?'  false s3 "$NOASK"
rm -rf "$MDIR"; t nag 'a NEXT block with a You row'    '▶️ NEXT
| Who | What to do | Run |
|---|---|---|
| **You** | Approve the connections work | github.com/x |'                            false s4 "$NOASK"

# --- stays quiet when the question WAS asked
rm -rf "$MDIR"; t quiet 'AskUserQuestion ran this turn' 'Two options here. Your call.' false s5 "$ASKED"

# --- must not fight a documented flow: /agent-harness:bug prescribes this exact hand-back
rm -rf "$MDIR"; t quiet '/agent-harness:bug hand-back wording' 'Held on your approval: github.com/x
Reply "approve 9998" and I'"'"'ll clear it.'                                          false s6 "$NOASK"

# --- a plain report with no decision in it
rm -rf "$MDIR"; t quiet 'no decision tell at all' 'Merged to develop. 725 tests green.' false s7 "$NOASK"

# --- the loop guards
rm -rf "$MDIR"; t quiet 'stop_hook_active guard' 'Your call.' true s8 "$NOASK"
rm -rf "$MDIR"
t nag   'cooldown — first stop of the session'  'Your call.' false s9 "$NOASK"
t quiet 'cooldown — second stop, same session'  'Your call.' false s9 "$NOASK"
t nag   'cooldown is per session, not global'   'Your call.' false s10 "$NOASK"

# --- cannot prove it was skipped -> stay quiet
rm -rf "$MDIR"; t quiet 'transcript unreadable'  'Your call.' false s11 "/nope/missing.jsonl"
rm -rf "$MDIR"; t quiet 'empty closing message'  ''           false s12 "$NOASK"

# --- a driver step has no person to ask, and its answer must not be rewritten
# Both Stop hooks stand down on HARNESS_DRIVER_RUN. This one's exit 2 rewrites the
# final message just as surely as the banner does, and the driver reads the answer
# from there. The control is the same input without the marker.
rm -rf "$MDIR"; t nag   'the control: this input does nag'   'Your call.' false d0 "$NOASK"
rm -rf "$MDIR"
HARNESS_DRIVER_RUN=10867:review \
  t quiet 'and stands down for a driver step' 'Your call.' false d1 "$NOASK"

rm -rf "$MDIR"
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
