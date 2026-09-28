---
description: "Maktura — take a bug from Dom's outline to merged, in one motion: reproduce → file → claim → fix → gate → merge to develop. Runs the whole chain without stopping between stages, except the design pause when pixels change. Usage: /bug \"<what's broken>\" | /bug NNNN (an already-filed bug)"
---

You are running `/bug`. Dom describes a bug; you take it all the way to merged on
`develop` and report back. This command is the **chain** — it owns no logic of its
own, it sequences `systematic-debugging` → `/file` → `/claim` → `/design` (only if
pixels move) → `/ui-gate` → `/finish` and refuses to skip a link.

**One bug at a time.** Do not start, offer, or triage other work while a `/bug` run
is open. The whole point is that Dom points at one thing and it goes away.

## Args — `/bug $ARGUMENTS`

- **quoted prose** → a new bug. Start at Step 1.
- **a bare number** (e.g. `9142`) → a bug already filed. Read the issue, then start
  at Step 1 anyway — an existing ticket is a *report*, not a reproduction, and
  Step 1 is what turns it into one. Skip Step 2's `gh issue create`; update the
  existing issue instead.
- **empty** → ask Dom what's broken. One question, then run.

## Step 1 — Reproduce before you write anything

Run **`superpowers:systematic-debugging`**. No ticket, no branch, no fix until the
fault is proven in the code or on a live surface.

This step is non-negotiable because a bug ticket's value is the reproduction, not
the description — `/file` already says so for exactly this reason. Filing from
Dom's prose alone produces an AC that is a guess, and a guessed AC produces a fix
that closes the ticket without fixing the bug.

Three failure modes to check for by name before you accept a diagnosis:

- **Fix the matrix, not the reported cell.** A "UI says X, engine says Y" bug is
  never one string. #9160 bounced three times off `/ui-gate`, each blocker the same
  defect one enum further out. Enumerate the full matrix and fix all of it.
- **Wired ≠ running.** Query UAT before you diagnose a surface. A module with a
  green unit suite may not be reachable from the app at all.
- **Re-verify the premise.** If Dom says "X is broken", confirm X exists and is
  what he means. Some reports are about the feature next to the one named.
- **Reproduce on a real render.** `/dev/*` needs no login; an authed `/dashboard/*` needs BOTH apps run from the worktree via `npx dotenv -e .env` with `AUTH_URL` on the port you browse (root `.env` pins :3000).
- **No login for a `/dashboard/*` component?** Mount it with stub props on a throwaway public `/dev/<name>/page.tsx`, second server with `--webpack`, drive it with Playwright — `/demo` writes are pretend-successes and prove nothing about persistence.

Come out of this step with: the reproduction, the root cause, and the file:line.

## Step 2 — File the ticket

Now run **`superpowers:brainstorming`** over the *fix*, not the fault. Step 1 settled
what is broken; brainstorming settles how far the fix reaches — scope, edge cases,
what stays broken on purpose. Dom asked for this interrogation explicitly; do not
collapse it into a one-line ticket because the root cause looks obvious.

Post it:

```bash
gh issue create --repo mrdombie/maktura \
  --title "fix(<scope>): <what stops being broken>" \
  --body-file <the spec> \
  --label "status:drafting,P?,type:bug,area:?,effort:?"
```

- The **reproduction and root cause go in the AC**, not in prose above it. Same for
  any stack decision the fix commits to.
- `gh label list --repo mrdombie/maktura` is the source of truth for labels, not
  memory. A ticket missing `area:` or `status:` is invisible to `/queue` and `/claim`.
- **Never file as `status:in-review`** — a ticket in that state with no PR is held by
  nothing and offered to no one.
- Do **not** guess a `needs:` label at filing time.
- Reported by a beta tester? Add `beta-feedback` alongside the normal set — never for Dom's own reports or review-gate findings.

Then promote it: `status:drafting` → `status:ready`. `/file` keeps these separate
deliberately, and this is the deliberate act — Dom authorised the build by invoking
`/bug`.

## Step 3 — Claim it

```
/claim <the issue number>
```

**This step cannot be skipped.** `/finish` refuses to run from a main repo clone and
verifies a live claim ref exists in `refs/claims/<issue>` (finish.md Step 1). Fixing
in place and going straight to `/finish` dead-ends the whole motion at the last step
with the work already done.

`/claim` places you in a per-claim worktree on branch `sh-NNN/<slug>`, generates the
Prisma client, and takes the atomic claim. Edit the **worktree**, never the main repo
path.

## Step 4 — Design pause, only if pixels change

If the fix alters anything visible, stop and hand it to **`/design <surface> "<brief>"`**
from inside the claim worktree. It reuses the branch and pauses at the `:3010` preview
URL for Dom's approval, with nothing merged.

Dom approves pixels. Send him the **URL, not a screenshot**. Wait for approval before
Phase 2 wiring.

If nothing visible changes, skip to Step 5. Do not invent a design phase for a
backend fix.

## Step 5 — Fix it

- `@maktura/ui` only; brand tokens only, never Tailwind defaults. Anything the fix
  needs that the kit lacks gets built **into** `packages/ui`.
- Write the failing test first wherever the bug is testable — a bug you can reproduce
  in code is a bug you can pin with a test, and that test is what stops the regression.
- Fix the whole matrix Step 1 identified, not the one cell Dom happened to see.
- Do not leave a confident comment explaining a fix you are unsure of. Code gets
  re-derived on review; prose gets believed.
- When the root cause sits inside a dependency, confirm the behaviour against its
  current docs in Context7 (`resolve-library-id` → `query-docs`) before fixing
  around it. A fix built on the remembered API is a second bug with a test.

## Step 6 — Gate

Run both, they are not substitutes:

```
/ui-gate          # functional honesty — dead controls, fake-live data, parity
/critic <route>   # rendered anti-slop, if the fix touches a surface
```

`/ui-gate` is already wired into `/finish` as Gate 4/5, and `/finish` refuses the
merge on a UI-touching PR without a **SHIP** verdict tied to the exact SHA. Export it:

```bash
export UI_GATE_VERDICT=SHIP
export UI_GATE_SHA=$(git rev-parse HEAD)
```

**SPIT-BACK halts the motion.** Fix the blockers, re-gate, re-export the new SHA. Do
not carry a stale verdict past a new commit.

**Never batch a gate with a push in one shell line.** `gate && git push` pushes on the
shell's exit status, not the gate's verdict.

If the fix touches deploy behaviour, run `sh scripts/bump-deploy-trigger.sh` — never hand-write
or `>>` the root `.deploy-trigger`; the script writes all three sentinels at a per-branch anchor,
and an EOF append conflicts with every peer's. `apps/.deploy-trigger` is a tracked decoy the gate
never reads.

## Step 7 — Ship

```
/finish
```

Gates → push → PR → merge to `develop` → close the issue → release the claim → append
to `MERGED.tsv`.

**A bug does NOT merge on its own if it changes what a user sees.** The approval gate
keys on the **diff**, not the ticket type: any PR whose diff touches a user-visible
surface gets `needs:dom-approval` applied automatically at PR-open, and stays red until
Dom removes the label. `type:feature` is an additional trigger, not the only one.

Two consequences to plan for rather than discover:

- **Commit the rendered shots to `docs/evidence/<issue>/`** and link them SHA-pinned in
  the PR body. Not `docs/mockups/`, which the gate does not read, and never a
  `raw.githubusercontent.com` URL — the repo is private, so those render broken for
  every reader while satisfying a naive grep.
- **Never remove the label to unblock yourself.** The removal IS the sign-off and is
  recorded in the PR timeline. Hand the PR back and stop.

So a pixel-changing bug ends at "green but held", and that is the correct finish. Say so
plainly rather than reporting it as merged.

### Handing a held PR back — always give Dom the one-click

**Every hand-back ends with the direct PR link and the approve instruction.** A held PR
that Dom has to go hunting for is a held PR that sits for days. Close the report with:

```
Held on your approval: https://github.com/mrdombie/maktura/pull/<n>
Reply "approve <n>" and I'll clear it.
```

**When Dom says "approve <n>"** (or "yup", "go", "ship it" against a named PR), that is
the deliberate act the gate exists to capture. Clear it and record who decided:

```bash
gh pr comment <n> --repo mrdombie/maktura --body "Approved by Dom in the agent window on <date>. \`needs:dom-approval\` cleared on his instruction — the decision is his, the keystroke is mine."
gh pr edit <n> --repo mrdombie/maktura --remove-label "needs:dom-approval"
```

Comment **before** removing the label, so the record exists even if the removal races
with automerge.

**This is not the thing AGENTS.md forbids.** That rule is an agent clearing its own
blocker *unasked* — "do not remove it to unblock yourself". Here the instruction comes
from Dom. The comment matters because every agent acts through his token, so GitHub
cannot tell his click from mine; the timeline entry is the only thing that records
which it was. Never clear the label without an explicit instruction naming the PR, and
never infer approval from general enthusiasm about the work.

## Report back

Tables, not prose blocks. Name the thing, not the ticket number — "the connection
health banner", not "#9142". State plainly what merged and what did not. If any part
of the fix was left out, say which part and why; scaling the fix down is Dom's call.

**Then sign off**, per `~/.claude/shared/agent-signoff.md`. The scope is the bug's own
area label, and `/bug` writes it to `.session-label` the moment the ticket is filed:

```bash
. ~/.claude/hooks/lib/claude-session.sh   # one definition of "which session am I"
printf '%s\t%s\n' "$SCOPE" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
  > ~/.claude/socialhub-tickets/.session-label
claude_session_pid > ~/.claude/socialhub-tickets/.session-label.owner
```

```
🏷️ Working on: the connection health banner (area:ACCESS)
   Shipped 1 — the banner stops reporting a dead connection as live
   Also running: 2 agents on Welcome Flow
   Resume: nothing — this one is done
```

This prints whether the bug merged, stalled at the design pause, or turned out to be
something else. A `/bug` that stops without it is the one Dom re-reports.

## What this does not do

- It does not pick its own work. That is `/auto`. `/bug` goes where Dom points.
- It does not stop between stages for approval, except the Step 4 design pause.
- It does not open a second branch for the design and the wiring — one branch, one PR.
- It does not promote to UAT. The review gate owns `develop` → `uat`.
