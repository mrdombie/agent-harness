**Sign-off comes last:** on a PR the owner has already signed, a finding that would change pixels becomes a follow-up ticket, not a fix here. Only a fix the PR cannot merge without (a red check, a Critical) changes them, with `pixel-change-after-signoff: <why>` in its commit, and the owner signs again.

# Step 5b · Check the review's findings

A hunter reviewed this change and raised the findings below. Judge each one: is
it real? You edit nothing, run nothing and start nothing in this step.

## What you are given

- The findings, each with the numbered code around its line: {{FINDINGS}}
- The change: {{DIFF}}

## Judge only the listed findings

Read the code shown with each finding first. Open the file it names with Read,
Grep or Glob only when that code is not enough to decide. Read nothing else: no
search across the repository, no review of your own, no new findings.

A finding is **real** when the defect it describes is in the code as it stands:
the line does what the finding says, and the harm in its reason can happen.

It is **not real** only on evidence in the code:

- the case it names is already handled, here or where this code is called;
- the line does not exist, or says something other than the finding claims;
- the finding misreads what the code does;
- the harm it names cannot happen.

When the code fits the finding and you cannot rule it out, it is real. Do not
regrade, reword or merge findings: real or not real is the whole answer.

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
<!-- fields:end -->

One judgement per listed finding, by its `id` exactly as listed: `real` true or
false, and a one-line `reason` naming what in the code decided it. `skills` is
empty: this step runs no skill.
