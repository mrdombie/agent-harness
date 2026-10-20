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
#   coordinator.rampFreeMemGb COORDINATOR_RAMP_FREE_MEM_GB 8 free memory needed to start more than
#                                                           one in a tick; under it, one per tick
#   coordinator.rampMax      COORDINATOR_RAMP_MAX     unset  most starts in one tick; unset, the room decides
#   coordinator.agentMemGb   COORDINATOR_AGENT_MEM_GB 1.5   memory one new builder is charged before it
#                                                           has used any (trees measure 0.6-1.3 GB)
#   coordinator.healingShare COORDINATOR_HEALING_SHARE 0.25 share of the ceiling kept for healing
#                                                           (repair + approved-merge), rounded up
#   coordinator.healAllAt    COORDINATOR_HEAL_ALL_AT   unset reds left (waiting + live healing runs)
#                                                           at which every place heals;
#                                                           under it the healingShare split returns.
#                                                           Polish reds never count toward it.
#                                                           Unset, empty or not a whole number >0: off
#   coordinator.polishListFull COORDINATOR_POLISH_LIST_FULL 8 unticked items at which a polish list
#                                                           starts while other work waits; under it,
#                                                           polish starts only when nothing else can
#   coordinator.toolingLabels COORDINATOR_TOOLING_LABELS (below) labels that make a ticket our own
#                                                           build tooling: it runs after product
#                                                           work of the same priority and class
#   coordinator.toolingScopes COORDINATOR_TOOLING_SCOPES gates ci harness ops pre-push dev
#                                                           title scopes ("feat(gates): …") that do too
#   coordinator.minFreeGb    COORDINATOR_MIN_FREE_GB   20    disk alarm floor
#   coordinator.sweepEveryMin COORDINATOR_SWEEP_EVERY_MIN 30  worktree sweep interval
#   coordinator.frozenMin    COORDINATOR_FROZEN_MIN    20    no log growth = frozen
#   coordinator.snapshotMaxAgeMin COORDINATOR_SNAPSHOT_MAX_AGE_MIN 15  oldest forge read a refused
#                                                           tick may start work from
#   coordinator.refreshEveryMin COORDINATOR_REFRESH_EVERY_MIN 5  queue re-seed interval
#   coordinator.pace.on      COORDINATOR_PACE           1    0: no usage pacing, the machine alone decides
#   coordinator.pace.target  COORDINATOR_PACE_TARGET   0.95  five-hour window share the pacer aims to end at
#   coordinator.pace.burnPerBuilderHour COORDINATOR_PACE_BURN 0.025  window share one builder burns an
#                                                           hour, when the samples cannot say
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
# Several starts in one tick only with memory to spare: a start allocates after the reading.
COORD_RAMP_FREE_MEM_GB="${COORDINATOR_RAMP_FREE_MEM_GB:-$(swarm_opt coordinator.rampFreeMemGb 8)}"
case "$COORD_RAMP_FREE_MEM_GB" in ""|*[!0-9]*) COORD_RAMP_FREE_MEM_GB=8 ;; esac
COORD_AGENT_MEM_GB="${COORDINATOR_AGENT_MEM_GB:-$(swarm_opt coordinator.agentMemGb 1.5)}"
awk -v a="$COORD_AGENT_MEM_GB" 'BEGIN{exit !(a ~ /^[0-9]*\.?[0-9]+$/)}' || COORD_AGENT_MEM_GB=1.5
COORD_RAMP_MAX="${COORDINATOR_RAMP_MAX:-$(swarm_opt coordinator.rampMax "")}"
case "$COORD_RAMP_MAX" in ""|0|*[!0-9]*) COORD_RAMP_MAX="" ;; esac
COORD_HEAL_SHARE="${COORDINATOR_HEALING_SHARE:-$(swarm_opt coordinator.healingShare 0.25)}"
awk -v s="$COORD_HEAL_SHARE" 'BEGIN{exit !(s ~ /^(0|1|0?\.[0-9]+|1\.0*)$/)}' || COORD_HEAL_SHARE=0.25
COORD_HEAL_ALL_AT="${COORDINATOR_HEAL_ALL_AT:-$(swarm_opt coordinator.healAllAt "")}"
case "$COORD_HEAL_ALL_AT" in ""|*[!0-9]*) COORD_HEAL_ALL_AT="" ;; *) [ "$COORD_HEAL_ALL_AT" -gt 0 ] || COORD_HEAL_ALL_AT="" ;; esac
COORD_POLISH_LIST_FULL="${COORDINATOR_POLISH_LIST_FULL:-$(swarm_opt coordinator.polishListFull 8)}"
case "$COORD_POLISH_LIST_FULL" in ""|0|*[!0-9]*) COORD_POLISH_LIST_FULL=8 ;; esac
# Owner call 2026-10-19: at one priority, product work goes ahead of our own tooling.
COORD_TOOLING_LABELS="${COORDINATOR_TOOLING_LABELS:-$(swarm_opt coordinator.toolingLabels "repo:agent-harness code-health project:ci-throughput project:harness-kit area:OPS area:HYGIENE area:OPS-CONSOLE")}"
COORD_TOOLING_SCOPES="${COORDINATOR_TOOLING_SCOPES:-$(swarm_opt coordinator.toolingScopes "gates ci harness ops pre-push dev")}"
[ -n "$COORD_MAX_LOAD_SET" ] || COORD_MAX_LOAD_SET=$(swarm_opt swarm.maxLoad "")
COORD_MIN_FREE_GB="${COORDINATOR_MIN_FREE_GB:-$(swarm_opt coordinator.minFreeGb 20)}"
COORD_SWEEP_EVERY_MIN="${COORDINATOR_SWEEP_EVERY_MIN:-$(swarm_opt coordinator.sweepEveryMin 30)}"
COORD_FROZEN_MIN="${COORDINATOR_FROZEN_MIN:-$(swarm_opt coordinator.frozenMin 20)}"
COORD_JUDGES="${COORDINATOR_JUDGES:-$(swarm_opt coordinator.judges 1)}"
COORD_JUDGE_TURNS="${COORDINATOR_JUDGE_TURNS:-$(swarm_opt coordinator.judge.turns 40)}"
COORD_JUDGE_BUDGET="${COORDINATOR_JUDGE_BUDGET_USD:-$(swarm_opt coordinator.judge.budgetUsd 5)}"
COORD_JUDGE_COMPACT="${COORDINATOR_JUDGE_COMPACT:-$(swarm_opt coordinator.judge.compactWindow 150000)}"

# coord_room [fresh] — room for one more builder? Prints the reading; 0 when there is.
# Never a reason to stop a running one: it only gates the next start.
coord_room() { # [fresh] — fresh: a new sample, and the lower of it and the median
  local idle="" n=0 sm mem load cores max raw=""
  # After a start the shared 5s sample and the median both predate it.
  [ "${1:-}" = fresh ] && raw=$(SWARM_IDLE_FRESH=1 swarm_cpu_idle)
  sm=$(swarm_cpu_idle_smoothed); mem=$(swarm_free_mem_gb); load=$(swarm_load); cores=$(swarm_cores)
  [ -n "$sm" ] && read -r idle n <<< "$sm"
  case "$raw" in ''|*[!0-9]*) ;; *) [ -n "$idle" ] && [ "$raw" -lt "$idle" ] && { idle=$raw; n=0; } ;; esac
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

# ---- the usage pacer ----------------------------------------------------------
# Owner call 2026-10-20: "work out the maths and automatically adjust both
# machines" — for the plan's five-hour window only. Every host on the account
# burns the same window, so each tick works out how many builders, across every
# host, the window affords until it resets, and this host takes what the other
# hosts' live claims leave. It only limits starts: a running builder is never stopped.
COORD_PACE="${COORDINATOR_PACE:-$(swarm_opt coordinator.pace.on 1)}"
case "$COORD_PACE" in 0|false|off) COORD_PACE=0 ;; *) COORD_PACE=1 ;; esac
COORD_PACE_TARGET="${COORDINATOR_PACE_TARGET:-$(swarm_opt coordinator.pace.target 0.95)}"
awk -v t="$COORD_PACE_TARGET" 'BEGIN{exit !(t ~ /^[0-9]*\.?[0-9]+$/ && t+0 > 0 && t+0 <= 1)}' || COORD_PACE_TARGET=0.95
COORD_PACE_BURN="${COORDINATOR_PACE_BURN:-$(swarm_opt coordinator.pace.burnPerBuilderHour 0.025)}"
awk -v b="$COORD_PACE_BURN" 'BEGIN{exit !(b ~ /^[0-9]*\.?[0-9]+$/ && b+0 > 0)}' || COORD_PACE_BURN=0.025
# Samples: <epoch> \t <utilization> \t <window reset epoch> \t <builders on every host>
COORD_PACE_SAMPLES="$COORD_DIR/pace.tsv"
COORD_PACE_LOOKBACK_MIN=90
# A burn measured over less than this, or fewer builder-hours, is noise at 1% steps.
COORD_PACE_MIN_SPAN_MIN=30
COORD_PACE_MIN_BUILDER_HOURS=0.25

# coord_pace_reading — "<utilization>\t<reset epoch>" for the five-hour window now
# open: the newest reading in the newest builder logs (a prose run's claim log, a
# driver run's step logs), else the last sample taken while it is still open.
coord_pace_reading() {
  local now files f best
  now=$(swarm_now)
  # shellcheck disable=SC2012  # names we wrote, no newlines
  files=$(ls -t "$SWARM_LOGS"/claim-*.log "${DRIVER_DIR:-$STATE_DIR/driver}"/*/steps/*.log 2>/dev/null | head -8)
  best=$(while IFS= read -r f; do
           [ -n "$f" ] && swarm_usage_cli_events "$f" | awk -F'\t' '$2 == "window" && $4 == "five_hour" { print $5 "\t" $3 }'
         done <<< "$files" \
         | awk -F'\t' -v now="$now" '$2 + 0 > now + 0 && ($2 + 0 > r + 0 || ($2 == r && $1 + 0 > u + 0)) { r = $2; u = $1 }
                                     END { if (r) printf "%s\t%s", u, r }')
  if [ -z "$best" ] && [ -s "$COORD_PACE_SAMPLES" ]; then
    best=$(awk -F'\t' -v now="$now" '$3 + 0 > now + 0 { u = $2; r = $3 } END { if (r) printf "%s\t%s", u, r }' "$COORD_PACE_SAMPLES")
  fi
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# coord_pace_burn <reset epoch> — "<window share per builder-hour>\tmeasured|default":
# the rise in utilization over the builder-hours run between the samples of the
# last COORD_PACE_LOOKBACK_MIN inside this one window. Too short, too few or
# falling (a reset), and the configured burn stands.
coord_pace_burn() {
  local now b=""
  now=$(swarm_now)
  [ -s "$COORD_PACE_SAMPLES" ] && b=$(sort -n -t$'\t' -k1,1 "$COORD_PACE_SAMPLES" | awk -F'\t' \
      -v r="$1" -v from="$(( now - COORD_PACE_LOOKBACK_MIN * 60 ))" \
      -v span="$(( COORD_PACE_MIN_SPAN_MIN * 60 ))" -v minbh="$COORD_PACE_MIN_BUILDER_HOURS" '
    $3 == r && $1 + 0 >= from + 0 {
      if (n) bh += ($1 - lt) / 3600 * ln; else { ft = $1; fu = $2 }
      n++; lt = $1; ln = $4; lu = $2
    }
    END { if (n >= 2 && lt - ft >= span && bh >= minbh && lu - fu > 0) printf "%.6f", (lu - fu) / bh }')
  if [ -n "$b" ]; then printf '%s\tmeasured' "$b"; else printf '%s\tdefault' "$COORD_PACE_BURN"; fi
}

# coord_pace <builders here> <claim rows> <this host> — "<this host's share>\t<line>",
# 1 with the reason when there is nothing to pace on. Claim rows are
# <ticket> \t <host> \t <step>; a row naming another host is a builder there.
# Records this tick's sample, so the next tick's burn has it.
coord_pace() {
  local here="${1:-0}" rows="${2:-}" host="${3:-}" reading u r other total burn bsrc now
  [ "$COORD_PACE" = 1 ] || { printf 'pace: off'; return 1; }
  reading=$(coord_pace_reading) || { printf 'pace: no five-hour reading in the newest logs — the machine alone decides'; return 1; }
  u=${reading%%$'\t'*}; r=${reading#*$'\t'}; now=$(swarm_now)
  other=$(printf '%s\n' "$rows" | awk -F'\t' -v h="$host" '$1 ~ /^[0-9]+$/ && $2 != "" && $2 != h { n++ } END { print n + 0 }')
  total=$(( here + other ))
  mkdir -p "$(dirname "$COORD_PACE_SAMPLES")" 2>/dev/null
  printf '%s\t%s\t%s\t%s\n' "$now" "$u" "$r" "$total" >> "$COORD_PACE_SAMPLES"
  tail -300 "$COORD_PACE_SAMPLES" > "$COORD_PACE_SAMPLES.$$" 2>/dev/null && mv -f "$COORD_PACE_SAMPLES.$$" "$COORD_PACE_SAMPLES"
  burn=$(coord_pace_burn "$r"); bsrc=${burn#*$'\t'}; burn=${burn%%$'\t'*}
  awk -v u="$u" -v r="$r" -v now="$now" -v t="$COORD_PACE_TARGET" -v b="$burn" -v o="$other" \
      -v at="$(swarm_iso "$r" | cut -c12-16)" -v src="$bsrc" '
    BEGIN {
      T = (r - now) / 3600; if (T < 0.1) T = 0.1
      a = int((t - u) / (b * T) + 1e-9); if (a < 0) a = 0
      s = a - o; if (s < 0) s = 0
      printf "%d\tpace: 5h window %d%%, resets %sZ, %.1f%%/builder-hour%s → %d across all hosts, %d on other hosts → %d here",
        s, u * 100 + 0.5, at, b * 100, (src == "default" ? " (default)" : ""), a, o, s
    }'
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

# coord_heal_all <reds-left> — 0 when that many reds left (waiting + healing) put every place on healing.
coord_heal_all() { [ -n "$COORD_HEAL_ALL_AT" ] && [ "${1:-0}" -ge "$COORD_HEAL_ALL_AT" ]; }
# coord_healing_slots <ceiling> [reds-left] — the whole ceiling under heal-all,
# else ceil(ceiling x healingShare).
coord_healing_slots() {
  if coord_heal_all "${2:-0}"; then printf '%s\n' "$1"; return 0; fi
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

# What a ticket is, read off its labels, title and claimable mode. The queue's seed
# and the tick's order both use these, so the two never disagree on a ticket.
#   coord_prin   P0..P9 as 0..9; no priority label is 9, after P3
#   coord_kind   half-built, feature, other, polish (owner call 2026-10-18)
#   coord_polish a P3 label or a polish list, nothing else: never stops new
#                building. A title or label that merely says "polish" is not one.
#   coord_tooling our own build tooling (coordinator.toolingLabels / toolingScopes):
#                after product work of the same priority and class
COORD_TICKET_JQ='
  def coord_pri($ls; $pri): ([$ls[]? | select(test("^P[0-9]$"))] | first) // $pri // "";
  def coord_prin($ls; $pri): ((coord_pri($ls; $pri) | capture("^P(?<d>[0-9])") | .d | tonumber) // 9);
  def coord_polish($ls; $pri; $title):
    coord_pri($ls; $pri) == "P3" or ($ls | index($plist)) != null;
  def coord_tooling($ls; $title):
    ($ls | any(. as $l | $tooling | index($l) != null))
    or ([($title // "") | capture("^[a-z]+\\((?<s>[^)]*)\\)!?:"; "i") | .s | ascii_downcase]
        | first // "" | . as $s | $toolscopes | index($s) != null);
  def coord_kind($ls; $mode; $pri; $title):
    if ($ls | index($partial)) or ($ls | index($inreview)) or $mode == "[RESUME PR]" then "half-built"
    elif ($ls | index("type:feature")) then "feature"
    elif coord_polish($ls; $pri; $title) then "polish"
    else "other" end;
  # Nobody can start it: closed, or a stop label. A repair or approved-merge row is
  # stopped only by the labels that park the ticket; a hold or a question to a person
  # stops new work but never a red or clashing PR.
  def coord_stopped($ls; $class; $state):
    (($state // "OPEN") != "OPEN")
    or ($ls | any(. as $l | (if $class == "new" then $stopnew else $stopall end) | index($l) != null));
  def coord_repair_note($note): (($note // "") | test("(^|\n)REPAIR on PR #[0-9]"));
  def coord_class($c; $note): if ($c // "new") == "new" and coord_repair_note($note) then "repair" else ($c // "new") end;'
# The stop labels coord_stopped reads, one JSON array each.
coord_stop_json() { # all|new
  { printf '%s\n' "${LBL_BATCHED:-status:batched}" "$LBL_PARKED" "$LBL_BLOCKED" "$LBL_EXTERNAL_BLOCKED" \
      "$LBL_GATED" "$LBL_DRAFTING" "$LBL_PM_DECISION" "$LBL_PM_TRACK"
    [ "$1" = new ] && printf '%s\n' "$HOLD_LABEL" "$LBL_NEEDS_HUMAN" "${LBL_OWNER_DECISION:-}" $DECISION_LABELS
  } | awk 'NF && !seen[$0]++' | jq -R . | jq -sc .
}
coord_jq() { # <jq args…> — jq with COORD_TICKET_JQ and the label names it needs
  jq --arg plist "$LBL_POLISH_LIST" --arg partial "${LBL_PARTIAL:-status:partial}" \
     --argjson tooling "$(printf '%s' "$COORD_TOOLING_LABELS" | tr ', ' '\n\n' | jq -R . | jq -sc 'map(select(length > 0))')" \
     --argjson toolscopes "$(printf '%s' "$COORD_TOOLING_SCOPES" | tr ', ' '\n\n' | jq -R . | jq -sc 'map(select(length > 0) | ascii_downcase)')" \
     --arg inreview "${LBL_IN_REVIEW:-status:in-review}" \
     --argjson stopall "$(coord_stop_json all)" --argjson stopnew "$(coord_stop_json new)" "$@"
}

# The queue in run order: <ticket> \t <class> \t <note>; with --wide,
# <ticket> \t <class> \t <priority 0-9> \t <polish 0|1> \t <polish list 0|1> \t
# <never held 0|1> \t <note>. Never held: an entry put at the front (a resume, an
# owner's answer) or half-built work — the polish hold never parks either.
# Owner call 2026-10-19: priority decides first, across classes (P0 < P1 < P2 < P3
# < none); within one priority repair, approved-merge, then new; within one class
# product work before our own tooling (coord_tooling); then new by kind; then the
# queue's own position. A repair of any priority used to outrank every new
# ticket, so a P3 red held a P0 build back. An entry put at the front stays first
# overall. A queue seeded from the shared sheet (coordinator-sheet.sh) runs in the
# sheet's order: its owner already ordered it. The tick's batched read ($ISSUES) is fresher than the seed: when it
# holds a ticket, its labels decide that ticket's priority and kind.
coord_queue_ordered() {
  local wide=0; [ "${1:-}" = --wide ] && wide=1
  [ -s "$COORD_QUEUE" ] || return 0
  coord_jq -r --argjson wide "$wide" --slurpfile iss <(printf '%s' "${ISSUES:-}" | jq -c 'objects' 2>/dev/null || true) \
    "$COORD_TICKET_JQ"'
     (($iss[0]) // {}) as $iss
     | ((.source // "") == "sheet") as $sheet
     | .tickets | to_entries
     | map(.value as $t | ($iss[($t.n|tostring)] // null) as $i
         | (if $i then ($i.labels // []) else null end) as $ls
         | $t + {pos: .key,
                 prin: (if $ls then coord_prin($ls; null) else ($t.prin // 9) end),
                 kind: (if $ls then coord_kind($ls; ""; null; $i.title) else ($t.kind // "other") end),
                 polish: (if $ls then coord_polish($ls; null; $i.title) else ($t.polish // ($t.kind == "polish")) end),
                 plist: (if $ls then ($ls | index($plist)) != null else ($t.plist // false) end),
                 tool: (if $ls then coord_tooling($ls; $i.title) else ($t.tooling // false) end),
                 class: coord_class($t.class; $t.note)}
         | . + {rank: ({"repair":0,"approved-merge":1,"new":2}[.class] // 3)})
     # A queue taken from the shared sheet keeps the order its owner wrote, exactly.
     # .top (the PM putting it on top with add --front) is first overall; .front (a resume, an answer,
     # a requeue) is first only among its own priority.
     | if $sheet then sort_by(if .top or .front then 0 else 1 end, .pos)
       else sort_by(if .top then 0 else 1 end, (if .top then .pos else 0 end), .prin,
               (if .front then 0 else 1 end), (if .front then .pos else 0 end), .rank, (if .tool then 1 else 0 end),
               (if .class == "new" then ({"half-built":0, feature:1, other:2, polish:3}[.kind] // 2) else 0 end), .pos) end
     | .[]
     | if $wide == 1 then [(.n|tostring), .class, (.prin|tostring), (if .polish then "1" else "0" end), (if .plist then "1" else "0" end),
                           (if .top or .front or .kind == "half-built" then "1" else "0" end), (.note // "")]
       else [(.n|tostring), .class, (.note // "")] end | @tsv' "$COORD_QUEUE" 2>/dev/null
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
