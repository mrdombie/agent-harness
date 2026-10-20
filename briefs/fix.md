**Sign-off comes last:** once the owner has signed a PR's screens, push no change to them. Its screens are `design.surfacePaths` plus `design.extraScreens` (`approval-kept.sh screens`); release notes are not screens. A review note that would change pixels becomes a follow-up ticket; a required fix that must change pixels says `pixel-change-after-signoff: <why>` in its commit message, and the pre-push guard (`scripts/signoff-push-guard.sh`) puts the hold back on for the owner to sign again.

# Step 6 · Fix what blocks

You are clearing the review's Critical, Major and Minor findings. Nothing else —
a Nit was dropped, so it is not here and not yours to fix in this ticket.

## Invoke the skill — do not work from this file

Run **`superpowers:receiving-code-review`** on the findings, and
**`superpowers:test-driven-development`** for each fix. Those own how a finding is
weighed and how the cycle runs. This brief owns only what the driver needs back
and the traps this project keeps falling into.

## What you are given

- The findings that block (Critical, Major and Minor): {{BLOCKERS}}
- The independent critic's open findings on this ticket's pull request: {{CRITIC_FINDINGS}}

**What you touch, you fix.** A finding whose id starts `polish-` is an item already on the polish list of a screen this change touches. Fix it here, whoever put it there, then record it with the exact `take` command its fix names: the next review clears an item only once it is recorded. A critic finding above is fixed the same way; the critic judges the screen again after CI photographs it.
- The evidence this pull request still owes: {{EVIDENCE_TASKS}}

**Evidence owed is a task, not a note.** A missing shot (a region, an opened state, dark, the phone width) is answered by an edit to the capture plan, committed — a code change alone leaves it open, and the critic fails the PR again.
- The change as it stands: {{DIFF}}
- The round: {{ROUND}}

## Trace the failure path before you land a fix

Ask what a person sees when this throws, nulls, or runs where the checks do not
reach. A run of fix-forwards here each repaired the happy path and broke the
failure path.

- **Do not accept a failure as pre-existing until you have re-verified it** in a
  tree whose generated artefacts exist. A fresh worktree reports failures that
  belong to the worktree, not the branch — a missing generated client, an absent
  environment file, a workspace package resolving to another checkout's copy.
  Prove it against a pristine control cut from the trunk before you say the
  branch is innocent.
- **Changed a value?** Grep the whole test tree for the old one and add every hit
  to the run. The test that pins it is rarely the one you were looking at.
- **A peer may have landed the same feature while you worked.** Reconcile against
  the trunk, keep only the part that is genuinely additive, and file the rest. A
  stub duplicate of something that already shipped is worse than nothing.

A finding you think is wrong is answered with a reason, not with agreement and a
change. If it survives the reason, it was a real finding.

## When the findings are red gates

A finding whose id starts `gate-` is not a review finding: one of this project's
self-check gates went red, and its output is the finding. Repair what the output
names, run that gate's command yourself until it exits 0, commit, and answer each
in `gateFixes` with the commit. There is no red/green test for a compile or lint
error; the driver re-runs every gate straight after this step, and nothing is
pushed past a red one. A red gate you believe this change did not cause goes in
`deferred` with the proof — that parks the ticket for a person.

A ratchet that says its baseline sits ABOVE actual, or names entries that no
longer exist, is telling you the change made things better: run the lowering
command it prints, commit the lowered baseline, and never undo the improvement to
make the numbers meet. Only a number that ROSE wants a code fix.

## A test you reword or remove is accounted for

If you remove, reword or skip an `it(`/`test(` case, list its file in
`replacedTests` (the repo-relative path git shows) with exactly one of `coveredBy`,
a bare path to the test that now pins it, or `removedBecause`. A gate checks them.

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

Conditional:
- when `status` is "fixed": at least one of `cleared`, `gateFixes`
- otherwise: requires `question`
<!-- fields:end -->

One `cleared` entry per review finding, each carrying the change, the test that goes red
when that finding returns, and the red and green runs. A finding cleared without
a test is one that can come back unnoticed, so the contract has no shape for it.

It also carries `testCommit` and `implCommit`, and they must be two commits. The
driver re-runs your test at the change's parent and at the change, exactly as it
does in the build step, so those two shas are what make `failedBefore` checkable
rather than claimed.

A finding you are not clearing goes in `deferred` with its reason and where it
went. A deferral with no follow-up is a finding dropped — and a Critical or a
Major is not deferrable: the ship step refuses while one is open.

A question names who answers it in `questionFor`: `owner` for pixels, a picture,
a product or commercial call, or the data model; `pm` for the ticket's shape —
repo, split, order, acceptance wording. Unsure is `owner`.

`skills` lists every skill you invoked. The driver reads the run log too, so a
skill claimed here and absent there fails the step.
