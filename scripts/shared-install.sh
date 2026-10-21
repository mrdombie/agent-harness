#!/usr/bin/env bash
# shared-install.sh — keep the shared clone's install at the integration branch's
# lockfile, on every host, with nobody running npm by hand.
#
#   shared-install.sh          one check (coordinator-housekeeping.sh runs it each pass)
#   COORDINATOR_SHADOW=0 …     act for real; anything else says what it would do
#
# The shared clone (MAIN_REPO) is where every worktree's node_modules links point
# (link-node-modules.sh). A trunk merge that adds a package moves package-lock.json
# and nothing re-ran the install there, so every build on that host failed typecheck
# on a module nobody's branch touched, until a person ran `npm install` by hand.
#
# Each check compares the blob of origin/<integrationBranch>:package-lock.json with
# the one recorded beside the install (node_modules/.harness-shared-install). When
# they differ, and nothing on this host is using the install:
#   1. the clone's checkout moves to origin/<integrationBranch> (detached, forced:
#      the shared clone is never edited by hand, block-write-traps.sh refuses it);
#   2. every node_modules in it is moved aside, and `npm ci --no-audit --no-fund` runs,
#      under a lock (flock) and a time limit;
#   3. success records the lock and drops the old install; a failure or a timeout puts
#      the old install and the old checkout back, logs it, and waits
#      coordinator.sharedInstall.retryMin (60) before trying the same lock again.
# Busy is: a live run on this host past its first steps (driver state's finished
# steps beyond coordinator.sharedInstall.preGateSteps, "start"), a run whose step
# cannot be read (the prose flow), or a process sitting in the shared clone
# (worktree-lib.sh). Busy waits for the next check; it is never forced.
#
# No stamp yet, but the clone's own package-lock.json is that blob and npm's record
# of the install agrees with it: adopted, nothing installed.
#
# Settings (harness.json, or the env var): coordinator.sharedInstall.on (1;
# SHARED_INSTALL=0 turns it off), .timeoutMin (30; SHARED_INSTALL_TIMEOUT_SEC),
# .retryMin (60), .preGateSteps ("start"). SHARED_INSTALL_CMD replaces the install
# command (tests).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/coordinator-env.sh" || exit 1
. "$SELF_DIR/worktree-lib.sh" || exit 1

LOGF="$COORD_DIR/shared-install.log"
STAMP_NAME=".harness-shared-install"
FAILED_F="$COORD_DIR/shared-install.failed"
LOCKF="$COORD_DIR/shared-install.lock"
PREV=".harness-prev"
say() { printf '%s shared install: %s\n' "$(date +%H:%M:%S)" "$*"; swarm_log "$COORD_LOG" "shared install: $*"; swarm_log "$LOGF" "$*"; }

# _si_timeout <sec> <cmd…> — runs it in its own process group and kills the group at
# the limit (exit 124): an alarm on npm alone leaves its children writing.
_si_timeout() {
  perl -e '$t = shift; $p = fork; die "fork" unless defined $p;
    if ($p == 0) { setpgrp(0, 0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "TERM", -$p; sleep 3; kill "KILL", -$p; exit 124 };
    alarm $t; waitpid($p, 0); exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$@"
}
# _si_flock <file> <cmd…> — 75 when another holder has the lock. The fd stays open
# into the command (and its children), so the lock lasts as long as they do.
_si_flock() {
  perl -MFcntl=:flock -e '$^F = 255; my $f = shift; open(my $h, ">>", $f) or exit 3;
    flock($h, LOCK_EX | LOCK_NB) or exit 75; exec @ARGV or exit 127' "$@"
}

CLONE="$MAIN_REPO"
BR="${INTEGRATION_BRANCH:-develop}"
# The node_modules directories the install owns: the root's and each workspace's.
# Paths hold no spaces: a clone and its workspaces are named by the harness and npm.
# Neither walks into an install, new or set aside: a package's own node_modules is not one.
nm_dirs()   { find "$CLONE" -maxdepth 4 \( -name .git -o -name "node_modules$PREV" \) -prune -o -type d -name node_modules -print -prune 2>/dev/null; }
prev_dirs() { find "$CLONE" -maxdepth 4 \( -name .git -o -name node_modules \) -prune -o -type d -name "node_modules$PREV" -print -prune 2>/dev/null; }
git_c() { git --git-dir="$GITDIR" --work-tree="$CLONE" "$@"; }

# ---- the install itself, under the lock ---------------------------------------
locked_install() { # <lock blob>
  local want="$1" t0 old rc=0 d why
  t0=$(date +%s)
  old=$(git_c rev-parse -q --verify HEAD 2>/dev/null)
  if ! git_c checkout -q -f --detach "refs/remotes/origin/$BR" >> "$LOGF" 2>&1; then
    say "the checkout could not move to origin/$BR — nothing installed, the old install stays"
    printf '%s %s\n' "$want" "$(date +%s)" > "$FAILED_F"; return 1
  fi
  # Listed first, moved after: find is not walked while its tree changes.
  for d in $(nm_dirs); do rm -rf "$d$PREV"; mv "$d" "$d$PREV"; done
  printf '%s --- %s in %s at %s\n' "$(swarm_stamp)" "${SHARED_INSTALL_CMD:-npm ci --no-audit --no-fund}" "$CLONE" "$(git_c rev-parse --short HEAD)" >> "$LOGF"
  # shellcheck disable=SC2086 # the command is words on purpose
  (cd "$CLONE" && _si_timeout "$TIMEOUT_SEC" ${SHARED_INSTALL_CMD:-npm ci --no-audit --no-fund}) >> "$LOGF" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && [ -d "$CLONE/node_modules" ]; then
    printf '%s %s %s\n' "$want" "$(git_c rev-parse HEAD)" "$(swarm_stamp)" > "$CLONE/node_modules/$STAMP_NAME"
    # A node_modules the install did not make again was not its own: it goes back.
    for d in $(prev_dirs); do if [ -e "${d%"$PREV"}" ]; then rm -rf "$d"; else mv "$d" "${d%"$PREV"}"; fi; done
    rm -f "$FAILED_F"
    say "installed origin/$BR's lock ${want:0:12} at $(git_c rev-parse --short HEAD) in $(( $(date +%s) - t0 ))s"
    return 0
  fi
  if [ "$rc" -eq 124 ]; then why="timed out after $((TIMEOUT_SEC / 60)) min"
  elif [ "$rc" -eq 0 ]; then why="it made no node_modules"
  else why="it exited $rc"; fi
  # The partial install goes; the old one and its checkout come back.
  for d in $(nm_dirs); do rm -rf "$d"; done
  for d in $(prev_dirs); do mv "$d" "${d%"$PREV"}"; done
  [ -z "$old" ] || git_c checkout -q -f --detach "$old" >> "$LOGF" 2>&1 || true
  printf '%s %s\n' "$want" "$(date +%s)" > "$FAILED_F"
  say "the install of lock ${want:0:12} failed ($why) — the old install and checkout are back; tried again in ${RETRY_MIN} min; output in $LOGF"
  return 1
}

# ---- the check ---------------------------------------------------------------
ON="${SHARED_INSTALL:-$(swarm_opt coordinator.sharedInstall.on 1)}"
TIMEOUT_SEC="${SHARED_INSTALL_TIMEOUT_SEC:-$(( $(swarm_opt coordinator.sharedInstall.timeoutMin 30) * 60 ))}"
RETRY_MIN="$(swarm_opt coordinator.sharedInstall.retryMin 60)"
PRE_GATE=" $(swarm_opt coordinator.sharedInstall.preGateSteps start) "
case "$TIMEOUT_SEC" in ''|*[!0-9]*) TIMEOUT_SEC=1800 ;; esac
case "$RETRY_MIN" in ''|*[!0-9]*) RETRY_MIN=60 ;; esac

if [ "${1:-}" = --locked ]; then
  GITDIR=$(git -C "$CLONE" rev-parse --absolute-git-dir 2>/dev/null) || exit 1
  locked_install "$2"; exit $?
fi

[ "$ON" = 0 ] && { say "off (coordinator.sharedInstall.on is 0)"; exit 0; }
[ -d "$CLONE/node_modules" ] || { say "$CLONE has no node_modules — no shared install to keep current"; exit 0; }
GITDIR=$(git -C "$CLONE" rev-parse --absolute-git-dir 2>/dev/null) || { say "$CLONE is not a git clone — skipped"; exit 0; }
[ "$(wt_real "$GITDIR")" != "$(wt_real "$CLONE")" ] || { say "$CLONE is a bare clone with no working tree — skipped"; exit 0; }

if ! (cd / && GIT_TERMINAL_PROMPT=0 _si_timeout 120 git -C "$CLONE" fetch -q origin "+refs/heads/$BR:refs/remotes/origin/$BR") >> "$LOGF" 2>&1; then
  say "origin/$BR could not be fetched — compared with the last fetch"
fi
want=$(git -C "$CLONE" rev-parse -q --verify "refs/remotes/origin/$BR:package-lock.json" 2>/dev/null) \
  || { say "origin/$BR has no package-lock.json — nothing to install"; exit 0; }
have=$(awk 'NR == 1 { print $1 }' "$CLONE/node_modules/$STAMP_NAME" 2>/dev/null)
if [ -z "$have" ] && [ "$(git hash-object "$CLONE/package-lock.json" 2>/dev/null)" = "$want" ] \
   && ! bash "$SELF_DIR/link-node-modules.sh" --behind "$CLONE" >/dev/null 2>&1 \
   && [ -f "$CLONE/node_modules/.package-lock.json" ]; then
  if coord_shadow; then say "lock ${want:0:12} checked: the install already matches it — would record it (shadow)"; exit 0; fi
  printf '%s %s %s\n' "$want" "$(git_c rev-parse HEAD 2>/dev/null)" "$(swarm_stamp)" > "$CLONE/node_modules/$STAMP_NAME"
  say "lock ${want:0:12} checked: the install already matches it — recorded, nothing installed"; exit 0
fi
if [ "$have" = "$want" ]; then say "lock ${want:0:12} checked: unchanged — nothing to install"; exit 0; fi
say "lock checked: origin/$BR has ${want:0:12}, the install was made from ${have:+${have:0:12}}${have:-an unrecorded lock}"

if [ -f "$FAILED_F" ] && read -r fwant fat < "$FAILED_F" && [ "$fwant" = "$want" ] \
   && [ $(( $(date +%s) - ${fat:-0} )) -lt $(( RETRY_MIN * 60 )) ]; then
  say "the install of this lock failed $(( ($(date +%s) - fat) / 60 )) min ago — tried again ${RETRY_MIN} min after it"; exit 0
fi

# Nothing on this host may be reading the install while it is replaced.
busy=""
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  rid=$(basename "$rec" .json)
  t=$(jq -r '.ticket // empty' "$rec" 2>/dev/null); b=$(jq -r '.builder // empty' "$rec" 2>/dev/null)
  if [ "$b" = driver ]; then
    past=""
    for s in $(jq -r '(.done // [])[]' "${DRIVER_DIR:-$STATE_DIR/driver}/$t/state.json" 2>/dev/null); do
      case "$PRE_GATE" in *" $s "*) ;; *) past="$s" ;; esac
    done
    [ -z "$past" ] || busy="$busy${busy:+; }$rid (#$t, past $past)"
  else
    busy="$busy${busy:+; }$rid (#${t:-?}, a ${b:-prose} run: its step cannot be read)"
  fi
done < <(wt_live_runs)
if wt_can_see_processes; then
  wt_cwds_load --exclude-self
  if occ=$(wt_occupant "$(wt_real "$CLONE")"); then busy="$busy${busy:+; }pid $occ ($(ps -o comm= -p "$occ" 2>/dev/null | tr -d ' ')) works in $CLONE"; fi
fi
# How long this lock has waited, so a host that never falls quiet shows it.
WAITF="$COORD_DIR/shared-install.waiting"
[ -n "$busy" ] || rm -f "$WAITF"
if [ -n "$busy" ]; then
  { [ -f "$WAITF" ] && read -r wwant wat < "$WAITF" && [ "$wwant" = "$want" ]; } || { wat=$(date +%s); printf '%s %s\n' "$want" "$wat" > "$WAITF"; }
  say "waiting $(( ($(date +%s) - wat) / 60 )) min — in use on this host: $busy; checked again next pass"; exit 0
fi

if coord_shadow; then say "would install lock ${want:0:12} (shadow)"; exit 0; fi
_si_flock "$LOCKF" bash "${BASH_SOURCE[0]}" --locked "$want"; rc=$?
[ "$rc" -ne 75 ] || say "another install holds $LOCKF — checked again next pass"
exit 0
