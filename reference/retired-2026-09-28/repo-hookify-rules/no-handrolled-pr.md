---
name: no-handrolled-pr
enabled: true
event: bash
action: block
conditions:
  - field: command
    operator: regex_match
    pattern: gh\s+pr\s+create
  - field: command
    operator: not_contains
    pattern: "# via /finish"
---

🛑 **BLOCKED — opening a PR is `/finish`'s job.**

`/finish` is not a wrapper around `gh pr create`. Before the PR exists it runs
the gates, and after it, the bookkeeping you will forget:

- lint / typecheck / tests, and the suppression ratchet
- the `UI-Gate:` trailer — and **it fingerprints the diff**, so develop must be
  merged FIRST and the gate run LAST
- `.deploy-trigger` via its script, changelog entry or a tagged skip
- issue transition, claim release

A hand-made PR is missing some of those and looks identical to one that is not.

**Use:**

```
/finish
```

**If you ARE `/finish`**, append `# via /finish` to the command.
