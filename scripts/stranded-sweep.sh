#!/usr/bin/env bash
# stranded-sweep.sh — commits that sit in one host's worktree and nowhere on origin
# go to origin as a stranded ref (driver/stranded.sh), with nobody asking.
#
#   stranded-sweep.sh           one sweep, at most every coordinator.strandedSweepEveryMin (60)
#   stranded-sweep.sh --force   now, whatever the last sweep's age
#   COORDINATOR_SHADOW=0 …      act for real; anything else says what it would push
#
# Since 0.7.145 a park pushes its work to refs/stranded/<ticket>/<host>-<utc>. A worktree
# left before that, or by a run that died, can still hold the only copy of its
# commits. This walks every worktree of the shared clone under the worktree root and
# pushes one whose HEAD has commits on none of: its upstream, origin's copy of its
# branch, origin/<integrationBranch>, any refs/stranded ref. A tree whose changed
# files already read the same on the integration branch (squash-merged) is left.
# Never a tree a live run on this host holds (worktree-lib.sh); nothing is deleted,
# moved or checked out — it only reads trees and pushes refs. Each push is logged.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/coordinator-env.sh" || exit 1
. "$SELF_DIR/worktree-lib.sh" || exit 1
. "$SELF_DIR/../driver/stranded.sh" || exit 1

say() { printf '%s stranded sweep: %s\n' "$(date +%H:%M:%S)" "$*"; swarm_log "$COORD_LOG" "stranded sweep: $*"; }

STAMP="$COORD_DIR/stranded-sweep.stamp"
EVERY="${STRANDED_SWEEP_EVERY_MIN:-$(swarm_opt coordinator.strandedSweepEveryMin 60)}"
case "$EVERY" in ''|*[!0-9]*) EVERY=60 ;; esac
if [ "${1:-}" != --force ] && [ -f "$STAMP" ] && [ $(( $(date +%s) - $(coord_mtime "$STAMP") )) -lt $(( EVERY * 60 )) ]; then
  exit 0
fi
BR="${INTEGRATION_BRANCH:-develop}"
# STRANDED_SWEEP_ROOT names another root (tests: theirs sit in the temp dir toolkit refuses).
ROOT="${STRANDED_SWEEP_ROOT:-}"
[ -n "$ROOT" ] || ROOT=$(toolkit_worktree_root 2>/dev/null) || { say "the worktree root could not be resolved — skipped"; exit 0; }
[ -d "$ROOT" ] || { touch "$STAMP"; say "no worktree root at $ROOT — nothing to sweep"; exit 0; }
ROOT=$(wt_real "$ROOT"); MAIN_REAL=$(wt_real "$MAIN_REPO")

# <path>\t<branch> for each worktree of the shared clone under the root.
TREES=$(git -C "$MAIN_REPO" worktree list --porcelain 2>/dev/null | awk '
  /^worktree / { if (p != "") print p "\t" b; p = substr($0, 10); b = "" }
  /^branch /   { b = substr($0, 8); sub(/^refs\/heads\//, "", b) }
  END          { if (p != "") print p "\t" b }')
CANDS=""
while IFS=$'\t' read -r p b; do
  [ -n "$p" ] && [ -d "$p" ] || continue
  r=$(wt_real "$p")
  [ "$r" != "$MAIN_REAL" ] || continue
  case "$r/" in "$ROOT"/*) CANDS="$CANDS$r"$'\t'"$b"$'\n' ;; esac
done <<<"$TREES"
[ -n "$CANDS" ] || { touch "$STAMP"; say "no worktrees under $ROOT"; exit 0; }

# One fetch: the trunk, every stranded ref, and each tree's branch that origin has.
REMOTE=$(cd / && perl -e 'alarm shift; exec @ARGV' 60 git -C "$MAIN_REPO" ls-remote origin 'refs/heads/*' 2>/dev/null) \
  || { say "origin could not be read — next sweep"; exit 0; }
specs=("+refs/heads/$BR:refs/remotes/origin/$BR" "+refs/stranded/*:refs/remotes/origin/stranded/*")
while IFS=$'\t' read -r r b; do
  [ -n "$b" ] && awk -v r="refs/heads/$b" '$2 == r { f = 1 } END { exit !f }' <<<"$REMOTE" && specs+=("+refs/heads/$b:refs/remotes/origin/$b")
done <<<"$CANDS"
(cd / && perl -e 'alarm shift; exec @ARGV' 300 git -C "$MAIN_REPO" fetch -q origin "${specs[@]}") >/dev/null 2>&1 \
  || { say "the fetch from origin failed — nothing judged, next sweep"; exit 0; }

seen=0 clean=0 pushed=0 held=0 merged=0
while IFS=$'\t' read -r wt b; do
  [ -n "$wt" ] || continue
  seen=$((seen+1))
  head=$(git -C "$wt" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || { say "$wt: its HEAD cannot be read — left"; continue; }
  if rid=$(wt_run_holder "$wt"); then held=$((held+1)); say "$wt: held by live run $rid — untouched"; continue; fi
  nots=("refs/remotes/origin/$BR")
  up=$(git -C "$wt" rev-parse -q --verify '@{upstream}' 2>/dev/null) && nots+=("$up")
  [ -n "$b" ] && git -C "$wt" rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null 2>&1 && nots+=("refs/remotes/origin/$b")
  n=$(git -C "$wt" rev-list --count "$head" --not "${nots[@]}" --glob='refs/remotes/origin/stranded/*' 2>/dev/null) \
    || { say "$wt: its commits could not be compared with origin — left"; continue; }
  [ "$n" -gt 0 ] || { clean=$((clean+1)); continue; }
  # Squash-merged: every file the commits changed already reads the same on the trunk.
  base=$(git -C "$wt" merge-base "$head" "refs/remotes/origin/$BR" 2>/dev/null)
  if [ -n "$base" ]; then
    files=$(git -C "$wt" diff --name-only "$base" "$head" 2>/dev/null)
    if [ -z "$files" ] || printf '%s\n' "$files" | tr '\n' '\0' | (cd "$wt" && xargs -0 git diff --quiet "$head" "refs/remotes/origin/$BR" -- 2>/dev/null); then
      merged=$((merged+1)); continue
    fi
  fi
  t=$(branch_ticket "$b" 2>/dev/null); [ -n "$t" ] || t=$(wt_ticket_of "${wt##*/}"); [ -n "$t" ] || t=$(wt_ticket_of "$b")
  if [ -z "$t" ]; then say "$wt: $n commit(s) on no ref of origin, but no ticket in its branch '${b:-detached}' or folder — not pushed (a stranded ref names one)"; continue; fi
  if coord_shadow; then say "would push $n commit(s) from $wt (#$t, ${b:-detached}) to refs/stranded/$t/ (shadow)"; continue; fi
  if driver_stranded_push "$t" "$wt" "$head"; then
    # Known here at once, so the next sweep does not push the same commits again.
    git -C "$MAIN_REPO" update-ref "refs/remotes/origin/${DRIVER_STRANDED_REF#refs/}" "$head" 2>/dev/null || true
    pushed=$((pushed+1)); say "pushed $n commit(s) from $wt (#$t, ${b:-detached}) to $DRIVER_STRANDED_REF"
  else
    say "$wt: $n commit(s) on no ref of origin, and the push failed: $DRIVER_STRANDED_WHY"
  fi
done <<<"$CANDS"
touch "$STAMP"
say "$seen worktree(s) under $ROOT: $pushed pushed, $clean already on origin, $merged already on $BR, $held held by a live run"
exit 0
