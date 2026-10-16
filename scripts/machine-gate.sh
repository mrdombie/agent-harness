#!/usr/bin/env bash
# machine-gate.sh — heavy local work waits for the machine.
#
#   machine-gate.sh wait   [--max SEC]           wait until the machine is not busy
#   machine-gate.sh run    [--max SEC] -- CMD…   wait for the machine, take a gate slot, run CMD, give the slot back
#   machine-gate.sh status                       cpu idle, load, thresholds, and who holds each slot
#
# Or sourced, for a caller that holds one slot across several commands:
#   . machine-gate.sh; machine_gate_wait_load; machine_gate_acquire; …; machine_gate_release
#
# Every path that starts heavy work calls it: /agent-harness:claim, :work, :auto
# and :bug before they begin, and the local gate step of /agent-harness:finish,
# the gate-runner agent and the driver's self-check around the gate commands.
# The scheduler, the coordinator tick and repair-watch use the same busy test
# (swarm_busy in swarm/load.sh).
#
# BUSY MEANS SAMPLED CPU IDLE BELOW THE FLOOR, not a high load average: macOS
# counts runnable and blocked threads, and on 2026-10-15 it read load 42-103 on
# 10 cores while top showed 41% idle, and 119-140 on 2026-10-16. The load average
# stays only as a runaway guard, at 20 x cores.
#
# IT NEVER FAILS THE TICKET. When busy it prints
#   machine busy (cpu idle N%, floor F%), waiting     or
#   machine busy (load N, limit M), waiting
# and re-checks every MACHINE_GATE_POLL seconds. --max bounds one call's wait so
# it fits inside a tool call's timeout: when it runs out the exit is 75 and
# NOTHING RAN — call it again, never proceed and never give up.
#
#   SWARM_MIN_CPU_IDLE   the idle floor in percent (else harness.json swarm.minCpuIdle, else 15)
#   SWARM_MAX_LOAD       the runaway guard (else harness.json swarm.maxLoad, else 20 x cores)
#   HARNESS_GATE_SLOTS   gate runs at once, machine-wide (else swarm.gateSlots, else 2)
#   HARNESS_GATE_SLOT_DIR  where the slots live (default ~/.cache/agent-harness/gate-slots:
#                        one per MACHINE, not per project — the cores are shared)
#   MACHINE_GATE_POLL    seconds between checks (default 30)
#   MACHINE_GATE_MAX_WAIT  default for --max (0 = wait as long as it takes)
#
# A slot is a directory made with mkdir, which is atomic, holding the holder's
# pid. A holder that died without letting go is found by its pid, not its age.

_mg_self="${BASH_SOURCE[0]}"
. "$(cd "$(dirname "$_mg_self")/../swarm" && pwd)/load.sh" || return 1 2>/dev/null || exit 1
unset _mg_self

MG_BUSY=75

_mg_cfg() { # <jq path> — an optional fact from harness.json, or nothing
  local cfg="${HARNESS_CFG:-${HARNESS_CFG_PATH:-}}"
  [ -n "$cfg" ] || cfg="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/harness.json"
  [ -f "$cfg" ] || return 0
  jq -r "$1 // empty" "$cfg" 2>/dev/null
}

machine_gate_init() {
  MG_MIN_IDLE="${SWARM_MIN_CPU_IDLE:-$(_mg_cfg .swarm.minCpuIdle)}"; MG_MIN_IDLE="${MG_MIN_IDLE:-15}"
  MG_MAX_LOAD="${SWARM_MAX_LOAD:-$(_mg_cfg .swarm.maxLoad)}"; MG_MAX_LOAD="${MG_MAX_LOAD:-$(swarm_default_max_load)}"
  MG_SLOTS="${HARNESS_GATE_SLOTS:-$(_mg_cfg .swarm.gateSlots)}"; MG_SLOTS="${MG_SLOTS:-2}"
  case "$MG_SLOTS" in ''|*[!0-9]*|0) MG_SLOTS=2 ;; esac
  MG_DIR="${HARNESS_GATE_SLOT_DIR:-$HOME/.cache/agent-harness/gate-slots}"
  MG_POLL="${MACHINE_GATE_POLL:-30}"
  mkdir -p "$MG_DIR" 2>/dev/null || true
}

# The pid that owns a slot taken from here. $$ is the script itself when run as a
# command; a caller that sources this file and lives longer than one call (the
# driver) is the same $$, so the slot dies with it either way.
_mg_owner() { printf '%s' "${MACHINE_GATE_OWNER_PID:-$$}"; }

_mg_alive() { [ -n "${1:-}" ] && [ "$1" -gt 0 ] 2>/dev/null && kill -0 "$1" 2>/dev/null; }

# _mg_waited <start-epoch> <max> — 0 while there is still time to wait.
_mg_time_left() { [ "${2:-0}" -le 0 ] && return 0; [ $(( $(date +%s) - $1 )) -lt "$2" ]; }

# Wait until the machine is not busy. 0 when clear, 75 when --max ran out.
machine_gate_wait_load() { # [max-seconds]
  machine_gate_init
  local max="${1:-${MACHINE_GATE_MAX_WAIT:-0}}" start why said=""
  start=$(date +%s)
  while :; do
    if ! why=$(swarm_busy "$MG_MIN_IDLE" "$MG_MAX_LOAD"); then
      [ -n "$said" ] && echo "machine clear ($why), going ahead" >&2
      return 0
    fi
    echo "machine busy ($why), waiting" >&2
    said=1
    _mg_time_left "$start" "$max" || {
      echo "machine still busy after ${max}s ($why) — nothing ran; run the same command again" >&2
      return "$MG_BUSY"; }
    sleep "$MG_POLL"
  done
}

# Clear a slot whose holder is gone. The pid read first can be stale: its holder
# may have let go and exited, and a live taker made the slot again. So the
# verdict is taken again under a per-slot reap lock, and the slot is removed in
# place, never moved: a slot can only change hands through a remove, and every
# remover of a slot that is not its own holds this lock.
_mg_reap() { # <slot-dir>
  local s="$1" lock="$1.reaping" pid
  _mg_slot_dead "$s" || return 1
  if ! mkdir "$lock" 2>/dev/null; then
    # A reaper that died mid-reap leaves its lock; a reap takes milliseconds.
    [ "$(_mg_age "$lock")" -gt 30 ] && rm -rf "$lock"
    return 1
  fi
  if [ -d "$s" ] && _mg_slot_dead "$s"; then
    pid=$(cat "$s/pid" 2>/dev/null)
    rm -rf "$s"
    echo "gate slot $(basename "$s") was held by pid ${pid:-?}, which is gone — freed" >&2
  fi
  rmdir "$lock" 2>/dev/null
  return 0
}

# Seconds since a path last changed; 0 when it is gone.
# GNU stat first: on Linux `stat -f` is the FILESYSTEM and exits 0 with no mtime.
_mg_age() { echo $(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || date +%s) )); }

# 0 when a slot's holder is gone: a dead pid, or no pid long after the mkdir
# (mkdir and the pid write are two steps; a slot seconds old is mid-take).
_mg_slot_dead() { # <slot-dir>
  local pid; pid=$(cat "$1/pid" 2>/dev/null)
  if [ -z "$pid" ]; then [ "$(_mg_age "$1")" -gt 10 ]; else ! _mg_alive "$pid"; fi
}

# Take one of the machine's gate slots. Sets MG_SLOT. 0 when held, 75 when --max ran out.
machine_gate_acquire() { # [max-seconds] [label]
  machine_gate_init
  local max="${1:-${MACHINE_GATE_MAX_WAIT:-0}}" label="${2:-gate}" start i s said=""
  start=$(date +%s)
  while :; do
    i=1
    while [ "$i" -le "$MG_SLOTS" ]; do
      s="$MG_DIR/slot-$i"
      [ -d "$s" ] && _mg_reap "$s"
      if mkdir "$s" 2>/dev/null; then
        printf '%s\n' "$(_mg_owner)" > "$s/pid" 2>/dev/null
        # Reaped between the mkdir and the write: not ours, try again.
        [ "$(cat "$s/pid" 2>/dev/null)" = "$(_mg_owner)" ] || { i=$((i+1)); continue; }
        printf '%s\t%s\t%s\n' "$(date +%s)" "$PWD" "$label" > "$s/what"
        MG_SLOT="$s"
        [ -n "$said" ] && echo "gate slot free, going ahead" >&2
        return 0
      fi
      i=$((i+1))
    done
    echo "machine busy ($MG_SLOTS of $MG_SLOTS gate runs going: $(machine_gate_holders)), waiting" >&2
    said=1
    _mg_time_left "$start" "$max" || {
      echo "no gate slot after ${max}s — nothing ran; run the same command again" >&2
      return "$MG_BUSY"; }
    sleep "$MG_POLL"
  done
}

machine_gate_release() {
  [ -n "${MG_SLOT:-}" ] || return 0
  # Only our own: a slot reaped and re-taken by someone else is theirs now.
  [ "$(cat "$MG_SLOT/pid" 2>/dev/null)" = "$(_mg_owner)" ] && rm -rf "$MG_SLOT"
  MG_SLOT=""
}

machine_gate_holders() {
  local s out="" pid
  for s in "$MG_DIR"/slot-*; do
    [ -d "$s" ] || continue
    case "$s" in *.reap*) continue ;; esac
    pid=$(cat "$s/pid" 2>/dev/null)
    out="$out${out:+, }pid ${pid:-?} in $(cut -f2 "$s/what" 2>/dev/null | xargs basename 2>/dev/null)"
  done
  printf '%s' "${out:-none}"
}

_mg_main() {
  local cmd="${1:-}" max="${MACHINE_GATE_MAX_WAIT:-0}" rc
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --max) max="${2:?--max needs seconds}"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  case "$cmd" in
    wait)
      machine_gate_wait_load "$max" ;;
    run)
      [ $# -gt 0 ] || { echo "machine-gate: run needs a command after --" >&2; return 2; }
      local start left
      start=$(date +%s)
      machine_gate_wait_load "$max" || return $?
      left=0
      [ "$max" -gt 0 ] && { left=$(( max - ($(date +%s) - start) )); [ "$left" -gt 0 ] || left=1; }
      machine_gate_acquire "$left" "$*" || return $?
      trap 'machine_gate_release' EXIT
      trap 'machine_gate_release; exit 130' INT TERM
      "$@"; rc=$?
      machine_gate_release
      return "$rc" ;;
    status)
      machine_gate_init
      local idle load verdict=clear
      idle=$(swarm_cpu_idle); load=$(swarm_load)
      SWARM_IDLE="$idle" SWARM_LOAD="$load" SWARM_IDLE_FILE="" SWARM_LOAD_FILE="" \
        swarm_busy "$MG_MIN_IDLE" "$MG_MAX_LOAD" >/dev/null && verdict=busy
      echo "$verdict · cpu idle $idle% (floor $MG_MIN_IDLE%) · load $load (limit $MG_MAX_LOAD) · gate slots $MG_SLOTS · held: $(machine_gate_holders)" ;;
    *)
      sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _mg_main "$@"; exit $?
fi
