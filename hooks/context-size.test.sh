#!/usr/bin/env bash
# context-size.sh — the Stop hook tells the operator when a window's context has
# grown past the limit: a systemMessage in the window and a ping naming it, once
# at the limit and once per step above it, and never a refused stop.
# Then the plants: the message removed, and the helper filter removed, must each
# turn their case red.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB=$(mktemp -d "${TMPDIR:-/tmp}/context-size-XXXXXX"); on_exit_keep_status 'rm -rf "$SB"'
unset HARNESS_DRIVER_RUN HARNESS_HEADLESS HARNESS_CONTEXT_WARN_TOKENS HARNESS_CONTEXT_WARN_STEP
export TMPDIR="$SB/tmp"; mkdir -p "$TMPDIR"
# The ping is recorded, never sent to the desktop running the suite.
cat > "$SB/ping" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$PINGS"
SH
chmod +x "$SB/ping"
export HARNESS_CONTEXT_NOTIFY_CMD="$SB/ping" PINGS="$SB/pings"
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }
H="$HERE/context-size.sh"
TP="$SB/t.jsonl"

reply() { # <cache-read tokens> [sidechain]
  jq -nc --argjson n "$1" --argjson s "${2:-false}" \
    '{type:"assistant",isSidechain:$s,message:{usage:{input_tokens:10,cache_creation_input_tokens:990,cache_read_input_tokens:($n-1000),output_tokens:50}}}' >> "$TP"
}
fresh() { rm -rf "$TMPDIR/claude-context-size" "$PINGS" "$TP"
  echo '{"type":"ai-title","aiTitle":"Billing fixes"}' > "$TP"; }
stop() { # <hook> — prints the hook's stdout; its exit code is kept in RC
  jq -nc --arg t "$TP" '{hook_event_name:"Stop",session_id:"s1",transcript_path:$t}' | bash "$1"; }
pings() { [ -f "$PINGS" ] && wc -l < "$PINGS" | tr -d ' ' || echo 0; }

echo "under the limit"
fresh; reply 120000
out=$(stop "$H"); rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && [ "$(pings)" = 0 ] && ok "120k: silent, no ping" || bad "120k said something: '$out' rc=$rc pings=$(pings)"

echo "over the limit"
warn_case() { fresh; reply 120000; reply 430000
  out=$(stop "$1"); rc=$?
  [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.systemMessage // ""' 2>/dev/null | grep -c '430k of context')" = 1 ]; }
warn_case "$H" && ok "430k: the window is told, with the size, and the stop is not refused" || bad "430k: no systemMessage naming 430k (out='$out' rc=$rc)"
[ "$(printf '%s' "$out" | jq -r 'has("decision") or has("hookSpecificOutput")')" = false ] && ok "nothing in the output continues the turn" || bad "the output carries a decision or context: $out"
[ "$(cat "$PINGS" 2>/dev/null)" = "Restart a window|Billing fixes: 430k of context. Restart it." ] && ok "the ping names the window" || bad "ping was: $(cat "$PINGS" 2>/dev/null)"

echo "once per step, not every turn"
reply 445000; out=$(stop "$H")
[ -z "$out" ] && [ "$(pings)" = 1 ] && ok "445k, same step: silent" || bad "445k warned again: '$out' pings=$(pings)"
reply 520000; out=$(stop "$H")
[ -n "$out" ] && [ "$(pings)" = 2 ] && ok "520k, next step: told again" || bad "520k was silent (pings=$(pings))"
reply 310000; out=$(stop "$H")
[ -z "$out" ] && ok "shrunk to 310k: silent" || bad "a smaller context warned: $out"
reply 415000; out=$(stop "$H")
[ -n "$out" ] && ok "grown back to 415k: told again" || bad "regrowth after shrinking was silent"
reply 90000; stop "$H" >/dev/null; reply 305000; out=$(stop "$H")
[ -n "$out" ] && ok "under the limit resets it: 305k is told" || bad "after dropping under the limit, 305k was silent"

echo "what is not this window's context"
side_case() { fresh; reply 120000; reply 700000 true
  out=$(stop "$1"); [ -z "$out" ]; }
side_case "$H" && ok "a helper's 700k reply is not read" || bad "a helper's reply was read as the window's: $out"
fresh; reply 430000
out=$(HARNESS_DRIVER_RUN=1 bash -c "$(declare -f stop); TP='$TP'; stop '$H'")
[ -z "$out" ] && [ "$(pings)" = 0 ] && ok "a driver run is not told" || bad "a driver run was told: $out"
out=$(HARNESS_HEADLESS=judge bash -c "$(declare -f stop); TP='$TP'; stop '$H'")
[ -z "$out" ] && [ "$(pings)" = 0 ] && ok "a headless run is not told" || bad "a headless run was told: $out"
out=$(jq -nc '{hook_event_name:"Stop",session_id:"s1",transcript_path:"/nonexistent/x.jsonl"}' | bash "$H"); rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && ok "no transcript: silent, exit 0" || bad "no transcript: '$out' rc=$rc"
fresh; reply 430000; echo 'not json {' >> "$TP"
out=$(stop "$H"); [ -n "$out" ] && ok "a broken line in the transcript does not hide the size" || bad "a broken line silenced the warning"
fresh; reply 250000
out=$(HARNESS_CONTEXT_WARN_TOKENS=200000 bash -c "$(declare -f stop); TP='$TP'; stop '$H'")
[ -n "$out" ] && ok "the limit can be set lower" || bad "HARNESS_CONTEXT_WARN_TOKENS was not read"

echo "plants"
d="$SB/kit"; mkdir -p "$d"; cp -R "$HERE" "$d/hooks"
python3 - "$d/hooks/context-size.sh" <<'PY' || bad "plant did not land"
import sys
p = sys.argv[1]; s = open(p).read()
a = '''jq -nc --arg m "$MSG" '{systemMessage:$m}'\n'''
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, ""))
PY
grep -q 'systemMessage:\$m' "$d/hooks/context-size.sh" && bad "plant: the message is still in the copy"
warn_case "$d/hooks/context-size.sh" && bad "planted: the message deleted → still green" || ok "planted: the message deleted → red"
d2="$SB/kit2"; mkdir -p "$d2"; cp -R "$HERE" "$d2/hooks"
python3 - "$d2/hooks/context-size.sh" <<'PY' || bad "plant did not land"
import sys
p = sys.argv[1]; s = open(p).read()
a = ''' and (.isSidechain | not)'''
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, ""))
PY
grep -q 'isSidechain | not' "$d2/hooks/context-size.sh" && bad "plant: the helper filter is still in the copy"
side_case "$d2/hooks/context-size.sh" && bad "planted: the helper filter deleted → still green" || ok "planted: the helper filter deleted → a helper's reply is read → red"
suite_end "$fail"
