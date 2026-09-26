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

case "${1:-}" in
  --print)  shift; script_for "${1:?--print needs a job}" >/dev/null || { echo "no job called '${1:-}'" >&2; exit 2; }
            print_plist "$1"; exit 0 ;;
  --jobs)   jobs_for_project; exit 0 ;;
  status)
    need_launchd || exit 1
    for j in $(jobs_for_project); do
      line=$(launchctl list 2>/dev/null | awk -v l="$(label "$j")" '$3==l{print "pid "$1", last exit "$2}')
      printf '%-14s %s\n' "$j" "${line:-not loaded}"
    done; exit 0 ;;
  restart)  need_launchd || exit 1; do_install "${2:?restart needs a job}"; exit $? ;;
  uninstall)
    need_launchd || exit 1
    if [ -n "${2:-}" ]; then do_uninstall "$2"; else for j in live-view scheduler repair-watch report; do do_uninstall "$j"; done; fi
    exit 0 ;;
  -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")       need_launchd || exit 1; rc=0; for j in $(jobs_for_project); do do_install "$j" || rc=1; done; exit $rc ;;
  *)        need_launchd || exit 1; do_install "$1"; exit $? ;;
esac
