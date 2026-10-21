#!/usr/bin/env bash
# keeper.sh — keeps one interactive Claude session (the coordinator tab) alive.
#
#   keeper.sh                          one pass: alive, or one headless turn resumes it
#   keeper.sh adopt <session-id> [cwd] keep this session (cwd defaults to its own, else $PWD)
#   keeper.sh forget                   keep nothing
#   keeper.sh status                   what is kept, and the last decisions
#
# The swarm's jobs survive any session; the coordinator tab does not. It stops
# when its usage runs out, its context ends or the editor closes it. A pass reads
# $STATE_DIR/coordinator/keeper.json and writes one line per decision to
# $STATE_DIR/coordinator/keeper.log:
#   alive            its transcript was written lately, or a claude process holds it
#   revived          one `claude -p --resume <id> "<prompt>"` ran from its cwd
#   skipped: usage   the plan's usage hold (the coordinator's own read) is on
#   skipped: held    the swarm is held
#   skipped: locked  another pass is still running its turn
# It only ever resumes that session: never a work loop, never a second session.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swarm-env.sh" || exit 1

KEEP_DIR="${COORDINATOR_DIR:-$STATE_DIR/coordinator}"
KEEP_FILE="${KEEPER_FILE:-$KEEP_DIR/keeper.json}"
KEEP_LOG="${KEEPER_LOG:-$KEEP_DIR/keeper.log}"
KEEP_OUT="${KEEPER_OUT:-$KEEP_DIR/keeper-runs.log}"
KEEP_LOCK="$KEEP_DIR/keeper.lock"
KEEP_CLAUDE="${KEEPER_CLAUDE:-claude}"
KEEP_PROJECTS="${KEEPER_PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"
KEEP_SESSIONS="${KEEPER_SESSIONS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions}"
KEEP_FRESH_MIN="${KEEPER_FRESH_MIN:-40}"
KEEP_TIMEOUT="${KEEPER_TIMEOUT_SEC:-1800}"
KEEP_MODE="${KEEPER_PERMISSION_MODE:-auto}"
KEEP_PROMPT_DEFAULT="You are the coordinator tab, resumed by the keeper because the session went quiet. Re-arm your watches, read pending notifications and peer messages, check harness builders and the coordinator, act on anything waiting, then end with your status block."
mkdir -p "$KEEP_DIR" 2>/dev/null || true

decide() { # <decision> <session> [detail]
  printf '%s\t%s\t%s\t%s\n' "$(swarm_stamp)" "$1" "$2" "${3:-}" >> "$KEEP_LOG"
  printf 'keeper: %s %s %s\n' "$1" "$2" "${3:-}"
}
mtime() { # GNU stat first: BSD's -f on GNU prints filesystem text at exit 1
  local m; m=$(stat -c %Y "$1" 2>/dev/null); case "$m" in ''|*[!0-9]*) m="" ;; esac
  [ -n "$m" ] || { m=$(stat -f %m "$1" 2>/dev/null); case "$m" in ''|*[!0-9]*) m=0 ;; esac; }
  printf '%s' "$m"
}
slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
transcript() { # <id> <cwd> — the slug's file, else wherever the id's file is
  local f="$KEEP_PROJECTS/$(slug "$2")/$1.jsonl"
  [ -f "$f" ] || f=$(ls "$KEEP_PROJECTS"/*/"$1.jsonl" 2>/dev/null | head -1)
  printf '%s' "$f"
}
procs() { if [ -n "${KEEPER_PS_FILE:-}" ]; then cat "$KEEPER_PS_FILE"; else ps -axo pid=,args= 2>/dev/null; fi; }
pid_alive() { if [ -n "${KEEPER_PS_FILE:-}" ]; then procs | awk -v p="$1" '$1==p{f=1} END{exit !f}'; else kill -0 "$1" 2>/dev/null; fi; }
# A VS Code session carries no id in its args and holds no transcript open; the registry names it.
holder() { # <id> — pid of a live claude process holding it
  local f pid
  for f in "$KEEP_SESSIONS"/*.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r '.sessionId // empty' "$f" 2>/dev/null)" = "$1" ] || continue
    pid=$(jq -r '.pid // empty' "$f" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    pid_alive "$pid" && procs | awk -v p="$pid" '$1==p && $0 ~ /claude/{f=1} END{exit !f}' && { printf '%s' "$pid"; return 0; }
  done
  procs | awk -v id="$1" '{ n = split($2, a, "/") } a[n] == "claude" && index($0, id) { print $1; f=1; exit } END{exit !f}'
}

adopt() { # <id> [cwd]
  local id="${1:?adopt needs a session id}" cwd="${2:-}" f prompt
  case "$id" in *[!0-9a-fA-F-]*|"") echo "keeper: '$id' is not a session id" >&2; return 2 ;; esac
  if [ -z "$cwd" ]; then
    for f in "$KEEP_SESSIONS"/*.json; do
      [ -f "$f" ] && [ "$(jq -r '.sessionId // empty' "$f" 2>/dev/null)" = "$id" ] && cwd=$(jq -r '.cwd // empty' "$f") && break
    done
  fi
  cwd="${cwd:-$PWD}"
  [ -d "$cwd" ] || { echo "keeper: no directory $cwd" >&2; return 2; }
  prompt="${KEEPER_PROMPT:-$KEEP_PROMPT_DEFAULT}"
  jq -n --arg id "$id" --arg cwd "$cwd" --arg prompt "$prompt" --arg at "$(swarm_stamp)" \
    '{session:$id, cwd:$cwd, prompt:$prompt, adopted_at:$at}' > "$KEEP_FILE.tmp.$$" && mv -f "$KEEP_FILE.tmp.$$" "$KEEP_FILE" \
    && echo "keeper: keeping $id in $cwd ($(transcript "$id" "$cwd" | sed 's/^$/no transcript yet/'))"
}

lock() { # mkdir is atomic; a lock whose pid is gone is a crash, not a run
  if mkdir "$KEEP_LOCK" 2>/dev/null; then echo $$ > "$KEEP_LOCK/pid"; return 0; fi
  local p; p=$(cat "$KEEP_LOCK/pid" 2>/dev/null)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then return 1; fi
  rm -rf "$KEEP_LOCK"; mkdir "$KEEP_LOCK" 2>/dev/null && echo $$ > "$KEEP_LOCK/pid"
}

pass() {
  [ -s "$KEEP_FILE" ] || return 0
  local id cwd prompt t age pid until held start rc
  id=$(jq -r '.session // empty' "$KEEP_FILE" 2>/dev/null)
  cwd=$(jq -r '.cwd // empty' "$KEEP_FILE" 2>/dev/null)
  prompt=$(jq -r '.prompt // empty' "$KEEP_FILE" 2>/dev/null); prompt="${prompt:-$KEEP_PROMPT_DEFAULT}"
  [ -n "$id" ] && [ -d "$cwd" ] || { decide "skipped: unreadable" "${id:--}" "$KEEP_FILE names no session or no directory"; return 0; }
  t=$(transcript "$id" "$cwd")
  if [ -n "$t" ]; then
    age=$(( $(swarm_now) - $(mtime "$t") ))
    [ "$age" -lt $(( KEEP_FRESH_MIN * 60 )) ] && { decide alive "$id" "transcript written ${age}s ago"; return 0; }
  fi
  if pid=$(holder "$id"); then decide alive "$id" "claude pid $pid holds it"; return 0; fi
  if held=$(swarm_held); then decide "skipped: held" "$id" "$held"; return 0; fi
  if until=$(swarm_usage_hold); then decide "skipped: usage" "$id" "until $until"; return 0; fi
  lock || { decide "skipped: locked" "$id" "pid $(cat "$KEEP_LOCK/pid" 2>/dev/null) is running a turn"; return 0; }
  trap 'rm -rf "$KEEP_LOCK"' EXIT
  start=$(date +%s)
  printf '\n=== %s resume %s in %s\n' "$(swarm_stamp)" "$id" "$cwd" >> "$KEEP_OUT"
  # An alarm set before exec survives it: no watchdog left to kill a reused pid.
  ( cd "$cwd" && exec perl -e 'alarm shift; exec @ARGV or exit 127' "$KEEP_TIMEOUT" \
      "$KEEP_CLAUDE" -p --resume "$id" --permission-mode "$KEEP_MODE" "$prompt" ) >> "$KEEP_OUT" 2>&1 < /dev/null
  rc=$?
  decide revived "$id" "exit $rc after $(( $(date +%s) - start ))s$([ "$rc" -ge 128 ] && echo ", stopped at the ${KEEP_TIMEOUT}s limit"), output in $KEEP_OUT"
}

case "${1:-}" in
  adopt)  shift; adopt "$@" ;;
  forget) rm -f "$KEEP_FILE"; echo "keeper: keeping nothing" ;;
  status) if [ -s "$KEEP_FILE" ]; then jq -c . "$KEEP_FILE"; else echo "keeper: keeping nothing"; fi
          tail -n 5 "$KEEP_LOG" 2>/dev/null ;;
  "")     pass ;;
  -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *)      echo "keeper: no command '$1' (adopt | forget | status)" >&2; exit 2 ;;
esac
