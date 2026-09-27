# Step 5 · Review

You are reviewing a finished change and returning a verdict with every finding
behind it, each graded. You do not edit anything in this step.

## Invoke the skill — do not work from this file

Run **`superpowers:requesting-code-review`**. It owns how a review is conducted.
This brief owns only how a finding is graded here and what the driver needs back.

## What you are given

- The change: {{DIFF}}
- The renders of every screen it touches: {{RENDERS}}
- The round: {{ROUND}}
- This project: {{PROJECT_FACTS}}

## Grade every finding

Every finding carries a **grade**, and the grade is what decides its effect. Two of
the four send work back; the other two never do.

| Grade | What it means | What happens to it |
|---|---|---|
| `critical` | wrong data, a security hole, lost work, something published unapproved | goes back to the build step; fixed in this ticket |
| `major` | a person is misled or stuck: an untrue screen, a dead control, a failure shown as success | goes back to the build step; fixed in this ticket |
| `minor` | polish: spacing, wording, a small visual slip | never blocks; leaves as one follow-up ticket for the whole review |
| `nit` | taste | dropped |

**A Critical or a Major names who is harmed and how, in the `reason`, in a user's
words.** "The button is not wired" is a claim about the code; "the person clicks
Save, sees it succeed, and the draft is gone" is the harm. A finding whose harm you
cannot write in one line is a Minor — grade it Minor and move on. This is the whole
point of the scale: the step-runner went four rounds, eleven findings then seven
then six, and about a quarter of them were spacing and wording. Each of those cost
a round a real defect needed.

Grading down is not being generous. A Minor is not dropped — it leaves as a ticket
with your words in it, at the Minor priority, worked when nothing bigger waits.

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

The verdict is read off the grades, never typed beside them: `SHIP` with a Critical
or a Major, and `BLOCKED` with neither, are both refused. Every finding carries its
file, its line, its grade, the one-line `reason` in a user's words, and the fix.

There is ONE list. The grade already says what each finding costs, so a second list
is a second place for the two to disagree.

`skills` lists every skill you invoked. The driver reads the run log too, so a
skill claimed here and absent there fails the step.
