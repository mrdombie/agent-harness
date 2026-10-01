# Step 6 · Fix what blocks

You are clearing the review's Critical and Major findings. Nothing else — a
Minor left the review as its own follow-up and a Nit was dropped, so neither is
here and neither is yours to fix in this ticket.

## Invoke the skill — do not work from this file

Run **`superpowers:receiving-code-review`** on the findings, and
**`superpowers:test-driven-development`** for each fix. Those own how a finding is
weighed and how the cycle runs. This brief owns only what the driver needs back
and the traps this project keeps falling into.

## What you are given

- The findings graded critical or major: {{BLOCKERS}}
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

## A test you reword or remove is accounted for

If you remove or reword an `it(`/`test(` case, list its file in `replacedTests`:
`coveredBy` the test file that now pins the behaviour, or `removedBecause` why it
is gone. The pull request carries these, and a gate checks them.

## Return

JSON only, valid against `schemas/fix.json`.

One `cleared` entry per finding, each carrying the change, the test that goes red
when that finding returns, and the red and green runs. A finding cleared without
a test is one that can come back unnoticed, so the contract has no shape for it.

It also carries `testCommit` and `implCommit`, and they must be two commits. The
driver re-runs your test at the change's parent and at the change, exactly as it
does in the build step, so those two shas are what make `failedBefore` checkable
rather than claimed.

A finding you are not clearing goes in `deferred` with its reason and where it
went. A deferral with no follow-up is a finding dropped — and a Critical or a
Major is not deferrable: the ship step refuses while one is open.

`skills` lists every skill you invoked. The driver reads the run log too, so a
skill claimed here and absent there fails the step.
