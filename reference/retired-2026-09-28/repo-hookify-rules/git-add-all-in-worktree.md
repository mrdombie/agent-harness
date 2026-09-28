---
name: block-git-add-all
enabled: true
event: bash
action: block
conditions:
  - field: command
    operator: regex_match
    pattern: ^\s*git\s+add\s+(-A|--all|\.)(\s|$)
---

**Blocked: `git add -A` / `git add .`**

Worktrees carry a `node_modules` symlink. `git add -A` stages it, and a
committed symlink to an absolute path on one machine is a broken tree on every
other one.

Stage the files you changed by name: `git add path/to/file`.
