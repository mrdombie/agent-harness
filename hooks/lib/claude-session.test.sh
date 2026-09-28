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

# --- THE SCOPE AND ITS OWNER ARE TWO FILES -----------------------------------
# A flow that writes the scope and not the owner leaves the previous owner's id
# behind. The hook then reads "owner == me", lets the nag through, and demands a
# banner for a scope this session never chose. Measured 2026-09-24: label 10:37,
# owner 09:54 — 43 minutes stale, and the id in it was this session's.
#
# These cases pass the LABEL path's sibling, so the staleness rule is live; the
# cases above pass a bare path, which is how they exercise the rest of the table.
LBL="$SB/.session-label"
MINE=$ALIVE

printf 'someone elses scope\t2026-09-24T10:37:10+0100\n' > "$LBL"
printf '%s' "$ALIVE" > "$LBL.owner"
# Make the owner OLDER than the label, which is the whole condition.
touch -t 202609240954 "$LBL.owner"
touch -t 202609241037 "$LBL"
got=$(scope_owned_by_peer "$LBL.owner" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && ok "a label newer than its owner file is not ours to announce" \
                || bad "a label newer than its owner file is not ours to announce (rc $rc)"
[ "$got" = "unclaimed" ] && ok "and it says the scope was never claimed" \
                         || bad "and it says the scope was never claimed (got '$got')"

# THE CONTROL. Without it the rule could be "always go quiet", which disarms the
# hook for the solo session it exists to serve.
printf 'our own scope\t2026-09-24T10:37:10+0100\n' > "$LBL"
printf '%s' "$ALIVE" > "$LBL.owner"
touch -t 202609241037 "$LBL"
touch -t 202609241037 "$LBL.owner"
scope_owned_by_peer "$LBL.owner" >/dev/null 2>&1 \
  && bad "a session that wrote both together is still nagged" \
  || ok "a session that wrote both together is still nagged"

# And an owner written AFTER the label — the ordinary order for a flow that
# writes the label first — is ownership, not staleness.
touch -t 202609241038 "$LBL.owner"
scope_owned_by_peer "$LBL.owner" >/dev/null 2>&1 \
  && bad "an owner written after the label is ownership" \
  || ok "an owner written after the label is ownership"

# A peer that DID claim the scope still wins over the staleness rule.
printf '%s' "$$" > "$LBL.owner"; MINE=$DEAD
touch -t 202609241038 "$LBL.owner"
got=$(scope_owned_by_peer "$LBL.owner" 2>/dev/null); rc=$?
MINE=$ALIVE
# BOTH ARMS USED TO CALL ok(), so this case could not fail — and it is the only
# one covering "label exists, owner newer than label, live peer", the branch the
# whole file exists to protect. A one-line plant (`return 1` inside the
# label-vs-owner block) made the peer guard go quiet for every real
# label-bearing scope and this row still printed ok.
if [ "$rc" -eq 0 ] && [ "$got" = "$$" ]; then
  ok "a live peer that did claim it is still named"
else
  bad "a live peer that did claim it is still named (rc $rc got '$got')"
fi


# ---------------------------------------------------------------------------
# THE WALK ITSELF. Every case above stubs claude_session_pid out, so none of
# them can see it break — and it HAD broken: the matcher named one launcher's
# argv[0] (`*native-binary/claude`) while `ps -o comm=` reports the basename,
# so the real function returned 1 everywhere and the peer guard was inert.
#
# Driven through a fake `ps` on PATH, so the suite asserts the matching rule
# rather than whatever happens to be running on the machine.
echo
echo "--- claude_session_pid: the real walk ---"
WALKDIR=$(mktemp -d); trap 'rm -rf "$WALKDIR"' EXIT

# $1 = the comm= that PID 100 reports. The tree is 300 -> 200 -> 100 -> 1.
fake_ps() {
  cat > "$WALKDIR/ps" <<PS
#!/usr/bin/env bash
pid=""; want=""
while [ \$# -gt 0 ]; do
  case "\$1" in -p) pid=\$2; shift 2 ;; -o) want=\$2; shift 2 ;; *) shift ;; esac
done
case "\$want" in
  comm=) case "\$pid" in 100) echo '$1' ;; 200) echo /bin/zsh ;; 300) echo /bin/bash ;; esac ;;
  ppid=) case "\$pid" in 300) echo 200 ;; 200) echo 100 ;; 100) echo 1 ;; esac ;;
esac
PS
  chmod +x "$WALKDIR/ps"
}

walk(){ ( PATH="$WALKDIR:$PATH"
          unset -f claude_session_pid
          . "$(cd "$(dirname "$0")" && pwd)/claude-session.sh"
          claude_session_pid 300 ); }

wcase(){ fake_ps "$1"; got=$(walk); rc=$?
  [ "$rc" -ne 0 ] && got="(unresolved)"
  if [ "$got" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 — want '$2', got '$got'"; fail=1; fi; }

wcase "claude"                          100           "bare 'claude' resolves (the live shape, 2026-09-28)"
wcase "/opt/x/native-binary/claude"     100           "the full native-binary path still resolves"
wcase "/opt/homebrew/bin/claude"        100           "any absolute path to claude resolves"
wcase "claude-foo"                      "(unresolved)" "a different binary whose name starts with claude does NOT"
wcase "node"                            "(unresolved)" "no claude ancestor is unresolved, not a false match"

echo
[ "$fail" -eq 0 ] && echo "claude-session fixture: all checks hold" \
                  || echo "claude-session fixture: FAILURES"
exit "$fail"
