#!/usr/bin/env bash
# coordinator-feed.sh — signs of life: one line per thing the coordinator did,
# with its time, followed live from its own log. No model calls, no forge calls.
#
#   coordinator-feed.sh                follow the coordinator's log
#   coordinator-feed.sh --log <file>   follow that file
#   coordinator-feed.sh --render       turn log lines on stdin into feed rows, once
#   coordinator-feed.sh --open         open the feed in a terminal window
#   coordinator-feed.sh --open-once    the same, the first time only (install does this)
#
# Rows: a check starting and ending, what is building, a build started or
# finished, a red pull request, sign-offs ready, and why nothing was started.
# NO_COLOR set: plain text.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

if [ -n "${NO_COLOR:-}" ]; then DIM="" GRN="" YEL="" RED="" OFF=""
else DIM=$'\033[2m' GRN=$'\033[32m' YEL=$'\033[33m' RED=$'\033[31m' OFF=$'\033[0m'; fi
EVERY_MIN=$(( ${SWARM_EVERY_COORDINATOR:-300} / 60 ))

row() { # <log line> — the coordinator stamps each line "HH:MM:SS <what>"
  local l="$1" t="" w
  case "$l" in [0-2][0-9]:[0-5][0-9]:[0-5][0-9]\ *) t="${l%% *}"; l="${l#* }" ;; esac
  w="${t:-        }"
  case "$l" in
    "tick: done")          printf '%s%s ── check done, next in %s min%s\n' "$DIM" "$w" "$EVERY_MIN" "$OFF" ;;
    "tick: "*" mode,"*)    printf '\n%s%s ── check started%s\n' "$DIM" "$w" "$OFF" ;;
    "tick: "*)             printf '%s%s ── %s%s\n' "$DIM" "$w" "${l#tick: }" "$OFF" ;;
    live:*)                printf '%s %s● building%s %s\n' "$w" "$GRN" "$OFF" "${l#live: }" ;;
    "spawned "*)           printf '%s %s▶ started%s %s\n' "$w" "$GRN" "$OFF" "${l#spawned }" ;;
    "would spawn "*)       printf '%s %s▷ would start%s %s\n' "$w" "$DIM" "$OFF" "${l#would spawn }" ;;
    "ended: "*)            printf '%s %s■ finished%s %s\n' "$w" "$DIM" "$OFF" "$(printf '%s' "${l#ended: }" | cut -c1-140)" ;;
    "event: red-pr"*)      printf '%s %s▲ red%s %s\n' "$w" "$YEL" "$OFF" "${l#event: red-pr }" ;;
    "event: signoff"*)     printf '%s %s★ for you%s sign-offs ready: %s\n' "$w" "$RED" "$OFF" "${l#event: signoff }" ;;
    "event: "*)            printf '%s %s▲%s %s\n' "$w" "$YEL" "$OFF" "${l#event: }" ;;
    "spawn: "*)            printf '%s %s‖ not starting:%s %s\n' "$w" "$DIM" "$OFF" "${l#spawn: }" ;;
    "")                    : ;;
    *)                     printf '%s%s   %s%s\n' "$DIM" "$w" "$l" "$OFF" ;;
  esac
}

render() { local l; while IFS= read -r l || [ -n "$l" ]; do row "$l"; done; }

log_path() {
  . "$(dirname "$SELF")/swarm-env.sh" >/dev/null || return 1
  printf '%s/coordinator.out.log' "$SWARM_LOGS"
}

follow() { # <log>
  printf '\033]0;Coordinator\007'
  echo "Coordinator, live. It checks every $EVERY_MIN minutes. Close this window any time; nothing stops."
  [ -e "$1" ] || echo "(no log yet at $1 — waiting for the first check)"
  tail -n 15 -F "$1" 2>/dev/null | render
}

# A terminal window running the feed. SWARM_FEED_OPENER replaces the opener
# (it is given the command line); without one, macOS Terminal, else the command.
open_window() {
  local log cmd
  log=$(log_path) || { echo "coordinator-feed: cannot resolve the coordinator's log" >&2; return 1; }
  cmd="bash $(printf '%q' "$SELF") --log $(printf '%q' "$log")"
  if [ -n "${SWARM_FEED_OPENER:-}" ]; then "$SWARM_FEED_OPENER" "$cmd"; return; fi
  if [ "$(uname -s)" = Darwin ] && command -v osascript >/dev/null 2>&1; then
    local esc=${cmd//\\/\\\\}; esc=${esc//\"/\\\"}
    osascript -e "tell application \"Terminal\" to do script \"$esc\"" >/dev/null && echo "coordinator-feed: opened in Terminal"
    return
  fi
  echo "coordinator-feed: run this in a terminal to watch the coordinator:"
  echo "  $cmd"
}

case "${1:-}" in
  --render) render ;;
  --log)    follow "${2:?--log needs a file}" ;;
  --open)   open_window ;;
  --open-once)
    . "$(dirname "$SELF")/swarm-env.sh" >/dev/null || exit 1
    stamp="$SWARM_DIR/coordinator-feed.opened"
    [ -e "$stamp" ] && exit 0
    open_window && { mkdir -p "$SWARM_DIR"; date -u +%FT%TZ > "$stamp"; } ;;
  "")       log=$(log_path) || { echo "coordinator-feed: cannot resolve the coordinator's log" >&2; exit 1; }
            follow "$log" ;;
  -h|--help) sed -n '2,13p' "$SELF" | sed 's/^# \{0,1\}//' ;;
  *) echo "coordinator-feed: no such option '$1'" >&2; exit 2 ;;
esac
