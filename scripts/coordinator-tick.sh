#!/usr/bin/env bash
# coordinator-tick.sh — one check of the overnight coordinator, in a fresh
# process, with no model call. Run it on a timer (swarm/install.sh coordinator).
#
#   coordinator-tick.sh            one tick
#   COORDINATOR_SHADOW=0 …         act for real; anything else is shadow
#
# A /loop coordinator re-sends its whole conversation on every wake, so each
# check cost more than the last. This one starts empty every time and keeps its
# state on disk and on the forge, the way spawn-claim.sh already runs the agents.
#
# One tick, in order:
#   1. lock          a tick still running means this one exits, untouched
#   2. ended runs    each runs/*.ended not yet seen: its exit code and final result;
#                    one the usage limit or a lost login cut off goes back to the
#                    front of the queue (4b) with its worktree named, judged by no model
#   3. frozen runs   a live run whose log has not grown for coordinator.frozenMin
#                    (nor its record's progress_paths: a driver run's step logs)
#   4. pull requests red (unless fix-lock.sh says a session is on it), and the
#                    held pixel PRs gone green, sent to the owner a full batch at a time
#   5. spawn         as many starts as the spare CPU fits, while the machine has room
#                    (coord_room) and under coordinator.cap when one is set, and
#                    no more than this host's share of the five-hour window
#                    (coord_pace: every host's builders burn the one account);
#                    healing (repair, approved-merge) fills ceil(ceiling x
#                    healingShare) of the places and new work the rest, and every
#                    place while coordinator.healAllAt or more reds are left
#                    (waiting plus being healed, polish reds not counted); a class
#                    with nothing spawnable lends its places to the other. The
#                    queue runs by priority across classes (coord_queue_ordered);
#                    polish new work starts only when nothing else can, or when
#                    a polish list holds coordinator.polishListFull items. The
#                    room is re-read before each start after the first; under
#                    coordinator.rampFreeMemGb, one start a tick. Never a ticket
#                    that is claimed, gated, on hold or wearing the owner-decision
#                    label (owner-question.sh), and nothing while the machine is busy.
#                    A process fix (coordinator.processLabel) starts first, ahead of
#                    priority, kind, heal-all, the split and polish, in any free
#                    place; a swarm HOLD "for process fixes" (or with an
#                    `allow: process` line) starts only those (owner call 2026-10-20)
#   5a. disk         under coordinator.disk.stopBelowGb free, nothing new starts and the
#                    auto-clean runs (disk-guard.sh), until coordinator.disk.resumeAtGb is free
#   5b. merge lane   merge-lane.sh, when harness.json names merge.method
#   6. housekeeping  reconcile-claims.sh, stop-dev-servers.sh --sweep, then every
#                    coordinator.sweepEveryMin the worktree sweep (merged and closed work goes)
#   7. disk          below coordinator.minFreeGb: the worktree cache pass, then an alarm if still below
#   8. judgement     one fresh `claude -p` per judgement event (coordinator-judge.sh)
#
# 5b-8 run in coordinator-housekeeping.sh, under a lock of their own, in the
# background after the starts and at most every coordinator.housekeepingEveryMin
# (default 5): a tick is the starts, so it can run every 2 minutes.
# A run whose last word is a wait on a human is not re-picked until the wait moves
# (coordinator-waits.sh): a label, a commit, a comment or a red check on its PR.
#
# Shadow (the default): every act is written to actions.log as "would …";
# nothing is spawned, killed, posted or notified, and housekeeping runs dry.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/coordinator-env.sh" || exit 1
. "$SELF_DIR/coordinator-waits.sh" || exit 1
. "$SELF_DIR/coordinator-sheet.sh" || exit 1

RECONCILE="${COORDINATOR_RECONCILE:-$SELF_DIR/reconcile-claims.sh}"
SWEEP="${COORDINATOR_SWEEP:-$SELF_DIR/stop-dev-servers.sh}"
JUDGE="${COORDINATOR_JUDGE:-$SELF_DIR/coordinator-judge.sh}"
NOTIFY="$SELF_DIR/coordinator-notify.sh"
QUEUE="$SELF_DIR/coordinator-queue.sh"
SIGNOFF="$SELF_DIR/signoff-batch.sh"
POLISH="$SELF_DIR/polish-list.sh"
SEEN_ENDED="$COORD_DIR/ended.seen"
touch "$SEEN_ENDED" "$COORD_EVENTS" "$COORD_ACTIONS"

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; swarm_log "$COORD_LOG" "$*"; }

# ---- 1. lock ----------------------------------------------------------------
LOCK="$COORD_DIR/tick.lock"
coord_lock "$LOCK" tick || { say "tick: $COORD_LOCK_WHY — exiting"; exit 0; }
trap 'rm -rf "$LOCK"' EXIT
# Every gh call this tick and what it runs is counted against the tick.
export GH_CALLER=coordinator-tick
TICK_T0=$(swarm_now)

say "tick: $(coord_mode) mode, cap ${COORD_CAP:-none}, config from ${HARNESS_CFG_FROM:-?}"
# A live view that is up but answers nothing is never restarted by launchd: probe it.
LV_WATCHDOG="${COORDINATOR_LIVE_VIEW_WATCHDOG:-$SELF_DIR/live-view-watchdog.sh}"
[ "$LV_WATCHDOG" = off ] || { . "$LV_WATCHDOG" && live_view_watchdog; }

# Writes an event once; the id is what makes it once.
event() { # <id> <kind> <judge:true|false> <ticket> <pr> <detail>
  grep -qF "\"id\":\"$1\"" "$COORD_EVENTS" 2>/dev/null && return 1
  jq -cn --arg id "$1" --arg kind "$2" --argjson judge "$3" --arg t "$4" --arg pr "$5" \
     --arg d "$6" --arg at "$(swarm_stamp)" \
     '{id:$id, at:$at, kind:$kind, judge:$judge, ticket:$t, pr:$pr, detail:$d}' >> "$COORD_EVENTS"
  say "event: $2 ${4:+#$4 }${5:+PR $5 }— $6"
  return 0
}


# ---- 2. ended runs -----------------------------------------------------------
final_line() { # <log> — the run's own last word
  local r
  r=$(grep '"type":"result"' "$1" 2>/dev/null | tail -1 | jq -r '.result // empty' 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -1)
  [ -n "$r" ] || r=$(sed '/^[[:space:]]*$/d' "$1" 2>/dev/null | tail -1)
  printf '%s' "$r" | tr '\t\n' '  ' | cut -c1-240
}
limit_hit() { swarm_usage_log_limited "$1"; }
# Runs the wall cut off mid-work, waiting to go back on the queue: <ticket> \t <run-id> \t <log> \t <why>
CUT_PENDING="$COORD_DIR/cut.$(coord_mode)"
cut_off() { [ -n "$1" ] && printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$CUT_PENDING"; }
for ended in "$RUNS_DIR"/*.ended; do
  [ -f "$ended" ] || continue
  rid=$(basename "$ended" .ended)
  grep -qxF "$rid" "$SEEN_ENDED" && continue
  rec="$RUNS_DIR/$rid.json"
  code=$(jq -r '.exit_code // "?"' "$ended" 2>/dev/null)
  ticket=$(jq -r '.ticket // empty' "$rec" 2>/dev/null)
  log=$(jq -r '.log // empty' "$rec" 2>/dev/null)
  [ -n "$log" ] || log="$SWARM_LOGS/$rid.log"
  last=$(final_line "$log")
  printf '%s\n' "$rid" >> "$SEEN_ENDED"
  printf '%s\tended\t%s\t%s\texit=%s %s\n' "$(swarm_stamp)" "$rid" "${ticket:-?}" "$code" "$last" >> "$COORD_DIR/runs.log"
  say "ended: $rid exit $code — ${last:-no result line}"
  # Its last word is the newest on the ticket: a wait it ends on replaces an older one.
  if [ -n "$ticket" ]; then
    if [ "$code" = 0 ] && why=$(coord_wait_reason "$log"); then
      coord_wait_note "$ticket" "$rid" "$(jq -r '.ended_at // empty' "$ended" 2>/dev/null)" "$why"
      say "wait: #$ticket ended waiting on a human ($why) — not re-picked until that changes"
    else coord_wait_clear "$ticket"; fi
  fi
  if limit_hit "$log"; then
    event "usage-limit:$rid" usage-limit false "$ticket" "" "run $rid stopped on the plan's usage limit"
    cut_off "$ticket" "$rid" "$log" "the plan's usage limit"
  elif swarm_login_log_lost "$log"; then
    event "login-lost:$rid" login-lost false "$ticket" "" "run $rid stopped: the CLI is not logged in"
    cut_off "$ticket" "$rid" "$log" "a lost login"
    if event "login-lost:$(swarm_day)" login-lost false "" "" "the agents' CLI is not logged in"; then
      bash "$NOTIFY" --class owner "login-lost:$(swarm_day)" "The agents' Claude login has gone: every run stops at once until someone runs /login on this machine"
    fi
  elif [ "$code" = "${DRIVER_E_REQUEUE:-28}" ]; then
    # The driver put it back on the queue itself (a usage limit, a claim another run holds): nothing to judge.
    event "requeued:$rid" requeued false "$ticket" "" "run $rid requeued itself: ${last:-no result line}"
  elif [ "$code" = 26 ]; then
    # The driver's DRIVER_E_UNREAD: GitHub could not be read, nothing parked, the ticket is picked again.
    say "unread: run $rid left #${ticket:-?} as it was — GitHub could not be read; the next tick tries again"
  elif [ "$code" != 0 ] || printf '%s' "$last" | grep -qiE 'park|stood down|stand down|blocked|cannot continue'; then
    event "stood-down:$rid" stood-down true "$ticket" "" "run $rid ended exit $code: ${last:-no result line}"
  fi
done

# ---- 3. live and frozen runs -------------------------------------------------
# A run's last sign of progress: its log, and any progress_paths its record names
# (a directory counts by the newest file under it). A driver run prints only at
# step boundaries while its build step streams into its state dir, so the log
# alone would read a long build step as frozen.
progress_mtime() { # <record> <log>
  local best m p f
  best=$(coord_mtime "$2")
  while IFS= read -r p; do
    [ -n "$p" ] && [ -e "$p" ] || continue
    if [ -d "$p" ]; then
      while IFS= read -r f; do
        m=$(coord_mtime "$f"); [ "$m" -gt "$best" ] && best=$m
      done < <(find "$p" -type f 2>/dev/null)
    else
      m=$(coord_mtime "$p"); [ "$m" -gt "$best" ] && best=$m
    fi
  done < <(jq -r '.progress_paths[]? // empty' "$1" 2>/dev/null)
  printf '%s' "$best"
}
NOW=$(swarm_now)
LIVE=0; LIVE_TICKETS=""; LIVE_RECS=""
for rec in "$RUNS_DIR"/claim-*.json; do
  [ -f "$rec" ] || continue
  swarm_record_alive "$rec" || continue
  LIVE=$((LIVE+1)); LIVE_RECS="$LIVE_RECS$rec"$'\n'
  rid=$(basename "$rec" .json)
  ticket=$(jq -r '.ticket // empty' "$rec" 2>/dev/null)
  LIVE_TICKETS="$LIVE_TICKETS${ticket:-?} "
  log=$(jq -r '.log // empty' "$rec" 2>/dev/null)
  [ -f "$log" ] || continue
  seen_at=$(progress_mtime "$rec" "$log")
  quiet=$(( (NOW - seen_at) / 60 ))
  if [ "$quiet" -ge "$COORD_FROZEN_MIN" ]; then
    event "frozen:$rid:$seen_at" frozen true "$ticket" "" "run $rid: no log growth for ${quiet} min" || true
  fi
done
say "live: $LIVE run(s) ${LIVE_TICKETS:+[${LIVE_TICKETS% }]}"

# ---- 4. pull requests --------------------------------------------------------
# A red PR a session already holds through fix-lock.sh is being fixed: judging it
# would queue a second fixer onto the same branch. An expired lock fixes nothing.
FIXLOCK="${COORDINATOR_FIX_LOCK:-$SELF_DIR/fix-lock.sh}"
FIXING=$(FIX_LOCK_REPO="${FIX_LOCK_REPO:-${MAIN_REPO:-}}" bash "$FIXLOCK" list --json 2>/dev/null \
  | jq -r '.[]? | select(.expired | not) | "\(.pr)\t\(.window)"' 2>/dev/null)
# One read of the open PRs serves the whole tick and the queue refresh. A refused
# read (GitHub rate-limiting the token every builder shares) falls back to the
# last good one while it is fresh enough: the starts go on, and nothing judged or
# sent to the owner is decided on it.
# The read also refreshes the shared copy (gh_open_prs) the watcher, the status
# line, repair-watch and the live view take instead of asking GitHub themselves.
PRS_STALE=0
ALLOWANCE=$(gh_allowance_read) || ALLOWANCE=""
PRS=$(gh_open_prs 0)
if [ -n "$PRS" ] && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$PRS"; then
  coord_snap_save prs "$PRS"
elif PRS=$(coord_snap_load prs); then
  PRS_STALE=1
  say "open PRs: could not be read$(gh_backoff_active >/dev/null && echo ' (GitHub is rate-limiting this token)') — working from the snapshot taken $(coord_snap_age prs) min ago"
else PRS=""; fi
if [ -n "$PRS" ] && [ "$PRS_STALE" = 0 ]; then
  # THE SIGN-OFF HOLD'S OWN CHECK IS NOT A RED. It is red BY the hold and goes green
  # when the owner signs; a healing run can do nothing for it. #12827 shipped, was
  # respawned 15 minutes later on that check alone, and parked on it.
  HOLD_CHECK="${COORDINATOR_HOLD_CHECK:-$(swarm_opt coordinator.holdCheck approval)}"
  printf '%s' "$PRS" | jq -r --arg pre "$BRANCH_PREFIX" --arg hold "$HOLD_LABEL" --arg gate "$HOLD_CHECK" "$BRANCH_TICKET_JQ"'
    .[] | select(.isDraft | not) | select((.headRefName | branch_ticket($pre)) != "")
    | ((.statusCheckRollup // []) | map(select(((.name // .context // "") | ascii_downcase) | contains($gate | ascii_downcase) | not))) as $c
    # Settled = no CHECK RUN still running. A pending commit status is a wait on something
    # outside CI (such as a design-critic verdict), so it never holds a real red back.
    | ($c | map(select((.status // "COMPLETED") != "COMPLETED")) | length) as $pending
    | ($c | map(select((.conclusion // .state // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))) | length) as $failed
    | ([.labels[]?.name] | index($hold)) as $held
    | (.headRefName | branch_ticket($pre)) as $t
    | if .mergeStateStatus == "DIRTY" then [ "red", .number, .headRefOid, $t, "clashes with the integration branch" ]
      elif $pending == 0 and $failed > 0 then [ "red", .number, .headRefOid, $t, "checks settled red" ]
      else empty end
    | @tsv' 2>/dev/null \
  | while IFS=$'\t' read -r kind pr sha t why; do
      case "$kind" in
        red)
          fixer=$(awk -F'\t' -v p="$pr" '$1 == p { print $2; exit }' <<<"$FIXING")
          if [ -n "$fixer" ]; then say "PR #$pr: $why — being fixed by $fixer, not judged"
          elif swarm_heal_parked_out "$t" "$sha"; then say "PR #$pr: $why — #$t parked past its cap on this head, so it waits for a person (a new head heals it again)"
          else event "red-pr:$pr:$sha" red-pr true "$t" "$pr" "$why" || true; fi ;;
      esac
    done
  # Sign-offs reach the owner in batches, the moment a batch fills: one entry per
  # full set of green held PRs not already sent, keyed on that set.
  BATCHED="$COORD_DIR/signoff-batched.$(coord_mode)"
  printf '%s' "$PRS" | bash "$SIGNOFF" batches "$BATCHED" 2>/dev/null \
  | while IFS=$'\t' read -r key prs; do
      [ -n "${key:-}" ] || continue
      if event "$key" signoff false "" "${prs// /,}" "a batch of screens is green and waiting on sign-off"; then
        bash "$NOTIFY" --class owner "$key" "$(printf '%s' "$prs" | wc -w | tr -d ' ') screens are ready for your sign-off: PR #${prs// /, #}"
      fi
      printf '%s\n' "${key#signoff-batch:}" | tr ',' '\n' | awk -F@ '{print "pr:" $1 ":" $2}' >> "$BATCHED"
    done
fi

# ---- 4b. runs the wall cut off -------------------------------------------------
# Back to the front of the queue with their worktree named, or the restart begins from nothing.
has_open_pr() { # <ticket>
  printf '%s' "${PRS:-[]}" | jq -e --arg pre "$BRANCH_PREFIX" --arg t "$1" \
    "$BRANCH_TICKET_JQ"'any(.[]; .headRefName | branch_is_ticket($pre; $t))' >/dev/null 2>&1
}
requeue_cut() { # <ticket> <run-id> <log> <why> — 0 once settled, 1 to try again next tick
  local t="$1" rid="$2" log="$3" why="$4" st cls wt sid note old
  st=$(swarm_gh issue view "$t" --repo "$REPO_SLUG" --json state -q .state 2>/dev/null)
  [ -n "$st" ] || { say "cut: #$t could not be read — trying again next tick"; return 1; }
  [ "$st" = OPEN ] || { say "cut: #$t is $st — not re-queued"; return 0; }
  cls=$(coord_run_class "$RUNS_DIR/$rid.json"); [ -n "$cls" ] || cls=new
  [ "$cls" = new ] && [ -n "${PRS:-}" ] && has_open_pr "$t" && cls=repair
  wt=$(sed -n 1p "$RUNS_DIR/$rid.worktrees" 2>/dev/null)
  sid=$(grep -o '"session_id":"[^"]*"' "$log" 2>/dev/null | head -1 | cut -d'"' -f4)
  note="Resume: run $rid was cut off by $why before it handed off.${wt:+ Its worktree: $wt.} Carry on from its branch and commits; do not start over.${sid:+ Its session: $sid.}"
  old=$(jq -r --argjson n "$t" '.tickets[]? | select(.n == $n) | .note // empty' "$COORD_QUEUE" 2>/dev/null)
  case "$old" in Resume:*"Earlier note: "*) old="${old#*Earlier note: }" ;; Resume:*) old="" ;; esac
  [ -z "$old" ] || note="$note Earlier note: $old"
  coord_act_log requeue "$t" "$cls — cut off by $why"
  if coord_shadow; then say "would re-queue #$t ($cls) at the front of its priority — cut off by $why"; return 0; fi
  if bash "$QUEUE" add "$t" --class "$cls" --note "$note" --first >/dev/null 2>&1; then
    say "re-queued #$t ($cls) at the front of its priority — cut off by $why"; return 0
  fi
  say "cut: could not re-queue #$t — trying again next tick"; return 1
}
if [ -s "$CUT_PENDING" ]; then
  : > "$CUT_PENDING.next"
  while IFS=$'\t' read -r t rid log why; do
    [ -n "${t:-}" ] || continue
    requeue_cut "$t" "$rid" "$log" "$why" || printf '%s\t%s\t%s\t%s\n' "$t" "$rid" "$log" "$why" >> "$CUT_PENDING.next"
  done < "$CUT_PENDING"
  mv -f "$CUT_PENDING.next" "$CUT_PENDING"
fi

# The waits recorded this tick, snapshotted while the open PRs are fresh.
[ -n "${PRS:-}" ] && [ "$PRS_STALE" = 0 ] && coord_wait_snap_pending

# ---- 5. spawn ----------------------------------------------------------------
# Labels that keep a ticket from any agent: the swarm's own list, plus gated.
stop_labels() { { swarm_blocking_labels; printf '%s\n' "$LBL_GATED" "$LBL_EXTERNAL_BLOCKED"; } | awk 'NF && !seen[$0]++'; }
# Fails closed: a claim list nobody could read is not "nothing claimed".
# Rows: <ticket> \t <host> \t <step>. The claim refs live on origin, so every host
# reads every other host's claims: what one machine holds, every machine skips.
claims() {
  if [ -n "${COORDINATOR_CLAIMS_CMD:-}" ]; then $COORDINATOR_CLAIMS_CMD; return; fi
  local j; j=$(bash "$CL" list --json 2>/dev/null)
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$j" || return 1
  jq -r '.[] | "\(.issue)\t\(.host // "")\t\(.step // "")"' <<<"$j"
}
CLAIMS_OK=1; CLAIM_ROWS=$(claims 2>/dev/null) || CLAIMS_OK=0
CLAIMED=$(printf '%s\n' "$CLAIM_ROWS" | cut -f1 | grep -E '^[0-9]+$')

spawn_block() { # <ticket> <class> — echoes why not, returns 0 when blocked
  local t="$1" cls="$2" meta st lab l
  grep -qx "$t" <<<"$CLAIMED" && { echo "claimed"; return 0; }
  swarm_ticket_live "$t" && { echo "already running"; return 0; }
  meta=$(coord_issue_meta "$t")
  [ -n "$meta" ] || { echo "could not be read"; return 0; }
  st=${meta%% *}; lab=${meta#* }
  [ "$st" = "OPEN" ] || { echo "$st"; return 0; }
  if [ "$cls" = new ]; then
    printf '%s' "${PRS:-[]}" | jq -e --arg pre "$BRANCH_PREFIX" --arg t "$t" \
      "$BRANCH_TICKET_JQ"'any(.[]; .headRefName | branch_is_ticket($pre; $t))' >/dev/null 2>&1 \
      && { echo "has an open PR"; return 0; }
  fi
  while read -r l; do
    [ -n "$l" ] || continue
    # A repair or an approved merge is in review by definition; only fresh work waits on it.
    [ "$l" = "$LBL_IN_REVIEW" ] && [ "$cls" != new ] && continue
    case ",$lab," in *",$l,"*) echo "$l"; return 0 ;; esac
  done <<< "$(stop_labels)"
  # Respawned before the human moves, it ends on the same wait again.
  coord_wait_holds "$t" "$lab" && return 0
  return 1
}

# Answers given anywhere free their tickets before anything is picked.
OWNERQ="$SELF_DIR/owner-question.sh"
if ! coord_shadow; then bash "$OWNERQ" sync 2>&1 | while IFS= read -r l; do say "owner: $l"; done; fi

# The re-seed reads every scope's members and the claimable list, so it runs every
# coordinator.refreshEveryMin, not every tick, and reads the open PRs from this
# tick's copy rather than asking again.
REFRESH_STAMP="$COORD_DIR/refresh.stamp"
COORD_REFRESH_EVERY_MIN="${COORDINATOR_REFRESH_EVERY_MIN:-$(swarm_opt coordinator.refreshEveryMin 5)}"
case "$COORD_REFRESH_EVERY_MIN" in ""|*[!0-9]*) COORD_REFRESH_EVERY_MIN=5 ;; esac
# With a sheet owner set, every machine but the owner works the owner's order
# (coordinator-sheet.sh) and never seeds its own: two orders pick against each other.
SHEET_ROLE=$(coord_sheet_role); SHEET_HOLD=""
if [ "$SHEET_ROLE" = reader ]; then
  if coord_sheet_read; then
    coord_sheet_seed_queue "$SHEET_ORDER"
    say "sheet: working $COORD_SHEET_OWNER's order, $SHEET_AGE_MIN min old$([ "$SHEET_FROM" = copy ] && echo ' (the last copy read: GitHub could not be asked)') — $(jq 'length' <<<"$SHEET_ORDER") on it"
  else
    SHEET_HOLD="$SHEET_WHY"
    say "sheet: $SHEET_WHY"
  fi
elif [ -s "$COORD_QUEUE" ] && [ "${COORDINATOR_REFRESH:-1}" = 1 ]; then
  if until=$(gh_backoff_active); then
    say "queue: GitHub is rate-limiting this token until $(swarm_iso "$until") — working the queue as it stands"
  elif [ $(( $(swarm_now) - $(coord_mtime "$REFRESH_STAMP") )) -ge $(( COORD_REFRESH_EVERY_MIN * 60 )) ]; then
    pf=""; if [ "$PRS_STALE" = 0 ] && [ -s "$(coord_snap_file prs)" ]; then pf=$(coord_snap_file prs); fi
    if CLAIMABLE_PRS_FILE="$pf" bash "$QUEUE" refresh >/dev/null 2>&1; then touch "$REFRESH_STAMP"
    else say "queue: refresh failed — working the queue as it stands"; fi
  fi
fi

# Every queued ticket's state and labels in one batched read (50 to a request),
# in place of one `gh issue view` per ticket: 59 of a tick's 101 calls were those.
# What a refused read misses comes from the last good snapshot while it is fresh.
ISSUES=""; ISSUES_OK=1
# The live runs' tickets too: a polish red being healed never counts toward heal-all.
# And the runs that ended inside the live view's window: its finished list says
# where each of those tickets stands now from this read, not from a call per row.
ENDED_TICKETS=$(find "$RUNS_DIR" -maxdepth 1 -name 'claim-*.ended' -mmin -"$(( ${SWARM_DONE_HOURS:-6} * 60 ))" 2>/dev/null \
  | while IFS= read -r e; do jq -r '.ticket // empty' "${e%.ended}.json" 2>/dev/null; done)
# The sheet's owner names every host's builds, so it reads their titles in the same request.
ISSUE_NUMS=$( { coord_queue_ordered | cut -f1; cut -f1 "$COORD_WAITS" 2>/dev/null; printf '%s\n' $LIVE_TICKETS $ENDED_TICKETS
                [ "$SHEET_ROLE" != owner ] || printf '%s\n' "$CLAIMED"; } | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ')
if [ -n "${ISSUE_NUMS// /}" ]; then
  # shellcheck disable=SC2086  # a list of numbers, split on purpose
  if ISSUES=$(gh_issues_batch $ISSUE_NUMS); then coord_snap_save issues "$ISSUES"
  else
    snap=$(coord_snap_load issues) || snap="{}"
    [ "$snap" != "{}" ] || ISSUES_OK=0
    [ -n "$ISSUES" ] || ISSUES="{}"
    ISSUES=$(jq -cn --argjson old "$snap" --argjson new "$ISSUES" '$old + $new' 2>/dev/null) || ISSUES=""
    say "tickets: the batched read was refused$(gh_backoff_active >/dev/null && echo ' (GitHub is rate-limiting this token)') — $( [ "$snap" = "{}" ] && echo 'no fresh snapshot to fall back on' || echo "the rest from the snapshot taken $(coord_snap_age issues) min ago")"
  fi
fi

# The order the owner publishes: taken before the starts take their tickets off the queue.
SHEET_WIDE=""; [ "$SHEET_ROLE" != owner ] || SHEET_WIDE=$(coord_queue_ordered --wide)

# Each live run's class, as the coordinator recorded it at spawn. A run with none
# on record (started outside the coordinator) heals when its ticket has an open PR.
live_class() { # <record>
  local c t
  c=$(coord_run_class "$1")
  if [ -z "$c" ]; then
    t=$(jq -r '.ticket // empty' "$1" 2>/dev/null)
    printf '%s' "${PRS:-[]}" | jq -e --arg pre "$BRANCH_PREFIX" --arg t "$t" \
      "$BRANCH_TICKET_JQ"'any(.[]; .headRefName | branch_is_ticket($pre; $t))' >/dev/null 2>&1 && c=repair
  fi
  coord_healing_class "${c:-new}" && echo healing || echo new
}
# polish: P3, a polish kind or a polish list, read off the batched labels (coord_polish).
ticket_polish() { # <ticket> — 0 when the tick's read holds it as polish
  [ -n "${ISSUES:-}" ] && coord_jq -e --arg n "$1" "$COORD_TICKET_JQ"'
    .[$n] // null | if . == null then false else coord_polish(.labels // []; null; .title) end' >/dev/null 2>&1 <<<"$ISSUES"
}
LIVE_HEAL=0; LIVE_NEW=0; LIVE_HEAL_POLISH=0
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  if [ "$(live_class "$rec")" = healing ]; then
    LIVE_HEAL=$((LIVE_HEAL+1))
    ticket_polish "$(jq -r '.ticket // empty' "$rec" 2>/dev/null)" && LIVE_HEAL_POLISH=$((LIVE_HEAL_POLISH+1))
  else LIVE_NEW=$((LIVE_NEW+1)); fi
done <<< "$LIVE_RECS"

# The ceiling is what is running plus as many as the spare CPU fits (coord_room),
# so an idle machine fills in one tick rather than one agent per tick.
CEILING=$LIVE; ROOM=""; READING=""; STARTS=0
# Live builders started inside the ramp window: the idle reading has not seen them.
RAMPING=0
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  at=$(jq -r '.started_at // empty' "$rec" 2>/dev/null); [ -n "$at" ] || continue
  [ $(( NOW - $(swarm_epoch "$at") )) -lt $(( COORD_RAMP_MIN * 60 )) ] && RAMPING=$((RAMPING+1))
done <<< "$LIVE_RECS"
if READING=$(coord_room); then
  ROOM=1; STARTS=${READING%%$'\t'*}; READING=${READING#*$'\t'}
  STARTS=$(( STARTS - RAMPING )); [ "$STARTS" -ge 0 ] || STARTS=0
  [ "$RAMPING" -eq 0 ] || READING="$READING, $RAMPING started in the last ${COORD_RAMP_MIN} min"
  CEILING=$((LIVE+STARTS))
fi
[ -n "$COORD_CAP" ] && [ "$CEILING" -gt "$COORD_CAP" ] && CEILING=$COORD_CAP
# The five-hour window is the account's, shared with every host: no more than its share here.
if PACE=$(coord_pace "$LIVE" "$CLAIM_ROWS" "$COORD_HOST"); then
  [ "$CEILING" -gt "${PACE%%$'\t'*}" ] && CEILING=${PACE%%$'\t'*}
  PACE=${PACE#*$'\t'}
fi
say "$PACE"
[ "$CEILING" -ge "$LIVE" ] || CEILING=$LIVE
SLOTS=$(( CEILING - LIVE )); [ "$SLOTS" -ge 0 ] || SLOTS=0
# The split needs the reds left — waiting plus being healed — so candidates()
# redoes it once the waiting ones are counted. Polish reds are healed in their
# turn but never count toward heal-all: on 2026-10-19 34 of 79 open changes were
# polish, and counting them let a backlog of spacing fixes stop all new building.
split_places() {
  REDS_LEFT=$(( REDS_WAITING - REDS_WAITING_POLISH + LIVE_HEAL - LIVE_HEAL_POLISH ))
  HEAL_ALL=""; coord_heal_all "$REDS_LEFT" && HEAL_ALL=1
  HEAL_SLOTS=$(coord_healing_slots "$CEILING" "$REDS_LEFT"); NEW_SLOTS=$(( CEILING - HEAL_SLOTS ))
  HEAL_FREE=$(( HEAL_SLOTS - LIVE_HEAL )); [ "$HEAL_FREE" -ge 0 ] || HEAL_FREE=0
  NEW_FREE=$(( NEW_SLOTS - LIVE_NEW ));   [ "$NEW_FREE" -ge 0 ] || NEW_FREE=0
}
REDS_WAITING=0; REDS_WAITING_POLISH=0; split_places
say "ceiling: $LIVE running · $([ "$SLOTS" -gt 0 ] && echo "room for $SLOTS more" || echo "no room for more"): ${READING:-?}${COORD_CAP:+ · cap $COORD_CAP}"

PLAN=""; NEXT=""; TOOK=""; SHEET_STARTED=""
# A hold for process fixes holds everything else: only those are candidates.
PROCESS_ONLY=""
if held=$(swarm_held) && swarm_hold_lets_process; then
  PROCESS_ONLY=1; say "spawn: held for everything but process fixes ($SWARM_PROCESS_LABEL) — $held"
fi
# The spawnable entries, in queue order: every healing one (so the reds waiting
# are counted), and new work up to one past the free places (the next pick).
# CANDS rows: <ticket> \t <class> \t <polish 0|1> \t <process 0|1> \t <note>.
# A process fix is never held as polish, never capped at one past the free places,
# and under a hold that lets process fixes through it is the only kind listed.
# Polish new work starts only when nothing else can, or when it is a polish list
# holding coordinator.polishListFull free items (owner call 2026-10-19): 20 of
# the 35 PRs waiting on the owner's sign-off were polish, one picture each. The
# hold never parks an entry put at the front (a resume, an owner's answer) or
# half-built work: those are paid for already.
CANDS=""
candidates() {
  local t cls pri pol pl ex proc note why nn=0 i=0 held="" rows="" other=0 lists bodies="{}" cnt waits=0 wide
  CANDS=""
  wide=$(coord_queue_ordered --wide)
  # A full list goes in its place in the order, ahead of lower-priority work, so the
  # lists' bodies are read first: one batched request, only when a list is queued.
  lists=$(printf '%s\n' "$wide" | awk -F'\t' '$2 == "new" && $5 == 1 { print $1 }' | tr '\n' ' ')
  # shellcheck disable=SC2086  # a list of numbers, split on purpose
  [ -z "${lists// /}" ] || bodies=$(GH_BATCH_BODY=1 gh_issues_batch $lists 2>/dev/null) || bodies="{}"
  while IFS=$'\t' read -r t cls pri pol pl ex proc note; do
    [ -n "${t:-}" ] || continue
    i=$((i+1))
    if [ -n "$PROCESS_ONLY" ] && [ "$proc" != 1 ]; then continue; fi
    # A list with nothing free on it is never work, however idle the factory: every
    # item is ticked, reserved by a PR, or taken by another run. Its own takes count.
    if [ "$cls" = new ] && [ "$pl" = 1 ]; then
      cnt=$(jq -r --arg n "$t" '.[$n].body // ""' <<<"$bodies" 2>/dev/null | bash "$POLISH" count - "$t" 2>/dev/null)
      case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
      [ "$cnt" -gt 0 ] || { say "skip #$t (polish list): nothing free on it — every item is ticked, reserved or taken"; continue; }
    fi
    # Held: new polish work that is neither put at the front nor half-built, unless
    # it is a full list.
    if ! coord_healing_class "$cls" && [ "$pol" = 1 ] && [ "$ex" != 1 ]; then
      [ "$pl" = 1 ] || cnt=0
      if [ "$pl" != 1 ] || [ "$cnt" -lt "$COORD_POLISH_LIST_FULL" ]; then
        held="$held$i"$'\t'"$t"$'\t'"$cls"$'\t'"$pl"$'\t'"$cnt"$'\t'"$note"$'\n'; continue
      fi
    fi
    [ "$proc" = 1 ] || coord_healing_class "$cls" || { [ "$nn" -le "$SLOTS" ] || [ "$nn" -lt 2 ] || continue; }
    if why=$(spawn_block "$t" "$cls"); then say "skip #$t ($cls): $why"; continue; fi
    [ "$proc" = 1 ] || coord_healing_class "$cls" || nn=$((nn+1))
    [ "$pol" = 1 ] || other=1
    rows="$rows$i"$'\t'"$t"$'\t'"$cls"$'\t'"$pol"$'\t'"${proc:-0}"$'\t'"$note"$'\n'
  done <<< "$wide"
  if [ -n "$held" ]; then
    while IFS=$'\t' read -r i t cls pl cnt note; do
      [ -n "${t:-}" ] || continue
      if [ "$other" = 1 ]; then
        if [ "$pl" = 1 ]; then say "skip #$t (polish list): $cnt of $COORD_POLISH_LIST_FULL items — rides along with its screen's next ticket"
        else waits=$((waits+1)); fi
        continue
      fi
      [ "$nn" -le "$SLOTS" ] || [ "$nn" -lt 2 ] || continue
      if why=$(spawn_block "$t" "$cls"); then say "skip #$t ($cls): $why"; continue; fi
      nn=$((nn+1))
      rows="$rows$i"$'\t'"$t"$'\t'"$cls"$'\t'1$'\t'0$'\t'"$note"$'\n'
    done <<< "$held"
    [ "$waits" -eq 0 ] || say "polish: $waits polish ticket(s) wait while other work can start"
  fi
  CANDS=$(printf '%s' "$rows" | sort -t$'\t' -k1,1n | cut -f2-); [ -z "$CANDS" ] || CANDS="$CANDS"$'\n'
  reds_waiting; split_places
}
reds_waiting() {
  REDS_WAITING=$(printf '%s' "$CANDS" | awk -F'\t' '$2 == "repair" || $2 == "approved-merge"' | grep -c .)
  REDS_WAITING_POLISH=$(printf '%s' "$CANDS" | awk -F'\t' '($2 == "repair" || $2 == "approved-merge") && $3 == 1' | grep -c .)
}
first_of() { # <healing|new|process> — the first candidate of that kind: <ticket> \t <class> \t <note>
  local t cls pol proc note
  while IFS=$'\t' read -r t cls pol proc note; do
    [ -n "${t:-}" ] || continue
    if [ "$1" = process ]; then [ "$proc" = 1 ] || continue
    elif coord_healing_class "$cls"; then [ "$1" = healing ] || continue; else [ "$1" = new ] || continue; fi
    printf '%s\t%s\t%s' "$t" "$cls" "$note"; return 0
  done <<< "$CANDS"
  return 1
}
# Held with work queued: what it would take next, and the reds that could start.
held_view() {
  candidates
  NEXT=$(printf '%s' "$CANDS" | awk -F'\t' 'NF { print $1; exit }')
}
# ---- 5a. disk ---------------------------------------------------------------------
# Owner call 2026-10-20: "Auto-clean and stop below 30 GB". Held from under stopBelowGb until
# resumeAtGb is free, so one freed GB does not start a build that fills the disk again.
DISK_GUARD="${COORDINATOR_DISK_GUARD:-$SELF_DIR/disk-guard.sh}"
DISK_HOLD=""; DISK_FREE=""
DISK_SAID=$(DISK_GUARD_HOLD_FILE="${DISK_GUARD_HOLD_FILE:-$COORD_DIR/disk-hold}" bash "$DISK_GUARD" tick 2>/dev/null) || DISK_HOLD=1
DISK_FREE=${DISK_SAID%%$'\t'*}; DISK_SAID=${DISK_SAID#*$'\t'}
case "$DISK_FREE" in ''|*[!0-9]*) DISK_FREE="" ;; esac
[ -z "$DISK_HOLD" ] || DISK_HOLD="${DISK_SAID:-disk low}"
say "${DISK_SAID:-disk: the guard said nothing}"
read -r DISK_STOP_GB DISK_RESUME_GB <<<"$(bash "$DISK_GUARD" limits 2>/dev/null)"
if [ -n "$DISK_HOLD" ]; then
  event "disk-hold:$(swarm_day)" disk-low false "" "" "$DISK_HOLD" || true
  DISK_CLEAN_LOG="$COORD_DIR/disk-clean.log"
  clean_args=""; coord_shadow || clean_args="--apply"
  if [ "${COORDINATOR_DISK_CLEAN:-background}" = inline ]; then
    DISK_GUARD_HOLD_FILE="${DISK_GUARD_HOLD_FILE:-$COORD_DIR/disk-hold}" bash "$DISK_GUARD" clean $clean_args >> "$DISK_CLEAN_LOG" 2>&1
    DISK_FREE=$(bash "$DISK_GUARD" free 2>/dev/null) || DISK_FREE=""
    say "disk: the auto-clean ran$([ -n "$clean_args" ] || echo ' dry') — ${DISK_FREE:-?} GB free after it ($DISK_CLEAN_LOG)"
  else
    DISK_GUARD_HOLD_FILE="${DISK_GUARD_HOLD_FILE:-$COORD_DIR/disk-hold}" \
      bash "$SELF_DIR/../swarm/detach.sh" bash "$DISK_GUARD" clean $clean_args >> "$DISK_CLEAN_LOG" 2>&1 < /dev/null &
    say "disk: the auto-clean started$([ -n "$clean_args" ] || echo ' dry') in the background (pid $!, $DISK_CLEAN_LOG)"
  fi
fi

if [ -n "$COORD_CAP_BAD" ]; then
  say "spawn: coordinator.cap is '$COORD_CAP_BAD', not a whole number — holding"
  event "cap-bad:$COORD_CAP_BAD" cap-bad false "" "" "coordinator.cap is '$COORD_CAP_BAD', so nothing is spawning" || true
elif [ -n "$DISK_HOLD" ]; then
  say "spawn: starting nothing new — $DISK_HOLD"
  coord_act_log disk-hold - "$DISK_HOLD"
  held_view
elif [ -z "$PROCESS_ONLY" ] && held=$(swarm_held); then
  say "spawn: held — $held"
elif [ -n "$SHEET_HOLD" ]; then
  say "spawn: starting nothing new — $SHEET_HOLD. This machine never falls back to its own order"
  coord_act_log sheet-hold - "$SHEET_HOLD"
elif [ "$CLAIMS_OK" = 0 ] || [ -z "$PRS" ]; then
  blind=$([ "$CLAIMS_OK" = 0 ] && echo "the claim list" || echo "the open pull requests")
  limit=""; [ "$CLAIMS_OK" = 0 ] || limit=$(gh_limit_why) || limit=""
  say "spawn: $blind could not be read${limit:+ — $limit} — spawning nothing"
  if event "blind:$(swarm_day)" blind false "" "" "$blind could not be read${limit:+ ($limit)}, so nothing is spawning"; then
    bash "$NOTIFY" --class owner "blind:$(swarm_day)" "The coordinator cannot read $blind (${limit:-gh auth or network?}) — nothing is spawning"
  fi
elif until=$(swarm_usage_hold); then
  say "spawn: usage limit — holding until $until — from $(swarm_usage_hold_source)"
  event "usage-hold:$until" usage-limit false "" "" "the plan's usage limit holds until $until" || true
elif busy=$(swarm_machine_busy); then
  say "spawn: machine busy ($busy) — holding"
  held_view
elif [ -n "$COORD_CAP" ] && [ "$LIVE" -ge "$COORD_CAP" ]; then
  say "spawn: $LIVE live, cap $COORD_CAP — no slot"
  held_view
elif [ -z "$ROOM" ]; then
  say "spawn: $LIVE live, no room for more ($READING) — holding"
  held_view
elif [ "$SLOTS" -le 0 ]; then
  say "spawn: $LIVE live, ceiling $CEILING — no slot"
  held_view
else
  candidates
  started=0
  # The room is re-read before each start after the first; near the floor that stops at one.
  RAMP=$SLOTS; RAMP_WHY=""
  if [ -n "$COORD_RAMP_MAX" ] && [ "$RAMP" -gt "$COORD_RAMP_MAX" ]; then RAMP=$COORD_RAMP_MAX; RAMP_WHY="coordinator.rampMax is $COORD_RAMP_MAX"; fi
  while [ "$started" -lt "$RAMP" ]; do
    heal=$(first_of healing); new=$(first_of new); proc=$(first_of process)
    # A process fix takes any free place first, whatever the split. Then each class
    # fills its own share; a class with nothing spawnable lends its places to the other.
    pick=""; lent=""
    if   [ -n "$proc" ]; then pick="$proc"; lent="any free place, a process fix first"
    elif [ "$HEAL_FREE" -gt 0 ] && [ -n "$heal" ]; then pick="$heal"
    elif [ "$NEW_FREE" -gt 0 ]  && [ -n "$new" ];  then pick="$new"
    elif [ "$HEAL_FREE" -gt 0 ] && [ -n "$new" ];  then pick="$new"; lent="a healing place"
    elif [ "$NEW_FREE" -gt 0 ]  && [ -n "$heal" ]; then pick="$heal"; lent="a new place"
    fi
    [ -n "$pick" ] || break
    if [ "$started" -gt 0 ]; then
      if ! again=$(coord_room fresh); then say "spawn: $started started, then no room: $again"; RAMP_WHY=""; break; fi
      fit=$(( ${again%%$'\t'*} - RAMPING - started ))
      if [ "$fit" -lt 1 ]; then say "spawn: $started started, and the re-read fits no more: ${again#*$'\t'}"; RAMP_WHY=""; break; fi
      # A builder started seconds ago has used none of its memory yet: charge it.
      MEM_LEFT=$(awk -v m="$(swarm_free_mem_gb)" -v n="$started" -v a="$COORD_AGENT_MEM_GB" 'BEGIN{ if (m !~ /^[0-9]+$/) exit 1; printf "%.1f", m - n * a }') || MEM_LEFT=""
      if [ -z "$MEM_LEFT" ] || awk -v l="$MEM_LEFT" -v f="$COORD_RAMP_FREE_MEM_GB" 'BEGIN{exit !(l < f)}'; then
        say "spawn: $started started, then ${MEM_LEFT:-unread} GB free after ${COORD_AGENT_MEM_GB} GB a start, under the ${COORD_RAMP_FREE_MEM_GB} GB a second start in one tick needs"; RAMP_WHY=""; break
      fi
    fi
    IFS=$'\t' read -r t cls note <<< "$pick"
    started=$((started+1))
    # Taken out of the candidates so the next pass picks the next one.
    CANDS=$(printf '%s' "$CANDS" | awk -F'\t' -v p="$t" 'NF && $1 != p'); [ -z "$CANDS" ] || CANDS="$CANDS"$'\n'
    PLAN="${PLAN:+$PLAN,}$t"; TOOK="$cls"
    heal_free_was=$HEAL_FREE; new_free_was=$NEW_FREE
    if coord_healing_class "$cls"; then
      if [ "$HEAL_FREE" -gt 0 ]; then HEAL_FREE=$((HEAL_FREE-1)); elif [ "$NEW_FREE" -gt 0 ]; then NEW_FREE=$((NEW_FREE-1)); fi
    else
      if [ "$NEW_FREE" -gt 0 ]; then NEW_FREE=$((NEW_FREE-1)); elif [ "$HEAL_FREE" -gt 0 ]; then HEAL_FREE=$((HEAL_FREE-1)); fi
    fi
    # Counted live only once it is (or, in shadow, would be) running.
    count_live() {
      if coord_healing_class "$cls"; then
        LIVE_HEAL=$((LIVE_HEAL+1)); ticket_polish "$t" && LIVE_HEAL_POLISH=$((LIVE_HEAL_POLISH+1))
      else LIVE_NEW=$((LIVE_NEW+1)); fi
    }
    coord_act_log spawn "$t" "$cls${note:+ — $note}"
    if coord_shadow; then
      say "would spawn #$t ($cls)${lent:+ in $lent$([ -n "$proc" ] && [ "$pick" = "$proc" ] || echo ', nothing else spawnable')}"; count_live
    else
      brief=""
      if [ -n "$note" ]; then brief=$(mktemp); printf 'Coordinator note (%s): %s\n' "$cls" "$note" > "$brief"; fi
      spawn_out=$(CLAIM_CLASS="$cls" swarm_spawn "$t" "$brief" 2>&1); spawn_rc=$?
      printf '%s\n' "$spawn_out" >> "$COORD_LOG"
      if [ "$spawn_rc" -eq 0 ]; then
        coord_record_class "$t" "$cls"; count_live
        say "spawned #$t ($cls)${lent:+ in $lent$([ -n "$proc" ] && [ "$pick" = "$proc" ] || echo ', nothing else spawnable')}"; bash "$QUEUE" remove "$t" >/dev/null 2>&1
        SHEET_STARTED="${SHEET_STARTED:+$SHEET_STARTED,}$t"
      else
        say "spawn of #$t failed"
        # Its place goes to the next entry this tick. Counted as taken, one refused
        # entry at the head of the queue would hold its class shut on every tick.
        started=$((started-1)); HEAL_FREE=$heal_free_was; NEW_FREE=$new_free_was
        # A refusal names its reason (driver mode cannot carry a brief, say);
        # raised so it is seen, not only buried in the coordinator's log.
        why=$(printf '%s\n' "$spawn_out" | sed '/^[[:space:]]*$/d' | tail -1 | cut -c1-240)
        event "spawn-failed:$t:$(swarm_day)" spawn-failed false "$t" "" "spawn of #$t ($cls) failed: ${why:-the spawner exited $spawn_rc}" || true
      fi
      [ -z "$brief" ] || rm -f "$brief"
    fi
  done
  if [ -n "$RAMP_WHY" ] && [ "$started" -eq "$RAMP" ] && [ "$RAMP" -lt "$SLOTS" ] && [ -n "$CANDS" ]; then
    say "spawn: $started this tick of $SLOTS place(s) — $RAMP_WHY"
  fi
  if [ "$started" -eq 0 ] && [ -z "$CANDS" ]; then
    say "spawn: $SLOTS slot(s), nothing spawnable in the queue"
  fi
  # The next pick is the first spawnable entry left, whatever its class.
  NEXT=$(printf '%s' "$CANDS" | awk -F'\t' 'NF { print $1; exit }')
  reds_waiting
  if [ "$REDS_WAITING" -gt 0 ] && ! coord_healing_class "${TOOK:-new}"; then
    say "spawn: healing has its $HEAL_SLOTS place(s) — $REDS_WAITING red(s) wait their turn"
  fi
fi
# ---- 5c. the shared sheet --------------------------------------------------------
# The owner writes what is startable, in run order, and who is building what, once
# the starts are made: its own starts show as building here before their claims land.
if [ "$SHEET_ROLE" = owner ]; then
  if [ "$ISSUES_OK" = 0 ]; then
    say "sheet: the queue's tickets could not be read — not written; readers start nothing once it is ${COORD_SHEET_STALE_MIN} min old"
  elif [ "$CLAIMS_OK" = 0 ]; then
    say "sheet: the claim list could not be read — not written"
  else
    if entries=$(coord_sheet_entries "$SHEET_WIDE" "$ISSUES" "$CLAIM_ROWS" "$SHEET_STARTED") && [ -n "$entries" ]; then
      said=$(coord_sheet_publish "$entries")
      say "sheet: $said · $(jq '.order | length' <<<"$entries") in the order, $(jq '.building | length' <<<"$entries") building"
    else
      say "sheet: its content could not be built — not written"
    fi
  fi
fi

say "split: $LIVE_NEW new · $LIVE_HEAL healing · $REDS_WAITING reds waiting (of $CEILING: $NEW_SLOTS new, $HEAL_SLOTS healing)${HEAL_ALL:+ · heal-all: $REDS_LEFT reds left (waiting + healing), at least $COORD_HEAL_ALL_AT, so every place heals}$( [ $(( REDS_WAITING_POLISH + LIVE_HEAL_POLISH )) -eq 0 ] || echo " · $(( REDS_WAITING_POLISH + LIVE_HEAL_POLISH )) polish red(s) not counted toward heal-all")"
# What the live view and the merge lane read: the ceiling, its reading, the split, the mode.
jq -cn --arg at "$(swarm_stamp)" --argjson epoch "$(date +%s)" --arg mode "$(coord_mode)" \
   --argjson live "$LIVE" --argjson ceiling "$CEILING" \
   --argjson room "$([ -n "$ROOM" ] && echo true || echo false)" --arg reading "$READING" --arg cap "$COORD_CAP" \
   --argjson hs "$HEAL_SLOTS" --argjson hl "$LIVE_HEAL" --argjson ns "$NEW_SLOTS" --argjson nl "$LIVE_NEW" \
   --argjson waiting "$REDS_WAITING" --arg took "$TOOK" \
   --arg healAllAt "$COORD_HEAL_ALL_AT" --argjson healAll "$([ -n "$HEAL_ALL" ] && echo true || echo false)" \
   --arg diskFree "$DISK_FREE" --arg diskStop "${DISK_STOP_GB:-}" --arg diskResume "${DISK_RESUME_GB:-}" \
   --argjson diskHeld "$([ -n "$DISK_HOLD" ] && echo true || echo false)" \
   '{at:$at, epoch:$epoch, mode:$mode, live:$live, ceiling:$ceiling, room:$room, reading:$reading,
     cap:(if $cap == "" then null else ($cap|tonumber) end),
     healing:{slots:$hs, live:$hl}, new:{slots:$ns, live:$nl}, redsWaiting:$waiting,
     healAll:{at:(if $healAllAt == "" then null else ($healAllAt|tonumber) end), inForce:$healAll}, started:(if $took == "" then null else $took end),
     disk:{freeGb:(if $diskFree == "" then null else ($diskFree|tonumber) end),
           stopBelowGb:(if $diskStop == "" then null else ($diskStop|tonumber) end),
           resumeAtGb:(if $diskResume == "" then null else ($diskResume|tonumber) end), held:$diskHeld}}' \
   > "$COORD_DIR/capacity.json.$$" 2>/dev/null && mv -f "$COORD_DIR/capacity.json.$$" "$COORD_DIR/capacity.json"
# The compare report reads what this tick saw and chose; next= stays last.
printf '%s\tplan\t-\t%s\tlive=%s slots=%s ceiling=%s healing=%s/%s new=%s/%s next=%s\n' "$(swarm_stamp)" "$PLAN" "${LIVE_TICKETS% }" "$SLOTS" \
  "$CEILING" "$LIVE_HEAL" "$HEAL_SLOTS" "$LIVE_NEW" "$NEW_SLOTS" "$NEXT" >> "$COORD_ACTIONS"

# Who spent the allowance: this tick, the last hour by caller, and what is left.
gh_calls_trim
say "gh: $(gh_calls_tally "$TICK_T0" coordinator-tick) call(s) this tick · last hour: $(gh_calls_tally $(( $(swarm_now) - 3600 )) | sed 's/^$/none counted/') · left: $(printf '%s' "$ALLOWANCE" | awk -F'\t' 'NF == 4 { printf "%s%s %s/%s", (n++ ? ", " : ""), ($1 == "graphql" ? "GraphQL" : "REST"), $2, $3 } END { if (!n) printf "unread" }')"

# ---- 5b-8. housekeeping, off the start path ------------------------------------
# The merge lane, reconcile, the sweeps, the disk pass and the judge took 2.9 of a
# 4.4-minute median tick, and launchd starts no tick while one runs: starts waited
# on them. They run in coordinator-housekeeping.sh under a lock of their own, at most
# every coordinator.housekeepingEveryMin, in the background once the starts are made.
HOUSE="${COORDINATOR_HOUSEKEEPING_CMD:-$SELF_DIR/coordinator-housekeeping.sh}"
HOUSE_STAMP="$COORD_DIR/housekeeping.stamp"
COORD_HOUSE_EVERY_MIN="${COORDINATOR_HOUSEKEEPING_EVERY_MIN:-$(swarm_opt coordinator.housekeepingEveryMin 5)}"
case "$COORD_HOUSE_EVERY_MIN" in ""|*[!0-9]*) COORD_HOUSE_EVERY_MIN=5 ;; esac
if [ $(( $(date +%s) - $(coord_mtime "$HOUSE_STAMP") )) -lt $(( COORD_HOUSE_EVERY_MIN * 60 )) ]; then
  say "housekeeping: ran under ${COORD_HOUSE_EVERY_MIN} min ago — not this tick"
elif [ "${COORDINATOR_HOUSEKEEPING:-background}" = inline ]; then
  touch "$HOUSE_STAMP"; bash "$HOUSE"
else
  touch "$HOUSE_STAMP"
  bash "$SELF_DIR/../swarm/detach.sh" bash "$HOUSE" > "$COORD_DIR/housekeeping.out" 2>&1 < /dev/null &
  say "housekeeping: started in the background (pid $!)"
fi
say "tick: done"
