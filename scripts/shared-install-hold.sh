#!/usr/bin/env bash
# shared-install-hold.sh — the hold shared-install.sh puts on new starts. Sourced by
# coordinator-tick.sh and shared-install.sh, so the writer and the reader agree.
#
# A host whose builds never all fall quiet would wait for ever to replace its
# shared install: five builds overlap nearly all the time. So once a moved lock has
# waited coordinator.sharedInstall.drainAfterMin (30), shared-install.sh writes this
# hold; the tick then starts nothing new, the live builds finish, the install runs,
# and the hold is removed. Each waiting pass rewrites it: one not rewritten for
# coordinator.sharedInstall.holdStaleMin (120) — its writer stopped — holds nothing.
#
#   shared_install_hold_file          its path
#   shared_install_hold               prints why, 0 while it holds; 1 when it does not
#   shared_install_hold_set <why>     write or refresh it
#   shared_install_hold_clear         remove it
shared_install_hold_file() { printf '%s' "${SHARED_INSTALL_HOLD_FILE:-$COORD_DIR/shared-install-hold}"; }
shared_install_hold() {
  local f stale age
  f=$(shared_install_hold_file)
  [ -f "$f" ] || return 1
  stale=$(swarm_opt coordinator.sharedInstall.holdStaleMin 120)
  case "$stale" in ''|*[!0-9]*) stale=120 ;; esac
  age=$(( ($(date +%s) - $(coord_mtime "$f")) / 60 ))
  [ "$age" -lt "$stale" ] || return 1
  printf 'the shared install waits on the builds running here: %s' "$(head -1 "$f" | cut -c1-200)"
}
shared_install_hold_set()   { printf '%s\n' "$1" > "$(shared_install_hold_file)"; }
shared_install_hold_clear() { rm -f "$(shared_install_hold_file)"; }
