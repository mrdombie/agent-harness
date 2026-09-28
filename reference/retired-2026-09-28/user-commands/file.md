---
description: Maktura — turn an idea into a filed ticket by running superpowers:brainstorming and posting the spec as a GitHub issue
---

You are filing new work into the queue.

**Run `superpowers:brainstorming`. Post what it produces as the issue. That is the
whole command.**

There is no Maktura ticket template. `brainstorming` already asks one question at
a time, proposes approaches with a recommendation, YAGNIs ruthlessly, and ends
with an agreed spec. That spec is the ticket. Inventing a second format around it
is how the queue ended up with three competing shapes that disagreed with each
other and with `/claim`'s own gate.

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
gh issue create --repo mrdombie/maktura \
  --title "<type(scope): what changes>" \
  --body-file <the spec> \
  --label "status:drafting,P?,type:?,area:?,effort:?"
```

4. **Label it.** `gh label list --repo mrdombie/maktura` is the source of truth,
   not memory. Today's queue has 119 open issues with no `area:` and 21 with no
   `status:` — all hand-filed. Missing labels make a ticket invisible to the
   filtered views `/queue` and `/claim` run.
   Off a beta tester's report? Add `--label beta-feedback` too — additive, so the cohort's reports stay filterable as one set. Not for Dom's own feedback or review-gate findings.

5. **`status:drafting` first.** Moving to `status:ready` is a separate,
   deliberate act — it is the moment an agent may pick the ticket up. Don't
   combine the two.
   Never file at `status:in-review` either — with no claim ref and no PR, the reconciler resets it to `ready` and nothing holds it.
   Anything titled or scoped "Phase 2" is post-release by default: file it `P2` + `status:gated` with a `## PM timing — POST-RELEASE` header, never `P1`/`ready`.
   One ticket = one PR's worth. Never file an epic as a Phase A/B/C list — each phase is its own ticket, `status:gated` on the prior one.

6. **`type:discovery` delivers evidence only.** Say so in the body: the agent audits and posts findings; it files no child tickets and decides nothing — the PM does.

7. **A stack/framework decision goes in the spec's Verify block as a POSITIVE assertion** (`grep '"ai"' package.json`), never as prose — a negative-only check passes whether or not the work was done.

8. **A ticket that talks to an outside service names the ONE home it extends.**
   LinkedIn, X, YouTube, Instagram, TikTok, Facebook, Canva, Slack, Outlook,
   WordPress, any API — before filing, `git ls-tree -r origin/develop --name-only
   apps/api/src/lib/platforms/<service>/` and write the spec against that module.
   Measured 2026-09-20: YouTube code lived in 6 separate homes, LinkedIn 6,
   Instagram 5, TikTok 4, X 3, Facebook 3 — each built by a ticket scoped to its
   own area, each agent inventorying only that area. Nobody was wrong by their
   ticket; the ticket design was. If no home exists, the spec's first step
   creates it at `lib/platforms/<service>/` and every later call goes through it
   (`callExternal`, #10032). A spec that adds a second client for a service that
   already has one is a filing error, not a build decision — Dom, 2026-09-20.

## Bugs

Use `superpowers:systematic-debugging`, not `brainstorming`. You cannot spec a
fix for a failure you have not reproduced, and the reproduction is the most
valuable thing in the ticket. Post the reproduction and what it proves; leave the
fix direction as a lead rather than an instruction if it has not been confirmed.

## Sign off

End with the sign-off banner — read `~/.claude/shared/agent-signoff.md`. `/file` files
and stops, so `Resume:` is what Dom or the next agent does with the ticket:

```
🏷️ Working on: Content Lab (project:content-lab)
   Filed 1 — drafts expire while someone is editing them (status:drafting)
   Also running: 2 agents on Welcome Flow
   Resume: /claim 9822 once you've flipped it to status:ready
```

Do **not** write `.session-label` here. `/file` does not build anything, and a scope
written by a filing run would make the backstop nag every later session in the window
about work nobody started.

## What this does not do

- It does not write the implementation plan (Step 11 of `/claim`, at build time).
- It does not decide priority or area for you. Those are PM calls.
- It does not set `status:ready`.

## Epics

An epic that a single agent may run end-to-end also needs a `## Autonomy
contract` — acceptance criteria, decision defaults, escalation bar — plus the
`epic:run-ready` label. Without both, `/claim` refuses it and releases the claim.
Everything above still applies; the contract is additional.

An epic-shaped or new-surface ticket opens with the Working Backwards trio — press release, FAQ, customer experience — before any scope; skip only if Dom says so.

## Before a programme or epic gets its first child ticket

A `programme` or `epic` needs an architecture spec first — `docs/architecture/<slug>.md`, from `docs/architecture/_template.md`. The spec is the only place its data model is defined; every child ticket references it rather than restating it.

Check before filing: `npm run check:architecture-specs`. If the spec is missing, write it before the ticket. Filing children against a programme with no spec is how three Pulse plans ended up hard-coding an assumption that changed four days later with nothing pointing at them.

A single ticket or a bug needs no spec.
