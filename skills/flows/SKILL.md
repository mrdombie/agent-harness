---
name: flows
description: "Find the flows a screen SHOULD have and doesn't. Derives the required flow set from the screen's job — blind to the code — then hunts each one in the implementation and reports what is missing. The complement to a control inventory, which can only see controls that exist. Use for: auditing a screen or a multi-screen sequence for gaps, \"what's broken about this flow\", \"does this screen handle X\", proving a surface is complete before or after it ships. Usage: /agent-harness:flows <route> \"<the screen's job, one line>\" | /agent-harness:flows <route> <route> ... \"<job>\" (a sequence, audited as one unit)"
---

# Flow-coverage audit

## The problem this exists for

Every other review reads the code and reports on what it finds:

| Review | Reads | Blind to |
|---|---|---|
| A control inventory (a manifest of the screen's controls) | the rendered screen | a control that was never drawn |
| `/agent-harness:ui-gate` | the diff | anything absent from the diff |
| A design critic | a screenshot | a flow with no pixels |

All three run **code → list**. A missing flow has no row to be missing from. An inventory
is a map, not a guard.

This skill runs the other direction: **job → code**. Derive what the screen must do from what
it is *for*, then go looking. What you cannot find is the finding.

## The one rule

**The model is derived blind.** The agent that writes the expected-flow list must not have
read the implementation, the inventory, the tickets, or a summary of any of them. A model
derived from the code inherits the code's blind spots and will do nothing but confirm what is
already there.

This is not a preference. It is the only thing separating this from a re-read of the inventory.

## Shape

```
CARTOGRAPHER (blind, no tools)             CHECKER (subagent, code only)
  in:  the screen's JOB, one line            in:  the expected rows + a pinned tree
       + TAXONOMY.md                         does: hunts each row, cites file:line
  CANNOT open the repo                       MUST NOT add, merge or reword a row
  out: numbered EXPECTED flow rows           out: a verdict + evidence per row
```

The cartographer is the `flow-cartographer` agent. It has no tools, so blindness is a
property of the agent, not a promise in its prompt. Its whole prompt is printed by:

```bash
scripts/flow-audit.sh brief cartographer --job "<the screen's job, one line>"
```

That prints the job line and `TAXONOMY.md`, and nothing from the repo. A job line holding a
path, a file name or a URL is refused with exit 2: write what a person is trying to get done,
not where the code lives. Hand the agent that output and nothing else.

The orchestrating session cannot be the cartographer — by the time it has decided a flow
audit is warranted it has normally read some of the code. Never write the rows yourself.

The checker may be several agents in parallel over row ranges, provided each gets the same
tree and the same instruction not to invent rows.

On a picture (before the screen is built) the checker is the `flow-checker` agent, which
clicks the clickable Storybook story rather than reading code. Its prompt is printed by:

```bash
scripts/flow-audit.sh brief checker --rows <cartographer-rows.md> --story "<http(s)://.../iframe.html?id=...>"
```

That carries every row of the cartographer's file unchanged, the five verdicts and the rule
that no row is added. A story URL without `iframe.html?id=` (a freehand HTML mock) or a rows
file with no `E-01`-shaped row is refused with exit 2.

## Verdicts

The checker returns exactly one per row:

| Verdict | Means |
|---|---|
| `PRESENT` | a cited path handles it |
| `PARTIAL` | handled on one branch and not the others — say which |
| `WRONG` | handled, but the behaviour contradicts something the screen states or promises |
| `ABSENT` | no path handles it. The finding. |
| `UNVERIFIED` | code for it exists, but static reading cannot prove any control reaches it |

`UNVERIFIED` exists because a static audit cannot see reachability. Built-but-unreachable is a
real failure mode and it reads as `PRESENT` to anyone grepping. Never collapse it into
`PRESENT` to make a coverage number look better — an honest `UNVERIFIED` is the whole value of
having the verdict.

A checker that returns no `ABSENT` rows on a screen anybody has complained about has usually
been too generous. `PARTIAL` and `PRESENT` are claims that need a citation; if the citation is
"the component probably handles this", the verdict is `ABSENT`.

## Severity — assigned after the check, from what was found

Ordered by what it does to a person, not by effort to fix:

1. **STRANDS** — no way forward and no way back. Someone is stuck.
2. **LIES** — the screen states something untrue, or presents an inference as a measurement.
3. **SILENT** — it fails and says nothing; the person cannot tell a failure from a normal result.
4. **ROUGH** — works, but badly.

## The gap row — how a finding is written

Broadcast the test, not the conclusion. A conclusion cannot be checked by the receiver; a
reproducible move can.

```markdown
### GAP-NN · SEVERITY · short name
**Axis:** N Axis-name (sub-case)
**The move:** the concrete thing a person does, in steps, from a state that is easy to reach.
**What happens now:** the observable outcome, with `path:line` proof.
**What should happen:** one sentence.
**Evidence:** `path:line`, `path:line`
```

`The move` is the deliverable. Everything else supports it. If you cannot write the move, you
have a suspicion, not a finding — mark the row `UNVERIFIED` and say what would settle it.

## Running it

1. **Pin the tree.** Read the integration branch from the project's config
   (`jq -r .integrationBranch .claude/harness.json`), fetch it, record its SHA and audit a
   read-only worktree at it. Every verdict is stamped with that SHA so a stale report is
   visibly stale. Never audit a local checkout without checking how far behind it is.
2. **Scope by sequence, not by folder.** If the job spans several screens, audit them as one
   unit — the interesting gaps cross screens (leave on step 1, round-trip out, come back
   somewhere else entirely). A per-screen audit cannot see them.
3. **Cartographer** — the `flow-cartographer` agent, given the output of
   `flow-audit.sh brief cartographer` and nothing else.
4. **Checker** — expected rows + the pinned tree, told explicitly to reach *beyond* the route
   folder into the endpoints and callbacks the flows touch.
5. **Report** — `REPORT-TEMPLATE.md`. Coverage table first, then the gaps in severity order.
6. **Stop.** The report is the deliverable. Tickets get filed from the owner's picks, not from
   the report wholesale.

## Proving the audit is measuring something

A coverage report that cannot fail is a compliment, not a measurement. Before trusting a first
run on a new surface:

- **Contamination check.** The expected list must contain rows naming behaviours that appear
  nowhere in the surface. If every row maps onto an existing control, the cartographer was not
  blind and the run is void.
- **Plant test.** Re-run the checker over a copy of the tree with one known handler removed.
  It must move that row to `ABSENT`. A checker that reports identical coverage on a broken
  tree is measuring nothing.
- **Re-run.** Same SHA, same job → the counts should match. Large drift means the taxonomy is
  being applied by feel.

## Relationship to a control inventory

Where the project keeps an inventory of each screen's controls, the two are complements and
neither replaces the other.

| | Control inventory | Flow audit |
|---|---|---|
| Direction | code → list | job → code |
| Answers | is every control wired? | is every required flow built? |
| Lives | co-located, permanent, in the diff | a dated report against a SHA |
| Cannot see | a flow nobody drew | a control that exists for no flow |

Read the inventory **after** the audit, never before — it is the best available check on the
checker's `ABSENT` calls, and the worst possible input to the cartographer.
