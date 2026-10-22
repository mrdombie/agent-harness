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
# Busy is: a live run on this host past its start step (any finished step outside
# coordinator.sharedInstall.preGateSteps, default none), a run whose step cannot be
# read (the prose flow), or a process sitting in the shared clone (worktree-lib.sh).
# Every step after start reads the install: measured on the Mac on 2026-10-21, plan
# ran an install-reading command in 21 of 88 transcripts and review in 35 of 53, and
# ship's push runs the project's pre-push, which runs its own npm gates. A run still in
# start is safe: a link made while the install is set aside writes no fingerprint,
# and self-check relinks a tree without one.
#
# BUSY IS BOUNDED. Five builds overlap nearly all the time, so a host could wait for
# ever. Once the lock has waited coordinator.sharedInstall.drainAfterMin (30), and for
# the whole install, it holds new starts on this host (shared-install-hold.sh, read
# by the tick like the disk hold); the live builds finish, the install runs, and the
# hold goes whenever nothing is pending any more: installed, failed, or unchanged.
#
# The clone's own package-lock.json is that blob and npm's record of the install agrees
# with it — no stamp yet, or a stamp a hand install left behind: adopted, nothing installed.
#
# EXACTLY WHAT THE LOCK PINS, whatever the project's age rule. `npm ci` installs only the
# lockfile's versions, so the age cutoff the project's .npmrc sets (min-release-age,
# before) guards nothing there: it is lifted on that command alone (--min-release-age=0,
# --before=<now>), read from the trunk's .npmrc. On 2026-10-22 develop moved Next to
# 16.4.2, published seven days before less a few hours, and the PM installed by hand past
# the rule.
#
# A BUILD THE INSTALL WOULD FIX IS NOT A BUILD IT WAITS FOR. A live run counts as busy
# only when its tree's package-lock.json is not already the trunk's: one that merged the
# trunk (every repair does) is failing on the old install, and the wait only kept it
# failing. Measured that day: the lock moved at 16:54Z, the install waited on four
# builds (three repairs) for 36 min, held new starts, and every builder's pre-push failed
# meanwhile. While the install is behind and not run, every pass says so loudly, with
# the number of packages behind: "shared install behind the lockfile: N packages".
#
# Settings (harness.json, or the env var): coordinator.sharedInstall.on (1;
# SHARED_INSTALL=0 turns it off), .timeoutMin (30; SHARED_INSTALL_TIMEOUT_SEC),
# .retryMin (60), .preGateSteps (""), .drainAfterMin (30), .holdStaleMin (120).
# SHARED_INSTALL_CMD replaces the install
# command (tests).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/coordinator-env.sh" || exit 1
. "$SELF_DIR/worktree-lib.sh" || exit 1
. "$SELF_DIR/shared-install-hold.sh" || exit 1

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

# si_age_flags <npmrc> — the flags that lift the project's own age cutoff for a lockfile
# install: --min-release-age=0 when it sets min-release-age, --before=<now> when it sets
# before. Nothing when it sets neither, or there is no .npmrc.
si_age_flags() {
  local f="$1" out=""
  [ -f "$f" ] || return 0
  grep -qE '^[[:space:]]*min-release-age[[:space:]]*=' "$f" && out="--min-release-age=0"
  grep -qE '^[[:space:]]*before[[:space:]]*=' "$f" && out="$out${out:+ }--before=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s' "$out"
}

# si_behind <lock blob> — how many packages the trunk's lock pins that the install does not
# hold at that version (npm's own record, node_modules/.package-lock.json); "?" unreadable.
si_behind() {
  local n
  n=$(git -C "$CLONE" show "$1" 2>/dev/null | jq -n --slurpfile b "$CLONE/node_modules/.package-lock.json" '
        input as $a | [($a.packages // {}) | to_entries[] | select(.key | startswith("node_modules/"))
          | select((($b[0].packages // {})[.key].version // "") != (.value.version // ""))] | length' 2>/dev/null)
  printf '%s' "${n:-?}"
}

# si_loud <lock blob> <why> — the install is behind the trunk and is not being run now.
si_loud() {
  say "⚠ shared install behind the lockfile: $(si_behind "$1") packages, pushes will fail — $2"
}

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
  local age; age=$(si_age_flags "$CLONE/.npmrc")
  printf '%s --- %s%s in %s at %s\n' "$(swarm_stamp)" "${SHARED_INSTALL_CMD:-npm ci --no-audit --no-fund}" "${age:+ $age}" "$CLONE" "$(git_c rev-parse --short HEAD)" >> "$LOGF"
  [ -z "$age" ] || say "the trunk's .npmrc sets an age cutoff; lifted for this lockfile install only ($age): npm ci installs exactly what the lock pins"
  # shellcheck disable=SC2086 # the command and the flags are words on purpose
  (cd "$CLONE" && _si_timeout "$TIMEOUT_SEC" ${SHARED_INSTALL_CMD:-npm ci --no-audit --no-fund} $age) >> "$LOGF" 2>&1 || rc=$?
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
  si_loud "$want" "its install failed ($why)"
  return 1
}

# ---- the check ---------------------------------------------------------------
ON="${SHARED_INSTALL:-$(swarm_opt coordinator.sharedInstall.on 1)}"
TIMEOUT_SEC="${SHARED_INSTALL_TIMEOUT_SEC:-$(( $(swarm_opt coordinator.sharedInstall.timeoutMin 30) * 60 ))}"
RETRY_MIN="$(swarm_opt coordinator.sharedInstall.retryMin 60)"
PRE_GATE=" $(swarm_opt coordinator.sharedInstall.preGateSteps "") "
DRAIN_MIN="$(swarm_opt coordinator.sharedInstall.drainAfterMin 30)"
case "$TIMEOUT_SEC" in ''|*[!0-9]*) TIMEOUT_SEC=1800 ;; esac
case "$DRAIN_MIN" in ''|*[!0-9]*) DRAIN_MIN=30 ;; esac
case "$RETRY_MIN" in ''|*[!0-9]*) RETRY_MIN=60 ;; esac

if [ "${1:-}" = --locked ]; then
  GITDIR=$(git -C "$CLONE" rev-parse --absolute-git-dir 2>/dev/null) || exit 1
  locked_install "$2"; exit $?
fi

# The hold lasts only while an install is pending: every exit lifts it but a wait
# past the drain bound and another install holding the lock.
KEEP_HOLD=0
trap 'coord_shadow || [ "$KEEP_HOLD" = 1 ] || shared_install_hold_clear' EXIT
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
if [ "$have" != "$want" ] && [ "$(git hash-object "$CLONE/package-lock.json" 2>/dev/null)" = "$want" ] \
   && ! bash "$SELF_DIR/link-node-modules.sh" --behind "$CLONE" >/dev/null 2>&1 \
   && [ -f "$CLONE/node_modules/.package-lock.json" ]; then
  if coord_shadow; then say "lock ${want:0:12} checked: the install already matches it — would record it (shadow)"; exit 0; fi
  printf '%s %s %s\n' "$want" "$(git_c rev-parse HEAD 2>/dev/null)" "$(swarm_stamp)" > "$CLONE/node_modules/$STAMP_NAME"
  say "lock ${want:0:12} checked: the install already matches it — recorded, nothing installed"; exit 0
fi
if [ "$have" = "$want" ]; then say "lock ${want:0:12} checked: unchanged — nothing to install"; exit 0; fi
say "lock checked: origin/$BR has ${want:0:12}, the install was made from $(if [ -n "$have" ]; then printf '%s' "${have:0:12}"; else printf 'an unrecorded lock'; fi)"

if [ -f "$FAILED_F" ] && read -r fwant fat < "$FAILED_F" && [ "$fwant" = "$want" ] \
   && [ $(( $(date +%s) - ${fat:-0} )) -lt $(( RETRY_MIN * 60 )) ]; then
  say "the install of this lock failed $(( ($(date +%s) - fat) / 60 )) min ago — tried again ${RETRY_MIN} min after it"
  si_loud "$want" "its install failed; output in $LOGF"; exit 0
fi

# Nothing on this host may be reading the install while it is replaced.
busy=""
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  rid=$(basename "$rec" .json)
  t=$(jq -r '.ticket // empty' "$rec" 2>/dev/null); b=$(jq -r '.builder // empty' "$rec" 2>/dev/null)
  # A tree already on the trunk's lock is failing on the old install: the install is its fix.
  rwt=$(jq -r '.worktree // empty' "${DRIVER_DIR:-$STATE_DIR/driver}/$t/state.json" 2>/dev/null)
  [ -n "$rwt" ] || rwt=$(jq -r '.worktree // empty' "$rec" 2>/dev/null)
  if [ -n "$rwt" ] && [ -f "$rwt/package-lock.json" ] && [ "$(git hash-object "$rwt/package-lock.json" 2>/dev/null)" = "$want" ]; then
    say "$rid (#${t:-?}) is already on the trunk's lock — the install fixes it, so it is not waited for"
    continue
  fi
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
RUNS_BUSY="$busy"
# A process in the clone counts only when it reads node_modules. Shells, git, tail
# and the sessions that start there sit in it all day (measured on the Mac
# 2026-10-21: monitors, a five-day-old git), and counting them never cleared.
if wt_can_see_processes; then
  wt_cwds_load --exclude-self
  for occ in $(wt_occupants "$(wt_real "$CLONE")"); do
    comm=$(ps -o comm= -p "$occ" 2>/dev/null); comm=${comm##*/}; comm=${comm// /}
    case "$comm" in node|npm|npx|pnpm|yarn|bun|tsc|tsx|vitest|jest|playwright|next|eslint)
      busy="$busy${busy:+; }pid $occ ($comm) works in $CLONE" ;;
    esac
  done
fi
# How long this lock has waited, so a host that never falls quiet shows it.
WAITF="$COORD_DIR/shared-install.waiting"
[ -n "$busy" ] || rm -f "$WAITF"
if [ -n "$busy" ]; then
  { [ -f "$WAITF" ] && read -r wwant wat < "$WAITF" && [ "$wwant" = "$want" ]; } || { wat=$(date +%s); printf '%s %s\n' "$want" "$wat" > "$WAITF"; }
  waited=$(( ($(date +%s) - wat) / 60 ))
  # Only builds drain: a hold over a process that is not one would hold for ever.
  if [ "$waited" -ge "$DRAIN_MIN" ] && [ -n "$RUNS_BUSY" ]; then
    KEEP_HOLD=1
    if coord_shadow; then say "waiting $waited min — would hold new starts on this host until the builds drain (shadow)"
    else
      shared_install_hold_set "lock ${want:0:12} has waited $waited min; in use: $busy"
      say "waiting $waited min, past ${DRAIN_MIN} — holding new starts on this host until the builds drain: $busy"
    fi
    si_loud "$want" "the install waits $waited min on builds still on the old lock"
    exit 0
  fi
  say "waiting $waited min — in use on this host: $busy; checked again next pass"
  si_loud "$want" "the install waits on builds still on the old lock"; exit 0
fi

if coord_shadow; then say "would install lock ${want:0:12} (shadow)"; exit 0; fi
# Nothing new starts while the install is set aside; the exit lifts it.
shared_install_hold_set "lock ${want:0:12} is being installed"
_si_flock "$LOCKF" bash "${BASH_SOURCE[0]}" --locked "$want"; rc=$?
[ "$rc" -ne 75 ] || { KEEP_HOLD=1; say "another install holds $LOCKF — checked again next pass"; si_loud "$want" "another install holds the lock"; }
exit 0
