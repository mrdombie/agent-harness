---
name: claim-status
description: show what the spawned claim agents are doing right now (one line each, no log tailing)
---

You are reporting on agents spawned by `/agent-harness:claim`. `claim-lock.sh list --json` marks each claim `mine: true/false` (its own rule, older host-only claims included) and carries `agent` as `login@host` — print **mine** or the login, because with two developers whose agent holds a ticket is the first thing the operator needs.

`/agent-harness:claim` spawns rather than building in the caller's session, so the work happens somewhere the user can't see. This is how they look without paying for it in context.

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
TOOLS=$(toolkit_tools) || exit 1

"$TOOLS/scripts/claim-status.sh" ${1:+"$1"}
```

Pass a ticket number or run-id fragment to narrow it: `/agent-harness:claim-status 8091`.

Spawned runs are only half the picture — a `/agent-harness:claim` typed into a live session
spawns nothing but still holds a claim. Show what is actually claimed, on every
machine, from the refs:

```bash
"$KIT_ROOT/scripts/claim-lock.sh" list --json \
  | jq -r '.[] | [(.issue|tostring),(if .mine then "mine" else (.agent//"?") end),(.branch//"?"),(.claimed_at//"")[0:16]] | @tsv'
```

And what is parked waiting on a human, which by design holds no claim at all:

```bash
gh issue list --repo "$REPO_SLUG" --state open \
  --label "$HOLD_LABEL" --json number,title \
  -q '.[] | "#\(.number) \(.title)"'
```

## Reading it

| state | meaning |
|---|---|
| `running` | process alive, working the ticket |
| `finished` | exited 0 — check the PR landed |
| `EXITED(n)` | exited non-zero; `[error_max_budget_usd]` means it hit the work limiter mid-ticket |
| `GONE` | no exit marker and no process — killed, OOM, or the machine slept. The launchd sweep escalates it within 10 minutes |

**Parked tickets no longer appear as held claims.** A park releases the ref on
purpose: it pushes the branch, opens a draft PR, writes a resume brief on the
issue and adds a `needs:*` label. So look for a parked ticket under the label
query above, not in the claim list. A ticket waiting on a human that still held
its claim would be a slot nobody could use and a ticket nobody could see — that
was the old behaviour, and 3 of 4 live claims were sitting in it on 2026-08-07.

## Do not tail the logs

Pulling a build's output into this conversation re-imports exactly the context the spawn was there to avoid. If the user wants the detail, give them the path and let them open it in a terminal:

```
tail -f <log> | jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text'
```

## What to surface

Report the lines as-is. If anything reads `EXITED` or `GONE`, say so plainly and check whether the ticket has already been escalated:

```bash
gh issue list --repo "$REPO_SLUG" --label "$LBL_NEEDS_HUMAN" --json number,title -q '.[] | "#\(.number) \(.title)"'
```

A dead run whose ticket has **not** been escalated yet means the sweep hasn't reached it — it will inside 10 minutes, or `/agent-harness:release-stale` forces it now.
