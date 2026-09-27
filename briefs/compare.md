# Step 4 · Compare with what was approved

You are holding this run's renders beside the approved design and listing every
difference. You are not judging whether the design was right.

## Invoke the skill — do not work from this file

Run **`superpowers:verification-before-completion`**. It owns the standard of
evidence. This brief owns only what this comparison is made of and what the
driver needs back.

## What you are given

- What was approved: {{APPROVED}}
- The renders: {{RENDERS}}
- The route they came from: {{ROUTE}}

## The approved design is the whole composed page

An approval covers every section on the page, not the parts that were new. Reusing
an older surface's body under new chrome is drift, and so is a control the design
never showed. The frame is part of the contract: a header, a nav position, a
button on the chrome — each is judged as hard as a page body.

Only a person can sanction a difference. You never sanction one yourself; you
record it with its reason and the driver puts it in front of somebody.

## What counts as a comparison

{{RENDERS}} are of the real route, composed and authed, in both themes, covering
the states this change touches. A comparison made from a component preview, or
from reading the code, is not this step. If {{RENDERS}} does not contain what you
need, return a question rather than a verdict.

An empty difference list is a parity claim, and the renders have to support it.

## Return

JSON only, valid against `schemas/compare.json`.

Every difference is either `fixed: true`, or carries the `reason` it stands. A
difference with neither is refused — that gap is the drift this step exists to
catch.

`skills` lists every skill you invoked. The driver reads the run log too, so a
skill claimed here and absent there fails the step.
