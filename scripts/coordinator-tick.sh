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
#   2. ended runs    each runs/*.ended not yet seen: its exit code and final result
#   3. frozen runs   a live run whose log has not grown for coordinator.frozenMin
#   4. pull requests red, or a pixel PR gone green that needs sign-off
#   5. spawn         the queue in class order, up to coordinator.cap live runs,
#                    never a ticket that is claimed, gated or on hold
#   5b. merge lane   merge-lane.sh, when harness.json names merge.method
#   6. housekeeping  reconcile-claims.sh, then stop-dev-servers.sh --sweep
#   7. disk          free space below coordinator.minFreeGb is an alarm
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
SEEN_ENDED="$COORD_DIR/ended.seen"
touch "$SEEN_ENDED" "$COORD_EVENTS" "$COORD_ACTIONS"

say() { printf '%s\n' "$*"; swarm_log "$COORD_LOG" "$*"; }

# ---- 1. lock ----------------------------------------------------------------
LOCK="$COORD_DIR/tick.lock"
coord_lock "$LOCK" tick || { say "tick: $COORD_LOCK_WHY — exiting"; exit 0; }
trap 'rm -rf "$LOCK"' EXIT

say "tick: $(coord_mode) mode, cap $COORD_CAP"

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
limit_hit() { # <log>
  grep -qE '"status":"rejected","resetsAt"|hit your (session|weekly) limit' "$1" 2>/dev/null
}
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
    event "usage-limit:$rid" usage-limit true "$ticket" "" "run $rid stopped on the plan's usage limit"
  elif [ "$code" != 0 ] || printf '%s' "$last" | grep -qiE 'park|stood down|stand down|blocked|cannot continue'; then
    event "stood-down:$rid" stood-down true "$ticket" "" "run $rid ended exit $code: ${last:-no result line}"
  fi
done

# ---- 3. live and frozen runs -------------------------------------------------
NOW=$(swarm_now)
LIVE=0; LIVE_TICKETS=""
for rec in "$RUNS_DIR"/claim-*.json; do
  [ -f "$rec" ] || continue
  swarm_record_alive "$rec" || continue
  LIVE=$((LIVE+1))
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
      elif $held != null and $pending == 0 and $failed == 0 and ($c | length) > 0 then [ "signoff", .number, .headRefOid, $t, "green and waiting on sign-off" ]
      else empty end
    | @tsv' 2>/dev/null \
  | while IFS=$'\t' read -r kind pr sha t why; do
      case "$kind" in
        red) event "red-pr:$pr:$sha" red-pr true "$t" "$pr" "$why" || true ;;
        signoff)
          if event "signoff:$pr:$sha" signoff false "$t" "$pr" "$why"; then
            bash "$NOTIFY" "signoff:$pr:$sha" "PR #$pr (ticket #$t) is green and needs your sign-off"
          fi ;;
      esac
    done
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

SLOTS=$(( COORD_CAP - LIVE ))
PLAN=""; NEXT=""
# The first ticket this tick would take, slot or not: what the compare report matches.
first_free() {
  local t cls note
  while IFS=$'\t' read -r t cls note; do
    [ -n "${t:-}" ] || continue
    spawn_block "$t" "$cls" >/dev/null || { printf '%s' "$t"; return 0; }
  done <<< "$(coord_queue_ordered)"
}
if held=$(swarm_held); then
  say "spawn: held — $held"
elif [ "$CLAIMS_OK" = 0 ] || [ -z "$PRS" ]; then
  blind=$([ "$CLAIMS_OK" = 0 ] && echo "the claim list" || echo "the open pull requests")
  say "spawn: $blind could not be read — spawning nothing"
  if event "blind:$(swarm_day)" blind false "" "" "$blind could not be read, so nothing is spawning"; then
    bash "$NOTIFY" "blind:$(swarm_day)" "The coordinator cannot read $blind (gh auth or network?) — nothing is spawning"
  fi
elif until=$(swarm_usage_hold); then
  say "spawn: usage limit — holding until $until"
  event "usage-hold:$until" usage-limit true "" "" "the plan's usage limit holds until $until" || true
elif [ "$SLOTS" -le 0 ]; then
  say "spawn: $LIVE live, cap $COORD_CAP — no slot"
  NEXT=$(first_free)
else
  started=0
  while IFS=$'\t' read -r t cls note; do
    [ -n "${t:-}" ] || continue
    if why=$(spawn_block "$t" "$cls"); then
      say "skip #$t ($cls): $why"; continue
    fi
    [ "$started" -lt "$SLOTS" ] || { NEXT="$t"; break; }
    PLAN="$PLAN$t,"
    started=$((started+1))
    coord_act_log spawn "$t" "$cls${note:+ — $note}"
    if coord_shadow; then
      say "would spawn #$t ($cls)"
    else
      brief=""
      if [ -n "$note" ]; then brief=$(mktemp); printf 'Coordinator note (%s): %s\n' "$cls" "$note" > "$brief"; fi
      if swarm_spawn "$t" "$brief" >> "$COORD_LOG" 2>&1; then
        say "spawned #$t ($cls)"; bash "$QUEUE" remove "$t" >/dev/null 2>&1
      else say "spawn of #$t failed"; fi
      [ -z "$brief" ] || rm -f "$brief"
    fi
  done <<< "$(coord_queue_ordered)"
  [ "$started" -gt 0 ] || say "spawn: $SLOTS slot(s), nothing spawnable in the queue"
fi
# The compare report reads what this tick saw and chose.
printf '%s\tplan\t-\t%s\tlive=%s slots=%s next=%s\n' "$(swarm_stamp)" "${PLAN%,}" "${LIVE_TICKETS% }" "$SLOTS" "$NEXT" >> "$COORD_ACTIONS"

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

# ---- 7. disk -----------------------------------------------------------------
FREE_GB="${COORDINATOR_FREE_GB:-$(df -Pk "$STATE_DIR" 2>/dev/null | awk 'NR==2{print int($4/1048576)}')}"
if [ -n "$FREE_GB" ] && [ "$FREE_GB" -lt "$COORD_MIN_FREE_GB" ]; then
  if event "disk-low:$(swarm_day)" disk-low false "" "" "${FREE_GB} GB free, below ${COORD_MIN_FREE_GB} GB"; then
    bash "$NOTIFY" "disk-low:$(swarm_day)" "Disk is low: ${FREE_GB} GB free (floor ${COORD_MIN_FREE_GB} GB)"
  fi
fi

# ---- 8. judgement ------------------------------------------------------------
bash "$JUDGE" >> "$COORD_LOG" 2>&1 || say "judge exited $?"
say "tick: done"
