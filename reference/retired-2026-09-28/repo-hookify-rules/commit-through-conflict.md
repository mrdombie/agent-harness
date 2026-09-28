---
name: block-commit-through-conflict
enabled: true
event: bash
action: block
conditions:
  - field: command
    operator: regex_match
    pattern: ^\s*git\s+commit\b.*(-a|--all|--no-verify)
---

**Check the merge state before committing this way.**

`git commit -a` during an unresolved merge commits conflict markers, and
`--no-verify` skips the gates that would have caught it. Both have shipped
broken trunk before.

Resolve the conflict, stage the resolved files by name, then commit.
