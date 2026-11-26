#!/usr/bin/env bash
# gate-timeout-memory.test.sh — a self-check gate that runs out of time while the
# machine is out of memory goes back on the queue and says so; with memory to spare
# on a quiet machine it parks with the old wording. Memory is judged on what was seen
# while the command ran, not after it was stopped and gave its memory back.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../driver-env.sh" || exit 1
. "$HERE/../steps/self-check.sh" || exit 1
. "$HERE/../../scripts/machine-gate.sh" || exit 1

export DRIVER_TICKET=1 SWARM_IDLE=80 SWARM_LOAD=1 SWARM_SWAP_PCT=0
export SWARM_MIN_FREE_MEM_PCT=10 SWARM_MAX_SWAP_PCT=90
unset SWARM_FREE_MEM_PCT_FILE SWARM_SWAP_PCT_FILE SWARM_SWAP_COUNTS_BELOW 2>/dev/null
CMD='npm run typecheck:changed'

if suite_case "the fixture fakes memory: a host short of memory does not hold a driver test"; then
  printf 'MemTotal:       1000 kB\nMemAvailable:     50 kB\nSwapTotal:         0 kB\nSwapFree:          0 kB\n' > "$FIX/tight-meminfo"
  rc=0; ( SWARM_MEM_OS=Linux SWARM_MEMINFO="$FIX/tight-meminfo" machine_gate_wait_load 2 ) >/dev/null 2>&1 || rc=$?
  want "the gate goes ahead on the fixture's reading" 0 "$rc"
fi

# mem_gate <during> <after> — a gate's command that runs out of time: free memory reads
# <during>% while it runs and <after>% once it has been stopped.
mem_gate() { printf '%s\n' "$1" > "$FIX/mem-pct"; sleep 2; printf '%s\n' "$2" > "$FIX/mem-pct"; return 124; }

if suite_case "out of memory while it ran, memory back once stopped: a second timeout requeues and names memory"; then
  driver_state_init 1
  rc=0; out=$(
    export SWARM_FREE_MEM_PCT_FILE="$FIX/mem-pct" MACHINE_GATE_MEM_SAMPLE=0.2
    _driver_gate_watched mem_gate 5 60 >/dev/null 2>&1
    _driver_gate_timed_out typecheck 900 "$CMD" 0 2>&1) || rc=$?
  note=$(driver_state_get 1 park_note)
  want "it requeues"                       "$DRIVER_E_BUSY" "$rc"
  want_in "the said line names memory"     'the machine was out of memory \(free memory 5%, floor 10%\)' "$out"
  want_in "the park note names memory"     'the machine was out of memory \(free memory 5%, floor 10%\)' "$note"
  want_not_in "it does not blame a quiet machine" 'quiet machine' "$note"
  want_not_in "it does not blame watch mode"      'watch-mode' "$note"
fi

if suite_case "memory to spare while it ran, tight once stopped: it parks and names no memory"; then
  driver_state_init 1
  rc=0; out=$(
    export SWARM_FREE_MEM_PCT_FILE="$FIX/mem-pct" MACHINE_GATE_MEM_SAMPLE=0.2
    _driver_gate_watched mem_gate 60 5 >/dev/null 2>&1
    _driver_gate_timed_out typecheck 900 "$CMD" 0 2>&1) || rc=$?
  want "it parks"                          "$DRIVER_E_TIMEOUT" "$rc"
  want_not_in "no memory named"            'out of memory' "$(driver_state_get 1 park_note)"
fi

if suite_case "memory to spare on a quiet machine: it parks with today's wording"; then
  driver_state_init 1
  rc=0; out=$(SWARM_FREE_MEM_PCT=60 _driver_gate_timed_out typecheck 900 "$CMD" 0 2>&1) || rc=$?
  want "it parks"                          "$DRIVER_E_TIMEOUT" "$rc"
  want "today's park note"                 "the 'typecheck' gate did not return within 900s, twice, on a quiet machine: $CMD" "$(driver_state_get 1 park_note)"
fi

if suite_case "out of memory while it ran: the first timeout says so"; then
  out=$(
    export SWARM_FREE_MEM_PCT_FILE="$FIX/mem-pct" MACHINE_GATE_MEM_SAMPLE=0.2
    machine_gate_release() { :; }; machine_gate_wait_load() { :; }; machine_gate_acquire() { :; }
    _driver_gate_watched mem_gate 5 60 >/dev/null 2>&1
    DRIVER_CMD_TIMEOUT=900 _driver_gate_quiet_retry typecheck 900 2>&1
  )
  want_in "the first timeout names memory" 'with the machine out of memory \(free memory 5%, floor 10%\)' "$out"
fi

suite_end "$FAILED"
