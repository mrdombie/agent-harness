#!/usr/bin/env bash
# shared-install-hold.sh — the hold shared-install.sh puts on new starts. Sourced by
# coordinator-tick.sh and shared-install.sh, so the writer and the reader agree.
#
# A host whose builds never all fall quiet would wait for ever to replace its
# shared install: five builds overlap nearly all the time. So once a moved lock has
# waited coordinator.sharedInstall.drainAfterMin (30), shared-install.sh writes this
# hold; the tick then starts nothing new, the live builds finish, the install runs,
# and the hold is removed. Each check rewrites it (the tick re-runs the check every
# tick while it stands): one not rewritten for coordinator.sharedInstall.holdStaleMin
# (15) — its writer stopped — holds nothing. On 2026-10-22 one stood 17 min unread
# while the only build it waited on had ended, and the old 120-min limit kept it.
#
# The same hold stands while the shared install is broken (shared-install.sh verifies each
# install before recording it); its line then starts "⚠ shared install broken".
#
#   shared_install_hold_file          its path
#   shared_install_hold               prints why, 0 while it holds; 1 when it does not
#   shared_install_hold_stale         prints its age in min, 0 when a hold stands past the limit
#   shared_install_hold_set <why>     write or refresh it
#   shared_install_hold_clear         remove it
shared_install_hold_file() { printf '%s' "${SHARED_INSTALL_HOLD_FILE:-$COORD_DIR/shared-install-hold}"; }
shared_install_hold_stale_min() {
  local m; m=$(swarm_opt coordinator.sharedInstall.holdStaleMin 15)
  case "$m" in ''|*[!0-9]*) m=15 ;; esac; printf '%s' "$m"
}
shared_install_hold_stale() {
  local f age; f=$(shared_install_hold_file)
  [ -f "$f" ] || return 1
  age=$(( ($(date +%s) - $(coord_mtime "$f")) / 60 ))
  [ "$age" -ge "$(shared_install_hold_stale_min)" ] || return 1
  printf '%s' "$age"
}
shared_install_hold() {
  local f
  f=$(shared_install_hold_file)
  [ -f "$f" ] || return 1
  ! shared_install_hold_stale >/dev/null || return 1
  # A broken install names itself: it waits on no build.
  case "$(head -1 "$f")" in
    "⚠ shared install broken"*) head -1 "$f" | cut -c1-300 ;;
    *) printf 'the shared install waits on the builds running here: %s' "$(head -1 "$f" | cut -c1-200)" ;;
  esac
}
shared_install_hold_set()   { printf '%s\n' "$1" > "$(shared_install_hold_file)"; }
shared_install_hold_clear() { rm -f "$(shared_install_hold_file)"; }
