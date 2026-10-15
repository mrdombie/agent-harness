#!/usr/bin/env bash
# sweep-orphan-worktrees.sh — remove the worktrees nothing needs, clean the caches of the rest.
#   sweep-orphan-worktrees.sh [--apply] [--caches-only]
# Considers every registered worktree under the worktree root and the temp dirs, whatever its name.
# Removed only with: no claim on a ticket its folder or branch names, no process inside,
# untouched for SWEEP_WORKTREE_HOURS (24), a clean tree, and every commit on a remote.
# Every worktree it keeps gets the cache pass (worktree-cache.sh, idle `build.cacheIdleMin`, 30).
set -uo pipefail

APPLY=0 CACHES_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --caches-only) CACHES_ONLY=1 ;;
    *) echo "unknown argument: $arg (--apply, --caches-only)" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/toolkit-env.sh" || exit 1
. "$HERE/worktree-lib.sh"

THRESHOLD_HOURS="${SWEEP_WORKTREE_HOURS:-24}"
IDLE_MIN="${SWEEP_CACHE_IDLE_MIN:-$(toolkit_cfg build.cacheIdleMin 2>/dev/null || echo 30)}"
CLAIMS_DIR="$STATE_DIR/claims"

ROOTS=()
if [ -n "${SWEEP_WORKTREE_ROOTS:-}" ]; then
  IFS=: read -r -a ROOTS <<<"$SWEEP_WORKTREE_ROOTS"
else
  r=$(toolkit_worktree_root 2>/dev/null) && ROOTS+=("$r")
  ROOTS+=("${TMPDIR:-/tmp}" /private/tmp /tmp)
fi
REAL_ROOTS=()
for r in "${ROOTS[@]}"; do [ -d "$r" ] && REAL_ROOTS+=("$(wt_real "$r")"); done
under_root() { local r; for r in "${REAL_ROOTS[@]}"; do case "$1/" in "$r"/*) return 0 ;; esac; done; return 1; }

# The first entry is the main checkout (or the bare store): never a candidate.
WORKTREES=()
while IFS= read -r wt; do
  [ -n "$wt" ] && [ -d "$wt" ] || continue
  under_root "$(wt_real "$wt")" && WORKTREES+=("$wt")
done < <(git -C "$MAIN_REPO" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | tail -n +2 | sort -u)
[ ${#WORKTREES[@]} -gt 0 ] || { echo "Sweep: no worktrees under ${REAL_ROOTS[*]:-no root}"; exit 0; }

cache_pass() { # <worktree>...
  [ $# -gt 0 ] || return 0
  if [ "$APPLY" = 1 ]; then bash "$HERE/worktree-cache.sh" clean --idle-min "$IDLE_MIN" "$@"
  else bash "$HERE/worktree-cache.sh" clean --idle-min "$IDLE_MIN" --dry-run "$@"; fi
}

if [ "$CACHES_ONLY" = 1 ]; then
  cache_pass "${WORKTREES[@]}"
  exit 0
fi

CLAIMS_OK=1
CLAIM_REFS=$(perl -e 'alarm shift; exec @ARGV' 20 git -C "$MAIN_REPO" ls-remote origin 'refs/claims/*' 2>/dev/null) || CLAIMS_OK=0
SEE=1; wt_can_see_processes && wt_cwds_load || SEE=0

ticket_of() { printf '%s' "$1" | sed -n 's/^[A-Za-z_]*-\{0,1\}\([0-9][0-9]*\).*/\1/p'; }

claim_on() { # <worktree> — echoes what claims it
  local n src form
  for src in "$(basename "$1")" "$(git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null)"; do
    n=$(ticket_of "$src"); [ -n "$n" ] || continue
    for form in "$n" "#$n"; do
      [ -d "$CLAIMS_DIR/$form.lock" ] && { echo "lockfile $form.lock"; return 0; }
    done
    grep -q "refs/claims/$n\$" <<<"$CLAIM_REFS" && { echo "refs/claims/$n on origin"; return 0; }
  done
  return 1
}

mtime_of() {
  if stat --version >/dev/null 2>&1; then stat -c %Y "$1" 2>/dev/null; else stat -f %m "$1" 2>/dev/null; fi
}

now=$(date -u +%s); threshold=$(( THRESHOLD_HOURS * 3600 ))
removed=0 KEPT=()
keep() { echo "keep    $(basename "$1") — $2"; KEPT+=("$1"); }

for wt in "${WORKTREES[@]}"; do
  real=$(wt_real "$wt")
  [ "$CLAIMS_OK" = 1 ] || { keep "$wt" "claims could not be read from origin"; continue; }
  if why=$(claim_on "$wt"); then keep "$wt" "live claim ($why)"; continue; fi
  [ "$SEE" = 1 ] || { keep "$wt" "cannot see processes (no lsof)"; continue; }
  if pid=$(wt_occupant "$real"); then keep "$wt" "in use (pid $pid)"; continue; fi
  m=$(mtime_of "$wt"); case "$m" in ''|*[!0-9]*) keep "$wt" "unreadable (cannot stat)"; continue ;; esac
  [ $(( now - m )) -ge "$threshold" ] || { keep "$wt" "younger than ${THRESHOLD_HOURS}h"; continue; }
  git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || { keep "$wt" "unreadable (no readable git dir)"; continue; }
  status=$(git -C "$wt" status --porcelain 2>/dev/null) || { keep "$wt" "unreadable (git status failed)"; continue; }
  [ -z "$status" ] || { keep "$wt" "uncommitted changes"; continue; }
  orphans=$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null) || { keep "$wt" "unreadable (rev-list failed)"; continue; }
  [ "$orphans" = 0 ] || { keep "$wt" "$orphans commit(s) on no remote"; continue; }

  if [ "$APPLY" = 0 ]; then
    echo "would remove  $(basename "$wt") — no claim, nobody inside, clean, fully pushed"
    removed=$((removed+1)); continue
  fi
  if git -C "$MAIN_REPO" worktree remove --force "$wt" >/dev/null 2>&1; then
    echo "remove  $(basename "$wt") — no claim, nobody inside, clean, fully pushed"
    removed=$((removed+1))
  else
    keep "$wt" "git worktree remove refused it"
  fi
done

if [ "$APPLY" = 0 ]; then
  echo "Sweep (dry run): kept=${#KEPT[@]} would-remove=$removed — pass --apply to delete"
else
  echo "Sweep complete: kept=${#KEPT[@]} removed=$removed"
fi
cache_pass ${KEPT[@]+"${KEPT[@]}"}
