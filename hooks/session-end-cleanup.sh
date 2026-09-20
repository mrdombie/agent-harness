#!/usr/bin/env bash
# Clean up what a finished session leaves behind.
#
# WHY: nothing owned this. Measured 2026-08-19 on Dom's MacBook: 110 registered
# worktrees (28 already dead), 50 orphan `next dev` servers, and 159 GB of
# Turbopack caches — 130 GB of it in ONE directory, held open by servers from a
# session closed hours earlier. Disk was 86% full.
#
# Claude Code cleans up worktrees IT creates, but `-p` runs have no exit prompt
# and these are created by our own scripts with `git worktree add`, so they sit
# outside that lifecycle entirely.
#
# DELIBERATELY CONSERVATIVE. Three actions, each provably safe on its own:
#   1. kill `next dev` servers whose working directory no longer exists — a
#      process rooted in a deleted directory cannot be serving anyone
#   2. delete .next caches in worktrees that are GONE from disk
#   3. `git worktree prune` — removes registrations whose directory is missing
#
# It does NOT remove worktrees. scripts/sweep-orphan-worktrees.sh already does
# that correctly (claim-free AND clean AND no unpushed commits, keeping anything
# unreadable), and it earned those rules: dirty-only called 27 of 34 safe, and
# adding the unpushed-commit test cut that to 18 — saving one worktree with six
# commits that existed nowhere else. Deleting worktrees is that script's job,
# run deliberately, not a hook's job run automatically.
set -uo pipefail
LOG=/tmp/claude-session-cleanup.log
{ echo "── $(date -u +%FT%TZ) session-end cleanup"; } >> "$LOG"

killed=0
for p in $(pgrep -f "next-server|next dev" 2>/dev/null); do
  d=$(lsof -a -p "$p" -d cwd -Fn 2>/dev/null | grep '^n' | cut -c2-)
  [ -n "$d" ] && [ ! -d "$d" ] && { kill "$p" 2>/dev/null && killed=$((killed+1)); }
done
[ "$killed" -gt 0 ] && echo "  stopped $killed dev server(s) rooted in deleted directories" >> "$LOG"

repo="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || exit 0
before=$(git -C "$repo" worktree list 2>/dev/null | wc -l | tr -d ' ')
git -C "$repo" worktree prune 2>/dev/null
after=$(git -C "$repo" worktree list 2>/dev/null | wc -l | tr -d ' ')
[ "$before" != "$after" ] && echo "  pruned $((before-after)) dead worktree registration(s)" >> "$LOG"

exit 0
