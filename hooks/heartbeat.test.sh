#!/usr/bin/env bash
# Plant tests for heartbeat.sh. Exit 1 on any mismatch.
#
# Each case plants what should make the hook fire or stay quiet. The first nag
# case is the reply that started this: a bare "no change" line mid-loop.
H="$(dirname "$0")/heartbeat.sh"; fail=0
TDIR=$(mktemp -d); trap 'rm -rf "$TDIR"' EXIT
export TMPDIR="$TDIR"; NDIR="$TDIR/claude-heartbeat"

# A transcript whose newest wakeup is $1: live | stopped | none.
transcript(){
  f="$TDIR/t$RANDOM.jsonl"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"/loop /work pulse"}}' > "$f"
  case "$1" in
    live) printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":1200,"prompt":"/loop /work pulse"}}]}}' >> "$f" ;;
    stopped)
      printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":1200,"prompt":"/loop /work pulse"}}]}}' >> "$f"
      printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"stop":true}}]}}' >> "$f" ;;
  esac
  printf '%s' "$f"
}

# want: nag | quiet ; t <want> <desc> <msg> <stop_hook_active> <transcript>
t(){ want=$1 desc=$2 msg=$3 active=$4 tp=$5
  jq -nc --arg m "$msg" --argjson a "$active" --arg p "$tp" \
    '{session_id:"s",hook_event_name:"Stop",stop_hook_active:$a,last_assistant_message:$m,transcript_path:$p}' \
    | "$H" >/dev/null 2>"$TDIR/err"
  [ $? -eq 2 ] && got=nag || got=quiet
  mark=OK; [ "$got" = "$want" ] || { mark=MISMATCH; fail=1; }
  printf '%-9s want=%-6s got=%-6s %s\n' "$mark" "$want" "$got" "$desc"; }

LIVE=$(transcript live); STOPPED=$(transcript stopped); NONE=$(transcript none)
BLOCK='Done.

## 💓 Status

| | |
|---|---|
| **Running** | Nothing |'

t nag   'a bare "no change" line mid-loop (2026-10-09)' 'No change: the feed PR is still held for your approval.' false "$LIVE"
t nag   'a full report mid-loop, but no status block'   '## ✅ Done
| Card | State |'                                                                                    false "$LIVE"
t quiet 'the status block is there'                     "$BLOCK"                                        false "$LIVE"
t quiet 'the loop was stopped'                          'Stopped: nothing running.'                     false "$STOPPED"
t quiet 'no loop in this session'                       'Merged to develop.'                            false "$NONE"
t quiet 'already sent back once this turn'              'No change.'                                    true  "$LIVE"
t quiet 'transcript unreadable'                         'No change.'                                    false "/nope/missing.jsonl"
t quiet 'empty closing message'                         ''                                              false "$LIVE"
t quiet 'Running is only the checks on a PR (2026-10-10), never refused' 'Done.

## 💓 Status

| | |
|---|---|
| **Running** | checks on the chip follow-ups PR |' false "$LIVE"
t quiet 'Running is only two reviewers, never refused' 'Done.

## 💓 Status

| | |
|---|---|
| **Running** | code reviewer and design reviewer, round 2 |' false "$LIVE"
t quiet 'Running is only the approval gate re-check, never refused' 'Done.

## 💓 Status

| | |
|---|---|
| **Running** | the approval gate re-check on the chip PR |' false "$LIVE"
t quiet 'Running names work beside the wait' 'Done.

## 💓 Status

| | |
|---|---|
| **Running** | building the frame check; checks on the chip PR |' false "$LIVE"
t quiet 'Running says nothing else is ready' 'Done.

## 💓 Status

| | |
|---|---|
| **Running** | checks on the chip PR; nothing else ready |' false "$LIVE"
t quiet 'Running names a capture, no wait' 'Done.

## 💓 Status

| | |
|---|---|
| **Running** | capturing the card in light and dark |' false "$LIVE"
# ok <desc> <command...>: a check beside the want/got table.
ok(){ d=$1; shift; if "$@"; then printf '%-9s %s\n' OK "$d"; else printf '%-9s %s\n' MISMATCH "$d"; fail=1; fi; }
# prompt <session>: the UserPromptSubmit half; prints what it hands the model.
prompt(){ jq -nc --arg s "$1" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"next"}' | "$H"; }
status(){ printf 'Done.\n\n## 💓 Status\n\n| | |\n|---|---|\n| **Running** | %s |\n| Waiting for | CI |\n' "$1"; }

# --- 2026-10-20 "Why are there two status every time too": replayed replies that
#     were refused and so posted their status block a second time.
rm -rf "$NDIR"
t quiet 'a wait-only status is never refused (2026-10-20)' "$(status 'checks on the chip PR')" false "$LIVE"
ok '  and its advice is queued for the next prompt' test -s "$NDIR/s"
OUT=$(prompt s)
ok '  the next prompt carries it as additionalContext' sh -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput.additionalContext | test(\"only a wait\")" >/dev/null' _ "$OUT"
ok '  the advice says not to resend the block' sh -c 'printf "%s" "$1" | grep -q "Do not resend"' _ "$OUT"
ok '  and is handed over once' test -z "$(prompt s)"
ok 'a prompt with nothing queued adds nothing' test -z "$(prompt other)"
for row in 'builders on the feed and digest tickets; CI on the chip PR' \
           'the coordinator owns the queue; reviewers on the chip PR' \
           'checks on the VM PR; the skills-ce session holds the merge' \
           'approval on the chip PR; nothing in scope'; do
  rm -rf "$NDIR"
  t quiet "PM session: \"$row\"" "$(status "$row")" false "$LIVE"
  ok '  and no advice is queued' test ! -e "$NDIR/s"
done
t nag   'a missing block in a loop is still asked for' 'Merged the chip PR.' false "$LIVE"
ok '  the ask is to add the status line' grep -q 'Add only the status line' "$TDIR/err"
ok '  and never to resend the reply' grep -q 'do not$' "$TDIR/err"
ok '  ... (resend or restate it)' grep -q '^resend or restate it' "$TDIR/err"

# --- 2026-10-21 "Don't shoehorn everything into tables and status blocks": one
#     plain line is the status; the old block still passes.
LINE='Merged the chip PR.

Status: 3 builders running; waiting on the billing fix; next check when a build finishes.'
t quiet 'a reply ending in a one-line status (2026-10-21)' "$LINE" false "$LIVE"
t quiet '  ... in any case, bolded' 'Done.
**status:** builders on the feed ticket; next check in 20 minutes.' false "$LIVE"
t nag   'neither the block nor a status line, mid-loop' 'Merged the chip PR. 3 builders running.' false "$LIVE"
t nag   '"status" mid-sentence is not a status line' 'The status of the chip PR is green.' false "$LIVE"
ok '  the ask suggests the one-line form first' sh -c 'grep -n "^Status: " "$1" | head -1 | grep -q . && ! grep -q "^|" "$1"' _ "$TDIR/err"
rm -rf "$NDIR"
t quiet 'a wait-only status line is never refused' 'Status: waiting on checks for the chip PR; next check when they finish.' false "$LIVE"
ok '  and its advice is queued for the next prompt' test -s "$NDIR/s"
rm -rf "$NDIR"
t quiet 'a status line naming builders' 'Status: builders on the feed ticket; CI on the chip PR.' false "$LIVE"
ok '  and no advice is queued' test ! -e "$NDIR/s"
rm -rf "$NDIR"

# The advice is dead unless the plugin wires the prompt half: read the call site.
HJ="$(dirname "$0")/hooks.json"
ok 'hooks.json runs heartbeat.sh on UserPromptSubmit' sh -c 'jq -e "[.hooks.UserPromptSubmit[]?.hooks[]?.command] | any(test(\"hooks/heartbeat.sh\"))" "$1" >/dev/null' _ "$HJ"
ok 'hooks.json still runs heartbeat.sh on Stop' sh -c 'jq -e "[.hooks.Stop[]?.hooks[]?.command] | any(test(\"hooks/heartbeat.sh\"))" "$1" >/dev/null' _ "$HJ"

HARNESS_DRIVER_RUN=1 t quiet 'a driver step'             'No change.'                                    false "$LIVE"

exit $fail
