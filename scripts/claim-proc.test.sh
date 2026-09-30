#!/usr/bin/env bash
# Fixture test for claim-proc.sh — the pid a claim records must read ALIVE while
# its holder runs and DEAD after, on every platform an agent runs on.
#
# Run by `scripts/claim-proc.test.sh`, with every other tracked suite.
#
# The Windows cases run only on Git Bash / MSYS, where they reproduce the failure
# this file exists for: a bash under a native parent sees PPID 1, `kill -0 1` is
# "no such process", and every claim taken there was released as abandoned.
# Elsewhere they print SKIP — so a green run on the macOS/Linux runner says
# nothing about Windows, and says so.
set -uo pipefail

SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claim-proc.sh"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }
. "$SUT"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP — $1"; }

echo "claim-proc: portable cases"

h=$(claim_host)
if [ -n "$h" ] && [ "${h#*.}" = "$h" ]; then ok "the host is non-empty and short ($h)"
else fail "the host is '$h' — a claim with an empty host is owned by every other empty host"; fi

claim_pid_alive "$$" && ok "this shell reads alive" || fail "this shell reads dead"

( exit 0 ) & dead=$!; wait "$dead"
claim_pid_alive "$dead" && fail "an exited pid ($dead) reads alive" || ok "an exited pid reads dead"

for v in "" null abc 12x; do
  claim_pid_alive "$v" && fail "'$v' reads alive" || ok "'$v' reads dead"
done

got=$(CLAIM_SESSION_PID="$$" claim_session_pid)
[ "$got" = "$$" ] && ok "a live CLAIM_SESSION_PID is the session" || fail "CLAIM_SESSION_PID=$$ gave '$got'"

got=$(CLAIM_SESSION_PID="$dead" claim_session_pid)
[ "$got" != "$dead" ] && ok "a dead CLAIM_SESSION_PID is ignored" || fail "a dead CLAIM_SESSION_PID was recorded"

got=$(unset CLAIM_SESSION_PID; claim_session_pid)
claim_pid_alive "$got" && ok "the walked session pid ($got) reads alive" \
  || fail "the walked session pid ($got) reads dead — every claim from here would be released"

echo "claim-proc: Windows cases"
if ! claim_is_windows; then
  skip "not Git Bash / MSYS — the native-parent cases cannot run here"
else
  powershell.exe -NoProfile -NonInteractive -Command "Start-Sleep 60" >/dev/null 2>&1 &
  native=$!
  sleep 1
  winpid=$(cat "/proc/$native/winpid" 2>/dev/null || true)
  if [ -z "$winpid" ]; then
    fail "no /proc/$native/winpid for a native child"
  else
    kill -0 "$winpid" 2>/dev/null \
      && skip "kill -0 happens to see native pid $winpid (collides with an MSYS pid)" \
      || ok "kill -0 cannot see a native pid — the premise"
    claim_pid_alive "$winpid" && ok "a live native pid reads alive" || fail "a live native pid ($winpid) reads dead"
    kill "$native" 2>/dev/null; wait "$native" 2>/dev/null
    sleep 1
    claim_pid_alive "$winpid" && fail "an exited native pid ($winpid) reads alive" || ok "an exited native pid reads dead"
  fi

  # A bash launched by a native process: PPID is 1, so the old $PPID fallback
  # recorded a dead pid. Launch one through PowerShell and ask it.
  probe=$(mktemp "${TMPDIR:-/tmp}/claim-proc-probe-XXXXXX.sh")
  cat > "$probe" <<PROBE
. '$SUT'
unset CLAIM_SESSION_PID
p=\$(claim_session_pid)
echo "ppid=\$PPID session=\$p alive=\$(claim_pid_alive "\$p" && echo yes || echo no)"
PROBE
  out=$(powershell.exe -NoProfile -NonInteractive -Command "& '$(cygpath -w "$BASH")' '$(cygpath -w "$probe")'" 2>&1 | tr -d '\r')
  rm -f "$probe"
  case "$out" in
    *"ppid=1 "*"alive=yes"*) ok "under a native parent (PPID 1) the session pid reads alive ($out)" ;;
    *"alive=yes"*)           skip "the probe's PPID was not 1 ($out) — the premise did not reproduce" ;;
    *)                       fail "under a native parent the session pid reads dead ($out)" ;;
  esac

  if [ -n "${CLAUDECODE:-}" ]; then
    s=$(claim_win_session_pid)
    name=$(powershell.exe -NoProfile -NonInteractive -Command "(Get-Process -Id ${s:-0} -ErrorAction SilentlyContinue).ProcessName" 2>/dev/null | tr -d '\r')
    [ "$name" = "claude" ] && ok "inside Claude Code the walk finds claude.exe ($s)" \
      || fail "inside Claude Code the walk found '${name:-nothing}' ($s)"
  else
    skip "not inside a Claude Code session — cannot check the walk reaches claude.exe"
  fi
fi

echo
echo "claim-proc: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
