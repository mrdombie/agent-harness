#!/usr/bin/env bash
# live-view-watchdog.sh — restart a live view that is up but no longer answers.
#
#   . "$KIT_ROOT/scripts/live-view-watchdog.sh"   (after coordinator-env.sh)
#   live_view_watchdog                            one probe; the tick calls it
#   live-view-watchdog.sh                         the same, standalone
#
# launchd and the Windows supervisor restart the live view only when it EXITS. A
# process that is alive and answers nothing is never restarted, and with no answer
# the swarm reads the machine as busy and holds (measured 2026-10-20: up 1h41m,
# every request timed out). Each tick probes SWARM_LIVE_URL with a timeout; after
# LIVE_VIEW_WATCHDOG_FAILS failed probes in a row (default 2) it restarts the job:
#   macOS    launchctl kickstart -k on the label install.sh gave the job, when that
#            job is installed here
#   else     kills the pid live-view.sh recorded; the supervisor, when one runs,
#            starts it again, and otherwise this starts it
# Shadow logs "would restart" and does nothing. Every restart is an action line.
#
# Settings (env): LIVE_VIEW_PROBE_SEC (5), LIVE_VIEW_WATCHDOG_FAILS (2),
# LIVE_VIEW_LAUNCHCTL (launchctl), LIVE_VIEW_START (how to start it off launchd).

lv_say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; swarm_log "${COORD_LOG:-$SWARM_LOGS/live-view-watchdog.log}" "$*"; }
lv_on_launchd() { [ "${SWARM_UNAME:-$(uname -s)}" = Darwin ] && command -v "${LIVE_VIEW_LAUNCHCTL:-launchctl}" >/dev/null 2>&1; }

lv_restart() { # <why> — 0 once a restart was asked for
  local why="$1" lbl pid i LV_PID_FILE="${LIVE_VIEW_PID_FILE:-$SWARM_DIR/live-view.pid}"
  if lv_on_launchd; then
    lbl=$(swarm_job_label live-view)
    # Only the kit's own job: a live view this machine never installed is not ours to bounce.
    [ -f "$HOME/Library/LaunchAgents/$lbl.plist" ] || { lv_say "live-view: $why — no $lbl installed, nothing to restart"; return 1; }
    "${LIVE_VIEW_LAUNCHCTL:-launchctl}" kickstart -k "gui/$(id -u)/$lbl" >/dev/null 2>&1 \
      || { lv_say "live-view: $why — launchctl kickstart of $lbl failed"; return 1; }
    lv_say "live-view: $why — restarted $lbl"
    return 0
  fi
  pid=$(cat "$LV_PID_FILE" 2>/dev/null)
  case "$pid" in ''|*[!0-9]*) lv_say "live-view: $why — no pid recorded in $LV_PID_FILE, nothing to restart"; return 1 ;; esac
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    for i in 1 2 3 4 5 6; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  fi
  local sup; sup=$(cat "$SWARM_DIR/supervisor.pid" 2>/dev/null)
  if [ -n "$sup" ] && kill -0 "$sup" 2>/dev/null; then
    lv_say "live-view: $why — killed $pid; the supervisor ($sup) starts it again"
    return 0
  fi
  if [ -n "${LIVE_VIEW_START:-}" ]; then
    nohup bash -c "$LIVE_VIEW_START" >/dev/null 2>&1 </dev/null &
  else
    nohup bash "$KIT_ROOT/swarm/live-view.sh" >> "$SWARM_LOGS/live-view.out.log" 2>> "$SWARM_LOGS/live-view.err.log" </dev/null &
  fi
  lv_say "live-view: $why — killed $pid and started it again"
  return 0
}

live_view_watchdog() {
  local n need="${LIVE_VIEW_WATCHDOG_FAILS:-2}" LV_FAILS_FILE="${LIVE_VIEW_FAILS_FILE:-$SWARM_DIR/live-view.fails}"
  if swarm_curl -sf -m "${LIVE_VIEW_PROBE_SEC:-5}" -o /dev/null "$SWARM_LIVE_URL" 2>/dev/null; then
    rm -f "$LV_FAILS_FILE"; return 0
  fi
  n=$(cat "$LV_FAILS_FILE" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  if [ "$n" -lt "$need" ]; then
    printf '%s\n' "$n" > "$LV_FAILS_FILE" 2>/dev/null
    lv_say "live-view: no answer from $SWARM_LIVE_URL in ${LIVE_VIEW_PROBE_SEC:-5}s ($n of $need)"
    return 0
  fi
  local why="no answer $n probes in a row"
  if [ "${COORD_SHADOW:-1}" != 0 ]; then
    printf '%s\n' "$n" > "$LV_FAILS_FILE" 2>/dev/null
    lv_say "live-view: $why — would restart (shadow)"
    coord_act_log restart-live-view - "$why" 2>/dev/null
    return 0
  fi
  if lv_restart "$why"; then
    rm -f "$LV_FAILS_FILE"
    coord_act_log restart-live-view - "$why" 2>/dev/null
  else
    printf '%s\n' "$n" > "$LV_FAILS_FILE" 2>/dev/null
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coordinator-env.sh" || exit 1
  live_view_watchdog
fi
