---
name: ui-gate
description: "Senior frontend review gate for code heading to develop. Runs the frontend-gate agent over a diff to catch the bug class lint/typecheck/tests miss — dead controls, fake-live data, parity regressions, token leaks, overflow, half-wired handlers — and SHIPs or SPITS-BACK with cited fixes. Usage: /agent-harness:ui-gate (current branch) | /agent-harness:ui-gate <PR#> | /agent-harness:ui-gate <branch> | add --fix to auto-apply mechanical fixes, --comment to post on the PR"
---

You are running `/agent-harness:ui-gate` for this repo. This is the **senior-dev / UI review gate** — the thing that looks at a ticket before it lands on `develop` and catches the "renders perfect, half of it is fake" failures that pass every automated gate (lint/typecheck/tests). It judges with the **frontend-gate** subagent (`.claude/agents/frontend-gate.md`) and then either clears the diff or bounces it with exact fixes.

## Guard
```bash
test -d .git && grep -q '"name"' package.json || { echo "Not in the repo"; exit 1; }
```

Run this at `/agent-harness:finish` time (before the merge to develop), or any time you want a senior eyeball on a UI diff.

## Args — `/agent-harness:ui-gate $ARGUMENTS`

Parse `$ARGUMENTS`:
- **empty** → review the **current branch** vs `origin/develop`.
- **a number** (e.g. `4434`) → review that **PR**: `gh pr checkout <n>` first if not already on it (or read it via `gh pr diff <n>`), base = the PR's base branch.
- **a branch name** → review that branch vs `origin/develop`.
- flags anywhere in args:
  - `--fix` → after the verdict, **apply every `auto-fixable: yes` finding** to the working tree, then re-run the gate to confirm. Without it, you only report (pure "spit it back").
  - `--comment` → post the findings as a PR review (requires a PR; use `gh pr comment` / `gh pr review`).

## Step 1 — resolve the diff
```bash
git fetch origin develop --quiet
BASE=origin/develop
git --no-pager diff --stat $BASE...HEAD        # what changed
git --no-pager diff --name-only $BASE...HEAD -- 'apps/web/**/*.tsx' 'apps/web/**/*.ts' 'packages/ui/**/*.tsx' 'packages/**/*.tsx'
```
Collect the changed **UI** files (`.tsx`, plus `.ts` that render or define UI types/hooks). If **zero** UI files changed, say "No UI surface in this diff — nothing for /agent-harness:ui-gate to judge" and stop (suggest `/code-review` for logic-only diffs). Note for each file whether it's under `app/dev/**` (preview — stubs allowed) or `app/dashboard/**` / `packages/ui` (authed/shared — stubs are bugs).

## Step 2 — run the gate
Spawn the **frontend-gate** subagent (Agent tool, `subagent_type: "agent-harness:frontend-gate"` — plugin agents carry the plugin name). Give it:
- the base ref (`origin/develop`), the changed-file list, and the absolute repo path,
- an instruction to **read each changed file in full** and judge against its nine lenses + `AGENTS.md`. **Lens 8 — mockup re-home:** if the diff rebuilds/redesigns a surface that has a mockup under `docs/design/source/`, tell the agent to read that mockup and confirm the render matches it (a "rebuild" that just re-wraps the old component is a BLOCKER).

For a **large diff** (>~12 changed UI files), fan out: group files by surface/directory and run one frontend-gate agent per group **in parallel** (one Agent message, multiple tool calls), then merge their verdicts — SPIT-BACK if any group is SPIT-BACK. For a normal ticket, one agent over the whole diff is right.

Do **not** re-run lint/typecheck/tests here — that's `gate-runner` / CI. This gate is exclusively about functional honesty + UI correctness.

## Step 3 — verdict
Relay the agent's verdict to the user, tight and skimmable:

```
🚦 /agent-harness:ui-gate — <branch or PR#> vs develop
VERDICT: SHIP ✅   (or  SPIT-BACK ⛔)

Blockers (N):
  ⛔ <file:line> — <control/value> — <rule broken> → <exact fix>  [auto-fixable]
Should-fix (N):
  ⚠️  …
Nits (N): …
```

- **SHIP** → say it's clear to merge to develop. If a PR and `--comment`, post an approving note.
- **SPIT-BACK** → this is the "bounce it back" path. Present the blockers as the rejection. If invoked inside `/agent-harness:finish`, **halt the merge** and hand the list back to the author/main agent to fix before re-running. If `--comment`, post the blockers as a requested-changes PR review.

## Step 4 — `--fix` (only if passed)
If `--fix` was given and there are `auto-fixable: yes` findings:
1. Apply **only** the auto-fixable ones in the working tree (truncation/`min-w-0`, `aria-label`, raw-token→brand-token swaps, honestly-disabling a dead button with a truthful tooltip + `TODO(#ticket)`). Honor the parity-lock and brand-token rules while fixing — never restructure a locked surface, never touch the accepted coral-gradient idiom.
2. Re-run the frontend-gate agent on the new diff to confirm those findings cleared and nothing regressed.
3. Report: what was auto-fixed, and the residual `auto-fixable: no` items that **still** need the author (real API wiring, data-flow, design calls). Auto-fix never turns a SPIT-BACK into a SHIP on its own if blockers needing real work remain — say so plainly.

For any disabled-as-fix, if there's no follow-up ticket, **file one** (`gh issue create`, parent the relevant EPIC) and put its number in the `TODO(#…)`. A dead control may only become an honestly-disabled control if it points at a real ticket — that's the AGENTS.md rule this gate enforces.

## Notes
- **Read-only by default.** Without `--fix`, this command never edits — it reports and bounces. That keeps it safe to run on anyone's branch.
- **Pairs with, doesn't replace:**
  - `gate-runner` (lint/type/test),
  - `/code-review` (deep logic bugs),
  - `/critic` + `design-critic` (rendered anti-slop),
  - the automated **`review-gate`** skill (post-merge `develop → uat` audit). `/agent-harness:ui-gate` is the **pre-merge** twin: catch dead controls/fake data *before* they land on develop, where `review-gate` catches whatever slips through *before* it reaches UAT.
  `/agent-harness:ui-gate` owns the *functional-honesty + UI-correctness* slice — the gap the others leave.
- **Wired into /agent-harness:finish (#8671):** this is a pre-merge step, not a command anyone has to remember. `/agent-harness:finish` Gate 4 refuses the merge on any UI- or `packages/ui`-touching PR without a **SHIP** verdict, and Gate 5 refuses it again if the head has moved since that verdict was taken. So when you run this, export the result for `/agent-harness:finish` to read:

  ```bash
  export UI_GATE_VERDICT=SHIP            # or SPIT-BACK
  export UI_GATE_SHA=$(git rev-parse HEAD)
  ```

  Record the SHA you actually reviewed. A verdict without one is refused, because a review that does not name its commit cannot be checked against the thing being merged — that is how #8405 shipped eight defects on 2026-08-06.
- The law this gate enforces lives in `AGENTS.md` (§"No dead controls, no fake-live data", §"Wiring must preserve the approved design", §"Create (Beta) … LOCKED", §"Shipping discipline"). Keep the agent and that file in sync — if a new failure mode shows up, add it to both.
