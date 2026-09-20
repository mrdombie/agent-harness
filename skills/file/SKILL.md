---
name: file
description: Turn an idea into a filed ticket by running superpowers:brainstorming and posting the spec as a GitHub issue
---

You are filing new work into the queue.

**Run `superpowers:brainstorming`. Post what it produces as the issue. That is the
whole command.**

There is no project ticket template. `brainstorming` already asks one question at
a time, proposes approaches with a recommendation, YAGNIs ruthlessly, and ends
with an agreed spec. That spec is the ticket. Inventing a second format around it
is how the queue ended up with three competing shapes that disagreed with each
other and with `/agent-harness:claim`'s own gate.

## Steps

1. **`superpowers:brainstorming`** — with the user's idea as the starting point.
   Follow it as written; don't summarise it or skip its questions.

2. **Stop at the spec.** `brainstorming` documents its terminal state as "invoke
   writing-plans". Do NOT here. A plan needs exact `Create:` / `Modify:` /
   `Test:` paths and forbids placeholders, which means it needs the codebase in
   front of it — so it is written by whoever *claims* the ticket, in their
   worktree, at Step 11. Filing a ticket for next month cannot know those paths.
   This is the one deliberate divergence from the skill.

3. **Post it as the issue** rather than to `docs/superpowers/specs/`. GitHub is
   the single source of truth for ticket state; a file in the repo is a second
   place to disagree.

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
gh issue create --repo "$REPO_SLUG" \
  --title "<type(scope): what changes>" \
  --body-file <the spec> \
  --label "$LBL_DRAFTING,P?,type:?,area:?,effort:?"
```

4. **Label it.** `gh label list --repo "$REPO_SLUG"` is the source of truth,
   not memory. Today's queue has 119 open issues with no `area:` and 21 with no
   `status:` — all hand-filed. Missing labels make a ticket invisible to the
   filtered views `/agent-harness:queue` and `/agent-harness:claim` run.

5. **`$LBL_DRAFTING` (drafting) first.** Moving to `$LBL_READY` (ready) is a separate,
   deliberate act — it is the moment an agent may pick the ticket up. Don't
   combine the two.

## Bugs

Use `superpowers:systematic-debugging`, not `brainstorming`. You cannot spec a
fix for a failure you have not reproduced, and the reproduction is the most
valuable thing in the ticket. Post the reproduction and what it proves; leave the
fix direction as a lead rather than an instruction if it has not been confirmed.

## Sign off

End with the sign-off banner — read `${CLAUDE_PLUGIN_ROOT}/shared/agent-signoff.md`. `/agent-harness:file` files
and stops, so `Resume:` is what the operator or the next agent does with the ticket:

```
🏷️ Working on: Content Lab (project:content-lab)
   Filed 1 — drafts expire while someone is editing them ($LBL_DRAFTING)
   Also running: 2 agents on Welcome Flow
   Resume: /agent-harness:claim 9822 once you've flipped it to $LBL_READY
```

Do **not** write `.session-label` here. `/agent-harness:file` does not build anything, and a scope
written by a filing run would make the backstop nag every later session in the window
about work nobody started.

## What this does not do

- It does not write the implementation plan (Step 11 of `/agent-harness:claim`, at build time).
- It does not decide priority or area for you. Those are PM calls.
- It does not set `$LBL_READY`.

## Epics

An epic that a single agent may run end-to-end also needs a `## Autonomy
contract` — acceptance criteria, decision defaults, escalation bar — plus the
`epic:run-ready` label. Without both, `/agent-harness:claim` refuses it and releases the claim.
Everything above still applies; the contract is additional.
