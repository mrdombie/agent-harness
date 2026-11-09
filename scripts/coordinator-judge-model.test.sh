#!/usr/bin/env bash
# coordinator-judge-model.test.sh — the judge runs on the model harness.json names under
# coordinator.judge.model, opus when the key is unset: its `claude -p` carries `--model`,
# so the machine's default model never decides.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
J="$HERE/coordinator-judge.sh"
C="$STATE/coordinator"
CFG="$REPO/.claude/harness.json"

cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
{ printf 'ARGV'; printf ' [%s]' "$@"; printf '\n'; } >> "$FIX/claude.log"
SH
chmod +x "$BIN/claude"
export COORDINATOR_CLAUDE="$BIN/claude" COORDINATOR_JUDGES=5

ev() { # <ticket> <run> — a stood-down event for an open ticket nobody is building: a judge's
  jq -cn --arg id "stood-down:$2" --arg t "$1" \
    '{id:$id, at:(now|todate), kind:"stood-down", judge:true, ticket:$t, pr:"", detail:"parked on the PM"}' >> "$C/events.did.jsonl"
}
fresh() {
  rm -rf "$C" "$STATE/runs"/* "$STATE/swarm/prs.json" "$FIX"/gh/issue-*.json; mkdir -p "$C/judges"
  : > "$FIX/claude.log"; printf '[]\n' > "$FIX/gh/prs-all.json"
}
judge() { COORDINATOR_SHADOW=0 bash "$J" >/dev/null 2>&1; for _ in $(seq 1 30); do [ -s "$FIX/claude.log" ] && break; sleep 0.1; done; sleep 0.2; }
model_arg() { grep -oE '\[--model\] \[[^]]*\]' "$FIX/claude.log" | head -1; }

echo "--- coordinator.judge.model = fable: the judge runs on fable ---"
fresh
jq '.coordinator.judge.model = "fable"' "$CFG" > "$CFG.new" && mv "$CFG.new" "$CFG"
fix_issue 701 OPEN status:parked
ev 701 claim-701-a
judge
want "one judge started"              "1" "$(grep -c ^ARGV "$FIX/claude.log")"
want "and its argv carries the model" "[--model] [fable]" "$(model_arg)"

echo "--- the key removed: the judge runs on opus, whatever the machine default ---"
fresh
jq 'del(.coordinator.judge.model)' "$CFG" > "$CFG.new" && mv "$CFG.new" "$CFG"
fix_issue 702 OPEN status:parked
ev 702 claim-702-a
judge
want "one judge started"               "1" "$(grep -c ^ARGV "$FIX/claude.log")"
want "and its argv falls back to opus" "[--model] [opus]" "$(model_arg)"

suite_end "$FAILED"
