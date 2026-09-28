---
description: "Maktura — /auto, scoped to one label. Ships that label's tickets until the context runs out, instead of taking whatever is top of the whole board. Usage: /work (carries on where you left off) | /work --resume (the same, said out loud) | /work <label-or-subject> | /work 9822 (one ticket) | /work --board (the workable labels)"
---

**`/work` is `/auto` with one thing changed: the candidate set.**

Read `~/.claude/commands/auto.md` and follow it exactly — the triage, the tiers, the loop, the
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
| **empty**, or `--resume` | **the chain** — what this machine already started, resolved by the ladder below. Nothing to carry on with → the label board |
| `--board` | the label board, and stop. The old no-argument behaviour, when you want to choose |

Query `mrdombie/maktura` — through the `social-hub` redirect `--label` silently returns `0`.

### `--resume` — carrying on without naming the scope

Bare `/work` and `/work --resume` are the same path. **Dom does not have to remember the
label.** This machine already knows what it was doing; the ladder below reads it off disk and
off origin.

**Walk it top-down and stop at the first rung that answers.** Then print the rung you landed
on and the row that proved it — one line, before the first `/claim`. A resume that does not
say what it resumed is indistinguishable from a resume that guessed.

| # | Rung | Resolves to |
|---|---|---|
| **1** | a **live claim ref** held by this machine, ticket still open | that ticket — `/claim <n>` picks the branch back up |
| 2 | an **open PR of mine** that is mine to move (see the label filter) | its ticket, the same way |
| 3 | `.session-label` — last 12h **and** `.session-label.owner` is `$MY_SESSION` | that scope, exactly as if typed |
| 4 | last row of `.session-tickets` → that ticket's `project:`/`area:` label | that label |
| — | nothing answered | the label board below, and stop |

Rungs 1 and 2 resume **one ticket**; the loop then re-walks the ladder, so a backlog of
half-built branches drains before any new ticket is claimed. Rungs 3 and 4 resolve a **label**
and hand back to the normal `/work <label>` loop.

**Rung 1 outranks a fresher rung 3.** A claimed ticket with a half-built branch is a zombie
the moment you start something else — it reads as progress to `/project` and to every peer.
Finish it, or park it properly (push, draft PR, resume brief, release). Never walk away to a
new label with a claim still held.

#### First: whose session are you? (this machine runs several)

**Every rung below reads machine-global state, and on 2026-09-14 this machine had six live
Claude sessions, aged two to eight days.** Without an identity check the ladder hands you a
peer's work and the lock agrees, because `claim-lock.sh` identifies an agent by **hostname**:

```
$ claim-lock.sh holds 10012
rc=0          # "you hold it" — but it meant this MACHINE holds it
```

#10012 was held by session **98306**. The session asking was **98431**. Both on
`Dominics-MacBook-Pro`, so `holds` returned 0 to the wrong one.

Resolve your own session first — walk up from the shell to the `native-binary/claude` ancestor:

```bash
. ~/.claude/hooks/lib/claude-session.sh   # the hooks compare against this exact value
MY_SESSION=$(claude_session_pid)
```

**Never use `holds` to decide whether a claim is yours.** Compare `claim-lock.sh show <n>`'s
`pid` against `$MY_SESSION`.

#### Rung 1 — `no live claims` is a lie by default

`claim-lock.sh list` cannot find a repo on this machine, writes the reason to **stderr**, and
still exits 0 with an empty list:

```
$ bash ~/.claude/socialhub-tickets/scripts/claim-lock.sh list
claim-lock: not in a git repo and /Users/dominabox/maktura-dev is not one; set CLAIM_REPO
no live claims
rc=0
```

`~/maktura-dev` was not on this machine on 2026-09-09. Hand it the repo from `config.json`
and the identical call returns **nine**:

```bash
CLAIM_REPO=$(jq -r '.repos.maktura' ~/.claude/socialhub-tickets/config.json)   bash ~/.claude/socialhub-tickets/scripts/claim-lock.sh list
```

```
#9879   sh-9879/vendor-neutral-identity      2026-09-08T21:08:08Z
#10113  sh-10113/connections-rows            2026-09-07T11:15:35Z
#9959   sh-9959/controls-that-lie            2026-09-07T10:22:04Z
… 9 rows, every one on Dominics-MacBook-Pro
```

Nine unfinished tickets reading as zero is the whole failure mode of this command. **`no live
claims` accompanied by a stderr line is UNKNOWN, never an empty rung** — fix the repo and ask
again.

**Read the ref, never the `status:` label.** On 2026-09-09 the newest live claim, **#9879**,
carried `status:ready` — the mirror had not been written. A ladder that filtered on
`status:claimed` would have skipped its own chain head and gone looking for new work.

Three claims are not chain and must not be resumed:

- **a live peer is building it** — the claim's `pid` is alive and is not `$MY_SESSION`. Say so in
  one line and move down the ladder. **Do not touch the branch, do not rebase it, do not release
  the ref.** On 2026-09-14 rung 1 resolved to #10012, whose holder (pid 98306) had been running
  four days; taking it would have put two writers on `sh-10012/one-desk-one-room`.
- **ticket closed, or its PR merged** → an orphan lock. `claim-lock.sh release <n>` and walk on.
  **#9973** was CLOSED on 2026-09-09 and still held its ref; resuming it would have rebuilt
  shipped work.
- **claimed over 24h ago with a dead pid and no PR** → stale. Name it in one line, hand it to
  `/release-stale`, do not build it.

#### Rung 2 — most open PRs are Dom's, not yours

`needs:human-approval` (and `needs:dom-approval`) means the PR is parked on him. Resuming one
does nothing but re-read a diff. `needs:rebase` is the opposite — that is your work.

```bash
gh pr list --repo mrdombie/maktura --author @me --state open --limit 60   --json number,headRefName,updatedAt,isDraft,labels   -q '.[] | [.updatedAt,(.number|tostring),.headRefName,([.labels[].name]|join(","))] | @tsv'   | sort -r
```

Of 14 open PRs on 2026-09-08, **10 carried `needs:human-approval`** and were not resumable.
Report those as one line — `10 PRs waiting on you` — and take the newest of the rest.

**A PR with no live claim, untouched for more than 7 days, is abandoned — not chain.** Rebasing
a month-old conflicting draft is a fresh job, not continuation, and taking one silently is how a
`/work` run spends its window somewhere Dom never asked for. On 2026-09-14 the three free PRs
were 13, 15 and 34 days stale and all CONFLICTING. Name them in one line and drop to rung 3.

**Order rungs 1 and 2 by PR `updatedAt`, falling back to `claimed_at` where there is no PR.**
That is a stand-in: `updatedAt` also moves when a bot comments or a label changes, so it ranks
recency of *activity*, not of your keystrokes. It is close enough to choose between branches
and wrong enough that the chosen row gets printed rather than assumed.


### Nothing to resume — the label board

Reached only when the ladder answered nothing, or when Dom typed `--board`. Print what is
worth working, then stop. **Do not pick a label yourself and do not fall through to `/auto`** —
there is nothing in flight to carry on with, so the scope is Dom's to choose.

Two traps make a raw `gh label list` useless:

- **Most labels are filters, not workstreams.** `P0`–`P3`, `status:*`,
  `effort:*`, `type:*`, `repo:*` are state, size and kind. Scoping to one slices
  every subject at once. Of 96 labels on 2026-08-30, **43** were workstreams.
- **Open count is the wrong number.** `/work` ships `status:ready`. A label with
  40 open and 0 ready is one `/work` does nothing with — `area:BILLING` (9 open)
  and `area:LEGAL` (8) were both exactly that. Rank on **ready**.

**One call**, then group locally — never loop `--label` per label (96 calls, and
the redirect returns `0` silently, so you would render a board of zeroes and
believe it):

```bash
gh issue list --repo mrdombie/maktura --state open --limit 2000 \
  --json number,labels -q '.[] | [([.labels[].name]|join(","))] | @tsv'
gh label list --repo mrdombie/maktura --limit 500 \
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
  > ~/.claude/socialhub-tickets/.session-label
echo "$MY_SESSION" > ~/.claude/socialhub-tickets/.session-label.owner
rm -f ~/.claude/socialhub-tickets/.stop-reason
touch ~/.claude/socialhub-tickets/.loop-active
```

Truncate-write, never append — one line, and it is the current scope or nothing.

**`.loop-active` is what arms the keep-going backstop.** `keep-working.sh` refuses your Stop
while this scope still has `status:ready` tickets and no stop reason is recorded. Nothing else
writes that file, which is how `/project` and `/standup` end turns freely with 469 ready
tickets on the board. Clearing `.stop-reason` at the same moment stops a previous loop's
reason from silencing this one.

**`.session-label` is one file for the whole machine, and six sessions write it.** So the scope
you read out of it is as likely to be a peer's as your own: on 2026-09-14 it said `project:echo`,
stamped one minute earlier by another session that was mid-triage. Taking that label would have
raced a peer into its own lane.

The owner file is what makes rung 3 safe, and it is deliberately a **sibling file, not a third
column** — `/standup`, `/project` and the sign-off all read `.session-label` with
`IFS=$'\t' read -r SCOPE SET_AT`, so a third field would land inside `SET_AT` and break the date
parsing rather than be ignored. A missing owner file means an unknown writer: still fine to
*display*, never enough to *resume* on.

**Local time with the offset, not UTC.** The file is per-machine and its only reader prints a
wall-clock time back to Dom. Stamping `...Z` made `/standup` show 16:11 for work done at 17:11,
because macOS `date -jf` reads a bare `Z` as local. `%z` carries the offset, so it both displays
directly and subtracts correctly.

**Write the RESOLVED value, not what Dom typed.** He types `ER`; the file holds
`project:event-registry`. A raw subject in there means `/standup` prints a label that does not
exist on any ticket.

| Argument form | `$SCOPE` |
|---|---|
| programme subject (`ER`, `welcome-flow`) | the resolved `project:` label |
| any other label (`flow-gap`) | that label |
| bare number (`9822`) | `ticket 9822` |
| **empty** / `--resume`, ladder answered | the scope the ladder resolved — rungs 1–2 write `ticket <n>` |
| **empty** / `--board`, label board reached | `rm -f` the file — Dom is choosing a scope, so there isn't one |

**3. Triage is scoped too.** Run `/auto`'s Step 1, but Tier 2 and Tier 3 only consider this
label. **Tier 1 still covers the whole estate** — a red trunk or a dead CI blocks your tickets
as surely as anyone's, and healing it is not out of scope.

**4. One extra stop condition.** This label's runnable list is empty — everything left is
gated, blocked, or parked on Dom. Report and stop. **Never widen to another label**; that is
`/auto`'s job and Dom chose the scope deliberately.

**5. Blockers move under you.** Re-resolve them every pass. Your own merge is usually what
unblocks the next ticket, and a ticket that was blocked at the start of the window is often the
best next thing by the end.

**6. Close with the run sheet, then the banner.** Render `/project <subject>` Steps 4–5 —
the headline figure and then **the run sheet**, one list of every ticket in the order it
gets done, per `~/.claude/shared/run-sheet.md`. That is the honest state, rather than a
diary of what you did, and it is what tells Dom how far through the label is without him
asking. Then sign off per `~/.claude/shared/agent-signoff.md`, with the resolved label as
the scope:

```
🏷️ Working on: Content Lab (project:content-lab)
   Shipped 3 · 1 in flight (draft cards, PR open)
   Also running: 2 agents on Welcome Flow
   Resume: /work content-lab
```

`Resume:` is `/work <what Dom typed>`, not the resolved label — he types subjects, and a
command he cannot retype is not a resume. **Where the run was resumed rather than typed, print
bare `/work`** — that is what he actually needs to type next, and it is the whole point of the
ladder.

**This fires on every handback, not just the end of the run.** A `/work` loop that pauses
for a pixel approval is the exact moment Dom starts a second agent, so it is the moment
the banner matters most. Line 2 says what it is paused ON.

## Running it unattended

`/work` is stateless — GitHub is the state — so a fresh window resumes by re-running the same
command, or by typing `/work` with nothing after it.

`.session-label` is no longer write-only. It is **rung 3** of the resume ladder, so deleting it
does change what a bare `/work` picks up: the ladder drops through to rung 4 and resolves the
label off the last ticket in `.session-tickets` instead. Both rungs sit below the live claim and
the open PR, so neither can send the loop somewhere there is unfinished work.

**This file cannot make the loop continue on its own.** It is instructions, not a runtime, and
the drift is real: on 2026-08-29 the model tried to hand back to Dom **twice** with context and
runnable tickets remaining.

`~/.claude/hooks/keep-working.sh` is the enforcement. It is a Stop hook, so it sees the moment
the turn ends and `exit 2`s the reason back — which continues the turn rather than ending it.
It fires only when **all** of these hold: `.loop-active` is fresh, no `.stop-reason` newer than
it, the scope is a label rather than `ticket <n>`, and that label still returns `status:ready`
rows from `mrdombie/maktura`. Six guards and a six-nag session budget keep it off the ~20x loop
that got its predecessor removed on 2026-08-30.

**Record the stop condition when one genuinely fires** — that is what turns the backstop off,
and it is a one-line write:

```bash
echo "<the condition, in one line>" > ~/.claude/socialhub-tickets/.stop-reason
```

| For | Use |
|---|---|
| it not giving up mid-window | `keep-working.sh` — armed automatically, nothing to type |
| the same, said out loud | `/goal every status:ready ticket under <label> is merged or its blocker is named` |
| surviving the window filling | `/work` — the ladder finds the scope again, no label to remember |
| pinning the scope anyway | re-run `/work <label>` |
| unattended across windows | `/loop /work` (or `/loop /work <label>` to hold one scope) |

**`/goal` is Claude Code's own built-in, and it is worth typing alongside the hook** — they
are the same mechanism with different evaluators. `/goal` is a session-scoped prompt-based
Stop hook: after every turn a small fast model reads the condition and the transcript and
returns met / not yet / impossible. `keep-working.sh` is a script Stop hook that queries
GitHub. The difference is the one that matters here — **the `/goal` evaluator does not call
tools, so it can only judge what has already been surfaced in the conversation.** A confident
summary can satisfy it. The hook reads the board and cannot be talked out of it.

So: `/goal` for the intent, the hook for the floor. Phrase the goal as **observable state**
(the label is empty, N tickets merged) — never 'until the context is full', which can only be
met by burning tokens and which neither evaluator can see.

**Claude Code overrides any Stop hook after 8 consecutive blocks without progress**, and
`/goal` stops its own loop when several turns pass with no tool use. `keep-working.sh` caps
itself at 6 nags a session, under the platform ceiling, so the two never race to it.

A permission-gate denial — reasoned or not — outranks the keep-going Stop hook: hold and
surface, never route around it. Writing `.stop-reason` is the correct response to one.

**Do not start a ticket you cannot finish before the window ends.** An unclaimed ticket costs
nothing; a claimed one with a half-built branch and no PR is a zombie that reads as progress to
`/project` and to every peer. If you must stop mid-build, push and open a **draft** PR so the
work is reachable, and say so.
