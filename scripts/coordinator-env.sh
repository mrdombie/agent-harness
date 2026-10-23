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
#   coordinator.polishListFull COORDINATOR_POLISH_LIST_FULL 8 most items of one polish list that ride
#                                                           along with one change; a list never starts
#                                                           on its own while other work can, full or not
#   coordinator.openPrCap    COORDINATOR_OPEN_PR_CAP   10    open PRs (drafts too) over which no new ticket
#                                                           starts: every place repairs or finishes, and
#                                                           only repairs, approved merges and process fixes
#                                                           start. While on it replaces the healingShare
#                                                           split and heal-all: under it priority decides
#                                                           across repairs and new work, a repair first at
#                                                           one priority. 0: off, and the split runs again
#   coordinator.openPrCapQuick COORDINATOR_OPEN_PR_CAP_QUICK on  over the cap, new tickets the driver's size
#                                                           rules call quick start anyway, after healing
#                                                           (scripts/cap-quick.sh); false: none does
#   coordinator.openPrCapQuickScan COORDINATOR_OPEN_PR_CAP_QUICK_SCAN 40  bodies read a tick to pre-size
#   coordinator.capExemptPriorities COORDINATOR_CAP_EXEMPT_PRIORITIES ["P0"]  priorities the open-work cap
#                                                           never holds: they start over it whatever their
#                                                           size (scripts/cap-quick.sh); [] none
#   coordinator.toolingLabels COORDINATOR_TOOLING_LABELS (below) labels that make a ticket our own
#                                                           build tooling: it runs after product
#                                                           work of the same priority and class
#   coordinator.toolingScopes COORDINATOR_TOOLING_SCOPES gates ci harness ops pre-push dev
#                                                           title scopes ("feat(gates): …") that do too
#   coordinator.toolingCap   COORDINATOR_TOOLING_CAP    2    most live runs, on every host together, on
#                                                           tickets wearing coordinator.processLabel or a
#                                                           toolingCapLabels label; over it they wait and
#                                                           the places go to product work
#   coordinator.toolingCapLabels COORDINATOR_TOOLING_CAP_LABELS project:harness-kit repo:agent-harness
#   coordinator.minFreeGb    COORDINATOR_MIN_FREE_GB   20    disk alarm floor
#   coordinator.disk.stopBelowGb / .resumeAtGb  30 / 50    read by scripts/disk-guard.sh, the one reader
#   coordinator.sweepEveryMin COORDINATOR_SWEEP_EVERY_MIN 30  worktree sweep interval
#   coordinator.frozenMin    COORDINATOR_FROZEN_MIN    20    no log growth = frozen
#   coordinator.snapshotMaxAgeMin COORDINATOR_SNAPSHOT_MAX_AGE_MIN 15  oldest forge read a refused
#                                                           tick may start work from
#   coordinator.refreshEveryMin COORDINATOR_REFRESH_EVERY_MIN 5  queue re-seed interval
#   coordinator.paceToWindow  {on, factor, exempt}  true / 0.95 / ["P0"]: the five-hour line (the usage pacer, below)
#   coordinator.releaseScopeOnly COORDINATOR_RELEASE_SCOPE_ONLY off  true, or {on, priorities, excludeLabels,
#                                                           excludeMilestones (regexes), alsoIn: {labels, titlePrefixes, titlePatterns}}:
#                                                           no NEW ticket outside it is seeded or started.
#                                                           In: a listed priority, or an alsoIn label ("x:*" is a
#                                                           prefix), title prefix or title regex (case-insensitive,
#                                                           e.g. "\\bcard\\b"); an excluded label or milestone
#                                                           wins over both. Repairs, approved merges and process
#                                                           fixes are never held. true: P0 P1, after-launch, the
#                                                           milestones below, alsoIn the screen labels and
#                                                           "Batch:" / "Polish list:" titles; an object's missing
#                                                           keys take those defaults
#   coordinator.judges       COORDINATOR_JUDGES         1    judges at once
#   coordinator.judge.turns  COORDINATOR_JUDGE_TURNS   40
#   coordinator.judge.budgetUsd   COORDINATOR_JUDGE_BUDGET_USD   5
#   coordinator.judge.compactWindow  COORDINATOR_JUDGE_COMPACT  150000

_coord_self="${BASH_SOURCE[0]}"
# swarm-env.sh fills in a default load limit; the room test must know whether one was set.
COORD_MAX_LOAD_SET="${SWARM_MAX_LOAD:-}"
. "$(cd "$(dirname "$_coord_self")/../swarm" && pwd)/swarm-env.sh" || return 1 2>/dev/null || exit 1
. "$(cd "$(dirname "$_coord_self")" && pwd)/branch-ticket.sh" || return 1 2>/dev/null || exit 1
# driver_repo_self / driver_repo_foreign: a repo:<other> ticket is never seeded, ordered or started here.
. "$(cd "$(dirname "$_coord_self")/../driver" && pwd)/size-rules.sh" || return 1 2>/dev/null || exit 1
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
# Owner call 2026-10-22: no new ticket starts while more than this many changes are open.
COORD_OPEN_PR_CAP="${COORDINATOR_OPEN_PR_CAP:-$(swarm_opt coordinator.openPrCap 10)}"
case "$COORD_OPEN_PR_CAP" in off|false|none) COORD_OPEN_PR_CAP=0 ;; ""|*[!0-9]*) COORD_OPEN_PR_CAP=10 ;; esac
# Owner call 2026-10-19: at one priority, product work goes ahead of our own tooling.
COORD_TOOLING_LABELS="${COORDINATOR_TOOLING_LABELS:-$(swarm_opt coordinator.toolingLabels "repo:agent-harness code-health project:ci-throughput project:harness-kit area:OPS area:HYGIENE area:OPS-CONSOLE")}"
COORD_TOOLING_SCOPES="${COORDINATOR_TOOLING_SCOPES:-$(swarm_opt coordinator.toolingScopes "gates ci harness ops pre-push dev")}"
# Owner call 2026-10-22: tooling builders capped at 2, so product builders get the usage back.
COORD_TOOLING_CAP="${COORDINATOR_TOOLING_CAP:-$(swarm_opt coordinator.toolingCap 2)}"
case "$COORD_TOOLING_CAP" in ""|*[!0-9]*) COORD_TOOLING_CAP=2 ;; esac
COORD_TOOLING_CAP_LABELS="${COORDINATOR_TOOLING_CAP_LABELS:-$(swarm_opt coordinator.toolingCapLabels "project:harness-kit repo:agent-harness")}"
[ -n "$COORD_MAX_LOAD_SET" ] || COORD_MAX_LOAD_SET=$(swarm_opt swarm.maxLoad "")
COORD_MIN_FREE_GB="${COORDINATOR_MIN_FREE_GB:-$(swarm_opt coordinator.minFreeGb 20)}"
COORD_SWEEP_EVERY_MIN="${COORDINATOR_SWEEP_EVERY_MIN:-$(swarm_opt coordinator.sweepEveryMin 30)}"
# A process left in a worktree nothing owns is reaped once this old (stop-dev-servers.sh --strays),
# and at the cap even with somebody sitting there, once the worktree's claim is gone.
COORD_STRAY_MIN_AGE_MIN="${COORDINATOR_STRAY_MIN_AGE_MIN:-$(swarm_opt coordinator.strayMinAgeMin 30)}"
case "$COORD_STRAY_MIN_AGE_MIN" in ""|*[!0-9]*) COORD_STRAY_MIN_AGE_MIN=30 ;; esac
COORD_STRAY_MAX_AGE_MIN="${COORDINATOR_STRAY_MAX_AGE_MIN:-$(swarm_opt coordinator.strayMaxAgeMin 180)}"
case "$COORD_STRAY_MAX_AGE_MIN" in ""|*[!0-9]*) COORD_STRAY_MAX_AGE_MIN=180 ;; esac
COORD_STRAY_GRACE_SEC="${COORDINATOR_STRAY_GRACE_SEC:-$(swarm_opt coordinator.strayGraceSec 10)}"
case "$COORD_STRAY_GRACE_SEC" in ""|*[!0-9]*) COORD_STRAY_GRACE_SEC=10 ;; esac
COORD_FROZEN_MIN="${COORDINATOR_FROZEN_MIN:-$(swarm_opt coordinator.frozenMin 20)}"
COORD_JUDGES="${COORDINATOR_JUDGES:-$(swarm_opt coordinator.judges 1)}"
COORD_JUDGE_TURNS="${COORDINATOR_JUDGE_TURNS:-$(swarm_opt coordinator.judge.turns 40)}"
COORD_JUDGE_BUDGET="${COORDINATOR_JUDGE_BUDGET_USD:-$(swarm_opt coordinator.judge.budgetUsd 5)}"
COORD_JUDGE_COMPACT="${COORDINATOR_JUDGE_COMPACT:-$(swarm_opt coordinator.judge.compactWindow 150000)}"

# The release scope, as one JSON object coord_jq hands to coord_release_held. Off unless
# set; a regex that does not compile is dropped, so one typo never fails every read.
coord_release_scope_json() {
  local raw="${COORDINATOR_RELEASE_SCOPE_ONLY-}"
  [ -n "$raw" ] || { [ -n "${HARNESS_CFG:-}" ] && raw=$(jq -c '.coordinator.releaseScopeOnly // false' "$HARNESS_CFG" 2>/dev/null); }
  jq -nc --arg raw "${raw:-false}" --arg sp "${LBL_SCREEN_PREFIX:-screen:}" '
    ($raw | try fromjson catch $raw) as $v
    | {on: true, priorities: ["P0", "P1"], excludeLabels: ["after-launch"],
       excludeMilestones: ["(?i)post-?launch", "(?i)fast-follow", "(?i)phase 2"],
       alsoIn: {labels: [$sp + "*"], titlePrefixes: ["Batch:", "Polish list:"], titlePatterns: []}} as $d
    | (if $v == true or $v == 1 or $v == "1" or $v == "true" or $v == "on" then $d
       elif ($v | type) == "object" then $d + $v + {on: (if $v | has("on") then $v.on == true else true end),
                                                  alsoIn: ($d.alsoIn + ($v.alsoIn // {}))}
       else {on: false} end)
    | def compiles: [.[]? | strings | . as $re | select(try ("" | test($re; "i") | true) catch false)];
      .excludeMilestones = ((.excludeMilestones // []) | compiles)
    | if .alsoIn then .alsoIn.titlePatterns = ((.alsoIn.titlePatterns // []) | compiles) else . end' 2>/dev/null \
    || printf '{"on":false}'
}
COORD_RELEASE_SCOPE=$(coord_release_scope_json)
coord_release_on() { jq -e '.on == true' >/dev/null 2>&1 <<<"$COORD_RELEASE_SCOPE"; }

# coordinator.screensFirst (owner call 2026-10-23: until the release every screen reaches
# its final form first). On, the order is: process fixes (develop-red P0s carry the
# process label), then P0s that are not screen work, then all screen work at any
# priority, then the rest, then coordinator.lastInReleaseLabel (default release:last):
# still in the release, built after everything else in it. A P0 never goes last, label
# or not (owner, 2026-10-23: a P0 Critical stays at the top). true, or {"on": true, "screenMatch": {labels, titlePrefixes,
# titlePatterns, pictures}}; screenMatch keys replace the defaults. Off unless set.
coord_screens_first_json() {
  local raw="${COORDINATOR_SCREENS_FIRST-}" last="${COORDINATOR_LAST_IN_RELEASE_LABEL-}"
  [ -n "$raw" ] || { [ -n "${HARNESS_CFG:-}" ] && raw=$(jq -c '.coordinator.screensFirst // false' "$HARNESS_CFG" 2>/dev/null); }
  [ -n "$last" ] || { [ -n "${HARNESS_CFG:-}" ] && last=$(jq -r '.coordinator.lastInReleaseLabel // empty' "$HARNESS_CFG" 2>/dev/null); }
  jq -nc --arg raw "${raw:-false}" --arg sp "${LBL_SCREEN_PREFIX:-screen:}" --arg last "${last:-release:last}" '
    ($raw | try fromjson catch $raw) as $v
    | {labels: [$sp + "*"], titlePrefixes: ["Polish list:"], titlePatterns: ["\\bcard\\b"], pictures: true} as $d
    | (if $v == true or $v == 1 or $v == "1" or $v == "true" or $v == "on" then {on: true} + $d
       elif ($v | type) == "object" then {on: (if $v | has("on") then $v.on == true else true end)} + $d + ($v.screenMatch // {})
       else {on: false} end)
    | .lastLabel = $last
    | .titlePatterns = [(.titlePatterns // [])[]? | strings | . as $re | select(try ("" | test($re; "i") | true) catch false)]' 2>/dev/null \
    || printf '{"on":false}'
}
COORD_SCREENS_FIRST=$(coord_screens_first_json)
coord_screens_first_on() { jq -e '.on == true' >/dev/null 2>&1 <<<"$COORD_SCREENS_FIRST"; }
# The tickets with an approved picture, as the picture code marks one: picture-approve.sh's
# "Picture for any machine" comment (picture-fetch.sh HEAD_LINE) or a "Picture approved"
# comment (critic-judge.sh picture_date). One search per marker, cached here by the seed.
COORD_PICTURE_MARKERS=("Picture for any machine" "Picture approved")
COORD_SCREEN_PICS_FILE="$COORD_DIR/screen-pictures.json"
coord_screen_pics_load() {
  COORD_SCREEN_PICS=$(jq -c '[.tickets[]? | numbers]' "$COORD_SCREEN_PICS_FILE" 2>/dev/null) || COORD_SCREEN_PICS='[]'
  [ -n "$COORD_SCREEN_PICS" ] || COORD_SCREEN_PICS='[]'
}
coord_screen_pics_load
# coord_screen_pics_refresh — re-read the picture tickets; a failed read keeps the last
# good list (an unread search is unknown, never "no pictures").
coord_screen_pics_refresh() {
  coord_screens_first_on || return 0
  jq -e '.pictures != false' >/dev/null 2>&1 <<<"$COORD_SCREENS_FIRST" || return 0
  declare -F gh_read >/dev/null 2>&1 || . "$KIT_ROOT/scripts/gh-batch.sh" || return 1
  local m got all=""
  for m in "${COORD_PICTURE_MARKERS[@]}"; do
    got=$(gh_read "the tickets with a \"$m\" comment" api -X GET search/issues --paginate \
          -f q="repo:$REPO_SLUG is:issue is:open in:comments \"$m\"" -f per_page=100 \
          --jq '.items[]?.number') || return 1
    all="$all$got"$'\n'
  done
  printf '%s\n' "$all" | grep -E '^[0-9]+$' | sort -un | jq -R 'tonumber' | jq -sc --arg at "$(swarm_stamp)" '{at: $at, tickets: .}' \
    > "$COORD_SCREEN_PICS_FILE.$$" && mv -f "$COORD_SCREEN_PICS_FILE.$$" "$COORD_SCREEN_PICS_FILE"
  coord_screen_pics_load
}

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
# PACE TO THE FIVE-HOUR WINDOW (owner call 2026-10-23, "a speed-up"). Every host on the
# account burns one five-hour window. Each tick reads its utilization u and reset
# (the freshest on any host: coord_pace_reading) and draws a straight line to
# factor x 100% at the reset:
#     elapsed = 1 - (reset - now) / 5h        target = elapsed x factor
#   - u > target (ahead): no new builder starts, but a priority in `exempt` (P0);
#     the running ones carry on, and swarm.usageStepHold stays the backstop at the wall;
#   - u <= target (behind): places fill as they would unpaced, to the machine and the cap;
#   - no reading (or the window already reset): nothing to pace on, places fill (fail open).
# The seven-day window is never paced on. Every host draws the same line from the same
# freshest reading, a sheet reader with the owner's factor, so the fleet follows one rule.
# Replaces the budget pacer of 2026-10-20/21 (coordinator.pace.*: target, headroom, the
# weekly line, the measured burn, the owner's split and the product floor), retired here.
#
#   coordinator.paceToWindow.on      COORDINATOR_PACE          true   false: no pacing, the machine alone decides
#   coordinator.paceToWindow.factor  COORDINATOR_PACE_FACTOR   0.95   the share of the window the line ends at
#   coordinator.paceToWindow.exempt  COORDINATOR_PACE_EXEMPT   ["P0"] priorities that start while ahead
COORD_PACE="${COORDINATOR_PACE:-$(swarm_opt coordinator.paceToWindow.on true)}"
case "$COORD_PACE" in 0|false|off) COORD_PACE=0 ;; *) COORD_PACE=1 ;; esac
COORD_PACE_FACTOR="${COORDINATOR_PACE_FACTOR:-$(swarm_opt coordinator.paceToWindow.factor 0.95)}"
awk -v t="$COORD_PACE_FACTOR" 'BEGIN{exit !(t ~ /^[0-9]*\.?[0-9]+$/ && t+0 > 0 && t+0 <= 1)}' || COORD_PACE_FACTOR=0.95
# coord_pace_exempt — the exempt priorities as digits, space-separated ("0").
coord_pace_exempt() {
  local v
  if [ -n "${COORDINATOR_PACE_EXEMPT+x}" ]; then v="$COORDINATOR_PACE_EXEMPT"
  elif [ -r "${HARNESS_CFG:-}" ]; then
    v=$(jq -r '(.coordinator.paceToWindow.exempt // ["P0"]) | if type == "array" then join(" ") else tostring end' "$HARNESS_CFG" 2>/dev/null) || v=P0
  else v=P0; fi
  printf '%s\n' "$v" | tr -s ', ' '\n' | sed -n 's/^[Pp]\([0-9]\)$/\1/p' | tr '\n' ' '
}
# Samples: <epoch> \t <utilization> \t <window reset epoch> \t <builders on every host>
COORD_PACE_SAMPLES="$COORD_DIR/pace.tsv"
COORD_PACE_KEEP=1000
# This tick's reading and verdict, for the heartbeat, the sheet and the live view.
COORD_PACE_STATE="$COORD_DIR/pace.json"
COORD_PACE_FIVE_SEC=18000

# coord_pace_others — every reading the other hosts published, as [{host, usage, capacity, builds, tick}]:
# the sheet this tick read (a reader), else the fleet the last tick wrote (the owner).
coord_pace_others() {
  local f="${SHEET_FLEET:-}"
  [ -n "$f" ] && [ "$f" != "[]" ] || f=$(jq -c '.hosts // []' "$COORD_DIR/fleet.json" 2>/dev/null)
  [ -n "$f" ] || f="[]"
  printf '%s' "$f"
}

# coord_pace_reading [window] — "<utilization>\t<reset epoch>\t<observed epoch>" for that
# window now open (five_hour by default): the freshest of this host's builder logs and
# every host's heartbeat (swarm_usage_freshest_at), else the last sample taken while it
# is open. The observed time rides on into pace.json and the heartbeat unchanged: a
# republished reading is never newer than when it was read.
coord_pace_reading() {
  local w="${1:-five_hour}" now best extra
  now=$(swarm_now)
  extra=$(coord_pace_others | jq -c --arg w "$w" --arg sp "${SHEET_PACE:-}" \
            '[.[]? | .usage? | .[$w]? // empty] + [($sp | fromjson? // {}) | .usage? | .[$w]? // empty]' 2>/dev/null) || extra="[]"
  best=$(swarm_usage_freshest_at "$w" "${extra:-[]}") || best=""
  if [ -z "$best" ] && [ "$w" = five_hour ] && [ -s "$COORD_PACE_SAMPLES" ]; then
    best=$(awk -F'\t' -v now="$now" '$3 + 0 > now + 0 { u = $2; r = $3; a = $1 } END { if (r) printf "%s\t%s\t%s", u, r, a }' "$COORD_PACE_SAMPLES")
  fi
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# coord_pace_fresh — this tick's pace.json, or nothing when no tick wrote one in the last 15 minutes.
coord_pace_fresh() {
  jq -c --argjson now "$(swarm_now)" 'select((.at // 0) > $now - 900)' "$COORD_PACE_STATE" 2>/dev/null
}

# coord_pace <builders here> <claim rows> <this host> — "<ahead 1|0>\t<line>", 1 with the
# reason when there is nothing to pace on (off, or no five-hour reading: places fill).
# Claim rows are <ticket> \t <host> \t <step>; a row naming another host is a builder
# there, counted into the sample. Writes pace.json; a sheet reader paces by the factor
# the owner published, so every host draws the same line.
coord_pace() {
  local here="${1:-0}" rows="${2:-}" host="${3:-}" reading u r a w7 u7="" r7="" a7="" other total now f="$COORD_PACE_FACTOR" role verdict
  rm -f "$COORD_PACE_STATE" 2>/dev/null
  [ "$COORD_PACE" = 1 ] || { printf 'pacing: off (coordinator.paceToWindow.on) — the machine alone decides'; return 1; }
  role=off; ! declare -F coord_sheet_role >/dev/null || role=$(coord_sheet_role)
  if [ "$role" = reader ] && [ -n "${SHEET_PACE:-}" ]; then
    f=$(jq -r --arg d "$f" '(.settings.factor // null) | if type == "number" and . > 0 and . <= 1 then tostring else $d end' <<<"$SHEET_PACE" 2>/dev/null) || f="$COORD_PACE_FACTOR"
    [ -n "$f" ] || f="$COORD_PACE_FACTOR"
  fi
  reading=$(coord_pace_reading five_hour) || { printf 'pacing: no five-hour reading — places fill, the machine alone decides'; return 1; }
  IFS=$'\t' read -r u r a <<<"$reading"; now=$(swarm_now)
  case "$a" in ''|*[!0-9]*) a=0 ;; esac
  if w7=$(coord_pace_reading seven_day); then IFS=$'\t' read -r u7 r7 a7 <<<"$w7"; case "$a7" in ''|*[!0-9]*) a7=0 ;; esac; fi
  other=$(printf '%s\n' "$rows" | awk -F'\t' -v h="$host" '$1 ~ /^[0-9]+$/ && $2 != "" && $2 != h { n++ } END { print n + 0 }')
  total=$(( here + other ))
  mkdir -p "$(dirname "$COORD_PACE_SAMPLES")" 2>/dev/null
  printf '%s\t%s\t%s\t%s\n' "$now" "$u" "$r" "$total" >> "$COORD_PACE_SAMPLES"
  tail -"$COORD_PACE_KEEP" "$COORD_PACE_SAMPLES" > "$COORD_PACE_SAMPLES.$$" 2>/dev/null && mv -f "$COORD_PACE_SAMPLES.$$" "$COORD_PACE_SAMPLES"
  # "<ahead 0|1>\t<elapsed>\t<target>"
  verdict=$(awk -v u="$u" -v r="$r" -v now="$now" -v f="$f" -v L="$COORD_PACE_FIVE_SEC" 'BEGIN {
    e = 1 - (r - now) / L; if (e < 0) e = 0; if (e > 1) e = 1
    t = e * f; printf "%d\t%.4f\t%.4f", (u + 0 > t + 1e-9), e, t }')
  local ahead e t ex
  IFS=$'\t' read -r ahead e t <<<"$verdict"
  ex=$(coord_pace_exempt | awk '{ for (i = 1; i <= NF; i++) printf "%sP%s", (i > 1 ? "/" : ""), $i }')
  jq -cn --argjson at "$now" --arg host "$host" --argjson u "$u" --argjson r "$r" --argjson a "$a" --arg u7 "$u7" --arg r7 "$r7" --arg a7 "$a7" \
     --argjson e "$e" --argjson t "$t" --argjson ahead "$([ "$ahead" = 1 ] && echo true || echo false)" --argjson f "$f" --arg ex "$ex" \
     --argjson running "$total" --argjson other "$other" '
    {at: $at, host: $host,
     usage: ({five_hour: {u: $u, reset: $r, at: $a}} + (if $u7 == "" then {} else {seven_day: {u: ($u7 | tonumber), reset: ($r7 | tonumber), at: ($a7 | tonumber)}} end)),
     fiveHour: {u: $u, reset: $r, elapsed: $e, line: $t, ahead: $ahead},
     pacing: (if $ahead then "ahead" else "behind" end),
     running: $running, otherHosts: $other,
     settings: {factor: $f, exempt: ($ex | split("/") | map(select(. != "")))}}' \
     > "$COORD_PACE_STATE.$$" 2>/dev/null && mv -f "$COORD_PACE_STATE.$$" "$COORD_PACE_STATE"
  printf '%s\t' "$ahead"
  awk -v u="$u" -v t="$t" -v e="$e" -v f="$f" -v at="$(swarm_iso "$r" | cut -c12-16)" -v ahead="$ahead" -v ex="$ex" 'BEGIN {
    printf "pacing: %s — 5h window %d%% against a target of %d%% (%d%% of the window gone x %.2f, resets %sZ)",
      (ahead ? "ahead" : "behind"), u * 100 + 0.5, t * 100 + 0.5, e * 100 + 0.5, f, at
    if (ahead) printf ": no new builder starts%s; the running ones carry on", (ex == "" ? "" : " but " ex)
    else printf ": places fill" }'
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
#   coord_process a process fix (coordinator.processLabel, default process): first of
#                all, whatever its priority, class or kind (owner call 2026-10-20)
#   coord_release_held new work outside coordinator.releaseScopeOnly: never seeded,
#                never started. Repairs, approved merges and process fixes never are.
COORD_TICKET_JQ='
  def coord_process($ls): ($ls | index($process)) != null;
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
  # The other repo a repo:<name> label names, or null: a ticket with repo: labels, none
  # of them a repo this project builds ($ownrepos, driver_repo_own), belongs to that repo.
  def coord_foreign($ls):
    ([$ls[]? | select(type == "string" and test("^repo:"; "i")) | sub("^repo:\\s*"; ""; "i")
      | split("/") | last | ascii_downcase | select(length > 0)]) as $r
    | if ($ownrepos | length) == 0 or ($r | length) == 0 or ($r | any(. as $x | $ownrepos | index($x) != null))
      then null else $r[0] end;
  def coord_repair_note($note): (($note // "") | test("(^|\n)REPAIR on PR #[0-9]"));
  def coord_class($c; $note): if ($c // "new") == "new" and coord_repair_note($note) then "repair" else ($c // "new") end;
  def coord_release_also($ls; $title):
    ($ls | any(. as $l | ($release.alsoIn.labels // []) | any(. as $p
        | if ($p | endswith("*")) then ($l | startswith($p[:-1])) else $l == $p end)))
    or ((($title // "") | ascii_downcase) as $t
        | ($release.alsoIn.titlePrefixes // []) | any(. as $p | $t | startswith($p | ascii_downcase)))
    or (($title // "") as $t | ($release.alsoIn.titlePatterns // []) | any(. as $re | $t | test($re; "i")));
  # Screen work under coordinator.screensFirst: a screen label, a "Polish list:" title,
  # a card title, or an approved picture on the ticket ($pics). A "Batch:" of screen
  # work carries its screen label, so the label covers it.
  def coord_screen($ls; $title; $n):
    ($screens.on == true) and (
      ($ls | any(. as $l | ($screens.labels // []) | any(. as $p
          | if ($p | endswith("*")) then ($l | startswith($p[:-1])) else $l == $p end)))
      or ((($title // "") | ascii_downcase) as $t
          | ($screens.titlePrefixes // []) | any(. as $p | $t | startswith($p | ascii_downcase)))
      or (($title // "") as $t | ($screens.titlePatterns // []) | any(. as $re | $t | test($re; "i")))
      or (($screens.pictures != false) and ($n != null) and (($pics | index($n | tonumber)) != null)));
  # Last in the release: the label, never on a P0.
  def coord_last($ls; $prin): ($screens.on == true) and $prin != 0 and (($ls | index($screens.lastLabel // "release:last")) != null);
  # The tier screensFirst orders by, ahead of everything but process: 0 off or a process
  # fix, 1 a P0 that is not screen work, 2 screen work at any priority, 3 the rest,
  # 4 last in the release.
  def coord_tier($screen; $prin; $proc; $last):
    if ($screens.on != true) or $proc then 0 elif $last then 4 elif $screen then 2 elif $prin == 0 then 1 else 3 end;
  def coord_release_held($ls; $title; $milestone; $class):
    ($release.on == true) and (($class // "new") == "new") and (coord_process($ls) | not)
    and (($ls | any(. as $l | ($release.excludeLabels // []) | any(. == $l)))
         or ((($milestone // "") | if type == "object" then (.title // "") else . end) as $m
             | $m != "" and (($release.excludeMilestones // []) | any(. as $re | $m | test($re))))
         or ((coord_pri($ls; null) as $p | ($release.priorities // []) | any(. == $p) | not)
             and (coord_release_also($ls; $title) | not)));'
# The stop labels coord_stopped reads, one JSON array each.
coord_stop_json() { # all|new
  { printf '%s\n' "${LBL_BATCHED:-status:batched}" "$LBL_PARKED" "$LBL_BLOCKED" "$LBL_EXTERNAL_BLOCKED" \
      "$LBL_GATED" "$LBL_DRAFTING" "$LBL_PM_DECISION" "$LBL_PM_TRACK"
    [ "$1" = new ] && printf '%s\n' "$HOLD_LABEL" "$LBL_NEEDS_HUMAN" "${LBL_OWNER_DECISION:-}" $DECISION_LABELS
  } | awk 'NF && !seen[$0]++' | jq -R . | jq -sc .
}
coord_jq() { # <jq args…> — jq with COORD_TICKET_JQ and the label names it needs
  jq --arg plist "$LBL_POLISH_LIST" --arg process "$SWARM_PROCESS_LABEL" --arg partial "${LBL_PARTIAL:-status:partial}" \
     --argjson tooling "$(printf '%s' "$COORD_TOOLING_LABELS" | tr ', ' '\n\n' | jq -R . | jq -sc 'map(select(length > 0))')" \
     --argjson toolscopes "$(printf '%s' "$COORD_TOOLING_SCOPES" | tr ', ' '\n\n' | jq -R . | jq -sc 'map(select(length > 0) | ascii_downcase)')" \
     --arg inreview "${LBL_IN_REVIEW:-status:in-review}" --argjson release "${COORD_RELEASE_SCOPE:-null}" \
     --argjson ownrepos "${COORD_OWN_REPOS_JSON:-$(driver_repo_own | jq -R . | jq -sc .)}" \
     --argjson stopall "$(coord_stop_json all)" --argjson stopnew "$(coord_stop_json new)" \
     --argjson screens "${COORD_SCREENS_FIRST:-null}" --argjson pics "${COORD_SCREEN_PICS:-[]}" "$@"
}

# The queue in run order: <ticket> \t <class> \t <note>; with --wide,
# <ticket> \t <class> \t <priority 0-9> \t <polish 0|1> \t <polish list 0|1> \t
# <never held 0|1> \t <process 0|1> \t <note>. Never held: an entry put at the front
# (a resume, an owner's answer), half-built work or a process fix — the polish hold
# never parks any of them. A process fix (coord_process) runs first of all, ahead of
# even an entry the PM put on top, in the sheet's order as in this machine's own.
# Owner call 2026-10-19: priority decides first, across classes (P0 < P1 < P2 < P3
# < none); within one priority repair, approved-merge, then new; within one class
# product work before our own tooling (coord_tooling); then new by kind; then the
# queue's own position. A repair of any priority used to outrank every new
# ticket, so a P3 red held a P0 build back. An entry put at the front stays first
# overall. A queue seeded from the shared sheet (coordinator-sheet.sh) runs in the
# sheet's order: its owner already ordered it. The tick's batched read ($ISSUES) is fresher than the seed: when it
# holds a ticket, its labels decide that ticket's priority and kind.
coord_queue_ordered() {
  local wide=0; [ "${1:-}" = --wide ] && wide=1; [ "${1:-}" = --tiers ] && wide=2
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
                 proc: (if $ls then coord_process($ls) else ($t.process // false) end),
                 screen: (if $ls then coord_screen($ls; $i.title; $t.n) else ($t.screen // false) end),
                 class: coord_class($t.class; $t.note)}
         | .last = (if $ls then coord_last($ls; .prin) else (($t.last // false) and .prin != 0) end)
         | . + {rank: ({"repair":0,"approved-merge":1,"new":2}[.class] // 3), tier: coord_tier(.screen; .prin; .proc; .last)})
     # A queue taken from the shared sheet keeps the order its owner wrote, exactly.
     # .top (the PM putting it on top with add --front) is first overall; .front (a resume, an answer,
     # a requeue) is first only among its own priority.
     | if $sheet then sort_by(if .proc then 0 else 1 end, if .top or .front then 0 else 1 end, .pos)
       else sort_by(if .proc then 0 else 1 end, .tier, if .top then 0 else 1 end, (if .top then .pos else 0 end), .prin,
               (if .front then 0 else 1 end), (if .front then .pos else 0 end), .rank, (if .tool then 1 else 0 end),
               (if .class == "new" then ({"half-built":0, feature:1, other:2, polish:3}[.kind] // 2) else 0 end), .pos) end
     | if $wide == 2 then [range(0; 5) as $k | [.[] | select(.tier == $k)] | length | tostring] | join("\t")
       else .[]
     | if $wide == 1 then [(.n|tostring), .class, (.prin|tostring), (if .polish then "1" else "0" end), (if .plist then "1" else "0" end),
                           (if .top or .front or .kind == "half-built" or .proc or .screen then "1" else "0" end),
                           (if .proc then "1" else "0" end), (.note // "")]
       else [(.n|tostring), .class, (.note // "")] end | @tsv end' "$COORD_QUEUE" 2>/dev/null
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
