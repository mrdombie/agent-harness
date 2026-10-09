#!/usr/bin/env bash
# Plant tests for heartbeat.sh. Exit 1 on any mismatch.
#
# Each case plants what should make the hook fire or stay quiet. The first nag
# case is the reply that started this: a bare "no change" line mid-loop.
H="$(dirname "$0")/heartbeat.sh"; fail=0
TDIR=$(mktemp -d); trap 'rm -rf "$TDIR"' EXIT

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
    | "$H" >/dev/null 2>&1
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
HARNESS_DRIVER_RUN=1 t quiet 'a driver step'             'No change.'                                    false "$LIVE"

exit $fail
