**Sign-off comes last:** once the owner has signed a PR's screens, push no change to them. Its screens are `design.surfacePaths` plus `design.extraScreens` (`approval-kept.sh screens`); release notes are not screens. A review note that would change pixels becomes a follow-up ticket; a required fix that must change pixels says `pixel-change-after-signoff: <why>` in its commit message, and the pre-push guard (`scripts/signoff-push-guard.sh`) puts the hold back on for the owner to sign again.

# Step 6 · Fix what blocks

You are clearing the review's blocking findings (from round 2, its Minors went on
the screen's polish list). Nothing else — a Nit was dropped.

## Invoke the skill — do not work from this file

Run **`superpowers:receiving-code-review`** on the findings, and
**`superpowers:test-driven-development`** for each fix. Those own how a finding is
weighed and how the cycle runs; this brief owns what the driver needs back.

## What you are given

- The findings that block: {{BLOCKERS}}
- The independent critic's open findings on this ticket's pull request: {{CRITIC_FINDINGS}}

**What you touch, you fix.** A finding whose id starts `polish-` is an item already on the polish list of a screen this change touches. Fix it here, whoever put it there, then record it with the exact `take` command its fix names: the next review clears an item only once it is recorded. A critic finding above is fixed the same way; the critic judges the screen again after CI photographs it.
- The evidence this pull request still owes: {{EVIDENCE_TASKS}}

**Evidence owed is a task, not a note.** A missing shot (a region, an opened state, dark, the phone width) is answered by an edit to the capture plan, committed — a code change alone leaves it open, and the critic fails the PR again.
- The change as it stands: {{DIFF}}
- The round: {{ROUND}}
- Proof limits: {{PROOF_LIMITS}}

## Trace the failure path before you land a fix

Ask what a person sees when this throws, nulls, or runs where the checks do not
reach.

- **Do not accept a failure as pre-existing until you have re-verified it** in a
  tree whose generated artefacts exist. A fresh worktree reports failures of its
  own — a missing generated client, an absent environment file, a workspace
  package resolving to another checkout's copy.
  Prove it against a pristine control cut from the trunk first.
- **Changed a value?** Grep the whole test tree for the old one and add every hit
  to the run.
- **A peer may have landed the same feature while you worked.** Reconcile against
  the trunk, keep only the part that is genuinely additive, and file the rest.

A finding you think is wrong is answered with a reason, not with agreement and a
change.

## When the findings are red gates

A `gate-` finding is not a review finding: one of this project's
self-check gates went red, and its output is the finding. Repair what the output
names, run that gate's command yourself until it exits 0, commit, and answer each
in `gateFixes` with the commit. There is no red/green test for a compile or lint
error; the driver re-runs every gate straight after this step, and nothing is
pushed past a red one. A red gate you believe this change did not cause goes in
`deferred` with the proof — that parks the ticket for a person.

A gate killed, or red only on a test outside this change, is load, never a
question: re-run it; green, answer it in `gateFixes` with the head commit.

A ratchet whose baseline sits ABOVE actual, or names entries that no longer
exist, means the change made things better: run the lowering command it prints,
commit the lowered baseline, and never undo the improvement. Only a number that ROSE wants a code fix.

## A test you reword or remove is accounted for

If you remove, reword or skip an `it(`/`test(` case, list its file in
`replacedTests` (the repo-relative path git shows) with exactly one of `coveredBy`,
a bare path to the test that now pins it, or `removedBecause`.

**Git your permission mode refuses** (a reset, dropping commits origin already has,
finishing a merge) is never run and never a question: list it in `gitActions`, and
the driver checks it and runs it after your answer.

## A PM answer already on the ticket

{{PM_ANSWERS}}

A blocking finding one of these names and accepts a non-test proof for (a
mutation, or the fixing commit) goes in `pmProofs` citing its ref, never in
`deferred`. The driver checks it. No such answer, no `pmProofs`.

## Cleared by editing the PR description

Answer it in `bodyProofs`, naming the repo's check that reads the description.
The driver runs it on the description now (must pass) and as reviewed (must fail).

## Return

JSON only, valid against `schemas/fix.json`.

<!-- fields:begin — generated from schemas/fix.json by briefs/return-fields.sh --write fix; edit the schema, never this list -->
Every field the contract has; `additionalProperties` is false, so no other.

- `step` (required): "fix"
- `skills` (required): list of string
- `status` (required): one of "fixed", "park"
- `round` (required): integer
- `cleared`: list of object
- `cleared[].blockerId` (required): string
- `cleared[].change` (required): list of object
- `cleared[].change[].path` (required): string
- `cleared[].change[].action` (required): one of "create", "modify", "delete"
- `cleared[].test` (required): object
- `cleared[].test.file` (required): string
- `cleared[].test.behaviour` (required): string
- `cleared[].test.redWhen` (required): string
- `cleared[].command` (required): string
- `cleared[].failedBefore` (required): true
- `cleared[].passedAfter` (required): true
- `cleared[].testCommit` (required): string
- `cleared[].implCommit` (required): string
- `deferred`: list of object
- `deferred[].blockerId` (required): string
- `deferred[].reason` (required): string
- `deferred[].followUp` (required): string
- `question`: string
- `questionFor`: one of "owner", "pm"
- `notes`: string
- `replacedTests`: list of object
- `replacedTests[].file` (required): string
- `replacedTests[].coveredBy`: string
- `replacedTests[].removedBecause`: string
- `gateFixes`: list of object
- `gateFixes[].blockerId` (required): string
- `gateFixes[].change` (required): list of object
- `gateFixes[].change[].path` (required): string
- `gateFixes[].change[].action` (required): one of "create", "modify", "delete"
- `gateFixes[].commit` (required): string
- `pmProofs`: list of object
- `pmProofs[].blockerId` (required): string
- `pmProofs[].pmAnswer` (required): string
- `pmProofs[].kind` (required): one of "mutation", "commit"
- `pmProofs[].commit` (required): string
- `pmProofs[].testFile`: string
- `pmProofs[].command`: string
- `pmProofs[].break`: object
- `pmProofs[].break.file` (required): string
- `pmProofs[].break.find` (required): string
- `pmProofs[].break.replace` (required): string
- `autoProofs`: list of object
- `autoProofs[].blockerId` (required): string
- `autoProofs[].kind` (required): one of "docs-only", "comment-only", "wording-only", "test-only"
- `autoProofs[].commit` (required): string
- `autoProofs[].testFile`: string
- `autoProofs[].command`: string
- `autoProofs[].break`: object
- `autoProofs[].break.file` (required): string
- `autoProofs[].break.find` (required): string
- `autoProofs[].break.replace` (required): string
- `bodyProofs`: list of object
- `bodyProofs[].blockerId` (required): string
- `bodyProofs[].command` (required): string
- `gitActions`: list of object
- `gitActions[].action` (required): one of "commitMerge", "resetTo", "dropLocalCommits"
- `gitActions[].sha`: string

Conditional:
- when `status` is "fixed": at least one of `cleared`, `gateFixes`, `pmProofs`, `autoProofs`, `bodyProofs`
- otherwise: requires `question`
<!-- fields:end -->

One `cleared` entry per review finding: the change, the test that goes red when
it returns, and the red and green runs.

`testCommit` and `implCommit` must be two commits: the driver runs `command`
verbatim from the worktree root at the change's parent and at the change. Give
the exact command, no placeholders: where the project has a test database,
`DATABASE_URL` is already set to a fresh migrated one, here and in the proof.

A finding you are not clearing goes in `deferred` with its reason and where it
went. A deferral with no follow-up is a finding dropped — and a Critical or a
Major is not deferrable: the ship step refuses while one is open.

A question names who answers it in `questionFor`: `owner` for pixels, a picture,
a product or commercial call, or the data model; `pm` for the ticket's shape —
repo, split, order, acceptance wording. Unsure is `owner`.

`skills` lists every skill you invoked; the driver checks it against the run log.
