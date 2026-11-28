#!/usr/bin/env bash
# step-model.test.sh — the thinking steps (plan, review, compare) ask for
# DRIVER_THINK_MODEL; the steps that write code take the session's model. When the
# thinking model is out of allowance the call is made again on the session's model,
# the model is marked out until its reset, and no spawning hold is written: the plan
# still has room. Fable's own week ran out on 2026-11-19 and held every build for five
# days while Opus had room.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../ai-step.sh" || exit 1
export DRIVER_TICKET=101 SWARM_NOW=1792347200
export SWARM_USAGE_HOLD_FILE="$FIX/usage-hold" DRIVER_MODEL_OUT_FILE="$FIX/model-out"
unset DRIVER_THINK_MODEL
driver_state_init 101

# A stub that keeps each call's argv and answers with $FIX/ai/<step>.<n>.jsonl when there is one.
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
step=""; prev=""
for a in "$@"; do case "$prev" in --name) step="$a" ;; esac; prev="$a"; done
n=$(( $(cat "$FIX/nth.$step" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FIX/nth.$step"
printf '%s\n' "$*" > "$FIX/args.$step.$n"
perl -e 'eval { local $SIG{ALRM} = sub { die }; alarm 5; 1 while <STDIN>; alarm 0 }' 2>/dev/null || true
if [ -f "$FIX/ai/$step.$n.jsonl" ]; then cat "$FIX/ai/$step.$n.jsonl"; else cat "$FIX/ai/$step.jsonl"; fi
SH
chmod +x "$BIN/claude"
model_of() { sed -n 's/.*--model \([^ ]*\).*/\1/p' "$FIX/args.$1"; }
fresh() { rm -f "$FIX"/nth.* "$FIX"/args.* "$FIX"/ai/*.[0-9].jsonl "$SWARM_USAGE_HOLD_FILE" "$DRIVER_MODEL_OUT_FILE"; }
fable_out() { # <file> — Fable's own week rejected, the plan's week still allowed
  {
    echo '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1792900000,"rateLimitType":"seven_day","utilization":0.73}}'
    echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1792440000,"rateLimitType":"seven_day_overage_included"}}'
    echo '{"type":"result","subtype":"success","is_error":true,"api_error":"usage_limit_reached","result":"You'"'"'ve reached your Fable limit","total_cost_usd":0}'
  } > "$1"
}

fix_brief plan superpowers:writing-plans
fix_ai    plan '{"files":["a.sh"],"tests":["a.test.sh"]}' superpowers:writing-plans
fix_brief build superpowers:subagent-driven-development
fix_ai    build '{"items":[]}' superpowers:subagent-driven-development

echo "--- plan asks for Fable; build takes the session's model ---"
fresh
rc=0; driver_ai_step 101 plan >/dev/null 2>&1 || rc=$?
want "plan finishes" "0" "$rc"
want "plan asked for Fable" "claude-fable-5-2" "$(model_of plan.1)"
rc=0; driver_ai_step 101 build >/dev/null 2>&1 || rc=$?
want "build finishes" "0" "$rc"
want "build named no model" "" "$(model_of build.1)"

echo "--- one step set outright, and the thinking model switched off ---"
fresh
DRIVER_STEP_MODEL_PLAN=claude-opus-5-5 driver_ai_step 101 plan >/dev/null 2>&1
want "the override wins" "claude-opus-5-5" "$(model_of plan.1)"
fresh
DRIVER_THINK_MODEL= driver_ai_step 101 plan >/dev/null 2>&1
want "an empty thinking model names none" "" "$(model_of plan.1)"

echo "--- Fable out: the same call again on the session's model, no hold ---"
fresh; fable_out "$FIX/ai/plan.1.jsonl"
rc=0; out=$(driver_ai_step 101 plan 2>&1) || rc=$?
want "the step still finishes" "0" "$rc"
want "the first call asked for Fable" "claude-fable-5-2" "$(model_of plan.1)"
want "the second named no model" "" "$(model_of plan.2)"
want "two calls, no more" "2" "$(cat "$FIX/nth.plan")"
want "no spawning hold" "0" "$( [ -e "$SWARM_USAGE_HOLD_FILE" ] && echo 1 || echo 0)"
want "Fable is marked out until its reset" "1792440000	claude-fable-5-2" "$(cut -f1,2 "$DRIVER_MODEL_OUT_FILE" 2>/dev/null)"
want_in "it says so" 'claude-fable-5-2 is out of allowance' "$out"

echo "--- while marked out, plan names no model; after the reset, Fable again ---"
rm -f "$FIX"/nth.* "$FIX"/args.* "$FIX"/ai/*.[0-9].jsonl
driver_ai_step 101 plan >/dev/null 2>&1
want "marked out: no model asked for" "" "$(model_of plan.1)"
rm -f "$FIX"/nth.* "$FIX"/args.*
SWARM_NOW=1792440001 driver_ai_step 101 plan >/dev/null 2>&1
want "past the reset: Fable again" "claude-fable-5-2" "$(model_of plan.1)"

echo "--- the whole plan out: the fallback meets the wall too and the hold is written ---"
fresh; fable_out "$FIX/ai/plan.1.jsonl"
{
  echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1792900000,"rateLimitType":"seven_day"}}'
  echo '{"type":"result","subtype":"success","is_error":true,"api_error":"usage_limit_reached","result":"You'"'"'ve hit your weekly limit","total_cost_usd":0}'
} > "$FIX/ai/plan.2.jsonl"
rc=0; driver_ai_step 101 plan >/dev/null 2>&1 || rc=$?
want "it ends on the usage code" "$DRIVER_E_USAGE" "$rc"
want "two calls" "2" "$(cat "$FIX/nth.plan")"
# A seven-day wall holds five hours at most (swarm_usage_hold_write): the hold is written,
# capped at five hours from the run's clock (SWARM_NOW), never the weekly reset days out.
want "the spawning hold is written, five hours at most" "$(( SWARM_NOW + 5 * 3600 ))" "$(cut -f1 "$SWARM_USAGE_HOLD_FILE" 2>/dev/null)"
want "  and it names the weekly window"                 "seven_day" "$(cut -f4 "$SWARM_USAGE_HOLD_FILE" 2>/dev/null)"

echo "--- plant: drop the fallback and the step stops on Fable's wall ---"
fresh; fable_out "$FIX/ai/plan.1.jsonl"
driver_model_wall() { return 1; }
rc=0; driver_ai_step 101 plan >/dev/null 2>&1 || rc=$?
want "without the fallback it stops on the usage code" "$DRIVER_E_USAGE" "$rc"

suite_end "$FAILED"
