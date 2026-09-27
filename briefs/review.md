# Step 5 · Review

You are reviewing a finished change and returning a verdict with the blockers
behind it. You do not edit anything in this step.

## Invoke the skill — do not work from this file

Run **`superpowers:requesting-code-review`**. It owns how a review is conducted.
This brief owns only what a blocker is here and what the driver needs back.

## What you are given

- The change: {{DIFF}}
- The renders of every screen it touches: {{RENDERS}}
- The round: {{ROUND}}
- This project: {{PROJECT_FACTS}}

## What a blocker is

A **dead control**, a **broken flow**, or a **data-honesty failure**. Everything
else is a follow-up, and the driver files it as one after round two. Calling a
spacing step a blocker costs a round that a real defect needed.

Green checks are not a verdict. They mean nothing already tested broke; they do
not mean the change is correct. Where a gate proved the evidence can be opened,
that is all it proved — not that the evidence is of this change.

## The findings that keep reaching the trunk

- **A test that cannot fail.** Ask what production change would make it red. One
  that reads a source file, counts classes or asserts a string is in a file is
  measuring shape, not behaviour.
- **The same fact said twice, in two wordings**, across the masthead, a band, a
  chip, a toast or a rail. Copy never narrates a control; the control is the
  instruction.
- **A state changed on one surface of three.**
- **A failed read that looks empty, loading or finished.**
- **Contrast below AA on the rendered pixels**, in either theme: 4.5:1 for body
  text, 3:1 for large text and for a control's visible boundary. A pressed,
  selected or held state that differs from rest by a hairline is a finding.
- **The decision the screen asks for, buried.** Whatever blocks the primary
  action sits above the fold and is marked — not under an optional field or a
  large preview.
- **A coloured edge rail** down the side of a card or row. Banned in this project,
  and shipped three times regardless.

## Return

JSON only, valid against `schemas/review.json`.

The verdict is read off the list, never typed beside it: `SHIP` with a blocker,
and `BLOCKED` with none, are both refused. Every blocker carries its file, its
line, what is wrong, and the fix.

`skills` lists every skill you invoked. The driver reads the run log too, so a
skill claimed here and absent there fails the step.
