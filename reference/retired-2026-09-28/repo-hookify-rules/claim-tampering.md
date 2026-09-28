---
name: block-claim-tampering
enabled: true
event: bash
action: block
conditions:
  - field: command
    operator: regex_match
    pattern: (rm\s+(-[a-z]+\s+)*.*(socialhub-tickets/claims|\.lock)|push\s+.*(--delete|:)\s*refs/claims)
---

**Blocked: direct tampering with a claim.**

Claims are `refs/claims/<issue>` on origin, and releasing one by hand releases a
ticket someone else may be mid-build on. Go through the script, which refuses to
release a claim you do not hold:

```
"$(git rev-parse --show-toplevel)/scripts/claim-lock.sh" release <issue>
```
