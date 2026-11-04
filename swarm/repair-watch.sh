#!/usr/bin/env bash
# repair-watch.sh — the watcher beside the builds: warn · unblock · restart · alarm.
#
#   repair-watch.sh                 one pass
#   repair-watch.sh --only warn     one section (warn|unblock|infra|alarm)
#   repair-watch.sh --explain       say what it would do, change nothing
#
# Run it on a timer (swarm/install.sh sets that up). It sends no agent to a red or
# clashing pull request: there is no repair. One that cannot merge within
# coordinator.rebuildAfterMin is closed and its ticket built fresh by the
# coordinator's rebuild pass (scripts/rebuild.sh).
#
# Four things happen in a pass:
#
#   WARN     a PR red only on a check that warns until the release
#            (release.nonBlockingChecks) is told so on the PR, once per head.
#   UNBLOCK  a ticket held behind parents ("Blocked until #12, #13") goes back
#            to ready the moment every parent has closed.
#   RESTART  a run that ENDED on a connection or service error is not a failed
#            ticket. It is restarted once from its saved work, twice a day at
#            most. Three agents died together on 2026-09-26 and sat dead for
#            four hours with nobody told.
#   ALARM    one open issue, mentioned to the operator, that says the swarm has
#            stopped and why — updated while the stall lasts, closed when the
#            agents run again. Dom, 2026-09-25: "why am I not notified when
#            things stop running?"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swarm-env.sh" || exit 1

. "$KIT_ROOT/scripts/branch-ticket.sh" || exit 1
. "$KIT_ROOT/scripts/coordinator-env.sh" || exit 1

LOG="$SWARM_LOGS/repair-watch.log"
TRIED="$SWARM_DIR/repair-attempts.tsv"          # ticket \t sha \t kind \t epoch
touch "$TRIED"

DRY=0; ONLY=""
QUIET_SEC="${SWARM_QUIET_SEC:-$(swarm_opt swarm.quietSec 1200)}"
IDLE_MIN="${SWARM_IDLE_MIN:-$(swarm_opt swarm.idleMin 20)}"
ALARM_LABEL="${SWARM_ALARM_LABEL:-$(swarm_opt swarm.alarmLabel "swarm:stalled")}"
ALARM_MENTION="${SWARM_ALARM_MENTION:-$(swarm_opt swarm.alarmMention "")}"
ALARM_TITLE="The swarm has stopped — needs a look"
# GRADED, like everything else an agent files. A stopped swarm is a CRITICAL on the
# harness's one scale — work is not landing and nobody has been told — so the alarm
# carries the Critical priority. Without it the alarm sorted below whatever the queue
# happened to be showing, which is the same as not raising it.
ALARM_PRIORITY="${SWARM_ALARM_PRIORITY:-$(swarm_opt labels.priority.critical P0)}"

while [ $# -gt 0 ]; do
  case "$1" in
    --only)    ONLY="${2:?--only needs warn|unblock|infra|alarm}"; shift 2 ;;
    --explain|--dry) DRY=1; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "repair-watch: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
say() { echo "$*"; [ "$DRY" = 1 ] || swarm_log "$LOG" "$*"; }
runs() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

# A ticket nobody may send an agent to: a deliberate pause — blocked, parked,
# handed to a person, or waiting on a decision.
paused_labels() {
  printf '%s\n' "$LBL_BLOCKED" "$LBL_EXTERNAL_BLOCKED" "$LBL_PARKED" "$LBL_NEEDS_HUMAN" $DECISION_LABELS \
    | awk 'NF && !seen[$0]++'
}
paused() { # <label-csv>
  local l
  while read -r l; do
    [ -n "$l" ] || continue
    case ",$1," in *",$l,"*) return 0 ;; esac
  done <<EOS
$(paused_labels)
EOS
  return 1
}

labels_of() { # <ticket> — "OPEN,label,label"
  swarm_gh issue view "$1" --repo "$REPO_SLUG" --json state,labels \
    -q '.state + "," + ([.labels[].name] | join(","))' 2>/dev/null
}

# Is an agent already on its way to this ticket? A spawn takes seconds to appear
# in the run records, so the process table is asked too — otherwise two passes a
# minute apart both launch.
already_going() { # <ticket>
  swarm_ticket_live "$1" && return 0
  ps -eo command 2>/dev/null | grep "[s]pawn-claim.sh $1\$" >/dev/null
}

attempts_today() { # <ticket> [kind]
  local since; since=$(( $(swarm_now) - 86400 ))
  awk -F'\t' -v t="$1" -v k="${2:-}" -v d="$since" \
    '$1==t && $4>=d && (k=="" || $3==k)' "$TRIED" | grep -c . | tr -d ' '
}

# Every open PR on a ticket branch (branch_ticket: a bare-number branch too), drafts
# included, as pr \t ticket \t sha \t mergeState \t pendingChecks \t draft 0|1 \t do-not-merge 0|1
#   \t updatedAt \t failedCheckNames — last, as it may be empty (a tab IFS folds an empty
#   field in the middle); a draft's checks are never its red. The alarm reads it.
# A commit status has a state and no status/conclusion: a failed one is red, and a
# pending one never holds a red PR back, since no CI job is still running for it.
# The sign-off hold's own check is red BY the hold: never a red.
# Each check counts by its newest run (newest_runs): a red cleared by a re-run is not red.
HOLD_CHECK="${COORDINATOR_HOLD_CHECK:-$(swarm_opt coordinator.holdCheck approval 2>/dev/null || echo approval)}"
# A check in release.nonBlockingChecks is a warning until the release: never a red here.
open_prs() {
  gh_open_prs "${SWARM_PRS_MAX_AGE:-300}" | jq -r --arg pre "$BRANCH_PREFIX" --arg dnm "${LBL_DO_NOT_MERGE:-do-not-merge}" \
      --argjson nb "$(release_nonblocking_json)" "$BRANCH_TICKET_JQ$RELEASE_NB_JQ"' [.[] | (.headRefName | branch_ticket($pre)) as $t | select($t != "")
           | [.number, $t, .headRefOid, .mergeStateStatus,
              ([.statusCheckRollup | newest_runs | .[] | select((.status // "COMPLETED") != "COMPLETED")] | length),
              (if .isDraft then 1 else 0 end), (if any(.labels[]?; .name == $dnm) then 1 else 0 end), (.updatedAt // "-"),
              (if .isDraft then "" else
                ([.statusCheckRollup | newest_runs | .[] | select(.conclusion == "FAILURE" or ((.state // "") | test("FAILURE|ERROR")))
                | select(release_nb($nb) | not)
                | select(((.name // .context // "") | ascii_downcase) | contains("'"$HOLD_CHECK"'" | ascii_downcase) | not) | (.name // .context)] | join(";")) end)]]
           | .[] | @tsv' 2>/dev/null
}

# warn_prs — pr \t head \t listed reds \t ticket, for every open PR on a ticket branch whose checks
# have settled with a release.nonBlockingChecks check red. Nothing while the list is off.
warn_prs() {
  local nb; nb=$(release_nonblocking_json)
  [ "$nb" != "[]" ] || return 0
  # The same PRs open_prs reads, chosen the same way.
  gh_open_prs "${SWARM_PRS_MAX_AGE:-300}" | jq -r --arg pre "$BRANCH_PREFIX" --argjson nb "$nb" "$BRANCH_TICKET_JQ$RELEASE_NB_JQ"'
    .[] | select(.headRefName | startswith("'"$BRANCH_PREFIX"'")) | select(.isDraft | not)
    | select([.statusCheckRollup | newest_runs | .[] | select((.status // "COMPLETED") != "COMPLETED")] | length == 0)
    | ([.statusCheckRollup | newest_runs | .[] | select(release_nb($nb)) | select(release_red) | (.name // .context)] | unique | join(", ")) as $w
    | select($w != "") | [.number, .headRefOid, $w, (.headRefName | branch_ticket($pre))] | @tsv' 2>/dev/null
}

section_release_warn() {
  local pr sha names t
  while IFS=$'\t' read -r pr sha names t; do
    [ -n "${pr:-}" ] || continue
    # A PR that keeps the critic is never told its red does not block.
    if release_critic_scoped; then
      names=$(release_warn_reds "$(gh_open_prs "${SWARM_PRS_MAX_AGE:-300}" | jq -c --argjson n "$pr" '[.[] | select(.number == $n)] | first | .statusCheckRollup // []')" \
        "$(release_labels_of "$pr" "$t")")
      [ -n "$names" ] || continue
    fi
    RELEASE_WARN_DRY=$DRY release_warn_pr "$pr" "$sha" "$names" say
  done <<< "$(warn_prs)"
}

# ---- 2. unblock --------------------------------------------------------------
# A ticket held behind others is released by the one unblocker (scripts/unblock-waiting.sh),
# which the coordinator's housekeeping runs every pass; here only while no coordinator is live.
section_unblock() {
  if declare -F coord_live_recently >/dev/null && coord_live_recently; then
    [ "$DRY" = 1 ] && echo "unblock: the coordinator's housekeeping runs it"; return 0
  fi
  local l
  while IFS= read -r l; do [ -n "$l" ] && say "$l"; done < <(bash "$KIT_ROOT/scripts/unblock-waiting.sh" $([ "$DRY" = 1 ] && echo --dry-run) 2>&1)
}

# ---- 3. restart after an infrastructure error --------------------------------
# The live view marks a run that died on the service (its CLI-signal reader).
section_infra() {
  local T AGO labs n brief
  while IFS=$'\t' read -r T AGO; do
    [ -n "${T:-}" ] || continue
    already_going "$T" && continue
    n=$(attempts_today "$T" infra)
    if [ "$n" -ge 2 ]; then say "INFRA-STOP #$T: a connection or service error again after 2 restarts today"; continue; fi
    labs=$(labels_of "$T"); [ -n "$labs" ] || continue
    case "$labs" in CLOSED,*) continue ;; esac
    paused "$labs" && continue
    if [ "$DRY" = 1 ]; then echo "WOULD restart #$T (ended $AGO min ago on an infrastructure error)"; continue; fi
    if swarm_held >/dev/null; then say "held mid-pass — not restarting #$T"; break; fi
    printf '%s\t%s\t%s\t%s\n' "$T" "infra-$(swarm_now)" "infra" "$(swarm_now)" >> "$TRIED"
    brief="$SWARM_DIR/briefs/infra-$T.md"; mkdir -p "$(dirname "$brief")"
    cat > "$brief" <<BRIEF
RESUME AFTER A CONNECTION OR SERVICE ERROR: your previous run ended on an API or
network error ($AGO min ago), not on a problem in your work. Your worktree still
holds your commits and any unsaved files — commit those first. Re-read the
ticket, continue where you stopped, commit after each step, push, open or update
the pull request, hand off.
BRIEF
    swarm_spawn "$T" "$brief" >/dev/null 2>&1
    say "restarted #$T after an infrastructure error ($AGO min ago)"
  done <<< "$(swarm_snapshot | jq -r '
      .live as $live
      | .done[]? | select((.endedAgoMin // 999) <= 90)
      | select(.infra == true)
      | . as $d | select([$live[].ticket] | index($d.ticket) | not)
      | "\($d.ticket)\t\($d.endedAgoMin)"' 2>/dev/null | sort -u -k1,1)"
}

# ---- 4. the alarm ------------------------------------------------------------
# Programmes that have work waiting: a ready ticket, or a pull request that is
# red or clashing. An idle machine with nothing to do is not a stall.
work_waiting() {
  { swarm_gh issue list --repo "$REPO_SLUG" --state open --label "$LBL_READY" --limit 300 \
      --json labels -q "[.[].labels[].name | select(startswith(\"$SWARM_PROGRAMME_PREFIX\"))] | .[]" 2>/dev/null \
      | sed "s/^$SWARM_PROGRAMME_PREFIX//"
    open_prs | awk -F'\t' '$4=="DIRTY" || ($5=="0" && $9!="") {print $2}' \
      | while read -r t; do [ -n "$t" ] && swarm_programme_of "$t"; done
  } | awk 'NF && !seen[$0]++'
}

section_alarm() {
  local reasons="" p idle_f idle_min snap stuck stops existing body
  snap=$(swarm_snapshot)

  # The live view itself. One slow answer under load is not an outage — the
  # alarm needs two misses in a row, which is why the miss is remembered.
  local viewfail="$SWARM_DIR/live-view-missed"
  if [ -z "$snap" ]; then
    if [ -f "$viewfail" ]; then
      reasons="$reasons
- **The live view is not answering** ($(swarm_snapshot_why)), so nothing can check the swarm. Restart it: \`swarm/install.sh restart live-view\`."
    else
      [ "$DRY" = 1 ] || swarm_now > "$viewfail"
    fi
  else
    rm -f "$viewfail"
  fi

  for p in $(work_waiting); do
    idle_f="$SWARM_DIR/idle-since.$p"
    if [ "$(swarm_live_count "$p")" = "0" ]; then
      [ -f "$idle_f" ] || { [ "$DRY" = 1 ] || swarm_now > "$idle_f"; }
      idle_min=$(( ( $(swarm_now) - $(cat "$idle_f" 2>/dev/null || swarm_now) ) / 60 ))
      [ "$idle_min" -ge "$IDLE_MIN" ] && reasons="$reasons
- **No agent has run on $p for $idle_min min** while it has work waiting."
    else
      rm -f "$idle_f"
    fi
  done

  stuck=$(printf '%s' "$snap" | jq -r --argjson q "$QUIET_SEC" \
    '[.live[]? | select(.quietSec > $q) | "\(.title) (silent \(.quietSec/60|floor) min)"] | join("; ")' 2>/dev/null)
  [ -n "$stuck" ] && reasons="$reasons
- **Agent silent $((QUIET_SEC/60))+ min:** $stuck"

  tail -1 "$SWARM_LOGS/scheduler.log" 2>/dev/null | grep 'usage limit' >/dev/null && \
    reasons="$reasons
- **The swarm is holding on the plan's usage limit.**"

  existing=$(swarm_gh issue list --repo "$REPO_SLUG" --state open --label "$ALARM_LABEL" \
               --json number -q '.[0].number // empty' 2>/dev/null)

  if [ -n "$reasons" ]; then
    body="${ALARM_MENTION:+$ALARM_MENTION

}Checked $(swarm_stamp).
$reasons"
    if [ "$DRY" = 1 ]; then echo "WOULD ALARM:"; printf '%s\n' "$body"; return 0; fi
    if [ -n "$existing" ]; then
      # At most one update an hour, so a long stall does not spam.
      local last age
      last=$(swarm_gh issue view "$existing" --repo "$REPO_SLUG" --json updatedAt -q .updatedAt 2>/dev/null)
      age=$(( $(swarm_now) - $(swarm_epoch "${last:-1970-01-01T00:00:00Z}") ))
      if [ "$age" -ge 3600 ]; then
        swarm_gh issue edit "$existing" --repo "$REPO_SLUG" --body "$body" >/dev/null 2>&1
        say "alarm updated #$existing"; swarm_ping_page
      fi
    else
      local n; n=$(swarm_gh issue create --repo "$REPO_SLUG" --title "$ALARM_TITLE" \
                     --label "$ALARM_LABEL" ${ALARM_PRIORITY:+--label "$ALARM_PRIORITY"} \
                     --body "$body" 2>/dev/null | grep -oE '[0-9]+$')
      say "ALARM opened #${n:-?}"; swarm_ping_page
    fi
  elif [ -n "$existing" ] && [ "$DRY" != 1 ]; then
    swarm_gh issue close "$existing" --repo "$REPO_SLUG" \
      --comment "Running again. Closing the alarm." >/dev/null 2>&1
    say "alarm closed #$existing"; swarm_ping_page
  fi
}

# Held (#42): the section that spawns stands down BEFORE it records an attempt.
# Warn, unblock and alarm spawn nothing, so they still run.
if held=$(swarm_held); then
  say "held — not restarting: $held"
fi
runs warn && section_release_warn
runs unblock && section_unblock
if ! swarm_held >/dev/null; then runs infra && section_infra; fi
runs alarm   && section_alarm
exit 0
