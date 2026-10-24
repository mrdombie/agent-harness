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

. "$KIT_ROOT/scripts/base-wait.sh" || exit 1
. "$KIT_ROOT/scripts/branch-ticket.sh" || exit 1
. "$KIT_ROOT/scripts/open-work.sh" || exit 1
# The one repair gate every repair start goes through (scripts/repair-gate.sh).
. "$KIT_ROOT/scripts/coordinator-env.sh" || exit 1
. "$KIT_ROOT/scripts/pr-red.sh" || exit 1
declare -F issue_status_set >/dev/null || . "$KIT_ROOT/scripts/issue-status.sh" || exit 1
. "$KIT_ROOT/scripts/repair-gate.sh" || exit 1

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
# A clash is mechanical: a park does not hold its repair (the coordinator's open-work rule).
paused() { # <label-csv> [kind]
  local l
  while read -r l; do
    [ -n "$l" ] || continue
    [ "${2:-}" = conflict ] && [ "$l" = "$LBL_PARKED" ] && continue
    case ",$1," in *",$l,"*) return 0 ;; esac
  done <<EOS
$(paused_labels)
EOS
  return 1
}

# A pass asks about many tickets; one batched read answers them all (gh-batch.sh),
# and only a ticket that read missed is asked on its own.
_LABELS='{}'
labels_prefetch() { # <ticket…>
  [ $# -gt 0 ] || return 0
  _LABELS=$(gh_issues_batch "$@" 2>/dev/null)
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$_LABELS" || _LABELS='{}'
}
labels_of() { # <ticket> — "OPEN,label,label"
  local hit
  hit=$(jq -r --arg t "$1" '.[$t] // empty | .state + "," + (.labels | join(","))' <<<"$_LABELS" 2>/dev/null)
  if [ -n "$hit" ]; then printf '%s' "$hit"; return 0; fi
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

# Is the machine able to take another agent for this programme right now?
room_for() { # <programme> — echoes why not, returns 1
  local live busy
  live=$(swarm_live_count "$1")
  if [ "$live" -ge "$SWARM_CAP" ]; then printf 'agents %s, cap %s' "$live" "$SWARM_CAP"; return 1; fi
  if busy=$(swarm_machine_busy); then printf '%s' "$busy"; return 1; fi
  return 0
}

# ---- 1. repair ---------------------------------------------------------------
repair_brief() { # <pr> <sha> <reason>
  local rule; rule=$(head -1 "$KIT_ROOT/shared/signoff-last.md" 2>/dev/null)
  [ -n "$rule" ] || { echo "repair-watch: $KIT_ROOT/shared/signoff-last.md is missing" >&2; return 1; }
  local critic="A red design status is fixed by fixing every finding in the critic's
comment on the PR, a Minor too, whoever put it there — unless the PR's screens are
signed off: then those findings are the PM's call, and you change no pixel."
  # Off until the release: its comments on the PR are no task and no question.
  release_critic_paused && critic="The design critic is off until the release: ignore each of its verdicts and
findings on the PR, signed off or not — no fix, no deferral, no question, and never
run the critic."
  cat <<BRIEF
$rule

REPAIR on PR #$1 at ${2:0:9}: $3.

Read the LATEST comment on the ticket and on the PR first — it may carry a
ruling you must apply. Then fix ONLY that: pull the PR branch (the merge robot
may have added commits), read the failing job logs (gh run view <id>
--log-failed), fix, re-run the local gates, re-stamp the code-review trailer only
if the fingerprint moved, push, keep auto-merge armed, hand off. Never write a
design verdict: the independent critic sets the design status on CI's shots after
the push. $critic

Your own code review counts its rounds from this repair: round 1 fixes every
Critical, Major and Minor; from round 2 only Critical and Major block, and each
Minor goes on its screen's polish list (scripts/polish-list.sh add <screen>
"[Minor] <finding> — <file>:<line>"), or, with no screen, under "Minor, deferred"
in your PR comment. Nits are dropped.

A clash: merge the integration branch keeping both sides' intent. If the same
failure also happens on the integration branch itself, say so on the PR and
stop.
BRIEF
}

# What is failing on the integration branch's newest commit, ";"-joined; empty
# when nothing is. "unknown" when it cannot be read, which holds like red.
#
# While the trunk itself is red every PR's CI is red for a reason no PR repair
# can fix. A repair spent then is recorded as tried at that head commit and never
# retried, so the PR sits unrepaired after the trunk is fixed — eight did, for
# nine hours, on the estate this came from. So CI repairs wait for a green trunk
# without recording an attempt. A clash is still repaired: it is the PR's own.
integration_red() {
  local out
  out=$(swarm_gh api "repos/$REPO_SLUG/commits/$INTEGRATION_BRANCH/check-runs?per_page=100" \
    -q '[.check_runs[] | select(.conclusion=="failure" or .conclusion=="timed_out") | .name] | join(";")' \
    2>/dev/null) || { printf 'unknown'; return; }
  # A check that warns until the release does not hold the trunk red either.
  local n keep="" IFS=';'
  for n in $out; do release_check_nonblocking "$n" || keep="$keep${keep:+;}$n"; done
  printf '%s' "$keep"
}

# repair_kind <mergeState> <pending> <fails> [draft 0|1] — "conflict", "ci" or "draft"; 1 when
# nothing to repair. A draft is the driver's park: repaired when it clashes, or once its
# park is cleared (section_repair reads the labels); its CI mid-build is no red.
repair_kind() {
  if [ "$1" = "DIRTY" ]; then printf conflict
  elif [ "${4:-0}" = 1 ]; then printf draft
  elif [ "${2:-0}" = "0" ] && [ -n "$3" ]; then printf ci
  else return 1; fi
}

section_repair() {
  local launched=0 row PR T SHA MSTATE PEND FAILS labs reason kind prog why trunk_red rows want=""
  trunk_red=$(integration_red)
  [ -z "$trunk_red" ] || say "$INTEGRATION_BRANCH is red ($trunk_red) — CI repairs wait until it is green"
  rows=$(open_prs)
  section_release_warn
  # The tickets this pass may still act on, read in one request before the loop.
  while IFS=$'\t' read -r PR T SHA MSTATE PEND DRAFT DNM UPD FAILS; do
    [ -n "${PR:-}" ] || continue
    kind=$(repair_kind "$MSTATE" "$PEND" "$FAILS" "$DRAFT") || continue
    [ "$kind" = ci ] && [ -n "$trunk_red" ] && continue
    grep -q "^$T	$SHA	$kind" "$TRIED" && continue
    want="$want $T"
  done <<< "$rows"
  labels_prefetch $want
  while IFS=$'\t' read -r PR T SHA MSTATE PEND DRAFT DNM UPD FAILS; do
    [ -n "${PR:-}" ] || continue
    [ "$launched" -lt "$MAX_PER_PASS" ] || break

    reason=""
    kind=$(repair_kind "$MSTATE" "$PEND" "$FAILS" "$DRAFT") || continue
    case "$kind" in
      conflict) reason="it clashes with $INTEGRATION_BRANCH" ;;
      ci)       reason="CI went red on: $FAILS" ;;
      draft)    reason="it is a parked draft whose park has cleared" ;;
    esac
    # A person's stop wins: their do-not-merge, or a draft they made.
    [ "${DNM:-0}" = 0 ] || continue
    if [ "${DRAFT:-0}" = 1 ]; then open_work_person_drafted "$PR" "${UPD#-}" >/dev/null; [ $? = 1 ] || continue; fi
    if [ "$kind" = ci ] && [ -n "$trunk_red" ]; then
      [ "$DRY" = 1 ] && echo "HOLD #$PR ($T): $INTEGRATION_BRANCH is red, not this PR"
      continue
    fi

    # A clash with the integration branch does not move the PR's head, so the
    # kind is part of the key: one attempt per head commit PER KIND.
    grep -q "^$T	$SHA	$kind" "$TRIED" && continue
    if [ "$kind" != conflict ] && swarm_heal_parked_out "$T" "$SHA"; then
      say "skip #$PR ($T): parked past its cap on this head — a person looks first"; continue
    fi
    if [ "$kind" = ci ] && base_wait_holds "$T" "$SHA"; then
      say "skip #$PR ($T): its reds fail on $INTEGRATION_BRANCH too — waiting for that fix (base-waits.tsv)"; continue
    fi

    labs=$(labels_of "$T")
    [ -n "$labs" ] || continue
    case "$labs" in CLOSED,*) continue ;; esac
    paused "$labs" "$kind" && continue
    # A draft still parked, or still being built, is no repair's yet.
    if [ "$kind" = draft ]; then
      case ",$labs," in *",$LBL_PARKED,"*|*",$LBL_CLAIMED,"*) continue ;; esac
    fi

    if [ "$(attempts_today "$T")" -ge 3 ]; then
      stop_sticky "$PR" "$T" "$reason"
      continue
    fi
    already_going "$T" && continue

    prog=$(swarm_programme_of "$T")
    if ! why=$(room_for "$prog"); then
      say "hold #$PR ($T): $reason — machine busy ($why)"; continue
    fi
    local gwhy
    if ! gwhy=$(repair_gate "$T" "$(gh_open_prs "${SWARM_PRS_MAX_AGE:-300}" | jq -c --argjson n "$PR" '[.[] | select(.number == $n)] | first // empty')"); then
      say "skip #$PR ($T): $gwhy"; continue
    fi
    if [ "$DRY" = 1 ]; then echo "WOULD repair #$PR ($T) at ${SHA:0:9}: $reason"; launched=$((launched+1)); continue; fi

    # A hold placed mid-pass: checked again right before the attempt is spent.
    if swarm_held >/dev/null; then say "held mid-pass — not repairing #$PR ($T)"; break; fi
    local brief; brief="$SWARM_DIR/briefs/repair-$T.md"
    mkdir -p "$(dirname "$brief")"
    repair_brief "$PR" "$SHA" "$reason" > "$brief" || { say "no repair for #$PR ($T): its brief could not be written"; continue; }
    printf '%s\t%s\t%s\t%s\n' "$T" "$SHA" "$kind" "$(swarm_now)" >> "$TRIED"
    swarm_spawn "$T" "$brief" >/dev/null 2>&1 && repair_record "$T"
    say "spawned repair for #$PR ($T) at ${SHA:0:9}: $reason"
    launched=$((launched+1))
  done <<< "$rows"
  [ "$launched" -eq 0 ] || say "repaired $launched pull request(s) this pass"
}

# Every open PR on a ticket branch (branch_ticket: a bare-number branch too), drafts
# included, as pr \t ticket \t sha \t mergeState \t pendingChecks \t draft 0|1 \t do-not-merge 0|1
#   \t updatedAt \t failedCheckNames — last, as it may be empty (a tab IFS folds an empty
#   field in the middle); a draft's checks are never its red.
# Drafts were left out, and every parked draft sat clashing with nothing to repair it
# (23 Oct: 11 of 17 clashing PRs, the open-work cap full, 0 builds).
# A commit status has a state and no status/conclusion: a failed one is red, and a
# pending one never holds a red PR back, since no CI job is still running for it.
# The sign-off hold's own check is red BY the hold: never a red to repair.
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

# warn_prs — pr \t head \t listed reds, for every open PR on a ticket branch whose checks
# have settled with a release.nonBlockingChecks check red. Nothing while the list is off.
warn_prs() {
  local nb; nb=$(release_nonblocking_json)
  [ "$nb" != "[]" ] || return 0
  # The same PRs open_prs reads, chosen the same way.
  gh_open_prs "${SWARM_PRS_MAX_AGE:-300}" | jq -r --argjson nb "$nb" "$RELEASE_NB_JQ"'
    .[] | select(.headRefName | startswith("'"$BRANCH_PREFIX"'")) | select(.isDraft | not)
    | select([.statusCheckRollup | newest_runs | .[] | select((.status // "COMPLETED") != "COMPLETED")] | length == 0)
    | ([.statusCheckRollup | newest_runs | .[] | select(release_nb($nb)) | select(release_red) | (.name // .context)] | unique | join(", ")) as $w
    | select($w != "") | [.number, .headRefOid, $w] | @tsv' 2>/dev/null
}

section_release_warn() {
  local pr sha names
  while IFS=$'\t' read -r pr sha names; do
    [ -n "${pr:-}" ] || continue
    RELEASE_WARN_DRY=$DRY release_warn_pr "$pr" "$sha" "$names" say
  done <<< "$(warn_prs)"
}

# Three repairs in a day and still red: hand it to a person, and make the hand-
# over STICK. One comment per ticket per day, so a stall does not spam.
stop_sticky() { # <pr> <ticket> <reason>
  grep -q "STOP #$1 " <<< "$(grep "^$(swarm_day)" "$LOG" 2>/dev/null)" && return 0
  if [ "$DRY" = 1 ]; then echo "WOULD STOP #$1 ($2): 3 repairs in 24h and still $3"; return 0; fi
  issue_status_set "$2" "$LBL_NEEDS_HUMAN" >/dev/null 2>&1
  swarm_gh issue comment "$2" --repo "$REPO_SLUG" --body \
    "**Stopped after 3 repairs in 24 hours** and still: $3. Labelled \`$LBL_NEEDS_HUMAN\`, so no agent is sent again until a person looks and removes the label." >/dev/null 2>&1
  say "STOP #$1 ($2): 3 repairs in 24h and still $3 — labelled $LBL_NEEDS_HUMAN"
}

# ---- 2. unblock --------------------------------------------------------------
# A ticket held behind others names them in a "Blocked until #12, #13" comment.
# One list read carries every held ticket's comments, and one batched read every parent's state.
section_unblock() {
  local B parents p open held all states
  held=$(swarm_gh issue list --repo "$REPO_SLUG" --label "$LBL_BLOCKED" --state open --limit 200 --json number,comments \
    -q '.[] | "\(.number)\t\([.comments[]?.body | select(startswith("Blocked until"))] | last // "" | [scan("#[0-9]+")] | join(" "))"' 2>/dev/null)
  all=$(printf '%s\n' "$held" | cut -f2 | tr -d '#' | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u)
  states='{}'
  [ -z "$all" ] || states=$(gh_issues_batch $all 2>/dev/null)
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$states" || states='{}'
  while IFS=$'\t' read -r B parents; do
    [ -n "${B:-}" ] || continue
    parents=$(printf '%s' "$parents" | tr -d '#')
    [ -n "$parents" ] || continue
    open=0
    for p in $parents; do
      [ "$(jq -r --arg p "$p" '.[$p].state // empty' <<<"$states")" = CLOSED ] || open=1
    done
    [ "$open" = 0 ] || continue
    if [ "$DRY" = 1 ]; then echo "WOULD unblock #$B (every parent closed)"; continue; fi
    issue_status_set "$B" "$LBL_READY" >/dev/null 2>&1 &&
    swarm_gh issue comment "$B" --repo "$REPO_SLUG" --body "Unblocked: every parent has merged. Back in the queue." >/dev/null 2>&1
    say "unblocked #$B"
  done <<< "$held"
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

  stops=$(grep "^$(swarm_day)" "$LOG" 2>/dev/null | grep -oE "STOP #[0-9]+" | sort -u | grep -c . | tr -d ' ')
  [ "${stops:-0}" -gt 0 ] && reasons="$reasons
- **Stopped after 3 repairs today:** $stops fix(es) — no more agents will be sent until a person looks."

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
