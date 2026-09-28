---
name: no-handrolled-ticket-branch
enabled: true
event: bash
action: block
conditions:
  - field: command
    operator: regex_match
    pattern: git\s+worktree\s+add[^|;&]*-b\s+sh-[0-9]
  - field: command
    operator: not_contains
    pattern: "# via /claim"
---

🛑 **BLOCKED — a ticket branch is `/claim`'s job, not yours.**

`git worktree add -b sh-<n>/…` by hand skips every gate that makes the work
consistent: the atomic claim ref, the spec and sizing gate, the anti-orphan
gates, the superpowers steps, the repo routing, the attestations.

**Use the one path:**

```
/claim 9822        # that ticket
/claim             # or let it pick
```

On 2026-08-28 a whole session was hand-rolled this way. It shipped, but it
re-derived by hand what `/claim` already knew, and skipped checks nobody
noticed were missing until the review caught them.

**If you ARE `/claim`** (or a script it drives), append `# via /claim` to the
command. That marker is the sanctioned path saying so — typing it while
freelancing is a deliberate lie, not a shortcut.
