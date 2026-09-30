#!/usr/bin/env bash
# install.sh — put the swarm's timers on the machine, so nothing depends on a
# session being open.
#
#   install.sh                 install every job that applies to this project
#   install.sh <job>           just one
#   install.sh status          what is loaded, and when each last ran
#   install.sh restart <job>   stop and start one
#   install.sh uninstall [job] remove them all, or one
#   install.sh --print <job>   print the job definition, write nothing
#   install.sh hold "<why>"    stop anything spawning until released (#42)
#   install.sh release         lift the hold, on purpose
#   install.sh audit [n]       the last n installs, restarts, holds and releases
#
# THE JOBS
#   live-view     the snapshot every other part reads — kept alive, restarted
#                 if it dies. Without it the swarm holds, because no answer
#                 counts as busy.
#   scheduler     every 5 minutes: top up each programme's queue and drain it.
#   repair-watch  every 10 minutes: repair, unblock, restart, alarm.
#   report        every minute, ONLY when the project sets swarm.reportUrl.
#
# Six of these were installed by hand on the machine they came from, which is
# why three of them were running a version nobody could name. They are written
# from this file now, and `status` reads back what is actually loaded.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swarm-env.sh" || exit 1

SWARM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$HOME/Library/LaunchAgents"
# Two projects can share one machine, so the label carries a key derived from
# the state directory — the one thing that is already per-project.
KEY=$(printf '%s' "$STATE_DIR" | cksum | awk '{printf "%08x", $1}')
NS="agent-harness.swarm"

jobs_for_project() {
  printf 'live-view\nscheduler\nrepair-watch\n'
  [ -n "$SWARM_REPORT_URL" ] && printf 'report\n'
  return 0
}
label()  { printf '%s.%s.%s' "$NS" "$1" "$KEY"; }
plist()  { printf '%s/%s.plist' "$AGENTS_DIR" "$(label "$1")"; }

script_for() { # <job> — the command line, one argument per line
  case "$1" in
    live-view)    printf '%s/live-view.sh\n' "$SWARM_ROOT" ;;
    scheduler)    printf '%s/scheduler.sh\n' "$SWARM_ROOT" ;;
    repair-watch) printf '%s/repair-watch.sh\n' "$SWARM_ROOT" ;;
    report)       printf '%s/report.sh\n--push\n' "$SWARM_ROOT" ;;
    *) return 1 ;;
  esac
}
# A job either runs forever and is kept alive, or runs on an interval. Never
# both: a KeepAlive on an interval job relaunches it the instant it finishes.
interval_for() {
  case "$1" in
    live-view) printf '' ;;
    scheduler) printf '%s' "${SWARM_EVERY_SCHEDULER:-300}" ;;
    repair-watch) printf '%s' "${SWARM_EVERY_REPAIR:-600}" ;;
    report) printf '%s' "${SWARM_EVERY_REPORT:-60}" ;;
  esac
}

# The environment a launchd job does NOT inherit. It has no login shell, no
# PATH worth the name, and — the one that cost a day — no keychain, so gh hangs
# waiting for an access prompt with nowhere to show it. swarm-env.sh reads the
# token file instead; every path it needs is named here.
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
print_plist() { # <job>
  local job="$1" arg iv
  iv=$(interval_for "$job")
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$(label "$job")</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
$(script_for "$job" | xml_escape | sed 's|.*|    <string>&</string>|')
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HARNESS_MAIN_REPO</key><string>$(printf '%s' "$MAIN_REPO" | xml_escape)</string>
    <key>HARNESS_STATE_DIR</key><string>$(printf '%s' "$STATE_DIR" | xml_escape)</string>
    <key>HARNESS_CFG_PATH</key><string>$(printf '%s' "$HARNESS_CFG" | xml_escape)</string>
    <key>KIT_ROOT</key><string>$(printf '%s' "$KIT_ROOT" | xml_escape)</string>
  </dict>
$(if [ -n "$iv" ]; then printf '  <key>StartInterval</key><integer>%s</integer>' "$iv"
  else printf '  <key>KeepAlive</key><true/>\n  <key>RunAtLoad</key><true/>'; fi)
  <key>StandardOutPath</key><string>$(printf '%s/%s.out.log' "$SWARM_LOGS" "$job" | xml_escape)</string>
  <key>StandardErrorPath</key><string>$(printf '%s/%s.err.log' "$SWARM_LOGS" "$job" | xml_escape)</string>
</dict>
</plist>
XML
}

need_launchd() {
  [ "$(uname -s)" = "Darwin" ] && command -v launchctl >/dev/null 2>&1 && return 0
  cat >&2 <<MSG
install: this machine has no launchd, so nothing was installed.

Run these on whatever timer the machine does have:
  every ${SWARM_EVERY_SCHEDULER:-300}s   $SWARM_ROOT/scheduler.sh
  every ${SWARM_EVERY_REPAIR:-600}s   $SWARM_ROOT/repair-watch.sh
  always     $SWARM_ROOT/live-view.sh$([ -n "$SWARM_REPORT_URL" ] && printf '\n  every %ss    %s/report.sh --push' "${SWARM_EVERY_REPORT:-60}" "$SWARM_ROOT")
MSG
  return 1
}

do_install() { # <job>
  local job="$1" f; f=$(plist "$job")
  script_for "$job" >/dev/null || { echo "install: no job called '$job'" >&2; return 2; }
  mkdir -p "$AGENTS_DIR" "$SWARM_LOGS"
  print_plist "$job" > "$f"
  launchctl unload "$f" >/dev/null 2>&1
  launchctl load "$f" && echo "installed $(label "$job")"
}
do_uninstall() { # <job>
  local f; f=$(plist "$1")
  [ -f "$f" ] || { echo "$1 was not installed"; return 0; }
  launchctl unload "$f" >/dev/null 2>&1; rm -f "$f"; echo "removed $(label "$1")"
}

# ---- Windows: one Task Scheduler task running supervisor.sh ------------------
# See supervisor.sh for why Windows gets one long-running task rather than a
# timer per job: a task and every process it starts share one job object, so a
# per-job task would stay Running while any agent it spawned lives.
is_windows() { case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }
WIN_TASK="$NS.$KEY"
WIN_WRAPPER="$SWARM_DIR/supervisor-task.sh"
win_ps() { powershell.exe -NoProfile -NonInteractive -Command "$1" 2>&1 | tr -d '\r'; }

# The environment a scheduled task does NOT inherit is written down, the way the
# plist writes it: the kit's paths, and this shell's PATH — which is where the
# claude CLI, gh, node and a -b jq shim were found.
win_write_wrapper() {
  mkdir -p "$SWARM_DIR" "$SWARM_LOGS"
  {
    echo '#!/usr/bin/env bash'
    echo '# Written by swarm/install.sh. Re-run it after a kit update: this names one copy.'
    printf 'export HARNESS_MAIN_REPO=%q HARNESS_STATE_DIR=%q HARNESS_CFG_PATH=%q KIT_ROOT=%q\n' \
      "$MAIN_REPO" "$STATE_DIR" "$HARNESS_CFG" "$KIT_ROOT"
    printf 'export PATH=%q\n' "$PATH"
    local v; for v in SWARM_PROGRAMMES SWARM_REPAIR_ONLY SWARM_CAP SWARM_BUDGET_USD; do
      [ -n "${!v:-}" ] && printf 'export %s=%q\n' "$v" "${!v}"
    done
    printf 'exec bash %q >> %q 2>&1\n' "$SWARM_ROOT/supervisor.sh" "$SWARM_LOGS/supervisor.out.log"
  } > "$WIN_WRAPPER"
}

win_supervisor_pid() {
  local p; p=$(cat "$SWARM_DIR/supervisor.pid" 2>/dev/null)
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && printf '%s' "$p"
}

# Stops the supervisor and its live view — never the task, whose end would take
# every agent in its job object with it.
win_stop_supervisor() {
  local p i
  p=$(win_supervisor_pid) || return 0
  kill "$p" 2>/dev/null
  for i in $(seq 1 30); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
  kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
  echo "stopped supervisor $p (agents keep running)"
}

win_install() {
  command -v powershell.exe >/dev/null 2>&1 || { echo "install: no powershell.exe on PATH" >&2; return 1; }
  command -v claude >/dev/null 2>&1 || echo "install: warning — no claude CLI on PATH; the spawner will refuse" >&2
  win_write_wrapper
  local bashw wrapw
  bashw="$(cygpath -w /)\\bin\\bash.exe"
  [ -f "$(cygpath -u "$bashw")" ] || bashw=$(cygpath -w "$(command -v bash)")
  wrapw=$(cygpath -w "$WIN_WRAPPER")
  win_stop_supervisor
  win_ps "
\$a = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument '--headless \"$bashw\" -l \"$wrapw\"'
\$t = New-ScheduledTaskTrigger -AtLogOn -User \$env:USERNAME
\$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName '$WIN_TASK' -Action \$a -Trigger \$t -Settings \$s -Description 'agent-harness swarm supervisor ($STATE_DIR)' -Force | Out-Null
Start-ScheduledTask -TaskName '$WIN_TASK'
'installed $WIN_TASK'"
  local i; for i in $(seq 1 20); do win_supervisor_pid >/dev/null && break; sleep 1; done
  win_supervisor_pid >/dev/null && echo "supervisor running (pid $(win_supervisor_pid))" \
    || { echo "install: the task started but no supervisor answered — see $SWARM_LOGS/supervisor.out.log" >&2; return 1; }
}

win_status() {
  local st p j last
  st=$(win_ps "(Get-ScheduledTask -TaskName '$WIN_TASK' -ErrorAction SilentlyContinue).State")
  p=$(win_supervisor_pid)
  printf '%-14s %s\n' "task" "${st:-not installed}"
  if [ -n "$p" ]; then printf '%-14s pid %s\n' "supervisor" "$p"; else printf '%-14s not running\n' "supervisor"; fi
  for j in $(jobs_for_project); do
    if [ "$j" = live-view ]; then
      if swarm_curl -s -m 3 "$SWARM_LIVE_URL" >/dev/null 2>&1; then last=answering; else last="not answering"; fi
    else
      last=$(cat "$SWARM_DIR/supervisor.$j.last" 2>/dev/null)
      case "$last" in ''|*[!0-9]*) last="never ran" ;; *) last="last ran $(( $(swarm_now) - last ))s ago" ;; esac
    fi
    printf '%-14s %s\n' "$j" "$last"
  done
}

win_uninstall() {
  win_stop_supervisor
  win_ps "Unregister-ScheduledTask -TaskName '$WIN_TASK' -Confirm:\$false -ErrorAction SilentlyContinue; 'removed $WIN_TASK'"
}

# ---- who started it, and the hold (#42) -------------------------------------
# A stopped swarm came back on 2026-09-29 and nothing could say who ran this.
# Every action that changes what runs is written down BEFORE it happens: the
# time, the caller's session and parent process, and the kit's branch and SHA.
AUDIT="$SWARM_LOGS/install-audit.log"
audit() { # <action> [detail]
  local parent; parent=$(ps -o args= -p "$PPID" 2>/dev/null | tr -s ' ' | cut -c1-120)
  printf '%s\t%s\t%s@%s\tsession=%s\tparent=%s\tkit=%s@%s\tprogrammes=%s cap=%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(whoami 2>/dev/null)" "$(hostname 2>/dev/null)" \
    "${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-none}}" "${parent:-?}" \
    "$(git -C "$SWARM_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
    "$(git -C "$SWARM_ROOT" rev-parse --short HEAD 2>/dev/null)" \
    "${SWARM_PROGRAMMES:-all}" "$SWARM_CAP" "${2:-}" >> "$AUDIT"
}
hold_status() {
  local h; if h=$(swarm_held); then printf '%-14s %s\n' "HOLD" "$h"; fi
  if [ -s "$AUDIT" ]; then echo "last changes:"; tail -n 3 "$AUDIT" | cut -f1,2,3,4 | sed 's/^/  /'; fi
  return 0
}

case "${1:-}" in
  hold)
    reason="${2:?hold needs a reason: install.sh hold \"<why>\"}"
    printf '%s (held %s by %s)\n' "$reason" "$(date -u +%Y-%m-%dT%H:%MZ)" "$(whoami 2>/dev/null)" > "$SWARM_HOLD_FILE"
    audit hold "$reason"
    echo "held: nothing spawns until 'install.sh release'. Agents already running are not stopped."
    exit 0 ;;
  release)
    if ! was=$(swarm_held); then echo "not held"; exit 0; fi
    audit release "was: $was"; rm -f "$SWARM_HOLD_FILE"
    echo "released — the next scheduler pass may spawn."
    exit 0 ;;
  audit) tail -n "${2:-20}" "$AUDIT" 2>/dev/null; exit 0 ;;
  status|uninstall|--print|--jobs|-h|--help) ;;
  *)
    # Installing or restarting while held brings back what the owner stopped.
    if held=$(swarm_held); then
      audit refused-held "${1:-install}"
      echo "install: the swarm is held — $held. Run 'install.sh release' first, on purpose." >&2
      exit 3
    fi ;;
esac
# Only an action that changes what runs is written down: install, restart,
# uninstall, or a real job name. A typo is refused further down, not audited.
case "${1:-}" in
  ""|restart|uninstall) audit "${1:-install}" "${2:-}" ;;
  *) if script_for "$1" >/dev/null 2>&1; then audit "$1" "${2:-}"; fi ;;
esac

if is_windows; then
  case "${1:-}" in
    --print|--jobs|-h|--help) ;;   # platform-neutral; fall through below
    status)    win_status; hold_status; exit 0 ;;
    uninstall) [ -n "${2:-}" ] && echo "on Windows every job runs in one supervisor; removing it"
               win_uninstall; exit 0 ;;
    restart)   win_install; exit $? ;;
    "")        win_install; exit $? ;;
    *)         script_for "$1" >/dev/null || { echo "install: no job called '$1'" >&2; exit 2; }
               echo "on Windows every job runs in one supervisor; installing it"
               win_install; exit $? ;;
  esac
fi

case "${1:-}" in
  --print)  shift; script_for "${1:?--print needs a job}" >/dev/null || { echo "no job called '${1:-}'" >&2; exit 2; }
            print_plist "$1"; exit 0 ;;
  --jobs)   jobs_for_project; exit 0 ;;
  status)
    need_launchd || exit 1
    for j in $(jobs_for_project); do
      line=$(launchctl list 2>/dev/null | awk -v l="$(label "$j")" '$3==l{print "pid "$1", last exit "$2}')
      printf '%-14s %s\n' "$j" "${line:-not loaded}"
    done; hold_status; exit 0 ;;
  restart)  need_launchd || exit 1; do_install "${2:?restart needs a job}"; exit $? ;;
  uninstall)
    need_launchd || exit 1
    if [ -n "${2:-}" ]; then do_uninstall "$2"; else for j in live-view scheduler repair-watch report; do do_uninstall "$j"; done; fi
    exit 0 ;;
  -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")       need_launchd || exit 1; rc=0; for j in $(jobs_for_project); do do_install "$j" || rc=1; done; exit $rc ;;
  *)        need_launchd || exit 1; do_install "$1"; exit $? ;;
esac
