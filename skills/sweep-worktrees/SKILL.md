---
name: sweep-worktrees
description: report finished and orphan worktrees under the worktree root (and the temp dir), whatever they are called and whichever clone made them, old harness-tools snapshots, and the build caches of the worktrees it keeps. Dry run by default; --apply deletes. A merged PR or closed ticket removes at once; anything claimed, in use, dirty, unpushed or unreadable is always kept.
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

It considers **every registered worktree** of the project (`git worktree list`) that sits under the worktree root, `$TMPDIR` or `/private/tmp` — whatever the folder is called — plus any worktree directly under those roots that a **second clone of the same project** registered (same `origin`). A main checkout is never a candidate; a worktree of a different repo is kept.

A worktree is removed ONLY when every one of these holds:

1. **No claim.** A ticket number is read from the folder name and from the branch (`<prefix>NNN…`, `NNN-…`); a lockfile in `claims/` or a `refs/claims/NNN` ref on origin keeps it. If the claim refs cannot be read from origin, nothing is removed.
2. **Nobody inside.** No process has its working directory in it (read with `lsof`; without `lsof`, nothing is removed). The session running the sweep counts too.
3. **Finished, or old enough.** Its branch has a **merged PR** (and no open one), or its **ticket is closed** (and the branch has no open PR): removed at once. Anything else must be untouched for the threshold. PR and ticket states come from one GraphQL query per 40 worktrees; if that fails, only the age rule applies and the summary says so.
4. **Clean.** `git status --porcelain` is empty (untracked files count).
5. **Fully pushed.** Every commit on HEAD is on a remote, or inside the head of the branch's merged PR (the branch is deleted on merge, so its commits leave every remote). A commit made after the PR's head keeps the worktree.

Then **harness-tools snapshots** (`harness-tools-<sha>`, the `scripts/` copies `toolkit_tools` extracts per integration-branch commit) under the same roots are removed when not the current commit's, older than `SWEEP_TOOLS_HOURS` (24), and no process has its cwd or an open file inside.

Anything whose git state cannot be read is KEPT and reported `unreadable`.

Then the **cache pass** runs over every worktree it kept (`scripts/worktree-cache.sh`): the folders in `build.cacheDirs` (default: the usual framework output) are removed when no process is inside the worktree, no live run or claim on any host holds it, and nothing in the worktree changed in `build.cacheIdleMin` minutes (30). A folder holding a tracked file is never touched. When the claims cannot be read, nothing is cleaned.

## What it does NOT do

- **Doesn't touch worktrees with uncommitted changes**, other than their idle build caches.
- **Doesn't recover the matching lockfile** — that's `/agent-harness:release-stale`'s job.
- **Doesn't delete branches** — the local branch survives as a regular branch.

## Output

`keep    <name> — <reason>`, `remove  <name> — …` (or `would remove`), a summary line `Sweep complete: kept=N removed=N`, then the cache pass's own lines and `cache pass: cleaned=N kept=N freed=NMB`. Surface the summaries to the user.
