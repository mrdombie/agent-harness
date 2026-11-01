#!/usr/bin/env bash
# coordinator-judge.sh — for each judgement event not yet judged, one fresh
# `claude -p` with a short brief: the event, the queue, the scope rules. It never
# receives a session's history, and it runs with a turn cap, a budget and a
# bounded compact window.
#
#   coordinator-judge.sh           launch judges for waiting events, up to coordinator.judges
#
# The tick runs this every tick (never behind housekeeping's lock: a slow sweep
# held every judgement for half an hour). One launcher at a time, under its own
# mkdir lock, so no two launchers ever start the same event. A builder's question
# (a stand-down parked on the PM or a person) is judged before red PRs and frozen runs.
#
# In shadow (the default) it logs "would judge" and launches nothing.
# COORDINATOR_CLAUDE replaces the claude binary (tests record its argv and env).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/coordinator-env.sh" || exit 1
. "$SELF_DIR/builder-mcp.sh" || exit 1
. "$SELF_DIR/coordinator-judge-moot.sh" || exit 1

CLAUDE_BIN="${COORDINATOR_CLAUDE:-claude}"
RULES="$KIT_ROOT/shared/coordinator-judge.md"
JUDGED="$COORD_DIR/judged.$(coord_mode).ids"
JDIR="$COORD_DIR/judges"
touch "$JUDGED" "$COORD_EVENTS"

running() {
  local n=0 p
  for p in "$JDIR"/*.pid; do
    [ -f "$p" ] || continue
    if pid_file_alive "$p"; then n=$((n+1)); else rm -f "$p"; fi
  done
  printf '%s' "$n"
}

brief() { # <event json> <event id>
  cat "$RULES"
  printf '\n## The event\n\n```json\n%s\n```\n' "$1"
  printf '\n## The queue (run order: ticket, class, note)\n\n```\n'
  coord_queue_ordered
  printf '```\n\nScope (a ticket under any one of these is in scope): %s\n' \
    "$(jq -r 'if (.labels | type) == "array" and (.labels | length) > 0 then .labels | join(", ") else (.label // "none") end' "$COORD_QUEUE" 2>/dev/null || echo none)"
  printf '\nState directory: %s\nKIT_ROOT: %s\nRepo: %s\n' "$COORD_DIR" "$KIT_ROOT" "$REPO_SLUG"
  printf 'PM answer file: %s\n' "$JDIR/$(safe_id "$2").pm-answer.json"
}

safe_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# Detached, so the judge outlives a tick that launchd reaps when it exits.
launch() { # <id> <event json>
  local safe; safe=$(safe_id "$1")
  brief "$2" "$1" > "$JDIR/$safe.brief"
  bash "$KIT_ROOT/swarm/detach.sh" bash "$SELF_DIR/coordinator-judge.sh" --run "$1" > /dev/null 2>&1 &
  printf '%s\n' "$!" > "$JDIR/$safe.pid"
}

# A PM ANSWER THE JUDGE REACHED IS CARRIED OUT HERE, never left as a log line for the PM to
# do by hand (2026-11-01: a park waited 15 minutes on a split the judge had already decided).
pm_answer() { # <id> <safe>
  local f="$JDIR/$2.pm-answer.json" t out rc
  [ -f "$f" ] || return 0
  t=$(jq -r --arg id "$1" 'select(.id == $id) | .ticket // ""' "$COORD_EVENTS" 2>/dev/null | tail -n 1)
  out=$(bash "$SELF_DIR/pm-answer.sh" "$f" --event-ticket "${t:-none}" 2>&1); rc=$?
  out=$(printf '%s' "$out" | tr '\n\t' '  ')
  case $rc in
    0) printf '%s\t%s\tPM answer carried out\t%s\n' "$(swarm_stamp)" "$1" "$out" ;;
    3) printf '%s\t%s\tPM answer refused, nothing touched\t%s\n' "$(swarm_stamp)" "$1" "$out" ;;
    *) printf '%s\t%s\tPM answer not carried out\t%s\n' "$(swarm_stamp)" "$1" "$out" ;;
  esac >> "$COORD_DIR/judgements.log"
  coord_act_log pm-answer "$1" "exit $rc: $out"
}

run_one() { # <id> — the judge itself, in the foreground of its own session
  local id="$1" safe code
  safe=$(safe_id "$id")
  cd "${COORDINATOR_JUDGE_CWD:-$MAIN_REPO}" 2>/dev/null || cd "$COORD_DIR" || exit 1
  # A judge reads the forge through gh: no MCP server of its own (builder-mcp.sh).
  local mcp=() a
  while IFS= read -r a; do [ -n "$a" ] && mcp+=("$a"); done <<< "$(builder_mcp_args 2>/dev/null)"
  # Nobody reads a judge's turn: the kit's Stop hooks stand down on HARNESS_HEADLESS.
  HARNESS_HEADLESS="judge:$id" CLAUDE_CODE_AUTO_COMPACT_WINDOW="$COORD_JUDGE_COMPACT" KIT_ROOT="$KIT_ROOT" COORD_DIR="$COORD_DIR" \
    "$CLAUDE_BIN" -p "$(cat "$JDIR/$safe.brief")" \
      --max-turns "$COORD_JUDGE_TURNS" \
      --max-budget-usd "$COORD_JUDGE_BUDGET" \
      --permission-mode "${COORDINATOR_PERMISSION_MODE:-auto}" \
      --add-dir "$STATE_DIR" \
      --name "judge-$safe" \
      ${mcp[@]+"${mcp[@]}"} \
      --output-format stream-json --verbose \
      > "$JDIR/$safe.log" 2>&1 < /dev/null
  code=$?
  # A judge the wall stopped decided nothing: its event waits for the next tick after the reset.
  if swarm_usage_log_limited "$JDIR/$safe.log" || swarm_login_log_lost "$JDIR/$safe.log"; then
    grep -vxF -- "$id" "$JUDGED" > "$JUDGED.$$" 2>/dev/null; mv -f "$JUDGED.$$" "$JUDGED"
  else
    pm_answer "$id" "$safe"
  fi
  printf '{"id":"%s","exit_code":%d,"ended_at":"%s"}\n' "$id" "$code" "$(swarm_stamp)" > "$JDIR/$safe.ended"
  rm -f "$JDIR/$safe.pid"
  exit 0
}

if [ "${1:-}" = "--run" ]; then run_one "${2:?--run needs an event id}"; fi

# One launcher at a time: the check-then-append on $JUDGED is not atomic on its own.
LOCK="$COORD_DIR/judge.lock"
coord_lock "$LOCK" "judge launcher" || { echo "judge: $COORD_LOCK_WHY — next tick"; exit 0; }
trap 'rm -rf "$LOCK"' EXIT

# THE FORGE, NOT THIS HOST'S LOG: a PM park is an event only where its build ran, so the
# owner (or a host with no fleet) lists the label's open tickets, one REST read a tick, and
# judges each park no event here covers, once while the label stays.
PM_SEEN="$COORD_DIR/pm-sweep.$(coord_mode).seen"   # <ticket> \t <event id, or own:>
PM_OWN_MIN="${COORDINATOR_PM_SWEEP_OWN_MIN:-60}"
judge_pm_sweep() {
  [ -n "${LBL_PM_DECISION:-}" ] || return 0
  . "$SELF_DIR/coordinator-sheet.sh" || return 0
  case "$(coord_sheet_role)" in owner|off) ;; *) return 0 ;; esac
  local repo="${ISSUE_REF:-$REPO_SLUG}" q got n now seen tmp id
  q=$(jq -rn --arg l "$LBL_PM_DECISION" '$l | @uri')
  got=$(gh_read "the open tickets waiting on the PM" api "repos/$repo/issues?labels=$q&state=open&per_page=100" \
        --jq '.[] | select(.pull_request | not) | .number' 2>&1) \
    || { echo "judge: ${got:-the PM questions could not be read} — swept next tick"; return 0; }
  got=$(printf '%s\n' "$got" | grep -E '^[0-9]+$' | sort -un)
  now=$(swarm_now); touch "$PM_SEEN"
  tmp=$(mktemp "$PM_SEEN.XXXXXX") || return 0
  for n in $got; do
    seen=$(awk -F'\t' -v n="$n" '$1 == n { print; exit }' "$PM_SEEN")
    if [ -n "$seen" ]; then printf '%s\n' "$seen" >> "$tmp"; continue; fi
    # This host's own event for the park (its run ended here) is the one judged.
    if jq -e -s --arg t "$n" --argjson since $(( now - PM_OWN_MIN * 60 )) \
         'any(.[]; .judge == true and .ticket == $t and ((.id // "") | startswith("pm-question:") | not) and ((.at // "") | (try fromdateiso8601 catch 0)) >= $since)' \
         "$COORD_EVENTS" >/dev/null 2>&1; then
      printf '%s\town:\n' "$n" >> "$tmp"; continue
    fi
    id="pm-question:$n:$now"
    jq -cn --arg id "$id" --arg t "$n" --arg at "$(swarm_stamp)" --arg l "$LBL_PM_DECISION" \
      '{id:$id, at:$at, kind:"stood-down", judge:true, ticket:$t, pr:"",
        detail:("parked (pm): #" + $t + " wears " + $l + " and no event on this host covers it — a build on another host or route asked")}' \
      >> "$COORD_EVENTS"
    printf '%s\t%s\n' "$n" "$id" >> "$tmp"
    echo "judge: #$n waits on the PM and no event here covers it — judged as a question"
  done
  mv -f "$tmp" "$PM_SEEN"
}
judge_pm_sweep

# Waiting = a judge:true event not yet judged, question parks first, then oldest first.
waiting() {
  jq -sc --rawfile judged "$JUDGED" '
    ($judged | split("\n") | map(select(. != "")) | map({key: ., value: true}) | from_entries) as $d
    | map(select(.judge == true and ($d[.id // ""] | not)))
    | to_entries
    | sort_by([(if .value.kind == "stood-down" and ((.value.detail // "") | test("parked \\((pm|person)\\)"; "i")) then 0 else 1 end), .key])
    | .[].value' "$COORD_EVENTS" 2>/dev/null
}
WAIT=$(waiting)
n_wait=$(printf '%s' "$WAIT" | grep -c . || true)
if [ "${n_wait:-0}" -gt 0 ]; then
  oldest=$(printf '%s\n' "$WAIT" | jq -rs --argjson now "$(swarm_now)" \
    '[.[].at | select(. != null) | fromdateiso8601] | if length == 0 then 0 else (($now - min) / 60 | floor) end' 2>/dev/null)
  echo "judge: $n_wait waiting, oldest ${oldest:-0} min"
else
  echo "judge: 0 waiting"
fi

slots=$(( COORD_JUDGES - $(running) ))
# Settled by rule first, from one read: a failed read settles nothing and launches nothing.
MOOT_READ=1
if ! coord_shadow && [ "${n_wait:-0}" -gt 0 ]; then
  judge_moot_read <<<"$WAIT" || MOOT_READ=0
fi
while IFS= read -r ev; do
  [ -n "$ev" ] || continue
  id=$(printf '%s' "$ev" | jq -r '.id')
  grep -qxF -- "$id" "$JUDGED" && continue
  if coord_shadow; then
    coord_act_log judge "$id" "$(printf '%s' "$ev" | jq -r '.kind + ": " + .detail')"
    printf '%s\n' "$id" >> "$JUDGED"
    echo "would judge $id"
    continue
  fi
  [ "$MOOT_READ" = 1 ] || { echo "judge: GitHub could not be read, so nothing is settled or judged — $id waits"; break; }
  if why=$(judge_moot "$ev"); then
    printf '%s\n' "$id" >> "$JUDGED"
    printf '%s\t%s\tmoot by rule: %s\tnothing; no judge started\n' "$(swarm_stamp)" "$id" "$why" >> "$COORD_DIR/judgements.log"
    coord_act_log judge-moot "$id" "$why"
    echo "settled $id by rule: $why"
    continue
  fi
  [ "$slots" -gt 0 ] || { echo "judge: no slot for $id — next tick"; break; }
  if until=$(swarm_usage_hold); then echo "judge: the plan's usage limit holds until $until — $id waits"; break; fi
  printf '%s\n' "$id" >> "$JUDGED"
  coord_act_log judge "$id" "$(printf '%s' "$ev" | jq -r '.kind + ": " + .detail')"
  launch "$id" "$ev"
  slots=$((slots-1))
  echo "judging $id"
done <<< "$WAIT"
exit 0
