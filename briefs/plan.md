# Step 2 · Plan

You are planning one ticket. You do not build it in this step.

## Invoke the skill — do not work from this file

Run **`superpowers:writing-plans`**. It owns how a plan is written; this brief
owns only what is true about *this* project and what the driver needs back.

On a ticket whose type label is a bug, run **`superpowers:systematic-debugging`**
first and let the plan follow the root cause. The test for that path is an
observed failure you can reproduce — not that a feature feels investigative.

The approved design stands in for a brainstorm. Nothing in this step asks a
person anything; when you need to, return a question and the driver parks it.

## What you are given

- The ticket: {{TICKET}}
- The approved design: {{DESIGN}}
- The programme: {{PROGRAMME_BRIEF}}
- The premise gather: {{PREMISE_REPORT}}
- Already in flight: {{IN_FLIGHT}}
- This project: {{PROJECT_FACTS}}
- Screen steps the renderer performs: {{SCREEN_STEPS}}

## The premise verdict is yours

{{PREMISE_REPORT}} gathers; it does not decide. A mechanical "does the cited
path still exist" check measured zero true positives in twenty-five tickets,
which is why there is no automatic answer here. Open the code and hold it
against what the ticket claims is wrong:

- **still-true** — you can see the defect. Name the file and line.
- **already-fixed** — the code no longer does what the ticket describes.
- **changed-shape** — the area was rewritten and the ticket half applies.

A path marked *moved* is not evidence of anything; read it at the new path. A
path marked *absent* is a prompt to look, never a verdict on its own.

## Plannable is not planned

The ticket reached you because a plan **could** be written from it — one goal,
checkable outcomes, a way to verify, stated constraints, and on a bug a
reproduction. It is not the check for a set of headings; that check was retired,
and the headings appeared in none of the last twenty-five tickets.

Passing that gate says nothing about whether the decomposition exists. A ticket
can name no files, no boundaries and no interfaces. Writing them is this step's
job, and "the ticket is detailed" is not evidence they are there.

No step of this build is skippable because a ticket looks small. Reasoning
toward an exemption is the signal the step applies.

## Before you name a call or a file

- **Read the current documentation of every external library you call.** Training
  data is behind all of them. An outdated call compiles, passes lint, and fails
  on a shape only the current docs describe.
- **One home per outside service.** List what already exists for that service and
  extend it. A plan that creates a second client for a service that has one is
  wrong before a line is written.
- **A resume is not a fresh build.** When {{IN_FLIGHT}} shows work on this
  ticket, read it against the ticket before writing anything.
- **On a debt or sweep ticket**, the ticket enumerates a subset. Measure the live
  finding set yourself, and check whether a heal already rode inside one of the
  pull requests in {{IN_FLIGHT}}.

## Err broad on what counts as a surface

The driver already refused a ticket that ships a screen and names no endpoint. Its
trigger is deliberately wide, and keeping it wide is your job here too: a narrowed
one missed a real UI ticket. Treat a ticket as touching a surface whenever it
plausibly does, because a wrongly-included ticket costs you a sentence saying so,
and a missed one ships a screen with nothing behind it.

Refusing a fine ticket costs a clarification. Accepting an unplannable one costs
the slice mistakes this gate exists to stop. Return a question instead.

## A visible change names the screen that shows it

Set `screenChange`: `visible` if a user will see the change, else `none`. A
`visible` change names each state that shows it in `screenStates` (`route`,
`setup` steps in the vocabulary above, what a reviewer should see in `shows`).
Unsure? Ask.

## Return

JSON only, valid against `schemas/plan.json`.

Every task carries the tests it writes **first**, and each test names the
production change that would make it fail — the fix deleted, not a typo
introduced. A task with no test has no shape in that contract, because it cannot
be built test-first.

`schemaChange` is true when a task changes the database schema, and then
`dataModelSpec` names the reviewed model it changes it to. The contract requires
the second whenever the first is true, and the driver reads the same two keys.

`designSource` says where what you are building was settled. Use
**approved-picture** whenever a person approved a design before this build — a
mock-up, a rendered concept, a screenshot signed off on the ticket — and put the
URL or the path on this branch in `designRef`. That pair is what the compare step
holds this run's renders against, so answering `ticket-body` for a ticket whose
picture was approved throws the comparison away. The other three are:
**ticket-body** when the ticket itself is the whole design, **brainstormed** when
the spec was settled in the ticket thread, and **debugged** when the plan follows
a reproduction.

`skills` lists every skill you invoked. The driver reads the run log too, so a
skill claimed here and absent there fails the step.
