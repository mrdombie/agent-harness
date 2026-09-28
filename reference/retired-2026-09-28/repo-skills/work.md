---
name: work
description: "/auto, scoped to one label. Ships that label's tickets until the context runs out, instead of taking whatever is top of the whole board. Usage: /work (lists the workable labels) | /work <label-or-subject> | /work welcome-flow | /work 9822 (one ticket)"
---

**`/work` is `/auto` with one thing changed: the candidate set.**

Read `.claude/skills/auto/SKILL.md` and follow it exactly — the triage, the tiers, the loop, the
stop conditions, the "never does" list, `/claim` for taking a ticket, `/finish` for shipping it.
All of it applies unchanged, including the superpowers discipline `/claim` already carries.

Everything below is the delta. There is nothing else.

## The delta

**0. It is a loop of `/claim <ticket>`.** That is the whole shape. `/claim` is the one path to
shipping code — the superpowers steps, the spec and anti-orphan gates, the worktree, `/finish`.
`/work` never builds anything itself; it decides WHICH ticket and calls `/claim <n>`. One
implementation, so no second path to drift out of step.

**1. Scope.** `/auto` takes the top row of the whole board. `/work` takes only tickets under
`$ARGUMENTS`:

| Argument | Set |
|---|---|
| a programme subject (`welcome-flow`, `ER`) | resolve to its `project:` label the way `/project` Step 0 does |
| any other label (`flow-gap`, `beta-feedback`) | that label |
| a bare number (`9822`) | that one ticket, then stop |
| **empty** | nothing ships — print the label board below and stop |

Query `$REPO_SLUG` — through a renamed-repo redirect `--label` silently returns `0`.

### No argument — the label board

Print what is worth working, then stop. Do not pick a label yourself and do not
fall through to `/auto`; the operator typed `/work` to choose the scope.

Two traps make a raw `gh label list` useless:

- **Most labels are filters, not workstreams.** `P0`–`P3`, `status:*`,
  `effort:*`, `type:*`, `repo:*` are state, size and kind. Scoping to one slices
  every subject at once. Of 96 labels on 2026-08-30, **43** were workstreams.
- **Open count is the wrong number.** `/work` ships `$LBL_READY` (ready). A label with
  40 open and 0 ready is one `/work` does nothing with — `area:BILLING` (9 open)
  and `area:LEGAL` (8) were both exactly that. Rank on **ready**.

**One call**, then group locally — never loop `--label` per label (96 calls, and
the redirect returns `0` silently, so you would render a board of zeroes and
believe it):

```bash
. "$(git rev-parse --show-toplevel)/scripts/toolkit-env.sh" || exit 1
gh issue list --repo "$REPO_SLUG" --state open --limit 2000 \
  --json number,labels -q '.[] | [([.labels[].name]|join(","))] | @tsv'
gh label list --repo "$REPO_SLUG" --limit 500 \
  --json name,description -q '.[] | [.name, (.description // "")] | @tsv'
```

The second call is what makes the board readable — `rg:stranding` and
`area:CROSS-CUTTING` do not say what work they hold. **Print the label's own
description as a column.** Never write a gloss here: the description lives on the
label, so it is one edit for every reader, and a gloss in this file would drift.

A description **exactly equal to** `Functional area: <NAME>` is the GitHub
default restating the name — it tells you nothing. Render it as `—` and say
`N labels still carry the placeholder description` in one line, so it gets fixed
at the source rather than papered over here. Match on equality, not on prefix:
`Functional area: ACCESS (profiles, permissions, roles, invites, audit)` carries
real detail, and a prefix test would throw it away.

Bucket every label on every issue by that issue's `status:` label. A label is a
**filter** — drop it — if it starts with `status:` `effort:` `type:` `repo:`
`epic:` `needs:`, or is exactly `P0` `P1` `P2` `P3` `epic` `epic-child`
`review-gate` `design-exempt` `bug` `documentation` `duplicate` `enhancement`
`good first issue` `help wanted` `invalid` `javascript` `dependencies`
`question` `wontfix`. (`review-gate` and `design-exempt` look like subjects and
are not — the gates apply them.)

**Exclusion, never enumeration.** A new `project:*` or `area:*` label has to
appear the run after it is created; a hard-coded workstream list silently hides
it.

Group the survivors by shape — `area:*` · `project:*` · `rg:*` · standalone
(`flow-gap`, `code-health`, `beta-feedback`, `launch-blocker`, `security`,
`programme`, anything new) — and render **label · ready · gated · open**, ready
descending, with **what it holds** — the label's description — as the widest
column. Ready first among the numbers: it is what decides whether
`/work <label>` does anything.

Then, only when non-empty:

```
NOTHING WORKABLE — open tickets, 0 ready
  area:BILLING (9 open)   area:LEGAL (8 open)   area:SENTINEL (1)
```

Labels with zero open issues are dead — leave them off the board; one line
saying `N labels carry no open tickets` covers them.

**2. Record the scope for `/standup`.** The moment the label resolves — before the first
`/claim` — write it beside the session ledger, so `/standup` can put it at the top of the board:

```bash
printf '%s\t%s\n' "$SCOPE" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
  > "$STATE_DIR/.session-label"
```

Truncate-write, never append — one line, and it is the current scope or nothing.

**Local time with the offset, not UTC.** The file is per-machine and its only reader prints a
wall-clock time back to the operator. Stamping `...Z` made `/standup` show 16:11 for work done at 17:11,
because macOS `date -jf` reads a bare `Z` as local. `%z` carries the offset, so it both displays
directly and subtracts correctly.

**Write the RESOLVED value, not what the operator typed.** They type `ER`; the file holds
`project:event-registry`. A raw subject in there means `/standup` prints a label that does not
exist on any ticket.

| Argument form | `$SCOPE` |
|---|---|
| programme subject (`ER`, `welcome-flow`) | the resolved `project:` label |
| any other label (`flow-gap`) | that label |
| bare number (`9822`) | `ticket 9822` |
| **empty** (the label board) | `rm -f` the file — the operator is choosing a scope, so there isn't one |

**3. Triage is scoped too.** Run `/auto`'s Step 1, but Tier 2 and Tier 3 only consider this
label. **Tier 1 still covers the whole estate** — a red trunk or a dead CI blocks your tickets
as surely as anyone's, and healing it is not out of scope.

**4. One extra stop condition.** This label's runnable list is empty — everything left is
gated, blocked, or parked on a human. Report and stop. **Never widen to another label**; that is
`/auto`'s job and the operator chose the scope deliberately.

**5. Blockers move under you.** Re-resolve them every pass. Your own merge is usually what
unblocks the next ticket, and a ticket that was blocked at the start of the window is often the
best next thing by the end.

**6. Close with the board, then the banner.** Render `/project <subject>` Steps 4–5, so the
honest state is on screen rather than a diary of what you did — then sign off per
`.claude/shared/agent-signoff.md`, with the resolved label as the scope:

```
🏷️ Working on: Content Lab (project:content-lab)
   Shipped 3 · 1 in flight (draft cards, PR open)
   Also running: 2 agents on Welcome Flow
   Resume: /work content-lab
```

`Resume:` is `/work <what the operator typed>`, not the resolved label — they type subjects, and a
command they cannot retype is not a resume.

**This fires on every handback, not just the end of the run.** A `/work` loop that pauses
for a pixel approval is the exact moment the operator starts a second agent, so it is the moment
the banner matters most. Line 2 says what it is paused ON.

## Running it unattended

`/work` is stateless — GitHub is the state — so a fresh window resumes by re-running the same
command. The one thing on disk, `.session-label`, is a display breadcrumb for `/standup`: the
loop writes it and never reads it back, so deleting it changes nothing about what ships.

**But this file cannot make the loop continue.** It is instructions, not a runtime, and the
drift is real: on 2026-08-29 the model tried to hand back to the operator **twice** with context and
runnable tickets remaining. A `/goal` stop hook caught both, and the session then merged three
more tickets and found a live P0.

| For | Use |
|---|---|
| it not giving up mid-window | `/goal complete as many <label> tickets as you can` — the only hard enforcement |
| surviving the window filling | re-run `/work <label>` |
| unattended across windows | `/loop /work <label>` |

**Do not start a ticket you cannot finish before the window ends.** An unclaimed ticket costs
nothing; a claimed one with a half-built branch and no PR is a zombie that reads as progress to
`/project` and to every peer. If you must stop mid-build, push and open a **draft** PR so the
work is reachable, and say so.
