#!/usr/bin/env bash
# model-pin.test.sh — every model call the driver starts runs on the model harness.json
# names (`driver.model`), whatever the machine's default is. Measured 2026-11-09: one
# `/model fable` in a person's own session moved every builder step off Opus, because
# `claude -p` with no --model follows ~/.claude/settings.json and ANTHROPIC_MODEL.
# plan → .plan; review, review-check and the attest reviewers → .review; every other
# step → .default; with no key at all, opus.
# The driver keeps wanted beside ran per step ($HARNESS_MODEL_RUNS, else $DRIVER_DIR/model-runs.tsv),
# ran read from the transcript's init event, so the host's record says which model each step
# ran on; the review step's own subagents inherit the session's model instead of pinning one.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../ai-step.sh" || exit 1
export DRIVER_TICKET=101
driver_state_init 101

# The machine says sonnet, both ways a person can say it.
export ANTHROPIC_MODEL=claude-sonnet-5-5
export CLAUDE_CONFIG_DIR="$FIX/home-cfg"; mkdir -p "$CLAUDE_CONFIG_DIR"
printf '{"model":"sonnet"}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
export HARNESS_MODEL_RUNS="$FIX/model-runs.tsv"
KIT="$(cd "$HERE/../.." && pwd)"

# A runner that reports the model it ran on: the full id of the --model alias it was
# given, else the machine default — the way the real CLI's init event does.
mv "$BIN/claude" "$BIN/claude.fixture"
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
m=""; prev=""
for a in "$@"; do [ "$prev" = --model ] && m="$a"; prev="$a"; done
case "$m" in
  fable) ran=claude-fable-5-1 ;; opus) ran=claude-opus-5-5 ;; sonnet) ran=claude-sonnet-5-5 ;;
  "") ran="${ANTHROPIC_MODEL:-claude-sonnet-5-5}" ;; *) ran="$m" ;;
esac
# No init event at all when the suite asks for one, for the record's `none`.
[ -n "${MODEL_PIN_NO_INIT:-}" ] ||
jq -nc --arg m "$ran" '{type:"system", subtype:"init", claude_code_version:"2.1.319", model:$m, tools:["Read","Skill"], skills:[]}'
exec "$(dirname "$0")/claude.fixture" "$@"
SH
chmod +x "$BIN/claude"

cfg="$REPO/.claude/harness.json"
set_models() { # <json or empty to delete>
  if [ -n "$1" ]; then jq --argjson m "$1" '.driver.model = $m' "$cfg" > "$cfg.tmp"
  else jq 'del(.driver.model)' "$cfg" > "$cfg.tmp"; fi
  mv "$cfg.tmp" "$cfg"
}
model_arg() { awk 'p { print; exit } $0 == "--model" { p = 1 }' "$FIX/claude-args-$1.txt" 2>/dev/null; }
ran_model() { jq -r 'select(.type == "system" and .subtype == "init") | .model' "$(driver_state_dir 101)/steps/$1.log" 2>/dev/null | tail -1; }
# The newest record row for a step, as wanted/ran; the whole row when asked for it.
runs_row() { awk -F'\t' -v s="$1" '$3 == s { print $4 "/" $5 }' "$HARNESS_MODEL_RUNS" 2>/dev/null | tail -1; }
agent_model() { awk '/^---$/ { n++; next } n == 1 && /^model:/ { print $2 }' "$KIT/agents/$1.md"; }
run_step() { # <step> [--as slot]
  local step="$1"; shift
  fix_brief "$step" ""
  fix_ai "$step" '{"ok":true}'
  rm -f "$FIX/claude-args-$step.txt"
  ( driver_ai_step 101 "$step" "$@" ) >/dev/null 2>&1 || true
}

echo "--- harness.json names plan and review on fable, the rest on opus ---"
set_models '{"default":"opus","plan":"fable","review":"fable"}'
run_step plan;         want "plan runs on the plan model"            fable "$(model_arg plan)"
run_step review --as review-hunter
                       want "review runs on the review model"        fable "$(model_arg review)"
run_step review-check; want "review-check runs on the review model"  fable "$(model_arg review-check)"
run_step build;        want "build runs on the default model"        opus  "$(model_arg build)"
run_step fix;          want "fix runs on the default model"          opus  "$(model_arg fix)"
run_step compare;      want "compare runs on the default model"      opus  "$(model_arg compare)"
want "and the plan transcript says it ran on fable, not the machine's sonnet" claude-fable-5-1 "$(ran_model plan)"
want "the build transcript says opus"                                        claude-opus-5-5  "$(ran_model build)"
want "the review transcript says fable"                                        claude-fable-5-1 "$(ran_model review-hunter)"

echo "--- the host keeps wanted beside ran, one row per step, read from the transcript ---"
want "plan: wanted fable, ran claude-fable-5-1"   fable/claude-fable-5-1 "$(runs_row plan)"
want "review: wanted fable, ran claude-fable-5-1" fable/claude-fable-5-1 "$(runs_row review)"
want "review-check: wanted fable"                 fable/claude-fable-5-1 "$(runs_row review-check)"
want "build: wanted opus, ran claude-opus-5-5"    opus/claude-opus-5-5   "$(runs_row build)"
want "fix: wanted opus"                           opus/claude-opus-5-5   "$(runs_row fix)"
want "compare: wanted opus"                       opus/claude-opus-5-5   "$(runs_row compare)"
want "one row per step run, five fields each: epoch, ticket, step, wanted, ran" 6 \
  "$(awk -F'\t' 'NF == 5 && $1 ~ /^[0-9]+$/ && $2 == "101"' "$HARNESS_MODEL_RUNS" 2>/dev/null | wc -l | tr -d ' ')"
MODEL_PIN_NO_INIT=1 run_step build
want "a transcript with no init event records ran as none" opus/none "$(runs_row build)"

echo "--- the review step's subagents inherit the review session's model ---"
want "frontend-gate inherits the session model"  inherit "$(agent_model frontend-gate)"
want "design-critic inherits the session model"  inherit "$(agent_model design-critic)"
want "neither pins opus" 0 "$(cat "$KIT/agents/frontend-gate.md" "$KIT/agents/design-critic.md" | grep -c '^model: opus')"

echo "--- the attest reviewers (push-requires.sh) take the review model from the same place ---"
driver_lean_args "$REPO" attest
want_in "attest carries --model fable" '(^|\|)--model\|fable(\||$)' "$(printf '%s\n' "${DRIVER_LEAN_ARGS[@]}" | tr '\n' '|')"
driver_lean_args "$REPO"
want_in "a bare call pins the default" '(^|\|)--model\|opus(\||$)' "$(printf '%s\n' "${DRIVER_LEAN_ARGS[@]}" | tr '\n' '|')"

echo "--- a plan model named with no default: the others still run on opus ---"
set_models '{"plan":"fable"}'
run_step plan;  want "plan on fable"                    fable "$(model_arg plan)"
run_step build; want "build on opus, the default's default" opus "$(model_arg build)"

echo "--- no driver.model at all: every step runs on opus, never the machine's default ---"
set_models ''
run_step plan;  want "plan on opus"   opus "$(model_arg plan)"
run_step build; want "build on opus"  opus "$(model_arg build)"
want "the transcript says opus"       claude-opus-5-5 "$(ran_model build)"
want "and the record says wanted opus, ran opus" opus/claude-opus-5-5 "$(runs_row build)"

echo "--- the value passes through untouched: a full id is a full id ---"
set_models '{"default":"claude-opus-5-5"}'
run_step build; want "a full id is passed as given" claude-opus-5-5 "$(model_arg build)"

suite_end "$FAILED"
