#!/usr/bin/env bash
# Self-test for one-preview-per-agent.sh: a server start under an agent session
# hands that session's pid to the stopper; anything else hands it nothing.
set -uo pipefail
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/one-preview-per-agent.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# The hook runs under a stand-in agent session: a process whose command names claude.
run() { # <command> → the stopper's recorded arguments, or nothing
  : > "$T/calls"
  printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" > "$T/in"
  ONE_PREVIEW_STOP_CMD="bash $T/stub.sh" ONE_PREVIEW_DELAY=0 ONE_PREVIEW_LOG="$T/log" \
    bash -c 'exec -a claude bash -c "bash \"\$0\" < \"\$1\"; sleep 1" "$0" "$1"' "$HOOK" "$T/in"
  sleep 1
  cat "$T/calls"
}
printf 'echo "$@" >> %q\n' "$T/calls" > "$T/stub.sh"

echo "one-preview-per-agent"
out=$(run "cd apps/web && npm run dev -- -p 3736")
printf '%s' "$out" | grep -qE '^--session [0-9]+$' && ok "a server start hands the session to the stopper" || fail "server start: '$out'"
out=$(run "npx next dev -p 3010")
printf '%s' "$out" | grep -q -- '--session' && ok "next dev is a server start" || fail "next dev: '$out'"
out=$(run "npm run dev:web")
printf '%s' "$out" | grep -q -- '--session' && ok "npm run dev:web is a server start" || fail "dev:web: '$out'"
out=$(run "git status")
[ -z "$out" ] && ok "an ordinary command stops nothing" || fail "git status: '$out'"
out=$(run "npm run devtools-check")
[ -z "$out" ] && ok "a script merely starting with dev is not a server start" || fail "devtools: '$out'"
: > "$T/calls"
printf '{"tool_input":{"command":"npm run dev"}}' > "$T/in"
# Double fork: the hook's parent exits first, so it runs under launchd with no claude above it.
( (sleep 1; ONE_PREVIEW_STOP_CMD="bash $T/stub.sh" ONE_PREVIEW_DELAY=0 ONE_PREVIEW_LOG="$T/log" bash "$HOOK" < "$T/in") & )
sleep 3
[ -z "$(cat "$T/calls")" ] && ok "outside an agent session nothing is stopped" || fail "no session: '$(cat "$T/calls")'"

echo "one-preview-per-agent: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
