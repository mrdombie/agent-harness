# The sign-off — "I was working on…"

Every agentic flow ends every handback with this block. **Handback means any time you
give the operator the floor** — finished the queue, paused for a decision, blocked, or stopped
to ask a question. Not only at the end of a run.

WHY: the operator loses track of which area an agent was on, and starts a second agent on work
already in flight. Three claims were open and unnamed at the moment this was written.
The banner is the one line that stops the duplicate.

## The block

```
🏷️ Working on: Content Lab (project:content-lab)
   Shipped 3 · 1 in flight (draft cards, PR open)
   Also running: 2 agents on Welcome Flow
   Resume: /agent-harness:work content-lab
```

The first line is mandatory and its opening `🏷️ Working on:` is literal — the backstop
greps for exactly that string. The other three lines are omitted when empty.

## Who "you" is

The banner addresses **the operator** — the human running this session (see
`.claude/shared/operator.md`). Never a name.

## Rules

- **Plain English first, the label in brackets.** "Content Lab (project:content-lab)",
  never the bare label. Same rule as every other table in the estate: the description
  is what the operator acts on, the reference goes last.
- **`Resume:` is a literal command the operator can run**, never a description of one. When the
  next move is theirs — approve pixels, answer a question — say that instead, in their
  words, not the gate's.
- **When paused, line 2 says what it is paused ON.** That is the line that stops the
  second agent, so it is the one that must be specific: "Paused on: you — approve the
  draft card pixels", not "waiting for review".
- **`Also running:` is read live**, in this turn, from:

  ```bash
  "$KIT_ROOT/scripts/claim-lock.sh" list --json
  ```

  Omit the line when this is the only live claim. Never write it from memory — a stale
  roster here is worse than no roster, because it is the exact fact the operator is about to
  act on.
- **Omit any line with no content.** Never "Shipped 0", never "none", never an empty
  `Also running:`.
- **Never print a bare ticket number.** "the draft cards", not "#9822".

## Where the scope comes from

`$STATE_DIR/.session-label` — one line, `<scope>\t<ISO timestamp>`,
truncate-written. Every work flow writes it the moment its scope resolves, before the
first `/agent-harness:claim`:

```bash
printf '%s\t%s\n' "$SCOPE" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
  > "$STATE_DIR/.session-label"
```

If the file is missing when you go to sign off, say so plainly rather than guessing
the scope — a guessed area is how the operator ends up on the wrong branch.
