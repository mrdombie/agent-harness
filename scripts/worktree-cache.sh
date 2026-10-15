#!/usr/bin/env bash
# worktree-cache.sh — remove a worktree's build caches, never its files.
#   worktree-cache.sh clean [--idle-min N] [--dry-run] <worktree>...
# Folders: `build.cacheDirs` (globs from the top level), else the usual framework output.
# Kept: a worktree a process sits in; a folder holding a tracked file, resolving outside, or changed within N min.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/worktree-lib.sh"

DEFAULT_DIRS=".next .turbo .nuxt .svelte-kit .parcel-cache"

[ "${1:-}" = clean ] || { echo "usage: worktree-cache.sh clean [--idle-min N] [--dry-run] <worktree>..." >&2; exit 2; }
shift
IDLE=0 DRY=0 TREES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --idle-min) IDLE="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -*) echo "worktree-cache: unknown flag '$1'" >&2; exit 2 ;;
    *) TREES+=("$1"); shift ;;
  esac
done
case "$IDLE" in ''|*[!0-9]*) echo "worktree-cache: --idle-min needs a number of minutes" >&2; exit 2 ;; esac
[ ${#TREES[@]} -gt 0 ] || exit 0

if ! wt_can_see_processes; then
  echo "worktree-cache: no lsof here — cannot tell who is using a worktree, cleaning nothing"
  exit 0
fi
wt_cwds_load

patterns() { # <worktree>
  local cfg="${HARNESS_CFG_PATH:-$1/.claude/harness.json}" got d
  got=$(wt_cfg "$cfg" '.build.cacheDirs')
  if [ -n "$got" ]; then printf '%s\n' "$got"; return; fi
  for d in $DEFAULT_DIRS; do printf '%s\n%s\n%s\n' "$d" "apps/*/$d" "packages/*/$d"; done
}

cleaned=0 kept=0 freed_kb=0
for wt in "${TREES[@]}"; do
  [ -d "$wt" ] || { echo "skip $wt — no such directory"; continue; }
  real=$(wt_real "$wt")
  top=$(git -C "$real" rev-parse --show-toplevel 2>/dev/null) && top=$(wt_real "$top")
  [ "${top:-}" = "$real" ] || { echo "skip $wt — not the top level of a checkout"; continue; }
  if pid=$(wt_occupant "$real"); then
    echo "keep $wt — in use (pid $pid has its cwd there)"; kept=$((kept+1)); continue
  fi
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    case "$pat" in /*|*..*) echo "skip pattern '$pat' — must stay inside the worktree"; continue ;; esac
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      abs="$real/$d"
      [ -d "$abs" ] || continue
      case "$(wt_real "$abs")/" in "$real"/*) ;; *) echo "keep $d — resolves outside the worktree"; continue ;; esac
      if ! tracked=$(git -C "$real" ls-files -- "$d" 2>/dev/null); then
        echo "keep $d — git could not list its files"; kept=$((kept+1)); continue
      fi
      [ -z "$tracked" ] || { echo "keep $d — holds tracked files"; kept=$((kept+1)); continue; }
      if [ "$IDLE" -gt 0 ] && [ -n "$(find "$abs" -mmin "-$IDLE" -print -quit 2>/dev/null)" ]; then
        echo "keep $d — changed in the last $IDLE min"; kept=$((kept+1)); continue
      fi
      kb=$(du -sk "$abs" 2>/dev/null | awk '{print $1}'); kb=${kb:-0}
      if [ "$DRY" = 1 ]; then
        echo "would clean $d in $wt ($((kb/1024)) MB)"
      else
        rm -rf "$abs" && echo "cleaned $d in $wt ($((kb/1024)) MB)"
      fi
      cleaned=$((cleaned+1)); freed_kb=$((freed_kb+kb))
    done <<<"$(cd "$real" && shopt -s nullglob && for m in $pat; do printf '%s\n' "$m"; done)"
  done <<<"$(patterns "$real")"
done
echo "cache pass$([ "$DRY" = 1 ] && echo ' (dry run)'): cleaned=$cleaned kept=$kept freed=$((freed_kb/1024))MB"
