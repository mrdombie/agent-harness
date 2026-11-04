#!/usr/bin/env bash
# Prune the worktree registrations whose directories are gone, when a session ends.
#
# The rest of what this hook did — kill `next dev` servers rooted in deleted directories
# and delete their .next caches — is gone: the driver starts each builder's dev server in
# a process group of its own and stops it when the step and the run end
# (scripts/builder-dev.sh), and the run's exit removes the tree's caches and install
# (spawn-claim.sh). Removing worktrees is scripts/sweep-orphan-worktrees.sh's job.
set -uo pipefail
LOG=/tmp/claude-session-cleanup.log
repo="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || exit 0
before=$(git -C "$repo" worktree list 2>/dev/null | wc -l | tr -d ' ')
git -C "$repo" worktree prune 2>/dev/null
after=$(git -C "$repo" worktree list 2>/dev/null | wc -l | tr -d ' ')
[ "$before" != "$after" ] && echo "── $(date -u +%FT%TZ) session-end: pruned $((before-after)) dead worktree registration(s)" >> "$LOG"
exit 0
