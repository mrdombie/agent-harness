# The operator

Every command in this toolkit is run by a human through their own GitHub account, and
the agent acts on that account's token. That human is **the operator**. Nothing in a
command names a person: what a command addresses is whoever is running it.

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
OPERATOR=$(toolkit_login)          # the GitHub login this session acts as
```

Three words, used precisely:

| Word | Means |
|---|---|
| **the operator** | the human running this session — the one the sign-off banner addresses, whose approval the park waits for, whose token every `gh` call uses |
| **the PM** | the product-decision role from `docs/operations/agent-workflow.md` — the person who files and marks tickets ready; `status:pm-decision` on an issue means that person still owes a call |
| **a peer** | another human whose login is in the `HUMAN_APPROVERS` repo variable — the only reviews the gate counts. A developer not yet in it can still sign off by removing the label, but their review changes nothing. |

What follows from it:

- The two sign-offs are defined once, in AGENTS.md § "A HUMAN SIGNS OFF BEFORE IT
  MERGES" — this file does not restate them. `toolkit_is_approver "$OPERATOR"` answers
  whether the operator's review is one of them.
- `/agent-harness:needsme` shows every hold with **who** can clear it, by the rule under its step 1a.
- `claim-lock.sh list --json` marks each claim `mine: true/false` by its own ownership rule
  (which also covers claims taken before ids carried the login); `/agent-harness:standup` and
  `/agent-harness:claim-status` read that field rather than comparing logins themselves.
- Dated decisions quoted in a command ("PM 2026-06-10: …", "2026-08-20, Dom: …") are
  attributions, not instructions to a person. They stay as written.
