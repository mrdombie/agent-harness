#!/usr/bin/env bash
# coordinator-service.sh — is this project's coordinator installed, and is it live?
#
#   coordinator-service.sh     prints live | shadow | off; exits 0 only when live
#
# live    installed (launchd job loaded, or its crontab line present) with
#         COORDINATOR_SHADOW=0: it spawns builders on its own.
# shadow  installed, acting on nothing.
# off     not installed for this project's state directory.
#
# /agent-harness:work, /agent-harness:auto and claim-lock.sh ask this before a
# chat builds anything: while the coordinator is live, every builder is its
# spawn, under its cap and its usage hold, and visible on the live view.
# COORDINATOR_SERVICE=live|shadow|off answers for it (tests, and a machine
# whose scheduler this cannot read).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../swarm" && pwd)/swarm-env.sh" >/dev/null 2>&1 || { echo off; exit 1; }

answer() { echo "$1"; [ "$1" = live ]; exit $?; }
case "${COORDINATOR_SERVICE:-}" in live|shadow|off) answer "$COORDINATOR_SERVICE" ;; esac

LABEL=$(swarm_job_label coordinator)
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
if [ "${SWARM_UNAME:-$(uname -s)}" = Darwin ] && command -v launchctl >/dev/null 2>&1; then
  [ -f "$PLIST" ] || answer off
  launchctl list 2>/dev/null | awk -v l="$LABEL" '$3==l{f=1} END{exit !f}' || answer off
  grep -A0 '<key>COORDINATOR_SHADOW</key>' "$PLIST" | grep -q '<string>0</string>' && answer live
  answer shadow
fi
line=$("${SWARM_CRONTAB:-crontab}" -l 2>/dev/null | grep -F -- "# $LABEL" | head -1)
[ -n "$line" ] || answer off
case "$line" in *"COORDINATOR_SHADOW=0 "*) answer live ;; esac
answer shadow
