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
#                 counts as busy. Another job already on its port is named and
#                 refused; SWARM_REPLACE_PORT=1 unloads it and sets it aside.
#   scheduler     every 5 minutes: top up each programme's queue and drain it.
#   repair-watch  every 10 minutes: repair, unblock, restart, alarm.
#   report        every minute, ONLY when the project sets swarm.reportUrl.
#   coordinator   every 2 minutes: scripts/coordinator-tick.sh. Opt-in — only
#                 `install.sh coordinator` installs it — and in shadow unless
#                 COORDINATOR_SHADOW=0 is set at install. Off macOS it is a
#                 crontab line.
#   merge-lane    every 3 minutes: scripts/merge-lane.sh, the serial merge lane.
#                 Opt-in the same way, and in shadow unless MERGE_LANE_SHADOW=0
#                 is set at install. The coordinator tick also runs it; the
#                 lane's own lock keeps the two from overlapping.
#   keeper        every 15 minutes: swarm/keeper.sh, which resumes the session
#                 `keeper.sh adopt <id>` named once it goes quiet. Opt-in the
#                 same way. Stop it: install.sh uninstall keeper.
#
# Installing the coordinator also opens swarm/coordinator-feed.sh once in a
# terminal window: a line per check, build, red PR and sign-off batch.
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
label()  { swarm_job_label "$1"; }
plist()  { printf '%s/%s.plist' "$AGENTS_DIR" "$(label "$1")"; }

script_for() { # <job> — the command line under the kit, one argument per line
  # Kit-relative, never absolute: the launcher adds the installed version's root.
  case "$1" in
    live-view)    printf 'swarm/live-view.sh\n' ;;
    scheduler)    printf 'swarm/scheduler.sh\n' ;;
    repair-watch) printf 'swarm/repair-watch.sh\n' ;;
    report)       printf 'swarm/report.sh\n--push\n' ;;
    coordinator)  printf 'scripts/coordinator-tick.sh\n' ;;
    merge-lane)   printf 'scripts/merge-lane.sh\n' ;;
    keeper)       printf 'swarm/keeper.sh\n' ;;
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
    coordinator) printf '%s' "${SWARM_EVERY_COORDINATOR:-120}" ;;
    merge-lane) printf '%s' "${SWARM_EVERY_MERGE_LANE:-180}" ;;
    keeper) printf '%s' "${SWARM_EVERY_KEEPER:-900}" ;;
  esac
}

# The environment a launchd job does NOT inherit. It has no login shell, no
# PATH worth the name, and — the one that cost a day — no keychain, so gh hangs
# waiting for an access prompt with nowhere to show it. swarm-env.sh reads the
# token file instead; every path it needs is named here.
# Shadow unless the installer says otherwise, so a first install acts on nothing.
coordinator_shadow() { [ "${COORDINATOR_SHADOW:-1}" = 0 ] && echo 0 || echo 1; }
lane_shadow() { [ "${MERGE_LANE_SHADOW:-1}" = 0 ] && echo 0 || echo 1; }
# The mode variables a job carries, one NAME=value per line.
shadow_vars() { # <job>
  case "$1" in
    keeper)      printf 'SWARM_USAGE_CEILING=%s\n' "$SWARM_USAGE_CEILING" ;;
    coordinator) printf 'COORDINATOR_SHADOW=%s\nMERGE_LANE_SHADOW=%s\n' "$(coordinator_shadow)" "$(lane_shadow)" ;;
    merge-lane)  printf 'MERGE_LANE_SHADOW=%s\n' "$(lane_shadow)" ;;
  esac
}
coordinator_env() { # <job>
  local kv
  for kv in $(shadow_vars "$1"); do
    printf '    <key>%s</key><string>%s</string>\n' "${kv%%=*}" "${kv#*=}"
  done
}
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
# The launcher lives outside the plugin cache, so a job follows plugin updates.
RUNNER="$SWARM_DIR/run-current.sh"
runner_args() { printf '%s\n' "$RUNNER"; script_for "$1"; } # <job>
# Copied whole then renamed: launchd may be running the old one this instant.
install_runner() {
  mkdir -p "$(dirname "$RUNNER")" || return 1
  cp "$SWARM_ROOT/run-current.sh" "$RUNNER.tmp.$$" && chmod +x "$RUNNER.tmp.$$" && mv -f "$RUNNER.tmp.$$" "$RUNNER"
}
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
$(runner_args "$job" | xml_escape | sed 's|.*|    <string>&</string>|')
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HARNESS_MAIN_REPO</key><string>$(printf '%s' "$MAIN_REPO" | xml_escape)</string>
    <key>HARNESS_STATE_DIR</key><string>$(printf '%s' "$STATE_DIR" | xml_escape)</string>
    <key>HARNESS_CFG_PATH</key><string>$(printf '%s' "$HARNESS_CFG" | xml_escape)</string>
    <key>KIT_ROOT</key><string>$(printf '%s' "$KIT_ROOT" | xml_escape)</string>
$(coordinator_env "$job")
  </dict>
$([ "$job" = coordinator ] && printf '  <key>AbandonProcessGroup</key><true/>')
$(if [ -n "$iv" ]; then printf '  <key>StartInterval</key><integer>%s</integer>' "$iv"
  else printf '  <key>KeepAlive</key><true/>\n  <key>RunAtLoad</key><true/>'; fi)
  <key>StandardOutPath</key><string>$(printf '%s/%s.out.log' "$SWARM_LOGS" "$job" | xml_escape)</string>
  <key>StandardErrorPath</key><string>$(printf '%s/%s.err.log' "$SWARM_LOGS" "$job" | xml_escape)</string>
</dict>
</plist>
XML
}

# Every command handed to a timer goes through the launcher, so a plugin update
# reaches the next run with no reinstall. Never a path inside one kit version.
job_cmd() { # <job> — env assignments, then the launcher and the job's kit path
  local vars a args=""
  vars=$(shadow_vars "$1" | tr '\n' ' ')
  for a in $(script_for "$1"); do args="$args $(printf '%q' "$a")"; done
  # A timer's own PATH finds neither claude nor gh: carry the installer's.
  printf 'PATH=%q HARNESS_MAIN_REPO=%q HARNESS_STATE_DIR=%q HARNESS_CFG_PATH=%q KIT_ROOT=%q %s/bin/bash %q%s' \
    "$PATH" "$MAIN_REPO" "$STATE_DIR" "$HARNESS_CFG" "$KIT_ROOT" "$vars" "$RUNNER" "$args"
}

need_launchd() {
  on_launchd && return 0
  install_runner 2>/dev/null
  local j iv
  {
    echo "install: this machine has no launchd, so nothing was installed."
    echo
    echo "Run these on whatever timer the machine does have:"
    for j in $(jobs_for_project); do
      iv=$(interval_for "$j")
      if [ -n "$iv" ]; then iv="every ${iv}s"; else iv=always; fi
      printf '  %s\n    %s\n' "$iv" "$(job_cmd "$j")"
    done
  } >&2
  return 1
}

# ---- elsewhere: the coordinator and the merge lane as one crontab line each,
# marked so a line is replaced, never doubled
SWARM_CRONTAB="${SWARM_CRONTAB:-crontab}"
cron_jobs() { printf 'coordinator\nmerge-lane\nkeeper\n'; }
cron_mark() { printf '# %s' "$(label "$1")"; }
cron_line() { # <job>
  local m=$(( $(interval_for "$1") / 60 )); [ "$m" -ge 1 ] || m=1
  printf '*/%s * * * * %s >> %q 2>&1 %s\n' "$m" "$(job_cmd "$1")" "$SWARM_LOGS/$1.out.log" "$(cron_mark "$1")"
}
cron_rest() { "$SWARM_CRONTAB" -l 2>/dev/null | grep -vF -- "$(cron_mark "$1")"; }
cron_install() { # <job>
  command -v "$SWARM_CRONTAB" >/dev/null 2>&1 || { echo "install: no launchd and no crontab — run this every $(( $(interval_for "$1") / 60 )) minutes yourself:" >&2; cron_line "$1" >&2; return 1; }
  mkdir -p "$SWARM_LOGS"
  install_runner || { echo "install: could not write $RUNNER" >&2; return 1; }
  local rest; rest=$(cron_rest "$1")   # read in full before the write replaces it
  { [ -z "$rest" ] || printf '%s\n' "$rest"; cron_line "$1"; } | "$SWARM_CRONTAB" - && echo "installed $(label "$1") in crontab ($(shadow_vars "$1" | tr '\n' ' ' | sed 's/ $//'))"
}
cron_uninstall() { # <job>
  "$SWARM_CRONTAB" -l 2>/dev/null | grep -F -- "$(cron_mark "$1")" >/dev/null || { echo "$1 was not installed"; return 0; }
  local rest; rest=$(cron_rest "$1")
  { [ -z "$rest" ] || printf '%s\n' "$rest"; } | "$SWARM_CRONTAB" - && echo "removed $(label "$1") from crontab"
}
on_launchd() { [ "${SWARM_UNAME:-$(uname -s)}" = Darwin ] && command -v launchctl >/dev/null 2>&1; }

# Another service already on the live view's port: a hand-written job left over
# from before this file wrote them. Ours would crash-loop on the taken port, so
# it is named and refused, or with SWARM_REPLACE_PORT=1 unloaded and its
# definition moved aside to $SWARM_DIR/replaced/ (never deleted).
port_holder() { # pid listening on SWARM_PORT, or nothing
  if [ -n "${SWARM_PORT_HOLDER+x}" ]; then printf '%s' "$SWARM_PORT_HOLDER"; return 0; fi
  lsof -nP -iTCP:"$SWARM_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1
}
label_of_pid() { launchctl list 2>/dev/null | awk -v p="$1" '$1==p{print $3; exit}'; }
free_port() {
  local pid other
  pid=$(port_holder); [ -n "$pid" ] || return 0
  other=$(label_of_pid "$pid")
  [ "$other" = "$(label live-view)" ] && return 0
  if [ "${SWARM_REPLACE_PORT:-0}" = 1 ] && [ -n "$other" ] && [ -f "$AGENTS_DIR/$other.plist" ]; then
    mkdir -p "$SWARM_DIR/replaced"
    audit replaced-port "$other"
    launchctl unload "$AGENTS_DIR/$other.plist" >/dev/null 2>&1
    mv "$AGENTS_DIR/$other.plist" "$SWARM_DIR/replaced/$other.plist" \
      && echo "replaced $other on port $SWARM_PORT (its definition is in $SWARM_DIR/replaced/)"
    return 0
  fi
  echo "install: port $SWARM_PORT is already served by ${other:-pid $pid}, not this kit's live view." >&2
  [ -n "$other" ] && [ -f "$AGENTS_DIR/$other.plist" ] \
    && echo "  Re-run with SWARM_REPLACE_PORT=1 to unload it and set its definition aside." >&2
  return 4
}

do_install() { # <job>
  local job="$1" f; f=$(plist "$job")
  script_for "$job" >/dev/null || { echo "install: no job called '$job'" >&2; return 2; }
  mkdir -p "$AGENTS_DIR" "$SWARM_LOGS"
  install_runner || { echo "install: could not write $RUNNER" >&2; return 1; }
  if [ "$job" = live-view ]; then free_port || return $?; fi
  print_plist "$job" > "$f"
  launchctl unload "$f" >/dev/null 2>&1
  launchctl load "$f" && echo "installed $(label "$job")" || return 1
  # The coordinator ticks out of sight; its feed opens in a window the first time.
  [ "$job" = coordinator ] && bash "$SWARM_ROOT/coordinator-feed.sh" --open-once
  return 0
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
    # A name that is no action at all is left for the dispatch below to reject.
    is_action=1
    case "${1:-}" in ""|restart) ;; *) script_for "$1" >/dev/null 2>&1 || is_action=0 ;; esac
    # A shadow coordinator or lane acts on nothing, so a hold does not stop installing one.
    [ "${1:-}" = coordinator ] && [ "$(coordinator_shadow)" = 1 ] && is_action=0
    [ "${1:-}" = merge-lane ] && [ "$(lane_shadow)" = 1 ] && is_action=0
    if [ "$is_action" = 1 ] && held=$(swarm_held); then
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

if cron_jobs | grep -x -- "${1:-}" >/dev/null && ! on_launchd; then cron_install "$1"; exit $?; fi
if [ "${1:-}" = uninstall ] && cron_jobs | grep -x -- "${2:-}" >/dev/null && ! on_launchd; then cron_uninstall "$2"; exit $?; fi

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
    for j in $(jobs_for_project) $(for o in coordinator merge-lane keeper; do [ -f "$(plist "$o")" ] && echo "$o"; done); do
      line=$(launchctl list 2>/dev/null | awk -v l="$(label "$j")" '$3==l{print "pid "$1", last exit "$2}')
      printf '%-14s %s\n' "$j" "${line:-not loaded}"
    done; hold_status; exit 0 ;;
  restart)  need_launchd || exit 1; do_install "${2:?restart needs a job}"; exit $? ;;
  uninstall)
    need_launchd || exit 1
    if [ -n "${2:-}" ]; then do_uninstall "$2"; else for j in live-view scheduler repair-watch report coordinator merge-lane keeper; do do_uninstall "$j"; done; fi
    exit 0 ;;
  -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")       need_launchd || exit 1; rc=0; for j in $(jobs_for_project); do do_install "$j" || rc=1; done; exit $rc ;;
  *)        need_launchd || exit 1; do_install "$1"; exit $? ;;
esac
