**Sign-off comes last:** on a PR the owner has already signed, a finding that would change pixels becomes a follow-up ticket, not a fix here. Only a fix the PR cannot merge without (a red check, a Critical) changes them, with `pixel-change-after-signoff: <why>` in its commit, and the owner signs again.

# Step 5b · Check the review's findings

A hunter reviewed this change and made the claims below. Judge each one: is it
real? You edit nothing, run nothing and start nothing in this step.

## What you are given

- Each claim, where it points, and the numbered code around that line: {{FINDINGS}}
- The change: {{DIFF}}

You are given the claim, not the hunter's argument for it. Judge it from the code.

## Try to disprove each listed claim

Read the code shown with each claim first. Open the file it names with Read,
Grep or Glob only when that code is not enough to decide. Read nothing else: no
search across the repository, no review of your own, no new findings.

For each claim, look for the code that shows it is wrong. A claim is **real**
when that search fails: the defect it describes is in the code as it stands.

It is **not real** only on evidence in the code:

- the case it names is already handled, here or where this code is called;
- the line does not exist, or says something other than the claim says;
- the claim misreads what the code does;
- the failure it describes cannot happen.

When the code fits the claim and you cannot disprove it, it is real. Do not
regrade, reword or merge claims: judge only the claims listed.

## Return

JSON only, valid against `schemas/review-check.json`.

<!-- fields:begin — generated from schemas/review-check.json by briefs/return-fields.sh --write review-check; edit the schema, never this list -->
Every field the contract has; `additionalProperties` is false, so no other.

- `step` (required): "review-check"
- `skills` (required): list of string
- `judgements` (required): list of object
- `judgements[].id` (required): string
- `judgements[].real` (required): boolean
- `judgements[].reason` (required): string
- `judgements[].rule` (required): one of "failure-shown-as-success", "wrong-source-of-truth", "one-path-of-several", "race-or-unlocked-write", "screen-out-of-step", "dead-or-unwired", "ticket-part-missing", "access-or-privacy", "data-lost-or-stranded", "edge-case-unhandled", "test-proves-nothing", "docs-out-of-step", "reimplements-existing", "off-design-kit", "unbounded-cost", "other"
<!-- fields:end -->

One judgement per listed claim, by its `id` exactly as listed. Verdict first:
`real` true or false, then a one-line `reason` that quotes the exact code that
shows the claim is real or not real, with its line number. Write no reasoning
before the verdict. Last, `rule`: the one rule on the field's list the claim breaks,
`other` only when none fits; it labels the claim and never changes the verdict. `skills` is empty: this step runs no skill.
