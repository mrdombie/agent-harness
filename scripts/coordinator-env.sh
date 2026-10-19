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
#   coord_polish P3, a polish kind, or a polish list: never stops new building
#   coord_tooling our own build tooling (coordinator.toolingLabels / toolingScopes):
#                after product work of the same priority and class
COORD_TICKET_JQ='
  def coord_pri($ls; $pri): ([$ls[]? | select(test("^P[0-9]$"))] | first) // $pri // "";
  def coord_prin($ls; $pri): ((coord_pri($ls; $pri) | capture("^P(?<d>[0-9])") | .d | tonumber) // 9);
  def coord_polish($ls; $pri; $title):
    coord_pri($ls; $pri) == "P3" or ($ls | index($plist)) != null
    or ($ls | any(test("polish"; "i"))) or (($title // "") | test("polish"; "i"));
  def coord_tooling($ls; $title):
    ($ls | any(. as $l | $tooling | index($l) != null))
    or ([($title // "") | capture("^[a-z]+\\((?<s>[^)]*)\\)!?:"; "i") | .s | ascii_downcase]
        | first // "" | . as $s | $toolscopes | index($s) != null);
  def coord_kind($ls; $mode; $pri; $title):
    if ($ls | index($partial)) or ($ls | index($inreview)) or $mode == "[RESUME PR]" then "half-built"
    elif ($ls | index("type:feature")) then "feature"
    elif coord_polish($ls; $pri; $title) then "polish"
    else "other" end;'
coord_jq() { # <jq args…> — jq with COORD_TICKET_JQ and the label names it needs
  jq --arg plist "$LBL_POLISH_LIST" --arg partial "${LBL_PARTIAL:-status:partial}" \
     --argjson tooling "$(printf '%s' "$COORD_TOOLING_LABELS" | tr ', ' '\n\n' | jq -R . | jq -sc 'map(select(length > 0))')" \
     --argjson toolscopes "$(printf '%s' "$COORD_TOOLING_SCOPES" | tr ', ' '\n\n' | jq -R . | jq -sc 'map(select(length > 0) | ascii_downcase)')" \
     --arg inreview "${LBL_IN_REVIEW:-status:in-review}" "$@"
}

# The queue in run order: <ticket> \t <class> \t <note>; with --wide,
# <ticket> \t <class> \t <priority 0-9> \t <polish 0|1> \t <polish list 0|1> \t <note>.
# Owner call 2026-10-19: priority decides first, across classes (P0 < P1 < P2 < P3
# < none); within one priority repair, approved-merge, then new; within one class
# product work before our own tooling (coord_tooling); then new by kind; then the
# queue's own position. A repair of any priority used to outrank every new
# ticket, so a P3 red held a P0 build back. An entry put at the front stays first
# overall. The tick's batched read ($ISSUES) is fresher than the seed: when it
# holds a ticket, its labels decide that ticket's priority and kind.
coord_queue_ordered() {
  local wide=0; [ "${1:-}" = --wide ] && wide=1
  [ -s "$COORD_QUEUE" ] || return 0
  coord_jq -r --argjson wide "$wide" --slurpfile iss <(printf '%s' "${ISSUES:-}" | jq -c 'objects' 2>/dev/null || true) \
    "$COORD_TICKET_JQ"'
     (($iss[0]) // {}) as $iss
     | .tickets | to_entries
     | map(.value as $t | ($iss[($t.n|tostring)] // null) as $i
         | (if $i then ($i.labels // []) else null end) as $ls
         | $t + {pos: .key,
                 prin: (if $ls then coord_prin($ls; null) else ($t.prin // 9) end),
                 kind: (if $ls then coord_kind($ls; ""; null; $i.title) else ($t.kind // "other") end),
                 polish: (if $ls then coord_polish($ls; null; $i.title) else ($t.polish // ($t.kind == "polish")) end),
                 plist: (if $ls then ($ls | index($plist)) != null else ($t.plist // false) end),
                 tool: (if $ls then coord_tooling($ls; $i.title) else ($t.tooling // false) end),
                 rank: ({"repair":0,"approved-merge":1,"new":2}[$t.class] // 3)})
     | sort_by(if .front then 0 else 1 end, (if .front then .pos else 0 end), .prin, .rank, (if .tool then 1 else 0 end),
               (if .class == "new" then ({"half-built":0, feature:1, other:2, polish:3}[.kind] // 2) else 0 end), .pos)
     | .[]
     | if $wide == 1 then [(.n|tostring), .class, (.prin|tostring), (if .polish then "1" else "0" end), (if .plist then "1" else "0" end), (.note // "")]
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
