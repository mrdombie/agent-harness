#!/usr/bin/env bash
# disk-guard.sh — nothing new starts on a nearly full disk.
#
#   disk-guard.sh free               free GB on the state volume, a whole number
#   disk-guard.sh host               the Windows drive also read under WSL (empty elsewhere)
#   disk-guard.sh limits             "<stopBelowGb> <resumeAtGb>"
#   disk-guard.sh check [<what>]     exit 1, saying why, below stopBelowGb: a long one-off job asks first
#   disk-guard.sh tick               the coordinator's hold, printed "<free>\t<line>"; exit 1 while held.
#                                    Held from under stopBelowGb until resumeAtGb is free, not on the first GB back.
#
# Owner call 2026-10-20, "Auto-clean and stop below 30 GB": the data volume reached 0.1 GB free and
# no build, session or coordinator tick could start a shell.
#
# The auto-clean it ran is gone. It removed what builders left behind in shared places — proof
# trees, spawn checkouts, idle trees' linked installs and caches — and each builder now owns its
# tree's install, dev server and caches: the run's exit removes them (spawn-claim.sh, worktree-cache.sh
# --deep), the idle sweep takes an abandoned tree's (sweep-orphan-worktrees.sh), and a proof's
# trees go with its run (build-ticket's EXIT trap).
#
# Settings (harness.json, or the env var):
#   coordinator.disk.stopBelowGb   COORDINATOR_DISK_STOP_BELOW_GB   30
#   coordinator.disk.resumeAtGb    COORDINATOR_DISK_RESUME_AT_GB    50   (never under stopBelowGb)
#   coordinator.disk.hostPath      COORDINATOR_DISK_HOST_PATH       /mnt/c  (WSL only)
# Under WSL, Linux's df reads the virtual disk, which can show 831 GB free while the Windows drive
# holding it has 37; the guard reads both and works from the lower, saying which bound.
# Seams: COORDINATOR_DF (a command printing free GB), COORDINATOR_FREE_GB, DISK_GUARD_PROC (/proc),
#   DISK_GUARD_HOLD_FILE.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The kit's config when there is one; the defaults when there is not. A guard that cannot start is no guard.
KIT_OK=0
if . "$HERE/toolkit-env.sh" >/dev/null 2>&1; then KIT_OK=1; fi
cd / || exit 1

cfg() { local v=""; [ "$KIT_OK" = 1 ] && v=$(toolkit_cfg "$1" 2>/dev/null); printf '%s' "${v:-$2}"; }
whole() { case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }

STOP_GB=$(whole "${COORDINATOR_DISK_STOP_BELOW_GB:-$(cfg coordinator.disk.stopBelowGb 30)}" 30)
RESUME_GB=$(whole "${COORDINATOR_DISK_RESUME_AT_GB:-$(cfg coordinator.disk.resumeAtGb 50)}" 50)
[ "$RESUME_GB" -ge "$STOP_GB" ] || RESUME_GB=$STOP_GB
STATE="${STATE_DIR:-}"
HOLD_FILE="${DISK_GUARD_HOLD_FILE:-${COORDINATOR_DIR:-${STATE:-$HOME/.harness-state}/coordinator}/disk-hold}"

PROC="${DISK_GUARD_PROC:-/proc}"
is_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] || [ -e "$PROC/sys/fs/binfmt_misc/WSLInterop" ] \
    || grep -i microsoft "$PROC/version" >/dev/null 2>&1
}
host_path() { is_wsl && printf '%s' "${COORDINATOR_DISK_HOST_PATH:-$(cfg coordinator.disk.hostPath /mnt/c)}"; }
df_gb() { df -Pk "$1" 2>/dev/null | awk 'NR==2{print int($4/1048576)}'; }
# free_gb — "<GB>" or, under WSL, "<the lower GB>\t<which bound>".
free_gb() {
  if [ -n "${COORDINATOR_DF:-}" ]; then "$COORDINATOR_DF"
  elif [ -n "${COORDINATOR_FREE_GB:-}" ]; then printf '%s\n' "$COORDINATOR_FREE_GB"
  else
    local at="$HOME" lx hp h; [ -n "$STATE" ] && [ -d "$STATE" ] && at="$STATE"
    lx=$(df_gb "$at"); hp=$(host_path)
    if [ -n "$hp" ]; then
      h=$(df_gb "$hp")
      case "$h" in ''|*[!0-9]*) printf '%s\ton Linux (the Windows host at %s could not be read)\n' "$lx" "$hp"; return ;; esac
      case "$lx" in ''|*[!0-9]*) printf '%s\ton the Windows host\n' "$h"; return ;; esac
      if [ "$h" -lt "$lx" ]; then printf '%s\ton the Windows host (Linux shows %s)\n' "$h" "$lx"
      else printf '%s\ton Linux (the Windows host shows %s)\n' "$lx" "$h"; fi
      return
    fi
    printf '%s\n' "$lx"
  fi
}
# read_free — sets FREE_NOW, and FREE_WHERE to " <which bound>" when two were read; 1 when unread.
FREE_NOW=""; FREE_WHERE=""
read_free() {
  local l; l=$(free_gb 2>/dev/null | head -1)
  FREE_NOW=${l%%$'\t'*}; FREE_WHERE=""; [ "$FREE_NOW" = "$l" ] || FREE_WHERE=" ${l#*$'\t'}"
  case "$FREE_NOW" in ''|*[!0-9]*) FREE_NOW=""; return 1 ;; esac
}
free_now() { read_free && printf '%s' "$FREE_NOW"; }

cmd="${1:-}"; shift || true
case "$cmd" in
  free)   free_now || { echo "disk-guard: free space could not be read" >&2; exit 2; }; echo; exit 0 ;;
  limits) echo "$STOP_GB $RESUME_GB"; exit 0 ;;
  host)   host_path; echo; exit 0 ;;
  check)
    what="${1:-this job}"
    [ "${HARNESS_DISK_GUARD:-on}" = off ] && exit 0
    if ! read_free; then echo "disk-guard: free space could not be read — $what goes ahead" >&2; exit 0; fi
    if [ "$FREE_NOW" -lt "$STOP_GB" ]; then
      echo "disk low: $FREE_NOW GB free$FREE_WHERE, under the $STOP_GB GB $what needs"
      exit 1
    fi
    exit 0 ;;
  tick)
    if ! read_free; then
      if [ -f "$HOLD_FILE" ]; then printf '\tdisk low: free space unread, held since %s\n' "$(head -1 "$HOLD_FILE")"; exit 1; fi
      printf '\tdisk: free space could not be read\n'; exit 0
    fi
    f=$FREE_NOW; w=$FREE_WHERE
    if [ "$f" -lt "$STOP_GB" ]; then
      [ -f "$HOLD_FILE" ] || { mkdir -p "$(dirname "$HOLD_FILE")"; date -u +%Y-%m-%dT%H:%M:%SZ > "$HOLD_FILE"; }
      printf '%s\tdisk low: %s GB free%s, under %s GB — nothing new starts until %s GB is free\n' "$f" "$f" "$w" "$STOP_GB" "$RESUME_GB"; exit 1
    fi
    if [ -f "$HOLD_FILE" ] && [ "$f" -lt "$RESUME_GB" ]; then
      printf '%s\tdisk low: %s GB free%s, held since under %s GB — nothing new starts until %s GB is free\n' "$f" "$f" "$w" "$STOP_GB" "$RESUME_GB"; exit 1
    fi
    if [ -f "$HOLD_FILE" ]; then rm -f "$HOLD_FILE"; printf '%s\tdisk: %s GB free%s, at or above %s GB — starts resume\n' "$f" "$f" "$w" "$RESUME_GB"; exit 0; fi
    printf '%s\tdisk: %s GB free%s\n' "$f" "$f" "$w"; exit 0 ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
