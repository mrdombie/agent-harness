#!/usr/bin/env bash
# Shared session-ownership helpers for the Stop hooks.
#
# WHY: the coordination files under the state dir (.session-label,
# .loop-active, .stop-reason) are single global slots, and several agents run at
# once. the work flows record the owning session in .session-label.owner as the Claude
# session PID. Both hooks must derive the SAME value to compare against it.
#
# Measured 2026-09-18: session 73885 was told to ship nine tickets from session
# 58632's scope, and printed 58632's area in its sign-off three times, because
# neither hook ever opened the owner file.
#
# The two sides used different identity schemes, which is why the check was
# never wired up: the hook payload carries a session UUID, while /work records a
# PID. Walking the process tree is the bridge.

# Echo the PID of the native-binary/claude ancestor of $1 (default: this shell).
# Echoes nothing and returns 1 when it cannot resolve.
claude_session_pid() {
  local P=${1:-$$}
  while [ "$P" -gt 1 ] 2>/dev/null; do
    case "$(ps -p "$P" -o comm= 2>/dev/null)" in
      *native-binary/claude) printf '%s' "$P"; return 0 ;;
    esac
    P=$(ps -p "$P" -o ppid= 2>/dev/null | tr -d ' ')
    [ -n "$P" ] || return 1
  done
  return 1
}

# Is the recorded scope owned by a DIFFERENT, LIVE session? Echoes that PID and
# returns 0 when so.
#
# Returns 1 — "not a peer's, carry on" — for every uncertain case: no owner file,
# empty owner, dead owner, or our own identity unresolvable. That direction is
# deliberate. A guard that goes quiet when it cannot tell is a guard that
# silently disarms the hook, which is the failure this file exists to stop.
scope_owned_by_peer() {
  local owner_file=$1 owner mine
  [ -f "$owner_file" ] || return 1
  owner=$(head -1 "$owner_file" 2>/dev/null | tr -d '[:space:]')
  [ -n "$owner" ] || return 1
  mine=$(claude_session_pid) || return 1
  [ -n "$mine" ] || return 1
  [ "$owner" != "$mine" ] || return 1
  ps -p "$owner" >/dev/null 2>&1 || return 1
  printf '%s' "$owner"
  return 0
}
