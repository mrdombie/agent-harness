#!/usr/bin/env bash
# disk-guard.sh — nothing new starts on a nearly full disk, and the disk is freed until it is back.
#
#   disk-guard.sh free               free GB on the state volume, a whole number
#   disk-guard.sh host               the Windows drive also read under WSL (empty elsewhere)
#   disk-guard.sh limits             "<stopBelowGb> <resumeAtGb>"
#   disk-guard.sh check [<what>]     exit 1, saying why, below stopBelowGb: a long one-off job asks first
#   disk-guard.sh tick               the coordinator's hold, printed "<free>\t<line>"; exit 1 while held.
#                                    Held from under stopBelowGb until resumeAtGb is free, not on the first GB back.
#   disk-guard.sh clean [--apply]    free space pass by pass until resumeAtGb is free; a dry run without --apply
#
# Owner call 2026-10-20, "Auto-clean and stop below 30 GB": the data volume reached 0.1 GB free and
# no build, session or coordinator tick could start a shell.
#
# The clean, in this order, stopping as soon as resumeAtGb is free:
#   a. driver-proof-* in the temp dir     the two trees of a red/green proof
#   b. harness-spawn-* in the temp dir    never the newest: the one spawns start in now
#   c. node_modules, dist and build caches in idle build folders (worktree-cache.sh --deep);
#      the next start relinks or reinstalls them (link-node-modules.sh)
#   d. the orphan-worktree sweep, sweep-orphan-worktrees.sh --apply
#   e. folders over 500 MB in Claude session scratchpads (<root>/<project>/<session>/scratchpad/*)
# Never removed: anything a live process has open or its cwd in, anything a live run's record names,
# any checkout a claim on any host holds (its worktree, branch or ticket), anything changed in the last
# 30 min (scratchpads: 60), and anything holding a git checkout with an uncommitted change whose content
# git does not already hold, or a commit no remote and no other branch holds. Without lsof nobody can
# tell who is using what, and without the claim list nobody can tell whose a tree is: nothing goes.
#
# Settings (harness.json, or the env var):
#   coordinator.disk.stopBelowGb   COORDINATOR_DISK_STOP_BELOW_GB   30
#   coordinator.disk.resumeAtGb    COORDINATOR_DISK_RESUME_AT_GB    50   (never under stopBelowGb)
#   coordinator.disk.hostPath      COORDINATOR_DISK_HOST_PATH       /mnt/c  (WSL only)
# Under WSL, Linux's df reads the virtual disk, which can show 831 GB free while the Windows drive
# holding it has 37; the guard reads both and works from the lower, saying which bound.
# Seams: COORDINATOR_DF (a command printing free GB), COORDINATOR_FREE_GB, DISK_GUARD_PROC (/proc), DISK_GUARD_TMP,
#   DISK_GUARD_BUILD_ROOT, DISK_GUARD_SCRATCH_ROOT, DISK_GUARD_SWEEP, DISK_GUARD_HOLD_FILE,
#   DISK_GUARD_RECENT_MIN (30), DISK_GUARD_SCRATCH_MIN (60), DISK_GUARD_SCRATCH_MB (500).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The kit's config when there is one; the defaults when there is not. A guard that cannot start is no guard.
KIT_OK=0
if . "$HERE/toolkit-env.sh" >/dev/null 2>&1; then KIT_OK=1; fi
. "$HERE/worktree-lib.sh"
cd / || exit 1

cfg() { local v=""; [ "$KIT_OK" = 1 ] && v=$(toolkit_cfg "$1" 2>/dev/null); printf '%s' "${v:-$2}"; }
whole() { case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }

STOP_GB=$(whole "${COORDINATOR_DISK_STOP_BELOW_GB:-$(cfg coordinator.disk.stopBelowGb 30)}" 30)
RESUME_GB=$(whole "${COORDINATOR_DISK_RESUME_AT_GB:-$(cfg coordinator.disk.resumeAtGb 50)}" 50)
[ "$RESUME_GB" -ge "$STOP_GB" ] || RESUME_GB=$STOP_GB
RECENT_MIN=$(whole "${DISK_GUARD_RECENT_MIN:-30}" 30)
SCRATCH_MIN=$(whole "${DISK_GUARD_SCRATCH_MIN:-60}" 60)
SCRATCH_MB=$(whole "${DISK_GUARD_SCRATCH_MB:-500}" 500)
STATE="${STATE_DIR:-}"
HOLD_FILE="${DISK_GUARD_HOLD_FILE:-${COORDINATOR_DIR:-${STATE:-$HOME/.harness-state}/coordinator}/disk-hold}"
TMP_ROOT="${DISK_GUARD_TMP:-${TMPDIR:-/tmp}}"; TMP_ROOT="${TMP_ROOT%/}"
if [ -n "${DISK_GUARD_SCRATCH_ROOT:-}" ]; then SCRATCH_ROOT="$DISK_GUARD_SCRATCH_ROOT"
elif [ -d "/private/tmp/claude-$(id -u)" ]; then SCRATCH_ROOT="/private/tmp/claude-$(id -u)"
else SCRATCH_ROOT="/tmp/claude-$(id -u)"; fi
SWEEP="${DISK_GUARD_SWEEP:-$HERE/sweep-orphan-worktrees.sh}"

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
  clean) ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac

# ---- clean ---------------------------------------------------------------------
APPLY=0
for a in "$@"; do case "$a" in --apply) APPLY=1 ;; *) echo "disk-guard clean: unknown argument $a" >&2; exit 2 ;; esac; done
say() { printf '%s disk-clean: %s\n' "$(date +%H:%M:%S)" "$*"; }

LOCK="$HOLD_FILE.clean.lock"
mkdir -p "$(dirname "$LOCK")" 2>/dev/null
if ! mkdir "$LOCK" 2>/dev/null; then
  owner=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then say "a clean is already running (pid $owner)"; exit 0; fi
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || { say "could not take the lock $LOCK"; exit 0; }
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

read_free || { say "free space could not be read — cleaning nothing"; exit 0; }
FREE=$FREE_NOW
START_FREE=$FREE
if ! wt_can_see_processes; then say "no lsof here — cannot tell who is using what, cleaning nothing"; exit 0; fi
CLAIM_REPO="${MAIN_REPO:-${HARNESS_MAIN_REPO:-}}"
if ! wt_claims_load "$CLAIM_REPO"; then say "the claim list could not be read${CLAIM_REPO:+ from $CLAIM_REPO} — cannot tell whose a tree is, cleaning nothing"; exit 0; fi
say "$FREE GB free$FREE_WHERE, cleaning until $RESUME_GB GB$([ "$APPLY" = 1 ] || echo ' (dry run: nothing is removed)')"
enough() { [ "$APPLY" = 1 ] && [ "$FREE" -ge "$RESUME_GB" ]; }

# Every open file and cwd of every process, as "<pid>\t<path>": read again at each pass.
OPEN=""
load_open() { OPEN=$(cd / && lsof -nP -Fpn 2>/dev/null | awk '/^p/{p=substr($0,2)} /^n\//{print p "\t" substr($0,2)}'); }
holder() { # <real-dir> — the pid with a file open or its cwd inside it
  printf '%s\n' "$OPEN" | awk -F'\t' -v root="$1/" 'index($2 "/", root) == 1 { print $1; found = 1; exit } END { exit !found }'
}
recent() { wt_recent "$@"; }   # <dir> <min> — a find that errors counts as recent
# A change is lost only when git does not already hold its content. A proof tree carries a copy
# of a committed test; a plant does not, and a deleted file is never held.
lost_work() { # <checkout> — prints why and returns 0 when removing it would lose work
  local c="$1" st n line path
  st=$(git -C "$c" status --porcelain --untracked-files=all 2>/dev/null) || { printf 'git status failed'; return 0; }
  if [ -n "$st" ]; then
    n=$(printf '%s\n' "$st" | wc -l | tr -d ' ')
    [ "$n" -le 200 ] || { printf '%s uncommitted changes' "$n"; return 0; }
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      path=${line:3}; case "$path" in *' -> '*) path=${path##* -> } ;; esac
      [ -f "$c/$path" ] && [ ! -L "$c/$path" ] || { printf 'uncommitted change: %s' "$path"; return 0; }
      git -C "$c" cat-file -e "$(git -C "$c" hash-object "$path" 2>/dev/null)" 2>/dev/null \
        || { printf 'uncommitted change: %s' "$path"; return 0; }
    done <<<"$st"
  fi
  n=$(git -C "$c" rev-list --count HEAD --not --remotes 2>/dev/null) || { printf 'git could not list its commits'; return 0; }
  [ "$n" = 0 ] && return 1
  # A detached head that a branch still holds loses nothing when the tree goes.
  if ! git -C "$c" symbolic-ref -q HEAD >/dev/null 2>&1 \
     && [ -n "$(git -C "$c" for-each-ref --contains HEAD --count=1 refs/heads refs/tags 2>/dev/null)" ]; then
    return 1
  fi
  printf '%s commit(s) on no remote' "$n"; return 0
}
checkouts_in() { # <dir> — every git checkout at or under it, node_modules left out
  find "$1" -maxdepth 4 -name node_modules -prune -o -name .git -print 2>/dev/null | while IFS= read -r g; do dirname "$g"; done
}
# kept_why <dir> <recent-min> — why it must stay, or 1 when it may go.
kept_why() {
  local d="$1" real pid why c
  real=$(wt_real "$d")
  if pid=$(holder "$real"); then printf 'in use (pid %s has a file or its cwd there)' "$pid"; return 0; fi
  if why=$(wt_run_holder "$real"); then printf 'a live run holds it (%s)' "$why"; return 0; fi
  if recent "$d" "$2"; then printf 'changed in the last %s min' "$2"; return 0; fi
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    why=$(wt_claim_holder "$c"); case $? in
      0) printf '%s on %s' "$why" "${c#"$d"/}"; return 0 ;;
      2) printf 'the claims for %s could not be read' "${c#"$d"/}"; return 0 ;;
    esac
    if why=$(lost_work "$c"); then printf '%s in %s' "$why" "${c#"$d"/}"; return 0; fi
  done <<<"$(checkouts_in "$d")"
  return 1
}
size_of() { du -sk "$1" 2>/dev/null | awk '{ kb = $1; if (kb >= 1048576) printf "%.1f GB", kb/1048576; else printf "%d MB", kb/1024 }'; }
remove() { # <dir> <label> — removes it (or says it would), logging its size and the free space around it
  local d="$1" size before common="" c
  size=$(size_of "$d"); before=$FREE
  if [ "$APPLY" != 1 ]; then say "would remove $2 $d ($size)"; return 0; fi
  # The repos that registered a worktree inside it, so their records are pruned once it is gone.
  while IFS= read -r c; do
    [ -n "$c" ] && [ -f "$c/.git" ] || continue
    common="$common$(git -C "$c" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"$'\n'
  done <<<"$(checkouts_in "$d")"
  rm -rf "$d"
  [ "${d##*/harness-spawn-*}" = "$d" ] || rm -f "$d.ready"
  while IFS= read -r c; do [ -n "$c" ] && git --git-dir="$c" worktree prune >/dev/null 2>&1; done <<<"$common"
  FREE=$(free_now) || FREE=$before
  say "removed $2 $d ($size) — $before GB free before, $FREE GB after"
}
keep() { say "keep $1 — $2"; }
newest_dir() { # <glob…> — the most recently changed directory of them
  local d best="" bm=0 m
  for d in "$@"; do
    [ -d "$d" ] || continue
    m=$(if stat --version >/dev/null 2>&1; then stat -c %Y "$d"; else stat -f %m "$d"; fi 2>/dev/null)
    case "$m" in ''|*[!0-9]*) continue ;; esac
    [ "$m" -gt "$bm" ] && { bm=$m; best=$d; }
  done
  printf '%s' "$best"
}
done_now() { enough && { say "$FREE GB free, at or above $RESUME_GB GB — stopping (from $START_FREE GB)"; exit 0; }; return 1; }

# ---- a. finished driver proofs ---------------------------------------------------------
load_open
for d in "$TMP_ROOT"/driver-proof-*; do
  [ -d "$d" ] || continue; done_now
  if why=$(kept_why "$d" "$RECENT_MIN"); then keep "$d" "$why"; continue; fi
  remove "$d" "driver proof"
done

# ---- b. spawn checkouts nothing uses ---------------------------------------------------
load_open
CURRENT=$(newest_dir "$TMP_ROOT"/harness-spawn-*)
for d in "$TMP_ROOT"/harness-spawn-*; do
  [ -d "$d" ] || continue; done_now
  [ "$d" = "$CURRENT" ] && { keep "$d" "the current spawn checkout"; continue; }
  [ -d "$d.lock" ] && { keep "$d" "being checked out"; continue; }
  if why=$(kept_why "$d" "$RECENT_MIN"); then keep "$d" "$why"; continue; fi
  remove "$d" "spawn checkout"
done

# ---- c. the installs and caches of idle build folders ----------------------------------
BUILD_ROOT="${DISK_GUARD_BUILD_ROOT:-}"
[ -n "$BUILD_ROOT" ] || { [ "$KIT_OK" = 1 ] && BUILD_ROOT=$(toolkit_worktree_root 2>/dev/null); }
if [ -n "$BUILD_ROOT" ] && [ -d "$BUILD_ROOT" ]; then
  load_open
  for d in "$BUILD_ROOT"/*; do
    [ -e "$d/.git" ] || continue; done_now
    if why=$(kept_why "$d" "$RECENT_MIN"); then keep "$d" "$why"; continue; fi
    before=$FREE
    if [ "$APPLY" = 1 ]; then out=$(bash "$HERE/worktree-cache.sh" clean --deep --idle-min "$RECENT_MIN" "$d" 2>&1)
    else out=$(bash "$HERE/worktree-cache.sh" clean --deep --idle-min "$RECENT_MIN" --dry-run "$d" 2>&1); fi
    printf '%s\n' "$out" | grep -E '^(would clean|cleaned) ' | while IFS= read -r l; do say "$l"; done
    FREE=$(free_now) || FREE=$before
    [ "$APPLY" = 1 ] && printf '%s\n' "$out" | grep -q '^cleaned ' && say "build folder $d — $before GB free before, $FREE GB after"
  done
else
  say "no build folder root — pass c skipped"
fi

# ---- d. the orphan-worktree sweep ------------------------------------------------------
done_now
before=$FREE
if [ "$APPLY" = 1 ]; then bash "$SWEEP" --apply 2>&1 | sed "s/^/$(date +%H:%M:%S) disk-clean: sweep: /"
else bash "$SWEEP" 2>&1 | sed "s/^/$(date +%H:%M:%S) disk-clean: sweep (dry): /"; fi
FREE=$(free_now) || FREE=$before
say "orphan-worktree sweep — $before GB free before, $FREE GB after"

# ---- e. stale large folders in Claude session scratchpads ------------------------------
load_open
for d in "$SCRATCH_ROOT"/*/*/scratchpad/*; do
  [ -d "$d" ] && [ ! -L "$d" ] || continue; done_now
  kb=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
  [ "${kb:-0}" -gt $(( SCRATCH_MB * 1024 )) ] || continue
  if why=$(kept_why "$d" "$SCRATCH_MIN"); then keep "$d" "$why"; continue; fi
  remove "$d" "scratchpad folder"
done

done_now
say "$FREE GB free after every pass (from $START_FREE GB)$([ "$APPLY" = 1 ] && [ "$FREE" -lt "$RESUME_GB" ] && echo " — still under $RESUME_GB GB")"
exit 0
