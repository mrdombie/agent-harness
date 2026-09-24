#!/usr/bin/env bash
# Plant tests for lib/claude-session.sh — scope_owned_by_peer.
#
# WHY THIS EXISTS
#   This helper decides whether a Stop hook stays quiet. Every branch of it
#   returns 1 ("not a peer's, carry on") on an uncertain input, which is the
#   safe direction but also the direction that silently disarms the hook if the
#   logic drifts. A test that only checked the happy path would pass against a
#   function whose body was `return 1`.
#
#   So each case below is planted to FAIL if the branch it names stops working,
#   and the suite asserts the peer case genuinely goes quiet — the one branch
#   that changes behaviour.
#
#   claude_session_pid walks the process tree for a real Claude ancestor, which
#   no test can conjure. It is replaced here AFTER sourcing, so what is under
#   test is scope_owned_by_peer's decision table, not the process walk.
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-session.sh"
[ -f "$LIB" ] || { echo "missing $LIB"; exit 2; }
# shellcheck source=claude-session.sh
. "$LIB"

SB="${TMPDIR:-/tmp}/claude-session-fixture-$$"
mkdir -p "$SB"
trap 'rm -rf "$SB"' EXIT
fail=0
ok()   { echo "  ok   — $1"; }
bad()  { echo "  FAIL — $1"; fail=1; }

# A PID that is certainly alive: this shell. And one that is certainly not.
ALIVE=$$
DEAD=$(( 4194304 - 1 ))   # above the default pid_max, so it can never be running

MINE=""   # what the stubbed identity resolves to; "" means unresolvable
claude_session_pid() { [ -n "$MINE" ] && { printf '%s' "$MINE"; return 0; }; return 1; }


echo "claude-session fixture — scope_owned_by_peer"

# 1. THE BEHAVIOUR THAT MATTERS: a different, live owner means keep quiet.
MINE=$ALIVE
printf '%s' "$$" > "$SB/owner"
# owner == us -> not a peer
scope_owned_by_peer "$SB/owner" >/dev/null 2>&1 \
  && bad "our own scope is not treated as a peer's" \
  || ok "our own scope is not treated as a peer's"

# A live PID that is not us. The parent shell qualifies and is certainly alive.
PEER_PID=$(ps -p $$ -o ppid= 2>/dev/null | tr -d ' ')
if [ -n "$PEER_PID" ] && [ "$PEER_PID" != "$MINE" ] && ps -p "$PEER_PID" >/dev/null 2>&1; then
  printf '%s' "$PEER_PID" > "$SB/owner"
  got=$(scope_owned_by_peer "$SB/owner" 2>/dev/null) && rc=0 || rc=1
  [ "$rc" -eq 0 ] && ok "a different LIVE owner is reported as a peer" \
                  || bad "a different LIVE owner is reported as a peer"
  [ "$got" = "$PEER_PID" ] && ok "it echoes the peer's id" || bad "it echoes the peer's id (got '$got')"
else
  bad "fixture could not find a live peer pid to test with"
fi

# 2. Every uncertain input falls through — the hook must stay armed.
MINE=$ALIVE
rm -f "$SB/owner"
scope_owned_by_peer "$SB/owner" >/dev/null 2>&1 \
  && bad "no owner file falls through" || ok "no owner file falls through"

: > "$SB/owner"
scope_owned_by_peer "$SB/owner" >/dev/null 2>&1 \
  && bad "an empty owner file falls through" || ok "an empty owner file falls through"

printf '%s' "$DEAD" > "$SB/owner"
scope_owned_by_peer "$SB/owner" >/dev/null 2>&1 \
  && bad "a DEAD owner falls through" || ok "a DEAD owner falls through"

# 3. Our own identity unresolvable — cannot tell, so do not disarm.
MINE=""
printf '%s' "$DEAD" > "$SB/owner"
scope_owned_by_peer "$SB/owner" >/dev/null 2>&1 \
  && bad "an unresolvable self falls through" || ok "an unresolvable self falls through"

echo
[ "$fail" -eq 0 ] && echo "claude-session fixture: all checks hold" \
                  || echo "claude-session fixture: FAILURES"
exit "$fail"
