#!/usr/bin/env bash
# supervisor.sh — the swarm's jobs as ONE long-running process, for machines
# whose timer cannot run them the way launchd does.
#
#   supervisor.sh            run until killed
#   supervisor.sh --once     one pass of every due job, then exit (tests)
#
# WHY NOT ONE TIMER PER JOB, AS ON macOS. Windows Task Scheduler puts a task
# and everything it starts in one job object, and reports the task Running
# until the LAST of those processes exits. An agent is a detached child of the
# scheduler pass that spawned it, so a per-job scheduler task stays Running for
# as long as any agent lives: with IgnoreNew the next pass never fires, and with
# an execution time limit every agent is killed when it expires. Measured
# 2026-09-28: a probe task's detached child outlived the task's own script by
# ninety seconds, and the task read Running for all ninety.
#
# One process that is SUPPOSED to run forever has neither problem: it is the
# task, it is always Running, and the agents living under it are its business.
#
# Stopping the supervisor never stops an agent: install.sh kills this pid, not
# the task, because ending the task ends its whole job object — every agent in it.
set -uo pipefail
SWARM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SWARM_ROOT/swarm-env.sh" || exit 1

EVERY_SCHEDULER="${SWARM_EVERY_SCHEDULER:-300}"
EVERY_REPAIR="${SWARM_EVERY_REPAIR:-600}"
EVERY_REPORT="${SWARM_EVERY_REPORT:-60}"
TICK="${SWARM_SUPERVISOR_TICK:-15}"
# A second machine joining a swarm another machine already runs takes a SHARE of
# it, not all of it. The cap is enforced per machine, so two schedulers on one
# programme run six agents; and repair-watch's once-per-head-commit record is per
# machine, so two watchers repair one red PR twice.
#   SWARM_PROGRAMMES   space-separated programmes this machine schedules (default: every one)
#   SWARM_REPAIR_ONLY  one repair-watch section (repair|unblock|infra|alarm); `infra`
#                      restarts only this machine's own dead runs
PROGRAMMES="${SWARM_PROGRAMMES:-}"
REPAIR_ONLY="${SWARM_REPAIR_ONLY:-}"
PIDFILE="$SWARM_DIR/supervisor.pid"
LOG="$SWARM_LOGS/supervisor.log"

ONCE=0; [ "${1:-}" = "--once" ] && ONCE=1

# One supervisor per project. A second one would run every job twice and, worse,
# two live views would fight over one port.
if [ "$ONCE" -eq 0 ] && [ -s "$PIDFILE" ]; then
  old=$(cat "$PIDFILE")
  if [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null; then
    swarm_log "$LOG" "another supervisor ($old) is running — exiting"
    exit 0
  fi
fi
[ "$ONCE" -eq 1 ] || printf '%s\n' "$$" > "$PIDFILE"

LV_PID=""
live_view_up() {
  [ -n "$LV_PID" ] && kill -0 "$LV_PID" 2>/dev/null && return 0
  [ -n "$LV_PID" ] && swarm_log "$LOG" "live-view ($LV_PID) exited — restarting"
  bash "$SWARM_ROOT/live-view.sh" >> "$SWARM_LOGS/live-view.out.log" 2>> "$SWARM_LOGS/live-view.err.log" &
  LV_PID=$!
  swarm_log "$LOG" "live-view started ($LV_PID)"
}

# A job's last run is a file's mtime, so a supervisor that restarts does not run
# every job at once the moment it comes back.
due() { # <job> <every-seconds>
  local stamp="$SWARM_DIR/supervisor.$1.last" last=0
  [ -f "$stamp" ] && last=$(cat "$stamp" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( $(swarm_now) - last )) -ge "$2" ]
}
ran() { swarm_now > "$SWARM_DIR/supervisor.$1.last"; }

run_job() { # <job> <script> [args…]
  local job="$1"; shift
  ran "$job"
  bash "$@" >> "$SWARM_LOGS/$job.out.log" 2>> "$SWARM_LOGS/$job.err.log"
  local rc=$?
  [ "$rc" -eq 0 ] || swarm_log "$LOG" "$job exited $rc — see $SWARM_LOGS/$job.err.log"
  return 0
}

stop() {
  swarm_log "$LOG" "supervisor $$ stopping"
  [ -n "$LV_PID" ] && kill "$LV_PID" 2>/dev/null
  [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE"
  exit 0
}
trap stop INT TERM

swarm_log "$LOG" "supervisor $$ up (scheduler ${EVERY_SCHEDULER}s, repair ${EVERY_REPAIR}s)"
# The scheduler's first question is the live view, and no answer reads as busy:
# give the view a moment to bind, or the first pass holds and then waits a round.
if [ "$ONCE" -eq 0 ]; then live_view_up; sleep 3; fi
while :; do
  [ "$ONCE" -eq 1 ] || live_view_up
  if due scheduler "$EVERY_SCHEDULER"; then
    if [ -z "$PROGRAMMES" ]; then run_job scheduler "$SWARM_ROOT/scheduler.sh"
    else for p in $PROGRAMMES; do run_job scheduler "$SWARM_ROOT/scheduler.sh" --programme "$p"; done; fi
  fi
  if due repair-watch "$EVERY_REPAIR"; then
    if [ -z "$REPAIR_ONLY" ]; then run_job repair-watch "$SWARM_ROOT/repair-watch.sh"
    else run_job repair-watch "$SWARM_ROOT/repair-watch.sh" --only "$REPAIR_ONLY"; fi
  fi
  if [ -n "$SWARM_REPORT_URL" ] && due report "$EVERY_REPORT"; then
    run_job report "$SWARM_ROOT/report.sh" --push
  fi
  [ "$ONCE" -eq 1 ] && exit 0
  sleep "$TICK"
done
