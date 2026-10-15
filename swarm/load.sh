#!/usr/bin/env bash
# load.sh — the machine's 1-minute load average, as a whole number. Sourced by
# swarm-env.sh and by scripts/machine-gate.sh, which must read it without a
# project config.
#
#   SWARM_LOAD       a fixed reading (a test seam)
#   SWARM_LOAD_FILE  a file read on EVERY call, so a test can move the load
#                    while a waiter is polling it
#
# sysctl on macOS, /proc on Linux — the CI runner is Linux and the operator's
# machine is not, so a script that knows only one of them is a script that is
# only ever tested on the other.
swarm_load() {
  if [ -n "${SWARM_LOAD_FILE:-}" ] && [ -f "$SWARM_LOAD_FILE" ]; then
    local f; f=$(head -1 "$SWARM_LOAD_FILE" 2>/dev/null); printf '%s' "${f%%.*}"; return
  fi
  if [ -n "${SWARM_LOAD:-}" ]; then printf '%s' "${SWARM_LOAD%%.*}"; return; fi
  local l=""
  l=$(/usr/sbin/sysctl -n vm.loadavg 2>/dev/null | awk '{print int($2)}')
  [ -n "$l" ] || l=$(awk '{print int($1)}' /proc/loadavg 2>/dev/null)
  printf '%s' "${l:-0}"
}
