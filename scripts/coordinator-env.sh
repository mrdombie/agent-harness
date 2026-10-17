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
#   coordinator.keepCpuIdle  COORDINATOR_KEEP_CPU_IDLE 15   median idle % kept back when filling; never
#                                                           under swarm.minCpuIdle, the hold floor
#   coordinator.agentCpuCores COORDINATOR_AGENT_CPU_CORES 0.8 cores one builder uses; the idle above
#                                                           keepCpuIdle starts as many as it fits
#   coordinator.rampMin      COORDINATOR_RAMP_MIN     10    a builder started this recently still
#                                                           counts against the room
#   coordinator.minFreeMemGb COORDINATOR_MIN_FREE_MEM_GB 4  free memory needed to start one more
#   coordinator.healingShare COORDINATOR_HEALING_SHARE 0.25 share of the ceiling kept for healing
#                                                           (repair + approved-merge), rounded up
#   coordinator.minFreeGb    COORDINATOR_MIN_FREE_GB   20    disk alarm floor
#   coordinator.sweepEveryMin COORDINATOR_SWEEP_EVERY_MIN 30  worktree sweep interval
#   coordinator.frozenMin    COORDINATOR_FROZEN_MIN    20    no log growth = frozen
#   coordinator.snapshotMaxAgeMin COORDINATOR_SNAPSHOT_MAX_AGE_MIN 15  oldest forge read a refused
#                                                           tick may start work from
#   coordinator.refreshEveryMin COORDINATOR_REFRESH_EVERY_MIN 5  queue re-seed interval
#   coordinator.judges       COORDINATOR_JUDGES         1    judges at once
#   coordinator.judge.turns  COORDINATOR_JUDGE_TURNS   40
#   coordinator.judge.budgetUsd   COORDINATOR_JUDGE_BUDGET_USD   5
#   coordinator.judge.compactWindow  COORDINATOR_JUDGE_COMPACT  150000

_coord_self="${BASH_SOURCE[0]}"
# swarm-env.sh fills in a default load limit; the room test must know whether one was set.
COORD_MAX_LOAD_SET="${SWARM_MAX_LOAD:-}"
. "$(cd "$(dirname "$_coord_self")/../swarm" && pwd)/swarm-env.sh" || return 1 2>/dev/null || exit 1
. "$(cd "$(dirname "$_coord_self")" && pwd)/branch-ticket.sh" || return 1 2>/dev/null || exit 1
unset _coord_self

COORD_DIR="${COORDINATOR_DIR:-$STATE_DIR/coordinator}"
mkdir -p "$COORD_DIR/judges" 2>/dev/null || true
COORD_QUEUE="$COORD_DIR/queue.json"
COORD_SHADOW="${COORDINATOR_SHADOW:-1}"
COORD_ACTIONS="$COORD_DIR/actions.log"
COORD_NEEDS_YOU="$COORD_DIR/needs-you.md"
COORD_LOG="$COORD_DIR/tick.log"
COORD_CAP="${COORDINATOR_CAP:-$(swarm_opt coordinator.cap "")}"
# What spawn-claim.sh will start: the same reading it makes (SPAWN_RUNNER, then
# swarm.runner), so the tick can pass over an entry that runner cannot take.
COORD_RUNNER="${SPAWN_RUNNER:-$(swarm_opt swarm.runner claim)}"
# 0 means spawn nothing; anything not a whole number holds every spawn, named.
COORD_CAP_BAD=""
case "$COORD_CAP" in ''|*[!0-9]*) [ -z "$COORD_CAP" ] || { COORD_CAP_BAD="$COORD_CAP"; COORD_CAP=""; } ;; esac
# Starts fill the spare CPU: as many agents as fit above the idle kept back, at
# agentCpuCores each. Dom, 2026-10-16: "fill all spare room", keeping 15% idle.
COORD_KEEP_IDLE="${COORDINATOR_KEEP_CPU_IDLE:-$(swarm_opt coordinator.keepCpuIdle 15)}"
case "$COORD_KEEP_IDLE" in ""|*[!0-9]*) COORD_KEEP_IDLE=15 ;; esac
# Kept idle under the hold floor would start agents the next tick calls busy.
[ "$COORD_KEEP_IDLE" -ge "${SWARM_MIN_CPU_IDLE:-15}" ] 2>/dev/null || COORD_KEEP_IDLE=${SWARM_MIN_CPU_IDLE:-15}
COORD_AGENT_CPU="${COORDINATOR_AGENT_CPU_CORES:-$(swarm_opt coordinator.agentCpuCores 0.8)}"
awk -v a="$COORD_AGENT_CPU" 'BEGIN{exit !(a ~ /^[0-9]*\.?[0-9]+$/ && a+0 > 0)}' || COORD_AGENT_CPU=0.8
# A builder takes minutes to load the CPU, so one started this recently still
# owns its share and the idle reading has not seen it yet.
COORD_RAMP_MIN="${COORDINATOR_RAMP_MIN:-$(swarm_opt coordinator.rampMin 10)}"
case "$COORD_RAMP_MIN" in ""|*[!0-9]*) COORD_RAMP_MIN=10 ;; esac
COORD_MIN_FREE_MEM_GB="${COORDINATOR_MIN_FREE_MEM_GB:-$(swarm_opt coordinator.minFreeMemGb 4)}"
case "$COORD_MIN_FREE_MEM_GB" in ""|*[!0-9]*) COORD_MIN_FREE_MEM_GB=4 ;; esac
COORD_HEAL_SHARE="${COORDINATOR_HEALING_SHARE:-$(swarm_opt coordinator.healingShare 0.25)}"
awk -v s="$COORD_HEAL_SHARE" 'BEGIN{exit !(s ~ /^(0|1|0?\.[0-9]+|1\.0*)$/)}' || COORD_HEAL_SHARE=0.25
[ -n "$COORD_MAX_LOAD_SET" ] || COORD_MAX_LOAD_SET=$(swarm_opt swarm.maxLoad "")
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
  local idle="" n=0 sm mem load cores max
  sm=$(swarm_cpu_idle_smoothed); mem=$(swarm_free_mem_gb); load=$(swarm_load); cores=$(swarm_cores)
  [ -n "$sm" ] && read -r idle n <<< "$sm"
  # A reading nobody could take is no room: unread, an uncapped ceiling ramps forever.
  [ -n "$idle" ]  || { printf 'cpu idle unread'; return 1; }
  [ -n "$mem" ]   || { printf 'free memory unread'; return 1; }
  [ -n "$load" ]  || { printf 'load unread'; return 1; }
  max="$COORD_MAX_LOAD_SET"
  if [ -z "$max" ]; then
    [ -n "$cores" ] || { printf 'cpu cores unread, so no load limit'; return 1; }
    max=$(( 20 * cores ))
  fi
  if [ "$load" -gt "$max" ]; then
    printf 'load %s, limit %s' "$load" "$max"; return 1
  fi
  [ -n "$cores" ] || { printf 'cpu cores unread'; return 1; }
  # Prints "<starts>\t<reading>": how many agents the idle above the kept share fits.
  local starts
  starts=$(awk -v i="$idle" -v k="$COORD_KEEP_IDLE" -v a="$COORD_AGENT_CPU" -v c="$cores" \
    'BEGIN{ per = a * 100 / c; n = int((i - k) / per); print (n > 0 ? n : 0) }')
  if [ "$starts" -lt 1 ]; then
    printf '%s, keeping %s%% and an agent needs %s of %s cores' "$(swarm_idle_label "$idle" "$n")" "$COORD_KEEP_IDLE" "$COORD_AGENT_CPU" "$cores"; return 1
  fi
  if [ "$mem" -lt "$COORD_MIN_FREE_MEM_GB" ]; then
    printf '%s GB free, floor %s GB' "$mem" "$COORD_MIN_FREE_MEM_GB"; return 1
  fi
  printf '%s\t%s, %s GB free' "$starts" "$(swarm_idle_label "$idle" "$n")" "$mem"
}

# The class each spawn was for, kept here: the spawner hands over to the project's
# own copy, which need not write a class into the run record.
#   run-classes.tsv   <run-id or -> \t <ticket> \t <class> \t <epoch>
COORD_RUN_CLASSES="$COORD_DIR/run-classes.tsv"
coord_record_class() { # <ticket> <class> — after a spawn returns
  local rec rid="-"
  rec=$(ls -t "$RUNS_DIR"/claim-"$1"-*.json 2>/dev/null | head -1)
  [ -n "$rec" ] && rid=$(basename "$rec" .json)
  printf '%s\t%s\t%s\t%s\n' "$rid" "$1" "$2" "$(date +%s)" >> "$COORD_RUN_CLASSES"
  tail -500 "$COORD_RUN_CLASSES" > "$COORD_RUN_CLASSES.$$" 2>/dev/null && mv -f "$COORD_RUN_CLASSES.$$" "$COORD_RUN_CLASSES"
}
coord_run_class() { # <runs/claim-*.json> — the class on record, or nothing
  local rid t m c
  c=$(jq -r '.class // empty' "$1" 2>/dev/null)
  [ -n "$c" ] && { printf '%s' "$c"; return; }
  [ -f "$COORD_RUN_CLASSES" ] || return 0
  rid=$(basename "$1" .json)
  c=$(awk -F'\t' -v r="$rid" '$1 == r { c = $3 } END { print c }' "$COORD_RUN_CLASSES")
  [ -n "$c" ] && { printf '%s' "$c"; return; }
  # Recorded before its run record existed: the ticket's entry from around its start.
  t=$(jq -r '.ticket // empty' "$1" 2>/dev/null); m=$(coord_mtime "$1")
  awk -F'\t' -v t="$t" -v m="$m" '$1 == "-" && $2 == t && $4 >= m - 600 && $4 <= m + 600 { c = $3 } END { print c }' "$COORD_RUN_CLASSES"
}

# 0 when a live (not shadow) tick wrote capacity.json in the last 15 minutes.
coord_live_recently() {
  local f="$COORD_DIR/capacity.json" e m
  [ -f "$f" ] || return 1
  m=$(jq -r '.mode // empty' "$f" 2>/dev/null); e=$(jq -r '.epoch // 0' "$f" 2>/dev/null)
  [ "$m" = did ] && [ $(( $(date +%s) - ${e:-0} )) -lt 900 ] 2>/dev/null
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

# The last good read of the forge, kept for the ticks GitHub refuses. A tick
# that cannot read the open PRs or the queue's tickets works from these while
# they are under coordinator.snapshotMaxAgeMin old, rather than starting nothing.
COORD_SNAP_DIR="$COORD_DIR/snapshot"
COORD_SNAP_MAX_AGE_MIN="${COORDINATOR_SNAPSHOT_MAX_AGE_MIN:-$(swarm_opt coordinator.snapshotMaxAgeMin 15)}"
case "$COORD_SNAP_MAX_AGE_MIN" in ""|*[!0-9]*) COORD_SNAP_MAX_AGE_MIN=15 ;; esac
coord_snap_file() { printf '%s/%s.json' "$COORD_SNAP_DIR" "$1"; }
coord_snap_save() { # <name> <json>
  mkdir -p "$COORD_SNAP_DIR" 2>/dev/null
  printf '%s\n' "$2" > "$(coord_snap_file "$1").$$" && mv -f "$(coord_snap_file "$1").$$" "$(coord_snap_file "$1")"
}
coord_snap_age() { # <name> — whole minutes since it was taken; 1 when there is none
  local f; f=$(coord_snap_file "$1"); [ -s "$f" ] || return 1
  printf '%s' $(( ($(swarm_now) - $(coord_mtime "$f")) / 60 ))
}
# coord_snap_load <name> — the snapshot; 1 when there is none or it is over the limit.
coord_snap_load() {
  local age; age=$(coord_snap_age "$1") || return 1
  [ "$age" -le "$COORD_SNAP_MAX_AGE_MIN" ] || return 1
  cat "$(coord_snap_file "$1")"
}

export COORD_DIR COORD_QUEUE COORD_EVENTS COORD_ACTIONS COORD_NEEDS_YOU COORD_LOG COORD_SHADOW
