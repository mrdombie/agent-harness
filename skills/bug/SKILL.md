---
name: bug
description: "Take a bug from the operator's outline to merged, in one motion: reproduce → file → claim → fix → gate → merge to develop. Runs the whole chain without stopping between stages, except the design pause when pixels change. Usage: /agent-harness:bug \"<what's broken>\" | /agent-harness:bug NNNN (an already-filed bug)"
---

You are running `/agent-harness:bug`. The operator describes a bug; you take it all the way to merged on
`develop` and report back. This command is the **chain** — it owns no logic of its
own, it sequences `systematic-debugging` → `/agent-harness:file` → `/agent-harness:claim` → `/design` (only if
pixels move) → `/agent-harness:ui-gate` → `/agent-harness:finish` and refuses to skip a link.

**One bug at a time.** Do not start, offer, or triage other work while a `/agent-harness:bug` run
is open. The whole point is that the operator points at one thing and it goes away.

## Args — `/agent-harness:bug $ARGUMENTS`

- **quoted prose** → a new bug. Start at Step 1.
- **a bare number** (e.g. `9142`) → a bug already filed. Read the issue, then start
  at Step 1 anyway — an existing ticket is a *report*, not a reproduction, and
  Step 1 is what turns it into one. Skip Step 2's `gh issue create`; update the
  existing issue instead.
- **empty** → ask the operator what's broken. One question, then run.

## Step 1 — Reproduce before you write anything

Run **`superpowers:systematic-debugging`**. No ticket, no branch, no fix until the
fault is proven in the code or on a live surface.

This step is non-negotiable because a bug ticket's value is the reproduction, not
the description — `/agent-harness:file` already says so for exactly this reason. Filing from
The operator's prose alone produces an AC that is a guess, and a guessed AC produces a fix
that closes the ticket without fixing the bug.

Three failure modes to check for by name before you accept a diagnosis:

- **Fix the matrix, not the reported cell.** A "UI says X, engine says Y" bug is
  never one string. #9160 bounced three times off `/agent-harness:ui-gate`, each blocker the same
  defect one enum further out. Enumerate the full matrix and fix all of it.
- **Wired ≠ running.** Query UAT before you diagnose a surface. A module with a
  green unit suite may not be reachable from the app at all.
- **Re-verify the premise.** If the operator says "X is broken", confirm X exists and is
  what they mean. Some reports are about the feature next to the one named.

Come out of this step with: the reproduction, the root cause, and the file:line.

## Step 2 — File the ticket

Now run **`superpowers:brainstorming`** over the *fix*, not the fault. Step 1 settled
what is broken; brainstorming settles how far the fix reaches — scope, edge cases,
what stays broken on purpose. The PM asked for this interrogation explicitly (Dom, 2026-08); do not
collapse it into a one-line ticket because the root cause looks obvious.

Post it:

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
gh issue create --repo "$REPO_SLUG" \
  --title "fix(<scope>): <what stops being broken>" \
  --body-file <the spec> \
  --label "$LBL_DRAFTING,P?,type:bug,area:?,effort:?"
```

- The **reproduction and root cause go in the AC**, not in prose above it. Same for
  any stack decision the fix commits to.
- `gh label list --repo "$REPO_SLUG"` is the source of truth for labels, not
  memory. A ticket missing `area:` or `status:` is invisible to `/agent-harness:queue` and `/agent-harness:claim`.
- **Never file as `$LBL_IN_REVIEW` (in-review)** — a ticket in that state with no PR is held by
  nothing and offered to no one.
- Do **not** guess a `needs:` label at filing time.

Then promote it: `$LBL_DRAFTING` → `$LBL_READY`. `/agent-harness:file` keeps these separate
deliberately, and this is the deliberate act — the operator authorised the build by invoking
`/agent-harness:bug`.

## Step 3 — Claim it

```
/agent-harness:claim <the issue number>
```

**This step cannot be skipped.** `/agent-harness:finish` refuses to run from a main repo clone and
verifies a live claim ref exists in `refs/claims/<issue>` (finish.md Step 1). Fixing
in place and going straight to `/agent-harness:finish` dead-ends the whole motion at the last step
with the work already done.

`/agent-harness:claim` places you in a per-claim worktree on branch `${BRANCH_PREFIX}NNN/<slug>`, generates the
Prisma client, and takes the atomic claim. Edit the **worktree**, never the main repo
path.

## Step 4 — Design pause, only if pixels change

If the fix alters anything visible, stop and hand it to **`/design <surface> "<brief>"`**
from inside the claim worktree. It reuses the branch and pauses at the `:3010` preview
URL for the operator's approval, with nothing merged.

A human approves pixels. Send the operator the **URL, not a screenshot**. Wait for approval before
Phase 2 wiring.

If nothing visible changes, skip to Step 5. Do not invent a design phase for a
backend fix.

## Step 5 — Fix it

- The design kit (`$DESIGN_KIT`) only; brand tokens only, never Tailwind defaults. Anything the fix
  needs that the kit lacks gets built **into** `packages/ui`.
- Write the failing test first wherever the bug is testable — a bug you can reproduce
  in code is a bug you can pin with a test, and that test is what stops the regression.
- Fix the whole matrix Step 1 identified, not the one cell the operator happened to see.
- Do not leave a confident comment explaining a fix you are unsure of. Code gets
  re-derived on review; prose gets believed.

## Step 6 — Gate

Run both, they are not substitutes:

```
/agent-harness:ui-gate          # functional honesty — dead controls, fake-live data, parity
/critic <route>   # rendered anti-slop, if the fix touches a surface
```

`/agent-harness:ui-gate` is already wired into `/agent-harness:finish` as Gate 4/5, and `/agent-harness:finish` refuses the
merge on a UI-touching PR without a **SHIP** verdict tied to the exact SHA. Export it:

```bash
export UI_GATE_VERDICT=SHIP
export UI_GATE_SHA=$(git rev-parse HEAD)
```

**SPIT-BACK halts the motion.** Fix the blockers, re-gate, re-export the new SHA. Do
not carry a stale verdict past a new commit.

**Never batch a gate with a push in one shell line.** `gate && git push` pushes on the
shell's exit status, not the gate's verdict.

If the fix touches deploy behaviour, **append** to the root `.deploy-trigger` with
`>>`. `npm run check:deploy-trigger` prints the real path; `apps/.deploy-trigger` is a
tracked decoy the gate never reads.

## Step 7 — Ship

```
/agent-harness:finish
```

Gates → push → PR → merge to `develop` → close the issue → release the claim → append
to the closed issue.

**A bug does NOT merge on its own if it changes what a user sees.** The approval gate
keys on the **diff**, not the ticket type: any PR whose diff touches a user-visible
surface gets the hold label (`$HOLD_LABEL`) applied automatically at PR-open, and stays red until
A human removes the label, or a peer approves the PR. `type:feature` is an additional trigger, not the only one.

Two consequences to plan for rather than discover:

- **Commit the rendered shots to `docs/evidence/<issue>/`** and link them SHA-pinned in
  the PR body. Not `docs/mockups/`, which the gate does not read, and never a
  `raw.githubusercontent.com` URL — the repo is private, so those render broken for
  every reader while satisfying a naive grep.
- **Never remove the label to unblock yourself.** The removal IS the sign-off and is
  recorded in the PR timeline. Hand the PR back and stop.

So a pixel-changing bug ends at "green but held", and that is the correct finish. Say so
plainly rather than reporting it as merged.

### Handing a held PR back — always give the operator the one-click

**Every hand-back ends with the direct PR link and the approve instruction.** A held PR
that the operator has to go hunting for is a held PR that sits for days. Close the report with:

```
Held on your approval: https://github.com/$REPO_SLUG/pull/<n>
Reply "approve <n>" and I'll clear it.
```

**When the operator says "approve <n>"** (or "yup", "go", "ship it" against a named PR), that is
the deliberate act the gate exists to capture. Clear it and record who decided:

```bash
"$KIT_ROOT/scripts/clear-hold.sh" <n>   # one motion, shared with /agent-harness:needsme
```

Comment **before** removing the label, so the record exists even if the removal races
with automerge.

**This is not the thing AGENTS.md forbids.** That rule is an agent clearing its own
blocker *unasked* — "do not remove it to unblock yourself". Here the instruction comes
from the operator. The comment matters because every agent acts through their token, so GitHub
cannot tell their click from mine; the timeline entry is the only thing that records
which it was. Never clear the label without an explicit instruction naming the PR, and
never infer approval from general enthusiasm about the work.

## Report back

Tables, not prose blocks. Name the thing, not the ticket number — "the connection
health banner", not "#9142". State plainly what merged and what did not. If any part
of the fix was left out, say which part and why; scaling the fix down is the operator's call.

**Then sign off**, per `${CLAUDE_PLUGIN_ROOT}/shared/agent-signoff.md`. The scope is the bug's own
area label, and `/agent-harness:bug` writes it to `.session-label` the moment the ticket is filed:

```bash
printf '%s\t%s\n' "$SCOPE" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
  > "$STATE_DIR/.session-label"
```

```
🏷️ Working on: the connection health banner (area:ACCESS)
   Shipped 1 — the banner stops reporting a dead connection as live
   Also running: 2 agents on Welcome Flow
   Resume: nothing — this one is done
```

This prints whether the bug merged, stalled at the design pause, or turned out to be
something else. A `/agent-harness:bug` that stops without it is the one the operator re-reports.

## What this does not do

- It does not pick its own work. That is `/agent-harness:auto`. `/agent-harness:bug` goes where the operator points.
- It does not stop between stages for approval, except the Step 4 design pause.
- It does not open a second branch for the design and the wiring — one branch, one PR.
- It does not promote to UAT. The review gate owns `develop` → `uat`.
