#!/usr/bin/env bash
# worktree-sparse.sh — cut an agent worktree that leaves `worktree.sparseExclude` folders out.
#   worktree-sparse.sh add <repo> <worktree> [git worktree add arguments...]
#   worktree-sparse.sh add-flag <worktree>     prints --sparse when the tree is sparse
# Off when nothing is configured: a plain `git worktree add`.
# Hazard: in a sparse tree `git add` refuses new files under an excluded folder without --sparse.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/worktree-lib.sh"

case "${1:-}" in
  add-flag)
    [ "$(git -C "${2:?worktree-sparse: add-flag needs a worktree}" config --get core.sparseCheckout 2>/dev/null)" = true ] && echo --sparse
    exit 0 ;;
  add) ;;
  *) echo "usage: worktree-sparse.sh add <repo> <worktree> [args...] | add-flag <worktree>" >&2; exit 2 ;;
esac
REPO="${2:?worktree-sparse: need a repo}"; WT="${3:?worktree-sparse: need a worktree path}"; shift 3

# A new branch cut from origin/<trunk> would track the trunk, and a bare push would land there.
case " $* " in *" --track "*|*" --no-track "*) ;; *" -b "*|*" -B "*) set -- --no-track "$@" ;; esac

CFG="${HARNESS_CFG_PATH:-${HARNESS_CFG:-$REPO/.claude/harness.json}}"
PATTERNS=('/*')
while IFS= read -r p; do
  [ -n "$p" ] || continue
  p="${p%/}"; p="${p#./}"
  case "$p" in /*|*..*|'!'*|'') echo "worktree-sparse: ignoring '$p' — a folder inside the worktree, relative to its top level" >&2; continue ;; esac
  PATTERNS+=("!/$p/")
done <<<"$(wt_cfg "$CFG" '.worktree.sparseExclude')"

if [ ${#PATTERNS[@]} -eq 1 ]; then
  exec git -C "$REPO" worktree add "$WT" "$@"
fi

git -C "$REPO" worktree add --no-checkout "$WT" "$@" || exit 1
if git -C "$WT" sparse-checkout set --no-cone "${PATTERNS[@]}" >/dev/null 2>&1 \
   && git -C "$WT" checkout -q 2>/dev/null && git -C "$WT" read-tree -mu HEAD 2>/dev/null; then
  echo "worktree-sparse: $WT leaves out ${PATTERNS[*]:1}" >&2
  exit 0
fi
echo "worktree-sparse: the sparse checkout failed — checking out the whole tree instead" >&2
git -C "$WT" sparse-checkout disable >/dev/null 2>&1
git -C "$WT" read-tree -mu HEAD
