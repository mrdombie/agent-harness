---
name: sweep-worktrees
description: report orphan worktrees at ${TMPDIR:-/tmp}/{sh-NNN,issueNNN}-*. Dry run by default; --apply deletes. Keeps anything claimed, dirty, unpushed, or unreadable.
---

You are running the orphan-worktree sweeper.

The queue lives **outside the repo** at `$STATE_DIR/`. Each `/agent-harness:claim` creates a worktree at `${TMPDIR:-/tmp}/<ticket>-<slug>-<hash>` and a lockfile at `claims/<ticket>.lock/`. When `/agent-harness:finish` succeeds, both are cleaned up. When `/agent-harness:finish` fails partway (agent crash, network blip, OS reboot, etc.) the worktree can survive past the lockfile, gradually filling the temp dir. This skill clears them.

## Argument

Optional: a number of hours that overrides the default 24h "old enough to remove" threshold.

- `/agent-harness:sweep-worktrees` — REPORT with the 24h default (deletes nothing)
- `/agent-harness:sweep-worktrees --apply` — actually delete what the report calls safe
- `/agent-harness:sweep-worktrees 4` — remove orphans older than 4 hours
- `/agent-harness:sweep-worktrees 0` — remove every orphan regardless of age (rare; only when you know nothing's in flight)

## Workflow

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1

HOURS="${1:-24}"

git -C "$MAIN_REPO" fetch -q origin develop
TOOLS=$(toolkit_tools) || exit 1

# Dry run. Read the report, then re-run with --apply to delete.
SWEEP_WORKTREE_HOURS="$HOURS" "$TOOLS/scripts/sweep-orphan-worktrees.sh"
# SWEEP_WORKTREE_HOURS="$HOURS" "$TOOLS/scripts/sweep-orphan-worktrees.sh" --apply
```

## What the script does

A worktree is removable ONLY when all three hold: no live claim, a clean tree, and zero commits that exist on no remote. The third was missing until #8623 — a clean tree says nothing about whether HEAD was pushed, so a worktree with five unpushed commits read as empty and was deleted. Anything whose git state cannot be read is KEPT and reported `unreadable`; a check that errored has not passed.

For every `sh-*-*` and `issue*-*` directory under the sweep base (`${TMPDIR:-/tmp}` AND `/private/tmp`, since worktrees predating #8623 may sit in either):

1. **Derive ticket id** from the path. Two patterns supported:
   - `sh-NNN-<slug>-<hash>` → `SH-NNN`
   - `issueNNN-<slug>-<hash>` → `#NNN`
   - Anything else → skipped with "can't derive ticket id"

2. **Lockfile present at `claims/<ticket>.lock/`?** → leave the worktree alone (active claim).
3. **Younger than the threshold?** → leave it alone (agent might still be working).
4. **Uncommitted changes (`git status --porcelain` non-empty)?** → leave it alone, log "resolve manually".
5. **Otherwise** → `git worktree remove --force` + tidy.

## What it does NOT do

- **Doesn't touch worktrees with uncommitted changes** — surface them to the operator instead. Lost work is not recoverable; a leftover dir in the temp dir is.
- **Doesn't recover the matching lockfile** — that's `/agent-harness:release-stale`'s job. This skill only cleans up what's left after a lockfile is already gone.
- **Doesn't push a branch** — the original branch (if any) survives; deleting just the worktree leaves it as a regular branch on the main repo. `git branch -D <branch>` afterwards if you want it gone too (this skill doesn't auto-do that to preserve any in-progress work that pushed but never got merged).

## When to use it

- Periodically — once a week is plenty in normal operation.
- After a crash / restart, to clean up worktrees from interrupted /agent-harness:finish runs.
- When the temp dir has too many `sh-*` / `issue*` dirs to count by eye.

## Output

The script prints `removing orphan <TICKET> → <PATH>` per remove + a summary line on the way out: `Sweep complete: removed=N dirty-skipped=N active-skipped=N young-skipped=N`. Surface those to the user. Silent when nothing's orphaned (typical case).
