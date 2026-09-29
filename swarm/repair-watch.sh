#!/usr/bin/env bash
# repair-watch.sh — the other half of "hand off after the push".
#
#   repair-watch.sh                 one pass: repair · unblock · restart · alarm
#   repair-watch.sh --only repair   one section (repair|unblock|infra|alarm)
#   repair-watch.sh --explain       say what it would do, change nothing
#
# An agent pushes, arms auto-merge and ends; nobody sits in a CI wait. This is
# what brings one back. Run it on a timer (swarm/install.sh sets that up).
#
# Four things happen in a pass:
#
#   REPAIR   a pull request whose checks have SETTLED red, or which now clashes
#            with the integration branch, gets one agent — ONE per head commit
#            per kind, so a fix that does not hold is never retried in a loop.
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
#
# THE STOP AFTER THREE IS STICKY. A ticket repaired three times in 24 hours and
# still red gets the needs-human label and a comment, which stops this watcher
# AND the scheduler — both read that label. Without the label the stop expired
# when the 24-hour window rolled, and #10685 got a fourth agent (2026-09-26).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swarm-env.sh" || exit 1

LOG="$SWARM_LOGS/repair-watch.log"
TRIED="$SWARM_DIR/repair-attempts.tsv"          # ticket \t sha \t kind \t epoch
touch "$TRIED"

DRY=0; ONLY=""
MAX_PER_PASS="${SWARM_REPAIRS_PER_PASS:-$(swarm_opt swarm.repairsPerPass 2)}"
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
    --only)    ONLY="${2:?--only needs repair|unblock|infra|alarm}"; shift 2 ;;
    --explain|--dry) DRY=1; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "repair-watch: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
say() { echo "$*"; [ "$DRY" = 1 ] || swarm_log "$LOG" "$*"; }
runs() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

# A ticket nobody may send an agent to.
#
# This list is DELIBERATELY SHORTER than the scheduler's. The scheduler will not
# start fresh work on a ticket that is in review — a person owns it. Repair is
# the opposite case: a ticket whose pull request is open is in review BY
# DEFINITION, so holding on that label would mean the watcher repaired nothing
# at all. What stops a repair is a deliberate pause: blocked, parked, handed to
# a person, or waiting on a decision.
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
  ps -eo command 2>/dev/null | grep -q "[s]pawn-claim.sh $1\$"
}

attempts_today() { # <ticket> [kind]
  local since; since=$(( $(swarm_now) - 86400 ))
  awk -F'\t' -v t="$1" -v k="${2:-}" -v d="$since" \
    '$1==t && $4>=d && (k=="" || $3==k)' "$TRIED" | grep -c . | tr -d ' '
}

# Is the machine able to take another agent for this programme right now?
room_for() { # <programme> — echoes why not, returns 1
  local live load
  live=$(swarm_live_count "$1"); load=$(swarm_load)
  if [ "$live" -ge "$SWARM_CAP" ]; then printf 'agents %s, cap %s' "$live" "$SWARM_CAP"; return 1; fi
  if [ "$load" -ge "$SWARM_MAX_LOAD" ]; then printf 'load %s' "$load"; return 1; fi
  return 0
}

# ---- 1. repair ---------------------------------------------------------------
repair_brief() { # <pr> <sha> <reason>
  cat <<BRIEF
REPAIR on PR #$1 at ${2:0:9}: $3.

Read the LATEST comment on the ticket and on the PR first — it may carry a
ruling you must apply. Then fix ONLY that: pull the PR branch (the merge robot
may have added commits), read the failing job logs (gh run view <id>
--log-failed), fix, re-run the local gates, re-stamp the review trailers only if
the fingerprint moved, push, keep auto-merge armed, hand off.

A clash: merge the integration branch keeping both sides' intent. If the same
failure also happens on the integration branch itself, say so on the PR and
stop.
BRIEF
}

section_repair() {
  local launched=0 row PR T SHA MSTATE PEND FAILS labs reason kind prog why
  while IFS=$'\t' read -r PR T SHA MSTATE PEND FAILS; do
    [ -n "${PR:-}" ] || continue
    [ "$launched" -lt "$MAX_PER_PASS" ] || break

    reason=""
    if [ "$MSTATE" = "DIRTY" ]; then reason="it clashes with $INTEGRATION_BRANCH"; kind=conflict
    elif [ "${PEND:-0}" = "0" ] && [ -n "$FAILS" ]; then reason="CI went red on: $FAILS"; kind=ci
    else continue; fi

    labs=$(labels_of "$T")
    [ -n "$labs" ] || continue
    case "$labs" in CLOSED,*) continue ;; esac
    paused "$labs" && continue

    # A clash with the integration branch does not move the PR's head, so the
    # kind is part of the key: one attempt per head commit PER KIND.
    grep -q "^$T	$SHA	$kind" "$TRIED" && continue

    if [ "$(attempts_today "$T")" -ge 3 ]; then
      stop_sticky "$PR" "$T" "$reason"
      continue
    fi
    already_going "$T" && continue

    prog=$(swarm_programme_of "$T")
    if ! why=$(room_for "$prog"); then
      say "hold #$PR ($T): $reason — machine busy ($why)"; continue
    fi
    if [ "$DRY" = 1 ]; then echo "WOULD repair #$PR ($T) at ${SHA:0:9}: $reason"; launched=$((launched+1)); continue; fi

    printf '%s\t%s\t%s\t%s\n' "$T" "$SHA" "$kind" "$(swarm_now)" >> "$TRIED"
    local brief; brief="$SWARM_DIR/briefs/repair-$T.md"
    mkdir -p "$(dirname "$brief")"; repair_brief "$PR" "$SHA" "$reason" > "$brief"
    swarm_spawn "$T" "$brief" >/dev/null 2>&1
    say "spawned repair for #$PR ($T) at ${SHA:0:9}: $reason"
    launched=$((launched+1))
  done <<< "$(open_prs)"
  [ "$launched" -eq 0 ] || say "repaired $launched pull request(s) this pass"
}

# Every open, non-draft PR on a ticket branch, as
# pr \t ticket \t sha \t mergeState \t pendingChecks \t failedCheckNames
open_prs() {
  swarm_gh pr list --repo "$REPO_SLUG" --state open --limit 100 \
    --json number,headRefName,headRefOid,isDraft,mergeStateStatus,statusCheckRollup \
    --jq "[.[] | select(.headRefName|startswith(\"$BRANCH_PREFIX\")) | select(.isDraft|not)
           | [.number,
              (.headRefName | ltrimstr(\"$BRANCH_PREFIX\") | split(\"/\")[0]),
              .headRefOid, .mergeStateStatus,
              ([.statusCheckRollup[]? | select(.status != \"COMPLETED\")] | length),
              ([.statusCheckRollup[]? | select(.conclusion == \"FAILURE\") | .name] | join(\";\"))]]
           | .[] | @tsv" 2>/dev/null
}

# Three repairs in a day and still red: hand it to a person, and make the hand-
# over STICK. One comment per ticket per day, so a stall does not spam.
stop_sticky() { # <pr> <ticket> <reason>
  grep -q "STOP #$1 " <<< "$(grep "^$(swarm_day)" "$LOG" 2>/dev/null)" && return 0
  if [ "$DRY" = 1 ]; then echo "WOULD STOP #$1 ($2): 3 repairs in 24h and still $3"; return 0; fi
  swarm_gh issue edit "$2" --repo "$REPO_SLUG" --add-label "$LBL_NEEDS_HUMAN" >/dev/null 2>&1
  swarm_gh issue comment "$2" --repo "$REPO_SLUG" --body \
    "**Stopped after 3 repairs in 24 hours** and still: $3. Labelled \`$LBL_NEEDS_HUMAN\`, so no agent is sent again until a person looks and removes the label." >/dev/null 2>&1
  say "STOP #$1 ($2): 3 repairs in 24h and still $3 — labelled $LBL_NEEDS_HUMAN"
}

# ---- 2. unblock --------------------------------------------------------------
# A ticket held behind others names them in a "Blocked until #12, #13" comment.
section_unblock() {
  local B parents p open
  while read -r B; do
    [ -n "${B:-}" ] || continue
    parents=$(swarm_gh issue view "$B" --repo "$REPO_SLUG" --json comments \
      -q '[.comments[].body | select(startswith("Blocked until"))] | last // ""' 2>/dev/null \
      | grep -oE '#[0-9]+' | tr -d '#' | sort -u)
    [ -n "$parents" ] || continue
    open=0
    for p in $parents; do
      [ "$(swarm_gh issue view "$p" --repo "$REPO_SLUG" --json state -q .state 2>/dev/null)" = CLOSED ] || open=1
    done
    [ "$open" = 0 ] || continue
    if [ "$DRY" = 1 ]; then echo "WOULD unblock #$B (every parent closed)"; continue; fi
    swarm_gh issue edit "$B" --repo "$REPO_SLUG" --remove-label "$LBL_BLOCKED" --add-label "$LBL_READY" >/dev/null 2>&1 &&
    swarm_gh issue comment "$B" --repo "$REPO_SLUG" --body "Unblocked: every parent has merged. Back in the queue." >/dev/null 2>&1
    say "unblocked #$B"
  done <<< "$(swarm_gh issue list --repo "$REPO_SLUG" --label "$LBL_BLOCKED" --state open --limit 200 --json number -q '.[].number' 2>/dev/null)"
}

# ---- 3. restart after an infrastructure error --------------------------------
INFRA_RE='API Error|Connection refused|ECONNRESET|ETIMEDOUT|overloaded|Overloaded|529|503 Service|socket hang up'
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
  done <<< "$(swarm_snapshot | jq -r --arg re "$INFRA_RE" '
      .live as $live
      | .done[]? | select((.endedAgoMin // 999) <= 90)
      | select(((.summary // "") | test($re)))
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
    open_prs | awk -F'\t' '$4=="DIRTY" || ($5=="0" && $6!="") {print $2}' \
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

  stops=$(grep "^$(swarm_day)" "$LOG" 2>/dev/null | grep -oE "STOP #[0-9]+" | sort -u | grep -c . | tr -d ' ')
  [ "${stops:-0}" -gt 0 ] && reasons="$reasons
- **Stopped after 3 repairs today:** $stops fix(es) — no more agents will be sent until a person looks."

  tail -1 "$SWARM_LOGS/scheduler.log" 2>/dev/null | grep -q 'usage limit' && \
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

# Held (#42): the two sections that spawn stand down BEFORE they record an
# attempt. Recording one and then being refused by swarm_spawn would spend the
# ticket's repair budget on nothing and mark a red PR "tried" at its SHA for good.
# Unblock and alarm spawn nothing, so they still run.
if held=$(swarm_held); then
  say "held — not repairing or restarting: $held"
else
  runs repair && section_repair
fi
runs unblock && section_unblock
if ! swarm_held >/dev/null; then runs infra && section_infra; fi
runs alarm   && section_alarm
exit 0
