#!/usr/bin/env bash
# coordinator-env.sh — where the coordinator keeps its state, and its settings.
#
#   . "$KIT_ROOT/scripts/coordinator-env.sh" || exit 1
#
# Sources swarm/swarm-env.sh, so every call out of the process goes through the
# same seams the swarm tests already drive (SWARM_GH, SWARM_SPAWN, SWARM_NOW).
#
# Sets:
#   COORD_DIR        $STATE_DIR/coordinator — the queue, events, logs
#   COORD_QUEUE      queue.json: scope, ordered tickets, class, note
#   COORD_EVENTS     events.<would|did>.jsonl: one line per event, written once
#   COORD_ACTIONS    actions.log: every act, "would" in shadow, "did" live
#   COORD_NEEDS_YOU  needs-you.md: what /agent-harness:needsme reads first
#   COORD_SHADOW     1 unless COORDINATOR_SHADOW=0 — shadow is the default
#
# Settings, all optional under `coordinator` in harness.json (or the env var):
#   coordinator.cap          COORDINATOR_CAP          unset  optional hard ceiling on live runs;
#                                                           unset, the machine decides (coord_room)
#   coordinator.startCpuIdle COORDINATOR_START_CPU_IDLE 30  idle % needed to start one more; sits
#                                                           above swarm.minCpuIdle, the hold floor
#   coordinator.minFreeMemGb COORDINATOR_MIN_FREE_MEM_GB 4  free memory needed to start one more
#   coordinator.healingShare COORDINATOR_HEALING_SHARE 0.25 share of the ceiling kept for healing
#                                                           (repair + approved-merge), rounded up
#   coordinator.minFreeGb    COORDINATOR_MIN_FREE_GB   20    disk alarm floor
#   coordinator.sweepEveryMin COORDINATOR_SWEEP_EVERY_MIN 30  worktree sweep interval
#   coordinator.frozenMin    COORDINATOR_FROZEN_MIN    20    no log growth = frozen
#   coordinator.judges       COORDINATOR_JUDGES         1    judges at once
#   coordinator.judge.turns  COORDINATOR_JUDGE_TURNS   40
#   coordinator.judge.budgetUsd   COORDINATOR_JUDGE_BUDGET_USD   5
#   coordinator.judge.compactWindow  COORDINATOR_JUDGE_COMPACT  150000

_coord_self="${BASH_SOURCE[0]}"
. "$(cd "$(dirname "$_coord_self")/../swarm" && pwd)/swarm-env.sh" || return 1 2>/dev/null || exit 1
unset _coord_self

COORD_DIR="${COORDINATOR_DIR:-$STATE_DIR/coordinator}"
mkdir -p "$COORD_DIR/judges" 2>/dev/null || true
COORD_QUEUE="$COORD_DIR/queue.json"
COORD_SHADOW="${COORDINATOR_SHADOW:-1}"
COORD_ACTIONS="$COORD_DIR/actions.log"
COORD_NEEDS_YOU="$COORD_DIR/needs-you.md"
COORD_LOG="$COORD_DIR/tick.log"
COORD_CAP="${COORDINATOR_CAP:-$(swarm_opt coordinator.cap "")}"
case "$COORD_CAP" in *[!0-9]*|0) COORD_CAP="" ;; esac
COORD_START_IDLE="${COORDINATOR_START_CPU_IDLE:-$(swarm_opt coordinator.startCpuIdle 30)}"
case "$COORD_START_IDLE" in ""|*[!0-9]*) COORD_START_IDLE=30 ;; esac
# A start floor at or under the hold floor is no hysteresis: the count would flap.
[ "$COORD_START_IDLE" -gt "${SWARM_MIN_CPU_IDLE:-15}" ] 2>/dev/null || COORD_START_IDLE=$(( ${SWARM_MIN_CPU_IDLE:-15} + 15 ))
COORD_MIN_FREE_MEM_GB="${COORDINATOR_MIN_FREE_MEM_GB:-$(swarm_opt coordinator.minFreeMemGb 4)}"
case "$COORD_MIN_FREE_MEM_GB" in ""|*[!0-9]*) COORD_MIN_FREE_MEM_GB=4 ;; esac
COORD_HEAL_SHARE="${COORDINATOR_HEALING_SHARE:-$(swarm_opt coordinator.healingShare 0.25)}"
awk -v s="$COORD_HEAL_SHARE" 'BEGIN{exit !(s ~ /^(0|1|0?\.[0-9]+|1\.0*)$/)}' || COORD_HEAL_SHARE=0.25
COORD_MIN_FREE_GB="${COORDINATOR_MIN_FREE_GB:-$(swarm_opt coordinator.minFreeGb 20)}"
COORD_SWEEP_EVERY_MIN="${COORDINATOR_SWEEP_EVERY_MIN:-$(swarm_opt coordinator.sweepEveryMin 30)}"
COORD_FROZEN_MIN="${COORDINATOR_FROZEN_MIN:-$(swarm_opt coordinator.frozenMin 20)}"
COORD_JUDGES="${COORDINATOR_JUDGES:-$(swarm_opt coordinator.judges 1)}"
COORD_JUDGE_TURNS="${COORDINATOR_JUDGE_TURNS:-$(swarm_opt coordinator.judge.turns 40)}"
COORD_JUDGE_BUDGET="${COORDINATOR_JUDGE_BUDGET_USD:-$(swarm_opt coordinator.judge.budgetUsd 5)}"
COORD_JUDGE_COMPACT="${COORDINATOR_JUDGE_COMPACT:-$(swarm_opt coordinator.judge.compactWindow 150000)}"

# coord_room — room for one more builder? Prints the reading; 0 when there is.
# Never a reason to stop a running one: it only gates the next start.
coord_room() {
  local idle mem load max
  idle=$(swarm_cpu_idle); mem=$(swarm_free_mem_gb); load=$(swarm_load)
  max="${SWARM_MAX_LOAD:-}"; [ -n "$max" ] || max=$(swarm_default_max_load)
  if [ "${load:-0}" -gt "$max" ]; then
    printf 'load %s, limit %s' "$load" "$max"; return 1
  fi
  if [ "${idle:-100}" -lt "$COORD_START_IDLE" ]; then
    printf 'cpu idle %s%%, start floor %s%%' "$idle" "$COORD_START_IDLE"; return 1
  fi
  if [ -n "$mem" ] && [ "$mem" -lt "$COORD_MIN_FREE_MEM_GB" ]; then
    printf '%s GB free, floor %s GB' "$mem" "$COORD_MIN_FREE_MEM_GB"; return 1
  fi
  printf 'cpu idle %s%%, %s' "$idle" "$([ -n "$mem" ] && printf '%s GB free' "$mem" || printf 'memory unread')"
}

# coord_healing_slots <ceiling> — ceil(ceiling x healingShare).
coord_healing_slots() {
  awk -v c="$1" -v s="$COORD_HEAL_SHARE" 'BEGIN{ h = c * s; n = int(h); if (n < h) n++; print n }'
}
coord_healing_class() { case "$1" in repair|approved-merge) return 0 ;; *) return 1 ;; esac; }

coord_shadow() { [ "$COORD_SHADOW" != 0 ]; }
coord_mode()   { if coord_shadow; then printf would; else printf did; fi; }
# Per mode: going live must not replay a shadow night's events, nor skip a live one.
COORD_EVENTS="$COORD_DIR/events.$(coord_mode).jsonl"

# One line per act: <iso> \t would|did \t <verb> \t <subject> \t <detail>
coord_act_log() { # <verb> <subject> [detail]
  printf '%s\t%s\t%s\t%s\t%s\n' "$(swarm_stamp)" "$(coord_mode)" "$1" "$2" "${3:-}" >> "$COORD_ACTIONS"
}

# coord_lock <dir> <noun> — one holder at a time. Fails, with COORD_LOCK_WHY set, when
# another live process holds it. A reused pid is not the holder: the lock
# carries the holder's start time too.
# GNU stat -f reads %m as a file name and prints to stdout, so ask GNU first.
coord_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
# Locale and zone pinned: cron's C and a shell's en_GB print the same start differently.
coord_started_of() { LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//'; }
coord_lock() { # <dir> <noun>
  local lock="$1" who="${2:-run}" holder
  COORD_LOCK_WHY=""
  if ! mkdir "$lock" 2>/dev/null; then
    holder=$(cat "$lock/pid" 2>/dev/null)
    if [ -z "$holder" ] && [ $(( $(date +%s) - $(coord_mtime "$lock") )) -lt 60 ]; then
      COORD_LOCK_WHY="another $who is taking the lock"; return 1
    fi
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null \
       && [ "$(coord_started_of "$holder")" = "$(cat "$lock/started" 2>/dev/null)" ]; then
      COORD_LOCK_WHY="another $who (pid $holder) is running"; return 1
    fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { COORD_LOCK_WHY="lost the lock race"; return 1; }
  fi
  coord_started_of "$$" > "$lock/started"
  echo "$$" > "$lock/pid"
}

# The queue in run order: <ticket> \t <class> \t <note>. Class decides first
# (repair > approved-merge > new); an unknown class sorts last rather than vanish.
coord_queue_ordered() {
  [ -s "$COORD_QUEUE" ] || return 0
  jq -r '.tickets | to_entries
         | map(.value + {pos: .key, rank: ({"repair":0,"approved-merge":1,"new":2}[.value.class] // 3)})
         | sort_by(.rank, .pos) | .[] | [(.n|tostring), .class, (.note // "")] | @tsv' "$COORD_QUEUE" 2>/dev/null
}

export COORD_DIR COORD_QUEUE COORD_EVENTS COORD_ACTIONS COORD_NEEDS_YOU COORD_LOG COORD_SHADOW
