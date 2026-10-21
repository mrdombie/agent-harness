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
rm -rf "$MDIR"; t quiet 'a NEXT block with a You row is a report (2026-10-21)' '▶️ NEXT
| Who | What to do | Run |
|---|---|---|
| **You** | Approve the connections work | github.com/x |'                            false s4 "$NOASK"

rm -rf "$MDIR"; t quiet 'a 🔴 block, no tell words, is a report (2026-10-21)' '## 🔴 Feed and Comments

| Thing | What it needs |
|---|---|
| **Feed card PR** | Your approval |'                                                 false s13 "$NOASK"
rm -rf "$MDIR"; t nag 'calls left on a linked page (2026-10-09)' 'Three Pulse calls for your morning are on one page: https://claude.ai/artifact/x' false s14 "$NOASK"
rm -rf "$MDIR"; t quiet 'a 🔴 block after the question was asked' '## 🔴 Needs you
| PR | Remove the label |'                                                        false s15 "$ASKED"

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

# --- 2026-10-20 "Why are there two status every time too": replies that were
#     refused, and so posted their status block a second time.
# The transcript in Claude Code's own shape: an AskUserQuestion this turn, answered.
REAL="$TDIR/real.jsonl"
cat > "$REAL" <<'JSONL'
{"type":"user","message":{"role":"user","content":"sort the VM out"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"AskUserQuestion","input":{"questions":[{"question":"Which VM?"}]}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"The big one"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done"}]}}
JSONL
rm -rf "$MDIR"; t quiet 'a 🔴 block after AskUserQuestion, real transcript shape' '## 🔴 Needs you

| Thing | What it needs |
|---|---|
| **Big VM** | Your approval |'                                                            false r1 "$REAL"
VM='Runner is set up on this side.

## 🔴 Needs you

| Who | What |
|---|---|
| **You** | Run this on the VM, it needs your login |

```
sudo ./svc.sh install && sudo ./svc.sh start
```'
rm -rf "$MDIR"; t quiet 'a 🔴 "run this command on the VM" block'      "$VM"        false r2 "$NOASK"
rm -rf "$MDIR"; t quiet 'the same 🔴 block without the command is still a report' "${VM%%\`\`\`*}" false r3 "$NOASK"
DONE='Merged the chip PR.

## 🔴 Your call stands

As you chose, the digest stays weekly. Confirmed on the ticket.'
rm -rf "$MDIR"; t quiet 'a decision already answered, reported back'  "$DONE"       false r4 "$NOASK"
rm -rf "$MDIR"; t quiet '"your call stands" is not "your call"'       'Weekly digest: your call stands.' false r5 "$NOASK"
rm -rf "$MDIR"; t nag   'a decided report with a NEW open choice'      "$DONE
Next one is your call: daily or weekly for Echo?"                                     false r6 "$NOASK"
rm -rf "$MDIR"; t nag   'a real open choice left in prose'            'The chip PR can merge now or wait for the icon set. Needs a decision.' false r7 "$NOASK"
rm -rf "$MDIR"; t nag   'options listed with no ask'                  'Two ways to do it:
- **Option A** — merge now
- **Option B** — wait for the icon set'                                                 false r8 "$NOASK"
rm -rf "$MDIR"; t quiet 'one "Option 1" mention is not a list'         'Shipped Option 1 from the plan.' false r9 "$NOASK"
# --- 2026-10-21: reports are not questions. Only the tells and a question to the
#     operator fire; a report's shape (🔴, "Needs you", who it waits on) does not.
RED='## 🔴 Billing

The billing fix is in review. The chip PR waits on Dom'"'"'s sign-off.

| Thing | State |
|---|---|
| Billing fix | review round 2 |'
rm -rf "$MDIR"; t quiet 'a plain report with a 🔴 heading and no question'    "$RED"       false q1 "$NOASK"
rm -rf "$MDIR"; t quiet 'a "Needs you" table that only reports'              '## Needs you

| Thing | State |
|---|---|
| Chip PR | waiting on your sign-off |'                                                     false q2 "$NOASK"
rm -rf "$MDIR"; t nag   '"This is your call: A or B?"'                         "$RED

This is your call: A or B?"                                                             false q3 "$NOASK"
rm -rf "$MDIR"; t nag   'a question to the operator, no tell phrase'           'The chip PR can merge now or wait for the icons. Which would you pick?' false q4 "$NOASK"
rm -rf "$MDIR"; t nag   '"should I" left in prose'                             'Should I merge the chip PR now.' false q5 "$NOASK"
rm -rf "$MDIR"; t nag   '"up to you" left in prose'                            'Weekly or daily is up to you.' false q6 "$NOASK"
rm -rf "$MDIR"; t quiet 'a question not addressed to the operator'             'Why did CI fail? A flaky runner, now re-run.' false q7 "$NOASK"
rm -rf "$MDIR"; t quiet 'a URL query string is not a question'                 'You can see it at https://x.dev/pr?you=1&tab=checks now.' false q8 "$NOASK"

rm -rf "$MDIR"
jq -nc --arg m 'Your call.' --arg p "$NOASK" '{session_id:"r10",stop_hook_active:false,last_assistant_message:$m,transcript_path:$p}' \
  | "$H" 2>"$TDIR/err" >/dev/null
grep -q 'Do not repeat the report or a status block' "$TDIR/err" \
  && echo "OK        the nag says not to repeat the report or the block" \
  || { echo "MISMATCH  the nag says not to repeat the report or the block"; fail=1; }

rm -rf "$MDIR"
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
