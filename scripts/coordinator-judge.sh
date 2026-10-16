#!/usr/bin/env bash
# coordinator-judge.sh — for each judgement event not yet judged, one fresh
# `claude -p` with a short brief: the event, the queue, the scope rules. It never
# receives a session's history, and it runs with a turn cap, a budget and a
# bounded compact window.
#
#   coordinator-judge.sh           launch judges for waiting events, up to coordinator.judges
#
# In shadow (the default) it logs "would judge" and launches nothing.
# COORDINATOR_CLAUDE replaces the claude binary (tests record its argv and env).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/coordinator-env.sh" || exit 1

CLAUDE_BIN="${COORDINATOR_CLAUDE:-claude}"
RULES="$KIT_ROOT/shared/coordinator-judge.md"
JUDGED="$COORD_DIR/judged.$(coord_mode).ids"
JDIR="$COORD_DIR/judges"
touch "$JUDGED" "$COORD_EVENTS"

running() {
  local n=0 p
  for p in "$JDIR"/*.pid; do
    [ -f "$p" ] || continue
    if kill -0 "$(cat "$p")" 2>/dev/null; then n=$((n+1)); else rm -f "$p"; fi
  done
  printf '%s' "$n"
}

brief() { # <event json>
  cat "$RULES"
  printf '\n## The event\n\n```json\n%s\n```\n' "$1"
  printf '\n## The queue (run order: ticket, class, note)\n\n```\n'
  coord_queue_ordered
  printf '```\n\nScope (a ticket under any one of these is in scope): %s\n' \
    "$(jq -r 'if (.labels | type) == "array" and (.labels | length) > 0 then .labels | join(", ") else (.label // "none") end' "$COORD_QUEUE" 2>/dev/null || echo none)"
  printf '\nState directory: %s\nKIT_ROOT: %s\nRepo: %s\n' "$COORD_DIR" "$KIT_ROOT" "$REPO_SLUG"
}

safe_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# Detached, so the judge outlives a tick that launchd reaps when it exits.
launch() { # <id> <event json>
  local safe; safe=$(safe_id "$1")
  brief "$2" > "$JDIR/$safe.brief"
  bash "$KIT_ROOT/swarm/detach.sh" bash "$SELF_DIR/coordinator-judge.sh" --run "$1" > /dev/null 2>&1 &
  printf '%s\n' "$!" > "$JDIR/$safe.pid"
}

run_one() { # <id> — the judge itself, in the foreground of its own session
  local id="$1" safe code
  safe=$(safe_id "$id")
  cd "${COORDINATOR_JUDGE_CWD:-$MAIN_REPO}" 2>/dev/null || cd "$COORD_DIR" || exit 1
  CLAUDE_CODE_AUTO_COMPACT_WINDOW="$COORD_JUDGE_COMPACT" KIT_ROOT="$KIT_ROOT" COORD_DIR="$COORD_DIR" \
    "$CLAUDE_BIN" -p "$(cat "$JDIR/$safe.brief")" \
      --max-turns "$COORD_JUDGE_TURNS" \
      --max-budget-usd "$COORD_JUDGE_BUDGET" \
      --permission-mode "${COORDINATOR_PERMISSION_MODE:-auto}" \
      --add-dir "$STATE_DIR" \
      --name "judge-$safe" \
      --output-format stream-json --verbose \
      > "$JDIR/$safe.log" 2>&1 < /dev/null
  code=$?
  # A judge the wall stopped decided nothing: its event waits for the next tick after the reset.
  if swarm_usage_log_limited "$JDIR/$safe.log" || swarm_login_log_lost "$JDIR/$safe.log"; then
    grep -vxF -- "$id" "$JUDGED" > "$JUDGED.$$" 2>/dev/null; mv -f "$JUDGED.$$" "$JUDGED"
  fi
  printf '{"id":"%s","exit_code":%d,"ended_at":"%s"}\n' "$id" "$code" "$(swarm_stamp)" > "$JDIR/$safe.ended"
  rm -f "$JDIR/$safe.pid"
  exit 0
}

if [ "${1:-}" = "--run" ]; then run_one "${2:?--run needs an event id}"; fi

slots=$(( COORD_JUDGES - $(running) ))
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
  [ "$slots" -gt 0 ] || { echo "judge: no slot for $id — next tick"; break; }
  if until=$(swarm_usage_hold); then echo "judge: the plan's usage limit holds until $until — $id waits"; break; fi
  printf '%s\n' "$id" >> "$JUDGED"
  coord_act_log judge "$id" "$(printf '%s' "$ev" | jq -r '.kind + ": " + .detail')"
  launch "$id" "$ev"
  slots=$((slots-1))
  echo "judging $id"
done < <(jq -c 'select(.judge == true)' "$COORD_EVENTS" 2>/dev/null)
exit 0
