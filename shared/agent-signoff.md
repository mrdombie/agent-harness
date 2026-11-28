# The sign-off — one closing line

Every agentic flow ends every handback with **one line**. Handback means any time you
give the operator the floor: finished, paused for a decision, blocked, or stopped to
ask a question.

WHY: the operator loses track of which area an agent was on and starts a second agent
on work already in flight. One line naming the work stops that. The owner, 2026-11-28,
replaced the old four-line banner ("🏷️ Working on:" / "Paused on:" / "Also running:" /
"Resume:" plus a separate status line) because it was "really confusing … three groups
etc, it's hard to read and follow".

## The line

```
Status: Content Lab's draft cards PR is open and red; waiting on its fix; next check when CI reports.
```

It starts with the literal `Status: ` (the backstop and the heartbeat hooks grep for
it) and says, in plain words:

- **what you are working on**, named as the work, not a label or ticket number;
- **what it waits on** — when that is the operator, say what they must do: "waiting
  on you to approve the draft card picture";
- **when you next check**, or "nothing else of mine is running".

## Rules

- **One sentence, one line.** No heading, table, emoji, label in brackets or second
  line.
- **Never a bare ticket number.**
- **Other agents are named only if the operator would act on it**, read live in this
  turn from `"$KIT_ROOT/scripts/claim-lock.sh" list --json`, never from memory.
- **Never repeat the reply above it.** It is the last line, not a recap.

## Where the scope comes from

`$STATE_DIR/.session-label` — one line, `<scope>\t<ISO timestamp>`, truncate-written.
Every work flow writes it the moment its scope resolves, before the first claim:

```bash
printf '%s\t%s\n' "$SCOPE" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
  > "$STATE_DIR/.session-label"
```

If the file is missing when you sign off, say so plainly rather than guessing the area.
