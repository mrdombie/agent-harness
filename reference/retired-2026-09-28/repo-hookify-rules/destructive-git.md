---
name: block-destructive-git
enabled: true
event: bash
action: block
conditions:
  - field: command
    operator: regex_match
    pattern: ^\s*git\s+(reset\s+--hard|stash\s+pop|clean\s+-[a-z]*[fd])
---

**Blocked: destructive git on a working tree you did not create.**

`git reset --hard`, `git stash pop` and `git clean -fd` all discard work with no
undo. They are most often reached for to A/B a tree or to "start clean" — both
of which lose a peer agent's uncommitted work when the worktree is shared.

To compare states, use `git diff` or `git worktree add` a second tree.
