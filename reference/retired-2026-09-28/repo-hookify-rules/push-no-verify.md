---
name: push-no-verify
enabled: true
event: bash
conditions:
  - field: command
    operator: regex_match
    pattern: git\s+push
  - field: command
    operator: contains
    pattern: --no-verify
---

🛑 **`git push --no-verify` skips all 29 pre-push checks.**

That is the whole local gate set — lint, typecheck, suppression ratchet, deploy-trigger,
ui-gate attestation, the lot. Whatever it would have caught lands on develop instead, and CI
finds it minutes later or a reviewer finds it days later.

If a check is wrong, **fix the check or say why in the PR** — do not route around it.

The one legitimate use is a **merge commit dragging prettier churn** you did not author
(`git commit --no-verify` on the merge, per `/auto` Tier 2). That is a commit, not a push.
