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

# Echo the PID of the Claude ancestor of $1 (default: this shell).
# Echoes nothing and returns 1 when it cannot resolve.
#
# MATCH THE BASENAME, NOT ONE INSTALL LAYOUT. This matched `*native-binary/claude`
# alone, which is the argv[0] of ONE way of launching the CLI. Measured
# 2026-09-28 on a live session, `ps -o comm=` reported plain `claude` — so the
# walk returned 1, every caller took its "identity unresolvable" branch, and the
# peer-ownership guard had never once fired. Nothing caught it because the only
# test of the callers STUBS this function out, and the stub always resolved.
#
# The trailing-component match covers every launcher (`claude`,
# `…/native-binary/claude`, a Homebrew shim) while still refusing a different
# binary whose name merely starts with it (`claude-foo`).
claude_session_pid() {
  local P=${1:-$$}
  while [ "$P" -gt 1 ] 2>/dev/null; do
    case "$(ps -p "$P" -o comm= 2>/dev/null)" in
      claude|*/claude) printf '%s' "$P"; return 0 ;;
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
# Seconds since the epoch for $1, or "" — GNU and BSD stat disagree on the flag.
_cs_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true
}

scope_owned_by_peer() {
  local owner_file
  owner_file=$1
  local owner mine label lt ot
  [ -f "$owner_file" ] || return 1

  # THE SCOPE AND ITS OWNER ARE TWO FILES, written by two statements. A flow
  # that sets the scope and not the owner leaves the previous owner's id in
  # place — so the hook reads "owner == me", lets the nag through, and demands a
  # banner for a scope this session never chose. Measured 2026-09-24: the label
  # said another programme, stamped 10:37; the owner file still said this
  # session, stamped 09:54, 43 minutes earlier.
  #
  # An owner file OLDER than the label it is supposed to describe is not
  # ownership, it is a leftover. Nobody claimed this scope, so it is not ours to
  # announce — and agent-signoff.md is explicit that a wrong roster is worse than
  # none. Report it as unclaimed and let the caller go quiet.
  #
  # A session that writes both together is unaffected: the owner lands at or
  # after the label. The check is skipped entirely when the caller passes a path
  # with no matching label file, which is how the fixtures drive the rest of the
  # decision table.
  label="${owner_file%.owner}"
  if [ "$label" != "$owner_file" ] && [ -f "$label" ]; then
    lt=$(_cs_mtime "$label"); ot=$(_cs_mtime "$owner_file")
    if [ -n "$lt" ] && [ -n "$ot" ] && [ "$ot" -lt "$lt" ] 2>/dev/null; then
      printf 'unclaimed'
      return 0
    fi
  fi

  owner=$(head -1 "$owner_file" 2>/dev/null | tr -d '[:space:]')
  [ -n "$owner" ] || return 1
  mine=$(claude_session_pid) || return 1
  [ -n "$mine" ] || return 1
  [ "$owner" != "$mine" ] || return 1
  ps -p "$owner" >/dev/null 2>&1 || return 1
  printf '%s' "$owner"
  return 0
}
