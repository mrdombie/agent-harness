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
#   4. pull requests red (unless fix-lock.sh says a session is on it), and the
#                    held pixel PRs gone green, sent to the owner a full batch at a time
#   5. spawn         as many starts as the spare CPU fits, while the machine has room
#                    (coord_room) and under coordinator.cap when one is set;
#                    healing (repair, approved-merge) fills ceil(ceiling x
#                    healingShare) of the places and new work the rest; a class
#                    with nothing spawnable lends its places to the other. Never
#                    a ticket that is claimed, gated or on hold, and nothing
#                    while the machine is busy (swarm_machine_busy)
#   5b. merge lane   merge-lane.sh, when harness.json names merge.method
#   6. housekeeping  reconcile-claims.sh, stop-dev-servers.sh --sweep, then every
#                    coordinator.sweepEveryMin the worktree sweep (merged and closed work goes)
#   7. disk          below coordinator.minFreeGb: the worktree cache pass, then an alarm if still below
#   8. judgement     one fresh `claude -p` per judgement event (coordinator-judge.sh)
#
# Shadow (the default): every act is written to actions.log as "would …";
# nothing is spawned, killed, posted or notified, and housekeeping runs dry.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/coordinator-env.sh" || exit 1

RECONCILE="${COORDINATOR_RECONCILE:-$SELF_DIR/reconcile-claims.sh}"
SWEEP="${COORDINATOR_SWEEP:-$SELF_DIR/stop-dev-servers.sh}"
JUDGE="${COORDINATOR_JUDGE:-$SELF_DIR/coordinator-judge.sh}"
NOTIFY="$SELF_DIR/coordinator-notify.sh"
QUEUE="$SELF_DIR/coordinator-queue.sh"
SIGNOFF="$SELF_DIR/signoff-batch.sh"
SEEN_ENDED="$COORD_DIR/ended.seen"
touch "$SEEN_ENDED" "$COORD_EVENTS" "$COORD_ACTIONS"

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; swarm_log "$COORD_LOG" "$*"; }

# ---- 1. lock ----------------------------------------------------------------
LOCK="$COORD_DIR/tick.lock"
coord_lock "$LOCK" tick || { say "tick: $COORD_LOCK_WHY — exiting"; exit 0; }
trap 'rm -rf "$LOCK"' EXIT

say "tick: $(coord_mode) mode, cap ${COORD_CAP:-none}, config from ${HARNESS_CFG_FROM:-?}"

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
  if limit_hit "$log"; then
    event "usage-limit:$rid" usage-limit false "$ticket" "" "run $rid stopped on the plan's usage limit"
    cut_off "$ticket" "$rid" "$log" "the plan's usage limit"
  elif swarm_login_log_lost "$log"; then
    event "login-lost:$rid" login-lost false "$ticket" "" "run $rid stopped: the CLI is not logged in"
    cut_off "$ticket" "$rid" "$log" "a lost login"
    if event "login-lost:$(swarm_day)" login-lost false "" "" "the agents' CLI is not logged in"; then
      bash "$NOTIFY" --class owner "login-lost:$(swarm_day)" "The agents' Claude login has gone: every run stops at once until someone runs /login on this machine"
    fi
  elif [ "$code" != 0 ] || printf '%s' "$last" | grep -qiE 'park|stood down|stand down|blocked|cannot continue'; then
    event "stood-down:$rid" stood-down true "$ticket" "" "run $rid ended exit $code: ${last:-no result line}"
  fi
done

# ---- 3. live and frozen runs -------------------------------------------------
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
  quiet=$(( (NOW - $(coord_mtime "$log")) / 60 ))
  if [ "$quiet" -ge "$COORD_FROZEN_MIN" ]; then
    event "frozen:$rid:$(coord_mtime "$log")" frozen true "$ticket" "" "run $rid: no log growth for ${quiet} min" || true
  fi
done
say "live: $LIVE run(s) ${LIVE_TICKETS:+[${LIVE_TICKETS% }]}"

# ---- 4. pull requests --------------------------------------------------------
# A red PR a session already holds through fix-lock.sh is being fixed: judging it
# would queue a second fixer onto the same branch. An expired lock fixes nothing.
FIXLOCK="${COORDINATOR_FIX_LOCK:-$SELF_DIR/fix-lock.sh}"
FIXING=$(FIX_LOCK_REPO="${FIX_LOCK_REPO:-${MAIN_REPO:-}}" bash "$FIXLOCK" list --json 2>/dev/null \
  | jq -r '.[]? | select(.expired | not) | "\(.pr)\t\(.window)"' 2>/dev/null)
PRS=$(swarm_gh pr list --repo "$REPO_SLUG" --state open --limit 200 \
        --json number,headRefName,headRefOid,isDraft,labels,mergeStateStatus,statusCheckRollup 2>/dev/null)
if [ -n "$PRS" ]; then
  printf '%s' "$PRS" | jq -r --arg pre "$BRANCH_PREFIX" --arg hold "$HOLD_LABEL" '
    .[] | select(.isDraft | not) | select(.headRefName | startswith($pre))
    | (.statusCheckRollup // []) as $c
    | ($c | map(select(((.status // "COMPLETED") != "COMPLETED") or ((.state // "") | test("PENDING|EXPECTED")))) | length) as $pending
    | ($c | map(select((.conclusion // .state // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))) | length) as $failed
    | ([.labels[]?.name] | index($hold)) as $held
    | (.headRefName | ltrimstr($pre) | capture("^(?<n>[0-9]+)").n // "") as $t
    | if .mergeStateStatus == "DIRTY" then [ "red", .number, .headRefOid, $t, "clashes with the integration branch" ]
      elif $pending == 0 and $failed > 0 then [ "red", .number, .headRefOid, $t, "checks settled red" ]
      else empty end
    | @tsv' 2>/dev/null \
  | while IFS=$'\t' read -r kind pr sha t why; do
      case "$kind" in
        red)
          fixer=$(awk -F'\t' -v p="$pr" '$1 == p { print $2; exit }' <<<"$FIXING")
          if [ -n "$fixer" ]; then say "PR #$pr: $why — being fixed by $fixer, not judged"
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
    'any(.[]; .headRefName | test("^" + $pre + $t + "([^0-9]|$)"))' >/dev/null 2>&1
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
  if coord_shadow; then say "would re-queue #$t ($cls) at the front — cut off by $why"; return 0; fi
  if bash "$QUEUE" add "$t" --class "$cls" --note "$note" --front >/dev/null 2>&1; then
    say "re-queued #$t ($cls) at the front — cut off by $why"; return 0
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

# ---- 5. spawn ----------------------------------------------------------------
# Labels that keep a ticket from any agent: the swarm's own list, plus gated.
stop_labels() { { swarm_blocking_labels; printf '%s\n' "$LBL_GATED" "$LBL_EXTERNAL_BLOCKED"; } | awk 'NF && !seen[$0]++'; }
# Fails closed: a claim list nobody could read is not "nothing claimed".
claims() {
  if [ -n "${COORDINATOR_CLAIMS_CMD:-}" ]; then $COORDINATOR_CLAIMS_CMD; return; fi
  local j; j=$(bash "$CL" list --json 2>/dev/null)
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$j" || return 1
  jq -r '.[].issue' <<<"$j"
}
CLAIMS_OK=1; CLAIMED=$(claims 2>/dev/null) || CLAIMS_OK=0

spawn_block() { # <ticket> <class> — echoes why not, returns 0 when blocked
  local t="$1" cls="$2" meta st lab l
  grep -qx "$t" <<<"$CLAIMED" && { echo "claimed"; return 0; }
  swarm_ticket_live "$t" && { echo "already running"; return 0; }
  meta=$(swarm_gh issue view "$t" --repo "$REPO_SLUG" --json state,labels \
           -q '.state+" "+([.labels[].name]|join(","))' 2>/dev/null)
  [ -n "$meta" ] || { echo "could not be read"; return 0; }
  st=${meta%% *}; lab=${meta#* }
  [ "$st" = "OPEN" ] || { echo "$st"; return 0; }
  if [ "$cls" = new ]; then
    printf '%s' "${PRS:-[]}" | jq -e --arg pre "$BRANCH_PREFIX" --arg t "$t" \
      'any(.[]; .headRefName | test("^" + $pre + $t + "([^0-9]|$)"))' >/dev/null 2>&1 \
      && { echo "has an open PR"; return 0; }
  fi
  while read -r l; do
    [ -n "$l" ] || continue
    # A repair or an approved merge is in review by definition; only fresh work waits on it.
    [ "$l" = "$LBL_IN_REVIEW" ] && [ "$cls" != new ] && continue
    case ",$lab," in *",$l,"*) echo "$l"; return 0 ;; esac
  done <<< "$(stop_labels)"
  return 1
}

if [ -s "$COORD_QUEUE" ] && [ "${COORDINATOR_REFRESH:-1}" = 1 ]; then
  bash "$QUEUE" refresh >/dev/null 2>&1 || say "queue: refresh failed — working the queue as it stands"
fi

# Each live run's class, as the coordinator recorded it at spawn. A run with none
# on record (started outside the coordinator) heals when its ticket has an open PR.
live_class() { # <record>
  local c t
  c=$(coord_run_class "$1")
  if [ -z "$c" ]; then
    t=$(jq -r '.ticket // empty' "$1" 2>/dev/null)
    printf '%s' "${PRS:-[]}" | jq -e --arg pre "$BRANCH_PREFIX" --arg t "$t" \
      '$t != "" and any(.[]; .headRefName | test("^" + $pre + $t + "([^0-9]|$)"))' >/dev/null 2>&1 && c=repair
  fi
  coord_healing_class "${c:-new}" && echo healing || echo new
}
LIVE_HEAL=0; LIVE_NEW=0
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  if [ "$(live_class "$rec")" = healing ]; then LIVE_HEAL=$((LIVE_HEAL+1)); else LIVE_NEW=$((LIVE_NEW+1)); fi
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
[ "$CEILING" -ge "$LIVE" ] || CEILING=$LIVE
SLOTS=$(( CEILING - LIVE )); [ "$SLOTS" -ge 0 ] || SLOTS=0
HEAL_SLOTS=$(coord_healing_slots "$CEILING"); NEW_SLOTS=$(( CEILING - HEAL_SLOTS ))
HEAL_FREE=$(( HEAL_SLOTS - LIVE_HEAL )); [ "$HEAL_FREE" -ge 0 ] || HEAL_FREE=0
NEW_FREE=$(( NEW_SLOTS - LIVE_NEW ));   [ "$NEW_FREE" -ge 0 ] || NEW_FREE=0
say "ceiling: $LIVE running · $([ "$SLOTS" -gt 0 ] && echo "room for $SLOTS more" || echo "no room for more"): ${READING:-?}${COORD_CAP:+ · cap $COORD_CAP}"

PLAN=""; NEXT=""; TOOK=""; REDS_WAITING=0
# The spawnable entries, in queue order: every healing one (so the reds waiting
# are counted), and new work up to one past the free places (the next pick).
CANDS=""
candidates() {
  local t cls note why nn=0
  while IFS=$'\t' read -r t cls note; do
    [ -n "${t:-}" ] || continue
    coord_healing_class "$cls" || { [ "$nn" -le "$SLOTS" ] || [ "$nn" -lt 2 ] || continue; }
    if why=$(spawn_block "$t" "$cls"); then say "skip #$t ($cls): $why"; continue; fi
    coord_healing_class "$cls" || nn=$((nn+1))
    CANDS="$CANDS$t"$'\t'"$cls"$'\t'"$note"$'\n'
  done <<< "$(coord_queue_ordered)"
}
first_of() { # <healing|new> — the first candidate of that kind: <ticket> \t <class> \t <note>
  local t cls note
  while IFS=$'\t' read -r t cls note; do
    [ -n "${t:-}" ] || continue
    if coord_healing_class "$cls"; then [ "$1" = healing ] || continue; else [ "$1" = new ] || continue; fi
    printf '%s\t%s\t%s' "$t" "$cls" "$note"; return 0
  done <<< "$CANDS"
  return 1
}
# Held with work queued: what it would take next, and the reds that could start.
held_view() {
  candidates
  NEXT=$(printf '%s' "$CANDS" | awk -F'\t' 'NF { print $1; exit }')
  REDS_WAITING=$(printf '%s' "$CANDS" | awk -F'\t' '$2 == "repair" || $2 == "approved-merge"' | grep -c .)
}
if [ -n "$COORD_CAP_BAD" ]; then
  say "spawn: coordinator.cap is '$COORD_CAP_BAD', not a whole number — holding"
  event "cap-bad:$COORD_CAP_BAD" cap-bad false "" "" "coordinator.cap is '$COORD_CAP_BAD', so nothing is spawning" || true
elif held=$(swarm_held); then
  say "spawn: held — $held"
elif [ "$CLAIMS_OK" = 0 ] || [ -z "$PRS" ]; then
  blind=$([ "$CLAIMS_OK" = 0 ] && echo "the claim list" || echo "the open pull requests")
  say "spawn: $blind could not be read — spawning nothing"
  if event "blind:$(swarm_day)" blind false "" "" "$blind could not be read, so nothing is spawning"; then
    bash "$NOTIFY" --class owner "blind:$(swarm_day)" "The coordinator cannot read $blind (gh auth or network?) — nothing is spawning"
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
  while [ "$started" -lt "$SLOTS" ]; do
    heal=$(first_of healing); new=$(first_of new)
    # Each class fills its own share first; a class with nothing spawnable lends
    # its places to the other, in both directions.
    pick=""; lent=""
    if   [ "$HEAL_FREE" -gt 0 ] && [ -n "$heal" ]; then pick="$heal"
    elif [ "$NEW_FREE" -gt 0 ]  && [ -n "$new" ];  then pick="$new"
    elif [ "$HEAL_FREE" -gt 0 ] && [ -n "$new" ];  then pick="$new"; lent="a healing place"
    elif [ "$NEW_FREE" -gt 0 ]  && [ -n "$heal" ]; then pick="$heal"; lent="a new place"
    fi
    [ -n "$pick" ] || break
    IFS=$'\t' read -r t cls note <<< "$pick"
    started=$((started+1))
    # Taken out of the candidates so the next pass picks the next one.
    CANDS=$(printf '%s' "$CANDS" | awk -F'\t' -v p="$t" 'NF && $1 != p'); [ -z "$CANDS" ] || CANDS="$CANDS"$'\n'
    PLAN="${PLAN:+$PLAN,}$t"; TOOK="$cls"
    if coord_healing_class "$cls"; then
      if [ "$HEAL_FREE" -gt 0 ]; then HEAL_FREE=$((HEAL_FREE-1)); else NEW_FREE=$((NEW_FREE-1)); fi
    else
      if [ "$NEW_FREE" -gt 0 ]; then NEW_FREE=$((NEW_FREE-1)); else HEAL_FREE=$((HEAL_FREE-1)); fi
    fi
    # Counted live only once it is (or, in shadow, would be) running.
    count_live() { if coord_healing_class "$cls"; then LIVE_HEAL=$((LIVE_HEAL+1)); else LIVE_NEW=$((LIVE_NEW+1)); fi; }
    coord_act_log spawn "$t" "$cls${note:+ — $note}"
    if coord_shadow; then
      say "would spawn #$t ($cls)${lent:+ in $lent, nothing else spawnable}"; count_live
    else
      brief=""
      if [ -n "$note" ]; then brief=$(mktemp); printf 'Coordinator note (%s): %s\n' "$cls" "$note" > "$brief"; fi
      if CLAIM_CLASS="$cls" swarm_spawn "$t" "$brief" >> "$COORD_LOG" 2>&1; then
        coord_record_class "$t" "$cls"; count_live
        say "spawned #$t ($cls)${lent:+ in $lent, nothing else spawnable}"; bash "$QUEUE" remove "$t" >/dev/null 2>&1
      else say "spawn of #$t failed"; fi
      [ -z "$brief" ] || rm -f "$brief"
    fi
  done
  if [ "$started" -eq 0 ] && [ -z "$CANDS" ]; then
    say "spawn: $SLOTS slot(s), nothing spawnable in the queue"
  fi
  # The next pick is the first spawnable entry left, whatever its class.
  NEXT=$(printf '%s' "$CANDS" | awk -F'\t' 'NF { print $1; exit }')
  REDS_WAITING=$(printf '%s' "$CANDS" | awk -F'\t' '$2 == "repair" || $2 == "approved-merge"' | grep -c .)
  if [ "$REDS_WAITING" -gt 0 ] && ! coord_healing_class "${TOOK:-new}"; then
    say "spawn: healing has its $HEAL_SLOTS place(s) — $REDS_WAITING red(s) wait their turn"
  fi
fi
say "split: $LIVE_NEW new · $LIVE_HEAL healing · $REDS_WAITING reds waiting (of $CEILING: $NEW_SLOTS new, $HEAL_SLOTS healing)"
# What the live view and the merge lane read: the ceiling, its reading, the split, the mode.
jq -cn --arg at "$(swarm_stamp)" --argjson epoch "$(date +%s)" --arg mode "$(coord_mode)" \
   --argjson live "$LIVE" --argjson ceiling "$CEILING" \
   --argjson room "$([ -n "$ROOM" ] && echo true || echo false)" --arg reading "$READING" --arg cap "$COORD_CAP" \
   --argjson hs "$HEAL_SLOTS" --argjson hl "$LIVE_HEAL" --argjson ns "$NEW_SLOTS" --argjson nl "$LIVE_NEW" \
   --argjson waiting "$REDS_WAITING" --arg took "$TOOK" \
   '{at:$at, epoch:$epoch, mode:$mode, live:$live, ceiling:$ceiling, room:$room, reading:$reading,
     cap:(if $cap == "" then null else ($cap|tonumber) end),
     healing:{slots:$hs, live:$hl}, new:{slots:$ns, live:$nl}, redsWaiting:$waiting, started:(if $took == "" then null else $took end)}' \
   > "$COORD_DIR/capacity.json.$$" 2>/dev/null && mv -f "$COORD_DIR/capacity.json.$$" "$COORD_DIR/capacity.json"
# The compare report reads what this tick saw and chose; next= stays last.
printf '%s\tplan\t-\t%s\tlive=%s slots=%s ceiling=%s healing=%s/%s new=%s/%s next=%s\n' "$(swarm_stamp)" "$PLAN" "${LIVE_TICKETS% }" "$SLOTS" \
  "$CEILING" "$LIVE_HEAL" "$HEAL_SLOTS" "$LIVE_NEW" "$NEW_SLOTS" "$NEXT" >> "$COORD_ACTIONS"

# ---- 5b. the merge lane -------------------------------------------------------
# Only where the project names a merge method. Its own lock, its own shadow.
LANE="${COORDINATOR_LANE:-$SELF_DIR/merge-lane.sh}"
if toolkit_cfg merge.method >/dev/null 2>&1; then
  bash "$LANE" >> "$COORD_LOG" 2>&1 || say "merge lane exited $?"
else
  say "merge lane: off — harness.json has no merge.method"
fi

# ---- 6. housekeeping ---------------------------------------------------------
if coord_shadow; then
  bash "$RECONCILE" --dry-run --quiet >> "$COORD_LOG" 2>&1 || say "reconcile (dry) exited $?"
  bash "$SWEEP" --sweep --dry-run >> "$COORD_LOG" 2>&1 || say "server sweep (dry) exited $?"
else
  bash "$RECONCILE" --quiet >> "$COORD_LOG" 2>&1 || say "reconcile exited $?"
  bash "$SWEEP" --sweep >> "$COORD_LOG" 2>&1 || say "server sweep exited $?"
fi
# An agent that dies never reaches /finish's cleanup, so its worktree stays until this runs.
WT_SWEEP="${COORDINATOR_WORKTREE_SWEEP:-$SELF_DIR/sweep-orphan-worktrees.sh}"
WT_STAMP="$COORD_DIR/worktree-sweep.stamp"
if [ -z "$(find "$WT_STAMP" -mmin -"$COORD_SWEEP_EVERY_MIN" 2>/dev/null)" ]; then
  touch "$WT_STAMP"
  if coord_shadow; then bash "$WT_SWEEP" >> "$COORD_LOG" 2>&1 || say "worktree sweep (dry) exited $?"
  else bash "$WT_SWEEP" --apply >> "$COORD_LOG" 2>&1 || say "worktree sweep exited $?"; fi
fi

# ---- 7. disk -----------------------------------------------------------------
CACHE="${COORDINATOR_CACHE:-$SELF_DIR/sweep-orphan-worktrees.sh}"
free_gb() {
  if [ -n "${COORDINATOR_DF:-}" ]; then "$COORDINATOR_DF"
  elif [ -n "${COORDINATOR_FREE_GB:-}" ]; then printf '%s\n' "$COORDINATOR_FREE_GB"
  else df -Pk "$STATE_DIR" 2>/dev/null | awk 'NR==2{print int($4/1048576)}'; fi
}
FREE_GB=$(free_gb)
case "$FREE_GB" in ''|*[!0-9]*) say "disk: free space could not be read"; FREE_GB="" ;; esac
if [ -n "$FREE_GB" ] && [ "$FREE_GB" -lt "$COORD_MIN_FREE_GB" ]; then
  before="$FREE_GB"
  if coord_shadow; then bash "$CACHE" --caches-only >> "$COORD_LOG" 2>&1 || say "cache pass (dry) exited $?"
  else bash "$CACHE" --caches-only --apply >> "$COORD_LOG" 2>&1 || say "cache pass exited $?"; fi
  FREE_GB=$(free_gb); case "$FREE_GB" in ''|*[!0-9]*) FREE_GB="$before" ;; esac
  say "disk: $before GB free, below $COORD_MIN_FREE_GB GB — $FREE_GB GB after the cache pass"
fi
if [ -n "$FREE_GB" ] && [ "$FREE_GB" -lt "$COORD_MIN_FREE_GB" ]; then
  if event "disk-low:$(swarm_day)" disk-low false "" "" "${FREE_GB} GB free, below ${COORD_MIN_FREE_GB} GB"; then
    bash "$NOTIFY" --class owner "disk-low:$(swarm_day)" "Disk is low: ${FREE_GB} GB free (floor ${COORD_MIN_FREE_GB} GB)"
  fi
fi

# ---- 8. judgement ------------------------------------------------------------
bash "$JUDGE" >> "$COORD_LOG" 2>&1 || say "judge exited $?"
say "tick: done"
