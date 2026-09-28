#!/usr/bin/env bash
# Plant tests for context-ceiling.sh. Exit 1 on any mismatch.
#
# Every case plants a transcript whose LAST assistant turn carries a known usage,
# so the number the hook reads is the number the case chose. The quiet cases
# carry as much weight as the firing one: a hook on every tool call that speaks
# when it should not is noise in every spawned run.
#
# The subject is the hook BESIDE THIS FILE. The marker directory lives under a
# scratch TMPDIR, so no case sees a marker a real run left behind.
H="$(cd "$(dirname "$0")" && pwd)/context-ceiling.sh"; fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export TMPDIR="$T"
unset CLAIM_RUN_ID CLAIM_CONTEXT_CEILING
# No config unless a case plants one: point the reader at a file that is not there.
export HARNESS_CFG_PATH="$T/none/harness.json"

# One assistant line with the given input side, split across the three fields the
# hook must sum. Compact, one object per line — the shape Claude Code writes.
asst(){ jq -nc --argjson i "$1" --argjson r "$2" --argjson c "$3" --argjson s "${4:-false}" \
  '{type:"assistant",isSidechain:$s,message:{role:"assistant",content:[{type:"text",text:"ok"}],
    usage:{input_tokens:$i,cache_read_input_tokens:$r,cache_creation_input_tokens:$c,output_tokens:9}}}'; }
user(){ jq -nc --arg t "$1" '{type:"user",message:{role:"user",content:[{type:"tool_result",content:$t}]}}'; }

# run <transcript> [env...] -> sets out and rc
run(){ local tp=$1; shift
  out=$(jq -nc --arg t "$tp" '{session_id:"s",hook_event_name:"PostToolUse",tool_name:"Bash",transcript_path:$t}' 2>/dev/null \
        | env "$@" bash "$H" 2>/dev/null); rc=$?; }

# want: fire | quiet
chk(){ want=$1 desc=$2
  got=quiet
  if [ -n "$out" ]; then
    ctx=$(printf '%s' "$out" | jq -r 'select(.hookSpecificOutput.hookEventName == "PostToolUse") | .hookSpecificOutput.additionalContext // ""' 2>/dev/null)
    printf '%s' "$ctx" | grep -q 'PARK per /agent-harness:claim' && got=fire || got="garbage"
  fi
  mark=OK
  { [ "$got" = "$want" ] && [ "$rc" -eq 0 ]; } || { mark=MISMATCH; fail=1; }
  printf '%-9s want=%-6s got=%-7s rc=%s %s\n' "$mark" "$want" "$got" "$rc" "$desc"; }

LOW="$T/low.jsonl";  { user hi; asst 3 100000 20000; user result; } > "$LOW"
HIGH="$T/high.jsonl"; { user hi; asst 3 100000 20000; user result; asst 2 280000 5000; user result; } > "$HIGH"

# --- the case the hook exists for, and its once-per-run guard -------------------
run "$HIGH" CLAIM_RUN_ID=run-a
chk fire  'above the ceiling (285002 > 250000) — one park instruction'
printf '%s' "$ctx" | grep -q 'at 285002 input tokens' \
  && echo "OK        the instruction names the measured size (sums all three fields)" \
  || { echo "MISMATCH  the instruction does not name 285002 tokens"; fail=1; }
printf '%s' "$out" | jq -e '.hookSpecificOutput | has("permissionDecision") or has("decision") | not' >/dev/null 2>&1 \
  && echo "OK        additionalContext only — never a block or a decision" \
  || { echo "MISMATCH  the output carries a decision"; fail=1; }
run "$HIGH" CLAIM_RUN_ID=run-a
chk quiet 'second call above the ceiling, same run — fires once'
run "$HIGH" CLAIM_RUN_ID=run-b
chk fire  'the once-marker is per run, not global'

# --- below, and outside a spawned run -----------------------------------------
run "$LOW" CLAIM_RUN_ID=run-c
chk quiet 'below the ceiling (120003) — silent'
run "$HIGH"
chk quiet 'CLAIM_RUN_ID unset — an interactive session is never told to park'

# The LAST assistant turn is the measurement, not the largest one.
DOWN="$T/down.jsonl"; { asst 0 300000 0; user r; asst 0 90000 0; user r; } > "$DOWN"
run "$DOWN" CLAIM_RUN_ID=run-d
chk quiet 'an earlier turn was over, the last one is under — silent'

# A subagent's turn is not this run's context.
SIDE="$T/side.jsonl"; { asst 0 100000 0; user r; asst 0 400000 0 true; } > "$SIDE"
run "$SIDE" CLAIM_RUN_ID=run-e
chk quiet 'a sidechain turn over the ceiling does not count'

# --- the ceiling is configurable ------------------------------------------------
run "$LOW" CLAIM_RUN_ID=run-f CLAIM_CONTEXT_CEILING=100000
chk fire  'CLAIM_CONTEXT_CEILING=100000 lowers it — 120003 fires'
mkdir -p "$T/proj/.claude"; echo '{"repo":"o/r","contextCeiling":400000}' > "$T/proj/.claude/harness.json"
run "$HIGH" CLAIM_RUN_ID=run-g HARNESS_CFG_PATH="$T/proj/.claude/harness.json"
chk quiet 'contextCeiling 400000 in harness.json raises it — 285002 is silent'
run "$HIGH" CLAIM_RUN_ID=run-h HARNESS_CFG_PATH="$T/proj/.claude/harness.json" CLAIM_CONTEXT_CEILING=200000
chk fire  'the env wins over harness.json'
run "$HIGH" CLAIM_RUN_ID=run-i CLAIM_CONTEXT_CEILING=lots
chk fire  'a non-numeric ceiling falls back to the default, not to zero or off'

# --- a large transcript is read by its tail -------------------------------------
# The first assistant line is pushed out of the 256 KiB window by a big tool
# result; the hook must widen once and still find it.
# The filler is written directly, not handed to jq as an argument: 400 KB is past
# the argument limit on some platforms, and a filler that fails to write leaves a
# transcript this case passes on without ever widening.
BIG="$T/big.jsonl"
{ asst 0 300000 0
  printf '%s' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"'
  head -c 400000 /dev/zero | tr '\0' x
  printf '%s\n' '"}]}}'; } > "$BIG"
{ [ "$(wc -c < "$BIG")" -gt 400000 ] && [ "$(tail -c 262144 "$BIG" | grep -c '"usage"')" -eq 0 ]; } \
  && echo "OK        plant: the usage line is outside the first 256 KiB window" \
  || { echo "MISMATCH  plant: the usage line is still inside the first window"; fail=1; }
run "$BIG" CLAIM_RUN_ID=run-j
chk fire  'the only usage line sits behind a 400 KB tool result — found by widening'

# --- every unknown is silence, exit 0 ------------------------------------------
run "$T/does-not-exist.jsonl" CLAIM_RUN_ID=run-k
chk quiet 'transcript missing — silent, exit 0'
GARB="$T/garbled.jsonl"; printf '{"type":"assistant","message":{"usage":{"input_tok\nnot json at all "usage"\n\0\0\n' > "$GARB"
run "$GARB" CLAIM_RUN_ID=run-l
chk quiet 'transcript garbled — silent, exit 0'
: > "$T/empty.jsonl"
run "$T/empty.jsonl" CLAIM_RUN_ID=run-m
chk quiet 'transcript empty — silent, exit 0'
out=$(printf 'not json' | CLAIM_RUN_ID=run-n bash "$H" 2>/dev/null); rc=$?
chk quiet 'payload is not JSON — silent, exit 0'
out=$(: | CLAIM_RUN_ID=run-o bash "$H" 2>/dev/null); rc=$?
chk quiet 'no payload at all — silent, exit 0'

echo
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES — see MISMATCH rows above"
exit "$fail"
