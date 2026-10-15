---
name: sweep-worktrees
description: report orphan worktrees under the worktree root (and the temp dir), whatever they are called, and the build caches of the ones it keeps. Dry run by default; --apply deletes. Keeps anything claimed, in use, young, dirty, unpushed, or unreadable.
---

You are running the orphan-worktree sweeper.

Each `/agent-harness:claim` and each driver run creates a worktree under `$(toolkit_worktree_root)` (`~/.harness-worktrees/<repo>` by default). When `/agent-harness:finish` fails partway (agent crash, network blip, reboot) the worktree survives, and a kept worktree carries its build output: about 4.2 GB of a typical 4.3 GB ticket worktree. This skill clears both.

## Argument

Optional: a number of hours that overrides the default 24h "old enough to remove" threshold.

- `/agent-harness:sweep-worktrees` — REPORT with the 24h default (deletes nothing)
- `/agent-harness:sweep-worktrees --apply` — delete what the report calls safe, and clean idle caches
- `/agent-harness:sweep-worktrees --caches-only` — report only the cache pass; add `--apply` to run it
- `/agent-harness:sweep-worktrees 4` — remove orphans older than 4 hours

## Workflow

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
HOURS="${1:-24}"

# Dry run. Read the report, then re-run with --apply to delete.
SWEEP_WORKTREE_HOURS="$HOURS" bash "$KIT_ROOT/scripts/sweep-orphan-worktrees.sh"
# SWEEP_WORKTREE_HOURS="$HOURS" bash "$KIT_ROOT/scripts/sweep-orphan-worktrees.sh" --apply
```

## What the script does

It considers **every registered worktree** of the project (`git worktree list`) that sits under the worktree root, `$TMPDIR` or `/private/tmp` — whatever the folder is called. The main checkout is never a candidate. It used to match only `sh-*` and `issue*` names, and on the origin machine 101 removable worktrees named `12619-…`, `harness-spawn-…` and the like were never looked at.

A worktree is removed ONLY when every one of these holds:

1. **No claim.** A ticket number is read from the folder name and from the branch (`<prefix>NNN…`, `NNN-…`); a lockfile in `claims/` or a `refs/claims/NNN` ref on origin keeps it. If the claim refs cannot be read from origin, nothing is removed.
2. **Nobody inside.** No process has its working directory in it (read with `lsof`; without `lsof`, nothing is removed). The session running the sweep counts too.
3. **Old enough.** Untouched for the threshold.
4. **Clean.** `git status --porcelain` is empty.
5. **Fully pushed.** `git rev-list --count HEAD --not --remotes` is 0.

Anything whose git state cannot be read is KEPT and reported `unreadable`.

Then the **cache pass** runs over every worktree it kept (`scripts/worktree-cache.sh`): the folders in `build.cacheDirs` (default: the usual framework output) are removed when no process is inside the worktree and nothing in the folder changed in `build.cacheIdleMin` minutes (30). A folder holding a tracked file is never touched.

## What it does NOT do

- **Doesn't touch worktrees with uncommitted changes**, other than their idle build caches.
- **Doesn't recover the matching lockfile** — that's `/agent-harness:release-stale`'s job.
- **Doesn't delete branches** — the local branch survives as a regular branch.

## Output

`keep    <name> — <reason>`, `remove  <name> — …` (or `would remove`), a summary line `Sweep complete: kept=N removed=N`, then the cache pass's own lines and `cache pass: cleaned=N kept=N freed=NMB`. Surface the summaries to the user.
