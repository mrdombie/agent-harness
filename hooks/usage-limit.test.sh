#!/usr/bin/env bash
# usage-limit.sh — the StopFailure hook writes down when the plan's usage limit
# resets, in the file the coordinator tick and the scheduler read. The reset is
# read exactly; other API errors hold nothing; the later of two walls is kept.
# Then the plant: the write removed must turn the recording case red.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB=$(mktemp -d "${TMPDIR:-/tmp}/usage-limit-XXXXXX"); trap 'rm -rf "$SB"' EXIT
unset HARNESS_CFG_PATH CLAUDE_PROJECT_DIR
export HARNESS_STATE_DIR="$SB/state"
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }
NOW=1792050000                     # a fixed instant: 2026-10-15 ~08:20 in London
ep() { USAGE_LIMIT_NOW=$NOW bash "$1" --reset-epoch "$2"; }
fire() { # <hook> <error> <details>
  jq -nc --arg e "$2" --arg d "$3" '{hook_event_name:"StopFailure",error:$e,error_details:$d}' \
    | (cd "$SB" && USAGE_LIMIT_NOW=$NOW bash "$1")
}
H="$HERE/usage-limit.sh"

echo "the reset time"
out=$(ep "$H" "You have hit your session limit · resets 2:40am (Europe/London)")
e=$(TZ=Europe/London date -r "$out" +%H:%M 2>/dev/null || TZ=Europe/London date -d "@$out" +%H:%M)
[ "$e" = "02:40" ] && [ "$out" -gt "$NOW" ] && ok "the next 02:40 London" || bad "read $out ($e), not the next 02:40 London"
[ "$(ep "$H" 'x "resetsAt":1792120000 y')" = 1792120000 ] && ok "resetsAt is taken exactly" || bad "resetsAt not taken exactly"
[ "$(ep "$H" "You have hit your session limit")" = $((NOW + 3600)) ] && ok "a wall with no time holds an hour" || bad "a wall with no time is not held an hour"
ep "$H" "all fine" >/dev/null && bad "a message with no limit set a reset" || ok "a message with no limit sets nothing"

echo "the hook"
rec_case() { rm -rf "$HARNESS_STATE_DIR"; fire "$1" rate_limit "You have hit your session limit · resets 2:40am (Europe/London)"
  [ -s "$HARNESS_STATE_DIR/usage-hold" ]; }
rec_case "$H" && ok "StopFailure on rate_limit records the reset" || bad "StopFailure on rate_limit recorded nothing"
rm -rf "$HARNESS_STATE_DIR"; fire "$H" authentication_failed "bad token"
[ -e "$HARNESS_STATE_DIR/usage-hold" ] && bad "an auth failure was read as a usage wall" || ok "other API errors hold nothing"
rm -rf "$HARNESS_STATE_DIR"
fire "$H" rate_limit 'weekly "resetsAt":1792500000'; fire "$H" rate_limit 'session "resetsAt":1792060000'
[ "$(cut -f1 "$HARNESS_STATE_DIR/usage-hold")" = 1792500000 ] && ok "the later of two walls is kept" || bad "a nearer wall replaced the later one"

echo "plants"
d="$SB/kit"; mkdir -p "$d"; cp -R "$HERE" "$d/hooks"
python3 - "$d/hooks/usage-limit.sh" <<'PY' || bad "plant did not land"
import sys
p = sys.argv[1]; s = open(p).read()
a = '''  printf '%s\\t%s\\n' "$E"'''
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, '''  : printf '%s\\t%s\\n' "$E"'''))
PY
rec_case "$d/hooks/usage-limit.sh" && bad "planted: the hold is never written → still green" || ok "planted: the hold is never written → red"
exit $fail
